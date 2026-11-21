import CryptoKit
import Darwin
import Foundation
import XCTest
#if SWIFT_PACKAGE
import ProviderRequest
#endif
@testable import PaperLensProduct

final class URLImportTests: XCTestCase {
  private func directory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    addTeardownBlock { try FileManager.default.removeItem(at: directory) }
    return directory
  }

  private func configuration() -> URLSessionConfiguration {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ImportFixtureProtocol.self]
    return configuration
  }

  func testRoutesPreserveArxivVersionAndRejectCredentialsHTTPAndMalformedArxiv() throws {
    let adapter = HTTPSPDFImportAdapter(authority: try ProviderRequest())
    XCTAssertEqual(try adapter.route("https://arxiv.org/abs/2401.12345v2").value,
      "https://arxiv.org/pdf/2401.12345v2")
    XCTAssertEqual(try adapter.route("https://arxiv.org/pdf/2401.12345v2.pdf").sourceKind, "arxivPDF")
    XCTAssertEqual(try adapter.route("https://fixture.invalid/chunks").sourceKind, "httpsPDF")
    for value in ["http://fixture.invalid/a.pdf", "https://user:secret@fixture.invalid/a.pdf",
      "https://arxiv.org/abs/not-an-id", "https://arxiv.org/abs/2401.12345?token=secret"] {
      XCTAssertThrowsError(try adapter.route(value))
    }
  }

  func testChunkedMagicProducesRealClosedImmutableStageAndDigest() async throws {
    let authority = try ProviderRequest()
    let adapter = HTTPSPDFImportAdapter(authority: authority)
    let pool = try RequestResourcePool(authority: authority, kind: "import")
    let before = pool.active
    let observations = HTTPSCloseObservations(pool: pool)
    let directory = try directory()
    let stage = try await adapter.download(route: adapter.route("https://fixture.invalid/chunks"),
      stagingDirectory: directory, assertCurrent: {}, configuration: configuration(), effects: observations.effects())
    XCTAssertEqual(observations.snapshot.attempts, 1)
    XCTAssertEqual(observations.snapshot.mode, 0o400)
    XCTAssertEqual(observations.snapshot.drains, 1)
    XCTAssertEqual(observations.snapshot.activeAtDrain, before + 1)
    XCTAssertEqual(pool.active, before)
    XCTAssertEqual(try Data(contentsOf: stage.file), Data("%PDF-1.7\nfixture".utf8))
    XCTAssertEqual(stage.byteCount, 16)
    XCTAssertEqual(stage.sha256, SHA256.hash(data: Data("%PDF-1.7\nfixture".utf8))
      .map { String(format: "%02x", $0) }.joined())
    let attributes = try FileManager.default.attributesOfItem(atPath: stage.file.path)
    XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o400)
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 1)
  }

  func testExactReadBufferAllowedAndOneOverRejectedWithStageRemoved() async throws {
    let authority = try ProviderRequest()
    let adapter = HTTPSPDFImportAdapter(authority: authority)
    let directory = try directory()
    let stage = try await adapter.download(route: adapter.route("https://fixture.invalid/exact-buffer"),
      stagingDirectory: directory, assertCurrent: {}, configuration: configuration(), effects: .actual)
    XCTAssertEqual(stage.byteCount, authority.limit("readBufferBytes"))
    try FileManager.default.removeItem(at: stage.file)
    do {
      _ = try await adapter.download(route: adapter.route("https://fixture.invalid/over-buffer"),
        stagingDirectory: directory, assertCurrent: {}, configuration: configuration(), effects: .actual)
      XCTFail("oversized transport callback accepted")
    } catch { XCTAssertEqual(error as? URLImportError, .rejected) }
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
  }

  func testMIMEEncodingMagicAndStatusRejectionsLeaveNoStage() async throws {
    let adapter = HTTPSPDFImportAdapter(authority: try ProviderRequest())
    let directory = try directory()
    for fixture in ["mime", "encoding", "magic", "empty", "status", "header-count", "header-bytes"] {
      do {
        _ = try await adapter.download(route: adapter.route("https://fixture.invalid/" + fixture),
          stagingDirectory: directory, assertCurrent: {}, configuration: configuration(), effects: .actual)
        XCTFail("invalid response accepted: " + fixture)
      } catch { XCTAssertEqual(error as? URLImportError, .rejected) }
      XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }
  }

  func testValidatedRedirectAndRejectedCredentialHTTPAndRedirectLoop() async throws {
    let adapter = HTTPSPDFImportAdapter(authority: try ProviderRequest())
    let directory = try directory()
    let stage = try await adapter.download(route: adapter.route("https://fixture.invalid/redirect"),
      stagingDirectory: directory, assertCurrent: {}, configuration: configuration(), effects: .actual)
    XCTAssertEqual(try Data(contentsOf: stage.file), Data("%PDF-1.7\nfixture".utf8))
    try FileManager.default.removeItem(at: stage.file)
    for fixture in ["redirect-http", "redirect-credential", "redirect-loop"] {
      do {
        _ = try await adapter.download(route: adapter.route("https://fixture.invalid/" + fixture),
          stagingDirectory: directory, assertCurrent: {}, configuration: configuration(), effects: .actual)
        XCTFail("unsafe redirect accepted")
      } catch { XCTAssertEqual(error as? URLImportError, .rejected) }
      XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }
  }

  func testCancelledTransportDrainsBeforeReturningAndRemovesStage() async throws {
    let authority = try ProviderRequest()
    let adapter = HTTPSPDFImportAdapter(authority: authority)
    let pool = try RequestResourcePool(authority: authority, kind: "import")
    let before = pool.active
    let observations = HTTPSCloseObservations(pool: pool)
    let directory = try directory()
    let marker = UUID().uuidString
    let sessionConfiguration = configuration()
    let task = Task {
      try await adapter.download(route: adapter.route("https://fixture.invalid/stall/" + marker),
        stagingDirectory: directory, assertCurrent: {}, configuration: sessionConfiguration, effects: observations.effects())
    }
    for _ in 0..<300 {
      if ImportFixtureProtocol.state.hasStarted(marker) { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertTrue(ImportFixtureProtocol.state.hasStarted(marker), "Fixture transport did not start")
    task.cancel()
    do { _ = try await task.value; XCTFail("cancel succeeded") }
    catch { XCTAssertEqual(error as? URLImportError, .cancelled) }
    XCTAssertTrue(ImportFixtureProtocol.state.hasStopped(marker))
    XCTAssertEqual(observations.snapshot.attempts, 1)
    XCTAssertEqual(observations.snapshot.drains, 1)
    XCTAssertEqual(observations.snapshot.activeAtDrain, before + 1)
    XCTAssertEqual(pool.active, before)
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
  }

  func testRejectedBodyAndEarlyActualInvalidationCloseExactlyOnce() async throws {
    let authority = try ProviderRequest()
    let adapter = HTTPSPDFImportAdapter(authority: authority)
    let pool = try RequestResourcePool(authority: authority, kind: "import")
    let directory = try directory()
    for invalidate in [false, true] {
      let before = pool.active
      let observations = HTTPSCloseObservations(pool: pool)
      do {
        _ = try await adapter.download(route: adapter.route("https://fixture.invalid/magic"),
          stagingDirectory: directory, assertCurrent: {}, configuration: configuration(),
          effects: observations.effects(invalidateImmediately: invalidate))
        XCTFail("rejection/invalidation returned a stage")
      } catch { XCTAssertEqual(error as? URLImportError, .rejected) }
      XCTAssertEqual(observations.snapshot.attempts, 1)
      XCTAssertEqual(observations.snapshot.drains, 1)
      XCTAssertEqual(observations.snapshot.activeAtDrain, before + 1)
      XCTAssertEqual(pool.active, before)
      XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }
  }

  func testInvalidStageURLsHaveNoDescriptorOrLeaseEffects() async throws {
    let authority = try ProviderRequest()
    let adapter = HTTPSPDFImportAdapter(authority: authority)
    let pool = try RequestResourcePool(authority: authority, kind: "import")
    let directory = try directory()
    let observations = HTTPSCloseObservations(pool: pool)
    let before = pool.active
    let invalid = [try XCTUnwrap(URL(string: "https://fixture.invalid/not-a-directory")),
      directory.appendingPathComponent("decoded\0NUL"),
      URL(fileURLWithPath: directory.path(percentEncoded: false) + "/explicit\0NUL"),
      directory.appendingPathComponent("missing-directory")]
    for url in invalid {
      do {
        _ = try await adapter.download(route: adapter.route("https://fixture.invalid/chunks"),
          stagingDirectory: url, assertCurrent: {}, configuration: configuration(), effects: observations.effects())
        XCTFail("invalid filesystem URL accepted")
      } catch { XCTAssertEqual(error as? URLImportError, .writerUnavailable, "Invalid stage denial: \(error)") }
    }
    XCTAssertNil(observations.snapshot.descriptor)
    XCTAssertEqual(observations.snapshot.attempts, 0)
    XCTAssertEqual(observations.snapshot.drains, 0)
    XCTAssertEqual(pool.active, before)
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
  }

  // Run this irreversible logical-debt case in its own process for parallel suites.
  func testUnknownCloseRetainsActualFDStageAndQuotaAfterTaskAndFacadeLoss() async throws {
    let authority = try ProviderRequest()
    let pool = try RequestResourcePool(authority: authority, kind: "import")
    let before = pool.active
    let roots = HTTPSPDFImportAdapter.rootedProducerIDs
    let directory = try directory()
    let observations = HTTPSCloseObservations(pool: pool)
    var adapter: HTTPSPDFImportAdapter? = HTTPSPDFImportAdapter(authority: authority)
    let sessionConfiguration = configuration()
    var download: Task<ClosedHTTPSPDFStage, any Error>? = Task { [adapter = try XCTUnwrap(adapter)] in
      try await adapter.download(route: adapter.route("https://fixture.invalid/chunks"),
        stagingDirectory: directory, assertCurrent: {}, configuration: sessionConfiguration,
        effects: observations.effects(failClose: true))
    }
    do { _ = try await download?.value; XCTFail("unknown close returned success") }
    catch { XCTAssertEqual(error as? URLImportError, .closureUnknown) }
    let descriptor = try XCTUnwrap(observations.snapshot.descriptor)
    // Explicit OS fixture cleanup is NOT an owner close acknowledgment.
    defer {
      XCTAssertEqual(Darwin.close(descriptor), 0)
      XCTAssertEqual(pool.active, before + 1)
      XCTAssertEqual(HTTPSPDFImportAdapter.rootedProducerIDs.subtracting(roots).count, 1)
      XCTAssertEqual(observations.snapshot.attempts, 1)
    }
    download = nil
    adapter = nil
    for _ in 0..<20 { await Task.yield() }
    XCTAssertNotEqual(Darwin.fcntl(descriptor, F_GETFD), -1)
    XCTAssertEqual(observations.snapshot.attempts, 1)
    XCTAssertEqual(observations.snapshot.drains, 1)
    XCTAssertEqual(pool.active, before + 1)
    XCTAssertEqual(HTTPSPDFImportAdapter.rootedProducerIDs.subtracting(roots).count, 1)
    let stages = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    XCTAssertEqual(stages.count, 1)
    XCTAssertEqual(try Data(contentsOf: XCTUnwrap(stages.first)), Data("%PDF-1.7\nfixture".utf8))
    let capacity = authority.limit(authority.contract["pools"]["import"]["limit"].string)
    var otherAdmissions: [RequestResourceLease] = []
    defer { for lease in otherAdmissions { lease.close() } }
    for _ in 0..<(capacity - before - 1) {
      otherAdmissions.append(try XCTUnwrap(pool.acquire()))
    }
    XCTAssertEqual(pool.active, capacity)
    XCTAssertNil(pool.acquire(), "retained actual lease must consume real authority capacity")
    XCTAssertEqual(observations.snapshot.attempts, 1)
  }

  func testRevokedWriterBlocksAllFileEffects() async throws {
    let adapter = HTTPSPDFImportAdapter(authority: try ProviderRequest())
    let directory = try directory()
    do {
      _ = try await adapter.download(route: adapter.route("https://fixture.invalid/chunks"),
        stagingDirectory: directory, assertCurrent: { throw URLImportError.writerUnavailable },
        configuration: configuration(), effects: .actual)
      XCTFail("revoked writer accepted")
    } catch { XCTAssertEqual(error as? URLImportError, .writerUnavailable) }
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
  }

  func testRevocationAfterAdmissionBlocksQueuedStageAndSessionCreation() async throws {
    let authority = try ProviderRequest()
    let adapter = HTTPSPDFImportAdapter(authority: authority)
    let pool = try RequestResourcePool(authority: authority, kind: "import")
    let before = pool.active
    let roots = HTTPSPDFImportAdapter.rootedProducerIDs
    let directory = try directory()
    let cancellation = ImportCancellation()
    let observations = HTTPSCloseObservations(pool: pool)
    do {
      _ = try await adapter.download(route: adapter.route("https://fixture.invalid/chunks"),
        stagingDirectory: directory, assertCurrent: {
          try cancellation.check()
          cancellation.cancel()
        }, configuration: configuration(), effects: observations.effects())
      XCTFail("Revoked writer was allowed to start producing")
    } catch { XCTAssertEqual(error as? URLImportError, .cancelled) }
    XCTAssertNil(observations.snapshot.descriptor)
    XCTAssertEqual(observations.snapshot.attempts, 0)
    XCTAssertEqual(observations.snapshot.sessions, 0)
    XCTAssertEqual(observations.snapshot.drains, 0)
    XCTAssertEqual(pool.active, before)
    XCTAssertEqual(HTTPSPDFImportAdapter.rootedProducerIDs, roots)
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
  }

  func testPDFBudgetNotRPCBodyBudgetAndOneOverIsSticky() throws {
    let authority = try ProviderRequest()
    let budget = try RequestResourceBudget(authority: authority, kind: "import")
    try budget.add("bodyBytes", delta: authority.limit("bodyBytes") + 1)
    try budget.add("bodyBytes", delta: authority.limit("pdfBytes") - authority.limit("bodyBytes") - 1)
    XCTAssertEqual(budget.values["bodyBytes"], authority.limit("pdfBytes"))
    XCTAssertThrowsError(try budget.add("bodyBytes", delta: 1))
    XCTAssertThrowsError(try budget.add("bodyBytes", delta: 0))
  }

  @MainActor
  func testDropLoadsURLAndLocalPDFOnlyAfterEnteringTarget() async throws {
    let grants = GrantRecorder()
    let service = URLImportService(authority: try ProviderRequest(), grantWriter: { _ in
      grants.record()
      throw URLImportError.writerUnavailable
    })
    let state = URLImportDragState()
    state.appear()
    var selectedFiles: [URL] = []
    let delegate = URLImportDropDelegate(state: state, supportsURL: { service.supports($0) },
      localPDFAvailable: true, canAccept: { service.confirmation == nil }, accept: { url in
        if url.isFileURL {
          selectedFiles.append(url)
        } else {
          do { try service.prepare(url.absoluteString, destination: "Library", possibleDuplicate: true) }
          catch { XCTFail("Supported drop did not enter confirmation") }
        }
      })
    let link = try XCTUnwrap(URL(string: "https://arxiv.org/abs/2401.12345v2"))
    let urlItem = NSItemProvider(object: link as NSURL)
    XCTAssertFalse(delegate.performDrop(urlItem), "The Library is not targeted yet")
    state.targeted = true
    XCTAssertTrue(delegate.performDrop(urlItem), "A fast drop needs no loaded hover payload")
    XCTAssertFalse(state.targeted)
    try await settleDrop(state)
    XCTAssertEqual(service.state, .confirming)
    XCTAssertEqual(service.confirmation?.inputKind, .arxivAbstract)
    XCTAssertEqual(grants.count, 0)
    service.cancelConfirmation()

    let file = try directory().appendingPathComponent("selected.pdf")
    try Data("%PDF-1.4\n%%EOF\n".utf8).write(to: file)
    state.targeted = true
    XCTAssertTrue(delegate.performDrop(NSItemProvider(object: file as NSURL)))
    try await settleDrop(state)
    XCTAssertEqual(selectedFiles.map(\.path), [file.path])
    XCTAssertEqual(service.state, .idle)
    XCTAssertEqual(grants.count, 0)
  }

  @MainActor
  func testDropRejectsHTTPAndNonPDFPayloadsAfterTypedHover() async throws {
    let service = URLImportService(authority: try ProviderRequest())
    let state = URLImportDragState()
    state.appear()
    let delegate = URLImportDropDelegate(state: state, supportsURL: { service.supports($0) },
      localPDFAvailable: true, canAccept: { true }, accept: { _ in
        XCTFail("Unsupported payload reached the Library")
      })
    let http = try XCTUnwrap(URL(string: "http://fixture.invalid/paper.pdf"))
    let textFile = try directory().appendingPathComponent("selected.txt")
    try Data("not a PDF".utf8).write(to: textFile)
    for candidate in [http, textFile] {
      state.targeted = true
      XCTAssertTrue(delegate.performDrop(NSItemProvider(object: candidate as NSURL)))
      try await settleDrop(state)
    }
    XCTAssertFalse(state.targeted)
    XCTAssertNil(service.confirmation)
  }

  @MainActor
  private func settleDrop(_ state: URLImportDragState) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + .seconds(3)
    while state.pendingDrop != nil && clock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertNil(state.pendingDrop, "Item provider did not finish")
  }

  @MainActor
  func testCancelBeforeContinueAndMissingCapabilityHaveZeroGrantEffects() throws {
    let recorder = GrantRecorder()
    let service = URLImportService(authority: try ProviderRequest(), grantWriter: { _ in
      recorder.record()
      throw URLImportError.writerUnavailable
    })
    try service.prepare("https://fixture.invalid/chunks", destination: "Library", possibleDuplicate: true)
    let oldID = try XCTUnwrap(service.confirmation).id
    service.cancelConfirmation()
    service.continueImport(confirmationID: oldID)
    XCTAssertEqual(service.state, .idle)
    XCTAssertEqual(recorder.count, 0)
    let unavailable = URLImportService(authority: try ProviderRequest())
    try unavailable.prepare("https://fixture.invalid/chunks", destination: "Library", possibleDuplicate: false)
    unavailable.continueImport(confirmationID: try XCTUnwrap(unavailable.confirmation).id)
    XCTAssertEqual(unavailable.state, .failed(.writerUnavailable))
  }

  @MainActor
  func testContinueConsumesOnceAndRetryRequiresFreshConfirmation() async throws {
    let recorder = GrantRecorder()
    let service = URLImportService(authority: try ProviderRequest(), grantWriter: { _ in
      recorder.record()
      throw URLImportError.writerUnavailable
    })
    try service.prepare("https://fixture.invalid/chunks", destination: "Actual Folder", possibleDuplicate: true)
    let id = try XCTUnwrap(service.confirmation).id
    service.continueImport(confirmationID: id)
    service.continueImport(confirmationID: id)
    while service.state == .downloading { await Task.yield() }
    XCTAssertEqual(recorder.count, 1)
    XCTAssertEqual(service.state, .failed(.writerUnavailable))
    XCTAssertTrue(service.canRetry)
    try service.retry()
    XCTAssertEqual(service.state, .confirming)
    let cancelledID = try XCTUnwrap(service.confirmation).id
    XCTAssertNotEqual(cancelledID, id)
    XCTAssertFalse(service.canRetry)
    service.cancelConfirmation()
    service.continueImport(confirmationID: cancelledID)
    XCTAssertEqual(service.state, .failed(.writerUnavailable))
    XCTAssertTrue(service.canRetry)
    try service.retry()
    let next = try XCTUnwrap(service.confirmation)
    XCTAssertNotEqual(next.id, cancelledID)
    XCTAssertEqual(next.destination, "Actual Folder")
    XCTAssertTrue(next.possibleDuplicate)
    XCTAssertEqual(recorder.count, 1)
  }
}

