import CoreFoundation
import Foundation

public struct RequestContractError: Error, Equatable, CustomStringConvertible, Sendable {
  public let code: String
  public let field: String
  public var description: String { "\(code):\(field)" }
  fileprivate init(_ code: String = "invalidShape", _ field: String = "request") {
    self.code = code
    self.field = field
  }
}

/// Value-semantic JSON. Integers retain their exact decimal representation; booleans never coerce.
public indirect enum RequestValue: Equatable, Sendable {
  case object([String: RequestValue])
  case array([RequestValue])
  case string(String)
  case integer(String)
  case bool(Bool)
  case null
  public static func == (lhs: Self, rhs: Self) -> Bool {
    switch (lhs, rhs) {
    case (.string(let a), .string(let b)), (.integer(let a), .integer(let b)):
      return a.utf8.elementsEqual(b.utf8)
    case (.bool(let a), .bool(let b)): return a == b
    case (.null, .null): return true
    case (.array(let a), .array(let b)): return a == b
    case (.object(let a), .object(let b)):
      guard a.count == b.count else { return false }
      let left = a.keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
      let right = b.keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
      return zip(left, right).allSatisfy { pair in
        pair.0.utf8.elementsEqual(pair.1.utf8) && a[pair.0] == b[pair.1]
      }
    default: return false
    }
  }
  public static func int(_ value: Int) -> Self { .integer(String(value)) }
  public subscript(_ key: String) -> RequestValue { object[key] ?? .null }
  public var object: [String: RequestValue] {
    if case .object(let v) = self { return v }
    return [:]
  }
  public var array: [RequestValue] {
    if case .array(let v) = self { return v }
    return []
  }
  public var string: String {
    if case .string(let v) = self { return v }
    return ""
  }
  public var integer: Int? {
    if case .integer(let v) = self, let number = Int(v), String(number) == v { return number }
    return nil
  }
  public var boolean: Bool? {
    if case .bool(let v) = self { return v }
    return nil
  }

  /// Strict conversion at Foundation call sites, retaining CFBoolean identity.
  public init(foundation value: Any) throws {
    if let v = value as? [String: Any] {
      self = .object(try v.mapValues { try RequestValue(foundation: $0) })
    } else if let v = value as? [Any] {
      self = .array(try v.map { try RequestValue(foundation: $0) })
    } else if let v = value as? String {
      self = .string(v)
    } else if let v = value as? NSNumber {
      if CFGetTypeID(v) == CFBooleanGetTypeID() {
        self = .bool(v.boolValue)
      } else {
        guard !["f", "d"].contains(String(cString: v.objCType)) else {
          throw RequestContractError()
        }
        self = .integer(v.stringValue)
      }
    } else if value is NSNull {
      self = .null
    } else {
      throw RequestContractError()
    }
  }
}

/// This scanner cannot reuse ProviderRPC's private JSONParser: topology has different
/// bounds and schemas. Both consume their own authority; this scanner rejects floats,
/// duplicate keys and malformed Unicode before constructing an immutable tree.
private struct StrictJSON {
  let bytes: [UInt8]
  let depth: Int
  let keys: Int
  let arrays: Int
  var offset = 0
  mutating func parse() throws -> RequestValue {
    guard String(validating: bytes, as: UTF8.self) != nil else {
      throw RequestContractError("invalidJSON")
    }
    let result = try value(0)
    whitespace()
    guard offset == bytes.count else { throw RequestContractError("invalidJSON") }
    return result
  }
  mutating func whitespace() {
    while offset < bytes.count && [9, 10, 13, 32].contains(bytes[offset]) { offset += 1 }
  }
  mutating func take(_ byte: UInt8) -> Bool {
    whitespace()
    if offset < bytes.count && bytes[offset] == byte {
      offset += 1
      return true
    }
    return false
  }
  mutating func require(_ byte: UInt8) throws {
    guard take(byte) else { throw RequestContractError("invalidJSON") }
  }
  mutating func value(_ level: Int) throws -> RequestValue {
    whitespace()
    guard offset < bytes.count else { throw RequestContractError("invalidJSON") }
    switch bytes[offset] {
    case 123:
      guard level < depth else { throw RequestContractError("invalidJSON") }
      offset += 1
      var result: [String: RequestValue] = [:]
      if take(125) { return .object(result) }
      repeat {
        let key = try text()
        guard result[key] == nil, result.count < keys else {
          throw RequestContractError("invalidJSON")
        }
        try require(58)
        result[key] = try value(level + 1)
        if take(125) { return .object(result) }
        try require(44)
      } while true
    case 91:
      guard level < depth else { throw RequestContractError("invalidJSON") }
      offset += 1
      var result: [RequestValue] = []
      if take(93) { return .array(result) }
      repeat {
        guard result.count < arrays else { throw RequestContractError("invalidJSON") }
        result.append(try value(level + 1))
        if take(93) { return .array(result) }
        try require(44)
      } while true
    case 34: return .string(try text())
    case 116:
      try literal("true")
      return .bool(true)
    case 102:
      try literal("false")
      return .bool(false)
    case 110:
      try literal("null")
      return .null
    default:
      let start = offset
      if bytes[offset] == 45 { offset += 1 }
      guard offset < bytes.count, (48...57).contains(bytes[offset]) else {
        throw RequestContractError("invalidJSON")
      }
      if bytes[offset] == 48 {
        offset += 1
      } else {
        while offset < bytes.count && (48...57).contains(bytes[offset]) { offset += 1 }
      }
      guard offset - start <= 20 else { throw RequestContractError("invalidJSON") }
      let number = String(decoding: bytes[start..<offset], as: UTF8.self)
      return .integer(number == "-0" ? "0" : number)
    }
  }
  mutating func literal(_ text: String) throws {
    let token = Array(text.utf8)
    guard bytes.count - offset >= token.count, Array(bytes[offset..<offset + token.count]) == token
    else { throw RequestContractError("invalidJSON") }
    offset += token.count
  }
  mutating func hex() throws -> UInt32 {
    guard bytes.count - offset >= 4 else { throw RequestContractError("invalidJSON") }
    var v: UInt32 = 0
    for _ in 0..<4 {
      let b = bytes[offset]
      offset += 1
      let digit: UInt32
      switch b {
      case 48...57: digit = UInt32(b - 48)
      case 65...70: digit = UInt32(b - 55)
      case 97...102: digit = UInt32(b - 87)
      default: throw RequestContractError("invalidJSON")
      }
      v = v * 16 + digit
    }
    return v
  }
  mutating func text() throws -> String {
    try require(34)
    var output: [UInt8] = []
    while offset < bytes.count {
      let b = bytes[offset]
      offset += 1
      if b == 34 {
        guard let text = String(validating: output, as: UTF8.self) else {
          throw RequestContractError("invalidJSON")
        }
        return text
      }
      guard b >= 32 else { throw RequestContractError("invalidJSON") }
      if b != 92 {
        output.append(b)
        continue
      }
      guard offset < bytes.count else { throw RequestContractError("invalidJSON") }
      let escape = bytes[offset]
      offset += 1
      switch escape {
      case 34, 47, 92: output.append(escape)
      case 98: output.append(8)
      case 102: output.append(12)
      case 110: output.append(10)
      case 114: output.append(13)
      case 116: output.append(9)
      case 117:
        var scalar = try hex()
        if (0xD800...0xDBFF).contains(scalar) {
          guard bytes.count - offset >= 2, bytes[offset] == 92, bytes[offset + 1] == 117 else {
            throw RequestContractError("invalidJSON")
          }
          offset += 2
          let low = try hex()
          guard (0xDC00...0xDFFF).contains(low) else { throw RequestContractError("invalidJSON") }
          scalar = 0x10000 + (scalar - 0xD800) * 1024 + low - 0xDC00
        }
        guard let unicode = Unicode.Scalar(scalar), !(0xD800...0xDFFF).contains(scalar) else {
          throw RequestContractError("invalidJSON")
        }
        output.append(contentsOf: String(unicode).utf8)
      default: throw RequestContractError("invalidJSON")
      }
    }
    throw RequestContractError("invalidJSON")
  }
}

