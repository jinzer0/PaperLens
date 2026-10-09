import Foundation
import GRDB
import XCTest
@testable import PaperLensProduct

final class ExtractionRevisionTests: XCTestCase {
  private actor DispatchCensus: ExtractionBatchProducing {
    private(set) var calls = 0
    func withBatches(_ identity: ExtractionIdentity,
      consume: @escaping @Sendable ([ExtractionBatch], ExtractionConsumptionScope) async throws -> Void) async throws {
      calls += 1
      throw ExtractionError.invalidBatch
    }
  }
  private struct UnboundGeometry: ExtractionGeometryInput {}
  private struct RejectingGeometryValidator: ExtractionGeometryValidating {
    func validateAndEncode(_ input: any ExtractionGeometryInput,
      identity: ExtractionSentenceIdentity, expectedText: String) throws -> ExtractionGeometryEncoding {
      throw ExtractionError.geometryUnavailable
    }
  }
  private func fixture() throws -> (ProductDatabase, UUID, UUID, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let db = try ProductDatabase.open(at: root)
    let paper = UUID(), generation = UUID()
    try db.adapterWrite { sql in
      try sql.execute(sql: """
        INSERT INTO paper(id, generation, title, status, pdfReference, pdfSHA256, createdAt)
        VALUES (?, ?, 'fixture', 'ready', ?, ?, 0)
        """, arguments: [paper.uuidString, generation.uuidString,
          "papers/\(paper.uuidString)/document.pdf", String(repeating: "a", count: 64)])
    }
    return (db, paper, generation, root)
  }

  private func identity(_ db: ProductDatabase, _ paper: UUID, _ generation: UUID,
    epoch: UUID = UUID()) throws -> ExtractionIdentity {
    .init(paperID: paper, generation: generation, pdfSHA256: String(repeating: "a", count: 64),
      pdfReference: "papers/\(paper.uuidString)/document.pdf", revision: UUID(), job: UUID(),
      attempt: UUID(), fence: UUID(), correlation: UUID(), input: UUID(), epoch: epoch,
      configuration: try db.providerConfiguration())
  }

  // These storage fixtures bypass the geometry boundary deliberately. They prove atomic
  // BLOB/text/index persistence, not PDFium production or canonical geometry calibration.
  private func rows(_ text: String) -> [ValidatedExtractionSentence] {
    [.init(page: 0, sentenceID: 0, text: text, geometry: Data([1, 2, 3]))]
  }

  private func canonicalBatch(_ id: ExtractionIdentity, quote: String, text: String) throws
    -> (ExtractionBatch, CanonicalExtractionGeometryValidator) {
    // Synthetic geometry and precision for contract tests, not a production PDF/profile.
    let key = ExtractionSentenceIdentity(paperID: id.paperID, pdfSHA256: id.pdfSHA256,
      revision: id.revision, page: 0, sentenceID: 0)
    let page = try PDFPageGeometry(pageIndex: 0, cropOrigin: PDFPoint(x: 0, y: 0),
      width: 100, height: 100, rotation: 0)
    let first = try PDFQuad(topLeft: PDFPoint(x: 10, y: 90), topRight: PDFPoint(x: 90, y: 90),
      bottomRight: PDFPoint(x: 90, y: 80), bottomLeft: PDFPoint(x: 10, y: 80), page: page)
    let continuation = try PDFQuad(topLeft: PDFPoint(x: 10, y: 70), topRight: PDFPoint(x: 80, y: 70),
      bottomRight: PDFPoint(x: 80, y: 60), bottomLeft: PDFPoint(x: 10, y: 60), page: page)
    let anchor = try PDFSentenceAnchor(identity: PDFSentenceIdentity(paperID: key.paperID,
      pdfSHA256: key.pdfSHA256, extractionRevision: key.revision.uuidString.lowercased(),
      pageIndex: key.page, sentenceID: key.sentenceID), fullSourceQuote: quote,
      page: page, quads: [first, continuation])
    let validator = try CanonicalExtractionGeometryValidator(owningAnchors: [anchor],
      precision: PDFGeometryPrecision(maximumErrorPDFPoints: 0))
    let batch = ExtractionBatch(identity: id, sequence: 0, sentences: [
      .init(identity: key, text: text, geometry: CanonicalExtractionGeometryInput(anchor: anchor)),
    ], complete: true, totalSentences: 1)
    return (batch, validator)
  }

