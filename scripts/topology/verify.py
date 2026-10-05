#!/usr/bin/env python3
"""Read-only signed-bundle checks and explicitly opted-in synthetic GUI run.

No notarization, stapling, spctl submission, permission reset, or real-container
inspection. Evidence never includes raw SDK, codesign, subprocess or OS logs.
"""
from __future__ import annotations

import argparse
import ctypes
import json
import os
from pathlib import Path
import platform
import plistlib
import pwd
import re
import selectors
import socket
import stat
import subprocess
import sys
import threading
import time
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parent))
import package as packaging
from acquire import ARCHES, Failure, ROOT, clean_env, ensure_root, require, safe_path, sha256

TEAM = "397452Z366"
IDENTITY = "io.github.jinzer0.PaperLens"
HOME = Path("/Users/paperlens-topology")
REPORT = HOME / "Library/Containers" / IDENTITY / "Data/Library/Application Support/PaperLensTopology/report.json"
SANDBOX = "com.apple.security.app-sandbox"
NETWORK = "com.apple.security.network.client"
INHERIT = "com.apple.security.inherit"
GROUP = TEAM + "." + IDENTITY + ".TopologyFixture"
GROUP_OWNER = IDENTITY + ".TopologyFixtureOwner"
CASE_FIELDS = ("runID", "caseID", "fixtureID", "actorInstanceRef", "operation", "ownerPre", "ownerPost", "sameUIDControl", "expectedRootMatched", "posixACLControl", "syscallResult", "errno", "sandboxDenialRef", "promptObserved", "verdict")


def command(argv, timeout=30):
    try:
        result = subprocess.run(list(map(str, argv)), env=clean_env(), stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout, check=False)
    except (OSError, subprocess.TimeoutExpired):
        return None, b"", b""
    return result.returncode, result.stdout, result.stderr


def result(case, verdict, reason, executed=None):
    if executed is None:
        executed = verdict in ("pass", "failed")
    return {"caseID": case, "verdict": verdict, "reason": reason, "executionStatus": "observed" if executed else "unexecuted"}


def base_evidence(arch, actual="unknown"):
    return {
        "manifest": {"schemaRevision": "topology-v1", "sourceCommit": None, "sourceTreeHash": None, "artifactHash": None, "fixtureMapHash": None, "entitlementHash": None, "OSBuild": None, "actualCPU": actual, "codeIdentityRefs": []},
        "requestedCPU": arch,
        "processTranslated": None,
        "automated": [],
        "manual": [result("cleanProfile", "blocked", "human_clean_profile_confirmation_required"), result("sandboxDenialAttribution", "blocked", "per_actor_os_denial_and_posix_tcc_controls_required")],
        "remote": [result("notarization", "blocked", "separate_submission_authorization_required"), result("staple", "blocked", "notarization_not_performed"), result("gatekeeperCleanGUI", "blocked", "separate_clean_machine_evidence_required"), result("actualTwoCPU", "blocked", "independent_native_arm64_and_intel_receipts_required")],
        "groupOwner": {"executionStatus": "unexecuted", "runID": None, "fixtureID": "G", "ownerPre": None, "ownerPost": None, "absent": None, "posixACLControl": "unverified"},
        "cases": [], "verdict": "blocked", "storyDone": False, "p1": "unverified",
    }


def native_cpu():
    if sys.platform != "darwin":
        return platform.machine(), None
    status, translated, _ = command(["/usr/sbin/sysctl", "-in", "sysctl.proc_translated"])
    if status == 0:
        require(translated.strip() in (b"0", b"1"), "invalid_rosetta_observation")
        is_translated = translated.strip() == b"1"
        return "arm64" if is_translated else platform.machine(), is_translated
    status, hardware, _ = command(["/usr/sbin/sysctl", "-n", "hw.optional.arm64"])
    if status == 0 and hardware.strip() == b"0" and platform.machine() == "x86_64":
        return "x86_64", False
    return platform.machine(), None


