import Darwin
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
  private struct TextFreePDFProducer: ExtractionBatchProducing {
    func withBatches(_ identity: ExtractionIdentity,
      consume: @escaping @Sendable ([ExtractionBatch], ExtractionConsumptionScope) async throws -> Void) async throws {
      throw PDFiumFailure(code: .noExtractableText)
    }
  }
  private struct UnboundGeometry: ExtractionGeometryInput {}
  private struct RejectingGeometryValidator: ExtractionGeometryValidating {
    func validateAndEncode(_ input: any ExtractionGeometryInput,
      identity: ExtractionSentenceIdentity, expectedText: String) throws -> ExtractionGeometryEncoding {
      throw ExtractionError.geometryUnavailable
    }
  }
  private func fixture(at root: URL = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString)) throws -> (ProductDatabase, UUID, UUID, URL) {
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

  private func replacementWithOriginalGeometry(_ identity: ExtractionIdentity) throws
    -> ValidatedExtractionSentence {
    let key = ExtractionSentenceIdentity(paperID: identity.paperID, pdfSHA256: identity.pdfSHA256,
      revision: identity.revision, page: 0, sentenceID: 0)
    let bounds = try PDFiumRawQuad(topLeftX: 0, topLeftY: 100, topRightX: 100, topRightY: 100,
      bottomRightX: 100, bottomRightY: 0, bottomLeftX: 0, bottomLeftY: 0)
    let rawPage = try PDFiumRawPage(pageIndex: 0, boundingBox: bounds, mediaBox: bounds,
      cropBox: bounds, rotationQuarterTurns: 0)
    let page = try PDFPageGeometry(pageIndex: 0, cropOrigin: .init(x: 0, y: 0),
      width: 100, height: 100, rotation: 0)
    let transform = try PDFGeometryAffine(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0)
    let mapping = try PDFiumPageMapping(page: page, rawToCanonical: transform,
      canonicalToReader: transform)
    let quad = try PDFiumRawQuad(topLeftX: 10, topLeftY: 90, topRightX: 20, topRightY: 90,
      bottomRightX: 20, bottomRightY: 80, bottomLeftX: 10, bottomLeftY: 80)
    let glyph = try PDFiumGlyph(nativeCharacterIndex: 0, unicodeScalar: 82,
      utf16Start: 0, utf16Length: 1, generated: false,
      matrixA: 1, matrixB: 0, matrixC: 0, matrixD: 1, matrixE: 0, matrixF: 0, rawQuad: quad)
    let input = PDFiumGeometryInput(identity: key, sourceText: "R", nativeStartCharacter: 0,
      nativeCharacterCount: 1, rawPage: rawPage, glyphs: [glyph])
    let validator = try PDFiumGeometryValidator(binding: PDFiumGeometryBinding(
      precision: PDFGeometryPrecision(maximumErrorPDFPoints: 0), mapPage: { _ in mapping }))
    let encoded = try validator.validateAndEncode(input, identity: key, expectedText: "R")
    return ValidatedExtractionSentence(page: 0, sentenceID: 0, text: "R",
      geometry: encoded.canonicalBytes, originalOwner: try XCTUnwrap(encoded.originalOwner))
  }

  func testProviderKindDriftRejectsExtractionBeforePublication() throws {
    let (db, paper, generation, root) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try db.compareAndSwapProviderConfiguration(expected: db.providerConfiguration(),
      replacementKind: .openAIAPIKey, replacementSlotID: UUID(), replacementModel: "fixture-model")
    let captured = try identity(db, paper, generation)
    try db.reserveExtraction(captured)
    let frozen = try db.adapterRead {
      try String.fetchOne($0, sql: "SELECT configKind FROM extractionAttempt WHERE paperID = ?",
        arguments: [paper.uuidString])
    }
    XCTAssertEqual(frozen, ProviderKind.openAIAPIKey.rawValue)
    try db.adapterWrite { try $0.execute(sql: "UPDATE providerConfig SET kind = 'codexChatGPT'") }
    XCTAssertEqual(try db.providerConfiguration().generation, captured.configuration.generation)
    XCTAssertThrowsError(try publishFixtureExtraction(db, captured, sentences: rows("stale role"))) {
      XCTAssertEqual($0 as? ExtractionError, .staleAttempt)
    }
    XCTAssertEqual(try db.adapterRead { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM extractionSentence") }, 0)
    XCTAssertEqual(try db.adapterRead { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM extractionVisible") }, 0)
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

  private enum PublicationExitPoint: String, CaseIterable {
    case beforeCommit, afterCommit

    var exitStatus: Int32 { self == .beforeCommit ? 71 : 72 }
  }

  func testPublicationSurvivesAbruptExitAtCommitBoundary() async throws {
    let argument = "PAPERLENS_TEST_EXTRACTION_PUBLICATION_EXIT"
    let temporaryDirectory = FileManager.default.temporaryDirectory
    if let request = ProcessInfo.processInfo.environment[argument] {
      let parts = request.split(separator: ":")
      guard parts.count == 2, let id = UUID(uuidString: String(parts[0])),
        let point = PublicationExitPoint(rawValue: String(parts[1])) else {
        return XCTFail("Invalid child fixture request")
      }
      let root = temporaryDirectory.appendingPathComponent("paperlens-publication-\(id.uuidString)")
      guard FileManager.default.fileExists(atPath: root.appendingPathComponent("xctest.log").path) else {
        return XCTFail("Parent fixture was not prepared")
      }
      try exitWhilePublishing(at: root, point: point)
    }

    for point in PublicationExitPoint.allCases {
      let id = UUID()
      let root = temporaryDirectory.appendingPathComponent("paperlens-publication-\(id.uuidString)")
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
      defer { try? FileManager.default.removeItem(at: root) }
      let log = root.appendingPathComponent("xctest.log")
      try Data().write(to: log, options: .withoutOverwriting)
      let output = try FileHandle(forWritingTo: log)
      defer { try? output.close() }
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
      process.arguments = ["xctest", "-XCTest",
        "ProductTests.ExtractionRevisionTests/testPublicationSurvivesAbruptExitAtCommitBoundary",
        Bundle(for: Self.self).bundlePath]
      var environment = ProcessInfo.processInfo.environment
      environment[argument] = "\(id.uuidString):\(point.rawValue)"
      process.environment = environment
      process.standardOutput = output
      process.standardError = output
      let exited = expectation(description: "Publisher exits \(point.rawValue)")
      process.terminationHandler = { _ in exited.fulfill() }
      try process.run()
      await fulfillment(of: [exited], timeout: 12)
      if process.isRunning {
        kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
      }
      guard process.terminationReason == .exit, process.terminationStatus == point.exitStatus else {
        return XCTFail("Publisher missed \(point) exit: \(try String(contentsOf: log, encoding: .utf8))")
      }

      let database = try ProductDatabase.open(at: root)
      let paper = try XCTUnwrap(database.adapterRead { db in
        try String.fetchOne(db, sql: "SELECT id FROM paper").flatMap(UUID.init(uuidString:))
      })
      let originalRevision = try XCTUnwrap(database.adapterRead { db in
        try String.fetchOne(db, sql: """
          SELECT i.revision FROM extractionInvocation i JOIN extractionAttemptHistory h USING (attempt)
          """).flatMap(UUID.init(uuidString:))
      })
      let receipt = try ProductJobRecovery(database: database).recoverStartup(currentEpoch: UUID())
      let status = try database.extractionStatus(paperID: paper)
      let hits = try database.searchExtraction(paperID: paper, matching: "R")
      XCTAssertEqual(try database.searchExtraction(paperID: paper, matching: "retained",
        revision: originalRevision).map(\.text), ["retained"])
      if point == .beforeCommit {
        XCTAssertEqual(receipt.interruptedJobs.map(\.kind), [.extraction])
        XCTAssertEqual(status.state, "failed")
        XCTAssertEqual(status.failure, "interrupted")
        XCTAssertEqual(status.usableRevision, originalRevision)
        XCTAssertEqual(try database.searchExtraction(paperID: paper, matching: "retained").count, 1)
        XCTAssertTrue(hits.isEmpty)
        let counts = try database.adapterRead { db in
          try ["extractionRevision", "extractionSentence", "extractionFTS", "extractionGeometryOwner"].map {
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \($0)")
          }
        }
        XCTAssertEqual(counts, [1, 1, 1, 0])
      } else {
        XCTAssertTrue(receipt.interruptedJobs.isEmpty)
        XCTAssertEqual(status.state, "succeeded")
        XCTAssertNil(status.failure)
        let hit = try XCTUnwrap(hits.first)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(status.usableRevision, hit.revision)
        XCTAssertNotEqual(hit.revision, originalRevision)
        let owner = try database.annotationIdentity(paperID: paper)
        let sentence = try PDFSentenceIdentity(paperID: paper, pdfSHA256: owner.pdfSHA256,
          extractionRevision: hit.revision.uuidString.lowercased(), pageIndex: hit.page, sentenceID: hit.sentenceID)
        let geometry = try XCTUnwrap(database.originalExtractionGeometryOwners(paperID: paper,
          generation: owner.generation, pdfSHA256: owner.pdfSHA256, revision: hit.revision, sentences: [sentence]))
        XCTAssertEqual(try geometry.resolve(hit, identity: sentence).fullSourceQuote, "R")
      }
    }
  }

  private func exitWhilePublishing(at root: URL, point: PublicationExitPoint) throws -> Never {
    let (db, paper, generation, _) = try fixture(at: root)
    let original = try identity(db, paper, generation)
    try db.reserveExtraction(original)
    try publishFixtureExtraction(db, original, sentences: rows("retained"))
    let next = try identity(db, paper, generation)
    try db.reserveExtraction(next)
    if point == .beforeCommit {
      try db.adapterWrite { sql in
        sql.add(function: DatabaseFunction("exitBeforePublicationCommit", argumentCount: 0) { _ in
          Darwin._exit(point.exitStatus)
        })
        try sql.execute(sql: """
          CREATE TEMP TRIGGER exitBeforePublicationCommit AFTER UPDATE OF state ON extractionAttempt
          WHEN NEW.state = 'succeeded' BEGIN
            SELECT exitBeforePublicationCommit();
          END;
          """)
      }
    }
    let replacement = try replacementWithOriginalGeometry(next)
    try publishFixtureExtraction(db, next, sentences: [replacement])
    // The storage adapter's return means its transaction has committed.
    Darwin._exit(PublicationExitPoint.afterCommit.exitStatus)
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

  func testIncompleteFTSWithoutSQLErrorDoesNotReplaceUsableRevision() throws {
    let (db, paper, generation, root) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let original = try identity(db, paper, generation)
    try db.reserveExtraction(original)
    try publishFixtureExtraction(db, original, sentences: rows("retained"))
    try db.adapterWrite { sql in
      try sql.execute(sql: """
        DROP TRIGGER extractionSentenceInsert;
        CREATE TRIGGER extractionSentenceInsert AFTER INSERT ON extractionSentence
        WHEN new.text != 'unindexed' BEGIN
          INSERT INTO extractionFTS(rowid, text) VALUES (new.id,
            CASE WHEN new.text = 'misindexed' THEN 'incorrect' ELSE new.text END);
        END;
        """)
    }

    for text in ["unindexed", "misindexed"] {
      let pending = try identity(db, paper, generation)
      try db.reserveExtraction(pending)
      let partial = rows("replacement") + [
        .init(page: 0, sentenceID: 1, text: text, geometry: Data([4, 5, 6])),
      ]
      XCTAssertThrowsError(try publishFixtureExtraction(db, pending, sentences: partial)) {
        XCTAssertEqual($0 as? ExtractionError, .storageFailure)
      }
      try db.failExtraction(pending, failure: .storageFailure)
      let status = try db.extractionStatus(paperID: paper)
      XCTAssertEqual(status.state, "failed")
      XCTAssertEqual(status.usableRevision, original.revision)
      XCTAssertEqual(try db.adapterRead { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM extractionFTS") }, 1)
      XCTAssertTrue(try db.searchExtraction(paperID: paper, matching: "replacement", revision: pending.revision).isEmpty)
    }
    let reopened = try ProductDatabase.open(at: root)
    let hits = try reopened.searchExtraction(paperID: paper, matching: "retained")
    XCTAssertEqual(hits.map(\.revision), [original.revision])
    XCTAssertEqual(hits.first?.canonicalGeometry, Data([1, 2, 3]))
  }

  func testPublicationRollsBackWhenCommittedComponentsAreMissingOrRewritten() throws {
    let (db, paper, generation, root) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let original = try identity(db, paper, generation)
    try db.reserveExtraction(original)
    try publishFixtureExtraction(db, original, sentences: rows("retained"))

    let incompleteWrites = [
      """
      CREATE TRIGGER incompletePublication BEFORE UPDATE ON extractionVisible
      BEGIN SELECT RAISE(IGNORE); END;
      """,
      """
      CREATE TRIGGER incompletePublication BEFORE UPDATE OF state ON extractionAttempt
      WHEN NEW.state = 'succeeded' BEGIN SELECT RAISE(IGNORE); END;
      """,
      """
      CREATE TRIGGER incompletePublication AFTER UPDATE OF state ON extractionAttempt
      WHEN NEW.state = 'succeeded' BEGIN
        DELETE FROM extractionFTS WHERE rowid IN (
          SELECT id FROM extractionSentence WHERE revision = NEW.revision
        );
      END;
      """,
      """
      CREATE TRIGGER incompletePublication AFTER UPDATE OF state ON extractionAttempt
      WHEN NEW.state = 'succeeded' BEGIN
        INSERT INTO extractionSentence(revision, page, sentenceID, text, geometry)
          VALUES (NEW.revision, 0, 1, 'unexpected', X'010203');
        DELETE FROM extractionFTS WHERE rowid IN (
          SELECT id FROM extractionSentence WHERE revision = NEW.revision AND sentenceID = 1
        );
      END;
      """,
      """
      CREATE TRIGGER incompletePublication BEFORE INSERT ON extractionGeometryOwner
      BEGIN SELECT RAISE(IGNORE); END;
      """,
      """
      CREATE TRIGGER incompletePublication AFTER UPDATE OF state ON extractionAttempt
      WHEN NEW.state = 'succeeded' BEGIN
        UPDATE extractionSentence SET text = text || char(0) || 'altered' WHERE revision = NEW.revision;
        DELETE FROM extractionFTS WHERE rowid IN (
          SELECT id FROM extractionSentence WHERE revision = NEW.revision
        );
        INSERT INTO extractionFTS(rowid, text)
          SELECT id, text FROM extractionSentence WHERE revision = NEW.revision;
      END;
      """,
      """
      CREATE TRIGGER incompletePublication AFTER UPDATE OF state ON extractionAttempt
      WHEN NEW.state = 'succeeded' BEGIN
        UPDATE extractionSentence SET page = page + 1 WHERE revision = NEW.revision;
        UPDATE extractionGeometryOwner SET page = page + 1 WHERE revision = NEW.revision;
      END;
      """,
      """
      CREATE TRIGGER incompletePublication AFTER UPDATE OF state ON extractionAttempt
      WHEN NEW.state = 'succeeded' BEGIN
        UPDATE extractionSentence SET page = page + 0.5 WHERE revision = NEW.revision;
      END;
      """,
      """
      CREATE TRIGGER incompletePublication AFTER UPDATE OF state ON extractionAttempt
      WHEN NEW.state = 'succeeded' BEGIN
        UPDATE extractionSentence SET geometry = X'010203' WHERE revision = NEW.revision;
      END;
      """,
      """
      CREATE TRIGGER incompletePublication AFTER UPDATE OF state ON extractionAttempt
      WHEN NEW.state = 'succeeded' BEGIN
        UPDATE extractionGeometryOwner SET originalAnchor = X'010203' WHERE revision = NEW.revision;
      END;
      """,
      """
      CREATE TRIGGER incompletePublication AFTER UPDATE OF state ON extractionAttempt
      WHEN NEW.state = 'succeeded' BEGIN
        UPDATE extractionGeometryOwner SET maximumErrorPDFPoints = 1 WHERE revision = NEW.revision;
      END;
      """,
    ]
    for trigger in incompleteWrites {
      let pending = try identity(db, paper, generation)
      try db.reserveExtraction(pending)
      let replacement = try replacementWithOriginalGeometry(pending)
      try db.adapterWrite { try $0.execute(sql: trigger) }
      XCTAssertThrowsError(try publishFixtureExtraction(db, pending, sentences: [replacement]), trigger) {
        XCTAssertEqual($0 as? ExtractionError, .storageFailure)
      }
      let status = try db.extractionStatus(paperID: paper)
      XCTAssertEqual(status.state, "running")
      XCTAssertEqual(status.usableRevision, original.revision)
      XCTAssertTrue(try db.searchExtraction(paperID: paper, matching: "R",
        revision: pending.revision).isEmpty)
      XCTAssertEqual(try db.adapterRead { try Int.fetchOne($0,
        sql: "SELECT COUNT(*) FROM extractionRevision WHERE id = ?",
        arguments: [pending.revision.uuidString]) }, 0)
      try db.adapterWrite { try $0.execute(sql: "DROP TRIGGER incompletePublication") }
      try db.failExtraction(pending, failure: .storageFailure)
    }
    let reopened = try ProductDatabase.open(at: root)
    XCTAssertEqual(try reopened.searchExtraction(paperID: paper, matching: "retained").map(\.revision),
      [original.revision])
    let retry = try identity(reopened, paper, generation)
    let replacement = try replacementWithOriginalGeometry(retry)
    try reopened.reserveExtraction(retry)
    try publishFixtureExtraction(reopened, retry, sentences: [replacement])
    XCTAssertEqual(try reopened.extractionStatus(paperID: paper).state, "succeeded")
    XCTAssertEqual(try reopened.searchExtraction(paperID: paper, matching: "R").map(\.revision),
      [retry.revision])
    let originalOwner = try XCTUnwrap(replacement.originalOwner)
    XCTAssertNotNil(try reopened.originalExtractionGeometryOwners(paperID: paper,
      generation: generation, pdfSHA256: retry.pdfSHA256, revision: retry.revision,
      sentences: [originalOwner.anchor.identity]))
  }

  func testFailedAttemptDoesNotAcceptARewrittenFailureReason() throws {
    let (db, paper, generation, root) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let pending = try identity(db, paper, generation)
    try db.reserveExtraction(pending)
    try db.adapterWrite { sql in
      try sql.execute(sql: """
        CREATE TRIGGER rewriteExtractionFailure AFTER UPDATE OF failure ON extractionAttempt
        WHEN NEW.failure = 'invalidBatch' BEGIN
          UPDATE extractionAttempt SET failure = 'interrupted' WHERE paperID = NEW.paperID;
        END;
        """)
    }
    XCTAssertThrowsError(try db.failExtraction(pending, failure: .invalidBatch)) {
      XCTAssertEqual($0 as? ExtractionError, .storageFailure)
    }
    let status = try db.extractionStatus(paperID: paper)
    XCTAssertEqual(status.state, "running")
    XCTAssertNil(status.failure)
    try db.adapterWrite { try $0.execute(sql: "DROP TRIGGER rewriteExtractionFailure") }
    try db.failExtraction(pending, failure: .invalidBatch)
    XCTAssertEqual(try db.extractionStatus(paperID: paper).failure, "invalidBatch")
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
    _ = try db.compareAndSwapProviderConfiguration(expected: retry.configuration,
      replacementKind: .openAIAPIKey, replacementSlotID: UUID(),
      replacementModel: "fixture-snapshot")
    XCTAssertThrowsError(try publishFixtureExtraction(db, retry, sentences: rows("stale")))
    let saga = try XCTUnwrap(db.beginDeletion(paper)).saga
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
    for permittedChecks in 0..<5 {
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

  func testTextFreePDFFailurePersistsSpecificUserReasonWithoutPublishing() async throws {
    let (db, paper, generation, root) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let id = try identity(db, paper, generation)
    let service = ExtractionRevisionService(database: db, producer: TextFreePDFProducer(),
      geometryValidator: RejectingGeometryValidator())
    do { try await service.parse(id); XCTFail("A PDF without extractable text must fail parsing") }
    catch { XCTAssertEqual((error as? PDFiumFailure)?.code, .noExtractableText) }

    let reopened = try ProductDatabase.open(at: root)
    let status = try reopened.extractionStatus(paperID: paper)
    XCTAssertEqual(status.state, "failed")
    XCTAssertEqual(status.failure, "noExtractableText")
    XCTAssertNil(status.usableRevision)
    XCTAssertEqual(ParsingFailureMessage.korean(status.failure),
      "PDF에서 추출할 수 있는 텍스트를 찾지 못했습니다.")
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
