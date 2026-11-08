#!/usr/bin/env python3
"""Offline Story 1.4 conformance only; never release/P1/P2 promotion.

The immutable canonical digest binds the existing dependency pins plus the
explicitly approved 2026-11-05 Xcode27.2 toolchain update in the Epic execution Spec.
The manifest remains the only
dependency inventory; no runtime git or historical checkout is required.
Changing accepted pins requires a new approved Spec, not a recomputed checksum.
"""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import re
import sys

SPEC_COMMIT = "33dcd8db20a122d13a6ce0a16b92077f278facb6"
MINIMUM_OS_BUILD = "24A335"
POINTS = ("minimum/arm64", "current/arm64")
# Approved semantic identity; whitespace and object order are not pin identity.
APPROVED_CANONICAL_SHA256 = "c95fca4915010196524bb616ec4caeba0c65f416096642a38e7fd67fe0eabe90"

CODES = (
    "LOCK_INPUT_MISSING", "LOCK_INPUT_CHANGED", "HASH_INVALID", "HASH_MISMATCH",
    "ARTIFACT_MISSING", "ARTIFACT_CHANGED", "ARTIFACT_UNVERIFIED",
    "MATRIX_POINT_MISSING", "MATRIX_POINT_DUPLICATE", "IDENTITY_MISMATCH",
    "MIN_OS_BUILD_UNPINNED", "NATIVE_EXEC_UNAVAILABLE", "PACKAGED_PROOF_NOT_RUN",
    "PACKAGED_PROOF_FAILED", "SQLITE_PROVENANCE_MISSING",
)
# Diagnostics are projections of closed enums, never input-derived prose.
CAUSES = {code: code for code in CODES}
RETEST = {code: "RECHECK_APPROVED_INPUTS" for code in CODES}
RETEST.update({
    "MIN_OS_BUILD_UNPINNED": "PIN_EXACT_MINIMUM_BUILD",
    "NATIVE_EXEC_UNAVAILABLE": "PROVIDE_AUTHORIZED_NATIVE_EXECUTION",
    "PACKAGED_PROOF_NOT_RUN": "RUN_AUTHORIZED_PACKAGED_PROOF",
    "PACKAGED_PROOF_FAILED": "REPAIR_AND_REPEAT_PACKAGED_PROOF",
    "SQLITE_PROVENANCE_MISSING": "PROVIDE_POINT_SYSTEM_SQLITE_PROOF",
    "ARTIFACT_MISSING": "PROVIDE_POINT_ARTIFACT_BYTES",
    "ARTIFACT_UNVERIFIED": "PROVIDE_POINT_EVIDENCE_BYTES",
})
POINTERS = ("/lock", "/matrix", "/source") + POINTS


def diagnostic(code, pointer):
    assert code in CODES and pointer in POINTERS
    return {"code": code, "pointerOrPoint": pointer, "cause": CAUSES[code],
            "retestCondition": RETEST[code]}


class Invalid(Exception):
    def __init__(self, code, pointer):
        self.diagnostic = diagnostic(code, pointer)
        super().__init__(code)


def require(condition, code, pointer):
    if not condition:
        raise Invalid(code, pointer)


def strict_json(data, pointer):
    def pairs(items):
        result = {}
        for key, value in items:
            require(key not in result, "IDENTITY_MISMATCH", pointer)
            result[key] = value
        return result

    def constant(_):
        raise Invalid("IDENTITY_MISMATCH", pointer)

    require(type(data) is bytes, "LOCK_INPUT_MISSING", pointer)
    try:
        return json.loads(data.decode("utf-8"), object_pairs_hook=pairs,
                          parse_constant=constant)
    except (UnicodeError, ValueError, RecursionError):
        raise Invalid("IDENTITY_MISMATCH", pointer) from None


def exact(value, expected):
    """Recursive equality with exact types (False must never equal integer 0)."""
    if type(value) is not type(expected):
        return False
    if type(expected) is dict:
        return value.keys() == expected.keys() and all(
            exact(value[key], child) for key, child in expected.items())
    if type(expected) is list:
        return len(value) == len(expected) and all(
            exact(left, right) for left, right in zip(value, expected))
    return value == expected


def validate_lock(data):
    value = strict_json(data, "/lock")
    try:
        canonical = json.dumps(value, sort_keys=True, separators=(",", ":"),
                               ensure_ascii=True, allow_nan=False).encode("ascii")
    except (TypeError, ValueError, RecursionError):
        raise Invalid("LOCK_INPUT_CHANGED", "/lock") from None
    require(digest(canonical) == APPROVED_CANONICAL_SHA256,
            "LOCK_INPUT_CHANGED", "/lock")
    return value