def decode_json(data):
    def unique_pairs(pairs):
        result = {}
        for key, value in pairs:
            require(key not in result, "duplicate_evidence_key")
            result[key] = value
        return result

    return json.loads(data, object_pairs_hook=unique_pairs)


def read_json(path, maximum=16 * 1024**2):
    require(path.is_file() and not path.is_symlink(), "evidence_file_missing")
    with path.open("rb") as stream:
        data = stream.read(maximum + 1)
    require(len(data) <= maximum, "evidence_size_limit")
    return decode_json(data)


def validate_inventory(bundle, arch, manifest):
    """Use the packager's exact post-signing inventory encoding, with no exclusions."""
    packaging.safe_manifest(manifest)
    require(manifest["arch"] == arch, "manifest_arch_mismatch")
    actual = packaging.tree_inventory(bundle)
    require(packaging.json_hash(actual) == manifest["artifactHash"], "artifact_hash_mismatch")
    records = {entry["path"]: entry for entry in manifest["files"]}
    require(set(records) == {entry["path"] for entry in actual}, "inventory_coverage_mismatch")
    for entry in actual:
        record = records[entry["path"]]
        if "link" in entry:
            require(record["kind"] == "symlink" and record["link"] == entry["link"], "inventory_link_mismatch")
        else:
            require(record["kind"] != "symlink" and record["signedSHA256"] == entry["sha256"] and record["mode"] == entry["mode"], "inventory_hash_mismatch")
        # sourceSHA256 is pre-signing provenance, never compared to signed bytes.
    return records


def inspect_bundle(bundle, arch, evidence):
    require(sys.platform == "darwin", "macos_required")
    require(bundle.is_dir() and not bundle.is_symlink(), "bundle_missing")
    work = ROOT / ".build/topology" / arch
    require(bundle.absolute() == work / "PaperLens.app", "bundle_work_path_mismatch")
    inventory = read_json(safe_path(work, "manifest.json"))
    records = validate_inventory(bundle, arch, inventory)
    require(sha256(safe_path(work, "acquisition.json")) == inventory["acquisitionHash"], "acquisition_hash_mismatch")
    require(sha256(ROOT / "scripts/topology/dependencies.json") == inventory["dependencyLockHash"], "dependency_lock_mismatch")
    acquisition = read_json(safe_path(work, "acquisition.json"))
    require(acquisition["arch"] == arch and acquisition["lockHash"] == inventory["dependencyLockHash"], "acquisition_manifest_mismatch")
    provenance = packaging.source_provenance(ROOT)
    require(all(inventory[key] == provenance[key] for key in provenance), "source_provenance_mismatch")
    packaging.validate_bundles(bundle)
    framework = bundle / "Contents/XPCServices/ProviderAgent.xpc/Contents/Frameworks/PythonRuntime.framework"
    primary = (framework / "PythonRuntime").resolve(strict=True)
    require(primary.is_relative_to(bundle.resolve()), "escaping_framework_code")
    entitlements, identities = {}, []
    for relative, record in records.items():
        path = bundle / relative
        if packaging.macho(path):
            kind = packaging.inspect_macho(path, arch, bundle)
            identifier, rights = packaging.code_policy(relative, kind)
            if path.resolve() == primary:
                require(kind == "library", "framework_not_library")
                identifier, rights = IDENTITY + ".ProviderAgent.PythonRuntime", {}
            require(record["kind"] == kind and record.get("identifier") == identifier and record.get("entitlements") == rights, "manifest_code_policy_mismatch")
            packaging.verify_signature(path, identifier, rights)
            entitlements[relative] = rights
            identities.append(identifier)
        else:
            require(record["kind"] in ("file", "symlink") and "identifier" not in record and "entitlements" not in record, "manifest_code_kind_mismatch")
    required = {IDENTITY, IDENTITY + ".PDFiumXPC", IDENTITY + ".ProviderAgent", IDENTITY + ".ProviderAgent.Python", IDENTITY + ".ProviderAgent.Codex"}
    require(required <= set(identities), "nested_identity_missing")
    require(all(identities.count(identifier) == 1 for identifier in required), "duplicate_process_identity")
    packaging.verify_signature(framework, IDENTITY + ".ProviderAgent.PythonRuntime", {})
    fixture_hashes = set()
    for relative, identifier, _, rights, _ in packaging.BUNDLES:
        nested = bundle / relative
        packaging.verify_signature(nested, identifier, rights)
        fixture_map = safe_path(nested, "Contents/Resources/fixture-map.json")
        require(read_json(fixture_map) == {"groupRoot": str(HOME / "Library/Group Containers" / GROUP)}, "fixture_map_mismatch")
        fixture_hashes.add(sha256(fixture_map))
    require(len(fixture_hashes) == 1, "fixture_map_hash_mismatch")
    evidence["manifest"].update(sourceCommit=inventory["sourceBaseCommit"], sourceTreeHash=inventory["sourceTreeHash"], artifactHash=inventory["artifactHash"], fixtureMapHash=fixture_hashes.pop(), entitlementHash=packaging.json_hash(entitlements), codeIdentityRefs=sorted(set(identities)))
    evidence["automated"].append(result("bundleIntegrity", "pass", "nested_signatures_hashes_arch_entitlements_verified"))


