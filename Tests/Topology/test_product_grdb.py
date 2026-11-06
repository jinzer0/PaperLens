"""Offline synthetic preparation coverage. No Xcode, vendor or runtime execution."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("product_grdb", ROOT / "scripts/product/prepare-grdb.py")
grdb = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(grdb)


class GRDBPreparationTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.source = self.root / "input/grdb-source/src"
        self.source.mkdir(parents=True)
        (self.source / ".git").mkdir()
        (self.source / ".git/config").write_text("[core]\nrepositoryformatversion = 0\nfilemode = true\nbare = false\nlogallrefupdates = true\n")
        self.files = {
            "Package.swift": b"// synthetic manifest, never executed\n",
            "GRDB.xcodeproj/project.pbxproj": b"synthetic official-project fixture\n",
            "GRDB/DatabaseQueue.swift": b"// synthetic tracked input\n",
        }
        for name, data in self.files.items():
            path = self.source / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        self.lock = json.loads(grdb.MANIFEST.read_bytes())
        self.manifest = self.root / "manifest.json"
        self.manifest.write_text(json.dumps(self.lock))
        self.receipt = self.source.parent / "source-only.json"
        self.tree = "1" * 40
        self.receipt_data = {
            "schemaRevision": "grdb-source-only-v1", "sourceOnly": True,
            "lockHash": grdb.digest(self.manifest.read_bytes()), "pin": grdb.PIN,
            "source": "grdb-source/src", "tree": self.tree,
            "packageSwiftSha256": grdb.digest(self.files["Package.swift"]),
        }
        self.write_receipt()
        self.output = self.root / "fresh-output"
        self.arch = "arm64"
        self.built_arch = None
        self.calls = []
        self.image_calls = []
        self.mounted = False
        self.distinct = True
        self.attach_returncode = 0
        self.detach_returncode = 0
        self.detach_hook = None
        self.overrides = {}
        self.build_returncode = 0
        self.build_hook = None
        self.tree_extras = b""
        self.real_toolchain = grdb.validate_toolchain
        self.patches = [
            mock.patch.object(grdb, "PACKAGE_SHA256", self.receipt_data["packageSwiftSha256"]),
            mock.patch.object(grdb.subprocess, "run", side_effect=self.fake_run),
            mock.patch.object(grdb.sys, "platform", "darwin"),
            mock.patch.object(grdb.platform, "machine", return_value="arm64"),
            mock.patch.object(grdb, "validate_toolchain", return_value={"pins": self.lock["toolchain"]}),
            mock.patch.object(grdb, "filesystem_device", side_effect=lambda path:
                              2 if self.mounted and self.distinct and path == self.output else 1),
        ]
        for patch in self.patches:
            patch.start()
            self.addCleanup(patch.stop)

    def write_receipt(self):
        self.receipt.write_text(json.dumps(self.receipt_data))

    def tree_listing(self):
        entries = []
        for name, data in self.files.items():
            oid = hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest()
            entries.append(b"100644 blob " + oid.encode() + b"\t" + name.encode() + b"\0")
        return b"".join(entries) + self.tree_extras

    def framework(self, arch):
        root = self.output / "products/GRDB.framework"
        version = root / "Versions/A"
        for name, data in {
            "GRDB": b"synthetic Mach-O, only mocked static tools inspect it",
            "Headers/GRDB.h": b"// synthetic header",
            "Modules/module.modulemap": b"framework module GRDB {}",
            "Modules/GRDB.swiftmodule/" + arch + "-apple-macos.swiftmodule": b"synthetic module",
            "Resources/Info.plist": plistlib.dumps({"CFBundleExecutable": "GRDB", "CFBundlePackageType": "FMWK"}),
        }.items():
            path = version / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        (root / "Versions/Current").symlink_to("A")
        for name in ("GRDB", "Headers", "Modules", "Resources"):
            (root / name).symlink_to("Versions/Current/" + name)

    def fake_run(self, argv, *, env, stdout, stderr, check):
        if argv[0] == "/usr/bin/hdiutil":
            return self.fake_image_run(argv, env, stdout, stderr, check)
        self.calls.append((argv, env))
        self.assertEqual(argv[:2], ["/usr/bin/sandbox-exec", "-p"])
        self.assertIn("(deny network*)", argv[2])
        self.assertIn("(deny file-write* (require-not ", argv[2])
        self.assertNotIn("(deny file-write*)", argv[2])
        self.assertFalse(check)
        tool, args = argv[3], argv[4:]
        result, error, code = b"", b"", 0
        if tool == "/usr/bin/git":
            if args[-2:] == ["rev-parse", "HEAD"]:
                result = grdb.PIN["commit"].encode()
            elif args[-2:] == ["rev-parse", "HEAD^{tree}"]:
                result = self.tree.encode()
            elif "ls-tree" in args:
                result = self.tree_listing()
            elif "fsck" not in args and "diff" not in args:
                self.fail("unexpected Git invocation")
        elif tool == "/usr/sbin/sysctl":
            result = b"0\n"
        elif tool == "/usr/bin/xcodebuild":
            requested = [arg.removeprefix("ARCHS=") for arg in args if str(arg).startswith("ARCHS=")]
            self.assertEqual(requested, [self.arch])
            self.built_arch = requested[0]
            self.framework(self.built_arch)
            if self.build_hook:
                self.build_hook()
            result, error, code = b"complete build output\nwarning: retained\n", b"complete stderr\n", self.build_returncode
        elif tool == "/usr/bin/lipo":
            self.assertEqual(self.built_arch, "arm64")
            result = (self.built_arch + "\n").encode()
        elif tool == "/usr/bin/otool":
            identifier = "@rpath/GRDB.framework/Versions/A/GRDB"
            result = {
                "-hv": "fixture:\nMach header\n DYLIB\n",
                "-D": "fixture:\n" + identifier + "\n",
                "-L": "fixture:\n " + identifier + " (compatibility version 1.0.0)\n /usr/lib/libsqlite3.dylib (compatibility version 9.0.0)\n /usr/lib/libSystem.B.dylib (compatibility version 1.0.0)\n",
                "-l": f"fixture:\nLoad command 0\n cmd LC_BUILD_VERSION\n platform 1\n minos 15.0\n sdk {self.lock['toolchain']['sdk']}\n",
            }[args[0]].encode()
        else:
            self.fail("unexpected tool invocation")
        result, error, code = self.overrides.get((tool, args[0] if args else ""), (result, error, code))
        if stdout == subprocess.PIPE:
            return subprocess.CompletedProcess(argv, code, result, error)
        stdout.write(result)
        stderr.write(error)
        return subprocess.CompletedProcess(argv, code)

    def fake_image_run(self, argv, env, stdout, stderr, check):
        self.image_calls.append((argv, env))
        self.assertFalse(check)
        self.assertEqual(env, grdb.environment("/var/empty", self.lock["toolchain"]["developerDir"]))
        result, code = b"", 0
        if argv[1] == "create":
            self.assertEqual(argv[2:-1], ["-size", "4g", "-type", "SPARSE", "-fs", "APFS", "-volname", "PaperLens-GRDB"])
            self.image = Path(argv[-1])
            self.assertEqual(self.image.parent.parent, self.output.parent)
            self.assertEqual(self.image.parent.stat().st_mode & 0o777, 0o700)
            self.assertEqual(self.image.parent.stat().st_uid, os.getuid())
            self.assertFalse(self.image.is_relative_to(self.output))
            self.image.write_bytes(b"synthetic image")
        elif argv[1] == "attach":
            self.assertEqual(argv[2:-1], ["-plist", "-nobrowse", "-owners", "on", "-mountpoint", str(self.output)])
            code = self.attach_returncode
            if code == 0:
                self.output.rename(self.image.parent / "underlying-mountpoint")
                self.output.mkdir()
                self.mounted = True
                result = plistlib.dumps({"system-entities": [
                    {"dev-entry": "/dev/disk987s1", "mount-point": str(self.output)}]})
        elif argv[1] == "detach":
            self.assertEqual(argv, ["/usr/bin/hdiutil", "detach", "/dev/disk987s1"])
            self.assertTrue(self.mounted)
            self.assertFalse((self.output / "preparation.json").exists()
                             and self.build_hook is None)
            code = self.detach_returncode
            if code == 0:
                self.output.rename(self.image.parent / "mounted-content")
                (self.image.parent / "underlying-mountpoint").rename(self.output)
                self.mounted = False
                if self.detach_hook:
                    self.detach_hook()
        else:
            self.fail("unexpected image invocation")
        stdout.write(result)
        stderr.write(b"image diagnostic\n")
        return subprocess.CompletedProcess(argv, code)

    def prepare(self):
        return grdb.prepare(self.receipt, self.output, self.arch, self.manifest)

    def assert_failure(self, code):
        with self.assertRaises(grdb.Failure) as failure:
            self.prepare()
        self.assertEqual(failure.exception.code, code)
        self.assertFalse((self.output / "preparation.json").exists())

    def test_write_predicates_are_disjoint_and_only_name_owned_output(self):
        # Predicate regression, not a Seatbelt execution/provenance claim.
        for output in (self.output, self.root / 'quoted-"output\\name'):
            with self.subTest(output=output):
                writable = '(require-any (subpath ' + json.dumps(str(output)) + ') (literal "/dev/null"))'
                self.assertEqual(grdb.sandbox(output),
                    '(version 1)(allow default)(deny network*)'
                    + '(deny file-write* (require-not ' + writable + '))'
                    + '(allow file-write* ' + writable + ')')
                self.assertNotIn(str(self.source), grdb.sandbox(output))
                self.assertNotIn(str(self.manifest), grdb.sandbox(output))
                self.assertNotIn(str(self.receipt), grdb.sandbox(output))
        self.assertEqual(grdb.sandbox(),
            '(version 1)(allow default)(deny network*)'
            '(deny file-write* (require-not (literal "/dev/null")))'
            '(allow file-write* (literal "/dev/null"))')

    def test_real_recipe_exclusive_receipt_and_readonly_input(self):
        arch = "arm64"
        before = grdb.inventory(self.source)
        receipt_bytes = self.receipt.read_bytes()
        result = self.prepare()
        self.assertEqual(grdb.inventory(self.source), before)
        self.assertEqual(self.receipt.read_bytes(), receipt_bytes)
        self.assertEqual(json.loads((self.output / "preparation.json").read_bytes()), result)
        build, env = next((argv, env) for argv, env in self.calls if argv[3] == "/usr/bin/xcodebuild")
        self.assertIn("ARCHS=" + arch, build)
        self.assertIn("ONLY_ACTIVE_ARCH=NO", build)
        self.assertEqual(result["architecture"], arch)
        self.assertFalse(result["runtimeExecuted"])
        self.assertIn("Versions/A/Modules/GRDB.swiftmodule/" + arch + "-apple-macos.swiftmodule", result["frameworkInventory"])
        self.assertIn("CODE_SIGNING_ALLOWED=NO", build)
        self.assertIn("MODULE_CACHE_DIR=" + str(self.output / "cache/clang"), build)
        self.assertEqual(env["CCHROOT"], str(self.output / "cache"))
        self.assertIn("MACOSX_DEPLOYMENT_TARGET=15.0", build)
        self.assertEqual(build[build.index("-target") + 1], "GRDB")
        self.assertEqual(build[build.index("-project") + 1], str(self.source / "GRDB.xcodeproj"))
        self.assertIn("(subpath " + json.dumps(str(self.output)) + ")", build[2])
        self.assertNotIn("SPI_BUILDER", env)
        self.assertNotIn("SQLITE_ENABLE_PREUPDATE_HOOK", env)
        self.assertEqual(env["HOME"], str(self.output / "home"))
        self.assertEqual(env["TMPDIR"], str(self.output / "tmp") + "/")
        self.assertEqual((self.output / "logs/build.stdout").read_bytes(), b"complete build output\nwarning: retained\n")
        self.assertEqual((self.output / "logs/build.stderr").read_bytes(), b"complete stderr\n")
        self.assertEqual(result["frameworkInventory"]["Versions/A/GRDB"]["sha256"], grdb.digest(b"synthetic Mach-O, only mocked static tools inspect it"))
        self.assertFalse(any("swift" == arg or "test" == arg or "codesign" in arg for argv, _ in self.calls for arg in argv))
        existing_receipt = (self.output / "preparation.json").read_bytes()
        with self.assertRaises(grdb.Failure) as failure:
            self.prepare()
        self.assertEqual(failure.exception.code, "OUTPUT_OCCUPIED")
        self.assertEqual((self.output / "preparation.json").read_bytes(), existing_receipt)
        self.assertEqual(grdb.inventory(self.source), before)

    def test_occupied_output_never_accepted_as_cache(self):
        self.output.mkdir()
        marker = self.output / "GRDB.framework"
        marker.write_bytes(b"cached binary must be preserved")
        self.assert_failure("OUTPUT_OCCUPIED")
        self.assertEqual(marker.read_bytes(), b"cached binary must be preserved")
        self.assertEqual(self.calls, [])

    def test_receipt_pin_lock_and_schema_tampering(self):
        for key, value, code in (
            ("sourceOnly", 1, "RECEIPT_INVALID"),
            ("source", "../../elsewhere", "RECEIPT_INVALID"),
            ("tree", "unknown", "RECEIPT_INVALID"),
            ("lockHash", "0" * 64, "INPUT_TAMPERED"),
            ("packageSwiftSha256", "0" * 64, "INPUT_TAMPERED"),
            ("pin", {**grdb.PIN, "version": "7.11.2"}, "INPUT_TAMPERED"),
            ("extra", True, "RECEIPT_INVALID"),
        ):
            with self.subTest(key=key):
                original = self.receipt_data.copy()
                self.receipt_data[key] = value
                self.write_receipt()
                self.assert_failure(code)
                self.assertFalse(self.output.exists())
                self.receipt_data = original
        self.write_receipt()
        self.manifest.write_bytes(self.manifest.read_bytes() + b"\n")
        self.assert_failure("INPUT_TAMPERED")

    def test_duplicate_receipt_fields_are_rejected(self):
        self.receipt.write_bytes(b'{"sourceOnly":true,"sourceOnly":false}')
        self.assert_failure("INVALID_JSON")
        self.assertEqual(self.calls, [])

    def test_source_edits_untracked_files_and_executable_mode_are_rejected(self):
        path = self.source / "GRDB/DatabaseQueue.swift"
        path.write_bytes(b"changed")
        self.assert_failure("SOURCE_TAMPERED")
        path.write_bytes(self.files["GRDB/DatabaseQueue.swift"])
        path.chmod(0o755)
        self.assert_failure("SOURCE_TAMPERED")
        path.chmod(0o644)
        extra = self.source / "GRDB/ignored.swift"
        extra.write_bytes(b"ignored but synchronized by Xcode")
        self.assert_failure("SOURCE_TAMPERED")
        self.assertFalse(self.output.exists())

    def test_source_and_output_symlinks_are_refused(self):
        self.output.symlink_to(self.root / "absent")
        self.assert_failure("SYMLINK_INPUT")
        self.assertFalse((self.root / "absent").exists())
        self.output.unlink()
        path = self.source / "GRDB/DatabaseQueue.swift"
        path.unlink()
        path.symlink_to(self.source / "Package.swift")
        self.assert_failure("SYMLINK_INPUT")

    def test_source_output_overlap_is_refused(self):
        self.output = self.source / "output"
        self.assert_failure("OUTPUT_OVERLAP")
        self.assertFalse(self.output.exists())

    def test_inherited_environment_does_not_reach_build(self):
        with mock.patch.dict(os.environ, {"SPI_BUILDER": "1", "SQLITE_ENABLE_PREUPDATE_HOOK": "1", "DYLD_INSERT_LIBRARIES": "private", "HOME": "/private/user-home"}):
            self.prepare()
        for _, env in self.calls:
            self.assertNotIn("DYLD_INSERT_LIBRARIES", env)
            self.assertNotIn("SPI_BUILDER", env)
            self.assertNotEqual(env["HOME"], "/private/user-home")

    def test_failed_build_keeps_complete_logs_and_partial_output(self):
        self.build_returncode = 65
        self.assert_failure("BUILD_FAILED")
        self.assertEqual((self.output / "logs/build.stderr").read_bytes(), b"complete stderr\n")
        self.assertIn(b"warning: retained", (self.output / "logs/build.stdout").read_bytes())
        self.assertTrue((self.output / "products/GRDB.framework/GRDB").is_file())
        self.assertFalse(self.mounted)
        self.assertFalse(self.image.exists())
        self.assert_failure("OUTPUT_OCCUPIED")

    def test_mount_must_be_distinct_before_any_build_or_toolchain_probe(self):
        self.distinct = False
        self.assert_failure("WORKSPACE_NOT_DISTINCT")
        grdb.validate_toolchain.assert_not_called()
        self.assertFalse(any(argv[3] == "/usr/bin/xcodebuild" for argv, _ in self.calls))
        self.assertFalse(self.mounted)
        self.assertTrue(self.image.exists())

    def test_unowned_workspace_is_rejected_before_image_creation(self):
        uid = os.getuid()
        with mock.patch.object(grdb.os, "getuid", return_value=uid + 1):
            self.assert_failure("WORKSPACE_OWNERSHIP_INVALID")
        self.assertEqual(self.image_calls, [])
        self.assertFalse(any(argv[3] == "/usr/bin/xcodebuild" for argv, _ in self.calls))

    def test_attach_failure_preserves_resources_and_never_compiles(self):
        self.attach_returncode = 1
        self.assert_failure("WORKSPACE_ATTACH_FAILED")
        self.assertTrue(self.image.exists())
        self.assertEqual((self.image.parent / "logs/attach.stderr").read_bytes(), b"image diagnostic\n")
        self.assertFalse(any(argv[1] == "detach" for argv, _ in self.image_calls))
        grdb.validate_toolchain.assert_not_called()

    def test_detach_failure_never_publishes_receipt_or_deletes_backing_image(self):
        self.detach_returncode = 1
        self.assert_failure("WORKSPACE_DETACH_FAILED")
        self.assertTrue(self.mounted)
        self.assertTrue(self.image.exists())
        self.assertEqual((self.image.parent / "export/logs/build.stdout").read_bytes(),
                         b"complete build output\nwarning: retained\n")
        self.assertTrue((self.image.parent / "export/products/GRDB.framework/GRDB").is_file())

    def test_copy_tampering_is_detected_before_receipt_and_retains_recovery_image(self):
        real_copy = grdb.shutil.copytree

        def tamper(source, destination, *args, **kwargs):
            result = real_copy(source, destination, *args, **kwargs)
            path = Path(destination) / "build.stdout"
            if path.exists():
                path.write_bytes(b"altered export")
            return result

        with mock.patch.object(grdb.shutil, "copytree", side_effect=tamper):
            self.assert_failure("EXPORT_INVALID")
        self.assertFalse(self.mounted)
        self.assertTrue(self.image.exists())

    def test_exported_framework_is_rechecked_after_detach(self):
        def tamper():
            (self.image.parent / "export/products/GRDB.framework/Versions/A/GRDB").write_bytes(b"changed after validation")
        self.detach_hook = tamper
        self.assert_failure("OUTPUT_INVALID")
        self.assertTrue(self.image.exists())

    def test_exported_logs_are_rechecked_after_detach(self):
        def tamper():
            (self.image.parent / "export/logs/build.stdout").write_bytes(b"changed after validation")
        self.detach_hook = tamper
        self.assert_failure("EXPORT_INVALID")
        self.assertTrue(self.image.exists())

    def test_unexpected_file_under_mountpoint_is_not_overwritten(self):
        self.detach_hook = lambda: (self.output / "marker").write_bytes(b"preserved")
        self.assert_failure("OUTPUT_OCCUPIED")
        self.assertEqual((self.output / "marker").read_bytes(), b"preserved")
        self.assertTrue(self.image.exists())

    def test_input_drift_during_detach_cannot_publish_receipt(self):
        self.detach_hook = lambda: self.manifest.write_bytes(self.manifest.read_bytes() + b"\n")
        self.assert_failure("INPUT_TAMPERED")
        self.assertTrue(self.image.exists())

    def test_pifcache_permission_failure_preserves_inputs_and_failed_namespace(self):
        before = grdb.inventory(self.source)
        receipt_bytes, manifest_bytes = self.receipt.read_bytes(), self.manifest.read_bytes()
        stdout = (b"ComputePackagePrebuildTargetDependencyGraph\n"
            b"error: NSCocoaErrorDomain Code=513; NSPOSIXErrorDomain Code=1\n")
        stderr = b"** BUILD FAILED **\nCompute target dependency graph for package preparation\n"
        self.overrides[("/usr/bin/xcodebuild", "-project")] = (stdout, stderr, 65)
        self.assert_failure("BUILD_FAILED")
        self.assertEqual(grdb.inventory(self.source), before)
        self.assertEqual(self.receipt.read_bytes(), receipt_bytes)
        self.assertEqual(self.manifest.read_bytes(), manifest_bytes)
        calls = len(self.calls)
        self.assert_failure("OUTPUT_OCCUPIED")
        self.assertEqual(len(self.calls), calls)
        self.assertEqual((self.output / "logs/build.stdout").read_bytes(), stdout)
        self.assertEqual((self.output / "logs/build.stderr").read_bytes(), stderr)

    def test_post_build_input_drift_never_receives_success_receipt(self):
        self.build_hook = lambda: self.manifest.write_bytes(self.manifest.read_bytes() + b"\n")
        self.assert_failure("INPUT_TAMPERED")
        self.assertTrue((self.output / "logs/build.stdout").exists())

    def test_receipt_collision_is_preserved_and_refused(self):
        self.build_hook = lambda: (self.output / "preparation.json").write_bytes(b"concurrent artifact")
        with self.assertRaises(grdb.Failure) as failure:
            self.prepare()
        self.assertEqual(failure.exception.code, "OUTPUT_OCCUPIED")
        self.assertFalse((self.output / "preparation.json").exists())
        self.assertEqual((self.image.parent / "mounted-content/preparation.json").read_bytes(), b"concurrent artifact")
        self.assertTrue(self.image.exists())

    def test_input_drift_during_toolchain_probes_never_compiles(self):
        def drift(*args):
            self.manifest.write_bytes(self.manifest.read_bytes() + b"\n")
            return {}
        with mock.patch.object(grdb, "validate_toolchain", side_effect=drift):
            self.assert_failure("INPUT_TAMPERED")
        self.assertFalse(any(argv[3] == "/usr/bin/xcodebuild" for argv, _ in self.calls))

    def test_wrong_cpu_deployment_install_id_and_nonsystem_link_are_refused(self):
        cases = [
            (("/usr/bin/lipo", "-archs"), b"x86_64\n"),
            (("/usr/bin/otool", "-D"), b"fixture:\n/tmp/cached/GRDB\n"),
            (("/usr/bin/otool", "-l"), f"fixture:\nLoad command 0\n cmd LC_BUILD_VERSION\n platform 1\n minos 14.0\n sdk {self.lock['toolchain']['sdk']}\n".encode()),
            (("/usr/bin/otool", "-L"), b"fixture:\n @rpath/GRDB.framework/Versions/A/GRDB (compatibility version 1.0.0)\n @rpath/libsqlite3.dylib (compatibility version 9.0.0)\n"),
        ]
        for index, (key, value) in enumerate(cases):
            with self.subTest(key=key):
                self.output = self.root / ("bad-output-" + str(index))
                self.overrides = {key: (value, b"", 0)}
                self.assert_failure("OUTPUT_INVALID")

    def test_framework_symlink_escape_is_refused(self):
        def escape():
            path = self.output / "products/GRDB.framework/Headers"
            path.unlink()
            path.symlink_to(self.source)
        self.build_hook = escape
        self.assert_failure("OUTPUT_INVALID")

    def test_framework_missing_module_is_refused(self):
        self.build_hook = lambda: (self.output / "products/GRDB.framework/Versions/A/Modules/GRDB.swiftmodule/arm64-apple-macos.swiftmodule").unlink()
        self.assert_failure("OUTPUT_INVALID")

    def test_wrong_and_fat_binary_cpu_are_refused(self):
        for index, reported in enumerate(("x86_64", "arm64 x86_64")):
            with self.subTest(reported=reported):
                self.output = self.root / ("wrong-cpu-" + str(index))
                self.overrides = {("/usr/bin/lipo", "-archs"): ((reported + "\n").encode(), b"", 0)}
                self.assert_failure("OUTPUT_INVALID")

    def test_other_cpu_swiftmodule_is_not_a_fallback(self):
        def mismatch():
            modules = self.output / "products/GRDB.framework/Versions/A/Modules/GRDB.swiftmodule"
            (modules / "arm64-apple-macos.swiftmodule").rename(modules / "x86_64-apple-macos.swiftmodule")
        self.build_hook = mismatch
        self.assert_failure("OUTPUT_INVALID")

    def test_intel_request_is_rejected_before_input_or_output_probes(self):
        self.arch = "x86_64"
        self.output.mkdir()
        marker = self.output / "historical-evidence"
        marker.write_bytes(b"preserve failed Intel preparation")
        with mock.patch.object(grdb, "checked_path") as checked_path, mock.patch.object(grdb, "validate_inputs") as validate_inputs, mock.patch.object(grdb, "inventory") as inventory:
            self.assert_failure("INVALID_ARCHITECTURE")
            with self.assertRaises(grdb.Failure) as failure:
                grdb.build_arguments(None, None, None, "x86_64")
            self.assertEqual(failure.exception.code, "INVALID_ARCHITECTURE")
            with self.assertRaises(grdb.Failure) as failure:
                grdb.validate_output(None, None, None, "x86_64")
            self.assertEqual(failure.exception.code, "INVALID_ARCHITECTURE")
            checked_path.assert_not_called()
            validate_inputs.assert_not_called()
            inventory.assert_not_called()
        self.assertEqual(marker.read_bytes(), b"preserve failed Intel preparation")
        self.assertEqual(list(self.output.iterdir()), [marker])
        self.assertEqual(self.calls, [])

    def test_invalid_architecture_never_probes_or_creates_output(self):
        for arch in (None, "", "ARM64", "aarch64", "x86_64", "arm64 x86_64", "x86_64;touch owned", "x86_64\nCODE_SIGNING_ALLOWED=YES"):
            with self.subTest(arch=arch):
                self.arch = arch
                self.assert_failure("INVALID_ARCHITECTURE")
                with self.assertRaises(grdb.Failure) as failure:
                    grdb.build_arguments(self.source, self.output, self.lock, arch)
                self.assertEqual(failure.exception.code, "INVALID_ARCHITECTURE")
                with self.assertRaises(grdb.Failure) as failure:
                    grdb.validate_output(self.output, self.lock, {}, arch)
                self.assertEqual(failure.exception.code, "INVALID_ARCHITECTURE")
                self.assertEqual(self.calls, [])
                self.assertFalse(self.output.exists())

    def test_architecture_is_required_by_all_builder_apis(self):
        for function, args in (
            (grdb.prepare, (self.receipt, self.output)),
            (grdb.build_arguments, (self.source, self.output, self.lock)),
            (grdb.validate_output, (self.output, self.lock, {})),
        ):
            with self.subTest(function=function.__name__), self.assertRaises(TypeError):
                function(*args)
        self.assertEqual(self.calls, [])
        self.assertFalse(self.output.exists())

    def test_cli_missing_invalid_or_injected_architecture_has_no_owned_effects(self):
        base = ["prepare-grdb.py", "--source-receipt", str(self.receipt), "--output", str(self.output)]
        for suffix in ([], ["--arch", "aarch64"], ["--arch", "x86_64"], ["--arch", "x86_64;touch owned"], ["--arch", "arm64 x86_64"]):
            with self.subTest(suffix=suffix), mock.patch.object(grdb.sys, "argv", base + suffix), mock.patch("sys.stderr"), mock.patch.object(grdb, "prepare") as prepare:
                with self.assertRaises(SystemExit) as failure:
                    grdb.main()
                self.assertEqual(failure.exception.code, 2)
                prepare.assert_not_called()
        self.assertEqual(self.calls, [])
        self.assertFalse(self.output.exists())

    def test_cli_forwards_explicit_arm64_architecture(self):
        argv = ["prepare-grdb.py", "--source-receipt", str(self.receipt), "--output", str(self.output), "--manifest", str(self.manifest), "--arch", "arm64"]
        with mock.patch.object(grdb.sys, "argv", argv), mock.patch("builtins.print"), mock.patch.object(grdb, "prepare", return_value={"schemaRevision": "grdb-unsigned-preparation-v1"}) as prepare:
            self.assertEqual(grdb.main(), 0)
            prepare.assert_called_once_with(self.receipt, self.output, "arm64", self.manifest)

    def test_translated_host_never_starts_build(self):
        self.overrides[("/usr/sbin/sysctl", "-in")] = (b"1\n", b"", 0)
        self.assert_failure("NATIVE_ARM64_REQUIRED")
        self.assertFalse(self.output.exists())
        self.assertFalse(any(argv[3] == "/usr/bin/xcodebuild" for argv, _ in self.calls))

    def test_explicit_artifact_cpu_does_not_expand_execution_hosts(self):
        for system, machine in (("darwin", "x86_64"), ("linux", "arm64")):
            with self.subTest(system=system, machine=machine), mock.patch.object(grdb.sys, "platform", system), mock.patch.object(grdb.platform, "machine", return_value=machine):
                self.assert_failure("NATIVE_ARM64_REQUIRED")
                self.assertFalse(self.output.exists())
        self.assertFalse(any(argv[3] == "/usr/bin/xcodebuild" for argv, _ in self.calls))

    def test_local_git_command_configuration_is_refused(self):
        (self.source / ".git/config").write_text('[include]\npath = /private/user-config\n')
        self.assert_failure("SOURCE_TAMPERED")
        self.assertEqual(self.calls, [])

    def test_git_object_validation_failure_is_not_hidden(self):
        self.overrides[("/usr/bin/git", "--no-optional-locks")] = (b"", b"private upstream path", 128)
        self.assert_failure("TOOL_FAILED")
        self.assertFalse(self.output.exists())

    def test_pinned_internal_link_and_uninitialized_gitlink(self):
        link = self.source / "Tests/CustomSQLite/GRDB"
        link.parent.mkdir(parents=True)
        link.symlink_to("../..")
        target = b"../.."
        oid = hashlib.sha1(b"blob " + str(len(target)).encode() + b"\0" + target).hexdigest()
        self.tree_extras = (
            b"120000 blob " + oid.encode() + b"\tTests/CustomSQLite/GRDB\0"
            + b"160000 commit " + b"2" * 40 + b"\tSQLiteCustom/src\0"
        )
        self.prepare()
        self.assertFalse((self.source / "SQLiteCustom/src").exists())
        self.output = self.root / "materialized-submodule-refused"
        submodule = self.source / "SQLiteCustom/src"
        submodule.mkdir(parents=True)
        (submodule / "sqlite3.c").write_bytes(b"unapproved materialized source")
        self.assert_failure("SOURCE_TAMPERED")

    def test_toolchain_probes_reject_changed_versions_and_linker_path(self):
        pins = self.lock["toolchain"]
        developer = pins["developerDir"]
        replies = {
            "xcode": f"Xcode {pins['xcode']}\nBuild version {pins['build']}".encode(),
            "sdk-version": pins["sdk"].encode(),
            "swift": ("Apple Swift version " + pins["swift"] + " (synthetic)").encode(),
            "sdk-path": (developer + "/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk").encode(),
            "linker-path": (developer + "/Toolchains/XcodeDefault.xctoolchain/usr/bin/ld").encode(),
            "linker-version": json.dumps({"version": pins["systemLinkerVersion"]}).encode(),
        }
        env = grdb.environment(self.root, developer)
        with mock.patch.object(grdb.Path, "is_dir", return_value=True), mock.patch.object(grdb, "read_bytes", return_value=b"synthetic linker"):
            for label, wrong in (
                ("xcode", b"Xcode 27.0\nBuild version 27A266a"),
                ("sdk-version", b"27.0"),
                ("swift", b"Apple Swift version 6.4.1 (different)"),
                ("linker-version", b'{"version":"27037.1"}'),
                ("xcode", b"Xcode 26.0\nBuild version different"),
                ("sdk-version", b"26.0"),
                ("swift", b"Apple Swift version 6.3 (different)"),
                ("sdk-path", b"/tmp/unapproved.sdk"),
                ("linker-path", b"/tmp/unapproved-ld"),
                ("linker-version", b'{"version":"different"}'),
            ):
                with self.subTest(label=label):
                    changed = {**replies, label: wrong}
                    with mock.patch.object(grdb, "command", side_effect=lambda argv, env, **kw: changed[kw["label"]]):
                        with self.assertRaises(grdb.Failure) as failure:
                            self.real_toolchain(self.lock, env, self.output)
                    self.assertEqual(failure.exception.code, "TOOLCHAIN_MISMATCH")


if __name__ == "__main__":
    unittest.main()
