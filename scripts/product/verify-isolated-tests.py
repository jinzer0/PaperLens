#!/usr/bin/env python3
"""Run caller-built ProductTests XCTest cases in separate native processes.

Discover caller-built tests using SwiftPM list or its native XCTest helper;
execute only ProductTests selectors against the explicit native XCTest bundle.
"""
import argparse
import json
import math
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time

SELECTOR = re.compile(r"ProductTests\.[A-Za-z_][A-Za-z_0-9]*/test[A-Za-z_0-9]+\Z")
LIST_SELECTOR = re.compile(r"[A-Za-z_][A-Za-z_0-9]*\.[A-Za-z_][A-Za-z_0-9]*/test[A-Za-z_0-9]+\Z")
CLASS = re.compile(r"ProductTests\.[A-Za-z_][A-Za-z_0-9]*\Z")
EVENT = re.compile(r"^Test Case '(.+)' (started|passed|failed|skipped)(?:[. ]|$)", re.MULTILINE)
SUMMARY = re.compile(r"Executed (\d+) tests?, with (?:(\d+) tests? skipped and )?(\d+) failures?")
PROGRESS_SECONDS = 10.0


def parse_listing(output):
    """Validate every native selector, retaining only ProductTests cases."""
    cases = []
    seen = set()
    for selector in output.splitlines():
        if not selector:
            continue
        if not LIST_SELECTOR.fullmatch(selector):
            raise ValueError("malformed selector in Swift test list stdout")
        if selector in seen:
            raise ValueError("duplicate selector in Swift test list stdout")
        seen.add(selector)
        if SELECTOR.fullmatch(selector):
            cases.append(selector)
    if not cases:
        raise ValueError("empty ProductTests case list")
    return sorted(cases)


def discover(package_path, report):
    argv = ["swift", "test", "list", "--skip-build", "--disable-automatic-resolution"]
    report["discovery"] = {"argv": argv, "returncode": None, "stdout": "", "stderr": ""}
    print("Discovering caller-built tests (120s limit)", flush=True)
    try:
        result = subprocess.run(argv, cwd=package_path, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, text=True, check=False, timeout=120)
    except subprocess.TimeoutExpired as error:
        report["discovery"]["stdout"] = (error.stdout or b"").decode("utf-8", errors="replace") if isinstance(error.stdout, bytes) else (error.stdout or "")
        report["discovery"]["stderr"] = (error.stderr or b"").decode("utf-8", errors="replace") if isinstance(error.stderr, bytes) else (error.stderr or "")
        raise ValueError("Swift test listing timed out") from error
    report["discovery"].update(returncode=result.returncode, stdout=result.stdout, stderr=result.stderr)
    if result.returncode != 0:
        raise ValueError("Swift test listing failed; see discovery diagnostics in report")
    return parse_listing(result.stdout)


def discover_native(bundle, helper, report):
    """Load the built bundle using SwiftPM's helper without reading a package manifest."""
    if not helper.is_file():
        raise ValueError("XCTest discovery helper must be an existing executable")
    with tempfile.TemporaryDirectory(prefix="paperlens-xctest-discovery-") as directory:
        destination = Path(directory) / "tests.json"
        argv = [str(helper), str(bundle), str(destination)]
        report["discovery"] = {"argv": argv, "returncode": None}
        result = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                text=True, check=False, timeout=120)
        report["discovery"].update(returncode=result.returncode, stdout=result.stdout,
                                   stderr=result.stderr)
        if result.returncode != 0:
            raise ValueError("native XCTest discovery failed; see report")
        document = json.loads(destination.read_text(encoding="utf-8"))
        report["discovery"]["tests"] = document
        return parse_native_listing(document)


def parse_native_listing(document):
    """Accept the SwiftPM helper's suite/class/method hierarchy, rejecting empty lists."""
    if not isinstance(document, dict) or document.get("name") != "All Tests":
        raise ValueError("invalid native XCTest root suite")
    suites = document.get("tests")
    if (not isinstance(suites, list) or len(suites) != 1 or not isinstance(suites[0], dict)
            or suites[0].get("name") != "ProductTests.xctest"):
        raise ValueError("expected exactly the ProductTests XCTest suite")
    selectors = []
    classes = suites[0].get("tests")
    if not isinstance(classes, list) or not classes:
        raise ValueError("empty native XCTest classes")
    for group in classes:
        if (not isinstance(group, dict) or not isinstance(group.get("name"), str)
                or not CLASS.fullmatch(group["name"])):
            raise ValueError("invalid native XCTest class")
        methods = group.get("tests")
        if not isinstance(methods, list) or not methods:
            raise ValueError("empty native XCTest methods")
        for method in methods:
            if not isinstance(method, dict) or set(method) != {"name"} or not isinstance(method["name"], str):
                raise ValueError("invalid native XCTest method")
            selectors.append(group["name"] + "/" + method["name"])
    return parse_listing("\n".join(selectors))


def select_cases(cases, requested):
    if requested is None:
        return cases
    if not (CLASS.fullmatch(requested) or SELECTOR.fullmatch(requested)):
        raise ValueError("filter must be an exact ProductTests.Class or ProductTests.Class/testCase")
    selected = [case for case in cases if case == requested or case.split("/")[0] == requested]
    if not selected:
        raise ValueError("filter matched no discovered cases")
    return selected


def event_selector(name):
    native = re.fullmatch(r"-\[([^ ]+) ([^ ]+)\]", name)
    if native:
        return native[1] + "/" + native[2]
    class_name, separator, method = name.rpartition(".")
    return class_name + "/" + method if separator else name


