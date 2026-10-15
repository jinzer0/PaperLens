"""Offline regression tests. No network, fetched tools, signing or GUI execution."""
import base64
import contextlib
import csv
import errno
import hashlib
import io
import json
import os
from pathlib import Path
import plistlib
import stat
import subprocess
import sys
import tarfile
import tempfile
import time
import unittest
from unittest import mock
import zipfile

SCRIPTS = Path(__file__).resolve().parents[2] / "scripts/topology"
sys.path.insert(0, str(SCRIPTS))
import acquire
import verify
import diagnose_eof
import control_log_timeout as log_control
import package as packaging


class IsolatedTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.network = mock.patch.object(acquire, "request", side_effect=AssertionError("network forbidden"))
        self.network.start()
        self.addCleanup(self.network.stop)

    def archive(self, members):
        path = self.root / "input.tar"
        with tarfile.open(path, "w") as archive:
            for name, kind, content in members:
                entry = tarfile.TarInfo(name)
                entry.mode = 0o755 if kind == "dir" else 0o644
                if kind == "file":
                    entry.size = len(content)
                    archive.addfile(entry, io.BytesIO(content))
                else:
                    entry.type = {"dir": tarfile.DIRTYPE, "link": tarfile.SYMTYPE, "hard": tarfile.LNKTYPE, "fifo": tarfile.FIFOTYPE}[kind]
                    entry.linkname = content
                    archive.addfile(entry)
        return path

    def wheel(self, extras=None, *, distribution="sample", version="1.0", filename=None, executable_paths=()):
        info = f"{distribution}-{version}.dist-info"
        files = {
            "sample/__init__.py": b"VALUE = 1\n",
            info + "/WHEEL": b"Wheel-Version: 1.0\nRoot-Is-Purelib: true\nTag: py3-none-any\n",
            info + "/METADATA": f"Metadata-Version: 2.4\nName: {distribution}\nVersion: {version}\n".encode(),
            info + "/licenses/LICENSE": b"synthetic license\n",
        }
        files.update(extras or {})
        rows = []
        for name, data in files.items():
            digest = base64.urlsafe_b64encode(hashlib.sha256(data).digest()).rstrip(b"=").decode()
            rows.append([name, "sha256=" + digest, str(len(data))])
        rows.append([info + "/RECORD", "", ""])
        record = io.StringIO()
        csv.writer(record).writerows(rows)
        files[info + "/RECORD"] = record.getvalue().encode()
        path = self.root / (filename or f"{distribution}-{version}-py3-none-any.whl")
        with zipfile.ZipFile(path, "w") as wheel:
            for name, data in files.items():
                entry = zipfile.ZipInfo(name)
                entry.external_attr = (stat.S_IFREG | (0o755 if name in executable_paths else 0o644)) << 16
                wheel.writestr(entry, data)
        return path


class UnsignedBuildDriverTests(IsolatedTest):
    """Synthetic driver coverage only; never run Xcode or acquired inputs."""

    def setUp(self):
        super().setUp()
        self.lock = acquire.load_lock()
        self.project = self.root / ".build/topology/isolated-story-1-4"
        self.project.mkdir(parents=True)
        self.input_work = self.root / ".build/topology/full-acquisition-arm64-ae7a27c9-e584-40ef-a164-e9631d68d11a"
        self.cache = self.root / ".build/topology/downloads"
        self.cache.mkdir()
        self.library = self.input_work / "deps/libpdfium.a"
        self.library.parent.mkdir(parents=True)
        self.library_bytes = b"!<arch>\nsynthetic driver archive"
        self.library.write_bytes(self.library_bytes)
        self.patch_target = self.input_work / "pdfium/src" / acquire.PDFIUM_PATCH["target"]
        self.patch_target.parent.mkdir(parents=True)
        self.patch_bytes = b"synthetic approved patched source\n"
        self.patch_target.write_bytes(self.patch_bytes)
        self.sdk = self.root / "SDK"
        self.sdk.mkdir()
        alias = self.input_work / "pdfium/out/sdk/xcode_links" / ("MacOSX" + self.lock["toolchain"]["sdk"] + ".sdk")
        alias.parent.mkdir(parents=True)
        alias.symlink_to(self.sdk)
        self.arguments = dict(self.lock["pdfium"]["gnArgs"], target_cpu="arm64", mac_sdk_path=str(alias))
        self.linker = {"path": "synthetic pinned linker", "sha256": "a" * 64, "version": "synthetic"}
        self.evidence = {"arch": "arm64", "sourceCommit": self.lock["pdfium"]["commit"],
                         "depsBlob": self.lock["pdfium"]["depsBlob"], "gnArgs": self.arguments,
                         "systemLinker": self.linker,
                         "sha256": "d584abe4d10355cb242b3b0a83bc46b1327c173e009cf2f1413b69dc26374401",
                         "actualExecution": "not_checked"}
        self.evidence_path = self.input_work / "pdfium-build.json"
        self.evidence_path.write_text(json.dumps(self.evidence))
        (self.input_work / "pdfium/out/args.gn").write_text(
            "\n".join(f"{key} = {json.dumps(value)}" for key, value in self.arguments.items()) + "\n")
        (self.input_work / "acquisition.json").write_text('{"synthetic": true}\n')
        self.intent = self.project / "bmad-docs/implementation-artifacts/spec-1-1-isolated-app-topology.md"
        self.intent.parent.mkdir(parents=True)
        self.approved = '<frozen-after-approval reason="human-owned intent">\nimmutable\n</frozen-after-approval>\n'
        self.intent.write_text(self.approved + "new admitted evidence outside frozen intent\n")
        launcher = (SCRIPTS / "build.sh").read_text()
        self.driver = launcher.split("<<'PY'\n", 1)[1].rsplit("\nPY", 1)[0]
        self.commands = []
        self.git_calls = []
        self.lipo_arch = "arm64"
        self.host = "arm64"
        self.translated = "0"
        self.build_action = None
        self.hash_failure = None

    def fake_git(self, path, *argv):
        self.git_calls.append((path, argv))
        if argv[0] == "show":
            self.assertEqual(argv[1], self.lock["approvalCommit"] + ":bmad-docs/implementation-artifacts/spec-1-1-isolated-app-topology.md")
            return self.approved
        if argv[0] == "rev-parse":
            return str(self.root / ".git")
        if argv[0] == "diff":
            raise acquire.Failure("subprocess_failed")
        self.assertEqual(argv, ("merge-base", "--is-ancestor", self.lock["approvalCommit"], "HEAD"))
        return ""

    def fake_run(self, argv, **kwargs):
        self.commands.append(list(map(str, argv)))
        if str(argv[0]) == "/usr/sbin/sysctl":
            return self.translated
        if str(argv[0]) == "/usr/bin/lipo":
            return self.lipo_arch
        self.assertEqual(str(argv[0]), "/usr/bin/xcodebuild", "forbidden driver command")
        self.assertEqual(kwargs, {"cwd": self.project})
        if self.build_action:
            self.build_action()
        return "synthetic compile-only result"

    def fake_hash(self, path, expected):
        path = Path(path)
        if path == acquire.LOCK_PATH:
            self.assertEqual(expected, "32be141a78f7ef2480892023d94a9a617f77bdd475bd19611500a3dab4530fb8")
            acquire.require(self.hash_failure != "manifest", "sha256_mismatch")
        elif path == self.patch_target:
            self.assertEqual(expected, acquire.PDFIUM_PATCH["afterSha256"])
            acquire.require(not path.is_symlink() and path.read_bytes() == self.patch_bytes, "sha256_mismatch")
        else:
            self.assertEqual(expected, self.evidence["sha256"])
            acquire.require(not path.is_symlink() and path.read_bytes() == self.library_bytes, "sha256_mismatch")

    def drive(self, *, unsigned=True, validation_error=None, input_work=None):
        args = ["build.sh", str(self.project)]
        args += (["--unsigned-only", "--arch", "arm64", "--input-work", str(input_work or self.input_work),
                  "--cache", str(self.cache)] if unsigned else ["--arch", "arm64"])
        output = io.StringIO()
        with contextlib.ExitStack() as stack:
            stack.enter_context(mock.patch.object(sys, "argv", args))
            stack.enter_context(mock.patch("importlib.util.module_from_spec", return_value=acquire))
            stack.enter_context(mock.patch("importlib.util.spec_from_file_location", return_value=mock.Mock()))
            stack.enter_context(mock.patch.object(acquire, "load_lock", return_value=self.lock))
            toolchain = stack.enter_context(mock.patch.object(acquire, "toolchain", return_value=str(self.sdk)))
            stack.enter_context(mock.patch.object(acquire, "git", side_effect=self.fake_git))
            stack.enter_context(mock.patch.object(acquire, "run", side_effect=self.fake_run))
            stack.enter_context(mock.patch.object(acquire, "check_hash", side_effect=self.fake_hash))
            stack.enter_context(mock.patch.object(acquire, "system_linker", return_value=self.linker))
            stack.enter_context(mock.patch.object(acquire.platform, "machine", return_value=self.host))
            validation = stack.enter_context(mock.patch.object(acquire, "validate_receipt",
                side_effect=acquire.Failure(validation_error) if validation_error else None,
                return_value={"synthetic": True}))
            preparation = stack.enter_context(mock.patch.object(acquire, "main", side_effect=AssertionError("preparation forbidden")))
            stack.enter_context(contextlib.redirect_stdout(output))
            with self.assertRaises(SystemExit) as exit_status:
                exec(compile(self.driver, str(SCRIPTS / "build.sh"), "exec"), {})
            preparation.assert_not_called()
            toolchain.assert_called_once_with(self.lock)
        return exit_status.exception.code, json.loads(output.getvalue()), validation

    def assert_blocked(self, reason, **kwargs):
        status, result, _ = self.drive(**kwargs)
        self.assertEqual(status, 2)
        self.assertEqual(result, {"arch": "arm64", "verdict": "blocked", "reason": reason})
        self.assertFalse(any(command[0] == "/usr/bin/xcodebuild" for command in self.commands))

    def test_unsigned_argv_preserves_settings_without_preparation_or_packaging(self):
        status, result, validation = self.drive()
        self.assertEqual(status, 0)
        self.assertEqual(result["scope"], "unsigned_compile_only")
        work = self.project / ".build/topology/arm64"
        self.assertEqual(self.commands, [
            ["/usr/sbin/sysctl", "-in", "sysctl.proc_translated"],
            ["/usr/bin/lipo", "-archs", str(self.library)],
            ["/usr/bin/xcodebuild", "-project", str(self.project / "PaperLens.xcodeproj"),
             "-scheme", "PaperLensTopology", "-configuration", "Release",
             "-destination", "platform=macOS,arch=arm64", "-derivedDataPath", str(work / "DerivedData"), "build",
             "ARCHS=arm64", "ONLY_ACTIVE_ARCH=YES", "MACOSX_DEPLOYMENT_TARGET=15.0",
             "DEVELOPMENT_TEAM=" + self.lock["team"], "CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO",
             "CONFIGURATION_BUILD_DIR=" + str(work / "products"), "CODE_SIGNING_ALLOWED=NO"],
            ["/usr/sbin/sysctl", "-in", "sysctl.proc_translated"],
            ["/usr/bin/lipo", "-archs", str(self.library)]])
        self.assertEqual(validation.call_args_list, [mock.call(self.lock, self.input_work, "arm64", "arm64", self.cache)] * 2)
        self.assertEqual((work / "deps/libpdfium.a").read_bytes(), self.library_bytes)
        self.assertEqual(self.library.read_bytes(), self.library_bytes)
        self.assertFalse(any(argv[0] == "diff" for _, argv in self.git_calls))

    def test_unsigned_restored_source_rejects_before_validator_or_patch_application(self):
        restored = b"synthetic restored upstream source\n"
        self.patch_target.write_bytes(restored)
        work = self.project / ".build/topology/arm64"
        for occupied in (False, True):
            with self.subTest(occupied=occupied):
                marker = work / "foreign-marker"
                if occupied:
                    work.mkdir(parents=True)
                    marker.write_bytes(b"preserve occupied output")
                status, result, validation = self.drive()
                self.assertEqual(status, 2)
                self.assertEqual(result["reason"], "sha256_mismatch")
                validation.assert_not_called()
                self.assertEqual(self.patch_target.read_bytes(), restored)
                self.assertEqual(self.library.read_bytes(), self.library_bytes)
                self.assertFalse(any(argv[0] == "apply" for _, argv in self.git_calls))
                self.assertFalse(any(command[0] == "/usr/bin/xcodebuild" for command in self.commands))
                if occupied:
                    self.assertEqual(marker.read_bytes(), b"preserve occupied output")
                else:
                    self.assertFalse(work.exists())

    def test_unsigned_changed_missing_duplicate_or_reordered_frozen_guard_rejects(self):
        for value, reason in (
            (self.approved.replace("immutable", "changed"), "frozen_intent_changed"),
            ("missing block", "frozen_intent_missing_or_ambiguous"),
            (self.approved * 2, "frozen_intent_missing_or_ambiguous"),
            ("</frozen-after-approval>" + self.approved.split("</frozen-after-approval>")[0], "frozen_intent_missing_or_ambiguous"),
            (self.approved + "<frozen-after-approval malformed", "frozen_intent_missing_or_ambiguous")):
            with self.subTest(value=value):
                self.intent.write_text(value)
                self.assert_blocked(reason)

    def test_unsigned_approved_guard_missing_or_duplicate_rejects(self):
        for baseline in ("missing", self.approved * 2):
            with self.subTest(baseline=baseline):
                self.approved = baseline
                self.assert_blocked("frozen_intent_missing_or_ambiguous")

    def test_default_whole_file_guard_still_rejects_outside_frozen_changes(self):
        self.assert_blocked("subprocess_failed", unsigned=False)
        self.assertIn((self.project, ("diff", "--exit-code", self.lock["approvalCommit"], "--",
                                      "bmad-docs/implementation-artifacts/spec-1-1-isolated-app-topology.md")), self.git_calls)

    def test_unsigned_stale_full_receipt_and_manifest_reject_before_copy(self):
        self.assert_blocked("acquisition_pin_or_arch_mismatch", validation_error="acquisition_pin_or_arch_mismatch")
        self.assertFalse((self.project / ".build/topology/arm64").exists())
        self.hash_failure = "manifest"
        self.assert_blocked("sha256_mismatch")

    def test_unsigned_wrong_input_namespace_rejects_without_output(self):
        self.assert_blocked("unsigned_input_namespace_mismatch", input_work=self.root / "other")
        self.assertFalse((self.project / ".build/topology/arm64").exists())

    def test_unsigned_non_native_or_translated_host_rejects_without_output(self):
        self.host = "x86_64"
        self.assert_blocked("native_build_host_not_proven")
        self.host = "arm64"
        self.translated = "1"
        self.assert_blocked("rosetta_or_unknown_host_forbidden")
        self.assertFalse((self.project / ".build/topology/arm64").exists())

    def test_unsigned_missing_pdfium_receipt_rejects_without_output(self):
        self.evidence_path.unlink()
        self.assert_blocked("build_failed")
        self.assertFalse((self.project / ".build/topology/arm64").exists())

    def test_unsigned_wrong_pdfium_receipt_library_and_cpu_reject(self):
        for field, value in (("sourceCommit", "0" * 40), ("arch", "x86_64"),
                             ("sha256", "a" * 64), ("actualExecution", "pass")):
            with self.subTest(field=field):
                self.evidence_path.write_text(json.dumps(self.evidence | {field: value}))
                self.assert_blocked("pdfium_receipt_mismatch")
        self.evidence_path.write_text(json.dumps(self.evidence))
        self.library.write_bytes(b"stale library")
        self.assert_blocked("sha256_mismatch")
        self.library.write_bytes(self.library_bytes)
        self.lipo_arch = "x86_64"
        self.assert_blocked("pdfium_arch_mismatch")

    def test_unsigned_occupied_dependency_derived_data_or_products_preserved(self):
        work = self.project / ".build/topology/arm64"
        for leaf in ("deps/libpdfium.a", "DerivedData/marker", "products/marker"):
            with self.subTest(leaf=leaf):
                target = work / leaf
                target.parent.mkdir(parents=True)
                target.write_bytes(b"preserve")
                self.assert_blocked("unsigned_destination_occupied")
                self.assertEqual(target.read_bytes(), b"preserve")

    def test_unsigned_postbuild_changed_acquisition_binding_rejects(self):
        self.build_action = lambda: (self.input_work / "acquisition.json").write_text('{"synthetic": true} \n')
        status, result, _ = self.drive()
        self.assertEqual(status, 2)
        self.assertEqual(result["reason"], "unsigned_input_changed")


class ArchiveTests(IsolatedTest):
    def test_traversal_absolute_and_backslash_are_rejected(self):
        for name in ("../outside", "/tmp/escape", "safe/../../escape", "safe\\escape"):
            with self.subTest(name=name):
                archive = self.archive([(name, "file", b"bad")])
                with self.assertRaises(acquire.Failure):
                    acquire.extract_archive(archive, self.root / "output")
        self.assertFalse((self.root / "outside").exists())

    def test_symlink_and_hardlink_escape_are_rejected(self):
        for kind, target in (("link", "../../outside"), ("link", "/tmp/outside"), ("hard", "../outside")):
            with self.subTest(kind=kind, target=target):
                archive = self.archive([("python/link", kind, target)])
                with self.assertRaises(acquire.Failure):
                    acquire.extract_archive(archive, self.root / "output")

    def test_archive_symlink_parent_is_rejected_before_writes(self):
        archive = self.archive([("root", "link", "target"), ("root/payload", "file", b"bad"), ("target", "dir", "")])
        output = self.root / "output"
        with self.assertRaisesRegex(acquire.Failure, "archive_link_parent"):
            acquire.extract_archive(archive, output)
        self.assertEqual(list(output.iterdir()), [])

    def test_existing_symlink_parent_cannot_escape(self):
        output = self.root / "output"
        output.mkdir()
        outside = self.root / "outside"
        outside.mkdir()
        (output / "link").symlink_to(outside)
        archive = self.archive([("link/payload", "file", b"bad")])
        with self.assertRaises(acquire.Failure):
            acquire.extract_archive(archive, output)
        self.assertEqual(list(outside.iterdir()), [])

    def test_internal_python_symlink_and_hardlink_work(self):
        archive = self.archive([("python/bin/python3.13", "file", b"synthetic"), ("python/bin/python3", "link", "python3.13"), ("python/bin/alias", "hard", "python/bin/python3.13")])
        output = self.root / "output"
        acquire.extract_archive(archive, output)
        self.assertEqual((output / "python/bin/python3").read_bytes(), b"synthetic")
        self.assertEqual((output / "python/bin/alias").read_bytes(), b"synthetic")
        inode = (output / "python/bin/python3.13").stat().st_ino
        inventory = acquire.tree_inventory(output)
        acquire.extract_archive(archive, output)
        self.assertEqual(acquire.tree_inventory(output), inventory)
        self.assertEqual((output / "python/bin/alias").stat().st_ino, inode)

    def test_retry_refuses_changed_permissions_and_link_targets(self):
        archive = self.archive([("bin/tool", "file", b"synthetic"), ("bin/alias", "link", "tool")])
        output = self.root / "output"
        acquire.extract_archive(archive, output)
        (output / "bin/tool").chmod(0o600)
        with self.assertRaisesRegex(acquire.Failure, "archive_mode_mismatch"):
            acquire.extract_archive(archive, output)
        self.assertEqual(stat.S_IMODE((output / "bin/tool").stat().st_mode), 0o600)
        (output / "bin/tool").chmod(0o644)
        (output / "bin/alias").unlink()
        (output / "bin/alias").symlink_to("different")
        with self.assertRaisesRegex(acquire.Failure, "archive_collision"):
            acquire.extract_archive(archive, output)
        self.assertEqual(os.readlink(output / "bin/alias"), "different")

    def test_clang_internal_dangling_linux_aliases_are_preserved(self):
        directory = "lib/clang/23/lib"
        aliases = {
            "aarch64-cros-linux-gnu": "aarch64-unknown-linux-gnu",
            "armv7a-cros-linux-gnueabihf": "armv7-unknown-linux-gnueabihf",
            "x86_64-cros-linux-gnu": "x86_64-unknown-linux-gnu",
        }
        archive = self.archive([(directory + "/" + name, "link", target) for name, target in aliases.items()])
        output = self.root / "clang"
        acquire.extract_archive(archive, output)
        for name, target in aliases.items():
            link = output / directory / name
            self.assertTrue(link.is_symlink())
            self.assertFalse(link.exists())
            self.assertEqual(os.readlink(link), target)
            self.assertEqual(link.resolve(), output / directory / target)
            self.assertFalse((output / directory / target).exists())
        inventory = acquire.tree_inventory(output)
        self.assertEqual(inventory, [{"path": directory + "/" + name, "link": target} for name, target in sorted(aliases.items())])
        acquire.extract_archive(archive, output)
        self.assertEqual(acquire.tree_inventory(output), inventory)

    def test_zip_internal_dangling_symlink_is_preserved(self):
        archive = self.root / "dangling.zip"
        with zipfile.ZipFile(archive, "w") as stream:
            entry = zipfile.ZipInfo("lib/alias")
            entry.external_attr = (stat.S_IFLNK | 0o777) << 16
            stream.writestr(entry, "missing-runtime")
        output = self.root / "output"
        acquire.extract_archive(archive, output)
        self.assertTrue((output / "lib/alias").is_symlink())
        self.assertFalse((output / "lib/alias").exists())
        self.assertEqual(os.readlink(output / "lib/alias"), "missing-runtime")

    def test_symbolic_self_and_multi_link_cycles_are_rejected(self):
        cycles = (
            [("lib/self", "link", "self")],
            [("lib/a", "link", "b"), ("lib/b", "link", "a")],
            [("lib/a", "link", "b"), ("lib/b", "link", "c"), ("lib/c", "link", "a")],
        )
        for index, members in enumerate(cycles):
            with self.subTest(members=members):
                archive = self.archive(members)
                with self.assertRaises(acquire.Failure):
                    acquire.extract_archive(archive, self.root / f"cycle-{index}")

    def test_internal_lexical_target_cannot_escape_through_existing_symlink(self):
        output = self.root / "output"
        output.mkdir()
        outside = self.root / "outside"
        outside.mkdir()
        marker = outside / "preserved"
        marker.write_bytes(b"user work")
        (output / "redirect").symlink_to(outside)
        archive = self.archive([("lib/alias", "link", "../redirect/missing")])
        with self.assertRaisesRegex(acquire.Failure, "escaping_link"):
            acquire.extract_archive(archive, output)
        self.assertEqual(marker.read_bytes(), b"user work")
        self.assertFalse((outside / "missing").exists())

    def test_dangling_hardlinks_remain_rejected(self):
        cases = (
            [("lib/alias", "hard", "lib/missing")],
            [("lib/alias", "hard", "lib/symbolic"), ("lib/symbolic", "link", "missing")],
        )
        for index, members in enumerate(cases):
            with self.subTest(members=members):
                archive = self.archive(members)
                output = self.root / f"hard-{index}"
                with self.assertRaisesRegex(acquire.Failure, "dangling_or_cyclic_archive_link"):
                    acquire.extract_archive(archive, output)
                self.assertFalse((output / "lib/alias").exists())
                self.assertFalse((output / "lib/alias").is_symlink())

    def test_zip_symlink_escape(self):
        path = self.root / "bad.zip"
        with zipfile.ZipFile(path, "w") as archive:
            entry = zipfile.ZipInfo("python/escape")
            entry.external_attr = (stat.S_IFLNK | 0o777) << 16
            archive.writestr(entry, "../../outside")
        with self.assertRaises(acquire.Failure):
            acquire.extract_archive(path, self.root / "output")

    def test_special_member_and_duplicate_rejected(self):
        for members in ([('fifo', 'fifo', '')], [('same', 'file', b'a'), ('same', 'file', b'b')]):
            with self.subTest(members=members):
                archive = self.archive(members)
                with self.assertRaises(acquire.Failure):
                    acquire.extract_archive(archive, self.root / "output")

    def test_no_broad_deletion_or_existing_file_overwrite(self):
        output = self.root / "output"
        output.mkdir()
        user_file = output / "owned"
        user_file.write_bytes(b"user work")
        sibling = self.root / "unrelated"
        sibling.write_bytes(b"preserve")
        archive = self.archive([("owned", "file", b"replacement")])
        with self.assertRaisesRegex(acquire.Failure, "archive_collision"):
            acquire.extract_archive(archive, output)
        self.assertEqual(user_file.read_bytes(), b"user work")
        self.assertEqual(sibling.read_bytes(), b"preserve")


