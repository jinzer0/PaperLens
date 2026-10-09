"""Synthetic pure conformance only: no provider, importer, parser or OS gate."""
import copy
from dataclasses import FrozenInstanceError, replace
import json
from pathlib import Path
import sys
import threading
import traceback
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "Contracts" / "ProviderRequest"))
import provider_request


def uuid(number):
    return f"00000000-0000-4000-8000-{number:012x}"


def plain(value):
    return json.loads(provider_request.canonical_bytes(value))


def identity():
    return {"paperID": uuid(2), "paperGeneration": 1, "pdfSHA256": "a" * 64,
            "extractionRevision": uuid(3)}


def sentences(quotes=("Canonical /tmp/paper https://example.org é한/\u2028\u2029",), pages=None):
    return [{"anchor": {"pageIndex": 0 if pages is None else pages[i], "sentenceID": i}, "quote": quote}
            for i, quote in enumerate(quotes)]


def turns(pairs=3, text="Prior data"):
    return [{"turnID": uuid(100 + i), "role": "user" if i % 2 == 0 else "assistant", "text": text}
            for i in range(pairs * 2)]


def snapshot(count=2):
    return {"snapshotID": uuid(5), "templateVersionID": uuid(6),
            "sections": [{"sectionID": uuid(7 + i), "heading": "Conclusion", "prompt": "Explain canonical results."}
                         for i in range(count)],
            "generationInputs": {"outputLanguage": "en", "policyVersion": 1}}


def context(operation, quotes=None, history=(), ranking=None, sources=None, pages=None):
    if operation == "connectionTest":
        return provider_request.TrustedContext(operation)
    data = sentences() if quotes is None else sentences(quotes, pages)
    if sources is None:
        sources = {"translation": {"targetLanguage": "ko", "sentenceIDs": [0]},
                   "paperChat": {"sessionID": uuid(4), "question": "What is the result?"},
                   "brief": {"templateSnapshot": snapshot()},
                   "librarySummary": {"outputLanguage": "en"}}[operation]
    ranking = tuple(range(len(data))) if ranking is None else ranking
    batch = tuple(sources["sentenceIDs"]) if operation == "translation" else ()
    return provider_request.TrustedContext(operation, identity(), data, ranking, sources, history, batch)


def request(operation, **kwargs):
    trusted = context(operation, **kwargs)
    return provider_request.build_request(operation, trusted.sources, trusted, uuid(1))


def grounded(text="Canonical answer.", kind="paper", indices=(0,)):
    return {"text": text, "kind": kind, "evidenceIndices": list(indices)}


def result_member(req):
    operation = req.operation
    if operation == "connectionTest":
        return {"text": "PAPERLENS_OK"}
    if operation == "translation":
        return {"translations": [{**plain(item["anchor"]), "text": "번역"} for item in req.input["evidence"]["items"]]}
    insufficiency = req.input["evidence"]["insufficiency"]
    segment = grounded() if req.input["evidence"]["items"] else grounded("No evidence.", "insufficient", ())
    if operation == "paperChat":
        return {"segments": [segment], "insufficiency": insufficiency}
    if operation == "brief":
        return {"sections": [{"sectionID": section["sectionID"], "state": "ready", "segments": [segment]}
                             for section in req.input["templateSnapshot"]["sections"]], "insufficiency": insufficiency}
    return {"summary": segment, "insufficiency": insufficiency}


def envelope(req, member=None):
    return {"schemaVersion": req.schemaVersion, "requestID": req.requestID, "operation": req.operation,
            "result": result_member(req) if member is None else member}


def vector_context(value):
    operation = value["operation"]
    payload = value["input"]
    if operation == "connectionTest":
        return context(operation)
    evidence = payload["evidence"]
    paper = {name: evidence[name] for name in identity()}
    data = [{"anchor": item["anchor"], "quote": item["quote"]} for item in evidence["items"]]
    sources = {k: v for k, v in payload.items() if k not in ("evidence", "priorTurns")}
    batch = tuple(item["anchor"]["sentenceID"] for item in evidence["items"]) if operation == "translation" else ()
    if operation == "translation":
        sources["sentenceIDs"] = batch
    return provider_request.TrustedContext(operation, paper, data, tuple(range(len(data))), sources,
                                           payload.get("priorTurns", ()), batch)


