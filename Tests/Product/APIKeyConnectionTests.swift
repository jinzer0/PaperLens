import Darwin
import Foundation
import XCTest
import ProviderRequest
@testable import PaperLensProduct

/// All credentials and provider replies in this suite are deterministic fixtures.
/// URLProtocol exercises the actual URLSession adapter but proves NO real authentication,
/// model enforcement, paid request, profile certification or product gate.
private final class NativeProbeURLProtocol: URLProtocol, @unchecked Sendable {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var handler: (@Sendable (URLRequest) throws -> (Int, Data))?
  static func install(_ value: @escaping @Sendable (URLRequest) throws -> (Int, Data)) {
    lock.lock()
    handler = value
    lock.unlock()
  }
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    Self.lock.lock()
    let callback = Self.handler
    Self.lock.unlock()
    do {
      guard let callback else { throw URLError(.badServerResponse) }
      let (status, data) = try callback(request)
      let response = HTTPURLResponse(url: request.url!, statusCode: status,
        httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    } catch { client?.urlProtocol(self, didFailWithError: error) }
  }
  override func stopLoading() {}
}

/// Stalling does not synthesize a terminal callback. Foundation must deliver task
/// completion and invalidation after the real URLSession task is cancelled.
private final class NativeGenerationURLProtocol: URLProtocol, @unchecked Sendable {
  struct Plan: Sendable {
    let start: @Sendable (NativeGenerationURLProtocol) -> Void
    let stop: @Sendable () -> Void
  }
  private static let lock = NSLock()
  nonisolated(unsafe) private static var plan: Plan?
  private let instanceLock = NSLock()
  private var stop: (@Sendable () -> Void)?

  static func install(_ plan: Plan) {
    lock.lock()
    self.plan = plan
    lock.unlock()
  }
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    Self.lock.lock()
    let plan = Self.plan
    Self.lock.unlock()
    guard let plan else {
      client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
      return
    }
    instanceLock.lock()
    stop = plan.stop
    instanceLock.unlock()
    plan.start(self)
  }
  override func stopLoading() {
    instanceLock.lock()
    let callback = stop
    stop = nil
    instanceLock.unlock()
    callback?()
  }
  func respond(_ data: Data, finish: Bool = true, status: Int = 200) {
    let response = HTTPURLResponse(url: request.url!, statusCode: status,
      httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    if !data.isEmpty { client?.urlProtocol(self, didLoad: data) }
    if finish { client?.urlProtocolDidFinishLoading(self) }
  }
}

private final class NativeHTTPObservation: @unchecked Sendable {
  let invalidated = XCTestExpectation(description: "Actual session invalidation callback")
  let releaseInvalidation = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var events: [NativeHTTPLifecycleEvent] = []
  private var returned = false
  private var gateExpired = false
  private let blockInvalidation: Bool

  init(blockInvalidation: Bool = false) { self.blockInvalidation = blockInvalidation }
  func receive(_ event: NativeHTTPLifecycleEvent) {
    lock.lock()
    events.append(event)
    lock.unlock()
    if event == .sessionInvalidated {
      invalidated.fulfill()
      if blockInvalidation, releaseInvalidation.wait(timeout: .now() + 5) == .timedOut {
        lock.lock()
        gateExpired = true
        lock.unlock()
      }
    }
  }
  func didReturn() {
    lock.lock()
    returned = true
    lock.unlock()
  }
  var snapshot: (events: [NativeHTTPLifecycleEvent], returned: Bool, gateExpired: Bool) {
    lock.lock()
    defer { lock.unlock() }
    return (events, returned, gateExpired)
  }
}

private func nativeHTTPFixtureBody(_ request: URLRequest) throws -> Data {
  if let body = request.httpBody { return body }
  let stream = try XCTUnwrap(request.httpBodyStream)
  stream.open()
  defer { stream.close() }
  var result = Data()
  var buffer = [UInt8](repeating: 0, count: 1024)
  while true {
    let count = buffer.withUnsafeMutableBufferPointer {
      stream.read($0.baseAddress!, maxLength: $0.count)
    }
    guard count >= 0, result.count + count <= 65_536 else { throw URLError(.badServerResponse) }
    if count == 0 { return result }
    result.append(contentsOf: buffer.prefix(count))
  }
}

@MainActor
private final class SelectorFixture: APIKeySelectorPersistence {
  var selected: APIKeySelection?
  var commits = 0
  var conflict = false
  var failCommit = false
  var commitAndThrow = false
  func currentSelection() throws -> APIKeySelection? { selected }
  func selectionMatchesConfiguration(_ configuration: NativeOpenAIConfiguration) throws -> Bool {
    selected != nil && configuration.model == "explicit-test-snapshot"
  }
  func compareAndSwap(expected: APIKeySelection?, slotID: UUID) throws -> APIKeySelection? {
    if failCommit { throw APIKeyConnectionError.persistenceFailure }
    guard !conflict, selected == expected else { return nil }
    let value = APIKeySelection(slotID: slotID, configGeneration: (selected?.configGeneration ?? 0) + 1)
    selected = value
    commits += 1
    if commitAndThrow { throw APIKeyConnectionError.persistenceFailure }
    return value
  }
}

@MainActor
private final class FixtureOnlyTransport: NativeConnectionTestTransport {
  func probe(key: String, configuration: NativeOpenAIConfiguration,
    request: AuthorizedProviderRequest, authority: ProviderRequest) async throws -> NativeProbeResponse {
    NativeProbeResponse(result: try authority.wrapModelResult(Data("PAPERLENS_OK".utf8), request: request),
      evidence: .deterministicFixture)
  }
}

@MainActor
private final class SuspendedProbe: NativeConnectionTestTransport {
  var pending: [(AuthorizedProviderRequest, ProviderRequest, CheckedContinuation<NativeProbeResponse, any Error>)] = []
  func probe(key: String, configuration: NativeOpenAIConfiguration,
    request: AuthorizedProviderRequest, authority: ProviderRequest) async throws -> NativeProbeResponse {
    try await withCheckedThrowingContinuation { continuation in
      pending.append((request, authority, continuation))
    }
  }
  func finish(_ index: Int, mismatchedID: Bool = false) throws {
    let (request, authority, continuation) = pending[index]
    var correlated = request
    if mismatchedID {
      let context = try TrustedRequestContext(authority: authority, sources: .connectionTest)
      correlated = try authority.buildRequest(sources: .connectionTest, context: context,
        requestID: UUID().uuidString.lowercased())
    }
    continuation.resume(returning: NativeProbeResponse(
      result: try authority.wrapModelResult(Data("PAPERLENS_OK".utf8), request: correlated),
      evidence: .authenticatedGenerationResponse))
  }
}

