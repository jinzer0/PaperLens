"""Story 1.5 pure offline assertion conformance; never execution certification.

validate_cell(record_bytes, expected, supplied) and validate_matrix(records,
expected, supplied) consume bytes and independent immutable owner configuration.
required_phases is a closed assertion vocabulary, NOT a probe or runtime record
constructor. No DB, execution, collection, implicit file reads or promotion.
Exit-like codes: 1 invalid input, 2 conformant but still blocked. All supplied
certification labels are untrusted assertions, even when their hashes match.
"""
from __future__ import annotations

from dataclasses import dataclass, fields
import hashlib
import json
import re
from uuid import UUID

# Immutable probe-intent provenance, not approval of active matrix membership.
SPEC_COMMIT = "7b489572bdee826e4a14101ca0961e10d705e570"
GRDB_COMMIT = "b83108d10f42680d78f23fe4d4d80fc88dab3212"
SCHEMA = "packaged-db-fts5-evidence-v1"
POINTS = ("minimum/arm64", "current/arm64")
SCOPES = ("local_contract_only", "local_grdb_probe", "packaged_db_fts5")
MIGRATIONS = ("probe-baseline-v1", "probe-fts5-v2")
REASONS = ("grdb_unavailable", "binding_mismatch", "db_open_failed",
           "migration_failed", "fts_unavailable", "fts_failed", "rollback_failed",
           "reopen_failed", "sqlite_origin_unverified", "provenance_overflow",
           "timeout", "cleanup_failed", "unexpected_failure")
SQLITE_CODES = (1, 5, 6, 7, 10, 11, 13, 14, 19, 21, 26, 1555, 2067)
BYTE_FIELDS = ("code", "lock", "spec", "grdbSource", "acquisition", "package", "artifact", "receipt")


@dataclass(frozen=True)
class SQLiteProjection:
    """Owner-approved timestamp-free system-image/code identity, not raw sourceID."""
    imageIdentity: str
    sqliteVersion: str
    sqliteSourceId: str
    compileOptions: tuple[str, ...]


@dataclass(frozen=True)
class OwnerExpectedBindings:
    """Independently supplied authority; never derive this from a submitted record.

    Hashes bind actual bytes, including the separately supplied package receipt.
    Receipt bytes are the closed {"bindings": ...} projection without their own
    receipt hash (no circular hash). Hashing is identity, not authentication.
    osBuild=None intentionally blocks minimum-build-unpinned configurations.
    """
    point: str
    osBuild: str | None
    run: str
    owner: str
    attempt: str
    lineage: str
    codeCommit: str
    code: str
    lock: str
    spec: str
    grdbSource: str
    acquisition: str
    package: str
    artifact: str
    receipt: str
    sqlite: SQLiteProjection


@dataclass(frozen=True)
class SuppliedBytes:
    """Actual caller-supplied bytes, not filenames or record-provided hashes."""
    code: bytes
    lock: bytes
    spec: bytes
    grdbSource: bytes
    acquisition: bytes
    package: bytes
    artifact: bytes
    receipt: bytes


class Invalid(Exception):
    def __init__(self, reason="binding_mismatch", phase="input", sqlite_code=None):
        self.reason = reason
        self.phase = phase
        self.sqlite_code = sqlite_code
        super().__init__(reason)


def require(condition, reason="binding_mismatch", phase="input"):
    if not condition:
        raise Invalid(reason, phase)


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def json_bytes(value) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"),
                      ensure_ascii=False, allow_nan=False).encode("utf-8")


def exact(left, right):
    if type(left) is not type(right):
        return False
    if type(right) is dict:
        return left.keys() == right.keys() and all(exact(left[k], v) for k, v in right.items())
    if type(right) in (tuple, list):
        return len(left) == len(right) and all(exact(a, b) for a, b in zip(left, right))
    return left == right


