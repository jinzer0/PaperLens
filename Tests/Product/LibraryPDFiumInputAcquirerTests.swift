import Darwin
import Foundation
import GRDB
import ProviderRequest
import XCTest
@testable import PaperLensProduct

/// Owned synthetic Library files and real GRDB/pool only; never starts PDFium or a renderer.
@MainActor final class LibraryPDFiumInputAcquirerTests: XCTestCase {
  private enum FixtureError: Error { case constructor, close }
  private struct Fixture: Sendable {
    let temporary: URL
    let database: ProductDatabase
    let lifecycle: LocalLibraryLifecycle
    let snapshot: ReaderPaperSnapshot
    let identity: ExtractionIdentity
  }
  private final class Effects: @unchecked Sendable {
    private let lock = NSLock()
    private var time = DispatchTime.now().uptimeNanoseconds
    private var retained: FileHandle?
    private var closes = 0
    func clock() -> UInt64 { lock.withLock { time } }
    func expire(_ deadline: UInt64) { lock.withLock { time = deadline } }
    func remember(_ sender: FileHandle) { lock.withLock { retained = sender } }
    func sender() -> FileHandle? { lock.withLock { retained } }
    func forgetSender() { lock.withLock { retained = nil } }
    func refuseClose(_ sender: FileHandle) throws {
      lock.withLock { retained = sender; closes += 1 }
      throw FixtureError.close
    }
    func closeCount() -> Int { lock.withLock { closes } }
  }

  private func fixture(reserve: Bool = true, staleEpoch: Bool = false,
    reference: String? = nil) async throws -> Fixture {
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    let source = temporary.appendingPathComponent("synthetic.pdf")
    try Data("%PDF-1.7\nowned acquisition fixture\n%%EOF\n".utf8).write(to: source)
    let database = try ProductDatabase.open(at: temporary.appendingPathComponent("library"))
    let lifecycle = try await LocalLibraryLifecycle.open(database: database)
    let paper = try await lifecycle.importPDF(from: source)
    let snapshot = try database.readerSnapshot(paperID: paper)
    let sha = try database.adapterRead {
      try XCTUnwrap(String.fetchOne($0, sql: "SELECT pdfSHA256 FROM paper WHERE id = ?",
        arguments: [paper.uuidString]))
    }
    let identity = ExtractionIdentity(paperID: paper, generation: snapshot.generation,
      pdfSHA256: sha, pdfReference: reference ?? snapshot.pdfReference, revision: UUID(), job: UUID(),
      attempt: UUID(), fence: UUID(), correlation: UUID(), input: UUID(),
      epoch: staleEpoch ? UUID() : lifecycle.epoch, configuration: try database.providerConfiguration())
    if reserve { try database.reserveExtraction(identity) }
    return Fixture(temporary: temporary, database: database, lifecycle: lifecycle,
      snapshot: snapshot, identity: identity)
  }

  private func resources(_ identity: ExtractionIdentity, effects: Effects) throws
    -> PDFiumExtractionResourceOwner {
    try PDFiumExtractionResourceOwner(identity: identity, operationID: UUID(), authority: ProviderRequest(),
      testingClock: { effects.clock() }, testingResidentBytes: { 1 })
  }

  private func dispose(_ input: PDFiumPinnedInput) async throws {
    try input.closeSender()
    input.recordConsumerDisposal()
    try await input.releasePinAfterConfirmedDrain()
    try await input.finishAfterDisposal()
  }

