import CryptoKit
import Darwin
import Foundation
import GRDB
import XCTest

@testable import PaperLensProduct

private enum LeasePurgeFailure: Error { case unavailable }
private enum SyntheticCloseFailure: Error { case refused }
private final class SyntheticCloseEffects: @unchecked Sendable {
  private let lock = NSLock()
  private var attempts = 0
  private let replacementDescriptor: Int32?
  init(replacementDescriptor: Int32? = nil) { self.replacementDescriptor = replacementDescriptor }
  var count: Int { lock.withLock { attempts } }
  func refuse(_ handle: FileHandle) throws {
    let attempt = lock.withLock { attempts += 1; return attempts }
    if let replacementDescriptor {
      // Atomically close the test-owned original and reuse only its owned numeric slot.
      // No free-FD window or unrelated target is overwritten by this fixture.
      if attempt == 1 {
        guard dup2(replacementDescriptor, handle.fileDescriptor) == handle.fileDescriptor else {
          throw SyntheticCloseFailure.refused
        }
      } else { _ = Darwin.close(handle.fileDescriptor) }
    }
    throw SyntheticCloseFailure.refused
  }
}
private actor LeaseAgentPurge: AgentLibraryPurging {
  let root: URL
  var failing = false
  var sagas: [UUID] = []
  init(root: URL) { self.root = root }
  func setFailing(_ value: Bool) { failing = value }
  func calls() -> [UUID] { sagas }
  func purgeLibraryPaper(paperID: UUID, deletionID: UUID) async throws -> AgentLibraryPurgeReceipt {
    sagas.append(deletionID)
    if failing { throw LeasePurgeFailure.unavailable }
    let owned = root.appendingPathComponent(paperID.uuidString)
    if FileManager.default.fileExists(atPath: owned.path) { try FileManager.default.removeItem(at: owned) }
    return AgentLibraryPurgeReceipt(paperID: paperID, deletionID: deletionID)
  }
}

@MainActor final class LibraryReadLeaseTests: XCTestCase {
  private func fixture() throws -> (URL, ProductDatabase, URL) {
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    let source = temporary.appendingPathComponent("synthetic.pdf")
    try Data("%PDF-1.7\nsynthetic lease fixture\n%%EOF\n".utf8).write(to: source)
    return (temporary, try ProductDatabase.open(at: temporary.appendingPathComponent("library")), source)
  }

  func testDeleteWaitsForActualLeaseCloseBeforeAgentAndPhysicalRemoval() async throws {
    let (temporary, db, source) = try fixture()
    defer { try? FileManager.default.removeItem(at: temporary) }
    let agent = LeaseAgentPurge(root: temporary.appendingPathComponent("agent"))
    let lifecycle = try await LocalLibraryLifecycle.open(database: db, agentPurge: agent)
    let id = try await lifecycle.importPDF(from: source)
    let snapshot = try db.readerSnapshot(paperID: id)
    let provider = LibraryReadLeaseProvider(lifecycle: lifecycle)
    var revoked = false
    let lease = try provider.acquireReadLease(for: snapshot) { revoked = true }
    let original = db.root.appendingPathComponent(snapshot.pdfReference)
    let deletion = Task { try await lifecycle.delete(paperID: id) }
    // The callback is a deterministic barrier: deletion has closed admission, but
    // this actual owner's document/session closure has deliberately not happened.
    for _ in 0..<10_000 where !revoked { await Task.yield() }
    XCTAssertTrue(revoked)
    XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
    let calls = await agent.calls()
    XCTAssertTrue(calls.isEmpty)
    XCTAssertThrowsError(try lease.validate())
    XCTAssertThrowsError(try provider.acquireReadLease(for: snapshot) {})
    lease.close()
    try await deletion.value
    XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
  }