def assess(selector, returncode, output, timed_out):
    events = [(event_selector(name), status) for name, status in EVENT.findall(output)]
    starts = [name for name, status in events if status == "started"]
    finishes = [(name, status) for name, status in events if status != "started"]
    summaries = SUMMARY.findall(output)
    reasons = []
    if timed_out:
        reasons.append("timeout")
    if returncode != 0:
        reasons.append("nonzero exit or crash")
    if starts != [selector] or finishes != [(selector, "passed")]:
        reasons.append("expected exactly one matching started and passed XCTest case; no skips")
    if not summaries or any(int(count) != 1 or int(skipped or 0) != 0 or int(failures) != 0
                            for count, skipped, failures in summaries):
        reasons.append("expected positive exactly-one execution summary with zero failures/skips")
    return reasons


def run_case(bundle, selector, timeout):
    if not SELECTOR.fullmatch(selector):
        raise ValueError("invalid XCTest selector")
    argv = ["xcrun", "xctest", "-XCTest", selector, str(bundle)]
    started = time.monotonic()
    timed_out = False
    with tempfile.TemporaryFile(mode="w+b") as capture:
        try:
            child = subprocess.Popen(argv, stdout=capture, stderr=subprocess.STDOUT)
        except OSError as error:
            return {"selector": selector, "passed": False, "returncode": None,
                    "timed_out": False, "duration_seconds": time.monotonic() - started,
                    "reasons": ["could not launch xctest"], "output": str(error)}
        try:
            while True:
                remaining = timeout - (time.monotonic() - started)
                if remaining <= 0:
                    timed_out = True
                    child.kill()
                    child.wait()
                    break
                try:
                    child.wait(timeout=min(PROGRESS_SECONDS, remaining))
                    break
                except subprocess.TimeoutExpired:
                    print(f"Running {selector} ({time.monotonic() - started:.0f}s)", flush=True)
        finally:
            # Reap the owned child even when interrupted or output processing fails.
            if child.poll() is None:
                child.kill()
                child.wait()
        capture.seek(0)
        output = capture.read().decode("utf-8", errors="replace")
    reasons = assess(selector, child.returncode, output, timed_out)
    return {"selector": selector, "passed": not reasons, "returncode": child.returncode,
            "timed_out": timed_out, "duration_seconds": time.monotonic() - started,
            "reasons": reasons, "output": output}


def positive_timeout(value):
    number = float(value)
    if not math.isfinite(number) or number <= 0:
        raise argparse.ArgumentTypeError("timeout must be finite and positive")
    return number


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bundle", type=Path, help="existing caller-built ProductTests.xctest directory")
    parser.add_argument("--package-path", type=Path, default=Path.cwd(),
                        help="caller-built Swift package directory (default: current directory)")
    parser.add_argument("--filter", help="exact ProductTests.Class or ProductTests.Class/testCase")
    parser.add_argument("--xctest-helper", type=Path,
                        help="discover using this SwiftPM native helper instead of loading Package.swift")
    parser.add_argument("--timeout", type=positive_timeout, default=120.0, help="seconds per case (default: 120)")
    parser.add_argument("--report", required=True, type=Path, help="JSON report output; parent directory must exist")
    args = parser.parse_args(argv)
    report = {"bundle": str(args.bundle.absolute()), "package_path": str(args.package_path.absolute()),
              "filter": args.filter, "timeout_seconds": args.timeout, "cases": [], "errors": []}
    exitcode = 2
    report_allowed = False
    try:
        # Never overwrite caller input, including paths inside the built bundle.
        report_path = args.report.resolve()
        if (report_path == (args.package_path / "Package.swift").resolve()
                or report_path == (args.package_path / "Package.resolved").resolve()
                or report_path == args.bundle.resolve() or args.bundle.resolve() in report_path.parents
                or (args.xctest_helper and report_path == args.xctest_helper.resolve())):
            raise ValueError("report must not overwrite package manifests, discovery helper or the built bundle")
        report_allowed = True
        if args.bundle.name != "ProductTests.xctest" or not args.bundle.is_dir():
            raise ValueError("bundle must be an existing ProductTests.xctest directory")
        if not args.package_path.is_dir():
            raise ValueError("package path must be an existing directory")
        discovered = (discover_native(args.bundle.absolute(), args.xctest_helper.absolute(), report)
                      if args.xctest_helper else discover(args.package_path.absolute(), report))
        cases = select_cases(discovered, args.filter)
        print(f"Discovered {len(cases)} selected XCTest cases", flush=True)
        for index, selector in enumerate(cases, 1):
            result = run_case(args.bundle.absolute(), selector, args.timeout)
            report["cases"].append(result)
            print(f"[{index}/{len(cases)}] {'PASS' if result['passed'] else 'FAIL'} {selector}", flush=True)
        exitcode = 0 if all(case["passed"] for case in report["cases"]) else 1
    except (OSError, ValueError, subprocess.TimeoutExpired) as error:
        report["errors"].append(str(error))
    report["passed"] = sum(case["passed"] for case in report["cases"])
    report["failed"] = len(report["cases"]) - report["passed"]
    report["success"] = exitcode == 0
    print(f"Summary: {report['passed']} passed, {report['failed']} failed, {len(report['errors'])} errors", flush=True)
    for case in report["cases"]:
        if not case["passed"]:
            print(f"FAIL {case['selector']}: {'; '.join(case['reasons'])}", flush=True)
    for error in report["errors"]:
        print(f"ERROR: {error}", file=sys.stderr)
    try:
        # Only write after input-path protection has succeeded.
        if not report_allowed:
            return 2
        args.report.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    except OSError as error:
        print(f"Cannot write report: {error}", file=sys.stderr)
        return 2
    return exitcode


if __name__ == "__main__":
    sys.exit(main())
