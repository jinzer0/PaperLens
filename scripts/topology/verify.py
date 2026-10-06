#!/usr/bin/env python3
"""Read-only signed-bundle checks and explicitly opted-in synthetic GUI run.

No notarization, stapling, spctl submission, permission reset, or real-container
inspection. Evidence never includes raw SDK, codesign, subprocess or OS logs.
"""
from __future__ import annotations

import argparse
import ctypes
import errno
import hashlib
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
SANDBOX = "com.apple.security.app-sandbox"
NETWORK = "com.apple.security.network.client"
INHERIT = "com.apple.security.inherit"
GROUP = TEAM + "." + IDENTITY + ".TopologyFixture"
GROUP_OWNER = IDENTITY + ".TopologyFixtureOwner"
FIXTURE_MAP = {"profile": "current-user", "groupID": GROUP}
CASE_FIELDS = ("runID", "caseID", "fixtureID", "actorInstanceRef", "operation", "ownerPre", "ownerPost", "sameUIDControl", "expectedRootMatched", "posixACLControl", "syscallResult", "errno", "sandboxDenialRef", "promptObserved", "verdict", "syscallObserved", "intervalRef")
ROLES = ("Main", "ProviderAgent", "Python", "PDFiumXPC")
OPERATIONS = ("read", "write", "symlinkRead", "readWrite", "connect", "bind", "listen", "descriptorRead", "descriptorWrite")
READINESS = "topology-readiness-v1"
RENAME_EXCL = 0x00000004  # Public Darwin sys/stdio.h; never replace an ACK.


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
        "schemaRevision": "topology-evidence-v2",
        "manifest": {"schemaRevision": "topology-evidence-v2", "sourceCommit": None, "sourceTreeHash": None, "artifactHash": None, "fixtureMapHash": None, "entitlementHash": None, "OSBuild": None, "actualCPU": actual, "codeIdentityRefs": []},
        "requestedCPU": arch,
        "processTranslated": None,
        "automated": [],
        "manual": [result("currentProfile", "blocked", "human_synthetic_only_consent_required"), result("cleanProfile", "blocked", "current_account_not_clean_machine_evidence"), result("sandboxDenialAttribution", "blocked", "per_actor_os_denial_and_posix_tcc_controls_required")],
        "remote": [result("notarization", "blocked", "separate_submission_authorization_required"), result("staple", "blocked", "notarization_not_performed"), result("gatekeeperCleanGUI", "blocked", "separate_clean_machine_evidence_required"), result("actualTwoCPU", "blocked", "independent_native_arm64_and_intel_receipts_required")],
        "groupOwner": {"executionStatus": "unexecuted", "runID": None, "fixtureID": "G", "ownerPre": None, "ownerPost": None, "absent": None, "posixACLControl": "unverified"},
        "intelDynamic": result("intelDynamic", "blocked", "approved_prototype_waiver_support_unverified"),
        "actualTwoCPU": False,
        "actorBindings": [], "controls": [], "intervals": [], "denials": [],
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
        validate_fixture_map(fixture_map)
        fixture_hashes.add(sha256(fixture_map))
    require(len(fixture_hashes) == 1, "fixture_map_hash_mismatch")
    evidence["manifest"].update(sourceCommit=inventory["sourceBaseCommit"], sourceTreeHash=inventory["sourceTreeHash"], artifactHash=inventory["artifactHash"], fixtureMapHash=fixture_hashes.pop(), entitlementHash=packaging.json_hash(entitlements), codeIdentityRefs=sorted(set(identities)))
    evidence["automated"].append(result("bundleIntegrity", "pass", "nested_signatures_hashes_arch_entitlements_verified"))


def validate_fixture_map(path):
    require(read_json(path) == FIXTURE_MAP, "fixture_map_mismatch")


def current_home():
    """Resolve only OS account metadata; never trust an overridden HOME."""
    require(sys.platform == "darwin", "fixture_profile_mismatch")
    uid = os.getuid()
    require(uid == os.geteuid() and uid >= 500, "fixture_profile_mismatch")
    try:
        account = pwd.getpwuid(uid)
        home = Path(account.pw_dir)
        require(account.pw_uid == uid and home.is_absolute() and home.is_dir() and not home.is_symlink(), "fixture_profile_mismatch")
        require(home.resolve(strict=True) == home and Path.home() == home, "fixture_profile_mismatch")
    except (KeyError, OSError, ValueError, RuntimeError):
        raise Failure("fixture_profile_mismatch") from None
    return home


def no_acl(path):
    library = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
    library.acl_get_fd_np.argtypes = [ctypes.c_int, ctypes.c_int]
    library.acl_get_fd_np.restype = ctypes.c_void_p
    library.acl_get_entry.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.POINTER(ctypes.c_void_p)]
    library.acl_get_entry.restype = ctypes.c_int
    library.acl_free.argtypes = [ctypes.c_void_p]
    borrowed = type(path) is int
    try:
        descriptor = path if borrowed else os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except OSError:
        return False
    pointer = None
    try:
        ctypes.set_errno(0)
        pointer = library.acl_get_fd_np(descriptor, 0x100)
        # With a live descriptor ENOENT means no extended ACL, not a missing file.
        if not pointer:
            return ctypes.get_errno() == errno.ENOENT
        entry = ctypes.c_void_p()
        ctypes.set_errno(0)
        # Darwin returns zero when an entry EXISTS, not when the ACL is empty.
        status = library.acl_get_entry(pointer, 0, ctypes.byref(entry))
        return status == -1 and ctypes.get_errno() == errno.EINVAL
    finally:
        if pointer:
            library.acl_free(pointer)
        if not borrowed:
            os.close(descriptor)


def uuid4(value):
    parsed = uuid.UUID(value)
    require(parsed.version == 4 and str(parsed) == value, "invalid_run_id")
    return value


