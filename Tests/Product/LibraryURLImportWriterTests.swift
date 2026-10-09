import Foundation
import GRDB
import ProviderRequest
import XCTest
@testable import PaperLensProduct

final class LibraryURLImportWriterTests: XCTestCase, @unchecked Sendable {
  private func database() throws -> ProductDatabase {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let database = try ProductDatabase.open(at: root)
    addTeardownBlock { try FileManager.default.removeItem(at: root) }
    return database
  }

  @MainActor
  private func continued(folder: UUID? = nil) async throws -> URLImportConfirmation {
    let box = URLConfirmationBox()
    let service = URLImportService(authority: try ProviderRequest(), grantWriter: { intent in
      box.store(intent)
      throw URLImportError.writerUnavailable
    })
    try service.prepare("https://writer.invalid/pdf", destination: "Not a UUID",
      possibleDuplicate: false, destinationFolderID: folder)
    service.continueImport(confirmationID: try XCTUnwrap(service.confirmation).id)
    while service.state == .downloading { await Task.yield() }
    return try XCTUnwrap(box.value)
  }

  private func stage(_ writer: any URLImportWriter, stall: Bool = false) async throws -> ClosedHTTPSPDFStage {
    let adapter = HTTPSPDFImportAdapter(authority: try ProviderRequest())
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [URLWriterFixture.self]
    return try await adapter.download(route: adapter.route("https://writer.invalid/" + (stall ? "stall" : "pdf")),
      stagingDirectory: writer.stagingDirectory, assertCurrent: { try writer.assertCurrent() },
      configuration: configuration)
  }

  @MainActor
  func testPrepareCancelAndUnconsumedFactoryCannotReserve() async throws {
    let db = try database()
    let lifecycle = try await LocalLibraryLifecycle.open(database: db)
    let service = URLImportService(authority: try ProviderRequest())
    try service.prepare("https://writer.invalid/pdf", destination: "Library", possibleDuplicate: false)
    let intent = try XCTUnwrap(service.confirmation)
    do { _ = try await lifecycle.grantURLImportWriter(for: intent); XCTFail("prepared intent granted") }
    catch { XCTAssertEqual(error as? URLImportError, .writerUnavailable) }
    service.cancelConfirmation()
    do { _ = try await lifecycle.grantURLImportWriter(for: intent); XCTFail("cancelled intent granted") }
    catch { XCTAssertEqual(error as? URLImportError, .writerUnavailable) }
    XCTAssertTrue(try db.libraryRecords().isEmpty)
  }

