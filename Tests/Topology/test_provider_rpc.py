import importlib.util
import json
from pathlib import Path
import struct
import unittest


_SOURCE = Path(__file__).resolve().parents[2] / "Contracts" / "ProviderRPC" / "provider_rpc.py"
_SPEC = importlib.util.spec_from_file_location("provider_rpc", _SOURCE)
rpc = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(rpc)

ID = "01234567-89ab-4cde-8123-456789abcdef"
STAGE = "11234567-89ab-4cde-8123-456789abcdef"
INTENT = "21234567-89ab-4cde-8123-456789abcdef"
CLEANUP = "31234567-89ab-4cde-8123-456789abcdef"
SELECTOR = {"kind": None, "slotID": None, "generation": 0, "model": None}
LOGIN = {"stageID": STAGE, "intentID": INTENT}
CLEAN = {"state": "clean", "stopped": True, "closed": True, "absent": True}
PROBE = {"outcome": "denied", "reason": "permissionDenied", "syscallObserved": True,
         "syscallResult": -1, "errno": 13, "beganAtNs": 1, "endedAtNs": 2}
CASES = [
    ("product.hello", {"major": 2, "minor": 0, "capabilities": ["product-v1"]},
     {"major": 2, "minor": 0, "capabilities": ["product-v1"]}),
    ("product.loginStart", {**LOGIN, "expectedSelector": SELECTOR, "mode": "browser", "model": "gpt-5"},
     {**LOGIN, "instructions": {"mode": "browser", "authUrl": "https://example.test/login"}}),
    ("product.loginObserve", LOGIN, {**LOGIN, "state": "pending"}),
    ("product.connectionTest", {**LOGIN, "expectedSelector": SELECTOR},
     {**LOGIN, "expectedSelector": SELECTOR, "state": "usable", "text": "PAPERLENS_OK"}),
    ("product.loginCancel", LOGIN, {**LOGIN, "accepted": False}),
    ("product.stageRetire", {**LOGIN, "cleanupID": CLEANUP}, {**LOGIN, "cleanupID": CLEANUP, **CLEAN}),
    ("product.startupCleanup", {"cleanupID": CLEANUP, "expectedSelector": SELECTOR},
     {"cleanupID": CLEANUP, "expectedSelector": SELECTOR, **CLEAN}),
    ("product.paperPurge", {"cleanupID": CLEANUP, "paperID": ID, "generation": 1, "correlationID": INTENT},
     {"cleanupID": CLEANUP, "paperID": ID, "generation": 1, "correlationID": INTENT, **CLEAN}),
    ("hello", {"major": 1, "minor": 1, "capabilities": ["topology-v1"]},
     {"major": 1, "minor": 1, "capabilities": ["topology-v1"]}),
    ("topology.runtime", {}, {"sdkImported": True, "cliInitialized": False, "architecture": "arm64"}),
    ("topology.prepare", {"runID": ID}, {"prepared": True}),
    ("topology.identity", {"runID": ID}, {"bridgePID": 1, "pythonPID": 2147483647}),
    ("topology.probe", {"runID": ID, "caseID": "ownZoneReadWrite"}, PROBE),
    ("topology.cleanup", {"runID": ID}, {"absent": True}),
    ("topology.attemptPrepare", {"runID": ID, "paperID": ID, "generation": 1, "correlationID": ID}, {"prepared": True}),
    ("topology.attemptTerminal", {"runID": ID, "paperID": ID, "generation": 1, "correlationID": ID, "outcome": "success"}, {"absent": True}),
    ("topology.attemptRecover", {"runID": ID}, {"absent": True}),
    ("topology.paperPurge", {"runID": ID, "paperID": ID, "generation": 1, "correlationID": ID}, {"absent": True, "drained": True}),
    ("topology.wait", {"durationMs": 1}, {"elapsed": True}),
    ("cancel", {"targetID": ID}, {"accepted": False}),
]


def request(method="topology.runtime", params=None, **changes):
    value = {"kind": "request", "id": ID, "method": method, "timeoutMs": 10000,
             "params": {} if params is None else params}
    value.update(changes)
    return value


def raw(body):
    if isinstance(body, str):
        body = body.encode("utf-8")
    return struct.pack(">I", len(body)) + body