  func testActualReaderReentrantDiscardDoesNotReleaseActiveSynchronousRead() async throws {
    let (temporary, db, source) = try fixture()
    defer { try? FileManager.default.removeItem(at: temporary) }
    let agent = LeaseAgentPurge(root: temporary.appendingPathComponent("agent"))
    let lifecycle = try await LocalLibraryLifecycle.open(database: db, agentPurge: agent)
    let id = try await lifecycle.importPDF(from: source)
    let snapshot = try db.readerSnapshot(paperID: id)
    let provider = LibraryReadLeaseProvider(lifecycle: lifecycle)
    let session = ReaderSession(database: db, leaseProvider: provider)
    var discards = 0
    var drainTask: Task<Void, any Error>?
    let drainCompleted = DispatchSemaphore(value: 0)
    _ = try session.open(paperID: id, validateDocument: { url in
      XCTAssertFalse(try Data(contentsOf: url).isEmpty)
      return 1
    }, discard: {
      discards += 1
      session.close() // Reentrant closure must not detach the active read pin.
      do {
        let late = try provider.acquireReadLease(for: snapshot) {}
        late.close()
        XCTFail("Revocation must reject reentrant admission")
      } catch {
        XCTAssertEqual(error as? ReaderError, .revoked)
      }
    })
    let registry = lifecycle.readLeaseRegistry
    XCTAssertThrowsError(try session.withReadAccess {
      let callbacks = registry.revoke(id)
      for callback in callbacks { callback() }
      XCTAssertNil(session.currentPaper)
      XCTAssertEqual(discards, 1)
      drainTask = Task.detached {
        try await registry.drain(id)
        drainCompleted.signal()
      }
      XCTAssertEqual(drainCompleted.wait(timeout: .now() + 0.05), .timedOut)
      // The original is still physically available inside the already admitted read.
      XCTAssertFalse(try Data(contentsOf: db.root.appendingPathComponent(snapshot.pdfReference)).isEmpty)
    }) { XCTAssertEqual($0 as? ReaderError, .revoked) }
    try await drainTask?.value
    try await lifecycle.delete(paperID: id)
    XCTAssertEqual(discards, 1)
    XCTAssertFalse(FileManager.default.fileExists(atPath: db.root.appendingPathComponent(snapshot.pdfReference).path))
  }

  func testReservedAdmissionRacingDeletionCannotInstallUsableLease() async throws {
    let (temporary, db, source) = try fixture()
    defer { try? FileManager.default.removeItem(at: temporary) }
    let lifecycle = try await LocalLibraryLifecycle.open(database: db)
    let id = try await lifecycle.importPDF(from: source)
    let snapshot = try db.readerSnapshot(paperID: id)
    let registry = lifecycle.readLeaseRegistry
    var revoked = false
    let token = try registry.reserve(snapshot) { revoked = true }
    let handle = try FileHandle(forReadingFrom: db.root.appendingPathComponent(snapshot.pdfReference))
    for callback in registry.revoke(id) { callback() }
    XCTAssertTrue(revoked)
    XCTAssertThrowsError(try registry.reserve(snapshot) {})
    XCTAssertThrowsError(try registry.install(handle, token: token))
    XCTAssertThrowsError(try registry.beginRead(token))
    try await registry.drain(id)
    // Producerless/Agentless deletion remains a durable failure, not a receipt.
    do { try await lifecycle.delete(paperID: id); XCTFail("Missing Agent must fail") }
    catch { XCTAssertEqual(error as? LocalLibraryError, .agentPurgeUnavailable) }
    XCTAssertThrowsError(try LibraryReadLeaseProvider(lifecycle: lifecycle).acquireReadLease(for: snapshot) {})
    XCTAssertTrue(FileManager.default.fileExists(atPath: db.root.appendingPathComponent(snapshot.pdfReference).path))
  }