def group_message(value, run_id, phase):
    require(isinstance(value, dict), "group_owner_invalid_message")
    if value.get("status") == "blocked":
        reasons = {"invalidInvocation": "group_owner_invalid_invocation", "profileUnavailable": "group_owner_profile_unavailable", "groupUnavailable": "group_owner_group_unavailable", "groupPathMismatch": "group_owner_group_path_mismatch", "groupDirectoryUnavailable": "group_owner_group_directory_unavailable", "fixtureUnavailable": "group_owner_fixture_unavailable"}
        require(set(value) == {"status", "fixtureID", "reason"} and value["fixtureID"] == "G" and value["reason"] in reasons, "group_owner_invalid_message")
        raise Failure(reasons[value["reason"]])
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
        self.home = current_home()
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
        require(current_home() == self.home, "fixture_profile_mismatch")
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
        validate_fixture_map(safe_path(bundle, "Contents/Resources/fixture-map.json"))
        # The signed owner derives expected G from its real-UID account home
        # and compares the OS group URL before emitting expectedRootMatched.
        # No caller-supplied path, shell, environment, or product group rights.
        self.process = subprocess.Popen([str(executable), "--run-id", self.run_id], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=clean_env(), bufsize=0)
        group_message(self.receive(time.monotonic() + 10), self.run_id, "ready")
        require(self.process.poll() is None, "group_owner_exited_before_probes")
        self.ready = True

    def finish(self, deadline=None):
        if self.process is None:
            return None
        try:
            alive = self.process.poll() is None
            if alive:
                self.process.terminate()
            if not self.ready:
                return None
            require(alive, "group_owner_exited_during_probes")
            deadline = time.monotonic() + 10 if deadline is None else deadline
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
        self.home = current_home()
        self.run_id = uuid4(run_id)
        self.marker = b"PaperLens topology canary\n"
        self.path = self.home / "Library/Application Support/PaperLensTopologyFixtureHost" / run_id / "external.canary"
        self.identity = None
        self.server = None
        self.thread = None
        self.stop = threading.Event()
        self.pre = False
        self.post = False
        self.network_pre = False
        self.network_post = False
        self.inbound_pre = False
        self.inbound_post = False
        self.finished = False

    def check_external(self):
        safe_path(self.home, self.path.relative_to(self.home).as_posix())
        descriptor = os.open(self.path, os.O_RDWR | os.O_NOFOLLOW)
        try:
            metadata = os.fstat(descriptor)
            require(self.identity == (metadata.st_dev, metadata.st_ino) and stat.S_ISREG(metadata.st_mode), "external_fixture_identity_changed")
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
        require(current_home() == self.home, "fixture_profile_mismatch")
        parent = safe_path(self.home, "Library/Application Support/PaperLensTopologyFixtureHost")
        ensure_root(parent)
        directory = safe_path(parent, self.run_id)
        directory.mkdir(mode=0o700)  # Existing run directory is never reused.
        require(stat.S_IMODE(directory.stat().st_mode) == 0o700 and no_acl(directory), "fixture_directory_control_failed")
        with self.path.open("xb") as output:
            os.fchmod(output.fileno(), 0o600)
            metadata = os.fstat(output.fileno())
            self.identity = (metadata.st_dev, metadata.st_ino)
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
        if self.finished:
            return
        self.finished = True
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


def int_range(value, minimum=0, maximum=2**63 - 1):
    return type(value) is int and minimum <= value <= maximum


def safe_case_id(value):
    return isinstance(value, str) and re.fullmatch(r"[A-Za-z0-9_.:-]{1,128}", value) is not None


def file_identity(info):
    return info.st_dev, info.st_ino


def private_fd(descriptor, directory=False):
    info = os.fstat(descriptor)
    require((stat.S_ISDIR(info.st_mode) if directory else stat.S_ISREG(info.st_mode))
            and info.st_uid == os.getuid() and stat.S_IMODE(info.st_mode) == (0o700 if directory else 0o600)
            and (info.st_nlink >= 2 if directory else info.st_nlink == 1)
            and no_acl(descriptor), "unsafe_live_inode")
    return info


def directory_fd(path, private=True):
    """Walk each fixed ancestor with openat; never follow or repair a link."""
    require(path.is_absolute(), "unsafe_live_directory")
    descriptor = os.open(path.anchor, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        for part in path.parts[1:]:
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=descriptor)
            os.close(descriptor)
            descriptor = child
        if private:
            private_fd(descriptor, directory=True)
        return descriptor
    except BaseException:
        os.close(descriptor)
        raise


def read_at(directory, name, maximum):
    descriptor = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC, dir_fd=directory)
    try:
        info = private_fd(descriptor)
        require(info.st_size <= maximum, "evidence_size_limit")
        data = bytearray()
        while len(data) <= maximum:
            chunk = os.read(descriptor, min(8192, maximum + 1 - len(data)))
            if not chunk:
                break
            data.extend(chunk)
        require(len(data) <= maximum and file_identity(os.stat(name, dir_fd=directory, follow_symlinks=False)) == file_identity(info), "unsafe_live_inode")
        return bytes(data), info
    finally:
        os.close(descriptor)


def run_paths(home, run_id):
    uuid4(run_id)
    main = home / "Library/Containers" / IDENTITY / "Data/Library/Application Support/PaperLensTopology"
    worker = home / "Library/Containers" / (IDENTITY + ".PDFiumXPC") / "Data/Library/Application Support/PaperLensTopology"
    return main / "Reports" / run_id, worker / run_id


def collision_preflight(home, run_id):
    # Main alone reserves Reports/r. lexists includes dangling symlinks. The
    # historical fixed report is deliberately not read, adopted or gated on.
    for path in run_paths(home, run_id):
        require(not os.path.lexists(path), "existing_run_preserved")
        safe_path(home, path.relative_to(home).as_posix())
    return run_paths(home, run_id)