class PinTests(IsolatedTest):
    def test_system_linker_receipt_requires_exact_path_version_and_bytes(self):
        linker = self.root / "Toolchains/XcodeDefault.xctoolchain/usr/bin/ld"
        linker.parent.mkdir(parents=True)
        linker.write_bytes(b"synthetic linker")
        lock = {"toolchain": {"developerDir": str(self.root), "systemLinkerVersion": "27037.1"}}
        with mock.patch.object(acquire, "run", side_effect=[str(linker), '{"version":"27037.1"}']):
            self.assertEqual(acquire.system_linker(lock), {"path": str(linker), "version": "27037.1", "sha256": hashlib.sha256(linker.read_bytes()).hexdigest()})

    def test_system_linker_rejects_other_path_before_execution(self):
        lock = {"toolchain": {"developerDir": str(self.root), "systemLinkerVersion": "27037.1"}}
        with mock.patch.object(acquire, "run", return_value="/usr/bin/ld") as run:
            with self.assertRaisesRegex(acquire.Failure, "system_linker_path_mismatch"):
                acquire.system_linker(lock)
        self.assertEqual(run.call_count, 1)

    def test_system_linker_rejects_symlink_or_version_change(self):
        linker = self.root / "Toolchains/XcodeDefault.xctoolchain/usr/bin/ld"
        linker.parent.mkdir(parents=True)
        payload = self.root / "payload"
        payload.write_bytes(b"synthetic linker")
        linker.symlink_to(payload)
        lock = {"toolchain": {"developerDir": str(self.root), "systemLinkerVersion": "27037.1"}}
        with mock.patch.object(acquire, "run", return_value=str(linker)):
            with self.assertRaisesRegex(acquire.Failure, "system_linker_path_mismatch"):
                acquire.system_linker(lock)
        linker.unlink()
        linker.write_bytes(payload.read_bytes())
        with mock.patch.object(acquire, "run", side_effect=[str(linker), '{"version":"27038.1"}']):
            with self.assertRaisesRegex(acquire.Failure, "system_linker_version_mismatch"):
                acquire.system_linker(lock)

    def test_unsupported_build_python_blocks_before_toolchain_or_source_access(self):
        with mock.patch.object(acquire.sys, "version_info", (3, 14, 0)), mock.patch.object(acquire, "toolchain") as toolchain:
            with self.assertRaisesRegex(acquire.Failure, "build_python_version_mismatch"):
                acquire.pdfium_stage({}, None, None, None)
        toolchain.assert_not_called()

    def test_wrong_sha256_rejected(self):
        path = self.root / "payload"
        path.write_bytes(b"wrong")
        with self.assertRaisesRegex(acquire.Failure, "sha256_mismatch"):
            acquire.check_hash(path, "0" * 64)

    def test_cached_wrong_hash_rejected_without_network(self):
        cache = self.root / "downloads"
        cache.mkdir()
        (cache / ("0" * 64)).write_bytes(b"wrong")
        with self.assertRaisesRegex(acquire.Failure, "sha256_mismatch"):
            acquire.download(cache, "https://files.pythonhosted.org/pinned.whl", "0" * 64)

    def test_generation_mismatch_is_not_accepted(self):
        response = io.BytesIO(b"payload")
        response.headers = {"x-goog-generation": "2"}
        digest = hashlib.sha256(b"payload").hexdigest()
        with mock.patch.object(acquire, "request", return_value=response):
            with self.assertRaisesRegex(acquire.Failure, "gcs_generation_mismatch"):
                acquire.download(self.root / "downloads", "https://commondatastorage.googleapis.com/chromium-browser-clang/object?generation=1", digest, "1")
        self.assertFalse((self.root / "downloads" / digest).exists())

    def test_pin_and_arch_mismatch(self):
        entry = {"arm64": {"filename": "package-macosx_x86_64.whl", "sha256": "0" * 64}}
        with self.assertRaisesRegex(acquire.Failure, "asset_arch_mismatch"):
            acquire.select_asset(entry, "arm64")
        with self.assertRaisesRegex(acquire.Failure, "unsupported_arch"):
            acquire.select_asset(entry, "universal")

    def test_cancelled_architectures_reject_at_cli_without_effects(self):
        for arch in ("x86_64", "x64", "amd64", "i386", "universal"):
            with self.subTest(arch=arch), mock.patch.object(acquire, "load_lock") as lock, mock.patch.object(acquire, "ensure_root") as output, mock.patch.object(acquire.subprocess, "run") as process, contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit) as error:
                    acquire.main(["--arch", arch, "--stage", "fetch"])
                self.assertEqual(error.exception.code, 2)
                lock.assert_not_called()
                output.assert_not_called()
                process.assert_not_called()

    def test_intel_host_rejects_before_lock_tools_or_output(self):
        with mock.patch.object(acquire.platform, "machine", return_value="x86_64"), mock.patch.object(acquire, "load_lock") as lock, mock.patch.object(acquire, "ensure_root") as output, mock.patch.object(acquire.subprocess, "run") as process, contextlib.redirect_stdout(io.StringIO()) as result:
            self.assertEqual(acquire.main(["--arch", "arm64", "--stage", "fetch"]), 2)
        self.assertEqual(json.loads(result.getvalue())["reason"], "unsupported_host_cpu")
        lock.assert_not_called()
        output.assert_not_called()
        process.assert_not_called()

    def test_translated_or_unproven_arm_host_rejects_without_fallback(self):
        for status, translated in ((0, b"1"), (0, b""), (1, b"")):
            result = subprocess.CompletedProcess([], status, stdout=translated, stderr=b"")
            with self.subTest(status=status, translated=translated), mock.patch.object(acquire.platform, "machine", return_value="arm64"), mock.patch.object(acquire.subprocess, "run", return_value=result) as process, mock.patch.object(acquire, "load_lock") as lock, mock.patch.object(acquire, "ensure_root") as output, contextlib.redirect_stdout(io.StringIO()) as response:
                self.assertEqual(acquire.main(["--arch", "arm64", "--stage", "fetch"]), 2)
                self.assertEqual(json.loads(response.getvalue())["reason"], "rosetta_or_unknown_host_forbidden")
                self.assertEqual(process.call_count, 1)
                lock.assert_not_called()
                output.assert_not_called()

    def test_cancelled_architectures_reject_at_apis_before_effects(self):
        before = acquire.tree_inventory(self.root)
        with mock.patch.object(acquire, "download") as download, mock.patch.object(acquire, "run") as run, mock.patch.object(acquire, "toolchain") as toolchain, mock.patch.object(acquire, "ensure_root") as output:
            for host, arch, reason in (("arm64", "x86_64", "unsupported_arch"), ("x86_64", "arm64", "unsupported_host_cpu")):
                for owner in (acquire.fetch, acquire.validate_receipt):
                    with self.subTest(owner=owner.__name__, host=host, arch=arch), self.assertRaisesRegex(acquire.Failure, reason):
                        owner({}, self.root, host, arch, self.root / "cache")
            with self.assertRaisesRegex(acquire.Failure, "unsupported_host_cpu"):
                acquire.source_graph({}, self.root, "x86_64", self.root / "cache")
            with self.assertRaisesRegex(acquire.Failure, "unsupported_host_cpu"):
                acquire.DepsReader("deps = {}", "x86_64", {})
            with self.assertRaisesRegex(acquire.Failure, "unsupported_arch"):
                acquire.select_asset({"any": {"filename": "pure.whl", "sha256": "0" * 64}}, "x86_64")
            with self.assertRaisesRegex(acquire.Failure, "unsupported_arch"):
                acquire.runtime_stage({}, self.root, {"arch": "x86_64"}, self.root / "cache")
            with mock.patch.object(acquire.sys, "version_info", (3, 13, 0)):
                for host, arch, reason in (("arm64", "x86_64", "unsupported_arch"), ("x86_64", "arm64", "unsupported_host_cpu")):
                    with self.assertRaisesRegex(acquire.Failure, reason):
                        acquire.pdfium_stage({}, self.root, {"host": host, "arch": arch}, self.root / "cache")
            with self.assertRaisesRegex(acquire.Failure, "asset_arch_mismatch"):
                acquire.install_wheel(self.root / "missing.whl", self.root / "runtime", "package-macosx_10_9_x86_64.whl")
            download.assert_not_called()
            run.assert_not_called()
            toolchain.assert_not_called()
            output.assert_not_called()
        self.assertEqual(acquire.tree_inventory(self.root), before)

    def test_receipt_wrong_arch_fails_before_source_or_network(self):
        lock = acquire.load_lock()
        receipt = {"lockHash": acquire.sha256(acquire.LOCK_PATH), "arch": "x86_64", "host": "arm64"}
        (self.root / "acquisition.json").write_text(json.dumps(receipt))
        with self.assertRaisesRegex(acquire.Failure, "acquisition_pin_or_arch_mismatch"):
            acquire.validate_receipt(lock, self.root, "arm64", "arm64", self.root / "downloads")

    def test_cipd_instance_hash_and_known_pin_mismatch(self):
        lock = acquire.load_lock()
        pin = lock["cipd"]["arm64"]["gn"]
        self.assertEqual(acquire.instance_sha(pin["instance"]), pin["sha256"])
        response = {"status": "SUCCESS", "instance_id": lock["cipd"]["x86_64"]["gn"]["instance"]}
        with mock.patch.object(acquire, "metadata", return_value=response):
            with self.assertRaisesRegex(acquire.Failure, "cipd_pin_mismatch"):
                acquire.resolve_cipd(lock, pin["package"], lock["pdfium"]["gnVersion"], pin)

    def test_repeated_arm_builds_reuse_same_immutable_tool_resolution(self):
        lock = acquire.load_lock()
        pin = lock["cipd"]["arm64"]["gn"]
        response = {"status": "SUCCESS", "instance_id": pin["instance"]}
        with mock.patch.object(acquire, "metadata", return_value=response) as metadata:
            first = acquire.resolve_cipd(lock, pin["package"], lock["pdfium"]["gnVersion"], pin, cache=self.root)
            second = acquire.resolve_cipd(lock, pin["package"], lock["pdfium"]["gnVersion"], pin, cache=self.root)
        self.assertEqual(first, second)
        self.assertEqual(metadata.call_count, 1)

    def test_pypi_filename_and_hash_are_both_required(self):
        lock = acquire.load_lock()
        entry = lock["wheels"][0]
        asset = acquire.select_asset(entry, "arm64")
        document = {"info": {"version": entry["version"]}, "urls": [{"filename": asset["filename"], "digests": {"sha256": "0" * 64}, "url": "https://files.pythonhosted.org/" + asset["filename"]}]}
        with mock.patch.object(acquire, "metadata", return_value=document):
            with self.assertRaisesRegex(acquire.Failure, "pypi_hash_mismatch"):
                acquire.pypi_asset(lock, entry, asset)

    def test_deps_never_executes_code_and_minimal_conditions(self):
        with self.assertRaises(acquire.Failure):
            acquire.DepsReader("import os\nos.system('exit 1')", "arm64", {})
        variables = {"checkout_configuration": "default", "checkout_skia": 'checkout_configuration != "minimal"'}
        reader = acquire.DepsReader("vars = " + repr(variables) + "\ndeps = {}\n", "arm64", {"checkout_configuration": "minimal"})
        self.assertFalse(reader.enabled({"condition": "checkout_skia"}))
        self.assertFalse(reader.enabled({"condition": "checkout_linux and unknown_platform_flag"}))


class GRDBSourceStageTests(IsolatedTest):
    # Model Git only; exercise the real source-stage implementation without
    # fetching/executing vendor source, SwiftPM, build tools or runtime probes.
    package_bytes = b"// synthetic Package.swift, never executed\n"
    tree = "1" * 40

    def setUp(self):
        super().setUp()
        self.lock = acquire.load_lock()
        self.manifest = self.root / "dependencies.json"
        self.manifest.write_text(json.dumps(self.lock))
        patch = mock.patch.object(acquire, "LOCK_PATH", self.manifest)
        patch.start()
        self.addCleanup(patch.stop)
        self.work = self.root / "fresh-work"
        self.replies = {}
        self.calls = []

    def fake_git(self, path, *args):
        self.calls.append(args)
        self.assertEqual(path, self.work / "grdb-source/src")
        if args in self.replies:
            return self.replies[args]
        if args == ("init",):
            return ""
        if args == ("fetch", "--depth=1", "--no-tags", self.lock["grdb"]["url"], self.lock["grdb"]["commit"]):
            return ""
        if args == ("checkout", "--detach", self.lock["grdb"]["commit"]):
            (path / "Package.swift").write_bytes(self.package_bytes)
            return ""
        if args == ("rev-parse", "HEAD"):
            return self.lock["grdb"]["commit"]
        if args == ("rev-parse", "HEAD^{tree}"):
            return self.tree
        if args == ("ls-files", "-v"):
            return "H Package.swift"
        if args == ("ls-files", "--error-unmatch", "--", "Package.swift"):
            return "Package.swift"
        if args in (
            ("diff", "--cached", "--name-only", "-z", "HEAD", "--"),
            ("ls-files", "--deleted"),
            ("diff", "--no-ext-diff", "--no-textconv", "--ignore-submodules=none", "--raw", "--no-abbrev", "HEAD", "--"),
        ):
            return ""
        raise AssertionError(f"unexpected Git command: {args}")

    def stage(self):
        with mock.patch.object(acquire, "git", side_effect=self.fake_git):
            return acquire.grdb_source_stage(self.lock, self.work)

    def test_exact_pin_required_before_filesystem_or_git_mutation(self):
        pins = [None, {}, {**self.lock["grdb"], "extra": True}]
        for key, value in (("url", "https://github.com/other/GRDB.swift.git"), ("version", "7.11.2"), ("commit", "0" * 40)):
            pins.append({**self.lock["grdb"], key: value})
        for pin in pins:
            with self.subTest(pin=pin):
                lock = {**self.lock, "grdb": pin}
                with mock.patch.object(acquire, "git") as git, mock.patch.object(acquire, "ensure_root") as ensure:
                    with self.assertRaisesRegex(acquire.Failure, "grdb_pin_mismatch"):
                        acquire.grdb_source_stage(lock, self.work)
                git.assert_not_called()
                ensure.assert_not_called()
                self.assertFalse(self.work.exists())

    def test_manifest_binding_rejected_before_mutation(self):
        lock = {**self.lock, "unrecorded": True}
        with mock.patch.object(acquire, "git") as git:
            with self.assertRaisesRegex(acquire.Failure, "grdb_manifest_mismatch"):
                acquire.grdb_source_stage(lock, self.work)
        git.assert_not_called()
        self.assertFalse(self.work.exists())

    def test_existing_destination_is_preserved_without_git(self):
        destination = self.work / "grdb-source"
        destination.mkdir(parents=True)
        marker = destination / "source-only.json"
        marker.write_bytes(b"historical receipt")
        with mock.patch.object(acquire, "git") as git:
            with self.assertRaisesRegex(acquire.Failure, "grdb_source_destination_occupied"):
                acquire.grdb_source_stage(self.lock, self.work)
        git.assert_not_called()
        self.assertEqual(marker.read_bytes(), b"historical receipt")
        self.assertEqual(list(destination.iterdir()), [marker])

    def test_symlink_destination_is_rejected_without_git(self):
        self.work.mkdir()
        destination = self.work / "grdb-source"
        destination.symlink_to(self.root / "missing")
        with mock.patch.object(acquire, "git") as git:
            with self.assertRaisesRegex(acquire.Failure, "symlink_path"):
                acquire.grdb_source_stage(self.lock, self.work)
        git.assert_not_called()
        self.assertTrue(destination.is_symlink())
        self.assertFalse((self.root / "missing").exists())

    def test_commit_tree_and_dirty_source_reject_without_receipt(self):
        cases = (
            (("rev-parse", "HEAD"), "0" * 40, "git_commit_mismatch"),
            (("rev-parse", "HEAD^{tree}"), "not-a-tree", "grdb_invalid_tree"),
            (("ls-files", "-v"), "h Package.swift", "grdb_hidden_source"),
            (("diff", "--cached", "--name-only", "-z", "HEAD", "--"), "Package.swift", "grdb_staged_source"),
            (("ls-files", "--deleted"), "Package.swift", "missing_git_source"),
            (("diff", "--no-ext-diff", "--no-textconv", "--ignore-submodules=none", "--raw", "--no-abbrev", "HEAD", "--"), "changed source", "grdb_dirty_source"),
            (("ls-files", "--error-unmatch", "--", "Package.swift"), "", "grdb_package_untracked"),
        )
        for index, (command, reply, reason) in enumerate(cases):
            with self.subTest(reason=reason):
                self.work = self.root / f"rejected-{index}"
                self.replies = {command: reply}
                with self.assertRaisesRegex(acquire.Failure, reason):
                    self.stage()
                self.assertFalse((self.work / "grdb-source/source-only.json").exists())
                with mock.patch.object(acquire, "git") as git:
                    with self.assertRaisesRegex(acquire.Failure, "grdb_source_destination_occupied"):
                        acquire.grdb_source_stage(self.lock, self.work)
                git.assert_not_called()

    def test_truthful_exclusive_source_only_receipt(self):
        hosts = acquire.GIT_HOSTS.copy()
        receipt = self.stage()
        self.assertEqual(receipt, {
            "schemaRevision": "grdb-source-only-v1", "sourceOnly": True,
            "lockHash": hashlib.sha256(self.manifest.read_bytes()).hexdigest(),
            "pin": self.lock["grdb"], "source": "grdb-source/src", "tree": self.tree,
            "packageSwiftSha256": hashlib.sha256(self.package_bytes).hexdigest(),
        })
        path = self.work / "grdb-source/source-only.json"
        original = path.read_bytes()
        self.assertEqual(json.loads(original), receipt)
        self.assertEqual(self.calls[:3], [
            ("init",),
            ("fetch", "--depth=1", "--no-tags", self.lock["grdb"]["url"], self.lock["grdb"]["commit"]),
            ("checkout", "--detach", self.lock["grdb"]["commit"]),
        ])
        self.assertEqual(acquire.GIT_HOSTS, hosts)
        self.assertNotIn("github.com", acquire.GIT_HOSTS)
        with mock.patch.object(acquire, "git") as git:
            with self.assertRaisesRegex(acquire.Failure, "grdb_source_destination_occupied"):
                acquire.grdb_source_stage(self.lock, self.work)
        git.assert_not_called()
        self.assertEqual(path.read_bytes(), original)

    def test_existing_git_wrapper_is_used_for_every_command(self):
        def fake_run(argv):
            self.assertEqual(argv[:12], [
                "/usr/bin/git", "-c", "core.hooksPath=/dev/null",
                "-c", "core.fsmonitor=false", "-c", "core.filemode=true",
                "-c", "core.ignorestat=false", "-c", "protocol.file.allow=never", "-C",
            ])
            return self.fake_git(argv[12], *argv[13:])

        with mock.patch.object(acquire, "run", side_effect=fake_run):
            receipt = acquire.grdb_source_stage(self.lock, self.work)
        self.assertEqual(receipt["tree"], self.tree)
        self.assertEqual(acquire.clean_env()["GIT_CONFIG_GLOBAL"], "/dev/null")
        self.assertEqual(acquire.clean_env()["GIT_CONFIG_NOSYSTEM"], "1")
        self.assertEqual(acquire.clean_env()["GIT_TERMINAL_PROMPT"], "0")

    def test_package_symlink_is_rejected_without_following_it(self):
        outside = self.root / "outside"
        outside.write_bytes(b"preserve")

        def fake_git(path, *args):
            reply = self.fake_git(path, *args)
            if args == ("checkout", "--detach", self.lock["grdb"]["commit"]):
                (path / "Package.swift").unlink()
                (path / "Package.swift").symlink_to(outside)
            return reply

        with mock.patch.object(acquire, "git", side_effect=fake_git):
            with self.assertRaisesRegex(acquire.Failure, "symlink_path"):
                acquire.grdb_source_stage(self.lock, self.work)
        self.assertEqual(outside.read_bytes(), b"preserve")
        self.assertFalse((self.work / "grdb-source/source-only.json").exists())

    def test_changed_manifest_during_fetch_cannot_receive_receipt(self):
        def fake_git(path, *args):
            reply = self.fake_git(path, *args)
            if args[0] == "fetch":
                self.manifest.write_text(json.dumps({**self.lock, "changed": True}))
            return reply

        with mock.patch.object(acquire, "git", side_effect=fake_git):
            with self.assertRaisesRegex(acquire.Failure, "grdb_manifest_changed"):
                acquire.grdb_source_stage(self.lock, self.work)
        self.assertFalse((self.work / "grdb-source/source-only.json").exists())

    def test_receipt_creation_is_exclusive_even_on_collision(self):
        save_json = acquire.save_json

        def occupied_receipt(path, value):
            path.write_bytes(b"preserve concurrent receipt")
            save_json(path, value)

        with mock.patch.object(acquire, "save_json", side_effect=occupied_receipt):
            with self.assertRaises(FileExistsError):
                self.stage()
        self.assertEqual((self.work / "grdb-source/source-only.json").read_bytes(), b"preserve concurrent receipt")


class PDFiumPatchTests(IsolatedTest):
    # Exact approved UTF-8/LF input. Git is modeled offline; no fetched source,
    # tools, hooks, patch commands or compiler are executed by these tests.
    patch_bytes = b"""--- a/core/fpdfapi/page/cpdf_psengine.cpp
+++ b/core/fpdfapi/page/cpdf_psengine.cpp
@@ -449,10 +449,10 @@
       if (j > 0) {
         j -= n;
       }
-      auto begin_it = std::begin(stack_) + stack_count_ - n;
-      auto middle_it = begin_it - j;
-      auto end_it = std::begin(stack_) + stack_count_;
-      std::rotate(begin_it, middle_it, end_it);
+      auto stack =
+          pdfium::span(stack_).first(stack_count_).last(static_cast<size_t>(n));
+      std::rotate(stack.begin(),
+                  stack.subspan(static_cast<size_t>(-j)).begin(), stack.end());
       break;
     }
     default:
"""

    def setUp(self):
        super().setUp()
        self.lock = acquire.load_lock()
        self.source = self.root / "pdfium/src"
        self.target = self.source / acquire.PDFIUM_PATCH["target"]
        self.target.parent.mkdir(parents=True)
        self.target.write_bytes(b"synthetic original\n")
        self.target.chmod(0o644)
        self.patch = self.root / acquire.PDFIUM_PATCH["path"]
        self.patch.parent.mkdir(parents=True)
        self.patch.write_bytes(self.patch_bytes)
        self.raw = ""
        self.staged = ""
        self.deleted = ""
        self.flags = "H " + acquire.PDFIUM_PATCH["target"]
        self.base = {
            "HEAD": self.lock["pdfium"]["commit"],
            "HEAD^{tree}": self.lock["pdfium"]["tree"],
            "HEAD:DEPS": self.lock["pdfium"]["depsBlob"],
        }
        for patcher in (
            mock.patch.object(acquire, "ROOT", self.root),
            mock.patch.object(acquire, "git", side_effect=self.git),
            mock.patch.object(acquire, "sha256", side_effect=self.hash),
        ):
            value = patcher.start()
            self.addCleanup(patcher.stop)
            if patcher.attribute == "git":
                self.commands = value

    def hash(self, path):
        data = Path(path).read_bytes()
        if Path(path) == self.target:
            known = {b"synthetic original\n": "beforeSha256", b"synthetic patched\n": "afterSha256"}
            if data in known:
                return acquire.PDFIUM_PATCH[known[data]]
        return hashlib.sha256(data).hexdigest()

    def approved_diff(self):
        return ":100644 100644 " + "1" * 40 + " " + "0" * 40 + " M\t" + acquire.PDFIUM_PATCH["target"]

    def git(self, path, *args):
        self.assertEqual(path, self.source)
        if args[0] == "rev-parse":
            return self.base[args[1]]
        if args == ("ls-files", "-v"):
            return self.flags
        if args == ("ls-files", "--deleted"):
            return self.deleted
        if args[0] == "diff":
            return self.staged if "--cached" in args else self.raw
        if args[0] == "apply":
            self.assertEqual(Path(args[-1]), self.patch)
            self.assertIn("--whitespace=error", args)
            if "--check" not in args:
                self.target.write_bytes(b"synthetic patched\n")
                self.raw = self.approved_diff()
            return ""
        self.fail("unexpected Git command: " + repr(args))

    def acquire(self):
        return acquire.pdfium_checkout(self.lock, self.source)

    def assert_not_applied(self):
        self.assertFalse(any(call.args[1] == "apply" for call in self.commands.call_args_list))

    def test_pristine_application_and_exact_reentry(self):
        self.assertEqual(hashlib.sha256(self.patch_bytes).hexdigest(), acquire.PDFIUM_PATCH["sha256"])
        expected = {"baseCommit": self.lock["pdfium"]["commit"], **acquire.PDFIUM_PATCH}
        self.assertEqual(self.acquire(), expected)
        self.assertEqual(self.target.read_bytes(), b"synthetic patched\n")
        self.commands.reset_mock()
        self.assertEqual(self.acquire(), expected)
        self.assert_not_applied()

    def test_changed_missing_and_symlink_patch_are_rejected(self):
        self.patch.write_bytes(self.patch_bytes + b"\n")
        with self.assertRaisesRegex(acquire.Failure, "sha256_mismatch"):
            self.acquire()
        self.patch.unlink()
        with self.assertRaisesRegex(acquire.Failure, "pdfium_patch_missing"):
            self.acquire()
        outside = self.root / "outside.patch"
        outside.write_bytes(self.patch_bytes)
        self.patch.symlink_to(outside)
        with self.assertRaisesRegex(acquire.Failure, "symlink_path"):
            self.acquire()
        self.assert_not_applied()

    def test_changed_source_is_never_overwritten(self):
        self.target.write_bytes(b"user work\n")
        with self.assertRaisesRegex(acquire.Failure, "pdfium_patch_source_mismatch"):
            self.acquire()
        self.assertEqual(self.target.read_bytes(), b"user work\n")
        self.assert_not_applied()

    def test_reentry_rejects_modified_result(self):
        self.acquire()
        self.commands.reset_mock()
        self.target.write_bytes(b"synthetic patched\nextra change\n")
        with self.assertRaisesRegex(acquire.Failure, "pdfium_patch_source_mismatch"):
            self.acquire()
        self.assert_not_applied()

    def test_reentry_still_requires_unchanged_patch_bytes(self):
        self.acquire()
        self.commands.reset_mock()
        self.patch.write_bytes(self.patch_bytes.replace(b"stack.end()", b"stack.begin()"))
        with self.assertRaisesRegex(acquire.Failure, "sha256_mismatch"):
            self.acquire()
        self.assert_not_applied()

    def test_target_and_patch_metadata_are_not_configurable(self):
        for key, value in (("target", "../escape"), ("target", "core/other.cpp"), ("path", "../outside.patch"), ("sha256", "0" * 64), ("beforeSha256", "0" * 64), ("afterSha256", "0" * 64)):
            with self.subTest(key=key, value=value):
                lock = json.loads(json.dumps(self.lock))
                lock["pdfium"]["patch"][key] = value
                with self.assertRaisesRegex(acquire.Failure, "pdfium_patch_pin_mismatch"):
                    acquire.pdfium_checkout(lock, self.source)
        self.assert_not_applied()

    def test_symlink_target_and_ancestor_are_rejected(self):
        outside = self.root / "outside.cpp"
        outside.write_bytes(b"user work\n")
        self.target.unlink()
        self.target.symlink_to(outside)
        with self.assertRaisesRegex(acquire.Failure, "symlink_path"):
            self.acquire()
        self.target.unlink()
        self.target.parent.rmdir()
        self.target.parent.symlink_to(self.root)
        with self.assertRaisesRegex(acquire.Failure, "symlink_path"):
            self.acquire()
        self.assertEqual(outside.read_bytes(), b"user work\n")
        self.assert_not_applied()

    def test_missing_target_and_target_mode_are_rejected(self):
        self.target.chmod(0o755)
        with self.assertRaisesRegex(acquire.Failure, "pdfium_patch_target_mode"):
            self.acquire()
        self.target.unlink()
        with self.assertRaisesRegex(acquire.Failure, "pdfium_patch_target_mode"):
            self.acquire()
        self.assert_not_applied()

    def test_wrong_head_tree_and_deps_are_rejected(self):
        for revision in self.base:
            with self.subTest(revision=revision):
                original = self.base[revision]
                self.base[revision] = "0" * 40
                with self.assertRaises(acquire.Failure):
                    self.acquire()
                self.base[revision] = original
        self.assert_not_applied()

    def test_pristine_content_with_dirty_path_or_mode_is_rejected(self):
        for raw in (self.approved_diff(), ":100644 100755 " + "1" * 40 + " " + "0" * 40 + " M\tDEPS"):
            with self.subTest(raw=raw):
                self.raw = raw
                with self.assertRaisesRegex(acquire.Failure, "pdfium_dirty_source"):
                    self.acquire()
        self.assert_not_applied()

    def test_reentry_rejects_extra_path_wrong_path_and_mode(self):
        self.target.write_bytes(b"synthetic patched\n")
        expected = self.approved_diff()
        for raw in (expected + "\n" + expected.replace(acquire.PDFIUM_PATCH["target"], "DEPS"), expected.replace(acquire.PDFIUM_PATCH["target"], "DEPS"), expected.replace(":100644 100644", ":100644 100755"), ""):
            with self.subTest(raw=raw):
                self.raw = raw
                with self.assertRaisesRegex(acquire.Failure, "pdfium_dirty_source"):
                    self.acquire()
        self.assert_not_applied()

    def test_staged_deleted_and_hidden_sources_are_rejected(self):
        for field, value, reason in (("staged", "DEPS\0", "pdfium_staged_source"), ("deleted", "DEPS", "missing_git_source"), ("flags", "h DEPS", "pdfium_hidden_source"), ("flags", "S DEPS", "pdfium_hidden_source")):
            with self.subTest(field=field):
                original = getattr(self, field)
                setattr(self, field, value)
                with self.assertRaisesRegex(acquire.Failure, reason):
                    self.acquire()
                setattr(self, field, original)
        self.assert_not_applied()

    def test_receipt_missing_or_tampered_patch_fails_before_graph(self):
        lock_hash = self.hash(acquire.LOCK_PATH)
        expected = acquire.pdfium_patch_receipt(self.lock)
        for patch in (None, dict(expected, baseCommit="0" * 40), dict(expected, sha256="0" * 64), dict(expected, afterSha256="0" * 64), dict(expected, target="../escape")):
            with self.subTest(patch=patch):
                receipt = {"lockHash": lock_hash, "arch": "arm64", "host": "arm64", "pdfiumPatch": patch}
                (self.root / "acquisition.json").write_text(json.dumps(receipt))
                with mock.patch.object(acquire, "source_graph") as graph:
                    with self.assertRaisesRegex(acquire.Failure, "pdfium_patch_receipt_mismatch"):
                        acquire.validate_receipt(self.lock, self.root, "arm64", "arm64", self.root / "downloads")
                graph.assert_not_called()

    def test_cached_receipt_does_not_authorize_changed_lock_metadata(self):
        lock = json.loads(json.dumps(self.lock))
        lock["pdfium"]["patch"]["sha256"] = "0" * 64
        receipt = {"lockHash": self.hash(acquire.LOCK_PATH), "arch": "arm64", "host": "arm64", "pdfiumPatch": acquire.pdfium_patch_receipt(self.lock)}
        (self.root / "acquisition.json").write_text(json.dumps(receipt))
        with self.assertRaisesRegex(acquire.Failure, "pdfium_patch_pin_mismatch"):
            acquire.validate_receipt(lock, self.root, "arm64", "arm64", self.root / "downloads")

    def test_old_lock_receipt_fails_without_rewriting_or_applying(self):
        receipt = {"lockHash": "0" * 64, "arch": "arm64", "host": "arm64", "pdfiumPatch": acquire.pdfium_patch_receipt(self.lock)}
        path = self.root / "acquisition.json"
        path.write_text(json.dumps(receipt))
        original = path.read_bytes()
        with self.assertRaisesRegex(acquire.Failure, "acquisition_pin_or_arch_mismatch"):
            acquire.fetch(self.lock, self.root, "arm64", "arm64", self.root / "downloads")
        self.assertEqual(path.read_bytes(), original)
        self.assert_not_applied()

    def test_new_acquisition_receipt_captures_patch_result(self):
        graph = {"repositories": [], "archives": [], "pdfiumPatch": self.acquire()}
        with mock.patch.object(acquire, "download"), mock.patch.object(acquire, "pypi_asset", return_value="https://files.pythonhosted.org/synthetic"), mock.patch.object(acquire, "source_graph", return_value=graph):
            receipt = acquire.fetch(self.lock, self.root, "arm64", "arm64", self.root / "downloads")
        persisted = json.loads((self.root / "acquisition.json").read_text())
        self.assertEqual(persisted, receipt)
        self.assertEqual(receipt["lockHash"], self.hash(acquire.LOCK_PATH))
        self.assertEqual(receipt["pdfiumPatch"], {"baseCommit": self.lock["pdfium"]["commit"], **acquire.PDFIUM_PATCH})


