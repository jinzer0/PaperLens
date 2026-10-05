"""Offline regression tests. No network, fetched tools, signing or GUI execution."""
import base64
import contextlib
import csv
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
+      auto stack = pdfium::span(stack_).first(stack_count_);
+      auto begin_it = stack.end() - n;
       auto middle_it = begin_it - j;
-      auto end_it = std::begin(stack_) + stack_count_;
-      std::rotate(begin_it, middle_it, end_it);
+      std::rotate(begin_it, middle_it, stack.end());
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
    def test_wrong_profile_blocks_gui_and_real_container_access(self):
        output = io.StringIO()
        with mock.patch.object(verify, "native_cpu", return_value=("arm64", False)), mock.patch.object(verify, "command", return_value=(0, b"25A1", b"")) as commands, mock.patch.object(verify, "inspect_bundle"), mock.patch.object(verify, "clean_account", return_value=False), mock.patch.object(verify, "gui_run") as gui, contextlib.redirect_stdout(output):
            status = verify.main(["--arch", "arm64", "--bundle", str(self.root / "PaperLens.app"), "--confirm-clean-profile"])
        gui.assert_not_called()
        evidence = json.loads(output.getvalue())
        self.assertEqual(status, 2)
        self.assertEqual(evidence["verdict"], "blocked")
        self.assertFalse(evidence["storyDone"])
        self.assertTrue(any(item["reason"] == "exact_clean_fixture_profile_required" for item in evidence["automated"]))
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
        row = {"caseID": "mainCanaryRead", "actorInstanceRef": "agent-1", "operation": "read", "fixtureID": "M", "errno": 13, "syscallResult": -1, "verdict": "pass", "sandboxDenialRef": "/private/log/secret"}
        report = {"schemaRevision": "topology-v1", "runID": run_id, "cases": [row]}
        projected = verify.project_cases(report, run_id)[0]
        self.assertEqual(projected["verdict"], "inconclusive")
        self.assertIsNone(projected["sandboxDenialRef"])
        row["promptObserved"] = True
        self.assertEqual(verify.project_cases(report, run_id)[0]["verdict"], "inconclusive")

    def test_unsafe_report_alias_is_rejected(self):
        run_id = "01234567-89ab-4cde-8fab-0123456789ab"
        report = {"schemaRevision": "topology-v1", "runID": run_id, "cases": [{"caseID": "read", "actorInstanceRef": "agent", "operation": "read", "fixtureID": "/Users/private"}]}
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

    def test_control_owner_cannot_run_in_real_profile(self):
        with mock.patch.object(verify, "clean_account", return_value=False), mock.patch.object(Path, "mkdir") as mkdir:
            with self.assertRaisesRegex(acquire.Failure, "fixture_profile_mismatch"):
                verify.Controls("01234567-89ab-4cde-8fab-0123456789ab")
        mkdir.assert_not_called()


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
        (bundle / "Contents/Resources/fixture-map.json").write_text(json.dumps({"groupRoot": str(verify.HOME / "Library/Group Containers" / verify.GROUP)}))
        return bundle

    def test_profile_rejection_never_launches_group_owner(self):
        with mock.patch.object(verify, "clean_account", return_value=False), mock.patch.object(verify.subprocess, "Popen") as launch:
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
        with mock.patch.object(verify, "ROOT", self.root), mock.patch.object(verify, "clean_account", return_value=True), mock.patch.object(packaging, "inspect_macho", return_value="executable"), mock.patch.object(packaging, "verify_signature") as signed, mock.patch.object(verify.subprocess, "Popen", return_value=process) as launch:
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
        with mock.patch.object(verify, "ROOT", self.root), mock.patch.object(verify, "clean_account", return_value=True), mock.patch.object(packaging, "inspect_macho", return_value="executable"), mock.patch.object(packaging, "verify_signature", side_effect=packaging.Failure("signed_team_mismatch")), mock.patch.object(verify.subprocess, "Popen") as launch:
            owner = verify.GroupOwner("arm64", self.run_id)
            with self.assertRaises(packaging.Failure):
                owner.start()
        launch.assert_not_called()

    def test_unavailable_owner_blocks_main_without_starting_external_controls(self):
        control = mock.Mock(pre=False, post=False, network_pre=False, network_post=False, inbound_pre=False, inbound_post=False)
        owner = mock.Mock(process=None, ready=False)
        owner.start.side_effect = acquire.Failure("group_owner_fixture_unavailable")
        owner.finish.return_value = None
        evidence = verify.base_evidence("arm64")
        with mock.patch.object(verify, "HOME", self.root), mock.patch.object(verify, "REPORT", self.root / "report.json"), mock.patch.object(verify, "clean_account", return_value=True), mock.patch.object(verify, "Controls", return_value=control), mock.patch.object(verify, "GroupOwner", return_value=owner), mock.patch.object(verify, "command") as commands:
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
        with self.assertRaisesRegex(acquire.Failure, "group_owner_fixture_unavailable"):
            verify.group_message({"status": "blocked", "fixtureID": "G", "reason": "profileOrGroupUnavailable"}, self.run_id, "ready")
        with self.assertRaisesRegex(acquire.Failure, "group_owner_inconsistent_post"):
            verify.group_message(dict(post, absent=False), self.run_id, "post")
        with self.assertRaisesRegex(acquire.Failure, "duplicate_evidence_key"):
            verify.decode_json(b'{"status":"ready","status":"blocked"}')

    def test_bounded_pipe_timeout_and_oversize(self):
        with mock.patch.object(verify, "clean_account", return_value=True):
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
