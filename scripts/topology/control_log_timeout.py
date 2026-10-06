#!/usr/bin/env python3
"""Fixed two-case public log timeout control; raw observations stay in RAM."""
from __future__ import annotations

import contextlib
import io
import json
import os
from pathlib import Path
import platform
import re
import selectors
import subprocess
import sys
import time
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parent))
import verify

PREDICATE = "processIdentifier == 0 AND processIdentifier == 1"
CASES = (("integer-two", "2", 12), ("minute-one", "1m", 75))
FLAGS = ("stdoutEOF", "stderrEOF", "framingComplete", "stopRequested", "reaped")
STATUSES = {"not-run", "normal-exit", "forced-timeout", "start-failed", "source-error",
            "invalid-output", "output-limit", "reap-timeout"}
STATES = {"not-observed", "running", "exit-zero", "exit-nonzero", "unknown"}
BANDS = {"under-5s", "5-to-under-12s", "12-to-under-75s", "75s-or-more", "unknown"}
INPUT_REASONS = {"not-observed", "none", "header-envelope-invalid", "header-grammar-invalid",
                 "header-shape-mismatch", "duplicate-header", "unexpected-record", "partial-eof",
                 "partial-target", "parser-exception"}
MAXIMUM = 1024**2
RECORD_MAXIMUM = 16384


def elapsed_band(duration):
    if duration is None or duration < 0:
        return "unknown"
    if duration < 5:
        return "under-5s"
    if duration < 12:
        return "5-to-under-12s"
    if duration < 75:
        return "12-to-under-75s"
    return "75s-or-more"


def not_run(argument):
    return {"timeoutArgument": argument, "status": "not-run", "processAtTarget": "not-observed",
            **{key: None for key in FLAGS}, "elapsedBand": "unknown", "inputReason": "not-observed"}


def validate_receipt(value):
    verify.require(type(value) is dict and set(value) == {
        "controlID", "sourceCommit", "OSBuild", "budgetWithinLimit", "cases"}, "control_receipt_invalid")
    verify.require(type(value["controlID"]) is str, "control_receipt_invalid")
    verify.uuid4(value["controlID"])
    verify.require(type(value["sourceCommit"]) is str and re.fullmatch(r"[0-9a-f]{40}", value["sourceCommit"])
                   and type(value["OSBuild"]) is str and re.fullmatch(r"[0-9A-Za-z.]{1,32}", value["OSBuild"])
                   and type(value["budgetWithinLimit"]) is bool, "control_receipt_invalid")
    rows = value["cases"]
    verify.require(type(rows) is dict and set(rows) == {case[0] for case in CASES}, "control_receipt_invalid")
    for name, argument, _ in CASES:
        row = rows[name]
        verify.require(type(row) is dict and set(row) == set(not_run(argument)), "control_receipt_invalid")
        verify.require(row["timeoutArgument"] == argument and type(row["timeoutArgument"]) is str
                       and type(row["status"]) is str and row["status"] in STATUSES
                       and type(row["processAtTarget"]) is str and row["processAtTarget"] in STATES
                       and type(row["elapsedBand"]) is str and row["elapsedBand"] in BANDS
                       and type(row["inputReason"]) is str and row["inputReason"] in INPUT_REASONS
                       and all(row[key] is None or type(row[key]) is bool for key in FLAGS), "control_receipt_invalid")
        verify.require((row["inputReason"] == "none") == (row["status"] == "normal-exit")
                       and (row["status"] not in {"not-run", "start-failed"}
                            or row["inputReason"] == "not-observed")
                       and (row["status"] != "invalid-output"
                            or row["inputReason"] not in {"not-observed", "none"}), "control_receipt_invalid")
        if row["status"] == "not-run":
            verify.require(row == not_run(argument), "control_receipt_invalid")
        if row["status"] == "normal-exit":
            verify.require(all(row[key] is True for key in ("stdoutEOF", "stderrEOF", "framingComplete", "reaped"))
                           and row["stopRequested"] is False and row["processAtTarget"] == "not-observed"
                           and row["elapsedBand"] != "unknown", "control_receipt_invalid")
            verify.require(row["elapsedBand"] in ({"under-5s", "5-to-under-12s"} if argument == "2" else
                           {"under-5s", "5-to-under-12s", "12-to-under-75s"}), "control_receipt_invalid")
    first = rows["integer-two"]
    verify.require(rows["minute-one"]["status"] == "not-run" or first["status"] == "normal-exit"
                   or first["status"] == "forced-timeout" and first["reaped"] is True, "control_receipt_invalid")
    return value


def _query(argv, deadline):
    remaining = deadline - time.monotonic()
    verify.require(remaining > 0, "control_preflight_failed")
    completed = subprocess.run(argv, cwd=verify.ROOT, env=verify.clean_env(), stdin=subprocess.DEVNULL,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               timeout=min(2, remaining), check=False)
    verify.require(completed.returncode == 0 and not completed.stderr and len(completed.stdout) <= 256,
                   "control_preflight_failed")
    return completed.stdout.decode("ascii", errors="strict").strip()


