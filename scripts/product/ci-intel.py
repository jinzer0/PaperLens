#!/usr/bin/env python3
"""Transfer pinned cross-built tests to a native macOS 15 Intel runner."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import sys
import tarfile

ROOT = Path(__file__).resolve().parents[2]
PRODUCTS = ROOT / ".build/ci-intel/out/Products/Debug"
BUNDLES = ("ProductTests", "ProviderRequestTests", "ProviderRPCTests")


def command(*argv):
    return subprocess.check_output(argv, cwd=ROOT, text=True).strip()


def require(condition, message):
    if not condition:
        raise ValueError(message)


def check_binaries():
    for name in BUNDLES:
        binary = PRODUCTS / f"{name}.xctest/Contents/MacOS/{name}"
        require(command("xcrun", "lipo", "-archs", str(binary)) == "x86_64",
                f"{name}: expected only x86_64")
        build = command("xcrun", "vtool", "-show-build", str(binary))
        require(re.search(r"\bminos 15\.0\s", build), f"{name}: expected deployment target 15.0")


def stage(destination):
    pin = json.loads((ROOT / "scripts/topology/dependencies.json").read_text())["toolchain"]
    xcode = command("xcodebuild", "-version")
    swift = command("xcrun", "swift", "--version")
    sdk = command("xcrun", "--sdk", "macosx", "--show-sdk-version")
    require(xcode == f"Xcode {pin['xcode']}\nBuild version {pin['build']}", "Xcode pin mismatch")
    require(f"Swift version {pin['swift']} " in swift, "Swift pin mismatch")
    require(sdk == pin["sdk"], "SDK pin mismatch")
    check_binaries()
    destination.mkdir(parents=True, exist_ok=False)
    archive = destination / "intel-tests.tar.gz"
    # Preserve bundles and their resources, omitting object files and protected PDFReadiness trials.
    members = [PRODUCTS / f"{name}.xctest" for name in BUNDLES]
    members += sorted(PRODUCTS.glob("*.bundle")) + [PRODUCTS / "PackageFrameworks"]
    with tarfile.open(archive, "w:gz") as tar:
        for path in members:
            tar.add(path, arcname=path.name)
    metadata = {"commit": command("git", "rev-parse", "HEAD"), "workspace": str(ROOT),
                "architecture": "x86_64", "deployment_target": "15.0", "xcode": xcode,
                "swift": swift, "sdk": sdk, "sha256": hashlib.sha256(archive.read_bytes()).hexdigest()}
    (destination / "build.json").write_text(json.dumps(metadata, indent=2) + "\n")
    print(json.dumps(metadata, indent=2))


def run(source, reports, product_filter=None):
    reports.mkdir(parents=True, exist_ok=True)
    version = command("sw_vers", "-productVersion")
    machine = platform.machine()
    host = {"macos": version, "build": command("sw_vers", "-buildVersion"),
            "architecture": machine, "xcode": command("xcodebuild", "-version"),
            "commit": command("git", "rev-parse", "HEAD"),
            "scope": "native product and contract tests; not a signed packaged release"}
    (reports / "host.json").write_text(json.dumps(host, indent=2) + "\n")
    require(version.split(".")[0] == "15" and machine == "x86_64", "native macOS 15 Intel required")
    translated = subprocess.run(["sysctl", "-in", "sysctl.proc_translated"],
                                capture_output=True, text=True, check=False)
    require(translated.stdout.strip() in ("", "0"), "Rosetta execution is forbidden")
    metadata = json.loads((source / "build.json").read_text())
    require(metadata["commit"] == host["commit"] and metadata["workspace"] == str(ROOT),
            "artifact checkout identity mismatch")
    require(metadata["architecture"] == machine and metadata["deployment_target"] == "15.0",
            "artifact target mismatch")
    archive = source / "intel-tests.tar.gz"
    require(hashlib.sha256(archive.read_bytes()).hexdigest() == metadata["sha256"], "artifact hash mismatch")
    PRODUCTS.mkdir(parents=True, exist_ok=False)
    with tarfile.open(archive) as tar:
        tar.extractall(PRODUCTS, filter="data")
    check_binaries()
    developer = Path(command("xcode-select", "-p"))
    # DEVELOPER_DIR overrides xcode-select on hosted runners.
    developer = Path(os.environ.get("DEVELOPER_DIR", developer))
    toolchain = developer / "Toolchains/XcodeDefault.xctoolchain/usr"
    helper = toolchain / "libexec/swift/pm/swiftpm-xctest-helper"
    frameworks = developer / "Platforms/MacOSX.platform/Developer/Library/Frameworks"
    libraries = developer / "Platforms/MacOSX.platform/Developer/usr/lib"
    environment = dict(os.environ, DYLD_FRAMEWORK_PATH=str(frameworks),
                       DYLD_LIBRARY_PATH=f"{libraries}:{toolchain}/lib/swift-6.2/macosx",
                       PAPERLENS_FIXTURE_PYTHON=sys.executable,
                       SWIFT_TESTING_ENABLED="0")
    statuses = []
    product_argv = [sys.executable, str(ROOT / "scripts/product/verify-isolated-tests.py"),
                    str(PRODUCTS / "ProductTests.xctest"), "--xctest-helper", str(helper),
                    "--report", str(reports / "product-tests.json")]
    if product_filter:
        for selected in product_filter.splitlines():
            product_argv += ["--filter", selected]
    product = subprocess.run(product_argv,
                             cwd=ROOT, env=environment, check=False)
    statuses.append(product.returncode == 0)
    for name in BUNDLES[1:]:
        result = subprocess.run(["xcrun", "xctest", str(PRODUCTS / f"{name}.xctest")],
                                cwd=ROOT, env=environment, capture_output=True, text=True,
                                timeout=180, check=False)
        output = result.stdout + result.stderr
        (reports / f"{name}.log").write_text(output)
        counts = re.findall(r"Executed (\d+) tests?, with (?:(\d+) tests? skipped and )?(\d+) failures?", output)
        passed = (result.returncode == 0 and bool(counts)
                  and all(int(n) > 0 and int(skips or 0) == 0 and int(failures) == 0
                          for n, skips, failures in counts))
        statuses.append(passed)
        print(f"{name}: {'PASS' if passed else 'FAIL'}", flush=True)
        if not passed:
            print(output)
    require(all(statuses), "native XCTest failures; see uploaded reports")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=["stage", "run"])
    parser.add_argument("artifact", type=Path)
    parser.add_argument("--reports", type=Path, default=ROOT / ".build/ci-reports")
    parser.add_argument("--filter", default=os.environ.get("PAPERLENS_PRODUCT_FILTER") or None,
                        help="optional exact product classes/cases, one per line")
    args = parser.parse_args()
    try:
        stage(args.artifact) if args.mode == "stage" else run(args.artifact, args.reports, args.filter)
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        sys.exit(1)