def clean_account():
    if sys.platform != "darwin":
        return False
    account = pwd.getpwuid(os.getuid())
    return os.getuid() == os.geteuid() and os.getuid() >= 500 and account.pw_name == "paperlens-topology" and account.pw_dir == str(HOME) and Path.home() == HOME and not HOME.is_symlink()


def no_acl(path):
    library = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
    library.acl_get_file.argtypes = [ctypes.c_char_p, ctypes.c_int]
    library.acl_get_file.restype = ctypes.c_void_p
    library.acl_get_entry.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.POINTER(ctypes.c_void_p)]
    library.acl_get_entry.restype = ctypes.c_int
    library.acl_free.argtypes = [ctypes.c_void_p]
    pointer = library.acl_get_file(os.fsencode(path), 0x100)
    if not pointer:
        return False
    try:
        entry = ctypes.c_void_p()
        return library.acl_get_entry(pointer, 0, ctypes.byref(entry)) == 0
    finally:
        library.acl_free(pointer)


def uuid4(value):
    parsed = uuid.UUID(value)
    require(parsed.version == 4 and str(parsed) == value, "invalid_run_id")
    return value


def group_message(value, run_id, phase):
    require(isinstance(value, dict), "group_owner_invalid_message")
    if value.get("status") == "blocked":
        require(set(value) == {"status", "fixtureID", "reason"} and value["fixtureID"] == "G" and value["reason"] in ("profileOrGroupUnavailable", "fixtureUnavailable"), "group_owner_invalid_message")
        raise Failure("group_owner_fixture_unavailable")
    require(value.get("runID") == run_id and value.get("fixtureID") == "G", "group_owner_run_mismatch")
    if phase == "ready":
        require(set(value) == {"status", "runID", "fixtureID", "ownerPre", "expectedRootMatched", "posixACLControl"}, "group_owner_invalid_message")
        require(value["status"] == "ready" and value["ownerPre"] == "pass" and value["expectedRootMatched"] is True and value["posixACLControl"] == "unverified", "group_owner_not_ready")
    else:
        require(set(value) == {"status", "runID", "fixtureID", "ownerPost", "absent"}, "group_owner_invalid_message")
        require(value["status"] in ("complete", "failed") and value["ownerPost"] in ("pass", "failed") and type(value["absent"]) is bool, "group_owner_invalid_message")
        require((value["status"] == "complete") == (value["ownerPost"] == "pass" and value["absent"]), "group_owner_inconsistent_post")
    return value


