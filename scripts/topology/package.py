#!/usr/bin/env python3
"""Assemble and locally sign the pinned topology; never submit or upload artifacts."""

import argparse
import base64
import csv
import email.parser
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import posixpath
import re
import shutil
import stat
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
TEAM = "397452Z366"
IDENTITY = "io.github.jinzer0.PaperLens"
SANDBOX = "com.apple.security.app-sandbox"
INHERIT = "com.apple.security.inherit"
NETWORK = "com.apple.security.network.client"
CHILD_RIGHTS = {SANDBOX: True, INHERIT: True}
ARCHES = ("arm64", "x86_64")
MAGICS = {b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca", b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca"}
SHA256 = re.compile(r"[0-9a-f]{64}")
SAFE_COMPONENT = re.compile(r"[A-Za-z0-9._+@ -]{1,255}")
PINS = {
    "openai-codex": "0.160.0", "openai-codex-cli-bin": "0.160.0",
    "annotated-types": "0.8.0", "packaging": "26.3", "pydantic": "2.13.5",
    "pydantic-core": "2.46.5", "typing-extensions": "4.16.0", "typing-inspection": "0.4.4",
}
BUNDLES = (
    ("", IDENTITY, "PaperLens", {SANDBOX: True, NETWORK: True}, "PaperLensApp/App/PaperLens.entitlements"),
    ("Contents/XPCServices/PDFiumXPC.xpc", IDENTITY + ".PDFiumXPC", "PDFiumXPC", {SANDBOX: True}, "PDFiumXPC/PDFiumXPC.entitlements"),
    ("Contents/XPCServices/ProviderAgent.xpc", IDENTITY + ".ProviderAgent", "ProviderAgent", {SANDBOX: True, NETWORK: True}, "ProviderAgent/ProviderAgent.entitlements"),
)


class Failure(Exception):
    """Only fixed, non-sensitive reason codes may cross the CLI boundary."""


def require(condition, reason):
    if not condition:
        raise Failure(reason)


