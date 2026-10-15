"""Pure Story 1.6 assertion conformance. No collection or authentication.

Owners supply frozen authority and actual bytes independently of records.
Return 1 for invalid assertions, 2 for conformant assertions; never certify.
"""
from __future__ import annotations

from dataclasses import dataclass

import verify_packaged_db as db

SCHEMA = "packaged-agent-matrix-evidence-v1"
# Immutable probe-intent provenance, not approval of active matrix membership.
SPEC_COMMIT = "f3c35000a75b04fd239fcc8820ffba90fd881951"
POINTS = db.POINTS
EVENTS = ("success", "failure", "restart", "replacement", "delete")
REASONS = db.REASONS + ("row_missing", "row_duplicate", "event_mismatch",
                       "phase_incomplete", "terminal_unverified", "producer_not_drained",
                       "purge_unverified", "marker_remaining", "actor_unverified",
                       "native_unapproved", "offline_only")


@dataclass(frozen=True)
class DBInput:
    record: bytes
    expected: db.OwnerExpectedBindings
    supplied: db.SuppliedBytes


@dataclass(frozen=True)
class ReplacementBindings:
    predecessorCode: str
    predecessorPackage: str
    replacementCode: str
    replacementPackage: str
    postDB: DBInput


@dataclass(frozen=True)
class OwnerExpectedBindings:
    db: DBInput
    event: str
    attempt: str
    lineage: str
    paper: str
    generation: int
    correlation: str
    agentCode: str
    nestedCode: str
    spec: str
    receipt: str
    replacement: ReplacementBindings | None = None


@dataclass(frozen=True)
class ReplacementBytes:
    predecessorCode: bytes
    predecessorPackage: bytes
    replacementCode: bytes
    replacementPackage: bytes


@dataclass(frozen=True)
class SuppliedBytes:
    agentCode: bytes
    nestedCode: bytes
    spec: bytes
    receipt: bytes
    replacement: ReplacementBytes | None = None


def expected_bindings(expected: OwnerExpectedBindings) -> dict:
    """Closed projection of independent authority, not an authentication receipt."""
    replacement = expected.replacement
    return {"issue": 9, "specCommit": SPEC_COMMIT,
            "db": db.expected_bindings(expected.db.expected),
            "dbRecord": db.digest(expected.db.record), "event": expected.event,
            **{name: getattr(expected, name) for name in
               ("attempt", "lineage", "paper", "generation", "correlation",
                "agentCode", "nestedCode", "spec", "receipt")},
            "replacement": None if replacement is None else {
                **{name: getattr(replacement, name) for name in
                   ("predecessorCode", "predecessorPackage", "replacementCode", "replacementPackage")},
                "postDB": db.expected_bindings(replacement.postDB.expected),
                "postDBRecord": db.digest(replacement.postDB.record)}}


def required_phases(expected: OwnerExpectedBindings) -> list[dict]:
    """Fixed event semantics; order and typed values are never record-derived."""
    db.require(type(expected) is OwnerExpectedBindings and expected.event in EVENTS)
    context = {name: getattr(expected, name) for name in
               ("attempt", "lineage", "paper", "generation", "correlation")}
    context.update(run=expected.db.expected.run, owner=expected.db.expected.owner)

    def phase(name, **values):
        return {"phase": name, "fixture": expected.event, **context, **values}

    phases = [phase("marker_present", owned=True)]
    if expected.event in ("success", "failure"):
        phases.append(phase("provider_terminal", source="approved_sdk_request",
                            terminal=expected.event,
                            failureType="provider" if expected.event == "failure" else None,
                            paperLinked=True, genuine=True))
    elif expected.event in ("restart", "replacement"):
        phases.append(phase("old_process_closed", producersClosed=True, reaped=True,
                            registered=True, drained=True, unknownProducers=False))
        if expected.event == "replacement":
            db.require(type(expected.replacement) is ReplacementBindings)
            phases.append(phase("replacement_installed",
                                code=expected.replacement.replacementCode,
                                package=expected.replacement.replacementPackage))
        code = expected.agentCode if expected.event == "restart" else expected.replacement.replacementCode
        phases.extend([phase("fresh_agent", signed=True, freshProcess=True, code=code,
                             nestedCode=expected.nestedCode),
                       phase("startup_recovery", owned=True, sameLiveProcess=False)])
    else:
        phases.extend([phase("paper_delete_signal", source="paper_generation_correlation_gate"),
                       phase("admission_revoked", revoked=True),
                       phase("cancel", registeredProducers=True)])
    phases.extend([phase("producer_drain", registered=True, closed=True, unknownProducers=False),
                   phase("purge_confirmed", source="agent_paperPurge", confirmed=True),
                   phase("absence_verified", markerRemaining=False, complete=True),
                   phase("cleanup", ownedOnly=True, unresolvedOwnership=False)])
    return phases


