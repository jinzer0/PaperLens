"""Pure Story 1.7 contract. No transport, tokenizer, retrieval, SDK or filesystem import.

TrustedContext is constructed by Application from immutable extraction/retrieval
state. Ranked candidates are already in Application's BM25/tie-break order;
this module selects a prefix, never performs retrieval or certifies a provider.
"""
from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass, field
import json
from pathlib import Path
import re
import threading
from types import MappingProxyType
from urllib.parse import urljoin, urlsplit


class ContractError(ValueError):
    """Only fixed code and field are observable, including str/repr/args."""
    def __init__(self, code, field):
        self.code = code
        self.field = field
        super().__init__(code, field)

    def as_dict(self):
        return {"code": self.code, "field": self.field}


def _fail(code="invalidShape", field="request"):
    raise ContractError(code, field) from None


@dataclass(frozen=True)
class FrozenRecord(Mapping):
    """Schema-typed, deeply immutable JSON object with deterministic equality."""
    schema: str
    _entries: tuple

    def __getitem__(self, key):
        for name, value in self._entries:
            if name == key:
                return value
        raise KeyError(key)

    def __iter__(self):
        return (name for name, _ in self._entries)

    def __len__(self):
        return len(self._entries)


class TypedRecord(Mapping):
    """Mapping surface for concrete immutable domain records."""
    def __getitem__(self, key):
        if key not in self.__dataclass_fields__:
            raise KeyError(key)
        return getattr(self, key)

    def __iter__(self):
        return iter(self.__dataclass_fields__)

    def __len__(self):
        return len(self.__dataclass_fields__)


@dataclass(frozen=True)
class Anchor(TypedRecord):
    pageIndex: int
    sentenceID: int


@dataclass(frozen=True)
class SourceSentence(TypedRecord):
    anchor: Anchor
    quote: str


@dataclass(frozen=True)
class PaperIdentity(TypedRecord):
    paperID: str
    paperGeneration: int
    pdfSHA256: str
    extractionRevision: str


@dataclass(frozen=True)
class Selection(TypedRecord):
    policyVersion: int
    method: str
    candidateCount: int


@dataclass(frozen=True)
class EvidenceItem(TypedRecord):
    anchor: Anchor
    quote: str
    rank: int


@dataclass(frozen=True)
class EvidenceBundle(TypedRecord):
    paperID: str
    paperGeneration: int
    pdfSHA256: str
    extractionRevision: str
    selection: Selection
    insufficiency: str
    items: tuple[EvidenceItem, ...] = field()


@dataclass(frozen=True)
class Turn(TypedRecord):
    turnID: str
    role: str
    text: str


@dataclass(frozen=True)
class Section(TypedRecord):
    sectionID: str
    heading: str
    prompt: str


@dataclass(frozen=True)
class GenerationInputs(TypedRecord):
    outputLanguage: str
    policyVersion: int


@dataclass(frozen=True)
class TemplateSnapshot(TypedRecord):
    snapshotID: str
    templateVersionID: str
    sections: tuple[Section, ...]
    generationInputs: GenerationInputs


@dataclass(frozen=True)
class Grounded(TypedRecord):
    text: str
    kind: str
    evidenceIndices: tuple[int, ...]


@dataclass(frozen=True)
class Translation(TypedRecord):
    pageIndex: int
    sentenceID: int
    text: str


@dataclass(frozen=True)
class ResultSection(TypedRecord):
    sectionID: str
    state: str
    segments: tuple[Grounded, ...]


def _freeze(value, schema="object"):
    if isinstance(value, TypedRecord):
        return value
    if isinstance(value, Mapping):
        return FrozenRecord(schema, tuple((k, _freeze(v, k)) for k, v in sorted(value.items())))
    if isinstance(value, (tuple, list)):
        return tuple(_freeze(v, schema + "Item") for v in value)
    return value


def _plain(value):
    if isinstance(value, Mapping):
        if any(type(k) is not str for k in value):
            _fail()
        return {k: _plain(value[k]) for k in value}
    if isinstance(value, (tuple, list)):
        return [_plain(v) for v in value]
    if type(value) not in (str, int, bool, type(None)):
        _fail()
    return value


def _utf8(value, code="invalidShape", field="request"):
    if type(value) is not str:
        _fail(code, field)
    try:
        return value.encode("utf-8", errors="strict")
    except UnicodeError:
        _fail(code, field)


