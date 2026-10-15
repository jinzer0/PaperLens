#!/usr/bin/env python3
"""Compile the numeric ROLL regression from the approved PDFium Ninja recipe."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shlex
import sys

# -I removes the script directory; add only this tooling directory.
sys.path.insert(0, str(Path(__file__).resolve().parent))
import acquire

ROOT = Path(__file__).resolve().parents[2]
ENGINE = "core/fpdfapi/page/cpdf_psengine.cpp"
PATCHED_SHA256 = "0aa9216ebb101fd28f55d929050a053900a960fa7037a688379f26d2ddbcf7c9"


def resolved_argument(value, directory):
    return (directory / value).resolve()


def select_command(database, source, output):
    matches = []
    for entry in database:
        directory = Path(entry["directory"])
        acquire.require(directory.is_absolute(), "compdb_directory_invalid")
        if resolved_argument(entry["file"], directory) == source / ENGINE:
            matches.append(entry)
    acquire.require(len(matches) == 1, "engine_command_not_unique")
    entry = matches[0]
    acquire.require(Path(entry["directory"]).resolve() == output.resolve(), "compdb_directory_mismatch")
    argv = entry.get("arguments")
    if argv is None:
        argv = shlex.split(entry["command"], posix=True)
    acquire.require(isinstance(argv, list) and all(isinstance(arg, str) for arg in argv), "compdb_arguments_invalid")
    return argv


def transform_command(argv, source, output, test, obj):
    compiler = source / "third_party/llvm-build/Release+Asserts/bin/clang++"
    acquire.require(argv and resolved_argument(argv[0], output) == compiler.resolve(), "unexpected_compiler")
    kept = [str(compiler)]
    inputs = outputs = compiles = 0
    index = 1
    while index < len(argv):
        arg = argv[index]
        acquire.require(not arg.startswith("@") and arg not in (";", "&&", "||", "|"), "unsafe_compile_command")
        if arg in ("-o", "-MF", "-MT", "-MQ"):
            acquire.require(index + 1 < len(argv), "missing_compile_argument")
            if arg == "-o":
                outputs += 1
            index += 2
            continue
        if arg == "-c":
            compiles += 1
        elif arg in ("-MMD", "-MD", "-MP"):
            pass
        elif resolved_argument(arg, output) == source / ENGINE:
            inputs += 1
        else:
            acquire.require(not arg.endswith((".cpp", ".cc", ".c", ".cxx", ".C", ".m", ".mm", ".s", ".S", ".o", ".a", ".bc")), "unexpected_compile_input")
            kept.append(arg)
        index += 1
    acquire.require(inputs == outputs == compiles == 1, "unexpected_compile_shape")
    return [*kept, "-c", str(test), "-o", str(obj)]


def link_command(compile_argv, obj, archive, executable, arch, sdk, deployment):
    acquire.require(arch == "arm64", "unsupported_target_cpu")
    # Only driver/ABI options from the actual compile recipe belong at link time.
    flags = []
    index = 1
    while index < len(compile_argv):
        arg = compile_argv[index]
        if arg in ("-isysroot", "-target", "--target", "-arch", "-stdlib"):
            flags.extend(compile_argv[index:index + 2])
            index += 2
            continue
        if arg.startswith(("--target=", "-target=", "-stdlib=", "-mmacos-version-min=", "-fsanitize=", "-fsanitize-trap=")):
            flags.append(arg)
        index += 1
    acquire.require(f"--target={arch}-apple-macos" in flags, "compile_arch_mismatch")
    acquire.require(f"-mmacos-version-min={deployment}" in flags, "compile_deployment_mismatch")
    acquire.require("-isysroot" in flags and flags[flags.index("-isysroot") + 1] == sdk, "compile_sdk_mismatch")
    acquire.require(not any(flag.startswith("-stdlib=") and flag != "-stdlib=libc++" for flag in flags), "compile_libcxx_mismatch")
    return [compile_argv[0], *flags, str(obj), str(archive), "-framework", "AppKit", "-framework", "CoreFoundation", "-framework", "CoreGraphics", "-framework", "Security", "-o", str(executable)]


def native_execution(arch):
    acquire.require(arch == "arm64", "unsupported_target_cpu")
    host = platform.machine()
    acquire.require(host == "arm64" and sys.platform == "darwin", "unsupported_host_cpu")
    try:
        translated = acquire.run(["/usr/sbin/sysctl", "-in", "sysctl.proc_translated"], env=acquire.clean_env(), offline=True)
    except acquire.Failure:
        raise acquire.Failure("native_host_not_proven") from None
    else:
        acquire.require(translated == "0", "rosetta_forbidden")
    return True


def save_result(path, result):
    acquire.safe_path(path.parent, path.name)
    temporary = acquire.safe_path(path.parent, path.name + ".tmp")
    acquire.exclusive_bytes(temporary, (json.dumps(result, sort_keys=True, indent=2) + "\n").encode())
    os.replace(temporary, path)


def verify(arch):
    native_execution(arch)
    lock = acquire.load_lock()
    work = acquire.ensure_root(ROOT / ".build/topology" / arch)
    source = acquire.safe_path(work, "pdfium/src")
    output = acquire.safe_path(work, "pdfium/out")
    archive = acquire.safe_path(work, "deps/libpdfium.a")
    build = json.loads(acquire.safe_path(work, "pdfium-build.json").read_text())
    acquire.require(build["arch"] == arch and build["sourceCommit"] == lock["pdfium"]["commit"] and build["depsBlob"] == lock["pdfium"]["depsBlob"], "pdfium_build_receipt_mismatch")
    acquire.check_hash(archive, build["sha256"])
    acquire.check_hash(acquire.safe_path(source, ENGINE), PATCHED_SHA256)
    # Reuse the preparation receipt: never substitute a host-installed compiler.
    inventories = json.loads(acquire.safe_path(work, "prepared-tools.json").read_text())
    compiler_directory = "third_party/llvm-build/Release+Asserts"
    acquire.require(compiler_directory in inventories, "compiler_inventory_missing")
    for path, expected in inventories.items():
        acquire.require(acquire.tree_inventory(acquire.safe_path(source, path)) == expected, "prepared_tool_integrity_mismatch")
    env = acquire.clean_env()
    database = json.loads(acquire.run([source / "third_party/ninja/ninja", "-C", output, "-t", "compdb", "cxx"], cwd=source, env=env, offline=True))
    test = acquire.safe_path(ROOT, "Tests/Topology/PDFiumRollTests.cpp")
    directory = acquire.ensure_root(acquire.safe_path(work, "pdfium-roll"))
    obj = acquire.safe_path(directory, "PDFiumRollTests.o")
    executable = acquire.safe_path(directory, "PDFiumRollTests")
    argv = select_command(database, source, output)
    compile_argv = transform_command(argv, source, output, test, obj)
    sdk = f"sdk/xcode_links/MacOSX{lock['toolchain']['sdk']}.sdk"
    expected_sdk = Path(lock["toolchain"]["developerDir"]) / "Platforms/MacOSX.platform/Developer/SDKs" / f"MacOSX{lock['toolchain']['sdk']}.sdk"
    acquire.require((output / sdk).resolve() == expected_sdk.resolve(), "sdk_alias_mismatch")
    acquire.require(f'-DCR_CLANG_REVISION="{lock["pdfium"]["clangVersion"]}"' in argv, "clang_revision_mismatch")
    link_argv = link_command(compile_argv, obj, archive, executable, arch, sdk, lock["toolchain"]["deploymentTarget"])
    inputs = {"archiveSha256": build["sha256"], "engineSha256": PATCHED_SHA256, "headerSha256": acquire.sha256(source / "core/fpdfapi/page/cpdf_psengine.h"), "testSha256": acquire.sha256(test), "lockSha256": acquire.sha256(acquire.LOCK_PATH), "compileCommandSha256": hashlib.sha256(json.dumps(compile_argv).encode()).hexdigest(), "linkCommandSha256": hashlib.sha256(json.dumps(link_argv).encode()).hexdigest()}
    result_path = acquire.safe_path(work, "pdfium-roll.json")
    if result_path.exists():
        previous = json.loads(result_path.read_text())
        acquire.require(previous["inputs"] == inputs, "roll_evidence_inputs_changed")
        for name, path in (("objectSha256", obj), ("executableSha256", executable)):
            if name in previous:
                acquire.check_hash(path, previous[name])
    result = {"arch": arch, "scope": "numeric_stack_regression_only", "inputs": inputs, "compile": "not_run", "link": "not_run", "execution": "not_run"}
    phase = "compile"
    try:
        acquire.run(compile_argv, cwd=output, env=env, offline=True)
        result.update(compile="pass", objectSha256=acquire.sha256(obj))
        phase = "link"
        acquire.run(link_argv, cwd=output, env=env, offline=True)
        result.update(link="pass", executableSha256=acquire.sha256(executable))
        phase = "execution"
        acquire.check_hash(archive, inputs["archiveSha256"])
        acquire.check_hash(source / ENGINE, inputs["engineSha256"])
        acquire.check_hash(source / "core/fpdfapi/page/cpdf_psengine.h", inputs["headerSha256"])
        acquire.check_hash(test, inputs["testSha256"])
        native_execution(arch)
        acquire.require(acquire.run([executable], cwd=directory, env=env, offline=True) == "pdfium-roll: pass", "roll_output_mismatch")
        result["execution"] = "native_pass"
        result["verdict"] = "pass"
    except (acquire.Failure, OSError) as error:
        result[phase] = "failed"
        result.update(verdict="blocked", reason=str(error) if isinstance(error, acquire.Failure) else "roll_io_failed")
        save_result(result_path, result)
        raise acquire.Failure(result["reason"]) from None
    save_result(result_path, result)
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--arch", required=True, choices=("arm64",))
    args = parser.parse_args(argv)
    try:
        result = verify(args.arch)
    except acquire.Failure as error:
        result = {"arch": args.arch, "verdict": "blocked", "reason": str(error)}
    except (OSError, ValueError, KeyError, TypeError, IndexError):
        result = {"arch": args.arch, "verdict": "blocked", "reason": "roll_verification_failed"}
    print(json.dumps(result, sort_keys=True))
    return 2 if result["verdict"] == "blocked" else 0


if __name__ == "__main__":
    raise SystemExit(main())