def _preflight(deadline):
    runtime = verify.ROOT / ".build/topology/arm64/runtime.pre-bounded-roll/python/bin/python3.13"
    verify.require(sys.version_info[:3] == (3, 13, 16) and Path(sys.executable).resolve(strict=True) == runtime.resolve(strict=True)
                   and sys.platform == "darwin" and platform.machine() == "arm64", "control_runtime_invalid")
    verify.require(_query(["/usr/sbin/sysctl", "-in", "sysctl.proc_translated"], deadline) == "0", "control_native_invalid")
    source = _query(["/usr/bin/git", "rev-parse", "HEAD"], deadline)
    build = _query(["/usr/bin/sw_vers", "-buildVersion"], deadline)
    verify.require(re.fullmatch(r"[0-9a-f]{40}", source) and re.fullmatch(r"[0-9A-Za-z.]{1,32}", build), "control_preflight_failed")
    return source, build


def _state(process):
    status = process.poll()
    return "running" if status is None else "exit-zero" if status == 0 else "exit-nonzero"


def _stop(process, row, start, deadline):
    """No IO after stop; closing a pipe must never manufacture EOF."""
    try:
        if process.poll() is not None:
            row["reaped"] = True
            return
    except Exception:
        pass
    stop = time.monotonic()
    end = min(stop + 0.3, deadline)
    wait_remaining = 0.3
    row["reaped"] = False
    try:
        if stop >= end:
            row["status"] = "reap-timeout"
            return
        row["elapsedBand"] = elapsed_band(stop - start)
        row["stopRequested"] = True
        process.terminate()
        remaining = end - time.monotonic()
        if remaining > 0:
            try:
                timeout = min(0.1, remaining, wait_remaining)
                wait_remaining -= timeout
                process.wait(timeout=timeout)
                row["reaped"] = time.monotonic() <= end
                if row["reaped"]:
                    return
            except subprocess.TimeoutExpired:
                pass
    except Exception:
        pass
    try:
        if time.monotonic() < end:
            process.kill()
            remaining = min(end - time.monotonic(), wait_remaining)
            if remaining > 0:
                process.wait(timeout=remaining)
                row["reaped"] = time.monotonic() <= end
    except Exception:
        pass
    if not row["reaped"]:
        row["status"] = "reap-timeout"


def _record_reason(record, banner, expected):
    """Classify only the existing owned header envelope and bounded grammar."""
    prefix = b'Filtering the log data using "'
    if not record.startswith(prefix):
        return "unexpected-record"
    if banner:
        return "duplicate-header"
    if not record.endswith(b'"'):
        return "header-envelope-invalid"
    try:
        reported = record[len(prefix):-1].decode("utf-8", errors="strict")
    except UnicodeError:
        return "header-envelope-invalid"
    try:
        shape = verify.predicate_shape(reported)
    except verify.Failure:
        return "header-grammar-invalid"
    if shape != expected:
        return "header-shape-mismatch"
    return None


