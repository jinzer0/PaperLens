import AppKit
import Foundation
import GRDB
import SwiftUI
import XCTest
@testable import PaperLensProduct

final class ParsingRecoveryCoordinatorTests: XCTestCase {
  private struct RejectingValidator: ExtractionGeometryValidating {
    func validateAndEncode(_ input: any ExtractionGeometryInput,
      identity: ExtractionSentenceIdentity, expectedText: String) throws -> ExtractionGeometryEncoding {
      throw ExtractionError.geometryUnavailable
    }
  }

  private actor UnexpectedDispatchProducer: ExtractionBatchProducing {
    private(set) var invocationCount = 0

    func withBatches(_ identity: ExtractionIdentity,
      consume: @escaping @Sendable ([ExtractionBatch], ExtractionConsumptionScope) async throws -> Void) async throws {
      invocationCount += 1
      throw ExtractionError.invalidBatch
    }
  }

  /// Controlled failure, not a parser or geometry-success substitute.
  private actor HeldFailureProducer: ExtractionBatchProducing {
    private let failure: ExtractionError
    private var started = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    private(set) var identities: [ExtractionIdentity] = []

    init(failure: ExtractionError = .invalidBatch) { self.failure = failure }

    func withBatches(_ identity: ExtractionIdentity,
      consume: @escaping @Sendable ([ExtractionBatch], ExtractionConsumptionScope) async throws -> Void) async throws {
      identities.append(identity)
      await withCheckedContinuation { continuation in
        releaseWaiter = continuation
        started = true
        startWaiter?.resume()
        startWaiter = nil
      }
      throw failure
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

  private func fixture(reserve: Bool = true) throws -> (ProductDatabase, ExtractionIdentity, URL) {
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
    if reserve {
      try database.reserveExtraction(identity)
      try database.failExtraction(identity, failure: .invalidBatch)
    }
    return (database, identity, root)
  }

  private func invocationCount(_ database: ProductDatabase) throws -> Int {
    try database.adapterRead { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM extractionInvocation") ?? 0 }
  }

  func testRetryPreservesFrozenProviderAndRejectsCurrentRoutingDrift() async throws {
    let (database, old, root) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let configuration = try database.compareAndSwapProviderConfiguration(expected: database.providerConfiguration(),
      replacementKind: .openAIAPIKey, replacementSlotID: UUID(), replacementModel: "fixture-model")
    let native = ExtractionIdentity(paperID: old.paperID, generation: old.generation,
      pdfSHA256: old.pdfSHA256, pdfReference: old.pdfReference, revision: UUID(), job: old.job,
      attempt: UUID(), fence: UUID(), correlation: UUID(), input: UUID(), epoch: UUID(),
      configuration: configuration)
    try database.reserveExtraction(native)
    try database.failExtraction(native, failure: .invalidBatch)
    let producer = HeldFailureProducer()
    let coordinator = ParsingRecoveryCoordinator(service: .init(database: database,
      producer: producer, geometryValidator: RejectingValidator()), currentEpoch: UUID())
    let captured = try await coordinator.context(paperID: old.paperID)
    let expected = try XCTUnwrap(captured)
    XCTAssertEqual(expected.failedAttempt.configuration.kind, .openAIAPIKey)
    try database.adapterWrite { try $0.execute(sql: "UPDATE providerConfig SET kind = 'codexChatGPT'") }
    let changed = try await coordinator.context(paperID: old.paperID)
    XCTAssertEqual(changed?.failedAttempt.configuration.kind, .openAIAPIKey)
    XCTAssertEqual(changed?.currentConfiguration.kind, .codexChatGPT)
    let before = try invocationCount(database)
    do { try await coordinator.retry(expected); XCTFail("Role drift reused a captured retry") }
    catch { XCTAssertEqual(error as? ParsingRecoveryError, .staleContext) }
    XCTAssertEqual(try invocationCount(database), before)
    let calls = await producer.identities
    XCTAssertTrue(calls.isEmpty)
  }

  func testObservedRetryContextRefreshesAfterOnlyProviderConfigurationChanges() async throws {
    let (database, failed, root) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    var presentations = database.parsingPresentations(paperID: failed.paperID, includesRetry: true).makeAsyncIterator()
    let initial = try await presentations.next()
    let initialContext = try XCTUnwrap(initial?.retry)
    let unavailableCoordinator = ParsingRecoveryCoordinator(service: .init(database: database,
      producer: nil, geometryValidator: RejectingValidator()), currentEpoch: UUID())
    var feedback: ParsingRetryFailure?
    do { try await unavailableCoordinator.retry(initialContext); XCTFail("Missing parser admitted a retry") }
    catch { feedback = ParsingRetryFailure(error: error, context: initialContext) }
    let previousFailure = try XCTUnwrap(feedback)
    XCTAssertEqual(previousFailure.matching(initial)?.message, "PDF 파싱 서비스가 연결되지 않았습니다.")
    XCTAssertNil(previousFailure.matching(nil))

    let configuration = try database.compareAndSwapProviderConfiguration(expected: initialContext.currentConfiguration,
      replacementKind: .openAIAPIKey, replacementSlotID: UUID(), replacementModel: "fixture-model")
    let updated = try await presentations.next()
    let updatedContext = try XCTUnwrap(updated?.retry)
    XCTAssertEqual(updated?.status.state, "failed")
    XCTAssertEqual(updated?.status.failure, initial?.status.failure)
    XCTAssertEqual(updatedContext.failedAttempt, failed)
    XCTAssertEqual(updatedContext.currentConfiguration, configuration)
    XCTAssertNil(previousFailure.matching(updated), "An unchanged attempt ID must not preserve stale feedback")

    let producer = HeldFailureProducer()
    let coordinator = ParsingRecoveryCoordinator(service: .init(database: database,
      producer: producer, geometryValidator: RejectingValidator()), currentEpoch: UUID())
    do { try await coordinator.retry(initialContext); XCTFail("Previous configuration must be rejected") }
    catch {
      XCTAssertEqual(error as? ParsingRecoveryError, .staleContext)
      XCTAssertNil(ParsingRetryFailure(error: error, context: initialContext))
    }
    let retry = Task { try await coordinator.retry(updatedContext) }
    await producer.waitForStart()
    let running = try await presentations.next()
    XCTAssertEqual(running?.status.state, "running")
    XCTAssertNil(running?.retry)
    XCTAssertNil(previousFailure.matching(running))
    await producer.release()
    do { _ = try await retry.value; XCTFail("Controlled parser failure should propagate") }
    catch { XCTAssertEqual(error as? ExtractionError, .invalidBatch) }
    let repeated = try await presentations.next()
    XCTAssertEqual(repeated?.status.state, "failed")
    let newRetry = try XCTUnwrap(repeated?.retry)
    XCTAssertNotEqual(newRetry.failedAttempt.attempt, failed.attempt)
    XCTAssertEqual(newRetry.currentConfiguration, configuration)
    let admitted = await producer.identities
    XCTAssertEqual(admitted.map(\.configuration), [configuration])
  }

  func testPresentationSuppressesStaleFailureAndRejectsDeletedPaper() async throws {
    let (database, failed, root) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let coordinator = ParsingRecoveryCoordinator(service: .init(database: database,
      producer: nil, geometryValidator: nil), currentEpoch: UUID())
    let initial = try await coordinator.presentation(paperID: failed.paperID)
    XCTAssertNotNil(ParsingFailureNotice.message(status: initial.status, unavailable: false))
    XCTAssertNotNil(initial.retry)
    for (column, value) in [("generation", UUID().uuidString), ("pdfSHA256", String(repeating: "b", count: 64)),
      ("pdfReference", "papers/\(UUID().uuidString)/document.pdf"), ("deletionID", UUID().uuidString)] {
      let original = try database.adapterRead { try String.fetchOne($0, sql: "SELECT \(column) FROM paper") }
      try database.adapterWrite { try $0.execute(sql: "UPDATE paper SET \(column) = ?", arguments: [value]) }
      let presentation = try await coordinator.presentation(paperID: failed.paperID)
      XCTAssertEqual(presentation.status.state, "unavailable", column)
      XCTAssertNil(ParsingFailureNotice.message(status: presentation.status, unavailable: false), column)
      XCTAssertNil(presentation.retry, column)
      try database.adapterWrite { try $0.execute(sql: "UPDATE paper SET \(column) = ?", arguments: [original]) }
    }
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
    let columns = "attempt, generation, pdfSHA256, pdfReference, job, correlation, input, epoch, "
      + "configSlot, configGeneration, configKind, state, failure"
    let historical = try database.adapterRead {
      try XCTUnwrap(Row.fetchOne($0, sql: "SELECT \(columns) FROM extractionAttempt"))
    }
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
    let history = try reopened.adapterRead {
      try Row.fetchAll($0, sql: "SELECT \(columns) FROM extractionAttemptHistory")
    }
    XCTAssertEqual(history, [historical])
  }

  func testRetryTerminalWriteCanBeRecoveredWithoutDispatchingAgain() async throws {
    let (database, old, root) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let usable = UUID()
    try database.adapterWrite { db in
      try db.execute(sql: """
        INSERT INTO extractionRevision(id, paperID, generation, pdfSHA256, pdfReference)
        VALUES (?, ?, ?, ?, ?)
        """, arguments: [usable.uuidString, old.paperID.uuidString, old.generation.uuidString,
          old.pdfSHA256, old.pdfReference])
      try db.execute(sql: "INSERT INTO extractionVisible(paperID, revision) VALUES (?, ?)",
        arguments: [old.paperID.uuidString, usable.uuidString])
      try db.execute(sql: """
        CREATE TRIGGER ignoreFailedAttempt BEFORE UPDATE OF state ON extractionAttempt
        WHEN NEW.state = 'failed' BEGIN SELECT RAISE(IGNORE); END;
        """)
    }
    let producer = HeldFailureProducer()
    let coordinator = ParsingRecoveryCoordinator(service: .init(database: database,
      producer: producer, geometryValidator: RejectingValidator()), currentEpoch: UUID())
    let before = try await coordinator.presentation(paperID: old.paperID)
    let context = try XCTUnwrap(before.retry)
    let operation = Task { try await coordinator.retry(context) }
    await producer.waitForStart()
    let running = try await coordinator.presentation(paperID: old.paperID)
    XCTAssertNil(running.pendingTerminalAttempt)
    await producer.release()
    do { try await operation.value; XCTFail("Uncommitted failure reported success") }
    catch { XCTAssertEqual(error as? ExtractionError, .storageFailure) }

    let pending = try await coordinator.presentation(paperID: old.paperID)
    let attempt = try XCTUnwrap(pending.pendingTerminalAttempt)
    XCTAssertEqual(pending.status.state, "running")
    XCTAssertEqual(pending.status.usableRevision, usable)
    XCTAssertNil(pending.retry)
    XCTAssertEqual(ParsingFailureNotice.message(status: pending.status, unavailable: false,
      terminalWritePending: true), "파싱 종료 상태를 저장하지 못했습니다.")
    do { try await coordinator.retry(context); XCTFail("Old Retry created another attempt") }
    catch { XCTAssertEqual(error as? ParsingRecoveryError, .staleContext) }
    do { try await coordinator.recoverTerminalWrite(attempt); XCTFail("Ignored write reported success") }
    catch { XCTAssertEqual(error as? ExtractionError, .storageFailure) }
    let stillPending = try await coordinator.presentation(paperID: old.paperID)
    XCTAssertEqual(stillPending.pendingTerminalAttempt, attempt)

    try database.adapterWrite { try $0.execute(sql: "DROP TRIGGER ignoreFailedAttempt") }
    try await coordinator.recoverTerminalWrite(old)
    XCTAssertEqual(try database.extractionStatus(paperID: old.paperID).state, "running")
    try await coordinator.recoverTerminalWrite(attempt)
    let recovered = try await coordinator.presentation(paperID: old.paperID)
    XCTAssertNil(recovered.pendingTerminalAttempt)
    XCTAssertEqual(recovered.retry?.failedAttempt, attempt)
    XCTAssertEqual(recovered.retry?.usableRevision, usable)
    let reopened = try ProductDatabase.open(at: root)
    XCTAssertEqual(try reopened.extractionStatus(paperID: old.paperID).failure, "invalidBatch")
    XCTAssertEqual(try invocationCount(reopened), 2)
    let calls = await producer.identities
    XCTAssertEqual(calls, [attempt])
  }

  func testFailedRetryReservationRollsBackHistoryAndKeepsCurrentFailure() async throws {
    let (database, old, root) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let producer = HeldFailureProducer()
    let coordinator = ParsingRecoveryCoordinator(service: .init(database: database,
      producer: producer, geometryValidator: RejectingValidator()), currentEpoch: UUID())
    let before = try await coordinator.context(paperID: old.paperID)
    let context = try XCTUnwrap(before)
    try database.adapterWrite { db in
      try db.execute(sql: """
        CREATE TRIGGER rejectNewAttempt BEFORE INSERT ON extractionAttempt BEGIN
          SELECT RAISE(ABORT, 'fixture rejects replacement');
        END;
        """)
    }
    do { try await coordinator.retry(context); XCTFail("replacement was admitted") }
    catch { XCTAssertTrue(error is DatabaseError) }
    let after = try await coordinator.context(paperID: old.paperID)
    XCTAssertEqual(after, context)
    XCTAssertEqual(try invocationCount(database), 1)
    XCTAssertEqual(try database.adapterRead {
      try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM extractionAttemptHistory")
    }, 0)
  }

  func testIncompleteRetryReservationRetainsFailedAttemptWithoutDispatch() async throws {
    for mutation in [
      "BEFORE INSERT ON extractionInvocation BEGIN SELECT RAISE(IGNORE); END",
      "BEFORE INSERT ON extractionAttempt BEGIN SELECT RAISE(IGNORE); END",
      """
      AFTER INSERT ON extractionAttempt BEGIN
        UPDATE extractionInvocation SET fence = 'wrong-fence' WHERE attempt = NEW.attempt;
      END
      """,
    ] {
      let (database, old, root) = try fixture()
      defer { try? FileManager.default.removeItem(at: root) }
      let producer = UnexpectedDispatchProducer()
      let coordinator = ParsingRecoveryCoordinator(service: .init(database: database,
        producer: producer, geometryValidator: RejectingValidator()), currentEpoch: UUID())
      let before = try await coordinator.presentation(paperID: old.paperID)
      let expected = try XCTUnwrap(before.retry)
      try database.adapterWrite { try $0.execute(sql: "CREATE TRIGGER alterReservation \(mutation)") }

      do { try await coordinator.retry(expected); XCTFail("Incomplete reservation was dispatched") }
      catch { XCTAssertEqual(error as? ExtractionError, .reservationFailure, mutation) }

      let calls = await producer.invocationCount
      XCTAssertEqual(calls, 0, mutation)
      let reopened = try ProductDatabase.open(at: root)
      let status = try reopened.extractionStatus(paperID: old.paperID)
      XCTAssertEqual(status.state, before.status.state, mutation)
      XCTAssertEqual(status.failure, before.status.failure, mutation)
      XCTAssertEqual(status.usableRevision, before.status.usableRevision, mutation)
      XCTAssertEqual(try invocationCount(reopened), 1, mutation)
      XCTAssertEqual(try reopened.adapterRead {
        try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM extractionAttemptHistory")
      }, 0, mutation)
      let reopenedCoordinator = ParsingRecoveryCoordinator(service: .init(database: reopened,
        producer: producer, geometryValidator: RejectingValidator()), currentEpoch: UUID())
      let after = try await reopenedCoordinator.context(paperID: old.paperID)
      XCTAssertEqual(after, expected, mutation)
    }
  }

  func testIncompleteInitialReservationPersistsExplicitRetryWithoutDispatch() async throws {
    let (database, identity, root) = try fixture(reserve: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let producer = UnexpectedDispatchProducer()
    let service = ExtractionRevisionService(database: database, producer: producer,
      geometryValidator: RejectingValidator())
    try database.adapterWrite { db in
      try db.execute(sql: """
        CREATE TRIGGER ignoreInitialReservation BEFORE INSERT ON extractionAttempt
        WHEN NEW.state = 'running' BEGIN SELECT RAISE(IGNORE); END;
        """)
    }

    do {
      try await service.parse(identity, firstInvocationOnly: true)
      XCTFail("Incomplete reservation was dispatched")
    } catch { XCTAssertEqual(error as? ExtractionError, .reservationFailure) }

    let calls = await producer.invocationCount
    XCTAssertEqual(calls, 0)
    XCTAssertEqual(try invocationCount(database), 1)
    let coordinator = ParsingRecoveryCoordinator(service: service, currentEpoch: identity.epoch)
    let failure = try await coordinator.presentation(paperID: identity.paperID)
    XCTAssertEqual(failure.status.state, "failed")
    XCTAssertEqual(failure.status.failure, ExtractionError.reservationFailure.rawValue)
    XCTAssertEqual(failure.retry?.failedAttempt, identity)
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
    XCTAssertEqual(try database.adapterRead {
      try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM extractionAttemptHistory")
    }, 1)
    let saga = try XCTUnwrap(database.beginDeletion(old.paperID)).saga
    let deletedContext = try await coordinator.context(paperID: old.paperID)
    XCTAssertNil(deletedContext)
    let identities = await producer.identities
    let fresh = try XCTUnwrap(identities.first)
    XCTAssertThrowsError(try publishFixtureExtraction(database, fresh, sentences: [
      .init(page: 0, sentenceID: 0, text: "late", geometry: Data([1])),
    ]))
    await producer.release()
    do { try await first.value; XCTFail("deleted failure reported as success") } catch {}
    try database.finalizeDeletion(old.paperID, saga: saga)
    do { try await coordinator.retry(context); XCTFail("deleted paper admitted") }
    catch { XCTAssertEqual(error as? ParsingRecoveryError, .staleContext) }
    XCTAssertEqual(try invocationCount(database), 0)
    XCTAssertEqual(try database.adapterRead {
      try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM extractionAttemptHistory")
    }, 0)
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

  func testFloatingNoticeTracksPersistedRetryAndReopenWithoutHidingUsableRevision() async throws {
    let (database, old, root) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let usable = UUID()
    // Storage-only retained-revision fixture; not a calibrated parsing result.
    try database.adapterWrite { db in
      try db.execute(sql: """
        INSERT INTO extractionRevision(id, paperID, generation, pdfSHA256, pdfReference)
        VALUES (?, ?, ?, ?, ?)
        """, arguments: [usable.uuidString, old.paperID.uuidString, old.generation.uuidString,
          old.pdfSHA256, old.pdfReference])
      try db.execute(sql: "INSERT INTO extractionVisible(paperID, revision) VALUES (?, ?)",
        arguments: [old.paperID.uuidString, usable.uuidString])
    }
    let producer = HeldFailureProducer(failure: .storageFailure)
    let coordinator = ParsingRecoveryCoordinator(service: .init(database: database,
      producer: producer, geometryValidator: RejectingValidator()), currentEpoch: UUID())
    let failed = try await coordinator.presentation(paperID: old.paperID)
    XCTAssertEqual(failed.status.usableRevision, usable)
    XCTAssertEqual(ParsingFailureNotice.message(status: failed.status, unavailable: false),
      "원문 파싱 결과를 검증하지 못했습니다. 다시 시도하세요.")
    let context = try XCTUnwrap(failed.retry)
    XCTAssertEqual(context.failedAttempt.attempt, old.attempt)
    XCTAssertEqual(context.usableRevision, usable)
    let retry = Task { try await coordinator.retry(context) }
    await producer.waitForStart()
    let running = try await coordinator.presentation(paperID: old.paperID)
    XCTAssertEqual(running.status.state, "running")
    XCTAssertEqual(running.status.usableRevision, usable)
    XCTAssertNil(running.retry)
    XCTAssertNil(ParsingFailureNotice.message(status: running.status, unavailable: false))
    await producer.release()
    do { try await retry.value; XCTFail("controlled failure reported success") }
    catch { XCTAssertEqual(error as? ExtractionError, .storageFailure) }
    let reopened = try ProductDatabase.open(at: root)
    let reopenedCoordinator = ParsingRecoveryCoordinator(service: .init(database: reopened,
      producer: producer, geometryValidator: RejectingValidator()), currentEpoch: UUID())
    let latest = try await reopenedCoordinator.presentation(paperID: old.paperID)
    XCTAssertEqual(latest.status.usableRevision, usable)
    XCTAssertEqual(ParsingFailureNotice.message(status: latest.status, unavailable: false),
      "원문 파싱 결과를 저장하지 못했습니다. 다시 시도하세요.")
    XCTAssertNil(ParsingFailureNotice.message(status: latest.status, unavailable: true))
    let currentRetry = try XCTUnwrap(latest.retry)
    let retryIdentities = await producer.identities
    XCTAssertEqual(currentRetry.failedAttempt.attempt, retryIdentities.first?.attempt)
    XCTAssertEqual(currentRetry.usableRevision, usable)
    do { try await reopenedCoordinator.retry(context); XCTFail("old presentation retried a newer failure") }
    catch { XCTAssertEqual(error as? ParsingRecoveryError, .staleContext) }
    XCTAssertEqual(try invocationCount(reopened), 2)
    XCTAssertEqual(try reopened.extractionStatus(paperID: old.paperID).failure, "storageFailure")
    _ = try XCTUnwrap(reopened.beginDeletion(old.paperID))
    let deleting = try reopened.extractionStatus(paperID: old.paperID)
    XCTAssertEqual(deleting.state, "unavailable")
    XCTAssertNil(ParsingFailureNotice.message(status: deleting, unavailable: false))
  }

  func testFloatingNoticeNeverLeaksDiagnosticsOrSurvivesNonfailedStatus() {
    let diagnostic = "secret/path token=private duration=9 attempt=42"
    for revision in [Optional<UUID>.none, UUID()] {
      for state in ["running", "succeeded", "unavailable", "notStarted"] {
        let status = ExtractionStatus(state: state, failure: diagnostic, usableRevision: revision)
        XCTAssertNil(ParsingFailureNotice.message(status: status, unavailable: false), state)
      }
      let unknown = ExtractionStatus(state: "failed", failure: diagnostic, usableRevision: revision)
      XCTAssertEqual(ParsingFailureNotice.message(status: unknown, unavailable: false),
        "원문 파싱에 실패했습니다. 다시 시도하세요.")
      XCTAssertNil(ParsingFailureNotice.message(status: unknown, unavailable: true))
      let missingReason = ExtractionStatus(state: "failed", failure: nil, usableRevision: revision)
      XCTAssertEqual(ParsingFailureNotice.message(status: missingReason, unavailable: false),
        "원문 파싱에 실패했습니다. 다시 시도하세요.")
    }
    XCTAssertNil(ParsingFailureNotice.message(status: nil, unavailable: false))
  }

  @MainActor func testParsingStatusDeliversAndClearsNoticeAtReaderSplitBoundary() async throws {
    let (database, identity, root) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let reported = expectation(description: "Failure reaches the Reader outside the right panel")
    let cleared = expectation(description: "Deletion clears the Reader failure notice")
    var didReportFailure = false
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 560),
      styleMask: [.borderless], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    window.contentView = NSHostingView(rootView: HSplitView {
      Color.clear.frame(minWidth: 240)
      ParsingStatusView(database: database, paperID: identity.paperID,
        onUsableRevisionChange: { true }).frame(minWidth: 240)
    }.onPreferenceChange(ParsingFailureNotice.self) { message in
      if !didReportFailure, message == "원문 파싱 결과를 검증하지 못했습니다. 다시 시도하세요." {
        didReportFailure = true
        reported.fulfill()
      } else if didReportFailure, message == nil {
        cleared.fulfill()
      }
    })
    window.contentView?.layoutSubtreeIfNeeded()
    await fulfillment(of: [reported], timeout: 4)
    _ = try XCTUnwrap(database.beginDeletion(identity.paperID))
    await fulfillment(of: [cleared], timeout: 4)
  }

  @MainActor func testCommittedParsingFailureAppearsWhileReaderMetadataRefreshWaits() async throws {
    let (database, identity, root) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    try database.adapterWrite {
      try $0.execute(sql: "UPDATE extractionAttempt SET state = 'running', failure = NULL")
    }
    let metadataStarted = expectation(description: "Reader started its initial metadata refresh")
    let reported = expectation(description: "Committed failure reaches the Reader before metadata refresh completes")
    var releaseMetadata: CheckedContinuation<Void, Never>?
    var metadataRequests = 0
    var didReportFailure = false
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 560),
      styleMask: [.borderless], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    defer {
      releaseMetadata?.resume()
      window.close()
    }
    window.contentView = NSHostingView(rootView: HSplitView {
      Color.clear.frame(minWidth: 240)
      ParsingStatusView(database: database, paperID: identity.paperID,
        onUsableRevisionChange: {
          metadataRequests += 1
          if metadataRequests == 1 {
            await withCheckedContinuation {
              releaseMetadata = $0
              metadataStarted.fulfill()
            }
          }
          return true
        }).frame(minWidth: 240)
    }.onPreferenceChange(ParsingFailureNotice.self) { message in
      if !didReportFailure, message == "원문 파싱 결과를 저장하지 못했습니다. 다시 시도하세요." {
        didReportFailure = true
        reported.fulfill()
      }
    })
    window.contentView?.layoutSubtreeIfNeeded()
    await fulfillment(of: [metadataStarted], timeout: 4)
    try database.failExtraction(identity, failure: .storageFailure)
    await fulfillment(of: [reported], timeout: 2)
    XCTAssertEqual(metadataRequests, 1)
  }

  func testFailureMessagesNeverExposeWorkerDiagnostics() {
    let diagnostic = "secret/path token=private duration=9 attempt=42"
    XCTAssertEqual(ParsingFailureMessage.korean(diagnostic),
      "원문 파싱에 실패했습니다. 다시 시도하세요.")
    XCTAssertEqual(ParsingFailureMessage.korean("invalidBatch"),
      "원문 파싱 결과를 검증하지 못했습니다. 다시 시도하세요.")
  }
}