class WheelTests(IsolatedTest):
    def test_metadata_license_record_and_data_relocation(self):
        archive = self.wheel({"sample-1.0.data/data/share/sample.txt": b"asset", "sample-1.0.data/purelib/relocated.py": b"VALUE = 2\n"})
        runtime = self.root / "python"
        acquire.install_wheel(archive, runtime, archive.name)
        site = runtime / "lib/python3.13/site-packages"
        self.assertEqual((runtime / "share/sample.txt").read_bytes(), b"asset")
        self.assertTrue((site / "relocated.py").exists())
        self.assertEqual((site / "sample-1.0.dist-info/licenses/LICENSE").read_bytes(), b"synthetic license\n")
        record = (site / "sample-1.0.dist-info/RECORD").read_text()
        self.assertIn("../../../share/sample.txt", record)
        self.assertIn("licenses/LICENSE", record)

    def test_known_python_script_relocates_without_host_python(self):
        archive = self.wheel({"sample-1.0.data/scripts/sample": b"#!python\nprint('sample')\n"})
        runtime = self.root / "python"
        acquire.install_wheel(archive, runtime, archive.name)
        script = runtime / "bin/sample"
        self.assertIn(b'/python3.13', script.read_bytes())
        self.assertNotIn(b'/usr/bin/env', script.read_bytes())
        self.assertEqual(stat.S_IMODE(script.stat().st_mode), 0o755)

    def test_unknown_executable_layout_rejected(self):
        archive = self.wheel({"sample-1.0.data/scripts/unknown": b"#!/bin/bash\nexit 0\n"})
        with self.assertRaisesRegex(acquire.Failure, "unknown_wheel_executable"):
            acquire.install_wheel(archive, self.root / "python", archive.name)

    def test_cli_distribution_installs_distinct_package_root_executables(self):
        paths = (
            "codex_cli_bin/bin/codex",
            "codex_cli_bin/bin/codex-code-mode-host",
            "codex_cli_bin/codex-path/rg",
            "codex_cli_bin/codex-resources/zsh/bin/zsh",
        )
        payloads = {path: ("synthetic, never executed: " + path).encode() for path in paths}
        for arch, tag in (("arm64", "macosx_11_0_arm64"),):
            with self.subTest(arch=arch):
                filename = f"openai_codex_cli_bin-0.160.0-py3-none-{tag}.whl"
                archive = self.wheel(payloads, distribution="openai_codex_cli_bin", version="0.160.0", filename=filename, executable_paths=paths)
                runtime = self.root / arch / "python"
                acquire.install_wheel(archive, runtime, filename)
                site = runtime / "lib/python3.13/site-packages"
                info = site / "openai_codex_cli_bin-0.160.0.dist-info"
                records = {row[0]: row[1:] for row in csv.reader(io.StringIO((info / "RECORD").read_text()))}
                self.assertIn("Name: openai_codex_cli_bin", (info / "METADATA").read_text())
                self.assertEqual((info / "licenses/LICENSE").read_bytes(), b"synthetic license\n")
                for path, data in payloads.items():
                    self.assertEqual((site / path).read_bytes(), data)
                    self.assertEqual(stat.S_IMODE((site / path).stat().st_mode), 0o755)
                    digest = base64.urlsafe_b64encode(hashlib.sha256(data).digest()).rstrip(b"=").decode()
                    self.assertEqual(records[path], ["sha256=" + digest, str(len(data))])
                self.assertFalse((site / "openai_codex_cli_bin").exists())

    def test_cli_executable_requires_both_distribution_and_actual_package_root(self):
        for distribution, root in (("openai_codex_cli_bin", "openai_codex_cli_bin"), ("sample", "codex_cli_bin")):
            with self.subTest(distribution=distribution, root=root):
                path = root + "/bin/codex"
                archive = self.wheel({path: b"synthetic, never executed"}, distribution=distribution, executable_paths=(path,))
                runtime = self.root / distribution / "python"
                with self.assertRaisesRegex(acquire.Failure, "unknown_wheel_executable"):
                    acquire.install_wheel(archive, runtime, archive.name)
                self.assertFalse((runtime / "lib/python3.13/site-packages" / path).exists())

    def test_wheel_data_traversal_and_unknown_scheme_rejected(self):
        for name in ("sample-1.0.data/data/../../outside", "sample-1.0.data/unknown/value"):
            with self.subTest(name=name):
                archive = self.wheel({name: b"bad"})
                with self.assertRaises(acquire.Failure):
                    acquire.install_wheel(archive, self.root / "python", archive.name)
        self.assertFalse((self.root / "outside").exists())


class RuntimeStageTests(IsolatedTest):
    # The primitive trusts caller-selected inputs; this is not full acquisition
    # or the parent's exact-nine-input preflight.
    python_bytes = b"synthetic Python binary, never executed\n"

    def setUp(self):
        super().setUp()
        for owner, name in ((acquire, "fetch"), (acquire, "source_graph"), (acquire, "request"),
                            (acquire, "run"), (subprocess, "run")):
            guard = mock.patch.object(owner, name, side_effect=AssertionError(name + " forbidden"))
            blocked = guard.start()
            self.addCleanup(guard.stop)
            self.addCleanup(blocked.assert_not_called)
        self.work = self.root / "work"
        self.work.mkdir()
        self.cache = self.root / "cache"
        self.cache.mkdir()
        self.addCleanup(self.assert_no_acquisition)

    def assert_no_acquisition(self):
        self.assertEqual(list(self.root.rglob("acquisition.json")), [])

    def cached_asset(self, path, kind):
        data = path.read_bytes()
        digest = hashlib.sha256(data).hexdigest()
        (self.cache / digest).write_bytes(data)
        return {"kind": kind, "filename": path.name, "sha256": digest}

    def runtime_input(self, members=None, wheel=None):
        if members is None:
            members = [("python/bin/python3.13", "file", self.python_bytes),
                       ("python/bin/python3", "link", "python3.13")]
        archive = self.archive(members)
        assets = [self.cached_asset(archive, "python")]
        assets.append(self.cached_asset(wheel or self.wheel({
            "sample-1.0.data/data/share/sample.txt": b"asset\n",
            "sample-1.0.data/scripts/sample": b"#!python\nprint('sample')\n",
        }), "wheel"))
        return {"arch": "arm64", "assets": assets}

    def stage(self, runtime_input):
        acquire.runtime_stage({}, self.work, runtime_input, self.cache)
        self.assertFalse((self.work / "acquisition.json").exists())

    def test_extract_install_record_inventory_and_receipt_byte_hashes(self):
        runtime_input = self.runtime_input()
        self.stage(runtime_input)
        runtime = self.work / "runtime"
        python = runtime / "python"
        site = python / "lib/python3.13/site-packages"
        info = site / "sample-1.0.dist-info"
        self.assertEqual((python / "bin/python3.13").read_bytes(), self.python_bytes)
        self.assertEqual(os.readlink(python / "bin/python3"), "python3.13")
        self.assertEqual((site / "sample/__init__.py").read_bytes(), b"VALUE = 1\n")
        self.assertIn("Name: sample", (info / "METADATA").read_text())
        self.assertEqual((info / "licenses/LICENSE").read_bytes(), b"synthetic license\n")
        self.assertEqual((python / "share/sample.txt").read_bytes(), b"asset\n")
        script = python / "bin/sample"
        self.assertIn(b'/python3.13', script.read_bytes())
        self.assertNotIn(b'/usr/bin/env', script.read_bytes())
        self.assertEqual(stat.S_IMODE(script.stat().st_mode), 0o755)
        rows = list(csv.reader(io.StringIO((info / "RECORD").read_text())))
        self.assertEqual(len(rows), len({row[0] for row in rows}))
        self.assertIn(["sample-1.0.dist-info/RECORD", "", ""], rows)
        self.assertIn("../../../share/sample.txt", {row[0] for row in rows})
        self.assertIn("../../../bin/sample", {row[0] for row in rows})
        for name, digest, length in rows:
            if name == "sample-1.0.dist-info/RECORD":
                continue
            data = (site / name).read_bytes()
            encoded = base64.urlsafe_b64encode(hashlib.sha256(data).digest()).rstrip(b"=").decode()
            self.assertEqual((digest, length), ("sha256=" + encoded, str(len(data))))
        receipt_path = self.work / "runtime.json"
        receipt_bytes = receipt_path.read_bytes()
        receipt = json.loads(receipt_bytes)
        self.assertEqual(receipt["arch"], "arm64")
        self.assertEqual(receipt["lockHash"], hashlib.sha256(acquire.LOCK_PATH.read_bytes()).hexdigest())
        self.assertEqual(receipt["files"], acquire.tree_inventory(runtime))
        self.assertEqual({item["path"] for item in receipt["files"]}, {
            "python/bin/python3.13", "python/bin/python3", "python/bin/sample",
            "python/share/sample.txt", "python/lib/python3.13/site-packages/sample/__init__.py",
            *["python/lib/python3.13/site-packages/sample-1.0.dist-info/" + name
              for name in ("WHEEL", "METADATA", "RECORD", "licenses/LICENSE")],
        })
        for item in receipt["files"]:
            path = runtime / item["path"]
            if "link" in item:
                self.assertEqual(item["link"], os.readlink(path))
            else:
                self.assertEqual(item["sha256"], hashlib.sha256(path.read_bytes()).hexdigest())
                self.assertEqual(item["mode"], stat.S_IMODE(path.stat().st_mode))
        self.stage(runtime_input)
        self.assertEqual(receipt_path.read_bytes(), receipt_bytes)

    def test_missing_or_invalid_python_layout_leaves_incomplete_destination(self):
        layouts = (
            [("python/lib/placeholder", "file", b"no binary")],
            [("elsewhere/bin/python3.13", "file", self.python_bytes)],
            [("python/bin/python3.13", "dir", "")],
            [("python/bin/python3.13", "file", self.python_bytes), ("foreign", "file", b"extra")],
        )
        for index, members in enumerate(layouts):
            with self.subTest(layout=index):
                self.work = self.root / ("invalid-" + str(index))
                self.work.mkdir()
                runtime_input = self.runtime_input(members)
                with self.assertRaisesRegex(acquire.Failure, "python_runtime_layout"):
                    self.stage(runtime_input)
                self.assertFalse((self.work / "runtime.json").exists())
                self.assertFalse((self.work / "acquisition.json").exists())
                inventory = acquire.tree_inventory(self.work / "runtime")
                with self.assertRaisesRegex(acquire.Failure, "incomplete_runtime"):
                    self.stage(runtime_input)
                self.assertEqual(acquire.tree_inventory(self.work / "runtime"), inventory)
                self.assertFalse((self.work / "runtime.json").exists())

    def test_duplicate_wheel_install_collision_never_writes_runtime_receipt(self):
        runtime_input = self.runtime_input()
        runtime_input["assets"].append(dict(runtime_input["assets"][1]))
        with self.assertRaisesRegex(acquire.Failure, "wheel_install_collision"):
            self.stage(runtime_input)
        self.assertFalse((self.work / "runtime.json").exists())
        site = self.work / "runtime/python/lib/python3.13/site-packages"
        self.assertEqual((site / "sample/__init__.py").read_bytes(), b"VALUE = 1\n")
        self.assertTrue((site / "sample-1.0.dist-info/RECORD").is_file())

    def test_tampered_wheel_record_never_writes_runtime_receipt(self):
        wheel = self.wheel()
        with zipfile.ZipFile(wheel) as source:
            members = [(item, source.read(item)) for item in source.infolist()]
        with zipfile.ZipFile(wheel, "w") as target:
            for item, data in members:
                target.writestr(item, b"tampered\n" if item.filename == "sample/__init__.py" else data)
        runtime_input = self.runtime_input(wheel=wheel)
        with self.assertRaisesRegex(acquire.Failure, "wheel_record_mismatch"):
            self.stage(runtime_input)
        self.assertFalse((self.work / "runtime.json").exists())
        self.assertEqual((self.work / "runtime/python/bin/python3.13").read_bytes(), self.python_bytes)
        self.assertFalse((self.work / "runtime/python/lib/python3.13/site-packages/sample/__init__.py").exists())

    def test_occupied_destination_refusal_preserves_foreign_bytes(self):
        runtime_input = self.runtime_input()
        destination = self.work / "runtime"
        destination.mkdir()
        foreign = destination / "foreign"
        foreign.write_bytes(b"preserve foreign bytes\n")
        foreign.chmod(0o600)
        inventory = acquire.tree_inventory(destination)
        with self.assertRaisesRegex(acquire.Failure, "incomplete_runtime"):
            self.stage(runtime_input)
        self.assertEqual(acquire.tree_inventory(destination), inventory)
        self.assertEqual(foreign.read_bytes(), b"preserve foreign bytes\n")
        self.assertFalse((self.work / "runtime.json").exists())

    def test_runtime_only_output_is_refused_without_full_acquisition(self):
        self.stage(self.runtime_input())
        receipt_bytes = (self.work / "runtime.json").read_bytes()
        inventory = acquire.tree_inventory(self.work / "runtime")
        with self.assertRaisesRegex(packaging.Failure, "required_file_missing"):
            packaging.validate_receipts(self.work, SCRIPTS.parents[1], "arm64", runtime_work=self.work, prepared=False)
        self.assertFalse((self.work / "acquisition.json").exists())
        self.assertEqual((self.work / "runtime.json").read_bytes(), receipt_bytes)
        self.assertEqual(acquire.tree_inventory(self.work / "runtime"), inventory)

    def test_missing_cached_hash_input_fails_without_creating_bytes(self):
        digest = hashlib.sha256(b"missing").hexdigest()
        path = acquire.safe_path(self.cache, digest)
        with self.assertRaises(FileNotFoundError):
            acquire.check_hash(path, digest)
        self.assertFalse(path.exists())

    def test_changed_cached_hash_input_is_rejected_and_preserved(self):
        asset = self.cached_asset(self.wheel(), "wheel")
        path = acquire.safe_path(self.cache, asset["sha256"])
        acquire.check_hash(path, asset["sha256"])
        path.write_bytes(b"changed cached bytes")
        with self.assertRaisesRegex(acquire.Failure, "sha256_mismatch"):
            acquire.check_hash(path, asset["sha256"])
        self.assertEqual(path.read_bytes(), b"changed cached bytes")

    def test_symlinked_cached_hash_input_is_rejected_even_with_matching_bytes(self):
        wheel = self.wheel()
        data = wheel.read_bytes()
        digest = hashlib.sha256(data).hexdigest()
        path = self.cache / digest
        path.symlink_to(wheel)
        with self.assertRaisesRegex(acquire.Failure, "sha256_mismatch"):
            acquire.check_hash(path, digest)
        with self.assertRaisesRegex(acquire.Failure, "symlink_path"):
            acquire.safe_path(self.cache, digest)
        self.assertTrue(path.is_symlink())
        self.assertEqual(wheel.read_bytes(), data)


class EvidenceTests(IsolatedTest):
    def report(self, **changes):
        actors = [{"role": role, "actorInstanceRef": "actor-" + str(verify.uuid.uuid4()), "identityVerified": False} for role in verify.ROLES]
        python = next(a["actorInstanceRef"] for a in actors if a["role"] == "Python")
        row = {"caseID": "mainCanaryRead", "actorInstanceRef": python, "operation": "read", "fixtureID": "M",
               "ownerPre": "unverified", "ownerPost": "unverified", "sameUIDControl": "unverified", "posixACLControl": "unverified",
               "expectedRootMatched": True, "promptObserved": "unverified", "syscallResult": -1, "errno": 13,
               "syscallObserved": True, "intervalRef": "mainCanaryRead", "sandboxDenialRef": None, "verdict": "inconclusive"}
        row.update(changes)
        return {"schemaRevision": "topology-evidence-v2", "runID": "01234567-89ab-4cde-8fab-0123456789ab", "actorBindings": actors, "cases": [row]}

    def invoke(self, arch="arm64", consent=False):
        output = io.StringIO()
        args = ["--arch", arch, "--bundle", str(self.root / "PaperLens.app")]
        if consent:
            args.append("--confirm-current-profile")
        with mock.patch.object(verify, "native_cpu", return_value=(arch, False)), mock.patch.object(verify, "command", return_value=(0, b"25A1", b"")), mock.patch.object(verify, "inspect_bundle") as inspect, mock.patch.object(verify, "current_home", return_value=self.root) as home, mock.patch.object(verify, "gui_run") as gui, contextlib.redirect_stdout(output):
            status = verify.main(args)
        return status, json.loads(output.getvalue()), inspect, home, gui

    def test_consent_required_before_profile_metadata_or_gui(self):
        status, evidence, inspect, home, gui = self.invoke()
        self.assertEqual(status, 2)
        inspect.assert_called_once()
        home.assert_not_called()
        gui.assert_not_called()
        self.assertTrue(any(row["reason"] == "explicit_current_profile_consent_required" for row in evidence["automated"]))

    def test_current_consent_preserves_manual_remote_and_p1_blocks(self):
        status, evidence, inspect, home, gui = self.invoke(consent=True)
        self.assertEqual(status, 2)
        inspect.assert_called_once()
        home.assert_called_once()
        gui.assert_called_once()
        manual = {row["caseID"]: row for row in evidence["manual"]}
        self.assertEqual(manual["currentProfile"]["verdict"], "inconclusive")
        self.assertEqual(manual["cleanProfile"]["verdict"], "blocked")
        self.assertNotIn("actualTwoCPU", evidence)
        self.assertNotIn("intelDynamic", evidence)
        self.assertEqual(evidence["requestedCPU"], "arm64")
        self.assertEqual({row["caseID"] for row in evidence["remote"]}, {"notarization", "staple", "gatekeeperCleanGUI"})
        self.assertFalse(evidence["storyDone"])
        self.assertEqual(evidence["p1"], "unverified")
        self.assertEqual(evidence["verdict"], "blocked")
        self.assertTrue(all(row["verdict"] == "blocked" for row in evidence["remote"]))

    def test_intel_cli_rejects_before_native_inspection_home_or_gui(self):
        with mock.patch.object(verify, "native_cpu") as native, mock.patch.object(verify, "command") as command, mock.patch.object(verify, "inspect_bundle") as inspect, mock.patch.object(verify, "current_home") as home, mock.patch.object(verify, "gui_run") as gui, contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit) as error:
                verify.main(["--arch", "x86_64", "--bundle", str(self.root), "--confirm-current-profile"])
            self.assertEqual(error.exception.code, 2)
            native.assert_not_called()
            command.assert_not_called()
            inspect.assert_not_called()
            home.assert_not_called()
            gui.assert_not_called()

    def test_native_cpu_rejects_intel_and_non_darwin_without_processes(self):
        for system, cpu in (("darwin", "x86_64"), ("linux", "arm64")):
            with self.subTest(system=system, cpu=cpu), mock.patch.object(verify.sys, "platform", system), mock.patch.object(verify.platform, "machine", return_value=cpu), mock.patch.object(verify, "command") as command:
                self.assertEqual(verify.native_cpu(), ("unknown", None))
                command.assert_not_called()

    def test_native_arm_cpu_requires_translation_proof_without_fallback(self):
        for status, output, expected in ((0, b"0\n", ("arm64", False)), (0, b"1\n", ("arm64", True)), (1, b"", ("unknown", None))):
            with self.subTest(status=status, output=output), mock.patch.object(verify.sys, "platform", "darwin"), mock.patch.object(verify.platform, "machine", return_value="arm64"), mock.patch.object(verify, "command", return_value=(status, output, b"")) as command:
                self.assertEqual(verify.native_cpu(), expected)
                command.assert_called_once_with(["/usr/sbin/sysctl", "-in", "sysctl.proc_translated"])
        with mock.patch.object(verify.sys, "platform", "darwin"), mock.patch.object(verify.platform, "machine", return_value="arm64"), mock.patch.object(verify, "command", return_value=(0, b"unknown", b"")) as command:
            with self.assertRaisesRegex(acquire.Failure, "invalid_rosetta_observation"):
                verify.native_cpu()
            self.assertEqual(command.call_count, 1)

    def test_rosetta_never_enables_synthetic_launch(self):
        output = io.StringIO()
        with mock.patch.object(verify, "native_cpu", return_value=("arm64", True)), mock.patch.object(verify, "command", return_value=(0, b"25A1", b"")), mock.patch.object(verify, "inspect_bundle"), mock.patch.object(verify, "current_home") as home, mock.patch.object(verify, "gui_run") as gui, contextlib.redirect_stdout(output):
            verify.main(["--arch", "arm64", "--bundle", str(self.root), "--confirm-current-profile"])
        home.assert_not_called()
        gui.assert_not_called()

    def test_removed_clean_profile_flag_has_no_alias(self):
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as error:
            verify.main(["--arch", "arm64", "--bundle", str(self.root), "--confirm-clean-profile"])
        self.assertEqual(error.exception.code, 2)

    def test_existing_report_is_untouched_and_does_not_block_new_namespace(self):
        report = self.root / "Library/Containers" / verify.IDENTITY / "Data/Library/Application Support/PaperLensTopology/report.json"
        report.parent.mkdir(parents=True)
        report.write_bytes(b"existing owner evidence")
        before = report.stat()
        with mock.patch.object(verify, "current_home", return_value=self.root), mock.patch.object(verify, "read_json") as read, mock.patch.object(verify, "Controls") as controls, mock.patch.object(verify, "GroupOwner") as owner, mock.patch.object(verify, "command") as launch:
            owner.return_value.start.side_effect = acquire.Failure("group_owner_fixture_unavailable")
            owner.return_value.finish.return_value = None
            with self.assertRaisesRegex(acquire.Failure, "group_owner_fixture_unavailable"):
                verify.gui_run(self.root / "PaperLens.app", verify.base_evidence("arm64"))
        read.assert_not_called()
        controls.return_value.start.assert_not_called()
        owner.return_value.start.assert_called_once()
        launch.assert_not_called()
        self.assertEqual(report.read_bytes(), b"existing owner evidence")
        after = report.stat()
        self.assertEqual((before.st_dev, before.st_ino, before.st_mode, before.st_mtime_ns), (after.st_dev, after.st_ino, after.st_mode, after.st_mtime_ns))

    def test_dangling_report_symlink_is_preserved(self):
        report = self.root / "Library/Containers" / verify.IDENTITY / "Data/Library/Application Support/PaperLensTopology/report.json"
        report.parent.mkdir(parents=True)
        report.symlink_to("missing-owner-report")
        with mock.patch.object(verify, "current_home", return_value=self.root), mock.patch.object(verify, "read_json") as read, mock.patch.object(verify, "GroupOwner") as owner, mock.patch.object(verify, "command") as launch:
            owner.return_value.start.side_effect = acquire.Failure("group_owner_fixture_unavailable")
            owner.return_value.finish.return_value = None
            with self.assertRaisesRegex(acquire.Failure, "group_owner_fixture_unavailable"):
                verify.gui_run(self.root, verify.base_evidence("arm64"))
        read.assert_not_called()
        launch.assert_not_called()
        self.assertEqual(os.readlink(report), "missing-owner-report")

    def test_wrong_profile_blocks_gui_and_real_container_access(self):
        output = io.StringIO()
        with mock.patch.object(verify, "native_cpu", return_value=("arm64", False)), mock.patch.object(verify, "command", return_value=(0, b"25A1", b"")) as commands, mock.patch.object(verify, "inspect_bundle"), mock.patch.object(verify, "current_home", side_effect=acquire.Failure("fixture_profile_mismatch")), mock.patch.object(verify, "gui_run") as gui, contextlib.redirect_stdout(output):
            status = verify.main(["--arch", "arm64", "--bundle", str(self.root / "PaperLens.app"), "--confirm-current-profile"])
        gui.assert_not_called()
        evidence = json.loads(output.getvalue())
        self.assertEqual(status, 2)
        self.assertEqual(evidence["verdict"], "blocked")
        self.assertFalse(evidence["storyDone"])
        self.assertTrue(any(item["reason"] == "fixture_profile_mismatch" for item in evidence["automated"]))
        self.assertTrue(all(item["verdict"] == "blocked" for item in evidence["remote"]))
        self.assertTrue(all(item["executionStatus"] == "unexecuted" for item in evidence["remote"]))
        self.assertEqual(commands.call_args_list, [mock.call(["/usr/bin/sw_vers", "-buildVersion"])])
        self.assertNotIn(str(self.root), output.getvalue())

    def test_tool_exception_is_sanitized(self):
        output = io.StringIO()
        with mock.patch.object(verify, "native_cpu", side_effect=OSError("/Users/private/secret-token")), contextlib.redirect_stdout(output):
            status = verify.main(["--arch", "arm64", "--bundle", str(self.root)])
        self.assertEqual(status, 2)
        self.assertNotIn("private", output.getvalue())
        self.assertNotIn("secret-token", output.getvalue())

    def test_errno_alone_and_untrusted_denial_ref_never_pass(self):
        run_id = "01234567-89ab-4cde-8fab-0123456789ab"
        report = self.report(verdict="pass", sandboxDenialRef="/private/log/secret")
        row = report["cases"][0]
        projected = verify.project_cases(report, run_id)[0]
        self.assertEqual(projected["verdict"], "blocked")
        self.assertIsNone(projected["sandboxDenialRef"])
        row["promptObserved"] = True
        self.assertEqual(verify.project_cases(report, run_id)[0]["verdict"], "blocked")

    def test_unsafe_report_alias_is_rejected(self):
        run_id = "01234567-89ab-4cde-8fab-0123456789ab"
        report = self.report(fixtureID="/Users/private")
        with self.assertRaisesRegex(acquire.Failure, "unsafe_fixture_alias"):
            verify.project_cases(report, run_id)

    def test_native_pdfium_blocked_is_preserved_without_runtime_dict(self):
        report = {"runtimeStatus": "blocked", "providerRuntimeStatus": "pass", "pdfiumRuntimeStatus": "blocked", "fixtureStatus": "blocked", "isolationVerdict": "inconclusive"}
        projected = {row["caseID"]: row for row in verify.project_statuses(report)}
        self.assertEqual(projected["providerInitialize"]["verdict"], "pass")
        self.assertEqual(projected["pdfiumInitialize"]["verdict"], "blocked")
        self.assertEqual(projected["runtimeInitialize"]["verdict"], "blocked")
        report["providerRuntimeStatus"] = "unknown"
        with self.assertRaisesRegex(acquire.Failure, "invalid_native_status"):
            verify.project_statuses(report)

    def test_control_owner_cannot_run_in_invalid_profile(self):
        with mock.patch.object(verify, "current_home", side_effect=acquire.Failure("fixture_profile_mismatch")), mock.patch.object(Path, "mkdir") as mkdir:
            with self.assertRaisesRegex(acquire.Failure, "fixture_profile_mismatch"):
                verify.Controls("01234567-89ab-4cde-8fab-0123456789ab")
        mkdir.assert_not_called()

    def test_existing_external_run_directory_is_preserved(self):
        run_id = "01234567-89ab-4cde-8fab-0123456789ab"
        directory = self.root / "Library/Application Support/PaperLensTopologyFixtureHost" / run_id
        directory.mkdir(parents=True)
        sentinel = directory / "external.canary"
        sentinel.write_bytes(b"prior invocation")
        before = sentinel.stat()
        with mock.patch.object(verify, "current_home", return_value=self.root), mock.patch.object(verify, "no_acl") as acl:
            control = verify.Controls(run_id)
            with self.assertRaises(FileExistsError):
                control.start()
        acl.assert_not_called()
        self.assertEqual(sentinel.read_bytes(), b"prior invocation")
        self.assertEqual(sentinel.stat().st_ino, before.st_ino)
        self.assertEqual(sentinel.stat().st_mode, before.st_mode)

    def test_external_replaced_inode_is_rejected_before_read_or_write(self):
        with mock.patch.object(verify, "current_home", return_value=self.root):
            control = verify.Controls("01234567-89ab-4cde-8fab-0123456789ab")
        control.path.parent.mkdir(parents=True)
        control.path.write_bytes(control.marker)
        metadata = control.path.stat()
        control.identity = (metadata.st_dev, metadata.st_ino + 1)
        with mock.patch.object(verify.os, "read") as read, mock.patch.object(verify.os, "write") as write:
            with self.assertRaisesRegex(acquire.Failure, "external_fixture_identity_changed"):
                control.check_external()
        read.assert_not_called()
        write.assert_not_called()


