#!/usr/bin/env python3
"""Invocation-local EOF diagnostics; observations are not causal or coverage proof."""
from __future__ import annotations

import argparse
import contextlib
import hashlib
import io
import json
import os
from pathlib import Path
import re
import stat
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import verify

SLOTS = ("start-before", "start-after", "mainpost-after", "report-tail",
         "last-before-target", "first-at-target", "before-stop", "after-cleanup")
ENUMS = {"processState": {"not-started", "running", "exit-zero", "exit-nonzero", "unknown"},
         "stdoutState": {"registered", "eof-observed", "unknown"},
         "stderrState": {"registered", "eof-observed", "unknown"},
         "targetRelation": {"before", "at-or-after", "unknown"},
         "observerRelation": {"before", "at-or-after", "unknown"}}
FLAGS = ("pendingFrame", "sourceFailure", "frozen", "reaped", "stopRequested")
PRIOR_RUNS = ("fe79146b-4f05-423e-8c9e-4482be6249f3", "ec1f04d7-b183-4c52-9084-536589d354d6",
              "18542572-8c31-4275-9bfe-6dba4ddecfa1", "3d0e3c1f-f160-46b0-bb53-f3fe58a655a5",
              "8cc02d20-70ca-49f6-b3fd-fc418997855d", "f82829ae-4854-45c5-8516-e40ad665b1ee",
              "3eeec5dd-b9b8-4de7-84ec-4184c7875832", "ab343779-f5f5-488c-b410-7de3a50aeaef")


def unknown():
    return {"observed": False, **{key: "unknown" for key in ENUMS},
            **{key: None for key in FLAGS}}


def validate_receipt(value):
    verify.require(type(value) is dict and set(value) == {"runID", "artifactHash", "cliTimeout", "milestones"}, "diagnostic_invalid")
    if value["runID"] is not None:
        verify.uuid4(value["runID"])
    verify.require(value["artifactHash"] is None or type(value["artifactHash"]) is str and re.fullmatch(r"[0-9a-f]{64}", value["artifactHash"]), "diagnostic_invalid")
    verify.require(value["cliTimeout"] is None or type(value["cliTimeout"]) is int and value["cliTimeout"] > 0, "diagnostic_invalid")
    rows = value["milestones"]
    verify.require(type(rows) is dict and set(rows) == set(SLOTS), "diagnostic_invalid")
    for row in rows.values():
        verify.require(type(row) is dict and set(row) == {"observed", *ENUMS, *FLAGS}, "diagnostic_invalid")
        verify.require(type(row["observed"]) is bool, "diagnostic_invalid")
        verify.require(all(type(row[key]) is str and row[key] in allowed for key, allowed in ENUMS.items()), "diagnostic_invalid")
        verify.require(all(row[key] is None or type(row[key]) is bool for key in FLAGS), "diagnostic_invalid")
        verify.require(row["observed"] or row == unknown(), "diagnostic_invalid")
    return value


@contextlib.contextmanager
def replace(target, name, value):
    original = getattr(target, name)
    own = name in vars(target)
    setattr(target, name, value)
    try:
        yield original
    finally:
        if own:
            setattr(target, name, original)
        else:
            delattr(target, name)