def ready_message(value, run_id, phase, contract_hash, worker=False):
    fields = {"schemaRevision", "runID", "phase", "contractHash", "clock", "actors", "links", "intervals", "ownerControl"}
    require(type(value) is dict and set(value) == fields, "invalid_readiness_schema")
    require(value["schemaRevision"] == READINESS and value["runID"] == run_id
            and value["phase"] == phase and value["contractHash"] == contract_hash
            and value["clock"] == "darwin-uptime-ns" and type(value["ownerControl"]) is bool,
            "readiness_hash_or_phase_mismatch")
    actors = value["actors"]
    require(type(actors) is list and len(actors) == (1 if worker else 4), "invalid_actor_candidates")
    require(all(type(a) is dict and set(a) == {"role", "pid"} and a["role"] in ROLES
                and int_range(a["pid"], 1, 2**31 - 1) for a in actors), "invalid_actor_candidates")
    require({a["role"] for a in actors} == ({"PDFiumXPC"} if worker else set(ROLES))
            and len({a["pid"] for a in actors}) == len(actors), "invalid_actor_candidates")
    links = value["links"]
    aliases = {"M", "A", "C", "E", "G"} if worker else {"A", "C"}
    require(type(links) is list and len(links) == len(aliases)
            and all(type(link) is dict and set(link) == {"alias", "name"}
                    and link["alias"] in aliases and link["name"] == link["alias"] + ".link" for link in links)
            and {link["alias"] for link in links} == aliases, "invalid_readiness_links")
    intervals = value["intervals"]
    require(type(intervals) is list and len(intervals) <= 256, "invalid_readiness_intervals")
    require(all(type(i) is dict and set(i) == {"caseID", "beganAtNs", "endedAtNs"}
                and safe_case_id(i["caseID"]) and int_range(i["beganAtNs"])
                and int_range(i["endedAtNs"], i["beganAtNs"]) for i in intervals)
            and len({i["caseID"] for i in intervals}) == len(intervals), "invalid_readiness_intervals")
    require(all(case_contract(i["caseID"]) is not None and i["beganAtNs"] > 0
                and (not worker or case_contract(i["caseID"])[0] == "PDFiumXPC") for i in intervals), "invalid_readiness_intervals")
    return value


def bounded_query(argv, deadline, input_bytes=None, maximum=65536):
    """Bound both pipes in RAM and wall time; terminate only this owned query."""
    require(deadline > time.monotonic(), "evidence_query_timeout")
    process = subprocess.Popen(list(map(str, argv)), env=clean_env(), stdin=subprocess.PIPE if input_bytes is not None else subprocess.DEVNULL,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0)
    output = bytearray()
    errors = 0
    try:
        if input_bytes is not None:
            # Four closed actor records fit far below a pipe's capacity; do
            # not allow a large blocking stdin write to bypass the deadline.
            require(len(input_bytes) <= 4096, "evidence_query_limit")
            process.stdin.write(input_bytes)
            process.stdin.close()
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ, True)
            selector.register(process.stderr, selectors.EVENT_READ, False)
            while selector.get_map():
                remaining = deadline - time.monotonic()
                require(remaining > 0, "evidence_query_timeout")
                events = selector.select(remaining)
                require(events, "evidence_query_timeout")
                for key, _ in events:
                    chunk = os.read(key.fileobj.fileno(), 8192)
                    if not chunk:
                        selector.unregister(key.fileobj)
                    elif key.data:
                        output.extend(chunk)
                    else:
                        errors += len(chunk)
                    require(len(output) + errors <= maximum, "evidence_query_limit")
        status = process.wait(timeout=max(0.001, deadline - time.monotonic()))
        return status, bytes(output)
    finally:
        if process.poll() is None:
            process.kill()
            process.wait(timeout=2)
        process.stdout.close()
        process.stderr.close()
        if process.stdin is not None and not process.stdin.closed:
            process.stdin.close()


def compile_actor_helper(run_id):
    # No global toolchain selection or signing/rights changes. Match the
    # installed, approved Xcode toolchain before compiling this local helper.
    import acquire
    lock = acquire.load_lock()
    expected = lock["toolchain"]
    deadline = time.monotonic() + 30
    status, version = bounded_query(["/usr/bin/xcodebuild", "-version"], deadline)
    require(status == 0 and version.decode().strip() == f"Xcode {expected['xcode']}\nBuild version {expected['build']}", "actor_helper_toolchain_unproven")
    status, version = bounded_query(["/usr/bin/xcrun", "--toolchain", "com.apple.dt.toolchain.XcodeDefault", "swiftc", "--version"], deadline)
    require(status == 0 and re.search(rb"Apple Swift version 6\.4(?:\s|\.)", version), "actor_helper_toolchain_unproven")
    status, sdk_bytes = bounded_query(["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-path"], deadline)
    sdk = Path(sdk_bytes.decode().strip())
    require(status == 0 and sdk.is_relative_to(expected["developerDir"]), "actor_helper_sdk_unproven")
    status, sdk_version = bounded_query(["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-version"], deadline)
    require(status == 0 and sdk_version.decode().strip() == expected["sdk"], "actor_helper_sdk_unproven")
    headers = {
        "usr/include/libproc.h": ("proc_pidinfo(",),
        "usr/include/sys/proc_info.h": ("PROC_PIDTBSDINFO", "pbi_start_tvsec", "pbi_ruid"),
        "System/Library/Frameworks/Security.framework/Headers/SecCode.h": ("SecCodeCopyGuestWithAttributes", "SecCodeCheckValidity", "kSecCodeInfoUnique"),
        "System/Library/Frameworks/Security.framework/Headers/SecStaticCode.h": ("SecStaticCodeCreateWithPath", "SecStaticCodeCheckValidity"),
        "System/Library/Frameworks/Security.framework/Headers/SecRequirement.h": ("SecRequirementCreateWithString",),
    }
    for relative, symbols in headers.items():
        text = (sdk / relative).read_text()
        require(all(symbol in text for symbol in symbols), "actor_helper_public_api_unavailable")
    directory = ROOT / ".build/topology" / ("actor-identity-" + run_id)
    directory.mkdir(mode=0o700)
    require(stat.S_IMODE(directory.stat().st_mode) == 0o700 and no_acl(directory), "actor_helper_directory_unsafe")
    helper = directory / "ActorIdentityProbe"
    status, _ = bounded_query(["/usr/bin/xcrun", "--toolchain", "com.apple.dt.toolchain.XcodeDefault", "swiftc", "-parse-as-library",
                               "-sdk", sdk, "-target", "arm64-apple-macosx15.0", ROOT / "Tests/Topology/ActorIdentityProbe.swift", "-o", helper], time.monotonic() + 30, maximum=1024**2)
    require(status == 0 and helper.is_file() and not helper.is_symlink(), "actor_helper_compile_blocked")
    return helper


