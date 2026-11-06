#!/bin/bash
set -euo pipefail
if ! { [[ "$#" == 2 && "$1" == --arch && "$2" == arm64 ]] ||
       [[ "$#" == 3 && "$1" == --unsigned-only && "$2" == --arch && "$3" == arm64 ]]; }; then
  printf '%s\n' 'Usage: scripts/topology/build.sh --arch arm64 OR --unsigned-only --arch arm64' >&2
  exit 2
fi
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)"
PYTHON="$(command -v python3)"
exec /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$HOME" LANG=C LC_ALL=C \
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault DEPOT_TOOLS_UPDATE=0 \
  "$PYTHON" -I -B - "$ROOT" "$@" <<'PY'
import importlib.util
import json
from pathlib import Path
import re
import sys
import tempfile

root = Path(sys.argv[1])
unsigned = sys.argv[2] == "--unsigned-only"
arch = sys.argv[4] if unsigned else sys.argv[3]
spec = importlib.util.spec_from_file_location("topology_acquire", root / "scripts/topology/acquire.py")
acquire = importlib.util.module_from_spec(spec)
spec.loader.exec_module(acquire)


def frozen(text):
    opening = re.findall(r'<frozen-after-approval(?:\s[^<>]*)?>', text)
    acquire.require(len(opening) == 1 and text.count('<frozen-after-approval') == 1 and text.count('</frozen-after-approval>') == 1,
                    "frozen_intent_missing_or_ambiguous")
    start = text.index(opening[0])
    end = text.index('</frozen-after-approval>') + len('</frozen-after-approval>')
    acquire.require(start < end - len('</frozen-after-approval>'), "frozen_intent_missing_or_ambiguous")
    return text[start:end]


def unsigned_input(lock, sdk):
    parent = Path(acquire.git(root, "rev-parse", "--path-format=absolute", "--git-common-dir")).parent
    acquire.require(root == parent and acquire.git(root, "branch", "--show-current") == "main",
                    "root_main_project_required")
    topology = acquire.safe_path(root, ".build/topology")
    work = acquire.safe_path(topology, arch)
    cache = acquire.safe_path(topology, "downloads")
    acquire.require(work.is_dir() and cache.is_dir(), "unsigned_input_missing")
    acquire.require(acquire.platform.machine() == "arm64", "native_build_host_not_proven")
    acquire.require(acquire.run(["/usr/sbin/sysctl", "-in", "sysctl.proc_translated"]) == "0",
                    "rosetta_or_unknown_host_forbidden")
    acquire.check_hash(acquire.safe_path(work, "pdfium/src/" + acquire.PDFIUM_PATCH["target"]),
                       acquire.PDFIUM_PATCH["afterSha256"])
    receipt = acquire.validate_receipt(lock, work, "arm64", arch, cache)
    acquire.require(receipt.get("schemaRevision") == "topology-v1", "acquisition_schema_mismatch")
    library = acquire.safe_path(work, "deps/libpdfium.a")
    evidence_path = acquire.safe_path(work, "pdfium-build.json")
    evidence = json.loads(evidence_path.read_text())
    alias = acquire.safe_path(work, "pdfium/out/sdk/xcode_links/MacOSX" + lock["toolchain"]["sdk"] + ".sdk",
                              allow_leaf_link=True)
    acquire.require(alias.is_symlink() and alias.resolve() == Path(sdk).resolve(), "sdk_alias_mismatch")
    arguments = dict(lock["pdfium"]["gnArgs"], target_cpu="arm64", mac_sdk_path=str(alias))
    expected = {"arch": arch, "sourceCommit": lock["pdfium"]["commit"],
                "depsBlob": lock["pdfium"]["depsBlob"], "gnArgs": arguments,
                "systemLinker": acquire.system_linker(lock),
                "sha256": acquire.sha256(library),
                "actualExecution": "not_checked"}
    acquire.require(not evidence_path.is_symlink() and evidence == expected, "pdfium_receipt_mismatch")
    args_file = acquire.safe_path(work, "pdfium/out/args.gn")
    acquire.require(args_file.read_text() == "\n".join(f"{key} = {json.dumps(value)}" for key, value in arguments.items()) + "\n",
                    "gn_args_mismatch")
    acquire.check_hash(library, expected["sha256"])
    with library.open("rb") as stream:
        acquire.require(stream.read(8) == b"!<arch>\n", "pdfium_not_static_archive")
    acquire.require(acquire.run(["/usr/bin/lipo", "-archs", library]) == arch, "pdfium_arch_mismatch")
    bindings = {name: acquire.sha256(acquire.safe_path(work, name))
                for name in ("acquisition.json", "pdfium-build.json", "pdfium/out/args.gn")}
    bindings["lockHash"] = acquire.sha256(acquire.LOCK_PATH)
    return work, cache, library, expected["sha256"], (receipt, bindings)