def bounded_json(data: bytes):
    """Strict UTF-8/duplicate-aware JSON, <=16384 bytes and container depth <=8."""
    require(type(data) is bytes and 0 < len(data) <= 16384)

    def pairs(items):
        result = {}
        for key, value in items:
            require(key not in result)
            result[key] = value
        return result

    def constant(_):
        raise Invalid()

    try:
        value = json.loads(data.decode("utf-8"), object_pairs_hook=pairs, parse_constant=constant)
    except (ValueError, UnicodeError, RecursionError):
        raise Invalid() from None

    def walk(item, depth):
        require(depth <= 8)
        if type(item) is dict:
            require(depth < 8)
            for key, child in item.items():
                require(type(key) is str)
                key.encode("utf-8", errors="strict")
                walk(child, depth + 1)
        elif type(item) is list:
            require(depth < 8)
            for child in item:
                walk(child, depth + 1)
        elif type(item) is str:
            item.encode("utf-8", errors="strict")
        else:
            require(type(item) in (int, bool, type(None)))
    try:
        walk(value, 0)
    except (UnicodeError, ValueError, RecursionError):
        raise Invalid() from None
    return value


def _uuid(value):
    require(type(value) is str)
    try:
        parsed = UUID(value)
    except ValueError:
        raise Invalid() from None
    require(str(parsed) == value and parsed.version == 4 and parsed.variant == "specified in RFC 4122")


def _hex(value, lengths=(64,)):
    require(type(value) is str and len(value) in lengths and
            re.fullmatch(r"[0-9a-f]+", value) is not None and len(set(value)) > 1)


def _owner(expected, supplied):
    require(type(expected) is OwnerExpectedBindings and type(supplied) is SuppliedBytes)
    require(type(expected.point) is str and expected.point in POINTS)
    require(expected.osBuild is None or (type(expected.osBuild) is str and
            re.fullmatch(r"[0-9]{2}[A-Z][0-9]{1,4}[a-z]?", expected.osBuild) is not None))
    for name in ("run", "owner", "attempt", "lineage"):
        _uuid(getattr(expected, name))
    require(len({expected.run, expected.owner, expected.attempt, expected.lineage}) == 4)
    _hex(expected.codeCommit, (40,))
    for name in BYTE_FIELDS:
        wanted, actual = getattr(expected, name), getattr(supplied, name)
        _hex(wanted)
        require(type(actual) is bytes and bool(actual), "grdb_unavailable" if name == "grdbSource" else "binding_mismatch")
        require(digest(actual) == wanted)
    # Reuse the approved 1.4 inventory's sole canonical pin authority.
    import validate_dependency_lock as dependency_lock
    try:
        dependency_lock.validate_lock(supplied.lock)
    except dependency_lock.Invalid:
        raise Invalid() from None
    projection = expected.sqlite
    require(type(projection) is SQLiteProjection)
    _hex(projection.imageIdentity)
    _hex(projection.sqliteSourceId, (40, 64))
    require(type(projection.sqliteVersion) is str and
            re.fullmatch(r"[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}", projection.sqliteVersion) is not None)
    require(type(projection.compileOptions) is tuple and 0 < len(projection.compileOptions) <= 16)
    require(all(type(x) is str and x in dependency_lock.COMPILE_FACTS for x in projection.compileOptions))
    require(len(set(projection.compileOptions)) == len(projection.compileOptions) and
            "ENABLE_FTS5" in projection.compileOptions)


def expected_bindings(expected: OwnerExpectedBindings) -> dict:
    """Closed owner projection; only explicitly approved code/artifact hashes."""
    role, cpu = expected.point.split("/")
    return {**{name: getattr(expected, name) for name in BYTE_FIELDS},
            "issue": 8, "specCommit": SPEC_COMMIT, "grdbCommit": GRDB_COMMIT,
            "grdbVersion": "7.11.1", "codeCommit": expected.codeCommit,
            "point": expected.point, "osVersion": "15.0" if role == "minimum" else "26.7.1",
            "osBuild": expected.osBuild, "artifactCPU": cpu, "hardwareCPU": cpu,
            "processCPU": cpu, "native": True, "translated": False,
            **{name: getattr(expected, name) for name in ("run", "owner", "attempt", "lineage")}}