def actor_records(value, candidates):
    require(type(value) is dict and set(value) == {"status", "actors", "timebase"}
            and value["status"] == "verified", "actor_identity_unproven")
    timebase = value["timebase"]
    require(type(timebase) is dict and set(timebase) == {"numerator", "denominator"}
            and all(int_range(v, 1, 2**32 - 1) for v in timebase.values()), "actor_clock_unproven")
    actors = value["actors"]
    require(type(actors) is list and len(actors) == len(candidates), "actor_identity_unproven")
    expected = {a["role"]: a["pid"] for a in candidates}
    records = {}
    identifiers = {"Main": IDENTITY, "ProviderAgent": IDENTITY + ".ProviderAgent", "Python": IDENTITY + ".ProviderAgent.Python", "PDFiumXPC": IDENTITY + ".PDFiumXPC"}
    for actor in actors:
        require(type(actor) is dict and set(actor) == {"role", "pid", "parentPID", "birthSec", "birthUsec", "codeIdentityRef", "verified"}, "actor_identity_unproven")
        role = actor["role"]
        require(role in expected and role not in records and type(actor["verified"]) is bool and actor["verified"]
                and int_range(actor["pid"], 1, 2**31 - 1) and actor["pid"] == expected[role]
                and int_range(actor["parentPID"], 1, 2**31 - 1) and int_range(actor["birthSec"], 1)
                and int_range(actor["birthUsec"], 0, 999999) and actor["codeIdentityRef"] == identifiers[role], "actor_identity_unproven")
        records[role] = actor
    if "Python" in records:
        require(records["Python"]["parentPID"] == records["ProviderAgent"]["pid"], "actor_parent_mismatch")
    return records


def same_generation(before, after):
    require(set(before) == set(after) and all(before[role] == after[role] for role in before), "actor_generation_changed")


def synthetic_pdf():
    data = bytearray(b"%PDF-1.4\n")
    offsets = []
    for index, obj in enumerate(("<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>", "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 72 72] /Resources << >> >>"), 1):
        offsets.append(len(data))
        data.extend(f"{index} 0 obj\n{obj}\nendobj\n".encode())
    xref = len(data)
    data.extend(b"xref\n0 4\n0000000000 65535 f \n")
    for offset in offsets:
        data.extend(f"{offset:010d} 00000 n \n".encode())
    data.extend(f"trailer\n<< /Size 4 /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n".encode())
    return bytes(data)


def fixture_paths(home, run_id):
    main = home / "Library/Containers" / IDENTITY / "Data"
    agent = home / "Library/Containers" / (IDENTITY + ".ProviderAgent") / "Data"
    support = "Library/Application Support/PaperLensTopology"
    return {
        "M": main / support / run_id / "db.canary", "PDF": main / support / run_id / "input.pdf",
        "A": agent / support / run_id / "secret.canary", "C": agent / "Library/Caches/PaperLensTopology" / run_id / "cache.canary",
        "E": home / "Library/Application Support/PaperLensTopologyFixtureHost" / run_id / "external.canary",
        "G": home / "Library/Group Containers" / GROUP / "PaperLensTopology" / run_id / "group.canary",
    }


class LiveControls:
    """Independent descriptor controls; retain pre generation until post."""
    def __init__(self, paths):
        self.paths = paths
        self.files = {}
        self.links = {}
        self.rows = {}

    def file(self, alias, phase):
        path = self.paths[alias]
        directory = directory_fd(path.parent)
        directory_identity = file_identity(os.fstat(directory))
        read_fd = write_fd = None
        try:
            read_fd = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC, dir_fd=directory)
            info = private_fd(read_fd)
            expected = synthetic_pdf() if alias == "PDF" else b"PaperLens topology canary\n"
            require(info.st_size == len(expected) and os.pread(read_fd, len(expected) + 1, 0) == expected, "fixture_marker_unproven")
            if phase == "post":
                require(alias in self.files and file_identity(info) == self.files[alias][0]
                        and file_identity(os.fstat(self.files[alias][1])) == file_identity(info)
                        and directory_identity == self.files[alias][2], "fixture_generation_changed")
            write_fd = os.open(path.name, os.O_WRONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC, dir_fd=directory)
            require(file_identity(private_fd(write_fd)) == file_identity(info), "fixture_generation_changed")
            # Never repair: unchanged first byte only after marker/metadata read.
            require(os.pwrite(write_fd, expected[:1], 0) == 1 and os.pread(read_fd, len(expected) + 1, 0) == expected,
                    "fixture_control_unproven")
            require(file_identity(os.stat(path.name, dir_fd=directory, follow_symlinks=False)) == file_identity(info), "fixture_generation_changed")
            if phase == "pre":
                require(alias not in self.files, "fixture_control_replayed")
                self.files[alias] = (file_identity(info), read_fd, directory_identity)
                read_fd = None
            return True
        finally:
            os.close(directory)
            if read_fd is not None:
                os.close(read_fd)
            if write_fd is not None:
                os.close(write_fd)

    def link(self, root, alias, role, phase):
        directory = directory_fd(root)
        try:
            name = alias + ".link"
            info = os.stat(name, dir_fd=directory, follow_symlinks=False)
            require(stat.S_ISLNK(info.st_mode) and info.st_uid == os.getuid() and info.st_nlink == 1
                    and os.readlink(name, dir_fd=directory) == str(self.paths[alias]), "fixture_link_unproven")
            key = (role, alias)
            if phase == "pre":
                require(key not in self.links, "fixture_control_replayed")
                self.links[key] = (file_identity(info), file_identity(os.fstat(directory)))
            else:
                require(self.links.get(key) == (file_identity(info), file_identity(os.fstat(directory))), "fixture_generation_changed")
            return True
        finally:
            os.close(directory)

    def observe(self, role, phase, root, deadline):
        aliases = ("M", "A", "C", "E", "G", "PDF")
        for alias in aliases:
            require(time.monotonic() < deadline, "readiness_control_timeout")
            # The same target fixtures are checked at Main and Worker fences;
            # keep each observer's pre descriptor independent.
            key = (role, alias, "file")
            row = self.rows.setdefault(key, {"controlRef": "control-" + str(uuid.uuid4()), "role": role, "alias": alias,
                                              "operation": "readWrite", "preVerified": False, "postVerified": False, "reason": "control-unproven"})
            try:
                row[phase + "Verified"] = self.file(alias, phase)
                row["reason"] = "same-uid-not-tcc-proof"
            except (Failure, OSError):
                row["reason"] = "fixture-or-posix-acl-unproven"
        targets = {"Main": ("A", "C"), "PDFiumXPC": ("M", "A", "C", "E", "G")}[role]
        link_roots = [(role, root, targets)]
        if role == "Main":
            link_roots.append(("Python", self.paths["A"].parent, ("M", "E", "G")))
        for link_role, link_root, link_aliases in link_roots:
            for alias in link_aliases:
                require(time.monotonic() < deadline, "readiness_control_timeout")
                key = (link_role, alias, "symlinkRead")
                row = self.rows.setdefault(key, {"controlRef": "control-" + str(uuid.uuid4()), "role": link_role, "alias": alias,
                                                  "operation": "symlinkRead", "preVerified": False, "postVerified": False, "reason": "control-unproven"})
                try:
                    row[phase + "Verified"] = self.link(link_root, alias, link_role, phase)
                    row["reason"] = "fixed-link-verified"
                except (Failure, OSError):
                    row["reason"] = "fixed-link-unproven"

    def close(self):
        for _, descriptor, _ in self.files.values():
            os.close(descriptor)
        self.files.clear()