class GroupOwner:
    """Own one signed fixture process and its bounded, allowlisted pipe."""
    def __init__(self, arch, run_id):
        require(clean_account(), "fixture_profile_mismatch")
        require(arch in ARCHES, "unsupported_arch")
        self.arch = arch
        self.run_id = uuid4(run_id)
        self.process = None
        self.buffer = b""
        self.ready = False
        self.completed = False

    def receive(self, deadline):
        with selectors.DefaultSelector() as selector:
            selector.register(self.process.stdout, selectors.EVENT_READ)
            while b"\n" not in self.buffer:
                remaining = deadline - time.monotonic()
                require(remaining > 0 and selector.select(remaining), "group_owner_response_timeout")
                chunk = os.read(self.process.stdout.fileno(), 4097 - len(self.buffer))
                require(chunk, "group_owner_unexpected_eof")
                self.buffer += chunk
                require(len(self.buffer) <= 4096, "group_owner_response_limit")
            line, self.buffer = self.buffer.split(b"\n", 1)
        require(line and not self.buffer, "group_owner_unsolicited_output")
        return decode_json(line)

    def start(self):
        require(clean_account(), "fixture_profile_mismatch")
        bundle = safe_path(ROOT / ".build/topology" / self.arch, "products/FixtureGroupOwner.app")
        require(bundle.is_dir(), "group_owner_bundle_unavailable")
        packaging.check_tree(bundle)
        info = plistlib.loads(safe_path(bundle, "Contents/Info.plist").read_bytes())
        require(info.get("CFBundleIdentifier") == GROUP_OWNER and info.get("CFBundleExecutable") == "FixtureGroupOwner", "group_owner_identity_mismatch")
        executable = safe_path(bundle, "Contents/MacOS/FixtureGroupOwner")
        require(packaging.inspect_macho(executable, self.arch, bundle) == "executable", "group_owner_not_executable")
        rights = {SANDBOX: True, "com.apple.security.application-groups": [GROUP]}
        packaging.verify_signature(executable, GROUP_OWNER, rights)
        packaging.verify_signature(bundle, GROUP_OWNER, rights)
        require(read_json(safe_path(bundle, "Contents/Resources/fixture-map.json")) == {"groupRoot": str(HOME / "Library/Group Containers" / GROUP)}, "group_owner_map_mismatch")
        # No caller-supplied path, shell, environment, or product group rights.
        self.process = subprocess.Popen([str(executable), "--run-id", self.run_id], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=clean_env(), bufsize=0)
        group_message(self.receive(time.monotonic() + 10), self.run_id, "ready")
        require(self.process.poll() is None, "group_owner_exited_before_probes")
        self.ready = True

    def finish(self):
        if self.process is None:
            return None
        try:
            alive = self.process.poll() is None
            if alive:
                self.process.terminate()
            if not self.ready:
                return None
            require(alive, "group_owner_exited_during_probes")
            deadline = time.monotonic() + 10
            value = group_message(self.receive(deadline), self.run_id, "post")
            status = self.process.wait(timeout=max(0.001, deadline - time.monotonic()))
            require(status == (0 if value["status"] == "complete" else 1), "group_owner_exit_mismatch")
            # EOF must follow the single post record; extra output is rejected.
            with selectors.DefaultSelector() as selector:
                selector.register(self.process.stdout, selectors.EVENT_READ)
                remaining = deadline - time.monotonic()
                require(remaining > 0 and selector.select(remaining), "group_owner_eof_timeout")
                require(os.read(self.process.stdout.fileno(), 1) == b"", "group_owner_unsolicited_output")
            self.completed = value["status"] == "complete"
            return value
        finally:
            if self.process.poll() is None:
                try:
                    self.process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    self.process.kill()
                    self.process.wait(timeout=2)
            self.process.stdout.close()


