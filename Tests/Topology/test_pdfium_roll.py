"""Offline command/evidence regression tests; all process execution is mocked."""
import contextlib
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

SCRIPTS = Path(__file__).resolve().parents[2] / "scripts/topology"
sys.path.insert(0, str(SCRIPTS))
import acquire
import verify_pdfium_roll as roll


class CommandTests(unittest.TestCase):
    def setUp(self):
        self.source = Path("/fixture/pdfium/src")
        self.output = Path("/fixture/pdfium/out")
        self.compiler = "../src/third_party/llvm-build/Release+Asserts/bin/clang++"
        self.argv = [self.compiler, "-MMD", "-MF", "engine.o.d", "-DNDEBUG", "-I../src", "-std=c++20", "-fno-rtti", "-fno-exceptions", "--target=arm64-apple-macos", "-isysroot", "sdk/xcode_links/MacOSX27.0.sdk", "-mmacos-version-min=15.0", "-c", "../src/" + roll.ENGINE, "-o", "engine.o"]

    def transform(self, argv):
        return roll.transform_command(argv, self.source, self.output, Path("/fixture/Test.cpp"), Path("/fixture/Test.o"))

    def test_preserves_all_flags_except_original_io_and_dependency_outputs(self):
        command = self.transform(self.argv)
        self.assertEqual(command[1:-4], self.argv[4:-4])
        self.assertEqual(command[-4:], ["-c", "/fixture/Test.cpp", "-o", "/fixture/Test.o"])
        self.assertEqual(command[0], str(self.source / "third_party/llvm-build/Release+Asserts/bin/clang++"))
        self.assertNotIn("-MF", command)
        self.assertNotIn("engine.o", command)
        self.assertNotIn("-MMD", command)

    def test_safely_tokenizes_quoted_paths(self):
        import shlex
        argv = [*self.argv[:5], "-Ipath with spaces", *self.argv[5:]]
        entry = {"directory": str(self.output), "file": "../src/" + roll.ENGINE, "command": shlex.join(argv)}
        self.assertEqual(roll.select_command([entry], self.source, self.output), argv)

    def test_selects_engine_only_and_rejects_duplicates(self):
        entry = {"directory": str(self.output), "file": "../src/" + roll.ENGINE, "arguments": self.argv}
        unrelated = dict(entry, file="../src/other.cpp")
        self.assertEqual(roll.select_command([unrelated, entry], self.source, self.output), self.argv)
        for database in ([unrelated], [entry, entry]):
            with self.assertRaisesRegex(acquire.Failure, "engine_command_not_unique"):
                roll.select_command(database, self.source, self.output)
        with self.assertRaisesRegex(acquire.Failure, "compdb_directory_mismatch"):
            roll.select_command([dict(entry, directory=str(self.source), file=roll.ENGINE)], self.source, self.output)

    def test_rejects_unexpected_compiler_input_and_response_files(self):
        for argv in (["/usr/bin/clang++", *self.argv[1:]], [*self.argv, "other.cpp"], [*self.argv, "@flags.rsp"], [*self.argv[:-4], "other.cpp", *self.argv[-3:]], [*self.argv, "&&", "echo"]):
            with self.subTest(argv=argv):
                with self.assertRaises(acquire.Failure):
                    self.transform(argv)

    def test_link_reuses_abi_flags_and_real_archive(self):
        command = roll.link_command(self.transform(self.argv), Path("/fixture/Test.o"), Path("/fixture/deps/libpdfium.a"), Path("/fixture/Test"), "arm64", "sdk/xcode_links/MacOSX27.0.sdk", "15.0")
        self.assertIn("--target=arm64-apple-macos", command)
        self.assertIn("-mmacos-version-min=15.0", command)
        self.assertIn("/fixture/deps/libpdfium.a", command)
        self.assertIn("Security", command)
        self.assertNotIn("-DNDEBUG", command)
        self.assertEqual(command[-2:], ["-o", "/fixture/Test"])
        for arch, sdk, deployment in (("x86_64", "sdk/xcode_links/MacOSX27.0.sdk", "15.0"), ("arm64", "other", "15.0"), ("arm64", "sdk/xcode_links/MacOSX27.0.sdk", "14.0")):
            with self.assertRaises(acquire.Failure):
                roll.link_command(self.transform(self.argv), Path("/fixture/Test.o"), Path("/fixture/lib.a"), Path("/fixture/Test"), arch, sdk, deployment)


    def test_intel_recipe_is_rejected_even_with_matching_target(self):
        argv = [arg.replace("arm64-apple-macos", "x86_64-apple-macos") for arg in self.argv]
        with self.assertRaisesRegex(acquire.Failure, "unsupported_target_cpu"):
            roll.link_command(self.transform(argv), Path("/fixture/Test.o"), Path("/fixture/lib.a"), Path("/fixture/Test"), "x86_64", "sdk/xcode_links/MacOSX27.0.sdk", "15.0")


class EvidenceTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.work = self.root / ".build/topology/arm64"
        self.source = self.work / "pdfium/src"
        self.output = self.work / "pdfium/out"
        self.archive = self.work / "deps/libpdfium.a"
        compiler_dir = "third_party/llvm-build/Release+Asserts"
        for path, content in ((self.source / roll.ENGINE, b"patched fixture"), (self.source / "core/fpdfapi/page/cpdf_psengine.h", b"fixture header"), (self.archive, b"!<arch>\nfixture"), (self.root / "Tests/Topology/PDFiumRollTests.cpp", b"fixture test"), (self.root / "lock.json", b"fixture lock")):
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(content)
        sdk = self.root / "Xcode/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.0.sdk"
        sdk.mkdir(parents=True)
        (self.output / "sdk/xcode_links").mkdir(parents=True)
        (self.output / "sdk/xcode_links/MacOSX27.0.sdk").symlink_to(sdk)
        self.lock = {"pdfium": {"commit": "pinned", "depsBlob": "deps", "clangVersion": "pinned-clang"}, "toolchain": {"sdk": "27.0", "deploymentTarget": "15.0", "developerDir": str(self.root / "Xcode")}}
        build = {"arch": "arm64", "sourceCommit": "pinned", "depsBlob": "deps", "sha256": acquire.sha256(self.archive)}
        (self.work / "pdfium-build.json").write_text(json.dumps(build))
        (self.work / "prepared-tools.json").write_text(json.dumps({compiler_dir: {}}))
        self.argv = ["../src/" + compiler_dir + "/bin/clang++", '-DCR_CLANG_REVISION="pinned-clang"', "-DNDEBUG", "-I../src", "-std=c++20", "--target=arm64-apple-macos", "-isysroot", "sdk/xcode_links/MacOSX27.0.sdk", "-mmacos-version-min=15.0", "-c", "../src/" + roll.ENGINE, "-o", "engine.o"]
        self.database = [{"directory": str(self.output), "file": "../src/" + roll.ENGINE, "arguments": self.argv}]
        self.calls = []
        for patch in (mock.patch.object(roll, "ROOT", self.root), mock.patch.object(acquire, "LOCK_PATH", self.root / "lock.json"), mock.patch.object(acquire, "load_lock", return_value=self.lock), mock.patch.object(roll, "PATCHED_SHA256", acquire.sha256(self.source / roll.ENGINE)), mock.patch.object(acquire, "tree_inventory", return_value={}), mock.patch.object(acquire, "request", side_effect=AssertionError("network forbidden")), mock.patch.object(acquire, "run", side_effect=self.mocked_process), mock.patch.object(roll, "native_execution", return_value=True)):
            patch.start()
            self.addCleanup(patch.stop)
        self.fail = None

    def mocked_process(self, argv, **kwargs):
        argv = list(map(str, argv))
        self.calls.append(argv)
        self.assertTrue(kwargs["offline"])
        self.assertEqual(kwargs["env"], acquire.clean_env())
        if "compdb" in argv:
            return json.dumps(self.database)
        phase = "compile" if "-c" in argv else "link" if "-o" in argv else "execution"
        if phase == self.fail:
            raise acquire.Failure("subprocess_failed")
        if phase in ("compile", "link"):
            Path(argv[argv.index("-o") + 1]).write_bytes(phase.encode())
            return ""
        return "pdfium-roll: pass"

    def test_native_build_records_actual_execution_and_repeats(self):
        result = roll.verify("arm64")
        self.assertEqual(result["verdict"], "pass")
        self.assertEqual(result["execution"], "native_pass")
        self.assertEqual(len(self.calls), 4)
        self.assertEqual(roll.verify("arm64"), result)
        self.assertEqual(json.loads((self.work / "pdfium-roll.json").read_text()), result)

    def test_altered_archive_source_and_recorded_input_are_rejected(self):
        roll.verify("arm64")
        for path in (self.archive, self.source / roll.ENGINE, self.root / "Tests/Topology/PDFiumRollTests.cpp"):
            original = path.read_bytes()
            path.write_bytes(original + b"altered")
            with self.subTest(path=path):
                with self.assertRaises(acquire.Failure):
                    roll.verify("arm64")
            path.write_bytes(original)

    def test_compile_link_and_execution_failure_propagate(self):
        for phase in ("compile", "link", "execution"):
            with self.subTest(phase=phase):
                self.fail = phase
                with mock.patch.object(roll, "native_execution", return_value=True):
                    with self.assertRaisesRegex(acquire.Failure, "subprocess_failed"):
                        roll.verify("arm64")
                result = json.loads((self.work / "pdfium-roll.json").read_text())
                self.assertEqual(result["verdict"], "blocked")
                self.assertEqual(result[phase], "failed")
                self.assertNotEqual(result["execution"], "native_pass")

    def test_native_success_has_actual_execution_evidence(self):
        with mock.patch.object(roll, "native_execution", return_value=True):
            result = roll.verify("arm64")
        self.assertEqual(result["execution"], "native_pass")
        self.assertEqual(result["verdict"], "pass")
        self.assertEqual(len(self.calls), 4)

    def test_changed_executable_is_rejected_before_recompilation(self):
        roll.verify("arm64")
        executable = self.work / "pdfium-roll/PDFiumRollTests"
        executable.write_bytes(b"altered executable")
        count = len(self.calls)
        with self.assertRaisesRegex(acquire.Failure, "sha256_mismatch"):
            roll.verify("arm64")
        self.assertEqual(len(self.calls), count + 1)  # Compdb only, no compiler.

    def test_lost_native_proof_prevents_probe_execution(self):
        with mock.patch.object(roll, "native_execution", side_effect=[True, acquire.Failure("rosetta_forbidden")]):
            with self.assertRaisesRegex(acquire.Failure, "rosetta_forbidden"):
                roll.verify("arm64")
        self.assertEqual(len(self.calls), 3)  # Compdb, compile and link only.
        result = json.loads((self.work / "pdfium-roll.json").read_text())
        self.assertEqual(result["verdict"], "blocked")
        self.assertEqual(result["execution"], "failed")

    def test_native_cli_success_requires_execution(self):
        with contextlib.redirect_stdout(io.StringIO()) as stream:
            self.assertEqual(roll.main(["--arch", "arm64"]), 0)
        self.assertEqual(json.loads(stream.getvalue())["verdict"], "pass")
        self.assertEqual(json.loads(stream.getvalue())["execution"], "native_pass")

    def test_main_failure_is_safe_json_and_exit_two(self):
        with mock.patch.object(roll, "verify", side_effect=acquire.Failure("fixture_blocked")), contextlib.redirect_stdout(io.StringIO()) as stream:
            self.assertEqual(roll.main(["--arch", "arm64"]), 2)
        self.assertEqual(json.loads(stream.getvalue()), {"arch": "arm64", "verdict": "blocked", "reason": "fixture_blocked"})