public enum RequestOperation: String, CaseIterable, Sendable {
  case connectionTest, translation, paperChat, brief, librarySummary
}
public struct RequestAnchor: Equatable, Sendable {
  public let pageIndex: Int
  public let sentenceID: Int
  public init(pageIndex: Int, sentenceID: Int) {
    self.pageIndex = pageIndex
    self.sentenceID = sentenceID
  }
  fileprivate var value: RequestValue {
    .object(["pageIndex": .int(pageIndex), "sentenceID": .int(sentenceID)])
  }
  fileprivate init(_ value: RequestValue) {
    pageIndex = value["pageIndex"].integer!
    sentenceID = value["sentenceID"].integer!
  }
}
public struct RequestSentence: Equatable, Sendable {
  public let anchor: RequestAnchor
  public let quote: String
  public init(anchor: RequestAnchor, quote: String) {
    self.anchor = anchor
    self.quote = quote
  }
  fileprivate var value: RequestValue {
    .object(["anchor": anchor.value, "quote": .string(quote)])
  }
  public static func == (lhs: Self, rhs: Self) -> Bool { lhs.value == rhs.value }
}
public struct RequestPaperIdentity: Equatable, Sendable {
  public let paperID: String
  public let paperGeneration: Int
  public let pdfSHA256: String
  public let extractionRevision: String
  public init(paperID: String, paperGeneration: Int, pdfSHA256: String, extractionRevision: String)
  {
    self.paperID = paperID
    self.paperGeneration = paperGeneration
    self.pdfSHA256 = pdfSHA256
    self.extractionRevision = extractionRevision
  }
  fileprivate var value: RequestValue {
    .object([
      "paperID": .string(paperID), "paperGeneration": .int(paperGeneration),
      "pdfSHA256": .string(pdfSHA256), "extractionRevision": .string(extractionRevision),
    ])
  }
}
public struct RequestTurn: Equatable, Sendable {
  public let turnID: String
  public let role: String
  public let text: String
  public init(turnID: String, role: String, text: String) {
    self.turnID = turnID
    self.role = role
    self.text = text
  }
  fileprivate var value: RequestValue {
    .object(["turnID": .string(turnID), "role": .string(role), "text": .string(text)])
  }
  public static func == (lhs: Self, rhs: Self) -> Bool { lhs.value == rhs.value }
}
public struct RequestSection: Equatable, Sendable {
  public let sectionID: String
  public let heading: String
  public let prompt: String
  public init(sectionID: String, heading: String, prompt: String) {
    self.sectionID = sectionID
    self.heading = heading
    self.prompt = prompt
  }
  fileprivate var value: RequestValue {
    .object([
      "sectionID": .string(sectionID), "heading": .string(heading), "prompt": .string(prompt),
    ])
  }
  public static func == (lhs: Self, rhs: Self) -> Bool { lhs.value == rhs.value }
}
public struct RequestTemplateSnapshot: Equatable, Sendable {
  public let snapshotID: String
  public let templateVersionID: String
  public let sections: [RequestSection]
  public let outputLanguage: String
  public let policyVersion: Int
  public init(
    snapshotID: String, templateVersionID: String, sections: [RequestSection],
    outputLanguage: String, policyVersion: Int
  ) {
    self.snapshotID = snapshotID
    self.templateVersionID = templateVersionID
    self.sections = sections
    self.outputLanguage = outputLanguage
    self.policyVersion = policyVersion
  }
  fileprivate var value: RequestValue {
    .object([
      "snapshotID": .string(snapshotID), "templateVersionID": .string(templateVersionID),
      "sections": .array(sections.map(\.value)),
      "generationInputs": .object([
        "outputLanguage": .string(outputLanguage), "policyVersion": .int(policyVersion),
      ]),
    ])
  }
  public static func == (lhs: Self, rhs: Self) -> Bool { lhs.value == rhs.value }
}
public enum RequestSources: Equatable, Sendable {
  case connectionTest
  case translation(targetLanguage: String, sentenceIDs: [Int])
  case paperChat(sessionID: String, question: String)
  case brief(RequestTemplateSnapshot)
  case librarySummary(outputLanguage: String)
  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.operation == rhs.operation && lhs.value == rhs.value
  }
  public var operation: RequestOperation {
    switch self {
    case .connectionTest: return .connectionTest
    case .translation: return .translation
    case .paperChat: return .paperChat
    case .brief: return .brief
    case .librarySummary: return .librarySummary
    }
  }
  public var value: RequestValue {
    switch self {
    case .connectionTest: return .object([:])
    case .translation(let language, let ids):
      return .object([
        "targetLanguage": .string(language), "sentenceIDs": .array(ids.map { .int($0) }),
      ])
    case .paperChat(let session, let question):
      return .object(["sessionID": .string(session), "question": .string(question)])
    case .brief(let snapshot): return .object(["templateSnapshot": snapshot.value])
    case .librarySummary(let language): return .object(["outputLanguage": .string(language)])
    }
  }
}
public struct RequestEvidenceItem: Equatable, Sendable {
  public let anchor: RequestAnchor
  public let quote: String
  public let rank: Int
  fileprivate init(_ v: RequestValue) {
    anchor = RequestAnchor(v["anchor"])
    quote = v["quote"].string
    rank = v["rank"].integer!
  }
  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.anchor == rhs.anchor && lhs.rank == rhs.rank && lhs.quote.utf8.elementsEqual(rhs.quote.utf8)
  }
}
public struct RequestSelection: Equatable, Sendable {
  public let policyVersion: Int
  public let method: String
  public let candidateCount: Int
  fileprivate init(_ v: RequestValue) {
    policyVersion = v["policyVersion"].integer!
    method = v["method"].string
    candidateCount = v["candidateCount"].integer!
  }
}
public struct RequestEvidenceBundle: Equatable, Sendable {
  public let identity: RequestPaperIdentity
  public let selection: RequestSelection
  public let insufficiency: String
  public let items: [RequestEvidenceItem]
  fileprivate init(_ v: RequestValue) {
    identity = RequestPaperIdentity(
      paperID: v["paperID"].string, paperGeneration: v["paperGeneration"].integer!,
      pdfSHA256: v["pdfSHA256"].string, extractionRevision: v["extractionRevision"].string)
    selection = RequestSelection(v["selection"])
    insufficiency = v["insufficiency"].string
    items = v["items"].array.map(RequestEvidenceItem.init)
  }
}
public enum RequestInput: Equatable, Sendable {
  case connectionTest
  case translation(targetLanguage: String, evidence: RequestEvidenceBundle)
  case paperChat(
    sessionID: String, question: String, priorTurns: [RequestTurn], evidence: RequestEvidenceBundle)
  case brief(templateSnapshot: RequestTemplateSnapshot, evidence: RequestEvidenceBundle)
  case librarySummary(outputLanguage: String, evidence: RequestEvidenceBundle)
  public static func == (lhs: Self, rhs: Self) -> Bool {
    switch (lhs, rhs) {
    case (.connectionTest, .connectionTest): return true
    case (.translation(let a, let x), .translation(let b, let y)),
      (.librarySummary(let a, let x), .librarySummary(let b, let y)):
      return a.utf8.elementsEqual(b.utf8) && x == y
    case (.paperChat(let a, let q, let t, let x), .paperChat(let b, let r, let u, let y)):
      return a.utf8.elementsEqual(b.utf8) && q.utf8.elementsEqual(r.utf8) && t == u && x == y
    case (.brief(let a, let x), .brief(let b, let y)): return a == b && x == y
    default: return false
    }
  }
}
public struct RequestGrounded: Equatable, Sendable {
  public let text: String
  public let kind: String
  public let evidenceIndices: [Int]
  fileprivate init(_ v: RequestValue) {
    text = v["text"].string
    kind = v["kind"].string
    evidenceIndices = v["evidenceIndices"].array.map { $0.integer! }
  }
  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.text.utf8.elementsEqual(rhs.text.utf8) && lhs.kind == rhs.kind
      && lhs.evidenceIndices == rhs.evidenceIndices
  }
}
public struct RequestTranslation: Equatable, Sendable {
  public let anchor: RequestAnchor
  public let text: String
  fileprivate init(_ v: RequestValue) {
    anchor = RequestAnchor(v)
    text = v["text"].string
  }
  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.anchor == rhs.anchor && lhs.text.utf8.elementsEqual(rhs.text.utf8)
  }
}
public struct RequestResultSection: Equatable, Sendable {
  public let sectionID: String
  public let state: String
  public let segments: [RequestGrounded]
  fileprivate init(_ v: RequestValue) {
    sectionID = v["sectionID"].string
    state = v["state"].string
    segments = v["segments"].array.map(RequestGrounded.init)
  }
}
public enum RequestResult: Equatable, Sendable {
  case connectionTest(String)
  case translation([RequestTranslation])
  case paperChat([RequestGrounded], insufficiency: String)
  case brief([RequestResultSection], insufficiency: String)
  case librarySummary(RequestGrounded, insufficiency: String)
}
public struct WireProviderRequest: Equatable, Sendable {
  public let schemaVersion: Int
  public let requestID: String
  public let operation: RequestOperation
  public let input: RequestValue
  public var typedInput: RequestInput {
    switch operation {
    case .connectionTest: return .connectionTest
    case .translation:
      return .translation(
        targetLanguage: input["targetLanguage"].string,
        evidence: RequestEvidenceBundle(input["evidence"]))
    case .paperChat:
      return .paperChat(
        sessionID: input["sessionID"].string, question: input["question"].string,
        priorTurns: input["priorTurns"].array.map {
          RequestTurn(turnID: $0["turnID"].string, role: $0["role"].string, text: $0["text"].string)
        }, evidence: RequestEvidenceBundle(input["evidence"]))
    case .brief:
      let v = input["templateSnapshot"]
      let snapshot = RequestTemplateSnapshot(
        snapshotID: v["snapshotID"].string, templateVersionID: v["templateVersionID"].string,
        sections: v["sections"].array.map {
          RequestSection(
            sectionID: $0["sectionID"].string, heading: $0["heading"].string,
            prompt: $0["prompt"].string)
        }, outputLanguage: v["generationInputs"]["outputLanguage"].string,
        policyVersion: v["generationInputs"]["policyVersion"].integer!)
      return .brief(templateSnapshot: snapshot, evidence: RequestEvidenceBundle(input["evidence"]))
    case .librarySummary:
      return .librarySummary(
        outputLanguage: input["outputLanguage"].string,
        evidence: RequestEvidenceBundle(input["evidence"]))
    }
  }
  public var evidenceItems: [RequestEvidenceItem] {
    input["evidence"]["items"].array.map(RequestEvidenceItem.init)
  }
  public var value: RequestValue {
    .object([
      "schemaVersion": .int(schemaVersion), "requestID": .string(requestID),
      "operation": .string(operation.rawValue), "input": input,
    ])
  }
  fileprivate init(version: Int, id: String, operation: RequestOperation, input: RequestValue) {
    schemaVersion = version
    requestID = id
    self.operation = operation
    self.input = input
  }
}
public struct AuthorizedProviderRequest: Sendable {
  public let wire: WireProviderRequest
  public let context: TrustedRequestContext
  fileprivate let authority: ProviderRequest
  fileprivate init(
    wire: WireProviderRequest, context: TrustedRequestContext, authority: ProviderRequest
  ) {
    self.wire = wire
    self.context = context
    self.authority = authority
  }
}
public struct ValidatedProviderResult: Equatable, Sendable {
  public let schemaVersion: Int
  public let requestID: String
  public let operation: RequestOperation
  public let result: RequestResult
  public let value: RequestValue
}
public struct RequestMessage: Equatable, Sendable {
  public let role: String
  public let content: String
  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.role == rhs.role && lhs.content.utf8.elementsEqual(rhs.content.utf8)
  }
}