  func testActualReadonlyTransferFullIdentityAndIndependentReaderClosure() async throws {
    let f = try await fixture()
    defer { try? FileManager.default.removeItem(at: f.temporary) }
    let effects = Effects(), owner = try resources(f.identity, effects: effects)
    let pool = try RequestResourcePool(authority: ProviderRequest(), kind: "parser")
    let reader = try LibraryReadLeaseProvider(lifecycle: f.lifecycle).acquireReadLease(
      for: f.snapshot, onRevoked: {})
    defer { reader.close() }
    let acquirer = LibraryPDFiumInputAcquirer(lifecycle: f.lifecycle,
      testingCloseSender: { try $0.close() }, testingBeforeConstruct: { effects.remember($0) })
    let input = try await acquirer.acquireInput(resources: owner, onRevoked: {})
    let sender = try XCTUnwrap(effects.sender())
    XCTAssertEqual(input.identity, f.identity)
    XCTAssertTrue(input.identity.pdfReference.utf8.elementsEqual(f.identity.pdfReference.utf8))
    XCTAssertEqual(input.operationID, owner.operationID)
    XCTAssertEqual(input.deadlineUptimeNanoseconds, owner.deadlineUptimeNanoseconds)
    XCTAssertEqual(input.limits.maximumInputBytes, owner.limits.maximumInputBytes)
    XCTAssertEqual(input.limits.maximumPages, owner.limits.maximumPages)
    XCTAssertEqual(input.limits.maximumSentences, owner.limits.maximumSentences)
    XCTAssertEqual(input.limits.maximumSentenceBytes, owner.limits.maximumSentenceBytes)
    XCTAssertEqual(input.limits.maximumTextBytes, owner.limits.maximumTextBytes)
    XCTAssertEqual(input.limits.maximumQuadsPerSentence, owner.limits.maximumQuadsPerSentence)
    XCTAssertEqual(input.limits.maximumQuads, owner.limits.maximumQuads)
    XCTAssertEqual(input.limits.maximumBatchSentences, owner.limits.maximumBatchSentences)
    XCTAssertEqual(input.limits.maximumBatchBytes, owner.limits.maximumBatchBytes)
    XCTAssertEqual(input.limits.maximumResidentBytes, owner.limits.maximumResidentBytes)
    XCTAssertEqual(fcntl(sender.fileDescriptor, F_GETFL) & O_ACCMODE, O_RDONLY)
    XCTAssertNotEqual(fcntl(sender.fileDescriptor, F_GETFD) & FD_CLOEXEC, 0)
    XCTAssertEqual(try sender.readToEnd(), try Data(contentsOf:
      f.database.root.appendingPathComponent(f.snapshot.pdfReference)))
    XCTAssertEqual(pool.active, 1)
    do {
      _ = try await acquirer.acquireInput(resources: owner, onRevoked: {})
      XCTFail("Reused a handed-off resource capture")
    } catch { XCTAssertEqual((error as? PDFiumFailure)?.code, .busy) }
    XCTAssertEqual(pool.active, 1)
    do { try await input.finishAfterDisposal(); XCTFail("Finished before disposal") }
    catch { XCTAssertEqual((error as? PDFiumFailure)?.code, .cleanupIncomplete) }
    // Callback can run under the actual writer transaction without a nested GRDB read.
    try f.database.adapterWrite { _ in try input.checkBudget() }
    try await dispose(input)
    XCTAssertEqual(pool.active, 0)
    try reader.validate()
    reader.close()
    try await f.lifecycle.readLeaseRegistry.drain(f.snapshot.paperID)
    let position = try f.database.adapterRead {
      try Row.fetchOne($0, sql: "SELECT readerSession, lastReadPage FROM paper WHERE id = ?",
        arguments: [f.snapshot.paperID.uuidString])
    }
    let session: String? = try XCTUnwrap(position)["readerSession"]
    let page: Int? = try XCTUnwrap(position)["lastReadPage"]
    XCTAssertNil(session)
    XCTAssertNil(page)
  }

  func testSeparateAcquirersCannotReuseOrFinishAnAlreadyTransferredAllowance() async throws {
    let f = try await fixture()
    defer { try? FileManager.default.removeItem(at: f.temporary) }
    let owner = try resources(f.identity, effects: Effects())
    let first = LibraryPDFiumInputAcquirer(lifecycle: f.lifecycle)
    let second = LibraryPDFiumInputAcquirer(lifecycle: f.lifecycle)
    let input = try await first.acquireInput(resources: owner, onRevoked: {})
    do { _ = try await second.acquireInput(resources: owner, onRevoked: {}); XCTFail("Shared allowance reused") }
    catch { XCTAssertEqual((error as? PDFiumFailure)?.code, .busy) }
    try input.checkBudget()
    XCTAssertEqual(try RequestResourcePool(authority: ProviderRequest(), kind: "parser").active, 1)
    try await dispose(input)
    XCTAssertEqual(try RequestResourcePool(authority: ProviderRequest(), kind: "parser").active, 0)
  }

  func testMissingReservationAndStaleEpochRejectBeforeAnyFileOpen() async throws {
    for stale in [false, true] {
      let f = try await fixture(reserve: stale, staleEpoch: stale)
      defer { try? FileManager.default.removeItem(at: f.temporary) }
      // An attempted open would now fail with POSIX, not staleAttempt.
      try FileManager.default.removeItem(at: f.database.root.appendingPathComponent(f.snapshot.pdfReference))
      let owner = try resources(f.identity, effects: Effects())
      do {
        _ = try await LibraryPDFiumInputAcquirer(lifecycle: f.lifecycle).acquireInput(
          resources: owner, onRevoked: {})
        XCTFail("Unadmitted identity acquired input")
      } catch { XCTAssertEqual(error as? ExtractionError, .staleAttempt) }
      XCTAssertEqual(try RequestResourcePool(authority: ProviderRequest(), kind: "parser").active, 0)
      try await f.lifecycle.readLeaseRegistry.drain(f.snapshot.paperID)
    }
  }