@MainActor
final class APIKeyConnectionTests: XCTestCase {
  private let model = "explicit-test-snapshot"

  private func ownedParent() throws -> URL {
    let alias = FileManager.default.temporaryDirectory
      .appendingPathComponent("paperlens-key-fixture-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: alias, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    guard let physicalPath = realpath(alias.path, nil) else {
      throw APIKeyConnectionError.unsafeStorage
    }
    defer { free(physicalPath) }
    return URL(fileURLWithPath: String(cString: physicalPath), isDirectory: true)
  }
  private func ownedStore() throws -> (URL, APIKeySlotStore) {
    let parent = try ownedParent()
    let store = try APIKeySlotStore(directory: parent.appendingPathComponent("slots", isDirectory: true))
    return (parent, store)
  }
  private func networkTransport() -> URLSessionOpenAIConnectionTransport {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [NativeProbeURLProtocol.self]
    return URLSessionOpenAIConnectionTransport(configuration: config)
  }
  private func reply(text: String = "PAPERLENS_OK", model: String = "explicit-test-snapshot", tokens: Int = 6) throws -> Data {
    try JSONSerialization.data(withJSONObject: [
      "id": "fixture-only-response", "object": "chat.completion", "model": model,
      "usage": ["completion_tokens": tokens],
      "choices": [["index": 0, "finish_reason": "stop",
        "message": ["role": "assistant", "content": text]]],
    ])
  }
  private func service(store: APIKeySlotStore, db: SelectorFixture?,
    transport: (any NativeConnectionTestTransport)? = nil) throws -> NativeAPIKeyConnection {
    NativeAPIKeyConnection(configuration: try NativeOpenAIConfiguration(model: model), slots: store,
      persistence: db, transport: transport ?? networkTransport(), authority: try ProviderRequest())
  }
  private func settled(_ connection: NativeAPIKeyConnection) async throws {
    for _ in 0..<400 {
      if connection.phase != .idle && connection.phase != .probing { return }
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTFail("Fixture connection did not settle")
  }
  private func started(_ transport: SuspendedProbe, count: Int) async throws {
    for _ in 0..<400 {
      if transport.pending.count == count { return }
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTFail("Fixture probe did not start")
  }

  private func summaryRequest(_ authority: ProviderRequest) throws -> AuthorizedProviderRequest {
    let source = RequestSources.librarySummary(outputLanguage: "en")
    let context = try TrustedRequestContext(authority: authority, sources: source,
      identity: .init(paperID: UUID().uuidString.lowercased(), paperGeneration: 1,
        pdfSHA256: String(repeating: "a", count: 64),
        extractionRevision: UUID().uuidString.lowercased()),
      sentences: [], rankedCandidates: [])
    return try authority.buildRequest(sources: source, context: context,
      requestID: UUID().uuidString.lowercased())
  }

  private func summaryReply(text: String = "No evidence.", tokens: Int = 512,
    responseModel: String = "explicit-test-snapshot") throws -> Data {
    let member = try JSONSerialization.data(withJSONObject: [
      "summary": ["text": text, "kind": "insufficient", "evidenceIndices": []] as [String: Any],
      "insufficiency": "noEvidence",
    ])
    return try reply(text: String(decoding: member, as: UTF8.self), model: responseModel, tokens: tokens)
  }

  private func startGeneration(_ request: AuthorizedProviderRequest, authority: ProviderRequest,
    observation: NativeHTTPObservation, deadlineCapMilliseconds: Int = 120_000
  ) throws -> Task<ValidatedProviderResult, any Error> {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [NativeGenerationURLProtocol.self]
    let transport = URLSessionOpenAIGenerationTransport(configuration: config,
      deadlineCapMilliseconds: deadlineCapMilliseconds, observe: { observation.receive($0) })
    let configuration = try NativeOpenAIConfiguration(model: model)
    return Task {
      defer { observation.didReturn() }
      return try await transport.execute(key: "fixture-generation-key", configuration: configuration,
        request: request, authority: authority)
    }
  }

  private func assertAwaitingActualInvalidationDrain(_ observation: NativeHTTPObservation) async {
    await fulfillment(of: [observation.invalidated], timeout: 3)
    await Task.yield()
    XCTAssertFalse(observation.snapshot.returned, "Invalidation callback is still held")
    XCTAssertEqual(observation.snapshot.events, [.taskCompleted, .sessionInvalidated])
    observation.releaseInvalidation.signal()
  }

  private func assertActualHTTPClosure(_ observation: NativeHTTPObservation,
    file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(observation.snapshot.events,
      [.taskCompleted, .sessionInvalidated, .consumerDrained], file: file, line: line)
    XCTAssertTrue(observation.snapshot.returned, file: file, line: line)
    XCTAssertFalse(observation.snapshot.gateExpired, file: file, line: line)
  }

  func testGenerationUsesCanonicalSummaryWireAndWaitsForActualSessionDrain() async throws {
    let authority = try ProviderRequest()
    let request = try summaryRequest(authority)
    let rendered = try authority.renderMessages(request.wire)
    let expected = try ProviderRequest.canonicalBytes(.object([
      "model": .string(model),
      "messages": .array(rendered.map { .object(["role": .string($0.role), "content": .string($0.content)]) }),
      "max_completion_tokens": .int(512), "stream": .bool(false), "n": .int(1), "store": .bool(false),
    ]))
    // The model's JSON object is larger than 2048 bytes; the summary text is exactly
    // the shared 2048-byte bound. The adapter must not impose a second raw-text policy.
    let text = String(repeating: "x", count: 2048)
    let body = try summaryReply(text: text)
    NativeGenerationURLProtocol.install(.init(start: { peer in
      do {
        XCTAssertEqual(peer.request.url, NativeOpenAIConfiguration.endpoint)
        XCTAssertEqual(peer.request.httpMethod, "POST")
        XCTAssertEqual(peer.request.timeoutInterval, 120)
        XCTAssertEqual(peer.request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-generation-key")
        XCTAssertEqual(peer.request.value(forHTTPHeaderField: "X-Client-Request-Id"), request.wire.requestID)
        XCTAssertEqual(try nativeHTTPFixtureBody(peer.request), expected)
        peer.respond(body)
      } catch { peer.client?.urlProtocol(peer, didFailWithError: error) }
    }, stop: {}))
    let observation = NativeHTTPObservation(blockInvalidation: true)
    defer { observation.releaseInvalidation.signal() }
    let execution = try startGeneration(request, authority: authority, observation: observation)
    await assertAwaitingActualInvalidationDrain(observation)
    let result = try await execution.value
    assertActualHTTPClosure(observation)
    XCTAssertEqual(result.requestID, request.wire.requestID)
    XCTAssertEqual(result.operation, .librarySummary)
    guard case .librarySummary(let summary, let insufficiency) = result.result else {
      return XCTFail("Expected shared typed summary")
    }
    XCTAssertEqual(summary.text, text)
    XCTAssertEqual(insufficiency, "noEvidence")
  }

  func testGenerationBodyLimitAtBoundaryAndOverflowDrainBeforeReturning() async throws {
    let authority = try ProviderRequest()
    let request = try summaryRequest(authority)
    let base = try summaryReply()
    for overflow in [false, true] {
      var body = base
      body.append(Data(repeating: 32, count: authority.limit("bodyBytes") - base.count + (overflow ? 1 : 0)))
      let response = body
      NativeGenerationURLProtocol.install(.init(start: { peer in
        // Overflow remains open: cancellation must really complete the task.
        peer.respond(response, finish: !overflow)
      }, stop: {}))
      let observation = NativeHTTPObservation(blockInvalidation: true)
      defer { observation.releaseInvalidation.signal() }
      let execution = try startGeneration(request, authority: authority, observation: observation)
      await assertAwaitingActualInvalidationDrain(observation)
      let result = await execution.result
      assertActualHTTPClosure(observation)
      if overflow {
        guard case .failure(let error) = result else { return XCTFail("Oversized body was accepted") }
        XCTAssertEqual(error as? APIKeyConnectionError, .invalidResponse)
      } else {
        XCTAssertEqual(try result.get().operation, .librarySummary)
      }
    }
  }

  func testGenerationRejectsWrongModelUsageAndSharedResultBoundsAfterClosure() async throws {
    let authority = try ProviderRequest()
    let request = try summaryRequest(authority)
    var bodies = [
      try summaryReply(responseModel: "different-snapshot"),
      try summaryReply(tokens: 513),
      try summaryReply(tokens: 0),
      try summaryReply(text: String(repeating: "x", count: 2049)),
      try summaryReply(text: "two\nlines"),
      try reply(text: "{\"summary\":{},\"summary\":{},\"insufficiency\":\"noEvidence\"}"),
    ]
    let valid = try XCTUnwrap(JSONSerialization.jsonObject(with: summaryReply()) as? [String: Any])
    for defect in ["choiceCount", "finish", "role", "refusal", "tool", "function", "usageType", "prompt", "total"] {
      var envelope = valid
      var choices = try XCTUnwrap(envelope["choices"] as? [[String: Any]])
      var message = try XCTUnwrap(choices[0]["message"] as? [String: Any])
      var usage = try XCTUnwrap(envelope["usage"] as? [String: Any])
      switch defect {
      case "choiceCount": choices.append(choices[0])
      case "finish": choices[0]["finish_reason"] = "length"
      case "role": message["role"] = "user"
      case "refusal": message["refusal"] = "fixture refusal"
      case "tool": message["tool_calls"] = [Any]()
      case "function": message["function_call"] = ["name": "fixture"]
      case "usageType": usage["completion_tokens"] = true
      case "prompt": usage["prompt_tokens"] = try authority.inputCharge(request.wire) + 1
      default:
        usage["prompt_tokens"] = 1
        usage["total_tokens"] = 1
      }
      choices[0]["message"] = message
      envelope["choices"] = choices
      envelope["usage"] = usage
      bodies.append(try JSONSerialization.data(withJSONObject: envelope))
    }
    for body in bodies {
      NativeGenerationURLProtocol.install(.init(start: { $0.respond(body) }, stop: {}))
      let observation = NativeHTTPObservation()
      let execution = try startGeneration(request, authority: authority, observation: observation)
      do {
        _ = try await execution.value
        XCTFail("Invalid generation response was accepted")
      } catch { XCTAssertEqual(error as? APIKeyConnectionError, .invalidResponse) }
      assertActualHTTPClosure(observation)
    }
  }

  func testGenerationCancellationWaitsForActualTaskAndInvalidationCallbacks() async throws {
    let authority = try ProviderRequest()
    let request = try summaryRequest(authority)
    let started = expectation(description: "Stalled HTTP request starts")
    let stopped = expectation(description: "Foundation stops the actual URLProtocol")
    NativeGenerationURLProtocol.install(.init(start: { peer in
      peer.respond(Data("{".utf8), finish: false)
      started.fulfill()
    }, stop: { stopped.fulfill() }))
    let observation = NativeHTTPObservation(blockInvalidation: true)
    defer { observation.releaseInvalidation.signal() }
    let execution = try startGeneration(request, authority: authority, observation: observation)
    await fulfillment(of: [started], timeout: 2)
    execution.cancel()
    await fulfillment(of: [stopped], timeout: 2)
    await assertAwaitingActualInvalidationDrain(observation)
    do {
      _ = try await execution.value
      XCTFail("Cancelled generation succeeded")
    } catch { XCTAssertEqual(error as? APIKeyConnectionError, .cancelled) }
    assertActualHTTPClosure(observation)
  }

  func testGenerationAbsoluteDeadlineStopsStallsWithoutAnotherResponseByte() async throws {
    for receivedHeaders in [false, true] {
      let authority = try ProviderRequest()
      let request = try summaryRequest(authority)
      let started = expectation(description: "Deadline fixture starts")
      let stopped = expectation(description: "Watchdog cancellation stops URLProtocol")
      NativeGenerationURLProtocol.install(.init(start: { peer in
        XCTAssertEqual(peer.request.timeoutInterval, 120, "Foundation timeout is not the shortened watchdog")
        if receivedHeaders { peer.respond(Data("{".utf8), finish: false) }
        started.fulfill()
      }, stop: { stopped.fulfill() }))
      let observation = NativeHTTPObservation(blockInvalidation: true)
      defer { observation.releaseInvalidation.signal() }
      let execution = try startGeneration(request, authority: authority, observation: observation,
        deadlineCapMilliseconds: 500)
      await fulfillment(of: [started, stopped], timeout: 3, enforceOrder: true)
      await assertAwaitingActualInvalidationDrain(observation)
      do {
        _ = try await execution.value
        XCTFail("Stalled generation succeeded")
      } catch { XCTAssertEqual(error as? APIKeyConnectionError, .deadline) }
      assertActualHTTPClosure(observation)
    }
  }

  func testGenerationWrongAuthorityFailsBeforeStartingHTTP() async throws {
    let authority = try ProviderRequest()
    let request = try summaryRequest(authority)
    NativeGenerationURLProtocol.install(.init(start: { peer in
      XCTFail("Unauthorized request reached HTTP")
      peer.respond(Data(), status: 401)
    }, stop: {}))
    let observation = NativeHTTPObservation()
    let execution = try startGeneration(request, authority: ProviderRequest(), observation: observation)
    do {
      _ = try await execution.value
      XCTFail("Request from another authority was accepted")
    } catch { XCTAssertEqual(error as? APIKeyConnectionError, .invalidConfiguration) }
    XCTAssertTrue(observation.snapshot.events.isEmpty)
  }

  private func independentLockStatus(_ directory: URL) async throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
    process.environment = [:]
    process.arguments = ["-e", """
      use Fcntl qw(O_RDONLY LOCK_EX LOCK_NB);
      use Errno qw(EWOULDBLOCK EAGAIN);
      sysopen(my $directory, $ARGV[0], O_RDONLY) or exit 3;
      exit 0 if flock($directory, LOCK_EX | LOCK_NB);
      exit(($! == EWOULDBLOCK || $! == EAGAIN) ? 2 : 4);
      """, directory.path]
    let exited = expectation(description: "Independent synthetic directory-lock process exits")
    process.terminationHandler = { _ in exited.fulfill() }
    try process.run()
    defer {
      if process.isRunning {
        kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
      }
    }
    await fulfillment(of: [exited], timeout: 5)
    guard !process.isRunning else { throw APIKeyConnectionError.cleanupBlocked }
    return process.terminationStatus
  }

  func testExclusiveDirectoryOwnerRejectsSecondOwnerAndReleasesOnTeardown() async throws {
    let parent = try ownedParent()
    defer { try? FileManager.default.removeItem(at: parent) }
    let directory = parent.appendingPathComponent("slots")
    var store: APIKeySlotStore? = try APIKeySlotStore(directory: directory)
    let id = try XCTUnwrap(store).create(key: "fixture-owned")
    XCTAssertThrowsError(try APIKeySlotStore(directory: directory)) {
      XCTAssertEqual($0 as? APIKeyConnectionError, .cleanupBlocked)
    }
    let held = try await independentLockStatus(directory)
    XCTAssertEqual(held, 2)
    XCTAssertEqual(try store?.read(id), "fixture-owned")
    try store?.validate()
    let afterReads = try await independentLockStatus(directory)
    XCTAssertEqual(afterReads, 2, "Closing ordinary read descriptors must not release flock")
    store = nil
    let released = try await independentLockStatus(directory)
    XCTAssertEqual(released, 0)
    // The independent process has exited; its lock must also have been released.
    let successor = try APIKeySlotStore(directory: directory)
    XCTAssertEqual(try successor.read(id), "fixture-owned")
  }

  func testUnreleasedLeaseRetainsDirectoryOwnershipAfterConnectionTeardown() throws {
    for explicitlyReleased in [false, true] {
      let parent = try ownedParent()
      defer { try? FileManager.default.removeItem(at: parent) }
      let directory = parent.appendingPathComponent("slots")
      var store: APIKeySlotStore? = try APIKeySlotStore(directory: directory)
      let selected = try XCTUnwrap(store).create(key: "fixture-selected")
      let db = SelectorFixture()
      db.selected = APIKeySelection(slotID: selected, configGeneration: 1)
      var connection: NativeAPIKeyConnection? = try service(
        store: XCTUnwrap(store), db: db, transport: FixtureOnlyTransport())
      connection?.restore()
      var lease: APIKeyConnectionLease? = try XCTUnwrap(connection).acquireLease()
      if explicitlyReleased {
        try XCTUnwrap(connection).releaseAfterTermination(XCTUnwrap(lease))
      }
      connection = nil
      store = nil
      if !explicitlyReleased {
        XCTAssertThrowsError(try APIKeySlotStore(directory: directory)) {
          XCTAssertEqual($0 as? APIKeyConnectionError, .cleanupBlocked)
        }
      }
      // An acknowledged stale token need not keep the lock; an outstanding token must.
      if explicitlyReleased {
        let successor = try APIKeySlotStore(directory: directory)
        XCTAssertEqual(try successor.read(selected), "fixture-selected")
        XCTAssertNotNil(lease)
      }
      lease = nil
      let successor = try APIKeySlotStore(directory: directory)
      XCTAssertEqual(try successor.read(selected), "fixture-selected")
    }
  }

  func testCancelledProbeRetainsDirectoryOwnershipUntilTransportActuallyReturns() async throws {
    let parent = try ownedParent()
    defer { try? FileManager.default.removeItem(at: parent) }
    let directory = parent.appendingPathComponent("slots")
    var store: APIKeySlotStore? = try APIKeySlotStore(directory: directory)
    let transport = SuspendedProbe()
    let db = SelectorFixture()
    var connection: NativeAPIKeyConnection? = try service(
      store: XCTUnwrap(store), db: db, transport: transport)
    weak var retained = connection
    connection?.connect(key: "fixture-pending")
    try await started(transport, count: 1)
    connection?.cancel()
    connection = nil
    store = nil
    XCTAssertNotNil(retained)
    XCTAssertThrowsError(try APIKeySlotStore(directory: directory))
    try transport.finish(0)
    for _ in 0..<400 {
      if retained == nil { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTAssertNil(retained)
    let successor = try APIKeySlotStore(directory: directory)
    XCTAssertTrue(try successor.validatedSlotIDs().isEmpty)
    XCTAssertEqual(db.commits, 0)
  }

  func testExclusiveStartupRemovesRecordedOrphansButPreservesDurableSelection() throws {
    let parent = try ownedParent()
    defer { try? FileManager.default.removeItem(at: parent) }
    let directory = parent.appendingPathComponent("slots")
    var previous: APIKeySlotStore? = try APIKeySlotStore(directory: directory)
    let selectedID = try XCTUnwrap(previous).create(key: "fixture-selected")
    let abandonedID = try XCTUnwrap(previous).create(key: "fixture-abandoned")
    let db = SelectorFixture()
    let selection = APIKeySelection(slotID: selectedID, configGeneration: 4)
    db.selected = selection
    previous = nil
    let store = try APIKeySlotStore(directory: directory)
    XCTAssertEqual(try store.validatedSlotIDs(), Set([selectedID, abandonedID]))
    let connection = try service(store: store, db: db, transport: FixtureOnlyTransport())
    connection.restore()
    XCTAssertEqual(connection.phase, .connected(selection))
    XCTAssertTrue(connection.eligibleForEntry)
    XCTAssertTrue(connection.canReplaceOwner)
    XCTAssertEqual(try store.validatedSlotIDs(), Set([selectedID]))
    XCTAssertEqual(try store.read(selectedID), "fixture-selected")
    XCTAssertEqual(db.selected, selection)
    XCTAssertEqual(db.commits, 0)
    connection.restore()
    XCTAssertEqual(try store.validatedSlotIDs(), Set([selectedID]))
  }

  func testStartupOrphanWithoutSelectionIsRemovedWithoutDispatchAndMissingSelectionBlocksCleanup() throws {
    for missingSelection in [false, true] {
      let parent = try ownedParent()
      defer { try? FileManager.default.removeItem(at: parent) }
      let directory = parent.appendingPathComponent("slots")
      var previous: APIKeySlotStore? = try APIKeySlotStore(directory: directory)
      let orphan = try XCTUnwrap(previous).create(key: "fixture-orphan")
      previous = nil
      let store = try APIKeySlotStore(directory: directory)
      let db = SelectorFixture()
      if missingSelection { db.selected = APIKeySelection(slotID: UUID(), configGeneration: 1) }
      let before = db.selected
      let transport = SuspendedProbe()
      let connection = try service(store: store, db: db, transport: transport)
      connection.restore()
      XCTAssertEqual(db.selected, before)
      XCTAssertEqual(db.commits, 0)
      XCTAssertTrue(transport.pending.isEmpty)
      XCTAssertFalse(connection.eligibleForEntry)
      if missingSelection {
        XCTAssertEqual(connection.phase, .failed(.unsafeStorage))
        XCTAssertEqual(try store.validatedSlotIDs(), Set([orphan]))
      } else {
        XCTAssertEqual(connection.phase, .idle)
        XCTAssertTrue(connection.canReplaceOwner)
        XCTAssertTrue(try store.validatedSlotIDs().isEmpty)
      }
    }
  }

  func testStartupDoesNotAdoptUnmarkedOrCopiedOwnershipRecords() throws {
    let parent = try ownedParent()
    defer { try? FileManager.default.removeItem(at: parent) }
    let directory = parent.appendingPathComponent("slots")
    var previous: APIKeySlotStore? = try APIKeySlotStore(directory: directory)
    let unmarked = try XCTUnwrap(previous).create(key: "fixture-unmarked")
    let marked = try XCTUnwrap(previous).create(key: "fixture-marked")
    let copied = UUID()
    let unmarkedURL = directory.appendingPathComponent(unmarked.uuidString)
    XCTAssertEqual(removexattr(unmarkedURL.path, APIKeySlotStore.ownershipAttribute, 0), 0)
    // Copying bytes/xattrs cannot grant ownership of a different filename/inode.
    let copiedURL = directory.appendingPathComponent(copied.uuidString)
    let markedURL = directory.appendingPathComponent(marked.uuidString)
    try FileManager.default.copyItem(at: markedURL, to: copiedURL)
    var record = [UInt8](repeating: 0, count: 512)
    let length = record.withUnsafeMutableBytes {
      getxattr(markedURL.path, APIKeySlotStore.ownershipAttribute, $0.baseAddress, $0.count, 0, 0)
    }
    guard length > 0, length <= record.count else { return XCTFail("Expected owned fixture record") }
    let copiedRecord = record.withUnsafeBytes {
      setxattr(copiedURL.path, APIKeySlotStore.ownershipAttribute, $0.baseAddress, length, 0, 0)
    }
    XCTAssertEqual(copiedRecord, 0)
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    var excludedCopy = copiedURL
    try excludedCopy.setResourceValues(values)
    previous = nil
    let store = try APIKeySlotStore(directory: directory)
    XCTAssertThrowsError(try store.remove(unmarked))
    XCTAssertThrowsError(try store.remove(copied))
    let db = SelectorFixture()
    db.selected = APIKeySelection(slotID: marked, configGeneration: 1)
    let connection = try service(store: store, db: db, transport: FixtureOnlyTransport())
    connection.restore()
    XCTAssertEqual(connection.phase, .failed(.cleanupBlocked))
    XCTAssertTrue(connection.eligibleForEntry)
    XCTAssertEqual(try store.validatedSlotIDs(), Set([unmarked, marked, copied]))
    XCTAssertEqual(try Data(contentsOf: unmarkedURL), Data("fixture-unmarked".utf8))
    XCTAssertEqual(try Data(contentsOf: copiedURL), Data("fixture-marked".utf8))
  }

  func testInvalidStartupEntriesPreventCleanupWithoutFollowingOrOpeningStreams() throws {
    for kind in ["fifo", "symlink", "hardlink"] {
      let parent = try ownedParent()
      defer { try? FileManager.default.removeItem(at: parent) }
      let directory = parent.appendingPathComponent("slots")
      var previous: APIKeySlotStore? = try APIKeySlotStore(directory: directory)
      let orphan = try XCTUnwrap(previous).create(key: "fixture-owned")
      previous = nil
      let owned = directory.appendingPathComponent(orphan.uuidString)
      let foreign = directory.appendingPathComponent(UUID().uuidString)
      switch kind {
      case "fifo":
        XCTAssertEqual(mkfifo(foreign.path, 0o600), 0)
      case "symlink":
        try FileManager.default.createSymbolicLink(at: foreign, withDestinationURL: owned)
      default:
        XCTAssertEqual(link(owned.path, foreign.path), 0)
      }
      XCTAssertThrowsError(try APIKeySlotStore(directory: directory)) {
        XCTAssertEqual($0 as? APIKeyConnectionError, .unsafeStorage)
      }
      XCTAssertEqual(try Data(contentsOf: owned), Data("fixture-owned".utf8))
      var info = stat()
      XCTAssertEqual(lstat(foreign.path, &info), 0, "Invalid entry must remain untouched")
    }
  }

  func testReplacedRootCannotUseOldLockToReadOrUnlinkAndFailedInitReleasesLock() throws {
    let parent = try ownedParent()
    defer { try? FileManager.default.removeItem(at: parent) }
    let directory = parent.appendingPathComponent("slots")
    let old = try APIKeySlotStore(directory: directory)
    let id = try old.create(key: "fixture-old")
    let moved = parent.appendingPathComponent("moved-slots")
    try FileManager.default.moveItem(at: directory, to: moved)
    var replacement: APIKeySlotStore? = try APIKeySlotStore(directory: directory)
    let replacementID = try XCTUnwrap(replacement).create(key: "fixture-replacement")
    XCTAssertThrowsError(try old.read(id))
    XCTAssertThrowsError(try old.remove(id))
    XCTAssertEqual(try replacement?.read(replacementID), "fixture-replacement")
    XCTAssertEqual(try Data(contentsOf: moved.appendingPathComponent(id.uuidString)), Data("fixture-old".utf8))
    replacement = nil
    let invalid = directory.appendingPathComponent(replacementID.uuidString)
    XCTAssertEqual(chmod(invalid.path, 0o644), 0)
    XCTAssertThrowsError(try APIKeySlotStore(directory: directory)) {
      XCTAssertEqual($0 as? APIKeyConnectionError, .unsafeStorage)
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: invalid.path))
    // Only the test repairs its synthetic file to verify failed initialization released flock.
    XCTAssertEqual(chmod(invalid.path, 0o600), 0)
    let successor = try APIKeySlotStore(directory: directory)
    XCTAssertEqual(try successor.read(replacementID), "fixture-replacement")
  }

  func testActualAdapterFixedWireAndExactSentinel() async throws {
    let authority = try ProviderRequest()
    let context = try TrustedRequestContext(authority: authority, sources: .connectionTest)
    let request = try authority.buildRequest(sources: .connectionTest, context: context,
      requestID: UUID().uuidString.lowercased())
    let body = try reply(tokens: 64)
    NativeProbeURLProtocol.install { wire in
      XCTAssertEqual(wire.url, NativeOpenAIConfiguration.endpoint)
      XCTAssertEqual(wire.httpMethod, "POST")
      XCTAssertEqual(wire.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-key")
      XCTAssertEqual(wire.value(forHTTPHeaderField: "X-Client-Request-Id"), request.wire.requestID)
      XCTAssertEqual(wire.timeoutInterval, 10)
      let payload: Data
      if let body = wire.httpBody {
        payload = body
      } else {
        let stream = try XCTUnwrap(wire.httpBodyStream)
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
          let read = buffer.withUnsafeMutableBufferPointer {
            stream.read($0.baseAddress!, maxLength: $0.count)
          }
          guard read >= 0, data.count + read <= 16_384 else { throw URLError(.badServerResponse) }
          if read == 0 { break }
          data.append(contentsOf: buffer.prefix(read))
        }
        payload = data
      }
      let object = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
      XCTAssertEqual(object["model"] as? String, "explicit-test-snapshot")
      XCTAssertEqual(object["max_completion_tokens"] as? Int, 64)
      XCTAssertEqual(object["stream"] as? Bool, false)
      XCTAssertEqual(object["store"] as? Bool, false)
      let messages = try XCTUnwrap(object["messages"] as? [[String: String]])
      XCTAssertEqual(messages, [["role": "user", "content": "Reply exactly PAPERLENS_OK."]])
      return (200, body)
    }
    let result = try await networkTransport().probe(key: "fixture-key",
      configuration: NativeOpenAIConfiguration(model: model), request: request, authority: authority)
    XCTAssertEqual(result.result.requestID, request.wire.requestID)
    XCTAssertEqual(result.result.schemaVersion, 1)
    XCTAssertEqual(result.result.operation, .connectionTest)
    XCTAssertEqual(result.result.result, .connectionTest("PAPERLENS_OK"))
    XCTAssertThrowsError(try NativeOpenAIConfiguration(model: model).requireCertifiedEnforcement()) {
      XCTAssertEqual($0 as? APIKeyConnectionError, .unsupportedProfile)
    }
  }

  func testAdapterRejectsInvalidProviderBodiesAndStatuses() async throws {
    let authority = try ProviderRequest()
    let context = try TrustedRequestContext(authority: authority, sources: .connectionTest)
    let request = try authority.buildRequest(sources: .connectionTest, context: context,
      requestID: UUID().uuidString.lowercased())
    let cases: [(Int, Data, APIKeyConnectionError)] = [
      (401, Data(), .authentication), (429, Data(), .rateLimited),
      (400, Data(), .unsupportedProfile), (503, Data(), .providerUnavailable),
      (200, try reply(text: "PAPERLENS_OK\n"), .invalidResponse),
      (200, try reply(text: "paperlens_ok"), .invalidResponse),
      (200, try reply(model: "other-model"), .invalidResponse),
      (200, try reply(tokens: 65), .invalidResponse),
      (200, Data("{\"object\":\"chat.completion\",\"object\":\"chat.completion\"}".utf8), .invalidResponse),
      (200, Data(repeating: 32, count: 16_385), .invalidResponse),
      (200, Data("not JSON".utf8), .invalidResponse),
    ]
    for (status, body, expected) in cases {
      NativeProbeURLProtocol.install { _ in (status, body) }
      do {
        _ = try await networkTransport().probe(key: "fixture-key",
          configuration: NativeOpenAIConfiguration(model: model), request: request, authority: authority)
        XCTFail("Rejected response was accepted")
      } catch { XCTAssertEqual(error as? APIKeyConnectionError, expected) }
    }
    NativeProbeURLProtocol.install { _ in throw URLError(.timedOut) }
    do {
      _ = try await networkTransport().probe(key: "fixture-key",
        configuration: NativeOpenAIConfiguration(model: model), request: request, authority: authority)
      XCTFail("Timeout was accepted")
    } catch { XCTAssertEqual(error as? APIKeyConnectionError, .deadline) }
  }

  func testMissingBindingAndSyntheticEvidenceNeverPromote() async throws {
    let (parent, store) = try ownedStore()
    defer { try? FileManager.default.removeItem(at: parent) }
    let unbound = try service(store: store, db: nil, transport: FixtureOnlyTransport())
    unbound.connect(key: "fixture-key")
    try await settled(unbound)
    XCTAssertEqual(unbound.phase, .failed(.persistenceUnavailable))
    XCTAssertFalse(unbound.eligibleForEntry)
    let db = SelectorFixture()
    let synthetic = try service(store: store, db: db, transport: FixtureOnlyTransport())
    synthetic.connect(key: "fixture-key")
    try await settled(synthetic)
    XCTAssertEqual(synthetic.phase, .failed(.authentication))
    XCTAssertNil(db.selected)
    XCTAssertEqual(db.commits, 0)
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.appendingPathComponent("slots").path), [])
  }

  func testReplacementRetainsLeasedOldSecretAndBlocksOldPublication() async throws {
    let (parent, store) = try ownedStore()
    defer { try? FileManager.default.removeItem(at: parent) }
    let db = SelectorFixture()
    let body = try reply()
    NativeProbeURLProtocol.install { _ in (200, body) }
    let connection = try service(store: store, db: db)
    connection.connect(key: "fixture-first")
    try await settled(connection)
    let old = try connection.acquireLease()
    connection.connect(key: "fixture-second")
    try await settled(connection)
    XCTAssertEqual(db.commits, 2)
    XCTAssertEqual(connection.activeSelection?.configGeneration, 2)
    XCTAssertEqual(try connection.key(for: old), "fixture-first")
    XCTAssertFalse(try connection.mayPublish(old))
    connection.restore()
    XCTAssertEqual(connection.phase, .connected(try XCTUnwrap(db.selected)))
    try connection.releaseAfterTermination(old)
    XCTAssertTrue(connection.canReplaceOwner)
    XCTAssertThrowsError(try store.read(old.selection.slotID))
    let new = try connection.acquireLease()
    XCTAssertEqual(try connection.key(for: new), "fixture-second")
    XCTAssertTrue(try connection.mayPublish(new))
    try connection.releaseAfterTermination(new)
    let restarted = try service(store: store, db: db)
    restarted.restore()
    XCTAssertEqual(restarted.activeSelection, connection.activeSelection)
    XCTAssertTrue(restarted.eligibleForEntry)
  }

  func testStartupUnknownSlotPreservesLastGoodAndBlocksReplacementWithoutDeleting() async throws {
    let (parent, store) = try ownedStore()
    defer { try? FileManager.default.removeItem(at: parent) }
    let selectedID = try store.create(key: "fixture-selected")
    let unknownID = try store.create(key: "fixture-unknown")
    let db = SelectorFixture()
    let selection = APIKeySelection(slotID: selectedID, configGeneration: 7)
    db.selected = selection
    let transport = SuspendedProbe()
    let connection = try service(store: store, db: db, transport: transport)
    connection.restore()
    XCTAssertEqual(connection.phase, .failed(.cleanupBlocked))
    XCTAssertEqual(connection.activeSelection, selection)
    XCTAssertTrue(connection.eligibleForEntry)
    XCTAssertFalse(connection.canReplaceOwner)
    let lease = try connection.acquireLease()
    XCTAssertEqual(try connection.key(for: lease), "fixture-selected")
    XCTAssertTrue(try connection.mayPublish(lease))
    connection.connect(key: "fixture-replacement")
    try await settled(connection)
    XCTAssertEqual(connection.phase, .failed(.cleanupBlocked))
    XCTAssertTrue(connection.eligibleForEntry)
    XCTAssertTrue(transport.pending.isEmpty)
    XCTAssertEqual(db.selected, selection)
    XCTAssertEqual(db.commits, 0)
    try connection.releaseAfterTermination(lease)
    connection.restore()
    XCTAssertFalse(connection.canReplaceOwner)
    XCTAssertEqual(try store.validatedSlotIDs(), Set([selectedID, unknownID]))
    XCTAssertEqual(try store.read(unknownID), "fixture-unknown")
  }

  func testUnknownSlotWithoutSelectionBlocksFirstProbeEvenWithoutRestore() async throws {
    let (parent, store) = try ownedStore()
    defer { try? FileManager.default.removeItem(at: parent) }
    let unknownID = try store.create(key: "fixture-unknown")
    let db = SelectorFixture()
    let transport = SuspendedProbe()
    let connection = try service(store: store, db: db, transport: transport)
    connection.connect(key: "fixture-new")
    try await settled(connection)
    XCTAssertEqual(connection.phase, .failed(.cleanupBlocked))
    XCTAssertFalse(connection.eligibleForEntry)
    XCTAssertFalse(connection.canReplaceOwner)
    XCTAssertNil(db.selected)
    XCTAssertEqual(db.commits, 0)
    XCTAssertTrue(transport.pending.isEmpty)
    XCTAssertEqual(try store.validatedSlotIDs(), Set([unknownID]))
    connection.restore()
    XCTAssertEqual(connection.phase, .failed(.cleanupBlocked))
    XCTAssertEqual(try store.read(unknownID), "fixture-unknown")
  }

  func testUnknownInventoryDuringProbeDeniesLatePromotionButRetainsLastGood() async throws {
    let (parent, store) = try ownedStore()
    defer { try? FileManager.default.removeItem(at: parent) }
    let selectedID = try store.create(key: "fixture-selected")
    let db = SelectorFixture()
    let selection = APIKeySelection(slotID: selectedID, configGeneration: 1)
    db.selected = selection
    let transport = SuspendedProbe()
    let connection = try service(store: store, db: db, transport: transport)
    connection.restore()
    connection.connect(key: "fixture-candidate")
    try await started(transport, count: 1)
    connection.restore()
    XCTAssertEqual(connection.phase, .connected(selection), "The owned probe is not unknown")
    let unknownID = try store.create(key: "fixture-unknown")
    try transport.finish(0)
    // Wait for actual candidate retirement, not restore's already terminal UI phase.
    for _ in 0..<400 {
      if try store.validatedSlotIDs() == Set([selectedID, unknownID]) { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTAssertEqual(try store.validatedSlotIDs(), Set([selectedID, unknownID]))
    XCTAssertEqual(db.selected, selection)
    XCTAssertEqual(db.commits, 0)
    XCTAssertTrue(connection.eligibleForEntry)
    XCTAssertFalse(connection.canReplaceOwner)
    XCTAssertEqual(connection.phase, .failed(.cleanupBlocked))
  }

  func testReplacementFailureAndCASConflictPreserveLastGood() async throws {
    let (parent, store) = try ownedStore()
    defer { try? FileManager.default.removeItem(at: parent) }
    let db = SelectorFixture()
    let body = try reply()
    NativeProbeURLProtocol.install { _ in (200, body) }
    let connection = try service(store: store, db: db)
    connection.connect(key: "fixture-good")
    try await settled(connection)
    let good = db.selected
    NativeProbeURLProtocol.install { _ in (401, Data()) }
    connection.connect(key: "fixture-invalid")
    try await settled(connection)
    XCTAssertEqual(connection.phase, .failed(.authentication))
    XCTAssertEqual(db.selected, good)
    XCTAssertTrue(connection.eligibleForEntry)
    NativeProbeURLProtocol.install { _ in (200, body) }
    db.conflict = true
    connection.connect(key: "fixture-conflict")
    try await settled(connection)
    XCTAssertEqual(connection.phase, .failed(.selectorConflict))
    XCTAssertEqual(db.selected, good)
    XCTAssertEqual(db.commits, 1)
    XCTAssertTrue(connection.eligibleForEntry)
    db.conflict = false
    db.failCommit = true
    connection.connect(key: "fixture-commit-failure")
    try await settled(connection)
    XCTAssertEqual(connection.phase, .failed(.persistenceFailure))
    XCTAssertEqual(db.selected, good)
  }

  func testEditCancelAndWrongCorrelationRejectLateSuccess() async throws {
    let (parent, store) = try ownedStore()
    defer { try? FileManager.default.removeItem(at: parent) }
    let db = SelectorFixture()
    let transport = SuspendedProbe()
    let connection = try service(store: store, db: db, transport: transport)
    connection.connect(key: "fixture-edit")
    try await started(transport, count: 1)
    XCTAssertFalse(connection.canReplaceOwner)
    connection.invalidateCandidate()
    XCTAssertFalse(connection.canReplaceOwner)
    try transport.finish(0)
    for _ in 0..<10 { await Task.yield() }
    XCTAssertNil(db.selected)
    connection.connect(key: "fixture-cancel")
    try await started(transport, count: 2)
    connection.cancel()
    XCTAssertFalse(connection.canReplaceOwner)
    try transport.finish(1)
    for _ in 0..<10 { await Task.yield() }
    XCTAssertNil(db.selected)
    XCTAssertEqual(connection.phase, .failed(.cancelled))
    XCTAssertTrue(connection.canReplaceOwner)
    connection.connect(key: "fixture-correlation")
    try await started(transport, count: 3)
    try transport.finish(2, mismatchedID: true)
    try await settled(connection)
    XCTAssertEqual(connection.phase, .failed(.invalidResponse))
    XCTAssertNil(db.selected)
    XCTAssertFalse(connection.eligibleForEntry)
  }

  func testStorageRejectsModesSymlinksAndReplacedInodesWithoutRepair() throws {
    let (parent, store) = try ownedStore()
    defer { try? FileManager.default.removeItem(at: parent) }
    let id = try store.create(key: "fixture-secret")
    let file = parent.appendingPathComponent("slots").appendingPathComponent(id.uuidString)
    XCTAssertEqual(try store.read(id), "fixture-secret")
    XCTAssertEqual(try file.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    XCTAssertEqual(chmod(file.path, 0o644), 0)
    XCTAssertThrowsError(try store.validate())
    var info = stat()
    XCTAssertEqual(lstat(file.path, &info), 0)
    XCTAssertEqual(info.st_mode & 0o7777, 0o644)
    // Test owns this fixture and explicitly restores it; production never repairs permissions.
    XCTAssertEqual(chmod(file.path, 0o600), 0)
    let moved = parent.appendingPathComponent("moved-fixture")
    try FileManager.default.moveItem(at: file, to: moved)
    try FileManager.default.createSymbolicLink(at: file, withDestinationURL: moved)
    XCTAssertThrowsError(try store.read(id))
    try FileManager.default.removeItem(at: file)
    try FileManager.default.copyItem(at: moved, to: file)
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    var replacement = file
    try replacement.setResourceValues(values)
    XCTAssertThrowsError(try store.read(id))
    XCTAssertThrowsError(try store.remove(id))
    XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
  }

  func testLatestCandidateWinsAndLosingCleanupNeverDeletesWinner() async throws {
    let (parent, store) = try ownedStore()
    defer { try? FileManager.default.removeItem(at: parent) }
    let db = SelectorFixture()
    let transport = SuspendedProbe()
    let connection = try service(store: store, db: db, transport: transport)
    connection.connect(key: "fixture-first-candidate")
    try await started(transport, count: 1)
    connection.connect(key: "fixture-second-candidate")
    try await started(transport, count: 2)
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(
      atPath: parent.appendingPathComponent("slots").path).count, 2)
    try transport.finish(1)
    try await settled(connection)
    let winner = try XCTUnwrap(db.selected)
    try transport.finish(0)
    for _ in 0..<100 {
      if try FileManager.default.contentsOfDirectory(
        atPath: parent.appendingPathComponent("slots").path).count == 1 { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTAssertEqual(db.commits, 1)
    XCTAssertEqual(db.selected, winner)
    XCTAssertEqual(try store.read(winner.slotID), "fixture-second-candidate")
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(
      atPath: parent.appendingPathComponent("slots").path).count, 1)
  }

  func testAmbiguousCommitRetainsPossiblySelectedSlotAndNeverReportsReady() async throws {
    let (parent, store) = try ownedStore()
    defer { try? FileManager.default.removeItem(at: parent) }
    let db = SelectorFixture()
    db.commitAndThrow = true
    let body = try reply()
    NativeProbeURLProtocol.install { _ in (200, body) }
    let connection = try service(store: store, db: db)
    connection.connect(key: "fixture-ambiguous-commit")
    try await settled(connection)
    let possibleWinner = try XCTUnwrap(db.selected)
    XCTAssertEqual(try store.read(possibleWinner.slotID), "fixture-ambiguous-commit")
    XCTAssertEqual(connection.phase, .failed(.persistenceFailure))
    XCTAssertNil(connection.activeSelection)
    XCTAssertFalse(connection.eligibleForEntry)
    XCTAssertThrowsError(try connection.acquireLease())
  }

  func testCleanupFailureAndBackupExclusionFailureBlockWithoutRepair() async throws {
    let (parent, store) = try ownedStore()
    defer { try? FileManager.default.removeItem(at: parent) }
    let db = SelectorFixture()
    let transport = SuspendedProbe()
    let connection = try service(store: store, db: db, transport: transport)
    connection.connect(key: "fixture-cleanup")
    try await started(transport, count: 1)
    let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(
      at: parent.appendingPathComponent("slots"), includingPropertiesForKeys: nil).first)
    XCTAssertEqual(chmod(file.path, 0o644), 0)
    try transport.finish(0)
    try await settled(connection)
    XCTAssertEqual(connection.phase, .failed(.cleanupBlocked))
    XCTAssertNil(db.selected)
    XCTAssertFalse(connection.eligibleForEntry)
    XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    // Fixture-only remediation to independently check backup refusal.
    XCTAssertEqual(chmod(file.path, 0o600), 0)
    // A child inherits its excluded parent's protection on macOS. Remove the
    // namespace's actual protection, not an ineffective child override.
    var url = parent.appendingPathComponent("slots", isDirectory: true)
    var values = URLResourceValues()
    values.isExcludedFromBackup = false
    try url.setResourceValues(values)
    XCTAssertThrowsError(try store.validate())
    connection.restore()
    XCTAssertFalse(connection.eligibleForEntry)
  }

  func testExplicitConfigurationRejectsUnsafeEndpointAndModel() throws {
    XCTAssertThrowsError(try NativeOpenAIConfiguration(model: ""))
    XCTAssertThrowsError(try NativeOpenAIConfiguration(model: "model\nHeader"))
    XCTAssertThrowsError(try NativeOpenAIConfiguration(model: model, endpoint: URL(string: "https://example.test/v1/chat/completions")!))
    XCTAssertThrowsError(try NativeOpenAIConfiguration(model: model, endpoint: URL(string: "http://api.openai.com/v1/chat/completions")!))
  }
}