class ContractTests(unittest.TestCase):
    def rejected(self, callback, code=None, field=None):
        with self.assertRaises(provider_request.ContractError) as caught:
            callback()
        error = caught.exception
        self.assertEqual(set(error.as_dict()), {"code", "field"})
        self.assertIn(error.code, provider_request.POLICIES["errorCodes"])
        self.assertIn(error.field, provider_request.POLICIES["errorFields"])
        if code:
            self.assertEqual(error.code, code)
        if field:
            self.assertEqual(error.field, field)
        self.assertEqual(error.args, (error.code, error.field))
        return error

    def test_embedded_cross_consumer_vectors(self):
        vectors = provider_request.CONTRACT["conformance"]
        for vector in vectors["canonical"]:
            self.assertEqual(provider_request.canonical_bytes(vector["value"]), vector["utf8"].encode("utf-8"))
        for vector in vectors["rendered"]:
            value = {"schemaVersion": 1, "requestID": uuid(1), "operation": vector["operation"], "input": plain(vector["input"])}
            wire = provider_request.parse_request(provider_request.canonical_bytes(value))
            messages = provider_request.render_messages(wire)
            self.assertEqual([{"role": m.role, "content": m.content} for m in messages], plain(vector["messages"]))
            if "contentBytes" in vector:
                self.assertEqual(sum(len(m.content.encode("utf-8")) for m in messages), vector["contentBytes"])
            if "inputCharge" in vector:
                self.assertEqual(provider_request.input_charge(wire), vector["inputCharge"])
        for vector in vectors["requests"]:
            raw = provider_request.canonical_bytes(vector["value"])
            if vector["accepted"]:
                wire = provider_request.parse_request(raw)
                authorized = provider_request.authorize_request(wire, vector_context(plain(vector["value"])))
                self.assertEqual(provider_request.encode_request(authorized), raw)
            else:
                self.rejected(lambda: provider_request.parse_request(raw), vector["code"])
        for vector in vectors["results"]:
            value = plain(vector["request"])
            wire = provider_request.parse_request(provider_request.canonical_bytes(value))
            req = provider_request.authorize_request(wire, vector_context(value))
            raw = provider_request.canonical_bytes(vector["value"])
            if vector["accepted"]:
                self.assertEqual(provider_request.validate_result(raw, req).requestID, req.requestID)
            else:
                self.rejected(lambda: provider_request.validate_result(raw, req), vector["code"])
        for raw in vectors["invalidJSON"]:
            self.rejected(lambda: provider_request.parse_request(raw.encode("utf-8")), "invalidJSON")

    def test_all_five_complete_pure_pipelines(self):
        for operation in provider_request.CONTRACT["operations"]:
            with self.subTest(operation=operation):
                original = request(operation, **({"history": turns(2)} if operation == "paperChat" else {}))
                raw = provider_request.encode_request(original)
                wire = provider_request.parse_request(raw)
                authorized = provider_request.authorize_request(wire, original.context)
                self.assertEqual(provider_request.encode_request(authorized), raw)
                self.assertEqual(provider_request.verify_adapter_copy(authorized, raw), wire)
                reordered = json.dumps(json.loads(raw), ensure_ascii=False, indent=2).encode("utf-8")
                self.assertEqual(provider_request.verify_adapter_copy(authorized, reordered), wire)
                messages = provider_request.render_messages(wire)
                self.assertIsInstance(messages, tuple)
                if operation == "connectionTest":
                    raw_member = b"PAPERLENS_OK"
                    self.assertEqual(messages, (provider_request.Message("user", "Reply exactly PAPERLENS_OK."),))
                else:
                    self.assertEqual(messages[0].role, "system")
                    self.assertEqual(messages[-1].role, "user")
                    self.assertNotIn("priorTurns", json.loads(messages[-1].content))
                    raw_member = provider_request.canonical_bytes(result_member(authorized))
                wrapped = provider_request.wrap_model_result(raw_member, authorized)
                validated = provider_request.validate_result(provider_request.canonical_bytes(envelope(authorized)), authorized)
                self.assertEqual(wrapped, validated)
                self.assertEqual((wrapped.schemaVersion, wrapped.requestID, wrapped.operation), (1, uuid(1), operation))

    def test_strict_json_utf8_duplicates_depth_and_scalars(self):
        good = provider_request.encode_request(request("connectionTest"))
        bad = [good + b"{}", b"\xef\xbb\xbf" + good, b"\xff", good.replace(b'"schemaVersion":1', b'"schemaVersion":1.0'),
               good.replace(b'"schemaVersion":1', b'"schemaVersion":NaN'), good.replace(b'"input":{}', b'"input":{"a":1,"a":2}'),
               b'{"a":"\\ud800"}', b'{"a":"\\udfff"}', b'{"a":"\x00"}', b"[" * 8 + b"0" + b"]" * 8]
        for raw in bad:
            self.rejected(lambda: provider_request.parse_request(raw), "invalidJSON")
        self.rejected(lambda: provider_request.parse_request(good.decode()), "invalidJSON")
        self.rejected(lambda: provider_request.parse_request(b" " * (provider_request.LIMITS["innerBytes"] + 1)), "inputLimit")
        for value in (True, None, "1", [], {}):
            candidate = json.loads(good)
            candidate["schemaVersion"] = value
            self.rejected(lambda: provider_request.parse_request(provider_request.canonical_bytes(candidate)), "invalidShape")
        # An escaped surrogate PAIR is a valid Unicode scalar, unlike a lone one.
        req = request("paperChat", quotes=("😀",))
        escaped = json.dumps(plain(req.wire.as_record()), ensure_ascii=True).encode()
        self.assertEqual(provider_request.verify_adapter_copy(req, escaped).input["evidence"]["items"][0]["quote"], "😀")

    def test_structural_and_raw_byte_ceiling_equality(self):
        raw = provider_request.encode_request(request("connectionTest"))
        at_limit = raw + b" " * (provider_request.LIMITS["innerBytes"] - len(raw))
        provider_request.parse_request(at_limit)
        self.rejected(lambda: provider_request.parse_request(at_limit + b" "), "inputLimit")
        for count, code in ((16, "invalidShape"), (17, "invalidJSON")):
            self.rejected(lambda: provider_request.parse_request(json.dumps({str(i): 0 for i in range(count)}).encode()), code)
        for count, code in ((32, "invalidShape"), (33, "invalidJSON")):
            self.rejected(lambda: provider_request.parse_request(json.dumps([0] * count).encode()), code)
        for depth, code in ((7, "invalidShape"), (8, "invalidJSON")):
            self.rejected(lambda: provider_request.parse_request(b"[" * depth + b"0" + b"]" * depth), code)
        req = request("paperChat")
        member = {"segments": [grounded("x")] * 32, "insufficiency": "none"}
        provider_request.wrap_model_result(provider_request.canonical_bytes(member), req)
        member["segments"].append(grounded("x"))
        self.rejected(lambda: provider_request.wrap_model_result(provider_request.canonical_bytes(member), req), "invalidJSON")

    def test_template_field_snapshot_and_count_boundaries(self):
        template = snapshot(16)
        template["sections"][0]["heading"] = "é" * 64
        template["sections"][0]["prompt"] = "é" * 512
        request("brief", sources={"templateSnapshot": template})
        for key in ("heading", "prompt"):
            invalid = copy.deepcopy(template)
            invalid["sections"][0][key] += "x"
            self.rejected(lambda: context("brief", sources={"templateSnapshot": invalid}))
        invalid = snapshot(17)
        self.rejected(lambda: context("brief", sources={"templateSnapshot": invalid}))
        invalid = snapshot(2)
        invalid["sections"][1]["sectionID"] = invalid["sections"][0]["sectionID"]
        self.rejected(lambda: context("brief", sources={"templateSnapshot": invalid}), "invalidTemplate")
        # Grow complete prompt fields without exceeding any individual cap,
        # then hit the canonical snapshot byte limit exactly.
        template = snapshot(8)
        size = len(provider_request.canonical_bytes(template))
        remaining = provider_request.LIMITS["snapshotBytes"] - size
        for section in template["sections"]:
            growth = min(remaining, 1024 - len(section["prompt"].encode()))
            section["prompt"] += "x" * growth
            remaining -= growth
        self.assertEqual(remaining, 0)
        self.assertEqual(len(provider_request.canonical_bytes(template)), provider_request.LIMITS["snapshotBytes"])
        request("brief", sources={"templateSnapshot": template})
        template["sections"][-1]["prompt"] += "x"
        self.rejected(lambda: context("brief", sources={"templateSnapshot": template}), "invalidTemplate")

    def test_actual_rendered_charge_exact_limit_and_one_byte_over(self):
        sources = {"sessionID": uuid(4), "question": "x"}
        req = request("paperChat", quotes=("\x00" * 3000,), sources=sources)
        ceiling = provider_request.CONTRACT["operations"]["paperChat"]["inputCharge"]
        slack = ceiling - provider_request.input_charge(req)
        self.assertGreaterEqual(slack, 0)
        self.assertLess(slack, 4096)
        sources["question"] += "x" * slack
        exact = request("paperChat", quotes=("\x00" * 3000,), sources=sources)
        self.assertEqual(len(exact.input["evidence"]["items"]), 1)
        self.assertEqual(provider_request.input_charge(exact), ceiling)
        modified = plain(exact.wire.as_record())
        modified["input"]["question"] += "x"
        self.rejected(lambda: provider_request.parse_request(provider_request.canonical_bytes(modified)), "inputLimit")

    def test_exact_keysets_at_every_request_and_result_object(self):
        def object_paths(value, path=()):
            if isinstance(value, dict):
                yield path
                for key, child in value.items():
                    yield from object_paths(child, path + (key,))
            elif isinstance(value, list):
                for index, child in enumerate(value):
                    yield from object_paths(child, path + (index,))
        def at(value, path):
            for key in path:
                value = value[key]
            return value
        for operation in provider_request.CONTRACT["operations"]:
            req = request(operation, **({"history": turns(1)} if operation == "paperChat" else {}))
            for original, consumer in ((plain(req.wire.as_record()), provider_request.parse_request),
                                       (envelope(req), lambda raw: provider_request.validate_result(raw, req))):
                for path in object_paths(original):
                    for action in ("extra", "missing"):
                        modified = copy.deepcopy(original)
                        node = at(modified, path)
                        if action == "missing":
                            if not node:
                                continue
                            del node[next(iter(node))]
                        else:
                            node["rawPDF"] = "SECRET_VALUE_NOT_ALLOWED"
                        error = self.rejected(lambda: consumer(provider_request.canonical_bytes(modified)))
                        self.assertNotIn("SECRET", str(error))

    def test_schema_types_ids_languages_and_numeric_bounds(self):
        original = plain(request("paperChat").wire.as_record())
        paths = [("input", "evidence", "paperGeneration"), ("input", "evidence", "items", 0, "rank"),
                 ("input", "evidence", "items", 0, "anchor", "pageIndex"),
                 ("input", "evidence", "items", 0, "anchor", "sentenceID")]
        for path in paths:
            for invalid in (True, False, None, 0.1, "1", -1):
                modified = copy.deepcopy(original)
                node = modified
                for key in path[:-1]:
                    node = node[key]
                node[path[-1]] = invalid
                self.rejected(lambda: provider_request.parse_request(json.dumps(modified).encode()))
        for invalid in (uuid(1).upper(), "00000000-0000-1000-8000-000000000001", "00000000-0000-4000-7000-000000000001", "not-a-uuid"):
            modified = copy.deepcopy(original)
            modified["requestID"] = invalid
            # All-digit UUID has no alphabetic case; use a letter-bearing variant.
            if invalid == uuid(1):
                continue
            self.rejected(lambda: provider_request.parse_request(provider_request.canonical_bytes(modified)))
        modified = copy.deepcopy(original)
        modified["requestID"] = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa".upper()
        self.rejected(lambda: provider_request.parse_request(provider_request.canonical_bytes(modified)))
        for language in ("en", "eng", "zh-Hans-CN", "es-419"):
            self.assertEqual(request("librarySummary", sources={"outputLanguage": language}).input["outputLanguage"], language)
        for language in ("EN", "e", "english", "en-us", "zh-hans", "en_US", "", "en-1234"):
            self.rejected(lambda: context("librarySummary", sources={"outputLanguage": language}))
        for field, maximum in (("pageIndex", 1999), ("sentenceID", 199999)):
            modified = copy.deepcopy(original)
            modified["input"]["evidence"]["items"][0]["anchor"][field] = maximum
            provider_request.parse_request(provider_request.canonical_bytes(modified))
            modified["input"]["evidence"]["items"][0]["anchor"][field] = maximum + 1
            self.rejected(lambda: provider_request.parse_request(provider_request.canonical_bytes(modified)))
        for generation in (1, 9223372036854775807):
            modified = copy.deepcopy(original)
            modified["input"]["evidence"]["paperGeneration"] = generation
            provider_request.parse_request(provider_request.canonical_bytes(modified))
        for generation in (0, 9223372036854775808):
            modified = copy.deepcopy(original)
            modified["input"]["evidence"]["paperGeneration"] = generation
            self.rejected(lambda: provider_request.parse_request(provider_request.canonical_bytes(modified)))

    def test_freeze_is_deep_and_context_equality_deterministic(self):
        data = sentences()
        source = {"templateSnapshot": snapshot()}
        paper = identity()
        trusted = provider_request.TrustedContext("brief", paper, data, [0], source)
        equal = provider_request.TrustedContext("brief", dict(reversed(list(paper.items()))), copy.deepcopy(data), [0], copy.deepcopy(source))
        self.assertEqual(trusted, equal)
        original = provider_request.build_request("brief", source, trusted, uuid(1))
        encoded = provider_request.encode_request(original)
        paper["paperGeneration"] = 2
        data[0]["quote"] = "changed"
        source["templateSnapshot"]["sections"][0]["prompt"] = "changed"
        self.assertEqual(provider_request.encode_request(original), encoded)
        with self.assertRaises(TypeError):
            original.input["evidence"]["items"][0]["anchor"]["pageIndex"] = 5
        with self.assertRaises(FrozenInstanceError):
            original.wire.operation = "connectionTest"
        self.rejected(lambda: provider_request.encode_request(original.wire), "sourceMismatch")
        validated = provider_request.wrap_model_result(provider_request.canonical_bytes(result_member(original)), original)
        with self.assertRaises(TypeError):
            validated.result["sections"][0]["segments"][0]["text"] = "changed"

    def test_provenance_active_revision_and_intent(self):
        req = request("paperChat", quotes=("high", "low"), history=turns(1), ranking=(1, 0))
        original = plain(req.wire.as_record())
        variants = []
        for key, value in (("paperID", uuid(99)), ("paperGeneration", 2), ("pdfSHA256", "b" * 64), ("extractionRevision", uuid(99))):
            changed = copy.deepcopy(original)
            changed["input"]["evidence"][key] = value
            variants.append((changed, "staleRevision"))
        for key, value in (("sessionID", uuid(99)), ("question", "Different intent")):
            changed = copy.deepcopy(original)
            changed["input"][key] = value
            variants.append((changed, "sourceMismatch"))
        changed = copy.deepcopy(original)
        changed["input"]["evidence"]["items"][0]["quote"] += " "
        variants.append((changed, "sourceMismatch"))
        changed = copy.deepcopy(original)
        changed["input"]["priorTurns"][0]["text"] = "Other session"
        variants.append((changed, "sourceMismatch"))
        changed = copy.deepcopy(original)
        changed["input"]["evidence"]["items"].reverse()
        for rank, item in enumerate(changed["input"]["evidence"]["items"]):
            item["rank"] = rank
        variants.append((changed, "sourceMismatch"))
        changed = copy.deepcopy(original)
        changed["input"]["evidence"]["items"].pop()
        changed["input"]["evidence"]["insufficiency"] = "budgetLimited"
        variants.append((changed, "sourceMismatch"))
        for changed, code in variants:
            wire = provider_request.parse_request(provider_request.canonical_bytes(changed))
            self.rejected(lambda: provider_request.authorize_request(wire, req.context), code)
            self.rejected(lambda: provider_request.verify_adapter_copy(req, provider_request.canonical_bytes(changed)))
        brief = request("brief")
        modified = plain(brief.wire.as_record())
        modified["input"]["templateSnapshot"]["sections"][0]["prompt"] = "Live lookup"
        self.rejected(lambda: provider_request.authorize_request(provider_request.parse_request(provider_request.canonical_bytes(modified)), brief.context), "sourceMismatch")
        self.rejected(lambda: provider_request.build_request("paperChat", {"sessionID": uuid(99), "question": "Different"}, req.context, uuid(1)), "sourceMismatch")

    def test_history_pairs_membership_and_pruning(self):
        for invalid in (turns(1)[:1], list(reversed(turns(1))), [turns(1)[0], turns(1)[0]],
                        [{**turns(1)[0], "role": "system"}, turns(1)[1]], turns(4)):
            self.rejected(lambda: context("paperChat", history=invalid))
        req = request("paperChat", quotes=("x" * 4096,) * 3, history=turns(3, "h" * 2048))
        selected = req.input["evidence"]["items"]
        self.assertEqual(len(selected), 3)
        retained = req.input["priorTurns"]
        self.assertLess(len(retained), 6)
        self.assertEqual(len(retained) % 2, 0)
        self.assertEqual(plain(retained), turns(3, "h" * 2048)[6 - len(retained):])
        self.assertEqual(req.input["evidence"]["insufficiency"], "none")
        self.assertLessEqual(provider_request.input_charge(req), provider_request.CONTRACT["operations"]["paperChat"]["inputCharge"])

    def test_ranked_prefix_caps_no_skips_and_dishonest_counts(self):
        req = request("paperChat", quotes=("x" * 4097, "short"))
        evidence = req.input["evidence"]
        self.assertEqual(evidence["items"], ())
        self.assertEqual(evidence["selection"]["candidateCount"], 2)
        self.assertEqual(evidence["insufficiency"], "budgetLimited")
        req = request("librarySummary", quotes=("x",) * 12, ranking=tuple(reversed(range(12))))
        items = req.input["evidence"]["items"]
        self.assertEqual(len(items), 8)
        self.assertEqual([i["anchor"]["sentenceID"] for i in items], list(reversed(range(12)))[:8])
        self.assertEqual([i["rank"] for i in items], list(range(8)))
        self.assertEqual(req.input["evidence"]["selection"]["candidateCount"], 12)
        modified = plain(req.wire.as_record())
        modified["input"]["evidence"]["selection"]["candidateCount"] = 8
        modified["input"]["evidence"]["insufficiency"] = "none"
        self.rejected(lambda: provider_request.authorize_request(provider_request.parse_request(provider_request.canonical_bytes(modified)), req.context), "sourceMismatch")
        for count, insufficiency in ((0, "none"), (1, "noEvidence"), (200001, "budgetLimited")):
            changed = plain(req.wire.as_record())
            changed["input"]["evidence"]["selection"]["candidateCount"] = count
            changed["input"]["evidence"]["insufficiency"] = insufficiency
            self.rejected(lambda: provider_request.parse_request(provider_request.canonical_bytes(changed)))
        empty = request("paperChat", quotes=())
        self.assertEqual(empty.input["evidence"]["insufficiency"], "noEvidence")

    def test_utf8_and_rendered_escape_charge_not_character_estimates(self):
        cap = 4096
        trusted = context("paperChat", quotes=("é" * (cap // 2), "x"))
        req = provider_request.build_request("paperChat", trusted.sources, trusted, uuid(1))
        self.assertEqual(len(req.input["evidence"]["items"][0]["quote"].encode()), cap)
        over = request("paperChat", quotes=("é" * (cap // 2) + "x", "x"))
        self.assertEqual(over.input["evidence"]["items"], ())
        # C0 serialization expands each input byte. Charge must use rendered C,
        # not the raw quote count (which still satisfies the quote-byte cap).
        escaped = request("paperChat", quotes=("\x00" * cap,) * 4)
        self.assertLess(len(escaped.input["evidence"]["items"]), 4)
        messages = provider_request.render_messages(escaped)
        measured = sum(len(m.content.encode()) + provider_request.LIMITS["messageOverhead"] for m in messages) + provider_request.CONTRACT["operations"]["paperChat"]["controlReserve"]
        self.assertEqual(provider_request.input_charge(escaped), measured)
        self.assertLessEqual(measured, provider_request.CONTRACT["operations"]["paperChat"]["inputCharge"])
        # Path-looking canonical quotes remain byte-identical, not filtered.
        original = request("paperChat")
        self.assertIn("/tmp/paper", original.input["evidence"]["items"][0]["quote"])
        self.assertIn("https://", original.input["evidence"]["items"][0]["quote"])

    def test_translation_greedy_complete_plan_ranks_and_whole_plan_failure(self):
        base = context("translation", quotes=("x" * 4096,) * 9)
        plan = provider_request.plan_translation_batches(0, "ko", base)
        self.assertGreater(len(plan), 1)
        self.assertEqual(tuple(sid for batch in plan for sid in batch), tuple(range(9)))
        for index, batch in enumerate(plan):
            bound = base.for_translation_batch("ko", batch)
            req = provider_request.build_request("translation", bound.sources, bound, uuid(10 + index))
            self.assertEqual(tuple(i["rank"] for i in req.input["evidence"]["items"]), batch)
            self.assertEqual(req.input["evidence"]["selection"]["candidateCount"], len(batch))
            self.assertEqual(req.input["evidence"]["insufficiency"], "none")
            if index + 1 < len(plan):
                extra_ids = batch + plan[index + 1][:1]
                self.rejected(lambda: base.for_translation_batch("ko", extra_ids), "sourceMismatch")
        self.rejected(lambda: base.for_translation_batch("ko", plan[0][:-1]), "sourceMismatch")
        bad = context("translation", quotes=("x", "y", "z" * 4097))
        self.rejected(lambda: provider_request.plan_translation_batches(0, "ko", bad), "inputLimit", "evidence")
        self.assertEqual(provider_request.plan_translation_batches(1, "ko", base), ())
        self.rejected(lambda: provider_request.plan_translation_batches(0, "en", base), "sourceMismatch")
        other_page = context("translation", quotes=("a", "b", "c"), pages=(0, 1, 1))
        self.assertEqual(provider_request.plan_translation_batches(1, "ko", other_page), ((1, 2),))
        bound = other_page.for_translation_batch("ko", (1, 2))
        req = provider_request.build_request("translation", bound.sources, bound, uuid(1))
        self.assertEqual([i["rank"] for i in req.input["evidence"]["items"]], [0, 1])
        empty = context("translation", quotes=(), sources={"targetLanguage": "ko", "sentenceIDs": []})
        self.assertEqual(provider_request.plan_translation_batches(0, "ko", empty), ())
        self.rejected(lambda: provider_request.build_request("translation", empty.sources, empty, uuid(1)), "invalidEvidence")

    def test_probe_raw_reply_exact_and_correlation(self):
        req = request("connectionTest")
        for raw in (b"PAPERLENS_OK\n", b" PAPERLENS_OK", b'"PAPERLENS_OK"', b'{"text":"PAPERLENS_OK"}', "PAPERLENS_OK", b"paperlens_ok", b""):
            self.rejected(lambda: provider_request.wrap_model_result(raw, req), "invalidResult")
        for key, value in (("requestID", uuid(99)), ("operation", "translation"), ("schemaVersion", True), ("schemaVersion", 2)):
            modified = envelope(req)
            modified[key] = value
            self.rejected(lambda: provider_request.validate_result(provider_request.canonical_bytes(modified), req), "invalidResult")
        product = request("paperChat")
        self.rejected(lambda: provider_request.wrap_model_result(provider_request.canonical_bytes(envelope(product)), product), "invalidResult")
        self.rejected(lambda: provider_request.validate_result(provider_request.canonical_bytes(envelope(req)), req.wire), "sourceMismatch")

    def test_translation_output_exact_order_anchor_and_text_bounds(self):
        req = request("translation", quotes=("a", "b"), sources={"targetLanguage": "ko", "sentenceIDs": [0, 1]})
        original = result_member(req)
        for modified in ({"translations": list(reversed(original["translations"]))},
                         {"translations": original["translations"][:1]}, {"translations": original["translations"] * 2},
                         {"translations": [{**original["translations"][0], "pageIndex": 1}, original["translations"][1]]},
                         {"translations": [{**original["translations"][0], "text": ""}, original["translations"][1]]}):
            self.rejected(lambda: provider_request.wrap_model_result(provider_request.canonical_bytes(modified), req), "invalidResult")
        for size, passes in ((8192, True), (8193, False)):
            modified = copy.deepcopy(original)
            modified["translations"][0]["text"] = "x" * size
            if passes:
                provider_request.wrap_model_result(provider_request.canonical_bytes(modified), req)
            else:
                self.rejected(lambda: provider_request.wrap_model_result(provider_request.canonical_bytes(modified), req), "invalidResult")

    def test_output_citations_insufficiency_and_aggregate_ceilings(self):
        req = request("paperChat", quotes=("a", "b", "c"))
        for segment in (grounded(indices=()), grounded(indices=(1, 0)), grounded(indices=(0, 0)), grounded(indices=(3,)),
                        grounded(kind="insufficient", indices=(0,)), grounded(indices=(True,)), grounded(kind="tool")):
            member = {"segments": [segment], "insufficiency": "none"}
            self.rejected(lambda: provider_request.wrap_model_result(provider_request.canonical_bytes(member), req), "invalidResult")
        accepted = {"segments": [grounded(indices=(0, 2)), grounded("Analysis", "analysis", ())], "insufficiency": "none"}
        provider_request.wrap_model_result(provider_request.canonical_bytes(accepted), req)
        accepted["insufficiency"] = "budgetLimited"
        self.rejected(lambda: provider_request.wrap_model_result(provider_request.canonical_bytes(accepted), req), "invalidResult")
        empty = request("paperChat", quotes=())
        member = {"segments": [grounded(indices=(0,))], "insufficiency": "noEvidence"}
        self.rejected(lambda: provider_request.wrap_model_result(provider_request.canonical_bytes(member), empty), "invalidResult")
        for size, passes in ((4096, True), (4097, False)):
            member = {"segments": [grounded("é" * size)], "insufficiency": "none"}
            if passes:
                provider_request.wrap_model_result(provider_request.canonical_bytes(member), req)
            else:
                self.rejected(lambda: provider_request.wrap_model_result(provider_request.canonical_bytes(member), req), "invalidResult")
        member = {"segments": [grounded("x" * 4096), grounded("y" * 4097)], "insufficiency": "none"}
        self.rejected(lambda: provider_request.wrap_model_result(provider_request.canonical_bytes(member), req), "outputLimit")

    def test_brief_all_missing_ready_snapshot_order_and_segment_total(self):
        req = request("brief")
        missing = {"sections": [{"sectionID": section["sectionID"], "state": "missing-content", "segments": []}
                                for section in req.input["templateSnapshot"]["sections"]], "insufficiency": "none"}
        provider_request.wrap_model_result(provider_request.canonical_bytes(missing), req)
        variants = []
        modified = copy.deepcopy(missing)
        modified["sections"][0]["state"] = "ready"
        variants.append(modified)
        modified = copy.deepcopy(missing)
        modified["sections"][0]["segments"] = [grounded()]
        variants.append(modified)
        modified = copy.deepcopy(missing)
        modified["sections"].reverse()
        variants.append(modified)
        modified = copy.deepcopy(missing)
        modified["sections"][0]["sectionID"] = uuid(99)
        variants.append(modified)
        modified = copy.deepcopy(missing)
        modified["insufficiency"] = "noEvidence"
        variants.append(modified)
        modified = result_member(req)
        modified["sections"][0]["segments"] = [grounded("a")] * 17
        modified["sections"][1]["segments"] = [grounded("b")] * 16
        variants.append(modified)
        for member in variants:
            self.rejected(lambda: provider_request.wrap_model_result(provider_request.canonical_bytes(member), req), "invalidResult")
        empty = request("brief", quotes=())
        missing["insufficiency"] = "noEvidence"
        provider_request.wrap_model_result(provider_request.canonical_bytes(missing), empty)

    def test_summary_one_line_bytes_and_kinds(self):
        req = request("librarySummary")
        for text in ("a\nb", "a\rb", "a\u2028b", "a\u2029b", "a\x85b", "a\vb", "a\fb"):
            member = {"summary": grounded(text), "insufficiency": "none"}
            self.rejected(lambda: provider_request.wrap_model_result(provider_request.canonical_bytes(member), req), "invalidResult")
        for size, passes in ((1024, True), (1025, False)):
            member = {"summary": grounded("é" * size), "insufficiency": "none"}
            if passes:
                provider_request.wrap_model_result(provider_request.canonical_bytes(member), req)
            else:
                self.rejected(lambda: provider_request.wrap_model_result(provider_request.canonical_bytes(member), req), "outputLimit")
        member = {"summary": grounded("Analysis", "analysis", ()), "insufficiency": "none"}
        self.rejected(lambda: provider_request.wrap_model_result(provider_request.canonical_bytes(member), req), "invalidResult")

    def test_provider_certification_separate_from_rendering(self):
        for operation, policy in provider_request.CONTRACT["operations"].items():
            profile = {"providerID": "synthetic-certified-mapping", "modelID": "synthetic-model", "certified": True,
                       "byteDecomposable": True, "noExpandingPreprocessing": True, "hiddenControlBytes": policy["controlReserve"],
                       "contextTokens": policy["inputCharge"] + policy["outputTokens"], "maxOutputTokens": policy["outputTokens"], "toolsDisabled": True}
            provider_request.validate_provider_profile(profile, operation)
            for key, value in (("certified", False), ("byteDecomposable", 1), ("noExpandingPreprocessing", False),
                               ("toolsDisabled", False), ("hiddenControlBytes", policy["controlReserve"] + 1),
                               ("contextTokens", profile["contextTokens"] - 1), ("maxOutputTokens", policy["outputTokens"] - 1)):
                modified = {**profile, key: value}
                self.rejected(lambda: provider_request.validate_provider_profile(modified, operation), "unsupportedProvider", "provider")
        self.rejected(lambda: provider_request.validate_provider_profile({}, "paperChat"), "unsupportedProvider")
        self.rejected(lambda: provider_request.validate_provider_profile({"certified": True}, "unknown"), "unsupportedProvider")

    def test_import_url_arxiv_and_redirect_rules(self):
        valid = ("https://example.org/paper.pdf", "https://example.org/a%2Fb.pdf?download=1", "https://[::1]/paper.pdf")
        for value in valid:
            self.assertEqual(provider_request.validate_import_url(value).value, value)
        invalid = ("http://example.org/p.pdf", "https:///p.pdf", "https://user:pass@example.org/p.pdf", "https://example.org\\p.pdf",
                   "https://example.org/%", "https://example.org/%G0", "https://example.org/%0", "https://example.org/%0a",
                   "https://example.org/\nfile.pdf", "https://example.org/%5cfile.pdf", "https://example.org:bad/a", "https://example.org:0/a")
        for value in invalid:
            self.rejected(lambda: provider_request.validate_import_url(value), "importRejected", "import")
        for identifier in ("2401.1234", "2401.12345v12", "hep-th/9901001v2"):
            result = provider_request.resolve_arxiv_abstract_url("https://www.arxiv.org/abs/" + identifier)
            self.assertEqual(result.value, "https://arxiv.org/pdf/" + identifier)
            provider_request.validate_import_url(result.value + ".pdf", "arxivPDF")
        for value in ("https://evil.org/abs/2401.12345", "https://arxiv.org/abs/2413.1234", "https://arxiv.org/abs/2401.123v1",
                      "https://arxiv.org/abs/2401.1234v0", "https://arxiv.org/abs/2401.1234/", "https://arxiv.org/abs/2401.1234?x=1"):
            self.rejected(lambda: provider_request.resolve_arxiv_abstract_url(value), "importRejected")
        current = provider_request.validate_import_url("https://example.org/a/p.pdf")
        self.assertEqual(provider_request.resolve_redirect_url(current, "../b.pdf").value, "https://example.org/b.pdf")
        self.rejected(lambda: provider_request.resolve_redirect_url(current, "http://example.org/b.pdf"), "importRejected")
        self.rejected(lambda: provider_request.resolve_redirect_url(current, "//u:p@example.org/b.pdf"), "importRejected")
        for length, passes in ((8192, True), (8193, False)):
            value = "https://example.org/" + "x" * (length - len("https://example.org/"))
            if passes:
                provider_request.validate_import_url(value)
            else:
                self.rejected(lambda: provider_request.validate_import_url(value), "importRejected")

    def test_http_pdf_gate_and_cumulative_attempt_headers(self):
        current = provider_request.validate_import_url("https://example.org/a.pdf")
        budget = provider_request.ResourceBudget("import")
        for status in provider_request.POLICIES["redirectStatuses"]:
            admitted = provider_request.validate_http_response(current, status, [("Location", "/b.pdf")], b"", budget)
            self.assertEqual(admitted.kind, "redirect")
        self.assertEqual(budget.values["redirects"], 5)
        self.rejected(lambda: provider_request.validate_http_response(current, 302, [("Location", "/b.pdf")], b"", budget), "importRejected")
        good = [("Content-Type", "Application/PDF; version=1.7"), ("Content-Encoding", "identity"), ("Content-Length", "0")]
        budget = provider_request.ResourceBudget("import")
        admitted = provider_request.validate_http_response(current, 200, good, b"%PDF-1.7", budget)
        self.assertEqual(admitted.kind, "pdf")
        self.assertGreater(budget.values["headerBytes"], 0)
        self.assertEqual(budget.values["bodyBytes"], 0)
        # Actual reads, not dishonest Content-Length, consume body budget.
        budget.add("bodyBytes", provider_request.LIMITS["pdfBytes"])
        self.rejected(lambda: budget.add("bodyBytes", 1), "importRejected")
        for status, headers, prefix in ((206, good, b"%PDF-"), (200, [("Content-Type", "text/html")], b"%PDF-"),
                                        (200, good, b"\n%PDF-"), (200, good, b"PK%PDF-"),
                                        (200, [("Content-Type", "application/pdf"), ("Content-Encoding", "gzip")], b"%PDF-"),
                                        (302, [], b""), (302, [("Location", "/a"), ("location", "/b")], b""),
                                        (200, [("Content-Type", "application/pdf"), ("content-type", "application/pdf")], b"%PDF-")):
            self.rejected(lambda: provider_request.validate_http_response(current, status, headers, prefix, provider_request.ResourceBudget("import")), "importRejected")
        self.assertTrue(provider_request.validate_pdf_signature(b"%PDF-", None, "localPDF"))
        for prefix in (b"", b"%PD", b"x%PDF-", b"\xef\xbb\xbf%PDF-"):
            self.rejected(lambda: provider_request.validate_pdf_signature(prefix, None, "localPDF"), "importRejected")
        budget = provider_request.ResourceBudget("import")
        many = [("X", "a")] * 64
        provider_request.validate_http_response(current, 302, [("Location", "/b")], b"", budget)
        self.rejected(lambda: provider_request.validate_http_response(current, 200, many, b"%PDF-", budget), "importRejected")

    def test_pdf_signature_mime_uses_strict_utf8_byte_bound(self):
        base = "application/pdf;"
        cap = provider_request.LIMITS["headerBytes"]
        remaining = cap - len(base.encode("utf-8"))
        mime = base + "𐐀" * (remaining // 4) + "x" * (remaining % 4)
        self.assertEqual(len(mime.encode("utf-8")), cap)
        for kind in ("httpsPDF", "arxivPDF", "arxivAbstract"):
            self.assertTrue(provider_request.validate_pdf_signature(b"%PDF-", mime, kind))
            self.rejected(lambda: provider_request.validate_pdf_signature(b"%PDF-", mime + "x", kind),
                          "importRejected", "import")
            self.rejected(lambda: provider_request.validate_pdf_signature(b"%PDF-", base + "\ud800", kind),
                          "importRejected", "import")

    def test_every_metric_mode_unit_scope_ceiling_and_terminal_failure(self):
        for kind, resource in provider_request.CONTRACT["resources"].items():
            for metric, policy in resource["metrics"].items():
                with self.subTest(kind=kind, metric=metric):
                    budget = provider_request.ResourceBudget(kind)
                    ceiling = provider_request.LIMITS[policy["limit"]]
                    change = budget.add if policy["mode"] == "cumulative" else budget.observe
                    self.assertEqual(change(metric, ceiling), ceiling)
                    self.assertEqual(budget.values[metric], ceiling)
                    self.rejected(lambda: change(metric, 1 if policy["mode"] == "cumulative" else ceiling + 1))
                    self.rejected(lambda: change(metric, 0))
                    wrong = provider_request.ResourceBudget(kind)
                    wrong_change = wrong.observe if policy["mode"] == "cumulative" else wrong.add
                    self.rejected(lambda: wrong_change(metric, 0))
                    self.assertIn(policy["unit"], ("bytes", "count", "ms"))
                    self.assertEqual(budget.scope, "connection" if kind == "rpc" else "attempt")
        for invalid in (-1, True, 1.0, "1", None):
            self.rejected(lambda: provider_request.ResourceBudget("import").add("bodyBytes", invalid), "importRejected")
        self.rejected(lambda: provider_request.ResourceBudget("parser").observe("unknown", 0), "parserLimit")
        budget = provider_request.ResourceBudget("import")
        budget.observe("elapsedMs", 10)
        self.rejected(lambda: budget.observe("elapsedMs", 9), "importRejected")
        gauge = provider_request.ResourceBudget("parser")
        gauge.observe("pdfBytes", 100)
        gauge.observe("pdfBytes", 100)
        self.assertEqual(gauge.values["pdfBytes"], 100)
        gauge.observe("rssBytes", 100)
        gauge.observe("rssBytes", 50)
        self.assertEqual(gauge.values["rssBytes"], 50)
        with self.assertRaises(TypeError):
            gauge.values["rssBytes"] = 1
        with self.assertRaises(AttributeError):
            gauge.kind = "import"

    def test_pool_held_mutex_rejects_without_wait_or_count_mutation(self):
        pool = provider_request.ResourcePool("import")
        before = pool.active
        mutex = provider_request._POOL_LOCK
        guarded = Mock(wraps=mutex)

        def acquire(blocking=True):
            # Fail before entering a blocking call, so a regression cannot
            # deadlock this test while the caller itself holds the mutex.
            self.assertIs(blocking, False)
            return mutex.acquire(blocking=blocking)

        guarded.acquire.side_effect = acquire
        with mutex:
            with patch.object(provider_request, "_POOL_LOCK", guarded):
                self.assertIsNone(pool.acquire())
                guarded.acquire.assert_called_once_with(blocking=False)
                guarded.release.assert_not_called()
        self.assertEqual(pool.active, before)
        lease = pool.acquire()
        self.assertIsNotNone(lease)
        try:
            self.assertEqual(pool.active, before + 1)
        finally:
            lease.close()
            lease.close()
        self.assertEqual(pool.active, before)

    def test_pool_process_scope_nonblocking_idempotent_close(self):
        first = provider_request.ResourcePool("import")
        second = provider_request.ResourcePool("import")
        a = first.acquire()
        b = second.acquire()
        self.assertIsNotNone(a)
        self.assertIsNotNone(b)
        try:
            self.assertIsNone(first.acquire())
            self.assertEqual(second.active, 2)
            a.close()
            a.close()
            self.assertEqual(second.active, 1)
            with first.acquire() as third:
                self.assertIsNotNone(third)
                self.assertIsNone(second.acquire())
            self.assertEqual(first.active, 1)
        finally:
            a.close()
            b.close()
        self.assertEqual(first.active, 0)
        parser = provider_request.ResourcePool("parser")
        with parser.acquire():
            self.assertIsNone(provider_request.ResourcePool("parser").acquire())
        try:
            with parser.acquire():
                raise RuntimeError("synthetic scope exit")
        except RuntimeError:
            pass
        self.assertEqual(parser.active, 0)
        barrier = threading.Barrier(8)
        leases = []
        guard = threading.Lock()
        def acquire():
            barrier.wait()
            lease = parser.acquire()
            with guard:
                leases.append(lease)
        workers = [threading.Thread(target=acquire) for _ in range(8)]
        for worker in workers:
            worker.start()
        for worker in workers:
            worker.join()
        self.assertEqual(sum(lease is not None for lease in leases), 1)
        for lease in leases:
            if lease:
                lease.close()
        self.assertEqual(parser.active, 0)

    def test_authorization_replacement_cannot_transfer_issuance(self):
        req = request("paperChat")
        other = request("paperChat", quotes=("Changed canonical quote",))
        oversized = plain(req.wire.as_record())
        oversized["input"]["evidence"]["items"] = [
            {"anchor": {"pageIndex": 0, "sentenceID": i}, "quote": "\x00" * 4096, "rank": i}
            for i in range(4)]
        oversized["input"]["evidence"]["selection"]["candidateCount"] = 4
        unbudgeted = provider_request.WireRequest(**oversized)
        nested = replace(req, wire=other.wire, _seal=replace(req._seal, wire=other.wire))
        nested_overbudget = replace(req, wire=unbudgeted, _seal=replace(req._seal, wire=unbudgeted))
        for forged in (replace(req, wire=other.wire), replace(req, context=other.context), replace(req, wire=unbudgeted), nested, nested_overbudget):
            self.rejected(lambda: provider_request.encode_request(forged), "sourceMismatch")
            self.rejected(lambda: provider_request.validate_result(provider_request.canonical_bytes(envelope(forged)), forged), "sourceMismatch")
            self.rejected(lambda: provider_request.wrap_model_result(provider_request.canonical_bytes(result_member(forged)), forged), "sourceMismatch")
        self.assertEqual(provider_request.encode_request(replace(req)), provider_request.encode_request(req))

    def test_translation_cache_injection_replacement_and_foreign_corpus(self):
        base = context("translation", quotes=("x",) * 33)
        fake = (((0,),), {(0,): 0})
        with self.assertRaises(TypeError):
            base._plans[(0, "ko")] = fake
        with self.assertRaises(FrozenInstanceError):
            base._plans = {(0, "ko"): fake}
        self.rejected(lambda: base.for_translation_batch("ko", (0,)), "sourceMismatch")
        self.assertEqual(provider_request.plan_translation_batches(0, "ko", base), (tuple(range(32)), (32,)))
        with self.assertRaises(TypeError):
            base._plans[(0, "ko")][1][(0,)] = 0
        with self.assertRaises(TypeError):
            base._plans[(0, "ko")] = fake
        foreign = replace(base, sentences=sentences(("y",) * 33))
        self.assertIsNot(foreign._plan_store, base._plan_store)
        self.assertEqual(dict(foreign._plans), {})
        with self.assertRaises(TypeError):
            replace(base, sentences=foreign.sentences, _plan_store=base._plan_store)
        self.rejected(lambda: base._plan_store.plan(0, "ko", foreign), "sourceMismatch")
        bad = context("translation", quotes=("x",) * 33 + ("z" * 4097,))
        with self.assertRaises(TypeError):
            bad._plans[(0, "ko")] = fake
        self.rejected(lambda: bad.for_translation_batch("ko", (0,)), "inputLimit")
        self.assertEqual(dict(bad._plans), {})
        self.rejected(lambda: provider_request.build_request("translation", bad.sources, bad, uuid(1)), "inputLimit")

    def test_translation_work_counts_linear_and_batch_corpus_shared(self):
        counts = []
        schema = provider_request._schema
        compute = provider_request._compute_page_plan
        for size in (2048, 4096):
            work = {"schema": 0, "plan": 0}
            def count_schema(*args, **kwargs):
                work["schema"] += 1
                return schema(*args, **kwargs)
            def count_plan(*args, **kwargs):
                work["plan"] += 1
                return compute(*args, **kwargs)
            with patch.object(provider_request, "_schema", count_schema), patch.object(provider_request, "_compute_page_plan", count_plan):
                base = context("translation", quotes=("x",) * size)
                plan = provider_request.plan_translation_batches(0, "ko", base)
                for batch in plan:
                    bound = base.for_translation_batch("ko", batch)
                    self.assertIs(bound.sentences, base.sentences)
                    self.assertIs(bound._plans, base._plans)
                    req = provider_request.build_request("translation", bound.sources, bound, uuid(1))
                    provider_request.authorize_request(req.wire, bound)
                    provider_request.encode_request(req)
                self.assertEqual(work["plan"], 1)
                self.assertEqual(tuple(s for batch in plan for s in batch), tuple(range(size)))
                counts.append(work["schema"])
        self.assertLessEqual(counts[1], counts[0] * 2 + 100)
        bad = context("translation", quotes=("x",) * 2048 + ("z" * 4097,))
        self.rejected(lambda: bad.for_translation_batch("ko", tuple(range(32))), "inputLimit")
        self.assertEqual(bad._plans, {})

    def test_copied_leases_are_identical_and_cannot_double_release(self):
        pool = provider_request.ResourcePool("parser")
        lease = pool.acquire()
        shallow, deep = copy.copy(lease), copy.deepcopy(lease)
        self.assertIs(shallow, lease)
        self.assertIs(deep, lease)
        lease.close()
        replacement = pool.acquire()
        try:
            shallow.close()
            deep.close()
            self.assertEqual(pool.active, 1)
            self.assertIsNone(pool.acquire())
        finally:
            replacement.close()
        self.rejected(lambda: provider_request.ResourceLease("parser", object()), "invalidShape")

    def test_oversized_direct_inputs_reject_before_encoding_or_header_iteration(self):
        original_utf8 = provider_request._utf8
        oversized = "x" * (provider_request.LIMITS["urlBytes"] + 1)
        def bounded_utf8(value, *args):
            self.assertNotEqual(value, oversized)
            return original_utf8(value, *args)
        with patch.object(provider_request, "_utf8", side_effect=bounded_utf8):
            self.rejected(lambda: provider_request.validate_import_url(oversized), "importRejected")
            self.rejected(lambda: provider_request.resolve_redirect_url("https://example.org/a", oversized), "importRejected")
            self.rejected(lambda: provider_request._schema(oversized, provider_request.CONTRACT["definitions"]["language"]))
        class UniterableHeaders(list):
            def __iter__(self):
                self.fail_iteration = True
                raise AssertionError("oversized headers were iterated")
        headers = UniterableHeaders([(None, None)] * 65)
        self.rejected(lambda: provider_request.validate_http_response("https://example.org/a", 200, headers, b"%PDF-", provider_request.ResourceBudget("import")), "importRejected")
        big_header = "x" * (provider_request.LIMITS["headerBytes"] + 1)
        with patch.object(provider_request.re, "fullmatch", wraps=provider_request.re.fullmatch) as regex:
            self.rejected(lambda: provider_request.validate_http_response("https://example.org/a", 200, [("X", big_header)], b"%PDF-", provider_request.ResourceBudget("import")), "importRejected")
            regex.assert_not_called()

    def test_safe_error_traceback_suppresses_underlying_port_value(self):
        invalid_url = "https://example.org:SECRET_VALUE/a"
        try:
            provider_request.validate_import_url(invalid_url)
        except provider_request.ContractError as error:
            rendered = "".join(traceback.format_exception(type(error), error, error.__traceback__))
            self.assertTrue(error.__suppress_context__)
            self.assertNotIn("SECRET_VALUE", rendered)
            self.assertNotIn("Port could not be cast", rendered)
            self.assertNotIn("ValueError:", rendered)
        else:
            self.fail("invalid port accepted")

    def test_unknown_contract_keywords_rules_refs_and_modes_reject(self):
        original = plain(provider_request.CONTRACT)
        variants = []
        for rules in ({"fixedProbe": {"unknownKeyword": True}}, ["fixedProbe", "fixedProbe"], [1], ["unknownRule"], None):
            malformed = copy.deepcopy(original)
            malformed["operations"]["connectionTest"]["rules"] = rules
            variants.append(malformed)
        extra = copy.deepcopy(original)
        extra["fallback"] = {}
        variants.append(extra)
        extra = copy.deepcopy(original)
        extra["definitions"]["item"]["additionalProperties"] = True
        variants.append(extra)
        extra = copy.deepcopy(original)
        extra["definitions"]["item"]["rules"] = ["unknownRule"]
        variants.append(extra)
        extra = copy.deepcopy(original)
        extra["rules"].append("unknownRule")
        variants.append(extra)
        extra = copy.deepcopy(original)
        extra["definitions"]["item"]["fields"]["quote"] = {"ref": "unknown"}
        variants.append(extra)
        extra = copy.deepcopy(original)
        extra["definitions"]["item"] = {"ref": "item"}
        variants.append(extra)
        extra = copy.deepcopy(original)
        extra["resources"]["parser"]["metrics"]["rssBytes"]["mode"] = "reset"
        variants.append(extra)
        extra = copy.deepcopy(original)
        extra["operations"]["fakeAdapter"] = extra["operations"]["connectionTest"]
        variants.append(extra)
        for modified in variants:
            self.rejected(lambda: provider_request.load_contract(provider_request.canonical_bytes(modified)), "contractDefinition")


    def test_fixed_v1_authority_rejects_schema_rule_and_resource_rewrites(self):
        original = plain(provider_request.CONTRACT)
        changes = [
            (("definitions", "item", "fields", "rank"), None),
            (("definitions", "turns", "rules"), None),
            (("definitions", "turns", "rules"), []),
            (("definitions", "turns", "rules"), ["snapshotIdentity"]),
            (("definitions", "sentence", "rules"), ["historyPairs"]),
            (("resources", "import", "metrics", "bodyBytes", "mode"), "gauge"),
            (("resources", "import", "metrics", "bodyBytes", "unit"), "count"),
            (("resources", "import", "metrics", "bodyBytes", "limit"), "readBufferBytes"),
            (("resources", "import", "metrics", "bodyBytes"), None),
            (("resources", "import", "metrics", "extra"), original["resources"]["import"]["metrics"]["bodyBytes"]),
            (("pools", "parser", "limit"), "importConcurrency"),
            (("limits", "parserConcurrency"), 2),
        ]
        for path, value in changes:
            modified = copy.deepcopy(original)
            node = modified
            for key in path[:-1]:
                node = node[key]
            if value is None:
                del node[path[-1]]
            else:
                node[path[-1]] = value
            self.rejected(lambda: provider_request.load_contract(provider_request.canonical_bytes(modified)), "contractDefinition")
        modified = copy.deepcopy(original)
        modified["limits"]["objectKeys"] = modified["limits"].pop("objectKeys")
        self.rejected(lambda: provider_request.load_contract(provider_request.canonical_bytes(modified)), "contractDefinition")
        reordered = dict(reversed(list(original.items())))
        formatted = json.dumps(reordered, ensure_ascii=False, indent=2).encode("utf-8")
        self.assertEqual(provider_request.load_contract(formatted), provider_request.CONTRACT)
        content = "K é é"
        req = request("paperChat", quotes=(content,))
        parsed = provider_request.parse_request(provider_request.encode_request(req))
        self.assertEqual(parsed.input["evidence"]["items"][0]["quote"].encode("utf-8"), content.encode("utf-8"))

    def test_validated_source_kind_cannot_downgrade_redirect_or_http(self):
        current = provider_request.validate_import_url("https://arxiv.org/pdf/2401.12345", "arxivPDF")
        foreign = "https://example.org/paper.pdf"
        for override in ("httpsPDF", "arxivAbstract", "", "PRIVATE"):
            self.rejected(lambda: provider_request.resolve_redirect_url(current, foreign, override), "importRejected")
            budget = provider_request.ResourceBudget("import")
            self.rejected(lambda: provider_request.validate_http_response(current, 302, [("Location", foreign)], b"", budget, override), "importRejected")
            self.rejected(lambda: provider_request.validate_http_response(current, 200, [("Content-Type", "application/pdf")], b"%PDF-", budget, override), "importRejected")
            self.assertEqual(budget.values["headerCount"], 0)
            self.assertEqual(budget.values["redirects"], 0)
        for override in (None, "arxivPDF"):
            self.rejected(lambda: provider_request.resolve_redirect_url(current, foreign, override), "importRejected")
            approved = provider_request.resolve_redirect_url(current, "/pdf/2401.12345v2", override)
            self.assertEqual(approved.sourceKind, "arxivPDF")
            budget = provider_request.ResourceBudget("import")
            response = provider_request.validate_http_response(current, 302, [("Location", "/pdf/2401.12345v2")], b"", budget, override)
            self.assertEqual(response.url, approved)
        self.assertEqual(provider_request.resolve_arxiv_abstract_url("https://arxiv.org/abs/2401.12345").sourceKind, "arxivPDF")


if __name__ == "__main__":
    unittest.main()