  func testCanonicalTextMismatchRejectsBeforePersistenceAndRetainsUsableRevision() throws {
    let (db, paper, generation, root) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let quote = "Original café sentence\nincluding its continuation."
    let first = try identity(db, paper, generation)
    let (originalBatch, originalValidator) = try canonicalBatch(first, quote: quote, text: quote)
    try db.reserveExtraction(first)
    let originalRows = try ExtractionRevisionService.validate([originalBatch], identity: first,
      validator: originalValidator, scope: fixtureExtractionScope())
    XCTAssertTrue(try XCTUnwrap(originalRows.first).text.utf8.elementsEqual(quote.utf8))
    try publishFixtureExtraction(db, first, sentences: originalRows)
    let original = try XCTUnwrap(db.searchExtraction(paperID: paper, matching: "Original").first)
    XCTAssertTrue(original.text.utf8.elementsEqual(quote.utf8))
    let decoded = try originalValidator.decodeAndValidate(original.canonicalGeometry,
      identity: originalBatch.sentences[0].identity)
    XCTAssertTrue(decoded.fullSourceQuote.utf8.elementsEqual(quote.utf8))

    for text in ["Different sentence.", "Original café sentence",
      "Original café sentence including its continuation.",
      "Original café sentence\nincluding a different continuation.",
      "Original café sentence\nincluding its continuation."] {
      let next = try identity(db, paper, generation)
      let (batch, validator) = try canonicalBatch(next, quote: quote, text: text)
      try db.reserveExtraction(next)
      // Exercise the service's actual pre-publication boundary with the real GRDB owner.
      XCTAssertThrowsError(try ExtractionRevisionService.validate([batch], identity: next,
        validator: validator, scope: fixtureExtractionScope())) {
        XCTAssertEqual($0 as? CanonicalExtractionGeometryError, .semanticExtentMismatch)
      }
      XCTAssertEqual(try db.adapterRead { try Int.fetchOne($0,
        sql: "SELECT COUNT(*) FROM extractionRevision WHERE id = ?",
        arguments: [next.revision.uuidString]) }, 0)
      XCTAssertEqual(try db.adapterRead { try Int.fetchOne($0,
        sql: "SELECT COUNT(*) FROM extractionSentence WHERE revision = ?",
        arguments: [next.revision.uuidString]) }, 0)
      // parse maps a non-ExtractionError validation failure to storageFailure.
      try db.failExtraction(next, failure: .storageFailure)
      let status = try db.extractionStatus(paperID: paper)
      XCTAssertEqual(status.failure, "storageFailure")
      XCTAssertEqual(status.usableRevision, first.revision)
      let retained = try XCTUnwrap(db.searchExtraction(paperID: paper, matching: "Original").first)
      XCTAssertEqual(retained.revision, first.revision)
      XCTAssertTrue(retained.text.utf8.elementsEqual(quote.utf8))
      XCTAssertEqual(retained.canonicalGeometry, original.canonicalGeometry)
      XCTAssertEqual(try db.adapterRead { try Int.fetchOne($0,
        sql: "SELECT COUNT(*) FROM extractionFTS") }, 1)
    }
    let reopened = try ProductDatabase.open(at: root)
    XCTAssertEqual(try reopened.extractionStatus(paperID: paper).usableRevision, first.revision)
    XCTAssertEqual(try reopened.searchExtraction(paperID: paper, matching: "Original").first?
      .canonicalGeometry, original.canonicalGeometry)
  }

