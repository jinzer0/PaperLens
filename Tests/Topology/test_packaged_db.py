"""Offline adversarial conformance tests; no native/packaged certification."""
import copy
from dataclasses import replace
import json
from pathlib import Path
import sys
import unittest
from uuid import uuid4

SCRIPTS = Path(__file__).resolve().parents[2] / "scripts/topology"
sys.path.insert(0, str(SCRIPTS))
import verify_packaged_db as db
import validate_dependency_lock as dependency_lock


def fixture(point="current/arm64", run=None, owner=None):
    blobs = {name: ("synthetic approved " + name).encode() for name in db.BYTE_FIELDS}
    blobs["lock"] = (SCRIPTS / "dependencies.json").read_bytes()
    blobs["artifact"] += point.split("/")[1].encode()
    projection = db.SQLiteProjection(db.digest(b"approved image"), "3.50.4",
                                     db.digest(b"approved SQLite source"), ("ENABLE_FTS5",))
    expected = db.OwnerExpectedBindings(
        point=point, osBuild="24A335" if point.startswith("minimum/") else "25G241",
        run=run or str(uuid4()), owner=owner or str(uuid4()), attempt=str(uuid4()),
        lineage=str(uuid4()), codeCommit="12" * 20, sqlite=projection,
        **{name: db.digest(blob) for name, blob in blobs.items()})
    receipt_bindings = db.expected_bindings(expected)
    del receipt_bindings["receipt"]
    blobs["receipt"] = db.json_bytes({"bindings": receipt_bindings})
    expected = replace(expected, receipt=db.digest(blobs["receipt"]))
    sqlite = {"origin": "apple-system", "osBuild": expected.osBuild, "point": point,
              "imageIdentity": projection.imageIdentity, "sqliteVersion": projection.sqliteVersion,
              "sqliteSourceId": projection.sqliteSourceId, "compileOptions": list(projection.compileOptions),
              "sameConnection": True, "symbolsBoundToImage": True,
              "inspection": {"entries": 1, "maxEntryBytes": 11, "complete": True}}
    record = {"schemaRevision": db.SCHEMA, "scope": "packaged_db_fts5",
              "bindings": db.expected_bindings(expected), "sqlite": sqlite,
              "corpus": {"payloadByteLengths": [256] * 4, "queryByteLength": 64},
              "phases": db.required_phases(4)}
    return record, expected, db.SuppliedBytes(**blobs)


def objects(value, path=()):
    if type(value) is dict:
        yield path, value
        for key, child in value.items():
            yield from objects(child, path + (key,))
    elif type(value) is list:
        for index, child in enumerate(value):
            yield from objects(child, path + (index,))


def leaves(value, path=()):
    if type(value) is dict:
        for key, child in value.items():
            yield from leaves(child, path + (key,))
    elif type(value) is list:
        for index, child in enumerate(value):
            yield from leaves(child, path + (index,))
    else:
        yield path, value


def at(value, path):
    for key in path:
        value = value[key]
    return value