class ReadinessObserver:
    def __init__(self, home, run_id, bundle, artifact_hash, helper, controls, external, owner):
        self.paths = run_paths(home, run_id)
        self.run_id, self.bundle, self.artifact_hash, self.helper = run_id, bundle, artifact_hash, helper
        require(isinstance(artifact_hash, str) and re.fullmatch(r"[0-9a-f]{64}", artifact_hash), "artifact_hash_unproven")
        self.contract_hash = sha256(bundle / "Contents/Resources/contract.json")
        self.controls, self.external, self.owner = controls, external, owner
        self.directories = {}
        self.done = set()
        self.pending = {}
        self.bindings = {}
        self.post_bindings = {}
        self.intervals = {}
        self.owner_control = {}
        self.owner_post = None
        self.denials = []

    def query(self, candidates, seconds):
        status, data = bounded_query([self.helper, "--bundle", self.bundle], time.monotonic() + seconds,
                                      json.dumps({"actors": candidates}, separators=(",", ":")).encode())
        require(status == 0, "actor_identity_unproven")
        return actor_records(decode_json(data), candidates)

    def withdraw(self):
        for key, (directory, ready_name, ready_identity, ack_name, ack_identity, expires) in list(self.pending.items()):
            try:
                current = os.stat(ready_name, dir_fd=directory, follow_symlinks=False)
                require(file_identity(current) == ready_identity, "readiness_inode_replaced")
                require(time.monotonic() < expires, "ack_consumption_timeout")
                continue
            except FileNotFoundError:
                pass
            current = os.stat(ack_name, dir_fd=directory, follow_symlinks=False)
            require(file_identity(current) == ack_identity, "ack_inode_replaced")
            os.unlink(ack_name, dir_fd=directory)
            del self.pending[key]

    def poll(self):
        self.withdraw()
        for index, path in enumerate(self.paths):
            role = "Main" if index == 0 else "PDFiumXPC"
            if index not in self.directories:
                if not os.path.lexists(path):
                    continue
                if index == 0:
                    parent = directory_fd(path.parent)
                    os.close(parent)
                descriptor = directory_fd(path)
                self.directories[index] = (descriptor, file_identity(os.fstat(descriptor)))
            directory, identity = self.directories[index]
            if index == 1 and (index, "post") in self.done and not any(k[0] == index for k in self.pending):
                continue  # Worker owns cleanup after the symmetric ACK fence.
            require(file_identity(os.stat(path, follow_symlinks=False)) == identity, "readiness_directory_replaced")
            for phase in ("pre", "post"):
                key = (index, phase)
                if key in self.done or phase == "post" and (index, "pre") not in self.done:
                    continue
                ready_name = "ready.json" if phase == "pre" else "post-ready.json"
                ack_name = "continue.json" if phase == "pre" else "post-continue.json"
                try:
                    data, ready_info = read_at(directory, ready_name, 65536)
                except FileNotFoundError:
                    continue
                ready = ready_message(decode_json(data), self.run_id, phase, self.contract_hash, worker=index == 1)
                fence_deadline = time.monotonic() + (1.8 if index == 1 else 9.5)
                records = self.query(ready["actors"], 0.7 if index == 1 else 2)
                if phase == "pre" and index == 0:
                    require(not self.bindings, "actor_binding_replayed")
                    self.bindings = records
                else:
                    require(self.bindings, "worker_binding_without_main")
                    subset = {r: self.bindings[r] for r in records}
                    same_generation(subset, records)
                if phase == "post":
                    self.post_bindings.update(records)
                self.owner_control[key] = ready["ownerControl"]
                self.controls[index].observe(role, phase, self.controls[index].paths["M"].parent if index == 0 else path, fence_deadline)
                if phase == "post" and index == 0:
                    # Complete owner and nonsandbox controls before ACK permits
                    # Main/Agent cleanup. Keep external's lifecycle idempotent.
                    self.external.finish()
                    self.owner_post = self.owner.finish(deadline=fence_deadline - 2)
                for interval in ready["intervals"]:
                    prior = self.intervals.get(interval["caseID"])
                    require(prior is None or prior == interval, "interval_generation_changed")
                    self.intervals[interval["caseID"]] = interval
                # Re-bracket after descriptor controls before releasing actors.
                same_generation(records, self.query(ready["actors"], 0.7 if index == 1 else 2))
                if phase == "post" and index == 0:
                    self.denials = collect_os_evidence(self.bindings, self.controls[0].paths, self.intervals,
                                                      min(fence_deadline, time.monotonic() + 1))
                require(time.monotonic() < fence_deadline, "readiness_control_timeout")
                require(file_identity(os.stat(ready_name, dir_fd=directory, follow_symlinks=False)) == file_identity(ready_info), "readiness_inode_replaced")
                require(read_at(directory, ready_name, 65536)[0] == data, "readiness_bytes_changed")
                ack = {"schemaRevision": READINESS, "runID": self.run_id, "phase": phase,
                       "readyHash": hashlib.sha256(data).hexdigest(), "artifactHash": self.artifact_hash}
                temporary = str(uuid.uuid4()) + ".ack"
                fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600, dir_fd=directory)
                info = os.fstat(fd)
                try:
                    private_fd(fd)
                    payload = json.dumps(ack, sort_keys=True, separators=(",", ":")).encode()
                    offset = 0
                    while offset < len(payload):
                        require(time.monotonic() < fence_deadline, "readiness_control_timeout")
                        try:
                            count = os.write(fd, payload[offset:])
                        except InterruptedError:
                            continue
                        require(count > 0, "ack_write_failed")
                        offset += count
                    os.fsync(fd)
                    require(file_identity(os.stat(temporary, dir_fd=directory, follow_symlinks=False)) == file_identity(info), "ack_inode_replaced")
                    library = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
                    rename = library.renameatx_np
                    rename.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
                    rename.restype = ctypes.c_int
                    if rename(directory, os.fsencode(temporary), directory, os.fsencode(ack_name), RENAME_EXCL) != 0:
                        raise OSError(ctypes.get_errno(), "ack_publication_failed")
                    self.pending[key] = (directory, ready_name, file_identity(ready_info), ack_name, file_identity(info), time.monotonic() + (2 if index == 1 else 10))
                    require(file_identity(os.stat(ack_name, dir_fd=directory, follow_symlinks=False)) == file_identity(info), "ack_inode_replaced")
                finally:
                    os.close(fd)
                    try:
                        if file_identity(os.stat(temporary, dir_fd=directory, follow_symlinks=False)) == file_identity(info):
                            os.unlink(temporary, dir_fd=directory)
                    except FileNotFoundError:
                        pass
                self.done.add(key)

    def close(self):
        # No cleanup of ready, fixture, report or unknown/replaced ACKs. Native
        # consumes/removes its ready first; only then withdraw our owned ACK.
        try:
            self.withdraw()
        finally:
            for descriptor, _ in self.directories.values():
                os.close(descriptor)
            for control in self.controls:
                control.close()
            self.bindings.clear()
            self.post_bindings.clear()
            self.intervals.clear()
            self.pending.clear()