class LiveAttributionTests(IsolatedTest):
    run_id = "01234567-89ab-4cde-8fab-0123456789ab"
    contract_hash = "a" * 64

    def report(self, **changes):
        return EvidenceTests.report(self, **changes)

    def ready(self, phase="pre", worker=False):
        aliases = ("M", "A", "C", "E", "G") if worker else ("A", "C")
        roles = ("PDFiumXPC",) if worker else verify.ROLES
        return {"schemaRevision": verify.READINESS, "runID": self.run_id, "phase": phase,
                "contractHash": self.contract_hash, "clock": "darwin-uptime-ns", "ownerControl": True,
                "actors": [{"role": role, "pid": 100 + verify.ROLES.index(role)} for role in roles],
                "links": [{"alias": alias, "name": alias + ".link"} for alias in aliases], "intervals": []}

    def identities(self, candidates=None):
        candidates = self.ready()["actors"] if candidates is None else candidates
        names = {"Main": verify.IDENTITY, "ProviderAgent": verify.IDENTITY + ".ProviderAgent",
                 "Python": verify.IDENTITY + ".ProviderAgent.Python", "PDFiumXPC": verify.IDENTITY + ".PDFiumXPC"}
        return {"status": "verified", "timebase": {"numerator": 125, "denominator": 3},
                "actors": [{"role": a["role"], "pid": a["pid"], "parentPID": 101 if a["role"] == "Python" else 1,
                            "birthSec": 123, "birthUsec": 456, "codeIdentityRef": names[a["role"]], "verified": True} for a in candidates]}

    def observer(self):
        collector = mock.Mock()
        collector.finish.return_value = ([], verify.collection_state("timed-out", "collector-stop-before-eof"))
        patcher = mock.patch.object(verify, "OSCollector", return_value=collector)
        patcher.start()
        self.addCleanup(patcher.stop)
        bundle = self.root / "PaperLens.app"
        contract = bundle / "Contents/Resources/contract.json"
        contract.parent.mkdir(parents=True, exist_ok=True)
        contract.write_bytes(b"synthetic closed contract")
        controls = [mock.Mock(paths=verify.fixture_paths(self.root, self.run_id), rows={}),
                    mock.Mock(paths=verify.fixture_paths(self.root, self.run_id), rows={})]
        observer = verify.ReadinessObserver(self.root, self.run_id, bundle, "b" * 64, self.root / "helper", controls, mock.Mock(), mock.Mock())
        self.addCleanup(lambda: [os.close(d) for d, _ in observer.directories.values()])
        return observer

    def write_ready(self, observer, phase="pre", worker=False):
        path = observer.paths[1 if worker else 0]
        path.mkdir(mode=0o700, parents=True, exist_ok=True)
        os.chmod(path, 0o700)
        if not worker:
            os.chmod(path.parent, 0o700)
        ready = self.ready(phase, worker)
        ready["contractHash"] = observer.contract_hash
        filename = "ready.json" if phase == "pre" else "post-ready.json"
        data = json.dumps(ready).encode()
        with (path / filename).open("xb") as stream:
            os.fchmod(stream.fileno(), 0o600)
            stream.write(data)
        return path, data

    def bound_observer(self, report):
        identities = verify.actor_records(self.identities(), self.ready()["actors"])
        return mock.Mock(bindings=identities, post_bindings=identities,
                         intervals={row["caseID"]: {"caseID": row["caseID"], "beganAtNs": 10, "endedAtNs": 20} for row in report["cases"]},
                         controls=[mock.Mock(rows={}), mock.Mock(rows={})], owner_control={}, denials=[])

    def test_new_run_collision_shapes_preserve_every_file(self):
        for worker in (False, True):
            for shape in ("directory", "file", "symlink"):
                with self.subTest(worker=worker, shape=shape):
                    run = str(verify.uuid.uuid4())
                    path = verify.run_paths(self.root, run)[int(worker)]
                    path.parent.mkdir(parents=True, exist_ok=True)
                    if shape == "directory":
                        path.mkdir()
                        (path / "report.json").write_bytes(b"existing evidence")
                    elif shape == "file":
                        path.write_bytes(b"existing evidence")
                    else:
                        path.symlink_to("missing")
                    info = path.lstat()
                    with self.assertRaisesRegex(acquire.Failure, "existing_run_preserved"):
                        verify.collision_preflight(self.root, run)
                    self.assertEqual((info.st_dev, info.st_ino, info.st_mode, info.st_mtime_ns),
                                     (path.lstat().st_dev, path.lstat().st_ino, path.lstat().st_mode, path.lstat().st_mtime_ns))
                    if shape == "directory":
                        self.assertEqual((path / "report.json").read_bytes(), b"existing evidence")

    def test_same_run_collision_stops_before_owner_controls_compile_or_launch(self):
        path = verify.run_paths(self.root, self.run_id)[0]
        path.mkdir(parents=True)
        with mock.patch.object(verify, "current_home", return_value=self.root), mock.patch.object(verify.uuid, "uuid4", return_value=verify.uuid.UUID(self.run_id)), mock.patch.object(verify, "Controls") as controls, mock.patch.object(verify, "GroupOwner") as owner, mock.patch.object(verify, "compile_actor_helper") as compiler, mock.patch.object(verify, "command") as launch:
            with self.assertRaisesRegex(acquire.Failure, "existing_run_preserved"):
                verify.gui_run(self.root / "PaperLens.app", verify.base_evidence("arm64"))
        for action in (controls, owner, compiler, launch):
            action.assert_not_called()

    def test_phase_contract_is_closed_and_replay_and_bool_pid_fail(self):
        ready = self.ready()
        verify.ready_message(ready, self.run_id, "pre", self.contract_hash)
        for changes in ({"extra": "private"}, {"phase": "post"}, {"contractHash": "b" * 64}, {"runID": str(verify.uuid.uuid4())},
                        {"clock": "wall-clock"}, {"ownerControl": 1}, {"actors": [{"role": "PDFiumXPC", "pid": True}]},
                        {"links": [{"alias": "A", "name": "../A.link"}, {"alias": "C", "name": "C.link"}]},
                        {"intervals": [{"caseID": "mainCanaryRead", "beganAtNs": 20, "endedAtNs": 10}]}):
            with self.subTest(changes=changes), self.assertRaises(acquire.Failure):
                verify.ready_message(dict(ready, **changes), self.run_id, "pre", self.contract_hash)

    def test_worker_candidate_is_only_the_main_bound_worker(self):
        ready = self.ready(worker=True)
        verify.ready_message(ready, self.run_id, "pre", self.contract_hash, worker=True)
        records = verify.actor_records(self.identities(), self.ready()["actors"])
        worker = verify.actor_records(self.identities(ready["actors"]), ready["actors"])
        verify.same_generation({"PDFiumXPC": records["PDFiumXPC"]}, worker)
        worker["PDFiumXPC"]["pid"] += 1
        with self.assertRaisesRegex(acquire.Failure, "actor_generation_changed"):
            verify.same_generation({"PDFiumXPC": records["PDFiumXPC"]}, worker)

    def test_birth_reuse_parent_signature_and_unverified_identity_fail_closed(self):
        candidates = self.ready()["actors"]
        original = verify.actor_records(self.identities(), candidates)
        for field, replacement in (("parentPID", 999), ("codeIdentityRef", verify.IDENTITY + ".ProviderAgent.PythonRuntime"), ("verified", False), ("pid", True), ("birthUsec", 1_000_000)):
            response = self.identities()
            python = next(a for a in response["actors"] if a["role"] == "Python")
            python[field] = replacement
            with self.subTest(field=field), self.assertRaises(acquire.Failure):
                verify.actor_records(response, candidates)
        changed = verify.actor_records(self.identities(), candidates)
        changed["Python"]["birthSec"] += 1
        with self.assertRaisesRegex(acquire.Failure, "actor_generation_changed"):
            verify.same_generation(original, changed)

    def test_ack_hashes_exact_bytes_and_controls_precede_release(self):
        observer = self.observer()
        path, data = self.write_ready(observer)
        records = verify.actor_records(self.identities(), self.ready()["actors"])
        with mock.patch.object(verify, "no_acl", return_value=True), mock.patch.object(observer, "query", return_value=records):
            observer.controls[0].observe.side_effect = lambda *args: self.assertFalse((path / "continue.json").exists())
            verify.OSCollector.return_value.start.side_effect = lambda: self.assertFalse((path / "continue.json").exists())
            observer.poll()
        verify.OSCollector.assert_called_once()
        self.assertEqual(set(verify.OSCollector.call_args.args[0]), set(verify.ROLES))
        observer.collector.start.assert_called_once()
        ack = json.loads((path / "continue.json").read_bytes())
        self.assertEqual(set(ack), {"schemaRevision", "runID", "phase", "readyHash", "artifactHash"})
        self.assertEqual(ack["readyHash"], hashlib.sha256(data).hexdigest())
        self.assertEqual(ack["artifactHash"], "b" * 64)
        self.assertEqual(stat.S_IMODE((path / "continue.json").stat().st_mode), 0o600)
        observer.withdraw()
        self.assertTrue((path / "continue.json").exists())  # Ready still owned by native.
        (path / "ready.json").unlink()
        observer.withdraw()
        self.assertFalse((path / "continue.json").exists())
        self.assertTrue(path.is_dir())

    def test_ack_is_invisible_until_complete_exclusive_publication(self):
        observer = self.observer()
        path, data = self.write_ready(observer)
        records = verify.actor_records(self.identities(), self.ready()["actors"])
        original_write = os.write
        def partial_write(descriptor, payload):
            self.assertFalse((path / "continue.json").exists())
            return original_write(descriptor, payload[:1])
        with mock.patch.object(verify, "no_acl", return_value=True), mock.patch.object(observer, "query", return_value=records), mock.patch.object(verify.os, "write", side_effect=partial_write):
            observer.poll()
        ack = json.loads((path / "continue.json").read_bytes())
        self.assertEqual(ack["readyHash"], hashlib.sha256(data).hexdigest())
        self.assertEqual((path / "continue.json").stat().st_nlink, 1)
        self.assertEqual({p.name for p in path.iterdir()}, {"ready.json", "continue.json"})

    def test_ack_replacement_is_preserved_and_replay_not_adopted(self):
        observer = self.observer()
        path, _ = self.write_ready(observer)
        records = verify.actor_records(self.identities(), self.ready()["actors"])
        with mock.patch.object(verify, "no_acl", return_value=True), mock.patch.object(observer, "query", return_value=records):
            observer.poll()
        ack = path / "continue.json"
        ack.rename(path / "held-owned-ack")  # Hold old inode so reuse cannot hide replacement.
        ack.write_bytes(b"other owner")
        (path / "ready.json").unlink()
        with self.assertRaisesRegex(acquire.Failure, "ack_inode_replaced"):
            observer.withdraw()
        self.assertEqual(ack.read_bytes(), b"other owner")
        self.assertTrue((path / "held-owned-ack").exists())

    def test_ready_replacement_and_parent_permissions_fail_without_adoption(self):
        observer = self.observer()
        path, _ = self.write_ready(observer)
        records = verify.actor_records(self.identities(), self.ready()["actors"])
        with mock.patch.object(verify, "no_acl", return_value=True), mock.patch.object(observer, "query", return_value=records):
            path.parent.chmod(0o755)
            with self.assertRaisesRegex(acquire.Failure, "unsafe_live_inode"):
                observer.poll()
            self.assertFalse((path / "continue.json").exists())
            path.parent.chmod(0o700)
            observer.poll()
        (path / "ready.json").rename(path / "held-ready")
        (path / "ready.json").write_bytes(b"replacement")
        with self.assertRaisesRegex(acquire.Failure, "readiness_inode_replaced"):
            observer.withdraw()
        self.assertTrue((path / "continue.json").exists())
        self.assertEqual((path / "ready.json").read_bytes(), b"replacement")

    def test_post_controls_owner_and_generation_checks_precede_main_ack(self):
        observer = self.observer()
        path, _ = self.write_ready(observer)
        records = verify.actor_records(self.identities(), self.ready()["actors"])
        with mock.patch.object(verify, "no_acl", return_value=True), mock.patch.object(observer, "query", return_value=records):
            observer.poll()
            (path / "ready.json").unlink()
            observer.withdraw()
            self.write_ready(observer, phase="post")
            observer.controls[0].observe.side_effect = lambda *args: self.assertFalse((path / "post-continue.json").exists())
            observer.external.finish.side_effect = lambda: self.assertFalse((path / "post-continue.json").exists())
            observer.owner.finish.side_effect = lambda **kwargs: self.assertFalse((path / "post-continue.json").exists())
            observer.poll()
        observer.external.finish.assert_called_once()
        observer.owner.finish.assert_called_once()
        observer.collector.finish.assert_not_called()
        self.assertTrue(observer.collector.lifecycle_complete)
        self.assertTrue((path / "post-continue.json").exists())

    def tail_report(self):
        observer = self.observer()
        path = observer.paths[0]
        path.mkdir(parents=True, mode=0o700)
        report = self.report()
        report["runID"] = self.run_id
        data = json.dumps(report).encode()
        file = path / "report.json"
        file.write_bytes(data)
        file.chmod(0o600)
        directory = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
        self.addCleanup(os.close, directory)
        observer.deadline = time.monotonic() + 230
        observer.done = {(0, "pre"), (0, "post"), (1, "pre"), (1, "post")}
        bound = self.bound_observer(report)
        observer.bindings, observer.post_bindings, observer.intervals = bound.bindings, bound.post_bindings, bound.intervals
        observer.collector = verify.OSCollector.return_value
        observer.collector.deadline = observer.deadline - 5
        observer.collector.failure = None
        observer.collector.process.poll.return_value = None
        observer.collector.selector.get_map.return_value = {1: "stdout", 2: "stderr"}
        return observer, directory, data, file.stat(), report, file

    def test_matching_report_waits_for_withdrawal_then_delayed_two_pipe_eof(self):
        observer, directory, data, info, report, file = self.tail_report()
        observer.pending[(0, "post")] = "owned ack"
        def withdraw():
            observer.pending.clear()
        def drain():
            self.assertFalse(observer.pending)
            observer.collector.process.poll.return_value = 0
            observer.collector.selector.get_map.return_value = {2: "stderr"} if observer.collector.drain.call_count == 1 else {}
        observer.collector.drain.side_effect = drain
        with mock.patch.object(verify, "no_acl", return_value=True), mock.patch.object(observer, "poll", side_effect=withdraw) as poll:
            observer.tail(directory, data, info, report)
        poll.assert_called_once()
        self.assertEqual(observer.collector.drain.call_count, 2)
        observer.collector.finish.assert_called_once_with(observer.intervals, observer.deadline)
        self.assertEqual(file.read_bytes(), data)
        self.assertEqual(file.stat().st_ino, info.st_ino)
        self.assertEqual(observer.bindings, observer.post_bindings)

    def test_tail_preserves_replaced_report_and_rejects_changed_bytes(self):
        for replacement in (False, True):
            with self.subTest(replacement=replacement):
                # A fresh synthetic namespace for each case, never an old report.
                self.run_id = str(verify.uuid.uuid4())
                observer, directory, data, info, report, file = self.tail_report()
                def change():
                    if replacement:
                        file.rename(file.parent / "held-report")
                    file.write_bytes(b"other evidence")
                    file.chmod(0o600)
                observer.collector.drain.side_effect = change
                with mock.patch.object(verify, "no_acl", return_value=True), self.assertRaisesRegex(acquire.Failure, "report_(inode_replaced|bytes_changed)"):
                    observer.tail(directory, data, info, report)
                observer.collector.finish.assert_not_called()
                self.assertEqual(file.read_bytes(), b"other evidence")
                if replacement:
                    self.assertEqual((file.parent / "held-report").read_bytes(), data)

    def test_tail_rejects_incomplete_release_before_waiting_for_eof(self):
        observer, directory, data, info, report, _ = self.tail_report()
        observer.done.remove((1, "post"))
        with mock.patch.object(verify, "no_acl", return_value=True), self.assertRaisesRegex(acquire.Failure, "report_lifecycle_incomplete"):
            observer.tail(directory, data, info, report)
        observer.collector.drain.assert_not_called()
        observer.collector.finish.assert_not_called()

    def test_tail_ack_timeout_does_not_start_natural_wait(self):
        observer, directory, data, info, report, _ = self.tail_report()
        observer.pending[(0, "post")] = "unconsumed ack"
        with mock.patch.object(verify, "no_acl", return_value=True), mock.patch.object(observer, "poll", side_effect=acquire.Failure("ack_consumption_timeout")), self.assertRaisesRegex(acquire.Failure, "ack_consumption_timeout"):
            observer.tail(directory, data, info, report)
        observer.collector.drain.assert_not_called()
        observer.collector.finish.assert_not_called()

    def test_tail_target_budget_does_not_extend_observer_or_invent_eof(self):
        observer, directory, data, info, report, _ = self.tail_report()
        observer.deadline, observer.collector.deadline = 330.0, 325.0
        with mock.patch.object(verify, "no_acl", return_value=True), mock.patch.object(verify.time, "monotonic", return_value=325.0), mock.patch.object(verify.time, "sleep") as sleep:
            observer.tail(directory, data, info, report)
        observer.collector.drain.assert_not_called()
        observer.collector.finish.assert_called_once_with(observer.intervals, 330.0)
        sleep.assert_not_called()
        self.assertFalse(observer.os_collection["queryCompleted"])
        self.assertEqual(observer.deadline, 330.0)

    def test_tail_source_failure_stops_before_deadline_without_discarding_report(self):
        observer, directory, data, info, report, file = self.tail_report()
        observer.collector.failure = ("truncated", "raw-limit")
        observer.collector.finish.return_value = ([], verify.collection_state("truncated", "raw-limit"))
        with mock.patch.object(verify, "no_acl", return_value=True), mock.patch.object(verify.time, "sleep") as sleep:
            observer.tail(directory, data, info, report)
        observer.collector.drain.assert_not_called()
        sleep.assert_not_called()
        self.assertEqual(observer.os_collection["reason"], "raw-limit")
        self.assertFalse(observer.os_collection["queryCompleted"])
        self.assertEqual(file.read_bytes(), data)

    def test_existing_ack_is_not_overwritten(self):
        observer = self.observer()
        path, _ = self.write_ready(observer)
        (path / "continue.json").write_bytes(b"existing ack")
        records = verify.actor_records(self.identities(), self.ready()["actors"])
        with mock.patch.object(verify, "no_acl", return_value=True), mock.patch.object(observer, "query", return_value=records), self.assertRaises(FileExistsError):
            observer.poll()
        self.assertEqual((path / "continue.json").read_bytes(), b"existing ack")

    def test_ready_inode_modes_hardlinks_acl_and_size_are_rejected(self):
        directory = self.root / "private"
        directory.mkdir(mode=0o700)
        path = directory / "ready.json"
        path.write_bytes(b"{}")
        descriptor = os.open(directory, os.O_RDONLY | os.O_DIRECTORY)
        self.addCleanup(os.close, descriptor)
        with mock.patch.object(verify, "no_acl", return_value=True):
            path.chmod(0o644)
            with self.assertRaisesRegex(acquire.Failure, "unsafe_live_inode"):
                verify.read_at(descriptor, "ready.json", 65536)
            path.chmod(0o600)
            os.link(path, directory / "held")
            with self.assertRaisesRegex(acquire.Failure, "unsafe_live_inode"):
                verify.read_at(descriptor, "ready.json", 65536)
            (directory / "held").unlink()
            path.write_bytes(b"x" * 65537)
            with self.assertRaisesRegex(acquire.Failure, "evidence_size_limit"):
                verify.read_at(descriptor, "ready.json", 65536)
        with mock.patch.object(verify, "no_acl", return_value=False), self.assertRaisesRegex(acquire.Failure, "unsafe_live_inode"):
            verify.read_at(descriptor, "ready.json", 65536)

    def fixture_control(self):
        path = self.root / "private/marker"
        path.parent.mkdir(mode=0o700)
        path.write_bytes(b"PaperLens topology canary\n")
        path.chmod(0o600)
        control = verify.LiveControls({"M": path})
        self.addCleanup(control.close)
        return control, path

    def test_fixture_fd_control_checks_marker_before_unchanged_first_byte(self):
        control, path = self.fixture_control()
        original = path.read_bytes()
        real_pwrite = os.pwrite
        writes = []
        def write(descriptor, data, offset):
            writes.append((data, offset))
            return real_pwrite(descriptor, data, offset)
        with mock.patch.object(verify, "no_acl", return_value=True), mock.patch.object(verify.os, "pwrite", side_effect=write):
            self.assertTrue(control.file("M", "pre"))
            self.assertTrue(control.file("M", "post"))
        self.assertEqual(writes, [(original[:1], 0), (original[:1], 0)])
        self.assertEqual(path.read_bytes(), original)

    def test_replaced_fixture_bad_marker_and_acl_never_get_written(self):
        control, path = self.fixture_control()
        with mock.patch.object(verify, "no_acl", return_value=True):
            control.file("M", "pre")
            path.rename(path.with_name("held"))
            path.write_bytes(b"PaperLens topology canary\n")
            path.chmod(0o600)
            with mock.patch.object(verify.os, "pwrite") as write, self.assertRaisesRegex(acquire.Failure, "fixture_generation_changed"):
                control.file("M", "post")
            write.assert_not_called()
            path.write_bytes(b"private, not a public marker")
            with mock.patch.object(verify.os, "pwrite") as write, self.assertRaisesRegex(acquire.Failure, "fixture_marker_unproven"):
                control.file("M", "post")
            write.assert_not_called()
        with mock.patch.object(verify, "no_acl", return_value=False), mock.patch.object(verify.os, "pwrite") as write, self.assertRaisesRegex(acquire.Failure, "unsafe_live_inode"):
            control.file("M", "post")
        write.assert_not_called()

    def test_fixed_link_controls_reject_other_target_and_reused_owner_root(self):
        control, target = self.fixture_control()
        links = self.root / "links"
        links.mkdir(mode=0o700)
        link = links / "M.link"
        link.symlink_to(target)
        with mock.patch.object(verify, "no_acl", return_value=True):
            self.assertTrue(control.link(links, "M", "Python", "pre"))
            link.rename(links / "held-link")
            link.symlink_to(self.root / "real-data")
            with self.assertRaisesRegex(acquire.Failure, "fixture_link_unproven"):
                control.link(links, "M", "Python", "post")
            link.unlink()
            link.symlink_to(target)
            with self.assertRaisesRegex(acquire.Failure, "fixture_generation_changed"):
                control.link(links, "M", "Python", "post")

    def test_false_observed_missing_binding_and_ref_mismatch_cannot_pass(self):
        report = self.report(syscallObserved=False, syscallResult=0, errno=0, verdict="pass")
        observer = self.bound_observer(report)
        self.assertEqual(verify.project_cases(report, self.run_id, observer)[0]["verdict"], "inconclusive")
        self.assertEqual(verify.project_cases(report, self.run_id)[0]["verdict"], "blocked")
        for changes, reason in (({"intervalRef": "other"}, "report_interval_join_mismatch"),
                                ({"actorInstanceRef": "actor-" + str(verify.uuid.uuid4())}, "report_actor_join_mismatch"),
                                ({"errno": True}, "invalid_report_syscall"), ({"syscallResult": 2**31}, "invalid_report_syscall"),
                                ({"beganAtNs": 1}, "raw_report_metadata"), ({"operation": "bind"}, "report_operation_join_mismatch")):
            bad = self.report(**changes)
            with self.subTest(changes=changes), self.assertRaisesRegex(acquire.Failure, reason):
                verify.project_cases(bad, self.run_id)

    def test_same_uid_controls_do_not_prove_tcc_or_prompt_absence(self):
        report = self.report(verdict="pass", promptObserved=False)
        observer = self.bound_observer(report)
        observer.controls[0].rows = {("Main", "M", "file"): {"preVerified": True, "postVerified": True}}
        row = verify.project_cases(report, self.run_id, observer)[0]
        self.assertTrue(row["sameUIDControl"])
        self.assertTrue(row["posixACLControl"])
        self.assertEqual(row["promptObserved"], "unverified")
        self.assertEqual(row["verdict"], "inconclusive")

    def test_forbidden_success_fails_and_safe_final_projection_has_no_raw_metadata(self):
        report = self.report(syscallResult=1, errno=0, verdict="pass", sandboxDenialRef="/Users/private/log")
        observer = self.bound_observer(report)
        evidence = verify.base_evidence("arm64")
        evidence["cases"] = verify.project_cases(report, self.run_id, observer, evidence)
        self.assertEqual(evidence["cases"][0]["verdict"], "failed")
        encoded = json.dumps(evidence)
        for forbidden in ("/Users/", "birthSec", "birthUsec", "parentPID", "beganAtNs", "endedAtNs", '"pid"'):
            self.assertNotIn(forbidden, encoded)
        self.assertIsNone(evidence["cases"][0]["sandboxDenialRef"])
        self.assertTrue(evidence["cases"][0]["intervalRef"].startswith("interval-"))

    def test_positive_pdf_descriptor_capabilities_are_not_sandbox_pass(self):
        for operation, value, code in (("descriptorRead", len(verify.synthetic_pdf()), 0), ("descriptorWrite", -1, errno.EBADF)):
            report = self.report(caseID="PDFiumXPC.PDF." + operation, intervalRef="PDFiumXPC.PDF." + operation,
                                 operation=operation, fixtureID="PDF", syscallResult=value, errno=code, verdict="pass")
            report["cases"][0]["actorInstanceRef"] = next(a["actorInstanceRef"] for a in report["actorBindings"] if a["role"] == "PDFiumXPC")
            evidence = verify.base_evidence("arm64")
            observer = self.bound_observer(report)
            observer.controls[1].rows = {("PDFiumXPC", "PDF", "file"): {
                "controlRef": "control-" + str(verify.uuid.uuid4()), "role": "PDFiumXPC", "alias": "PDF",
                "operation": "readWrite", "preVerified": True, "postVerified": True, "reason": "same-uid-not-tcc-proof"}}
            rows = verify.project_cases(report, self.run_id, observer, evidence)
            self.assertEqual(rows[0]["verdict"], "inconclusive")
            self.assertEqual(evidence["automated"][-1]["verdict"], "pass")
            self.assertEqual(evidence["automated"][-1]["reason"], "descriptor-capability-not-sandbox-proof")

    def test_duplicate_denials_keep_distinct_refs_after_final_actor_join(self):
        report = self.report()
        observer = self.bound_observer(report)
        paths = verify.fixture_paths(self.root, self.run_id)
        event = {"subsystem": "com.apple.sandbox.reporting", "category": "violation", "processID": 0,
                 "eventMessage": f"Sandbox: Python(102) deny(1) file-read-data {paths['M']}"}
        observer.denials = verify.safe_denial_projection([event, event], observer.bindings, paths, observer.intervals)
        evidence = verify.base_evidence("arm64")
        verify.project_cases(report, self.run_id, observer, evidence)
        self.assertEqual(len(evidence["denials"]), 2)
        self.assertEqual(len({row["denialRef"] for row in evidence["denials"]}), 2)
        self.assertEqual(evidence["denials"][0]["actorInstanceRef"], evidence["denials"][1]["actorInstanceRef"])
        self.assertTrue(all(not row["attributed"] and not row["clockVerified"] for row in evidence["denials"]))
        self.assertNotIn(str(self.root), json.dumps(evidence))

    def test_clock_ambiguity_and_network_actual_stage_are_not_promoted(self):
        bindings = verify.actor_records(self.identities(), self.ready()["actors"])
        paths = verify.fixture_paths(self.root, self.run_id)
        file_event = {"subsystem": "com.apple.sandbox.reporting", "category": "violation", "processID": 102, "eventMessage": f"Sandbox: Python(102) deny(1) file-read-data {paths['M']}", "machTimestamp": 10}
        bind_event = {"subsystem": "com.apple.sandbox.reporting", "category": "violation", "processID": 102, "eventMessage": "Sandbox: Python(102) deny(1) network-bind 127.0.0.1:18766"}
        rows = verify.safe_denial_projection([file_event, file_event, bind_event], bindings, paths, {"mainCanaryRead": {"beganAtNs": 10, "endedAtNs": 20}})
        self.assertEqual(len(rows), 3)
        self.assertEqual(len({row["denialRef"] for row in rows}), 3)
        self.assertEqual({row["operation"] for row in rows}, {"read", "bind"})
        self.assertTrue(all(not row["attributed"] and row["reason"] == "clock-unproven" for row in rows))
        self.assertNotIn("listen", {row["operation"] for row in rows})
        encoded = json.dumps(rows)
        self.assertNotIn(str(self.root), encoded)
        self.assertNotIn("machTimestamp", encoded)
        wrong = dict(file_event, processID=103)
        boolean = dict(file_event, processID=True)
        escaped = dict(file_event, eventMessage=file_event["eventMessage"] + "/../real")
        self.assertEqual(verify.safe_denial_projection([wrong, boolean, escaped], bindings, paths, {}), [])

    def test_kernel_logger_pid_is_not_the_denied_process_pid(self):
        bindings = verify.actor_records(self.identities(), self.ready()["actors"])
        paths = verify.fixture_paths(self.root, self.run_id)
        event = {"subsystem": "com.apple.sandbox.reporting", "category": "violation", "processID": 0, "eventMessage": f"Sandbox: Python(102) deny(1) file-write-data {paths['M']}"}
        rows = verify.safe_denial_projection([event], bindings, paths, {})
        self.assertEqual(len(rows), 1)
        self.assertEqual((rows[0]["role"], rows[0]["alias"], rows[0]["operation"]), ("Python", "M", "write"))
        self.assertFalse(rows[0]["attributed"])
        unknown = dict(event, eventMessage=event["eventMessage"].replace("(102)", "(999)"))
        self.assertEqual(verify.safe_denial_projection([unknown], bindings, paths, {}), [])

    def test_historical_native_schema_has_no_reader_fallback(self):
        report = self.report()
        report["schemaRevision"] = "topology-v1"
        with self.assertRaisesRegex(acquire.Failure, "stale_or_invalid_report"):
            verify.project_cases(report, self.run_id)

    def test_bounded_query_refuses_expired_deadline_before_start(self):
        with mock.patch.object(verify.subprocess, "Popen") as launch, self.assertRaisesRegex(acquire.Failure, "evidence_query_timeout"):
            verify.bounded_query(["never-run"], time.monotonic() - 1)
        launch.assert_not_called()

    def test_bounded_query_limits_output_and_kills_only_owned_query(self):
        read_fd, write_fd = os.pipe()
        error_read, error_write = os.pipe()
        reader = os.fdopen(read_fd, "rb", buffering=0)
        errors = os.fdopen(error_read, "rb", buffering=0)
        with os.fdopen(write_fd, "wb", buffering=0) as writer:
            writer.write(b"x" * 4097)
        os.close(error_write)
        process = mock.Mock(stdout=reader, stderr=errors, stdin=None)
        process.poll.return_value = None
        with mock.patch.object(verify.subprocess, "Popen", return_value=process) as launch, self.assertRaisesRegex(acquire.Failure, "evidence_query_limit"):
            verify.bounded_query(["owned-query-only"], time.monotonic() + 1, maximum=4096)
        process.kill.assert_called_once()
        process.wait.assert_called_once_with(timeout=2)
        self.assertTrue(reader.closed)
        self.assertTrue(errors.closed)
        self.assertEqual(launch.call_args.args[0], ["owned-query-only"])

    def test_os_query_is_known_pid_fixed_target_and_operation_scoped(self):
        bindings = verify.actor_records(self.identities(), self.ready()["actors"])
        paths = verify.fixture_paths(self.root, self.run_id)
        predicate = verify.collector_predicate(bindings, paths)
        self.assertIn('subsystem == "com.apple.sandbox.reporting"', predicate)
        self.assertIn('category == "violation"', predicate)
        for pid in (100, 101, 102, 103):
            self.assertIn(f"processIdentifier == {pid}", predicate)
        self.assertIn("composedMessage CONTAINS", predicate)
        self.assertNotIn("processID ==", predicate)
        self.assertNotIn("eventMessage CONTAINS", predicate)
        self.assertIn(self.run_id, predicate)
        self.assertIn("file-write-data", predicate)
        self.assertIn("network-bind", predicate)
        self.assertNotIn("process ==", predicate)