class PackagedDBTests(unittest.TestCase):
    def setUp(self):
        self.record, self.expected, self.supplied = fixture()

    def validate(self, record=None, expected=None, supplied=None):
        value = self.record if record is None else record
        return db.validate_cell(value if type(value) is bytes else db.json_bytes(value),
                                self.expected if expected is None else expected,
                                self.supplied if supplied is None else supplied)

    def check_result(self, result, conformant=False):
        code, output = result
        self.assertEqual(code, 2 if conformant else 1)
        self.assertIs(output["conformant"], conformant)
        self.assertEqual(output["status"], "blocked")
        self.assertFalse(output["storyDone"])
        self.assertFalse(output["p2Passed"])
        self.assertEqual(output["promotion"], "not_promoted")
        for diagnostic in output["diagnostics"]:
            self.assertEqual(set(diagnostic), {"reason", "phase", "sqliteCode"})
            self.assertIn(diagnostic["reason"], db.REASONS)
            self.assertIn(diagnostic["phase"], {"input", "provenance", "offline_only", "unavailable"} |
                          {p["phase"] for p in db.required_phases(1)})
            self.assertTrue(diagnostic["sqliteCode"] is None or
                            type(diagnostic["sqliteCode"]) is int and diagnostic["sqliteCode"] in db.SQLITE_CODES)

    def test_complete_assertions_all_scopes_still_not_runtime_proof(self):
        for scope in db.SCOPES:
            changed = copy.deepcopy(self.record)
            changed["scope"] = scope
            self.check_result(self.validate(changed), True)
        self.assertEqual(self.validate(), self.validate())

    def test_actual_byte_identity_every_input_not_record_hash_authority(self):
        for name in db.BYTE_FIELDS:
            for blob in (b"", b"foreign actual bytes", None, "not bytes"):
                with self.subTest(name=name, blob=blob):
                    self.check_result(self.validate(supplied=replace(self.supplied, **{name: blob})))
            changed = copy.deepcopy(self.record)
            changed["bindings"][name] = db.digest(b"foreign bytes")
            self.check_result(self.validate(changed))
            self.check_result(self.validate(expected=replace(self.expected, **{name: "f" * 64})))

    def test_rehashed_stale_inventory_rejected_by_canonical_source_authority(self):
        lock = json.loads(self.supplied.lock)
        lock["unapproved"] = True
        blob = db.json_bytes(lock)
        expected = replace(self.expected, lock=db.digest(blob))
        self.check_result(self.validate(expected=expected, supplied=replace(self.supplied, lock=blob)))

    def test_receipt_closed_and_binding_checked_even_when_owner_hash_matches(self):
        receipt = json.loads(self.supplied.receipt)
        for field, value in (("point", "minimum/x86_64"), ("native", False),
                             ("attempt", str(uuid4())), ("osBuild", "24A335")):
            changed = copy.deepcopy(receipt)
            changed["bindings"][field] = value
            blob = db.json_bytes(changed)
            expected = replace(self.expected, receipt=db.digest(blob))
            self.check_result(self.validate(expected=expected, supplied=replace(self.supplied, receipt=blob)))
        for blob in (b'{"x":1,"x":2}', b"\xff", b"{}", b"{" + b" " * 16384 + b"}"):
            self.check_result(self.validate(expected=replace(self.expected, receipt=db.digest(blob)),
                                            supplied=replace(self.supplied, receipt=blob)))

    def test_unknown_missing_keys_at_every_record_object(self):
        for path, value in objects(self.record):
            for key in value:
                changed = copy.deepcopy(self.record)
                del at(changed, path)[key]
                with self.subTest(path=path, missing=key):
                    self.check_result(self.validate(changed))
            changed = copy.deepcopy(self.record)
            at(changed, path)["PRIVATE/path/SQL"] = "SECRET"
            self.check_result(self.validate(changed))

    def test_wrong_types_every_leaf_including_bool_integer_alias(self):
        for path, original in leaves(self.record):
            if type(original) is bool:
                replacements = (int(original), None, "true")
            elif type(original) is int:
                replacements = (bool(original), float(original), None, "1")
            else:
                replacements = (None, 0, False, [])
            for replacement in replacements:
                with self.subTest(path=path, replacement=replacement):
                    changed = copy.deepcopy(self.record)
                    at(changed, path[:-1])[path[-1]] = replacement
                    self.check_result(self.validate(changed))

    def test_utf8_duplicates_nonfinite_numbers_and_surrogate_rejected(self):
        encoded = db.json_bytes(self.record)
        for prefix in (b'"scope":"local_contract_only",', b'"private":NaN,',
                       b'"private":Infinity,', b'"private":-Infinity,', b'"private":"\\ud800",'):
            self.check_result(self.validate(b"{" + prefix + encoded[1:]))
        for malformed in (b"\xff", b"\xef\xbb\xbf{}", b"{} trailing", b"[", b"null"):
            self.check_result(self.validate(malformed))
        # Duplicate keys inside nested objects also fail before projection.
        self.check_result(self.validate(encoded.replace(b'"entries":1', b'"entries":1,"entries":1')))

    def test_bytes_and_depth_exact_boundaries(self):
        encoded = db.json_bytes(self.record)
        for length in (16383, 16384):
            self.check_result(self.validate(encoded + b" " * (length - len(encoded))), True)
        self.check_result(self.validate(encoded + b" " * (16385 - len(encoded))))
        self.assertEqual(db.bounded_json(b"[" * 8 + b"0" + b"]" * 8), [[[[[[[[0]]]]]]]])
        with self.assertRaises(db.Invalid):
            db.bounded_json(b"[" * 9 + b"0" + b"]" * 9)
        self.check_result(self.validate(b"[" * 2000 + b"0" + b"]" * 2000))

    def test_corpus_and_id_n_plus_one_bounds(self):
        for field, value in (("payloadByteLengths", [1] * 5), ("payloadByteLengths", []),
                             ("payloadByteLengths", [257]), ("payloadByteLengths", [0]),
                             ("queryByteLength", 65), ("queryByteLength", 0)):
            changed = copy.deepcopy(self.record)
            changed["corpus"][field] = value
            self.check_result(self.validate(changed))
        changed = copy.deepcopy(self.record)
        changed["phases"][4]["ids"] = [1, 2, 3, 4, 5]
        self.check_result(self.validate(changed))
        for rows in range(1, 5):
            changed = copy.deepcopy(self.record)
            changed["corpus"]["payloadByteLengths"] = [1] * rows
            changed["phases"] = db.required_phases(rows)
            self.check_result(self.validate(changed), True)
        for rows in (0, 5, True, 1.0):
            with self.assertRaises(db.Invalid):
                db.required_phases(rows)

    def test_missing_order_conflict_and_phase_n_plus_one(self):
        for index in range(len(self.record["phases"])):
            changed = copy.deepcopy(self.record)
            changed["phases"].pop(index)
            self.check_result(self.validate(changed))
        for index in range(len(self.record["phases"]) - 1):
            changed = copy.deepcopy(self.record)
            phases = changed["phases"]
            phases[index], phases[index + 1] = phases[index + 1], phases[index]
            self.check_result(self.validate(changed))
        for count in (32, 33):
            changed = copy.deepcopy(self.record)
            changed["phases"] = [self.record["phases"][0]] * count
            self.check_result(self.validate(changed))

    def test_failure_atomicity_earlier_commits_unchanged_reopen_and_drain(self):
        for index, phase in enumerate(self.record["phases"]):
            if phase["phase"] in ("rollback", "failure_reopen"):
                changed = copy.deepcopy(self.record)
                changed["phases"][index]["after"]["version"] = 2
                self.check_result(self.validate(changed))
                changed = copy.deepcopy(self.record)
                changed["phases"][index]["after"]["tables"] = ["partial_or_lost_state"]
                self.check_result(self.validate(changed))
            for key in ("atomic", "drained", "ownedOnly", "sidecarsRemoved", "integrity", "sameFailedStartup"):
                if key in phase:
                    changed = copy.deepcopy(self.record)
                    changed["phases"][index][key] = False
                    self.check_result(self.validate(changed))
            for key in ("ready", "reseeded", "unresolvedOwnership"):
                if key in phase:
                    changed = copy.deepcopy(self.record)
                    changed["phases"][index][key] = True
                    self.check_result(self.validate(changed))
            for key in ("queueCount", "activeQueues"):
                if key in phase:
                    changed = copy.deepcopy(self.record)
                    changed["phases"][index][key] += 1
                    self.check_result(self.validate(changed))
        changed = copy.deepcopy(self.record)
        changed["phases"][7]["migrationsRun"] = [db.MIGRATIONS[0]]
        self.check_result(self.validate(changed))
        changed = copy.deepcopy(self.record)
        changed["phases"][8]["ids"] = [1]
        self.check_result(self.validate(changed))

    def test_fault_codes_and_closed_unavailable_reasons(self):
        for reason in db.REASONS:
            changed = copy.deepcopy(self.record)
            changed["phases"] = [{"phase": "unavailable", "reason": reason, "sqliteCode": None}]
            self.check_result(self.validate(changed), True)
        for code in db.SQLITE_CODES:
            changed = copy.deepcopy(self.record)
            for phase in changed["phases"]:
                if phase["phase"] == "injected_failure":
                    phase["sqliteCode"] = code
            self.check_result(self.validate(changed), True)
        for code in (True, 1.0, -1, 9999, "SQL/private/secret"):
            changed = copy.deepcopy(self.record)
            changed["phases"][11]["sqliteCode"] = code
            self.check_result(self.validate(changed))
        changed = copy.deepcopy(self.record)
        changed["phases"] = [{"phase": "unavailable", "reason": "PRIVATE_ERROR", "sqliteCode": 1}]
        self.check_result(self.validate(changed))

    def test_runtime_provenance_timestamp_paths_and_unapproved_fact_authority(self):
        for field, value in (("origin", "bundled"), ("imageIdentity", "/usr/lib/libsqlite3.dylib"),
                             ("sqliteSourceId", "2026-10-08 01:00:00 " + self.expected.sqlite.sqliteSourceId),
                             ("sqliteSourceId", "x" * 64), ("sameConnection", False),
                             ("symbolsBoundToImage", False), ("compileOptions", ["PRIVATE_OPTION"]),
                             ("point", "minimum/x86_64")):
            changed = copy.deepcopy(self.record)
            changed["sqlite"][field] = value
            self.check_result(self.validate(changed))
        for name in ("rawSourceID", "path", "SQL", "errorText", "duration", "dbHash", "address", "log", "argv"):
            changed = copy.deepcopy(self.record)
            changed["sqlite"][name] = "PRIVATE_SENTINEL"
            result = self.validate(changed)
            self.check_result(result)
            self.assertNotIn("PRIVATE_SENTINEL", json.dumps(result))
        for name in ("entries", "maxEntryBytes"):
            for value in (0, 257, True, 256.0):
                changed = copy.deepcopy(self.record)
                changed["sqlite"]["inspection"][name] = value
                self.check_result(self.validate(changed))
            changed = copy.deepcopy(self.record)
            changed["sqlite"]["inspection"][name] = 256
            self.check_result(self.validate(changed), True)
        changed = copy.deepcopy(self.record)
        changed["sqlite"]["inspection"]["complete"] = False
        self.check_result(self.validate(changed))
        for facts in (("ENABLE_FTS5",) * 17, ("ENABLE_FTS5", "PRIVATE_OPTION"), ("ENABLE_FTS5",) * 2):
            self.check_result(self.validate(expected=replace(self.expected,
                sqlite=replace(self.expected.sqlite, compileOptions=facts))))
        for facts in (["ENABLE_FTS5"], {"ENABLE_FTS5"}, "ENABLE_FTS5"):
            self.check_result(self.validate(expected=replace(self.expected,
                sqlite=replace(self.expected.sqlite, compileOptions=facts))))

    def test_approved_fact_limit_and_both_timestamp_free_suffix_sizes(self):
        for suffix in ("ab" * 20, "ab" * 32):
            projection = replace(self.expected.sqlite, compileOptions=dependency_lock.COMPILE_FACTS,
                                 sqliteSourceId=suffix)
            expected = replace(self.expected, sqlite=projection)
            changed = copy.deepcopy(self.record)
            changed["sqlite"]["compileOptions"] = list(dependency_lock.COMPILE_FACTS)
            changed["sqlite"]["sqliteSourceId"] = suffix
            changed["sqlite"]["inspection"]["entries"] = 16
            maximum = max(len(fact.encode("utf-8")) for fact in dependency_lock.COMPILE_FACTS)
            changed["sqlite"]["inspection"]["maxEntryBytes"] = maximum
            self.check_result(self.validate(changed, expected=expected), True)
            changed["sqlite"]["inspection"]["maxEntryBytes"] = maximum - 1
            self.check_result(self.validate(changed, expected=expected))
        for suffix in ("ab" * 21, "ab" * 33, "2026-10-08 01:00:00 " + "ab" * 20):
            self.check_result(self.validate(expected=replace(self.expected,
                sqlite=replace(self.expected.sqlite, sqliteSourceId=suffix))))

    def test_inspection_byte_maximum_must_cover_exported_fact(self):
        maximum = len("ENABLE_FTS5".encode("utf-8"))
        for reported in (1, maximum - 1, maximum):
            changed = copy.deepcopy(self.record)
            changed["sqlite"]["inspection"]["maxEntryBytes"] = reported
            self.check_result(self.validate(changed), reported == maximum)

    def test_missing_build_and_materialization_never_become_proof(self):
        self.check_result(db.validate_cell(db.json_bytes(self.record),
                         dict(self.record["bindings"]), self.supplied))
        self.check_result(self.validate(supplied=replace(self.supplied, grdbSource=b"")))
        changed, expected, supplied = fixture("minimum/arm64")
        expected = replace(expected, osBuild=None)
        receipt_bindings = db.expected_bindings(expected)
        del receipt_bindings["receipt"]
        receipt = db.json_bytes({"bindings": receipt_bindings})
        expected = replace(expected, receipt=db.digest(receipt))
        supplied = replace(supplied, receipt=receipt)
        changed["bindings"] = db.expected_bindings(expected)
        changed["sqlite"]["osBuild"] = None
        self.check_result(self.validate(changed, expected, supplied), True)

    def test_owner_uuid_native_cell_and_copied_lineage_bindings(self):
        for name in ("run", "owner", "attempt", "lineage"):
            for value in (str(uuid4()), "00000000-0000-0000-0000-000000000000", 1):
                changed = copy.deepcopy(self.record)
                changed["bindings"][name] = value
                self.check_result(self.validate(changed))
            self.check_result(self.validate(expected=replace(self.expected, **{name: "not_uuid"})))
        for name, value in (("native", False), ("translated", True), ("hardwareCPU", "x86_64"),
                            ("processCPU", "x86_64"), ("artifactCPU", "x86_64"),
                            ("point", "minimum/arm64"), ("specCommit", "ab" * 20),
                            ("grdbCommit", "ab" * 20), ("grdbVersion", "0.0.0")):
            changed = copy.deepcopy(self.record)
            changed["bindings"][name] = value
            self.check_result(self.validate(changed))
        foreign, _, _ = fixture()
        self.check_result(self.validate(foreign))

    def test_four_cell_aggregate_exact_bounds_distinct_attempts_and_nonpromotion(self):
        run, owner = str(uuid4()), str(uuid4())
        fixtures = [fixture(point, run, owner) for point in db.POINTS]
        records = tuple(db.json_bytes(f[0]) for f in fixtures)
        expected = tuple(f[1] for f in fixtures)
        supplied = tuple(f[2] for f in fixtures)
        self.assertEqual(len({e.artifact for e in expected}), 2)
        self.check_result(db.validate_matrix(records, expected, supplied), True)
        padded = tuple(r + b" " * (16384 - len(r)) for r in records)
        self.assertEqual(sum(map(len, padded)), 65536)
        self.check_result(db.validate_matrix(padded, expected, supplied), True)
        self.check_result(db.validate_matrix((padded[0] + b" ",) + padded[1:], expected, supplied))
        for size in (3, 5):
            self.check_result(db.validate_matrix((records * 2)[:size], (expected * 2)[:size], (supplied * 2)[:size]))
        self.check_result(db.validate_matrix(records[::-1], expected, supplied))
        self.check_result(db.validate_matrix(records, expected[::-1], supplied))
        for name in ("attempt", "lineage", "artifact", "receipt"):
            changed = (expected[0], replace(expected[1], **{name: getattr(expected[0], name)}), *expected[2:])
            self.check_result(db.validate_matrix(records, changed, supplied))
        self.check_result(db.validate_matrix(list(records), expected, supplied))

    def test_artifact_pairing_rejects_rebound_four_artifacts_and_cross_cpu_alias(self):
        for variant in ("four-artifacts", "cross-cpu-alias", "current/arm64", "current/x86_64"):
            with self.subTest(variant=variant):
                run, owner = str(uuid4()), str(uuid4())
                fixtures = []
                for point in db.POINTS:
                    record, expected, supplied = fixture(point, run, owner)
                    artifact = supplied.artifact
                    if variant == "four-artifacts" or variant == point:
                        artifact = ("approved " + point).encode()
                    elif variant == "cross-cpu-alias":
                        artifact = b"same artifact"
                    expected = replace(expected, artifact=db.digest(artifact))
                    bindings = db.expected_bindings(expected)
                    del bindings["receipt"]
                    receipt = db.json_bytes({"bindings": bindings})
                    expected = replace(expected, receipt=db.digest(receipt))
                    supplied = replace(supplied, artifact=artifact, receipt=receipt)
                    record["bindings"] = db.expected_bindings(expected)
                    self.check_result(db.validate_cell(db.json_bytes(record), expected, supplied), True)
                    fixtures.append((db.json_bytes(record), expected, supplied))
                self.check_result(db.validate_matrix(
                    tuple(f[0] for f in fixtures), tuple(f[1] for f in fixtures),
                    tuple(f[2] for f in fixtures)))

    def test_no_input_or_exception_echo(self):
        for value in (None, 4, "PRIVATE/path", b'{"PRIVATE_key":"PRIVATE/path"}'):
            result = db.validate_cell(value, self.expected, self.supplied)
            self.check_result(result)
            serialized = json.dumps(result)
            for secret in ("PRIVATE", "TypeError", "ValueError", "Unicode", "Traceback"):
                self.assertNotIn(secret, serialized)


if __name__ == "__main__":
    unittest.main()