class Controls:
    def __init__(self, run_id):
        require(clean_account(), "fixture_profile_mismatch")
        self.run_id = uuid4(run_id)
        self.marker = b"PaperLens topology canary\n"
        self.path = HOME / "Library/Application Support/PaperLensTopologyFixtureHost" / run_id / "external.canary"
        self.server = None
        self.thread = None
        self.stop = threading.Event()
        self.pre = False
        self.post = False
        self.network_pre = False
        self.network_post = False
        self.inbound_pre = False
        self.inbound_post = False

    def check_external(self):
        descriptor = os.open(self.path, os.O_RDWR | os.O_NOFOLLOW)
        try:
            metadata = os.fstat(descriptor)
            require(metadata.st_uid == os.getuid() and stat.S_IMODE(metadata.st_mode) == 0o600 and no_acl(self.path), "fixture_posix_acl_failed")
            require(os.read(descriptor, len(self.marker) + 1) == self.marker, "external_marker_modified")
            # Same bytes, only after checking the original marker; no repair.
            os.lseek(descriptor, 0, os.SEEK_SET)
            require(os.write(descriptor, self.marker) == len(self.marker), "owner_write_failed")
            os.lseek(descriptor, 0, os.SEEK_SET)
            require(os.read(descriptor, len(self.marker) + 1) == self.marker, "owner_read_failed")
            return True
        finally:
            os.close(descriptor)

    def listen_control(self):
        try:
            with socket.socket() as probe:
                probe.settimeout(2)
                probe.bind(("127.0.0.1", 18766))
                probe.listen(1)
            return True
        except OSError:
            return False

    def serve(self):
        while not self.stop.is_set():
            try:
                connection, _ = self.server.accept()
                with connection:
                    deadline = time.monotonic() + 2
                    data = self.receive_nonce(connection, deadline)
                    remaining = deadline - time.monotonic()
                    if data == b"PaperLensTopology\n" and remaining > 0:
                        connection.settimeout(remaining)
                        connection.sendall(data)
            except (OSError, TimeoutError):
                continue

    @staticmethod
    def receive_nonce(connection, deadline):
        data = b""
        while len(data) < len(b"PaperLensTopology\n"):
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return b""
            connection.settimeout(remaining)
            chunk = connection.recv(len(b"PaperLensTopology\n") - len(data))
            if not chunk:
                return b""
            data += chunk
        return data

    def echo_control(self):
        try:
            deadline = time.monotonic() + 2
            with socket.create_connection(("127.0.0.1", 18765), timeout=2) as connection:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    return False
                connection.settimeout(remaining)
                connection.sendall(b"PaperLensTopology\n")
                return self.receive_nonce(connection, deadline) == b"PaperLensTopology\n"
        except OSError:
            return False

    def start(self):
        parent = safe_path(HOME, "Library/Application Support/PaperLensTopologyFixtureHost")
        ensure_root(parent)
        directory = safe_path(parent, self.run_id)
        directory.mkdir(mode=0o700)  # Existing run directory is never reused.
        require(stat.S_IMODE(directory.stat().st_mode) == 0o700 and no_acl(directory), "fixture_directory_control_failed")
        with self.path.open("xb") as output:
            os.chmod(self.path, 0o600)
            output.write(self.marker)
        self.pre = self.check_external()
        self.inbound_pre = self.listen_control()
        self.server = socket.socket()
        self.server.settimeout(0.2)
        self.server.bind(("127.0.0.1", 18765))
        self.server.listen(8)
        self.thread = threading.Thread(target=self.serve, daemon=True)
        self.thread.start()
        self.network_pre = self.echo_control()
        require(self.inbound_pre and self.network_pre, "network_control_failed")

    def finish(self):
        try:
            self.post = self.check_external() if self.pre else False
            self.network_post = self.echo_control() if self.thread else False
            self.inbound_post = self.listen_control()
        finally:
            self.stop.set()
            if self.server:
                self.server.close()
            if self.thread:
                self.thread.join(timeout=3)
        # Preserve even failed synthetic fixtures for owner review. No unlink,
        # rmtree, TCC reset, group creation or access to another user's home.