class OSCollectionTests(IsolatedTest):
    run_id = "01234567-89ab-4cde-8fab-0123456789ab"

    def collector(self):
        bindings = {role: {"pid": 100 + index} for index, role in enumerate(verify.ROLES)}
        collector = verify.OSCollector(bindings, verify.fixture_paths(self.root, self.run_id))
        self.addCleanup(lambda: collector.finish({}))
        return collector

    def event(self, collector, stage="file-write-data", multiline=False):
        denial = f"deny(1) {stage} {collector.paths['M']}"
        message = f"Sandbox: Python(102) {denial}"
        if multiline:
            message += f"\nViolation: {denial}\nProcess: Python [102]"
        return {"subsystem": "com.apple.sandbox.reporting", "category": "violation", "processID": 0,
                "eventMessage": message}

    def ended_process(self, collector, code=0):
        # Pure mocks: no subprocesses, logging or real OS records.
        process = mock.Mock(stdout=mock.Mock(), stderr=mock.Mock())
        process.poll.return_value = code
        process.wait.return_value = code
        collector.process = process
        collector.lifecycle_complete = True  # Model completed Mainpost checks.
        collector.selector.close()
        collector.selector = mock.Mock()
        collector.selector.get_map.return_value = {}
        collector.selector.select.return_value = []
        return process

    def test_documented_multiline_crosschecks_and_single_line(self):
        collector = self.collector()
        for multiline in (False, True):
            row = verify.denial_candidate(self.event(collector, multiline=multiline), collector.bindings, collector.paths, {})
            self.assertEqual((row["role"], row["alias"], row["operation"]), ("Python", "M", "write"))
            self.assertTrue(row["producerVerified"] and row["targetVerified"])
            self.assertFalse(row["clockVerified"] or row["attributed"])
            self.assertEqual(row["caseAssociation"], "unverified")
        event = self.event(collector, multiline=True)
        for message in (event["eventMessage"].replace("Process: Python [102]", "Process: Other [102]"),
                        event["eventMessage"].replace("[102]", "[103]"),
                        event["eventMessage"].replace("Violation: deny(1) file-write-data", "Violation: deny(1) file-read-data"),
                        "Sandbox: Python(102)", event["eventMessage"] + "\nUnknown Field: private",
                        event["eventMessage"].replace("file-write-data", "file-write-create")):
            with self.subTest(message=message), self.assertRaises(acquire.Failure):
                verify.denial_candidate(dict(event, eventMessage=message), collector.bindings, collector.paths, {})

    def test_rich_aligned_apple_record_is_checked_and_diagnostics_are_ram_only(self):
        collector = self.collector()
        event = self.event(collector)
        event["eventMessage"] += (f"\n\nViolation:       deny(1) file-write-data {collector.paths['M']}"
                                 "\nProcess:         Python [102]\nPath:            /synthetic/private/Python"
                                 "\nIdentifier:      synthetic.python\nVersion:         1.0 (1)"
                                 "\nCode Type:       arm64 (Native)\nLoad Address:    0x0000000100000000"
                                 "\nParent Process:  Agent [101]\nResponsible:     /synthetic/private/SampleApp"
                                 "\nUser ID:         501\n\nThread 0 (id: 551548):"
                                 "\n0 libsystem_kernel.dylib 0x0000000000001234 synthetic_call + 8"
                                 "\n1 synthetic.dylib 0x0000000000005678 synthetic_entry + 16")
        for code_type in ("arm64", "x86_64", "ARM-64", "X86-64"):
            candidate = verify.denial_candidate(dict(event, eventMessage=event["eventMessage"].replace("arm64 (Native)", code_type + " (Native)")),
                                                collector.bindings, collector.paths, {})
            self.assertTrue(candidate["producerVerified"])
            self.assertFalse(candidate["clockVerified"])
        collector.feed(json.dumps(event).encode() + b"\n")
        self.assertIsNone(collector.failure)
        self.ended_process(collector)
        rows, state = collector.finish({})
        self.assertEqual(state["status"], "complete-nonempty")
        self.assertEqual(rows[0]["operation"], "write")
        for private in ("synthetic_call", "/synthetic/private", "Thread", "Load Address", "User ID"):
            self.assertNotIn(private, json.dumps(rows))
        for change in (event["eventMessage"].replace("Python [102]", "Python [103]"),
                       event["eventMessage"] + "\nprivate free text",
                       event["eventMessage"].replace("1 synthetic.dylib", "2 synthetic.dylib"),
                       event["eventMessage"].replace("User ID:         501", "User ID:         private"),
                       event["eventMessage"].replace("0x0000000100000000", "0xnothex"),
                       event["eventMessage"].replace("Thread 0 (id: 551548):", "Thread 0 (id: unknown):"),
                       event["eventMessage"].replace("Thread 0 (id: 551548):", "Thread 2147483648 (id: 551548):"),
                       event["eventMessage"].replace("/synthetic/private/SampleApp", "relative/SampleApp"),
                       event["eventMessage"] + "\n[…]", event["eventMessage"] + "\n[...]"):
            with self.assertRaises(acquire.Failure):
                verify.denial_candidate(dict(event, eventMessage=change),
                                        {role: {"pid": 100 + i} for i, role in enumerate(verify.ROLES)},
                                        verify.fixture_paths(self.root, self.run_id), {})

    def test_owned_header_and_blank_separators_are_exact_and_byte_counted(self):
        collector = self.collector()
        data = collector.expected_header + b"\n\n" + json.dumps(self.event(collector)).encode() + b"\n"
        collector.feed(data)
        self.assertEqual(collector.total, len(data))
        self.assertEqual(len(collector.events), 1)
        self.ended_process(collector)
        self.assertEqual(collector.finish({})[1]["status"], "complete-nonempty")
        collector = self.collector()
        collector.feed(b"\n\n")
        self.ended_process(collector)
        self.assertEqual(collector.finish({})[1]["status"], "complete-empty")
        for banner in (b'Filtering the log data using "TRUEPREDICATE"\n', b"unexpected banner\n", b" \n"):
            collector = self.collector()
            collector.feed(banner)
            self.assertEqual(collector.failure, ("invalid", "parser-input-invalid"))

    def test_reformatted_owned_predicate_header_requires_exact_semantic_filter(self):
        collector = self.collector()
        predicate = verify.collector_predicate(collector.bindings, collector.paths)
        variants = [" ( " + predicate + " ) ",
                    predicate.replace(" == ", " = ").replace(" AND ", " && ").replace(" OR ", " || "),
                    predicate.replace("processIdentifier == 0 OR processIdentifier == 100 OR processIdentifier == 101",
                                      "(processIdentifier == 101 OR processIdentifier == 100) OR (processIdentifier == 0)"),
                    predicate.replace("subsystem ==", "(subsystem ==").replace('"com.apple.sandbox.reporting" AND',
                                                                                 '"com.apple.sandbox.reporting") AND'),
                    predicate.replace("sandbox.reporting", "sandbox\\u002ereporting")]
        for rendered in variants:
            current = self.collector()
            header = ('Filtering the log data using "' + rendered + '"\n').encode()
            current.feed(header + json.dumps(self.event(current)).encode() + b"\n")
            self.assertIsNone(current.failure)
            self.assertEqual(len(current.events), 1)
            self.assertEqual(current.total, len(header) + len(json.dumps(self.event(current)).encode()) + 1)
        invalid = [predicate.replace("processIdentifier == 100", "processIdentifier == 999"),
                   predicate.replace("127.0.0.1:18766", "127.0.0.1:18767"),
                   predicate.replace(" AND ", " OR ", 1),
                   predicate.replace("CONTAINS", "BEGINSWITH"),
                   predicate.replace("processIdentifier == 0 OR", "processIdentifier == 0 AND", 1),
                   predicate + ' OR processIdentifier == 999', predicate[:-1],
                   predicate + ' AND composedMessage CONTAINS "unapproved"',
                   predicate.replace("processIdentifier", "processID"),
                   predicate.replace("composedMessage", "eventMessage"),
                   predicate.replace("category ==", "unknown =="),
                   "(" * 65 + predicate + ")" * 65]
        for rendered in invalid:
            current = self.collector()
            current.feed(('Filtering the log data using "' + rendered + '"\n').encode())
            self.assertEqual(current.failure, ("invalid", "parser-input-invalid"))

    def test_unknown_producer_subject_and_targets_are_not_candidates(self):
        collector = self.collector()
        event = self.event(collector)
        for changes in ({"subsystem": "unknown"}, {"category": "debug"}, {"processID": 103}, {"processID": True}, {"truncated": True},
                        {"eventMessage": event["eventMessage"].replace("(102)", "(999)")},
                        {"eventMessage": event["eventMessage"] + "/private"},
                        {"eventMessage": "Sandbox: Python(102) deny(1) network-bind 127.0.0.1:18765"}):
            self.assertEqual(verify.safe_denial_projection([dict(event, **changes)], collector.bindings, collector.paths, {}), [])
        missing = dict(event)
        del missing["subsystem"]
        self.assertEqual(verify.safe_denial_projection([missing], collector.bindings, collector.paths, {}), [])

    def test_clock_epochs_and_overlapping_reads_do_not_create_unique_proof(self):
        collector = self.collector()
        events = [dict(self.event(collector, "file-read-data"), machTimestamp=stamp, timestamp="untrusted date")
                  for stamp in (10, 10**18, 1.25)]
        intervals = {"mainCanaryRead": {"beganAtNs": 10, "endedAtNs": 20},
                     "mainCanarySymlinkRead": {"beganAtNs": 10, "endedAtNs": 20}}
        rows = verify.safe_denial_projection(events, collector.bindings, collector.paths, intervals)
        self.assertEqual(len(rows), 3)
        self.assertTrue(all(row["caseAssociation"] == "ambiguous" and not row["clockVerified"] and not row["attributed"] for row in rows))
        for forbidden in ("machTimestamp", "timestamp", str(self.root), "processID", "Python(102)"):
            self.assertNotIn(forbidden, json.dumps(rows))

    def test_ndjson_partial_record_then_eof_is_invalid_not_empty(self):
        collector = self.collector()
        encoded = json.dumps(self.event(collector)).encode()
        collector.feed(encoded[:20])
        self.assertEqual(collector.events, [])
        collector.feed(encoded[20:] + b"\n")
        self.assertEqual(len(collector.events), 1)
        collector.feed(b'{"eventMessage":')
        self.ended_process(collector)
        rows, state = collector.finish({})
        self.assertEqual(len(rows), 1)
        self.assertEqual((state["status"], state["reason"]), ("invalid", "parser-partial-eof"))
        self.assertFalse(state["queryCompleted"])
        self.assertEqual(collector.events, [])
        self.assertEqual(collector.pending, bytearray())

    def test_nonblocking_drain_consumes_both_eofs_and_keeps_only_safe_projection(self):
        collector = self.collector()
        process = self.ended_process(collector)
        output = mock.Mock(fileobj=process.stdout, data=True)
        errors = mock.Mock(fileobj=process.stderr, data=False)
        record = json.dumps(self.event(collector, multiline=True)).encode() + b"\n"
        collector.selector.select.side_effect = [[(output, 1), (errors, 1)], [(output, 1)], []]
        with mock.patch.object(verify.os, "read", side_effect=[record, b"", b""]):
            collector.drain()
        self.assertEqual(collector.selector.unregister.call_count, 2)
        self.assertTrue(all(call.args == (0,) for call in collector.selector.select.call_args_list))
        self.assertEqual(collector.total, len(record))
        collector.selector.select.side_effect = None
        rows, state = collector.finish({})
        self.assertEqual(state["status"], "complete-nonempty")
        self.assertFalse(state["scopeVerified"])
        self.assertEqual(rows[0]["alias"], "M")
        self.assertNotIn(str(self.root), json.dumps(rows))

    def test_observer_deadline_and_failed_reap_are_not_complete(self):
        collector = self.collector()
        process = self.ended_process(collector, None)
        collector.deadline = time.monotonic() - 1
        collector.observer_deadline = collector.deadline
        process.wait.side_effect = subprocess.TimeoutExpired("owned", 0.1)
        _, state = collector.finish({})
        self.assertEqual((state["status"], state["reason"]), ("timed-out", "collector-reap-timeout"))
        self.assertFalse(state["queryCompleted"])
        self.assertEqual(process.wait.call_count, 3)
        self.assertTrue(all(call.kwargs["timeout"] == 0 for call in process.wait.call_args_list))
        self.assertTrue(collector.closed)

    def test_zero_fence_reap_timeout_retains_owner_and_later_reaps_without_changing_evidence(self):
        collector = self.collector()
        process = self.ended_process(collector, None)
        process.wait.side_effect = subprocess.TimeoutExpired("owned", 0)
        rows, state = collector.finish({}, deadline=time.monotonic() - 1)
        self.assertTrue(collector.closed)
        self.assertFalse(collector.reaped)
        self.assertIs(collector.process, process)
        self.assertTrue(all(call.kwargs["timeout"] == 0 for call in process.wait.call_args_list))
        process.poll.return_value = -9
        process.wait.side_effect = None
        process.wait.return_value = -9
        self.assertEqual(collector.finish({}, deadline=time.monotonic() + 0.1), (rows, state))
        self.assertTrue(collector.reaped)
        self.assertEqual(state["reason"], "collector-reap-timeout")
        self.assertFalse(state["queryCompleted"])

    def test_main_fence_never_borrows_new_wait_time(self):
        collector = self.collector()
        process = self.ended_process(collector, None)
        process.wait.return_value = -15
        _, state = collector.finish({}, deadline=time.monotonic() - 1)
        self.assertFalse(state["queryCompleted"])
        self.assertTrue(all(call.kwargs["timeout"] == 0 for call in process.wait.call_args_list))

    def test_early_eof_before_mainpost_never_becomes_complete(self):
        collector = self.collector()
        self.ended_process(collector)
        collector.lifecycle_complete = False
        collector.drain()
        collector.lifecycle_complete = True
        _, state = collector.finish({})
        self.assertEqual((state["status"], state["reason"]), ("invalid", "collector-early-eof"))
        self.assertFalse(state["queryCompleted"] or state["scopeVerified"])

    def test_single_pipe_early_eof_is_incomplete_even_while_process_is_alive(self):
        collector = self.collector()
        process = self.ended_process(collector, None)
        collector.lifecycle_complete = False
        output = mock.Mock(fileobj=process.stdout, data=True)
        collector.selector.select.return_value = [(output, 1)]
        collector.selector.get_map.return_value = {2: "stderr"}
        with mock.patch.object(verify.os, "read", return_value=b""):
            collector.drain()
        self.assertEqual(collector.failure, ("invalid", "collector-early-eof"))
        collector.selector.select.return_value = []
        process.poll.return_value = 0
        process.wait.return_value = 0
        self.assertFalse(collector.finish({})[1]["queryCompleted"])

    def test_eof_observed_before_target_can_finalize_in_existing_reserve(self):
        collector = self.collector()
        self.ended_process(collector)
        collector.deadline, collector.observer_deadline = 325.0, 330.0
        with mock.patch.object(verify.time, "monotonic", return_value=324.9):
            collector.drain()
        self.assertTrue(collector.eof_observed)
        with mock.patch.object(verify.time, "monotonic", return_value=325.1):
            _, state = collector.finish({})
        self.assertTrue(state["queryCompleted"])
        self.assertFalse(state["scopeVerified"])

    def test_exit_and_pipe_eof_first_observed_after_target_is_not_completion(self):
        collector = self.collector()
        self.ended_process(collector)
        collector.deadline, collector.observer_deadline = 325.0, 330.0
        with mock.patch.object(verify.time, "monotonic", return_value=325.1):
            _, state = collector.finish({})
        self.assertEqual(state["reason"], "collector-timeout")
        self.assertFalse(state["queryCompleted"])

    def test_one_pipe_missing_and_nonzero_exit_never_complete(self):
        for code, pipes, reason in ((0, {2: "stderr"}, "parser-partial-eof"), (3, {}, "collector-nonzero-exit")):
            with self.subTest(code=code):
                collector = self.collector()
                self.ended_process(collector, code)
                collector.selector.get_map.return_value = pipes
                _, state = collector.finish({})
                self.assertEqual(state["reason"], reason)
                self.assertFalse(state["queryCompleted"])

    def test_timeout_rounding_reserve_and_insufficient_start_are_absolute(self):
        for start, timeout in ((100.0, "225"), (100.4, "224"), (323.9, "1"), (324.1, None), (330.0, None)):
            with self.subTest(start=start):
                collector = self.collector()
                collector.observer_deadline, collector.deadline = 330.0, 325.0
                process = self.ended_process(collector)
                collector.process = None
                with mock.patch.object(verify.time, "monotonic", return_value=start), mock.patch.object(verify.os, "set_blocking"), mock.patch.object(verify.subprocess, "Popen", return_value=process) as launch:
                    collector.start()
                if timeout is None:
                    launch.assert_not_called()
                    self.assertEqual(collector.failure, ("timed-out", "collector-insufficient-budget"))
                else:
                    self.assertEqual(launch.call_args.args[0][5], timeout)
                self.assertEqual(collector.observer_deadline, 330.0)
                self.assertEqual(collector.deadline, 325.0)

    def test_empty_nonempty_nonzero_and_owned_cancel_are_distinct(self):
        for code, event, expected in ((0, False, "complete-empty"), (0, True, "complete-nonempty"), (1, False, "unavailable"),
                                      (None, False, "timed-out")):
            with self.subTest(code=code, event=event):
                collector = self.collector()
                if event:
                    collector.feed(json.dumps(self.event(collector)).encode() + b"\n")
                process = self.ended_process(collector, code)
                if code is None:
                    process.poll.side_effect = [None, None, 0]
                    process.wait.side_effect = [subprocess.TimeoutExpired("owned", 0.1), -9]
                rows, state = collector.finish({})
                self.assertEqual(state["status"], expected)
                self.assertEqual(state["queryCompleted"], code == 0)
                self.assertFalse(state["scopeVerified"])
                self.assertFalse(state["truncated"])
                if code is None:
                    process.terminate.assert_called_once()
                    process.kill.assert_called_once()
                    self.assertEqual(process.wait.call_count, 2)
                else:
                    process.terminate.assert_not_called()
                self.assertTrue(collector.closed)
                process.stdout.close.assert_called_once()
                process.stderr.close.assert_called_once()
                self.assertEqual(collector.finish({}), (rows, state))

    def test_parser_and_stderr_and_all_limits_fail_closed_without_raw_persistence(self):
        for mode, expected, reason in (("bad", "invalid", "parser-input-invalid"),
                                       ("stderr", "unavailable", "collector-access-or-source-error"),
                                       ("record", "truncated", "record-limit"),
                                       ("raw", "truncated", "raw-limit"),
                                       ("candidates", "truncated", "candidate-limit")):
            with self.subTest(mode=mode):
                collector = self.collector()
                if mode == "bad":
                    collector.feed(b'{"subsystem":"unknown"}\n')
                elif mode == "stderr":
                    collector.feed(b"private permission diagnostic", output=False)
                elif mode == "record":
                    collector.feed(b"x" * 16385)
                elif mode == "raw":
                    collector.total = 1024**2 - 1
                    collector.feed(b"xx", output=False)
                else:
                    record = json.dumps(self.event(collector)).encode() + b"\n"
                    for _ in range(257):
                        collector.feed(record)
                self.ended_process(collector)
                with mock.patch.object(verify.Path, "write_bytes") as disk:
                    rows, state = collector.finish({})
                disk.assert_not_called()
                self.assertEqual((state["status"], state["reason"]), (expected, reason))
                self.assertFalse(state["queryCompleted"])
                self.assertLessEqual(len(rows), 256)
                self.assertEqual(collector.events, [])
                self.assertEqual(collector.pending, bytearray())
                self.assertEqual(collector.bindings, {})
                self.assertNotIn(str(self.root), json.dumps({"state": state, "rows": rows}))

    def test_start_failure_access_timeout_and_unproved_readiness(self):
        for failure, expected in ((OSError(errno.ENOENT, "private"), ("unavailable", "collector-start-failed")),
                                  (PermissionError(errno.EACCES, "private"), ("unavailable", "collector-access-denied"))):
            collector = self.collector()
            with mock.patch.object(verify.subprocess, "Popen", side_effect=failure):
                collector.start()
            _, state = collector.finish({})
            self.assertEqual((state["status"], state["reason"]), expected)
        collector = self.collector()
        collector.deadline = time.monotonic() - 1
        with mock.patch.object(verify.subprocess, "Popen") as launch:
            collector.start()
        launch.assert_not_called()
        self.assertEqual(collector.finish({})[1]["status"], "timed-out")
        collector = self.collector()
        process = self.ended_process(collector)
        with mock.patch.object(verify.subprocess, "Popen", return_value=process) as launch, mock.patch.object(verify.os, "set_blocking"):
            collector.start()
        self.assertFalse(collector.state["queryCompleted"] or collector.state["scopeVerified"])
        argv = launch.call_args.args[0]
        self.assertEqual(argv[:5], ["/usr/bin/log", "stream", "--style", "ndjson", "--timeout"])
        self.assertNotIn("--ignore-dropped", argv)
        self.assertNotIn("--last", argv)