def required_phases(row_count: int) -> list[dict]:
    """Fixed assertions of real behavior required later; this executes no behavior.

    Schema state is actual table/registry/version assertion, not cached version.
    Separate fault fixtures must preserve earlier commits on unchanged reopen.
    watchdogSeconds declares the configured limit, never an observed duration.
    """
    require(type(row_count) is int and 1 <= row_count <= 4)

    def state(version):
        return {"version": version, "registry": list(MIGRATIONS[:version]),
                "tables": ["probe_state"] if version == 1 else
                (["probe_state", "probe_fts", "probe_fts_data", "probe_fts_idx",
                  "probe_fts_content", "probe_fts_docsize", "probe_fts_config"] if version == 2 else []),
                "rows": 0}

    def phase(name, fixture="success", **values):
        return {"phase": name, "fixture": fixture, **values}

    phases = [phase("open", queueCount=1, watchdogSeconds=30, before=state(0))]
    for index, migration in enumerate(MIGRATIONS):
        phases.append(phase("migration", migration=migration, before=state(index),
                            after=state(index + 1), atomic=True))
    phases += [phase("fts_create", after=state(2)),
               phase("fts_query", rows=row_count, ids=list(range(1, row_count + 1))),
               phase("fts_delete", rows=0, ids=[]), phase("close", drained=True, activeQueues=0),
               phase("reopen", queueCount=1, watchdogSeconds=30,
                     before=state(2), after=state(2), migrationsRun=[]),
               phase("reopened_absence", rows=0, ids=[]),
               phase("close_reopened", drained=True, activeQueues=0)]
    for index, migration in enumerate(MIGRATIONS):
        fixture = "baseline_failure" if index == 0 else "fts_failure"
        phases += [phase("fault_open", fixture, queueCount=1, watchdogSeconds=30, before=state(index)),
                   phase("injected_failure", fixture, migration=migration,
                         injection="after_changes_before_completion", reason="migration_failed", sqliteCode=1),
                   phase("rollback", fixture, after=state(index), atomic=True),
                   phase("fault_close", fixture, drained=True, activeQueues=0),
                   phase("failure_reopen", fixture, queueCount=1, watchdogSeconds=30,
                         before=state(index), after=state(index),
                         integrity=True, sameFailedStartup=True, ready=False, reseeded=False),
                   phase("fault_reclose", fixture, drained=True, activeQueues=0)]
    phases.append(phase("cleanup", fixture="all", drained=True, activeQueues=0,
                        ownedOnly=True, sidecarsRemoved=True, unresolvedOwnership=False))
    return phases


def _result(conformant, reason, phase="input", sqlite_code=None):
    return (2 if conformant else 1), {"schemaRevision": SCHEMA, "conformant": conformant,
            "status": "blocked", "storyDone": False, "p2Passed": False,
            "promotion": "not_promoted", "diagnostics": [{"reason": reason,
            "phase": phase, "sqliteCode": sqlite_code}]}