/// Immutable corpus ownership is shared only by contexts created through batch binding.
private final class RequestCorpus: Sendable {
  let identity: RequestPaperIdentity?
  let sentences: [RequestSentence]
  let ranked: [Int]
  let turns: [RequestTurn]
  let pageRanges: [Int: Range<Int>]
  init(
    identity: RequestPaperIdentity?, sentences: [RequestSentence], ranked: [Int],
    turns: [RequestTurn]
  ) {
    self.identity = identity
    self.sentences = sentences
    self.ranked = ranked
    self.turns = turns
    var ranges: [Int: Range<Int>] = [:]
    for (index, sentence) in sentences.enumerated() {
      let page = sentence.anchor.pageIndex
      ranges[page] = (ranges[page]?.lowerBound ?? index)..<(index + 1)
    }
    pageRanges = ranges
  }
}
private final class TranslationPlans: @unchecked Sendable {
  let corpus: RequestCorpus
  let language: String
  private let lock = NSLock()
  private var plans: [Int: [[Int]]] = [:]
  private var membership: [Int: Set<[Int]>] = [:]
  init(corpus: RequestCorpus, language: String) {
    self.corpus = corpus
    self.language = language
  }
  func plan(page: Int, context: TrustedRequestContext, authority: ProviderRequest) throws -> [[Int]]
  {
    guard context.corpus === corpus, context.sources.value["targetLanguage"].string == language
    else { throw RequestContractError("sourceMismatch", "evidence") }
    lock.lock()
    defer { lock.unlock() }
    if let plan = plans[page] { return plan }
    let computed = try authority.computePlan(page: page, language: language, context: context)
    plans[page] = computed
    membership[page] = Set(computed)
    return computed
  }
  func contains(page: Int, batch: [Int]) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return membership[page]?.contains(batch) == true
  }
}
public final class TrustedRequestContext: Sendable {
  public let sources: RequestSources
  public var operation: RequestOperation { sources.operation }
  public var identity: RequestPaperIdentity? { corpus.identity }
  public var sentences: [RequestSentence] { corpus.sentences }
  public var rankedCandidates: [Int] { corpus.ranked }
  public var turns: [RequestTurn] { corpus.turns }
  public let expectedBatch: [Int]
  fileprivate let corpus: RequestCorpus
  fileprivate let plans: TranslationPlans?
  fileprivate let authority: ProviderRequest
  public init(
    authority: ProviderRequest, sources: RequestSources, identity: RequestPaperIdentity? = nil,
    sentences: [RequestSentence] = [], rankedCandidates: [Int] = [], turns: [RequestTurn] = [],
    expectedBatch: [Int] = []
  ) throws {
    try authority.check(
      sources.value, schema: authority.operation(sources.operation)["source"],
      code: "sourceMismatch")
    if sources.operation == .connectionTest {
      guard identity == nil, sentences.isEmpty, rankedCandidates.isEmpty, turns.isEmpty,
        expectedBatch.isEmpty
      else { throw RequestContractError("sourceMismatch") }
    } else {
      guard let identity else { throw RequestContractError("sourceMismatch", "evidence") }
      try authority.check(
        identity.value, schema: authority.definition("identity"), field: "evidence",
        code: "sourceMismatch")
      guard sentences.count <= authority.limit("sentences") else {
        throw RequestContractError("inputLimit", "evidence")
      }
      var page = -1
      var total = 0
      for (index, sentence) in sentences.enumerated() {
        try authority.check(
          sentence.value, schema: authority.definition("sentence"), field: "evidence",
          code: "sourceMismatch")
        guard sentence.anchor.sentenceID == index, sentence.anchor.pageIndex >= page else {
          throw RequestContractError("sourceMismatch", "evidence")
        }
        page = sentence.anchor.pageIndex
        total += sentence.quote.utf8.count
        guard total <= authority.limit("textBytes") else {
          throw RequestContractError("inputLimit", "evidence")
        }
      }
      guard rankedCandidates.count <= authority.limit("sentences"),
        Set(rankedCandidates).count == rankedCandidates.count,
        rankedCandidates.allSatisfy({ $0 >= 0 && $0 < sentences.count })
      else { throw RequestContractError("sourceMismatch", "evidence") }
      try authority.check(
        .array(turns.map(\.value)), schema: authority.definition("turns"), field: "history",
        code: "invalidHistory")
      guard sources.operation == .paperChat || turns.isEmpty else {
        throw RequestContractError("sourceMismatch", "history")
      }
      if case .translation(_, let ids) = sources {
        guard ids == expectedBatch, expectedBatch.allSatisfy({ $0 >= 0 && $0 < sentences.count })
        else { throw RequestContractError("sourceMismatch", "evidence") }
      } else if !expectedBatch.isEmpty {
        throw RequestContractError("sourceMismatch", "evidence")
      }
    }
    self.authority = authority
    self.sources = sources
    self.expectedBatch = expectedBatch
    let corpus = RequestCorpus(
      identity: identity, sentences: sentences, ranked: rankedCandidates, turns: turns)
    self.corpus = corpus
    if case .translation(let language, _) = sources {
      plans = TranslationPlans(corpus: corpus, language: language)
    } else {
      plans = nil
    }
  }
  private init(parent: TrustedRequestContext, sources: RequestSources, batch: [Int]) {
    authority = parent.authority
    corpus = parent.corpus
    plans = parent.plans
    self.sources = sources
    expectedBatch = batch
  }
  public func forTranslationBatch(language: String, sentenceIDs: [Int]) throws
    -> TrustedRequestContext
  {
    guard case .translation(let intended, _) = sources, language == intended, !sentenceIDs.isEmpty,
      sentenceIDs.allSatisfy({ $0 >= 0 && $0 < corpus.sentences.count })
    else { throw RequestContractError("sourceMismatch") }
    let source = RequestSources.translation(targetLanguage: language, sentenceIDs: sentenceIDs)
    try authority.check(
      source.value, schema: authority.operation(.translation)["source"], code: "sourceMismatch")
    let page = corpus.sentences[sentenceIDs[0]].anchor.pageIndex
    _ = try authority.planTranslationBatches(page: page, language: language, context: self)
    guard plans!.contains(page: page, batch: sentenceIDs) else {
      throw RequestContractError("sourceMismatch", "evidence")
    }
    return TrustedRequestContext(parent: self, sources: source, batch: sentenceIDs)
  }
}