class ManualObservationTests(IsolatedTest):
    run_id = "01234567-89ab-4cde-8fab-0123456789ab"

    def evidence(self):
        evidence = verify.base_evidence("arm64")
        evidence["manifest"]["artifactHash"] = "b" * 64
        evidence["actorBindings"] = [{"actorInstanceRef": "actor-" + self.run_id, "role": "Python",
                                       "preVerified": True, "postVerified": True}]
        evidence["cases"] = [{"actorInstanceRef": "actor-" + self.run_id, "promptObserved": "unverified", "verdict": "inconclusive"}]
        return evidence

    def receipt(self, **changes):
        return {"runID": self.run_id, "artifactHash": "b" * 64, "actorInstanceRef": "actor-" + self.run_id,
                "fdaStatus": "not-listed", "prompt": "not-observed", "coverage": "complete",
                "grantChange": "none-observed", **changes}

    def test_bound_complete_receipt_is_human_observation_not_effective_tcc(self):
        evidence = self.evidence()
        verify.project_manual_observations(evidence, self.run_id, [self.receipt()])
        self.assertEqual(evidence["manualObservations"], [self.receipt()])
        self.assertEqual(evidence["cases"][0]["verdict"], "inconclusive")
        self.assertEqual(evidence["cases"][0]["promptObserved"], "unverified")

    def test_missing_partial_unknown_and_incomplete_bindings_never_claim_absence(self):
        for receipts in (None, [], [self.receipt(coverage="partial")], [self.receipt(coverage="unknown")]):
            evidence = self.evidence()
            verify.project_manual_observations(evidence, self.run_id, receipts)
            row = evidence["manualObservations"][0]
            self.assertEqual((row["fdaStatus"], row["prompt"], row["grantChange"]), ("unknown", "unknown", "unknown"))
        evidence["actorBindings"][0]["postVerified"] = False
        with self.assertRaisesRegex(acquire.Failure, "manual-receipt"):
            verify.project_manual_observations(evidence, self.run_id, [self.receipt()])
        self.assertEqual(evidence["manualObservations"], [])

    def test_wrong_run_artifact_actor_enum_unknown_fields_and_duplicates_fail_closed(self):
        for changes in ({"runID": str(verify.uuid.uuid4())}, {"artifactHash": "c" * 64},
                        {"actorInstanceRef": "actor-unbound"}, {"fdaStatus": "denied"}, {"prompt": True},
                        {"coverage": "full"}, {"grantChange": "none"}, {"person": "private"}):
            evidence = self.evidence()
            with self.subTest(changes=changes), self.assertRaisesRegex(acquire.Failure, "manual-receipt"):
                verify.project_manual_observations(evidence, self.run_id, [self.receipt(**changes)])
            self.assertEqual(evidence["manualObservations"][0]["prompt"], "unknown")
        with self.assertRaisesRegex(acquire.Failure, "manual-receipt"):
            verify.project_manual_observations(self.evidence(), self.run_id, [self.receipt(), self.receipt()])

    def test_partial_positive_prompt_blocks_without_retroactive_ack_claim(self):
        evidence = self.evidence()
        self.assertTrue(verify.project_manual_observations(evidence, self.run_id, [self.receipt(prompt="observed", coverage="partial")]))
        self.assertEqual(evidence["cases"][0], {"actorInstanceRef": "actor-" + self.run_id, "promptObserved": True, "verdict": "blocked"})
        self.assertEqual(evidence["manualObservations"][0]["prompt"], "observed")
        self.assertEqual(evidence["automated"][-1]["reason"], "human-prompt-observed-final-blocked")

    def test_callback_context_is_opaque_and_bounded_errors_do_not_persist_text(self):
        evidence = self.evidence()
        callback = mock.Mock(return_value=[self.receipt()])
        verify.receive_manual_observations(evidence, self.run_id, callback, time.monotonic() + 1)
        self.assertEqual(callback.call_args.args[0], {"runID": self.run_id, "artifactHash": "b" * 64,
                                                   "actorInstanceRefs": ("actor-" + self.run_id,)})
        with self.assertRaisesRegex(acquire.Failure, "manual-callback-invalid"):
            verify.receive_manual_observations(evidence, self.run_id, mock.Mock(side_effect=ValueError("private")), time.monotonic() + 1)
        thread = mock.Mock()
        thread.is_alive.return_value = True
        with mock.patch.object(verify.threading, "Thread", return_value=thread), self.assertRaisesRegex(acquire.Failure, "manual-callback-timeout"):
            verify.receive_manual_observations(evidence, self.run_id, callback, time.monotonic() + 1)
        self.assertLessEqual(thread.join.call_args.kwargs["timeout"], 0.05)
        self.assertEqual(evidence["manualObservations"][0]["prompt"], "unknown")


class CurrentProfileTests(IsolatedTest):
    def test_darwin_acl_entry_success_is_not_an_empty_acl(self):
        for pointer, status, error, expected in ((1, 0, 0, False), (1, -1, errno.EINVAL, True), (1, -1, errno.EIO, False), (0, -1, errno.EINVAL, False), (0, -1, errno.ENOENT, True), (0, -1, errno.EPERM, False)):
            library = mock.Mock()
            library.acl_get_fd_np.return_value = pointer
            library.acl_get_entry.return_value = status
            with self.subTest(pointer=pointer, status=status, error=error), mock.patch.object(verify.ctypes, "CDLL", return_value=library), mock.patch.object(verify.ctypes, "get_errno", return_value=error):
                self.assertEqual(verify.no_acl(self.root), expected)
            self.assertEqual(library.acl_free.call_count, int(bool(pointer)))

    def resolve(self, uid=501, effective=501, home=None, account_uid=501, reported_home=None):
        home = self.root if home is None else home
        account = mock.Mock(pw_uid=account_uid, pw_dir=str(home))
        reported_home = self.root if reported_home is None else reported_home
        with mock.patch.object(verify.sys, "platform", "darwin"), mock.patch.object(verify.os, "getuid", return_value=uid), mock.patch.object(verify.os, "geteuid", return_value=effective), mock.patch.object(verify.pwd, "getpwuid", return_value=account), mock.patch.object(Path, "home", return_value=reported_home):
            return verify.current_home()

    def test_regular_current_account_uses_os_home(self):
        self.assertEqual(self.resolve(), self.root)

    def test_root_sudo_system_and_wrong_account_are_rejected(self):
        for args in ({"uid": 0, "effective": 0}, {"uid": 501, "effective": 0}, {"uid": 499, "effective": 499}, {"account_uid": 502}):
            with self.subTest(args=args), self.assertRaisesRegex(acquire.Failure, "fixture_profile_mismatch"):
                self.resolve(**args)

    def test_relative_missing_symlink_and_overridden_home_are_rejected(self):
        link = self.root / "alias"
        link.symlink_to(self.root, target_is_directory=True)
        for args in ({"home": Path("relative")}, {"home": self.root / "missing"}, {"home": link, "reported_home": link}, {"reported_home": self.root / "sandbox"}):
            with self.subTest(args=args), self.assertRaisesRegex(acquire.Failure, "fixture_profile_mismatch"):
                self.resolve(**args)

    def test_missing_os_account_fails_closed_without_home_fallback(self):
        with mock.patch.object(verify.sys, "platform", "darwin"), mock.patch.object(verify.os, "getuid", return_value=501), mock.patch.object(verify.os, "geteuid", return_value=501), mock.patch.object(verify.pwd, "getpwuid", side_effect=KeyError(501)), mock.patch.object(Path, "home") as home:
            with self.assertRaisesRegex(acquire.Failure, "fixture_profile_mismatch"):
                verify.current_home()
        home.assert_not_called()

    def test_signed_map_is_exact_and_contains_no_home(self):
        path = self.root / "fixture-map.json"
        path.write_text(json.dumps({"profile": "current-user", "groupID": verify.GROUP}))
        verify.validate_fixture_map(path)
        for value in ({"groupRoot": str(self.root)}, {"profile": "dedicated", "groupID": verify.GROUP}, {"profile": "current-user", "groupID": "other"}, dict(verify.FIXTURE_MAP, home=str(self.root))):
            with self.subTest(value=value):
                path.write_text(json.dumps(value))
                with self.assertRaisesRegex(acquire.Failure, "fixture_map_mismatch"):
                    verify.validate_fixture_map(path)


class ManifestTests(IsolatedTest):
    def manifest(self):
        bundle = self.root / "PaperLens.app"
        executable = bundle / "Contents/MacOS/PaperLens"
        executable.parent.mkdir(parents=True)
        executable.write_bytes(b"synthetic signed executable bytes")
        signature = bundle / "Contents/_CodeSignature/CodeResources"
        signature.parent.mkdir()
        signature.write_bytes(b"synthetic signature resource")
        (executable.parent / "internal-link").symlink_to("PaperLens")
        inventory = packaging.tree_inventory(bundle)
        files = []
        for item in inventory:
            entry = {"path": item["path"], "kind": "symlink" if "link" in item else "file", "sourceSHA256": None if "link" in item else "1" * 64, "signedSHA256": item.get("sha256")}
            entry.update({"link": item["link"]} if "link" in item else {"mode": item["mode"]})
            files.append(entry)
        manifest = packaging.safe_manifest({
            "schemaRevision": "topology-v1", "arch": "arm64", "team": verify.TEAM,
            "sourceBaseCommit": "a" * 40, "sourceTreeHash": "b" * 64, "sourceDirty": True,
            "artifactHash": packaging.json_hash(inventory), "acquisitionHash": "c" * 64,
            "dependencyLockHash": "d" * 64, "files": files,
            "notarization": "not_performed", "storyDone": False,
        })
        return bundle, manifest

    def test_exact_packager_schema_accepts_changed_signed_bytes(self):
        bundle, manifest = self.manifest()
        records = verify.validate_inventory(bundle, "arm64", manifest)
        self.assertIn("Contents/MacOS/PaperLens", records)
        self.assertIn("Contents/_CodeSignature/CodeResources", records)
        self.assertNotEqual(records["Contents/MacOS/PaperLens"]["sourceSHA256"], records["Contents/MacOS/PaperLens"]["signedSHA256"])
        self.assertFalse((bundle / "Contents/Resources/topology-inventory.json").exists())

    def test_main_and_signature_tampering_are_detected(self):
        bundle, manifest = self.manifest()
        for relative in ("Contents/MacOS/PaperLens", "Contents/_CodeSignature/CodeResources"):
            with self.subTest(relative=relative):
                path = bundle / relative
                original = path.read_bytes()
                path.write_bytes(b"tampered")
                with self.assertRaisesRegex(acquire.Failure, "artifact_hash_mismatch"):
                    verify.validate_inventory(bundle, "arm64", manifest)
                path.write_bytes(original)

    def test_manifest_omission_wrong_hash_and_arch_are_rejected(self):
        bundle, manifest = self.manifest()
        with self.assertRaisesRegex(acquire.Failure, "manifest_arch_mismatch"):
            verify.validate_inventory(bundle, "x86_64", manifest)
        removed = manifest["files"].pop()
        with self.assertRaisesRegex(acquire.Failure, "inventory_coverage_mismatch"):
            verify.validate_inventory(bundle, "arm64", manifest)
        manifest["files"].append(removed)
        entry = next(item for item in manifest["files"] if item["kind"] == "file")
        entry["signedSHA256"] = "e" * 64
        with self.assertRaisesRegex(acquire.Failure, "inventory_hash_mismatch"):
            verify.validate_inventory(bundle, "arm64", manifest)

    def test_link_and_mode_tampering_are_detected(self):
        bundle, manifest = self.manifest()
        entry = next(item for item in manifest["files"] if item["kind"] == "symlink")
        entry["link"] = "../_CodeSignature/CodeResources"
        with self.assertRaisesRegex(acquire.Failure, "inventory_link_mismatch"):
            verify.validate_inventory(bundle, "arm64", manifest)
        entry["link"] = "PaperLens"
        regular = next(item for item in manifest["files"] if item["kind"] == "file")
        regular["mode"] ^= 0o100
        with self.assertRaisesRegex(acquire.Failure, "inventory_hash_mismatch"):
            verify.validate_inventory(bundle, "arm64", manifest)