def digest(data):
    return hashlib.sha256(data).hexdigest()


def hash_value(value, pointer):
    require(type(value) is str and re.fullmatch(r"[0-9a-f]{64}", value)
            and len(set(value)) > 1, "HASH_INVALID", pointer)


def keys(value, names, pointer):
    require(type(value) is dict and set(value) == set(names),
            "IDENTITY_MISMATCH", pointer)


def hash_bytes(data, expected, pointer, missing, changed):
    hash_value(expected, pointer)
    require(type(data) is bytes and bool(data), missing, pointer)
    require(digest(data) == expected, changed, pointer)


def candidate_matrix(lock_bytes, source_bytes):
    """Construct from actual bytes only. Parent writes after all source edits."""
    validate_lock(lock_bytes)
    require(type(source_bytes) is bytes and bool(source_bytes),
            "LOCK_INPUT_MISSING", "/source")
    cells = []
    for point in POINTS:
        role, cpu = point.split("/")
        blockers = []
        if role == "minimum":
            blockers.append("NATIVE_EXEC_UNAVAILABLE")
        blockers.append("PACKAGED_PROOF_NOT_RUN")
        blockers.extend(("ARTIFACT_MISSING", "ARTIFACT_UNVERIFIED",
                         "SQLITE_PROVENANCE_MISSING"))
        cells.append({"cpu": cpu, "osRole": role,
                      "osVersion": "15.0" if role == "minimum" else "26.7.1",
                      "osBuild": MINIMUM_OS_BUILD if role == "minimum" else "25G241",
                      "status": "not_run" if point == "current/arm64" else "blocked",
                      "blockers": blockers, "artifact": None, "evidence": None,
                      "sqlite": None})
    return {"schemaRevision": "runtime-matrix-v1", "specCommit": SPEC_COMMIT,
            "lockSha256": digest(lock_bytes), "sourceSha256": digest(source_bytes),
            "promotion": "not_promoted", "cells": cells}


SQLITE_KEYS = ("origin", "osBuild", "imageIdentity", "sqliteVersion", "sqliteSourceId",
               "compileOptions", "grdbOpen", "orderedMigration", "fts5Create",
               "fts5Query", "fts5Delete", "point")
EVENTS = ("sdkSuccess", "sdkFailure", "restart", "appReplacement", "paperDelete")
COMPILE_FACTS = ("ENABLE_FTS5", "THREADSAFE=1", "ENABLE_COLUMN_METADATA",
                 "ENABLE_RTREE", "ENABLE_JSON1", "ENABLE_FTS3", "ENABLE_FTS4",
                 "ENABLE_FTS3_PARENTHESIS", "ENABLE_UNLOCK_NOTIFY", "SECURE_DELETE",
                 "DEFAULT_AUTOVACUUM", "ENABLE_DBSTAT_VTAB", "ENABLE_MATH_FUNCTIONS",
                 "OMIT_LOAD_EXTENSION", "USE_URI", "ENABLE_SESSION")


def sqlite_source_identity(value):
    # Preserve upstream alt markers and Apple's public SDK sqlite3.h "aapl" marker.
    # https://www.sqlite.org/releaselog/3_21_0.html . Image origin is checked separately.
    return type(value) is str and re.fullmatch(
        r"(?:[0-9a-f]{40}|[0-9a-f]{64}|[0-9a-f]{60}(?:alt[12]|aapl))", value) is not None


def sqlite_proof(value, build, point):
    keys(value, SQLITE_KEYS, point)
    require(value["origin"] == "apple-system" and value["osBuild"] == build and
            value["point"] == point,
            "IDENTITY_MISMATCH", point)
    hash_value(value["imageIdentity"], point)
    require(type(value["sqliteVersion"]) is str and
            re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", value["sqliteVersion"]),
            "IDENTITY_MISMATCH", point)
    # Only SQLite's source-code identity suffix is durable; its date stays in RAM.
    require(sqlite_source_identity(value["sqliteSourceId"]), "IDENTITY_MISMATCH", point)
    options = value["compileOptions"]
    require(type(options) is list and 0 < len(options) <= 16 and all(
        type(item) is str and item in COMPILE_FACTS
        for item in options), "IDENTITY_MISMATCH", point)
    require(len(options) == len(set(options)) and "ENABLE_FTS5" in options,
            "IDENTITY_MISMATCH", point)
    require(all(value[key] is True for key in SQLITE_KEYS[6:-1]),
            "ARTIFACT_UNVERIFIED", point)


