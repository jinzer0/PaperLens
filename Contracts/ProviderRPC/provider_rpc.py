"""Bounded wire framing and schema validation; connection state belongs to the server."""

import json
import math
from pathlib import Path
import re
import struct


with Path(__file__).with_name("contract.json").open(encoding="utf-8") as _file:
    CONTRACT = json.load(_file)

_LIMITS = CONTRACT["limits"]
MAX_BODY_BYTES = _LIMITS["maxBodyBytes"]
MAX_FRAME_BYTES = _LIMITS["maxFrameBytes"]
_UUID = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\Z")


class ProtocolError(Exception):
    def __init__(self, code="protocolViolation"):
        if type(code) is not str or code not in (
            "protocolViolation", *CONTRACT["definitions"]["errorCode"]["enum"]
        ):
            code = "protocolViolation"
        self.code = code
        super().__init__(code)


def _violation(*_args):
    raise ProtocolError() from None


def _pairs(pairs):
    result = {}
    for key, value in pairs:
        if key in result or len(result) >= _LIMITS["maxObjectKeys"]:
            _violation()
        result[key] = value
    return result


def _check_string(value):
    try:
        if len(value.encode("utf-8", errors="strict")) > _LIMITS["maxStringBytes"]:
            _violation()
    except UnicodeError:
        _violation()


def _check_structure(value, depth=0):
    if type(value) is dict:
        depth += 1
        if depth > _LIMITS["maxDepth"] or len(value) > _LIMITS["maxObjectKeys"]:
            _violation()
        for key, item in value.items():
            if type(key) is not str:
                _violation()
            _check_string(key)
            _check_structure(item, depth)
    elif type(value) is list:
        depth += 1
        if depth > _LIMITS["maxDepth"] or len(value) > _LIMITS["maxArrayItems"]:
            _violation()
        for item in value:
            _check_structure(item, depth)
    elif type(value) is str:
        _check_string(value)
    elif type(value) is float:
        if not math.isfinite(value):
            _violation()
    elif value is not None and type(value) not in (int, bool):
        _violation()


def _check_root(value):
    if type(value) is not dict:
        _violation()
    _check_structure(value)


def _check_raw_depth(text):
    # Bound nesting before invoking the recursive stdlib JSON parser.
    depth = 0
    quoted = False
    escaped = False
    for character in text:
        if quoted:
            if escaped:
                escaped = False
            elif character == "\\":
                escaped = True
            elif character == '"':
                quoted = False
        elif character == '"':
            quoted = True
        elif character in "[{":
            depth += 1
            if depth > _LIMITS["maxDepth"]:
                _violation()
        elif character in "]}":
            depth -= 1


def _parse_integer(text):
    # Do not change the process-wide CPython digit limit or narrow version numbers.
    negative = text.startswith("-")
    digits = text[1:] if negative else text
    value = 0
    for start in range(0, len(digits), 9):
        chunk = digits[start:start + 9]
        value = value * (10 ** len(chunk)) + int(chunk)
    return -value if negative else value


def _integer_text(value):
    if value.bit_length() > MAX_BODY_BYTES * 4:
        _violation()  # Even its decimal digits cannot fit in a frame.
    negative = value < 0
    magnitude = abs(value)
    parts = []
    while magnitude >= 1_000_000_000:
        magnitude, remainder = divmod(magnitude, 1_000_000_000)
        parts.append(f"{remainder:09d}")
        if len(parts) * 9 > MAX_BODY_BYTES:
            _violation()
    parts.append(str(magnitude))
    return ("-" if negative else "") + "".join(reversed(parts))


def encode_frame(object: dict) -> bytes:
    _check_root(object)
    body = bytearray()

    def append(text):
        encoded = text.encode("utf-8", errors="strict")
        if len(body) + len(encoded) > MAX_BODY_BYTES:
            _violation()
        body.extend(encoded)

    def emit(value):
        if type(value) is dict:
            append("{")
            for index, (key, item) in enumerate(value.items()):
                if index:
                    append(",")
                emit(key)
                append(":")
                emit(item)
            append("}")
        elif type(value) is list:
            append("[")
            for index, item in enumerate(value):
                if index:
                    append(",")
                emit(item)
            append("]")
        elif type(value) is int:
            append(_integer_text(value))
        else:
            append(json.dumps(value, ensure_ascii=False, allow_nan=False, separators=(",", ":")))

    try:
        emit(object)
    except (ValueError, TypeError, UnicodeError, OverflowError, RecursionError):
        _violation()
    if not body:
        _violation()
    return struct.pack(">I", len(body)) + bytes(body)