class GroupOwnerTests(IsolatedTest):
    run_id = "01234567-89ab-4cde-8fab-0123456789ab"

    def messages(self):
        ready = {"status": "ready", "runID": self.run_id, "fixtureID": "G", "ownerPre": "pass", "expectedRootMatched": True, "posixACLControl": "unverified"}
        post = {"status": "complete", "runID": self.run_id, "fixtureID": "G", "ownerPost": "pass", "absent": True}
        return ready, post

    def bundle(self):
        bundle = self.root / ".build/topology/arm64/products/FixtureGroupOwner.app"
        (bundle / "Contents/MacOS").mkdir(parents=True)
        (bundle / "Contents/Resources").mkdir()
        (bundle / "Contents/MacOS/FixtureGroupOwner").write_bytes(b"synthetic")
        (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": verify.GROUP_OWNER, "CFBundleExecutable": "FixtureGroupOwner"}))
        (bundle / "Contents/Resources/fixture-map.json").write_text(json.dumps(verify.FIXTURE_MAP))
        return bundle

    def test_profile_rejection_never_launches_group_owner(self):
        with mock.patch.object(verify, "current_home", side_effect=acquire.Failure("fixture_profile_mismatch")), mock.patch.object(verify.subprocess, "Popen") as launch:
            with self.assertRaisesRegex(acquire.Failure, "fixture_profile_mismatch"):
                verify.GroupOwner("arm64", self.run_id)
        launch.assert_not_called()

    def test_signed_owner_ready_lifetime_and_post_cleanup(self):
        bundle = self.bundle()
        ready, post = self.messages()
        read_fd, write_fd = os.pipe()
        reader = os.fdopen(read_fd, "rb", buffering=0)
        self.addCleanup(reader.close)
        self.addCleanup(lambda: writer.close() if not writer.closed else None)
        writer = os.fdopen(write_fd, "wb", buffering=0)
        writer.write(json.dumps(ready).encode() + b"\n")

        class Process:
            stdout = reader
            status = None
            terminated = False

            def poll(self):
                return self.status

            def terminate(self):
                self.terminated = True
                writer.write(json.dumps(post).encode() + b"\n")
                writer.close()
                self.status = 0

            def wait(self, timeout):
                return self.status

        process = Process()
        with mock.patch.object(verify, "ROOT", self.root), mock.patch.object(verify, "current_home", return_value=self.root), mock.patch.object(packaging, "inspect_macho", return_value="executable"), mock.patch.object(packaging, "verify_signature") as signed, mock.patch.object(verify.subprocess, "Popen", return_value=process) as launch:
            owner = verify.GroupOwner("arm64", self.run_id)
            owner.start()
            self.assertTrue(owner.ready)
            self.assertFalse(process.terminated)
            self.assertIsNone(process.poll())
            self.assertEqual(owner.finish(), post)
        self.assertTrue(owner.completed)
        self.assertTrue(process.terminated)
        rights = {verify.SANDBOX: True, "com.apple.security.application-groups": [verify.GROUP]}
        self.assertEqual(signed.call_args_list, [mock.call(bundle / "Contents/MacOS/FixtureGroupOwner", verify.GROUP_OWNER, rights), mock.call(bundle, verify.GROUP_OWNER, rights)])
        self.assertEqual(launch.call_args.args[0], [str(bundle / "Contents/MacOS/FixtureGroupOwner"), "--run-id", self.run_id])
        self.assertEqual(launch.call_args.kwargs["stderr"], verify.subprocess.DEVNULL)

    def test_signature_failure_never_starts_process(self):
        self.bundle()
        with mock.patch.object(verify, "ROOT", self.root), mock.patch.object(verify, "current_home", return_value=self.root), mock.patch.object(packaging, "inspect_macho", return_value="executable"), mock.patch.object(packaging, "verify_signature", side_effect=packaging.Failure("signed_team_mismatch")), mock.patch.object(verify.subprocess, "Popen") as launch:
            owner = verify.GroupOwner("arm64", self.run_id)
            with self.assertRaises(packaging.Failure):
                owner.start()
        launch.assert_not_called()

    def test_wrong_signed_owner_map_never_starts_process(self):
        bundle = self.bundle()
        (bundle / "Contents/Resources/fixture-map.json").write_text(json.dumps(dict(verify.FIXTURE_MAP, groupRoot=str(self.root))))
        with mock.patch.object(verify, "ROOT", self.root), mock.patch.object(verify, "current_home", return_value=self.root), mock.patch.object(packaging, "inspect_macho", return_value="executable"), mock.patch.object(packaging, "verify_signature") as signed, mock.patch.object(verify.subprocess, "Popen") as launch:
            owner = verify.GroupOwner("arm64", self.run_id)
            with self.assertRaisesRegex(acquire.Failure, "fixture_map_mismatch"):
                owner.start()
        self.assertEqual(signed.call_count, 2)
        launch.assert_not_called()

    def test_unavailable_owner_blocks_main_without_starting_external_controls(self):
        control = mock.Mock(pre=False, post=False, network_pre=False, network_post=False, inbound_pre=False, inbound_post=False)
        owner = mock.Mock(process=None, ready=False)
        owner.start.side_effect = acquire.Failure("group_owner_fixture_unavailable")
        owner.finish.return_value = None
        evidence = verify.base_evidence("arm64")
        with mock.patch.object(verify, "current_home", return_value=self.root), mock.patch.object(verify, "Controls", return_value=control), mock.patch.object(verify, "GroupOwner", return_value=owner), mock.patch.object(verify, "command") as commands:
            with self.assertRaisesRegex(acquire.Failure, "group_owner_fixture_unavailable"):
                verify.gui_run(self.root / "PaperLens.app", evidence)
        commands.assert_not_called()
        control.start.assert_not_called()
        control.finish.assert_not_called()
        owner.finish.assert_called_once()
        self.assertTrue(all(item["verdict"] == "blocked" for item in evidence["automated"]))

    def test_ready_contract_rejects_wrong_run_extra_fields_and_unavailable_group(self):
        ready, post = self.messages()
        bad = dict(ready, runID="01234567-89ab-4cde-8fab-0123456789ac")
        with self.assertRaisesRegex(acquire.Failure, "group_owner_run_mismatch"):
            verify.group_message(bad, self.run_id, "ready")
        with self.assertRaisesRegex(acquire.Failure, "group_owner_invalid_message"):
            verify.group_message(dict(ready, path="/Users/private"), self.run_id, "ready")
        for reason, expected in (("profileUnavailable", "group_owner_profile_unavailable"), ("groupUnavailable", "group_owner_group_unavailable"), ("groupPathMismatch", "group_owner_group_path_mismatch"), ("groupDirectoryUnavailable", "group_owner_group_directory_unavailable"), ("fixtureUnavailable", "group_owner_fixture_unavailable"), ("invalidInvocation", "group_owner_invalid_invocation")):
            with self.subTest(reason=reason), self.assertRaisesRegex(acquire.Failure, expected):
                verify.group_message({"status": "blocked", "fixtureID": "G", "reason": reason}, self.run_id, "ready")
        with self.assertRaisesRegex(acquire.Failure, "group_owner_inconsistent_post"):
            verify.group_message(dict(post, absent=False), self.run_id, "post")
        with self.assertRaisesRegex(acquire.Failure, "duplicate_evidence_key"):
            verify.decode_json(b'{"status":"ready","status":"blocked"}')

    def test_bounded_pipe_timeout_and_oversize(self):
        with mock.patch.object(verify, "current_home", return_value=self.root):
            owner = verify.GroupOwner("arm64", self.run_id)
        read_fd, write_fd = os.pipe()
        with os.fdopen(read_fd, "rb", buffering=0) as reader, os.fdopen(write_fd, "wb", buffering=0) as writer:
            owner.process = mock.Mock(stdout=reader)
            with self.assertRaisesRegex(acquire.Failure, "group_owner_response_timeout"):
                owner.receive(time.monotonic() - 1)
            writer.write(b"x" * 4097)
            with self.assertRaisesRegex(acquire.Failure, "group_owner_response_limit"):
                owner.receive(time.monotonic() + 1)


class EOFDiagnosticTests(IsolatedTest):
    run_id = "01234567-89ab-4cde-8fab-0123456789ab"
    artifact = "a" * 64

    class Pipe:
        def __init__(self, fd):
            self.fd = fd
            self.closed = False

        def fileno(self):
            return self.fd

        def close(self):
            self.closed = True

    class Process:
        def __init__(self, status=None):
            self.stdout = EOFDiagnosticTests.Pipe(10)
            self.stderr = EOFDiagnosticTests.Pipe(11)
            self.status = status
            self.calls = []

        def poll(self):
            return self.status

        def terminate(self):
            self.calls.append("terminate")
            self.status = 0

        def kill(self):
            self.calls.append("kill")
            self.status = -9

        def wait(self, timeout):
            self.calls.append(("wait", timeout))
            return self.status

    class Selector:
        def __init__(self):
            self.entries = {}
            self.reads = []

        def register(self, pipe, events, output):
            self.entries[pipe.fd] = mock.Mock(fileobj=pipe, data=output)

        def unregister(self, pipe):
            return self.entries.pop(pipe.fd)

        def get_map(self):
            return self.entries

        def select(self, timeout):
            if self.reads:
                return [(self.entries[self.reads.pop(0)], 1)]
            return []

        def close(self):
            self.entries.clear()

    def collector(self, hooks, status=None):
        bindings = {role: {"pid": 100 + index} for index, role in enumerate(verify.ROLES)}
        process = hooks.test_process
        process.status = status
        collector = verify.OSCollector(bindings, verify.fixture_paths(self.root, self.run_id), deadline=230)
        collector.start()
        collector.lifecycle_complete = True
        return collector, process

    def context(self, read=None):
        stack = contextlib.ExitStack()
        stack.enter_context(mock.patch.object(verify.time, "monotonic", return_value=0.75))
        stack.enter_context(mock.patch.object(verify.selectors, "DefaultSelector", self.Selector))
        process = self.Process()
        stack.enter_context(mock.patch.object(verify.subprocess, "Popen", return_value=process))
        stack.enter_context(mock.patch.object(verify.os, "set_blocking"))
        if read is not None:
            stack.enter_context(mock.patch.object(verify.os, "read", side_effect=read))
        hooks = stack.enter_context(diagnose_eof.Hooks())
        hooks.test_process = process
        self.addCleanup(stack.close)
        return hooks

    def test_fixed_slots_unknown_defaults_and_raw_rejection(self):
        hooks = diagnose_eof.Hooks()
        self.assertEqual(set(hooks.receipt["milestones"]), set(diagnose_eof.SLOTS))
        self.assertTrue(all(row == diagnose_eof.unknown() for row in hooks.receipt["milestones"].values()))
        diagnose_eof.validate_receipt(hooks.receipt)
        for field, value in (("pid", 10), ("path", "/Users/private"), ("duration", 1), ("header", "raw")):
            bad = json.loads(json.dumps(hooks.receipt))
            bad["milestones"]["start-before"][field] = value
            with self.subTest(field=field), self.assertRaises(acquire.Failure):
                diagnose_eof.validate_receipt(bad)
        bad = json.loads(json.dumps(hooks.receipt))
        bad["milestones"]["start-before"]["reaped"] = False
        with self.assertRaises(acquire.Failure):
            diagnose_eof.validate_receipt(bad)

    def test_actual_argv_timeout_rounding_and_original_deadlines(self):
        hooks = self.context()
        collector, process = self.collector(hooks)
        self.assertEqual(hooks.receipt["cliTimeout"], 224)
        self.assertEqual((collector.deadline, collector.observer_deadline), (225, 230))
        self.assertEqual(hooks.receipt["milestones"]["start-before"]["processState"], "not-started")
        self.assertEqual(hooks.receipt["milestones"]["start-after"]["processState"], "running")
        hooks.receipt["cliTimeout"] = None
        hooks.bind_process(self.Process(), ["other", "--timeout", "224"])
        self.assertIsNone(hooks.receipt["cliTimeout"])
        self.assertEqual(process.calls, [])

    def test_exit_with_registered_pipes_is_not_eof_and_close_is_unknown(self):
        hooks = self.context()
        collector, process = self.collector(hooks, status=0)
        hooks.sample("mainpost-after")
        row = hooks.receipt["milestones"]["mainpost-after"]
        self.assertEqual((row["processState"], row["stdoutState"], row["stderrState"]), ("exit-zero", "registered", "registered"))
        collector.selector.close()
        process.stdout.close()
        process.stderr.close()
        hooks.sample("after-cleanup")
        self.assertEqual(hooks.receipt["milestones"]["after-cleanup"]["stdoutState"], "unknown")
        self.assertFalse(hooks.eof)

    def test_no_popen_means_no_computed_timeout_substitute(self):
        hooks = self.context()
        with mock.patch.object(verify.time, "monotonic", return_value=225):
            collector, process = self.collector(hooks)
        self.assertIsNone(collector.process)
        self.assertIsNone(hooks.receipt["cliTimeout"])
        self.assertEqual(collector.failure, ("timed-out", "collector-insufficient-budget"))
        self.assertEqual(hooks.receipt["milestones"]["start-after"]["processState"], "not-started")

    def test_only_original_readzero_and_successful_unregister_record_eof(self):
        reads = []
        def read(fd, size):
            reads.append((fd, size))
            return b""
        hooks = self.context(read=read)
        collector, process = self.collector(hooks, status=0)
        collector.selector.reads = [10, 11]
        collector.drain()
        self.assertEqual(reads, [(10, 8192), (11, 8192)])
        hooks.sample("report-tail")
        self.assertEqual(hooks.eof, {"stdoutState", "stderrState"})
        row = hooks.receipt["milestones"]["report-tail"]
        self.assertEqual((row["stdoutState"], row["stderrState"]), ("eof-observed", "eof-observed"))
        self.assertTrue(collector.eof_observed)

    def test_unregistration_without_zero_and_failed_unregister_do_not_claim_eof(self):
        hooks = self.context()
        collector, process = self.collector(hooks)
        collector.selector.unregister(process.stdout)
        self.assertFalse(hooks.eof)
        hooks.draining = True
        hooks.zero.add(10)
        with self.assertRaises(KeyError):
            collector.selector.unregister(process.stdout)
        self.assertFalse(hooks.eof)

    def test_target_early_return_late_samples_and_first_slot_immutability(self):
        hooks = self.context()
        collector, process = self.collector(hooks)
        collector.selector.reads = [10]
        with mock.patch.object(verify.time, "monotonic", return_value=224.9):
            hooks.sample()
        with mock.patch.object(verify.time, "monotonic", return_value=225), mock.patch.object(verify.os, "read") as read:
            collector.drain()
            read.assert_not_called()
        first = dict(hooks.receipt["milestones"]["first-at-target"])
        self.assertEqual(collector.failure, ("timed-out", "collector-timeout"))
        self.assertEqual(first["processState"], "running")
        self.assertFalse(first["sourceFailure"])
        process.status = 0
        with mock.patch.object(verify.time, "monotonic", return_value=226):
            hooks.sample()
        self.assertEqual(hooks.receipt["milestones"]["first-at-target"], first)
        self.assertEqual(hooks.receipt["milestones"]["last-before-target"]["targetRelation"], "before")
        self.assertEqual(len(hooks.receipt["milestones"]), 8)

    def test_forced_stop_is_separate_from_cleanup_and_completion(self):
        hooks = self.context()
        collector, process = self.collector(hooks)
        rows, state = collector.finish({})
        hooks.sample("after-cleanup")
        before = hooks.receipt["milestones"]["before-stop"]
        after = hooks.receipt["milestones"]["after-cleanup"]
        self.assertEqual((before["processState"], before["stopRequested"]), ("running", False))
        self.assertEqual((after["processState"], after["stopRequested"], after["reaped"], after["frozen"]), ("exit-zero", True, True, True))
        self.assertFalse(state["queryCompleted"])
        self.assertEqual(state["reason"], "collector-stop-before-eof")
        self.assertFalse(hooks.receipt["milestones"]["report-tail"]["observed"])

    def test_original_return_exception_and_hook_restoration(self):
        failure = RuntimeError("private raw failure")
        original = verify.OSCollector.start
        with mock.patch.object(verify.OSCollector, "start", side_effect=failure), mock.patch.object(verify.selectors, "DefaultSelector", self.Selector):
            with diagnose_eof.Hooks() as hooks:
                bindings = {role: {"pid": 100 + index} for index, role in enumerate(verify.ROLES)}
                collector = verify.OSCollector(bindings, verify.fixture_paths(self.root, self.run_id), deadline=230)
                with self.assertRaises(RuntimeError) as observed:
                    collector.start()
                self.assertIs(observed.exception, failure)
                self.assertFalse(hooks.receipt["milestones"]["start-after"]["observed"])
        self.assertIs(verify.OSCollector.start, original)

    def test_first_actual_stop_is_not_overwritten_by_later_kill(self):
        hooks = self.context()
        collector, process = self.collector(hooks)
        with mock.patch.object(process, "wait", side_effect=[subprocess.TimeoutExpired("owned", 0.1), 0]):
            collector.finish({})
        self.assertEqual(process.calls, ["terminate", "kill"])
        row = hooks.receipt["milestones"]["before-stop"]
        self.assertEqual((row["processState"], row["stopRequested"]), ("running", False))
        self.assertFalse(collector.state["queryCompleted"])

    def test_after_cleanup_is_actual_gui_return_or_exception_boundary(self):
        cleaned = []
        failure = RuntimeError("original")
        def gui(*args, **kwargs):
            try:
                raise failure
            finally:
                cleaned.append(True)
                collector.closed = True
        with mock.patch.object(verify, "gui_run", gui):
            hooks = self.context()
            collector, process = self.collector(hooks)
            with self.assertRaises(RuntimeError) as observed:
                verify.gui_run("bundle", {})
            self.assertIs(observed.exception, failure)
            self.assertEqual(cleaned, [True])
            self.assertTrue(hooks.receipt["milestones"]["after-cleanup"]["frozen"])
            hooks.stack.close()

    def test_mainpost_and_report_tail_require_actual_successful_boundaries(self):
        observer = mock.Mock(done=set(), run_id=self.run_id, artifact_hash=self.artifact)
        def poll(value):
            value.done.add((0, "post"))
            return "original"
        def tail(value):
            verify.require(True, "report_lifecycle_incomplete")
            value.collector.drain()
            return "tail-return"
        with mock.patch.object(verify.ReadinessObserver, "poll", poll), mock.patch.object(verify.ReadinessObserver, "tail", tail):
            hooks = self.context()
            collector, process = self.collector(hooks)
            observer.collector = collector
            self.assertEqual(verify.ReadinessObserver.poll(observer), "original")
            self.assertTrue(hooks.receipt["milestones"]["mainpost-after"]["observed"])
            self.assertFalse(hooks.receipt["milestones"]["report-tail"]["observed"])
            self.assertEqual(verify.ReadinessObserver.tail(observer), "tail-return")
            self.assertTrue(hooks.receipt["milestones"]["report-tail"]["observed"])
            hooks.stack.close()

    def test_failed_mainpost_return_or_report_validation_cannot_create_slots(self):
        observer = mock.Mock(done=set())
        failure = acquire.Failure("report_lifecycle_incomplete")
        def poll(value):
            value.done.add((0, "post"))
            raise failure
        def tail(value):
            verify.require(False, "report_lifecycle_incomplete")
            value.collector.drain()
        with mock.patch.object(verify.ReadinessObserver, "poll", poll), mock.patch.object(verify.ReadinessObserver, "tail", tail):
            hooks = self.context()
            collector, process = self.collector(hooks)
            observer.collector = collector
            with self.assertRaises(acquire.Failure) as observed:
                verify.ReadinessObserver.poll(observer)
            self.assertIs(observed.exception, failure)
            with self.assertRaises(acquire.Failure):
                verify.ReadinessObserver.tail(observer)
            self.assertFalse(hooks.receipt["milestones"]["mainpost-after"]["observed"])
            self.assertFalse(hooks.receipt["milestones"]["report-tail"]["observed"])
            hooks.stack.close()

    def safe_values(self):
        receipt = diagnose_eof.Hooks().receipt
        receipt.update(runID=self.run_id, artifactHash=self.artifact)
        evidence = verify.base_evidence("arm64")
        evidence["manifest"]["artifactHash"] = self.artifact
        evidence["groupOwner"]["runID"] = self.run_id
        summary = diagnose_eof.project_output(json.dumps(evidence), receipt)
        summary.update(priorReportsPreserved=True, priorReportsHash="b" * 64)
        return receipt, evidence, summary

    def test_safe_join_and_raw_capture_never_projected(self):
        receipt, evidence, summary = self.safe_values()
        evidence["privateRaw"] = "/Users/private PID 123 timestamp header"
        self.assertNotIn("private", json.dumps(diagnose_eof.project_output(json.dumps(evidence), receipt)))
        evidence["groupOwner"]["runID"] = str(verify.uuid.uuid4())
        with self.assertRaisesRegex(acquire.Failure, "diagnostic_join_invalid"):
            diagnose_eof.project_output(json.dumps(evidence), receipt)
        evidence["groupOwner"]["runID"] = self.run_id
        evidence["osCollection"]["reason"] = "/Users/private"
        with self.assertRaises(acquire.Failure):
            diagnose_eof.project_output(json.dumps(evidence), receipt)
        capture = diagnose_eof.Capture()
        capture.maximum = 4
        capture.write("1234")
        with self.assertRaises(acquire.Failure):
            capture.write("5")

    def test_exclusive_output_collision_and_extra_raw_fields_preserve_bytes(self):
        receipt, evidence, summary = self.safe_values()
        directory = self.root / ".build/topology/arm64"
        directory.mkdir(parents=True)
        existing = directory / ("eof-diagnostic-" + self.run_id + ".json")
        existing.write_bytes(b"preserve")
        before = existing.stat()
        with mock.patch.object(verify, "ROOT", self.root):
            with self.assertRaises(FileExistsError):
                diagnose_eof.save(receipt, summary)
            summary["raw"] = "/Users/private"
            with self.assertRaises(acquire.Failure):
                diagnose_eof.save(receipt, summary)
        self.assertEqual(existing.read_bytes(), b"preserve")
        self.assertEqual((existing.stat().st_ino, existing.stat().st_mode), (before.st_ino, before.st_mode))

    def test_exclusive_safe_output_success_and_second_destination_collision(self):
        receipt, evidence, summary = self.safe_values()
        directory = self.root / ".build/topology/arm64"
        directory.mkdir(parents=True)
        with mock.patch.object(verify, "ROOT", self.root):
            diagnose_eof.save(receipt, summary)
        first = directory / ("eof-diagnostic-" + self.run_id + ".json")
        second = directory / ("eof-evidence-" + self.run_id + ".json")
        self.assertEqual(json.loads(first.read_bytes()), receipt)
        self.assertEqual(json.loads(second.read_bytes()), summary)
        self.assertEqual(stat.S_IMODE(first.stat().st_mode), 0o600)
        other = str(verify.uuid.uuid4())
        receipt["runID"] = other
        collision = directory / ("eof-evidence-" + other + ".json")
        collision.write_bytes(b"preserve second")
        before = collision.stat()
        with mock.patch.object(verify, "ROOT", self.root), self.assertRaises(FileExistsError):
            diagnose_eof.save(receipt, summary)
        self.assertEqual(collision.read_bytes(), b"preserve second")
        self.assertEqual(collision.stat().st_ino, before.st_ino)

    def test_original_run_failure_and_report_changes_are_not_hidden_or_retried(self):
        prior = {(None, "report.json"): (1, 2, 0o600, b"safe")}
        prior.update({(run_id, "report.json"): (1, index + 3, 0o600, b"safe") for index, run_id in enumerate(diagnose_eof.PRIOR_RUNS)})
        failure = RuntimeError("original raw error")
        argv = ["--arch", "arm64", "--bundle", "bundle", "--confirm-current-profile"]
        with mock.patch.object(diagnose_eof, "report_snapshot", return_value=prior), mock.patch.object(verify, "main", side_effect=failure) as invocation:
            with self.assertRaises(RuntimeError) as observed:
                diagnose_eof.run(argv)
        self.assertIs(observed.exception, failure)
        invocation.assert_called_once_with(argv, manual_observer=None)
        changed = dict(prior)
        changed[(None, "report.json")] = (1, 2, 0o600, b"changed")
        with mock.patch.object(diagnose_eof, "report_snapshot", side_effect=[prior, changed]), mock.patch.object(verify, "main", return_value=2) as invocation:
            with self.assertRaisesRegex(acquire.Failure, "diagnostic_prior_report_changed"):
                diagnose_eof.run(argv)
        invocation.assert_called_once()

    def test_secondary_preservation_failures_keep_original_exception_primary(self):
        prior = {(None, "report.json"): (1, 2, 0o600, b"safe")}
        prior.update({(run_id, "report.json"): (1, index + 3, 0o600, b"safe") for index, run_id in enumerate(diagnose_eof.PRIOR_RUNS)})
        changed = dict(prior)
        changed[(None, "report.json")] = (1, 2, 0o600, b"changed")
        argv = ["--arch", "arm64", "--bundle", "bundle", "--confirm-current-profile"]
        original_start = verify.OSCollector.start
        for secondary in (changed, OSError("private secondary path")):
            with self.subTest(secondary=type(secondary).__name__):
                failure = RuntimeError("original raw error")
                with mock.patch.object(diagnose_eof, "report_snapshot", side_effect=[prior, secondary]), mock.patch.object(verify, "main", side_effect=failure) as invocation:
                    with self.assertRaises(RuntimeError) as observed:
                        diagnose_eof.run(argv)
                self.assertIs(observed.exception, failure)
                self.assertEqual(failure.__notes__, ["EOF diagnostic report preservation check also failed; raw details withheld."])
                self.assertIs(verify.OSCollector.start, original_start)
                invocation.assert_called_once_with(argv, manual_observer=None)

    def test_nine_prior_reports_snapshot_and_one_original_run_preserve_bytes(self):
        root = self.root / "Library/Containers" / verify.IDENTITY / "Data/Library/Application Support/PaperLensTopology"
        root.mkdir(parents=True, mode=0o700)
        (root / "report.json").write_bytes(b"fixed")
        for index, run_id in enumerate(diagnose_eof.PRIOR_RUNS):
            directory = root / "Reports" / run_id
            directory.mkdir(parents=True, mode=0o700)
            (directory / "report.json").write_bytes(bytes([index]))
        receipt, evidence, summary = self.safe_values()
        def main(argv, manual_observer=None):
            print(json.dumps(evidence))
            return 2
        # No live verifier calls: use real safe file reads and fake invocation.
        with mock.patch.object(verify, "current_home", return_value=self.root), mock.patch.object(verify, "no_acl", return_value=True):
            before = diagnose_eof.report_snapshot()
            with mock.patch.object(verify, "main", side_effect=main) as invocation, mock.patch.object(diagnose_eof.Hooks, "__enter__", return_value=mock.Mock(receipt=receipt)), mock.patch.object(diagnose_eof.Hooks, "__exit__", return_value=False):
                status, result, projected = diagnose_eof.run(["--arch", "arm64", "--bundle", "bundle", "--confirm-current-profile"])
            self.assertEqual(diagnose_eof.report_snapshot(), before)
        invocation.assert_called_once()
        self.assertEqual(status, 2)
        self.assertTrue(projected["priorReportsPreserved"])
        self.assertEqual(len(before), 9)

    def test_cli_contains_original_raw_exception_and_does_not_save(self):
        output = io.StringIO()
        with mock.patch.object(diagnose_eof, "run", side_effect=RuntimeError("/Users/private log PID")), mock.patch.object(diagnose_eof, "save") as save, contextlib.redirect_stderr(output):
            self.assertEqual(diagnose_eof.main(["--arch", "arm64", "--bundle", "private", "--confirm-current-profile"]), 2)
        self.assertNotIn("/Users/", output.getvalue())
        self.assertNotIn("PID", output.getvalue())
        save.assert_not_called()


class LogTimeoutControlTests(IsolatedTest):
    control_id = "01234567-89ab-4cde-8fab-0123456789ab"

    class Clock:
        now = 0.0

        def monotonic(self):
            return self.now

        def sleep(self, duration):
            self.now += duration

    class Pipe:
        def __init__(self, fd):
            self.fd = fd
            self.closed = False

        def fileno(self):
            return self.fd

        def close(self):
            self.closed = True

    class Process:
        def __init__(self, clock, finish=0, status=0, reap=True):
            self.clock = clock
            self.finish = finish
            self.status = status
            self.reap = reap
            self.stdout = LogTimeoutControlTests.Pipe(10)
            self.stderr = LogTimeoutControlTests.Pipe(11)
            self.calls = []

        def poll(self):
            return self.status if self.clock.now >= self.finish else None

        def terminate(self):
            self.calls.append("terminate")

        def kill(self):
            self.calls.append("kill")

        def wait(self, timeout):
            self.calls.append(timeout)
            if not self.reap or self.calls.count("kill") == 0:
                self.clock.sleep(timeout)
                raise subprocess.TimeoutExpired("private command", timeout)
            self.status = -9
            self.finish = self.clock.now
            return self.status

    class Selector:
        def __init__(self):
            self.entries = {}

        def register(self, pipe, event, flag):
            self.entries[pipe.fd] = mock.Mock(fd=pipe.fd, fileobj=pipe, data=flag)

        def unregister(self, pipe):
            del self.entries[pipe.fd]

        def select(self, timeout):
            return [(key, 1) for key in self.entries.values()]

        def close(self):
            pass

    def scenario(self, plans, startup=0, read_error=False, late_read=False, hold_eof=False):
        clock = self.Clock()
        launches, processes, reads = [], [], []
        chunks = {}

        def popen(argv, **kwargs):
            launches.append((argv, kwargs))
            plan = plans[len(launches) - 1]
            clock.sleep(startup)
            if isinstance(plan, Exception):
                raise plan
            process = self.Process(clock, clock.now + plan.get("duration", 0),
                                   plan.get("status", 0), plan.get("reap", True))
            processes.append(process)
            chunks.clear()
            chunks.update({10: list(plan.get("stdout", [b""])), 11: list(plan.get("stderr", [b""]))})
            return process

        def read(fd, maximum):
            reads.append((fd, maximum))
            if read_error:
                raise OSError("private path/PID")
            if late_read:
                clock.now = 12
            if (hold_eof or processes[-1].poll() is None) and not chunks[fd]:
                raise BlockingIOError()
            if chunks[fd]:
                chunk = chunks[fd].pop(0)
                if len(chunk) > maximum:
                    chunks[fd].insert(0, chunk[maximum:])
                    chunk = chunk[:maximum]
                return chunk
            return b""

        stack = contextlib.ExitStack()
        self.addCleanup(stack.close)
        for target, name, value in (
            (log_control.time, "monotonic", clock.monotonic),
            (log_control.time, "sleep", clock.sleep),
            (log_control.subprocess, "Popen", popen),
            (log_control.selectors, "DefaultSelector", self.Selector),
            (log_control.os, "set_blocking", lambda *args: None),
            (log_control.os, "read", read),
            (log_control, "_preflight", lambda deadline: ("a" * 40, "25A123")),
        ):
            stack.enter_context(mock.patch.object(target, name, value))
        return clock, launches, processes, reads

    def test_normal_two_launches_exact_argv_and_early_exit_are_observations(self):
        banner = b'Filtering the log data using "processIdentifier = 1 && (processIdentifier == 0)"\n\n'
        clock, launches, processes, reads = self.scenario([
            {"duration": 2, "stdout": [banner]}, {"duration": 60}])
        receipt = log_control.run()
        self.assertEqual(len(launches), 2)
        for (name, argument, _), (argv, kwargs) in zip(log_control.CASES, launches):
            self.assertEqual(argv, ["/usr/bin/log", "stream", "--style", "ndjson", "--timeout",
                                    argument, "--predicate", log_control.PREDICATE])
            self.assertEqual(kwargs["stdin"], subprocess.DEVNULL)
            self.assertEqual(kwargs["stdout"], subprocess.PIPE)
            self.assertEqual(kwargs["stderr"], subprocess.PIPE)
            self.assertEqual(kwargs["env"], acquire.clean_env())
            self.assertEqual(receipt["cases"][name]["status"], "normal-exit")
            self.assertEqual(receipt["cases"][name]["inputReason"], "none")
            self.assertEqual(receipt["cases"][name]["recordKind"], "not-observed")
            self.assertEqual(receipt["cases"][name]["objectMarkers"], "not-observed")
            self.assertEqual(processes[0].calls, [])
        self.assertEqual(receipt["cases"]["integer-two"]["elapsedBand"], "under-5s")
        self.assertEqual(receipt["cases"]["minute-one"]["elapsedBand"], "12-to-under-75s")
        self.assertTrue(receipt["budgetWithinLimit"])
        self.assertTrue(all(maximum <= 8192 for _, maximum in reads))

    def test_start_failure_and_bad_output_prevent_second_launch(self):
        plans = [OSError("/Users/private"), {"status": 1}, {"stderr": [b"private error"]},
                 {"stdout": [b'{}\n']}, {"stdout": [b"partial", b""]},
                 {"stdout": [b'Filtering the log data using "processIdentifier == 0"\n']},
                 {"stdout": [b'Filtering the log data using "' + log_control.PREDICATE.encode() + b'"\n'] * 2}]
        expected = ["start-failed", "source-error", "source-error", "invalid-output", "invalid-output",
                    "invalid-output", "invalid-output"]
        reasons = ["not-observed", "not-observed", "not-observed", "unexpected-record", "partial-eof",
                   "header-shape-mismatch", "duplicate-header"]
        for plan, status, reason in zip(plans, expected, reasons):
            with self.subTest(status=status, plan=plan):
                self.scenario([plan])
                receipt = log_control.run()
                self.assertEqual(receipt["cases"]["integer-two"]["status"], status)
                self.assertEqual(receipt["cases"]["integer-two"]["inputReason"], reason)
                self.assertEqual(receipt["cases"]["integer-two"]["recordKind"],
                                 "json-object" if reason == "unexpected-record" else "not-observed")
                self.assertEqual(receipt["cases"]["integer-two"]["objectMarkers"],
                                 "neither" if reason == "unexpected-record" else "not-observed")
                self.assertEqual(receipt["cases"]["minute-one"], log_control.not_run("1m"))
                self.assertNotIn("private", json.dumps(receipt))

    def test_closed_header_reasons_do_not_widen_acceptance(self):
        prefix = b'Filtering the log data using "'
        banner = prefix + log_control.PREDICATE.encode() + b'"\n'
        cases = [(prefix + b'processIdentifier == 0\n', "header-envelope-invalid"),
                 (prefix + b'\xff"\n', "header-envelope-invalid"),
                 (prefix + b'FALSEPREDICATE"\n', "header-grammar-invalid"),
                 (prefix + b'processID == 0"\n', "header-grammar-invalid"),
                 (prefix + b'processIdentifier != 0"\n', "header-grammar-invalid"),
                 (prefix + b'(' * 65 + log_control.PREDICATE.encode() + b')' * 65 + b'"\n',
                  "header-grammar-invalid"),
                 (prefix + b' AND '.join([b'processIdentifier == 0'] * 300) + b'"\n',
                  "header-grammar-invalid"),
                 (prefix + b'processIdentifier == 0 OR processIdentifier == 1"\n', "header-shape-mismatch"),
                 (prefix + b'processIdentifier == 0 AND processIdentifier == 1 AND category == "extra""\n',
                  "header-shape-mismatch"),
                 (banner + prefix + b'\xff\n', "duplicate-header"),
                 (b'{}\n', "unexpected-record"),
                 (b'other private record\n', "unexpected-record"),
                 (banner + b'{}\n', "unexpected-record"),
                 (b' ' + banner, "unexpected-record")]
        for output, reason in cases:
            with self.subTest(reason=reason, output=output):
                clock, launches, processes, reads = self.scenario([{"stdout": [output]}])
                receipt = log_control.run()
                row = receipt["cases"]["integer-two"]
                self.assertEqual(row["status"], "invalid-output")
                self.assertEqual(row["inputReason"], reason)
                self.assertEqual(receipt["cases"]["minute-one"], log_control.not_run("1m"))
                self.assertEqual(len(launches), 1)
                self.assertNotIn("private", json.dumps(receipt))

    def test_unexpected_record_syntax_kinds_remain_rejected_and_private(self):
        cases = [(b'{"private-key":"private-value"}', "json-object"),
                 (b'{"private-key":1,"private-key":2}', "json-object"),
                 (b'[]', "json-other"), (b'"private-value"', "json-other"),
                 (b'true', "json-other"), (b'false', "json-other"), (b'null', "json-other"),
                 (b'-12.5e+3', "json-other"), (b'  {}\t\r', "json-object"),
                 (b'9' * 5000, "json-other"), (b'1e' + b'9' * 5000, "json-other"),
                 (b'0.' + b'9' * 5000, "json-other"),
                 (b'9' * log_control.RECORD_MAXIMUM, "json-other"),
                 (b'NaN', "text"), (b'Infinity', "text"), (b'-Infinity', "text"),
                 (b'{"private-key":NaN}', "text"), (b'{} null', "text"),
                 (b'{} private trailing', "text"), (b'{"private-key":', "text"),
                 (b'01', "text"), (b'private utility text', "text"),
                 (b'\xef\xbb\xbf{}', "text"), (b'\xff', "invalid-utf8"),
                 (b'{"private-key":"\xc0\xaf"}', "invalid-utf8"),
                 (b'[' * 64 + b'null' + b']' * 64, "json-other"),
                 (b'[' * 65 + b'null' + b']' * 65, "unknown"),
                 (b'{"private-key":' * 64 + b'null' + b'}' * 64, "json-object"),
                 (b'{"private-key":' * 65 + b'null' + b'}' * 65, "unknown"),
                 (b'[' * 64 + json.dumps('[{' * 100 + '"\\' + ']}' * 100).encode() + b']' * 64, "json-other"),
                 (json.dumps({"private-key": '[{' * 100 + '"\\' + ']}' * 100}).encode(), "json-object")]
        for record, kind in cases:
            with self.subTest(kind=kind, size=len(record)):
                clock, launches, processes, reads = self.scenario([{"stdout": [record + b'\n']}])
                receipt = log_control.run()
                row = receipt["cases"]["integer-two"]
                self.assertEqual(row["status"], "invalid-output")
                self.assertEqual(row["inputReason"], "unexpected-record")
                self.assertEqual(row["recordKind"], kind)
                markers = ("unknown" if record == b'{"private-key":1,"private-key":2}' else "neither")
                self.assertEqual(row["objectMarkers"], markers if kind == "json-object" else "not-observed")
                self.assertFalse(row["framingComplete"])
                self.assertFalse(row["stdoutEOF"])
                self.assertEqual(row["stderrEOF"], len(record) + 1 > 8192)
                self.assertEqual(receipt["cases"]["minute-one"], log_control.not_run("1m"))
                self.assertEqual(len(launches), 1)
                self.assertNotIn("private", json.dumps(receipt))

    def test_object_marker_membership_is_single_parse_rejected_and_private(self):
        cases = [(b'{}', "neither"),
                 (b'{"finished":null}', "finished-only"),
                 (b'{"eventType":false}', "event-type-only"),
                 (b'{"finished":false,"eventType":null}', "both"),
                 (b'{"finished":"private-value","eventType":{"private-key":[1,true]}}', "both"),
                 (b'{"finished":[],"eventType":-1.5e9}', "both"),
                 (b'{"private-key":{"finished":true,"eventType":true}}', "neither"),
                 (b'{"private-key":[{"finished":true},{"eventType":true}]}', "neither"),
                 (b'{"unfinished":true,"EventType":true}', "neither"),
                 (b'{"finis\\u0068ed":null,"event\\u0054ype":false}', "both"),
                 (b'{"finished":0,"finished":1}', "unknown"),
                 (b'{"eventType":0,"event\\u0054ype":1}', "unknown"),
                 (b'{"private-key":0,"private-key":1}', "unknown"),
                 (b'{"finished":{"private-key":0,"private-key":1}}', "unknown"),
                 (b'{"eventType":[{"private-key":0,"private-key":1}]}', "unknown"),
                 (b'{"private-key":{"finished":0,"finis\\u0068ed":1}}', "unknown"),
                 (b'{"finished":{},"eventType":{}}', "both")]
        for record, markers in cases:
            with self.subTest(record=record, markers=markers):
                clock, launches, processes, reads = self.scenario([{"stdout": [record + b'\n']}])
                with mock.patch.object(log_control.json, "loads", wraps=json.loads) as parser, \
                     mock.patch.object(log_control.json, "dumps", side_effect=AssertionError("raw serialization")):
                    receipt = log_control.run()
                parser.assert_called_once()
                row = receipt["cases"]["integer-two"]
                self.assertEqual((row["recordKind"], row["objectMarkers"]), ("json-object", markers))
                self.assertEqual((row["status"], row["inputReason"]), ("invalid-output", "unexpected-record"))
                self.assertFalse(row["stdoutEOF"])
                self.assertFalse(row["framingComplete"])
                self.assertEqual(len(launches), 1)
                self.assertEqual(len(reads), 1)
                self.assertEqual(receipt["cases"]["minute-one"], log_control.not_run("1m"))
                serialized = json.dumps(receipt)
                for private in ("private-key", "private-value", "unfinished", "EventType"):
                    self.assertNotIn(private, serialized)

    def test_nonobject_duplicates_and_incomplete_objects_do_not_project_markers(self):
        cases = [(b'[{"finished":0,"finished":1}]', ("json-other", "not-observed")),
                 (b'{"finished":true} {}', ("text", "not-observed")),
                 (b'{"finished":true,"finished":false} trailing', ("text", "not-observed")),
                 (b'{"finished":Infinity}', ("text", "not-observed")),
                 (b'{"finished":', ("text", "not-observed")),
                 (b' ' * (log_control.RECORD_MAXIMUM - 2) + b'{}', ("json-object", "neither")),
                 (b' ' * (log_control.RECORD_MAXIMUM - 1) + b'{}', ("unknown", "not-observed"))]
        for record, expected in cases:
            with self.subTest(expected=expected, size=len(record)):
                self.assertEqual(log_control._record_diagnostic(record), expected)

    def test_projection_exception_after_confirmed_object_preserves_object_kind(self):
        for error in (MemoryError("private resource"), RecursionError("private recursion"),
                      RuntimeError("private projection"), UnicodeError("private projection")):
            with self.subTest(error=type(error).__name__):
                self.scenario([{"stdout": [b'{"finished":false}\n']}])
                with mock.patch.object(log_control, "_object_markers", side_effect=error) as projection, \
                     mock.patch.object(log_control.json, "loads", wraps=json.loads) as parser:
                    receipt = log_control.run()
                parser.assert_called_once()
                projection.assert_called_once()
                row = receipt["cases"]["integer-two"]
                self.assertEqual((row["recordKind"], row["objectMarkers"]), ("json-object", "unknown"))
                self.assertEqual((row["status"], row["inputReason"]), ("invalid-output", "unexpected-record"))
                self.assertNotIn("private", json.dumps(receipt))

    def test_depth_cap_precedes_stdlib_parse_and_numbers_use_nonconverting_hooks(self):
        with mock.patch.object(log_control.json, "loads", wraps=json.loads) as parser:
            self.assertEqual(log_control._record_diagnostic(b'[' * 65 + b'null' + b']' * 65),
                             ("unknown", "not-observed"))
            parser.assert_not_called()
            self.assertEqual(log_control._record_diagnostic(b'[' * 64 + b'null' + b']' * 64),
                             ("json-other", "not-observed"))
            parser.assert_called_once()
            hooks = parser.call_args.kwargs
            self.assertIsNone(hooks["parse_int"]("9" * 5000))
            self.assertIsNone(hooks["parse_float"]("1e" + "9" * 5000))
            with self.assertRaises(json.JSONDecodeError):
                hooks["parse_constant"]("NaN")
            self.assertEqual(hooks["object_pairs_hook"]([("private-key", "private-value")]),
                             {"private-key": None})
            with self.assertRaises(MemoryError):
                hooks["object_pairs_hook"]([("private-key", None)] * (log_control.RECORD_MAXIMUM + 1))

    def test_classifier_is_only_used_for_existing_complete_unexpected_records(self):
        banner = b'Filtering the log data using "' + log_control.PREDICATE.encode() + b'"\n'
        plans = [{"stdout": [b'\n \t\n' + banner]},
                 {"stdout": [banner + banner]}, {"stdout": [b'{"private-key":']},
                 {"stdout": [b'{' * (log_control.RECORD_MAXIMUM + 1) + b'\n']},
                 {"stderr": [b'{}\n']}, {"status": 1}, OSError("private startup")]
        for plan in plans:
            with self.subTest(plan=plan):
                self.scenario([plan, {}])
                with mock.patch.object(log_control, "_record_diagnostic", side_effect=AssertionError("not eligible")) as classifier:
                    receipt = log_control.run()
                classifier.assert_not_called()
                self.assertTrue(all(row["recordKind"] == "not-observed" for row in receipt["cases"].values()))
                self.assertTrue(all(row["objectMarkers"] == "not-observed" for row in receipt["cases"].values()))

    def test_classifier_resource_and_unexpected_exceptions_are_unknown_not_source_errors(self):
        for error in (MemoryError("private resource"), RecursionError("private recursion"),
                      RuntimeError("private implementation"), ValueError("private unexpected")):
            with self.subTest(error=type(error).__name__):
                clock, launches, processes, reads = self.scenario([{"stdout": [b'{}\n']}])
                with mock.patch.object(log_control.json, "loads", side_effect=error):
                    receipt = log_control.run()
                row = receipt["cases"]["integer-two"]
                self.assertEqual(row["status"], "invalid-output")
                self.assertEqual(row["inputReason"], "unexpected-record")
                self.assertEqual(row["recordKind"], "unknown")
                self.assertEqual(row["objectMarkers"], "not-observed")
                self.assertEqual(len(launches), 1)
                self.assertEqual(len(reads), 1)
                self.assertNotIn("private", json.dumps(receipt))
        class FailingDecode(bytes):
            def decode(self, *args, **kwargs):
                raise MemoryError("private decode")
        self.assertEqual(log_control._record_diagnostic(FailingDecode(b'{}')), ("unknown", "not-observed"))

    def test_generic_parser_exceptions_only_classify_existing_invalid_output(self):
        for error in (verify.Failure("private parser detail"), UnicodeError("private parser detail"),
                      OSError("private source detail"), RuntimeError("private source detail")):
            with self.subTest(error=type(error).__name__):
                self.scenario([{}])
                with mock.patch.object(log_control.os, "read", side_effect=error):
                    receipt = log_control.run()
                row = receipt["cases"]["integer-two"]
                parser = isinstance(error, (verify.Failure, UnicodeError))
                self.assertEqual(row["status"], "invalid-output" if parser else "source-error")
                self.assertEqual(row["inputReason"], "parser-exception" if parser else "not-observed")
                self.assertEqual(row["recordKind"], "not-observed")
                self.assertEqual(row["objectMarkers"], "not-observed")
                self.assertEqual(receipt["cases"]["minute-one"], log_control.not_run("1m"))
                self.assertNotIn("private", json.dumps(receipt))
                self.scenario([error])
                receipt = log_control.run()
                self.assertEqual(receipt["cases"]["integer-two"]["status"], "start-failed")
                self.assertEqual(receipt["cases"]["integer-two"]["inputReason"], "not-observed")

    def test_first_rejection_survives_reap_failure_and_later_records(self):
        prefix = b'Filtering the log data using "'
        banner = prefix + log_control.PREDICATE.encode() + b'"\n'
        for output, reason in ((prefix + b'\xff"\n{}\n', "header-envelope-invalid"),
                               (banner + banner + b'{}\n', "duplicate-header"),
                               (b'{}\n' + banner, "unexpected-record")):
            with self.subTest(reason=reason):
                clock, launches, processes, reads = self.scenario([
                    {"duration": 1000, "stdout": [output], "stderr": [], "reap": False}])
                with mock.patch.object(self.Selector, "close", side_effect=OSError("private cleanup")), \
                     mock.patch.object(self.Pipe, "close", side_effect=UnicodeError("private cleanup")):
                    receipt = log_control.run()
                row = receipt["cases"]["integer-two"]
                self.assertEqual(row["status"], "reap-timeout")
                self.assertEqual(row["inputReason"], reason)
                self.assertEqual(row["recordKind"], "json-object" if reason == "unexpected-record" else "not-observed")
                self.assertEqual(row["objectMarkers"], "neither" if reason == "unexpected-record" else "not-observed")
                self.assertFalse(row["reaped"])
                self.assertEqual(len(launches), 1)
                self.assertEqual(len(reads), 1)
                self.assertLessEqual(sum(value for value in processes[0].calls if type(value) is float), 0.3)

    def test_first_unexpected_diagnostic_is_frozen_through_reap_and_later_records(self):
        for record, kind, markers in ((b'{}', "json-object", "neither"),
                                     (b'{"finished":false}', "json-object", "finished-only"),
                                     (b'{"eventType":null}', "json-object", "event-type-only"),
                                     (b'{"finished":0,"eventType":[]}', "json-object", "both"),
                                     (b'{"finished":0,"finished":1}', "json-object", "unknown"),
                                     (b'null', "json-other", "not-observed"),
                                     (b'private text', "text", "not-observed"),
                                     (b'\xff', "invalid-utf8", "not-observed"),
                                     (b'[' * 65, "unknown", "not-observed")):
            with self.subTest(kind=kind):
                clock, launches, processes, reads = self.scenario([
                    {"duration": 1000, "stdout": [record + b'\n{}\n', b'private later\n'],
                     "stderr": [], "reap": False}])
                with mock.patch.object(log_control, "_record_diagnostic", wraps=log_control._record_diagnostic) as classifier, \
                     mock.patch.object(self.Selector, "close", side_effect=OSError("private cleanup")), \
                     mock.patch.object(self.Pipe, "close", side_effect=UnicodeError("private cleanup")):
                    receipt = log_control.run()
                classifier.assert_called_once_with(bytearray(record))
                row = receipt["cases"]["integer-two"]
                self.assertEqual(row["status"], "reap-timeout")
                self.assertEqual(row["inputReason"], "unexpected-record")
                self.assertEqual(row["recordKind"], kind)
                self.assertEqual(row["objectMarkers"], markers)
                self.assertEqual(len(reads), 1)
                self.assertEqual(len(launches), 1)
                self.assertNotIn("private", json.dumps(receipt))

    def test_normal_cleanup_failure_never_claims_none(self):
        for owner in (self.Selector, self.Pipe):
            with self.subTest(owner=owner.__name__):
                clock, launches, processes, reads = self.scenario([{}])
                with mock.patch.object(owner, "close", side_effect=OSError("private cleanup")):
                    receipt = log_control.run()
                row = receipt["cases"]["integer-two"]
                self.assertEqual(row["status"], "source-error")
                self.assertEqual(row["inputReason"], "not-observed")
                self.assertTrue(row["stdoutEOF"])
                self.assertTrue(row["stderrEOF"])
                self.assertTrue(row["reaped"])
                self.assertEqual(len(launches), 1)

    def test_nonzero_at_target_or_after_startup_prevents_second_launch(self):
        for startup, duration in ((13, 0), (0, 12)):
            with self.subTest(startup=startup, duration=duration):
                clock, launches, processes, reads = self.scenario([
                    {"status": 1, "duration": duration, "stdout": [], "stderr": []}], startup=startup)
                receipt = log_control.run()
                row = receipt["cases"]["integer-two"]
                self.assertEqual(row["processAtTarget"], "exit-nonzero")
                self.assertEqual(row["status"], "source-error")
                self.assertEqual(row["inputReason"], "not-observed")
                self.assertTrue(row["reaped"])
                self.assertFalse(row["stopRequested"])
                self.assertEqual(receipt["cases"]["minute-one"], log_control.not_run("1m"))
                self.assertEqual(len(launches), 1)

    def test_timeout_reap_allows_only_second_planned_launch_without_fake_eof(self):
        clock, launches, processes, reads = self.scenario([
            {"duration": 1000, "stdout": [], "stderr": []}, {}])
        receipt = log_control.run()
        row = receipt["cases"]["integer-two"]
        self.assertEqual(row["status"], "forced-timeout")
        self.assertEqual(row["inputReason"], "not-observed")
        self.assertEqual(row["processAtTarget"], "running")
        self.assertFalse(row["stdoutEOF"])
        self.assertFalse(row["stderrEOF"])
        self.assertTrue(row["stopRequested"])
        self.assertTrue(row["reaped"])
        self.assertEqual(processes[0].calls[0], "terminate")
        self.assertIn("kill", processes[0].calls)
        self.assertTrue(processes[0].stdout.closed)
        self.assertEqual(len(launches), 2)
        self.assertLessEqual(sum(value for value in processes[0].calls if type(value) is float), 0.3)

    def test_unconfirmed_reap_prevents_second_case(self):
        clock, launches, processes, reads = self.scenario([
            {"duration": 1000, "stdout": [], "stderr": [], "reap": False}])
        receipt = log_control.run()
        self.assertEqual(receipt["cases"]["integer-two"]["status"], "reap-timeout")
        self.assertEqual(receipt["cases"]["integer-two"]["inputReason"], "not-observed")
        self.assertFalse(receipt["cases"]["integer-two"]["reaped"])
        self.assertEqual(len(launches), 1)

    def test_exit_zero_and_close_do_not_substitute_for_readzero(self):
        clock, launches, processes, reads = self.scenario([
            {"stdout": [], "stderr": []}, {"stdout": [], "stderr": []}], hold_eof=True)
        receipt = log_control.run()
        for name, _, _ in log_control.CASES:
            row = receipt["cases"][name]
            self.assertEqual(row["status"], "forced-timeout")
            self.assertEqual(row["processAtTarget"], "exit-zero")
            self.assertFalse(row["stdoutEOF"])
            self.assertFalse(row["stderrEOF"])
            self.assertFalse(row["stopRequested"])
            self.assertTrue(row["reaped"])
        self.assertTrue(all(process.stdout.closed and process.stderr.closed for process in processes))
        self.assertEqual(len(launches), 2)

    def test_minute_case_has_75_second_cap_instead_of_batch_deadline(self):
        clock, launches, processes, reads = self.scenario([
            {}, {"duration": 1000, "stdout": [], "stderr": []}])
        receipt = log_control.run()
        row = receipt["cases"]["minute-one"]
        self.assertEqual(row["status"], "forced-timeout")
        self.assertEqual(row["elapsedBand"], "75s-or-more")
        self.assertEqual(row["processAtTarget"], "running")
        self.assertGreaterEqual(clock.now, 75)
        self.assertLessEqual(clock.now, 75.3)
        self.assertEqual(len(launches), 2)

    def test_partial_frame_at_target_is_error_and_does_not_allow_second_case(self):
        clock, launches, processes, reads = self.scenario([
            {"duration": 1000, "stdout": [b"partial"], "stderr": []}])
        receipt = log_control.run()
        self.assertEqual(receipt["cases"]["integer-two"]["status"], "invalid-output")
        self.assertEqual(receipt["cases"]["integer-two"]["inputReason"], "partial-target")
        self.assertFalse(receipt["cases"]["integer-two"]["framingComplete"])
        self.assertEqual(receipt["cases"]["minute-one"]["status"], "not-run")
        self.assertEqual(len(launches), 1)

    def test_nonzero_at_target_takes_priority_over_pending_frame(self):
        clock, launches, processes, reads = self.scenario([
            {"duration": 12, "status": 1, "stdout": [b"partial"], "stderr": []}])
        receipt = log_control.run()
        row = receipt["cases"]["integer-two"]
        self.assertEqual(row["processAtTarget"], "exit-nonzero")
        self.assertEqual(row["status"], "source-error")
        self.assertEqual(row["inputReason"], "not-observed")
        self.assertFalse(row["framingComplete"])
        self.assertTrue(row["reaped"])
        self.assertEqual(len(launches), 1)

    def test_startup_counts_toward_target_and_batch_overrun_is_not_hidden(self):
        clock, launches, processes, reads = self.scenario([{}, {}], startup=13)
        receipt = log_control.run()
        self.assertEqual(receipt["cases"]["integer-two"]["status"], "forced-timeout")
        self.assertEqual(receipt["cases"]["integer-two"]["processAtTarget"], "exit-zero")
        self.assertFalse(receipt["cases"]["integer-two"]["stdoutEOF"])
        self.assertEqual(receipt["cases"]["minute-one"]["status"], "normal-exit")
        self.scenario([{}], startup=101)
        receipt = log_control.run()
        self.assertFalse(receipt["budgetWithinLimit"])
        self.assertEqual(receipt["cases"]["minute-one"]["status"], "not-run")

    def test_insufficient_case_budget_never_spawns_and_targets_do_not_grow(self):
        clock, launches, processes, reads = self.scenario([{}])
        row, count = log_control._case("1m", 75, 75, 0)
        self.assertEqual(row, log_control.not_run("1m"))
        self.assertEqual(launches, [])
        clock.now = 25
        row, count = log_control._case("1m", 75, 100, 0)
        self.assertEqual(row, log_control.not_run("1m"))

    def test_readzero_at_target_is_not_normal_and_io_errors_are_safe(self):
        self.scenario([{}, {}], late_read=True)
        receipt = log_control.run()
        row = receipt["cases"]["integer-two"]
        self.assertEqual(row["status"], "forced-timeout")
        self.assertFalse(row["stdoutEOF"])
        self.scenario([{}], read_error=True)
        receipt = log_control.run()
        self.assertEqual(receipt["cases"]["integer-two"]["status"], "source-error")
        self.assertEqual(receipt["cases"]["integer-two"]["inputReason"], "not-observed")
        self.assertEqual(receipt["cases"]["minute-one"]["status"], "not-run")

    def test_record_and_batch_caps_fail_closed(self):
        self.scenario([{"stdout": [b" " * (16384 + 1)]}])
        receipt = log_control.run()
        self.assertEqual(receipt["cases"]["integer-two"]["status"], "output-limit")
        self.assertEqual(receipt["cases"]["integer-two"]["inputReason"], "not-observed")
        self.scenario([{"stdout": [b"\n" * log_control.MAXIMUM]}, {"stdout": [b"\n"]}])
        receipt = log_control.run()
        self.assertEqual(receipt["cases"]["integer-two"]["status"], "normal-exit")
        self.assertEqual(receipt["cases"]["minute-one"]["status"], "output-limit")
        self.assertEqual(receipt["cases"]["minute-one"]["inputReason"], "not-observed")

    def test_elapsed_band_edges(self):
        for duration, band in ((None, "unknown"), (-1, "unknown"), (0, "under-5s"),
                               (4.999, "under-5s"), (5, "5-to-under-12s"),
                               (11.999, "5-to-under-12s"), (12, "12-to-under-75s"),
                               (74.999, "12-to-under-75s"), (75, "75s-or-more")):
            self.assertEqual(log_control.elapsed_band(duration), band)

    def test_pinned_runtime_and_native_preflight_reject_fallback(self):
        runtime = self.root / ".build/topology/arm64/runtime.pre-bounded-roll/python/bin/python3.13"
        runtime.parent.mkdir(parents=True)
        runtime.write_bytes(b"offline runtime identity")
        with mock.patch.object(verify, "ROOT", self.root), mock.patch.object(log_control.sys, "executable", str(runtime)), mock.patch.object(log_control.sys, "version_info", (3, 13, 16)), mock.patch.object(log_control.sys, "platform", "darwin"), mock.patch.object(log_control.platform, "machine", return_value="arm64"):
            with mock.patch.object(log_control, "_query", side_effect=["0", "a" * 40, "25A123"]) as query:
                self.assertEqual(log_control._preflight(100), ("a" * 40, "25A123"))
                self.assertEqual([call.args[0] for call in query.call_args_list], [
                    ["/usr/sbin/sysctl", "-in", "sysctl.proc_translated"],
                    ["/usr/bin/git", "rev-parse", "HEAD"], ["/usr/bin/sw_vers", "-buildVersion"]])
            with mock.patch.object(log_control, "_query", return_value="1"):
                with self.assertRaises(acquire.Failure):
                    log_control._preflight(100)
            for version in ((3, 13, 15), (3, 14, 0)):
                with mock.patch.object(log_control.sys, "version_info", version), mock.patch.object(log_control, "_query") as query:
                    with self.assertRaises(acquire.Failure):
                        log_control._preflight(100)
                    query.assert_not_called()
            with mock.patch.object(log_control.sys, "executable", sys.executable + ".missing"), mock.patch.object(log_control, "_query") as query:
                with self.assertRaises((acquire.Failure, OSError)):
                    log_control._preflight(100)
                query.assert_not_called()
            with mock.patch.object(log_control.platform, "machine", return_value="x86_64"), mock.patch.object(log_control, "_query") as query:
                with self.assertRaises(acquire.Failure):
                    log_control._preflight(100)
                query.assert_not_called()

    def test_preflight_query_timeout_and_raw_errors_are_not_adopted(self):
        with mock.patch.object(log_control.time, "monotonic", return_value=99), mock.patch.object(log_control.subprocess, "run", return_value=mock.Mock(returncode=0, stdout=b"25A123\n", stderr=b"")) as run:
            self.assertEqual(log_control._query(["/usr/bin/sw_vers", "-buildVersion"], 100), "25A123")
            self.assertEqual(run.call_args.kwargs["timeout"], 1)
        for result in (mock.Mock(returncode=1, stdout=b"", stderr=b"private"),
                       mock.Mock(returncode=0, stdout=b"x" * 257, stderr=b""),
                       mock.Mock(returncode=0, stdout=b"25A123", stderr=b"private")):
            with mock.patch.object(log_control.time, "monotonic", return_value=0), mock.patch.object(log_control.subprocess, "run", return_value=result):
                with self.assertRaises(acquire.Failure):
                    log_control._query(["/usr/bin/sw_vers", "-buildVersion"], 100)
        with mock.patch.object(log_control.time, "monotonic", return_value=100), mock.patch.object(log_control.subprocess, "run") as run:
            with self.assertRaises(acquire.Failure):
                log_control._query(["/usr/bin/sw_vers", "-buildVersion"], 100)
            run.assert_not_called()

    def test_preflight_failure_is_fixed_safe_error_without_log_launch(self):
        with mock.patch.object(log_control, "_preflight", side_effect=OSError("/Users/private PID")), mock.patch.object(log_control.subprocess, "Popen") as popen:
            with self.assertRaisesRegex(acquire.Failure, "^control_preflight_failed$"):
                log_control.run()
            popen.assert_not_called()

    def receipt(self):
        return {"controlID": self.control_id, "sourceCommit": "a" * 40, "OSBuild": "25A123",
                "budgetWithinLimit": True, "cases": {name: log_control.not_run(argument)
                                                      for name, argument, _ in log_control.CASES}}

    def test_safe_schema_rejects_extra_keys_wrong_joins_and_types(self):
        mutations = [lambda r: r.update(raw="private"),
                     lambda r: r.update(OSBuild="/Users/private"),
                     lambda r: r.update(sourceCommit="a" * 39),
                     lambda r: r.update(budgetWithinLimit=1),
                     lambda r: r["cases"]["integer-two"].update(timeoutArgument="1m"),
                     lambda r: r["cases"]["integer-two"].update(stdoutEOF=False),
                     lambda r: r["cases"]["integer-two"].update(raw="private"),
                     lambda r: r["cases"]["integer-two"].pop("inputReason"),
                     lambda r: r["cases"]["integer-two"].update(inputReason=None),
                     lambda r: r["cases"]["integer-two"].update(inputReason=True),
                     lambda r: r["cases"]["integer-two"].update(inputReason="private raw header"),
                     lambda r: r["cases"]["integer-two"].pop("recordKind"),
                     lambda r: r["cases"]["integer-two"].update(recordKind=None),
                     lambda r: r["cases"]["integer-two"].update(recordKind=True),
                     lambda r: r["cases"]["integer-two"].update(recordKind="private raw record"),
                     lambda r: r["cases"]["integer-two"].update(recordKind="json-object"),
                     lambda r: r["cases"]["integer-two"].pop("objectMarkers"),
                     lambda r: r["cases"]["integer-two"].update(objectMarkers=None),
                     lambda r: r["cases"]["integer-two"].update(objectMarkers=True),
                     lambda r: r["cases"]["integer-two"].update(objectMarkers="private raw marker"),
                     lambda r: r["cases"]["integer-two"].update(objectMarkers="neither"),
                     lambda r: r["cases"]["integer-two"].update(inputReason="none"),
                     lambda r: r["cases"]["integer-two"].update(inputReason="parser-exception"),
                     lambda r: r["cases"]["integer-two"].update(status="start-failed", inputReason="parser-exception"),
                     lambda r: r["cases"]["integer-two"].update(status="invalid-output"),
                     lambda r: r["cases"]["integer-two"].update(status="normal-exit")]
        for mutate in mutations:
            receipt = self.receipt()
            mutate(receipt)
            with self.assertRaises((acquire.Failure, ValueError)):
                log_control.validate_receipt(receipt)

    def test_record_kind_and_object_markers_closed_enums_and_reason_joins(self):
        for reason in log_control.INPUT_REASONS:
            for kind in log_control.RECORD_KINDS:
                for markers in ("not-observed", "finished-only", "event-type-only", "both", "neither", "unknown"):
                    with self.subTest(reason=reason, kind=kind, markers=markers):
                        receipt = self.receipt()
                        row = receipt["cases"]["integer-two"]
                        row.update(status="source-error", inputReason=reason, recordKind=kind,
                                   objectMarkers=markers)
                        valid = reason != "none" and (
                            (reason == "unexpected-record") == (kind != "not-observed")) and (
                            (kind == "json-object") == (markers != "not-observed"))
                        if valid:
                            self.assertIs(log_control.validate_receipt(receipt), receipt)
                        else:
                            with self.assertRaises(acquire.Failure):
                                log_control.validate_receipt(receipt)
        for status in ("invalid-output", "reap-timeout"):
            for kind in log_control.RECORD_KINDS - {"not-observed"}:
                receipt = self.receipt()
                receipt["cases"]["integer-two"].update(status=status, inputReason="unexpected-record", recordKind=kind,
                                                       objectMarkers="unknown" if kind == "json-object" else "not-observed")
                self.assertIs(log_control.validate_receipt(receipt), receipt)

    def test_object_marker_schema_rejects_wrong_types_even_for_confirmed_object(self):
        for markers in (None, True, 0, [], {}, "finished", "private-value", "not-observed"):
            with self.subTest(markers=markers):
                receipt = self.receipt()
                receipt["cases"]["integer-two"].update(status="invalid-output", inputReason="unexpected-record",
                                                       recordKind="json-object", objectMarkers=markers)
                with self.assertRaises(acquire.Failure):
                    log_control.validate_receipt(receipt)

        receipt = self.receipt()
        row = receipt["cases"]["integer-two"]
        row.update(status="invalid-output", inputReason="unexpected-record", recordKind="json-object",
                   objectMarkers="neither")
        del row["objectMarkers"]
        with self.assertRaises(acquire.Failure):
            log_control.validate_receipt(receipt)

    def test_normal_schema_requires_none_and_never_accepts_it_for_failures(self):
        receipt = self.receipt()
        row = receipt["cases"]["integer-two"]
        row.update(status="normal-exit", stdoutEOF=True, stderrEOF=True, framingComplete=True,
                   reaped=True, stopRequested=False, elapsedBand="under-5s", inputReason="none")
        self.assertIs(log_control.validate_receipt(receipt), receipt)
        for reason in log_control.INPUT_REASONS - {"none"}:
            with self.subTest(reason=reason):
                row["inputReason"] = reason
                with self.assertRaises(acquire.Failure):
                    log_control.validate_receipt(receipt)
        row["inputReason"] = "none"
        for status in log_control.STATUSES - {"normal-exit"}:
            with self.subTest(status=status):
                row["status"] = status
                with self.assertRaises(acquire.Failure):
                    log_control.validate_receipt(receipt)

    def test_exclusive_private_write_and_file_symlink_collisions_preserve(self):
        root = self.root / ".build/topology/arm64"
        root.mkdir(parents=True)
        receipt = self.receipt()
        destination = root / ("log-timeout-control-" + self.control_id + ".json")
        with mock.patch.object(verify, "ROOT", self.root):
            log_control.save(receipt)
            before = destination.stat()
            data = destination.read_bytes()
            self.assertEqual(json.loads(data), receipt)
            self.assertEqual(stat.S_IMODE(before.st_mode), 0o600)
            with self.assertRaises(FileExistsError):
                log_control.save(receipt)
            self.assertEqual(destination.read_bytes(), data)
            self.assertEqual(destination.stat().st_ino, before.st_ino)
            other = self.receipt()
            other["controlID"] = "11234567-89ab-4cde-8fab-0123456789ab"
            link = root / ("log-timeout-control-" + other["controlID"] + ".json")
            link.symlink_to(destination)
            with self.assertRaises(OSError):
                log_control.save(other)
            self.assertTrue(link.is_symlink())
            self.assertEqual(destination.read_bytes(), data)

    def test_cli_emits_only_safe_receipt_or_fixed_error_and_never_retries(self):
        output, errors = io.StringIO(), io.StringIO()
        with mock.patch.object(log_control, "run", return_value=self.receipt()) as run, mock.patch.object(log_control, "save") as save:
            with contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
                self.assertEqual(log_control.main([]), 0)
            self.assertEqual(json.loads(output.getvalue()), self.receipt())
            run.assert_called_once_with()
            save.assert_called_once_with(self.receipt())
        output, errors = io.StringIO(), io.StringIO()
        with mock.patch.object(log_control, "run", side_effect=RuntimeError("/Users/private PID")) as run:
            with contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
                self.assertEqual(log_control.main([]), 2)
            self.assertEqual(output.getvalue(), "")
            self.assertEqual(errors.getvalue(), "Log timeout control failed; no raw output emitted.\n")
            run.assert_called_once_with()
        with mock.patch.object(log_control, "run") as run, contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(log_control.main(["--predicate", "private"]), 2)
            run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