def _case(argument, cap, deadline, raw_count):
    row = not_run(argument)
    start = time.monotonic()  # Inclusive of Popen/startup, not utility timer time.
    if deadline - start < cap + 1:
        return row, raw_count
    target = min(start + cap, deadline - 1)
    row["status"] = "start-failed"
    process = None
    selector = None
    pending = bytearray()
    banner = False
    expected = verify.predicate_shape(PREDICATE)
    try:
        process = subprocess.Popen(["/usr/bin/log", "stream", "--style", "ndjson", "--timeout", argument,
                                    "--predicate", PREDICATE], env=verify.clean_env(), stdin=subprocess.DEVNULL,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0)
        row.update(status="source-error", stdoutEOF=False, stderrEOF=False, framingComplete=True,
                   stopRequested=False, reaped=False)
        selector = selectors.DefaultSelector()
        for pipe, flag in ((process.stdout, "stdoutEOF"), (process.stderr, "stderrEOF")):
            os.set_blocking(pipe.fileno(), False)
            selector.register(pipe, selectors.EVENT_READ, flag)
        failure = None
        while failure is None:
            if time.monotonic() >= target:
                row["processAtTarget"] = _state(process)
                if row["processAtTarget"] == "exit-nonzero":
                    row["status"] = "source-error"
                elif pending:
                    row["status"] = "invalid-output"
                    row["inputReason"] = "partial-target"
                else:
                    row["status"] = "forced-timeout"
                break
            state = _state(process)
            if state == "exit-nonzero":
                failure = "source-error"
                break
            # At most eight reads per pass, regardless of source readiness.
            ready = selector.select(0)
            for key, _ in ready[:8]:
                if time.monotonic() >= target:
                    break
                try:
                    chunk = os.read(key.fd, min(8192, MAXIMUM - raw_count + 1))
                except BlockingIOError:
                    continue
                raw_count += len(chunk)
                if raw_count > MAXIMUM:
                    failure = "output-limit"
                    break
                if not chunk:
                    if time.monotonic() >= target:
                        # Even read-zero observed late cannot become normal EOF.
                        break
                    row[key.data] = True
                    selector.unregister(key.fileobj)
                    if key.data == "stdoutEOF" and pending:
                        failure = "invalid-output"
                        row["inputReason"] = "partial-eof"
                        break
                    continue
                if key.data == "stderrEOF":
                    failure = "source-error"
                    break
                pending.extend(chunk)
                row["framingComplete"] = False
                while b"\n" in pending:
                    record, _, rest = pending.partition(b"\n")
                    if len(record) > RECORD_MAXIMUM:
                        failure = "output-limit"
                        break
                    pending[:] = rest
                    if record.strip():
                        reason = _record_reason(bytes(record), banner, expected)
                        if reason is not None:
                            failure = "invalid-output"
                            row["inputReason"] = reason
                            break
                        banner = True
                if failure is not None:
                    break
                if len(pending) > RECORD_MAXIMUM:
                    failure = "output-limit"
                    break
                row["framingComplete"] = not pending
            if failure is not None:
                break
            if time.monotonic() < target and row["stdoutEOF"] and row["stderrEOF"] and not pending:
                status = process.poll()
                completed = time.monotonic()
                if status == 0 and completed < target:
                    row.update(status="normal-exit", reaped=True, framingComplete=True,
                               elapsedBand=elapsed_band(completed - start))
                    return row, raw_count
            remaining = target - time.monotonic()
            if remaining > 0:
                time.sleep(min(0.01, remaining))
        if failure is not None:
            row["status"] = failure
    except (verify.Failure, UnicodeError):
        row["status"] = "invalid-output" if process is not None else "start-failed"
        if process is not None and row["inputReason"] == "not-observed":
            row["inputReason"] = "parser-exception"
    except Exception:
        row["status"] = "source-error" if process is not None else "start-failed"
        if time.monotonic() >= target and process is not None:
            row["processAtTarget"] = "unknown"
    finally:
        if process is not None:
            if row["status"] != "normal-exit":
                _stop(process, row, start, deadline)
            if selector is not None:
                try:
                    selector.close()
                except Exception:
                    if row["status"] == "normal-exit":
                        row["status"] = "source-error"
            for pipe in (process.stdout, process.stderr):
                if pipe is not None:
                    try:
                        pipe.close()
                    except Exception:
                        if row["status"] == "normal-exit":
                            row["status"] = "source-error"
        if row["status"] == "normal-exit":
            row["inputReason"] = "none"
    return row, raw_count


def run():
    """Run one fixed batch, returning its safe receipt without writing it.

    Parent owns report preservation and driver hash/dirty evidence. No retry.
    """
    deadline = time.monotonic() + 100
    try:
        source, build = _preflight(deadline)
    except Exception:
        raise verify.Failure("control_preflight_failed") from None
    receipt = {"controlID": str(uuid.uuid4()), "sourceCommit": source, "OSBuild": build,
               "budgetWithinLimit": True, "cases": {name: not_run(argument) for name, argument, _ in CASES}}
    raw_count = 0
    for name, argument, cap in CASES:
        row, raw_count = _case(argument, cap, deadline, raw_count)
        receipt["cases"][name] = row
        if row["status"] != "normal-exit" and not (row["status"] == "forced-timeout" and row["reaped"] is True):
            break
    receipt["budgetWithinLimit"] = time.monotonic() <= deadline
    return validate_receipt(receipt)


def save(receipt):
    """Write once to the fixed private exclusive destination; never adopt/retry."""
    validate_receipt(receipt)
    data = (json.dumps(receipt, sort_keys=True, indent=2) + "\n").encode("ascii")
    directory = verify.directory_fd(verify.ROOT / ".build/topology/arm64", private=False)
    descriptor = None
    try:
        descriptor = os.open("log-timeout-control-" + receipt["controlID"] + ".json",
                             os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
                             0o600, dir_fd=directory)
        os.fchmod(descriptor, 0o600)
        offset = 0
        while offset < len(data):
            count = os.write(descriptor, data[offset:])
            verify.require(count > 0, "control_write_failed")
            offset += count
    finally:
        if descriptor is not None:
            os.close(descriptor)
        os.close(directory)


def main(argv=None):
    try:
        # Nothing from raw utility errors or caller arguments reaches the CLI.
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            verify.require(not (sys.argv[1:] if argv is None else argv), "control_arguments_invalid")
            receipt = run()
            save(receipt)
        print(json.dumps(receipt, sort_keys=True))
        return 0
    except (Exception, SystemExit, KeyboardInterrupt):
        print("Log timeout control failed; no raw output emitted.", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