  func testPublishSearchRetainsPinnedOldRevisionAndRestart() throws {
    let (db, paper, generation, root) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let first = try identity(db, paper, generation)
    try db.reserveExtraction(first)
    XCTAssertTrue(try db.searchExtraction(paperID: paper, matching: "alpha").isEmpty)
    try publishFixtureExtraction(db, first, sentences: rows("alpha original"))
    let second = try identity(db, paper, generation)
    try db.reserveExtraction(second)
    XCTAssertEqual(try db.searchExtraction(paperID: paper, matching: "alpha").first?.revision, first.revision)
    try publishFixtureExtraction(db, second, sentences: rows("beta replacement"))
    XCTAssertTrue(try db.searchExtraction(paperID: paper, matching: "alpha").isEmpty)
    XCTAssertEqual(try db.searchExtraction(paperID: paper, matching: "alpha", revision: first.revision).first?.text,
      "alpha original")
    XCTAssertEqual(try db.lookupExtraction(.init(paperID: paper, pdfSHA256: first.pdfSHA256,
      revision: first.revision, page: 0, sentenceID: 0))?.text, "alpha original")
    XCTAssertNil(try db.lookupExtraction(.init(paperID: UUID(), pdfSHA256: first.pdfSHA256,
      revision: first.revision, page: 0, sentenceID: 0)))
    XCTAssertNil(try db.lookupExtraction(.init(paperID: paper, pdfSHA256: first.pdfSHA256,
      revision: first.revision, page: 1, sentenceID: 0)))
    let reopened = try ProductDatabase.open(at: root)
    XCTAssertEqual(try reopened.extractionStatus(paperID: paper).usableRevision, second.revision)
    XCTAssertEqual(try reopened.searchExtraction(paperID: paper, matching: "beta").first?.canonicalGeometry,
      Data([1, 2, 3]))
  }

  func testFTSFailureRollsBackEveryRowAndKeepsPreviousUsableRevision() throws {
    let (db, paper, generation, root) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let first = try identity(db, paper, generation)
    try db.reserveExtraction(first)
    try publishFixtureExtraction(db, first, sentences: rows("original"))
    let next = try identity(db, paper, generation)
    try db.reserveExtraction(next)
    try db.adapterWrite { sql in
      try sql.execute(sql: """
        DROP TRIGGER extractionSentenceInsert;
        CREATE TRIGGER extractionSentenceInsert AFTER INSERT ON extractionSentence BEGIN
          INSERT INTO extractionFTS(rowid, text) VALUES (new.id, new.text);
          SELECT CASE WHEN new.text = 'broken' THEN RAISE(ABORT, 'injected FTS build failure') END;
        END;
        """)
    }
    XCTAssertThrowsError(try publishFixtureExtraction(db, next, sentences: rows("broken")))
    try db.failExtraction(next, failure: .storageFailure)
    XCTAssertEqual(try db.extractionStatus(paperID: paper).usableRevision, first.revision)
    XCTAssertEqual(try db.adapterRead { try Int.fetchOne($0,
      sql: "SELECT COUNT(*) FROM extractionRevision WHERE id = ?", arguments: [next.revision.uuidString]) }, 0)
    XCTAssertTrue(try db.searchExtraction(paperID: paper, matching: "broken").isEmpty)
    XCTAssertEqual(try db.searchExtraction(paperID: paper, matching: "original").count, 1)
  }