def _result(conformant=False, coverage=False, positive=False, reason="binding_mismatch",
            point=None, event=None, phase="input"):
    return (2 if conformant else 1), {
        "schemaRevision": SCHEMA, "conformant": conformant, "coverage": coverage,
        "positiveAssertions": positive, "status": "blocked", "storyDone": False,
        "p2Passed": False, "promotion": "not_promoted",
        "diagnostics": [{"point": point, "event": event, "phase": phase, "reason": reason}]}


def _db_input(value):
    db.require(type(value) is DBInput)
    code, _ = db.validate_cell(value.record, value.expected, value.supplied)
    db.require(code == 2)
    record = db.bounded_json(value.record)
    wanted = db.required_phases(len(record["corpus"]["payloadByteLengths"]))
    return (value.expected.osBuild is not None and record["scope"] == "packaged_db_fts5" and
            db.exact([p["phase"] for p in record["phases"]], [p["phase"] for p in wanted]))


def _owner(expected, supplied):
    db.require(type(expected) is OwnerExpectedBindings and type(supplied) is SuppliedBytes)
    db.require(type(expected.event) is str and expected.event in EVENTS, "event_mismatch")
    positive = _db_input(expected.db)
    for name in ("attempt", "lineage", "paper", "correlation"):
        db._uuid(getattr(expected, name))
    identities = [expected.attempt, expected.lineage, expected.paper, expected.correlation,
                  expected.db.expected.run, expected.db.expected.owner,
                  expected.db.expected.attempt, expected.db.expected.lineage]
    db.require(len(set(identities)) == len(identities))
    db.require(type(expected.generation) is int and 1 <= expected.generation <= 2147483647)
    for name in ("agentCode", "nestedCode", "spec", "receipt"):
        db._hex(getattr(expected, name))
        actual = getattr(supplied, name)
        db.require(type(actual) is bytes and bool(actual) and db.digest(actual) == getattr(expected, name))
    db.require(len(supplied.receipt) <= 4096)
    if expected.event != "replacement":
        db.require(expected.replacement is None and supplied.replacement is None)
    else:
        r, s = expected.replacement, supplied.replacement
        db.require(type(r) is ReplacementBindings and type(s) is ReplacementBytes)
        for name in ("predecessorCode", "predecessorPackage", "replacementCode", "replacementPackage"):
            db._hex(getattr(r, name))
            actual = getattr(s, name)
            db.require(type(actual) is bytes and bool(actual) and db.digest(actual) == getattr(r, name))
        db.require(r.predecessorCode == expected.agentCode)
        db.require(r.predecessorPackage == expected.db.expected.package)
        db.require(r.predecessorCode != r.replacementCode and r.predecessorPackage != r.replacementPackage)
        positive = _db_input(r.postDB) and positive
        before, after = expected.db.expected, r.postDB.expected
        db.require(len(set(identities + [after.attempt, after.lineage])) == len(identities) + 2)
        for name in ("point", "osBuild", "run", "owner", "lock", "spec", "grdbSource", "sqlite"):
            db.require(db.exact(getattr(before, name), getattr(after, name)))
        for name in ("attempt", "lineage", "receipt"):
            db.require(getattr(before, name) != getattr(after, name))
        db.require(after.code == r.replacementCode and after.package == r.replacementPackage)
        db.require(s.predecessorCode == supplied.agentCode and
                   s.predecessorPackage == expected.db.supplied.package and
                   s.replacementCode == r.postDB.supplied.code and
                   s.replacementPackage == r.postDB.supplied.package)
    projection = expected_bindings(expected)
    del projection["receipt"]
    db.require(db.exact(db.bounded_json(supplied.receipt), {"bindings": projection}))
    return positive