def project_cases(report, run_id):
    require(report.get("schemaRevision") == "topology-v1" and report.get("runID") == run_id, "stale_or_invalid_report")
    require(isinstance(report.get("cases"), list) and len(report["cases"]) <= 256, "report_case_limit")
    projected = []
    for item in report["cases"]:
        require(isinstance(item, dict), "invalid_report_case")
        row = {key: None for key in CASE_FIELDS}
        row["runID"] = run_id
        for key in ("caseID", "actorInstanceRef", "operation"):
            value = item.get(key)
            require(isinstance(value, str) and re.fullmatch(r"[A-Za-z0-9_.:-]{1,128}", value), "unsafe_report_field")
            row[key] = value
        fixture = item.get("fixtureID")
        require(fixture in ("M", "A", "C", "E", "G", "PDF", "loopback", "A/C", "network", None), "unsafe_fixture_alias")
        row["fixtureID"] = fixture
        for key in ("ownerPre", "ownerPost", "sameUIDControl", "posixACLControl"):
            value = item.get(key)
            row[key] = value if type(value) is bool or isinstance(value, str) and value in ("pass", "failed", "blocked", "inconclusive", "unverified") else None
        for key in ("expectedRootMatched", "promptObserved"):
            value = item.get(key)
            row[key] = value if type(value) is bool else None
        for key in ("syscallResult", "errno"):
            value = item.get(key)
            row[key] = value if type(value) is int and -(2**31) <= value < 2**31 else None
        # An in-app string is not independent OS denial evidence. Do not copy
        # arbitrary log references or promote denied errno to isolation PASS.
        row["sandboxDenialRef"] = None
        proposed = item.get("verdict")
        row["verdict"] = proposed if proposed in ("failed", "blocked", "inconclusive") else "inconclusive"
        if row["promptObserved"]:
            row["verdict"] = "inconclusive"
        projected.append(row)
    return projected


def project_statuses(report):
    fields = {
        "runtimeStatus": "runtimeInitialize",
        "providerRuntimeStatus": "providerInitialize",
        "pdfiumRuntimeStatus": "pdfiumInitialize",
        "fixtureStatus": "fixtureReadiness",
        "isolationVerdict": "signedIsolation",
    }
    projected = []
    for field, case in fields.items():
        value = report.get(field)
        require(isinstance(value, str) and value in ("pass", "failed", "blocked", "inconclusive"), "invalid_native_status")
        # Native fixture readiness is not independent isolation proof.
        if field in ("fixtureStatus", "isolationVerdict") and value == "pass":
            value = "inconclusive"
        projected.append(result(case, value, "signed_gui_status_observed", executed=True))
    return projected