def decode_frame(frame: bytes) -> dict:
    if not isinstance(frame, bytes) or not 5 <= len(frame) <= MAX_FRAME_BYTES:
        _violation()
    length = struct.unpack_from(">I", frame)[0]
    if not 1 <= length <= MAX_BODY_BYTES or len(frame) != length + 4:
        _violation()
    try:
        text = frame[4:].decode("utf-8", errors="strict")
        _check_raw_depth(text)
        object = json.loads(text, object_pairs_hook=_pairs, parse_constant=_violation, parse_int=_parse_integer)
        _check_root(object)
    except (ValueError, TypeError, UnicodeError, OverflowError, RecursionError):
        _violation()
    return object


def _matches(value, schema):
    if "ref" in schema:
        return _matches(value, CONTRACT["definitions"][schema["ref"]])
    kind = schema["type"]
    if kind == "object":
        if type(value) is not dict:
            return False
        fields = schema.get("fields")
        if fields is not None and (
            value.keys() != fields.keys()
            or any(not _matches(value[key], rule) for key, rule in fields.items())
        ):
            return False
    elif kind == "array":
        if type(value) is not list or any(not _matches(item, schema["items"]) for item in value):
            return False
    elif kind == "integer":
        if type(value) is not int:
            return False
        minimum = schema.get("minimum", _LIMITS.get(schema.get("minimumLimit")))
        maximum = schema.get("maximum", _LIMITS.get(schema.get("maximumLimit")))
        if (minimum is not None and value < minimum) or (maximum is not None and value > maximum):
            return False
    elif kind == "boolean":
        if type(value) is not bool:
            return False
    elif kind == "string":
        if type(value) is not str:
            return False
    elif kind == "uuid":
        if type(value) is not str or _UUID.fullmatch(value) is None:
            return False
    else:
        return False
    if "const" in schema and value != schema["const"]:
        return False
    if "enum" in schema and value not in schema["enum"]:
        return False
    return True


def validate_request(object: dict) -> None:
    _check_root(object)
    if not _matches(object, CONTRACT["envelopes"]["request"]):
        _violation()
    method = CONTRACT["methods"].get(object["method"])
    if method is None:
        raise ProtocolError("unknownMethod")
    if not _matches(object["params"], method["params"]):
        raise ProtocolError("invalidParams")


def validate_terminal(object: dict, method: str) -> None:
    _check_root(object)
    kind = object.get("kind")
    if kind not in ("result", "error") or not _matches(object, CONTRACT["envelopes"][kind]):
        _violation()
    if kind == "result":
        if type(method) is not str or method not in CONTRACT["methods"]:
            raise ProtocolError("unknownMethod")
        if not _matches(object["result"], CONTRACT["methods"][method]["result"]):
            _violation()


class FrameDecoder:
    """Retains at most one bounded frame. A violation permanently poisons the reader."""

    def __init__(self):
        self._buffer = bytearray()
        self._length = None
        self._failed = False

    def finish(self) -> None:
        if self._failed or self._buffer or self._length is not None:
            self._failed = True
            self._buffer.clear()
            self._length = None
            _violation()

    def feed(self, data: bytes) -> list[bytes]:
        if self._failed or not isinstance(data, bytes):
            _violation()
        frames = []
        offset = 0
        try:
            while offset < len(data):
                target = 4 if self._length is None else self._length + 4
                count = min(target - len(self._buffer), len(data) - offset)
                self._buffer.extend(data[offset:offset + count])
                offset += count
                if self._length is None and len(self._buffer) == 4:
                    self._length = struct.unpack_from(">I", self._buffer)[0]
                    if not 1 <= self._length <= MAX_BODY_BYTES:
                        _violation()
                if self._length is not None and len(self._buffer) == self._length + 4:
                    frame = bytes(self._buffer)
                    decode_frame(frame)
                    frames.append(frame)
                    self._buffer.clear()
                    self._length = None
        except ProtocolError:
            self._failed = True
            self._buffer.clear()
            self._length = None
            raise
        return frames
