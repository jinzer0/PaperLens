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

    def test_both_target_builds_reuse_same_immutable_tool_resolution(self):
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
        for arch, tag in (("arm64", "macosx_11_0_arm64"), ("x86_64", "macosx_10_9_x86_64")):
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

    def test_current_consent_is_not_clean_profile_or_two_cpu_proof(self):
        status, evidence, inspect, home, gui = self.invoke(consent=True)
        self.assertEqual(status, 2)
        inspect.assert_called_once()
        home.assert_called_once()
        gui.assert_called_once()
        manual = {row["caseID"]: row for row in evidence["manual"]}
        self.assertEqual(manual["currentProfile"]["verdict"], "inconclusive")
        self.assertEqual(manual["cleanProfile"]["verdict"], "blocked")
        self.assertFalse(evidence["actualTwoCPU"])
        self.assertFalse(evidence["storyDone"])
        self.assertEqual(evidence["p1"], "unverified")
        self.assertEqual(evidence["verdict"], "blocked")
        self.assertTrue(all(row["verdict"] == "blocked" for row in evidence["remote"]))

    def test_native_intel_remains_static_only_even_with_consent(self):
        _, evidence, inspect, home, gui = self.invoke("x86_64", consent=True)
        inspect.assert_called_once()
        home.assert_not_called()
        gui.assert_not_called()
        self.assertEqual(evidence["intelDynamic"]["executionStatus"], "unexecuted")
        self.assertTrue(any(row["reason"] == "intel_dynamic_waived_support_unverified" for row in evidence["automated"]))

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
        bundle = self.root / "PaperLens.app"
        contract = bundle / "Contents/Resources/contract.json"
        contract.parent.mkdir(parents=True)
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
            observer.poll()
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
        with mock.patch.object(verify, "no_acl", return_value=True), mock.patch.object(observer, "query", return_value=records), mock.patch.object(verify, "collect_os_evidence", return_value=[]):
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
        self.assertTrue((path / "post-continue.json").exists())

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

    def test_clock_ambiguity_and_network_actual_stage_are_not_promoted(self):
        bindings = verify.actor_records(self.identities(), self.ready()["actors"])
        paths = verify.fixture_paths(self.root, self.run_id)
        file_event = {"processID": 102, "eventMessage": f"Sandbox: Python(102) deny(1) file-read-data {paths['M']}", "machTimestamp": 10}
        bind_event = {"processID": 102, "eventMessage": "Sandbox: Python(102) deny(1) network-bind 127.0.0.1:18766"}
        rows = verify.safe_denial_projection([file_event, file_event, bind_event], bindings, paths, {"mainCanaryRead": {"beganAtNs": 10, "endedAtNs": 20}})
        self.assertEqual(len(rows), 2)
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
        event = {"processID": 0, "eventMessage": f"Sandbox: Python(102) deny(1) file-write-data {paths['M']}"}
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
        with mock.patch.object(verify, "bounded_query", return_value=(0, b"[]")) as query:
            self.assertEqual(verify.collect_os_evidence(bindings, paths, {}, time.monotonic() + 1), [])
        arguments = query.call_args.args[0]
        self.assertEqual(arguments[:3], ["/usr/bin/log", "show", "--last"])
        predicate = arguments[-1]
        for pid in (100, 101, 102, 103):
            self.assertIn(f"processID == {pid}", predicate)
        self.assertIn(self.run_id, predicate)
        self.assertIn("file-write-data", predicate)
        self.assertIn("network-bind", predicate)
        self.assertNotIn("process ==", predicate)
        self.assertEqual(query.call_args.kwargs["maximum"], 1024**2)


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


if __name__ == "__main__":
    unittest.main()