def validate_row(record_bytes: bytes, expected: OwnerExpectedBindings,
                 supplied: SuppliedBytes) -> tuple[int, dict]:
    """Validate one assertion against frozen independently owned byte bindings."""
    point = event = None
    coverage = False
    try:
        positive_db = _owner(expected, supplied)
        point, event = expected.db.expected.point, expected.event
        record = db.bounded_json(record_bytes)
        db.require(type(record) is dict and set(record) ==
                   {"schemaRevision", "bindings", "point", "event", "state", "phases"})
        db.require(db.exact(record["schemaRevision"], SCHEMA))
        db.require(db.exact(record["bindings"], expected_bindings(expected)))
        db.require(db.exact(record["point"], point) and db.exact(record["event"], event), "event_mismatch")
        coverage = True
        phases = record["phases"]
        db.require(type(phases) is list and len(phases) <= 12, "phase_incomplete")
        db.require(type(record["state"]) is str and record["state"] in ("positive", "unavailable", "failed"))
        wanted = required_phases(expected)
        if record["state"] != "positive":
            # Failed observations contain an exact successful prefix and one closed failure.
            db.require(1 <= len(phases) <= len(wanted), "phase_incomplete")
            prefix, failure = phases[:-1], phases[-1]
            db.require(db.exact(prefix, wanted[:len(prefix)]), "phase_incomplete")
            db.require(type(failure) is dict and set(failure) == {"phase", "reason"})
            phase = "unavailable" if record["state"] == "unavailable" else wanted[len(prefix)]["phase"]
            db.require(record["state"] != "unavailable" or not prefix)
            db.require(db.exact(failure["phase"], phase))
            db.require(type(failure["reason"]) is str and failure["reason"] in REASONS)
            return _result(True, True, False, failure["reason"], point, event, phase)
        db.require(db.exact(phases, wanted), "phase_incomplete")
        return _result(True, True, positive_db, "offline_only", point, event, "offline_only")
    except db.Invalid as failure:
        reason = failure.reason if failure.reason in REASONS else "binding_mismatch"
        return _result(coverage=coverage, reason=reason, point=point, event=event)
    except (TypeError, ValueError, UnicodeError, RecursionError, OverflowError, AttributeError):
        return _result()


def validate_matrix(records: tuple[bytes, ...], expected: tuple[OwnerExpectedBindings, ...],
                    supplied: tuple[SuppliedBytes, ...], db_inputs: tuple[DBInput, ...]) -> tuple[int, dict]:
    """Exactly ten ordered event rows and two arm64 DB executions; no runtime PASS."""
    try:
        db.require(all(type(x) is tuple for x in (records, expected, supplied, db_inputs)))
        row_count = len(POINTS) * len(EVENTS)
        db.require(len(records) == len(expected) == len(supplied) == row_count,
                   "row_missing" if min(len(records), len(expected), len(supplied)) < row_count else "event_mismatch")
        db.require(len(db_inputs) == len(POINTS))
        db.require(all(type(r) is bytes for r in records) and sum(map(len, records)) <= 163840)
        db.require(all(type(e) is OwnerExpectedBindings for e in expected))
        db.require(all(type(d) is DBInput for d in db_inputs))
        code, _ = db.validate_matrix(tuple(d.record for d in db_inputs),
                                     tuple(d.expected for d in db_inputs), tuple(d.supplied for d in db_inputs))
        db.require(code == 2)
        cells = tuple((e.db.expected.point, e.event) for e in expected)
        db.require(len(set(cells)) == row_count, "row_duplicate")
        db.require(cells ==
                   tuple((p, event) for p in POINTS for event in EVENTS), "event_mismatch")
        replacements = [e.replacement for e in expected if e.event == "replacement"]
        db.require(all(type(r) is ReplacementBindings and type(r.postDB) is DBInput
                       for r in replacements))
        execution_ids = [identity for e in expected for identity in (e.attempt, e.lineage, e.correlation)]
        execution_ids += [identity for d in db_inputs for identity in (d.expected.attempt, d.expected.lineage)]
        execution_ids += [identity for r in replacements for identity in
                          (r.postDB.expected.attempt, r.postDB.expected.lineage)]
        db.require(len(set(execution_ids)) == len(execution_ids))
        receipts = [e.receipt for e in expected] + [d.expected.receipt for d in db_inputs]
        receipts += [r.postDB.expected.receipt for r in replacements]
        db.require(len(set(receipts)) == len(receipts))
        for index, e in enumerate(expected):
            db.require(db.exact(e.db, db_inputs[index // len(EVENTS)]))
        db.require(len({e.spec for e in expected}) == 1)
        results = [validate_row(r, e, s) for r, e, s in zip(records, expected, supplied)]
        conformant = all(code == 2 for code, _ in results)
        _, output = _result(conformant, all(o["coverage"] for _, o in results),
                            conformant and all(o["positiveAssertions"] for _, o in results),
                            "offline_only")
        output["rows"] = [o for _, o in results]
        return (2 if conformant else 1), output
    except db.Invalid as failure:
        return _result(reason=failure.reason if failure.reason in REASONS else "binding_mismatch")
    except (TypeError, ValueError, UnicodeError, RecursionError, OverflowError, AttributeError):
        return _result()
