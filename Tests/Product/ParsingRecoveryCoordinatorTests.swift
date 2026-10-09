import Foundation
import GRDB
import XCTest
@testable import PaperLensProduct

final class ParsingRecoveryCoordinatorTests: XCTestCase {
  private struct RejectingValidator: ExtractionGeometryValidating {
    func validateAndEncode(_ input: any ExtractionGeometryInput,
      identity: ExtractionSentenceIdentity, expectedText: String) throws -> ExtractionGeometryEncoding {
      throw ExtractionError.geometryUnavailable
    }
  }

  /// Controlled failure, not a parser or geometry-success substitute.
  private actor HeldFailureProducer: ExtractionBatchProducing {
    private var started = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    private(set) var identities: [ExtractionIdentity] = []

    func extract(_ identity: ExtractionIdentity) async throws -> [ExtractionBatch] {
      identities.append(identity)
      await withCheckedContinuation { continuation in
        releaseWaiter = continuation
        started = true
        startWaiter?.resume()
        startWaiter = nil
      }
      throw ExtractionError.invalidBatch
    }

    func waitForStart() async {
      if started { return }
      await withCheckedContinuation { startWaiter = $0 }
    }

    func release() {
      releaseWaiter?.resume()
      releaseWaiter = nil
    }
  }

  private func fixture() throws -> (ProductDatabase, ExtractionIdentity, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let database = try ProductDatabase.open(at: root)
    let paper = UUID(), generation = UUID()
    let identity = ExtractionIdentity(paperID: paper, generation: generation,
      pdfSHA256: String(repeating: "a", count: 64),
      pdfReference: "papers/\(paper.uuidString)/document.pdf", revision: UUID(), job: UUID(),
      attempt: UUID(), fence: UUID(), correlation: UUID(), input: UUID(), epoch: UUID(),
      configuration: try database.providerConfiguration())
    try database.adapterWrite { db in
      try db.execute(sql: """
        INSERT INTO paper(id, generation, title, status, pdfReference, pdfSHA256, createdAt)
        VALUES (?, ?, 'fixture', 'ready', ?, ?, 0)
        """, arguments: [paper.uuidString, generation.uuidString, identity.pdfReference, identity.pdfSHA256])
    }
    try database.reserveExtraction(identity)
    try database.failExtraction(identity, failure: .invalidBatch)
    return (database, identity, root)
  }

