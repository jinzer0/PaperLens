import Foundation
import ProviderRequest
import XCTest

final class ProviderRequestTests: XCTestCase {
  private let id = "00000000-0000-4000-8000-000000000001"
  private let paperID = "00000000-0000-4000-8000-000000000002"
  private let revision = "00000000-0000-4000-8000-000000000003"
  private let session = "00000000-0000-4000-8000-000000000004"

  private func bytes(_ value: RequestValue) throws -> Data {
    try ProviderRequest.canonicalBytes(value)
  }
  private func rejects<T>(
    _ code: String? = nil, _ field: String? = nil, file: StaticString = #filePath,
    line: UInt = #line, _ action: () throws -> T
  ) {
    XCTAssertThrowsError(try action(), file: file, line: line) { error in
      guard let safe = error as? RequestContractError else {
        XCTFail("Non-contract error", file: file, line: line)
        return
      }
      if let code { XCTAssertEqual(safe.code, code, file: file, line: line) }
      if let field { XCTAssertEqual(safe.field, field, file: file, line: line) }
      XCTAssertEqual(safe.description, safe.code + ":" + safe.field, file: file, line: line)
      XCTAssertFalse(safe.description.contains("PRIVATE"), file: file, line: line)
    }
  }
  private func replacing(_ value: RequestValue, path: [String], with replacement: RequestValue?)
    -> RequestValue
  {
    guard let key = path.first else { return replacement ?? .null }
    var object = value.object
    if path.count == 1 {
      object[key] = replacement
    } else {
      object[key] = replacing(object[key]!, path: Array(path.dropFirst()), with: replacement)
    }
    return .object(object)
  }
  private func identity(generation: Int = 1) -> RequestPaperIdentity {
    RequestPaperIdentity(
      paperID: paperID, paperGeneration: generation, pdfSHA256: String(repeating: "a", count: 64),
      extractionRevision: revision)
  }
  private func sentences(_ count: Int, quote: String = "Canonical evidence.", page: Int = 0)
    -> [RequestSentence]
  {
    (0..<count).map {
      RequestSentence(anchor: RequestAnchor(pageIndex: page, sentenceID: $0), quote: quote)
    }
  }
  private func snapshot() -> RequestTemplateSnapshot {
    RequestTemplateSnapshot(
      snapshotID: "00000000-0000-4000-8000-000000000005",
      templateVersionID: "00000000-0000-4000-8000-000000000006",
      sections: [
        RequestSection(
          sectionID: "00000000-0000-4000-8000-000000000007", heading: "Conclusion",
          prompt: "Summarize the conclusion.")
      ], outputLanguage: "en", policyVersion: 1)
  }
  private func sources(_ operation: RequestOperation) -> RequestSources {
    switch operation {
    case .connectionTest: return .connectionTest
    case .translation: return .translation(targetLanguage: "ko", sentenceIDs: [])
    case .paperChat: return .paperChat(sessionID: session, question: "What is known?")
    case .brief: return .brief(snapshot())
    case .librarySummary: return .librarySummary(outputLanguage: "en")
    }
  }
  private func context(
    _ api: ProviderRequest, source: RequestSources, corpus: [RequestSentence] = [],
    ranked: [Int] = [], turns: [RequestTurn] = [], expected: [Int] = []
  ) throws -> TrustedRequestContext {
    try TrustedRequestContext(
      authority: api, sources: source,
      identity: source.operation == .connectionTest ? nil : identity(), sentences: corpus,
      rankedCandidates: ranked, turns: turns, expectedBatch: expected)
  }
  private func request(
    _ api: ProviderRequest, operation: RequestOperation, count: Int = 0,
    quote: String = "Canonical evidence."
  ) throws -> AuthorizedProviderRequest {
    let source = sources(operation)
    let corpus = operation == .connectionTest ? [] : sentences(count, quote: quote)
    var ctx = try context(api, source: source, corpus: corpus, ranked: Array(corpus.indices))
    if operation == .translation {
      let batches = try api.planTranslationBatches(page: 0, language: "ko", context: ctx)
      ctx = try ctx.forTranslationBatch(language: "ko", sentenceIDs: XCTUnwrap(batches.first))
    }
    return try api.buildRequest(sources: ctx.sources, context: ctx, requestID: id)
  }
  private func grounded(
    _ text: String = "No canonical evidence.", kind: String = "insufficient", indices: [Int] = []
  ) -> RequestValue {
    .object([
      "text": .string(text), "kind": .string(kind),
      "evidenceIndices": .array(indices.map { .int($0) }),
    ])
  }
  private func member(_ wire: WireProviderRequest) -> RequestValue {
    let insufficiency = wire.input["evidence"]["insufficiency"]
    switch wire.operation {
    case .connectionTest: return .object(["text": .string("PAPERLENS_OK")])
    case .translation:
      return .object([
        "translations": .array(
          wire.evidenceItems.map {
            .object([
              "pageIndex": .int($0.anchor.pageIndex), "sentenceID": .int($0.anchor.sentenceID),
              "text": .string("번역"),
            ])
          })
      ])
    case .paperChat:
      return .object(["segments": .array([grounded()]), "insufficiency": insufficiency])
    case .brief:
      return .object([
        "sections": .array(
          wire.input["templateSnapshot"]["sections"].array.map {
            .object([
              "sectionID": $0["sectionID"], "state": .string("missing-content"),
              "segments": .array([]),
            ])
          }), "insufficiency": insufficiency,
      ])
    case .librarySummary: return .object(["summary": grounded(), "insufficiency": insufficiency])
    }
  }
  private func envelope(_ wire: WireProviderRequest, _ result: RequestValue) -> RequestValue {
    .object([
      "schemaVersion": .int(wire.schemaVersion), "requestID": .string(wire.requestID),
      "operation": .string(wire.operation.rawValue), "result": result,
    ])
  }
  /// Vector contexts are recovered solely from the common authority's public fixtures.
  private func vectorContext(_ api: ProviderRequest, wire: WireProviderRequest) throws
    -> TrustedRequestContext
  {
    var source = sources(wire.operation)
    let input = wire.input
    var corpus: [RequestSentence] = []
    var ranked: [Int] = []
    if wire.operation != .connectionTest {
      corpus = wire.evidenceItems.map { RequestSentence(anchor: $0.anchor, quote: $0.quote) }
      ranked = corpus.map { $0.anchor.sentenceID }
    }
    var turns: [RequestTurn] = []
    switch wire.typedInput {
    case .connectionTest: break
    case .translation(let language, _):
      source = .translation(targetLanguage: language, sentenceIDs: [])
    case .paperChat(let session, let question, let prior, _):
      source = .paperChat(sessionID: session, question: question)
      turns = prior
    case .brief(let snapshot, _): source = .brief(snapshot)
    case .librarySummary(let language, _): source = .librarySummary(outputLanguage: language)
    }
    let bundle = input["evidence"]
    let paper =
      wire.operation == .connectionTest
      ? nil
      : RequestPaperIdentity(
        paperID: bundle["paperID"].string, paperGeneration: bundle["paperGeneration"].integer!,
        pdfSHA256: bundle["pdfSHA256"].string,
        extractionRevision: bundle["extractionRevision"].string)
    let ctx = try TrustedRequestContext(
      authority: api, sources: source, identity: paper, sentences: corpus, rankedCandidates: ranked,
      turns: turns)
    if wire.operation == .translation {
      return try ctx.forTranslationBatch(
        language: input["targetLanguage"].string, sentenceIDs: ranked)
    }
    return ctx
  }