def gui_run(bundle, evidence):
    require(clean_account(), "fixture_profile_mismatch")
    run_id = str(uuid.uuid4())
    # Do not overwrite a prior owner's evidence even though the application
    # itself uses atomic report replacement. No report is read until this gate.
    safe_path(HOME, REPORT.relative_to(HOME).as_posix())
    require(not REPORT.exists(), "existing_owner_report_preserved")
    controls = Controls(run_id)
    owner = GroupOwner(evidence["requestedCPU"], run_id)
    controls_started = False
    try:
        owner.start()
        evidence["groupOwner"].update(executionStatus="observed", runID=run_id, ownerPre="pass")
        evidence["automated"].append(result("groupOwnerPre", "pass", "signed_owner_ready_expected_root", executed=True))
        controls_started = True
        controls.start()
        status, _, _ = command(["/usr/bin/open", "-n", bundle, "--args", "--topology-smoke", "--run-id", run_id])
        require(status == 0, "gui_launch_failed")
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            if REPORT.exists():
                safe_path(HOME, REPORT.relative_to(HOME).as_posix())
                report = read_json(REPORT, maximum=1024**2)
                evidence["cases"] = project_cases(report, run_id)
                evidence["automated"].extend(project_statuses(report))
                evidence["automated"].append(result("guiLaunch", "pass", "matching_synthetic_run_report"))
                return
            time.sleep(0.1)
        raise Failure("gui_report_timeout")
    finally:
        try:
            if controls_started:
                controls.finish()
        finally:
            evidence["automated"].extend([
                result("externalOwnerControl", "pass" if controls.pre and controls.post else "failed" if controls.pre else "blocked", "owner_marker_and_same_uid_read_write", executed=controls_started),
                result("loopbackControl", "pass" if controls.network_pre and controls.network_post and controls.inbound_pre and controls.inbound_post else "blocked", "pre_post_connect_and_bind_control", executed=controls_started),
            ])
            try:
                if owner.process is not None:
                    evidence["groupOwner"].update(executionStatus="observed", runID=run_id)
                post = owner.finish()
                if post is not None:
                    evidence["groupOwner"].update(ownerPost=post["ownerPost"], absent=post["absent"])
                    evidence["automated"].append(result("groupOwnerPost", "pass" if owner.completed else "failed", "signed_owner_post_and_absence_observed", executed=True))
                    for row in evidence["cases"]:
                        if row["fixtureID"] == "G":
                            row["ownerPre"] = "pass"
                            row["ownerPost"] = post["ownerPost"]
                            # Group owner says ACL is unverified; it is not a
                            # same-UID non-sandbox control or OS denial proof.
                            row["posixACLControl"] = "unverified"
                else:
                    evidence["automated"].append(result("groupOwnerPost", "blocked", "group_owner_not_ready"))
            except (Failure, OSError, ValueError, subprocess.TimeoutExpired):
                evidence["automated"].append(result("groupOwnerPost", "failed" if owner.ready else "blocked", "group_owner_post_not_proven", executed=owner.process is not None))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--arch", required=True, choices=ARCHES)
    parser.add_argument("--bundle", required=True, type=Path)
    parser.add_argument("--confirm-clean-profile", action="store_true", help="Human attests this exact synthetic account has no added TCC/container/FDA grants; never changes permissions")
    args = parser.parse_args(argv)
    evidence = base_evidence(args.arch)
    try:
        actual, translated = native_cpu()
        evidence["manifest"]["actualCPU"] = actual if actual in ARCHES else "unknown"
        evidence["processTranslated"] = translated
        status, output, _ = command(["/usr/bin/sw_vers", "-buildVersion"])
        build = output.decode().strip() if status == 0 else ""
        if re.fullmatch(r"[0-9A-Za-z.]{1,32}", build):
            evidence["manifest"]["OSBuild"] = build
        native = actual == args.arch and translated is False
        evidence["automated"].append(result("actualCPU", "pass" if native else "blocked", "native_not_rosetta" if native else "native_cpu_not_proven", executed=True))
        inspect_bundle(args.bundle.absolute(), args.arch, evidence)
        if not native:
            evidence["automated"].append(result("guiLaunch", "blocked", "native_cpu_required"))
        elif not clean_account() or not args.confirm_clean_profile:
            evidence["automated"].append(result("guiLaunch", "blocked", "exact_clean_fixture_profile_required"))
        else:
            evidence["manual"][0] = result("cleanProfile", "inconclusive", "human_attested_no_additional_grants_not_automatically_proven", executed=True)
            gui_run(args.bundle.absolute(), evidence)
    except (Failure, packaging.Failure) as error:
        failed = str(error) in {"inventory_hash_mismatch", "artifact_hash_mismatch", "inventory_coverage_mismatch", "manifest_code_policy_mismatch", "manifest_code_kind_mismatch", "inventory_link_mismatch", "manifest_arch_mismatch", "acquisition_hash_mismatch", "dependency_lock_mismatch", "acquisition_manifest_mismatch", "source_provenance_mismatch", "signed_identifier_mismatch", "signed_team_mismatch", "signed_entitlements_mismatch", "binary_architecture_mismatch", "fixture_map_mismatch"}
        evidence["automated"].append(result("verification", "failed" if failed else "blocked", str(error), executed=True))
    except (OSError, ValueError, KeyError, TypeError, plistlib.InvalidFileException, subprocess.TimeoutExpired):
        evidence["automated"].append(result("verification", "blocked", "verification_input_or_tool_failed"))
    if any(row["verdict"] == "failed" for section in ("automated", "cases") for row in evidence[section]):
        evidence["verdict"] = "failed"
    print(json.dumps(evidence, sort_keys=True, indent=2))
    # The unattended verifier never claims Story/P-1 completion. A correctly
    # prepared local bundle still has remote/manual/second-host gates blocked.
    return 1 if evidence["verdict"] == "failed" else 2


if __name__ == "__main__":
    raise SystemExit(main())
