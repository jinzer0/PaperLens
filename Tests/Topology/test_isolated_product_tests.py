"""Offline fixture coverage only: subprocesses are mocked, never built or launched."""
import argparse
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("isolated_product_tests", ROOT / "scripts/product/verify-isolated-tests.py")
driver = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(driver)

CASE = "ProductTests.LocalLibraryLifecycleTests/testImport"
SECOND = "ProductTests.LocalLibraryLifecycleTests/testDelete"


def output(selector=CASE, status="passed", count=1, skipped=0, failures=0):
    class_name, method = selector.split("/")
    skip_text = f"{skipped} test skipped and " if skipped else ""
    return (f"Test Case '-[{class_name} {method}]' started.\n"
            f"Test Case '-[{class_name} {method}]' {status} (0.001 seconds).\n"
            f"Executed {count} test, with {skip_text}{failures} failures (0 unexpected) in 0.001 seconds\n")


class IsolatedProductTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="isolated-product-fixture-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.bundle = self.root / "spaces and ; shell $(tokens)" / "ProductTests.xctest"
        self.bundle.mkdir(parents=True)
        self.listing = CASE + "\n" + SECOND + "\nContractsTests.ContractTests/testContract\n"
        self.list_result = subprocess.CompletedProcess([], 0, self.listing, "fixture diagnostic\n")
        listing_patch = mock.patch.object(driver.subprocess, "run", return_value=self.list_result)
        self.list_run = listing_patch.start()
        self.addCleanup(listing_patch.stop)
        self.report = self.root / "report.json"

    def cli(self, *extra):
        return [str(self.bundle), "--package-path", str(self.root),
                "--report", str(self.report), *extra]

    def invoke(self, *extra):
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            return driver.main(self.cli(*extra))

    def fake_child(self, text, code=0):
        child = mock.Mock()
        child.returncode = code
        child.wait.return_value = code
        child.poll.return_value = code

        def launch(argv, *, stdout, stderr):
            self.assertIsInstance(argv, list)
            self.assertEqual(stderr, subprocess.STDOUT)
            stdout.write(text.encode())
            stdout.flush()
            return child
        return child, launch

    def test_native_stdout_discovery_and_exact_class_or_case_filter(self):
        report = {}
        cases = driver.discover(self.root, report)
        self.assertEqual(cases, [SECOND, CASE])
        self.list_run.assert_called_once_with(
            ["swift", "test", "list", "--skip-build", "--disable-automatic-resolution"],
            cwd=self.root, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, check=False, timeout=120)
        self.assertEqual(report["discovery"]["stdout"], self.listing)
        self.assertEqual(report["discovery"]["stderr"], "fixture diagnostic\n")
        self.assertEqual(driver.select_cases(cases, CASE), [CASE])
        self.assertEqual(driver.select_cases(cases, "ProductTests.LocalLibraryLifecycleTests"), cases)
        self.assertEqual(driver.select_cases(cases, None), cases)
        self.assertEqual(driver.select_cases(cases, [CASE, SECOND, CASE]), cases)
        self.assertEqual(driver.select_cases(cases, ["ProductTests.LocalLibraryLifecycleTests", CASE]), cases)
        for filters in [[], [CASE, "ProductTests.Missing"], [CASE, CASE + ",Other/testBad"]]:
            with self.assertRaises(ValueError):
                driver.select_cases(cases, filters)

    def test_bad_empty_duplicate_and_injected_listing(self):
        fixtures = ["", "\n", "OtherTests.Class/testOnly\n", CASE + "\n" + CASE,
                    CASE + ",Other/testCase", CASE + ";touch bad", " " + CASE,
                    CASE + "\nmalformed", CASE + "\nOtherTests.Bad/testCase,Other/testBad",
                    CASE + "\nOtherTests.Class/testCase\nOtherTests.Class/testCase"]
        for fixture in fixtures:
            with self.subTest(fixture=fixture):
                with self.assertRaises(ValueError):
                    driver.parse_listing(fixture)

    def native_listing(self, cases=(CASE, SECOND)):
        return {"name": "All Tests", "tests": [{"name": "ProductTests.xctest", "tests": [
            {"name": "ProductTests.LocalLibraryLifecycleTests", "tests": [
                {"name": case.split("/")[1]} for case in cases]}]}]}

    def test_native_helper_discovers_bundle_without_loading_package_manifest(self):
        helper = self.root / "swiftpm-xctest-helper"
        helper.touch()

        def helper_run(argv, **kwargs):
            self.assertEqual(argv[:2], [str(helper), str(self.bundle)])
            Path(argv[2]).write_text(json.dumps(self.native_listing()))
            return subprocess.CompletedProcess(argv, 0, "", "native diagnostics")

        self.list_run.side_effect = helper_run
        child, launch = self.fake_child(output())
        with mock.patch.object(driver.subprocess, "Popen", side_effect=launch):
            self.assertEqual(self.invoke("--xctest-helper", str(helper), "--filter", CASE), 0)
        discovery = json.loads(self.report.read_text())["discovery"]
        self.assertEqual(discovery["stderr"], "native diagnostics")
        self.assertEqual(discovery["tests"], self.native_listing())
        self.assertFalse(Path(self.list_run.call_args.args[0][2]).exists())

    def test_native_helper_rejects_wrong_suite_empty_duplicate_or_injected_cases(self):
        fixtures = [None, {}, {"name": "All Tests", "tests": [None]},
                    {"name": "All Tests", "tests": []},
                    {"name": "All Tests", "tests": [{"name": "OtherTests.xctest"}]},
                    self.native_listing(()), self.native_listing((CASE, CASE)),
                    self.native_listing((CASE + ",Other/testBad",))]
        for fixture in fixtures:
            with self.subTest(fixture=fixture), self.assertRaises(ValueError):
                driver.parse_native_listing(fixture)

    def test_native_helper_failure_never_executes_cases(self):
        helper = self.root / "swiftpm-xctest-helper"
        helper.touch()
        for result in [subprocess.CompletedProcess([], 1, "", "cannot load bundle"),
                       subprocess.TimeoutExpired("helper", 120)]:
            self.list_run.side_effect = result if isinstance(result, Exception) else None
            self.list_run.return_value = result
            with mock.patch.object(driver.subprocess, "Popen") as launch:
                self.assertEqual(self.invoke("--xctest-helper", str(helper)), 2)
                launch.assert_not_called()
                self.assertFalse(json.loads(self.report.read_text())["success"])

    def test_filter_injection_and_no_match_rejected_without_process(self):
        for requested in ["-XCTest All", CASE + "," + SECOND, "ProductTests.*",
                          CASE + ";touch file", CASE + "\n", "ProductTests.Missing"]:
            with self.subTest(requested=requested), mock.patch.object(driver.subprocess, "Popen") as launch:
                self.assertEqual(self.invoke("--filter", requested), 2)
                launch.assert_not_called()
                self.assertFalse(json.loads(self.report.read_text())["success"])

    def test_pass_requires_exit_zero_exact_case_and_execution_summary(self):
        self.assertEqual(driver.assess(CASE, 0, output(), False), [])
        linux = (f"Test Case 'ProductTests.LocalLibraryLifecycleTests.testImport' started.\n"
                 f"Test Case 'ProductTests.LocalLibraryLifecycleTests.testImport' passed (0.0 seconds).\n"
                 "Executed 1 test, with 0 failures (0 unexpected) in 0.0 seconds\n")
        self.assertEqual(driver.assess(CASE, 0, linux, False), [])
        # Nested XCTest suites repeat their summaries; they do not execute extra cases.
        self.assertEqual(driver.assess(CASE, 0, output() + output().splitlines()[-1] + "\n", False), [])
        fixtures = [(1, output()), (-11, output()), (0, output(status="failed", failures=1)),
                    (0, output(status="skipped", skipped=1)), (0, output(skipped=1)),
                    (0, "Executed 0 tests, with 0 failures\n"), (0, output(count=0)),
                    (0, output(count=2)), (0, output() + output(SECOND)),
                    (0, output(SECOND)), (0, ""), (0, "\n".join(output().splitlines()[:2])),
                    (0, "\n".join(output().splitlines()[1:]))]
        for code, text in fixtures:
            with self.subTest(code=code, text=text):
                self.assertTrue(driver.assess(CASE, code, text, False))
        self.assertTrue(driver.assess(CASE, 0, output(), True))

    def test_native_array_argv_and_report_success(self):
        child, launch = self.fake_child(output())
        with mock.patch.object(driver.subprocess, "Popen", side_effect=launch) as popen:
            self.assertEqual(self.invoke("--filter", CASE), 0)
        self.assertEqual(popen.call_args.args[0], ["xcrun", "xctest", "-XCTest", CASE, str(self.bundle)])
        child.wait.assert_called_once()
        report = json.loads(self.report.read_text())
        self.assertTrue(report["success"])
        self.assertEqual(report["passed"], 1)
        self.assertEqual(report["cases"][0]["output"], output())

    def test_package_default_is_current_directory_and_missing_path_denies_listing(self):
        child, launch = self.fake_child(output())
        argv = [str(self.bundle), "--report", str(self.report), "--filter", CASE]
        with mock.patch.object(driver.subprocess, "Popen", side_effect=launch), \
                contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(driver.main(argv), 0)
        self.assertEqual(self.list_run.call_args.kwargs["cwd"], Path.cwd())
        self.list_run.reset_mock()
        with mock.patch.object(driver.subprocess, "Popen") as popen:
            self.assertEqual(self.invoke("--package-path", str(self.root / "missing")), 2)
            popen.assert_not_called()
        self.list_run.assert_not_called()

    def test_fresh_process_for_every_case_and_continue_after_failure(self):
        launches = []

        def launch(argv, *, stdout, stderr):
            selector = argv[3]
            launches.append(argv)
            text = output(selector, status="failed", failures=1) if selector == SECOND else output(selector)
            stdout.write(text.encode())
            child = mock.Mock(returncode=1 if selector == SECOND else 0)
            child.poll.return_value = child.returncode
            return child

        with mock.patch.object(driver.subprocess, "Popen", side_effect=launch):
            self.assertEqual(self.invoke(), 1)
        self.assertEqual([call[3] for call in launches], [SECOND, CASE])
        report = json.loads(self.report.read_text())
        self.assertEqual((report["passed"], report["failed"]), (1, 1))
        self.assertIn("failures", report["cases"][0]["output"])
        self.assertTrue(report["cases"][0]["reasons"])
        launches.clear()
        with mock.patch.object(driver.subprocess, "Popen", side_effect=launch):
            self.assertEqual(self.invoke("--filter", CASE, "--filter", SECOND, "--filter", CASE), 1)
        self.assertEqual([call[3] for call in launches], [SECOND, CASE])

    def test_timeout_kills_and_reaps_owned_child_with_progress(self):
        child, launch = self.fake_child(output())
        child.returncode = -9
        child.poll.return_value = -9
        child.wait.side_effect = [subprocess.TimeoutExpired("xctest", 10), -9]
        # started, remaining, heartbeat, remaining, duration
        with mock.patch.object(driver.subprocess, "Popen", side_effect=launch), \
                mock.patch.object(driver.time, "monotonic", side_effect=[0, 0, 10, 12, 12]), \
                contextlib.redirect_stdout(io.StringIO()) as progress:
            result = driver.run_case(self.bundle, CASE, 12)
        child.kill.assert_called_once()
        self.assertEqual(child.wait.call_args_list, [mock.call(timeout=10), mock.call()])
        self.assertTrue(result["timed_out"])
        self.assertFalse(result["passed"])
        self.assertIn("timeout", result["reasons"])
        self.assertIn("Running", progress.getvalue())

    def test_launch_error_is_retained_as_failure(self):
        with mock.patch.object(driver.subprocess, "Popen", side_effect=OSError("fixture launch failure")):
            result = driver.run_case(self.bundle, CASE, 1)
        self.assertFalse(result["passed"])
        self.assertIsNone(result["returncode"])
        self.assertIn("fixture launch failure", result["output"])

    def test_interruption_also_kills_and_reaps(self):
        child, launch = self.fake_child("")
        child.poll.return_value = None
        child.wait.side_effect = [KeyboardInterrupt, -9]
        with mock.patch.object(driver.subprocess, "Popen", side_effect=launch):
            with self.assertRaises(KeyboardInterrupt):
                driver.run_case(self.bundle, CASE, 1)
        child.kill.assert_called_once()
        self.assertEqual(child.wait.call_count, 2)

    def test_listing_failure_invalid_output_and_missing_bundle_report_errors(self):
        for code, content in [(1, self.listing), (-9, self.listing), (0, "bad selector")]:
            self.list_result.returncode = code
            self.list_result.stdout = content
            with mock.patch.object(driver.subprocess, "Popen") as launch:
                self.assertEqual(self.invoke(), 2)
                launch.assert_not_called()
                self.assertTrue(json.loads(self.report.read_text())["errors"])
                self.assertEqual(json.loads(self.report.read_text())["discovery"]["returncode"], code)
        self.list_run.side_effect = OSError("missing swift")
        with mock.patch.object(driver.subprocess, "Popen") as launch:
            self.assertEqual(self.invoke(), 2)
            launch.assert_not_called()
        self.bundle.rmdir()
        self.list_run.reset_mock()
        self.assertEqual(self.invoke(), 2)
        self.list_run.assert_not_called()

    def test_listing_timeout_retains_diagnostics_without_case_launch(self):
        self.list_run.side_effect = subprocess.TimeoutExpired("swift", 120, output=b"partial", stderr=b"fixture")
        with mock.patch.object(driver.subprocess, "Popen") as launch:
            self.assertEqual(self.invoke(), 2)
            launch.assert_not_called()
        report = json.loads(self.report.read_text())
        self.assertEqual(report["discovery"]["stdout"], "partial")
        self.assertEqual(report["discovery"]["stderr"], "fixture")

    def test_report_cannot_overwrite_manifests_or_bundle(self):
        manifest = self.root / "Package.swift"
        manifest.write_text("synthetic manifest")
        for target in [manifest, self.root / "Package.resolved", self.bundle / "output.json", self.bundle]:
            with mock.patch.object(driver.subprocess, "Popen") as launch:
                self.assertEqual(self.invoke("--report", str(target)), 2)
                launch.assert_not_called()
        self.assertEqual(manifest.read_text(), "synthetic manifest")
        self.assertFalse((self.bundle / "output.json").exists())
        helper = self.root / "swiftpm-xctest-helper"
        helper.write_text("synthetic helper executable")
        with mock.patch.object(driver.subprocess, "Popen") as launch:
            self.assertEqual(self.invoke("--xctest-helper", str(helper), "--report", str(helper)), 2)
            launch.assert_not_called()
        self.assertEqual(helper.read_text(), "synthetic helper executable")

    def test_report_write_failure_is_not_success(self):
        child, launch = self.fake_child(output())
        with mock.patch.object(driver.subprocess, "Popen", side_effect=launch):
            self.assertEqual(self.invoke("--filter", CASE, "--report", str(self.root / "missing/report.json")), 2)

    def test_nonfinite_zero_negative_timeout_rejected(self):
        for value in ["nan", "inf", "0", "-1"]:
            with self.subTest(value=value):
                with self.assertRaises(argparse.ArgumentTypeError):
                    driver.positive_timeout(value)


if __name__ == "__main__":
    unittest.main()
