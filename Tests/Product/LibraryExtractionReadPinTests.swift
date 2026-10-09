import Darwin
import Foundation
import XCTest

@testable import PaperLensProduct

private enum PinFixtureFailure: Error { case close, duplicate }

private final class PinEffects: @unchecked Sendable {
  private let lock = NSLock()
  private var attempts = 0
  var count: Int { lock.withLock { attempts } }
  func refuse(_ handle: FileHandle) throws {
    lock.withLock { attempts += 1 }
    throw PinFixtureFailure.close
  }
}

private final class PinRegistryBox: @unchecked Sendable {
  var registry: LibraryReadLeaseRegistry!
  var token: UUID!
  var sender: FileHandle?
}

@MainActor final class LibraryExtractionReadPinTests: XCTestCase {
  private func fixture() async throws -> (URL, ProductDatabase, LocalLibraryLifecycle, ReaderPaperSnapshot) {
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    let source = temporary.appendingPathComponent("synthetic.pdf")
    try Data("%PDF-1.7\nowned extraction pin fixture\n%%EOF\n".utf8).write(to: source)
    let database = try ProductDatabase.open(at: temporary.appendingPathComponent("library"))
    let lifecycle = try await LocalLibraryLifecycle.open(database: database)
    let paperID = try await lifecycle.importPDF(from: source)
    return (temporary, database, lifecycle, try database.readerSnapshot(paperID: paperID))
  }

  func testActualReadonlySenderTransfersOnceAndWrongOperationDoesNothing() async throws {
    let (temporary, database, lifecycle, snapshot) = try await fixture()
    defer { try? FileManager.default.removeItem(at: temporary) }
    let operationID = UUID()
    let pin = try LibraryReadLeaseProvider(lifecycle: lifecycle).acquireExtractionReadPin(
      for: snapshot, operationID: operationID, onRevoked: {})
    do { try await pin.release(operationID: UUID()); XCTFail("Wrong operation released pin") }
    catch { XCTAssertEqual(error as? LibraryExtractionPinError, .wrongOperation) }
    try pin.validate()
    let sender = try pin.takeSenderPDF()
    XCTAssertEqual(fcntl(sender.fileDescriptor, F_GETFL) & O_ACCMODE, O_RDONLY)
    XCTAssertNotEqual(fcntl(sender.fileDescriptor, F_GETFD) & FD_CLOEXEC, 0)
    XCTAssertEqual(try sender.readToEnd(), try Data(contentsOf:
      database.root.appendingPathComponent(snapshot.pdfReference)))
    XCTAssertThrowsError(try pin.takeSenderPDF()) {
      XCTAssertEqual($0 as? LibraryExtractionPinError, .senderAlreadyTaken)
    }
    try sender.close() // Actual producer disposal, not a caller-declared closed flag.
    try await pin.release(operationID: operationID)
    try await pin.release(operationID: operationID)
    XCTAssertThrowsError(try pin.validate())
    XCTAssertThrowsError(try pin.takeSenderPDF())
  }

  func testChildReleaseDoesNotWaitForOrCloseOrdinaryReader() async throws {
    let (temporary, _, lifecycle, snapshot) = try await fixture()
    defer { try? FileManager.default.removeItem(at: temporary) }
    let provider = LibraryReadLeaseProvider(lifecycle: lifecycle)
    let reader = try provider.acquireReadLease(for: snapshot, onRevoked: {})
    let pin = try provider.acquireExtractionReadPin(for: snapshot, operationID: UUID(), onRevoked: {})
    try await pin.release(operationID: pin.operationID)
    try reader.validate()
    try reader.withReadAccess { try reader.validate() }
    reader.close()
    try await lifecycle.readLeaseRegistry.drain(snapshot.paperID)
  }

