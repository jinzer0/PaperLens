#!/bin/bash
set -euo pipefail
if [[ "$#" != 2 || "$1" != --arch || ( "$2" != arm64 && "$2" != x86_64 ) ]]; then
  printf '%s\n' 'Usage: scripts/topology/build.sh --arch arm64|x86_64' >&2
  exit 2
fi
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)"
PYTHON="$(command -v python3)"
exec /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$HOME" LANG=C LC_ALL=C \
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault DEPOT_TOOLS_UPDATE=0 \
  "$PYTHON" -I -B - "$ROOT" "$2" <<'PY'
import importlib.util
import json
from pathlib import Path
import sys

root, arch = Path(sys.argv[1]), sys.argv[2]
spec = importlib.util.spec_from_file_location("topology_acquire", root / "scripts/topology/acquire.py")
acquire = importlib.util.module_from_spec(spec)
spec.loader.exec_module(acquire)
try:
    lock = acquire.load_lock()
    acquire.toolchain(lock)
    acquire.git(root, "merge-base", "--is-ancestor", lock["approvalCommit"], "HEAD")
    acquire.git(root, "diff", "--exit-code", lock["approvalCommit"], "--", "bmad-docs/implementation-artifacts/spec-1-1-isolated-app-topology.md")
    for stage in ("fetch", "pdfium", "runtime"):
        if acquire.main(["--arch", arch, "--stage", stage]):
            raise acquire.Failure("preparation_blocked")
    work = root / ".build/topology" / arch
    products = work / "products"
    acquire.run([
        "/usr/bin/xcodebuild", "-project", root / "PaperLens.xcodeproj",
        "-scheme", "PaperLensTopology", "-configuration", "Release",
        "-destination", "platform=macOS,arch=" + arch,
        "-derivedDataPath", work / "DerivedData", "build",
        "ARCHS=" + arch, "ONLY_ACTIVE_ARCH=YES", "MACOSX_DEPLOYMENT_TARGET=15.0",
        "DEVELOPMENT_TEAM=" + lock["team"], "CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO",
        "CONFIGURATION_BUILD_DIR=" + str(products),
    ], cwd=root)
    acquire.run([sys.executable, "-I", "-B", root / "scripts/topology/package.py", "--arch", arch, "--products", products], cwd=root)
    acquire.require((work / "PaperLens.app").is_dir(), "packaged_bundle_missing")
    print(json.dumps({"arch": arch, "verdict": "pass", "scope": "local_build_only", "bundle": ".build/topology/" + arch + "/PaperLens.app", "notarization": "blocked", "actualTwoCPU": "blocked"}))
except acquire.Failure as error:
    print(json.dumps({"arch": arch, "verdict": "blocked", "reason": str(error)}))
    raise SystemExit(2)
except (OSError, ValueError, KeyError, TypeError):
    print(json.dumps({"arch": arch, "verdict": "blocked", "reason": "build_failed"}))
    raise SystemExit(2)
PY
