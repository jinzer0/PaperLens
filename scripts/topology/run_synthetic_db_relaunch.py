"""Run the signed arm64 app twice per migration fault on independently reserved fixtures."""

import argparse
from contextlib import ExitStack
import json
import os
from pathlib import Path
import platform
import pwd
import stat
import subprocess
import sys
from uuid import uuid4


IDENTIFIER = "io.github.jinzer0.PaperLens"
REQUIREMENT = (
    f'anchor apple generic and identifier "{IDENTIFIER}"'
    ' and certificate leaf[subject.OU] = "397452Z366"'
    ' and certificate 1[field.1.2.840.113635.100.6.2.6] exists'
    ' and certificate leaf[field.1.2.840.113635.100.6.1.13] exists'
)
DIRECTORY_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
FAILURE_CODES = {"primary": 19, "extended": 1555}


def directory(path, lifetime, parent=None):
    descriptor = os.open(path, DIRECTORY_FLAGS, dir_fd=parent)
    lifetime.callback(os.close, descriptor)
    return descriptor


def reserve_directory(name, parent, lifetime):
    os.mkdir(name, 0o700, dir_fd=parent)
    return directory(name, lifetime, parent)


def launch(executable, phase, kind, ids, descriptors, identity):
    arguments = [executable, "--synthetic-packaged-db-relaunch", phase, kind, *ids,
                 *(str(value) for value in (*descriptors, *identity))]
    with subprocess.Popen(arguments, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                          stderr=subprocess.DEVNULL, pass_fds=descriptors) as child:
        try:
            receipt, _ = child.communicate(timeout=30)
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait()
            raise
        if child.returncode or not 0 < len(receipt) <= 16384:
            raise ValueError("phase_failed")
    record = json.loads(receipt)
    expected = {"phase": phase, "kind": kind, "rollbackVersion": 0 if kind == "m1" else 1,
                "failure": FAILURE_CODES, "closed": True, "cleaned": phase == "reopen"}
    if not isinstance(record, dict) or set(record) != set(expected) | {"provenance"}:
        raise ValueError("phase_receipt_invalid")
    if any(type(record[key]) is not type(value) or record[key] != value
           for key, value in expected.items()):
        raise ValueError("phase_receipt_invalid")
    if not isinstance(record["provenance"], dict):
        raise ValueError("phase_receipt_invalid")
    return child.pid, record


def run_fault(executable, parent, kind):
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
        if first_pid == second_pid or os.listdir(topology) or first["provenance"] != second["provenance"]:
            raise ValueError("relaunch_unconfirmed")
        return {"kind": kind, "firstClosedAndExited": True, "sameDatabaseReopened": True,
                "rollbackVersion": second["rollbackVersion"], "failure": second["failure"],
                "secondClosedAndCleaned": True, "provenance": second["provenance"]}


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
        subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", "-R",
                        "=" + REQUIREMENT, app], check=True, timeout=30, stderr=subprocess.DEVNULL)
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
            results = [run_fault(executable, parent, kind) for kind in ("m1", "m2")]
    except (OSError, ValueError, subprocess.SubprocessError):
        print("synthetic_db_relaunch_unconfirmed", file=sys.stderr)
        return 1
    print(json.dumps({"schema": "paperlens-synthetic-db-relaunch-v1", "storyDone": False,
                      "p2Passed": False, "faults": results}, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