  func testCurrentModelAndEveryRunningLineageFieldAreAdmissionFacts() async throws {
    let f = try await fixture()
    defer { try? FileManager.default.removeItem(at: f.temporary) }
    for column in ["revision", "job", "attempt", "fence", "correlation", "input", "epoch",
      "generation", "pdfSHA256", "pdfReference", "configGeneration", "configSlot", "state"] {
      let original = try f.database.adapterRead {
        try String.fetchOne($0, sql: "SELECT \(column) FROM extractionAttempt WHERE paperID = ?",
          arguments: [f.identity.paperID.uuidString])
      }
      try f.database.adapterWrite {
        try $0.execute(sql: "UPDATE extractionAttempt SET \(column) = ? WHERE paperID = ?",
          arguments: [column == "configGeneration" ? "999" : UUID().uuidString,
            f.identity.paperID.uuidString])
      }
      XCTAssertThrowsError(try f.database.extractionReadSnapshot(f.identity)) {
        XCTAssertEqual($0 as? ExtractionError, .staleAttempt)
      }
      try f.database.adapterWrite {
        try $0.execute(sql: "UPDATE extractionAttempt SET \(column) = ? WHERE paperID = ?",
          arguments: [original, f.identity.paperID.uuidString])
      }
    }
    try f.database.adapterWrite { try $0.execute(sql: "UPDATE providerConfig SET model = 'changed-only-model'") }
    try FileManager.default.removeItem(at: f.database.root.appendingPathComponent(f.snapshot.pdfReference))
    let owner = try resources(f.identity, effects: Effects())
    do {
      _ = try await LibraryPDFiumInputAcquirer(lifecycle: f.lifecycle).acquireInput(
        resources: owner, onRevoked: {})
      XCTFail("Model-only change admitted")
    } catch { XCTAssertEqual(error as? ExtractionError, .staleAttempt) }
    XCTAssertEqual(try RequestResourcePool(authority: ProviderRequest(), kind: "parser").active, 0)
    try await f.lifecycle.readLeaseRegistry.drain(f.snapshot.paperID)
  }

  func testInvalidUTF8ReferenceAndChangedReadyPaperRejectBeforeOpen() async throws {
    let f = try await fixture(reserve: false, reference: "papers/é/document.pdf")
    defer { try? FileManager.default.removeItem(at: f.temporary) }
    // Canonically equal Swift Strings are not interchangeable opaque references.
    let decomposed = "papers/é/document.pdf"
    XCTAssertEqual(f.identity.pdfReference, decomposed)
    XCTAssertFalse(f.identity.pdfReference.utf8.elementsEqual(decomposed.utf8))
    try f.database.adapterWrite {
      try $0.execute(sql: "UPDATE paper SET pdfReference = ? WHERE id = ?",
        arguments: [decomposed, f.snapshot.paperID.uuidString])
    }
    XCTAssertThrowsError(try f.database.reserveExtraction(f.identity))
    // Even matching durable bytes plus a genuine running reservation cannot admit
    // a noncanonical Library reference. The adapter must reject it before open.
    try f.database.adapterWrite {
      try $0.execute(sql: "UPDATE paper SET pdfReference = ? WHERE id = ?",
        arguments: [f.identity.pdfReference, f.snapshot.paperID.uuidString])
    }
    try f.database.reserveExtraction(f.identity)
    try FileManager.default.removeItem(at: f.database.root.appendingPathComponent(f.snapshot.pdfReference))
    let owner = try resources(f.identity, effects: Effects())
    do {
      _ = try await LibraryPDFiumInputAcquirer(lifecycle: f.lifecycle).acquireInput(
        resources: owner, onRevoked: {})
      XCTFail("Invalid reference admitted")
    } catch { XCTAssertEqual(error as? ExtractionError, .staleAttempt) }
    XCTAssertEqual(try RequestResourcePool(authority: ProviderRequest(), kind: "parser").active, 0)
    try await f.lifecycle.readLeaseRegistry.drain(f.snapshot.paperID)
  }