def safe_denial_projection(events, bindings, paths, intervals):
    """Exact nonce/PID/stage matches remain candidates, not denial proof.

    Public log timestamps do not establish uptime epoch/uncertainty semantics.
    Never promote wall clock, receipt ordering or machTimestamp by assumption.
    """
    projected = {}
    if type(events) is not list:
        return []
    for event in events:
        if type(event) is not dict or not int_range(event.get("processID"), 0, 2**31 - 1):
            continue
        message = event.get("eventMessage")
        if not isinstance(message, str) or len(message) > 8192:
            continue
        match = re.fullmatch(r"Sandbox: [^\n]{1,128}\(([0-9]+)\) deny\([0-9]+\) (file-read-data|file-write-data) (.+)", message)
        alias = operation = None
        if match:
            alias = next((a for a, path in paths.items() if str(path) == match[3]), None)
            operation = {"file-read-data": "read", "file-write-data": "write"}[match[2]]
        else:
            match = re.fullmatch(r"Sandbox: [^\n]{1,128}\(([0-9]+)\) deny\([0-9]+\) network-(outbound|bind|inbound) (?:TCP )?127\.0\.0\.1:(18765|18766)", message)
            if match:
                operation = {"outbound": "connect", "bind": "bind", "inbound": "listen"}[match[2]]
                if match[3] == ("18765" if operation == "connect" else "18766"):
                    alias = "network"
        if alias is None or match is None:
            continue
        subject = int(match[1])
        # The kernel logger is PID0; the denied subject is the bounded PID
        # in its closed Sandbox message, independently bound to this run.
        role = next((r for r, a in bindings.items() if a["pid"] == subject), None)
        if role is None or event["processID"] not in (0, subject):
            continue
        row = {"role": role, "alias": alias, "operation": operation,
               "attributed": False, "reason": "clock-unproven"}
        digest = packaging.json_hash(row)
        row["denialRef"] = "denial-" + digest
        projected[digest] = row
    return list(projected.values())


def collect_os_evidence(bindings, paths, intervals, deadline):
    if not bindings:
        return []
    pids = sorted({a["pid"] for a in bindings.values()})
    stages = ("file-read-data", "file-write-data", "network-outbound", "network-bind", "network-inbound")
    targets = [str(path) for path in paths.values()] + ["127.0.0.1:18765", "127.0.0.1:18766"]
    predicate = ("(processID == 0 OR " + " OR ".join(f"processID == {pid}" for pid in pids) + ") AND ("
                 + " OR ".join("eventMessage CONTAINS " + json.dumps(f"({pid}) deny(") for pid in pids) + ") AND eventMessage CONTAINS \"deny\" AND ("
                 + " OR ".join("eventMessage CONTAINS " + json.dumps(stage) for stage in stages) + ") AND ("
                 + " OR ".join("eventMessage ENDSWITH " + json.dumps(target, ensure_ascii=False) for target in targets) + ")")
    try:
        status, data = bounded_query(["/usr/bin/log", "show", "--last", "230s", "--style", "json", "--predicate", predicate], deadline, maximum=1024**2)
        if status != 0:
            return []
        return safe_denial_projection(decode_json(data), bindings, paths, intervals)
    except (Failure, OSError, ValueError, subprocess.TimeoutExpired):
        return []


def candidate_bindings(report):
    candidates = report.get("actorBindings")
    require(type(candidates) is list and len(candidates) == 4, "invalid_report_actor_bindings")
    by_ref = {}
    for candidate in candidates:
        require(type(candidate) is dict and set(candidate) == {"role", "actorInstanceRef", "identityVerified"}
                and candidate["role"] in ROLES and candidate["identityVerified"] is False, "invalid_report_actor_bindings")
        reference = candidate["actorInstanceRef"]
        require(isinstance(reference, str) and reference.startswith("actor-"), "invalid_report_actor_bindings")
        uuid4(reference[6:])
        require(reference not in by_ref, "invalid_report_actor_bindings")
        by_ref[reference] = candidate["role"]
    require(set(by_ref.values()) == set(ROLES), "invalid_report_actor_bindings")
    return by_ref


