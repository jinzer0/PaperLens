"""Run normal and faulted SQL cases across separate launches of the signed arm64 app."""

import argparse
from contextlib import ExitStack
import hashlib
import json
import os
from pathlib import Path
import platform
import pwd
import re
import selectors
import stat
import subprocess
import sys
import time
from uuid import uuid4

from validate_dependency_lock import COMPILE_FACTS, sqlite_source_identity
from verify_packaged_db import MAX_RECORD_BYTES, Invalid, bounded_json, exact


IDENTIFIER = "io.github.jinzer0.PaperLens"
REQUIREMENT = (
    f'anchor apple generic and identifier "{IDENTIFIER}"'
    ' and certificate leaf[subject.OU] = "397452Z366"'
    ' and certificate 1[field.1.2.840.113635.100.6.2.6] exists'
    ' and certificate leaf[field.1.2.840.113635.100.6.1.13] exists'
)
DIRECTORY_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
FAILURE_CODES = {"primary": 19, "extended": 1555}
NORMAL_CHECKS = {
    "first": ("initial", "base", "migrations", "fts", "deletion"),
    "reopen": ("initial", "reopen"),
}
PROVENANCE_FLAGS = ("sameConnection", "symbolsBoundToImage", "sharedCacheImage", "metadataMatches")


def directory(path, lifetime, parent=None):
    descriptor = os.open(path, DIRECTORY_FLAGS, dir_fd=parent)
    lifetime.callback(os.close, descriptor)
    return descriptor


def reserve_directory(name, parent, lifetime):
    os.mkdir(name, 0o700, dir_fd=parent)
    return directory(name, lifetime, parent)


def remove_case_directories(parent, owner_id, root, build, topology):
    directories = (
        (parent, owner_id, root, [".build"]),
        (root, ".build", build, ["topology"]),
        (build, "topology", topology, []),
    )
    # The child removes the database namespace. Verify the entire retained
    # hierarchy before removing any of the parent's empty wrapper directories.
    for container, name, descriptor, entries in directories:
        named = os.stat(name, dir_fd=container, follow_symlinks=False)
        if (not stat.S_ISDIR(named.st_mode) or stat.S_IMODE(named.st_mode) != 0o700
                or named.st_uid != os.getuid() or not os.path.samestat(named, os.fstat(descriptor))
                or os.listdir(descriptor) != entries):
            raise ValueError("fixture_replaced")
    for container, name, _, _ in reversed(directories):
        os.rmdir(name, dir_fd=container)


def validate_provenance(observed, os_build):
    identity_fields = {"osBuild", "imageIdentity", "sqliteVersion", "sqliteSourceId"}
    required = {"compileOptions", "inspectedEntries", "maxEntryBytes"}.union(PROVENANCE_FLAGS)
    if (type(observed) is not dict
            or not required <= observed.keys() <= required | identity_fields):
        raise ValueError("invalid_provenance_receipt")
    options = observed["compileOptions"]
    if (any(type(observed[flag]) is not bool for flag in PROVENANCE_FLAGS)
            or ("osBuild" in observed and observed["osBuild"] != os_build)
            or ("imageIdentity" in observed and (type(observed["imageIdentity"]) is not str
                or not re.fullmatch(r"[0-9a-f]{64}", observed["imageIdentity"])
                or len(set(observed["imageIdentity"])) < 2))
            or ("sqliteVersion" in observed and (type(observed["sqliteVersion"]) is not str
                or not re.fullmatch(r"[0-9]{1,3}(\.[0-9]{1,3}){2}", observed["sqliteVersion"])))
            or ("sqliteSourceId" in observed and not sqlite_source_identity(observed["sqliteSourceId"]))
            or type(options) is not list or len(options) > 16
            or not all(type(option) is str and option in COMPILE_FACTS for option in options)
            or len(set(options)) != len(options)
            or type(observed["inspectedEntries"]) is not int
            or not len(options) <= observed["inspectedEntries"] <= 256
            or type(observed["maxEntryBytes"]) is not int
            or not max(map(len, options), default=0) <= observed["maxEntryBytes"] <= 256):
        raise ValueError("invalid_provenance_receipt")
    return (identity_fields <= observed.keys() and "ENABLE_FTS5" in options
            and all(observed[flag] for flag in PROVENANCE_FLAGS))


def collect_receipt(child, timeout):
    deadline = time.monotonic() + timeout
    receipt = bytearray()
    descriptor = child.stdout.fileno()
    try:
        with selectors.DefaultSelector() as reader:
            reader.register(descriptor, selectors.EVENT_READ)
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0 or not reader.select(remaining):
                    raise subprocess.TimeoutExpired(child.args, timeout)
                # Read one byte beyond the limit to distinguish an exact-size receipt from overflow.
                chunk = os.read(descriptor, MAX_RECORD_BYTES + 1 - len(receipt))
                if not chunk:
                    break
                receipt.extend(chunk)
                if len(receipt) > MAX_RECORD_BYTES:
                    raise ValueError("phase_failed")
        if child.wait(timeout=max(0, deadline - time.monotonic())) != 0 or not receipt:
            raise ValueError("phase_failed")
        return bytes(receipt)
    finally:
        if child.poll() is None:
            child.kill()
            child.wait()


