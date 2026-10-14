import Darwin
import Foundation
import GRDB
import ProviderRequest
import XCTest
@testable import PaperLensProduct

/// Real owned Library/GRDB/FD/Main-Mach fixtures only. No XPC connection is resumed.
@MainActor final class MainPDFiumParsingCompositionTests: XCTestCase {
  private enum FixtureFailure: Error, Equatable { case stoppedBeforeInputReturn }
  private struct Fixture {
    let temporary: URL
    let database: ProductDatabase
    let lifecycle: LocalLibraryLifecycle
    let snapshot: ReaderPaperSnapshot
    let identity: ExtractionIdentity
  }

  /// Controls a real-input factory that always throws, so even assertion failure
  /// cannot return an input to the producer's connection-start path.
  private actor AcquisitionGate {
    private var result: Result<UUID, Error>?
    private var observer: CheckedContinuation<UUID, Error>?
    private var release: CheckedContinuation<Void, Never>?
    func hold(operationID: UUID) async {
      await withCheckedContinuation { continuation in
        release = continuation
        result = .success(operationID)
        observer?.resume(returning: operationID)
        observer = nil
      }
    }
    func fail(_ error: Error) {
      result = .failure(error)
      observer?.resume(throwing: error)
      observer = nil
    }
    func operation() async throws -> UUID {
      if let result { return try result.get() }
      return try await withCheckedThrowingContinuation { observer = $0 }
    }
    func open() { release?.resume(); release = nil }
  }

  private func fixture(reserve: Bool = true) async throws -> Fixture {
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    let source = temporary.appendingPathComponent("owned.pdf")
    try Data("%PDF-1.7\nowned composition fixture\n%%EOF\n".utf8).write(to: source)
    let database = try ProductDatabase.open(at: temporary.appendingPathComponent("library"))
    let lifecycle = try await LocalLibraryLifecycle.open(database: database)
    let paper = try await lifecycle.importPDF(from: source)
    let configuration = try database.providerConfiguration()
    _ = try database.compareAndSwapProviderConfiguration(expected: configuration,
      replacementKind: .openAIAPIKey, replacementSlotID: UUID(),
      replacementModel: "explicit-owned-fixture-model")
    let snapshot = try database.readerSnapshot(paperID: paper)
    let sha = try database.adapterRead {
      try XCTUnwrap(String.fetchOne($0, sql: "SELECT pdfSHA256 FROM paper WHERE id = ?",
        arguments: [paper.uuidString]))
    }
    let identity = ExtractionIdentity(paperID: paper, generation: snapshot.generation,
      pdfSHA256: sha, pdfReference: snapshot.pdfReference, revision: UUID(), job: UUID(),
      attempt: UUID(), fence: UUID(), correlation: UUID(), input: UUID(), epoch: lifecycle.epoch,
      configuration: try database.providerConfiguration())
    if reserve { try database.reserveExtraction(identity) }
    return Fixture(temporary: temporary, database: database, lifecycle: lifecycle,
      snapshot: snapshot, identity: identity)
  }

  private func binding() throws -> PDFiumGeometryBinding {
    // Explicit fixture coordinates/precision, never a calibration or certification.
    let page = try PDFPageGeometry(pageIndex: 0, cropOrigin: PDFPoint(x: 0, y: 0),
      width: 100, height: 100, rotation: 0)
    let transform = try PDFGeometryAffine(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0)
    let mapping = PDFiumPageMapping(page: page, rawToCanonical: transform,
      canonicalToReader: transform)
    return try PDFiumGeometryBinding(precision: PDFGeometryPrecision(maximumErrorPDFPoints: 0),
      mapPage: { _ in mapping })
  }

  private func graph(_ f: Fixture) throws -> MainPDFiumParsingComposition {
    try MainPDFiumParsingComposition(lifecycle: f.lifecycle, authority: ProviderRequest(),
      geometryBinding: binding())
  }

  private func dispose(_ input: PDFiumPinnedInput) async throws {
    try input.closeSender()
    input.recordConsumerDisposal()
    try await input.releasePinAfterConfirmedDrain()
    try await input.finishAfterDisposal()
  }