def case_contract(case_id):
    for role, aliases in (("Main", ("A", "C")), ("PDFiumXPC", ("M", "A", "C", "E", "G"))):
        for alias in aliases:
            for operation in ("read", "write", "symlinkRead"):
                if case_id == f"{role}.{alias}.{operation}":
                    return role, alias, operation
    for case, contract in {
        "Main.pre.network.connect": ("Main", "network", "connect"),
        "Main.post.network.connect": ("Main", "network", "connect"),
        "PDFiumXPC.network.connect": ("PDFiumXPC", "network", "connect"),
        "PDFiumXPC.PDF.descriptorRead": ("PDFiumXPC", "PDF", "descriptorRead"),
        "PDFiumXPC.PDF.descriptorWrite": ("PDFiumXPC", "PDF", "descriptorWrite"),
        "PDFiumXPC.PDF.write": ("PDFiumXPC", "PDF", "write"),
        "inboundListen": ("Python", "network", "listen"),
        "ownZoneReadWrite.pre": ("Python", "A/C", "readWrite"),
        "ownZoneReadWrite.post": ("Python", "A/C", "readWrite"),
    }.items():
        if case_id == case:
            return contract
    for prefix, alias in (("mainCanary", "M"), ("externalCanary", "E"), ("foreignGroupCanary", "G")):
        for suffix, operation in (("Read", "read"), ("Write", "write"), ("SymlinkRead", "symlinkRead")):
            if case_id == prefix + suffix:
                return "Python", alias, operation
    return None