private final class HTTPSCloseObservations: @unchecked Sendable {
  struct Snapshot {
    var descriptor: Int32?
    var attempts = 0
    var mode: Int?
    var sessions = 0
    var drains = 0
    var activeAtDrain: Int?
  }
  private let lock = NSLock()
  private let pool: RequestResourcePool
  private var value = Snapshot()
  init(pool: RequestResourcePool) { self.pool = pool }
  var snapshot: Snapshot { lock.withLock { value } }
  func effects(failClose: Bool = false, invalidateImmediately: Bool = false) -> HTTPSPDFFileEffects {
    HTTPSPDFFileEffects(acquired: { descriptor in
      self.lock.withLock { self.value.descriptor = descriptor }
    }, checkedClose: { handle in
      // Inspect only before checked close; FileHandle.fileDescriptor after close traps.
      var status = stat()
      let mode = Darwin.fstat(handle.fileDescriptor, &status) == 0 ? Int(status.st_mode & 0o777) : nil
      self.lock.withLock {
        self.value.attempts += 1
        self.value.mode = mode
      }
      if failClose { throw URLImportError.closureUnknown }
      try handle.close()
    }, sessionStarted: { session in
      self.lock.withLock { self.value.sessions += 1 }
      if invalidateImmediately { session.invalidateAndCancel() }
    }, finalNetworkDrain: {
      let active = self.pool.active
      self.lock.withLock {
        self.value.drains += 1
        self.value.activeAtDrain = active
      }
    })
  }
}