  func testExpiredOriginalBudgetDoesNotRenewOrOpenFile() async throws {
    let f = try await fixture()
    defer { try? FileManager.default.removeItem(at: f.temporary) }
    let effects = Effects(), owner = try resources(f.identity, effects: effects)
    let deadline = owner.deadlineUptimeNanoseconds
    effects.expire(deadline)
    try FileManager.default.removeItem(at: f.database.root.appendingPathComponent(f.snapshot.pdfReference))
    do {
      _ = try await LibraryPDFiumInputAcquirer(lifecycle: f.lifecycle).acquireInput(
        resources: owner, onRevoked: {})
      XCTFail("Expired capture renewed")
    } catch { XCTAssertEqual((error as? PDFiumFailure)?.code, .resourceExceeded) }
    XCTAssertEqual(owner.deadlineUptimeNanoseconds, deadline)
    XCTAssertEqual(try RequestResourcePool(authority: ProviderRequest(), kind: "parser").active, 0)
    try await f.lifecycle.readLeaseRegistry.drain(f.snapshot.paperID)
  }

  func testConstructorFailureAndFinalSnapshotRaceCloseRealOwnership() async throws {
    for mode in 0..<4 {
      let f = try await fixture()
      defer { try? FileManager.default.removeItem(at: f.temporary) }
      let effects = Effects(), owner = try resources(f.identity, effects: effects)
      let acquirer = LibraryPDFiumInputAcquirer(lifecycle: f.lifecycle,
        testingCloseSender: { try $0.close() }, testingBeforeConstruct: { sender in
          effects.remember(sender)
          if mode == 1 {
            try f.database.adapterWrite {
              try $0.execute(sql: "UPDATE providerConfig SET model = 'raced-only-model'")
            }
          } else if mode == 2 {
            effects.expire(owner.deadlineUptimeNanoseconds)
          } else if mode == 3 {
            // Real constructor fstat rejects the now-empty owned file.
            let url = f.database.root.appendingPathComponent(f.snapshot.pdfReference)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            try Data().write(to: url)
          } else { throw FixtureError.constructor }
        })
      do {
        _ = try await acquirer.acquireInput(resources: owner, onRevoked: {})
        XCTFail("Failure path succeeded")
      } catch {
        switch mode {
        case 1: XCTAssertEqual(error as? ExtractionError, .staleAttempt)
        case 2: XCTAssertEqual((error as? PDFiumFailure)?.code, .resourceExceeded)
        case 3: XCTAssertEqual((error as? PDFiumFailure)?.code, .invalidRequest)
        default: XCTAssertTrue(error is FixtureError)
        }
      }
      XCTAssertEqual(try RequestResourcePool(authority: ProviderRequest(), kind: "parser").active, 0)
      try await f.lifecycle.readLeaseRegistry.drain(f.snapshot.paperID)
      try LibraryReadLeaseProvider(lifecycle: f.lifecycle).acquireReadLease(
        for: f.snapshot, onRevoked: {}).close()
    }
  }

  func testRevocationForwardsCallbackButDoesNotReleaseProducerOwnership() async throws {
    let f = try await fixture()
    defer { try? FileManager.default.removeItem(at: f.temporary) }
    let owner = try resources(f.identity, effects: Effects())
    var callbacks = 0
    let input = try await LibraryPDFiumInputAcquirer(lifecycle: f.lifecycle).acquireInput(
      resources: owner, onRevoked: { callbacks += 1 })
    let revocations = f.lifecycle.readLeaseRegistry.revoke(f.snapshot.paperID)
    for callback in revocations { callback() }
    XCTAssertEqual(callbacks, 1)
    XCTAssertThrowsError(try input.checkBudget()) { XCTAssertEqual($0 as? ReaderError, .revoked) }
    XCTAssertEqual(try RequestResourcePool(authority: ProviderRequest(), kind: "parser").active, 1)
    try await dispose(input)
    try await f.lifecycle.readLeaseRegistry.drain(f.snapshot.paperID)
    let deniedOwner = try resources(f.identity, effects: Effects())
    do {
      _ = try await LibraryPDFiumInputAcquirer(lifecycle: f.lifecycle).acquireInput(
        resources: deniedOwner, onRevoked: {})
      XCTFail("Revoked Library reopened")
    } catch { XCTAssertEqual(error as? ReaderError, .revoked) }
    XCTAssertEqual(try RequestResourcePool(authority: ProviderRequest(), kind: "parser").active, 0)
  }

