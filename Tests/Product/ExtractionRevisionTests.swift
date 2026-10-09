import Foundation
import GRDB
import XCTest
@testable import PaperLensProduct

final class ExtractionRevisionTests: XCTestCase {
  private struct UnboundGeometry: ExtractionGeometryInput {}
  private struct RejectingGeometryValidator: ExtractionGeometryValidating {
    func validateAndEncode(_ input: any ExtractionGeometryInput,
      identity: ExtractionSentenceIdentity) throws -> ExtractionGeometryEncoding {
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

  func testPublishSearchRetainsPinnedOldRevisionAndRestart() throws {
    let (db, paper, generation, root) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let first = try identity(db, paper, generation)
    try db.reserveExtraction(first)
    XCTAssertTrue(try db.searchExtraction(paperID: paper, matching: "alpha").isEmpty)
    try db.publishExtraction(first, sentences: rows("alpha original"))
    let second = try identity(db, paper, generation)
    try db.reserveExtraction(second)
    XCTAssertEqual(try db.searchExtraction(paperID: paper, matching: "alpha").first?.revision, first.revision)
    try db.publishExtraction(second, sentences: rows("beta replacement"))
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
    try db.publishExtraction(first, sentences: rows("original"))
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
    XCTAssertThrowsError(try db.publishExtraction(next, sentences: rows("broken")))
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
      XCTAssertThrowsError(try db.publishExtraction(id, sentences: rows("mustnotpublish")))
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
    try db.publishExtraction(first, sentences: rows("retained"))
    let pending = try identity(db, paper, generation)
    try db.reserveExtraction(pending)
    try db.recoverInterruptedExtractions(currentEpoch: UUID())
    XCTAssertThrowsError(try db.publishExtraction(pending, sentences: rows("late")))
    XCTAssertEqual(try db.extractionStatus(paperID: paper).failure, "interrupted")
    let retry = try identity(db, paper, generation)
    try db.reserveExtraction(retry)
    _ = try db.compareAndSwapProviderConfiguration(expected: retry.configuration, replacementSlotID: UUID(),
      replacementModel: "fixture-snapshot")
    XCTAssertThrowsError(try db.publishExtraction(retry, sentences: rows("stale")))
    let saga = try XCTUnwrap(db.beginDeletion(paper))
    XCTAssertTrue(try db.searchExtraction(paperID: paper, matching: "retained").isEmpty)
    try db.finalizeDeletion(paper, saga: saga)
    XCTAssertThrowsError(try db.publishExtraction(retry, sentences: rows("resurrected")))
    XCTAssertEqual(try db.adapterRead { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM extractionFTS") }, 0)
    XCTAssertEqual(try db.adapterRead { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM extractionSentence") }, 0)
    XCTAssertEqual(try db.adapterRead { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM extractionRevision") }, 0)
  }

  func testAbsentProducerPersistsExplicitFailureWithoutUsableRevision() async throws {
    let (db, paper, generation, root) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let id = try identity(db, paper, generation)
    let service = ExtractionRevisionService(database: db, producer: nil, geometryValidator: nil)
    do { try await service.parse(id); XCTFail("missing producer must fail") }
    catch { XCTAssertEqual(error as? ExtractionError, .producerUnavailable) }
    XCTAssertEqual(try db.extractionStatus(paperID: paper).failure, "producerUnavailable")
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
      validator: validator)) { XCTAssertEqual($0 as? ExtractionError, .invalidBatch) }
    let wrong = ExtractionBatch(identity: try identity(db, paper, generation), sequence: 0,
      sentences: [sentence], complete: true, totalSentences: 1)
    XCTAssertThrowsError(try ExtractionRevisionService.validate([wrong], identity: id,
      validator: validator)) { XCTAssertEqual($0 as? ExtractionError, .invalidBatch) }
    let unbound = ExtractionBatch(identity: id, sequence: 0, sentences: [sentence],
      complete: true, totalSentences: 1)
    XCTAssertThrowsError(try ExtractionRevisionService.validate([unbound], identity: id,
      validator: validator)) { XCTAssertEqual($0 as? ExtractionError, .geometryUnavailable) }
  }
}
