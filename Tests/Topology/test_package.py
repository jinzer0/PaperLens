"""Synthetic filesystem/mocked-tool tests; no signing, downloads, or runtime execution."""

import base64
import copy
import csv
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch

MODULE_PATH = Path(__file__).resolve().parents[2] / "scripts/topology/package.py"
SPEC = importlib.util.spec_from_file_location("topology_package", MODULE_PATH)
package = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(package)


class PackagingTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()

    def file(self, relative, data=b"data", executable=False):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        path.chmod(0o755 if executable else 0o644)
        return path

    def binary(self, relative, executable=True):
        # Deliberately not runnable. Native tools are always mocked in these tests.
        return self.file(relative, b"\xcf\xfa\xed\xfe" + b"synthetic", executable)

    def runtime(self):
        runtime = self.root / "runtime"
        self.binary("runtime/bin/python3.13")
        self.binary("runtime/lib/libpython3.13.dylib", False)
        self.binary("runtime/lib/python3.13/lib-dynload/_struct.so", False)
        self.file("runtime/lib/python3.13/os.py")
        self.file("runtime/lib/python3.13/encodings/__init__.py")
        self.file("runtime/include/python3.13/patchlevel.h", b'#define PY_VERSION "3.13.16"\n')
        site = runtime / "lib/python3.13/site-packages"
        for name, version in (package.PINS | package.PYTHON_BUNDLED_DISTRIBUTIONS).items():
            info = site / (name.replace("-", "_") + "-" + version + ".dist-info")
            info.mkdir(parents=True)
            (info / "METADATA").write_text(f"Name: {name}\nVersion: {version}\n")
            (info / "WHEEL").write_text("Wheel-Version: 1.0\n")
            (info / "RECORD").write_text("")
        cli = self.binary("runtime/lib/python3.13/site-packages/codex_cli_bin/bin/codex")
        record = site / "openai_codex_cli_bin-0.160.0.dist-info/RECORD"
        encoded = base64.urlsafe_b64encode(bytes.fromhex(package.digest(cli))).rstrip(b"=").decode()
        with record.open("w", newline="") as stream:
            csv.writer(stream).writerow([cli.relative_to(site).as_posix(), "sha256=" + encoded, str(cli.stat().st_size)])
        return runtime, cli, record

    def app(self):
        app = self.root / "products/PaperLens.app"
        for relative, identifier, executable, rights, entitlement_source in package.BUNDLES:
            bundle = app / relative
            info = {"CFBundleIdentifier": identifier, "CFBundleExecutable": executable, "CFBundlePackageType": "XPC!" if relative else "APPL"}
            self.file((bundle / "Contents/Info.plist").relative_to(self.root), plistlib.dumps(info))
            self.binary((bundle / "Contents/MacOS" / executable).relative_to(self.root))
            self.file((bundle / "Contents/Resources/contract.json").relative_to(self.root), b"{}")
            self.file((bundle / "Contents/Resources/fixture-map.json").relative_to(self.root), b"{}")
            self.file(entitlement_source, plistlib.dumps(rights))
        return app

    def manifest(self):
        return {
            "schemaRevision": "topology-v1", "arch": "arm64", "team": package.TEAM,
            "sourceBaseCommit": "a" * 40, "sourceDirty": True, "sourceTreeHash": "b" * 64,
            "artifactHash": "c" * 64, "acquisitionHash": "d" * 64, "dependencyLockHash": "e" * 64,
            "files": [{"path": "Contents/MacOS/PaperLens", "kind": "executable", "mode": 0o755, "sourceSHA256": "f" * 64, "signedSHA256": "0" * 64, "identifier": package.IDENTITY, "entitlements": {package.SANDBOX: True, package.NETWORK: True}}],
            "notarization": "not_performed", "storyDone": False,
        }

    def test_missing_bundle_and_runtime_fail_before_tools(self):
        with patch.object(package, "command") as command:
            with self.assertRaises(package.Failure):
                package.validate_bundles(self.root / "missing.app")
            with self.assertRaises(package.Failure):
                package.validate_runtime(self.root / "missing-python")
            command.assert_not_called()

    def test_both_real_xpc_executables_required(self):
        app = self.app()
        package.validate_bundles(app)
        binary = app / "Contents/XPCServices/ProviderAgent.xpc/Contents/MacOS/ProviderAgent"
        binary.write_bytes(b"#!/bin/sh\nexit 0\n")
        with self.assertRaisesRegex(package.Failure, "bundle_executable_missing"):
            package.validate_bundles(app)
        binary.unlink()
        with self.assertRaisesRegex(package.Failure, "required_file_missing"):
            package.validate_bundles(app)

    def test_macho_discovery_does_not_depend_on_executable_bit(self):
        library = self.binary("library.so", False)
        script = self.file("script", b"#!/bin/sh\n", True)
        self.assertTrue(package.macho(library))
        self.assertFalse(package.macho(script))

    def test_symlink_escape_absolute_and_dangling_rejected(self):
        tree = self.root / "tree"
        tree.mkdir()
        outside = self.file("outside")
        link = tree / "escape"
        link.symlink_to("../outside")
        with self.assertRaisesRegex(package.Failure, "escaping_symlink"):
            package.check_tree(tree)
        link.unlink()
        link.symlink_to(outside)
        with self.assertRaisesRegex(package.Failure, "absolute_symlink"):
            package.check_tree(tree)
        link.unlink()
        link.symlink_to("missing")
        with self.assertRaises(OSError):
            package.check_tree(tree)

    def test_runtime_requires_version_extensions_and_exact_pins(self):
        runtime, cli, _ = self.runtime()
        self.assertEqual(package.validate_runtime(runtime), cli.relative_to(runtime))
        metadata = runtime / "lib/python3.13/site-packages/openai_codex-0.160.0.dist-info/METADATA"
        metadata.write_text("Name: openai-codex\nVersion: 0.159.0\n")
        with self.assertRaisesRegex(package.Failure, "runtime_distribution_mismatch"):
            package.validate_runtime(runtime)
        metadata.write_text("Name: openai-codex\nVersion: 0.160.0\n")
        (runtime / "include/python3.13/patchlevel.h").write_text('#define PY_VERSION "3.13.15"\n')
        with self.assertRaisesRegex(package.Failure, "python_version_mismatch"):
            package.validate_runtime(runtime)

    def test_cli_must_be_hash_verified_member_of_pinned_record(self):
        runtime, cli, record = self.runtime()
        cli.write_bytes(cli.read_bytes() + b"tampered")
        with self.assertRaisesRegex(package.Failure, "cli_record_hash_mismatch"):
            package.validate_runtime(runtime)
        record.write_text("../../../codex,sha256=wrong,1\n")
        with self.assertRaisesRegex(package.Failure, "unsafe_inventory_path"):
            package.validate_runtime(runtime)
        record.write_text("")
        with self.assertRaisesRegex(package.Failure, "cli_executable_ambiguous"):
            package.validate_runtime(runtime)

    def test_bundled_pip_is_required_and_cannot_authorize_extra_distributions(self):
        runtime, _, _ = self.runtime()
        site = runtime / "lib/python3.13/site-packages"
        metadata = site / "pip-26.2.1.dist-info/METADATA"
        metadata.write_text("Name: pip\nVersion: 26.2.2\n")
        with self.assertRaisesRegex(package.Failure, "runtime_distribution_mismatch"):
            package.validate_runtime(runtime)
        metadata.write_text("Name: pip\nVersion: 26.2.1\n")
        extra = site / "unexpected-1.0.dist-info"
        extra.mkdir()
        (extra / "METADATA").write_text("Name: unexpected\nVersion: 1.0\n")
        (extra / "WHEEL").write_text("Wheel-Version: 1.0\n")
        (extra / "RECORD").write_text("")
        with self.assertRaisesRegex(package.Failure, "runtime_distribution_mismatch"):
            package.validate_runtime(runtime)

    def test_framework_preserves_prefix_and_keeps_cli_inside_its_seal(self):
        app = self.app()
        runtime, cli, record = self.runtime()
        cli_hash, record_bytes = package.digest(cli), record.read_bytes()
        self.file("ProviderAgent/agent.py")
        self.file("Contracts/ProviderRPC/provider_rpc.py")
        self.file("Contracts/ProviderRPC/contract.json", b"{}")
        framework = package.install_runtime(app, runtime, cli.relative_to(runtime), self.root)
        version = framework / "Versions/3.13"
        agent = app / "Contents/XPCServices/ProviderAgent.xpc/Contents"
        self.assertEqual((agent / "MacOS/python3").resolve(), version / "bin/python3.13")
        self.assertEqual((agent / "MacOS/codex").resolve(), version / cli.relative_to(runtime))
        self.assertFalse((version / cli.relative_to(runtime)).is_symlink())
        self.assertTrue((agent / "MacOS/codex").is_symlink())
        self.assertEqual(package.digest(agent / "MacOS/codex"), cli_hash)
        self.assertEqual((version / record.relative_to(runtime)).read_bytes(), record_bytes)
        self.assertEqual((framework / "PythonRuntime").resolve(), version / "PythonRuntime")
        self.assertFalse((version / "PythonRuntime").is_symlink())
        self.assertEqual((version / "lib/libpython3.13.dylib").resolve(), version / "PythonRuntime")
        self.assertEqual(package.digest(version / "PythonRuntime"), package.digest(runtime / "lib/libpython3.13.dylib"))
        package.check_tree(app)
        self.assertTrue(cli.is_file() and not cli.is_symlink())

    def test_architecture_mismatch_fails_before_signing(self):
        with patch.object(package, "command", return_value=(b"x86_64\n", b"")) as command:
            with self.assertRaisesRegex(package.Failure, "binary_architecture_mismatch"):
                package.inspect_macho(self.root / "binary", "arm64")
            self.assertEqual(command.call_count, 1)

    def test_relative_load_cannot_escape_app(self):
        app = self.root / "PaperLens.app"
        binary = app / "Contents/MacOS/child"
        package.check_relative_load("@loader_path/../Frameworks/library.dylib", binary, "executable", app)
        with self.assertRaisesRegex(package.Failure, "escaping_relative_load"):
            package.check_relative_load("@loader_path/../../../outside.dylib", binary, "executable", app)
        self.assertFalse(package.allowed_load_name("@rpath/../../../outside.dylib"))

    def test_load_command_and_rpath_policy(self):
        for name in ("/opt/homebrew/lib/libbad.dylib", "/private/tmp/build/libbad.dylib", "libbad.dylib", "/usr/lib/../../tmp/bad", "@loader_path/evil\n"):
            with self.subTest(name=name):
                self.assertFalse(package.allowed_load_name(name))
        for name in ("/usr/lib/libSystem.B.dylib", "/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit", "@loader_path/../lib/libpython3.13.dylib", "@rpath/libswiftCore.dylib", "@executable_path/../lib/libpython3.13.dylib"):
            self.assertTrue(package.allowed_load_name(name))
        results = [(b"arm64\n", b""), (b"MH_MAGIC_64 ARM64 ALL EXECUTE\n", b""), (b"binary:\n\t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1.0.0)\n", b""), (b"Load command 1\n          cmd LC_RPATH\n      cmdsize 48\n         path /opt/homebrew/lib (offset 12)\n", b"")]
        with patch.object(package, "command", side_effect=results):
            with self.assertRaisesRegex(package.Failure, "external_rpath"):
                package.inspect_macho(self.root / "binary", "arm64")

    def test_dylib_identifier_is_not_a_dependency_but_loads_remain_restricted(self):
        for dependency, error in (("/usr/lib/libSystem.B.dylib", None), ("libitcl4.3.8.dylib", "external_load_dependency"), ("/opt/homebrew/lib/libbad.dylib", "external_load_dependency")):
            results = [(b"arm64\n", b""), (b"MH_MAGIC_64 ARM64 ALL DYLIB\n", b""), (f"binary:\n\tlibitcl4.3.8.dylib (compatibility version 1.0.0)\n\t{dependency} (compatibility version 1.0.0)\n".encode(), b""), (b"binary:\nlibitcl4.3.8.dylib\n", b""), (b"Load command 1\n cmd LC_ID_DYLIB\n name libitcl4.3.8.dylib (offset 24)\n", b"")]
            with self.subTest(dependency=dependency), patch.object(package, "command", side_effect=results):
                if error:
                    with self.assertRaisesRegex(package.Failure, error):
                        package.inspect_macho(self.root / "binary", "arm64")
                else:
                    self.assertEqual(package.inspect_macho(self.root / "binary", "arm64"), "library")

    def test_unique_team_identity_required(self):
        identity = b'  1) ' + b'A' * 40 + b' "Developer ID Application: Synthetic (397452Z366)"\n'
        with patch.object(package, "command", return_value=(identity, b"")):
            self.assertEqual(package.signing_identity(), "A" * 40)
        for output in (b"", identity + identity, identity.replace(b"397452Z366", b"OTHERTEAM1")):
            with patch.object(package, "command", return_value=(output, b"")):
                with self.assertRaisesRegex(package.Failure, "unique_developer_id_required"):
                    package.signing_identity()

    def test_library_and_executable_entitlements_are_separate(self):
        prefix = "Contents/XPCServices/ProviderAgent.xpc/Contents/"
        python = prefix + "Frameworks/PythonRuntime.framework/Versions/3.13/bin/python3.13"
        self.assertEqual(package.code_policy(python, "executable"), (package.IDENTITY + ".ProviderAgent.Python", package.CHILD_RIGHTS))
        cli = prefix + "Frameworks/PythonRuntime.framework/Versions/3.13/lib/python3.13/site-packages/codex_cli_bin/bin/codex"
        self.assertEqual(package.code_policy(cli, "executable"), (package.IDENTITY + ".ProviderAgent.Codex", package.CHILD_RIGHTS))
        extension = prefix + "Frameworks/PythonRuntime.framework/Versions/3.13/lib/python3.13/lib-dynload/_struct.so"
        self.assertEqual(package.code_policy(extension, "library")[1], {})
        helper = prefix + "Frameworks/PythonRuntime.framework/Versions/3.13/bin/helper"
        self.assertEqual(package.code_policy(helper, "executable")[1], package.CHILD_RIGHTS)
        with self.assertRaisesRegex(package.Failure, "unexpected_nested_code"):
            package.code_policy("Contents/MacOS/unknown", "executable")

    def test_sign_command_has_hardened_runtime_without_deep_or_exceptions(self):
        with patch.object(package, "command", return_value=(b"", b"")) as command:
            package.sign(self.root / "extension.so", "A" * 40, package.IDENTITY + ".Library", {}, self.root)
            arguments = command.call_args_list[0].args[0]
            self.assertIn("runtime", arguments)
            self.assertNotIn("--entitlements", arguments)
            self.assertNotIn("--deep", arguments)
            package.sign(self.root / "python", "A" * 40, package.IDENTITY + ".Python", package.CHILD_RIGHTS, self.root)
            arguments = command.call_args_list[2].args[0]
            rights = plistlib.loads(Path(arguments[arguments.index("--entitlements") + 1]).read_bytes())
            self.assertEqual(rights, {package.SANDBOX: True, package.INHERIT: True})

    def test_signature_verification_rejects_debugging_or_library_exceptions(self):
        text = f"Identifier={package.IDENTITY}\nTeamIdentifier={package.TEAM}\nAuthority=Developer ID Application: Synthetic\nCodeDirectory flags=0x10000(runtime)\n".encode()
        expected = {package.SANDBOX: True, package.NETWORK: True}
        for forbidden in ("com.apple.security.get-task-allow", "com.apple.security.cs.disable-library-validation", "com.apple.security.cs.allow-jit"):
            results = [(b"", b""), (b"", text), (plistlib.dumps({**expected, forbidden: True}), b"")]
            with patch.object(package, "command", side_effect=results):
                with self.assertRaisesRegex(package.Failure, "signed_entitlements_mismatch"):
                    package.verify_signature(self.root / "app", package.IDENTITY, expected)

    def test_manifest_rejects_paths_secrets_extra_fields_and_false_completion(self):
        package.safe_manifest(self.manifest())
        mutations = [
            lambda value: value.update(rawStdout="secret"),
            lambda value: value.update(sourceBaseCommit="/Users/private"),
            lambda value: value.update(storyDone=True),
            lambda value: value["files"][0].update(path="../../outside"),
            lambda value: value["files"][0].update(path="/Users/private/file"),
            lambda value: value["files"][0].update(signedSHA256="not-a-hash"),
            lambda value: value["files"][0].update(mode="secret"),
            lambda value: value["files"][0].update(exception="token"),
            lambda value: value["files"].append(copy.deepcopy(value["files"][0])),
        ]
        for mutation in mutations:
            manifest = self.manifest()
            mutation(manifest)
            with self.assertRaises(package.Failure):
                package.safe_manifest(manifest)

    def test_pipeline_signs_inside_out_and_inventories_source_vs_signed(self):
        app = self.app()
        runtime, _, _ = self.runtime()
        work = self.root / ".build/topology/arm64"
        (work / "runtime").mkdir(parents=True)
        runtime.rename(work / "runtime/python")
        self.file("ProviderAgent/agent.py")
        self.file("Contracts/ProviderRPC/provider_rpc.py")
        self.file("Contracts/ProviderRPC/contract.json", b"{}")
        order = []
        self.file("Tests/Topology/fixture-map.json", b"{}")

        def sign(path, identity, identifier, rights, scratch):
            order.append((str(path), identifier, rights))
            if path.is_file():
                path.write_bytes(path.read_bytes() + b"signed")

        def inspect(path, arch, app=None):
            return "library" if path.suffix in (".so", ".dylib") or path.name == "PythonRuntime" else "executable"

        with patch.object(package.sys, "platform", "darwin"), patch.object(package, "validate_receipts", return_value=("a" * 64, "b" * 64)), patch.object(package, "source_provenance", return_value={"sourceBaseCommit": "c" * 40, "sourceDirty": True, "sourceTreeHash": "d" * 64}), patch.object(package, "signing_identity", return_value="A" * 40), patch.object(package, "inspect_macho", side_effect=inspect), patch.object(package, "sign", side_effect=sign), patch.object(package, "verify_signature"):
            manifest = package.package(self.root, "arm64", app.parent)
        ids = [item[1] for item in order]
        self.assertLess(ids.index(package.IDENTITY + ".ProviderAgent.Python"), len(ids) - 3)
        framework_index = next(index for index, item in enumerate(order) if item[0].endswith("PythonRuntime.framework"))
        self.assertLess(framework_index, ids.index(package.IDENTITY + ".ProviderAgent"))
        self.assertEqual(ids[-1], package.IDENTITY)
        self.assertLess(ids.index(package.IDENTITY + ".PDFiumXPC"), len(ids) - 1)
        python = next(item for item in manifest["files"] if item.get("identifier") == package.IDENTITY + ".ProviderAgent.Python")
        self.assertNotEqual(python["sourceSHA256"], python["signedSHA256"])
        self.assertTrue((work / "manifest.json").is_file())
        self.assertEqual(json.loads((work / "manifest.json").read_text()), manifest)
        self.assertEqual(manifest["artifactHash"], package.json_hash(package.tree_inventory(work / "PaperLens.app")))
        self.assertTrue(app.is_dir())
        with patch.object(package.sys, "platform", "darwin"):
            with self.assertRaisesRegex(package.Failure, "output_already_exists"):
                package.package(self.root, "arm64", app.parent)


if __name__ == "__main__":
    unittest.main()