  func testDeleteRevokesButWaitsForActualChildRelease() async throws {
    let (temporary, database, lifecycle, snapshot) = try await fixture()
    defer { try? FileManager.default.removeItem(at: temporary) }
    let revoked = XCTestExpectation(description: "Actual deletion revokes child admission")
    let pin = try LibraryReadLeaseProvider(lifecycle: lifecycle).acquireExtractionReadPin(
      for: snapshot, operationID: UUID(), onRevoked: { revoked.fulfill() })
    let sender = try pin.takeSenderPDF()
    let deletion = Task { try await lifecycle.delete(paperID: snapshot.paperID) }
    let outcome = await XCTWaiter.fulfillment(of: [revoked], timeout: 5)
    guard outcome == .completed else {
      deletion.cancel()
      try sender.close()
      try await pin.release(operationID: pin.operationID)
      XCTFail("Deletion never reached its actual revoke callback")
      throw PinFixtureFailure.close
    }
    let original = database.root.appendingPathComponent(snapshot.pdfReference)
    XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
    XCTAssertThrowsError(try pin.validate())
    XCTAssertThrowsError(try pin.takeSenderPDF())
    XCTAssertThrowsError(try LibraryReadLeaseProvider(lifecycle: lifecycle).acquireExtractionReadPin(
      for: snapshot, operationID: UUID(), onRevoked: {}))
    XCTAssertFalse(try XCTUnwrap(sender.readToEnd()).isEmpty)
    try sender.close()
    try await pin.release(operationID: pin.operationID)
    do { try await deletion.value; XCTFail("Missing Agent cannot certify complete deletion") }
    catch { XCTAssertEqual(error as? LocalLibraryError, .agentPurgeUnavailable) }
    try await lifecycle.readLeaseRegistry.drain(snapshot.paperID)
    let record = try XCTUnwrap(database.libraryRecords().first { $0.id == snapshot.paperID })
    XCTAssertEqual(record.status, .deletionFailed)
    XCTAssertTrue(record.cleanupDebt)
    XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
  }

  func testReleaseDuringRealDuplicationRejectsLateTransferAndJoinsClose() async throws {
    let (temporary, database, _, snapshot) = try await fixture()
    defer { try? FileManager.default.removeItem(at: temporary) }
    let original = try FileHandle(forReadingFrom: database.root.appendingPathComponent(snapshot.pdfReference))
    let box = PinRegistryBox()
    defer { box.registry = nil }
    let entered = DispatchSemaphore(value: 0)
    let proceed = DispatchSemaphore(value: 0)
    // Bounded barriers hold an actual active read while release requests closure.
    box.registry = LibraryReadLeaseRegistry(closeHandle: { handle in
      try handle.close()
    }, duplicateHandle: { handle in
      entered.signal()
      guard proceed.wait(timeout: .now() + 5) == .success else {
        throw PinFixtureFailure.duplicate
      }
      XCTAssertGreaterThanOrEqual(fcntl(handle.fileDescriptor, F_GETFD), 0)
      let descriptor = fcntl(handle.fileDescriptor, F_DUPFD_CLOEXEC, 0)
      guard descriptor >= 0 else { throw PinFixtureFailure.duplicate }
      return FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
    })
    box.token = try box.registry.reserve(snapshot, revoke: {})
    try box.registry.install(original, token: box.token)
    let pin = LibraryExtractionReadPin(operationID: UUID(), registry: box.registry, token: box.token)
    let duplication = Task.detached { try pin.takeSenderPDF() }
    XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
    box.registry.close(box.token) // Exact release linearization, before opening the barrier.
    XCTAssertGreaterThanOrEqual(fcntl(original.fileDescriptor, F_GETFD), 0)
    async let first: Void = pin.release(operationID: pin.operationID)
    async let second: Void = pin.release(operationID: pin.operationID)
    proceed.signal()
    do { _ = try await duplication.value; XCTFail("Late transfer survived release") }
    catch { XCTAssertEqual(error as? ReaderError, .revoked) }
    _ = try await (first, second)
    try await box.registry.drain(snapshot.paperID)
  }

  func testRejectedDuplicateCleanupFailureRetainsBothDescriptorsAndNoRetry() async throws {
    let (temporary, database, _, snapshot) = try await fixture()
    defer { try? FileManager.default.removeItem(at: temporary) }
    let original = try FileHandle(forReadingFrom: database.root.appendingPathComponent(snapshot.pdfReference))
    defer { try? original.close() }
    let box = PinRegistryBox()
    defer { box.registry = nil }
    let effects = PinEffects()
    box.registry = LibraryReadLeaseRegistry(closeHandle: { try effects.refuse($0) },
      duplicateHandle: { handle in
        let descriptor = fcntl(handle.fileDescriptor, F_DUPFD_CLOEXEC, 0)
        guard descriptor >= 0 else { throw PinFixtureFailure.duplicate }
        let sender = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        box.sender = sender
        box.registry.close(box.token)
        return sender
      })
    defer { try? box.sender?.close() } // Fixture disposal, not registry retry.
    box.token = try box.registry.reserve(snapshot, revoke: {})
    try box.registry.install(original, token: box.token)
    let pin = LibraryExtractionReadPin(operationID: UUID(), registry: box.registry, token: box.token)
    XCTAssertThrowsError(try pin.takeSenderPDF()) {
      XCTAssertEqual($0 as? LocalLibraryError, .producerClosureUnknown)
    }
    for _ in 0..<3 {
      do { try await pin.release(operationID: pin.operationID); XCTFail("Cleanup debt succeeded") }
      catch { XCTAssertEqual(error as? LocalLibraryError, .producerClosureUnknown) }
      box.registry.retryClosures(snapshot.paperID)
    }
    XCTAssertEqual(effects.count, 1)
    XCTAssertGreaterThanOrEqual(fcntl(original.fileDescriptor, F_GETFD), 0)
    XCTAssertGreaterThanOrEqual(fcntl(try XCTUnwrap(box.sender).fileDescriptor, F_GETFD), 0)
  }