try:
    lock = acquire.load_lock()
    sdk = acquire.toolchain(lock)
    acquire.git(root, "merge-base", "--is-ancestor", lock["approvalCommit"], "HEAD")
    intent_path = "bmad-docs/implementation-artifacts/spec-1-1-isolated-app-topology.md"
    approved = acquire.git(root, "show", lock["approvalCommit"] + ":" + intent_path)
    with acquire.safe_path(root, intent_path).open(newline="") as stream:
        current = stream.read()
    acquire.require(frozen(current) == frozen(approved), "frozen_intent_changed")
    if unsigned:
        input_work, cache, library, digest, receipt = unsigned_input(lock, sdk)
    for stage in (() if unsigned else ("fetch", "pdfium", "runtime")):
        if acquire.main(["--arch", arch, "--stage", stage]):
            raise acquire.Failure("preparation_blocked")
        if stage == "pdfium":
            print(acquire.run([
                sys.executable, "-I", "-B", root / "scripts/topology/verify_pdfium_roll.py",
                "--arch", arch,
            ], cwd=root))
    if unsigned:
        topology = acquire.ensure_root(root / ".build/topology")
        work = Path(tempfile.mkdtemp(prefix="unsigned-" + arch + "-", dir=topology))
    else:
        work = root / ".build/topology" / arch
    products = work / "products"
    grdb_preparation = acquire.verify_grdb_preparation(root, arch)
    argv = [
        "/usr/bin/xcodebuild", "-project", root / "PaperLens.xcodeproj",
        "-scheme", "PaperLensTopology", "-configuration", "Release",
        "-destination", "platform=macOS,arch=" + arch,
        "-derivedDataPath", work / "DerivedData", "build",
        "ARCHS=" + arch, "ONLY_ACTIVE_ARCH=YES", "MACOSX_DEPLOYMENT_TARGET=15.0",
        "DEVELOPMENT_TEAM=" + lock["team"], "CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO",
        "CONFIGURATION_BUILD_DIR=" + str(products),
    ]
    if unsigned:
        argv.append("CODE_SIGNING_ALLOWED=NO")
    acquire.run(argv, cwd=root)
    acquire.require(acquire.verify_grdb_preparation(root, arch) == grdb_preparation,
                    "grdb_preparation_changed")
    if unsigned:
        acquire.require(unsigned_input(lock, sdk)[4] == receipt, "unsigned_input_changed")
        acquire.check_hash(library, digest)
        print(json.dumps({"arch": arch, "verdict": "pass", "scope": "unsigned_compile_only",
                          "products": str(products.relative_to(root))}))
        raise SystemExit(0)
    acquire.run([sys.executable, "-I", "-B", root / "scripts/topology/package.py", "--arch", arch, "--products", products], cwd=root)
    acquire.require((work / "PaperLens.app").is_dir(), "packaged_bundle_missing")
    print(json.dumps({"arch": arch, "verdict": "pass", "scope": "local_build_only", "bundle": ".build/topology/" + arch + "/PaperLens.app", "notarization": "blocked"}))
except acquire.Failure as error:
    print(json.dumps({"arch": arch, "verdict": "blocked", "reason": str(error)}))
    raise SystemExit(2)
except (OSError, ValueError, KeyError, TypeError):
    print(json.dumps({"arch": arch, "verdict": "blocked", "reason": "build_failed"}))
    raise SystemExit(2)
PY