def validate_matrix(value, lock_bytes, source_bytes, artifacts=None, evidence=None):
    artifacts = {} if artifacts is None else artifacts
    evidence = {} if evidence is None else evidence
    require(type(artifacts) is dict and type(evidence) is dict and
            set(artifacts) <= set(POINTS) and set(evidence) <= set(POINTS),
            "IDENTITY_MISMATCH", "/matrix")
    keys(value, ("schemaRevision", "specCommit", "lockSha256", "sourceSha256",
                 "promotion", "cells"), "/matrix")
    require(value["schemaRevision"] == "runtime-matrix-v1" and
            value["specCommit"] == SPEC_COMMIT and value["promotion"] == "not_promoted",
            "IDENTITY_MISMATCH", "/matrix")
    hash_bytes(lock_bytes, value["lockSha256"], "/lock",
               "LOCK_INPUT_MISSING", "HASH_MISMATCH")
    hash_bytes(source_bytes, value["sourceSha256"], "/source",
               "LOCK_INPUT_MISSING", "HASH_MISMATCH")
    cells = value["cells"]
    require(type(cells) is list, "IDENTITY_MISMATCH", "/matrix")
    seen = set()
    used_artifacts = set()
    used_evidence = set()
    diagnostics = []
    for cell in cells:
        keys(cell, ("cpu", "osRole", "osVersion", "osBuild", "status", "blockers",
                    "artifact", "evidence", "sqlite"), "/matrix")
        require(type(cell["cpu"]) is str and cell["cpu"] == "arm64" and
                type(cell["osRole"]) is str and cell["osRole"] in ("minimum", "current"),
                "IDENTITY_MISMATCH", "/matrix")
        point = cell["osRole"] + "/" + cell["cpu"]
        require(point not in seen, "MATRIX_POINT_DUPLICATE", point)
        seen.add(point)
        minimum = cell["osRole"] == "minimum"
        require(cell["osVersion"] == ("15.0" if minimum else "26.7.1"),
                "IDENTITY_MISMATCH", point)
        build = cell["osBuild"]
        require(not minimum or build is not None, "MIN_OS_BUILD_UNPINNED", point)
        # Public target identity is not evidence of native execution.
        require(exact(build, MINIMUM_OS_BUILD if minimum else "25G241"),
                "IDENTITY_MISMATCH", point)
        status = cell["status"]
        require(type(status) is str and status in ("blocked", "not_run", "failed", "verified"),
                "IDENTITY_MISMATCH", point)
        blockers = cell["blockers"]
        require(type(blockers) is list and all(type(item) is str and item in CODES
                for item in blockers), "IDENTITY_MISMATCH", point)
        require(len(blockers) == len(set(blockers)), "IDENTITY_MISMATCH", point)
        require(not minimum or cell["evidence"] is not None or
                status == "blocked", "IDENTITY_MISMATCH", point)
        require(cell["evidence"] is None or status == "verified",
                "ARTIFACT_UNVERIFIED", point)
        expected = []
        if minimum and cell["evidence"] is None:
            expected.append("NATIVE_EXEC_UNAVAILABLE")
        if status in ("not_run", "blocked"):
            expected.append("PACKAGED_PROOF_NOT_RUN")
        if status == "failed":
            expected.append("PACKAGED_PROOF_FAILED")
        bindings = {"point": point, "lockSha256": value["lockSha256"],
                    "sourceSha256": value["sourceSha256"]}
        artifact = cell["artifact"]
        proof = cell["evidence"]
        sqlite = cell["sqlite"]
        if artifact is None:
            expected.append("ARTIFACT_MISSING")
            require(point not in artifacts, "IDENTITY_MISMATCH", point)
        else:
            keys(artifact, ("sha256", *bindings), point)
            require(all(exact(artifact[key], item) for key, item in bindings.items()),
                    "IDENTITY_MISMATCH", point)
            hash_bytes(artifacts.get(point), artifact["sha256"], point,
                       "ARTIFACT_MISSING", "ARTIFACT_CHANGED")
            require(artifact["sha256"] not in used_artifacts, "MATRIX_POINT_DUPLICATE", point)
            used_artifacts.add(artifact["sha256"])
        if proof is None:
            expected.append("ARTIFACT_UNVERIFIED")
            require(point not in evidence, "IDENTITY_MISMATCH", point)
        else:
            require(artifact is not None and sqlite is not None and build is not None,
                    "ARTIFACT_UNVERIFIED", point)
            keys(proof, ("sha256", "artifactSha256", *bindings), point)
            require(all(exact(proof[key], item) for key, item in bindings.items()) and
                    proof["artifactSha256"] == artifact["sha256"],
                    "IDENTITY_MISMATCH", point)
            hash_bytes(evidence.get(point), proof["sha256"], point,
                       "ARTIFACT_UNVERIFIED", "ARTIFACT_CHANGED")
            require(proof["sha256"] not in used_evidence, "MATRIX_POINT_DUPLICATE", point)
            used_evidence.add(proof["sha256"])
            receipt = strict_json(evidence[point], point)
            wanted = {**bindings, "artifactSha256": artifact["sha256"],
                      "osVersion": cell["osVersion"], "osBuild": build,
                      "native": True, "packaged": True, "sqlite": sqlite,
                      "events": {event: {"observed": True, "ownedPurge": True}
                                 for event in EVENTS}}
            require(exact(receipt, wanted), "ARTIFACT_UNVERIFIED", point)
        if sqlite is None:
            expected.append("SQLITE_PROVENANCE_MISSING")
        else:
            require(proof is not None, "ARTIFACT_UNVERIFIED", point)
            sqlite_proof(sqlite, build, point)
        require(blockers == expected, "IDENTITY_MISMATCH", point)
        require(status != "verified" or not expected, "ARTIFACT_UNVERIFIED", point)
        require(status != "blocked" or bool(expected), "IDENTITY_MISMATCH", point)
        diagnostics.extend(diagnostic(code, point) for code in expected)
    require(seen == set(POINTS), "MATRIX_POINT_MISSING", "/matrix")
    return sorted(diagnostics, key=lambda item: (item["pointerOrPoint"], item["code"]))