def _pairs(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            _fail("invalidJSON", "request")
        result[key] = value
    return result


def _no_number(_):
    _fail("invalidJSON", "request")


def _integer(text):
    # Bound work before Python's own interpreter-dependent integer limit.
    if len(text) > 20:
        _fail("invalidJSON", "request")
    return int(text)


def _decode(raw, max_bytes, depth, keys, arrays, field="request"):
    if type(raw) is not bytes:
        _fail("invalidJSON", field)
    if len(raw) > max_bytes:
        _fail("outputLimit" if field == "result" else "inputLimit", field)
    try:
        text = raw.decode("utf-8", errors="strict")
        # Preflight nesting BEFORE the JSON decoder can allocate a deep tree.
        level = 0
        quoted = False
        escaped = False
        for char in text:
            if quoted:
                if escaped:
                    escaped = False
                elif char == "\\":
                    escaped = True
                elif char == '"':
                    quoted = False
            elif char == '"':
                quoted = True
            elif char in "[{":
                level += 1
                if level > depth:
                    _fail("invalidJSON", field)
            elif char in "]}":
                level -= 1
        value = json.loads(text, object_pairs_hook=_pairs, parse_int=_integer,
                           parse_float=_no_number, parse_constant=_no_number)
        def walk(node, level=0):
            if isinstance(node, dict):
                if level + 1 > depth or len(node) > keys:
                    _fail("invalidJSON", field)
                for key, child in node.items():
                    _utf8(key, "invalidJSON", field)
                    walk(child, level + 1)
            elif isinstance(node, list):
                if level + 1 > depth or len(node) > arrays:
                    _fail("invalidJSON", field)
                for child in node:
                    walk(child, level + 1)
            elif isinstance(node, str):
                _utf8(node, "invalidJSON", field)
        walk(value)
        return value
    except ContractError:
        _fail("invalidJSON", field)
    except (ValueError, UnicodeError, RecursionError, OverflowError):
        _fail("invalidJSON", field)


# Keywords and named rules are implementation capabilities, not policy values.
_SCHEMA_KEYS = frozenset(("type", "ref", "fields", "items", "minimum", "maximum",
                          "const", "enum", "pattern", "maxBytes", "minItems", "maxItems", "rules"))
_RULES = frozenset(("bundleRelations", "historyPairs", "snapshotIdentity", "citationRelations",
                   "translationOrder", "resultInsufficiency", "snapshotResult", "summaryLine",
                   "fixedProbe", "translationPlan", "frozenProvenance", "renderedBudget",
                   "rankedPrefix", "historyFirst"))
_OPERATIONS = frozenset(("connectionTest", "translation", "paperChat", "brief", "librarySummary"))
_LIMIT_NAMES = frozenset(("innerBytes", "bodyBytes", "frameBytes", "depth", "outerDepth", "objectKeys", "arrayItems",
                         "inputStringBytes", "resultStringBytes", "messages", "messageBytes", "messageOverhead",
                         "evidenceItems", "evidenceBytes", "summaryItems", "summaryEvidenceBytes", "snapshotBytes",
                         "historyMessages", "streams", "chunks", "streamBytes", "outstanding", "ordinary", "cancel",
                         "queuedFrames", "queuedBytes", "requestsPerConnection", "probeDeadlineMs", "generationDeadlineMs",
                         "redirects", "headerBytes", "headerCount", "pdfBytes", "readBufferBytes", "importConcurrency",
                         "idleMs", "importElapsedMs", "pages", "sentences", "textBytes", "sentenceBytes",
                         "quadsPerSentence", "quads", "batchSentences", "batchBytes", "parserConcurrency",
                         "parserElapsedMs", "rssBytes", "watchdogIntervalMs", "urlBytes"))


def load_contract(raw=None):
    """Load the sole authority, rejecting unknown keywords, refs, modes and rules."""
    if raw is None:
        try:
            raw = Path(__file__).with_name("contract.json").read_bytes()
        except OSError:
            _fail("contractDefinition", "request")
    # These are loader safeguards, not request/resource policy overrides.
    try:
        document = _decode(raw, 1048576, 32, 256, 1000)
        root_keys = {"schemaVersion", "limits", "definitions", "operations", "policies",
                     "rules", "resources", "pools", "conformance"}
        if type(document) is not dict or set(document) != root_keys or type(document["schemaVersion"]) is not int or document["schemaVersion"] != 1:
            _fail()
        if any(type(document[name]) is not dict for name in root_keys - {"schemaVersion", "rules"}) or type(document["rules"]) is not list:
            _fail()
        if set(document["limits"]) != _LIMIT_NAMES:
            _fail()
        if set(document["operations"]) != _OPERATIONS or set(document["rules"]) != _RULES or len(document["rules"]) != len(_RULES):
            _fail()
        for number in document["limits"].values():
            if type(number) is not int or number < 0:
                _fail()
        def check_schema(schema, seen=()):
            if type(schema) is not dict or not schema or not set(schema) <= _SCHEMA_KEYS:
                _fail()
            if "ref" in schema:
                if set(schema) != {"ref"} or schema["ref"] not in document["definitions"] or schema["ref"] in seen:
                    _fail()
                check_schema(document["definitions"][schema["ref"]], seen + (schema["ref"],))
                return
            kind = schema.get("type")
            allowed = {"type", "const", "enum", "rules"}
            if kind == "object":
                allowed |= {"fields"}
                if type(schema.get("fields")) is not dict:
                    _fail()
                for child in schema["fields"].values():
                    check_schema(child, seen)
            elif kind == "array":
                allowed |= {"items", "minItems", "maxItems"}
                check_schema(schema.get("items"), seen)
            elif kind == "integer":
                allowed |= {"minimum", "maximum"}
            elif kind == "string":
                allowed |= {"maxBytes", "pattern"}
                if "pattern" in schema:
                    re.compile(schema["pattern"])
            elif kind != "uuid":
                _fail()
            if not set(schema) <= allowed or not set(schema.get("rules", ())) <= _RULES:
                _fail()
            for key in ("minimum", "maximum", "maxBytes", "minItems", "maxItems"):
                if key in schema and (type(schema[key]) is not int or schema[key] < 0):
                    _fail()
            if "enum" in schema and (type(schema["enum"]) is not list or not schema["enum"]):
                _fail()
            if "rules" in schema and (type(schema["rules"]) is not list or len(set(schema["rules"])) != len(schema["rules"])):
                _fail()
            for low, high in (("minimum", "maximum"), ("minItems", "maxItems")):
                if low in schema and high in schema and schema[low] > schema[high]:
                    _fail()
        for schema in document["definitions"].values():
            check_schema(schema)
        for operation in document["operations"].values():
            if set(operation) != {"input", "result", "source", "inputCharge", "outputTokens", "outputBytes", "controlReserve", "rules"}:
                _fail()
            for key in ("input", "result", "source"):
                check_schema(operation[key])
            rules = operation["rules"]
            if type(rules) is not list or any(type(rule) is not str for rule in rules) or len(set(rules)) != len(rules) or not set(rules) <= _RULES:
                _fail()
            for key in ("inputCharge", "outputTokens", "outputBytes", "controlReserve"):
                if type(operation[key]) is not int or operation[key] < 0:
                    _fail()
        policy_keys = {"requestFields", "resultFields", "canonical", "uuidPattern", "systemPrompt", "probePrompt", "probeReply", "summaryQuery", "sourceKinds", "arxivHosts", "arxivIdentifier", "arxivAbstractPrefix", "arxivPDFPrefix", "arxivCanonicalBase", "redirectStatuses", "terminalStatus", "pdfMIME", "encoding", "pdfMagic", "summaryLineSeparators", "profileFields", "errorFields", "errorCodes"}
        if set(document["policies"]) != policy_keys or set(document["policies"]["canonical"]) != {"sortKeys", "ensureASCII", "separators", "allowNaN"}:
            _fail()
        canonical = document["policies"]["canonical"]
        if canonical["sortKeys"] is not True or canonical["ensureASCII"] is not False or canonical["allowNaN"] is not False or canonical["separators"] != [",", ":"]:
            _fail()
        for name in ("uuidPattern", "systemPrompt", "probePrompt", "probeReply", "summaryQuery", "arxivIdentifier", "arxivAbstractPrefix", "arxivPDFPrefix", "arxivCanonicalBase", "pdfMIME", "encoding", "pdfMagic"):
            if type(document["policies"][name]) is not str or not document["policies"][name]:
                _fail()
        for name in ("requestFields", "resultFields", "sourceKinds", "arxivHosts", "summaryLineSeparators", "profileFields", "errorFields", "errorCodes"):
            entries = document["policies"][name]
            if type(entries) is not list or any(type(entry) is not str for entry in entries) or len(set(entries)) != len(entries):
                _fail()
        if type(document["policies"]["redirectStatuses"]) is not list or any(type(status) is not int for status in document["policies"]["redirectStatuses"]) or type(document["policies"]["terminalStatus"]) is not int:
            _fail()
        for expression in ("uuidPattern", "arxivIdentifier"):
            re.compile(document["policies"][expression])
        if set(document["resources"]) != {"import", "parser", "rpc"} or set(document["pools"]) != {"import", "parser"}:
            _fail()
        for kind, resource in document["resources"].items():
            if type(resource) is not dict or set(resource) != {"scope", "metrics"} or type(resource["metrics"]) is not dict or resource["scope"] != ("connection" if kind == "rpc" else "attempt"):
                _fail()
            for metric in resource["metrics"].values():
                if set(metric) != {"unit", "mode", "limit"} or metric["unit"] not in ("bytes", "count", "ms") or metric["mode"] not in ("cumulative", "gauge", "monotonic") or metric["limit"] not in document["limits"]:
                    _fail()
        for pool in document["pools"].values():
            if set(pool) != {"scope", "limit"} or pool["scope"] != "process" or pool["limit"] not in document["limits"]:
                _fail()
        vectors = document["conformance"]
        if set(vectors) != {"canonical", "rendered", "requests", "results", "invalidJSON"}:
            _fail()
        vector_keys = {"canonical": {"value", "utf8"}, "rendered": {"operation", "input", "messages", "contentBytes", "inputCharge"}, "requests": {"accepted", "value", "code"}, "results": {"accepted", "request", "value", "code"}}
        for group, allowed in vector_keys.items():
            if type(vectors[group]) is not list:
                _fail()
            for vector in vectors[group]:
                required = allowed - {"code", "contentBytes", "inputCharge"}
                if type(vector) is not dict or not required <= set(vector) or not set(vector) <= allowed:
                    _fail()
        return _freeze(document, "contract")
    except (ContractError, KeyError, TypeError, ValueError, re.error, RecursionError):
        _fail("contractDefinition", "request")


CONTRACT = load_contract()
LIMITS = CONTRACT["limits"]
POLICIES = CONTRACT["policies"]


def canonical_bytes(value):
    """C(value), without Unicode normalization, including literal U+2028/2029."""
    try:
        config = POLICIES["canonical"]
        text = json.dumps(_plain(value), sort_keys=config["sortKeys"], ensure_ascii=config["ensureASCII"],
                          separators=tuple(config["separators"]), allow_nan=config["allowNaN"])
        return _utf8(text)
    except (ValueError, TypeError, RecursionError):
        _fail()


def _resolve(schema):
    if "ref" in schema:
        return _resolve(CONTRACT["definitions"][schema["ref"]])
    return {key: ({name: _resolve(child) for name, child in value.items()} if key == "fields"
                  else _resolve(value) if key == "items" else _plain(value))
            for key, value in schema.items()}


def result_schema(operation):
    if type(operation) is not str or operation not in CONTRACT["operations"]:
        _fail("unknownOperation", "request")
    return _freeze(_resolve(CONTRACT["operations"][operation]["result"]), "resultSchema")


def _schema(value, schema, field="request", code="invalidShape"):
    if "ref" in schema:
        return _schema(value, CONTRACT["definitions"][schema["ref"]], field, code)
    kind = schema["type"]
    if kind == "object":
        if not isinstance(value, Mapping) or set(value) != set(schema["fields"]):
            _fail(code, field)
        for key, child in schema["fields"].items():
            _schema(value[key], child, field, code)
    elif kind == "array":
        if not isinstance(value, (list, tuple)) or not schema.get("minItems", 0) <= len(value) <= schema.get("maxItems", LIMITS["arrayItems"]):
            _fail(code, field)
        for child in value:
            _schema(child, schema["items"], field, code)
    elif kind == "integer":
        if type(value) is not int or value < schema.get("minimum", 0) or ("maximum" in schema and value > schema["maximum"]):
            _fail(code, field)
    elif kind in ("string", "uuid"):
        ceiling = schema.get("maxBytes", LIMITS["inputStringBytes"])
        if type(value) is not str or len(value) > ceiling:
            _fail(code, field)
        data = _utf8(value, code, field)
        if not data or len(data) > ceiling:
            _fail(code, field)
        pattern = POLICIES["uuidPattern"] if kind == "uuid" else schema.get("pattern")
        if pattern and not re.fullmatch(pattern, value):
            _fail(code, field)
    if "const" in schema and (type(value) is not type(schema["const"]) or value != schema["const"]):
        _fail(code, field)
    if "enum" in schema and value not in schema["enum"]:
        _fail(code, field)
    for rule in schema.get("rules", ()):
        if rule == "historyPairs":
            if len(value) % 2 or len({turn["turnID"] for turn in value}) != len(value):
                _fail("invalidHistory", "history")
            for i, turn in enumerate(value):
                if turn["role"] != ("user" if i % 2 == 0 else "assistant"):
                    _fail("invalidHistory", "history")
        elif rule == "snapshotIdentity":
            if len({section["sectionID"] for section in value["sections"]}) != len(value["sections"]) or len(canonical_bytes(value)) > LIMITS["snapshotBytes"]:
                _fail("invalidTemplate", "template")
        elif rule == "bundleRelations":
            _bundle_relations(value)
        elif rule == "citationRelations":
            indices = value["evidenceIndices"]
            if list(indices) != sorted(set(indices)) or (value["kind"] == "paper" and not indices) or (value["kind"] == "insufficient" and indices):
                _fail("invalidResult", "result")


def _anchor(value):
    return value["pageIndex"], value["sentenceID"]


def _typed_snapshot(value):
    return TemplateSnapshot(value["snapshotID"], value["templateVersionID"],
                            tuple(Section(**dict(section)) for section in value["sections"]),
                            GenerationInputs(**dict(value["generationInputs"])))


def _typed_input(value):
    payload = dict(value)
    if "evidence" in payload:
        bundle = dict(payload["evidence"])
        bundle["selection"] = Selection(**dict(bundle["selection"]))
        bundle["items"] = tuple(EvidenceItem(Anchor(**dict(item["anchor"])), item["quote"], item["rank"])
                                for item in bundle["items"])
        payload["evidence"] = EvidenceBundle(**bundle)
    if "templateSnapshot" in payload:
        payload["templateSnapshot"] = _typed_snapshot(payload["templateSnapshot"])
    if "priorTurns" in payload:
        payload["priorTurns"] = tuple(Turn(**dict(turn)) for turn in payload["priorTurns"])
    return _freeze(payload, "input")


def _typed_grounded(value):
    return Grounded(value["text"], value["kind"], tuple(value["evidenceIndices"]))


def _typed_result(value):
    payload = dict(value)
    if "translations" in payload:
        payload["translations"] = tuple(Translation(**dict(item)) for item in payload["translations"])
    if "segments" in payload:
        payload["segments"] = tuple(_typed_grounded(item) for item in payload["segments"])
    if "summary" in payload:
        payload["summary"] = _typed_grounded(payload["summary"])
    if "sections" in payload:
        payload["sections"] = tuple(ResultSection(section["sectionID"], section["state"],
                                                   tuple(_typed_grounded(item) for item in section["segments"]))
                                    for section in payload["sections"])
    return _freeze(payload, "result")


def _bundle_relations(bundle):
    items = bundle["items"]
    selection = bundle["selection"]
    count = selection["candidateCount"]
    ranks = [item["rank"] for item in items]
    anchors = [_anchor(item["anchor"]) for item in items]
    if len(set(anchors)) != len(anchors) or len({a[1] for a in anchors}) != len(anchors) or ranks != sorted(set(ranks)):
        _fail("invalidEvidence", "evidence")
    if selection["method"] == "canonicalPageOrder":
        if not items or count != len(items) or bundle["insufficiency"] != "none" or len({a[0] for a in anchors}) != 1 or ranks != list(range(ranks[0], ranks[0] + len(ranks))) or [a[1] for a in anchors] != sorted(a[1] for a in anchors):
            _fail("invalidEvidence", "evidence")
    else:
        if ranks != list(range(len(items))) or len(items) > count:
            _fail("invalidEvidence", "evidence")
        expected = "noEvidence" if count == 0 else "budgetLimited" if len(items) < count else "none"
        if bundle["insufficiency"] != expected:
            _fail("invalidEvidence", "evidence")


@dataclass(frozen=True)
class WireRequest:
    schemaVersion: int
    requestID: str
    operation: str
    input: FrozenRecord

    def __post_init__(self):
        if type(self.schemaVersion) is not int or self.schemaVersion != CONTRACT["schemaVersion"]:
            _fail("versionMismatch", "request")
        if type(self.operation) is not str or self.operation not in CONTRACT["operations"]:
            _fail("unknownOperation", "request")
        _schema(self.requestID, CONTRACT["definitions"]["uuid"])
        _schema(self.input, CONTRACT["operations"][self.operation]["input"])
        object.__setattr__(self, "input", _typed_input(self.input))

    def as_record(self):
        return _freeze({"schemaVersion": self.schemaVersion, "requestID": self.requestID,
                        "operation": self.operation, "input": self.input}, "request")


_SEAL = object()


@dataclass(frozen=True)
class _Issuance:
    wire: WireRequest
    context: TrustedContext
    seal: object


@dataclass(frozen=True)
class AuthorizedRequest:
    wire: WireRequest
    context: TrustedContext
    _seal: object = field(repr=False, compare=False)

    @property
    def operation(self):
        return self.wire.operation

    @property
    def requestID(self):
        return self.wire.requestID

    @property
    def input(self):
        return self.wire.input

    @property
    def schemaVersion(self):
        return self.wire.schemaVersion


@dataclass(frozen=True)
class ValidatedResult:
    schemaVersion: int
    requestID: str
    operation: str
    result: FrozenRecord

    def __post_init__(self):
        object.__setattr__(self, "result", _typed_result(self.result))

    def as_record(self):
        return _freeze({"schemaVersion": self.schemaVersion, "requestID": self.requestID,
                        "operation": self.operation, "result": self.result}, "resultEnvelope")


@dataclass(frozen=True)
class Message:
    role: str
    content: str


class _PlanStore:
    """Internally owned cache; only computation can publish complete plans."""
    __slots__ = ("__compute", "__view")

    def __init__(self, corpus, identity, language):
        entries = {}
        lock = threading.Lock()
        def compute(page, requested_language, context):
            if context.sentences is not corpus or context.identity is not identity or requested_language != language:
                _fail("sourceMismatch", "evidence")
            key = (page, requested_language)
            with lock:
                if key not in entries:
                    batches = _compute_page_plan(page, requested_language, context)
                    entries[key] = (batches, MappingProxyType({batch: index for index, batch in enumerate(batches)}))
                return entries[key][0]
        object.__setattr__(self, "_PlanStore__compute", compute)
        object.__setattr__(self, "_PlanStore__view", MappingProxyType(entries))

    def __setattr__(self, name, value):
        raise AttributeError("Immutable plan store")

    @property
    def view(self):
        return self.__view

    def plan(self, page, language, context):
        return self.__compute(page, language, context)


@dataclass(frozen=True)
class TrustedContext:
    """Application-owned provenance, copied and validated once on construction.

    identity: exact Paper identity; sentences: complete revision in ordinal order;
    ranked_candidates: unique sentenceIDs already sorted by BM25 then anchor;
    sources: exact operation source schema; turns: selected same-session pairs;
    expected_batch: exact translation sentenceIDs, bound by Application to plan.
    No score, retrieval row, handle, URL, or arbitrary metadata is sent to Model.
    """
    operation: str
    identity: Mapping | None = None
    sentences: tuple = ()
    ranked_candidates: tuple = ()
    sources: Mapping = field(default_factory=dict)
    turns: tuple = ()
    expected_batch: tuple = ()
    _plan_store: object = field(default=None, init=False, repr=False, compare=False)

    def __post_init__(self):
        if type(self.operation) is not str or self.operation not in CONTRACT["operations"]:
            _fail("unknownOperation", "request")
        _schema(self.sources, CONTRACT["operations"][self.operation]["source"], code="sourceMismatch")
        if self.operation == "connectionTest":
            if self.identity is not None or self.sentences or self.ranked_candidates or self.turns or self.expected_batch:
                _fail("sourceMismatch", "request")
        else:
            _schema(self.identity, CONTRACT["definitions"]["identity"], "evidence", "sourceMismatch")
            if not isinstance(self.sentences, (tuple, list)) or len(self.sentences) > LIMITS["sentences"]:
                _fail("inputLimit", "evidence")
            previous = -1
            seen = set()
            previous_page = -1
            text_bytes = 0
            for sentence in self.sentences:
                _schema(sentence, CONTRACT["definitions"]["sentence"], "evidence", "sourceMismatch")
                text_bytes += len(_utf8(sentence["quote"]))
                if text_bytes > LIMITS["textBytes"]:
                    _fail("inputLimit", "evidence")
                page, ordinal = _anchor(sentence["anchor"])
                if ordinal != previous + 1 or page < previous_page or ordinal in seen:
                    _fail("sourceMismatch", "evidence")
                previous, previous_page = ordinal, page
                seen.add(ordinal)
            if not isinstance(self.ranked_candidates, (tuple, list)) or len(self.ranked_candidates) > LIMITS["sentences"] or any(type(v) is not int or v not in seen for v in self.ranked_candidates) or len(set(self.ranked_candidates)) != len(self.ranked_candidates):
                _fail("sourceMismatch", "evidence")
            _schema(self.turns, CONTRACT["definitions"]["turns"], "history", "invalidHistory")
            if self.operation != "paperChat" and self.turns:
                _fail("sourceMismatch", "history")
            if not isinstance(self.expected_batch, (tuple, list)):
                _fail("sourceMismatch", "evidence")
            if self.operation == "translation":
                if tuple(self.sources["sentenceIDs"]) != tuple(self.expected_batch):
                    _fail("sourceMismatch", "evidence")
                if any(type(v) is not int or v not in seen for v in self.expected_batch):
                    _fail("sourceMismatch", "evidence")
            elif self.expected_batch:
                _fail("sourceMismatch", "evidence")
        for name in ("ranked_candidates", "sources", "expected_batch"):
            object.__setattr__(self, name, _freeze(getattr(self, name), name))
        if self.identity is not None:
            object.__setattr__(self, "identity", PaperIdentity(**dict(self.identity)))
        object.__setattr__(self, "sentences", tuple(SourceSentence(Anchor(**dict(s["anchor"])), s["quote"]) for s in self.sentences))
        object.__setattr__(self, "turns", tuple(Turn(**dict(turn)) for turn in self.turns))
        if self.operation == "brief":
            object.__setattr__(self, "sources", _freeze({"templateSnapshot": _typed_snapshot(self.sources["templateSnapshot"])}))
        object.__setattr__(self, "_plan_store", _PlanStore(self.sentences, self.identity, self.sources.get("targetLanguage")))

    @property
    def _plans(self):
        return self._plan_store.view

    def for_translation_batch(self, language, sentence_ids):
        if self.operation != "translation" or language != self.sources["targetLanguage"]:
            _fail("sourceMismatch", "request")
        sources = {"targetLanguage": language, "sentenceIDs": sentence_ids}
        _schema(sources, CONTRACT["operations"]["translation"]["source"], code="sourceMismatch")
        ids = tuple(sentence_ids)
        if not ids or any(sid >= len(self.sentences) for sid in ids):
            _fail("sourceMismatch", "evidence")
        page = self.sentences[ids[0]]["anchor"]["pageIndex"]
        _plan_page(page, language, self)
        if ids not in self._plans[(page, language)][1]:
            _fail("sourceMismatch", "evidence")
        bound = object.__new__(TrustedContext)
        for name in self.__dataclass_fields__:
            object.__setattr__(bound, name, getattr(self, name))
        object.__setattr__(bound, "sources", _freeze(sources))
        object.__setattr__(bound, "expected_batch", ids)
        return bound


def _wire(value):
    if type(value) is not dict or set(value) != set(POLICIES["requestFields"]):
        _fail()
    if type(value["schemaVersion"]) is not int:
        _fail()
    if value["schemaVersion"] != CONTRACT["schemaVersion"]:
        _fail("versionMismatch", "request")
    _schema(value["requestID"], CONTRACT["definitions"]["uuid"])
    operation = value["operation"]
    if type(operation) is not str:
        _fail()
    if operation not in CONTRACT["operations"]:
        _fail("unknownOperation", "request")
    _schema(value["input"], CONTRACT["operations"][operation]["input"])
    wire = WireRequest(value["schemaVersion"], value["requestID"], operation, _freeze(value["input"], operation + "Input"))
    if operation != "connectionTest":
        method = "canonicalPageOrder" if operation == "translation" else "wholePaperBM25"
        if wire.input["evidence"]["selection"]["method"] != method:
            _fail("invalidEvidence", "evidence")
    _input_budget(wire)
    return wire


def parse_request(raw):
    value = _decode(raw, LIMITS["innerBytes"], LIMITS["depth"], LIMITS["objectKeys"], LIMITS["arrayItems"])
    return _wire(value)


def render_messages(request):
    wire = request.wire if isinstance(request, AuthorizedRequest) else request
    if not isinstance(wire, WireRequest):
        _fail()
    operation = wire.operation
    if operation not in CONTRACT["operations"]:
        _fail("unknownOperation", "request")
    if operation == "connectionTest":
        return (Message("user", POLICIES["probePrompt"]),)
    system = POLICIES["systemPrompt"] + "\n" + operation + "\n" + canonical_bytes(result_schema(operation)).decode("utf-8")
    messages = [Message("system", system)]
    payload = dict(wire.input)
    if operation == "paperChat":
        messages.extend(Message(turn["role"], turn["text"]) for turn in payload.pop("priorTurns"))
    messages.append(Message("user", canonical_bytes(payload).decode("utf-8")))
    return tuple(messages)


def input_charge(request):
    operation = request.operation
    messages = render_messages(request)
    return sum(len(_utf8(message.content)) + LIMITS["messageOverhead"] for message in messages) + CONTRACT["operations"][operation]["controlReserve"]


def _input_budget(wire):
    messages = render_messages(wire)
    if len(messages) > LIMITS["messages"] or any(len(_utf8(m.content)) > LIMITS["messageBytes"] for m in messages) or input_charge(wire) > CONTRACT["operations"][wire.operation]["inputCharge"] or len(canonical_bytes(wire.as_record())) > LIMITS["innerBytes"]:
        _fail("inputLimit", "budget")
    if wire.operation != "connectionTest":
        items = wire.input["evidence"]["items"]
        item_cap = LIMITS["summaryItems"] if wire.operation == "librarySummary" else LIMITS["evidenceItems"]
        quote_cap = LIMITS["summaryEvidenceBytes"] if wire.operation == "librarySummary" else LIMITS["evidenceBytes"]
        if len(items) > item_cap or sum(len(_utf8(i["quote"])) for i in items) > quote_cap:
            _fail("inputLimit", "evidence")


def _new_wire(operation, payload, request_id):
    return _wire({"schemaVersion": CONTRACT["schemaVersion"], "requestID": request_id,
                  "operation": operation, "input": _plain(payload)})


def _bundle(context, candidates, selected, translation=False):
    identity = _plain(context.identity)
    identity.update({"selection": {"policyVersion": CONTRACT["schemaVersion"],
                     "method": "canonicalPageOrder" if translation else "wholePaperBM25",
                     "candidateCount": len(selected) if translation else len(candidates)},
                     "insufficiency": "none" if translation else "noEvidence" if not candidates else "budgetLimited" if len(selected) < len(candidates) else "none",
                     "items": selected})
    return identity


def _candidate_items(context, ids, translation=False):
    # Canonical ordinal gives O(1) sentence lookup, without a mutable cache.
    if translation:
        page = context.sentences[ids[0]]["anchor"]["pageIndex"] if ids else None
        low, high = 0, len(context.sentences)
        while low < high:
            middle = (low + high) // 2
            if context.sentences[middle]["anchor"]["pageIndex"] < page:
                low = middle + 1
            else:
                high = middle
        page_start = low
    else:
        page_start = 0
    return [{"anchor": context.sentences[sid]["anchor"], "quote": context.sentences[sid]["quote"],
             "rank": sid - page_start if translation else rank}
            for rank, sid in enumerate(ids)]


def _build_wire(operation, sources, context, request_id):
    if not isinstance(context, TrustedContext) or context.operation != operation:
        _fail("sourceMismatch", "request")
    _schema(sources, CONTRACT["operations"][operation]["source"], code="sourceMismatch")
    if canonical_bytes(sources) != canonical_bytes(context.sources):
        _fail("sourceMismatch", "request")
    if operation == "connectionTest":
        return _new_wire(operation, {}, request_id)
    if operation == "translation":
        ids = tuple(context.expected_batch)
        if not ids or any(b != a + 1 for a, b in zip(ids, ids[1:])) or len({context.sentences[sid]["anchor"]["pageIndex"] for sid in ids}) != 1:
            _fail("invalidEvidence", "evidence")
        # Validate that this is an actual greedy planned batch, not an arbitrary
        # subrange (including a fitting but under-filled first batch).
        page = context.sentences[ids[0]]["anchor"]["pageIndex"]
        _plan_page(page, sources["targetLanguage"], context)
        if ids not in context._plans[(page, sources["targetLanguage"])][1]:
            _fail("sourceMismatch", "evidence")
        items = _candidate_items(context, ids, True)
        return _new_wire(operation, {"targetLanguage": sources["targetLanguage"],
                                     "evidence": _bundle(context, ids, items, True)}, request_id)
    candidates = context.ranked_candidates
    payload = _plain(sources)
    turns = list(context.turns)
    if operation == "paperChat":
        payload["priorTurns"] = turns
    # History is sacrificed first, complete oldest pairs only. The desired
    # initial evidence prefix respects item/quote field caps but never skips an
    # over-cap high-ranked sentence to retain a lower-ranked one.
    item_cap = LIMITS["summaryItems"] if operation == "librarySummary" else LIMITS["evidenceItems"]
    quote_cap = LIMITS["summaryEvidenceBytes"] if operation == "librarySummary" else LIMITS["evidenceBytes"]
    items = _candidate_items(context, candidates[:item_cap])
    selected = []
    quote_bytes = 0
    for item in items:
        size = len(_utf8(item["quote"]))
        if len(selected) == item_cap or size > CONTRACT["definitions"]["item"]["fields"]["quote"]["maxBytes"] or quote_bytes + size > quote_cap:
            break
        selected.append(item)
        quote_bytes += size
    while True:
        payload["evidence"] = _bundle(context, candidates, selected)
        try:
            return _new_wire(operation, payload, request_id)
        except ContractError as error:
            if error.code != "inputLimit":
                raise
            if operation == "paperChat" and turns:
                turns = turns[2:]
                payload["priorTurns"] = turns
            elif selected:
                selected = selected[:-1]
            else:
                _fail("inputLimit", "budget")


def build_request(operation, sources, context, requestID):
    if type(operation) is not str or operation not in CONTRACT["operations"]:
        _fail("unknownOperation", "request")
    wire = _build_wire(operation, sources, context, requestID)
    return AuthorizedRequest(wire, context, _Issuance(wire, context, _SEAL))


def authorize_request(wire, context):
    if not isinstance(wire, WireRequest) or not isinstance(context, TrustedContext):
        _fail("sourceMismatch", "request")
    # Revalidate public records: constructing a WireRequest is not authorization.
    checked = parse_request(canonical_bytes(wire.as_record()))
    if checked.operation != context.operation:
        _fail("sourceMismatch", "request")
    if checked.operation != "connectionTest":
        bundle = checked.input["evidence"]
        if any(bundle[k] != context.identity[k] for k in context.identity):
            _fail("staleRevision", "evidence")
    expected = _build_wire(checked.operation, context.sources, context, checked.requestID)
    if canonical_bytes(checked.as_record()) != canonical_bytes(expected.as_record()):
        _fail("sourceMismatch", "request")
    return AuthorizedRequest(checked, context, _Issuance(checked, context, _SEAL))


def _plan_page(page, language, context):
    _schema(page, CONTRACT["definitions"]["pageIndex"], "evidence")
    _schema(language, CONTRACT["definitions"]["language"])
    if not isinstance(context, TrustedContext) or context.operation != "translation" or context.identity is None:
        _fail("sourceMismatch", "evidence")
    # Planning checks the intended language even before any batch is bound.
    intended = context.sources.get("targetLanguage", context.sources.get("outputLanguage"))
    if intended is not None and intended != language:
        _fail("sourceMismatch", "request")
    return context._plan_store.plan(page, language, context)


def _compute_page_plan(page, language, context):
    ids = tuple(s["anchor"]["sentenceID"] for s in context.sentences if s["anchor"]["pageIndex"] == page)
    if not ids:
        return ()
    batches = []
    offset = 0
    # Request UUID has a fixed byte length; a syntactically valid constant is
    # used solely for sizing, not as dispatched correlation or fake execution.
    sizing_id = "00000000-0000-4000-8000-000000000000"
    while offset < len(ids):
        longest = ()
        for end in range(offset + 1, min(len(ids), offset + LIMITS["evidenceItems"]) + 1):
            batch = ids[offset:end]
            items = _candidate_items(context, batch, True)
            try:
                _new_wire("translation", {"targetLanguage": language, "evidence": _bundle(context, batch, items, True)}, sizing_id)
            except ContractError as error:
                if error.code not in ("inputLimit", "invalidShape"):
                    raise
                break
            longest = batch
        if not longest:
            _fail("inputLimit", "evidence")
        batches.append(longest)
        offset += len(longest)
    return tuple(batches)


def plan_translation_batches(page, language, context):
    return _plan_page(page, language, context)


def encode_request(request):
    return canonical_bytes(_authorized(request).as_record())


def verify_adapter_copy(original, raw):
    expected = encode_request(original)
    copied = parse_request(raw)
    if canonical_bytes(copied.as_record()) != expected:
        _fail("sourceMismatch", "request")
    return copied


def _authorized(request):
    if not isinstance(request, AuthorizedRequest) or not isinstance(request._seal, _Issuance):
        _fail("sourceMismatch", "request")
    issuance = request._seal
    if issuance.seal is not _SEAL or issuance.wire is not request.wire or issuance.context is not request.context:
        _fail("sourceMismatch", "request")
    try:
        authorize_request(request.wire, request.context)
    except ContractError:
        _fail("sourceMismatch", "request")
    return request.wire


def validate_result(raw, request):
    wire = _authorized(request)
    value = _decode(raw, LIMITS["innerBytes"], LIMITS["depth"], LIMITS["objectKeys"], LIMITS["arrayItems"], "result")
    if type(value) is not dict or set(value) != set(POLICIES["resultFields"]):
        _fail("invalidResult", "result")
    if type(value["schemaVersion"]) is not int or value["schemaVersion"] != wire.schemaVersion or value["requestID"] != wire.requestID or value["operation"] != wire.operation:
        _fail("invalidResult", "result")
    result = value["result"]
    operation = wire.operation
    _schema(result, CONTRACT["operations"][operation]["result"], "result", "invalidResult")
    texts = []
    if operation == "connectionTest":
        texts = [result["text"]]
    elif operation == "translation":
        expected = [_anchor(i["anchor"]) for i in wire.input["evidence"]["items"]]
        if [_anchor(i) for i in result["translations"]] != expected:
            _fail("invalidResult", "result")
        texts = [i["text"] for i in result["translations"]]
    else:
        bundle = wire.input["evidence"]
        if result["insufficiency"] != bundle["insufficiency"]:
            _fail("invalidResult", "result")
        if operation == "paperChat":
            segments = result["segments"]
        elif operation == "brief":
            sections = result["sections"]
            snapshot = wire.input["templateSnapshot"]["sections"]
            if [s["sectionID"] for s in sections] != [s["sectionID"] for s in snapshot]:
                _fail("invalidResult", "result")
            for section in sections:
                if (section["state"] == "ready") != bool(section["segments"]):
                    _fail("invalidResult", "result")
            segments = [s for section in sections for s in section["segments"]]
            if len(segments) > LIMITS["arrayItems"] or (not segments and any(s["state"] != "missing-content" for s in sections)):
                _fail("invalidResult", "result")
        else:
            segments = [result["summary"]]
            summary = result["summary"]
            if summary["kind"] not in ("paper", "insufficient") or any(c in summary["text"] for c in POLICIES["summaryLineSeparators"]):
                _fail("invalidResult", "result")
        for segment in segments:
            if any(index >= len(bundle["items"]) for index in segment["evidenceIndices"]) or (bundle["insufficiency"] == "noEvidence" and segment["kind"] == "paper"):
                _fail("invalidResult", "result")
            texts.append(segment["text"])
    if sum(len(_utf8(text, "invalidResult", "result")) for text in texts) > CONTRACT["operations"][operation]["outputBytes"]:
        _fail("outputLimit", "result")
    return ValidatedResult(wire.schemaVersion, wire.requestID, operation, _freeze(result, operation + "Result"))


def wrap_model_result(raw, request):
    wire = _authorized(request)
    if wire.operation == "connectionTest":
        if type(raw) is not bytes or raw != _utf8(POLICIES["probeReply"]):
            _fail("invalidResult", "result")
        member = {"text": POLICIES["probeReply"]}
    else:
        member = _decode(raw, LIMITS["innerBytes"], LIMITS["depth"] - 1, LIMITS["objectKeys"], LIMITS["arrayItems"], "result")
    envelope = {"schemaVersion": wire.schemaVersion, "requestID": wire.requestID, "operation": wire.operation, "result": member}
    return validate_result(canonical_bytes(envelope), request)


def validate_provider_profile(profile, operation):
    """Validate a trusted certification; does not discover/certify any mapping."""
    if type(operation) is not str or operation not in CONTRACT["operations"] or not isinstance(profile, Mapping) or set(profile) != set(POLICIES["profileFields"]):
        _fail("unsupportedProvider", "provider")
    for key in ("providerID", "modelID"):
        if type(profile[key]) is not str or not profile[key] or len(profile[key]) > LIMITS["inputStringBytes"] or len(_utf8(profile[key], "unsupportedProvider", "provider")) > LIMITS["inputStringBytes"]:
            _fail("unsupportedProvider", "provider")
    for key in ("certified", "byteDecomposable", "noExpandingPreprocessing", "toolsDisabled"):
        if profile[key] is not True:
            _fail("unsupportedProvider", "provider")
    for key in ("hiddenControlBytes", "contextTokens", "maxOutputTokens"):
        if type(profile[key]) is not int or profile[key] < 0:
            _fail("unsupportedProvider", "provider")
    policy = CONTRACT["operations"][operation]
    if profile["hiddenControlBytes"] > policy["controlReserve"] or profile["contextTokens"] < policy["inputCharge"] + policy["outputTokens"] or profile["maxOutputTokens"] < policy["outputTokens"]:
        _fail("unsupportedProvider", "provider")
    return _freeze(profile, "providerProfile")


@dataclass(frozen=True)
class ValidatedURL:
    value: str
    sourceKind: str


def validate_import_url(url, sourceKind="httpsPDF"):
    if sourceKind not in POLICIES["sourceKinds"] or sourceKind == "localPDF":
        _fail("importRejected", "import")
    if type(url) is not str or len(url) > LIMITS["urlBytes"]:
        _fail("importRejected", "import")
    encoded = _utf8(url, "importRejected", "import")
    if not encoded or len(encoded) > LIMITS["urlBytes"] or any(ord(c) <= 32 or ord(c) == 127 or c == "\\" for c in url):
        _fail("importRejected", "import")
    if re.search(r"%(?:$|[^0-9A-Fa-f]|[0-9A-Fa-f](?:$|[^0-9A-Fa-f]))", url):
        _fail("importRejected", "import")
    # Escapes cannot smuggle controls/backslash into authority/path either.
    for match in re.finditer(r"%([0-9A-Fa-f]{2})", url):
        byte = int(match.group(1), 16)
        if byte < 32 or byte in (127, 92):
            _fail("importRejected", "import")
    try:
        parts = urlsplit(url)
        port = parts.port
        host = parts.hostname
        if parts.scheme != "https" or not host or parts.username is not None or parts.password is not None or "@" in parts.netloc:
            _fail("importRejected", "import")
        if port is not None and not 1 <= port <= 65535:
            _fail("importRejected", "import")
        if "%" in parts.netloc or not parts.netloc or parts.netloc.endswith(":"):
            _fail("importRejected", "import")
        if sourceKind in ("arxivAbstract", "arxivPDF"):
            if host not in POLICIES["arxivHosts"] or port is not None or parts.query or parts.fragment:
                _fail("importRejected", "import")
            prefix = POLICIES["arxivAbstractPrefix"] if sourceKind == "arxivAbstract" else POLICIES["arxivPDFPrefix"]
            if not parts.path.startswith(prefix):
                _fail("importRejected", "import")
            identifier = parts.path[len(prefix):]
            if sourceKind == "arxivPDF" and identifier.endswith(".pdf"):
                identifier = identifier[:-4]
            if not re.fullmatch(POLICIES["arxivIdentifier"], identifier):
                _fail("importRejected", "import")
    except (ValueError, UnicodeError):
        _fail("importRejected", "import")
    return ValidatedURL(url, sourceKind)


def resolve_arxiv_abstract_url(url):
    value = url.value if isinstance(url, ValidatedURL) else url
    approved = validate_import_url(value, "arxivAbstract")
    identifier = urlsplit(approved.value).path[len(POLICIES["arxivAbstractPrefix"]):]
    return validate_import_url(POLICIES["arxivCanonicalBase"] + identifier, "arxivPDF")


def resolve_redirect_url(current, location, sourceKind=None):
    kind = (current.sourceKind if isinstance(current, ValidatedURL) else "httpsPDF") if sourceKind is None else sourceKind
    base = current.value if isinstance(current, ValidatedURL) else current
    validate_import_url(base, kind)
    if type(location) is not str or len(location) > LIMITS["urlBytes"]:
        _fail("importRejected", "import")
    data = _utf8(location, "importRejected", "import")
    if not data or len(data) > LIMITS["urlBytes"] or any(ord(c) <= 32 or ord(c) == 127 or c == "\\" for c in location):
        _fail("importRejected", "import")
    try:
        target = urljoin(base, location)
    except ValueError:
        _fail("importRejected", "import")
    return validate_import_url(target, kind)


def validate_pdf_signature(prefix, mime, sourceKind):
    if sourceKind not in POLICIES["sourceKinds"] or type(prefix) is not bytes or len(prefix) > LIMITS["readBufferBytes"] or not prefix.startswith(_utf8(POLICIES["pdfMagic"])):
        _fail("importRejected", "import")
    if sourceKind != "localPDF" and (type(mime) is not str or len(mime) > LIMITS["headerBytes"] or mime.split(";", 1)[0].strip().lower() != POLICIES["pdfMIME"]):
        _fail("importRejected", "import")
    return True


@dataclass(frozen=True)
class HTTPAdmission:
    kind: str
    url: ValidatedURL


def validate_http_response(current, status, headers, prefix, budget, sourceKind=None):
    """Charge every response's headers; body reads are charged by the caller.

    prefix is bounded byte-zero metadata, not an additional body read. No
    Content-Length-based admission or counter reset is performed here.
    """
    kind = (current.sourceKind if isinstance(current, ValidatedURL) else "httpsPDF") if sourceKind is None else sourceKind
    value = current.value if isinstance(current, ValidatedURL) else current
    url = validate_import_url(value, kind)
    if not isinstance(budget, ResourceBudget) or budget.kind != "import" or type(status) is not int or not isinstance(headers, (tuple, list)) or type(prefix) is not bytes or len(prefix) > LIMITS["readBufferBytes"]:
        _fail("importRejected", "import")
    normalized = {}
    budget.add("headerCount", len(headers))
    # Bound iteration independently of metadata; accumulated headers remain
    # charged on rejected attempts as well as redirects.
    for header in headers:
        if not isinstance(header, (tuple, list)) or len(header) != 2:
            _fail("importRejected", "import")
        name, text = header
        if type(name) is not str or type(text) is not str or len(name) + len(text) + 4 > LIMITS["headerBytes"]:
            _fail("importRejected", "import")
        if type(name) is not str or not re.fullmatch(r"[!#$%&'*+.^_`|~0-9A-Za-z-]+", name) or type(text) is not str or any(ord(c) < 32 and c != "\t" or ord(c) == 127 for c in text):
            _fail("importRejected", "import")
        budget.add("headerBytes", len(_utf8(name)) + len(_utf8(text)) + 4)
        normalized.setdefault(name.lower(), []).append(text)
    if status in POLICIES["redirectStatuses"]:
        if len(normalized.get("location", ())) != 1:
            _fail("importRejected", "import")
        budget.add("redirects", 1)
        return HTTPAdmission("redirect", resolve_redirect_url(url, normalized["location"][0], kind))
    if status != POLICIES["terminalStatus"] or len(normalized.get("content-type", ())) != 1 or len(normalized.get("content-encoding", ())) > 1:
        _fail("importRejected", "import")
    encoding = normalized.get("content-encoding", [POLICIES["encoding"]])[0].strip().lower()
    if encoding != POLICIES["encoding"]:
        _fail("importRejected", "import")
    validate_pdf_signature(prefix, normalized["content-type"][0], kind)
    return HTTPAdmission("pdf", url)


class ResourceBudget:
    """Attempt or connection metrics. Failure is terminal for this budget."""
    def __init__(self, kind):
        if type(kind) is not str or kind not in CONTRACT["resources"]:
            _fail("invalidShape", "budget")
        self._kind = kind
        self._values = {name: 0 for name in CONTRACT["resources"][kind]["metrics"]}
        self._failed = False
        self._lock = threading.Lock()

    @property
    def kind(self):
        return self._kind

    @property
    def values(self):
        with self._lock:
            return MappingProxyType(dict(self._values))

    @property
    def scope(self):
        return CONTRACT["resources"][self.kind]["scope"]

    def _change(self, metric, value, mode):
        with self._lock:
            code = "parserLimit" if self.kind == "parser" else "importRejected" if self.kind == "import" else "inputLimit"
            error_field = self.kind if self.kind in ("parser", "import") else "budget"
            metrics = CONTRACT["resources"][self.kind]["metrics"]
            if self._failed or type(metric) is not str or metric not in metrics or type(value) is not int or value < 0:
                self._failed = True
                _fail(code, error_field)
            policy = metrics[metric]
            if (mode == "add" and policy["mode"] != "cumulative") or (mode == "observe" and policy["mode"] == "cumulative"):
                self._failed = True
                _fail(code, error_field)
            previous = self._values[metric]
            next_value = previous + value if mode == "add" else value
            if (policy["mode"] == "monotonic" and next_value < previous) or next_value > LIMITS[policy["limit"]]:
                self._failed = True
                _fail(code, error_field)
            self._values[metric] = next_value
            return next_value

    def add(self, metric, delta):
        return self._change(metric, delta, "add")

    def observe(self, metric, value):
        return self._change(metric, value, "observe")


_POOL_LOCK = threading.Lock()
_POOL_COUNTS = {kind: 0 for kind in CONTRACT["pools"]}


class ResourceLease:
    def __init__(self, kind, seal):
        if seal is not _SEAL:
            _fail("invalidShape", "budget")
        self._kind = kind
        self._closed = False

    def __copy__(self):
        return self

    def __deepcopy__(self, memo):
        memo[id(self)] = self
        return self

    @property
    def kind(self):
        return self._kind

    def close(self):
        with _POOL_LOCK:
            if not self._closed:
                _POOL_COUNTS[self.kind] -= 1
                self._closed = True

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()


class ResourcePool:
    """All instances share process-wide counts. acquire never queues/waits."""
    def __init__(self, kind):
        if type(kind) is not str or kind not in CONTRACT["pools"]:
            _fail("invalidShape", "budget")
        self._kind = kind

    @property
    def kind(self):
        return self._kind

    def acquire(self):
        if not _POOL_LOCK.acquire(blocking=False):
            return None
        try:
            if _POOL_COUNTS[self.kind] >= LIMITS[CONTRACT["pools"][self.kind]["limit"]]:
                return None
            _POOL_COUNTS[self.kind] += 1
            return ResourceLease(self.kind, _SEAL)
        finally:
            _POOL_LOCK.release()

    @property
    def active(self):
        with _POOL_LOCK:
            return _POOL_COUNTS[self.kind]