  func testMissingGeometryDeniesConstructionBeforeNewJobsOrParserLease() async throws {
    let f = try await fixture(reserve: false)
    defer { try? FileManager.default.removeItem(at: f.temporary) }
    let authority = try ProviderRequest()
    let pool = try RequestResourcePool(authority: authority, kind: "parser")
    let jobsBefore = try f.database.adapterRead {
      try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM extractionInvocation")
    }
    let activeBefore = pool.active
    XCTAssertThrowsError(try MainPDFiumParsingComposition(lifecycle: f.lifecycle,
      authority: authority, geometryBinding: nil)) {
      XCTAssertEqual($0 as? ExtractionError, .geometryUnavailable)
    }
    XCTAssertEqual(pool.active, activeBefore)
    XCTAssertEqual(try f.database.adapterRead {
      try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM extractionInvocation")
    }, jobsBefore)
    let lease = try LibraryReadLeaseProvider(lifecycle: f.lifecycle).acquireReadLease(
      for: f.snapshot, onRevoked: {})
    lease.close()
    try await f.lifecycle.readLeaseRegistry.drain(f.snapshot.paperID)
  }

  func testActualGraphAcquiresOriginalIdentityModelEpochAndDisposesAllowance() async throws {
    let f = try await fixture()
    defer { try? FileManager.default.removeItem(at: f.temporary) }
    let authority = try ProviderRequest(), operation = UUID()
    let graph = try MainPDFiumParsingComposition(lifecycle: f.lifecycle,
      authority: authority, geometryBinding: binding())
    let pool = try RequestResourcePool(authority: graph.authority, kind: "parser")
    XCTAssertGreaterThan(try PDFiumExtractionResourceOwner.observeMainResidentBytes(), 0)
    XCTAssertTrue(graph.lifecycle === f.lifecycle)
    XCTAssertTrue(graph.authority === authority)
    XCTAssertTrue(graph.service.database === f.database)
    XCTAssertTrue((graph.service.producer as? PDFiumExtractionProducer) === graph.producer)
    XCTAssertNotNil(graph.service.geometryValidator as? PDFiumGeometryValidator)
    let start = DispatchTime.now().uptimeNanoseconds
    let input = try await graph.acquireOwnedInput(identity: f.identity, operationID: operation)
    XCTAssertEqual(input.identity, f.identity)
    XCTAssertEqual(input.identity.configuration.model, "explicit-owned-fixture-model")
    XCTAssertEqual(input.identity.epoch, graph.lifecycle.epoch)
    XCTAssertEqual(input.operationID, operation)
    XCTAssertEqual(input.pdfByteCount, Int64(try Data(contentsOf:
      f.database.root.appendingPathComponent(f.snapshot.pdfReference)).count))
    XCTAssertGreaterThan(input.deadlineUptimeNanoseconds, start)
    try input.checkBudget() // Actual acquired read-only handle and Main Mach/clock checks.
    XCTAssertEqual(pool.active, 1)
    do { try await input.finishAfterDisposal(); XCTFail("Finished while pin is held") }
    catch { XCTAssertEqual((error as? PDFiumFailure)?.code, .cleanupIncomplete) }
    try await dispose(input)
    XCTAssertEqual(pool.active, 0)
    try await f.lifecycle.readLeaseRegistry.drain(f.snapshot.paperID)
    // Single-operation captures cannot be renewed after successful physical disposal.
    do {
      _ = try await graph.acquireOwnedInput(identity: f.identity, operationID: operation)
      XCTFail("Renewed consumed operation")
    } catch { XCTAssertEqual((error as? PDFiumFailure)?.code, .busy) }
    XCTAssertEqual(pool.active, 0)
  }

  func testActualRegistryRevocationHoldsOriginalPinAndResourcesUntilDisposal() async throws {
    let f = try await fixture()
    defer { try? FileManager.default.removeItem(at: f.temporary) }
    let graph = try graph(f)
    let pool = try RequestResourcePool(authority: graph.authority, kind: "parser")
    let input = try await graph.acquireOwnedInput(identity: f.identity, operationID: UUID())
    let callbacks = f.lifecycle.readLeaseRegistry.revoke(f.snapshot.paperID)
    XCTAssertEqual(callbacks.count, 1)
    for callback in callbacks { callback() }
    XCTAssertThrowsError(try input.checkBudget()) { XCTAssertEqual($0 as? ReaderError, .revoked) }
    XCTAssertEqual(pool.active, 1)
    XCTAssertNil(pool.acquire())
    do { try await input.finishAfterDisposal(); XCTFail("Revocation falsely finished resources") }
    catch { XCTAssertEqual((error as? PDFiumFailure)?.code, .cleanupIncomplete) }
    try await dispose(input)
    try await f.lifecycle.readLeaseRegistry.drain(f.snapshot.paperID)
    XCTAssertEqual(pool.active, 0)
    // Direct acquisition deliberately has no producer session; a request is denied,
    // never interpreted as successful helper drain or physical closure.
    do { try await graph.producer.requestCancellation(operationID: input.operationID)
      XCTFail("Admitted an operation outside this producer")
    } catch { XCTAssertEqual((error as? PDFiumFailure)?.code, .identityMismatch) }
  }