def validate(lock_bytes, matrix_bytes, source_bytes, artifacts=None, evidence=None):
    """Pure API: inputs are bytes, never paths. Even complete fixtures exit 2."""
    try:
        validate_lock(lock_bytes)
        matrix = strict_json(matrix_bytes, "/matrix")
        diagnostics = validate_matrix(matrix, lock_bytes, source_bytes, artifacts, evidence)
        return 2, {"conformant": True, "promotion": "not_promoted",
                   "diagnostics": diagnostics}
    except Invalid as failure:
        return 1, {"conformant": False, "promotion": "not_promoted",
                   "diagnostics": [failure.diagnostic]}
    except (TypeError, ValueError, RecursionError, OverflowError):
        return 1, {"conformant": False, "promotion": "not_promoted",
                   "diagnostics": [diagnostic("IDENTITY_MISMATCH", "/matrix")]}


def json_bytes(value):
    return (json.dumps(value, sort_keys=True, indent=2) + "\n").encode("utf-8")


def read_bytes(path, pointer):
    try:
        return Path(path).read_bytes()
    except (OSError, ValueError, TypeError):
        raise Invalid("LOCK_INPUT_MISSING", pointer) from None


def main(argv=None):
    """Usage: validate_dependency_lock.py [validate|write-candidate] [lock matrix].

    CLI validates the blocked candidate. Supplied artifact/evidence bytes use the
    pure API, avoiding untrusted path strings in durable evidence or diagnostics.
    write-candidate is the parent-only construction step, not a gate or promotion.
    """
    argv = list(sys.argv[1:] if argv is None else argv)
    here = Path(__file__).resolve().parent
    try:
        require(len(argv) in (0, 1, 3), "IDENTITY_MISMATCH", "/matrix")
        mode = argv[0] if argv else "validate"
        require(mode in ("validate", "write-candidate"), "IDENTITY_MISMATCH", "/matrix")
        lock_path, matrix_path = (argv[1:] if len(argv) == 3 else
                                 (here / "dependencies.json", here / "runtime-matrix.json"))
        lock = read_bytes(lock_path, "/lock")
        source = read_bytes(__file__, "/source")
        if mode == "write-candidate":
            matrix = json_bytes(candidate_matrix(lock, source))
            # Exclusive creation protects historical outputs and existing work.
            try:
                with Path(matrix_path).open("xb") as stream:
                    stream.write(matrix)
            except (OSError, ValueError, TypeError):
                raise Invalid("IDENTITY_MISMATCH", "/matrix") from None
        else:
            matrix = read_bytes(matrix_path, "/matrix")
        code, result = validate(lock, matrix, source)
    except Invalid as failure:
        code, result = 1, {"conformant": False, "promotion": "not_promoted",
                           "diagnostics": [failure.diagnostic]}
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return code


if __name__ == "__main__":
    raise SystemExit(main())
