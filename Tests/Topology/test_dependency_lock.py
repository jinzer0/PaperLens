"""Pure offline candidate-lock conformance tests; no runtime/promotion evidence."""
import contextlib
import copy
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

SCRIPTS = Path(__file__).resolve().parents[2] / "scripts/topology"
sys.path.insert(0, str(SCRIPTS))
import validate_dependency_lock as lock_validator


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


class DependencyLockTests(unittest.TestCase):
    def setUp(self):
        self.lock_bytes = (SCRIPTS / "dependencies.json").read_bytes()
        self.lock = json.loads(self.lock_bytes)
        self.source = b"synthetic actual source bytes\n"
        self.matrix = lock_validator.candidate_matrix(self.lock_bytes, self.source)

    def validate(self, matrix=None, lock=None, source=None, artifacts=None, evidence=None):
        return lock_validator.validate(
            self.lock_bytes if lock is None else lock,
            lock_validator.json_bytes(self.matrix if matrix is None else matrix),
            self.source if source is None else source, artifacts, evidence)

    def invalid(self, result, code=None):
        status, output = result
        self.assertEqual(status, 1)
        self.assertFalse(output["conformant"])
        self.assertEqual(output["promotion"], "not_promoted")
        self.assertTrue(output["diagnostics"])
        if code:
            self.assertEqual(output["diagnostics"][0]["code"], code)
        for item in output["diagnostics"]:
            self.assertEqual(set(item), {"code", "pointerOrPoint", "cause", "retestCondition"})
            self.assertIn(item["code"], lock_validator.CODES)
            self.assertIn(item["pointerOrPoint"], lock_validator.POINTERS)
            self.assertEqual(item["cause"], lock_validator.CAUSES[item["code"]])
            self.assertEqual(item["retestCondition"], lock_validator.RETEST[item["code"]])

    def test_initial_candidate_is_exactly_four_blocked_points(self):
        code, output = self.validate()
        self.assertEqual(code, 2)
        self.assertTrue(output["conformant"])
        self.assertEqual(output["promotion"], "not_promoted")
        cells = self.matrix["cells"]
        self.assertEqual([c["osRole"] + "/" + c["cpu"] for c in cells],
                         list(lock_validator.POINTS))
        self.assertEqual([c["status"] for c in cells],
                         ["blocked", "blocked", "not_run", "blocked"])
        self.assertEqual([c["osBuild"] for c in cells], [None, None, "25G241", "25G241"])
        for cell in cells:
            self.assertIsNone(cell["artifact"])
            self.assertIsNone(cell["evidence"])
            self.assertIsNone(cell["sqlite"])
            for missing in ("ARTIFACT_MISSING", "ARTIFACT_UNVERIFIED", "SQLITE_PROVENANCE_MISSING"):
                self.assertIn(missing, cell["blockers"])
        self.assertIn("MIN_OS_BUILD_UNPINNED", cells[0]["blockers"])
        self.assertIn("NATIVE_EXEC_UNAVAILABLE", cells[1]["blockers"])
        self.assertIn("PACKAGED_PROOF_NOT_RUN", cells[2]["blockers"])
        self.assertIn("NATIVE_EXEC_UNAVAILABLE", cells[3]["blockers"])
        self.assertNotIn("P1", json.dumps(output))
        self.assertNotIn("P2", json.dumps(output))

    def test_every_inventory_leaf_identity_and_exact_type_is_pinned(self):
        # Covers metadata, toolchain, all source/patch pins, generations,
        # CIPD instances, GN args, every wheel and both CPU assets.
        for path, original in leaves(self.lock):
            for replacement in (None, 0 if type(original) is bool else False,
                                "f" * 64 if type(original) is str else "changed"):
                with self.subTest(path=path, replacement=replacement):
                    changed = copy.deepcopy(self.lock)
                    at(changed, path[:-1])[path[-1]] = replacement
                    self.invalid(self.validate(lock=lock_validator.json_bytes(changed)),
                                 "LOCK_INPUT_CHANGED")

    def test_canonical_identity_ignores_format_but_preserves_numeric_types(self):
        compact = json.dumps(self.lock, separators=(",", ":")).encode("utf-8")
        reordered = json.dumps(dict(reversed(list(self.lock.items()))), indent=4).encode("utf-8")
        for encoded in (compact, reordered):
            self.assertEqual(lock_validator.validate_lock(encoded), self.lock)
        changed_any = False
        for path, value in leaves(self.lock):
            if type(value) in (bool, int):
                for replacement in (int(value), float(value)):
                    if type(replacement) is type(value):
                        continue
                    changed = copy.deepcopy(self.lock)
                    at(changed, path[:-1])[path[-1]] = replacement
                    self.invalid(self.validate(lock=lock_validator.json_bytes(changed)),
                                 "LOCK_INPUT_CHANGED")
                changed_any = True
        self.assertTrue(changed_any)

    def test_missing_and_unknown_keys_at_every_inventory_object(self):
        def objects(value, path=()):
            if type(value) is dict:
                yield path, value
                for key, child in value.items():
                    yield from objects(child, path + (key,))
            elif type(value) is list:
                for index, child in enumerate(value):
                    yield from objects(child, path + (index,))

        for path, value in objects(self.lock):
            for key in value:
                with self.subTest(path=path, missing=key):
                    changed = copy.deepcopy(self.lock)
                    del at(changed, path)[key]
                    self.invalid(self.validate(lock=lock_validator.json_bytes(changed)))
            changed = copy.deepcopy(self.lock)
            at(changed, path)["PRIVATE_unknown_key"] = "PRIVATE_secret_value"
            self.invalid(self.validate(lock=lock_validator.json_bytes(changed)))

    def test_asset_inventory_cannot_be_removed_reordered_or_reused(self):
        for group in ("wheels", "clang"):
            changed = copy.deepcopy(self.lock)
            if group == "wheels":
                changed[group].reverse()
            else:
                changed[group]["x86_64"] = changed[group]["arm64"]
            self.invalid(self.validate(lock=lock_validator.json_bytes(changed)))
        for index in range(len(self.lock["wheels"])):
            changed = copy.deepcopy(self.lock)
            del changed["wheels"][index]
            self.invalid(self.validate(lock=lock_validator.json_bytes(changed)))

    def test_duplicate_json_keys_and_non_json_constants_fail_closed(self):
        for data in (b'{"secret":1,"secret":2}', b'{"secret":NaN}',
                     b'{"secret":Infinity}', b'\xff', b'[]', b'{', b'null'):
            with self.subTest(data=data):
                self.invalid(self.validate(lock=data))
                self.invalid(lock_validator.validate(self.lock_bytes, data, self.source))
        duplicate = self.lock_bytes.replace(b'"schemaRevision":',
                                           b'"schemaRevision":"topology-v1","schemaRevision":', 1)
        self.invalid(self.validate(lock=duplicate), "IDENTITY_MISMATCH")

    def test_matrix_byte_binding_not_semantic_or_self_declared(self):
        self.invalid(self.validate(lock=self.lock_bytes + b"\n"), "HASH_MISMATCH")
        self.invalid(self.validate(source=self.source + b"changed"), "HASH_MISMATCH")
        self.invalid(self.validate(source=b""), "LOCK_INPUT_MISSING")
        self.invalid(self.validate(source="not bytes"), "LOCK_INPUT_MISSING")
        for key in ("lockSha256", "sourceSha256"):
            for bad in ("0" * 64, "e" * 64, "invalid", False, None):
                matrix = copy.deepcopy(self.matrix)
                matrix[key] = bad
                self.invalid(self.validate(matrix))

    def test_exact_four_points_and_no_host_as_minimum(self):
        for index in range(4):
            matrix = copy.deepcopy(self.matrix)
            del matrix["cells"][index]
            self.invalid(self.validate(matrix), "MATRIX_POINT_MISSING")
        matrix = copy.deepcopy(self.matrix)
        matrix["cells"].append(copy.deepcopy(matrix["cells"][0]))
        self.invalid(self.validate(matrix), "MATRIX_POINT_DUPLICATE")
        matrix = copy.deepcopy(self.matrix)
        matrix["cells"][0] = copy.deepcopy(matrix["cells"][2])
        self.invalid(self.validate(matrix), "MATRIX_POINT_DUPLICATE")
        for field, value in (("osBuild", "25G241"), ("osVersion", "26.7.1"),
                             ("cpu", "rosetta"), ("osRole", "host")):
            matrix = copy.deepcopy(self.matrix)
            matrix["cells"][0][field] = value
            self.invalid(self.validate(matrix))

    def test_matrix_closed_keys_types_blockers_and_fake_promotion(self):
        for container in ((), ("cells", 0)):
            for key in at(self.matrix, container):
                matrix = copy.deepcopy(self.matrix)
                del at(matrix, container)[key]
                self.invalid(self.validate(matrix))
                matrix = copy.deepcopy(self.matrix)
                at(matrix, container)[key] = 0
                self.invalid(self.validate(matrix))
            matrix = copy.deepcopy(self.matrix)
            at(matrix, container)["PRIVATE_secret_path"] = "/private/SECRET"
            self.invalid(self.validate(matrix))
        for status in ("verified", "PASS", True):
            matrix = copy.deepcopy(self.matrix)
            matrix["cells"][0]["status"] = status
            self.invalid(self.validate(matrix))
        for key, value in (("promotion", "promoted"), ("specCommit", "a" * 40),
                           ("schemaRevision", "runtime-matrix-v2")):
            matrix = copy.deepcopy(self.matrix)
            matrix[key] = value
            self.invalid(self.validate(matrix))
        for blockers in ([], ["PRIVATE_secret"], ["ARTIFACT_MISSING"] * 2, None):
            matrix = copy.deepcopy(self.matrix)
            matrix["cells"][0]["blockers"] = blockers
            self.invalid(self.validate(matrix))

    def complete_fixture(self):
        matrix = copy.deepcopy(self.matrix)
        artifacts, evidence = {}, {}
        for cell in matrix["cells"]:
            point = cell["osRole"] + "/" + cell["cpu"]
            cell["osBuild"] = "24A335" if cell["osRole"] == "minimum" else "25G241"
            cell["status"] = "verified"
            cell["blockers"] = []
            artifacts[point] = ("actual synthetic packaged bytes " + point).encode()
            bindings = {"point": point, "lockSha256": matrix["lockSha256"],
                        "sourceSha256": matrix["sourceSha256"]}
            artifact_hash = lock_validator.digest(artifacts[point])
            cell["artifact"] = {**bindings, "sha256": artifact_hash}
            cell["sqlite"] = {
                "origin": "apple-system", "osBuild": cell["osBuild"], "point": point,
                "imageIdentity": lock_validator.digest(("system image " + point).encode()),
                "sqliteVersion": "3.50.0",
                "sqliteSourceId": "ab" * 20,
                "compileOptions": ["ENABLE_FTS5"], "grdbOpen": True,
                "orderedMigration": True, "fts5Create": True,
                "fts5Query": True, "fts5Delete": True,
            }
            receipt = {**bindings, "artifactSha256": artifact_hash,
                       "osVersion": cell["osVersion"], "osBuild": cell["osBuild"],
                       "native": True, "packaged": True, "sqlite": cell["sqlite"],
                       "events": {event: {"observed": True, "ownedPurge": True}
                                  for event in lock_validator.EVENTS}}
            evidence[point] = lock_validator.json_bytes(receipt)
            cell["evidence"] = {**bindings, "artifactSha256": artifact_hash,
                                "sha256": lock_validator.digest(evidence[point])}
        return matrix, artifacts, evidence

    def test_complete_synthetic_bytes_are_only_conformance_never_promotion(self):
        matrix, artifacts, evidence = self.complete_fixture()
        code, output = self.validate(matrix, artifacts=artifacts, evidence=evidence)
        self.assertEqual(code, 2)
        self.assertEqual(output, {"conformant": True, "promotion": "not_promoted",
                                  "diagnostics": []})
        self.assertNotIn("P1", json.dumps(output))
        self.assertNotIn("P2", json.dumps(output))

    def test_sqlite_source_identity_excludes_raw_timestamp_even_in_bound_receipt(self):
        for source_id in ("2026-01-01 00:00:00 " + "ab" * 20,
                          "ab" * 21, "/private/SECRET"):
            matrix, artifacts, evidence = self.complete_fixture()
            cell = matrix["cells"][2]
            point = "current/arm64"
            cell["sqlite"]["sqliteSourceId"] = source_id
            receipt = json.loads(evidence[point])
            receipt["sqlite"] = cell["sqlite"]
            evidence[point] = lock_validator.json_bytes(receipt)
            cell["evidence"]["sha256"] = lock_validator.digest(evidence[point])
            result = self.validate(matrix, artifacts=artifacts, evidence=evidence)
            self.invalid(result, "IDENTITY_MISMATCH")
            self.assertNotIn(source_id, json.dumps(result))

    def test_compile_fact_policy_in_rehashed_bound_receipts(self):
        cases = ((list(lock_validator.COMPILE_FACTS), True),
                 (list(lock_validator.COMPILE_FACTS) + ["PRIVATE_FACT"], False),
                 (["ENABLE_FTS5", "PRIVATE_DOCUMENT_SENTINEL"], False),
                 (["ENABLE_FTS5", "UNKNOWN_OPTION"], False),
                 (["ENABLE_FTS5"] * 17, False),
                 (["ENABLE_FTS5", "ENABLE_FTS5"], False),
                 (["THREADSAFE=1"], False), ([], False),
                 (["ENABLE_FTS5", 1], False), ("ENABLE_FTS5", False))
        for options, accepted in cases:
            with self.subTest(options=options):
                matrix, artifacts, evidence = self.complete_fixture()
                cell = matrix["cells"][2]
                point = "current/arm64"
                cell["sqlite"]["compileOptions"] = options
                receipt = json.loads(evidence[point])
                receipt["sqlite"] = cell["sqlite"]
                evidence[point] = lock_validator.json_bytes(receipt)
                cell["evidence"]["sha256"] = lock_validator.digest(evidence[point])
                result = self.validate(matrix, artifacts=artifacts, evidence=evidence)
                if accepted:
                    self.assertEqual(result[0], 2)
                    self.assertTrue(result[1]["conformant"])
                    self.assertEqual(result[1]["promotion"], "not_promoted")
                else:
                    self.invalid(result, "IDENTITY_MISMATCH")
                    self.assertNotIn("PRIVATE_DOCUMENT_SENTINEL", json.dumps(result))

    def test_compile_fact_consumer_requires_exact_list_type(self):
        matrix, _, _ = self.complete_fixture()
        sqlite = matrix["cells"][2]["sqlite"]
        for options in (("ENABLE_FTS5",), {"ENABLE_FTS5"}, None):
            changed = copy.deepcopy(sqlite)
            changed["compileOptions"] = options
            with self.assertRaises(lock_validator.Invalid):
                lock_validator.sqlite_proof(changed, "25G241", "current/arm64")

    def test_artifact_and_evidence_bytes_are_required_and_actually_hashed(self):
        matrix, artifacts, evidence = self.complete_fixture()
        self.invalid(self.validate(matrix))
        for point in lock_validator.POINTS:
            for inputs, kind in ((artifacts, "artifact"), (evidence, "evidence")):
                for replacement in (None, b"", b"different bytes", "not bytes"):
                    changed = dict(inputs)
                    changed[point] = replacement
                    args = {"artifacts": artifacts, "evidence": evidence}
                    args[kind if kind == "evidence" else "artifacts"] = changed
                    self.invalid(self.validate(matrix, **args))
                changed = dict(inputs)
                del changed[point]
                args = {"artifacts": artifacts, "evidence": evidence}
                args[kind if kind == "evidence" else "artifacts"] = changed
                self.invalid(self.validate(matrix, **args))

    def test_cross_point_stale_lock_and_reused_proof_are_rejected(self):
        matrix, artifacts, evidence = self.complete_fixture()
        for field in ("artifact", "evidence"):
            for identity in ("point", "lockSha256", "sourceSha256"):
                changed = copy.deepcopy(matrix)
                changed["cells"][0][field][identity] = (
                    "current/arm64" if identity == "point" else lock_validator.digest(b"stale"))
                self.invalid(self.validate(changed, artifacts=artifacts, evidence=evidence))
            changed = copy.deepcopy(matrix)
            changed["cells"][1][field] = copy.deepcopy(changed["cells"][0][field])
            self.invalid(self.validate(changed, artifacts=artifacts, evidence=evidence))
        changed = copy.deepcopy(matrix)
        reused = dict(artifacts)
        reused["minimum/x86_64"] = reused["minimum/arm64"]
        changed["cells"][1]["artifact"]["sha256"] = lock_validator.digest(reused["minimum/x86_64"])
        self.invalid(self.validate(changed, artifacts=reused, evidence=evidence),
                     "MATRIX_POINT_DUPLICATE")

    def test_artifact_and_evidence_refs_have_closed_keys_and_types(self):
        matrix, artifacts, evidence = self.complete_fixture()
        for field in ("artifact", "evidence"):
            for key in matrix["cells"][0][field]:
                changed = copy.deepcopy(matrix)
                del changed["cells"][0][field][key]
                self.invalid(self.validate(changed, artifacts=artifacts, evidence=evidence))
                changed = copy.deepcopy(matrix)
                changed["cells"][0][field][key] = False
                self.invalid(self.validate(changed, artifacts=artifacts, evidence=evidence))
            changed = copy.deepcopy(matrix)
            changed["cells"][0][field]["PRIVATE_secret"] = "/private/SECRET"
            self.invalid(self.validate(changed, artifacts=artifacts, evidence=evidence))
        point = "current/arm64"
        for extra in (b'"native":true,', b'"private":NaN,'):
            changed = copy.deepcopy(matrix)
            proofs = dict(evidence)
            proofs[point] = b"{" + extra + proofs[point][1:]
            changed["cells"][2]["evidence"]["sha256"] = lock_validator.digest(proofs[point])
            self.invalid(self.validate(changed, artifacts=artifacts, evidence=proofs))

    def test_failed_packaged_point_still_blocks_and_missing_causes_cannot_be_hidden(self):
        matrix = copy.deepcopy(self.matrix)
        matrix["cells"][2]["status"] = "failed"
        matrix["cells"][2]["blockers"][0] = "PACKAGED_PROOF_FAILED"
        code, output = self.validate(matrix)
        self.assertEqual(code, 2)
        self.assertTrue(output["conformant"])
        self.assertIn("PACKAGED_PROOF_FAILED", [d["code"] for d in output["diagnostics"]])
        for index, cell in enumerate(self.matrix["cells"]):
            for blocker in cell["blockers"]:
                changed = copy.deepcopy(self.matrix)
                changed["cells"][index]["blockers"].remove(blocker)
                self.invalid(self.validate(changed))

    def test_rehashed_receipt_cannot_claim_foreign_native_or_purge_proof(self):
        matrix, artifacts, evidence = self.complete_fixture()
        point = "current/arm64"
        for field, value in (("native", False), ("packaged", False),
                             ("point", "minimum/arm64"), ("osBuild", "24A335"),
                             ("events", {"sdkSuccess": True}), ("secret", "/private/SECRET")):
            changed = copy.deepcopy(matrix)
            proofs = dict(evidence)
            receipt = json.loads(proofs[point])
            receipt[field] = value
            proofs[point] = lock_validator.json_bytes(receipt)
            changed["cells"][2]["evidence"]["sha256"] = lock_validator.digest(proofs[point])
            self.invalid(self.validate(changed, artifacts=artifacts, evidence=proofs))
        for event in lock_validator.EVENTS:
            for field in ("observed", "ownedPurge"):
                changed = copy.deepcopy(matrix)
                proofs = dict(evidence)
                receipt = json.loads(proofs[point])
                receipt["events"][event][field] = False
                proofs[point] = lock_validator.json_bytes(receipt)
                changed["cells"][2]["evidence"]["sha256"] = lock_validator.digest(proofs[point])
                self.invalid(self.validate(changed, artifacts=artifacts, evidence=proofs))
        for field in lock_validator.SQLITE_KEYS:
            changed = copy.deepcopy(matrix)
            proofs = dict(evidence)
            changed["cells"][2]["sqlite"][field] = None
            receipt = json.loads(proofs[point])
            receipt["sqlite"] = changed["cells"][2]["sqlite"]
            proofs[point] = lock_validator.json_bytes(receipt)
            changed["cells"][2]["evidence"]["sha256"] = lock_validator.digest(proofs[point])
            self.invalid(self.validate(changed, artifacts=artifacts, evidence=proofs))

    def test_safe_diagnostics_never_echo_keys_values_paths_or_exceptions(self):
        secrets = ("PRIVATE_secret_key", "/private/SECRET", "https://secret.invalid/token")
        matrix = copy.deepcopy(self.matrix)
        matrix[secrets[0]] = list(secrets)
        result = self.validate(matrix)
        self.invalid(result)
        serialized = json.dumps(result)
        for secret in secrets:
            self.assertNotIn(secret, serialized)
        output = io.StringIO()
        with contextlib.redirect_stdout(output), mock.patch.object(
                Path, "read_bytes", side_effect=OSError("/private/SECRET")):
            self.assertEqual(lock_validator.main(["validate"]), 1)
        self.assertNotIn("SECRET", output.getvalue())
        self.assertNotIn("OSError", output.getvalue())

    def test_cli_deterministic_candidate_generation_is_exclusive_and_nonpromoting(self):
        with tempfile.TemporaryDirectory() as temporary:
            matrix_path = Path(temporary) / "matrix.json"
            args = ["write-candidate", str(SCRIPTS / "dependencies.json"), str(matrix_path)]
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                self.assertEqual(lock_validator.main(args), 2)
            generated = matrix_path.read_bytes()
            actual_source = Path(lock_validator.__file__).read_bytes()
            self.assertEqual(json.loads(generated), lock_validator.candidate_matrix(
                self.lock_bytes, actual_source))
            outputs = []
            for _ in range(2):
                stream = io.StringIO()
                with contextlib.redirect_stdout(stream):
                    self.assertEqual(lock_validator.main([
                        "validate", str(SCRIPTS / "dependencies.json"), str(matrix_path)]), 2)
                outputs.append(stream.getvalue())
            self.assertEqual(outputs[0], outputs[1])
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(lock_validator.main(args), 1)
            self.assertEqual(matrix_path.read_bytes(), generated)

    def test_delivered_candidate_uses_actual_manifest_and_source_bytes(self):
        # Parent generates this fourth target after source is final, not with an
        # example digest. Missing matrix intentionally fails the approved gate.
        matrix_bytes = (SCRIPTS / "runtime-matrix.json").read_bytes()
        source = Path(lock_validator.__file__).read_bytes()
        self.assertEqual(json.loads(matrix_bytes),
                         lock_validator.candidate_matrix(self.lock_bytes, source))
        code, output = lock_validator.validate(self.lock_bytes, matrix_bytes, source)
        self.assertEqual(code, 2)
        self.assertTrue(output["conformant"])


if __name__ == "__main__":
    unittest.main()
