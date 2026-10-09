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

  private func ownedStore() throws -> (URL, APIKeySlotStore) {
    let alias = FileManager.default.temporaryDirectory
      .appendingPathComponent("paperlens-key-fixture-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: alias, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    guard let physicalPath = realpath(alias.path, nil) else {
      throw APIKeyConnectionError.unsafeStorage
    }
    defer { free(physicalPath) }
    let parent = URL(fileURLWithPath: String(cString: physicalPath), isDirectory: true)
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
    try connection.releaseAfterTermination(old)
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
