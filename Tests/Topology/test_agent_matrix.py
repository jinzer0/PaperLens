"""Synthetic assertion tests, never signed/SDK/native execution evidence."""
import copy
from dataclasses import FrozenInstanceError, replace
import json
from pathlib import Path
import sys
import unittest
from unittest.mock import patch
from uuid import uuid4

SCRIPTS = Path(__file__).resolve().parents[2] / "scripts/topology"
sys.path.insert(0, str(SCRIPTS))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import verify_agent_matrix as agent
import verify_packaged_db as db
from test_packaged_db import fixture, leaves, at


def db_input(point, run, owner):
    record, expected, supplied = fixture(point, run, owner)
    return agent.DBInput(db.json_bytes(record), expected, supplied)


def rebound_db(value, **changes):
    """Owner independently changes actual bytes; rebuild upstream closed receipt."""
    supplied = replace(value.supplied, **changes)
    expected = replace(value.expected, **{k: db.digest(v) for k, v in changes.items()})
    bindings = db.expected_bindings(expected)
    del bindings["receipt"]
    receipt = db.json_bytes({"bindings": bindings})
    supplied = replace(supplied, receipt=receipt)
    expected = replace(expected, receipt=db.digest(receipt))
    record = db.bounded_json(value.record)
    record["bindings"] = db.expected_bindings(expected)
    return agent.DBInput(db.json_bytes(record), expected, supplied)


def seal(expected, supplied, state="positive", phases=None):
    bindings = agent.expected_bindings(expected)
    del bindings["receipt"]
    receipt = db.json_bytes({"bindings": bindings})
    expected = replace(expected, receipt=db.digest(receipt))
    supplied = replace(supplied, receipt=receipt)
    record = {"schemaRevision": agent.SCHEMA, "bindings": agent.expected_bindings(expected),
              "point": expected.db.expected.point, "event": expected.event, "state": state,
              "phases": agent.required_phases(expected) if phases is None else phases}
    return db.json_bytes(record), expected, supplied


def row(value, event):
    code, nested, spec = b"synthetic agent code", b"synthetic nested code", b"committed agent spec"
    expected = agent.OwnerExpectedBindings(
        db=value, event=event, attempt=str(uuid4()), lineage=str(uuid4()), paper=str(uuid4()),
        generation=1, correlation=str(uuid4()), agentCode=db.digest(code), nestedCode=db.digest(nested),
        spec=db.digest(spec), receipt=db.digest(b"initial independent receipt"))
    supplied = agent.SuppliedBytes(code, nested, spec, b"initial independent receipt")
    if event == "replacement":
        post = db_input(value.expected.point, value.expected.run, value.expected.owner)
        post = rebound_db(post, code=b"actual replacement code", package=b"actual replacement package")
        r = agent.ReplacementBindings(expected.agentCode, value.expected.package,
                                      post.expected.code, post.expected.package, post)
        s = agent.ReplacementBytes(code, value.supplied.package, post.supplied.code, post.supplied.package)
        expected, supplied = replace(expected, replacement=r), replace(supplied, replacement=s)
    return seal(expected, supplied)


def matrix(points=db.POINTS):
    run, owner = str(uuid4()), str(uuid4())
    inputs = tuple(db_input(p, run, owner) for p in points)
    rows = [row(d, event) for d in inputs for event in agent.EVENTS]
    return tuple(r[0] for r in rows), tuple(r[1] for r in rows), tuple(r[2] for r in rows), inputs