/// Pure policy consumer. Certification is a supplied claim, never an SDK/network discovery.
public final class ProviderRequest: Sendable {
  public let contract: RequestValue
  private static let rules: Set<String> = [
    "bundleRelations", "historyPairs", "snapshotIdentity", "citationRelations", "translationOrder",
    "resultInsufficiency", "snapshotResult", "summaryLine", "fixedProbe", "translationPlan",
    "frozenProvenance", "renderedBudget", "rankedPrefix", "historyFirst",
  ]
  private static func bundledData() throws -> Data {
    #if SWIFT_PACKAGE
      guard let url = Bundle.module.url(forResource: "contract", withExtension: "json") else {
        throw RequestContractError("contractDefinition")
      }
    #else
      guard
        let url = Bundle(for: RequestBundleToken.self).url(
          forResource: "contract", withExtension: "json", subdirectory: "ProviderRequest")
      else { throw RequestContractError("contractDefinition") }
    #endif
    do { return try Data(contentsOf: url) } catch {
      throw RequestContractError("contractDefinition")
    }
  }
  public convenience init() throws { try self.init(contractData: Self.bundledData()) }
  public init(contractData: Data) throws {
    do {
      contract = try Self.decode(contractData, bytes: 1_048_576, depth: 32, keys: 256, arrays: 1000)
      let shipped = try Self.decode(
        Self.bundledData(), bytes: 1_048_576, depth: 32, keys: 256, arrays: 1000)
      try Self.closedDefinitionKeys(contract)
      try Self.closedDefinitionKeys(shipped)
      guard try Self.canonicalBytes(contract) == Self.canonicalBytes(shipped) else {
        throw RequestContractError("contractDefinition")
      }
      try validateDefinition()
    } catch { throw RequestContractError("contractDefinition") }
  }
  public func limit(_ name: String) -> Int { contract["limits"][name].integer! }
  private static func closedDefinitionKeys(_ value: RequestValue) throws {
    switch value {
    case .object(let object):
      for (key, child) in object {
        guard key.utf8.allSatisfy({ $0 < 128 }) else {
          throw RequestContractError("contractDefinition")
        }
        try closedDefinitionKeys(child)
      }
    case .array(let array): for child in array { try closedDefinitionKeys(child) }
    default: break
    }
  }
  fileprivate func definition(_ name: String) -> RequestValue { contract["definitions"][name] }
  fileprivate func operation(_ op: RequestOperation) -> RequestValue {
    contract["operations"][op.rawValue]
  }
  private func policy(_ key: String) -> RequestValue { contract["policies"][key] }
  private static func decode(
    _ raw: Data, bytes: Int, depth: Int, keys: Int, arrays: Int, field: String = "request"
  ) throws -> RequestValue {
    guard raw.count <= bytes else {
      throw RequestContractError(field == "result" ? "outputLimit" : "inputLimit", field)
    }
    do {
      var parser = StrictJSON(bytes: Array(raw), depth: depth, keys: keys, arrays: arrays)
      return try parser.parse()
    } catch { throw RequestContractError("invalidJSON", field) }
  }
  private func decode(_ raw: Data, field: String = "request", depth: Int? = nil) throws
    -> RequestValue
  {
    try Self.decode(
      raw, bytes: limit("innerBytes"), depth: depth ?? limit("depth"), keys: limit("objectKeys"),
      arrays: limit("arrayItems"), field: field)
  }
  public static func canonicalBytes(_ value: RequestValue) throws -> Data {
    func quote(_ s: String) -> String {
      var output = "\""
      for scalar in s.unicodeScalars {
        switch scalar.value {
        case 34: output += "\\\""
        case 92: output += "\\\\"
        case 8: output += "\\b"
        case 12: output += "\\f"
        case 10: output += "\\n"
        case 13: output += "\\r"
        case 9: output += "\\t"
        case 0..<32: output += String(format: "\\u%04x", scalar.value)
        default: output.unicodeScalars.append(scalar)
        }
      }
      return output + "\""
    }
    func render(_ value: RequestValue) throws -> String {
      switch value {
      case .object(let v):
        return "{"
          + (try v.keys.sorted().map { try quote($0) + ":" + render(v[$0]!) }).joined(
            separator: ",") + "}"
      case .array(let v): return "[" + (try v.map(render)).joined(separator: ",") + "]"
      case .string(let v): return quote(v)
      case .integer(let v):
        guard v.utf8.count <= 20, Self.fullMatch("-?(?:0|[1-9][0-9]*)", v) else {
          throw RequestContractError()
        }
        return v == "-0" ? "0" : v
      case .bool(let v): return v ? "true" : "false"
      case .null: return "null"
      }
    }
    return Data(try render(value).utf8)
  }
  private static func fullMatch(_ pattern: String, _ value: String) -> Bool {
    guard let expression = try? NSRegularExpression(pattern: "\\A(?:" + pattern + ")\\z") else {
      return false
    }
    return expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
  }
  private func strings(_ value: RequestValue) -> [String] { value.array.map(\.string) }
  private func exact(_ value: RequestValue, _ names: Set<String>) -> Bool {
    if case .object(let v) = value {
      guard v.keys.allSatisfy({ $0.utf8.allSatisfy { $0 < 128 } }) else { return false }
      return Set(v.keys) == names
    }
    return false
  }
  private func validateDefinition() throws {
    func demand(_ condition: Bool) throws {
      guard condition else { throw RequestContractError("contractDefinition") }
    }
    try demand(
      exact(
        contract,
        [
          "schemaVersion", "limits", "definitions", "operations", "policies", "rules", "resources",
          "pools", "conformance",
        ]) && contract["schemaVersion"] == .int(1))
    let names: Set<String> = [
      "innerBytes", "bodyBytes", "frameBytes", "depth", "outerDepth", "objectKeys", "arrayItems",
      "inputStringBytes", "resultStringBytes", "messages", "messageBytes", "messageOverhead",
      "evidenceItems", "evidenceBytes", "summaryItems", "summaryEvidenceBytes", "snapshotBytes",
      "historyMessages", "streams", "chunks", "streamBytes", "outstanding", "ordinary", "cancel",
      "queuedFrames", "queuedBytes", "requestsPerConnection", "probeDeadlineMs",
      "generationDeadlineMs", "redirects", "headerBytes", "headerCount", "pdfBytes",
      "readBufferBytes", "importConcurrency", "idleMs", "importElapsedMs", "pages", "sentences",
      "textBytes", "sentenceBytes", "quadsPerSentence", "quads", "batchSentences", "batchBytes",
      "parserConcurrency", "parserElapsedMs", "rssBytes", "watchdogIntervalMs", "urlBytes",
    ]
    try demand(
      exact(contract["limits"], names)
        && contract["limits"].object.values.allSatisfy { ($0.integer ?? -1) >= 0 })
    try demand(exact(contract["operations"], Set(RequestOperation.allCases.map(\.rawValue))))
    try demand(
      Set(strings(contract["rules"])) == Self.rules
        && contract["rules"].array.count == Self.rules.count)
    func schema(_ s: RequestValue, seen: Set<String> = []) throws {
      guard case .object(let object) = s, !object.isEmpty else {
        throw RequestContractError("contractDefinition")
      }
      if let ref = object["ref"] {
        guard case .string(let name) = ref else { throw RequestContractError("contractDefinition") }
        try demand(
          exact(s, ["ref"]) && !seen.contains(name) && contract["definitions"].object[name] != nil)
        try schema(definition(name), seen: seen.union([name]))
        return
      }
      var allowed: Set<String> = ["type", "const", "enum", "rules"]
      switch s["type"].string {
      case "object":
        allowed.insert("fields")
        guard case .object(let fields) = s["fields"] else {
          throw RequestContractError("contractDefinition")
        }
        for child in fields.values { try schema(child, seen: seen) }
      case "array":
        allowed.formUnion(["items", "minItems", "maxItems"])
        try schema(s["items"], seen: seen)
      case "integer": allowed.formUnion(["minimum", "maximum"])
      case "string":
        allowed.formUnion(["maxBytes", "pattern"])
        if let p = object["pattern"] {
          guard case .string(let pattern) = p else {
            throw RequestContractError("contractDefinition")
          }
          _ = try NSRegularExpression(pattern: pattern)
        }
      case "uuid": break
      default: throw RequestContractError("contractDefinition")
      }
      try demand(Set(object.keys).isSubset(of: allowed))
      for key in ["minimum", "maximum", "maxBytes", "minItems", "maxItems"] {
        if let v = object[key] { try demand((v.integer ?? -1) >= 0) }
      }
      for (low, high) in [("minimum", "maximum"), ("minItems", "maxItems")] {
        if let a = object[low], let b = object[high] { try demand(a.integer! <= b.integer!) }
      }
      if let v = object["enum"] {
        guard case .array(let a) = v, !a.isEmpty else {
          throw RequestContractError("contractDefinition")
        }
      }
      if let v = object["rules"] {
        guard case .array(let entries) = v,
          entries.allSatisfy({
            if case .string = $0 { return true }
            return false
          })
        else { throw RequestContractError("contractDefinition") }
        let r = strings(v)
        try demand(Set(r).count == r.count && Set(r).isSubset(of: Self.rules))
      }
    }
    guard case .object(let definitions) = contract["definitions"] else {
      throw RequestContractError("contractDefinition")
    }
    for s in definitions.values { try schema(s) }
    for o in contract["operations"].object.values {
      try demand(
        exact(
          o,
          [
            "input", "result", "source", "inputCharge", "outputTokens", "outputBytes",
            "controlReserve", "rules",
          ]))
      for key in ["input", "result", "source"] { try schema(o[key]) }
      for key in ["inputCharge", "outputTokens", "outputBytes", "controlReserve"] {
        try demand((o[key].integer ?? -1) >= 0)
      }
      guard case .array(let entries) = o["rules"],
        entries.allSatisfy({
          if case .string = $0 { return true }
          return false
        })
      else { throw RequestContractError("contractDefinition") }
      let r = strings(o["rules"])
      try demand(Set(r).isSubset(of: Self.rules) && Set(r).count == r.count)
    }
    try demand(
      exact(
        contract["policies"],
        [
          "requestFields", "resultFields", "canonical", "uuidPattern", "systemPrompt",
          "probePrompt", "probeReply", "summaryQuery", "sourceKinds", "arxivHosts",
          "arxivIdentifier", "arxivAbstractPrefix", "arxivPDFPrefix", "arxivCanonicalBase",
          "redirectStatuses", "terminalStatus", "pdfMIME", "encoding", "pdfMagic",
          "summaryLineSeparators", "profileFields", "errorFields", "errorCodes",
        ]))
    try demand(
      policy("canonical")
        == .object([
          "sortKeys": .bool(true), "ensureASCII": .bool(false),
          "separators": .array([.string(","), .string(":")]), "allowNaN": .bool(false),
        ]))
    for key in [
      "uuidPattern", "systemPrompt", "probePrompt", "probeReply", "summaryQuery", "arxivIdentifier",
      "arxivAbstractPrefix", "arxivPDFPrefix", "arxivCanonicalBase", "pdfMIME", "encoding",
      "pdfMagic",
    ] {
      guard case .string(let v) = policy(key), !v.isEmpty else {
        throw RequestContractError("contractDefinition")
      }
    }
    for key in [
      "requestFields", "resultFields", "sourceKinds", "arxivHosts", "summaryLineSeparators",
      "profileFields", "errorFields", "errorCodes",
    ] {
      guard case .array(let a) = policy(key),
        a.allSatisfy({
          if case .string = $0 { return true }
          return false
        })
      else { throw RequestContractError("contractDefinition") }
      try demand(Set(strings(policy(key))).count == a.count)
    }
    _ = try NSRegularExpression(pattern: policy("uuidPattern").string)
    _ = try NSRegularExpression(pattern: policy("arxivIdentifier").string)
    guard case .array(let statuses) = policy("redirectStatuses") else {
      throw RequestContractError("contractDefinition")
    }
    try demand(statuses.allSatisfy { $0.integer != nil } && policy("terminalStatus").integer != nil)
    try demand(
      exact(contract["resources"], ["import", "parser", "rpc"])
        && exact(contract["pools"], ["import", "parser"]))
    for (kind, resource) in contract["resources"].object {
      try demand(
        exact(resource, ["scope", "metrics"])
          && resource["scope"].string == (kind == "rpc" ? "connection" : "attempt"))
      guard case .object(let metrics) = resource["metrics"] else {
        throw RequestContractError("contractDefinition")
      }
      for metric in metrics.values {
        try demand(
          exact(metric, ["unit", "mode", "limit"])
            && ["bytes", "count", "ms"].contains(metric["unit"].string)
            && ["cumulative", "gauge", "monotonic"].contains(metric["mode"].string)
            && names.contains(metric["limit"].string))
      }
    }
    for pool in contract["pools"].object.values {
      try demand(
        exact(pool, ["scope", "limit"]) && pool["scope"].string == "process"
          && names.contains(pool["limit"].string))
    }
    try demand(
      exact(
        contract["conformance"], ["canonical", "rendered", "requests", "results", "invalidJSON"]))
    let vectorKeys: [String: Set<String>] = [
      "canonical": ["value", "utf8"],
      "rendered": ["operation", "input", "messages", "contentBytes", "inputCharge"],
      "requests": ["accepted", "value", "code"],
      "results": ["accepted", "request", "value", "code"],
    ]
    for (group, allowed) in vectorKeys {
      guard case .array(let vectors) = contract["conformance"][group] else {
        throw RequestContractError("contractDefinition")
      }
      for vector in vectors {
        guard case .object(let object) = vector else {
          throw RequestContractError("contractDefinition")
        }
        try demand(
          Set(object.keys).isSubset(of: allowed)
            && allowed.subtracting(["code", "contentBytes", "inputCharge"]).isSubset(
              of: Set(object.keys))
        )
      }
    }
  }
  fileprivate func check(
    _ value: RequestValue, schema: RequestValue, field: String = "request",
    code: String = "invalidShape"
  ) throws {
    if schema.object["ref"] != nil {
      try check(value, schema: definition(schema["ref"].string), field: field, code: code)
      return
    }
    func demand(_ condition: Bool) throws {
      guard condition else { throw RequestContractError(code, field) }
    }
    switch schema["type"].string {
    case "object":
      try demand(exact(value, Set(schema["fields"].object.keys)))
      for (key, s) in schema["fields"].object {
        try check(value[key], schema: s, field: field, code: code)
      }
    case "array":
      guard case .array(let a) = value else { throw RequestContractError(code, field) }
      try demand(
        a.count >= (schema["minItems"].integer ?? 0)
          && a.count <= (schema["maxItems"].integer ?? limit("arrayItems")))
      for v in a { try check(v, schema: schema["items"], field: field, code: code) }
    case "integer":
      guard let n = value.integer else { throw RequestContractError(code, field) }
      try demand(
        n >= (schema["minimum"].integer ?? 0) && n <= (schema["maximum"].integer ?? Int.max))
    case "string", "uuid":
      guard case .string(let s) = value else { throw RequestContractError(code, field) }
      try demand(
        !s.isEmpty && s.utf8.count <= (schema["maxBytes"].integer ?? limit("inputStringBytes")))
      let p =
        schema["type"].string == "uuid" ? policy("uuidPattern").string : schema["pattern"].string
      try demand(p.isEmpty || Self.fullMatch(p, s))
    default: throw RequestContractError("contractDefinition")
    }
    if let constant = schema.object["const"] { try demand(value == constant) }
    if let enumeration = schema.object["enum"] { try demand(enumeration.array.contains(value)) }
    for rule in strings(schema["rules"]) {
      switch rule {
      case "historyPairs":
        let turns = value.array
        guard turns.count % 2 == 0, Set(turns.map { $0["turnID"].string }).count == turns.count,
          turns.enumerated().allSatisfy({
            $0.element["role"].string == ($0.offset % 2 == 0 ? "user" : "assistant")
          })
        else { throw RequestContractError("invalidHistory", "history") }
      case "snapshotIdentity":
        guard
          Set(value["sections"].array.map { $0["sectionID"].string }).count
            == value["sections"].array.count,
          try Self.canonicalBytes(value).count <= limit("snapshotBytes")
        else { throw RequestContractError("invalidTemplate", "template") }
      case "bundleRelations": try bundleRelations(value)
      case "citationRelations":
        let indices = value["evidenceIndices"].array.map { $0.integer! }
        guard indices == Set(indices).sorted(),
          !(value["kind"].string == "paper" && indices.isEmpty),
          !(value["kind"].string == "insufficient" && !indices.isEmpty)
        else { throw RequestContractError("invalidResult", "result") }
      default: break  // Context-dependent rules are enforced at authorization/result sinks.
      }
    }
  }
  private func bundleRelations(_ bundle: RequestValue) throws {
    let items = bundle["items"].array
    let count = bundle["selection"]["candidateCount"].integer!
    let ids = items.map { $0["anchor"]["sentenceID"].integer! }
    let pages = items.map { $0["anchor"]["pageIndex"].integer! }
    let ranks = items.map { $0["rank"].integer! }
    guard Set(ids).count == ids.count, ranks == Set(ranks).sorted() else {
      throw RequestContractError("invalidEvidence", "evidence")
    }
    if bundle["selection"]["method"].string == "canonicalPageOrder" {
      guard let first = ranks.first, !items.isEmpty, count == items.count,
        bundle["insufficiency"].string == "none", Set(pages).count == 1,
        ranks == Array(first..<first + ranks.count), ids == ids.sorted()
      else { throw RequestContractError("invalidEvidence", "evidence") }
    } else {
      let expected = count == 0 ? "noEvidence" : items.count < count ? "budgetLimited" : "none"
      guard ranks == Array(0..<items.count), items.count <= count,
        bundle["insufficiency"].string == expected
      else { throw RequestContractError("invalidEvidence", "evidence") }
    }
  }
  public func parseRequest(_ raw: Data) throws -> WireProviderRequest { try wire(decode(raw)) }
  private func wire(_ value: RequestValue) throws -> WireProviderRequest {
    guard exact(value, Set(strings(policy("requestFields")))),
      case .integer = value["schemaVersion"]
    else { throw RequestContractError() }
    guard value["schemaVersion"] == contract["schemaVersion"] else {
      throw RequestContractError("versionMismatch")
    }
    let version = contract["schemaVersion"].integer!
    try check(value["requestID"], schema: definition("uuid"))
    guard case .string(let tag) = value["operation"] else { throw RequestContractError() }
    guard let op = RequestOperation(rawValue: tag) else {
      throw RequestContractError("unknownOperation")
    }
    try check(value["input"], schema: operation(op)["input"])
    let result = WireProviderRequest(
      version: version, id: value["requestID"].string, operation: op, input: value["input"])
    if op != .connectionTest {
      guard
        value["input"]["evidence"]["selection"]["method"].string
          == (op == .translation ? "canonicalPageOrder" : "wholePaperBM25")
      else { throw RequestContractError("invalidEvidence", "evidence") }
    }
    try inputBudget(result)
    return result
  }
  public func resultSchema(_ operation: RequestOperation) -> RequestValue {
    func resolve(_ s: RequestValue) -> RequestValue {
      if s.object["ref"] != nil { return resolve(definition(s["ref"].string)) }
      var o = s.object
      if let fields = o["fields"] { o["fields"] = .object(fields.object.mapValues(resolve)) }
      if let items = o["items"] { o["items"] = resolve(items) }
      return .object(o)
    }
    return resolve(self.operation(operation)["result"])
  }
  public func renderMessages(_ request: WireProviderRequest) throws -> [RequestMessage] {
    if request.operation == .connectionTest {
      return [RequestMessage(role: "user", content: policy("probePrompt").string)]
    }
    let system =
      policy("systemPrompt").string + "\n" + request.operation.rawValue + "\n"
      + String(decoding: try Self.canonicalBytes(resultSchema(request.operation)), as: UTF8.self)
    var messages = [RequestMessage(role: "system", content: system)]
    var payload = request.input.object
    if request.operation == .paperChat {
      for turn in payload.removeValue(forKey: "priorTurns")!.array {
        messages.append(RequestMessage(role: turn["role"].string, content: turn["text"].string))
      }
    }
    messages.append(
      RequestMessage(
        role: "user",
        content: String(decoding: try Self.canonicalBytes(.object(payload)), as: UTF8.self)))
    return messages
  }
  public func inputCharge(_ request: WireProviderRequest) throws -> Int {
    try renderMessages(request).reduce(operation(request.operation)["controlReserve"].integer!) {
      $0 + $1.content.utf8.count + limit("messageOverhead")
    }
  }
  private func inputBudget(_ wire: WireProviderRequest) throws {
    let messages = try renderMessages(wire)
    guard messages.count <= limit("messages"),
      messages.allSatisfy({ $0.content.utf8.count <= limit("messageBytes") }),
      try inputCharge(wire) <= operation(wire.operation)["inputCharge"].integer!,
      try Self.canonicalBytes(wire.value).count <= limit("innerBytes")
    else { throw RequestContractError("inputLimit", "budget") }
    if wire.operation != .connectionTest {
      let items = wire.input["evidence"]["items"].array
      guard
        items.count <= limit(wire.operation == .librarySummary ? "summaryItems" : "evidenceItems"),
        items.reduce(0, { $0 + $1["quote"].string.utf8.count })
          <= limit(wire.operation == .librarySummary ? "summaryEvidenceBytes" : "evidenceBytes")
      else { throw RequestContractError("inputLimit", "evidence") }
    }
  }
  private func newWire(_ operation: RequestOperation, _ payload: RequestValue, _ id: String) throws
    -> WireProviderRequest
  {
    try wire(
      .object([
        "schemaVersion": contract["schemaVersion"], "requestID": .string(id),
        "operation": .string(operation.rawValue), "input": payload,
      ]))
  }
  private func bundle(
    _ context: TrustedRequestContext, candidates: [Int], items: [RequestValue],
    translation: Bool = false
  ) -> RequestValue {
    var value = context.identity!.value.object
    value["selection"] = .object([
      "policyVersion": contract["schemaVersion"],
      "method": .string(translation ? "canonicalPageOrder" : "wholePaperBM25"),
      "candidateCount": .int(translation ? items.count : candidates.count),
    ])
    value["insufficiency"] = .string(
      translation
        ? "none"
        : candidates.isEmpty
          ? "noEvidence" : items.count < candidates.count ? "budgetLimited" : "none")
    value["items"] = .array(items)
    return .object(value)
  }
  private func items(_ context: TrustedRequestContext, ids: [Int], translation: Bool = false)
    -> [RequestValue]
  {
    var start = 0
    if translation, let first = ids.first {
      let page = context.corpus.sentences[first].anchor.pageIndex
      start = context.corpus.pageRanges[page]!.lowerBound
    }
    return ids.enumerated().map { rank, id in
      let s = context.corpus.sentences[id]
      return .object([
        "anchor": s.anchor.value, "quote": .string(s.quote),
        "rank": .int(translation ? id - start : rank),
      ])
    }
  }
  private func buildWire(sources: RequestSources, context: TrustedRequestContext, requestID: String)
    throws -> WireProviderRequest
  {
    guard context.authority === self,
      try Self.canonicalBytes(sources.value) == Self.canonicalBytes(context.sources.value)
    else { throw RequestContractError("sourceMismatch") }
    let op = sources.operation
    if op == .connectionTest { return try newWire(op, .object([:]), requestID) }
    if case .translation(let language, _) = sources {
      let ids = context.expectedBatch
      guard !ids.isEmpty, zip(ids, ids.dropFirst()).allSatisfy({ pair in pair.1 == pair.0 + 1 }),
        Set(ids.map { context.corpus.sentences[$0].anchor.pageIndex }).count == 1
      else { throw RequestContractError("invalidEvidence", "evidence") }
      let page = context.corpus.sentences[ids[0]].anchor.pageIndex
      _ = try planTranslationBatches(page: page, language: language, context: context)
      guard context.plans!.contains(page: page, batch: ids) else {
        throw RequestContractError("sourceMismatch", "evidence")
      }
      return try newWire(
        op,
        .object([
          "targetLanguage": .string(language),
          "evidence": bundle(
            context, candidates: ids, items: items(context, ids: ids, translation: true),
            translation: true),
        ]), requestID)
    }
    let candidates = context.corpus.ranked
    let cap = limit(op == .librarySummary ? "summaryItems" : "evidenceItems")
    let bytesCap = limit(op == .librarySummary ? "summaryEvidenceBytes" : "evidenceBytes")
    var selected: [RequestValue] = []
    var bytes = 0
    for item in items(context, ids: Array(candidates.prefix(cap))) {
      let size = item["quote"].string.utf8.count
      if size > definition("item")["fields"]["quote"]["maxBytes"].integer!
        || bytes + size > bytesCap
      {
        break
      }
      selected.append(item)
      bytes += size
    }
    var payload = sources.value.object
    var turns = context.corpus.turns.map(\.value)
    while true {
      if op == .paperChat { payload["priorTurns"] = .array(turns) }
      payload["evidence"] = bundle(context, candidates: candidates, items: selected)
      do { return try newWire(op, .object(payload), requestID) } catch let e as RequestContractError
      {
        guard e.code == "inputLimit" else { throw e }
        if op == .paperChat && !turns.isEmpty {
          turns.removeFirst(2)
        } else if !selected.isEmpty {
          selected.removeLast()
        } else {
          throw RequestContractError("inputLimit", "budget")
        }
      }
    }
  }
  public func buildRequest(
    sources: RequestSources, context: TrustedRequestContext, requestID: String
  ) throws -> AuthorizedProviderRequest {
    AuthorizedProviderRequest(
      wire: try buildWire(sources: sources, context: context, requestID: requestID),
      context: context, authority: self)
  }
  public func authorizeRequest(_ wire: WireProviderRequest, context: TrustedRequestContext) throws
    -> AuthorizedProviderRequest
  {
    let checked = try parseRequest(Self.canonicalBytes(wire.value))
    guard checked.operation == context.operation, context.authority === self else {
      throw RequestContractError("sourceMismatch")
    }
    if checked.operation != .connectionTest {
      guard let identity = context.identity,
        identity.value.object.allSatisfy({ checked.input["evidence"][$0.key] == $0.value })
      else { throw RequestContractError("staleRevision", "evidence") }
    }
    let expected = try buildWire(
      sources: context.sources, context: context, requestID: checked.requestID)
    guard try Self.canonicalBytes(checked.value) == Self.canonicalBytes(expected.value) else {
      throw RequestContractError("sourceMismatch")
    }
    return AuthorizedProviderRequest(wire: checked, context: context, authority: self)
  }
  private func authorized(_ request: AuthorizedProviderRequest) throws -> WireProviderRequest {
    guard request.authority === self else { throw RequestContractError("sourceMismatch") }
    do { _ = try authorizeRequest(request.wire, context: request.context) } catch {
      throw RequestContractError("sourceMismatch")
    }
    return request.wire
  }
  public func encodeRequest(_ request: AuthorizedProviderRequest) throws -> Data {
    try Self.canonicalBytes(authorized(request).value)
  }
  public func verifyAdapterCopy(_ request: AuthorizedProviderRequest, raw: Data) throws
    -> WireProviderRequest
  {
    let expected = try encodeRequest(request)
    let copy = try parseRequest(raw)
    guard try Self.canonicalBytes(copy.value) == expected else {
      throw RequestContractError("sourceMismatch")
    }
    return copy
  }
  public func planTranslationBatches(page: Int, language: String, context: TrustedRequestContext)
    throws -> [[Int]]
  {
    try check(.int(page), schema: definition("pageIndex"), field: "evidence")
    try check(.string(language), schema: definition("language"))
    guard context.authority === self, context.operation == .translation, let plans = context.plans
    else { throw RequestContractError("sourceMismatch", "evidence") }
    guard plans.language == language else { throw RequestContractError("sourceMismatch") }
    return try plans.plan(page: page, context: context, authority: self)
  }
  fileprivate func computePlan(page: Int, language: String, context: TrustedRequestContext) throws
    -> [[Int]]
  {
    let ids = Array(context.corpus.pageRanges[page] ?? (0..<0))
    var batches: [[Int]] = []
    var offset = 0
    guard ids.isEmpty || limit("evidenceItems") > 0 else {
      throw RequestContractError("inputLimit", "evidence")
    }
    while offset < ids.count {
      var longest: [Int] = []
      for end in (offset + 1)...min(ids.count, offset + limit("evidenceItems")) {
        let batch = Array(ids[offset..<end])
        do {
          _ = try newWire(
            .translation,
            .object([
              "targetLanguage": .string(language),
              "evidence": bundle(
                context, candidates: batch, items: items(context, ids: batch, translation: true),
                translation: true),
            ]), "00000000-0000-4000-8000-000000000000")
        } catch let e as RequestContractError {
          guard ["inputLimit", "invalidShape"].contains(e.code) else { throw e }
          break
        }
        longest = batch
      }
      guard !longest.isEmpty else { throw RequestContractError("inputLimit", "evidence") }
      batches.append(longest)
      offset += longest.count
    }
    return batches
  }
  public func validateResult(_ raw: Data, request: AuthorizedProviderRequest) throws
    -> ValidatedProviderResult
  {
    let wire = try authorized(request)
    let value = try decode(raw, field: "result")
    guard exact(value, Set(strings(policy("resultFields")))),
      value["schemaVersion"] == .int(wire.schemaVersion),
      value["requestID"] == .string(wire.requestID),
      value["operation"] == .string(wire.operation.rawValue)
    else { throw RequestContractError("invalidResult", "result") }
    let member = value["result"]
    let op = wire.operation
    try check(member, schema: operation(op)["result"], field: "result", code: "invalidResult")
    var texts: [String] = []
    let typed: RequestResult
    if op == .connectionTest {
      texts = [member["text"].string]
      typed = .connectionTest(member["text"].string)
    } else if op == .translation {
      let translations = member["translations"].array.map(RequestTranslation.init)
      guard translations.map(\.anchor) == wire.evidenceItems.map(\.anchor) else {
        throw RequestContractError("invalidResult", "result")
      }
      texts = translations.map(\.text)
      typed = .translation(translations)
    } else {
      let bundle = wire.input["evidence"]
      let insufficiency = member["insufficiency"].string
      guard member["insufficiency"] == bundle["insufficiency"] else {
        throw RequestContractError("invalidResult", "result")
      }
      let segments: [RequestGrounded]
      switch op {
      case .paperChat:
        segments = member["segments"].array.map(RequestGrounded.init)
        typed = .paperChat(segments, insufficiency: insufficiency)
      case .brief:
        let sections = member["sections"].array.map(RequestResultSection.init)
        guard
          sections.map(\.sectionID)
            == wire.input["templateSnapshot"]["sections"].array.map({ $0["sectionID"].string }),
          sections.allSatisfy({ ($0.state == "ready") == !$0.segments.isEmpty })
        else { throw RequestContractError("invalidResult", "result") }
        segments = sections.flatMap(\.segments)
        guard segments.count <= limit("arrayItems"),
          !segments.isEmpty || sections.allSatisfy({ $0.state == "missing-content" })
        else { throw RequestContractError("invalidResult", "result") }
        typed = .brief(sections, insufficiency: insufficiency)
      case .librarySummary:
        let summary = RequestGrounded(member["summary"])
        guard ["paper", "insufficient"].contains(summary.kind),
          !strings(policy("summaryLineSeparators")).contains(where: summary.text.contains)
        else { throw RequestContractError("invalidResult", "result") }
        segments = [summary]
        typed = .librarySummary(summary, insufficiency: insufficiency)
      default: throw RequestContractError("invalidResult", "result")
      }
      for segment in segments {
        guard segment.evidenceIndices.allSatisfy({ $0 < bundle["items"].array.count }),
          !(insufficiency == "noEvidence" && segment.kind == "paper")
        else { throw RequestContractError("invalidResult", "result") }
      }
      texts = segments.map(\.text)
    }
    guard texts.reduce(0, { $0 + $1.utf8.count }) <= operation(op)["outputBytes"].integer! else {
      throw RequestContractError("outputLimit", "result")
    }
    return ValidatedProviderResult(
      schemaVersion: wire.schemaVersion, requestID: wire.requestID, operation: op, result: typed,
      value: value)
  }
  public func wrapModelResult(_ raw: Data, request: AuthorizedProviderRequest) throws
    -> ValidatedProviderResult
  {
    let wire = try authorized(request)
    let member: RequestValue
    if wire.operation == .connectionTest {
      guard raw == Data(policy("probeReply").string.utf8) else {
        throw RequestContractError("invalidResult", "result")
      }
      member = .object(["text": policy("probeReply")])
    } else {
      member = try decode(raw, field: "result", depth: limit("depth") - 1)
    }
    return try validateResult(
      Self.canonicalBytes(
        .object([
          "schemaVersion": .int(wire.schemaVersion), "requestID": .string(wire.requestID),
          "operation": .string(wire.operation.rawValue), "result": member,
        ])), request: request)
  }
  public func validateProviderProfile(_ profile: RequestValue, operation op: RequestOperation)
    throws -> RequestValue
  {
    func demand(_ c: Bool) throws {
      guard c else { throw RequestContractError("unsupportedProvider", "provider") }
    }
    try demand(exact(profile, Set(strings(policy("profileFields")))))
    for key in ["providerID", "modelID"] {
      guard case .string(let v) = profile[key], !v.isEmpty,
        v.utf8.count <= limit("inputStringBytes")
      else { throw RequestContractError("unsupportedProvider", "provider") }
    }
    for key in ["certified", "byteDecomposable", "noExpandingPreprocessing", "toolsDisabled"] {
      try demand(profile[key] == .bool(true))
    }
    for key in ["hiddenControlBytes", "contextTokens", "maxOutputTokens"] {
      try demand((profile[key].integer ?? -1) >= 0)
    }
    let o = operation(op)
    let sum = o["inputCharge"].integer!.addingReportingOverflow(o["outputTokens"].integer!)
    try demand(
      !sum.overflow && profile["hiddenControlBytes"].integer! <= o["controlReserve"].integer!
        && profile["contextTokens"].integer! >= sum.partialValue
        && profile["maxOutputTokens"].integer! >= o["outputTokens"].integer!)
    return profile
  }
  public func validateImportURL(_ value: String, sourceKind: String = "httpsPDF") throws
    -> ValidatedRequestURL
  {
    func reject() -> RequestContractError { RequestContractError("importRejected", "import") }
    guard strings(policy("sourceKinds")).contains(sourceKind), sourceKind != "localPDF",
      !value.isEmpty, value.utf8.count <= limit("urlBytes"),
      !value.unicodeScalars.contains(where: { $0.value <= 32 || $0.value == 127 || $0.value == 92 })
    else { throw reject() }
    let bytes = Array(value.utf8)
    var i = 0
    while i < bytes.count {
      if bytes[i] == 37 {
        guard i + 2 < bytes.count,
          let b = UInt8(String(decoding: bytes[(i + 1)...(i + 2)], as: UTF8.self), radix: 16),
          b >= 32, b != 127, b != 92
        else { throw reject() }
        i += 3
      } else {
        i += 1
      }
    }
    // Inspect the original authority; URLComponents can silently repair malformed input.
    guard let separator = value.range(of: "://"),
      value[..<separator.lowerBound].lowercased() == "https"
    else { throw reject() }
    let authorityText = String(value[separator.upperBound...].prefix { !"/?#".contains($0) })
    guard !authorityText.isEmpty, !authorityText.contains("@"), !authorityText.contains("%"),
      !authorityText.hasSuffix(":"), let parts = URLComponents(string: value),
      parts.scheme?.lowercased() == "https", let host = parts.host, !host.isEmpty,
      parts.user == nil, parts.password == nil
    else { throw reject() }
    if let port = parts.port { guard (1...65535).contains(port) else { throw reject() } }
    if ["arxivAbstract", "arxivPDF"].contains(sourceKind) {
      guard strings(policy("arxivHosts")).contains(host.lowercased()), parts.port == nil,
        (parts.query ?? "").isEmpty, (parts.fragment ?? "").isEmpty
      else { throw reject() }
      let prefix = policy(sourceKind == "arxivAbstract" ? "arxivAbstractPrefix" : "arxivPDFPrefix")
        .string
      // Percent-encoded identifiers are not accepted by Python's raw-path grammar.
      let path = parts.percentEncodedPath
      guard path.hasPrefix(prefix) else { throw reject() }
      var identifier = String(path.dropFirst(prefix.count))
      if sourceKind == "arxivPDF" && identifier.hasSuffix(".pdf") {
        identifier = String(identifier.dropLast(4))
      }
      guard Self.fullMatch(policy("arxivIdentifier").string, identifier) else { throw reject() }
    }
    return ValidatedRequestURL(value: value, sourceKind: sourceKind)
  }
  public func resolveArxivAbstractURL(_ value: String) throws -> ValidatedRequestURL {
    let approved = try validateImportURL(value, sourceKind: "arxivAbstract")
    let path = URLComponents(string: approved.value)!.percentEncodedPath
    let identifier = String(path.dropFirst(policy("arxivAbstractPrefix").string.count))
    return try validateImportURL(
      policy("arxivCanonicalBase").string + identifier, sourceKind: "arxivPDF")
  }
  public func resolveRedirectURL(
    _ current: ValidatedRequestURL, location: String, sourceKind: String? = nil
  ) throws -> ValidatedRequestURL {
    if let sourceKind, !sourceKind.utf8.elementsEqual(current.sourceKind.utf8) {
      throw RequestContractError("importRejected", "import")
    }
    let kind = current.sourceKind
    _ = try validateImportURL(current.value, sourceKind: kind)
    guard !location.isEmpty, location.utf8.count <= limit("urlBytes"),
      !location.unicodeScalars.contains(where: {
        $0.value <= 32 || $0.value == 127 || $0.value == 92
      }), let base = URL(string: current.value),
      let resolved = URL(string: location, relativeTo: base)?.absoluteURL,
      var parts = URLComponents(url: resolved, resolvingAgainstBaseURL: false)
    else { throw RequestContractError("importRejected", "import") }
    // Check escapes before Foundation can quote a malformed '%' in the target.
    let raw = Array(location.utf8)
    for i in raw.indices where raw[i] == 37 {
      guard i + 2 < raw.count,
        let byte = UInt8(String(decoding: raw[(i + 1)...(i + 2)], as: UTF8.self), radix: 16),
        byte >= 32, byte != 127, byte != 92
      else { throw RequestContractError("importRejected", "import") }
    }
    // Foundation on macOS 15 retains leading /../ segments. Apply RFC 3986's
    // literal dot-segment removal explicitly; encoded dots remain ordinary bytes.
    let path = parts.percentEncodedPath
    var segments: [Substring] = []
    for segment in path.split(separator: "/", omittingEmptySubsequences: false).dropFirst() {
      if segment == ".." {
        if !segments.isEmpty { segments.removeLast() }
      } else if segment != "." {
        segments.append(segment)
      }
    }
    if !path.isEmpty {
      let trailingDot = path.hasSuffix("/.") || path.hasSuffix("/..")
      parts.percentEncodedPath = "/" + segments.joined(separator: "/")
        + (trailingDot && !segments.isEmpty ? "/" : "")
    }
    guard let target = parts.string else {
      throw RequestContractError("importRejected", "import")
    }
    return try validateImportURL(target, sourceKind: kind)
  }
  @discardableResult public func validatePDFSignature(
    prefix: Data, mime: String?, sourceKind: String
  ) throws -> Bool {
    guard strings(policy("sourceKinds")).contains(sourceKind),
      prefix.count <= limit("readBufferBytes"),
      prefix.starts(with: Data(policy("pdfMagic").string.utf8))
    else { throw RequestContractError("importRejected", "import") }
    if sourceKind != "localPDF" {
      guard let mime, mime.utf8.count <= limit("headerBytes"),
        mime.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)[0]
          .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == policy("pdfMIME").string
      else { throw RequestContractError("importRejected", "import") }
    }
    return true
  }
  public func validateHTTPResponse(
    current: ValidatedRequestURL, status: Int, headers: [RequestHTTPHeader], prefix: Data,
    budget: RequestResourceBudget, sourceKind: String? = nil
  ) throws -> RequestHTTPAdmission {
    if let sourceKind, !sourceKind.utf8.elementsEqual(current.sourceKind.utf8) {
      throw RequestContractError("importRejected", "import")
    }
    let kind = current.sourceKind
    let url = try validateImportURL(current.value, sourceKind: kind)
    guard budget.authority === self, budget.kind == "import",
      prefix.count <= limit("readBufferBytes")
    else { throw RequestContractError("importRejected", "import") }
    var normalized: [String: [String]] = [:]
    try budget.add("headerCount", delta: headers.count)
    for header in headers {
      guard header.name.utf8.count + header.value.utf8.count + 4 <= limit("headerBytes"),
        Self.fullMatch("[!#$%&'*+.^_`|~0-9A-Za-z-]+", header.name),
        !header.value.unicodeScalars.contains(where: {
          ($0.value < 32 && $0.value != 9) || $0.value == 127
        })
      else { throw RequestContractError("importRejected", "import") }
      try budget.add("headerBytes", delta: header.name.utf8.count + header.value.utf8.count + 4)
      normalized[header.name.lowercased(), default: []].append(header.value)
    }
    if policy("redirectStatuses").array.contains(.int(status)) {
      guard let locations = normalized["location"], locations.count == 1 else {
        throw RequestContractError("importRejected", "import")
      }
      try budget.add("redirects", delta: 1)
      return .redirect(try resolveRedirectURL(url, location: locations[0], sourceKind: kind))
    }
    guard status == policy("terminalStatus").integer, let mime = normalized["content-type"],
      mime.count == 1, (normalized["content-encoding"]?.count ?? 0) <= 1
    else { throw RequestContractError("importRejected", "import") }
    let encoding = (normalized["content-encoding"]?.first ?? policy("encoding").string)
      .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard encoding == policy("encoding").string else {
      throw RequestContractError("importRejected", "import")
    }
    try validatePDFSignature(prefix: prefix, mime: mime[0], sourceKind: kind)
    return .pdf(url)
  }
}
private final class RequestBundleToken: NSObject {}
public struct ValidatedRequestURL: Equatable, Sendable {
  public let value: String
  public let sourceKind: String
  fileprivate init(value: String, sourceKind: String) {
    self.value = value
    self.sourceKind = sourceKind
  }
}
public struct RequestHTTPHeader: Equatable, Sendable {
  public let name: String
  public let value: String
  public init(_ name: String, _ value: String) {
    self.name = name
    self.value = value
  }
}
public enum RequestHTTPAdmission: Equatable, Sendable {
  case redirect(ValidatedRequestURL)
  case pdf(ValidatedRequestURL)
}