class NativeTests(unittest.TestCase):
    def test_intel_target_never_queries_or_executes(self):
        with mock.patch.object(roll.sys, "platform", "darwin"), mock.patch.object(roll.platform, "machine", return_value="arm64"), mock.patch.object(acquire, "run") as run:
            with self.assertRaisesRegex(acquire.Failure, "unsupported_target_cpu"):
                roll.native_execution("x86_64")
            run.assert_not_called()

    def test_rosetta_is_rejected(self):
        with mock.patch.object(roll.sys, "platform", "darwin"), mock.patch.object(roll.platform, "machine", return_value="arm64"), mock.patch.object(acquire, "run", return_value="1"):
            with self.assertRaisesRegex(acquire.Failure, "rosetta_forbidden"):
                roll.native_execution("arm64")

    def test_arm64_requires_untranslated_proof_without_hardware_fallback(self):
        for translated in ("1", "", "unknown", acquire.Failure("subprocess_failed")):
            with self.subTest(translated=translated):
                failure = isinstance(translated, acquire.Failure)
                with mock.patch.object(roll.sys, "platform", "darwin"), mock.patch.object(roll.platform, "machine", return_value="arm64"), mock.patch.object(acquire, "run", return_value=translated, side_effect=translated if failure else None) as run:
                    with self.assertRaisesRegex(acquire.Failure, "native_host_not_proven" if failure else "rosetta_forbidden"):
                        roll.native_execution("arm64")
                    self.assertEqual(run.call_count, 1)
                    self.assertEqual(run.call_args.args[0], ["/usr/sbin/sysctl", "-in", "sysctl.proc_translated"])

    def test_native_arm64_queries_translation_offline(self):
        with mock.patch.object(roll.sys, "platform", "darwin"), mock.patch.object(roll.platform, "machine", return_value="arm64"), mock.patch.object(acquire, "run", return_value="0") as run:
            self.assertTrue(roll.native_execution("arm64"))
            run.assert_called_once_with(["/usr/sbin/sysctl", "-in", "sysctl.proc_translated"], env=acquire.clean_env(), offline=True)

    def test_unsupported_host_is_rejected_before_any_input_or_build_work(self):
        for host, system in (("x86_64", "darwin"), ("i386", "darwin"), ("unknown", "darwin"), ("arm64", "linux")):
            with self.subTest(host=host, system=system):
                with mock.patch.object(roll.sys, "platform", system), mock.patch.object(roll.platform, "machine", return_value=host), mock.patch.object(acquire, "run") as run, mock.patch.object(acquire, "load_lock") as load, mock.patch.object(acquire, "ensure_root") as ensure, mock.patch.object(Path, "read_text") as read, mock.patch.object(roll, "save_result") as save:
                    with self.assertRaisesRegex(acquire.Failure, "unsupported_host_cpu"):
                        roll.verify("arm64")
                    run.assert_not_called()
                    load.assert_not_called()
                    ensure.assert_not_called()
                    read.assert_not_called()
                    save.assert_not_called()

    def test_cli_intel_target_is_rejected_before_verification(self):
        with mock.patch.object(roll, "verify") as verify, contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit) as raised:
                roll.main(["--arch", "x86_64"])
            self.assertEqual(raised.exception.code, 2)
            verify.assert_not_called()

    def test_intel_target_verify_is_rejected_before_input_or_build_work(self):
        with mock.patch.object(acquire, "run") as run, mock.patch.object(acquire, "load_lock") as load, mock.patch.object(acquire, "ensure_root") as ensure:
            with self.assertRaisesRegex(acquire.Failure, "unsupported_target_cpu"):
                roll.verify("x86_64")
            run.assert_not_called()
            load.assert_not_called()
            ensure.assert_not_called()

    def test_translation_failure_is_rejected_before_input_or_build_work(self):
        with mock.patch.object(roll.sys, "platform", "darwin"), mock.patch.object(roll.platform, "machine", return_value="arm64"), mock.patch.object(acquire, "run", return_value="1") as run, mock.patch.object(acquire, "load_lock") as load, mock.patch.object(acquire, "ensure_root") as ensure, mock.patch.object(Path, "read_text") as read, mock.patch.object(roll, "save_result") as save:
            with self.assertRaisesRegex(acquire.Failure, "rosetta_forbidden"):
                roll.verify("arm64")
            self.assertEqual(run.call_count, 1)
            load.assert_not_called()
            ensure.assert_not_called()
            read.assert_not_called()
            save.assert_not_called()

    def test_cli_intel_host_returns_blocked_without_build_work(self):
        with mock.patch.object(roll.sys, "platform", "darwin"), mock.patch.object(roll.platform, "machine", return_value="x86_64"), mock.patch.object(acquire, "run") as run, mock.patch.object(acquire, "load_lock") as load, contextlib.redirect_stdout(io.StringIO()) as stream:
            self.assertEqual(roll.main(["--arch", "arm64"]), 2)
        self.assertEqual(json.loads(stream.getvalue()), {"arch": "arm64", "verdict": "blocked", "reason": "unsupported_host_cpu"})
        run.assert_not_called()
        load.assert_not_called()


if __name__ == "__main__":
    unittest.main()