class AgentMatrixTests(unittest.TestCase):
    def setUp(self):
        self.records, self.expected, self.supplied, self.inputs = matrix()

    def check(self, result, conformant=False, positive=False):
        code, output = result
        self.assertEqual(code, 2 if conformant else 1)
        self.assertIs(output["conformant"], conformant)
        self.assertIs(output["positiveAssertions"], positive)
        self.assertEqual(output["status"], "blocked")
        self.assertIs(output["storyDone"], False)
        self.assertIs(output["p2Passed"], False)
        self.assertEqual(output["promotion"], "not_promoted")
        self.assertEqual(set(output), {"schemaRevision", "conformant", "coverage", "positiveAssertions",
                                     "status", "storyDone", "p2Passed", "promotion", "diagnostics"} |
                         ({"rows"} if "rows" in output else set()))
        for diagnostic in output["diagnostics"]:
            self.assertIn(diagnostic["reason"], agent.REASONS)
            self.assertIn(diagnostic["point"], (None,) + db.POINTS)
            self.assertIn(diagnostic["event"], (None,) + agent.EVENTS)
        return output

    def validate(self, records=None, expected=None, supplied=None, inputs=None):
        return agent.validate_matrix(self.records if records is None else records,
                                     self.expected if expected is None else expected,
                                     self.supplied if supplied is None else supplied,
                                     self.inputs if inputs is None else inputs)

    def test_ten_individual_rows_two_arm64_executions_never_authenticate(self):
        self.assertEqual(agent.POINTS, ("minimum/arm64", "current/arm64"))
        self.assertEqual(tuple((e.db.expected.point, e.event) for e in self.expected),
                         tuple((point, event) for point in agent.POINTS for event in agent.EVENTS))
        for r, e, s in zip(self.records, self.expected, self.supplied):
            output = self.check(agent.validate_row(r, e, s), True, True)
            self.assertTrue(output["coverage"])
        output = self.check(self.validate(), True, True)
        self.assertTrue(output["coverage"])
        self.assertEqual(len(output["rows"]), 10)
        self.assertEqual(len(self.inputs), 2)
        self.assertNotEqual(self.inputs[0].expected.attempt, self.inputs[1].expected.attempt)
        self.assertEqual(self.inputs[0].expected.artifact, self.inputs[1].expected.artifact)
        self.assertEqual(self.validate(), self.validate())

    def test_frozen_authority_and_exact_input_types(self):
        with self.assertRaises(FrozenInstanceError):
            self.expected[0].generation = 2
        for index in range(4):
            args = [self.records, self.expected, self.supplied, self.inputs]
            args[index] = list(args[index])
            self.check(agent.validate_matrix(*args))
        for bad in (None, {}, object()):
            self.check(agent.validate_row(self.records[0], bad, self.supplied[0]))
            self.check(agent.validate_row(self.records[0], self.expected[0], bad))
        for generation in (True, 0, -1, 2147483648, "1"):
            e = replace(self.expected[0], generation=generation)
            r, e, s = seal(e, self.supplied[0])
            self.check(agent.validate_row(r, e, s))

    def test_missing_extra_reordered_duplicate_unknown_rows_and_db_inputs(self):
        for indices in (tuple(range(9)), tuple(range(10)) + (0,),
                        tuple(range(5)), tuple(range(5, 10)),
                        (1, 0) + tuple(range(2, 10)), (0, 0) + tuple(range(2, 10))):
            self.check(self.validate(tuple(self.records[i] for i in indices),
                                     tuple(self.expected[i] for i in indices),
                                     tuple(self.supplied[i] for i in indices)))
        for inputs in (self.inputs[:-1], self.inputs + (self.inputs[0],),
                       (self.inputs[1], self.inputs[0], *self.inputs[2:]),
                       (self.inputs[0], self.inputs[0], *self.inputs[2:])):
            self.check(self.validate(inputs=inputs))
        for name, value in (("event", "invented"), ("point", "foreign/arm64")):
            record = db.bounded_json(self.records[0])
            record[name] = value
            self.check(agent.validate_row(db.json_bytes(record), self.expected[0], self.supplied[0]))

    def test_intel_extra_and_legacy_twenty_row_matrices_are_rejected(self):
        legacy = ("minimum/arm64", "minimum/x86_64", "current/arm64", "current/x86_64")
        for points in (legacy, ("minimum/x86_64", "current/x86_64"),
                       ("minimum/arm64", "current/x86_64"),
                       ("minimum/x86_64", "current/arm64"),
                       agent.POINTS + ("current/x86_64",),
                       ("minimum/arm64", "minimum/arm64"),
                       ("current/arm64", "current/arm64")):
            with self.subTest(points=points):
                records, expected, supplied, inputs = matrix(points)
                self.check(agent.validate_matrix(records, expected, supplied, inputs))
                for r, e, s in zip(records, expected, supplied):
                    if e.db.expected.point.endswith("/x86_64"):
                        self.check(agent.validate_row(r, e, s))

    def test_unavailable_failed_and_positive_coverage_are_distinct(self):
        for index, (r, e, s) in enumerate(zip(self.records, self.expected, self.supplied)):
            phases = agent.required_phases(e)
            for state, observations in (
                ("unavailable", [{"phase": "unavailable", "reason": "native_unapproved"}]),
                ("failed", phases[:-1] + [{"phase": "cleanup", "reason": "cleanup_failed"}])):
                r2, e2, s2 = seal(e, s, state, observations)
                self.check(agent.validate_row(r2, e2, s2), True)
                records, expected, supplied = list(self.records), list(self.expected), list(self.supplied)
                records[index], expected[index], supplied[index] = r2, e2, s2
                self.check(self.validate(tuple(records), tuple(expected), tuple(supplied)), True)
        failure = db.bounded_json(self.records[1])
        self.assertEqual(failure["phases"][1]["failureType"], "provider")
        self.check(agent.validate_row(self.records[1], self.expected[1], self.supplied[1]), True, True)
        failure["phases"][1]["failureType"] = "cleanup_failed"
        self.check(agent.validate_row(db.json_bytes(failure), self.expected[1], self.supplied[1]))
        for state, phases in (("positive", []), ("failed", []),
                              ("unavailable", [{"phase": "unavailable", "reason": "PRIVATE-reason"}]),
                              ("unavailable", [{"phase": "unavailable", "reason": True}]),
                              ("failed", [{"phase": "marker_present", "reason": "cleanup_failed", "extra": True}]),
                              ("unavailable", agent.required_phases(self.expected[0])[:1] +
                               [{"phase": "unavailable", "reason": "native_unapproved"}]),
                              ("failed", [{"phase": "cleanup", "reason": "cleanup_failed"}])):
            r, e, s = seal(self.expected[0], self.supplied[0], state, phases)
            self.check(agent.validate_row(r, e, s))

    def test_conformant_unavailable_db_cannot_fill_positive_agent_assertions(self):
        value = self.inputs[0]
        record = db.bounded_json(value.record)
        record["phases"] = [{"phase": "unavailable", "reason": "grdb_unavailable", "sqliteCode": None}]
        value = replace(value, record=db.json_bytes(record))
        self.assertEqual(db.validate_cell(value.record, value.expected, value.supplied)[0], 2)
        rows = [row(value if i < 5 else self.inputs[i // 5], agent.EVENTS[i % 5]) for i in range(10)]
        for r, e, s in rows:
            self.check(agent.validate_row(r, e, s), True, e.db != value)
        inputs = (value,) + self.inputs[1:]
        self.check(agent.validate_matrix(tuple(r[0] for r in rows), tuple(r[1] for r in rows),
                                         tuple(r[2] for r in rows), inputs), True)

    def test_upstream_scope_and_typed_injected_failure_policy_consumed(self):
        for scope in db.SCOPES:
            value = self.inputs[0]
            record = db.bounded_json(value.record)
            record["scope"] = scope
            for phase in record["phases"]:
                if phase["phase"] == "injected_failure":
                    phase["sqliteCode"] = 5
            value = replace(value, record=db.json_bytes(record))
            self.assertEqual(db.validate_cell(value.record, value.expected, value.supplied)[0], 2)
            r, e, s = row(value, "failure")
            self.check(agent.validate_row(r, e, s), True, scope == "packaged_db_fts5")
        # A full ordered denominator is not proof of complete positive observations.
        records = list(self.records)
        record = db.bounded_json(records[0])
        record["phases"] = []
        records[0] = db.json_bytes(record)
        output = self.check(self.validate(records=tuple(records)))
        self.assertTrue(output["coverage"])

    def test_every_phase_leaf_is_asserted_with_exact_order_and_types(self):
        for r, e, s in zip(self.records, self.expected, self.supplied):
            self.check(agent.validate_row(r, e, s), True, True)
            record = db.bounded_json(r)
            phases = record["phases"]
            for path, value in leaves(phases):
                changed = copy.deepcopy(record)
                parent = at(changed["phases"], path[:-1])
                parent[path[-1]] = (1 if type(value) is bool else False if type(value) is int
                                   else "private-wrong-value")
                with self.subTest(event=e.event, path=path):
                    self.check(agent.validate_row(db.json_bytes(changed), e, s))
            for changed_phases in (phases[::-1], phases[1:], phases + [phases[-1]],
                                   [phases[0]] * 12, [phases[0]] * 13):
                changed = copy.deepcopy(record)
                changed["phases"] = changed_phases
                self.check(agent.validate_row(db.json_bytes(changed), e, s))

    def test_closed_schema_and_receipts_exclude_own_hash(self):
        for r, e, s in zip(self.records, self.expected, self.supplied):
            self.assertNotIn("receipt", db.bounded_json(s.receipt)["bindings"])
            record = db.bounded_json(r)
            for key in ("authentic", "approval", "PASS", "promotion", "rawPath"):
                changed = copy.deepcopy(record)
                changed[key] = True
                self.check(agent.validate_row(db.json_bytes(changed), e, s))
            changed = copy.deepcopy(record)
            del changed["bindings"]["specCommit"]
            self.check(agent.validate_row(db.json_bytes(changed), e, s))
            receipt = db.bounded_json(s.receipt)
            receipt["bindings"]["receipt"] = e.receipt
            actual = db.json_bytes(receipt)
            e2, s2 = replace(e, receipt=db.digest(actual)), replace(s, receipt=actual)
            record["bindings"] = agent.expected_bindings(e2)
            self.check(agent.validate_row(db.json_bytes(record), e2, s2))

    def test_independently_rebound_execution_reuse_rejected_after_per_row_conformance(self):
        for name in ("attempt", "lineage", "correlation"):
            e = replace(self.expected[5], **{name: getattr(self.expected[0], name)})
            r, e, s = seal(e, self.supplied[5])
            self.check(agent.validate_row(r, e, s), True, True)
            records, expected, supplied = list(self.records), list(self.expected), list(self.supplied)
            records[5], expected[5], supplied[5] = r, e, s
            self.check(self.validate(tuple(records), tuple(expected), tuple(supplied)))
        # A valid independently rebound foreign DB row must not transfer into another cell.
        r, e, s = row(self.inputs[1], "success")
        self.check(agent.validate_row(r, e, s), True, True)
        self.check(self.validate((r,) + self.records[1:], (e,) + self.expected[1:],
                                 (s,) + self.supplied[1:]))

    def test_independently_rebound_db_owner_attempt_and_artifact_matrix_rules(self):
        for name in ("owner", "attempt", "receipt"):
            foreign = db_input(self.inputs[0].expected.point, self.inputs[0].expected.run,
                               str(uuid4()) if name == "owner" else self.inputs[0].expected.owner)
            r, e, s = row(foreign, "success")
            self.check(agent.validate_row(r, e, s), True, True)
            self.check(self.validate((r,) + self.records[1:], (e,) + self.expected[1:],
                                     (s,) + self.supplied[1:]))
        for mode in ("distinct-artifacts", "shared-artifact"):
            inputs = tuple(rebound_db(d, artifact=(d.expected.point.encode() if mode == "distinct-artifacts"
                                                   else b"PRIVATE independently supplied arm64 artifact")) for d in self.inputs)
            rows = [row(d, event) for d in inputs for event in agent.EVENTS]
            for r, e, s in rows:
                self.check(agent.validate_row(r, e, s), True, True)
            self.check(agent.validate_matrix(tuple(r[0] for r in rows), tuple(r[1] for r in rows),
                                             tuple(r[2] for r in rows), inputs),
                       mode == "shared-artifact", mode == "shared-artifact")
        lock = db.bounded_json(self.inputs[0].supplied.lock)
        lock["unapproved"] = True
        invalid = rebound_db(self.inputs[0], lock=db.json_bytes(lock))
        r, e, s = row(invalid, "success")
        self.check(agent.validate_row(r, e, s))
        r, e, s = self.records[0], self.expected[0], self.supplied[0]
        actual = self.supplied[5].receipt
        e2, s2 = replace(e, receipt=db.digest(actual)), replace(s, receipt=actual)
        record = db.bounded_json(r)
        record["bindings"] = agent.expected_bindings(e2)
        self.check(agent.validate_row(db.json_bytes(record), e2, s2))

    def test_actual_byte_substitutions_and_independent_owner_mismatch(self):
        for r, e, s in zip(self.records, self.expected, self.supplied):
            for name in ("agentCode", "nestedCode", "spec", "receipt"):
                for actual in (b"", b"private foreign actual bytes", None, "not bytes"):
                    self.check(agent.validate_row(r, e, replace(s, **{name: actual})))
                record = db.bounded_json(r)
                record["bindings"][name] = db.digest(b"foreign rehashed bytes")
                self.check(agent.validate_row(db.json_bytes(record), e, s))
            for name in ("attempt", "lineage", "paper", "correlation"):
                self.check(agent.validate_row(r, replace(e, **{name: str(uuid4())}), s))
            for name in db.BYTE_FIELDS:
                supplied = replace(e.db.supplied, **{name: b"foreign DB bytes"})
                self.check(agent.validate_row(r, replace(e, db=replace(e.db, supplied=supplied)), s))
            for name in ("owner", "attempt", "lineage", "lock", "spec", "artifact", "code"):
                value = str(uuid4()) if name in ("owner", "attempt", "lineage") else db.digest(b"foreign")
                foreign = replace(e.db.expected, **{name: value})
                self.check(agent.validate_row(r, replace(e, db=replace(e.db, expected=foreign)), s))
            foreign_index = (db.POINTS.index(e.db.expected.point) + 1) % len(db.POINTS)
            foreign_record = self.inputs[foreign_index].record
            self.assertNotEqual(foreign_record, e.db.record)
            self.check(agent.validate_row(r, replace(e, db=replace(e.db, record=foreign_record)), s))

    def test_rehashed_governing_projection_cannot_override_owner_or_spec_policy(self):
        r, e, s = self.records[0], self.expected[0], self.supplied[0]
        for name, value in (("issue", 8), ("issue", True), ("specCommit", "ab" * 20),
                            ("generation", True), ("dbRecord", db.digest(self.inputs[1].record)),
                            ("event", "delete")):
            record = db.bounded_json(r)
            record["bindings"][name] = value
            receipt = copy.deepcopy(record["bindings"])
            del receipt["receipt"]
            actual = db.json_bytes({"bindings": receipt})
            e2 = replace(e, receipt=db.digest(actual))
            s2 = replace(s, receipt=actual)
            record["bindings"]["receipt"] = e2.receipt
            self.check(agent.validate_row(db.json_bytes(record), e2, s2))

    def test_replacement_bytes_and_post_db_independently_bound(self):
        r, e, s = self.records[3], self.expected[3], self.supplied[3]
        self.check(agent.validate_row(r, e, s), True, True)
        for name in ("predecessorCode", "predecessorPackage", "replacementCode", "replacementPackage"):
            bad_bytes = replace(s.replacement, **{name: b"foreign replacement bytes"})
            self.check(agent.validate_row(r, e, replace(s, replacement=bad_bytes)))
            # Even independently rehashed bytes cannot change the required predecessor/post DB links.
            binding = replace(e.replacement, **{name: db.digest(b"foreign replacement bytes")})
            r2, e2, s2 = seal(replace(e, replacement=binding), replace(s, replacement=bad_bytes))
            self.check(agent.validate_row(r2, e2, s2))
        for post in (e.db, self.inputs[1], replace(e.replacement.postDB, record=e.db.record)):
            r2, e2, s2 = seal(replace(e, replacement=replace(e.replacement, postDB=post)), s)
            self.check(agent.validate_row(r2, e2, s2))
        for missing in (None, {}):
            self.check(agent.validate_row(r, replace(e, replacement=missing), s))
            self.check(agent.validate_row(r, e, replace(s, replacement=missing)))
        self.check(agent.validate_row(self.records[0], replace(self.expected[0], replacement=e.replacement),
                                      replace(self.supplied[0], replacement=s.replacement)))

    def test_byte_limits_exact_plus_one_and_complete_input_not_prefix(self):
        for r, e, s in zip(self.records, self.expected, self.supplied):
            self.assertLessEqual(len(s.receipt), 4096)
            self.check(agent.validate_row(r + b" " * (16384 - len(r)), e, s), True, True)
            self.check(agent.validate_row(r + b" " * (16385 - len(r)), e, s))
            padded = s.receipt + b" " * (4096 - len(s.receipt))
            e2, s2 = replace(e, receipt=db.digest(padded)), replace(s, receipt=padded)
            record = db.bounded_json(r)
            record["bindings"] = agent.expected_bindings(e2)
            self.check(agent.validate_row(db.json_bytes(record), e2, s2), True, True)
            padded += b" "
            e2, s2 = replace(e, receipt=db.digest(padded)), replace(s, receipt=padded)
            record["bindings"] = agent.expected_bindings(e2)
            self.check(agent.validate_row(db.json_bytes(record), e2, s2))
            self.check(agent.validate_row(r + b"{}", e, s))
        padded_rows = tuple(r + b" " * (16384 - len(r)) for r in self.records)
        self.assertEqual(sum(map(len, padded_rows)), 163840)
        self.check(self.validate(padded_rows), True, True)
        self.check(self.validate((padded_rows[0] + b" ",) + padded_rows[1:]))
        padded_db = tuple(replace(d, record=d.record + b" " * (16384 - len(d.record))) for d in self.inputs)
        rows = [row(d, event) for d in padded_db for event in agent.EVENTS]
        self.assertEqual(sum(len(d.record) for d in padded_db), 32768)
        self.check(agent.validate_matrix(tuple(r[0] for r in rows), tuple(r[1] for r in rows),
                                         tuple(r[2] for r in rows), padded_db), True, True)
        self.check(self.validate(inputs=(replace(padded_db[0], record=padded_db[0].record + b" "),) + padded_db[1:]))

    def test_shared_parser_depth_utf8_duplicate_and_type_bounds(self):
        for depth in (8, 9):
            raw = b"[" * depth + b"0" + b"]" * depth
            if depth == 8:
                self.assertIsInstance(db.bounded_json(raw), list)
            else:
                with self.assertRaises(db.Invalid):
                    db.bounded_json(raw)
        r, e, s = self.records[0], self.expected[0], self.supplied[0]
        for raw in (b"\xff", b'{"x":1,"x":2}', b'{"x":"\\ud800"}', b'{"x":NaN}',
                    b'{"x":1.0}', b"[" * 9 + b"0" + b"]" * 9,
                    b"", "not bytes", bytearray(r)):
            self.check(agent.validate_row(raw, e, s))
        duplicate = r.replace(b'"state":"positive"', b'"state":"positive","state":"positive"')
        self.assertNotEqual(duplicate, r)
        self.check(agent.validate_row(duplicate, e, s))

    def test_private_diagnostic_sentinel_and_no_implicit_io(self):
        sentinel = "PRIVATE-owner-/secret/path-header-SDK-output"
        r, e, s = self.records[0], self.expected[0], self.supplied[0]
        for result in (agent.validate_row(sentinel.encode(), e, s),
                       agent.validate_row(r, replace(e, attempt=sentinel), s),
                       agent.validate_row(r, e, replace(s, receipt=sentinel.encode())),
                       self.validate(records=(sentinel.encode(),) + self.records[1:])):
            self.check(result)
            output = json.dumps(result[1])
            self.assertNotIn(sentinel, output)
            self.assertNotIn(e.attempt, output)
            self.assertNotIn(e.receipt, output)
            self.assertNotIn(e.db.expected.owner, output)
        # Dependency modules are already imported; fixtures are created before the fence.
        with patch("builtins.open", side_effect=AssertionError("implicit read")), \
             patch("pathlib.Path.read_bytes", side_effect=AssertionError("implicit read")), \
             patch("os.getenv", side_effect=AssertionError("environment")), \
             patch("os.listdir", side_effect=AssertionError("discovery")), \
             patch("subprocess.run", side_effect=AssertionError("process")), \
             patch("socket.socket", side_effect=AssertionError("network")), \
             patch("sqlite3.connect", side_effect=AssertionError("database")):
            self.check(self.validate(), True, True)
        self.assertNotIn("ProviderAgent.agent", sys.modules)


if __name__ == "__main__":
    unittest.main()
