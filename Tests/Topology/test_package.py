"""Synthetic filesystem/pure projection tests; no signing, downloads, or SDK/native execution."""

import base64
import copy
import csv
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

MODULE_PATH = Path(__file__).resolve().parents[2] / "scripts/topology/package.py"
SPEC = importlib.util.spec_from_file_location("topology_package", MODULE_PATH)
package = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(package)


class PackagingTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        host = patch.object(package.platform, "machine", return_value="arm64")
        host.start()
        self.addCleanup(host.stop)

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

    def test_cancelled_architectures_reject_at_cli_before_owner(self):
        for arch in ("x86_64", "x64", "amd64", "i386", "universal"):
            with self.subTest(arch=arch), patch.object(package, "package") as owner, patch("sys.stderr"):
                with self.assertRaises(SystemExit) as error:
                    package.main(["--arch", arch, "--products", str(self.root)])
                self.assertEqual(error.exception.code, 2)
                owner.assert_not_called()

    def test_intel_apis_reject_before_tools_inputs_or_outputs(self):
        before = package.tree_inventory(self.root)
        with patch.object(package.sys, "platform", "darwin"), patch.object(package, "command") as command, patch.object(package, "load_acquire") as acquire, patch.object(package, "digest") as digest:
            with self.assertRaisesRegex(package.Failure, "macos_arch_required"):
                package.package(self.root, "x86_64", self.root)
            with self.assertRaisesRegex(package.Failure, "native_build_host_not_proven"):
                package.validate_prepared_inputs(self.root, "x86_64", self.root, self.root)
            with self.assertRaisesRegex(package.Failure, "unsupported_arch"):
                package.validate_receipts(self.root, self.root, "x86_64", runtime_work=self.root, prepared=True)
            with self.assertRaisesRegex(package.Failure, "unsupported_arch"):
                package.inspect_macho(self.root / "binary", "x86_64")
            with patch.object(package.platform, "machine", return_value="x86_64"):
                with self.assertRaisesRegex(package.Failure, "native_build_host_not_proven"):
                    package.package(self.root, "arm64", self.root)
            command.assert_not_called()
            acquire.assert_not_called()
            digest.assert_not_called()
        self.assertEqual(package.tree_inventory(self.root), before)

    def test_intel_manifest_rejected_without_effects(self):
        manifest = self.manifest()
        manifest["arch"] = "x86_64"
        original = copy.deepcopy(manifest)
        with patch.object(package, "command") as command:
            with self.assertRaisesRegex(package.Failure, "manifest_schema_mismatch"):
                package.safe_manifest(manifest)
            command.assert_not_called()
        self.assertEqual(manifest, original)

    def test_translated_or_unknown_host_rejected_before_inputs_or_staging(self):
        (self.root / ".build/topology/arm64").mkdir(parents=True)
        before = package.tree_inventory(self.root)
        for translated in (b"1", b"", b"unknown"):
            with self.subTest(translated=translated), patch.object(package.sys, "platform", "darwin"), patch.object(package, "command", return_value=(translated, b"")) as command, patch.object(package, "validate_bundles") as bundles, patch.object(package, "signing_identity") as identity:
                with self.assertRaisesRegex(package.Failure, "rosetta_or_unknown_host_forbidden"):
                    package.package(self.root, "arm64", self.root)
                command.assert_called_once_with(["/usr/sbin/sysctl", "-in", "sysctl.proc_translated"])
                bundles.assert_not_called()
                identity.assert_not_called()
            self.assertEqual(package.tree_inventory(self.root), before)

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
        self.file("ProviderAgent/account_login.py", b"# private account controller fixture\n")
        self.file("ProviderAgent/broker.py", b"# owned CLI fixture\n")
        self.file("Contracts/ProviderRPC/provider_rpc.py")
        self.file("Contracts/ProviderRPC/contract.json", b"{}")
        framework = package.install_runtime(app, runtime, cli.relative_to(runtime), self.root)
        version = framework / "Versions/3.13"
        agent = app / "Contents/XPCServices/ProviderAgent.xpc/Contents"
        self.assertEqual((agent / "Resources/account_login.py").read_bytes(),
                         b"# private account controller fixture\n")
        self.assertEqual((agent / "Resources/broker.py").read_bytes(), b"# owned CLI fixture\n")
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

    def test_packaged_account_projection_imports_only_packaged_contract(self):
        app = self.app()
        runtime, cli, _ = self.runtime()
        repository = MODULE_PATH.parents[2]
        for relative in ("ProviderAgent/agent.py", "ProviderAgent/account_login.py", "ProviderAgent/broker.py",
                         "Contracts/ProviderRPC/provider_rpc.py", "Contracts/ProviderRPC/contract.json"):
            self.file(relative, (repository / relative).read_bytes())
        package.install_runtime(app, runtime, cli.relative_to(runtime), self.root)
        resources = app / "Contents/XPCServices/ProviderAgent.xpc/Contents/Resources"
        for relative in ("ProviderAgent/agent.py", "ProviderAgent/account_login.py", "ProviderAgent/broker.py",
                         "Contracts/ProviderRPC/provider_rpc.py", "Contracts/ProviderRPC/contract.json"):
            self.assertEqual((resources / Path(relative).name).read_bytes(),
                             (repository / relative).read_bytes())
        rpc_spec = importlib.util.spec_from_file_location("_packaged_rpc_fixture", resources / "provider_rpc.py")
        rpc = importlib.util.module_from_spec(rpc_spec)
        rpc_spec.loader.exec_module(rpc)
        login_spec = importlib.util.spec_from_file_location("_packaged_account_fixture", resources / "account_login.py")
        login = importlib.util.module_from_spec(login_spec)
        with patch.dict(sys.modules, {"provider_rpc": rpc, login_spec.name: login}):
            login_spec.loader.exec_module(login)
            self.assertIs(login.CONTRACT, rpc.CONTRACT)
            self.assertEqual(rpc.CONTRACT, json.loads((resources / "contract.json").read_bytes()))
            controller = login.AccountLoginController("chatgpt")
            intent = controller.replace_intent()
            prefix = "https://example.invalid/"
            payload = {"type": "chatgpt", "loginId": "private-fixture-login",
                       "authUrl": prefix + "x" * (4096 - len(prefix))}
            self.assertTrue(controller.accept_instructions(intent, payload))
            self.assertEqual(controller.state, "waiting")
            self.assertEqual(controller.instructions.auth_url, payload["authUrl"])
            payload["authUrl"] += "x"
            with self.assertRaises(login.AccountLoginError) as caught:
                login.validate_browser_instructions(payload)
            self.assertEqual(str(caught.exception), "invalidInstructions")
        broker_spec = importlib.util.spec_from_file_location(
            "_packaged_broker_fixture", resources / "broker.py")
        broker = importlib.util.module_from_spec(broker_spec)
        original_import = __import__

        def closed_import(name, *args, **kwargs):
            if name == "openai_codex" or name.startswith("openai_codex."):
                raise AssertionError("packaged broker imported SDK")
            return original_import(name, *args, **kwargs)

        forbidden = AssertionError("packaged broker performed an import-time native effect")
        with patch.dict(sys.modules, {broker_spec.name: broker}), \
                patch("builtins.__import__", side_effect=closed_import), \
                patch("ctypes.CDLL", side_effect=forbidden), \
                patch("subprocess.Popen", side_effect=forbidden), \
                patch("os.posix_spawn", side_effect=forbidden), \
                patch("select.kqueue", create=True, side_effect=forbidden):
            broker_spec.loader.exec_module(broker)

    def test_agent_resources_missing_or_symlink_refuses_before_runtime_copy(self):
        parent = self.root
        for resource, kind in ((resource, kind)
                               for resource in ("account_login.py", "broker.py")
                               for kind in ("missing", "directory", "source_symlink", "destination_symlink")):
            with self.subTest(resource=resource, kind=kind):
                self.root = parent / resource / kind
                app = self.app()
                runtime, cli, _ = self.runtime()
                self.file("ProviderAgent/agent.py")
                other = "broker.py" if resource == "account_login.py" else "account_login.py"
                self.file("ProviderAgent/" + other)
                self.file("Contracts/ProviderRPC/provider_rpc.py")
                self.file("Contracts/ProviderRPC/contract.json", b"{}")
                marker = self.file("untouched-marker", b"private fixture, not a credential")
                source = self.root / "ProviderAgent" / resource
                if kind == "directory":
                    source.mkdir()
                elif kind == "source_symlink":
                    source.symlink_to(os.path.relpath(marker, source.parent))
                elif kind == "destination_symlink":
                    source.write_bytes(b"controller fixture")
                    destination = app / "Contents/XPCServices/ProviderAgent.xpc/Contents/Resources" / resource
                    destination.symlink_to(os.path.relpath(marker, destination.parent))
                before = package.tree_inventory(self.root)
                code = "resource_symlink_collision" if kind == "destination_symlink" else "agent_resource_missing"
                with patch.object(package, "command") as command:
                    with self.assertRaisesRegex(package.Failure, code):
                        package.install_runtime(app, runtime, cli.relative_to(runtime), self.root)
                    command.assert_not_called()
                self.assertEqual(package.tree_inventory(self.root), before)
                self.assertEqual(marker.read_bytes(), b"private fixture, not a credential")
                self.assertFalse((app / "Contents/XPCServices/ProviderAgent.xpc/Contents/Frameworks/PythonRuntime.framework").exists())

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

    def receipt_inputs(self):
        lock_bytes = (MODULE_PATH.parent / "dependencies.json").read_bytes()
        lock_path = self.file("scripts/topology/dependencies.json", lock_bytes)
        lock = json.loads(lock_bytes)
        acquisition = self.root / "acquisition"
        runtime = self.root / "runtime-input"
        assets = [("python", lock["python"]["arm64"])]
        assets.extend(("wheel", item.get("any", item.get("arm64"))) for item in lock["wheels"])
        assets.append(("source", lock["sdkSource"]))
        assets = [{"kind": kind, "filename": item["filename"], "sha256": item["sha256"]} for kind, item in assets]
        self.file("runtime-input/runtime/python/file", b"runtime")
        receipt = {"arch": "arm64", "lockHash": package.digest(lock_path), "files": package.tree_inventory(runtime / "runtime")}
        self.file("runtime-input/runtime.json", json.dumps(receipt).encode())
        self.file("acquisition/acquisition.json", json.dumps({"arch": "arm64", "lockHash": receipt["lockHash"], "assets": assets}).encode())
        materialization = {"schemaRevision": "runtime-assets-only-v1", "runID": package.PREPARED_RUNTIME.removeprefix("runtime-assets-only-"),
                           "arch": "arm64", "manifestHash": receipt["lockHash"], "files": receipt["files"],
                           "inputs": assets[:-1], "status": "materialized", "scope": "unsigned_cached_runtime_materialization_only",
                           "fullAcquisitionProved": False, "signed": False, "storyDone": False}
        self.file("runtime-input/runtime-assets-only.json", json.dumps(materialization).encode())
        return acquisition, runtime, receipt, materialization

    def test_canonical_receipts_need_no_prepared_materialization_or_owner_checks(self):
        acquisition, runtime, receipt, _ = self.receipt_inputs()
        (runtime / "runtime").rename(acquisition / "runtime")
        (runtime / "runtime.json").rename(acquisition / "runtime.json")
        with patch.object(package, "validate_prepared_inputs") as owner:
            hashes = package.validate_receipts(acquisition, self.root, "arm64", runtime_work=acquisition, prepared=False)
            owner.assert_not_called()
        self.assertEqual(hashes, (receipt["lockHash"], package.digest(acquisition / "acquisition.json")))

    def test_prepared_runtime_bindings_are_independent_of_full_acquisition(self):
        acquisition, runtime, receipt, materialization = self.receipt_inputs()
        before = package.tree_inventory(self.root)
        with patch.object(package, "validate_prepared_inputs") as owner:
            hashes = package.validate_receipts(acquisition, self.root, "arm64", runtime_work=runtime, prepared=True)
            owner.assert_called_once_with(self.root, "arm64", acquisition, runtime)
        self.assertEqual(hashes, (receipt["lockHash"], package.digest(acquisition / "acquisition.json")))
        self.assertEqual(before, package.tree_inventory(self.root))
        mutations = [("runtime.json", {**receipt, "arch": "x86_64"}, "receipt_pin_mismatch"),
                     ("runtime.json", {**receipt, "lockHash": "0" * 64}, "receipt_pin_mismatch"),
                     ("runtime.json", {**receipt, "files": []}, "runtime_integrity_mismatch"),
                     ("runtime-assets-only.json", {**materialization, "manifestHash": "0" * 64}, "runtime_materialization_mismatch"),
                     ("runtime-assets-only.json", {**materialization, "inputs": []}, "runtime_asset_mismatch")]
        for name, value, reason in mutations:
            with self.subTest(reason=reason), patch.object(package, "validate_prepared_inputs"):
                (runtime / "runtime.json").write_text(json.dumps(receipt))
                (runtime / "runtime-assets-only.json").write_text(json.dumps(materialization))
                (runtime / name).write_text(json.dumps(value))
                with self.assertRaisesRegex(package.Failure, reason):
                    package.validate_receipts(acquisition, self.root, "arm64", runtime_work=runtime, prepared=True)
        with patch.object(package, "validate_prepared_inputs"):
            with self.assertRaisesRegex(package.Failure, "required_file_missing"):
                package.validate_receipts(runtime, self.root, "arm64", runtime_work=runtime, prepared=True)

    def test_prepared_owner_requires_namespaces_native_host_and_applied_target(self):
        parent = self.root
        topology = parent / ".build/topology"
        root = topology / "isolated"
        acquisition = topology / package.PREPARED_ACQUISITION
        runtime = topology / package.PREPARED_RUNTIME
        for directory in (root, acquisition, runtime, topology / "downloads"):
            directory.mkdir(parents=True)
        self.file(root.relative_to(parent) / ".git", b"gitdir: synthetic")
        intent = '<frozen-after-approval>exact\nintent</frozen-after-approval>'
        self.file(root.relative_to(parent) / "bmad-docs/implementation-artifacts/spec-1-1-isolated-app-topology.md", intent.encode())
        target = self.file(acquisition.relative_to(parent) / "pdfium/src/target", b"patched")
        lock = {"approvalCommit": "a" * 40}
        acquire = SimpleNamespace(Failure=package.Failure, LOCK_PATH=root / "lock", PDFIUM_PATCH={"target": "target", "afterSha256": package.digest(target)},
                                  git=Mock(side_effect=lambda _, *args: str(parent / ".git") if args[0] == "rev-parse" else intent if args[0] == "show" else ""),
                                  safe_path=lambda base, relative: base / relative, load_lock=Mock(return_value=lock),
                                  platform=SimpleNamespace(machine=Mock(return_value="arm64")), run=Mock(return_value="0"),
                                  toolchain=Mock(), check_hash=Mock(), validate_receipt=Mock())
        def check_hash(path, expected):
            if path == target:
                package.require(package.digest(path) == expected, "prepared_target_changed")
        acquire.check_hash.side_effect = check_hash
        with patch.object(package, "load_acquire", return_value=acquire):
            package.validate_prepared_inputs(root, "arm64", acquisition, runtime)
            acquire.validate_receipt.assert_called_once_with(lock, acquisition, "arm64", "arm64", topology / "downloads")
            self.assertEqual(target.read_bytes(), b"patched")
            acquire.validate_receipt.reset_mock()
            for invalid in (runtime, topology / "other"):
                with self.assertRaisesRegex(package.Failure, "prepared_input_namespace_mismatch"):
                    package.validate_prepared_inputs(root, "arm64", invalid, runtime)
            with self.assertRaisesRegex(package.Failure, "isolated_project_required"):
                package.validate_prepared_inputs(parent, "arm64", acquisition, runtime)
            for arch, host in (("x86_64", "arm64"), ("arm64", "x86_64")):
                acquire.platform.machine.return_value = host
                with self.assertRaisesRegex(package.Failure, "native_build_host_not_proven"):
                    package.validate_prepared_inputs(root, arch, acquisition, runtime)
            acquire.platform.machine.return_value = "arm64"
            acquire.run.return_value = "1"
            with self.assertRaisesRegex(package.Failure, "rosetta_or_unknown_host_forbidden"):
                package.validate_prepared_inputs(root, "arm64", acquisition, runtime)
            acquire.run.return_value = "0"
            intent_path = root / "bmad-docs/implementation-artifacts/spec-1-1-isolated-app-topology.md"
            intent_path.write_text(intent.replace("exact", "changed"))
            with self.assertRaisesRegex(package.Failure, "frozen_intent_changed"):
                package.validate_prepared_inputs(root, "arm64", acquisition, runtime)
            intent_path.write_text(intent)
            original_git = acquire.git.side_effect
            def reject_ancestry(directory, *args):
                if args[0] == "merge-base":
                    raise package.Failure("approval_not_ancestor")
                return original_git(directory, *args)
            acquire.git.side_effect = reject_ancestry
            with self.assertRaisesRegex(package.Failure, "approval_not_ancestor"):
                package.validate_prepared_inputs(root, "arm64", acquisition, runtime)
            acquire.git.side_effect = original_git
            target.write_bytes(b"unpatched")
            with self.assertRaisesRegex(package.Failure, "prepared_target_changed"):
                package.validate_prepared_inputs(root, "arm64", acquisition, runtime)
            acquire.validate_receipt.assert_not_called()
            self.assertEqual(target.read_bytes(), b"unpatched")

    def test_frozen_intent_requires_exact_unique_section(self):
        text = '<frozen-after-approval>intent</frozen-after-approval>'
        self.assertEqual(package.frozen("before" + text + "after"), text)
        for invalid in ("", text + text, '</frozen-after-approval><frozen-after-approval>', text.replace('</frozen-after-approval>', '')):
            with self.assertRaisesRegex(package.Failure, "frozen_intent_missing_or_ambiguous"):
                package.frozen(invalid)

    def test_prepared_arguments_must_be_paired_and_cli_forwards_named_inputs(self):
        (self.root / ".build/topology/arm64").mkdir(parents=True)
        with patch.object(package.sys, "platform", "darwin"), patch.object(package, "validate_bundles") as bundles:
            for keywords in ({"prepared_acquisition": self.root}, {"prepared_runtime": self.root}):
                with self.assertRaisesRegex(package.Failure, "prepared_inputs_required_together"):
                    package.package(self.root, "arm64", self.root, **keywords)
            bundles.assert_not_called()
        with patch.object(package, "package") as owner, patch("builtins.print"):
            self.assertEqual(package.main(["--arch", "arm64", "--products", str(self.root),
                                           "--prepared-acquisition", str(self.root / "acquisition"),
                                           "--prepared-runtime", str(self.root / "runtime")]), 0)
            owner.assert_called_once_with(package.ROOT, "arm64", self.root,
                                          prepared_acquisition=self.root / "acquisition", prepared_runtime=self.root / "runtime")

    def test_output_file_and_dangling_symlink_collisions_fail_before_inputs(self):
        work = self.root / ".build/topology/arm64"
        work.mkdir(parents=True)
        for name in ("manifest.json", "PaperLens.app"):
            for symlink in (False, True):
                with self.subTest(name=name, symlink=symlink):
                    output = work / name
                    if symlink:
                        output.symlink_to("missing")
                    else:
                        output.write_bytes(b"caller-owned")
                    with patch.object(package.sys, "platform", "darwin"), patch.object(package, "validate_bundles") as bundles:
                        with self.assertRaisesRegex(package.Failure, "output_already_exists"):
                            package.package(self.root, "arm64", self.root, prepared_acquisition=self.root, prepared_runtime=self.root)
                        bundles.assert_not_called()
                    self.assertTrue(output.is_symlink() if symlink else output.read_bytes() == b"caller-owned")
                    output.unlink()

    def test_pipeline_signs_inside_out_and_inventories_source_vs_signed(self):
        self.pipeline(False)

    def test_prepared_pipeline_preserves_inputs_and_canonical_output_collisions(self):
        self.pipeline(True)

    def pipeline(self, prepared):
        app = self.app()
        runtime, _, _ = self.runtime()
        work = self.root / ".build/topology/arm64"
        work.mkdir(parents=True)
        acquisition_work = self.root / "borrowed-acquisition" if prepared else work
        runtime_work = self.root / "borrowed-runtime" if prepared else work
        (runtime_work / "runtime").mkdir(parents=True)
        runtime.rename(runtime_work / "runtime/python")
        acquisition_work.mkdir(exist_ok=True)
        (acquisition_work / "acquisition.json").write_text("original receipt")
        input_inventory = package.tree_inventory(runtime_work / "runtime")
        product_inventory = package.tree_inventory(app)
        keywords = {"prepared_acquisition": acquisition_work, "prepared_runtime": runtime_work} if prepared else {}
        self.file("ProviderAgent/agent.py")
        self.file("ProviderAgent/account_login.py")
        self.file("ProviderAgent/broker.py")
        self.file("Contracts/ProviderRPC/provider_rpc.py")
        self.file("Contracts/ProviderRPC/contract.json", b"{}")
        order = []
        self.file("Tests/Topology/fixture-map.json", b"{}")

        def sign(path, identity, identifier, rights, scratch):
            self.assertTrue(path.is_relative_to(work))
            self.assertTrue(path.relative_to(work).parts[0].startswith("package-"))
            self.assertTrue(scratch.is_relative_to(work))
            order.append((str(path), identifier, rights))
            if path.is_file():
                path.write_bytes(path.read_bytes() + b"signed")

        def inspect(path, arch, app=None):
            return "library" if path.suffix in (".so", ".dylib") or path.name == "PythonRuntime" else "executable"

        with patch.object(package.sys, "platform", "darwin"), patch.object(package, "command", return_value=(b"0\n", b"")) as command, patch.object(package, "validate_receipts", return_value=("a" * 64, "b" * 64)) as receipts, patch.object(package, "source_provenance", return_value={"sourceBaseCommit": "c" * 40, "sourceDirty": True, "sourceTreeHash": "d" * 64}), patch.object(package, "signing_identity", return_value="A" * 40), patch.object(package, "inspect_macho", side_effect=inspect), patch.object(package, "sign", side_effect=sign), patch.object(package, "verify_signature"):
            manifest = package.package(self.root, "arm64", app.parent, **keywords)
            command.assert_called_once_with(["/usr/sbin/sysctl", "-in", "sysctl.proc_translated"])
            receipts.assert_called_once_with(acquisition_work, self.root, "arm64", runtime_work=runtime_work, prepared=prepared)
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
        self.assertEqual(product_inventory, package.tree_inventory(app))
        self.assertEqual(input_inventory, package.tree_inventory(runtime_work / "runtime"))
        self.assertEqual((acquisition_work / "acquisition.json").read_text(), "original receipt")
        with patch.object(package.sys, "platform", "darwin"):
            with self.assertRaisesRegex(package.Failure, "output_already_exists"):
                package.package(self.root, "arm64", app.parent, **keywords)


if __name__ == "__main__":
    unittest.main()