  private func invocationCount(_ database: ProductDatabase) throws -> Int {
    try database.adapterRead { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM extractionInvocation") ?? 0 }
  }

  func testMissingProductionBoundariesRejectBeforeReservation() async throws {
    let (database, old, root) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let producer = HeldFailureProducer()
    for service in [
      ExtractionRevisionService(database: database, producer: nil, geometryValidator: RejectingValidator()),
      ExtractionRevisionService(database: database, producer: producer, geometryValidator: nil),
    ] {
      let coordinator = ParsingRecoveryCoordinator(service: service, currentEpoch: UUID())
      let captured = try await coordinator.context(paperID: old.paperID)
      let context = try XCTUnwrap(captured)
      do { try await coordinator.retry(context); XCTFail("unbound boundary admitted") }
      catch {
        XCTAssertEqual(error as? ExtractionError,
          service.producer == nil ? .producerUnavailable : .geometryUnavailable)
      }
      XCTAssertEqual(try invocationCount(database), 1)
      XCTAssertEqual(try database.extractionStatus(paperID: old.paperID).failure, "invalidBatch")
    }
    let calls = await producer.identities
    XCTAssertTrue(calls.isEmpty)
  }

  func testEveryCapturedGuardRejectsWithoutDispatchOrNewInvocation() async throws {
    let mutations = [
      "UPDATE paper SET generation = 'changed'",
      "UPDATE paper SET pdfSHA256 = 'changed'",
      "UPDATE paper SET pdfReference = 'changed'",
      "UPDATE paper SET status = 'deleting'",
      "UPDATE paper SET deletionID = 'changed'",
      "UPDATE providerConfig SET generation = generation + 1",
      "UPDATE providerConfig SET slotID = 'changed'",
      "UPDATE providerConfig SET model = 'changed'",
      "UPDATE extractionAttempt SET state = 'running'",
      "UPDATE extractionAttempt SET configGeneration = 999",
    ] + ["generation", "revision", "job", "attempt", "fence", "correlation", "input", "epoch",
      "configSlot"].map {
        "UPDATE extractionAttempt SET \($0) = '\(UUID().uuidString)'"
      }
    for mutation in mutations {
      let (database, old, root) = try fixture()
      defer { try? FileManager.default.removeItem(at: root) }
      let producer = HeldFailureProducer()
      let coordinator = ParsingRecoveryCoordinator(service: .init(database: database,
        producer: producer, geometryValidator: RejectingValidator()), currentEpoch: UUID())
      let captured = try await coordinator.context(paperID: old.paperID)
      let context = try XCTUnwrap(captured)
      try database.adapterWrite { try $0.execute(sql: mutation) }
      do { try await coordinator.retry(context); XCTFail("changed guard admitted: \(mutation)") }
      catch { /* Invalid persisted UUIDs and mismatched snapshots both reject closed. */ }
      XCTAssertEqual(try invocationCount(database), 1, mutation)
      let calls = await producer.identities
      XCTAssertTrue(calls.isEmpty, mutation)
    }
  }

  func testConcurrentClicksFreshMainLineageAndPersistedRepeatedFailure() async throws {
    let (database, old, root) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let producer = HeldFailureProducer(), epoch = UUID()
    let service = ExtractionRevisionService(database: database, producer: producer,
      geometryValidator: RejectingValidator())
    let coordinator = ParsingRecoveryCoordinator(service: service, currentEpoch: epoch)
    let other = ParsingRecoveryCoordinator(service: service, currentEpoch: epoch)
    let captured = try await coordinator.context(paperID: old.paperID)
    let context = try XCTUnwrap(captured)
    let first = Task { try await coordinator.retry(context) }
    await producer.waitForStart()
    do { try await coordinator.retry(context); XCTFail("duplicate admitted") }
    catch { XCTAssertEqual(error as? ParsingRecoveryError, .alreadyRunning) }
    do { try await other.retry(context); XCTFail("second arbiter admitted") }
    catch { XCTAssertEqual(error as? ParsingRecoveryError, .staleContext) }
    let identities = await producer.identities
    let fresh = try XCTUnwrap(identities.first)
    XCTAssertEqual(identities.count, 1)
    XCTAssertEqual(fresh.epoch, epoch)
    XCTAssertEqual(fresh.job, old.job)
    XCTAssertEqual(fresh.generation, old.generation)
    XCTAssertNotEqual(fresh.attempt, old.attempt)
    XCTAssertNotEqual(fresh.fence, old.fence)
    XCTAssertNotEqual(fresh.correlation, old.correlation)
    XCTAssertNotEqual(fresh.input, old.input)
    XCTAssertNotEqual(fresh.revision, old.revision)
    await producer.release()
    do { try await first.value; XCTFail("failure reported as success") }
    catch { XCTAssertEqual(error as? ExtractionError, .invalidBatch) }
    try database.failExtraction(old, failure: .storageFailure)
    XCTAssertEqual(try database.extractionStatus(paperID: old.paperID).failure, "invalidBatch")
    let reopened = try ProductDatabase.open(at: root)
    XCTAssertEqual(try reopened.extractionStatus(paperID: old.paperID).state, "failed")
    XCTAssertEqual(try invocationCount(reopened), 2)
  }

  func testUsableRevisionChangeInvalidatesCapturedRetryAndRetainsReaderData() async throws {
    let (database, old, root) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let producer = HeldFailureProducer()
    let coordinator = ParsingRecoveryCoordinator(service: .init(database: database,
      producer: producer, geometryValidator: RejectingValidator()), currentEpoch: UUID())
    let captured = try await coordinator.context(paperID: old.paperID)
    let context = try XCTUnwrap(captured)
    // Storage-only fixture; these bytes do not attest validated geometry.
    let usable = UUID()
    try database.adapterWrite { db in
      try db.execute(sql: """
        INSERT INTO extractionRevision(id, paperID, generation, pdfSHA256, pdfReference)
        VALUES (?, ?, ?, ?, ?)
        """, arguments: [usable.uuidString, old.paperID.uuidString, old.generation.uuidString,
          old.pdfSHA256, old.pdfReference])
      try db.execute(sql: "INSERT INTO extractionVisible(paperID, revision) VALUES (?, ?)",
        arguments: [old.paperID.uuidString, usable.uuidString])
    }
    do { try await coordinator.retry(context); XCTFail("changed usable pointer admitted") }
    catch { XCTAssertEqual(error as? ParsingRecoveryError, .staleContext) }
    let updated = try await coordinator.context(paperID: old.paperID)
    let retryContext = try XCTUnwrap(updated)
    let first = Task { try await coordinator.retry(retryContext) }
    await producer.waitForStart()
    XCTAssertEqual(try database.extractionStatus(paperID: old.paperID).usableRevision, usable)
    await producer.release()
    do { try await first.value; XCTFail("failure reported as success") } catch {}
    XCTAssertEqual(try database.extractionStatus(paperID: old.paperID).usableRevision, usable)
    XCTAssertEqual(try invocationCount(database), 2)
  }

  func testDeletionDuringProducerFailureBlocksRetryAndLatePublication() async throws {
    let (database, old, root) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let producer = HeldFailureProducer()
    let coordinator = ParsingRecoveryCoordinator(service: .init(database: database,
      producer: producer, geometryValidator: RejectingValidator()), currentEpoch: UUID())
    let captured = try await coordinator.context(paperID: old.paperID)
    let context = try XCTUnwrap(captured)
    let first = Task { try await coordinator.retry(context) }
    await producer.waitForStart()
    let saga = try XCTUnwrap(database.beginDeletion(old.paperID))
    let deletedContext = try await coordinator.context(paperID: old.paperID)
    XCTAssertNil(deletedContext)
    let identities = await producer.identities
    let fresh = try XCTUnwrap(identities.first)
    XCTAssertThrowsError(try database.publishExtraction(fresh, sentences: [
      .init(page: 0, sentenceID: 0, text: "late", geometry: Data([1])),
    ]))
    await producer.release()
    do { try await first.value; XCTFail("deleted failure reported as success") } catch {}
    try database.finalizeDeletion(old.paperID, saga: saga)
    do { try await coordinator.retry(context); XCTFail("deleted paper admitted") }
    catch { XCTAssertEqual(error as? ParsingRecoveryError, .staleContext) }
    XCTAssertEqual(try invocationCount(database), 0)
    XCTAssertEqual(try database.extractionStatus(paperID: old.paperID).state, "unavailable")
  }

  func testMainStartupReconciliationRestoresInterruptedFailureWithoutReplay() async throws {
    let (database, old, root) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    try database.adapterWrite { try $0.execute(sql: "UPDATE extractionAttempt SET state = 'running'") }
    let reopened = try ProductDatabase.open(at: root)
    let epoch = UUID()
    _ = try ProductJobRecovery(database: reopened).recoverStartup(currentEpoch: epoch)
    let producer = HeldFailureProducer()
    let coordinator = ParsingRecoveryCoordinator(service: .init(database: reopened,
      producer: producer, geometryValidator: RejectingValidator()), currentEpoch: epoch)
    let context = try await coordinator.context(paperID: old.paperID)
    XCTAssertNotNil(context)
    XCTAssertEqual(try reopened.extractionStatus(paperID: old.paperID).failure, "interrupted")
    XCTAssertEqual(try invocationCount(reopened), 1)
    let identities = await producer.identities
    XCTAssertTrue(identities.isEmpty)
  }

  func testFailureMessagesNeverExposeWorkerDiagnostics() {
    let diagnostic = "secret/path token=private duration=9 attempt=42"
    XCTAssertEqual(ParsingFailureMessage.korean(diagnostic),
      "원문 파싱에 실패했습니다. 다시 시도하세요.")
    XCTAssertEqual(ParsingFailureMessage.korean("invalidBatch"),
      "원문 파싱 결과를 검증하지 못했습니다. 다시 시도하세요.")
  }
}