def digest(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def json_hash(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()).hexdigest()


def command(arguments, *, cwd=None):
    env = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C"}
    # security/codesign need the login keychain context, never export key material.
    if "HOME" in os.environ:
        env["HOME"] = os.environ["HOME"]
    process = subprocess.run([str(item) for item in arguments], cwd=cwd, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=180)
    require(process.returncode == 0, "local_tool_failed")
    return process.stdout, process.stderr


def safe_relative(value):
    require(isinstance(value, str) and value and "\\" not in value, "unsafe_inventory_path")
    path = PurePosixPath(value)
    require(not path.is_absolute() and all(part not in (".", "..") and SAFE_COMPONENT.fullmatch(part) for part in path.parts), "unsafe_inventory_path")
    require(path.as_posix() == value, "unsafe_inventory_path")
    return path


def check_tree(root):
    root = Path(root)
    require(root.is_dir() and not root.is_symlink(), "missing_tree")
    resolved = root.resolve()
    for path in root.rglob("*"):
        safe_relative(path.relative_to(root).as_posix())
        mode = path.lstat().st_mode
        require(not mode & (stat.S_ISUID | stat.S_ISGID), "privileged_file")
        if path.is_symlink():
            require(not os.path.isabs(os.readlink(path)), "absolute_symlink")
            require(path.resolve(strict=True).is_relative_to(resolved), "escaping_symlink")
        else:
            require(stat.S_ISDIR(mode) or stat.S_ISREG(mode), "special_file")


def tree_inventory(root):
    check_tree(root)
    result = []
    for path in sorted(Path(root).rglob("*")):
        relative = path.relative_to(root).as_posix()
        if path.is_symlink():
            result.append({"path": relative, "link": os.readlink(path)})
        elif path.is_file():
            result.append({"path": relative, "sha256": digest(path), "mode": stat.S_IMODE(path.stat().st_mode)})
    return result


def macho(path):
    if not path.is_file() or path.is_symlink():
        return False
    with path.open("rb") as stream:
        return stream.read(4) in MAGICS


def required_file(root, relative):
    path = root / safe_relative(relative)
    require(path.is_file() and path.resolve().is_relative_to(root.resolve()), "required_file_missing")
    return path


def validate_bundles(app):
    check_tree(app)
    for relative, identifier, executable, _, _ in BUNDLES:
        bundle = app / relative
        info = plistlib.loads(required_file(bundle, "Contents/Info.plist").read_bytes())
        require(info.get("CFBundleIdentifier") == identifier and info.get("CFBundleExecutable") == executable, "bundle_identity_mismatch")
        require(info.get("CFBundlePackageType") == ("APPL" if not relative else "XPC!"), "bundle_type_mismatch")
        binary = required_file(bundle, "Contents/MacOS/" + executable)
        require(macho(binary) and os.access(binary, os.X_OK), "bundle_executable_missing")
        required_file(bundle, "Contents/Resources/contract.json")
        required_file(bundle, "Contents/Resources/fixture-map.json")
    services = app / "Contents/XPCServices"
    require({path.name for path in services.iterdir()} == {"PDFiumXPC.xpc", "ProviderAgent.xpc"}, "unexpected_xpc_service")


def normalize_name(value):
    return re.sub(r"[-_.]+", "-", value).lower()


def validate_runtime(runtime):
    check_tree(runtime)
    interpreter = required_file(runtime, "bin/python3.13")
    require(macho(interpreter) and os.access(interpreter, os.X_OK), "python_executable_missing")
    library = required_file(runtime, "lib/libpython3.13.dylib")
    require(macho(library.resolve()), "python_library_missing")
    required_file(runtime, "lib/python3.13/os.py")
    required_file(runtime, "lib/python3.13/encodings/__init__.py")
    required_file(runtime, "include/python3.13/patchlevel.h")
    header = (runtime / "include/python3.13/patchlevel.h").read_text()
    require(re.search(r'^#define\s+PY_VERSION\s+"3\.13\.16"\s*$', header, re.MULTILINE), "python_version_mismatch")
    require(any(macho(path) for path in (runtime / "lib/python3.13/lib-dynload").glob("*.so")), "python_extensions_missing")
    site = runtime / "lib/python3.13/site-packages"
    distributions = {}
    cli_info = None
    for metadata in site.glob("*.dist-info/METADATA"):
        message = email.parser.Parser().parsestr(metadata.read_text())
        name = normalize_name(message.get("Name", ""))
        require(name and name not in distributions, "duplicate_distribution")
        distributions[name] = message.get("Version")
        required_file(runtime, (metadata.parent / "WHEEL").relative_to(runtime).as_posix())
        required_file(runtime, (metadata.parent / "RECORD").relative_to(runtime).as_posix())
        if name == "openai-codex-cli-bin":
            cli_info = metadata.parent
    require(distributions == PINS, "runtime_distribution_mismatch")
    require(cli_info is not None, "cli_distribution_missing")
    candidates = []
    with (cli_info / "RECORD").open(newline="") as stream:
        for row in csv.reader(stream):
            require(len(row) == 3, "invalid_cli_record")
            relative, recorded_hash, size = row
            # Only the pinned CLI distribution's payload is eligible, never PATH.
            if PurePosixPath(relative).name != "codex":
                continue
            safe_relative(relative)
            candidate = required_file(site, relative)
            require(macho(candidate) and os.access(candidate, os.X_OK), "cli_executable_missing")
            encoded = base64.urlsafe_b64encode(bytes.fromhex(digest(candidate))).rstrip(b"=").decode()
            require(recorded_hash == "sha256=" + encoded and size == str(candidate.stat().st_size), "cli_record_hash_mismatch")
            candidates.append(candidate)
    require(len(candidates) == 1, "cli_executable_ambiguous")
    return candidates[0].relative_to(runtime)


def validate_receipts(work, root, arch):
    lock_path = root / "scripts/topology/dependencies.json"
    lock_hash = digest(lock_path)
    lock = json.loads(lock_path.read_text())
    require(lock["team"] == TEAM and lock["python"]["version"] == "3.13.16" and lock["python"]["release"] == "20261003", "dependency_pin_mismatch")
    require({item["project"]: item["version"] for item in lock["wheels"]} == PINS, "wheel_pin_mismatch")
    acquisition = json.loads(required_file(work, "acquisition.json").read_text())
    runtime_receipt = json.loads(required_file(work, "runtime.json").read_text())
    for receipt in (acquisition, runtime_receipt):
        require(receipt["arch"] == arch and receipt["lockHash"] == lock_hash, "receipt_pin_mismatch")
    require(runtime_receipt["files"] == tree_inventory(work / "runtime"), "runtime_integrity_mismatch")
    expected_assets = [("python", lock["python"][arch])]
    expected_assets.extend(("wheel", item.get("any", item.get(arch))) for item in lock["wheels"])
    expected_assets.append(("source", lock["sdkSource"]))
    observed = [(item["kind"], item["filename"], item["sha256"]) for item in acquisition["assets"]]
    require(observed == [(kind, item["filename"], item["sha256"]) for kind, item in expected_assets], "acquisition_asset_mismatch")
    return lock_hash, digest(work / "acquisition.json")


def install_runtime(app, runtime, cli_relative, root):
    agent = app / "Contents/XPCServices/ProviderAgent.xpc/Contents"
    framework = agent / "Frameworks/PythonRuntime.framework"
    require(not framework.exists(), "runtime_already_embedded")
    version = framework / "Versions/3.13"
    version.parent.mkdir(parents=True)
    shutil.copytree(runtime, version, symlinks=True)
    resources = version / "Resources"
    require(not resources.exists(), "framework_resource_collision")
    resources.mkdir()
    info = {"CFBundleIdentifier": IDENTITY + ".ProviderAgent.PythonRuntime", "CFBundleExecutable": "PythonRuntime", "CFBundleName": "PythonRuntime", "CFBundlePackageType": "FMWK", "CFBundleVersion": "3.13.16", "CFBundleShortVersionString": "3.13.16", "LSMinimumSystemVersion": "15.0"}
    (resources / "Info.plist").write_bytes(plistlib.dumps(info, sort_keys=True))
    (version / "PythonRuntime").symlink_to("lib/libpython3.13.dylib")
    (framework / "Versions/Current").symlink_to("3.13")
    (framework / "PythonRuntime").symlink_to("Versions/Current/PythonRuntime")
    (framework / "Resources").symlink_to("Versions/Current/Resources")
    python_link = agent / "MacOS/python3"
    require(not python_link.exists() and not python_link.is_symlink(), "python_destination_exists")
    python_link.symlink_to("../Frameworks/PythonRuntime.framework/Versions/3.13/bin/python3.13")
    cli_source = version / cli_relative
    cli_destination = agent / "MacOS/codex"
    require(not cli_destination.exists() and not cli_destination.is_symlink(), "cli_destination_exists")
    cli_source.rename(cli_destination)
    cli_source.symlink_to(os.path.relpath(cli_destination, cli_source.parent))
    for source, name in ((root / "ProviderAgent/agent.py", "agent.py"), (root / "Contracts/ProviderRPC/provider_rpc.py", "provider_rpc.py"), (root / "Contracts/ProviderRPC/contract.json", "contract.json")):
        require(source.is_file() and not source.is_symlink(), "agent_resource_missing")
        target = agent / "Resources" / name
        require(not target.is_symlink(), "resource_symlink_collision")
        shutil.copy2(source, target)
    check_tree(app)
    return framework


def allowed_load_name(name):
    if not isinstance(name, str) or not name or any(ord(char) < 32 for char in name):
        return False
    if name.startswith(("/usr/lib/", "/System/Library/")):
        return ".." not in PurePosixPath(name).parts
    if name in ("@loader_path", "@executable_path"):
        return True
    if name.startswith("@rpath/"):
        return ".." not in PurePosixPath(name).parts
    return name.startswith(("@loader_path/", "@executable_path/"))


def check_relative_load(name, path, kind, app):
    if app is None or name.startswith(("/usr/lib/", "/System/Library/", "@rpath/")):
        return
    if name.startswith("@loader_path"):
        base, suffix = path.parent, name[len("@loader_path"):].lstrip("/")
    else:
        require(name.startswith("@executable_path"), "external_load_dependency")
        base = path.parent if kind == "executable" else app / "Contents/XPCServices/ProviderAgent.xpc/Contents/Frameworks/PythonRuntime.framework/Versions/3.13/bin"
        suffix = name[len("@executable_path"):].lstrip("/")
    require((base / suffix).resolve().is_relative_to(app.resolve()), "escaping_relative_load")


def inspect_macho(path, arch, app=None):
    output, _ = command(["/usr/bin/lipo", "-archs", path])
    require(output.decode().strip().split() == [arch], "binary_architecture_mismatch")
    output, _ = command(["/usr/bin/otool", "-hv", path])
    types = set(re.findall(r"\b(EXECUTE|DYLIB|BUNDLE)\b", output.decode()))
    require(len(types) == 1, "unsupported_macho_type")
    kind = "executable" if types == {"EXECUTE"} else "library"
    output, _ = command(["/usr/bin/otool", "-L", path])
    lines = output.decode().splitlines()
    require(len(lines) > 1, "missing_load_commands")
    for line in lines[1:]:
        name = line.strip().split(" (compatibility version", 1)[0]
        require(allowed_load_name(name), "external_load_dependency")
        check_relative_load(name, path, kind, app)
    output, _ = command(["/usr/bin/otool", "-l", path])
    commands = re.split(r"\nLoad command \d+\n", output.decode())
    for load in commands:
        if re.search(r"^\s*cmd LC_RPATH\s*$", load, re.MULTILINE):
            match = re.search(r"^\s*path (.+) \(offset \d+\)\s*$", load, re.MULTILINE)
            require(match and allowed_load_name(match.group(1)), "external_rpath")
            check_relative_load(match.group(1), path, kind, app)
    return kind


def signing_identity():
    output, _ = command(["/usr/bin/security", "find-identity", "-v", "-p", "codesigning"])
    matches = re.findall(r'^\s*\d+\) ([0-9A-Fa-f]{40}) "Developer ID Application: [^"\n]+ \(' + TEAM + r'\)"\s*$', output.decode(), re.MULTILINE)
    require(len(matches) == 1, "unique_developer_id_required")
    return matches[0]


def code_policy(relative, kind):
    for bundle, identifier, executable, rights, _ in BUNDLES:
        path = "/".join(part for part in (bundle, "Contents/MacOS/" + executable) if part)
        if relative == path:
            require(kind == "executable", "bundle_not_executable")
            return identifier, rights
    prefix = "Contents/XPCServices/ProviderAgent.xpc/Contents/"
    require(relative.startswith(prefix), "unexpected_nested_code")
    tail = relative[len(prefix):]
    if tail == "MacOS/codex":
        require(kind == "executable", "cli_not_executable")
        return IDENTITY + ".ProviderAgent.Codex", CHILD_RIGHTS
    if tail == "Frameworks/PythonRuntime.framework/Versions/3.13/bin/python3.13":
        require(kind == "executable", "python_not_executable")
        return IDENTITY + ".ProviderAgent.Python", CHILD_RIGHTS
    require(tail.startswith("Frameworks/PythonRuntime.framework/Versions/3.13/"), "unexpected_nested_code")
    suffix = hashlib.sha256(relative.encode()).hexdigest()[:24]
    return IDENTITY + ".ProviderAgent." + ("Child." if kind == "executable" else "Library.") + suffix, CHILD_RIGHTS if kind == "executable" else {}


def sign(path, identity, identifier, entitlements, scratch):
    arguments = ["/usr/bin/codesign", "--force", "--sign", identity, "--identifier", identifier, "--options", "runtime", "--timestamp=none", "--generate-entitlement-der"]
    if entitlements:
        entitlement_file = scratch / (hashlib.sha256(identifier.encode()).hexdigest() + ".plist")
        entitlement_file.write_bytes(plistlib.dumps(entitlements, sort_keys=True))
        arguments.extend(["--entitlements", entitlement_file])
    arguments.append(path)
    command(arguments)
    command(["/usr/bin/codesign", "--verify", "--strict", path])


def verify_signature(path, identifier, rights):
    command(["/usr/bin/codesign", "--verify", "--strict", path])
    out, err = command(["/usr/bin/codesign", "-d", "--verbose=4", path])
    text = (out + err).decode()
    require(re.search(r"^Identifier=" + re.escape(identifier) + r"$", text, re.MULTILINE), "signed_identifier_mismatch")
    require(re.search(r"^TeamIdentifier=" + TEAM + r"$", text, re.MULTILINE), "signed_team_mismatch")
    require("Authority=Developer ID Application:" in text and re.search(r"flags=0x[0-9a-fA-F]+\([^\n]*runtime", text), "hardened_developer_id_required")
    output, _ = command(["/usr/bin/codesign", "-d", "--entitlements", ":-", path])
    actual = plistlib.loads(output) if output.strip() else {}
    require(actual == rights, "signed_entitlements_mismatch")


def source_provenance(root):
    out, _ = command(["/usr/bin/git", "rev-parse", "HEAD"], cwd=root)
    base = out.decode().strip()
    require(re.fullmatch(r"[0-9a-f]{40}", base), "source_commit_missing")
    out, _ = command(["/usr/bin/git", "status", "--porcelain", "-z", "--untracked-files=all"], cwd=root)
    dirty = bool(out)
    sources = []
    for directory in ("PaperLens.xcodeproj", "PaperLensApp", "PDFiumXPC", "ProviderAgent", "Contracts", "Tests/Topology", "scripts/topology"):
        tree = root / directory
        require(tree.is_dir(), "source_tree_missing")
        for path in sorted(tree.rglob("*")):
            if "__pycache__" in path.parts:
                continue
            require(not path.is_symlink(), "source_symlink")
            if path.is_file():
                sources.append({"path": path.relative_to(root).as_posix(), "sha256": digest(path)})
    sources.append({"path": "Package.swift", "sha256": digest(root / "Package.swift")})
    return {"sourceBaseCommit": base, "sourceDirty": dirty, "sourceTreeHash": json_hash(sorted(sources, key=lambda item: item["path"]))}


def safe_manifest(manifest):
    require(manifest["schemaRevision"] == "topology-v1" and manifest["arch"] in ARCHES and manifest["team"] == TEAM, "manifest_schema_mismatch")
    require(re.fullmatch(r"[0-9a-f]{40}", manifest["sourceBaseCommit"]) and type(manifest["sourceDirty"]) is bool, "manifest_source_mismatch")
    for key in ("sourceTreeHash", "artifactHash", "acquisitionHash", "dependencyLockHash"):
        require(SHA256.fullmatch(manifest[key]), "manifest_hash_mismatch")
    seen = set()
    for entry in manifest["files"]:
        safe_relative(entry["path"])
        require(entry["path"] not in seen, "manifest_duplicate_path")
        seen.add(entry["path"])
        require(entry["kind"] in ("file", "symlink", "executable", "library"), "manifest_kind_mismatch")
        for key in ("sourceSHA256", "signedSHA256"):
            require(entry[key] is None or SHA256.fullmatch(entry[key]), "manifest_hash_mismatch")
        if entry["kind"] == "symlink":
            require("link" in entry and entry["sourceSHA256"] is None and entry["signedSHA256"] is None and "mode" not in entry, "manifest_link_mismatch")
            require(not os.path.isabs(entry["link"]) and not any(ord(char) < 32 for char in entry["link"]), "unsafe_manifest_link")
            safe_relative(posixpath.normpath(posixpath.join(posixpath.dirname(entry["path"]), entry["link"])))
        else:
            require("link" not in entry and SHA256.fullmatch(entry["signedSHA256"]), "manifest_file_mismatch")
            require(type(entry.get("mode")) is int and 0 <= entry["mode"] <= 0o777, "manifest_mode_mismatch")
        if entry["kind"] in ("library", "executable"):
            require("identifier" in entry and "entitlements" in entry, "manifest_code_mismatch")
        if "identifier" in entry:
            require(re.fullmatch(r"io\.github\.jinzer0\.PaperLens(?:\.[A-Za-z0-9_-]+)*", entry["identifier"]), "unsafe_manifest_identity")
            require(entry["entitlements"] in ({}, CHILD_RIGHTS, {SANDBOX: True}, {SANDBOX: True, NETWORK: True}), "unsafe_manifest_entitlements")
    # Explicit schema prevents accidentally serializing stdout, paths, or secrets.
    allowed = {"schemaRevision", "arch", "team", "sourceBaseCommit", "sourceDirty", "sourceTreeHash", "artifactHash", "acquisitionHash", "dependencyLockHash", "files", "notarization", "storyDone"}
    require(set(manifest) == allowed and manifest["notarization"] == "not_performed" and manifest["storyDone"] is False, "unsafe_manifest_fields")
    for entry in manifest["files"]:
        require(set(entry) <= {"path", "kind", "sourceSHA256", "signedSHA256", "link", "mode", "identifier", "entitlements"}, "unsafe_manifest_fields")
    return manifest


def package(root, arch, products):
    require(sys.platform == "darwin" and arch in ARCHES, "macos_arch_required")
    root = root.resolve()
    work = root / ".build/topology" / arch
    require(work.is_dir() and work.resolve().is_relative_to(root), "work_directory_missing")
    destination = work / "PaperLens.app"
    manifest_path = work / "manifest.json"
    require(not destination.exists() and not destination.is_symlink() and not manifest_path.exists() and not manifest_path.is_symlink(), "output_already_exists")
    source = products / "PaperLens.app"
    validate_bundles(source)
    for relative, _, _, _, _ in BUNDLES:
        for name, source_path in (("contract.json", "Contracts/ProviderRPC/contract.json"), ("fixture-map.json", "Tests/Topology/fixture-map.json")):
            require(digest(source / relative / "Contents/Resources" / name) == digest(root / source_path), "built_resource_mismatch")
    lock_hash, acquisition_hash = validate_receipts(work, root, arch)
    runtime = work / "runtime/python"
    cli_relative = validate_runtime(runtime)
    provenance = source_provenance(root)
    identity = signing_identity()
    # Never delete or replace caller-owned output. Failed staging is retained for inspection.
    stage = Path(tempfile.mkdtemp(prefix="package-", dir=work))
    app = stage / "PaperLens.app"
    shutil.copytree(source, app, symlinks=True)
    framework = install_runtime(app, runtime, cli_relative, root)
    before = {entry["path"]: entry for entry in tree_inventory(app)}
    policies = {}
    for path in sorted(app.rglob("*")):
        if macho(path):
            relative = path.relative_to(app).as_posix()
            kind = inspect_macho(path, arch, app)
            identifier, rights = code_policy(relative, kind)
            policies[relative] = (kind, identifier, rights)
    primary = (framework / "PythonRuntime").resolve()
    primary_relative = primary.relative_to(app).as_posix()
    require(primary_relative in policies and policies[primary_relative][0] == "library", "framework_executable_missing")
    policies[primary_relative] = ("library", IDENTITY + ".ProviderAgent.PythonRuntime", {})
    bundle_executables = {("/".join(part for part in (relative, "Contents/MacOS/" + executable) if part)) for relative, _, executable, _, _ in BUNDLES}
    scratch = stage / "signing"
    scratch.mkdir()
    for relative in sorted(policies, key=lambda value: (-value.count("/"), value)):
        if relative in bundle_executables:
            continue
        _, identifier, rights = policies[relative]
        sign(app / relative, identity, identifier, rights, scratch)
    sign(framework, identity, IDENTITY + ".ProviderAgent.PythonRuntime", {}, scratch)
    for relative, identifier, _, rights, entitlement_source in reversed(BUNDLES):
        actual_rights = plistlib.loads((root / entitlement_source).read_bytes())
        require(actual_rights == rights, "source_entitlements_mismatch")
        sign(app / relative, identity, identifier, rights, scratch)
    check_tree(app)
    for relative, (_, identifier, rights) in policies.items():
        inspect_macho(app / relative, arch, app)
        verify_signature(app / relative, identifier, rights)
    verify_signature(framework, IDENTITY + ".ProviderAgent.PythonRuntime", {})
    for relative, identifier, _, rights, _ in BUNDLES:
        verify_signature(app / relative, identifier, rights)
    after = tree_inventory(app)
    files = []
    for entry in after:
        relative = entry["path"]
        original = before.get(relative, {})
        record = {"path": relative, "kind": "symlink" if "link" in entry else "file", "sourceSHA256": original.get("sha256"), "signedSHA256": entry.get("sha256")}
        if "link" in entry:
            record["link"] = entry["link"]
        else:
            record["mode"] = entry["mode"]
        if relative in policies:
            record["kind"], record["identifier"], record["entitlements"] = policies[relative]
        files.append(record)
    manifest = safe_manifest({"schemaRevision": "topology-v1", "arch": arch, "team": TEAM, **provenance, "artifactHash": json_hash(after), "acquisitionHash": acquisition_hash, "dependencyLockHash": lock_hash, "files": files, "notarization": "not_performed", "storyDone": False})
    staged_manifest = stage / "manifest.json"
    staged_manifest.write_text(json.dumps(manifest, indent=2, sort_keys=True, ensure_ascii=False) + "\n")
    require(not destination.exists() and not destination.is_symlink() and not manifest_path.exists() and not manifest_path.is_symlink(), "output_already_exists")
    app.rename(destination)
    staged_manifest.rename(manifest_path)
    return manifest


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--arch", required=True, choices=ARCHES)
    parser.add_argument("--products", required=True, type=Path)
    arguments = parser.parse_args(argv)
    try:
        package(ROOT, arguments.arch, arguments.products.absolute())
        print(json.dumps({"arch": arguments.arch, "verdict": "pass", "scope": "local_packaging_only", "notarization": "not_performed", "storyDone": False}))
        return 0
    except Failure as error:
        print(json.dumps({"arch": arguments.arch, "verdict": "blocked", "reason": str(error)}))
    except (OSError, ValueError, KeyError, TypeError, RuntimeError, subprocess.SubprocessError):
        print(json.dumps({"arch": arguments.arch, "verdict": "blocked", "reason": "packaging_failed"}))
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