private final class GrantRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0
  var count: Int { lock.withLock { value } }
  func record() { lock.withLock { value += 1 } }
}

final class ImportFixtureProtocol: URLProtocol, @unchecked Sendable {
  final class State: @unchecked Sendable {
    private let lock = NSLock()
    private var started: Set<String> = []
    private var stopped: Set<String> = []
    func start(_ marker: String) { lock.withLock { _ = started.insert(marker) } }
    func stop(_ marker: String) { lock.withLock { _ = stopped.insert(marker) } }
    func hasStarted(_ marker: String) -> Bool { lock.withLock { started.contains(marker) } }
    func hasStopped(_ marker: String) -> Bool { lock.withLock { stopped.contains(marker) } }
  }
  static let state = State()
  override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "fixture.invalid" }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let url = request.url else { return }
    let fixture = url.pathComponents.dropFirst().first ?? "chunks"
    if fixture.hasPrefix("redirect") {
      let target: String
      switch fixture {
      case "redirect-http": target = "http://fixture.invalid/chunks"
      case "redirect-credential": target = "https://user:secret@fixture.invalid/chunks"
      case "redirect-loop": target = "/redirect-loop"
      default: target = "/chunks"
      }
      let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1",
        headerFields: ["Location": target])!
      client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: URL(string: target, relativeTo: url)!),
        redirectResponse: response)
      client?.urlProtocolDidFinishLoading(self)
      return
    }
    var headers = ["Content-Type": fixture == "mime" ? "text/html" : "application/pdf"]
    if fixture == "encoding" { headers["Content-Encoding"] = "gzip" }
    if fixture == "header-count" {
      for index in 0..<(try! ProviderRequest()).limit("headerCount") {
        headers["X-Fixture-\(index)"] = "value"
      }
    }
    if fixture == "header-bytes" {
      headers["X-Fixture"] = String(repeating: "x", count: (try! ProviderRequest()).limit("headerBytes") + 1)
    }
    let response = HTTPURLResponse(url: url, statusCode: fixture == "status" ? 404 : 200,
      httpVersion: "HTTP/1.1", headerFields: headers)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    if fixture == "stall" {
      client?.urlProtocol(self, didLoad: Data("%P".utf8))
      Self.state.start(url.lastPathComponent)
      return
    }
    if fixture == "exact-buffer" || fixture == "over-buffer" {
      let count = (try! ProviderRequest()).limit("readBufferBytes") + (fixture == "over-buffer" ? 1 : 0)
      var data = Data("%PDF-".utf8)
      data.append(Data(repeating: 32, count: count - data.count))
      client?.urlProtocol(self, didLoad: data)
    } else if fixture == "magic" {
      client?.urlProtocol(self, didLoad: Data("<html>not PDF".utf8))
    } else if fixture != "empty" {
      for text in ["%", "PD", "F-", "1.7\nfixture"] {
        client?.urlProtocol(self, didLoad: Data(text.utf8))
      }
    }
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {
    if let url = request.url, url.pathComponents.contains("stall") {
      Self.state.stop(url.lastPathComponent)
    }
  }
}