  func testOneReservedIdentityPublishesRealClosedStageIntoConfirmedFolder() async throws {
    let db = try database()
    let folder = try db.createFolder(name: "Confirmed")
    let lifecycle = try await LocalLibraryLifecycle.open(database: db)
    let intent = try await continued(folder: folder.id)
    let writer = try await lifecycle.grantURLImportWriter(for: intent)
    let reserved = try XCTUnwrap(db.libraryRecords().first)
    let job = try db.adapterRead { try Row.fetchOne($0, sql: "SELECT * FROM importJob") }
    XCTAssertEqual(try db.adapterRead { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM importJob") }, 1)
    do { _ = try await lifecycle.grantURLImportWriter(for: intent); XCTFail("intent granted twice") }
    catch { XCTAssertEqual(error as? URLImportError, .writerUnavailable) }
    let closed = try await stage(writer)
    let id = try await writer.publish(closed)
    XCTAssertEqual(id, reserved.id)
    XCTAssertEqual(try db.folderID(for: id), folder.id)
    XCTAssertEqual(try db.libraryRecords().map(\.status), [.ready])
    XCTAssertEqual(try db.adapterRead {
      try String.fetchOne($0, sql: "SELECT pdfSHA256 FROM paper WHERE id = ?",
        arguments: [id.uuidString])
    }, closed.sha256)
    XCTAssertEqual(try db.libraryRecords().first?.title, "HTTPS PDF")
    let published = try db.adapterRead { try Row.fetchOne($0, sql: "SELECT * FROM importJob") }
    for key in ["id", "paperID", "attempt", "fence", "correlation", "input", "epoch", "writer", "publication"] {
      let before: String? = job?[key], after: String? = published?[key]
      XCTAssertEqual(before, after, key)
    }
    let final = writer.stagingDirectory.appendingPathComponent("document.pdf")
    XCTAssertEqual(try Data(contentsOf: final), URLWriterFixture.bytes)
    let attributes = try FileManager.default.attributesOfItem(atPath: final.path)
    XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o400)
    XCTAssertFalse(FileManager.default.fileExists(atPath: closed.file.path))
    do { _ = try await writer.publish(closed); XCTFail("stage published twice") }
    catch { XCTAssertEqual(error as? URLImportError, .writerUnavailable) }
    writer.revoke()
    try await writer.abort(reason: .cancelled)
    XCTAssertEqual(try Data(contentsOf: final), URLWriterFixture.bytes)
  }

  func testChangedOwnedBytesRejectedAndClosedCleanupDoesNotCreateSecondJob() async throws {
    let db = try database()
    let lifecycle = try await LocalLibraryLifecycle.open(database: db)
    let writer = try await lifecycle.grantURLImportWriter(for: continued())
    let closed = try await stage(writer)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: closed.file.path)
    try Data("%PDF-1.7\nchanged".utf8).write(to: closed.file)
    try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: closed.file.path)
    do { _ = try await writer.publish(closed); XCTFail("changed immutable bytes accepted") }
    catch { XCTAssertEqual(error as? URLImportError, .rejected) }
    writer.revoke()
    try await writer.abort(reason: .rejected)
    try await writer.abort(reason: .rejected)
    XCTAssertEqual(try db.libraryRecords().map(\.status), [.importFailed])
    XCTAssertEqual(try db.adapterRead { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM importJob") }, 1)
    XCTAssertFalse(FileManager.default.fileExists(atPath: writer.stagingDirectory.path))
  }

  func testForeignClosedStageCannotPublishIntoAnotherReservedNamespace() async throws {
    let db = try database()
    let lifecycle = try await LocalLibraryLifecycle.open(database: db)
    let first = try await lifecycle.grantURLImportWriter(for: continued())
    let second = try await lifecycle.grantURLImportWriter(for: continued())
    let closed = try await stage(first)
    do { _ = try await second.publish(closed); XCTFail("foreign stage accepted") }
    catch { XCTAssertEqual(error as? URLImportError, .rejected) }
    try await second.abort(reason: .rejected)
    XCTAssertTrue(FileManager.default.fileExists(atPath: closed.file.path))
    _ = try await first.publish(closed)
    XCTAssertEqual(try db.libraryRecords().filter { $0.status == .ready }.count, 1)
  }

  func testRemovedConfirmedFolderRejectsPublicationAndCleansClosedStage() async throws {
    let db = try database()
    let folder = try db.createFolder(name: "Removed")
    let lifecycle = try await LocalLibraryLifecycle.open(database: db)
    let writer = try await lifecycle.grantURLImportWriter(for: continued(folder: folder.id))
    let closed = try await stage(writer)
    try db.deleteFolder(id: folder.id)
    do { _ = try await writer.publish(closed); XCTFail("removed folder accepted") } catch {}
    try await writer.abort(reason: .rejected)
    XCTAssertEqual(try db.libraryRecords().map(\.status), [.importFailed])
    XCTAssertFalse(FileManager.default.fileExists(atPath: writer.stagingDirectory.path))
  }

  func testUnknownClosureRetainsDebtAndRetryDeletionUsesSameSaga() async throws {
    let db = try database()
    let agent = URLWriterAgent(root: db.root.appendingPathComponent("agent"))
    let lifecycle = try await LocalLibraryLifecycle.open(database: db, agentPurge: agent)
    let writer = try await lifecycle.grantURLImportWriter(for: continued())
    let closed = try await stage(writer)
    let id = try XCTUnwrap(db.libraryRecords().first).id
    // A conservative typed unknown report must not be upgraded merely because a
    // terminal failure was received. No synthetic successful stage is constructed.
    try await writer.abort(reason: .closureUnknown)
    XCTAssertTrue(try XCTUnwrap(db.libraryRecords().first).cleanupDebt)
    for _ in 0..<2 {
      do { try await lifecycle.delete(paperID: id); XCTFail("unknown closure purged") } catch {}
      XCTAssertTrue(FileManager.default.fileExists(atPath: closed.file.path))
    }
    let sagas = await agent.sagas()
    XCTAssertEqual(sagas.count, 2)
    XCTAssertEqual(sagas.first, sagas.last)
    XCTAssertEqual(try db.libraryRecords().map(\.status), [.deletionFailed])
  }

  @MainActor
  func testDeletionCancelsActualTransportButWaitsForAbortAfterDrain() async throws {
    let db = try database()
    let lifecycle = try await LocalLibraryLifecycle.open(database: db)
    let writer = try await lifecycle.grantURLImportWriter(for: continued())
    let actual = try XCTUnwrap(writer as? LibraryURLImportWriter)
    let download = Task { try await stage(writer, stall: true) }
    try actual.bindDownload(download)
    for _ in 0..<300 {
      if URLWriterFixture.state.started { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertTrue(URLWriterFixture.state.started)
    let id = actual.identity.paperID
    let deletion = Task { try await lifecycle.delete(paperID: id) }
    do { _ = try await download.value; XCTFail("revoked network completed") } catch {}
    XCTAssertTrue(URLWriterFixture.state.stopped)
    // Namespace still exists: transport cancellation/drain alone cannot release census.
    XCTAssertTrue(FileManager.default.fileExists(atPath: writer.stagingDirectory.path))
    try await writer.abort(reason: .cancelled)
    do { try await deletion.value; XCTFail("missing Agent reported success") }
    catch { XCTAssertEqual(error as? LocalLibraryError, .agentPurgeUnavailable) }
    XCTAssertEqual(try db.libraryRecords().map(\.status), [.deletionFailed])
    do { try writer.assertCurrent(); XCTFail("revoked capability current") } catch {}
  }

  func testPriorRevocationCancelsNewlyBoundRealTask() async throws {
    let db = try database()
    let lifecycle = try await LocalLibraryLifecycle.open(database: db)
    let writer = try await lifecycle.grantURLImportWriter(for: continued())
    let actual = try XCTUnwrap(writer as? LibraryURLImportWriter)
    writer.revoke()
    let download = Task { try await stage(writer) }
    try actual.bindDownload(download)
    do { _ = try await download.value; XCTFail("prior revocation ignored") } catch {}
    try await writer.abort(reason: .cancelled)
    XCTAssertFalse(FileManager.default.fileExists(atPath: writer.stagingDirectory.path))
  }
}

private final class URLConfirmationBox: @unchecked Sendable {
  private let lock = NSLock()
  private var intent: URLImportConfirmation?
  var value: URLImportConfirmation? { lock.withLock { intent } }
  func store(_ intent: URLImportConfirmation) { lock.withLock { self.intent = intent } }
}

private actor URLWriterAgent: AgentLibraryPurging {
  let root: URL
  private var invocations: [UUID] = []
  init(root: URL) { self.root = root }
  func sagas() -> [UUID] { invocations }
  func purgeLibraryPaper(paperID: UUID, deletionID: UUID) async throws -> AgentLibraryPurgeReceipt {
    invocations.append(deletionID)
    let owned = root.appendingPathComponent(paperID.uuidString)
    if FileManager.default.fileExists(atPath: owned.path) { try FileManager.default.removeItem(at: owned) }
    guard !FileManager.default.fileExists(atPath: owned.path) else { throw URLImportError.cleanupFailed }
    return AgentLibraryPurgeReceipt(paperID: paperID, deletionID: deletionID)
  }
}

private final class URLWriterFixture: URLProtocol, @unchecked Sendable {
  static let bytes = Data("%PDF-1.7\nfixture".utf8)
  final class State: @unchecked Sendable {
    private let lock = NSLock()
    private var didStart = false
    private var didStop = false
    var started: Bool { lock.withLock { didStart } }
    var stopped: Bool { lock.withLock { didStop } }
    func start() { lock.withLock { didStart = true; didStop = false } }
    func stop() { lock.withLock { didStop = true } }
  }
  static let state = State()
  override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "writer.invalid" }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    guard let url = request.url else { return }
    if url.path == "/stall" { Self.state.start(); return }
    let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
      headerFields: ["Content-Type": "application/pdf"])!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Self.bytes)
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() { if request.url?.path == "/stall" { Self.state.stop() } }
}