public final class RequestResourceBudget: @unchecked Sendable {
  public let kind: String
  fileprivate let authority: ProviderRequest
  private let lock = NSLock()
  private var counters: [String: Int]
  private var failed = false
  public var scope: String { authority.contract["resources"][kind]["scope"].string }
  public var values: [String: Int] {
    lock.lock()
    defer { lock.unlock() }
    return counters
  }
  public init(authority: ProviderRequest, kind: String) throws {
    guard authority.contract["resources"].object[kind] != nil else {
      throw RequestContractError("invalidShape", "budget")
    }
    self.authority = authority
    self.kind = kind
    counters = authority.contract["resources"][kind]["metrics"].object.mapValues { _ in 0 }
  }
  @discardableResult public func add(_ metric: String, delta: Int) throws -> Int {
    try change(metric, value: delta, add: true)
  }
  @discardableResult public func observe(_ metric: String, value: Int) throws -> Int {
    try change(metric, value: value, add: false)
  }
  private func change(_ metric: String, value: Int, add: Bool) throws -> Int {
    lock.lock()
    defer { lock.unlock() }
    let error = RequestContractError(
      kind == "parser" ? "parserLimit" : kind == "import" ? "importRejected" : "inputLimit",
      ["parser", "import"].contains(kind) ? kind : "budget")
    let metrics = authority.contract["resources"][kind]["metrics"].object
    guard !failed, let policy = metrics[metric], value >= 0, let previous = counters[metric] else {
      failed = true
      throw error
    }
    let mode = policy["mode"].string
    guard add ? mode == "cumulative" : mode != "cumulative" else {
      failed = true
      throw error
    }
    let sum = previous.addingReportingOverflow(value)
    let next = add ? sum.partialValue : value
    guard !(add && sum.overflow), !(mode == "monotonic" && next < previous),
      next <= authority.limit(policy["limit"].string)
    else {
      failed = true
      throw error
    }
    counters[metric] = next
    return next
  }
}
private final class RequestPoolState: @unchecked Sendable {
  static let shared = RequestPoolState()
  let lock = NSLock()
  var counts: [String: Int] = [:]
}
public final class RequestResourceLease: @unchecked Sendable {
  public let kind: String
  private var closed = false
  fileprivate init(kind: String) { self.kind = kind }
  public func close() {
    let state = RequestPoolState.shared
    state.lock.lock()
    defer { state.lock.unlock() }
    if !closed {
      state.counts[kind, default: 0] -= 1
      closed = true
    }
  }
  deinit { close() }
}
public final class RequestResourcePool: Sendable {
  public let kind: String
  private let cap: Int
  public init(authority: ProviderRequest, kind: String) throws {
    guard let policy = authority.contract["pools"].object[kind] else {
      throw RequestContractError("invalidShape", "budget")
    }
    self.kind = kind
    cap = authority.limit(policy["limit"].string)
  }
  public func acquire() -> RequestResourceLease? {
    let state = RequestPoolState.shared
    guard state.lock.try() else { return nil }
    defer { state.lock.unlock() }
    guard state.counts[kind, default: 0] < cap else { return nil }
    state.counts[kind, default: 0] += 1
    return RequestResourceLease(kind: kind)
  }
  public var active: Int {
    let state = RequestPoolState.shared
    state.lock.lock()
    defer { state.lock.unlock() }
    return state.counts[kind, default: 0]
  }
}