def launch(executable, phase, kind, ids, descriptors, identity):
    arguments = [executable, "--synthetic-packaged-db-relaunch", phase, kind, *ids,
                 *(str(value) for value in (*descriptors, *identity))]
    with subprocess.Popen(arguments, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                          stderr=subprocess.DEVNULL, pass_fds=descriptors) as child:
        receipt = collect_receipt(child, timeout=30)
    record = bounded_json(receipt)
    expected = {"phase": phase, "kind": kind, "closed": True, "cleaned": phase == "reopen"}
    steps = ("reopenedIntegrity",) if phase == "reopen" else ()
    if kind == "normal":
        steps += NORMAL_CHECKS[phase]
    else:
        expected.update(rollbackVersion=0 if kind == "m1" else 1, failure=FAILURE_CODES)
    if steps:
        expected["checks"] = [{"phase": step, "passed": True} for step in steps]
    if (type(record) is not dict or "provenance" not in record
            or not exact({k: v for k, v in record.items() if k != "provenance"}, expected)):
        raise ValueError("phase_receipt_invalid")
    return child.pid, record


def run_case(executable, parent, kind):
    owner_id, case_id = str(uuid4()), str(uuid4())
    entry = f"local-grdb-probe-{case_id}"
    with ExitStack() as lifetime:
        root = reserve_directory(owner_id, parent, lifetime)
        build = reserve_directory(".build", root, lifetime)
        topology = reserve_directory("topology", build, lifetime)
        namespace = reserve_directory(entry, topology, lifetime)
        descriptors = (root, topology, namespace)
        file_descriptor = os.open("db.sqlite", os.O_WRONLY | os.O_CREAT | os.O_EXCL
                                  | os.O_NOFOLLOW, 0o600, dir_fd=namespace)
        try:
            reserved = os.fstat(file_descriptor)
        finally:
            os.close(file_descriptor)
        identity = reserved.st_dev, reserved.st_ino
        first_pid, first = launch(executable, "first", kind,
                                  (owner_id, case_id, str(uuid4())), descriptors, identity)
        committed = os.stat("db.sqlite", dir_fd=namespace, follow_symlinks=False)
        if ((committed.st_dev, committed.st_ino) != identity or not stat.S_ISREG(committed.st_mode)
                or committed.st_size <= 0 or os.listdir(namespace) != ["db.sqlite"]):
            raise ValueError("fixture_replaced")
        second_pid, second = launch(executable, "reopen", kind,
                                    (owner_id, case_id, str(uuid4())), descriptors, identity)
        if (first_pid == second_pid or os.listdir(topology)
                or not exact(first["provenance"], second["provenance"])):
            raise ValueError("relaunch_unconfirmed")
        remove_case_directories(parent, owner_id, root, build, topology)
        result = {"kind": kind, "firstClosedAndExited": True, "sameDatabaseReopened": True,
                  "secondClosedAndCleaned": True, "provenance": second["provenance"],
                  "reopenChecks": second["checks"]}
        if kind == "normal":
            result["firstChecks"] = first["checks"]
        else:
            result.update(rollbackVersion=second["rollbackVersion"], failure=second["failure"])
        return result


def executable_sha256(executable):
    digest = hashlib.sha256()
    with executable.open("rb") as binary:
        for chunk in iter(lambda: binary.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def verify_bundle(app):
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", "-R",
                    "=" + REQUIREMENT, app], check=True, timeout=30, stderr=subprocess.DEVNULL)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    args = parser.parse_args()
    try:
        app = args.app.resolve(strict=True)
        executable = app / "Contents/MacOS/PaperLens"
        if platform.machine() != "arm64" or os.getuid() != os.geteuid():
            raise ValueError("arm64_host_required")
        if subprocess.check_output(["/usr/bin/lipo", "-archs", executable], timeout=30,
                                   stderr=subprocess.DEVNULL).strip() != b"arm64":
            raise ValueError("arm64_bundle_required")
        verify_bundle(app)
        executable_digest = executable_sha256(executable)
        os_version = subprocess.check_output(["/usr/bin/sw_vers", "-productVersion"],
                                             timeout=5).decode("ascii").strip()
        os_build = subprocess.check_output(["/usr/bin/sw_vers", "-buildVersion"],
                                           timeout=5).decode("ascii").strip()
        home = Path(pwd.getpwuid(os.getuid()).pw_dir)
        components = ("Library", "Containers", IDENTIFIER, "Data", "Library",
                      "Application Support", "PaperLensSyntheticPackagedDB")
        with ExitStack() as lifetime:
            parent = directory(home, lifetime)
            for component in components:
                parent = directory(component, lifetime, parent)
            info = os.fstat(parent)
            if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
                raise ValueError("fixture_parent_invalid")
            normal, *faults = [run_case(executable, parent, kind) for kind in ("normal", "m1", "m2")]
        verify_bundle(app)
        if (executable_sha256(executable) != executable_digest
                or any(not exact(fault["provenance"], normal["provenance"]) for fault in faults)):
            raise ValueError("runtime_binding_changed")
        verified_sqlite = validate_provenance(normal["provenance"], os_build)
    except (Invalid, OSError, ValueError, subprocess.SubprocessError):
        print("synthetic_db_relaunch_unconfirmed", file=sys.stderr)
        return 1
    print(json.dumps({"schema": "paperlens-synthetic-db-relaunch-v3", "storyDone": False,
                      "p2Passed": False, "normal": normal, "faults": faults,
                      "sqliteOrigin": "apple-system" if verified_sqlite else "sqlite_origin_unverified",
                      "runtime": {"osVersion": os_version, "osBuild": os_build,
                                  "architecture": "arm64",
                                  "signedExecutableSHA256": executable_digest}}, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