  func testUnknownPhysicalClosureFailsDrainAndRetainsOriginal() async throws {
    let (temporary, db, source) = try fixture()
    defer { try? FileManager.default.removeItem(at: temporary) }
    let lifecycle = try await LocalLibraryLifecycle.open(database: db)
    let id = try await lifecycle.importPDF(from: source)
    let snapshot = try db.readerSnapshot(paperID: id)
    let effects = SyntheticCloseEffects()
    let registry = LibraryReadLeaseRegistry(closeHandle: { try effects.refuse($0) })
    let token = try registry.reserve(snapshot) {}
    let descriptor = Darwin.open(db.root.appendingPathComponent(snapshot.pdfReference).path,
      O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    XCTAssertGreaterThanOrEqual(descriptor, 0)
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    try registry.install(handle, token: token)
    // Foundation accepts closing an already-closed descriptor on this platform.
    // Inject failure BEFORE closing, so the actual descriptor stays live.
    registry.close(token)
    XCTAssertGreaterThanOrEqual(fcntl(descriptor, F_GETFD), 0)
    do { try await registry.drain(id); XCTFail("Unknown close must retain debt") }
    catch { XCTAssertEqual(error as? LocalLibraryError, .producerClosureUnknown) }
    registry.retryClosures(id)
    registry.close(token)
    XCTAssertEqual(effects.count, 1, "Uncertainty prohibits retrying the physical effect")
    XCTAssertTrue(FileManager.default.fileExists(atPath: db.root.appendingPathComponent(snapshot.pdfReference).path))
    try handle.close() // Test-owned remediation does not erase registry debt.
    do { try await registry.drain(id); XCTFail("External close cannot certify registry drain") }
    catch { XCTAssertEqual(error as? LocalLibraryError, .producerClosureUnknown) }
    XCTAssertEqual(fcntl(descriptor, F_GETFD), -1)
    XCTAssertEqual(errno, EBADF)
  }

  func testUncertainCloseCannotCloseAReusedReadOnlyDescriptor() async throws {
    let (temporary, db, source) = try fixture()
    defer { try? FileManager.default.removeItem(at: temporary) }
    let lifecycle = try await LocalLibraryLifecycle.open(database: db)
    let id = try await lifecycle.importPDF(from: source)
    let snapshot = try db.readerSnapshot(paperID: id)
    let canary = temporary.appendingPathComponent("unrelated-owned-fixture")
    let canaryBytes = Data("unrelated read-only descriptor must survive".utf8)
    try canaryBytes.write(to: canary)
    let replacement = try FileHandle(forReadingFrom: canary)
    defer { try? replacement.close() }
    let descriptor = Darwin.open(db.root.appendingPathComponent(snapshot.pdfReference).path,
      O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw SyntheticCloseFailure.refused }
    defer { _ = Darwin.close(descriptor) }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
    let effects = SyntheticCloseEffects(replacementDescriptor: replacement.fileDescriptor)
    let registry = LibraryReadLeaseRegistry(closeHandle: { try effects.refuse($0) })
    let token = try registry.reserve(snapshot) {}
    try registry.install(handle, token: token)
    try registry.beginRead(token)
    registry.close(token)
    XCTAssertEqual(effects.count, 0, "An active read still owns the original descriptor")
    registry.endRead(token) // The injected uncertain close atomically reuses its numeric FD.
    XCTAssertEqual(effects.count, 1)
    for _ in 0..<3 { registry.retryClosures(id); registry.close(token) }
    XCTAssertEqual(effects.count, 1)
    XCTAssertEqual(fcntl(descriptor, F_GETFL) & O_ACCMODE, O_RDONLY)
    XCTAssertGreaterThanOrEqual(fcntl(descriptor, F_GETFD), 0)
    let borrowed = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
    XCTAssertEqual(try borrowed.readToEnd(), canaryBytes)
    XCTAssertEqual(try Data(contentsOf: canary), canaryBytes)
    do { try await registry.drain(id); XCTFail("Reused FD does not prove original closure") }
    catch { XCTAssertEqual(error as? LocalLibraryError, .producerClosureUnknown) }
    XCTAssertThrowsError(try registry.validate(token))
  }

  func testFailedDeletionRetryKeepsSameSagaAndNeverReopensAdmission() async throws {
    let (temporary, db, source) = try fixture()
    defer { try? FileManager.default.removeItem(at: temporary) }
    let agent = LeaseAgentPurge(root: temporary.appendingPathComponent("agent"))
    await agent.setFailing(true)
    let lifecycle = try await LocalLibraryLifecycle.open(database: db, agentPurge: agent)
    let id = try await lifecycle.importPDF(from: source)
    let snapshot = try db.readerSnapshot(paperID: id)
    let provider = LibraryReadLeaseProvider(lifecycle: lifecycle)
    var lease: (any ReaderReadLease)?
    lease = try provider.acquireReadLease(for: snapshot) { lease?.close() }
    do { try await lifecycle.delete(paperID: id); XCTFail("Actual purge failure must propagate") }
    catch { XCTAssertTrue(error is LeasePurgeFailure) }
    XCTAssertThrowsError(try provider.acquireReadLease(for: snapshot) {})
    await agent.setFailing(false)
    try await lifecycle.retryDeletion(paperID: id)
    let sagas = await agent.calls()
    XCTAssertEqual(sagas.count, 2)
    XCTAssertEqual(sagas.first, sagas.last)
  }

  func testExactSnapshotIdentityNotContentHashAdmitsOriginal() async throws {
    let (temporary, db, source) = try fixture()
    defer { try? FileManager.default.removeItem(at: temporary) }
    let lifecycle = try await LocalLibraryLifecycle.open(database: db)
    let id = try await lifecycle.importPDF(from: source)
    let snapshot = try db.readerSnapshot(paperID: id)
    let provider = LibraryReadLeaseProvider(lifecycle: lifecycle)
    let foreign = ReaderPaperSnapshot(paperID: id, generation: UUID(),
      pdfReference: snapshot.pdfReference, title: snapshot.title)
    XCTAssertThrowsError(try provider.acquireReadLease(for: foreign) {})
    let wrongReference = ReaderPaperSnapshot(paperID: id, generation: snapshot.generation,
      pdfReference: "../synthetic.pdf", title: snapshot.title)
    XCTAssertThrowsError(try provider.acquireReadLease(for: wrongReference) {})
    let lease = try provider.acquireReadLease(for: snapshot) {}
    try lease.validate()
    lease.close()
  }

  func testConfirmationDigestChecksCopiedBytesAndNeverPublishesMismatch() async throws {
    let (temporary, db, source) = try fixture()
    defer { try? FileManager.default.removeItem(at: temporary) }
    let lifecycle = try await LocalLibraryLifecycle.open(database: db)
    let folder = try db.createFolder(name: "Confirmed")
    let confirmed = SHA256.hash(data: try Data(contentsOf: source)).map { String(format: "%02x", $0) }.joined()
    try Data("%PDF-1.7\nchanged after confirmation\n%%EOF\n".utf8).write(to: source)
    let rejected = try await lifecycle.importPDF(from: source, expectedSHA256: confirmed,
      destinationFolderID: folder.id)
    let records = try await lifecycle.list()
    XCTAssertEqual(records.first(where: { $0.id == rejected })?.status, .importFailed)
    XCTAssertEqual(records.first(where: { $0.id == rejected })?.failure, "sourceChanged")
    XCTAssertThrowsError(try db.readerSnapshot(paperID: rejected))
    XCTAssertNil(try db.folderID(for: rejected))
    XCTAssertFalse(FileManager.default.fileExists(atPath: db.root.appendingPathComponent("papers/\(rejected.uuidString)").path))
    let exact = SHA256.hash(data: try Data(contentsOf: source)).map { String(format: "%02x", $0) }.joined()
    let accepted = try await lifecycle.importPDF(from: source, expectedSHA256: exact,
      destinationFolderID: folder.id)
    XCTAssertEqual(try db.readerSnapshot(paperID: accepted).paperID, accepted)
    XCTAssertEqual(try db.folderID(for: accepted), folder.id)
    let normal = try await lifecycle.importPDF(from: source)
    XCTAssertEqual(try db.readerSnapshot(paperID: normal).paperID, normal)
  }
}