  func testEveryPersistedAttemptFenceIsRevalidatedBeforeWriting() throws {
    let (db, paper, generation, root) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let id = try identity(db, paper, generation)
    try db.reserveExtraction(id)
    for column in ["generation", "pdfSHA256", "pdfReference", "revision", "job", "attempt",
      "fence", "correlation", "input", "epoch", "configGeneration", "state"] {
      let original = try db.adapterRead { sql in
        try String.fetchOne(sql,
          sql: "SELECT CAST(\(column) AS TEXT) FROM extractionAttempt WHERE paperID = ?",
          arguments: [paper.uuidString])
      }
      try db.adapterWrite { sql in
        try sql.execute(sql: "UPDATE extractionAttempt SET \(column) = ? WHERE paperID = ?",
          arguments: [column == "configGeneration" ? "999" : UUID().uuidString, paper.uuidString])
      }
      XCTAssertThrowsError(try publishFixtureExtraction(db, id, sentences: rows("mustnotpublish")))
      try db.adapterWrite { sql in
        try sql.execute(sql: "UPDATE extractionAttempt SET \(column) = ? WHERE paperID = ?",
          arguments: [original, paper.uuidString])
      }
    }
    XCTAssertNil(try db.extractionStatus(paperID: paper).usableRevision)
  }