  func testFailedAcquisitionCleanupReportsActualOriginalCloseUncertainty() async throws {
    for revokedInstall in [false, true] {
      let f = try await fixture()
      defer { try? FileManager.default.removeItem(at: f.temporary) }
      let effects = Effects(), owner = try resources(f.identity, effects: effects)
      let handle = try FileHandle(forReadingFrom:
        f.database.root.appendingPathComponent(f.snapshot.pdfReference))
      defer {
        // Actual owned-fixture debt teardown, not successful production closure evidence.
        try? handle.close()
        try? owner.finishOperation(owner.operationID)
      }
      let registry = LibraryReadLeaseRegistry(closeHandle: { try effects.refuseClose($0) })
      let token = try registry.reserve(f.snapshot, revoke: {})
      let observation = registry.closureObservation(token)
      if revokedInstall {
        _ = registry.revoke(f.snapshot.paperID)
        XCTAssertThrowsError(try registry.install(handle, token: token)) {
          XCTAssertEqual($0 as? ReaderError, .revoked)
        }
      }
      for _ in 0..<3 {
        XCTAssertThrowsError(try registry.cleanupFailedAcquisition(handle, token: token,
          observation: observation)) {
          XCTAssertEqual($0 as? LocalLibraryError, .producerClosureUnknown)
        }
      }
      XCTAssertEqual(effects.closeCount(), 1)
      XCTAssertGreaterThanOrEqual(fcntl(handle.fileDescriptor, F_GETFD), 0)
      XCTAssertEqual(try RequestResourcePool(authority: ProviderRequest(), kind: "parser").active, 1)
      do { try await registry.drain(f.snapshot.paperID); XCTFail("Uncertain original drain succeeded") }
      catch { XCTAssertEqual(error as? LocalLibraryError, .producerClosureUnknown) }
    }
  }

  func testFailedAcquisitionCleanupConfirmsNoFDAndKnownPhysicalClosure() async throws {
    let f = try await fixture()
    defer { try? FileManager.default.removeItem(at: f.temporary) }
    for opened in [false, true] {
      let registry = LibraryReadLeaseRegistry()
      let token = try registry.reserve(f.snapshot, revoke: {})
      let observation = registry.closureObservation(token)
      let handle = opened ? try FileHandle(forReadingFrom:
        f.database.root.appendingPathComponent(f.snapshot.pdfReference)) : nil
      let descriptor = handle?.fileDescriptor
      try registry.cleanupFailedAcquisition(handle, token: token, observation: observation)
      if let descriptor {
        XCTAssertEqual(fcntl(descriptor, F_GETFD), -1)
        XCTAssertEqual(errno, EBADF)
      }
      try observation.requireConfirmedClosure()
      try await registry.drain(f.snapshot.paperID)
    }
  }

  func testUnknownSenderCleanupRetainsActualFDTokenAndPoolWithoutRetry() async throws {
    let f = try await fixture()
    defer { try? FileManager.default.removeItem(at: f.temporary) }
    let effects = Effects(), owner = try resources(f.identity, effects: effects)
    let acquirer = LibraryPDFiumInputAcquirer(lifecycle: f.lifecycle,
      testingCloseSender: { try effects.refuseClose($0) },
      testingBeforeConstruct: { effects.remember($0); throw FixtureError.constructor })
    do {
      _ = try await acquirer.acquireInput(resources: owner, onRevoked: {})
      XCTFail("Unknown sender cleanup succeeded")
    } catch { XCTAssertEqual(error as? LocalLibraryError, .producerClosureUnknown) }
    var sender: FileHandle? = try XCTUnwrap(effects.sender())
    weak var registryRetainedSender = sender
    let descriptor = try XCTUnwrap(sender).fileDescriptor
    sender = nil
    effects.forgetSender()
    XCTAssertNotNil(registryRetainedSender)
    XCTAssertGreaterThanOrEqual(fcntl(descriptor, F_GETFD), 0)
    XCTAssertEqual(try RequestResourcePool(authority: ProviderRequest(), kind: "parser").active, 1)
    XCTAssertNil(try RequestResourcePool(authority: ProviderRequest(), kind: "parser").acquire())
    for _ in 0..<3 {
      f.lifecycle.readLeaseRegistry.retryClosures(f.snapshot.paperID)
      do { try await f.lifecycle.readLeaseRegistry.drain(f.snapshot.paperID); XCTFail("Debt drained") }
      catch { XCTAssertEqual(error as? LocalLibraryError, .producerClosureUnknown) }
    }
    XCTAssertEqual(effects.closeCount(), 1)
    XCTAssertNotNil(registryRetainedSender)
    XCTAssertGreaterThanOrEqual(fcntl(descriptor, F_GETFD), 0)
    // Explicit owned-fixture teardown only, never acquirer retry or successful End evidence.
    try XCTUnwrap(registryRetainedSender).close()
    try owner.finishOperation(owner.operationID)
  }
}