  func testEveryCommonConformanceVector() throws {
    let api = try ProviderRequest()
    let vectors = api.contract["conformance"]
    for vector in vectors["canonical"].array {
      XCTAssertEqual(try bytes(vector["value"]), Data(vector["utf8"].string.utf8))
    }
    for vector in vectors["rendered"].array {
      let wire = try api.parseRequest(
        bytes(
          .object([
            "schemaVersion": api.contract["schemaVersion"], "requestID": .string(id),
            "operation": vector["operation"], "input": vector["input"],
          ])))
      let messages = try api.renderMessages(wire)
      XCTAssertEqual(
        messages.map {
          RequestValue.object(["role": .string($0.role), "content": .string($0.content)])
        }, vector["messages"].array)
      if let expected = vector["contentBytes"].integer {
        XCTAssertEqual(messages.reduce(0) { $0 + $1.content.utf8.count }, expected)
      }
      if let expected = vector["inputCharge"].integer {
        XCTAssertEqual(try api.inputCharge(wire), expected)
      }
    }
    for vector in vectors["requests"].array {
      if vector["accepted"].boolean == true {
        let wire = try api.parseRequest(bytes(vector["value"]))
        let ctx = try vectorContext(api, wire: wire)
        let authorized = try api.authorizeRequest(wire, context: ctx)
        XCTAssertEqual(try api.encodeRequest(authorized), try bytes(vector["value"]))
        XCTAssertEqual(try api.verifyAdapterCopy(authorized, raw: bytes(vector["value"])), wire)
      } else {
        rejects(vector["code"].string) { try api.parseRequest(bytes(vector["value"])) }
      }
    }
    for vector in vectors["results"].array {
      let wire = try api.parseRequest(bytes(vector["request"]))
      let authorized = try api.authorizeRequest(wire, context: vectorContext(api, wire: wire))
      if vector["accepted"].boolean == true {
        XCTAssertEqual(
          try api.validateResult(bytes(vector["value"]), request: authorized).value, vector["value"]
        )
      } else {
        rejects(vector["code"].string) {
          try api.validateResult(bytes(vector["value"]), request: authorized)
        }
      }
    }
    for raw in vectors["invalidJSON"].array {
      rejects("invalidJSON", "request") { try api.parseRequest(Data(raw.string.utf8)) }
    }
  }
  func testFiveOperationPublicPipelineAndTypedResults() throws {
    let api = try ProviderRequest()
    for op in RequestOperation.allCases {
      let auth = try request(api, operation: op, count: op == .translation ? 1 : 0)
      let encoded = try api.encodeRequest(auth)
      let parsed = try api.parseRequest(encoded)
      _ = parsed.typedInput
      XCTAssertEqual(try api.verifyAdapterCopy(auth, raw: encoded), parsed)
      XCTAssertEqual(try api.authorizeRequest(parsed, context: auth.context).wire, auth.wire)
      let result = member(auth.wire)
      let raw = op == .connectionTest ? Data("PAPERLENS_OK".utf8) : try bytes(result)
      let wrapped = try api.wrapModelResult(raw, request: auth)
      XCTAssertEqual(wrapped.value, envelope(auth.wire, result))
      XCTAssertEqual(try api.validateResult(bytes(wrapped.value), request: auth), wrapped)
      switch (op, wrapped.result) {
      case (.connectionTest, .connectionTest), (.translation, .translation),
        (.paperChat, .paperChat), (.brief, .brief), (.librarySummary, .librarySummary):
        break
      default: XCTFail("Wrong typed operation result")
      }
    }
  }
  func testStrictDecodeBoundsTypesUnicodeAndSafeErrors() throws {
    let api = try ProviderRequest()
    for raw in [
      "{} {}", "\u{FEFF}{}", "{\"a\":1,\"a\":2}", "{\"a\":1.0}", "{\"a\":1e0}", "{\"a\":NaN}",
      "{\"a\":Infinity}", "{\"a\":01}", "{\"a\":-}", "{\"a\":\"\\ud800\"}", "{\"a\":\"\\udc00\"}",
      "{\"a\":\"\\uPRIVATE\"}", "{\"a\":111111111111111111111}", "[true,]", "{\"x\":false,}",
    ] {
      rejects("invalidJSON", "request") { try api.parseRequest(Data(raw.utf8)) }
    }
    rejects("invalidJSON") { try api.parseRequest(Data([123, 34, 120, 34, 58, 34, 255, 34, 125])) }
    rejects("invalidJSON") {
      try api.parseRequest(
        Data(
          (String(repeating: "[", count: api.limit("depth") + 1) + "0"
            + String(repeating: "]", count: api.limit("depth") + 1)).utf8))
    }
    rejects("invalidJSON") {
      try api.parseRequest(
        bytes(.array(Array(repeating: .null, count: api.limit("arrayItems") + 1))))
    }
    var keys: [String: RequestValue] = [:]
    for n in 0...api.limit("objectKeys") { keys[String(n)] = .null }
    rejects("invalidJSON") { try api.parseRequest(bytes(.object(keys))) }
    rejects("inputLimit", "request") {
      try api.parseRequest(Data(repeating: 32, count: api.limit("innerBytes") + 1))
    }
    let auth = try request(api, operation: .connectionTest)
    rejects("invalidShape") {
      try api.parseRequest(
        bytes(replacing(auth.wire.value, path: ["schemaVersion"], with: .bool(true))))
    }
    rejects("versionMismatch") {
      try api.parseRequest(
        bytes(replacing(auth.wire.value, path: ["schemaVersion"], with: .int(2))))
    }
    rejects("unknownOperation") {
      try api.parseRequest(
        bytes(replacing(auth.wire.value, path: ["operation"], with: .string("PRIVATE"))))
    }
    XCTAssertEqual(try RequestValue(foundation: NSNumber(value: true)), .bool(true))
    XCTAssertEqual(try RequestValue(foundation: NSNumber(value: 1)), .int(1))
    rejects("invalidShape") { try RequestValue(foundation: NSNumber(value: 1.0)) }
    rejects("invalidShape") { try RequestValue(foundation: Double.nan) }
  }
  func testExactKeysAndNullAtEveryNestedObject() throws {
    let api = try ProviderRequest()
    func mutations(_ v: RequestValue) -> [RequestValue] {
      switch v {
      case .object(let object):
        var output: [RequestValue] = []
        var extra = object
        extra["PRIVATE"] = .null
        output.append(.object(extra))
        for (key, child) in object {
          var removed = object
          removed.removeValue(forKey: key)
          output.append(.object(removed))
          var nulled = object
          nulled[key] = .null
          output.append(.object(nulled))
          for mutation in mutations(child) {
            var changed = object
            changed[key] = mutation
            output.append(.object(changed))
          }
        }
        return output
      case .array(let array):
        return array.enumerated().flatMap { index, child in
          mutations(child).map { mutation in
            var changed = array
            changed[index] = mutation
            return .array(changed)
          }
        }
      default: return []
      }
    }
    for op in RequestOperation.allCases {
      let auth = try request(api, operation: op, count: 1)
      for mutation in mutations(auth.wire.value) {
        rejects { try api.parseRequest(bytes(mutation)) }
      }
      for mutation in mutations(envelope(auth.wire, member(auth.wire))) {
        rejects { try api.validateResult(bytes(mutation), request: auth) }
      }
    }
  }
  func testStructuralAndRenderedCeilingsAtEqualityAndOneByteOver() throws {
    let api = try ProviderRequest()
    let probe = try request(api, operation: .connectionTest)
    var raw = try api.encodeRequest(probe)
    raw.append(Data(repeating: 32, count: api.limit("innerBytes") - raw.count))
    _ = try api.parseRequest(raw)
    raw.append(32)
    rejects("inputLimit") { try api.parseRequest(raw) }
    let depth = api.limit("depth")
    rejects("invalidShape") {
      try api.parseRequest(
        Data(
          (String(repeating: "[", count: depth) + "0" + String(repeating: "]", count: depth)).utf8))
    }
    rejects("invalidShape") {
      try api.parseRequest(bytes(.array(Array(repeating: .null, count: api.limit("arrayItems")))))
    }
    let corpus = sentences(1, quote: String(repeating: "\u{0000}", count: 3000))
    let source = RequestSources.paperChat(sessionID: session, question: "x")
    let ctx = try context(api, source: source, corpus: corpus, ranked: [0])
    let initial = try api.buildRequest(sources: source, context: ctx, requestID: id)
    let ceiling = api.contract["operations"]["paperChat"]["inputCharge"].integer!
    let slack = ceiling - (try api.inputCharge(initial.wire))
    XCTAssertGreaterThanOrEqual(slack, 0)
    XCTAssertLessThan(slack, api.limit("inputStringBytes"))
    let exactSource = RequestSources.paperChat(
      sessionID: session, question: "x" + String(repeating: "x", count: max(0, slack)))
    let exactContext = try context(api, source: exactSource, corpus: corpus, ranked: [0])
    let exact = try api.buildRequest(sources: exactSource, context: exactContext, requestID: id)
    XCTAssertEqual(exact.wire.evidenceItems.count, 1)
    XCTAssertEqual(try api.inputCharge(exact.wire), ceiling)
    rejects("inputLimit") {
      try api.parseRequest(
        bytes(
          replacing(
            exact.wire.value, path: ["input", "question"],
            with: .string(exact.wire.input["question"].string + "x"))))
    }
  }
  func testLanguageIdentityNumericAndMultibyteFieldBounds() throws {
    let api = try ProviderRequest()
    let auth = try request(api, operation: .paperChat, count: 1)
    for language in ["en", "eng", "zh-Hans-CN", "es-419"] {
      _ = try context(api, source: .librarySummary(outputLanguage: language))
    }
    for language in ["EN", "e", "english", "en-us", "zh-hans", "en_US", "", "en-1234"] {
      rejects("sourceMismatch") {
        try context(api, source: .librarySummary(outputLanguage: language))
      }
    }
    for uuid in [
      "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA", "00000000-0000-1000-8000-000000000001",
      "00000000-0000-4000-7000-000000000001", "PRIVATE",
    ] {
      rejects("invalidShape") {
        try api.parseRequest(
          bytes(replacing(auth.wire.value, path: ["requestID"], with: .string(uuid))))
      }
    }
    for generation in [1, Int.max] {
      _ = try api.parseRequest(
        bytes(
          replacing(
            auth.wire.value, path: ["input", "evidence", "paperGeneration"], with: .int(generation))
        ))
    }
    for generation in [
      RequestValue.bool(true), .string("1"), .int(0), .integer("9223372036854775808"),
    ] {
      rejects("invalidShape") {
        try api.parseRequest(
          bytes(
            replacing(
              auth.wire.value, path: ["input", "evidence", "paperGeneration"], with: generation)))
      }
    }
    let item = auth.wire.input["evidence"]["items"].array[0]
    for field in ["pageIndex", "sentenceID"] {
      let cap = api.contract["definitions"][field]["maximum"].integer!
      let validItem = replacing(item, path: ["anchor", field], with: .int(cap))
      _ = try api.parseRequest(
        bytes(
          replacing(
            auth.wire.value, path: ["input", "evidence", "items"], with: .array([validItem]))))
      for value in [RequestValue.int(cap + 1), .int(-1), .bool(false), .string("1")] {
        let invalidItem = replacing(item, path: ["anchor", field], with: value)
        rejects("invalidShape") {
          try api.parseRequest(
            bytes(
              replacing(
                auth.wire.value, path: ["input", "evidence", "items"], with: .array([invalidItem])))
          )
        }
      }
    }
    let cap = api.limit("inputStringBytes")
    let atCap = String(repeating: "é", count: cap / 2)
    _ = try context(api, source: .paperChat(sessionID: session, question: atCap))
    rejects("sourceMismatch") {
      try context(api, source: .paperChat(sessionID: session, question: atCap + "x"))
    }
  }
  func testTemplateSnapshotAggregateCeilingAndSectionIdentity() throws {
    let api = try ProviderRequest()
    let original = snapshot()
    func template(_ sections: [RequestSection]) -> RequestTemplateSnapshot {
      RequestTemplateSnapshot(
        snapshotID: original.snapshotID, templateVersionID: original.templateVersionID,
        sections: sections, outputLanguage: "en", policyVersion: 1)
    }
    let fields = api.contract["definitions"]["section"]["fields"]
    let heading = String(repeating: "é", count: fields["heading"]["maxBytes"].integer! / 2)
    let prompt = String(repeating: "é", count: fields["prompt"]["maxBytes"].integer! / 2)
    _ = try context(
      api,
      source: .brief(
        template([
          RequestSection(
            sectionID: original.sections[0].sectionID, heading: heading, prompt: prompt)
        ])))
    for section in [
      RequestSection(
        sectionID: original.sections[0].sectionID, heading: heading + "x", prompt: prompt),
      RequestSection(
        sectionID: original.sections[0].sectionID, heading: heading, prompt: prompt + "x"),
    ] {
      rejects("sourceMismatch") { try context(api, source: .brief(template([section]))) }
    }
    rejects("invalidTemplate") {
      try context(api, source: .brief(template([original.sections[0], original.sections[0]])))
    }
    var sections = (0..<8).map {
      RequestSection(
        sectionID: String(format: "00000000-0000-4000-8000-%012d", $0 + 100), heading: "h",
        prompt: "p")
    }
    var remaining =
      api.limit("snapshotBytes")
      - (try bytes(RequestSources.brief(template(sections)).value["templateSnapshot"]).count)
    for index in sections.indices {
      let section = sections[index]
      let growth = min(remaining, fields["prompt"]["maxBytes"].integer! - section.prompt.utf8.count)
      sections[index] = RequestSection(
        sectionID: section.sectionID, heading: section.heading,
        prompt: section.prompt + String(repeating: "x", count: growth))
      remaining -= growth
    }
    XCTAssertEqual(remaining, 0)
    XCTAssertEqual(
      try bytes(RequestSources.brief(template(sections)).value["templateSnapshot"]).count,
      api.limit("snapshotBytes"))
    _ = try context(api, source: .brief(template(sections)))
    let last = try XCTUnwrap(sections.last)
    sections[sections.count - 1] = RequestSection(
      sectionID: last.sectionID, heading: last.heading, prompt: last.prompt + "x")
    rejects("invalidTemplate") { try context(api, source: .brief(template(sections))) }
  }
  func testImmutableCallerInputsAndByteExactProvenance() throws {
    let api = try ProviderRequest()
    var corpus = sentences(1, quote: "é PRIVATE /tmp/paper https://example.org")
    let source = RequestSources.librarySummary(outputLanguage: "en")
    let ctx = try context(api, source: source, corpus: corpus, ranked: [0])
    let auth = try api.buildRequest(sources: source, context: ctx, requestID: id)
    let frozen = try api.encodeRequest(auth)
    corpus[0] = RequestSentence(
      anchor: RequestAnchor(pageIndex: 0, sentenceID: 0), quote: "replacement")
    var copiedInput = auth.wire.input.object
    copiedInput["outputLanguage"] = .string("ko")
    XCTAssertEqual(try api.encodeRequest(auth), frozen)
    XCTAssertEqual(ctx.sentences[0].quote, "é PRIVATE /tmp/paper https://example.org")
    var bundle = auth.wire.input["evidence"].object
    var item = bundle["items"]!.array[0].object
    item["quote"] = .string("e\u{0301} PRIVATE /tmp/paper https://example.org")
    bundle["items"] = .array([.object(item)])
    let replacement = replacing(
      auth.wire.value, path: ["input", "evidence"], with: .object(bundle))
    let changed = try api.parseRequest(bytes(replacement))
    // Swift String equality normalizes; authorization must compare canonical UTF8 bytes instead.
    rejects("sourceMismatch") { try api.authorizeRequest(changed, context: ctx) }
    rejects("sourceMismatch") { try api.verifyAdapterCopy(auth, raw: bytes(replacement)) }
    let stale = try api.parseRequest(
      bytes(
        replacing(auth.wire.value, path: ["input", "evidence", "paperGeneration"], with: .int(2))))
    rejects("staleRevision", "evidence") { try api.authorizeRequest(stale, context: ctx) }
    let other = try context(
      api, source: source, corpus: sentences(1, quote: "replacement"), ranked: [0])
    rejects("sourceMismatch") { try api.authorizeRequest(auth.wire, context: other) }
    let otherAuthority = try ProviderRequest()
    rejects("sourceMismatch") { try otherAuthority.encodeRequest(auth) }
    rejects("sourceMismatch") {
      try otherAuthority.wrapModelResult(bytes(member(auth.wire)), request: auth)
    }
  }
  func testCorpusOrderRankingHistoryAndLanguageProvenance() throws {
    let api = try ProviderRequest()
    let source = sources(.paperChat)
    rejects("sourceMismatch", "evidence") {
      try context(
        api, source: source,
        corpus: [RequestSentence(anchor: RequestAnchor(pageIndex: 0, sentenceID: 1), quote: "x")])
    }
    rejects("sourceMismatch", "evidence") {
      try context(api, source: source, corpus: sentences(1), ranked: [0, 0])
    }
    rejects("sourceMismatch", "evidence") {
      try context(api, source: source, corpus: sentences(1), ranked: [1])
    }
    let user = RequestTurn(turnID: id, role: "user", text: "PRIVATE history")
    let assistant = RequestTurn(turnID: revision, role: "assistant", text: "previous answer")
    rejects("invalidHistory", "history") { try context(api, source: source, turns: [user]) }
    rejects("invalidHistory", "history") {
      try context(api, source: source, turns: [assistant, user])
    }
    rejects("invalidHistory", "history") {
      try context(
        api, source: source, turns: [user, RequestTurn(turnID: id, role: "assistant", text: "x")])
    }
    rejects("sourceMismatch", "history") {
      try context(api, source: sources(.librarySummary), turns: [user, assistant])
    }
    let ctx = try context(api, source: source, turns: [user, assistant])
    let auth = try api.buildRequest(sources: source, context: ctx, requestID: id)
    let sessionChanged = try api.parseRequest(
      bytes(replacing(auth.wire.value, path: ["input", "sessionID"], with: .string(revision))))
    rejects("sourceMismatch") { try api.authorizeRequest(sessionChanged, context: ctx) }
    let removedHistory = try api.parseRequest(
      bytes(replacing(auth.wire.value, path: ["input", "priorTurns"], with: .array([]))))
    rejects("sourceMismatch") { try api.authorizeRequest(removedHistory, context: ctx) }
    rejects("sourceMismatch") {
      try api.buildRequest(
        sources: .paperChat(sessionID: session, question: "changed"), context: ctx, requestID: id)
    }
    let translation = try context(api, source: sources(.translation), corpus: sentences(1))
    rejects("sourceMismatch") {
      try api.planTranslationBatches(page: 0, language: "en", context: translation)
    }
    rejects("sourceMismatch") {
      try translation.forTranslationBatch(language: "en", sentenceIDs: [0])
    }
    let brief = try request(api, operation: .brief)
    let changedSnapshot = replacing(
      brief.wire.value, path: ["input", "templateSnapshot", "generationInputs", "outputLanguage"],
      with: .string("ko"))
    rejects("sourceMismatch") {
      try api.authorizeRequest(api.parseRequest(bytes(changedSnapshot)), context: brief.context)
    }
  }
  func testBOMInsideJSONStringPreservedAndRawBOMRejected() throws {
    let api = try ProviderRequest()
    let text = "\u{FEFF}{}é"
    let source = RequestSources.paperChat(sessionID: session, question: text)
    let ctx = try context(api, source: source, corpus: sentences(1, quote: text), ranked: [0])
    let auth = try api.buildRequest(sources: source, context: ctx, requestID: id)
    let encoded = try api.encodeRequest(auth)
    let parsed = try api.parseRequest(encoded)
    XCTAssertEqual(Array(parsed.input["question"].string.utf8), Array(text.utf8))
    XCTAssertEqual(Array(parsed.evidenceItems[0].quote.utf8), Array(text.utf8))
    let escaped = String(decoding: encoded, as: UTF8.self).replacingOccurrences(
      of: "\u{FEFF}", with: "\\ufeff")
    XCTAssertEqual(try api.verifyAdapterCopy(auth, raw: Data(escaped.utf8)), parsed)
    rejects("invalidJSON", "request") { try api.parseRequest(Data("\u{FEFF}{}".utf8)) }
    rejects("invalidJSON", "request") { try api.parseRequest(Data("\u{FEFF}".utf8) + encoded) }
    let reply = RequestValue.object([
      "segments": .array([grounded(text)]),
      "insufficiency": auth.wire.input["evidence"]["insufficiency"],
    ])
    let result = try api.wrapModelResult(bytes(reply), request: auth)
    XCTAssertEqual(
      Array(result.value["result"]["segments"].array[0]["text"].string.utf8), Array(text.utf8))
  }
  func testNormalizationCannotTransferQuoteQuestionHistoryOrTemplate() throws {
    let api = try ProviderRequest()
    let composed = "é"
    let decomposed = "e\u{0301}"
    XCTAssertNotEqual(RequestValue.string(composed), .string(decomposed))
    XCTAssertNotEqual(RequestValue.array([.string(composed)]), .array([.string(decomposed)]))
    XCTAssertNotEqual(RequestValue.object([composed: .int(1)]), .object([decomposed: .int(1)]))
    let corpus = sentences(1, quote: composed)
    let turns = [
      RequestTurn(turnID: id, role: "user", text: composed),
      RequestTurn(turnID: revision, role: "assistant", text: composed),
    ]
    let source = RequestSources.paperChat(sessionID: session, question: composed)
    let ctx = try context(api, source: source, corpus: corpus, ranked: [0], turns: turns)
    let auth = try api.buildRequest(sources: source, context: ctx, requestID: id)
    var alteredQuote = auth.wire.input["evidence"]["items"].array[0].object
    alteredQuote["quote"] = .string(decomposed)
    var alteredTurn = auth.wire.input["priorTurns"].array[0].object
    alteredTurn["text"] = .string(decomposed)
    let variants = [
      replacing(auth.wire.value, path: ["input", "question"], with: .string(decomposed)),
      replacing(
        auth.wire.value, path: ["input", "evidence", "items"], with: .array([.object(alteredQuote)])
      ),
      replacing(
        auth.wire.value, path: ["input", "priorTurns"],
        with: .array([.object(alteredTurn), auth.wire.input["priorTurns"].array[1]])),
    ]
    for value in variants {
      let wire = try api.parseRequest(bytes(value))
      XCTAssertNotEqual(wire, auth.wire)
      XCTAssertNotEqual(wire.typedInput, auth.wire.typedInput)
      rejects("sourceMismatch") { try api.authorizeRequest(wire, context: ctx) }
      rejects("sourceMismatch") { try api.verifyAdapterCopy(auth, raw: bytes(value)) }
      rejects("sourceMismatch") { try api.encodeRequest(api.authorizeRequest(wire, context: ctx)) }
      rejects("sourceMismatch") {
        try api.wrapModelResult(
          bytes(member(auth.wire)), request: api.authorizeRequest(wire, context: ctx))
      }
    }
    rejects("sourceMismatch") {
      try api.buildRequest(
        sources: .paperChat(sessionID: session, question: decomposed), context: ctx, requestID: id)
    }
    let foreign = try context(
      api, source: source, corpus: sentences(1, quote: decomposed), ranked: [0], turns: turns)
    rejects("sourceMismatch") { try api.authorizeRequest(auth.wire, context: foreign) }
    let original = snapshot()
    func template(_ heading: String, _ prompt: String) -> RequestTemplateSnapshot {
      RequestTemplateSnapshot(
        snapshotID: original.snapshotID, templateVersionID: original.templateVersionID,
        sections: [
          RequestSection(
            sectionID: original.sections[0].sectionID, heading: heading, prompt: prompt)
        ], outputLanguage: "en", policyVersion: 1)
    }
    let briefSource = RequestSources.brief(template(composed, composed))
    let briefContext = try context(api, source: briefSource)
    let brief = try api.buildRequest(sources: briefSource, context: briefContext, requestID: id)
    for changed in [template(decomposed, composed), template(composed, decomposed)] {
      XCTAssertNotEqual(briefSource, .brief(changed))
      rejects("sourceMismatch") {
        try api.buildRequest(sources: .brief(changed), context: briefContext, requestID: id)
      }
      let value = replacing(
        brief.wire.value, path: ["input", "templateSnapshot"],
        with: RequestSources.brief(changed).value["templateSnapshot"])
      rejects("sourceMismatch") {
        try api.authorizeRequest(api.parseRequest(bytes(value)), context: briefContext)
      }
      rejects("sourceMismatch") { try api.verifyAdapterCopy(brief, raw: bytes(value)) }
      rejects("sourceMismatch") {
        try api.encodeRequest(
          api.authorizeRequest(api.parseRequest(bytes(value)), context: briefContext))
      }
      rejects("sourceMismatch") {
        try api.wrapModelResult(
          bytes(member(brief.wire)),
          request: api.authorizeRequest(api.parseRequest(bytes(value)), context: briefContext))
      }
    }
    let encoded = try api.encodeRequest(auth)
    XCTAssertEqual(encoded, try bytes(auth.wire.value))
    let first = try api.wrapModelResult(
      bytes(
        .object([
          "segments": .array([grounded(composed)]),
          "insufficiency": auth.wire.input["evidence"]["insufficiency"],
        ])), request: auth)
    let second = try api.wrapModelResult(
      bytes(
        .object([
          "segments": .array([grounded(decomposed)]),
          "insufficiency": auth.wire.input["evidence"]["insufficiency"],
        ])), request: auth)
    XCTAssertNotEqual(first, second)
    XCTAssertNotEqual(first.result, second.result)
    XCTAssertEqual(try api.validateResult(bytes(first.value), request: auth), first)
    // Closed schema keys must not silently treat non-ASCII lookalikes as allowed fields.
    let unknown = replacing(auth.wire.value, path: ["input", composed], with: .string("x"))
    rejects("invalidShape") { try api.parseRequest(bytes(unknown)) }
    rejects("invalidJSON") { try api.parseRequest(Data("{\"é\":1,\"e\\u0301\":2}".utf8)) }
  }
  func testRankedPrefixDoesNotSkipOverCapSentence() throws {
    let api = try ProviderRequest()
    let source = sources(.librarySummary)
    let oversized = String(
      repeating: "x",
      count: api.contract["definitions"]["item"]["fields"]["quote"]["maxBytes"].integer! + 1)
    var corpus = sentences(2)
    corpus[0] = RequestSentence(anchor: corpus[0].anchor, quote: oversized)
    let ctx = try context(api, source: source, corpus: corpus, ranked: [0, 1])
    let auth = try api.buildRequest(sources: source, context: ctx, requestID: id)
    XCTAssertTrue(auth.wire.evidenceItems.isEmpty)
    XCTAssertEqual(auth.wire.input["evidence"]["selection"]["candidateCount"], .int(2))
    XCTAssertEqual(auth.wire.input["evidence"]["insufficiency"], .string("budgetLimited"))
    let more = try context(
      api, source: source, corpus: sentences(api.limit("summaryItems") + 1),
      ranked: Array(0...api.limit("summaryItems")))
    let summary = try api.buildRequest(sources: source, context: more, requestID: id)
    XCTAssertLessThanOrEqual(summary.wire.evidenceItems.count, api.limit("summaryItems"))
    XCTAssertEqual(
      summary.wire.evidenceItems.map(\.rank), Array(0..<summary.wire.evidenceItems.count))
    let trimmed = replacing(
      summary.wire.value, path: ["input", "evidence", "items"], with: .array([]))
    let trimmedWithState = replacing(
      trimmed, path: ["input", "evidence", "insufficiency"], with: .string("budgetLimited"))
    rejects("sourceMismatch") {
      try api.authorizeRequest(api.parseRequest(bytes(trimmedWithState)), context: more)
    }
  }
  func testHistoryPrunedBeforeLowestRankEvidence() throws {
    let api = try ProviderRequest()
    let source = sources(.paperChat)
    let history = (0..<api.limit("historyMessages")).map { n in
      RequestTurn(
        turnID: String(format: "00000000-0000-4000-8000-%012d", n + 10),
        role: n % 2 == 0 ? "user" : "assistant",
        text: String(
          repeating: "h",
          count: api.contract["definitions"]["turn"]["fields"]["text"]["maxBytes"].integer!))
    }
    let corpus = sentences(
      api.limit("evidenceItems"),
      quote: String(repeating: "q", count: api.limit("evidenceBytes") / api.limit("evidenceItems")))
    let ctx = try context(
      api, source: source, corpus: corpus, ranked: Array(corpus.indices), turns: history)
    let auth = try api.buildRequest(sources: source, context: ctx, requestID: id)
    XCTAssertEqual(auth.wire.evidenceItems.count, corpus.count)
    let retained = auth.wire.input["priorTurns"].array
    XCTAssertLessThan(retained.count, history.count)
    XCTAssertEqual(retained.count % 2, 0)
    XCTAssertEqual(
      retained.map { $0["turnID"].string }, history.suffix(retained.count).map(\.turnID))
    XCTAssertEqual(auth.wire.input["evidence"]["insufficiency"], .string("none"))
    XCTAssertLessThanOrEqual(
      try api.inputCharge(auth.wire),
      api.contract["operations"]["paperChat"]["inputCharge"].integer!)
  }
  func testGreedyComplete33SentencePlanAndUnderfilledRejection() throws {
    let api = try ProviderRequest()
    let source = sources(.translation)
    let total = api.limit("evidenceItems") + 1
    let ctx = try context(api, source: source, corpus: sentences(total, quote: "x"))
    let plan = try api.planTranslationBatches(page: 0, language: "ko", context: ctx)
    XCTAssertEqual(plan.flatMap { $0 }, Array(0..<total))
    XCTAssertEqual(plan.first?.count, api.limit("evidenceItems"))
    XCTAssertEqual(plan.last, [total - 1])
    rejects("sourceMismatch", "evidence") {
      try ctx.forTranslationBatch(language: "ko", sentenceIDs: [0])
    }
    let rogue = try context(
      api, source: .translation(targetLanguage: "ko", sentenceIDs: [0]),
      corpus: sentences(total, quote: "x"), expected: [0])
    rejects("sourceMismatch", "evidence") {
      try api.buildRequest(sources: rogue.sources, context: rogue, requestID: id)
    }
    var copiedPlan = plan
    copiedPlan[0].removeLast()
    XCTAssertEqual(try api.planTranslationBatches(page: 0, language: "ko", context: ctx), plan)
    for batch in plan {
      let bound = try ctx.forTranslationBatch(language: "ko", sentenceIDs: batch)
      XCTAssertEqual(try api.planTranslationBatches(page: 0, language: "ko", context: bound), plan)
      for _ in 0..<3 {
        let auth = try api.buildRequest(sources: bound.sources, context: bound, requestID: id)
        XCTAssertEqual(auth.wire.evidenceItems.map { $0.anchor.sentenceID }, batch)
        XCTAssertEqual(auth.wire.evidenceItems.map(\.rank), batch)
        _ = try api.encodeRequest(auth)
        _ = try api.wrapModelResult(bytes(member(auth.wire)), request: auth)
      }
    }
    // A separate owner cannot inject another corpus's cached plan through the API.
    let other = try context(
      api, source: source, corpus: sentences(total, quote: String(repeating: "x", count: 4096)))
    rejects("sourceMismatch", "evidence") {
      try other.forTranslationBatch(language: "ko", sentenceIDs: plan[0])
    }
    XCTAssertEqual(try api.planTranslationBatches(page: 1, language: "ko", context: ctx), [])
    rejects("invalidEvidence", "evidence") {
      try api.buildRequest(sources: source, context: ctx, requestID: id)
    }
  }
  func testOversizedLaterSentenceFailsWholePlanBeforeAnyDispatch() throws {
    let api = try ProviderRequest()
    let source = sources(.translation)
    var corpus = sentences(api.limit("evidenceItems") + 1, quote: "x")
    let index = corpus.count - 1
    corpus[index] = RequestSentence(
      anchor: corpus[index].anchor,
      quote: String(
        repeating: "x",
        count: api.contract["definitions"]["item"]["fields"]["quote"]["maxBytes"].integer! + 1))
    let ctx = try context(api, source: source, corpus: corpus)
    for _ in 0..<2 {
      rejects("inputLimit", "evidence") {
        try api.planTranslationBatches(page: 0, language: "ko", context: ctx)
      }
    }
    var dispatched = 0
    rejects("inputLimit", "evidence") {
      let plan = try api.planTranslationBatches(page: 0, language: "ko", context: ctx)
      for batch in plan {
        let bound = try ctx.forTranslationBatch(language: "ko", sentenceIDs: batch)
        _ = try api.encodeRequest(
          api.buildRequest(sources: bound.sources, context: bound, requestID: id))
        dispatched += 1
      }
    }
    XCTAssertEqual(dispatched, 0)
    rejects("inputLimit", "evidence") {
      try ctx.forTranslationBatch(language: "ko", sentenceIDs: [0])
    }
    let firstOnly = try context(
      api, source: .translation(targetLanguage: "ko", sentenceIDs: [0]), corpus: corpus,
      expected: [0])
    rejects("inputLimit", "evidence") {
      try api.buildRequest(sources: firstOnly.sources, context: firstOnly, requestID: id)
    }
  }
  func testEscapedRenderedBytesGreedyPlansAndPageIndexCopies() throws {
    let api = try ProviderRequest()
    let source = sources(.translation)
    let quoteCap = api.contract["definitions"]["item"]["fields"]["quote"]["maxBytes"].integer!
    let count = api.limit("evidenceItems") + 1
    var corpus = sentences(count, quote: String(repeating: "\"", count: quoteCap))
    corpus += (count..<(count * 2)).map {
      RequestSentence(anchor: RequestAnchor(pageIndex: 1, sentenceID: $0), quote: "second page")
    }
    let ctx = try context(api, source: source, corpus: corpus)
    let plan = try api.planTranslationBatches(page: 0, language: "ko", context: ctx)
    XCTAssertEqual(plan.flatMap { $0 }, Array(0..<count))
    // Raw quotes fit the evidence byte cap, but escaping consumes the rendered cap first.
    XCTAssertLessThan(try XCTUnwrap(plan.first).count, api.limit("evidenceBytes") / quoteCap)
    for batch in plan {
      let bound = try ctx.forTranslationBatch(language: "ko", sentenceIDs: batch)
      let auth = try api.buildRequest(sources: bound.sources, context: bound, requestID: id)
      XCTAssertLessThanOrEqual(
        try api.inputCharge(auth.wire),
        api.contract["operations"]["translation"]["inputCharge"].integer!)
      XCTAssertEqual(try api.verifyAdapterCopy(auth, raw: api.encodeRequest(auth)), auth.wire)
    }
    let later = try api.planTranslationBatches(page: 1, language: "ko", context: ctx)
    XCTAssertEqual(later.flatMap { $0 }, Array(count..<(count * 2)))
    let bound = try ctx.forTranslationBatch(language: "ko", sentenceIDs: XCTUnwrap(later.last))
    let auth = try api.buildRequest(sources: bound.sources, context: bound, requestID: id)
    XCTAssertEqual(auth.wire.evidenceItems.map(\.rank), [api.limit("evidenceItems")])
    // Each access is a value copy, never a writable corpus/plan cache alias.
    var copy = ctx.sentences
    copy.removeAll()
    var ranks = ctx.rankedCandidates
    ranks.append(0)
    var batches = later
    batches.removeAll()
    XCTAssertEqual(ctx.sentences.count, count * 2)
    XCTAssertTrue(ctx.rankedCandidates.isEmpty)
    XCTAssertEqual(try api.planTranslationBatches(page: 1, language: "ko", context: bound), later)
  }
  func testImmutableTemplateHistoryAndRejectBeforeSyntheticSink() throws {
    let api = try ProviderRequest()
    var sections = snapshot().sections
    let frozen = RequestTemplateSnapshot(
      snapshotID: snapshot().snapshotID, templateVersionID: snapshot().templateVersionID,
      sections: sections, outputLanguage: "en", policyVersion: 1)
    let brief = try context(api, source: .brief(frozen))
    sections.removeAll()
    let request = try api.buildRequest(sources: brief.sources, context: brief, requestID: id)
    XCTAssertEqual(request.wire.input["templateSnapshot"]["sections"].array.count, 1)
    var turns = [
      RequestTurn(turnID: id, role: "user", text: "original"),
      RequestTurn(turnID: revision, role: "assistant", text: "answer"),
    ]
    let chat = try context(api, source: sources(.paperChat), turns: turns)
    turns.removeAll()
    XCTAssertEqual(chat.turns.count, 2)
    var sinkCalls = 0
    func sink(_ authorized: AuthorizedProviderRequest) throws {
      _ = try api.encodeRequest(authorized)
      sinkCalls += 1
    }
    let auth = try api.buildRequest(sources: chat.sources, context: chat, requestID: id)
    let changed = try api.parseRequest(
      bytes(
        replacing(
          auth.wire.value, path: ["input", "question"], with: .string("PRIVATE replacement"))))
    rejects("sourceMismatch") { try sink(api.authorizeRequest(changed, context: chat)) }
    let foreign = try ProviderRequest()
    rejects("sourceMismatch") { try sink(foreign.authorizeRequest(auth.wire, context: chat)) }
    XCTAssertEqual(sinkCalls, 0)
    try sink(auth)
    XCTAssertEqual(sinkCalls, 1)
  }
  func testScannerLiteralEscapeCoverageAndLargeExactVersion() throws {
    let api = try ProviderRequest()
    let raw =
      "{\"schemaVersion\":1,\"requestID\":\"" + id
      + "\",\"operation\":\"connectionTest\",\"input\":{}}"
    XCTAssertEqual(try api.parseRequest(Data(raw.utf8)).operation, .connectionTest)
    for literal in ["true", "false", "null", "\"1\""] {
      rejects("invalidShape") {
        try api.parseRequest(
          Data(
            raw.replacingOccurrences(
              of: "\"schemaVersion\":1", with: "\"schemaVersion\":" + literal
            ).utf8))
      }
    }
    rejects("versionMismatch") {
      try api.parseRequest(
        Data(
          raw.replacingOccurrences(
            of: "\"schemaVersion\":1", with: "\"schemaVersion\":18446744073709551615"
          ).utf8))
    }
    for literal in ["True", "FALSE", "undefined", "+1", "0x1", "1e-1", "-Infinity", "truefalse"] {
      rejects("invalidJSON") {
        try api.parseRequest(
          Data(
            raw.replacingOccurrences(
              of: "\"schemaVersion\":1", with: "\"schemaVersion\":" + literal
            ).utf8))
      }
    }
    let auth = try request(api, operation: .paperChat)
    let question = "\"\\/\u{0008}\u{000C}\n\r\t\u{0000}é한𝄞"
    let value = replacing(auth.wire.value, path: ["input", "question"], with: .string(question))
    XCTAssertEqual(
      try api.parseRequest(bytes(value)).input["question"].string.utf8.map { $0 },
      Array(question.utf8))
    let encoded = String(decoding: try bytes(value), as: UTF8.self)
    let escaped = encoded.replacingOccurrences(of: "𝄞", with: "\\ud834\\udd1e")
    XCTAssertEqual(
      try api.parseRequest(Data(escaped.utf8)).input["question"].string.utf8.map { $0 },
      Array(question.utf8))
    let duplicate = raw.replacingOccurrences(
      of: "\"input\":{}", with: "\"input\":{},\"\\u0069nput\":{}")
    rejects("invalidJSON") { try api.parseRequest(Data(duplicate.utf8)) }
    for forged in ["01", "+1", " 1", "1.0"] { XCTAssertNil(RequestValue.integer(forged).integer) }
  }
  func testTranslationPageRanksAndResultsOrderAreRevisionWide() throws {
    let api = try ProviderRequest()
    var corpus = sentences(4, quote: "x")
    for n in 2..<4 {
      corpus[n] = RequestSentence(anchor: RequestAnchor(pageIndex: 1, sentenceID: n), quote: "x")
    }
    let ctx = try context(api, source: sources(.translation), corpus: corpus)
    let plan = try api.planTranslationBatches(page: 1, language: "ko", context: ctx)
    XCTAssertEqual(plan, [[2, 3]])
    let bound = try ctx.forTranslationBatch(language: "ko", sentenceIDs: [2, 3])
    let auth = try api.buildRequest(sources: bound.sources, context: bound, requestID: id)
    XCTAssertEqual(auth.wire.evidenceItems.map(\.rank), [0, 1])
    let good = member(auth.wire)
    let translated = good["translations"].array
    for bad in [Array(translated.reversed()), [translated[0]], [translated[0], translated[0]]] {
      rejects("invalidResult", "result") {
        try api.wrapModelResult(bytes(.object(["translations": .array(bad)])), request: auth)
      }
    }
    let wrongPage = replacing(translated[0], path: ["pageIndex"], with: .int(0))
    rejects("invalidResult") {
      try api.wrapModelResult(
        bytes(.object(["translations": .array([wrongPage, translated[1]])])), request: auth)
    }
  }
  func testCitationCorrelationInsufficiencyAndOutputBoundaries() throws {
    let api = try ProviderRequest()
    let auth = try request(api, operation: .paperChat, count: 2)
    let insufficiency = auth.wire.input["evidence"]["insufficiency"]
    func chat(_ segments: [RequestValue]) -> RequestValue {
      .object(["segments": .array(segments), "insufficiency": insufficiency])
    }
    _ = try api.wrapModelResult(
      bytes(chat([grounded("claim", kind: "paper", indices: [0, 1])])), request: auth)
    for segment in [
      grounded("PRIVATE", kind: "paper"), grounded("PRIVATE", kind: "paper", indices: [1, 0]),
      grounded("PRIVATE", kind: "paper", indices: [0, 0]),
      grounded("PRIVATE", kind: "paper", indices: [2]), grounded("PRIVATE", indices: [0]),
    ] {
      rejects("invalidResult", "result") {
        try api.wrapModelResult(bytes(chat([segment])), request: auth)
      }
    }
    let textCap = api.contract["operations"]["paperChat"]["outputBytes"].integer!
    _ = try api.wrapModelResult(
      bytes(chat([grounded(String(repeating: "x", count: textCap))])), request: auth)
    rejects("outputLimit", "result") {
      try api.wrapModelResult(
        bytes(chat([grounded(String(repeating: "x", count: textCap)), grounded("x")])),
        request: auth)
    }
    let envelope = envelope(auth.wire, chat([grounded()]))
    for (key, replacement) in [
      ("requestID", RequestValue.string(revision)), ("operation", .string("brief")),
      ("schemaVersion", .bool(true)),
    ] {
      rejects("invalidResult", "result") {
        try api.validateResult(
          bytes(replacing(envelope, path: [key], with: replacement)), request: auth)
      }
    }
    rejects("invalidResult") {
      try api.wrapModelResult(
        bytes(replacing(chat([grounded()]), path: ["insufficiency"], with: .string("noEvidence"))),
        request: auth)
    }
    let empty = try request(api, operation: .paperChat)
    rejects("invalidResult") {
      try api.wrapModelResult(
        bytes(
          .object([
            "segments": .array([grounded("claim", kind: "paper", indices: [0])]),
            "insufficiency": .string("noEvidence"),
          ])), request: empty)
    }
    rejects("outputLimit", "result") {
      try api.validateResult(Data(repeating: 32, count: api.limit("innerBytes") + 1), request: auth)
    }
    rejects("invalidJSON", "result") {
      try api.wrapModelResult(Data("{\"segments\":[],\"segments\":[]}".utf8), request: auth)
    }
  }
  func testBriefAllMissingSnapshotStatesAndSummarySingleLine() throws {
    let api = try ProviderRequest()
    let brief = try request(api, operation: .brief)
    _ = try api.wrapModelResult(bytes(member(brief.wire)), request: brief)
    let sectionID = brief.wire.input["templateSnapshot"]["sections"].array[0]["sectionID"]
    for section in [
      RequestValue.object([
        "sectionID": sectionID, "state": .string("ready"), "segments": .array([]),
      ]),
      .object([
        "sectionID": sectionID, "state": .string("missing-content"),
        "segments": .array([grounded()]),
      ]),
      .object([
        "sectionID": .string(revision), "state": .string("missing-content"), "segments": .array([]),
      ]),
    ] {
      rejects("invalidResult") {
        try api.wrapModelResult(
          bytes(.object(["sections": .array([section]), "insufficiency": .string("noEvidence")])),
          request: brief)
      }
    }
    let summary = try request(api, operation: .librarySummary)
    let outputCap = api.contract["operations"]["librarySummary"]["outputBytes"].integer!
    func result(_ text: String, kind: String = "insufficient") -> RequestValue {
      .object(["summary": grounded(text, kind: kind), "insufficiency": .string("noEvidence")])
    }
    _ = try api.wrapModelResult(
      bytes(result(String(repeating: "é", count: outputCap / 2))), request: summary)
    rejects("outputLimit") {
      try api.wrapModelResult(
        bytes(result(String(repeating: "é", count: outputCap / 2) + "x")), request: summary)
    }
    for separator in api.contract["policies"]["summaryLineSeparators"].array {
      rejects("invalidResult") {
        try api.wrapModelResult(bytes(result("a" + separator.string + "b")), request: summary)
      }
    }
    rejects("invalidResult") {
      try api.wrapModelResult(bytes(result("analysis", kind: "analysis")), request: summary)
    }
  }
  func testBriefSectionOrderAndAggregateSegmentCount() throws {
    let api = try ProviderRequest()
    let original = snapshot()
    let second = RequestSection(
      sectionID: revision, heading: "Results", prompt: "Describe results.")
    let template = RequestTemplateSnapshot(
      snapshotID: original.snapshotID, templateVersionID: original.templateVersionID,
      sections: original.sections + [second], outputLanguage: "en", policyVersion: 1)
    let ctx = try context(api, source: .brief(template))
    let auth = try api.buildRequest(sources: ctx.sources, context: ctx, requestID: id)
    let half = api.limit("arrayItems") / 2
    func section(_ id: String, count: Int) -> RequestValue {
      .object([
        "sectionID": .string(id), "state": .string("ready"),
        "segments": .array(Array(repeating: grounded("x"), count: count)),
      ])
    }
    let first = section(original.sections[0].sectionID, count: half)
    let last = section(second.sectionID, count: api.limit("arrayItems") - half)
    func result(_ sections: [RequestValue]) -> RequestValue {
      .object(["sections": .array(sections), "insufficiency": .string("noEvidence")])
    }
    _ = try api.wrapModelResult(bytes(result([first, last])), request: auth)
    rejects("invalidResult") {
      try api.wrapModelResult(bytes(result([last, first])), request: auth)
    }
    rejects("invalidResult") {
      try api.wrapModelResult(
        bytes(
          result([first, section(second.sectionID, count: api.limit("arrayItems") - half + 1)])),
        request: auth)
    }
  }
  func testProbeRawExactBytesNotTrimmedOrJSONCoerced() throws {
    let api = try ProviderRequest()
    let auth = try request(api, operation: .connectionTest)
    XCTAssertEqual(
      try api.wrapModelResult(Data("PAPERLENS_OK".utf8), request: auth).result,
      .connectionTest("PAPERLENS_OK"))
    for raw in [
      "PAPERLENS_OK ", " PAPERLENS_OK", "PAPERLENS_OK\n", "\"PAPERLENS_OK\"",
      "{\"text\":\"PAPERLENS_OK\"}", "paperlens_ok", "",
    ] {
      rejects("invalidResult", "result") { try api.wrapModelResult(Data(raw.utf8), request: auth) }
    }
    rejects("invalidResult") { try api.wrapModelResult(Data([255]), request: auth) }
  }
  func testProfileUsesOperationAuthorityAndDoesNotCertifyUnknownMappings() throws {
    let api = try ProviderRequest()
    for op in RequestOperation.allCases {
      let policy = api.contract["operations"][op.rawValue]
      let profile = RequestValue.object([
        "providerID": .string("supplied"), "modelID": .string("supplied"), "certified": .bool(true),
        "byteDecomposable": .bool(true), "noExpandingPreprocessing": .bool(true),
        "hiddenControlBytes": policy["controlReserve"],
        "contextTokens": .int(policy["inputCharge"].integer! + policy["outputTokens"].integer!),
        "maxOutputTokens": policy["outputTokens"], "toolsDisabled": .bool(true),
      ])
      XCTAssertEqual(try api.validateProviderProfile(profile, operation: op), profile)
      for key in ["certified", "byteDecomposable", "noExpandingPreprocessing", "toolsDisabled"] {
        for value in [RequestValue.bool(false), .int(1), .null] {
          rejects("unsupportedProvider", "provider") {
            try api.validateProviderProfile(
              replacing(profile, path: [key], with: value), operation: op)
          }
        }
      }
      for (key, value) in [
        ("hiddenControlBytes", policy["controlReserve"].integer! + 1),
        ("contextTokens", policy["inputCharge"].integer! + policy["outputTokens"].integer! - 1),
        ("maxOutputTokens", policy["outputTokens"].integer! - 1),
      ] {
        rejects("unsupportedProvider") {
          try api.validateProviderProfile(
            replacing(profile, path: [key], with: .int(value)), operation: op)
        }
      }
      for key in api.contract["policies"]["profileFields"].array.map(\.string) {
        rejects("unsupportedProvider") {
          try api.validateProviderProfile(replacing(profile, path: [key], with: nil), operation: op)
        }
      }
    }
  }
  func testImportURLArxivRedirectMIMEAndSignatureGates() throws {
    let api = try ProviderRequest()
    let approved = try api.validateImportURL("https://example.org/paper.pdf")
    XCTAssertEqual(
      try api.resolveRedirectURL(approved, location: "../other.pdf").value,
      "https://example.org/other.pdf")
    XCTAssertEqual(
      try api.resolveRedirectURL(approved, location: "//other.org/paper.pdf").value,
      "https://other.org/paper.pdf")
    for bad in [
      "http://example.org/x", "https://u:p@example.org/x", "https://@example.org/x", "https:///x",
      "https://example.org:/x", "https://example.org:0/x", "https://example.org:65536/x",
      "https://example.org/%", "https://example.org/%0", "https://example.org/%GG",
      "https://example.org/%0a", "https://example.org/%5C", "https://example.org/PRIVATE\\x",
      "https://example.org/ PRIVATE", "https://ex%61mple.org/x",
    ] { rejects("importRejected", "import") { try api.validateImportURL(bad) } }
    rejects("importRejected") { try api.validateImportURL(approved.value, sourceKind: "localPDF") }
    rejects("importRejected") {
      try api.validateImportURL(
        "https://example.org/" + String(repeating: "x", count: api.limit("urlBytes")))
    }
    for location in [
      "http://other.org/x", "https://u@other.org/x", "%", "%0a", " PRIVATE", "\\PRIVATE",
    ] { rejects("importRejected") { try api.resolveRedirectURL(approved, location: location) } }
    for identifier in ["2401.12345v2", "hep-th/9901001v1"] {
      XCTAssertEqual(
        try api.resolveArxivAbstractURL("https://www.arxiv.org/abs/" + identifier).value,
        "https://arxiv.org/pdf/" + identifier)
      _ = try api.validateImportURL(
        "https://arxiv.org/pdf/" + identifier + ".pdf", sourceKind: "arxivPDF")
    }
    for bad in [
      "https://example.org/abs/2401.12345", "https://arxiv.org:443/abs/2401.12345",
      "https://arxiv.org/abs/2413.12345", "https://arxiv.org/abs/2401.12345v0",
      "https://arxiv.org/abs/2401.12345?x=1", "https://arxiv.org/abs/2401.12345#x",
      "https://arxiv.org/abs/%32%3401.12345",
    ] { rejects("importRejected") { try api.resolveArxivAbstractURL(bad) } }
    XCTAssertTrue(
      try api.validatePDFSignature(
        prefix: Data("%PDF-1.7".utf8), mime: "Application/PDF; charset=binary",
        sourceKind: "httpsPDF"))
    XCTAssertTrue(
      try api.validatePDFSignature(prefix: Data("%PDF-".utf8), mime: nil, sourceKind: "localPDF"))
    for bad in [" %PDF-", "PRIVATE", "", "PK%PDF-"] {
      rejects("importRejected") {
        try api.validatePDFSignature(
          prefix: Data(bad.utf8), mime: "application/pdf", sourceKind: "httpsPDF")
      }
    }
    rejects("importRejected") {
      try api.validatePDFSignature(
        prefix: Data("%PDF-".utf8), mime: "text/html", sourceKind: "httpsPDF")
    }
    rejects("importRejected") {
      try api.validatePDFSignature(
        prefix: Data(repeating: 0, count: api.limit("readBufferBytes") + 1), mime: nil,
        sourceKind: "localPDF")
    }
  }
  func testPDFSignatureMIMEUsesUTF8ByteBound() throws {
    let api = try ProviderRequest()
    let base = "application/pdf;"
    let cap = api.limit("headerBytes")
    let remaining = cap - base.utf8.count
    let mime = base + String(repeating: "𐐀", count: remaining / 4)
      + String(repeating: "x", count: remaining % 4)
    XCTAssertEqual(mime.utf8.count, cap)
    for kind in ["httpsPDF", "arxivPDF", "arxivAbstract"] {
      XCTAssertTrue(
        try api.validatePDFSignature(prefix: Data("%PDF-".utf8), mime: mime, sourceKind: kind))
      rejects("importRejected", "import") {
        try api.validatePDFSignature(
          prefix: Data("%PDF-".utf8), mime: mime + "x", sourceKind: kind)
      }
    }
  }
  func testHTTPHeadersRedirectAccountingAndTerminalAdmission() throws {
    let api = try ProviderRequest()
    let url = try api.validateImportURL("https://example.org/a.pdf")
    let budget = try RequestResourceBudget(authority: api, kind: "import")
    for status in api.contract["policies"]["redirectStatuses"].array {
      let result = try api.validateHTTPResponse(
        current: url, status: status.integer!, headers: [RequestHTTPHeader("Location", "/b.pdf")],
        prefix: Data(), budget: budget)
      XCTAssertEqual(result, .redirect(try api.validateImportURL("https://example.org/b.pdf")))
    }
    XCTAssertEqual(
      budget.values["redirects"], api.contract["policies"]["redirectStatuses"].array.count)
    try budget.add("bodyBytes", delta: 7)
    XCTAssertEqual(
      try api.validateHTTPResponse(
        current: url, status: 200, headers: [RequestHTTPHeader("Content-Type", "application/pdf")],
        prefix: Data("%PDF-1".utf8), budget: budget), .pdf(url))
    XCTAssertEqual(budget.values["bodyBytes"], 7)  // Prefix metadata is not a new body read.
    XCTAssertGreaterThan(budget.values["headerBytes"]!, 0)
    rejects("importRejected") {
      try api.validateHTTPResponse(
        current: url, status: 302, headers: [RequestHTTPHeader("Location", "/c.pdf")],
        prefix: Data(), budget: budget)
    }
    let badHeaders: [[RequestHTTPHeader]] = [
      [], [RequestHTTPHeader("Location", "/a"), RequestHTTPHeader("location", "/b")],
      [RequestHTTPHeader("Content-Type", "text/html")],
      [
        RequestHTTPHeader("Content-Type", "application/pdf"),
        RequestHTTPHeader("Content-Encoding", "gzip"),
      ],
      [
        RequestHTTPHeader("Content-Type", "application/pdf"),
        RequestHTTPHeader("content-type", "application/pdf"),
      ],
      [
        RequestHTTPHeader("Content-Type", "application/pdf"),
        RequestHTTPHeader("Content-Encoding", "identity"),
        RequestHTTPHeader("content-encoding", "identity"),
      ],
      [RequestHTTPHeader("PRIVATE\n", "x")], [RequestHTTPHeader("X-Header", "PRIVATE\r\nx")],
    ]
    for headers in badHeaders {
      let fresh = try RequestResourceBudget(authority: api, kind: "import")
      rejects("importRejected") {
        try api.validateHTTPResponse(
          current: url, status: 200, headers: headers, prefix: Data("%PDF-".utf8), budget: fresh)
      }
      XCTAssertEqual(fresh.values["headerCount"], headers.count)
    }
    let fresh = try RequestResourceBudget(authority: api, kind: "import")
    rejects("importRejected") {
      try api.validateHTTPResponse(
        current: url, status: 206, headers: [RequestHTTPHeader("Content-Type", "application/pdf")],
        prefix: Data("%PDF-".utf8), budget: fresh)
    }
    rejects("importRejected") {
      try api.validateHTTPResponse(
        current: url, status: 200, headers: [], prefix: Data(),
        budget: RequestResourceBudget(authority: api, kind: "parser"))
    }
  }
  func testEveryResourceMetricUnitsScopeModesBoundaryAndTerminalFailure() throws {
    let api = try ProviderRequest()
    for (kind, resource) in api.contract["resources"].object {
      for (metric, policy) in resource["metrics"].object {
        let code =
          kind == "parser" ? "parserLimit" : kind == "import" ? "importRejected" : "inputLimit"
        let field = kind == "rpc" ? "budget" : kind
        let cap = api.limit(policy["limit"].string)
        let cumulative = policy["mode"].string == "cumulative"
        let budget = try RequestResourceBudget(authority: api, kind: kind)
        XCTAssertEqual(budget.scope, resource["scope"].string)
        if cumulative {
          XCTAssertEqual(try budget.add(metric, delta: cap), cap)
          rejects(code, field) { try budget.add(metric, delta: 1) }
        } else {
          XCTAssertEqual(try budget.observe(metric, value: cap), cap)
          rejects(code, field) { try budget.observe(metric, value: cap + 1) }
        }
        XCTAssertEqual(budget.values[metric], cap)
        rejects(code, field) { try budget.observe(metric, value: 0) }
        let wrongMode = try RequestResourceBudget(authority: api, kind: kind)
        if cumulative {
          rejects(code, field) { try wrongMode.observe(metric, value: 0) }
        } else {
          rejects(code, field) { try wrongMode.add(metric, delta: 0) }
        }
        let negative = try RequestResourceBudget(authority: api, kind: kind)
        rejects(code, field) { try negative.add(metric, delta: -1) }
        if policy["mode"].string == "monotonic" {
          let clock = try RequestResourceBudget(authority: api, kind: kind)
          try clock.observe(metric, value: 1)
          rejects(code, field) { try clock.observe(metric, value: 0) }
        }
        if cumulative {
          let overflow = try RequestResourceBudget(authority: api, kind: kind)
          rejects(code, field) { try overflow.add(metric, delta: Int.max) }
        }
      }
      let unknown = try RequestResourceBudget(authority: api, kind: kind)
      rejects { try unknown.add("PRIVATE", delta: 1) }
    }
    rejects("invalidShape", "budget") { try RequestResourceBudget(authority: api, kind: "PRIVATE") }
  }
  func testProcessWidePoolsNonblockingAdmissionAndIdempotentRelease() throws {
    let api = try ProviderRequest()
    for (kind, policy) in api.contract["pools"].object {
      let first = try RequestResourcePool(authority: api, kind: kind)
      let second = try RequestResourcePool(authority: api, kind: kind)
      let cap = api.limit(policy["limit"].string)
      var leases: [RequestResourceLease] = []
      for _ in 0..<cap { leases.append(try XCTUnwrap(first.acquire())) }
      XCTAssertEqual(second.active, cap)
      // Saturated admission returns immediately rather than queueing an acquisition.
      for _ in 0..<20 { XCTAssertNil(second.acquire()) }
      let copied = leases[0]
      XCTAssertTrue(copied === leases[0])
      copied.close()
      leases[0].close()
      copied.close()
      XCTAssertEqual(first.active, cap - 1)
      let replacement = try XCTUnwrap(second.acquire())
      XCTAssertEqual(first.active, cap)
      replacement.close()
      for lease in leases { lease.close() }
      XCTAssertEqual(second.active, 0)
      do {
        let temporary = try XCTUnwrap(first.acquire())
        XCTAssertEqual(temporary.kind, kind)
      }
      XCTAssertEqual(first.active, 0)
    }
    rejects("invalidShape", "budget") { try RequestResourcePool(authority: api, kind: "PRIVATE") }
  }
  func testLoaderRejectsUnknownDefinitionCapabilitiesRatherThanFallback() throws {
    let api = try ProviderRequest()
    let changes: [([String], RequestValue?)] = [
      (["PRIVATE"], .int(1)), (["limits", "innerBytes"], .bool(true)),
      (["limits", "PRIVATE"], .int(1)),
      (["definitions", "sentenceID", "PRIVATE"], .int(1)),
      (["definitions", "sentenceID", "type"], .string("float")),
      (["definitions", "sentenceID", "maximum"], .int(-1)),
      (["definitions", "sentenceID", "rules"], .array([.string("PRIVATE")])),
      (["definitions", "sentenceID", "rules"], .bool(true)),
      (["definitions", "sentenceID", "rules"], .string("historyPairs")),
      (["definitions", "language", "pattern"], .int(1)),
      (["definitions", "language", "pattern"], .bool(false)),
      (["definitions", "identity", "ref"], .string("identity")),
      (["operations", "translation", "inputCharge"], .bool(true)),
      (["operations", "translation", "rules"], .array([.string("PRIVATE")])),
      (["operations", "translation", "rules"], .null),
      (["operations", "translation", "rules"], .array([.int(1)])),
      (["policies", "canonical", "ensureASCII"], .bool(true)),
      (["resources", "import", "metrics", "bodyBytes", "mode"], .string("PRIVATE")),
      (["pools", "parser", "scope"], .string("instance")), (["conformance", "canonical"], nil),
    ]
    for (path, replacement) in changes {
      rejects("contractDefinition", "request") {
        try ProviderRequest(
          contractData: bytes(replacing(api.contract, path: path, with: replacement)))
      }
    }
  }
  func testFixedV1AuthorityRejectsSchemaRuleAndResourceRewrites() throws {
    let api = try ProviderRequest()
    let rewrites: [([String], RequestValue?)] = [
      (["definitions", "item", "fields", "rank"], nil),
      (["definitions", "turns", "rules"], nil),
      (["definitions", "turns", "rules"], .array([])),
      (["definitions", "turns", "rules"], .array([.string("snapshotIdentity")])),
      (["definitions", "sentence", "rules"], .array([.string("historyPairs")])),
      (["resources", "import", "metrics", "bodyBytes", "mode"], .string("gauge")),
      (["resources", "import", "metrics", "bodyBytes", "unit"], .string("count")),
      (["resources", "import", "metrics", "bodyBytes", "limit"], .string("readBufferBytes")),
      (["resources", "import", "metrics", "bodyBytes"], nil),
      (
        ["resources", "import", "metrics", "extra"],
        api.contract["resources"]["import"]["metrics"]["bodyBytes"]
      ),
      (["pools", "parser", "limit"], .string("importConcurrency")),
      (["limits", "parserConcurrency"], .int(2)),
    ]
    for (path, value) in rewrites {
      rejects("contractDefinition", "request") {
        try ProviderRequest(contractData: bytes(replacing(api.contract, path: path, with: value)))
      }
    }
    var limits = api.contract["limits"].object
    limits["objectKeys"] = limits.removeValue(forKey: "objectKeys")
    rejects("contractDefinition", "request") {
      try ProviderRequest(
        contractData: bytes(replacing(api.contract, path: ["limits"], with: .object(limits))))
    }
    let compact = try bytes(api.contract)
    let reformatted = Data(" \n\t".utf8) + compact + Data("\n ".utf8)
    XCTAssertEqual(try ProviderRequest(contractData: reformatted).contract, api.contract)
    let members = try api.contract.object.keys.sorted().reversed().map { key in
      String(decoding: try bytes(.string(key)), as: UTF8.self) + ":"
        + String(decoding: try bytes(api.contract[key]), as: UTF8.self)
    }
    let differentlyOrdered = "{" + members.joined(separator: ",") + "}"
    XCTAssertEqual(
      try ProviderRequest(contractData: Data(differentlyOrdered.utf8)).contract, api.contract)
    let content = "K é e\u{0301}"
    let ctx = try context(
      api, source: sources(.paperChat), corpus: sentences(1, quote: content), ranked: [0])
    let auth = try api.buildRequest(sources: ctx.sources, context: ctx, requestID: id)
    XCTAssertEqual(
      Array(try api.parseRequest(api.encodeRequest(auth)).evidenceItems[0].quote.utf8),
      Array(content.utf8))
  }
  func testValidatedSourceKindCannotBeDowngradedAcrossRedirectOrHTTP() throws {
    let api = try ProviderRequest()
    let current = try api.validateImportURL(
      "https://arxiv.org/pdf/2401.12345", sourceKind: "arxivPDF")
    let foreign = "https://example.org/paper.pdf"
    for override in ["httpsPDF", "arxivAbstract", "", "PRIVATE"] {
      rejects("importRejected", "import") {
        try api.resolveRedirectURL(current, location: foreign, sourceKind: override)
      }
      let budget = try RequestResourceBudget(authority: api, kind: "import")
      rejects("importRejected", "import") {
        try api.validateHTTPResponse(
          current: current, status: 302, headers: [RequestHTTPHeader("Location", foreign)],
          prefix: Data(), budget: budget, sourceKind: override)
      }
      rejects("importRejected", "import") {
        try api.validateHTTPResponse(
          current: current, status: 200,
          headers: [RequestHTTPHeader("Content-Type", "application/pdf")],
          prefix: Data("%PDF-".utf8), budget: budget, sourceKind: override)
      }
      XCTAssertEqual(budget.values["redirects"], 0)
      XCTAssertEqual(budget.values["headerCount"], 0)
    }
    for override in [String?.none, "arxivPDF"] {
      rejects("importRejected", "import") {
        try api.resolveRedirectURL(current, location: foreign, sourceKind: override)
      }
      let approved = try api.resolveRedirectURL(
        current, location: "/pdf/2401.12345v2", sourceKind: override)
      XCTAssertEqual(approved.sourceKind, "arxivPDF")
      let budget = try RequestResourceBudget(authority: api, kind: "import")
      XCTAssertEqual(
        try api.validateHTTPResponse(
          current: current, status: 302,
          headers: [RequestHTTPHeader("Location", "/pdf/2401.12345v2")], prefix: Data(),
          budget: budget, sourceKind: override), .redirect(approved))
    }
    XCTAssertEqual(
      try api.resolveArxivAbstractURL("https://arxiv.org/abs/2401.12345").sourceKind, "arxivPDF")
  }
}