class Hooks:
    """Eight bounded safe snapshots; handles and EOF event identity stay in RAM."""
    def __init__(self):
        self.receipt = {"runID": None, "artifactHash": None, "cliTimeout": None,
                        "milestones": {name: unknown() for name in SLOTS}}
        self.collector = None
        self.observer = None
        self.stopped = False
        self.eof = set()
        self.zero = set()
        self.draining = False
        self.starting = False
        self.in_tail = False
        self.tail_validated = False
        self.stack = contextlib.ExitStack()

    def sample(self, name=None):
        collector = self.collector
        if collector is None:
            return
        row = unknown()
        row["observed"] = True
        now = verify.time.monotonic()
        for key, attribute in (("targetRelation", "deadline"), ("observerRelation", "observer_deadline")):
            deadline = getattr(collector, attribute, None)
            if type(deadline) in (int, float):
                row[key] = "before" if now < deadline else "at-or-after"
        process = collector.process
        if process is None:
            row["processState"] = "not-started"
        else:
            try:
                status = process.poll()  # Only this owned handle; no wait.
                row["processState"] = "running" if status is None else "exit-zero" if status == 0 else "exit-nonzero"
            except OSError:
                pass
            try:
                registered = collector.selector.get_map()
                for key, pipe in (("stdoutState", process.stdout), ("stderrState", process.stderr)):
                    if key in self.eof:
                        row[key] = "eof-observed"
                    elif registered is not None and any(entry.fileobj is pipe for entry in registered.values()):
                        row[key] = "registered"
            except (OSError, ValueError):
                pass
        row.update(pendingFrame=bool(collector.pending), sourceFailure=collector.failure is not None,
                   frozen=collector.closed, reaped=collector.reaped, stopRequested=self.stopped)
        rows = self.receipt["milestones"]
        if name is not None and not rows[name]["observed"]:
            rows[name] = dict(row)
        if row["targetRelation"] == "before":
            rows["last-before-target"] = dict(row)
        elif row["targetRelation"] == "at-or-after" and not rows["first-at-target"]["observed"]:
            rows["first-at-target"] = dict(row)

    def bind_collector(self, collector):
        self.collector = collector
        unregister = collector.selector.unregister
        def unregistered(fileobj):
            fd = fileobj.fileno()
            result = unregister(fileobj)
            if self.draining and fd in self.zero and collector.process is not None:
                for key, pipe in (("stdoutState", collector.process.stdout), ("stderrState", collector.process.stderr)):
                    if fileobj is pipe:
                        self.eof.add(key)
                self.zero.discard(fd)
            return result
        self.stack.enter_context(replace(collector.selector, "unregister", unregistered))

    def bind_process(self, process, argv):
        # Project only the exact positive integer supplied to the owned Popen.
        if type(argv) in (list, tuple) and list(argv[:2]) == ["/usr/bin/log", "stream"]:
            try:
                text = argv[argv.index("--timeout") + 1]
                if type(text) is str and re.fullmatch(r"[1-9][0-9]*", text):
                    self.receipt["cliTimeout"] = int(text)
            except (ValueError, IndexError):
                pass
        for name in ("terminate", "kill"):
            original = getattr(process, name)
            def stop(*args, _original=original, **kwargs):
                self.sample("before-stop")
                self.stopped = True
                return _original(*args, **kwargs)
            self.stack.enter_context(replace(process, name, stop))

    def __enter__(self):
        hooks = self
        init = verify.OSCollector.__init__
        def collector_init(collector, *args, **kwargs):
            result = init(collector, *args, **kwargs)
            hooks.bind_collector(collector)
            return result
        self.stack.enter_context(replace(verify.OSCollector, "__init__", collector_init))
        observer_init = verify.ReadinessObserver.__init__
        def observer_created(observer, *args, **kwargs):
            result = observer_init(observer, *args, **kwargs)
            hooks.observer = observer
            hooks.receipt.update(runID=observer.run_id, artifactHash=observer.artifact_hash)
            return result
        self.stack.enter_context(replace(verify.ReadinessObserver, "__init__", observer_created))
        popen = verify.subprocess.Popen
        def opened(argv, *args, **kwargs):
            process = popen(argv, *args, **kwargs)
            if hooks.starting:
                hooks.bind_process(process, argv)
            return process
        self.stack.enter_context(replace(verify.subprocess, "Popen", opened))
        read = verify.os.read
        def read_original(fd, size):
            data = read(fd, size)
            if hooks.draining and data == b"":
                hooks.zero.add(fd)
            return data
        self.stack.enter_context(replace(verify.os, "read", read_original))
        require = verify.require
        def checked(condition, reason):
            result = require(condition, reason)
            if hooks.in_tail and reason == "report_lifecycle_incomplete":
                hooks.tail_validated = True
            return result
        self.stack.enter_context(replace(verify, "require", checked))
        for name in ("start", "drain", "finish", "reap"):
            original = getattr(verify.OSCollector, name)
            def call(collector, *args, _name=name, _original=original, **kwargs):
                hooks.sample("start-before" if _name == "start" else "report-tail" if hooks.in_tail and hooks.tail_validated and _name in ("drain", "finish") else None)
                old_starting, old_draining = hooks.starting, hooks.draining
                hooks.starting = _name == "start" or old_starting
                hooks.draining = _name == "drain" or old_draining
                try:
                    result = _original(collector, *args, **kwargs)
                finally:
                    hooks.starting, hooks.draining = old_starting, old_draining
                    if _name == "drain":
                        hooks.zero.clear()
                hooks.sample("start-after" if _name == "start" else None)
                return result
            self.stack.enter_context(replace(verify.OSCollector, name, call))
        poll = verify.ReadinessObserver.poll
        def polled(observer, *args, **kwargs):
            before = (0, "post") in observer.done
            hooks.sample()
            result = poll(observer, *args, **kwargs)
            hooks.sample("mainpost-after" if not before and (0, "post") in observer.done else None)
            return result
        self.stack.enter_context(replace(verify.ReadinessObserver, "poll", polled))
        tail = verify.ReadinessObserver.tail
        def tailed(observer, *args, **kwargs):
            hooks.in_tail, hooks.tail_validated = True, False
            try:
                return tail(observer, *args, **kwargs)
            finally:
                hooks.in_tail, hooks.tail_validated = False, False
        self.stack.enter_context(replace(verify.ReadinessObserver, "tail", tailed))
        gui = verify.gui_run
        def gui_finished(*args, **kwargs):
            try:
                return gui(*args, **kwargs)
            finally:
                hooks.sample("after-cleanup")
        self.stack.enter_context(replace(verify, "gui_run", gui_finished))
        return self

    def __exit__(self, *exception):
        return self.stack.__exit__(*exception)