def validate_cell(record_bytes: bytes, expected: OwnerExpectedBindings,
                  supplied: SuppliedBytes) -> tuple[int, dict]:
    """Validate supplied assertions against owner authority and actual bytes only."""
    try:
        _owner(expected, supplied)
        receipt_bindings = expected_bindings(expected)
        del receipt_bindings["receipt"]
        require(exact(bounded_json(supplied.receipt), {"bindings": receipt_bindings}))
        record = bounded_json(record_bytes)
        require(type(record) is dict and set(record) ==
                {"schemaRevision", "scope", "bindings", "sqlite", "corpus", "phases"})
        require(exact(record["schemaRevision"], SCHEMA))
        require(type(record["scope"]) is str and record["scope"] in SCOPES)
        require(exact(record["bindings"], expected_bindings(expected)))
        projection = {f.name: getattr(expected.sqlite, f.name) for f in fields(SQLiteProjection)}
        projection["compileOptions"] = list(projection["compileOptions"])
        projection.update(origin="apple-system", osBuild=expected.osBuild, point=expected.point,
                          sameConnection=True, symbolsBoundToImage=True)
        sqlite = record["sqlite"]
        require(type(sqlite) is dict and set(sqlite) == set(projection) | {"inspection"},
                "sqlite_origin_unverified", "provenance")
        inspection = sqlite["inspection"]
        require(type(inspection) is dict and set(inspection) == {"entries", "maxEntryBytes", "complete"},
                "sqlite_origin_unverified", "provenance")
        for name in ("entries", "maxEntryBytes"):
            require(type(inspection[name]) is int and 1 <= inspection[name] <= 256,
                    "provenance_overflow", "provenance")
        require(inspection["complete"] is True and inspection["entries"] >= len(projection["compileOptions"]),
                "sqlite_origin_unverified", "provenance")
        require(inspection["maxEntryBytes"] >= max(
            len(option.encode("utf-8")) for option in projection["compileOptions"]),
            "sqlite_origin_unverified", "provenance")
        require(exact({k: v for k, v in sqlite.items() if k != "inspection"}, projection),
                "sqlite_origin_unverified", "provenance")
        corpus = record["corpus"]
        require(type(corpus) is dict and set(corpus) == {"payloadByteLengths", "queryByteLength"})
        lengths = corpus["payloadByteLengths"]
        require(type(lengths) is list and 1 <= len(lengths) <= 4 and
                all(type(n) is int and 1 <= n <= 256 for n in lengths))
        require(type(corpus["queryByteLength"]) is int and 1 <= corpus["queryByteLength"] <= 64)
        phases = record["phases"]
        require(type(phases) is list and 1 <= len(phases) <= 32)
        # A reported inability is conformance only; never substitutes for missing phases.
        if len(phases) == 1 and type(phases[0]) is dict and set(phases[0]) == {"phase", "reason", "sqliteCode"}:
            failure = phases[0]
            require(failure["phase"] == "unavailable" and type(failure["reason"]) is str and failure["reason"] in REASONS)
            code = failure["sqliteCode"]
            require(code is None or (type(code) is int and code in SQLITE_CODES))
            return _result(True, failure["reason"], "unavailable", code)
        wanted = required_phases(len(lengths))
        require(len(phases) == len(wanted))
        for actual, assertion in zip(phases, wanted):
            if assertion["phase"] == "injected_failure":
                require(type(actual) is dict and type(actual.get("sqliteCode")) is int and actual["sqliteCode"] in SQLITE_CODES,
                        "migration_failed", "injected_failure")
                assertion["sqliteCode"] = actual["sqliteCode"]
            require(exact(actual, assertion), "binding_mismatch", assertion["phase"])
        return _result(True, "sqlite_origin_unverified", "offline_only")
    except Invalid as failure:
        return _result(False, failure.reason, failure.phase, failure.sqlite_code)
    except (TypeError, ValueError, UnicodeError, RecursionError, OverflowError, AttributeError):
        return _result(False, "binding_mismatch")


def validate_matrix(records: tuple[bytes, ...], expected: tuple[OwnerExpectedBindings, ...],
                    supplied: tuple[SuppliedBytes, ...]) -> tuple[int, dict]:
    """Exactly minimum/current arm64 executions; no runtime PASS or promotion."""
    try:
        require(type(records) is tuple and type(expected) is tuple and type(supplied) is tuple)
        require(len(records) == len(expected) == len(supplied) == len(POINTS))
        require(all(type(r) is bytes for r in records) and sum(map(len, records)) <= 32768)
        require(all(type(e) is OwnerExpectedBindings for e in expected))
        require(tuple(e.point for e in expected) == POINTS)
        for name in ("attempt", "lineage", "receipt"):
            require(len({getattr(e, name) for e in expected}) == len(POINTS))
        require(expected[0].artifact == expected[1].artifact)
        for name in ("run", "owner", "codeCommit", "code", "lock", "spec", "grdbSource", "acquisition", "package"):
            require(len({getattr(e, name) for e in expected}) == 1)
        results = [validate_cell(r, e, s) for r, e, s in zip(records, expected, supplied)]
        _, output = _result(all(code == 2 for code, _ in results), "sqlite_origin_unverified", "offline_only")
        output["cells"] = [item for _, item in results]
        return (2 if output["conformant"] else 1), output
    except (Invalid, TypeError, ValueError, AttributeError):
        return _result(False, "binding_mismatch")