def project_cases(report, run_id, observer=None, evidence=None):
    require(report.get("schemaRevision") == "topology-evidence-v2" and report.get("runID") == run_id, "stale_or_invalid_report")
    require(type(report.get("cases")) is list and len(report["cases"]) <= 256, "report_case_limit")
    references = candidate_bindings(report)
    if evidence is not None:
        for reference, role in references.items():
            pre = observer is not None and role in observer.bindings
            post = observer is not None and role in observer.post_bindings
            evidence["actorBindings"].append({"actorInstanceRef": reference, "role": role,
                                               "codeIdentityRef": observer.bindings[role]["codeIdentityRef"] if pre else None,
                                               "preVerified": pre, "postVerified": post})
        if observer is not None:
            refs_by_role = {role: reference for reference, role in references.items()}
            evidence["controls"] = [dict(row, actorInstanceRef=refs_by_role[row["role"]])
                                    for control in observer.controls for row in control.rows.values()]
            for role in ("Main", "Python", "PDFiumXPC"):
                for operation in ("connect", "bind", "listen"):
                    pre = observer.external.network_pre if operation == "connect" else observer.external.inbound_pre
                    post = observer.external.network_post if operation == "connect" else observer.external.inbound_post
                    evidence["controls"].append({"controlRef": "control-" + str(uuid.uuid4()), "role": role,
                                                "actorInstanceRef": refs_by_role[role],
                                                "alias": "network", "operation": operation,
                                                "preVerified": pre is True, "postVerified": post is True,
                                                "reason": "same-uid-not-tcc-proof"})
            for candidate in observer.denials:
                projection = dict(candidate, actorInstanceRef=refs_by_role[candidate["role"]])
                projection.pop("denialRef", None)
                projection["denialRef"] = "denial-" + packaging.json_hash(projection)
                evidence["denials"].append(projection)
    projected = []
    seen = set()
    for item in report["cases"]:
        require(type(item) is dict, "invalid_report_case")
        row = {key: None for key in CASE_FIELDS}
        row["runID"] = run_id
        require(safe_case_id(item.get("caseID")) and item["caseID"] not in seen, "unsafe_report_field")
        seen.add(item["caseID"])
        row["caseID"] = item["caseID"]
        require(item.get("operation") in OPERATIONS, "unsafe_report_operation")
        row["operation"] = item["operation"]
        reference = item.get("actorInstanceRef")
        contract = case_contract(item["caseID"])
        require(contract is not None and reference in references and references[reference] == contract[0], "report_actor_join_mismatch")
        row["actorInstanceRef"] = reference
        role = references[reference]
        fixture = item.get("fixtureID")
        require(fixture in ("M", "A", "C", "E", "G", "PDF", "loopback", "A/C", "network", None), "unsafe_fixture_alias")
        require((role, fixture, row["operation"]) == contract, "report_operation_join_mismatch")
        row["fixtureID"] = fixture
        for key in ("ownerPre", "ownerPost", "sameUIDControl", "posixACLControl"):
            value = item.get(key)
            require(type(value) is bool or isinstance(value, str) and value in ("pass", "failed", "blocked", "inconclusive", "unverified"), "invalid_report_control")
            # Native control assertions are candidates only; independent
            # observer data below may fill these, never its TCC state.
            row[key] = "unverified"
        for key in ("expectedRootMatched", "promptObserved"):
            value = item.get(key)
            require(type(value) is bool or key == "promptObserved" and value == "unverified", "invalid_report_control")
            row[key] = value if key == "expectedRootMatched" or value is True else "unverified"
        for key in ("syscallResult", "errno"):
            value = item.get(key)
            require(int_range(value, 0 if key == "errno" else -(2**31), 2**31 - 1), "invalid_report_syscall")
            row[key] = value
        row["sandboxDenialRef"] = None  # Ignore arbitrary native denial refs.
        require(type(item.get("syscallObserved")) is bool, "invalid_report_syscall")
        row["syscallObserved"] = item["syscallObserved"]
        require(row["syscallObserved"] or row["syscallResult"] == 0 and row["errno"] == 0, "invalid_unobserved_syscall")
        require(item.get("intervalRef") == row["caseID"], "report_interval_join_mismatch")
        require(not any(k in item for k in ("beganAtNs", "endedAtNs", "pid", "birthSec", "birthUsec")), "raw_report_metadata")
        interval = observer.intervals.get(row["caseID"]) if observer is not None else None
        bound = observer is not None and role in observer.bindings and role in observer.post_bindings
        row["intervalRef"] = "interval-" + packaging.json_hash({"caseID": row["caseID"], "actorInstanceRef": reference}) if interval else None
        if evidence is not None and interval:
            evidence["intervals"].append({"intervalRef": row["intervalRef"], "actorInstanceRef": reference,
                                          "role": role, "caseID": row["caseID"], "operation": row["operation"],
                                          "alias": fixture, "observed": row["syscallObserved"], "clockVerified": False,
                                          "reason": "clock-unproven"})
        proposed = item.get("verdict")
        require(proposed in ("pass", "failed", "blocked", "inconclusive"), "invalid_native_verdict")
        row["verdict"] = "inconclusive"
        capability = role == "PDFiumXPC" and fixture == "PDF" and row["operation"] in ("descriptorRead", "descriptorWrite")
        allowed = row["operation"] == "readWrite" or row["caseID"].startswith(("Main.pre.", "Main.post."))
        if not bound or proposed == "blocked":
            row["verdict"] = "blocked"
        elif row["syscallObserved"] and not capability and not allowed and row["expectedRootMatched"] and (proposed == "failed" or row["syscallResult"] >= 0 and row["errno"] == 0):
            row["verdict"] = "failed"
        if observer is not None and fixture in ("M", "A", "C", "E", "G", "PDF"):
            index = 1 if role == "PDFiumXPC" else 0
            control = observer.controls[index]
            file_row = control.rows.get(("PDFiumXPC" if index else "Main", fixture, "file"))
            if file_row:
                good = file_row["preVerified"] and file_row["postVerified"]
                row["sameUIDControl"] = good
                row["posixACLControl"] = good
                row["ownerPre"] = observer.owner_control.get((index, "pre"), False)
                row["ownerPost"] = observer.owner_control.get((index, "post"), False)
                if not good and row["verdict"] != "failed":
                    row["verdict"] = "blocked" if not file_row["preVerified"] else "inconclusive"
            if row["operation"] == "symlinkRead":
                link = control.rows.get((role, fixture, "symlinkRead"))
                if not link or not link["preVerified"] or not link["postVerified"]:
                    row["verdict"] = "blocked" if row["verdict"] != "failed" else "failed"
        # No case PASS without current-run manual TCC/prompt and compatible OS
        # clocks. fd read/EBADF is capability evidence, not sandbox attribution.
        if evidence is not None and capability and bound and row["syscallObserved"]:
            valid = ((row["operation"] == "descriptorRead" and row["syscallResult"] == len(synthetic_pdf()) and row["errno"] == 0)
                     or (row["operation"] == "descriptorWrite" and row["syscallResult"] == -1 and row["errno"] == errno.EBADF))
            controlled = row["expectedRootMatched"] and row["sameUIDControl"] is True and row["posixACLControl"] is True
            evidence["automated"].append(result("pdfReadOnlyCapability" + row["operation"], "pass" if controlled and valid else "failed" if controlled else "blocked",
                                                "descriptor-capability-not-sandbox-proof", executed=True))
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
    home = current_home()
    run_id = str(uuid.uuid4())
    collision_preflight(home, run_id)
    controls = Controls(run_id)
    owner = GroupOwner(evidence["requestedCPU"], run_id)
    controls_started = False
    observer = None
    try:
        owner.start()
        evidence["groupOwner"].update(executionStatus="observed", runID=run_id, ownerPre="pass")
        evidence["automated"].append(result("groupOwnerPre", "pass", "signed_owner_ready_expected_root", executed=True))
        controls_started = True
        controls.start()
        helper = compile_actor_helper(run_id)
        observer = ReadinessObserver(home, run_id, bundle, evidence["manifest"]["artifactHash"], helper,
                                     [LiveControls(fixture_paths(home, run_id)), LiveControls(fixture_paths(home, run_id))], controls, owner)
        status, _, _ = command(["/usr/bin/open", "-n", bundle, "--args", "--topology-smoke", "--run-id", run_id])
        require(status == 0, "gui_launch_failed")
        deadline = time.monotonic() + 230
        while time.monotonic() < deadline:
            observer.poll()
            if 0 in observer.directories:
                directory = observer.directories[0][0]
                try:
                    data, _ = read_at(directory, "report.json", 1024**2)
                except FileNotFoundError:
                    data = None
            else:
                data = None
            if data is not None:
                report = decode_json(data)
                evidence["cases"] = project_cases(report, run_id, observer, evidence)
                evidence["automated"].extend(project_statuses(report))
                evidence["automated"].append(result("guiLaunch", "pass", "matching_synthetic_run_report"))
                evidence["automated"].append(result("osDenialClock", "inconclusive", "clock-unproven", executed=True))
                evidence["automated"].append(result("currentRunTCCPrompt", "inconclusive", "manual-current-run-evidence-unverified", executed=True))
                return
            time.sleep(0.01)
        raise Failure("gui_report_timeout")
    finally:
        try:
            if observer is not None:
                observer.close()
        finally:
            try:
                if controls_started:
                    controls.finish()
            except (Failure, OSError, ValueError):
                evidence["automated"].append(result("externalPostControl", "blocked", "external-post-control-unproven", executed=True))
            evidence["automated"].extend([
                result("externalOwnerControl", "pass" if controls.pre and controls.post else "failed" if controls.pre else "blocked", "owner_marker_and_same_uid_read_write", executed=controls_started),
                result("loopbackControl", "pass" if controls.network_pre and controls.network_post and controls.inbound_pre and controls.inbound_post else "blocked", "pre_post_connect_and_bind_control", executed=controls_started),
            ])
            try:
                if owner.process is not None:
                    evidence["groupOwner"].update(executionStatus="observed", runID=run_id)
                post = observer.owner_post if observer is not None and observer.owner_post is not None else owner.finish()
                if post is not None:
                    evidence["groupOwner"].update(ownerPost=post["ownerPost"], absent=post["absent"])
                    evidence["automated"].append(result("groupOwnerPost", "pass" if owner.completed else "failed", "signed_owner_post_and_absence_observed", executed=True))
                else:
                    evidence["automated"].append(result("groupOwnerPost", "blocked", "group_owner_not_ready"))
            except (Failure, OSError, ValueError, subprocess.TimeoutExpired):
                evidence["automated"].append(result("groupOwnerPost", "failed" if owner.ready else "blocked", "group_owner_post_not_proven", executed=owner.process is not None))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--arch", required=True, choices=ARCHES)
    parser.add_argument("--bundle", required=True, type=Path)
    parser.add_argument("--confirm-current-profile", action="store_true", help="Consent to current-account synthetic-only arm64 probes; not proof of clean TCC/FDA grants; never changes permissions")
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
        if args.arch != "arm64":
            evidence["automated"].append(result("guiLaunch", "blocked", "intel_dynamic_waived_support_unverified"))
        elif not native:
            evidence["automated"].append(result("guiLaunch", "blocked", "native_cpu_required"))
        elif not args.confirm_current_profile:
            evidence["automated"].append(result("guiLaunch", "blocked", "explicit_current_profile_consent_required"))
        else:
            current_home()
            evidence["manual"][0] = result("currentProfile", "inconclusive", "synthetic_only_consent_not_clean_tcc_fda_proof", executed=True)
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
