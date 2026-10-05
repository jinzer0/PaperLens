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
CASES = [
    ("hello", {"major": 1, "minor": 0, "capabilities": ["topology-v1"]},
     {"major": 1, "minor": 0, "capabilities": ["topology-v1"]}),
    ("topology.runtime", {}, {"sdkImported": True, "cliInitialized": False, "architecture": "arm64"}),
    ("topology.prepare", {"runID": ID}, {"prepared": True}),
    ("topology.probe", {"runID": ID, "caseID": "ownZoneReadWrite"}, {"outcome": "denied", "reason": "permissionDenied"}),
    ("topology.cleanup", {"runID": ID}, {"absent": True}),
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
    def rejects(self, action, code="protocolViolation"):
        with self.assertRaises(rpc.ProtocolError) as caught:
            action()
        self.assertEqual(caught.exception.code, code)

    def test_every_method_round_trip_and_closed_fields(self):
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
                    '"params":{"major":' + number + ',"minor":0,"capabilities":["topology-v1"]}}')
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
        # Negotiation, not the schema, handles major-version mismatch.
        rpc.validate_request(request("hello", {"major": 2, "minor": 1, "capabilities": ["topology-v1"]}))
        for params in ({"major": True, "minor": 0, "capabilities": ["topology-v1"]},
                       {"major": 1, "minor": 0.0, "capabilities": ["topology-v1"]},
                       {"major": 1, "minor": 0, "capabilities": []},
                       {"major": 1, "minor": 0, "capabilities": ["topology-v1", "unknown"]}):
            self.rejects(lambda: rpc.validate_request(request("hello", params)), "invalidParams")
        for method, _, result in CASES:
            for key, value in result.items():
                if type(value) is bool:
                    bad = {**result, key: int(value)}
                    self.rejects(lambda: rpc.validate_terminal({"kind": "result", "id": ID, "result": bad}, method))
        for architecture in ("arm64", "x86_64"):
            rpc.validate_terminal({"kind": "result", "id": ID, "result": {"sdkImported": True, "cliInitialized": True, "architecture": architecture}}, "topology.runtime")
        self.rejects(lambda: rpc.validate_terminal({"kind": "result", "id": ID, "result": {"sdkImported": True, "cliInitialized": True, "architecture": "aarch64"}}, "topology.runtime"))
        self.rejects(lambda: rpc.validate_terminal({"kind": "result", "id": ID, "result": {"major": 2, "minor": 0, "capabilities": ["topology-v1"]}}, "hello"))

    def test_closed_probe_and_error_enums(self):
        case_ids = ["ownZoneReadWrite", "mainCanaryRead", "mainCanaryWrite", "externalCanaryRead", "externalCanaryWrite",
                    "mainCanarySymlinkRead", "externalCanarySymlinkRead", "foreignGroupCanaryRead", "foreignGroupCanaryWrite",
                    "foreignGroupCanarySymlinkRead", "inboundListen"]
        for case_id in case_ids:
            rpc.validate_request(request("topology.probe", {"runID": ID, "caseID": case_id}))
        self.rejects(lambda: rpc.validate_request(request("topology.probe", {"runID": ID, "caseID": "arbitraryPath"})), "invalidParams")
        for outcome in ("allowed", "denied", "inconclusive"):
            for reason in ("none", "permissionDenied", "missingFixture", "controlFailed", "unexpectedErrno"):
                rpc.validate_terminal({"kind": "result", "id": ID, "result": {"outcome": outcome, "reason": reason}}, "topology.probe")
        for result in ({"outcome": "success", "reason": "none"}, {"outcome": "allowed", "reason": "ENOENT"}):
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