class ProviderRPCTests(unittest.TestCase):
    # Typed wire fixtures only: none represents an SDK call or cleanup observation.
    def product_terminal(self, result):
        return {"kind": "result", "id": ID, "result": result}

    def test_product_selectors_correlations_and_generations(self):
        for method, params, result in CASES[:8]:
            for key in ("stageID", "intentID", "cleanupID", "paperID", "correlationID"):
                if key not in params:
                    continue
                for invalid in (ID.upper(), ID.replace("4cde", "1cde"), True, 1, None):
                    self.rejects(lambda: rpc.validate_request(request(method, {**params, key: invalid})), "invalidParams")
                    self.rejects(lambda: rpc.validate_terminal(self.product_terminal({**result, key: invalid}), method))
        for kind in (None, "openAIAPIKey", "codexChatGPT"):
            for generation in ((0, 1, 9223372036854775807) if kind is None else (1, 9223372036854775807)):
                for model in (None, "gpt-5"):
                    selector = {"kind": kind, "slotID": None if kind is None else ID, "generation": generation, "model": model}
                    rpc.validate_request(request("product.connectionTest", {**LOGIN, "expectedSelector": selector}))
        invalid_selectors = [
            {**SELECTOR, "slotID": ID}, {**SELECTOR, "kind": "codexChatGPT"},
            {**SELECTOR, "kind": "unknown", "slotID": ID, "generation": 1},
            {**SELECTOR, "kind": "openAIAPIKey", "slotID": ID},
            {**SELECTOR, "kind": "codexChatGPT", "slotID": ID.upper(), "generation": 1},
            {**SELECTOR, "extra": 1}, {key: value for key, value in SELECTOR.items() if key != "model"},
        ]
        invalid_selectors += [{**SELECTOR, "generation": value} for value in (-1, 9223372036854775808, True, False, 1.0, "1", None)]
        invalid_selectors += [{**SELECTOR, "model": value} for value in ("", True, 1, [])]
        for selector in invalid_selectors:
            self.rejects(lambda: rpc.validate_request(request("product.connectionTest", {**LOGIN, "expectedSelector": selector})), "invalidParams")
            self.rejects(lambda: rpc.validate_terminal(self.product_terminal({**CASES[3][2], "expectedSelector": selector}), "product.connectionTest"))
        for generation in (0, 2147483648, True, 1.0, None):
            params = CASES[7][1]
            self.rejects(lambda: rpc.validate_request(request("product.paperPurge", {**params, "generation": generation})), "invalidParams")

    def test_product_states_proofs_and_method_separation(self):
        for state in ("pending", "authenticated", "failed", "cancelled", "timeout", "exited"):
            rpc.validate_terminal(self.product_terminal({**LOGIN, "state": state}), "product.loginObserve")
        for state in ("usable", "clean", "unknown", True, None):
            self.rejects(lambda: rpc.validate_terminal(self.product_terminal({**LOGIN, "state": state}), "product.loginObserve"))
        for method, _, result in CASES[5:8]:
            for key in ("stopped", "closed", "absent"):
                self.rejects(lambda: rpc.validate_terminal(self.product_terminal({**result, key: False}), method))
                rpc.validate_terminal(self.product_terminal({**result, "state": "unknown", key: False}), method)
                for invalid in (0, 1, "true", None):
                    self.rejects(lambda: rpc.validate_terminal(self.product_terminal({**result, "state": "unknown", key: invalid}), method))
            rpc.validate_terminal(self.product_terminal({**result, "state": "unknown"}), method)
        for accepted in (True, False):
            cancel = self.product_terminal({**LOGIN, "accepted": accepted})
            rpc.validate_terminal(cancel, "product.loginCancel")
            self.rejects(lambda: rpc.validate_terminal(cancel, "product.stageRetire"))
        for invalid in (0, 1, "true", None):
            self.rejects(lambda: rpc.validate_terminal(self.product_terminal({**LOGIN, "accepted": invalid}), "product.loginCancel"))
        for changes in ({"state": "authenticated"}, {"text": "OK"}, {"text": "PAPERLENS_OK\n"}):
            self.rejects(lambda: rpc.validate_terminal(self.product_terminal({**CASES[3][2], **changes}), "product.connectionTest"))
        for method in ("product.hello",):
            for hello in ({"major": 1, "minor": 1, "capabilities": ["topology-v1"]},
                          {"major": 2, "minor": 0, "capabilities": ["topology-v1"]}):
                self.rejects(lambda: rpc.validate_request(request(method, hello)), "invalidParams")
                self.rejects(lambda: rpc.validate_terminal(self.product_terminal(hello), method))
        for method, _, result in CASES[:8]:
            self.rejects(lambda: rpc.validate_terminal(self.product_terminal(result), "topology.runtime"))

    def test_product_url_authority_delimiter_uses_utf8_boundaries(self):
        for url in ("https://example.test:443/́login", "https://example.test:443?́login", "https://example.test:443#́login"):
            for instructions in ({"mode": "browser", "authUrl": url},
                                 {"mode": "device", "userCode": "CODE", "verificationUrl": url}):
                with self.subTest(url=url, mode=instructions["mode"]):
                    value = self.product_terminal({**LOGIN, "instructions": instructions})
                    rpc.validate_terminal(value, "product.loginStart")
                    rpc.validate_terminal(rpc.decode_frame(rpc.encode_frame(value)), "product.loginStart")

    def test_product_login_instructions_and_narrow_url_exception(self):
        def browser(url):
            return self.product_terminal({**LOGIN, "instructions": {"mode": "browser", "authUrl": url}})

        def reject_wire(value):
            self.rejects(lambda: rpc.encode_frame(value))
            self.rejects(lambda: rpc.decode_frame(raw(json.dumps(value, ensure_ascii=False))))

        prefix = "https://example.test/"
        for size in (256, 257, 4096):
            url = prefix + "a" * (size - len(prefix))
            value = browser(url)
            self.assertEqual(rpc.decode_frame(rpc.encode_frame(value)), value)
            rpc.validate_terminal(value, "product.loginStart")
            self.rejects(lambda: rpc.validate_terminal(value, "product.loginObserve"))
            escaped = json.dumps(value).replace("a", "\\u0061")
            self.assertEqual(rpc.decode_frame(raw(escaped)), value)
        for size in (256, 257, 4096, 4097):
            remaining = size - len(prefix)
            url = prefix + "é" * (remaining // 2) + "x" * (remaining % 2)
            self.assertEqual(len(url.encode("utf-8")), size)
            if size <= 4096:
                self.assertEqual(rpc.decode_frame(rpc.encode_frame(browser(url))), browser(url))
            else:
                reject_wire(browser(url))
        reject_wire(browser(prefix + "a" * (4097 - len(prefix))))
        long_url = prefix + "a" * 257
        for value in ({"authUrl": long_url}, {"result": {"instructions": {"mode": "browser", "authUrl": long_url}}},
                      {**browser(long_url), "extra": 1}, {**browser(long_url), "id": "invalid"},
                      self.product_terminal({**LOGIN, "instructions": {"mode": "device", "authUrl": long_url}}),
                      {"x": {"authUrl": long_url}}, {"k" * 257: "x"}):
            reject_wire(value)
        for url in ("http://example.test", "https://", "https:///path", "https://user@example.test", "https://u:p@example.test",
                    "https://example.test:", "https://example.test:abc", "https://example.test:65536", "https://example.test:-1",
                    "https://example.test/a b", "https://example.test/\n", "https://example.test/\x00", "https://example.test/\x7f",
                    "https://example.test/\\x", "https://example.test/\u00a0"):
            self.rejects(lambda: rpc.validate_terminal(browser(url), "product.loginStart"))
            if url != "https://":
                reject_wire(browser(url + "a" * 257))
        for mode in ("browser", "device"):
            rpc.validate_request(request("product.loginStart", {**CASES[1][1], "mode": mode}))
        for key, invalids in (("mode", ("unknown", True, None)), ("model", ("", None, True, 1))):
            for invalid in invalids:
                self.rejects(lambda: rpc.validate_request(request("product.loginStart", {**CASES[1][1], key: invalid})), "invalidParams")
        for size in (256, 257):
            instructions = {"mode": "device", "userCode": "CODE", "verificationUrl": prefix + "a" * (size - len(prefix))}
            value = self.product_terminal({**LOGIN, "instructions": instructions})
            if size == 256:
                rpc.validate_terminal(rpc.decode_frame(rpc.encode_frame(value)), "product.loginStart")
            else:
                reject_wire(value)
        for size in (256, 257):
            value = self.product_terminal({**LOGIN, "instructions": {"mode": "device", "userCode": "a" * size, "verificationUrl": prefix}})
            if size == 256:
                rpc.validate_terminal(rpc.decode_frame(rpc.encode_frame(value)), "product.loginStart")
            else:
                reject_wire(value)
        for instructions in ({"mode": "device", "userCode": "", "verificationUrl": prefix},
                             {"mode": "device", "userCode": "CODE", "verificationUrl": "http://example.test"},
                             {"mode": "browser", "authUrl": prefix, "userCode": "CODE"},
                             {"mode": "browser"}, {"mode": "unknown", "authUrl": prefix},
                             {"mode": "device", "userCode": "CODE", "verificationUrl": prefix, "authUrl": prefix}):
            self.rejects(lambda: rpc.validate_terminal(self.product_terminal({**LOGIN, "instructions": instructions}), "product.loginStart"))
        self.rejects(lambda: rpc.decode_frame(raw(json.dumps(browser(long_url)).replace("example", "exam\\ud800ple"))))
        invalid_utf8 = json.dumps(browser(long_url)).encode("utf-8").replace(b"example", b"exam\xffple")
        self.rejects(lambda: rpc.decode_frame(raw(invalid_utf8)))

    def rejects(self, action, code="protocolViolation"):
        with self.assertRaises(rpc.ProtocolError) as caught:
            action()
        self.assertEqual(caught.exception.code, code)

    def test_every_method_round_trip_and_closed_fields(self):
        self.assertEqual({case[0] for case in CASES}, set(rpc.CONTRACT['methods']))
        for method, params, result in CASES:
            with self.subTest(method=method):
                value = request(method, params)
                decoded = rpc.decode_frame(rpc.encode_frame(value))
                self.assertEqual(decoded, value)
                rpc.validate_request(decoded)
                terminal = {"kind": "result", "id": ID, "result": result}
                rpc.validate_terminal(rpc.decode_frame(rpc.encode_frame(terminal)), method)
                self.rejects(lambda: rpc.validate_request(request(method, {**params, "path": "/tmp/forbidden"})), "invalidParams")
                self.rejects(lambda: rpc.validate_terminal({**terminal, "message": "forbidden"}, method))
                self.rejects(lambda: rpc.validate_terminal({**terminal, "result": {**result, "message": "forbidden"}}, method))
                self.rejects(lambda: rpc.validate_terminal({**terminal, "result": {}}, method))
                for key in params:
                    missing = {name: item for name, item in params.items() if name != key}
                    self.rejects(lambda: rpc.validate_request(request(method, missing)), "invalidParams")
                for key in result:
                    missing = {name: item for name, item in result.items() if name != key}
                    self.rejects(lambda: rpc.validate_terminal({**terminal, "result": missing}, method))

    def test_attempt_identity_bounds_and_closed_outcomes(self):
        identity = {"runID": ID, "paperID": ID, "generation": 1, "correlationID": ID}
        for method in ("topology.attemptPrepare", "topology.attemptTerminal"):
            params = {**identity, **({"outcome": "success"} if method.endswith("Terminal") else {})}
            for generation in (1, 2147483647):
                rpc.validate_request(request(method, {**params, "generation": generation}))
            for generation in (0, -1, 2147483648, True, False, 1.0, "1", None):
                self.rejects(lambda: rpc.validate_request(request(method, {**params, "generation": generation})), "invalidParams")
            for key in ("runID", "paperID", "correlationID"):
                for invalid in (ID.upper(), "../fixture", "01234567-89ab-1cde-8123-456789abcdef", 1, None):
                    self.rejects(lambda: rpc.validate_request(request(method, {**params, key: invalid})), "invalidParams")
        for outcome in ("success", "failure", "cancelled"):
            rpc.validate_request(request("topology.attemptTerminal", {**identity, "outcome": outcome}))
        for outcome in ("providerSuccess", "timeout", "SUCCESS", 1, None, True):
            self.rejects(lambda: rpc.validate_request(request("topology.attemptTerminal", {**identity, "outcome": outcome})), "invalidParams")
        self.rejects(lambda: rpc.validate_request(request("topology.attemptRecover", {"runID": "invalid"})), "invalidParams")
        for method, key in (("topology.attemptPrepare", "prepared"), ("topology.attemptTerminal", "absent"), ("topology.attemptRecover", "absent")):
            for value in (True, False):
                rpc.validate_terminal({"kind": "result", "id": ID, "result": {key: value}}, method)
            for value in (1, 0, "true", None):
                self.rejects(lambda: rpc.validate_terminal({"kind": "result", "id": ID, "result": {key: value}}, method))
            self.rejects(lambda: rpc.validate_terminal({"kind": "event", "id": ID, "result": {key: True}}, method))
            rpc.validate_terminal({"kind": "error", "id": ID, "code": "unavailable"}, method)

    def test_paper_purge_identity_bounds_and_envelope_separation(self):
        method = "topology.paperPurge"
        identity = {"runID": "11234567-89ab-4cde-8123-456789abcdef",
                    "paperID": "21234567-89ab-4cde-8123-456789abcdef",
                    "generation": 1, "correlationID": "31234567-89ab-4cde-8123-456789abcdef"}
        retry_id = "41234567-89ab-4cde-8123-456789abcdef"
        for envelope_id in (ID, retry_id):
            decoded = rpc.decode_frame(rpc.encode_frame(request(method, identity, id=envelope_id)))
            rpc.validate_request(decoded)
            self.assertEqual(decoded["id"], envelope_id)
            self.assertEqual(decoded["params"], identity)
            self.assertNotEqual(decoded["id"], decoded["params"]["correlationID"])
            terminal = {"kind": "result", "id": envelope_id, "result": {"absent": True, "drained": True}}
            response = rpc.decode_frame(rpc.encode_frame(terminal))
            rpc.validate_terminal(response, method)
            self.assertEqual(response["id"], decoded["id"])
        for generation in (1, 2147483647):
            rpc.validate_request(rpc.decode_frame(rpc.encode_frame(request(method, {**identity, "generation": generation}))))
        for generation in (0, -1, 2147483648, True, False, 1.0, "1", None):
            with self.subTest(generation=generation):
                decoded = rpc.decode_frame(rpc.encode_frame(request(method, {**identity, "generation": generation})))
                self.rejects(lambda: rpc.validate_request(decoded), "invalidParams")
        for key in ("runID", "paperID", "correlationID"):
            for invalid in (ID.upper(), "../fixture", "01234567-89ab-1cde-8123-456789abcdef", True, False, 1, None):
                with self.subTest(key=key, invalid=invalid):
                    decoded = rpc.decode_frame(rpc.encode_frame(request(method, {**identity, key: invalid})))
                    self.rejects(lambda: rpc.validate_request(decoded), "invalidParams")
        self.rejects(lambda: rpc.validate_request(request(method, identity, id=True)))
        self.rejects(lambda: rpc.validate_request(request(method, identity, correlationID=identity["correlationID"])))
        self.rejects(lambda: rpc.validate_request(request(method, {**identity, "id": ID})), "invalidParams")

    def test_paper_purge_result_is_true_only(self):
        method = "topology.paperPurge"
        result = {"absent": True, "drained": True}
        for key in result:
            for invalid in (False, 0, 1, None, "true"):
                with self.subTest(key=key, invalid=invalid):
                    terminal = {"kind": "result", "id": ID, "result": {**result, key: invalid}}
                    decoded = rpc.decode_frame(rpc.encode_frame(terminal))
                    self.rejects(lambda: rpc.validate_terminal(decoded, method))
        rpc.validate_terminal({"kind": "error", "id": ID, "code": "unavailable"}, method)

    def test_paper_purge_duplicate_malformed_and_framing_rejection(self):
        params = {"runID": ID, "paperID": ID, "generation": 1, "correlationID": ID}
        body = json.dumps(request("topology.paperPurge", params), separators=(",", ":"))
        terminal_body = json.dumps({"kind": "result", "id": ID, "result": {"absent": True, "drained": True}}, separators=(",", ":"))
        invalid_bodies = [body[:-1], body + "{}",
                          body.replace('"id":', '"id":"' + ID + '","id":', 1),
                          body.replace('"runID":', '"runID":"' + ID + '","runID":', 1),
                          body.replace('"generation":1', '"generation":1,"generation":1'),
                          terminal_body.replace('"absent":true', '"absent":true,"absent":true'),
                          terminal_body.replace('"drained":true', '"drained":true,"drained":true')]
        for invalid in invalid_bodies:
            self.rejects(lambda: rpc.decode_frame(raw(invalid)))
        frame = raw(body)
        for invalid in (frame[:-1], frame + b"x", struct.pack(">I", 0) + frame[4:]):
            self.rejects(lambda: rpc.decode_frame(invalid))
        decoder = rpc.FrameDecoder()
        self.assertEqual(decoder.feed(frame[:3]), [])
        self.assertEqual(decoder.feed(frame[3:]), [frame])
        decoder.finish()
        decoder = rpc.FrameDecoder()
        self.assertEqual(decoder.feed(frame[:-1]), [])
        self.rejects(decoder.finish)
        self.rejects(lambda: decoder.feed(frame))

    def test_unknown_method_and_invalid_params_are_not_framing_failures(self):
        unknown = request("arbitrary.execute", {"command": "not-executed"})
        decoded = rpc.decode_frame(rpc.encode_frame(unknown))
        self.rejects(lambda: rpc.validate_request(decoded), "unknownMethod")
        invalid = request("topology.wait", {"durationMs": 0})
        self.assertEqual(rpc.decode_frame(rpc.encode_frame(invalid)), invalid)
        self.rejects(lambda: rpc.validate_request(invalid), "invalidParams")
        self.rejects(lambda: rpc.validate_terminal({"kind": "result", "id": ID, "result": {"prepared": True}}, "topology.cleanup"))
        rpc.validate_terminal({"kind": "error", "id": ID, "code": "unknownMethod"}, "missing")
        self.rejects(lambda: rpc.validate_terminal({"kind": "result", "id": ID, "result": {}}, "missing"), "unknownMethod")
        self.rejects(lambda: rpc.validate_request(request("missing", id="invalid")))
        self.rejects(lambda: rpc.validate_request(request("missing", params=[])))

    def test_protocol_error_does_not_expose_arbitrary_exception_text(self):
        error = rpc.ProtocolError("/private/provider/token: SDK traceback")
        self.assertEqual(error.code, "protocolViolation")
        self.assertEqual(str(error), "protocolViolation")
        self.assertEqual(rpc.ProtocolError("invalidParams").code, "invalidParams")

    def test_large_integer_versions_are_not_narrowed_or_rejected(self):
        for number in ("18446744073709551617", "-18446744073709551617", "9" * 5000):
            body = ('{"kind":"request","id":"' + ID + '","method":"hello","timeoutMs":1,'
                    '"params":{"major":' + number + ',"minor":1,"capabilities":["topology-v1"]}}')
            decoded = rpc.decode_frame(raw(body))
            rpc.validate_request(decoded)
            self.assertNotEqual(decoded["params"]["major"], 1)
            rpc.validate_request(rpc.decode_frame(rpc.encode_frame(decoded)))
            integer_frame = raw('{"x":' + number + '}')
            self.assertEqual(rpc.encode_frame(rpc.decode_frame(integer_frame)), integer_frame)
            self.rejects(lambda: rpc.validate_request(request("topology.wait", {"durationMs": decoded["params"]["major"]})), "invalidParams")
            response = {"kind": "result", "id": ID, "result": decoded["params"]}
            self.rejects(lambda: rpc.validate_terminal(response, "hello"))

    def test_envelope_uuid_and_timeout(self):
        for key in request():
            value = request()
            del value[key]
            self.rejects(lambda: rpc.validate_request(value))
        for changes in ({"message": "no"}, {"kind": "event"}, {"params": []}, {"method": 1},
                        {"timeoutMs": 0}, {"timeoutMs": 10001}, {"timeoutMs": True}, {"timeoutMs": 1.0}):
            self.rejects(lambda: rpc.validate_request(request(**changes)))
        for timeout in (1, 10000):
            rpc.validate_request(request(timeoutMs=timeout))
        for invalid in (ID.upper(), ID.replace("4cde", "1cde"), ID.replace("8123", "7123"),
                        "{" + ID + "}", ID.replace("-", ""), ID + "\n", 1):
            self.rejects(lambda: rpc.validate_request(request(id=invalid)))
            self.rejects(lambda: rpc.validate_request(request("topology.prepare", {"runID": invalid})), "invalidParams")
            self.rejects(lambda: rpc.validate_request(request("cancel", {"targetID": invalid})), "invalidParams")
            self.rejects(lambda: rpc.validate_terminal({"kind": "error", "id": invalid, "code": "busy"}, "hello"))

    def test_method_parameter_boundaries_and_boolean_results(self):
        for value in (1, 5000):
            rpc.validate_request(request("topology.wait", {"durationMs": value}))
        for value in (0, 5001, True, 1.0, "1", None):
            self.rejects(lambda: rpc.validate_request(request("topology.wait", {"durationMs": value})), "invalidParams")
        # Connection admission, not the schema, handles version mismatch.
        rpc.validate_request(request("hello", {"major": 2, "minor": 1, "capabilities": ["topology-v1"]}))
        for params in ({"major": True, "minor": 1, "capabilities": ["topology-v1"]},
                       {"major": 1, "minor": 1.0, "capabilities": ["topology-v1"]},
                       {"major": 1, "minor": 1, "capabilities": []},
                       {"major": 1, "minor": 1, "capabilities": ["topology-v1", "unknown"]}):
            self.rejects(lambda: rpc.validate_request(request("hello", params)), "invalidParams")
        for method, _, result in CASES:
            for key, value in result.items():
                if type(value) is bool:
                    bad = {**result, key: int(value)}
                    self.rejects(lambda: rpc.validate_terminal({"kind": "result", "id": ID, "result": bad}, method))
        for architecture in ("arm64", "x86_64"):
            rpc.validate_terminal({"kind": "result", "id": ID, "result": {"sdkImported": True, "cliInitialized": True, "architecture": architecture}}, "topology.runtime")
        self.rejects(lambda: rpc.validate_terminal({"kind": "result", "id": ID, "result": {"sdkImported": True, "cliInitialized": True, "architecture": "aarch64"}}, "topology.runtime"))
        self.rejects(lambda: rpc.validate_terminal({"kind": "result", "id": ID, "result": {"major": 2, "minor": 1, "capabilities": ["topology-v1"]}}, "hello"))

    def test_exact_hello_result_and_identity_boundaries(self):
        for major, minor in ((1, 0), (1, 2), (2, 1), (True, 1), (1, True), (1, 1.0)):
            self.rejects(lambda: rpc.validate_terminal(
                {"kind": "result", "id": ID, "result": {"major": major, "minor": minor, "capabilities": ["topology-v1"]}}, "hello"))
        self.rejects(lambda: rpc.validate_request(request("topology.identity", {"runID": "invalid"})), "invalidParams")
        for key in ("bridgePID", "pythonPID"):
            for value in (1, 2147483647):
                rpc.validate_terminal({"kind": "result", "id": ID, "result": {"bridgePID": 1, "pythonPID": 1, key: value}}, "topology.identity")
            for value in (0, -1, 2147483648, True, False, 1.0, "1", None, 10 ** 100):
                self.rejects(lambda: rpc.validate_terminal(
                    {"kind": "result", "id": ID, "result": {"bridgePID": 1, "pythonPID": 1, key: value}}, "topology.identity"))

    def test_probe_observation_types_ranges_and_coherence(self):
        def validate(result):
            rpc.validate_terminal(rpc.decode_frame(rpc.encode_frame(
                {"kind": "result", "id": ID, "result": result})), "topology.probe")

        unobserved = {**PROBE, "syscallObserved": False, "syscallResult": 0,
                      "errno": 0, "beganAtNs": 0, "endedAtNs": 0}
        validate(unobserved)
        for key in ("syscallResult", "errno", "beganAtNs", "endedAtNs"):
            self.rejects(lambda: validate({**unobserved, key: 1}))
            for value in (True, False, 1.0, "1", None):
                self.rejects(lambda: validate({**PROBE, key: value}))
        for value in (0, 1, "true", None):
            self.rejects(lambda: validate({**PROBE, "syscallObserved": value}))
        for changes in ({"syscallResult": -2147483648},
                        {"syscallResult": 2147483647, "errno": 0},
                        {"syscallResult": 0, "errno": 0}, {"errno": 0}, {"beganAtNs": 0},
                        {"errno": 2147483647},
                        {"beganAtNs": 9223372036854775806, "endedAtNs": 9223372036854775807}):
            validate({**PROBE, **changes})
        for changes in ({"syscallResult": -2147483649}, {"syscallResult": 2147483648},
                        {"errno": -1}, {"errno": 2147483648},
                        {"beganAtNs": -1}, {"beganAtNs": 9223372036854775808},
                        {"endedAtNs": -1}, {"endedAtNs": 9223372036854775808},
                        {"endedAtNs": 0}, {"endedAtNs": 1},
                        {"beganAtNs": 3}, {"syscallResult": 0}, {"syscallResult": 1}):
            self.rejects(lambda: validate({**PROBE, **changes}))
        self.rejects(lambda: validate({"outcome": "denied", "reason": "permissionDenied"}))

    def test_closed_probe_and_error_enums(self):
        case_ids = ["ownZoneReadWrite", "mainCanaryRead", "mainCanaryWrite", "externalCanaryRead", "externalCanaryWrite",
                    "mainCanarySymlinkRead", "externalCanarySymlinkRead", "foreignGroupCanaryRead", "foreignGroupCanaryWrite",
                    "foreignGroupCanarySymlinkRead", "inboundListen"]
        for case_id in case_ids:
            rpc.validate_request(request("topology.probe", {"runID": ID, "caseID": case_id}))
        self.rejects(lambda: rpc.validate_request(request("topology.probe", {"runID": ID, "caseID": "arbitraryPath"})), "invalidParams")
        for outcome in ("allowed", "denied", "inconclusive"):
            for reason in ("none", "permissionDenied", "missingFixture", "controlFailed", "unexpectedErrno"):
                rpc.validate_terminal({"kind": "result", "id": ID, "result": {**PROBE, "outcome": outcome, "reason": reason}}, "topology.probe")
        for result in ({**PROBE, "outcome": "success", "reason": "none"}, {**PROBE, "outcome": "allowed", "reason": "ENOENT"}):
            self.rejects(lambda: rpc.validate_terminal({"kind": "result", "id": ID, "result": result}, "topology.probe"))
        for code in ("versionMismatch", "handshakeRequired", "unknownMethod", "invalidParams", "busy", "cancelled", "timeout", "unavailable", "internal"):
            rpc.validate_terminal({"kind": "error", "id": ID, "code": code}, "hello")
        for value in ({"kind": "error", "id": ID, "code": "protocolViolation"},
                      {"kind": "error", "id": ID, "code": "busy", "message": "sensitive"},
                      {"kind": "error", "id": ID}, {"kind": "event", "id": ID, "code": "busy"}):
            self.rejects(lambda: rpc.validate_terminal(value, "hello"))

    def test_corrupt_json_utf8_duplicate_keys_and_nonfinite_numbers(self):
        bodies = [b'{"x":"\xff"}', b'{"x":"\xc0\x80"}', b'{"x":"\xed\xa0\x80"}',
                  b'\xef\xbb\xbf{}', b'{"x":"\x00"}', b'{"x":"\\ud800"}', b'{"x":"\\udc00"}',
                  b'{"x":1,"\\u0078":2}', b'{"nested":{"x":1,"\\u0078":2}}',
                  b'{"x":NaN}', b'{"x":Infinity}', b'{"x":-Infinity}', b'{"x":1e9999}',
                  b'{"x":01}', b'{"x":+1}', b'{"x":1.}', b'{"x":1e}',
                  b'{"x":true,}', b'{"x":[1,]}', b'{}{}', b'[]', b'null', b'1', b'"text"', b' ', b'{']
        for body in bodies:
            with self.subTest(body=body):
                self.rejects(lambda: rpc.decode_frame(raw(body)))
        for value in (float("nan"), float("inf"), float("-inf"), "\ud800"):
            self.rejects(lambda: rpc.encode_frame({"x": value}))
        cycle = []
        cycle.append(cycle)
        self.rejects(lambda: rpc.encode_frame({"x": cycle}))
        self.rejects(lambda: rpc.encode_frame({1: "not a string key"}))
        self.assertEqual(rpc.decode_frame(raw('{"x":"\\ud834\\udd1e"}')), {"x": "𝄞"})

    def test_structural_limits_at_max_and_plus_one(self):
        def check(value):
            self.assertEqual(rpc.decode_frame(rpc.encode_frame(value)), value)

        for value in ({str(i): i for i in range(16)}, {"x": list(range(32))},
                      {"x": "a" * 256}, {"x": "é" * 128}, {"k" * 256: None}):
            check(value)
        for value in ({str(i): i for i in range(17)}, {"x": list(range(33))},
                      {"x": "a" * 257}, {"x": "é" * 128 + "x"}, {"k" * 257: None}):
            self.rejects(lambda: rpc.encode_frame(value))
            self.rejects(lambda: rpc.decode_frame(raw(json.dumps(value))))
        nested = []
        for _ in range(6):
            nested = [nested]
        check({"x": nested})  # Root object plus seven arrays is depth eight.
        self.rejects(lambda: rpc.encode_frame({"x": [nested]}))
        self.rejects(lambda: rpc.decode_frame(raw('{"x":' + '[' * 8 + ']' * 8 + '}')))
        self.assertEqual(rpc.decode_frame(raw('{"x":"' + '\\u0061' * 256 + '"}')), {"x": "a" * 256})

    def test_exact_body_and_prefix_boundaries(self):
        self.assertEqual(rpc.decode_frame(raw(b"{}" + b" " * 65534)), {})
        self.rejects(lambda: rpc.decode_frame(raw(b"{}" + b" " * 65535)))
        self.rejects(lambda: rpc.decode_frame(raw(b"0")))  # Legal byte length, illegal root.
        for frame in (b"", b"\x00", b"\x00\x00\x00", struct.pack(">I", 0),
                      struct.pack(">I", 65537), struct.pack(">I", 0xffffffff),
                      struct.pack(">I", 3) + b"{}", struct.pack(">I", 1) + b"{}", raw(b"{}") + b"x"):
            self.rejects(lambda: rpc.decode_frame(frame))
        strings = ["a" * 256] * 252
        value = {"items": [strings[i:i + 32] for i in range(0, len(strings), 32)], "pad": ""}
        missing = 65540 - len(rpc.encode_frame(value))
        self.assertGreaterEqual(missing, 0)
        self.assertLessEqual(missing, 256)
        value["pad"] = "b" * missing
        encoded = rpc.encode_frame(value)
        self.assertEqual(len(encoded), 65540)
        self.assertEqual(rpc.decode_frame(encoded), value)
        value["pad"] += "b"
        self.rejects(lambda: rpc.encode_frame(value))

    def test_stream_partial_coalesced_and_permanent_failure(self):
        first = rpc.encode_frame(request())
        second = rpc.encode_frame(request("topology.wait", {"durationMs": 5000}))
        for split in range(len(first) + 1):
            decoder = rpc.FrameDecoder()
            self.assertEqual(decoder.feed(first[:split]) + decoder.feed(first[split:]), [first])
        decoder = rpc.FrameDecoder()
        result = []
        for byte in first + second:
            result.extend(decoder.feed(bytes([byte])))
        self.assertEqual(result, [first, second])
        decoder = rpc.FrameDecoder()
        self.assertEqual(decoder.feed(first + second + first[:3]), [first, second])
        self.assertEqual(decoder.feed(first[3:]), [first])
        self.assertEqual(decoder.feed(b""), [])
        for prefix in (0, 65537, 0xffffffff):
            decoder = rpc.FrameDecoder()
            self.assertEqual(decoder.feed(struct.pack(">I", prefix)[:3]), [])
            self.rejects(lambda: decoder.feed(struct.pack(">I", prefix)[3:]))
            self.rejects(lambda: decoder.feed(first))
        decoder = rpc.FrameDecoder()
        self.rejects(lambda: decoder.feed(raw(b'{"x":1,"x":2}')))
        self.rejects(lambda: decoder.feed(first))
        maximum = raw(b"{}" + b" " * 65534)
        decoder = rpc.FrameDecoder()
        self.assertEqual(decoder.feed(maximum * 5), [maximum] * 5)
        decoder = rpc.FrameDecoder()
        self.assertEqual(decoder.feed(maximum[:-1]), [])
        self.assertEqual(decoder.feed(maximum[-1:] + first), [maximum, first])

    def test_successful_eof_seals_empty_complete_and_fragmented_streams(self):
        frame = rpc.encode_frame(request())
        for chunks in ((), (frame,), (frame[:2], frame[2:])):
            with self.subTest(chunks=len(chunks)):
                decoder = rpc.FrameDecoder()
                frames = []
                for chunk in chunks:
                    frames.extend(decoder.feed(chunk))
                self.assertEqual(frames, [frame] if chunks else [])
                decoder.finish()
                decoder.finish()
                self.rejects(lambda: decoder.feed(b""))
                self.rejects(lambda: decoder.feed(frame))

    def test_malformed_coalesced_batch_returns_no_frames_and_poisons_stream(self):
        frame = rpc.encode_frame(request())
        for invalid in (raw(b'{"x":"\xff"}'), raw(b'{"x":1,"\\u0078":2}'),
                        raw(b"null"), struct.pack(">I", 0)):
            with self.subTest(invalid=invalid):
                decoder = rpc.FrameDecoder()
                self.assertEqual(decoder.feed(frame[:2]), [])
                self.rejects(lambda: decoder.feed(frame[2:] + invalid + frame))
                self.rejects(lambda: decoder.feed(b""))
                self.rejects(lambda: decoder.feed(frame))
                self.rejects(decoder.finish)

    def test_non_bytes_input_poisons_empty_and_partial_streams(self):
        frame = rpc.encode_frame(request())
        for prefix_length in (0, 2, 5):
            for invalid in (None, "", bytearray(), memoryview(b""), 0):
                with self.subTest(prefix_length=prefix_length, invalid=invalid):
                    decoder = rpc.FrameDecoder()
                    self.assertEqual(decoder.feed(frame[:prefix_length]), [])
                    self.rejects(lambda: decoder.feed(invalid))
                    self.rejects(lambda: decoder.feed(frame[prefix_length:]))
                    self.rejects(lambda: decoder.feed(frame))
                    self.rejects(decoder.finish)

    def test_eof_rejects_every_truncated_prefix_and_body(self):
        frame = rpc.encode_frame(request())
        rpc.FrameDecoder().finish()
        decoder = rpc.FrameDecoder()
        self.assertEqual(decoder.feed(frame), [frame])
        decoder.finish()
        for length in range(1, len(frame)):
            decoder = rpc.FrameDecoder()
            self.assertEqual(decoder.feed(frame[:length]), [])
            self.rejects(decoder.finish)
            self.rejects(lambda: decoder.feed(frame))
        decoder = rpc.FrameDecoder()
        self.assertEqual(decoder.feed(frame + frame[:2]), [frame])
        self.rejects(decoder.finish)


if __name__ == "__main__":
    unittest.main()
