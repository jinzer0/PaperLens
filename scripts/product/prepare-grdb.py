#!/usr/bin/env python3
"""Prepare the pinned official GRDB framework; never execute the product."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import stat
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
MANIFEST = ROOT / "scripts/topology/dependencies.json"
PIN = {"url": "https://github.com/groue/GRDB.swift.git", "version": "7.11.1", "commit": "b83108d10f42680d78f23fe4d4d80fc88dab3212"}
PACKAGE_SHA256 = "4118b6c48dcb87f91d95fe40420371b8a474a44b0b0be2bf0417e0be1ebf7853"


class Failure(Exception):
    """Fixed diagnostic code, without paths or upstream exception contents."""

    def __init__(self, code):
        self.code = code
        super().__init__(code)


def require(condition, code):
    if not condition:
        raise Failure(code)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def checked_path(value):
    path = Path(os.path.abspath(value))
    require(".." not in Path(value).parts, "UNSAFE_PATH")
    require(not any(part.is_symlink() for part in [path, *path.parents]), "SYMLINK_INPUT")
    return path


def read_bytes(path):
    path = checked_path(path)
    require(path.is_file(), "INPUT_MISSING")
    return path.read_bytes()


def json_object(data):
    def pairs(items):
        result = {}
        for key, value in items:
            require(key not in result, "INVALID_JSON")
            result[key] = value
        return result

    try:
        result = json.loads(data, object_pairs_hook=pairs)
    except (ValueError, UnicodeError):
        raise Failure("INVALID_JSON") from None
    require(isinstance(result, dict), "INVALID_JSON")
    return result


def environment(home, developer):
    return {
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": str(home),
        "CFFIXED_USER_HOME": str(home), "LANG": "C", "LC_ALL": "C",
        "DEVELOPER_DIR": developer, "TOOLCHAINS": "com.apple.dt.toolchain.XcodeDefault",
        "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_TERMINAL_PROMPT": "0", "GIT_OPTIONAL_LOCKS": "0", "GIT_NO_REPLACE_OBJECTS": "1",
    }


def sandbox(output=None):
    profile = '(version 1)(allow default)(deny network*)'
    writable = '(literal "/dev/null")'
    if output is not None:
        # JSON quoting also escapes the sandbox string delimiter and backslashes.
        writable = '(require-any (subpath ' + json.dumps(str(output)) + ') ' + writable + ')'
    # Keep the write rules disjoint: an owned-output write must not also match
    # an unconditional denial. This changes no writable namespace.
    return profile + '(deny file-write* (require-not ' + writable + '))' + '(allow file-write* ' + writable + ')'


def command(argv, env, *, output=None, label=None):
    argv = ["/usr/bin/sandbox-exec", "-p", sandbox(output), *map(str, argv)]
    if output is None:
        completed = subprocess.run(argv, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
        stdout = completed.stdout
    else:
        # Open exclusive logs before starting; retain full bytes on failure.
        with (output / "logs" / (label + ".stdout")).open("xb") as out:
            with (output / "logs" / (label + ".stderr")).open("xb") as err:
                completed = subprocess.run(argv, env=env, stdout=out, stderr=err, check=False)
        stdout = read_bytes(output / "logs" / (label + ".stdout"))
    require(completed.returncode == 0, "BUILD_FAILED" if label == "build" else "TOOL_FAILED")
    return stdout


def git(source, env, *args):
    return command([
        "/usr/bin/git", "--no-optional-locks", "--no-replace-objects",
        "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false",
        "-C", source, *args,
    ], env)


def inventory(root, *, framework=False):
    result = {}

    def walk_error(error):
        raise Failure("OUTPUT_INVALID" if framework else "SOURCE_TAMPERED") from None

    for directory, dirs, files in os.walk(root, followlinks=False, onerror=walk_error):
        if not framework and Path(directory) == root:
            dirs[:] = [name for name in dirs if name != ".git"]
        for name in sorted(dirs + files):
            path = Path(directory) / name
            relative = path.relative_to(root).as_posix()
            mode = path.lstat().st_mode
            if stat.S_ISLNK(mode):
                code = "OUTPUT_INVALID" if framework else "SOURCE_TAMPERED"
                try:
                    target = path.resolve(strict=True)
                except (OSError, RuntimeError):
                    raise Failure(code) from None
                require(target.is_relative_to(root) and target.exists(), code)
                result[relative] = {"link": os.readlink(path)}
            elif stat.S_ISREG(mode):
                result[relative] = {"sha256": digest(path.read_bytes()), "executable": bool(mode & 0o111)}
            else:
                require(stat.S_ISDIR(mode), "OUTPUT_INVALID" if framework else "SOURCE_TAMPERED")
    return result


def validate_inputs(receipt_path, manifest_path):
    receipt_path, manifest_path = checked_path(receipt_path), checked_path(manifest_path)
    receipt_bytes, manifest_bytes = read_bytes(receipt_path), read_bytes(manifest_path)
    receipt, lock = json_object(receipt_bytes), json_object(manifest_bytes)
    require(lock.get("grdb") == PIN, "PIN_MISMATCH")
    require(set(receipt) == {"schemaRevision", "sourceOnly", "lockHash", "pin", "source", "tree", "packageSwiftSha256"}, "RECEIPT_INVALID")
    require(receipt["schemaRevision"] == "grdb-source-only-v1" and receipt["sourceOnly"] is True, "RECEIPT_INVALID")
    require(receipt["pin"] == PIN and receipt["lockHash"] == digest(manifest_bytes), "INPUT_TAMPERED")
    require(receipt["source"] == "grdb-source/src" and receipt_path.parent.name == "grdb-source", "RECEIPT_INVALID")
    require(isinstance(receipt["tree"], str) and re.fullmatch(r"[0-9a-f]{40}", receipt["tree"]), "RECEIPT_INVALID")
    require(receipt["packageSwiftSha256"] == PACKAGE_SHA256, "INPUT_TAMPERED")
    source = checked_path(receipt_path.parent / "src")
    require(source.is_dir() and checked_path(source / ".git").is_dir(), "INPUT_MISSING")
    for directory, dirs, files in os.walk(source / ".git", followlinks=False):
        require(not any((Path(directory) / name).is_symlink() for name in dirs + files), "SOURCE_TAMPERED")
    # No alternate object databases or local includes/filters/commands are admitted.
    require(not (source / ".git/objects/info/alternates").exists(), "SOURCE_TAMPERED")
    config = read_bytes(source / ".git/config").decode("utf-8")
    require(all(line.strip().lower() in ("", "[core]") or re.fullmatch(
        r"\s*(repositoryformatversion|filemode|bare|logallrefupdates|ignorecase|precomposeunicode)\s*=\s*(0|true|false)\s*", line, re.I
    ) for line in config.splitlines()), "SOURCE_TAMPERED")
    developer = lock.get("toolchain", {}).get("developerDir")
    require(developer == "/Applications/Xcode.app/Contents/Developer", "TOOLCHAIN_MISMATCH")
    env = environment("/var/empty", developer)
    require(git(source, env, "rev-parse", "HEAD").strip().decode() == PIN["commit"], "SOURCE_TAMPERED")
    require(git(source, env, "rev-parse", "HEAD^{tree}").strip().decode() == receipt["tree"], "SOURCE_TAMPERED")
    git(source, env, "fsck", "--full", "--strict", "--no-reflogs", PIN["commit"])
    require(git(source, env, "diff", "--cached", "--no-ext-diff", "--no-textconv", "--name-only", "-z", "HEAD", "--") == b"", "SOURCE_TAMPERED")
    tracked = {}
    for entry in git(source, env, "ls-tree", "-rz", "--full-tree", "HEAD").split(b"\0"):
        if not entry:
            continue
        metadata, name_bytes = entry.split(b"\t", 1)
        mode, kind, oid = metadata.split()
        name = name_bytes.decode("utf-8")
        # The approved repository includes an unused SQLiteCustom/src gitlink.
        # Never initialize it, fetch it or accept materialized submodule bytes.
        if mode == b"160000" and kind == b"commit":
            path = checked_path(source / name)
            require(path.is_relative_to(source), "SOURCE_TAMPERED")
            require(not path.exists() or (path.is_dir() and not any(path.iterdir())), "SOURCE_TAMPERED")
            continue
        require(mode in (b"100644", b"100755", b"120000") and kind == b"blob", "SOURCE_TAMPERED")
        if mode == b"120000":
            path = checked_path((source / name).parent) / Path(name).name
            require(path.is_relative_to(source) and path.is_symlink(), "SOURCE_TAMPERED")
            data = os.fsencode(os.readlink(path))
            blob = hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest().encode()
            require(blob == oid, "SOURCE_TAMPERED")
            tracked[name] = {"link": os.readlink(path)}
            continue
        path = checked_path(source / name)
        require(path.is_relative_to(source), "SOURCE_TAMPERED")
        data = read_bytes(path)
        blob = hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest().encode()
        require(blob == oid and bool(path.stat().st_mode & 0o111) == (mode == b"100755"), "SOURCE_TAMPERED")
        tracked[name] = {"sha256": digest(data), "executable": mode == b"100755"}
    require(inventory(source) == tracked, "SOURCE_TAMPERED")
    require(tracked.get("Package.swift", {}).get("sha256") == PACKAGE_SHA256, "INPUT_TAMPERED")
    require("GRDB.xcodeproj/project.pbxproj" in tracked, "INPUT_MISSING")
    return source, lock, {
        "manifestSha256": digest(manifest_bytes), "sourceReceiptSha256": digest(receipt_bytes),
        "tree": receipt["tree"], "sourceInventory": tracked,
    }


def validate_toolchain(lock, env, output):
    expected = lock["toolchain"]

    def probe(argv, label):
        return command(argv, env, output=output, label=label).decode("utf-8").strip()

    require(probe(["/usr/bin/xcodebuild", "-version"], "xcode") == f"Xcode {expected['xcode']}\nBuild version {expected['build']}", "TOOLCHAIN_MISMATCH")
    require(probe(["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-version"], "sdk-version") == expected["sdk"], "TOOLCHAIN_MISMATCH")
    swift = probe(["/usr/bin/xcrun", "--toolchain", env["TOOLCHAINS"], "swiftc", "--version"], "swift")
    require(re.search(r"Apple Swift version " + re.escape(expected["swift"]) + r"(?:\s|\.)", swift), "TOOLCHAIN_MISMATCH")
    sdk = Path(probe(["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-path"], "sdk-path"))
    require(sdk.is_absolute() and sdk.is_relative_to(expected["developerDir"]) and sdk.is_dir(), "TOOLCHAIN_MISMATCH")
    linker = Path(probe(["/usr/bin/xcrun", "--sdk", "macosx", "--find", "ld"], "linker-path"))
    require(linker == Path(expected["developerDir"]) / "Toolchains/XcodeDefault.xctoolchain/usr/bin/ld", "TOOLCHAIN_MISMATCH")
    details = json_object(command([linker, "-version_details"], env, output=output, label="linker-version"))
    require(details.get("version") == expected["systemLinkerVersion"], "TOOLCHAIN_MISMATCH")
    require(expected["deploymentTarget"] == "15.0", "TOOLCHAIN_MISMATCH")
    return {"pins": expected, "linkerSha256": digest(read_bytes(linker))}


def build_arguments(source, output, lock, arch):
    require(arch == "arm64", "INVALID_ARCHITECTURE")
    return [
        "/usr/bin/xcodebuild", "-project", source / "GRDB.xcodeproj", "-target", "GRDB",
        "-configuration", "Release", "-sdk", "macosx", "build",
        "ARCHS=" + arch, "ONLY_ACTIVE_ARCH=NO", "SUPPORTED_PLATFORMS=macosx",
        "MACOSX_DEPLOYMENT_TARGET=" + lock["toolchain"]["deploymentTarget"],
        "CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO", "CODE_SIGN_IDENTITY=",
        "SYMROOT=" + str(output / "build"), "OBJROOT=" + str(output / "intermediates"),
        "CONFIGURATION_BUILD_DIR=" + str(output / "products"),
        "SHARED_PRECOMPS_DIR=" + str(output / "precompiled"),
        "CLANG_MODULE_CACHE_PATH=" + str(output / "cache/clang"),
        "SWIFT_MODULE_CACHE_PATH=" + str(output / "cache/swift"),
        "COMPILER_INDEX_STORE_ENABLE=NO",
    ]


def validate_output(output, lock, env, arch):
    require(arch == "arm64", "INVALID_ARCHITECTURE")
    require(not (output / "products").is_symlink(), "OUTPUT_INVALID")
    framework = output / "products/GRDB.framework"
    require(framework.is_dir() and not framework.is_symlink(), "OUTPUT_INVALID")
    files = inventory(framework, framework=True)
    binary = framework / "GRDB"
    require(binary.is_file() and binary.resolve(strict=True).is_relative_to(framework), "OUTPUT_INVALID")

    def inspect(flag, label):
        return command(["/usr/bin/otool", flag, binary], env, output=output, label=label).decode("utf-8")

    binary_archs = command(["/usr/bin/lipo", "-archs", binary], env, output=output, label="cpu").decode().split()
    require(binary_archs == [arch], "OUTPUT_INVALID")
    require(set(re.findall(r"\b(EXECUTE|DYLIB|BUNDLE)\b", inspect("-hv", "macho"))) == {"DYLIB"}, "OUTPUT_INVALID")
    identifiers = inspect("-D", "install-id").splitlines()[1:]
    require(len(identifiers) == 1 and identifiers[0].strip() == "@rpath/GRDB.framework/Versions/A/GRDB", "OUTPUT_INVALID")
    names = [line.strip().split(" (compatibility version", 1)[0] for line in inspect("-L", "links").splitlines()[1:]]
    require(names and names[0] == identifiers[0].strip(), "OUTPUT_INVALID")
    require("/usr/lib/libsqlite3.dylib" in names[1:] and all(
        name.startswith(("/usr/lib/", "/System/Library/Frameworks/")) and "/../" not in name
        for name in names[1:]
    ), "OUTPUT_INVALID")
    loads = inspect("-l", "load-commands")
    build_versions = [block for block in re.split(r"\nLoad command \d+\n", loads) if re.search(r"^\s*cmd LC_BUILD_VERSION\s*$", block, re.M)]
    require(len(build_versions) == 1, "OUTPUT_INVALID")
    version = build_versions[0]
    require(re.search(r"^\s*platform (?:1|MACOS)\s*$", version, re.M), "OUTPUT_INVALID")
    for field, expected in (("minos", lock["toolchain"]["deploymentTarget"]), ("sdk", lock["toolchain"]["sdk"])):
        require(re.search(r"^\s*" + field + r" " + re.escape(expected) + r"(?:\.0)?\s*$", version, re.M), "OUTPUT_INVALID")
    for relative in ("Headers/GRDB.h", "Modules/module.modulemap", "Modules/GRDB.swiftmodule/" + arch + "-apple-macos.swiftmodule", "Resources/Info.plist"):
        path = framework / relative
        require(path.is_file() and path.resolve(strict=True).is_relative_to(framework) and path.stat().st_size > 0, "OUTPUT_INVALID")
    info = plistlib.loads((framework / "Resources/Info.plist").read_bytes())
    require(info.get("CFBundleExecutable") == "GRDB" and info.get("CFBundlePackageType") == "FMWK", "OUTPUT_INVALID")
    require(not any("_CodeSignature" in Path(name).parts for name in files), "OUTPUT_INVALID")
    return files


def prepare(receipt_path, output, arch, manifest_path=MANIFEST):
    require(arch == "arm64", "INVALID_ARCHITECTURE")
    output = checked_path(output)
    require(not output.exists(), "OUTPUT_OCCUPIED")
    require(output.parent.is_dir(), "OUTPUT_PARENT_MISSING")
    source, lock, inputs = validate_inputs(receipt_path, manifest_path)
    for path in (source.parent, checked_path(manifest_path)):
        require(not output.is_relative_to(path) and not path.is_relative_to(output), "OUTPUT_OVERLAP")
    require(sys.platform == "darwin" and platform.machine() == "arm64", "NATIVE_ARM64_REQUIRED")
    env = environment("/var/empty", lock["toolchain"]["developerDir"])
    require(command(["/usr/sbin/sysctl", "-in", "sysctl.proc_translated"], env).strip() == b"0", "NATIVE_ARM64_REQUIRED")
    try:
        output.mkdir()
    except FileExistsError:
        raise Failure("OUTPUT_OCCUPIED") from None
    for name in ("home", "cache", "tmp", "logs", "products", "build", "intermediates", "precompiled"):
        (output / name).mkdir()
    env = environment(output / "home", lock["toolchain"]["developerDir"])
    env.update({"TMPDIR": str(output / "tmp") + "/", "XDG_CACHE_HOME": str(output / "cache"), "CLANG_MODULE_CACHE_PATH": str(output / "cache/clang")})
    tools = validate_toolchain(lock, env, output)
    driver_hash = digest(read_bytes(Path(__file__)))
    require(validate_inputs(receipt_path, manifest_path)[2] == inputs, "INPUT_TAMPERED")
    command(build_arguments(source, output, lock, arch), env, output=output, label="build")
    _, _, after = validate_inputs(receipt_path, manifest_path)
    require(inputs == after and digest(read_bytes(Path(__file__))) == driver_hash, "INPUT_TAMPERED")
    files = validate_output(output, lock, env, arch)
    # Recheck after static inspection as well; no successful receipt on drift.
    require(validate_inputs(receipt_path, manifest_path)[2] == inputs, "INPUT_TAMPERED")
    require(inventory(output / "products/GRDB.framework", framework=True) == files, "OUTPUT_INVALID")
    result = {
        "schemaRevision": "grdb-unsigned-preparation-v1", "pin": PIN,
        "inputs": inputs, "driverSha256": driver_hash, "toolchain": tools,
        "framework": "products/GRDB.framework", "frameworkInventory": files,
        "architecture": arch, "configuration": "Release", "codeSigningAllowed": False,
        "runtimeExecuted": False, "lintStatus": "UNKNOWN",
        "logs": {path.name: digest(read_bytes(path)) for path in sorted((output / "logs").iterdir())},
    }
    try:
        stream = (output / "preparation.json").open("x")
    except FileExistsError:
        raise Failure("OUTPUT_OCCUPIED") from None
    with stream:
        json.dump(result, stream, indent=2, sort_keys=True)
        stream.write("\n")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-receipt", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, default=MANIFEST)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--arch", choices=("arm64",), required=True)
    args = parser.parse_args()
    try:
        result = prepare(args.source_receipt, args.output, args.arch, args.manifest)
    except Failure as error:
        print(json.dumps({"status": "failed", "code": error.code}))
        return 1
    except (OSError, ValueError, KeyError, TypeError, UnicodeError, RuntimeError):
        print(json.dumps({"status": "failed", "code": "INVALID_INPUT_OR_OUTPUT"}))
        return 1
    print(json.dumps({"status": "prepared", "schemaRevision": result["schemaRevision"], "runtimeExecuted": False}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