class Capture(io.StringIO):
    """Bounded raw verifier stdout/stderr, never forwarded or written."""
    maximum = 4 * 1024**2
    def write(self, text):
        verify.require(self.tell() + len(text) <= self.maximum, "diagnostic_capture_limit")
        return super().write(text)


def report_snapshot():
    home = verify.current_home()
    root = home / "Library/Containers" / verify.IDENTITY / "Data/Library/Application Support/PaperLensTopology"
    directory = verify.directory_fd(root, private=False)
    snapshots = {}
    def snapshot_file(parent):
        descriptor = os.open("report.json", os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC, dir_fd=parent)
        try:
            info = os.fstat(descriptor)
            verify.require(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid()
                           and info.st_nlink == 1 and info.st_size <= 1024**2, "diagnostic_report_unsafe")
            data = bytearray()
            while len(data) <= 1024**2:
                chunk = os.read(descriptor, min(8192, 1024**2 + 1 - len(data)))
                if not chunk:
                    break
                data.extend(chunk)
            verify.require(len(data) <= 1024**2 and verify.file_identity(os.stat("report.json", dir_fd=parent, follow_symlinks=False)) == verify.file_identity(info), "diagnostic_report_unsafe")
            return info.st_dev, info.st_ino, stat.S_IMODE(info.st_mode), bytes(data)
        finally:
            os.close(descriptor)
    try:
        snapshots[(None, "report.json")] = snapshot_file(directory)
        reports = os.open("Reports", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=directory)
        try:
            for name in PRIOR_RUNS:
                child = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=reports)
                try:
                    snapshots[(name, "report.json")] = snapshot_file(child)
                finally:
                    os.close(child)
        finally:
            os.close(reports)
    finally:
        os.close(directory)
    return snapshots


def project_output(raw, receipt):
    validate_receipt(receipt)
    value = verify.decode_json(raw)
    verify.require(type(value) is dict and value.get("schemaRevision") == "topology-evidence-v2", "diagnostic_evidence_invalid")
    verify.require(value["manifest"]["artifactHash"] == receipt["artifactHash"]
                   and value["groupOwner"]["runID"] == receipt["runID"], "diagnostic_join_invalid")
    state = value["osCollection"]
    statuses = {"unavailable", "timed-out", "invalid", "truncated", "complete-empty", "complete-nonempty"}
    reasons = {"collector-not-started", "coverage-unproven", "collector-insufficient-budget", "collector-access-denied", "collector-start-failed", "collector-binding-invalid", "collector-timeout", "raw-limit", "record-limit", "candidate-limit", "collector-access-or-source-error", "collector-header-invalid", "parser-input-invalid", "collector-early-eof", "collector-read-failed", "collector-stop-before-eof", "collector-reap-timeout", "collector-nonzero-exit", "parser-partial-eof", "normal-eof-clock-unproven", "normal-eof-empty-coverage-unproven"}
    verify.require(type(state) is dict and set(state) == {"status", "queryCompleted", "scopeVerified", "truncated", "reason"}
                   and state["status"] in statuses and state["reason"] in reasons
                   and all(type(state[key]) is bool for key in ("queryCompleted", "scopeVerified", "truncated"))
                   and state["scopeVerified"] is False, "diagnostic_evidence_invalid")
    verify.require(value["verdict"] in {"blocked", "failed", "inconclusive"} and value["storyDone"] is False and value["p1"] == "unverified", "diagnostic_evidence_invalid")
    return {"eofDiagnostic": receipt, "verifier": {"osCollection": dict(state), "verdict": value["verdict"], "storyDone": False, "p1": "unverified"}}