  func testDuplicationFailureDoesNotLoseOriginalAndReentrantCloseJoins() async throws {
    let (temporary, database, _, snapshot) = try await fixture()
    defer { try? FileManager.default.removeItem(at: temporary) }
    let original = try FileHandle(forReadingFrom: database.root.appendingPathComponent(snapshot.pdfReference))
    let box = PinRegistryBox()
    defer { box.registry = nil }
    box.registry = LibraryReadLeaseRegistry(closeHandle: { handle in
      box.registry.close(box.token) // Reentrant request cannot repeat a physical effect.
      try handle.close()
    }, duplicateHandle: { _ in throw PinFixtureFailure.duplicate })
    box.token = try box.registry.reserve(snapshot, revoke: {})
    try box.registry.install(original, token: box.token)
    let pin = LibraryExtractionReadPin(operationID: UUID(), registry: box.registry, token: box.token)
    XCTAssertThrowsError(try pin.takeSenderPDF())
    try pin.validate()
    XCTAssertGreaterThanOrEqual(fcntl(original.fileDescriptor, F_GETFD), 0)
    XCTAssertThrowsError(try pin.takeSenderPDF()) {
      XCTAssertEqual($0 as? LibraryExtractionPinError, .senderAlreadyTaken)
    }
    try await pin.release(operationID: pin.operationID)
    try await pin.release(operationID: pin.operationID)
    try await box.registry.drain(snapshot.paperID)
  }

  func testUnknownCloseIsPermanentOwnTokenFailureAndNeverRetried() async throws {
    let (temporary, database, _, snapshot) = try await fixture()
    defer { try? FileManager.default.removeItem(at: temporary) }
    let descriptor = Darwin.open(database.root.appendingPathComponent(snapshot.pdfReference).path,
      O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else { throw PinFixtureFailure.duplicate }
    defer { _ = Darwin.close(descriptor) } // Explicit fixture-owned cleanup only.
    let original = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
    let effects = PinEffects()
    let registry = LibraryReadLeaseRegistry(closeHandle: { try effects.refuse($0) })
    let token = try registry.reserve(snapshot, revoke: {})
    try registry.install(original, token: token)
    let pin = LibraryExtractionReadPin(operationID: UUID(), registry: registry, token: token)
    for _ in 0..<3 {
      do { try await pin.release(operationID: pin.operationID); XCTFail("Unknown closure succeeded") }
      catch { XCTAssertEqual(error as? LocalLibraryError, .producerClosureUnknown) }
      registry.retryClosures(snapshot.paperID)
    }
    XCTAssertEqual(effects.count, 1)
    XCTAssertGreaterThanOrEqual(fcntl(descriptor, F_GETFD), 0)
    do { try await registry.drain(snapshot.paperID); XCTFail("Unknown closure drained") }
    catch { XCTAssertEqual(error as? LocalLibraryError, .producerClosureUnknown) }
  }

  func testSnapshotGenerationAndReferenceMustMatchDurableReadyPaper() async throws {
    let (temporary, _, lifecycle, snapshot) = try await fixture()
    defer { try? FileManager.default.removeItem(at: temporary) }
    let provider = LibraryReadLeaseProvider(lifecycle: lifecycle)
    let foreign = ReaderPaperSnapshot(paperID: snapshot.paperID, generation: UUID(),
      pdfReference: snapshot.pdfReference, title: snapshot.title)
    XCTAssertThrowsError(try provider.acquireExtractionReadPin(
      for: foreign, operationID: UUID(), onRevoked: {}))
    let invalid = ReaderPaperSnapshot(paperID: snapshot.paperID, generation: snapshot.generation,
      pdfReference: "../synthetic.pdf", title: snapshot.title)
    XCTAssertThrowsError(try provider.acquireExtractionReadPin(
      for: invalid, operationID: UUID(), onRevoked: {}))
    try await lifecycle.readLeaseRegistry.drain(snapshot.paperID)
  }
}