  func testRestartStaleConfigurationAndDeletionDoNotResurrect() throws {
    let (db, paper, generation, root) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let first = try identity(db, paper, generation)
    try db.reserveExtraction(first)
    try publishFixtureExtraction(db, first, sentences: rows("retained"))
    let pending = try identity(db, paper, generation)
    try db.reserveExtraction(pending)
    _ = try ProductJobRecovery(database: db).recoverStartup(currentEpoch: UUID())
    XCTAssertThrowsError(try publishFixtureExtraction(db, pending, sentences: rows("late")))
    XCTAssertEqual(try db.extractionStatus(paperID: paper).failure, "interrupted")
    let retry = try identity(db, paper, generation)
    try db.reserveExtraction(retry)
    _ = try db.compareAndSwapProviderConfiguration(expected: retry.configuration, replacementSlotID: UUID(),
      replacementModel: "fixture-snapshot")
    XCTAssertThrowsError(try publishFixtureExtraction(db, retry, sentences: rows("stale")))
    let saga = try XCTUnwrap(db.beginDeletion(paper))
    XCTAssertTrue(try db.searchExtraction(paperID: paper, matching: "retained").isEmpty)
    try db.finalizeDeletion(paper, saga: saga)
    XCTAssertThrowsError(try publishFixtureExtraction(db, retry, sentences: rows("resurrected")))
    XCTAssertEqual(try db.adapterRead { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM extractionFTS") }, 0)
    XCTAssertEqual(try db.adapterRead { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM extractionSentence") }, 0)
    XCTAssertEqual(try db.adapterRead { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM extractionRevision") }, 0)
  }

  func testBudgetExhaustionRollsBackRowsIndexVisibilityAndJobState() throws {
    let (db, paper, generation, root) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let original = try identity(db, paper, generation)
    try db.reserveExtraction(original)
    try publishFixtureExtraction(db, original, sentences: rows("retained"))
    let pending = try identity(db, paper, generation)
    try db.reserveExtraction(pending)
    for permittedChecks in 0..<4 {
      let budget = ExtractionFixtureBudget(maximumChecks: permittedChecks)
      XCTAssertThrowsError(try db.publishExtraction(pending, sentences: rows("forbidden"),
        checkBudget: { try budget.check() })) {
        XCTAssertTrue($0 is ExtractionFixtureBudget.Failure)
      }
      XCTAssertEqual(try db.extractionStatus(paperID: paper).usableRevision, original.revision)
      XCTAssertNil(try db.extractionStatus(paperID: paper).failure)
      XCTAssertEqual(try db.adapterRead { try String.fetchOne($0,
        sql: "SELECT state FROM extractionAttempt WHERE paperID = ?",
        arguments: [paper.uuidString]) }, "running")
      XCTAssertEqual(try db.adapterRead { try Int.fetchOne($0,
        sql: "SELECT COUNT(*) FROM extractionRevision WHERE id = ?",
        arguments: [pending.revision.uuidString]) }, 0)
      XCTAssertEqual(try db.adapterRead { try Int.fetchOne($0,
        sql: "SELECT COUNT(*) FROM extractionSentence WHERE revision = ?",
        arguments: [pending.revision.uuidString]) }, 0)
      XCTAssertTrue(try db.searchExtraction(paperID: paper, matching: "forbidden").isEmpty)
      XCTAssertEqual(try db.searchExtraction(paperID: paper, matching: "retained").count, 1)
    }
  }

  func testAlreadyCancelledParseCreatesNoDurableIntentOrProducerDispatch() async throws {
    let (db, paper, generation, root) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let id = try identity(db, paper, generation)
    let producer = DispatchCensus()
    let service = ExtractionRevisionService(database: db, producer: producer,
      geometryValidator: RejectingGeometryValidator())
    let request = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      try await service.parse(id)
    }
    do { try await request.value; XCTFail("Cancelled action was admitted") }
    catch { XCTAssertTrue(error is CancellationError) }
    let dispatches = await producer.calls
    XCTAssertEqual(dispatches, 0)
    for table in ["extractionInvocation", "extractionAttempt", "extractionRevision"] {
      XCTAssertEqual(try db.adapterRead { try Int.fetchOne($0,
        sql: "SELECT COUNT(*) FROM \(table)") }, 0)
    }
    XCTAssertNil(try db.extractionStatus(paperID: paper).failure)
    XCTAssertNil(try db.extractionStatus(paperID: paper).usableRevision)
  }

  func testAbsentProducerRejectsBeforeReservationWithoutUsableRevision() async throws {
    let (db, paper, generation, root) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let id = try identity(db, paper, generation)
    let service = ExtractionRevisionService(database: db, producer: nil, geometryValidator: nil)
    do { try await service.parse(id); XCTFail("missing producer must fail") }
    catch { XCTAssertEqual(error as? ExtractionError, .producerUnavailable) }
    XCTAssertNil(try db.extractionStatus(paperID: paper).failure)
    XCTAssertEqual(try db.adapterRead { try Int.fetchOne($0,
      sql: "SELECT COUNT(*) FROM extractionInvocation") }, 0)
    XCTAssertNil(try db.extractionStatus(paperID: paper).usableRevision)
  }

  func testIncompleteBatchWrongIdentityAndUnknownGeometryReject() throws {
    let (db, paper, generation, root) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let id = try identity(db, paper, generation)
    let sentence = ExtractionSentenceInput(identity: .init(paperID: paper,
      pdfSHA256: id.pdfSHA256, revision: id.revision, page: 0, sentenceID: 0),
      text: "unvalidated", geometry: UnboundGeometry())
    let validator = RejectingGeometryValidator()
    let incomplete = ExtractionBatch(identity: id, sequence: 0, sentences: [sentence],
      complete: false, totalSentences: nil)
    XCTAssertThrowsError(try ExtractionRevisionService.validate([incomplete], identity: id,
      validator: validator, scope: fixtureExtractionScope())) { XCTAssertEqual($0 as? ExtractionError, .invalidBatch) }
    let wrong = ExtractionBatch(identity: try identity(db, paper, generation), sequence: 0,
      sentences: [sentence], complete: true, totalSentences: 1)
    XCTAssertThrowsError(try ExtractionRevisionService.validate([wrong], identity: id,
      validator: validator, scope: fixtureExtractionScope())) { XCTAssertEqual($0 as? ExtractionError, .invalidBatch) }
    let unbound = ExtractionBatch(identity: id, sequence: 0, sentences: [sentence],
      complete: true, totalSentences: 1)
    XCTAssertThrowsError(try ExtractionRevisionService.validate([unbound], identity: id,
      validator: validator, scope: fixtureExtractionScope())) { XCTAssertEqual($0 as? ExtractionError, .geometryUnavailable) }
  }
}