  func testRealResourceWrongOperationDenialAndStickyCancellationCannotRenew() async throws {
    let f = try await fixture()
    defer { try? FileManager.default.removeItem(at: f.temporary) }
    let authority = try ProviderRequest(), operation = UUID()
    let resources = try PDFiumExtractionResourceOwner(identity: f.identity,
      operationID: operation, authority: authority)
    defer { try? resources.finishOperation(operation) }
    let deadline = resources.deadlineUptimeNanoseconds
    let pool = try RequestResourcePool(authority: authority, kind: "parser")
    XCTAssertThrowsError(try resources.requestCancellation(operationID: UUID())) {
      XCTAssertEqual(($0 as? PDFiumFailure)?.code, .invalidRequest)
    }
    try resources.checkBudget()
    try resources.requestCancellation(operationID: operation)
    for _ in 0..<3 {
      try resources.requestCancellation(operationID: operation)
      XCTAssertThrowsError(try resources.checkBudget()) {
        XCTAssertEqual(($0 as? PDFiumFailure)?.code, .cancelled)
      }
    }
    XCTAssertEqual(resources.deadlineUptimeNanoseconds, deadline)
    XCTAssertEqual(pool.active, 1)
    XCTAssertNil(pool.acquire())
    try resources.finishOperation(operation)
    XCTAssertEqual(pool.active, 0)
    XCTAssertThrowsError(try resources.requestCancellation(operationID: operation)) {
      XCTAssertEqual(($0 as? PDFiumFailure)?.code, .cleanupIncomplete)
    }
    XCTAssertThrowsError(try PDFiumExtractionResourceOwner(identity: f.identity,
      operationID: operation, authority: authority)) {
      XCTAssertEqual(($0 as? PDFiumFailure)?.code, .busy)
    }
    XCTAssertEqual(pool.active, 0)
  }

  func testPendingActualInputFactoryAdmitsOnlyCurrentCancellationAndAlwaysFailsBeforeHelper() async throws {
    let f = try await fixture()
    defer { try? FileManager.default.removeItem(at: f.temporary) }
    let graph = try graph(f), gate = AcquisitionGate()
    let pool = try RequestResourcePool(authority: graph.authority, kind: "parser")
    let producer = PDFiumExtractionProducer { identity, operation in
      let input: PDFiumPinnedInput
      do { input = try await graph.acquireOwnedInput(identity: identity, operationID: operation) }
      catch { await gate.fail(error); throw error }
      await gate.hold(operationID: operation)
      try input.closeSender()
      input.recordConsumerDisposal()
      try await input.releasePinAfterConfirmedDrain()
      try await input.finishAfterDisposal()
      throw FixtureFailure.stoppedBeforeInputReturn // Unconditional: no path can resume XPC.
    }
    let task = Task {
      try await producer.withBatches(f.identity) { _, _ in
        XCTFail("Guaranteed-failing acquisition reached consumption")
      }
    }
    let operation = try await gate.operation()
    do { try await producer.requestCancellation(operationID: UUID()); XCTFail("Foreign admitted") }
    catch { XCTAssertEqual((error as? PDFiumFailure)?.code, .identityMismatch) }
    for _ in 0..<2 {
      do { try await producer.requestCancellation(operationID: operation) }
      catch { XCTFail("Current acquisition cancellation rejected: \(error)") }
    }
    XCTAssertEqual(pool.active, 1)
    await gate.open()
    do { try await task.value; XCTFail("Guaranteed-failing factory succeeded") }
    catch { XCTAssertEqual(error as? FixtureFailure, .stoppedBeforeInputReturn) }
    XCTAssertEqual(pool.active, 0)
    do { try await producer.requestCancellation(operationID: operation); XCTFail("Stale admitted") }
    catch { XCTAssertEqual((error as? PDFiumFailure)?.code, .identityMismatch) }
    try await f.lifecycle.readLeaseRegistry.drain(f.snapshot.paperID)
  }
}