def run(argv, manual_observer=None):
    """One original invocation. Returns (original status, safe receipt, summary).

    Original exceptions propagate to API callers after hook restoration. CLI
    contains exceptions; raw captured verifier output is never returned.
    """
    verify.require(type(argv) in (list, tuple) and len(argv) == 5
                   and list(argv[:3]) == ["--arch", "arm64", "--bundle"]
                   and type(argv[3]) is str and argv[4] == "--confirm-current-profile", "diagnostic_invocation_invalid")
    before = report_snapshot()
    verify.require(len(before) == 9, "diagnostic_prior_reports_missing")
    output, errors = Capture(), Capture()
    def check_preservation():
        after = report_snapshot()
        verify.require(all(after.get(key) == row for key, row in before.items()), "diagnostic_prior_report_changed")
    try:
        with Hooks() as hooks, contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
            status = verify.main(argv, manual_observer=manual_observer)
    except BaseException as original:
        try:
            check_preservation()
        except BaseException:
            original.add_note("EOF diagnostic report preservation check also failed; raw details withheld.")
        raise
    check_preservation()
    receipt = validate_receipt(hooks.receipt)
    summary = project_output(output.getvalue(), receipt)
    digest = hashlib.sha256()
    for key, row in sorted(before.items(), key=lambda item: str(item[0])):
        digest.update(hashlib.sha256(row[3]).digest())
    summary.update(priorReportsPreserved=True, priorReportsHash=digest.hexdigest())
    return status, receipt, summary


def save(receipt, summary):
    """Fixed arm64 paths, exclusive creation, no arbitrary report/home intake."""
    validate_receipt(receipt)
    verify.require(receipt["runID"] is not None and summary.get("eofDiagnostic") == receipt, "diagnostic_join_invalid")
    # Serialize only independently revalidated safe projections, never caller extras.
    verify.require(set(summary) == {"eofDiagnostic", "verifier", "priorReportsPreserved", "priorReportsHash"}, "diagnostic_evidence_invalid")
    verifier = summary["verifier"]
    verify.require(type(verifier) is dict and set(verifier) == {"osCollection", "verdict", "storyDone", "p1"}, "diagnostic_evidence_invalid")
    project_output(json.dumps({"schemaRevision": "topology-evidence-v2", "manifest": {"artifactHash": receipt["artifactHash"]}, "groupOwner": {"runID": receipt["runID"]}, **verifier}), receipt)
    verify.require(summary["priorReportsPreserved"] is True and type(summary["priorReportsHash"]) is str and re.fullmatch(r"[0-9a-f]{64}", summary["priorReportsHash"]), "diagnostic_evidence_invalid")
    root = verify.ROOT / ".build/topology/arm64"
    directory = verify.directory_fd(root, private=False)
    descriptors = []
    try:
        names = [prefix + receipt["runID"] + ".json" for prefix in ("eof-diagnostic-", "eof-evidence-")]
        for name in names:
            try:
                os.stat(name, dir_fd=directory, follow_symlinks=False)
            except FileNotFoundError:
                continue
            raise FileExistsError("diagnostic_output_collision")
        for name in names:
            descriptors.append(os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600, dir_fd=directory))
        for descriptor, value in zip(descriptors, (receipt, summary)):
            data = (json.dumps(value, sort_keys=True, indent=2) + "\n").encode()
            offset = 0
            while offset < len(data):
                count = os.write(descriptor, data[offset:])
                verify.require(count > 0, "diagnostic_write_failed")
                offset += count
    finally:
        for descriptor in descriptors:
            os.close(descriptor)
        os.close(directory)


def main(argv=None):
    # Parsing is also captured so invalid user arguments cannot echo raw paths.
    try:
        with contextlib.redirect_stdout(Capture()), contextlib.redirect_stderr(Capture()):
            parser = argparse.ArgumentParser(description=__doc__)
            parser.add_argument("--arch", required=True, choices=("arm64",))
            parser.add_argument("--bundle", required=True, type=Path)
            parser.add_argument("--confirm-current-profile", required=True, action="store_true")
            args = parser.parse_args(argv)
            status, receipt, summary = run(["--arch", args.arch, "--bundle", str(args.bundle), "--confirm-current-profile"])
            save(receipt, summary)
        return status
    except (Exception, SystemExit):
        print("EOF diagnostic failed; no raw output emitted.", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
