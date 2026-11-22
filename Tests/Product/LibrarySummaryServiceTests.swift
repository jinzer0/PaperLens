import Combine
import Foundation
import GRDB
import XCTest
import ProviderRequest
@testable import PaperLensProduct

final class LibrarySummaryServiceTests: XCTestCase {
  private struct Fixture {
    let db: ProductDatabase
    let root: URL
    let identity: LibrarySummaryIdentity
    let request: AuthorizedProviderRequest
    let frozen: LibrarySummaryFrozen
    let result: ValidatedProviderResult
  }

  private func fixture(tail: String? = nil, rankTail: Bool = false,
    database: ProductDatabase? = nil) throws -> Fixture {
    let db = try database ?? ProductDatabase.open(at:
      FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    let root = db.root
    let paper = UUID(), generation = UUID(), revision = UUID()
    let hash = String(repeating: "a", count: 64)
    let identity = LibrarySummaryIdentity(paperID: paper, generation: generation, requestPaperGeneration: 1, pdfSHA256: hash,
      revision: revision, configurationGeneration: 0, job: UUID(), attempt: UUID(), fence: UUID(),
      correlation: UUID(), input: UUID(), epoch: UUID())
    let quotes = ["main contribution alpha", "results conclusion beta"] + (tail.map { [$0] } ?? [])
    try db.adapterWrite { sql in
      try sql.execute(sql: """
        INSERT INTO paper(id, generation, title, status, pdfReference, pdfSHA256, createdAt)
        VALUES (?, ?, 'fixture', 'ready', ?, ?, 0)
        """, arguments: [paper.uuidString, generation.uuidString,
          "papers/\(paper.uuidString)/document.pdf", hash])
      try sql.execute(sql: """
        INSERT INTO extractionRevision(id, paperID, generation, pdfSHA256, pdfReference)
        VALUES (?, ?, ?, ?, ?)
        """, arguments: [revision.uuidString, paper.uuidString, generation.uuidString, hash,
          "papers/\(paper.uuidString)/document.pdf"])
      try sql.execute(sql: "INSERT INTO extractionVisible(paperID, revision) VALUES (?, ?)",
        arguments: [paper.uuidString, revision.uuidString])
      for (id, quote) in quotes.enumerated() {
        try sql.execute(sql: """
          INSERT INTO extractionSentence(revision, page, sentenceID, text, geometry) VALUES (?, 0, ?, ?, ?)
          """, arguments: [revision.uuidString, id, quote, Data([0])])
      }
    }
    let authority = try ProviderRequest()
    let source = RequestSources.librarySummary(outputLanguage: "en")
    let context = try TrustedRequestContext(authority: authority, sources: source,
      identity: .init(paperID: paper.uuidString.lowercased(), paperGeneration: 1,
        pdfSHA256: hash, extractionRevision: revision.uuidString.lowercased()),
      sentences: quotes.enumerated().map { .init(anchor: .init(pageIndex: 0, sentenceID: $0.offset), quote: $0.element) },
      rankedCandidates: rankTail ? [1, 0, 2] : [1, 0])
    let request = try authority.buildRequest(sources: source, context: context,
      requestID: identity.correlation.uuidString.lowercased())
    guard case .librarySummary(_, let bundle) = request.wire.typedInput else {
      throw LibrarySummaryError.invalidResult
    }
    let result = try authority.wrapModelResult(JSONSerialization.data(withJSONObject: [
      "summary": ["text": "Grounded summary", "kind": "paper", "evidenceIndices": [0, 1]],
      "insufficiency": bundle.insufficiency
    ]), request: request)
    let f = Fixture(db: db, root: root, identity: identity, request: request,
      frozen: try LibrarySummaryFrozen(request: request), result: result)
    _ = try installCanonicalGeometry(f, owners: canonicalOwners(f))
    return f
  }

  private func canonicalOwners(_ f: Fixture) throws -> [PDFSentenceAnchor] {
    // Independently constructed owned test extents, not owners recovered from stored bytes.
    // Zero precision is fixture-only; it does not select a production profile.
    try f.frozen.sentences.map { sentence in
      let identity = try PDFSentenceIdentity(paperID: f.identity.paperID,
        pdfSHA256: f.identity.pdfSHA256, extractionRevision: f.identity.revision.uuidString.lowercased(),
        pageIndex: sentence.page, sentenceID: sentence.id)
      let page = try PDFPageGeometry(pageIndex: sentence.page,
        cropOrigin: .init(x: 0, y: 0), width: 100, height: 100, rotation: 0)
      let first = try PDFQuad(topLeft: .init(x: 10, y: 80), topRight: .init(x: 80, y: 80),
        bottomRight: .init(x: 80, y: 70), bottomLeft: .init(x: 10, y: 70), page: page)
      let continuation = try PDFQuad(topLeft: .init(x: 10, y: 60), topRight: .init(x: 60, y: 60),
        bottomRight: .init(x: 60, y: 50), bottomLeft: .init(x: 10, y: 50), page: page)
      return try PDFSentenceAnchor(identity: identity, fullSourceQuote: sentence.quote,
        page: page, quads: [first, continuation])
    }
  }

  private func installCanonicalGeometry(_ f: Fixture, owners: [PDFSentenceAnchor]) throws
    -> CanonicalExtractionGeometryValidator {
    let codec = try CanonicalExtractionGeometryValidator(owningAnchors: owners,
      precision: PDFGeometryPrecision(maximumErrorPDFPoints: 0))
    for owner in owners {
      let key = ExtractionSentenceIdentity(paperID: f.identity.paperID,
        pdfSHA256: f.identity.pdfSHA256, revision: f.identity.revision,
        page: owner.identity.pageIndex, sentenceID: owner.identity.sentenceID)
      let bytes = try codec.validateAndEncode(CanonicalExtractionGeometryInput(anchor: owner),
        identity: key, expectedText: owner.fullSourceQuote).canonicalBytes
      try f.db.adapterWrite { sql in
        try sql.execute(sql: "UPDATE extractionSentence SET geometry = ? WHERE revision = ? AND sentenceID = ?",
          arguments: [bytes, f.identity.revision.uuidString, key.sentenceID])
      }
    }
    return codec
  }

  func testReservationRejectsNoncanonicalOwnerBeforeGroundingCallback() throws {
    struct GroundingProbe: LibrarySummaryGeometryValidating {
      func resolve(_ hit: ExtractionSearchHit, identity: PDFSentenceIdentity) throws -> PDFSentenceAnchor {
        XCTFail("Noncanonical reservation invoked candidate grounding before owner admission")
        throw CanonicalExtractionGeometryError.invalidEncoding
      }
    }
    let f = try fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    XCTAssertThrowsError(try f.db.reserveLibrarySummary(f.identity, frozen: f.frozen,
      geometry: GroundingProbe())) {
      XCTAssertEqual($0 as? LibrarySummaryError, .geometryUnavailable)
    }
    XCTAssertEqual(try f.db.adapterRead { try Int.fetchOne($0,
      sql: "SELECT COUNT(*) FROM librarySummaryJob") }, 0)
  }

  func testReservationRejectsOriginalArchiveQuotaBeforeCorruptCandidateDecode() throws {
    let f = try fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    var owners = try canonicalOwners(f)
    let original = owners[0]
    owners[0] = try PDFSentenceAnchor(identity: original.identity,
      fullSourceQuote: String(repeating: "q", count: SummaryOwnerArchive.maximumBytes / 6 + 1),
      page: original.page, quads: original.quads)
    let geometry = try CanonicalExtractionGeometryValidator(owningAnchors: owners,
      precision: PDFGeometryPrecision(maximumErrorPDFPoints: 0))
    try f.db.adapterWrite { sql in
      try sql.execute(sql: "UPDATE extractionSentence SET geometry = ? WHERE revision = ?",
        arguments: [Data([0]), f.identity.revision.uuidString])
    }
    XCTAssertThrowsError(try f.db.reserveLibrarySummary(f.identity, frozen: f.frozen,
      geometry: geometry)) {
      // Invalid candidate encoding must not run before original-owner byte preflight.
      XCTAssertEqual($0 as? LibrarySummaryError, .invalidGrounding)
    }
    for table in ["librarySummaryJob", "librarySummaryOwner", "librarySummaryOwnerAnchor"] {
      XCTAssertEqual(try f.db.adapterRead { try Int.fetchOne($0,
        sql: "SELECT COUNT(*) FROM \(table)") }, 0, table)
    }
  }

  func testCanonicalSummarySaveReopenRestoresRetainedRevisionWithoutGenerationOrProvider() throws {
    let f = try fixture(tail: "independent unranked full extent")
    defer { try? FileManager.default.removeItem(at: f.root) }
    let owners = try canonicalOwners(f)
    let codec = try installCanonicalGeometry(f, owners: owners)
    try f.db.reserveLibrarySummary(f.identity, frozen: f.frozen, geometry: codec)
    let saved = try f.db.publishLibrarySummary(f.identity, frozen: f.frozen, result: f.result,
      bytes: ProviderRequest.canonicalBytes(f.result.value), permit: UUID().uuidString,
      resultID: UUID(), geometry: codec)
    let newer = UUID()
    try f.db.adapterWrite { sql in
      try sql.execute(sql: """
        INSERT INTO extractionRevision(id, paperID, generation, pdfSHA256, pdfReference)
        VALUES (?, ?, ?, ?, ?)
        """, arguments: [newer.uuidString, f.identity.paperID.uuidString,
          f.identity.generation.uuidString, f.identity.pdfSHA256,
          "papers/\(f.identity.paperID.uuidString)/document.pdf"])
      try sql.execute(sql: "UPDATE extractionVisible SET revision = ? WHERE paperID = ?",
        arguments: [newer.uuidString, f.identity.paperID.uuidString])
    }
    _ = try f.db.compareAndSwapProviderConfiguration(expected: f.db.providerConfiguration(),
      replacementKind: nil, replacementSlotID: nil, replacementModel: "new configuration")
    let reopened = try ProductDatabase.open(at: f.root)
    let restored = try XCTUnwrap(LibrarySummaryService(database: reopened, geometry: codec)
      .restore(paperID: f.identity.paperID))
    XCTAssertEqual(restored.id, saved.id)
    XCTAssertEqual(restored.identity, f.identity)
    XCTAssertEqual(restored.result, f.result)
    XCTAssertEqual(restored.evidence, saved.evidence)
    XCTAssertEqual(restored.claimAnchors, [owners[1], owners[0]])
    XCTAssertEqual(try reopened.adapterRead { try Int.fetchOne($0,
      sql: "SELECT COUNT(*) FROM librarySummaryJob") }, 1)
    XCTAssertEqual(try reopened.adapterRead { try Int.fetchOne($0,
      sql: "SELECT COUNT(*) FROM librarySummaryResult") }, 1)
    let missingOldOwner = try CanonicalExtractionGeometryValidator(owningAnchors: [],
      precision: PDFGeometryPrecision(maximumErrorPDFPoints: 0))
    XCTAssertThrowsError(try LibrarySummaryService(database: reopened, geometry: missingOldOwner)
      .restore(paperID: f.identity.paperID)) {
      XCTAssertEqual($0 as? PDFGeometryError, .unknownSentence)
    }
  }

  func testOriginalOwnerArchiveRestoresWithoutInjectedGeometryOrProviderAfterRevisionChange() throws {
    let f = try fixture(tail: "independent unranked full extent")
    defer { try? FileManager.default.removeItem(at: f.root) }
    let owners = try canonicalOwners(f)
    _ = try installCanonicalGeometry(f, owners: owners)
    // Explicit nonzero test tolerance belongs to these original fixture owners only.
    let codec = try CanonicalExtractionGeometryValidator(owningAnchors: owners,
      precision: PDFGeometryPrecision(maximumErrorPDFPoints: 0.25))
    try f.db.reserveLibrarySummary(f.identity, frozen: f.frozen, geometry: codec)
    let saved = try f.db.publishLibrarySummary(f.identity, frozen: f.frozen, result: f.result,
      bytes: ProviderRequest.canonicalBytes(f.result.value), permit: UUID().uuidString,
      resultID: UUID(), geometry: codec)
    let newer = UUID()
    try f.db.adapterWrite { sql in
      try sql.execute(sql: """
        INSERT INTO extractionRevision(id, paperID, generation, pdfSHA256, pdfReference)
        VALUES (?, ?, ?, ?, ?)
        """, arguments: [newer.uuidString, f.identity.paperID.uuidString,
          f.identity.generation.uuidString, f.identity.pdfSHA256,
          "papers/\(f.identity.paperID.uuidString)/document.pdf"])
      try sql.execute(sql: "UPDATE extractionVisible SET revision = ? WHERE paperID = ?",
        arguments: [newer.uuidString, f.identity.paperID.uuidString])
    }
    _ = try f.db.compareAndSwapProviderConfiguration(expected: f.db.providerConfiguration(),
      replacementKind: nil, replacementSlotID: nil, replacementModel: "new configuration")
    let reopened = try ProductDatabase.open(at: f.root)
    // Neither geometry nor provider is injected: only the registered original archive owns restore.
    let restored = try XCTUnwrap(LibrarySummaryService(database: reopened)
      .restore(paperID: f.identity.paperID))
    XCTAssertEqual(restored.id, saved.id)
    XCTAssertEqual(restored.identity, f.identity)
    XCTAssertEqual(restored.identity.requestPaperGeneration, f.frozen.paperGeneration)
    XCTAssertEqual(restored.identity.revision, f.identity.revision)
    XCTAssertEqual(restored.result, f.result)
    XCTAssertEqual(restored.evidence, saved.evidence)
    XCTAssertEqual(restored.claimAnchors, [owners[1], owners[0]])
    XCTAssertEqual(restored.claimAnchors.map(\.fullSourceQuote),
      [owners[1].fullSourceQuote, owners[0].fullSourceQuote])
    let archived = try reopened.adapterRead { sql in
      try Data.fetchAll(sql, sql: "SELECT anchor FROM librarySummaryOwnerAnchor WHERE job = ? ORDER BY page, sentenceID",
        arguments: [f.identity.job.uuidString])
    }
    XCTAssertEqual(try archived.map { try CanonicalExtractionGeometryValidator.decodeCanonicalAnchor($0) }, owners)
    XCTAssertEqual(try reopened.adapterRead { try Double.fetchOne($0,
      sql: "SELECT maximumErrorPDFPoints FROM librarySummaryOwner WHERE job = ?",
      arguments: [f.identity.job.uuidString]) }, 0.25) // Synthetic fixture precision, not calibration.
    XCTAssertEqual(try reopened.adapterRead { try Int.fetchOne($0,
      sql: "SELECT COUNT(*) FROM librarySummaryJob") }, 1)
    XCTAssertEqual(try reopened.adapterRead { try Int.fetchOne($0,
      sql: "SELECT COUNT(*) FROM librarySummaryResult") }, 1)
  }

  func testOriginalOwnerArchiveRejectsMissingHeaderInvalidPrecisionCorruptAnchorAndMissingTail() throws {
    for corruption in ["header", "precision", "anchor", "membership"] {
      let f = try fixture(tail: "independent unranked full extent")
      defer { try? FileManager.default.removeItem(at: f.root) }
      let owners = try canonicalOwners(f)
      let codec = try installCanonicalGeometry(f, owners: owners)
      try f.db.reserveLibrarySummary(f.identity, frozen: f.frozen, geometry: codec)
      let saved = try f.db.publishLibrarySummary(f.identity, frozen: f.frozen, result: f.result,
        bytes: ProviderRequest.canonicalBytes(f.result.value), permit: UUID().uuidString,
        resultID: UUID(), geometry: codec)
      try f.db.adapterWrite { sql in
        if corruption == "header" || corruption == "precision" {
          // DELETE/INSERT respects the real immutable-update triggers. SQLite permits text
          // in this REAL-affinity column; recovery must reject it rather than guess precision.
          try sql.execute(sql: "DELETE FROM librarySummaryOwner WHERE job = ?",
            arguments: [f.identity.job.uuidString])
          if corruption == "precision" {
            try sql.execute(sql: "INSERT INTO librarySummaryOwner(job, format, maximumErrorPDFPoints) VALUES (?, 1, 'unknown')",
              arguments: [f.identity.job.uuidString])
            for owner in owners {
              try sql.execute(sql: "INSERT INTO librarySummaryOwnerAnchor(job, page, sentenceID, anchor) VALUES (?, ?, ?, ?)",
                arguments: [f.identity.job.uuidString, owner.identity.pageIndex,
                  owner.identity.sentenceID, try CanonicalExtractionGeometryValidator.encodeCanonicalAnchor(owner)])
            }
          }
        } else {
          // The unranked tail is required even though the saved claim selects only [1, 0].
          try sql.execute(sql: "DELETE FROM librarySummaryOwnerAnchor WHERE job = ? AND page = 0 AND sentenceID = 2",
            arguments: [f.identity.job.uuidString])
          if corruption == "anchor" {
            try sql.execute(sql: "INSERT INTO librarySummaryOwnerAnchor(job, page, sentenceID, anchor) VALUES (?, 0, 2, ?)",
              arguments: [f.identity.job.uuidString, Data([0])])
          }
        }
      }
      let reopened = try ProductDatabase.open(at: f.root)
      XCTAssertThrowsError(try LibrarySummaryService(database: reopened)
        .restore(paperID: f.identity.paperID), corruption) { error in
        switch corruption {
        case "header", "precision": XCTAssertEqual(error as? LibrarySummaryError, .geometryUnavailable)
        case "anchor": XCTAssertEqual(error as? CanonicalExtractionGeometryError, .invalidEncoding)
        default: XCTAssertEqual(error as? LibrarySummaryError, .invalidGrounding)
        }
      }
      // The saved result and candidate geometry remain valid under independent fixture owners;
      // archive failure must not regenerate, delete or silently replace the committed result.
      XCTAssertEqual(try LibrarySummaryService(database: reopened, geometry: codec)
        .restore(paperID: f.identity.paperID)?.id, saved.id)
      XCTAssertEqual(try reopened.adapterRead { try Int.fetchOne($0,
        sql: "SELECT COUNT(*) FROM librarySummaryJob") }, 1)
      XCTAssertEqual(try reopened.adapterRead { try Data.fetchOne($0,
        sql: "SELECT result FROM librarySummaryResult WHERE id = ?",
        arguments: [saved.id.uuidString]) }, try ProviderRequest.canonicalBytes(f.result.value))
      XCTAssertEqual(try reopened.adapterRead { try String.fetchOne($0,
        sql: "SELECT resultID FROM librarySummaryVisible WHERE paperID = ?",
        arguments: [f.identity.paperID.uuidString]) }, saved.id.uuidString)
    }
  }

  func testOriginalOwnerArchiveCannotRestoreSummaryForChangedPaperGeneration() throws {
    let f = try fixture(tail: "independent unranked full extent")
    defer { try? FileManager.default.removeItem(at: f.root) }
    let codec = try installCanonicalGeometry(f, owners: canonicalOwners(f))
    try f.db.reserveLibrarySummary(f.identity, frozen: f.frozen, geometry: codec)
    let saved = try f.db.publishLibrarySummary(f.identity, frozen: f.frozen, result: f.result,
      bytes: ProviderRequest.canonicalBytes(f.result.value), permit: UUID().uuidString,
      resultID: UUID(), geometry: codec)
    try f.db.adapterWrite { sql in
      try sql.execute(sql: "UPDATE paper SET generation = ? WHERE id = ?",
        arguments: [UUID().uuidString, f.identity.paperID.uuidString])
    }
    let reopened = try ProductDatabase.open(at: f.root)
    XCTAssertNil(try LibrarySummaryService(database: reopened).restore(paperID: f.identity.paperID))
    XCTAssertEqual(try reopened.adapterRead { try Int.fetchOne($0,
      sql: "SELECT COUNT(*) FROM librarySummaryOwnerAnchor WHERE job = ?",
      arguments: [f.identity.job.uuidString]) }, 3)
    // Fixture-only stale pointer models corruption; even a still-retained archive cannot
    // relabel this old result with the new Paper generation. No deletion/purge ACK is invented.
    try reopened.adapterWrite { sql in
      try sql.execute(sql: "INSERT INTO librarySummaryVisible(paperID, resultID) VALUES (?, ?)",
        arguments: [f.identity.paperID.uuidString, saved.id.uuidString])
    }
    XCTAssertThrowsError(try LibrarySummaryService(database: reopened)
      .restore(paperID: f.identity.paperID)) {
      XCTAssertEqual($0 as? LibrarySummaryError, .staleIdentity)
    }
    XCTAssertEqual(try reopened.adapterRead { try Int.fetchOne($0,
      sql: "SELECT COUNT(*) FROM librarySummaryResult") }, 1)
  }

  func testOriginalOwnerArchiveSQLPaperDeleteCascadesSummaryRowsOnly() throws {
    let f = try fixture(tail: "independent unranked full extent")
    defer { try? FileManager.default.removeItem(at: f.root) }
    let codec = try installCanonicalGeometry(f, owners: canonicalOwners(f))
    try f.db.reserveLibrarySummary(f.identity, frozen: f.frozen, geometry: codec)
    let saved = try f.db.publishLibrarySummary(f.identity, frozen: f.frozen, result: f.result,
      bytes: ProviderRequest.canonicalBytes(f.result.value), permit: UUID().uuidString,
      resultID: UUID(), geometry: codec)
    XCTAssertEqual(try LibrarySummaryService(database: f.db)
      .restore(paperID: f.identity.paperID)?.id, saved.id)
    let tables = ["librarySummaryJob", "librarySummaryResult", "librarySummaryVisible",
      "librarySummaryOwner", "librarySummaryOwnerAnchor"]
    for table in tables {
      XCTAssertEqual(try f.db.adapterRead { try Int.fetchOne($0,
        sql: "SELECT COUNT(*) FROM \(table)") }, table == "librarySummaryOwnerAnchor" ? 3 : 1)
    }
    try f.db.adapterWrite { sql in
      XCTAssertEqual(try Int.fetchOne(sql, sql: "PRAGMA foreign_keys"), 1)
      // Owned SQL fixture deletion only: not application deletion, purge or FD closure.
      try sql.execute(sql: "DELETE FROM paper WHERE id = ?",
        arguments: [f.identity.paperID.uuidString])
    }
    let reopened = try ProductDatabase.open(at: f.root)
    XCTAssertEqual(try reopened.adapterRead { try Int.fetchOne($0,
      sql: "SELECT COUNT(*) FROM paper WHERE id = ?",
      arguments: [f.identity.paperID.uuidString]) }, 0)
    for table in tables {
      XCTAssertEqual(try reopened.adapterRead { try Int.fetchOne($0,
        sql: "SELECT COUNT(*) FROM \(table)") }, 0, table)
    }
    XCTAssertNil(try LibrarySummaryService(database: reopened).restore(paperID: f.identity.paperID))
  }

  func testOriginalOwnerArchiveRejectsOversizedRowAndAggregateBeforeAnchorDecode() throws {
    let f = try fixture(tail: "independent unranked full extent")
    defer { try? FileManager.default.removeItem(at: f.root) }
    let codec = try installCanonicalGeometry(f, owners: canonicalOwners(f))
    try f.db.reserveLibrarySummary(f.identity, frozen: f.frozen, geometry: codec)
    let saved = try f.db.publishLibrarySummary(f.identity, frozen: f.frozen, result: f.result,
      bytes: ProviderRequest.canonicalBytes(f.result.value), permit: UUID().uuidString,
      resultID: UUID(), geometry: codec)
    XCTAssertEqual(try LibrarySummaryService(database: f.db)
      .restore(paperID: f.identity.paperID)?.id, saved.id)
    let maximumBytes = SummaryOwnerArchive.maximumBytes
    // The real row CHECK forbids a single oversized BLOB. The failed replacement is
    // transactional, so it cannot remove the previously registered original tail.
    XCTAssertThrowsError(try f.db.adapterWrite { sql in
      try sql.execute(sql: "DELETE FROM librarySummaryOwnerAnchor WHERE job = ? AND page = 0 AND sentenceID = 2",
        arguments: [f.identity.job.uuidString])
      try sql.execute(sql: "INSERT INTO librarySummaryOwnerAnchor(job, page, sentenceID, anchor) VALUES (?, 0, 2, ?)",
        arguments: [f.identity.job.uuidString, Data(repeating: 0, count: maximumBytes + 1)])
    }) { error in
      XCTAssertEqual((error as? DatabaseError)?.resultCode, .SQLITE_CONSTRAINT)
    }
    XCTAssertEqual(try LibrarySummaryService(database: f.db)
      .restore(paperID: f.identity.paperID)?.id, saved.id)
    try f.db.adapterWrite { sql in
      // Individually permitted BLOB length, but total archive bytes now exceed the
      // existing metadata bound. Immutable UPDATE triggers remain untouched.
      try sql.execute(sql: "DELETE FROM librarySummaryOwnerAnchor WHERE job = ? AND page = 0 AND sentenceID = 2",
        arguments: [f.identity.job.uuidString])
      try sql.execute(sql: "INSERT INTO librarySummaryOwnerAnchor(job, page, sentenceID, anchor) VALUES (?, 0, 2, ?)",
        arguments: [f.identity.job.uuidString, Data(repeating: 0, count: maximumBytes)])
    }
    let reopened = try ProductDatabase.open(at: f.root)
    XCTAssertEqual(try reopened.adapterRead { try Int.fetchOne($0,
      sql: "SELECT COUNT(*) FROM librarySummaryOwnerAnchor WHERE job = ?",
      arguments: [f.identity.job.uuidString]) }, 3)
    let bytes = try XCTUnwrap(reopened.adapterRead { try Int.fetchOne($0,
      sql: "SELECT SUM(length(anchor)) FROM librarySummaryOwnerAnchor WHERE job = ?",
      arguments: [f.identity.job.uuidString]) })
    XCTAssertGreaterThan(bytes, maximumBytes)
    // Invalid JSON would produce invalidEncoding if fetched/decoded. The aggregate
    // guard must instead deny with invalidGrounding before anchor decoding.
    XCTAssertThrowsError(try LibrarySummaryService(database: reopened)
      .restore(paperID: f.identity.paperID)) {
      XCTAssertEqual($0 as? LibrarySummaryError, .invalidGrounding)
    }
    XCTAssertEqual(try LibrarySummaryService(database: reopened, geometry: codec)
      .restore(paperID: f.identity.paperID)?.id, saved.id)
    XCTAssertEqual(try reopened.adapterRead { try Int.fetchOne($0,
      sql: "SELECT COUNT(*) FROM librarySummaryJob") }, 1)
    XCTAssertEqual(try reopened.adapterRead { try Data.fetchOne($0,
      sql: "SELECT result FROM librarySummaryResult WHERE id = ?",
      arguments: [saved.id.uuidString]) }, try ProviderRequest.canonicalBytes(f.result.value))
  }

  func testCanonicalSummaryRequiresFullUnrankedOwnerAtReservePublishAndRestore() throws {
    for boundary in ["reserve", "publish", "restore"] {
      let f = try fixture(tail: "independent unranked full extent")
      defer { try? FileManager.default.removeItem(at: f.root) }
      let owners = try canonicalOwners(f)
      let codec = try installCanonicalGeometry(f, owners: owners)
      if boundary != "reserve" {
        try f.db.reserveLibrarySummary(f.identity, frozen: f.frozen, geometry: codec)
      }
      if boundary == "restore" {
        _ = try f.db.publishLibrarySummary(f.identity, frozen: f.frozen, result: f.result,
          bytes: ProviderRequest.canonicalBytes(f.result.value), permit: UUID().uuidString,
          resultID: UUID(), geometry: codec)
      }
      let original = try XCTUnwrap(f.db.adapterRead { try Data.fetchOne($0,
        sql: "SELECT geometry FROM extractionSentence WHERE revision = ? AND sentenceID = 2",
        arguments: [f.identity.revision.uuidString]) })
      var encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
      let quads = try XCTUnwrap(encoded["quads"] as? [[String: Any]])
      encoded["quads"] = Array(quads.prefix(1))
      let truncated = try JSONSerialization.data(withJSONObject: encoded, options: [.sortedKeys])
      try f.db.adapterWrite { sql in
        try sql.execute(sql: "UPDATE extractionSentence SET geometry = ? WHERE revision = ? AND sentenceID = 2",
          arguments: [truncated, f.identity.revision.uuidString])
      }
      XCTAssertEqual(f.request.wire.evidenceItems.map(\.anchor.sentenceID), [1, 0])
      XCTAssertThrowsError(try {
        switch boundary {
        case "reserve": try f.db.reserveLibrarySummary(f.identity, frozen: f.frozen, geometry: codec)
        case "publish":
          _ = try f.db.publishLibrarySummary(f.identity, frozen: f.frozen, result: f.result,
            bytes: ProviderRequest.canonicalBytes(f.result.value), permit: UUID().uuidString,
            resultID: UUID(), geometry: codec)
        default:
          _ = try LibrarySummaryService(database: f.db, geometry: codec).restore(paperID: f.identity.paperID)
        }
      }()) { XCTAssertEqual($0 as? CanonicalExtractionGeometryError, .semanticExtentMismatch) }
      XCTAssertEqual(try f.db.adapterRead { try Int.fetchOne($0,
        sql: "SELECT COUNT(*) FROM librarySummaryJob") }, boundary == "reserve" ? 0 : 1)
      XCTAssertEqual(try f.db.adapterRead { try Int.fetchOne($0,
        sql: "SELECT COUNT(*) FROM librarySummaryResult") }, boundary == "restore" ? 1 : 0)
      XCTAssertEqual(try f.db.adapterRead { try Int.fetchOne($0,
        sql: "SELECT COUNT(*) FROM librarySummaryVisible") }, boundary == "restore" ? 1 : 0)
      if boundary == "publish" {
        XCTAssertEqual(try f.db.adapterRead { try String.fetchOne($0,
          sql: "SELECT state FROM librarySummaryJob") }, "running")
      }
    }
  }

  func testCanonicalSummaryRejectsCorrelatedFrozenTextAndGeometryForgeryBeforeReservation() throws {
    let f = try fixture(tail: "independent unranked full extent")
    defer { try? FileManager.default.removeItem(at: f.root) }
    let owners = try canonicalOwners(f)
    let codec = try installCanonicalGeometry(f, owners: owners)
    let forgedQuote = String(repeating: "z", count: owners[2].fullSourceQuote.utf8.count)
    var frozen = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(f.frozen))
      as? [String: Any])
    var sentences = try XCTUnwrap(frozen["sentences"] as? [[String: Any]])
    sentences[2]["quote"] = forgedQuote
    frozen["sentences"] = sentences
    let forgedFrozen = try JSONDecoder().decode(LibrarySummaryFrozen.self,
      from: JSONSerialization.data(withJSONObject: frozen))
    let forgedAnchor = try PDFSentenceAnchor(identity: owners[2].identity,
      fullSourceQuote: forgedQuote, page: owners[2].page, quads: owners[2].quads)
    // Codec-only deliberately manufactures correlated corruption, not owner authority.
    let forgedBytes = try CanonicalExtractionGeometryValidator.encodeCanonicalAnchor(forgedAnchor)
    try f.db.adapterWrite { sql in
      try sql.execute(sql: "UPDATE extractionSentence SET text = ?, geometry = ? WHERE revision = ? AND sentenceID = 2",
        arguments: [forgedQuote, forgedBytes, f.identity.revision.uuidString])
    }
    let authority = try ProviderRequest()
    XCTAssertEqual(try authority.encodeRequest(forgedFrozen.authorized(using: authority)), f.frozen.request)
    XCTAssertThrowsError(try f.db.reserveLibrarySummary(f.identity, frozen: forgedFrozen, geometry: codec)) {
      XCTAssertEqual($0 as? CanonicalExtractionGeometryError, .semanticExtentMismatch)
    }
    XCTAssertEqual(try f.db.adapterRead { try Int.fetchOne($0,
      sql: "SELECT COUNT(*) FROM librarySummaryJob") }, 0)
  }

  private func reserve(_ f: Fixture) throws {
    try f.db.reserveLibrarySummary(f.identity, frozen: f.frozen, geometry: originalGeometry(f))
  }
  private func publish(_ f: Fixture) throws -> LibrarySummaryRecord {
    try f.db.publishLibrarySummary(f.identity, frozen: f.frozen, result: f.result,
      bytes: ProviderRequest.canonicalBytes(f.result.value), permit: UUID().uuidString,
      resultID: UUID(), geometry: originalGeometry(f))
  }

  private func originalGeometry(_ f: Fixture) throws -> CanonicalExtractionGeometryValidator {
    // Only immutable original fixture context supplies these synthetic extents.
    // Never read candidate SQL/frozen/result corruption or rewrite storage at a boundary.
    try CanonicalExtractionGeometryValidator(owningAnchors: canonicalOwners(f),
      precision: PDFGeometryPrecision(maximumErrorPDFPoints: 0))
  }

  private func assertForgedTailRejected(tail: String, rankTail: Bool) throws {
    for field in ["quote", "page"] {
      let f = try fixture(tail: tail, rankTail: rankTail)
      defer { try? FileManager.default.removeItem(at: f.root) }
      var stored = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(f.frozen))
        as? [String: Any])
      var sentences = try XCTUnwrap(stored["sentences"] as? [[String: Any]])
      if field == "quote" {
        sentences[2][field] = String(repeating: "z", count: tail.utf8.count)
      } else {
        sentences[2][field] = 1
      }
      stored["sentences"] = sentences
      let forged = try JSONDecoder().decode(LibrarySummaryFrozen.self,
        from: JSONSerialization.data(withJSONObject: stored))
      let authority = try ProviderRequest()
      XCTAssertEqual(try authority.encodeRequest(forged.authorized(using: authority)), f.frozen.request)
      XCTAssertEqual(f.request.wire.evidenceItems.map(\.anchor.sentenceID), [1, 0])
      XCTAssertThrowsError(try f.db.reserveLibrarySummary(f.identity, frozen: forged,
        geometry: originalGeometry(f))) {
        XCTAssertEqual($0 as? LibrarySummaryError, .invalidGrounding)
      }
      XCTAssertEqual(try f.db.adapterRead { try Int.fetchOne($0,
        sql: "SELECT COUNT(*) FROM librarySummaryJob") }, 0)
      try reserve(f)
      let forgedBytes = try JSONEncoder().encode(forged)
      let originalBytes = try JSONEncoder().encode(f.frozen)
      // Model durable corruption of both copies, not merely the job/frozen equality guard.
      try f.db.adapterWrite { sql in
        try sql.execute(sql: "UPDATE librarySummaryJob SET frozen = ? WHERE job = ?",
          arguments: [forgedBytes, f.identity.job.uuidString])
      }
      XCTAssertThrowsError(try f.db.publishLibrarySummary(f.identity, frozen: forged,
        result: f.result, bytes: ProviderRequest.canonicalBytes(f.result.value),
        permit: UUID().uuidString, resultID: UUID(), geometry: originalGeometry(f))) {
        XCTAssertEqual($0 as? LibrarySummaryError, .invalidGrounding)
      }
      XCTAssertEqual(try f.db.adapterRead { try Int.fetchOne($0,
        sql: "SELECT COUNT(*) FROM librarySummaryResult") }, 0)
      XCTAssertEqual(try f.db.adapterRead { try String.fetchOne($0,
        sql: "SELECT state FROM librarySummaryJob") }, "running")
      try f.db.adapterWrite { sql in
        try sql.execute(sql: "UPDATE librarySummaryJob SET frozen = ? WHERE job = ?",
          arguments: [originalBytes, f.identity.job.uuidString])
      }
      let saved = try publish(f)
      let service = try LibrarySummaryService(database: f.db, geometry: originalGeometry(f))
      XCTAssertEqual(try service.restore(paperID: f.identity.paperID)?.id, saved.id)
      try f.db.adapterWrite { sql in
        try sql.execute(sql: "UPDATE librarySummaryJob SET frozen = ? WHERE job = ?",
          arguments: [forgedBytes, f.identity.job.uuidString])
        try sql.execute(sql: "UPDATE librarySummaryResult SET frozen = ? WHERE id = ?",
          arguments: [forgedBytes, saved.id.uuidString])
      }
      XCTAssertThrowsError(try service.restore(paperID: f.identity.paperID)) {
        XCTAssertEqual($0 as? LibrarySummaryError, .invalidGrounding)
      }
    }
  }

  func testUnrankedFrozenTailRejectsForgedQuoteAndAnchorAtEveryStorageBoundary() throws {
    try assertForgedTailRejected(tail: "unranked canonical source", rankTail: false)
  }

  func testBudgetTruncatedFrozenTailRejectsForgedQuoteAndAnchorAtEveryStorageBoundary() throws {
    // Beyond the canonical per-item byte cap: ranked, but omitted from the wire prefix.
    let authority = try ProviderRequest()
    let cap = try XCTUnwrap(authority.contract["definitions"]["item"]["fields"]["quote"]["maxBytes"].integer)
    try assertForgedTailRejected(tail: String(repeating: "x", count: cap + 1), rankTail: true)
  }

  func testUnselectedFrozenTailRequiresCanonicalGeometry() throws {
    let f = try fixture(tail: "unranked canonical source")
    defer { try? FileManager.default.removeItem(at: f.root) }
    try f.db.adapterWrite { sql in
      try sql.execute(sql: "UPDATE extractionSentence SET geometry = ? WHERE revision = ? AND sentenceID = 2",
        arguments: [Data([0]), f.identity.revision.uuidString])
    }
    XCTAssertThrowsError(try reserve(f)) {
      XCTAssertEqual($0 as? CanonicalExtractionGeometryError, .invalidEncoding)
    }
    XCTAssertEqual(try f.db.adapterRead { try Int.fetchOne($0,
      sql: "SELECT COUNT(*) FROM librarySummaryJob") }, 0)
  }

  func testSaveReopenRestoresExactOrderedGroundingWithoutProvider() throws {
    let f = try fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    try reserve(f)
    let saved = try publish(f)
    let reopened = try ProductDatabase.open(at: f.root)
    let restored = try XCTUnwrap(LibrarySummaryService(database: reopened,
      geometry: originalGeometry(f)).restore(paperID: f.identity.paperID))
    XCTAssertEqual(restored.id, saved.id)
    XCTAssertEqual(restored.identity, f.identity)
    XCTAssertEqual(restored.result, f.result)
    XCTAssertEqual(restored.evidence, saved.evidence)
    XCTAssertEqual(restored.claimAnchors.map(\.identity.sentenceID), [1, 0])
    XCTAssertEqual(restored.claimAnchors.map(\.fullSourceQuote),
      ["results conclusion beta", "main contribution alpha"])
  }

  func testRestoreDeniesChangedQuoteMissingSentenceAndCorruptGeometry() throws {
    let f = try fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    try reserve(f)
    _ = try publish(f)
    let service = try LibrarySummaryService(database: f.db, geometry: originalGeometry(f))
    try f.db.adapterWrite { sql in
      try sql.execute(sql: "UPDATE extractionSentence SET text = 'unrelated' WHERE revision = ? AND sentenceID = 1",
        arguments: [f.identity.revision.uuidString])
    }
    XCTAssertThrowsError(try service.restore(paperID: f.identity.paperID)) {
      XCTAssertEqual($0 as? LibrarySummaryError, .invalidGrounding)
    }
    try f.db.adapterWrite { sql in
      try sql.execute(sql: "UPDATE extractionSentence SET text = 'results conclusion beta', geometry = ? WHERE revision = ? AND sentenceID = 1",
        arguments: [Data([0]), f.identity.revision.uuidString])
    }
    XCTAssertThrowsError(try service.restore(paperID: f.identity.paperID)) {
      XCTAssertEqual($0 as? CanonicalExtractionGeometryError, .invalidEncoding)
    }
    try f.db.adapterWrite { sql in
      try sql.execute(sql: "DELETE FROM extractionSentence WHERE revision = ? AND sentenceID = 1",
        arguments: [f.identity.revision.uuidString])
    }
    XCTAssertThrowsError(try service.restore(paperID: f.identity.paperID)) {
      XCTAssertEqual($0 as? LibrarySummaryError, .invalidGrounding)
    }
  }

  func testGuardedCommitRejectsConfigurationChangeWithoutPartialResult() throws {
    let f = try fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    try reserve(f)
    _ = try f.db.compareAndSwapProviderConfiguration(expected: f.db.providerConfiguration(),
      replacementKind: nil, replacementSlotID: nil, replacementModel: "changed")
    XCTAssertThrowsError(try publish(f))
    XCTAssertEqual(try f.db.adapterRead { try Int.fetchOne($0,
      sql: "SELECT COUNT(*) FROM librarySummaryResult") }, 0)
    XCTAssertEqual(try f.db.adapterRead { try String.fetchOne($0,
      sql: "SELECT state FROM librarySummaryJob WHERE job = ?", arguments: [f.identity.job.uuidString]) }, "running")
  }

  func testPointerFailureRollsBackResultAndJobSuccess() throws {
    let f = try fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    try reserve(f)
    try f.db.adapterWrite { sql in
      try sql.execute(sql: """
        CREATE TRIGGER rejectSummaryPointer BEFORE INSERT ON librarySummaryVisible
        BEGIN SELECT RAISE(ABORT, 'injected pointer failure'); END;
        """)
    }
    XCTAssertThrowsError(try publish(f))
    XCTAssertEqual(try f.db.adapterRead { try Int.fetchOne($0,
      sql: "SELECT COUNT(*) FROM librarySummaryResult") }, 0)
    XCTAssertEqual(try f.db.adapterRead { try String.fetchOne($0,
      sql: "SELECT state FROM librarySummaryJob") }, "running")
  }

  func testLibraryRejectsVisibleSummaryBoundToAnotherPaperAfterReopen() throws {
    let f = try fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let other = try fixture(database: f.db)
    try reserve(f)
    let saved = try publish(f)
    try f.db.adapterWrite { db in
      try db.execute(sql: "INSERT INTO librarySummaryVisible(paperID, resultID) VALUES (?, ?)",
        arguments: [other.identity.paperID.uuidString, saved.id.uuidString])
    }

    let reopened = try ProductDatabase.open(at: f.root)
    XCTAssertThrowsError(try LibrarySummaryService(database: reopened)
      .restore(paperID: other.identity.paperID)) { error in
        XCTAssertEqual(error as? LibrarySummaryError, .invalidResult)
      }
    let facts = try reopened.librarySortFacts()
    let otherSummary = try XCTUnwrap(facts.first { $0.paperID == other.identity.paperID }?.summary)
    XCTAssertEqual(otherSummary.availability, .verificationFailed)
    XCTAssertNil(otherSummary.record)
    let original = try XCTUnwrap(facts.first { $0.paperID == f.identity.paperID }?.summary)
    XCTAssertEqual(original.availability, .available)
    XCTAssertEqual(original.record?.id, saved.id)
    XCTAssertEqual(original.record?.claimAnchors, saved.claimAnchors)
  }

  func testDuplicateIntentCannotSendAgainAndInterruptionCannotPublish() throws {
    let f = try fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    try reserve(f)
    XCTAssertThrowsError(try reserve(f))
    _ = try ProductJobRecovery(database: f.db).recoverStartup(currentEpoch: UUID())
    XCTAssertThrowsError(try publish(f))
    XCTAssertThrowsError(try reserve(f))
  }

  func testPreviousSavedIdentitySurvivesConfigurationChangeAndFailure() throws {
    let f = try fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    try reserve(f)
    let saved = try publish(f)
    _ = try f.db.compareAndSwapProviderConfiguration(expected: f.db.providerConfiguration(),
      replacementKind: nil, replacementSlotID: nil, replacementModel: "changed")
    try f.db.failLibrarySummary(f.identity)
    let restored = try XCTUnwrap(LibrarySummaryService(database: f.db,
      geometry: originalGeometry(f)).restore(paperID: f.identity.paperID))
    XCTAssertEqual(restored.id, saved.id)
    XCTAssertEqual(restored.identity.configurationGeneration, 0)
  }

  func testDeletionDeniesLateCommitAndRemovesVisibility() throws {
    let f = try fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    try reserve(f)
    _ = try f.db.beginDeletion(f.identity.paperID)
    XCTAssertThrowsError(try publish(f))
    XCTAssertNil(try LibrarySummaryService(database: f.db,
      geometry: originalGeometry(f)).restore(paperID: f.identity.paperID))
  }

  func testFrozenContextRoundTripAndInvalidSummaryAreValidatedLocally() throws {
    let f = try fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let restored = try JSONDecoder().decode(LibrarySummaryFrozen.self,
      from: JSONEncoder().encode(f.frozen))
    let authority = try ProviderRequest()
    XCTAssertEqual(try authority.encodeRequest(restored.authorized(using: authority)), f.frozen.request)
    XCTAssertEqual(try restored.validate(result: ProviderRequest.canonicalBytes(f.result.value)), f.result)
    for text in ["   ", "line one\nline two", "line one\r\nline two"] {
      let raw = try JSONSerialization.data(withJSONObject: ["schemaVersion": f.result.schemaVersion,
        "requestID": f.result.requestID, "operation": "librarySummary",
        "result": ["summary": ["text": text, "kind": "paper", "evidenceIndices": [0]], "insufficiency": "none"]])
      XCTAssertThrowsError(try restored.validate(result: raw))
    }
  }

  func testFrozenContextRejectsChangedRankedProjection() throws {
    let f = try fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    var stored = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(f.frozen))
      as? [String: Any])
    stored["ranked"] = [0, 1]
    let changed = try JSONDecoder().decode(LibrarySummaryFrozen.self,
      from: JSONSerialization.data(withJSONObject: stored))
    XCTAssertThrowsError(try changed.authorized()) { error in
      XCTAssertEqual((error as? RequestContractError)?.code, "sourceMismatch")
    }
  }

  func testFrozenValidationRejectsNonClosedOrMismatchedResponse() throws {
    let f = try fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let valid = try XCTUnwrap(JSONSerialization.jsonObject(
      with: ProviderRequest.canonicalBytes(f.result.value)) as? [String: Any])
    var extra = valid
    extra["unexpected"] = true
    var wrongRequest = valid
    wrongRequest["requestID"] = UUID().uuidString.lowercased()
    var wrongOperation = valid
    wrongOperation["operation"] = "paperChat"
    var wrongResult = try XCTUnwrap(valid["result"] as? [String: Any])
    wrongResult["insufficiency"] = "noEvidence"
    var wrongInsufficiency = valid
    wrongInsufficiency["result"] = wrongResult
    var summary = try XCTUnwrap(wrongResult["summary"] as? [String: Any])
    summary["evidenceIndices"] = [2]
    wrongResult["summary"] = summary
    wrongResult["insufficiency"] = "none"
    var wrongEvidence = valid
    wrongEvidence["result"] = wrongResult
    for response in [extra, wrongRequest, wrongOperation, wrongInsufficiency, wrongEvidence] {
      XCTAssertThrowsError(try f.frozen.validate(
        result: JSONSerialization.data(withJSONObject: response))) { error in
        XCTAssertEqual((error as? RequestContractError)?.code, "invalidResult")
      }
    }
  }

  func testAbsentSavedSummaryRestoresNilWithoutGeometryOrDurableEffects() throws {
    let f = try fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    XCTAssertNil(try LibrarySummaryService(database: f.db).restore(paperID: f.identity.paperID))
    for table in ["librarySummaryJob", "librarySummaryResult", "librarySummaryVisible",
      "librarySummaryOwner", "librarySummaryOwnerAnchor"] {
      XCTAssertEqual(try f.db.adapterRead { try Int.fetchOne($0,
        sql: "SELECT COUNT(*) FROM \(table)") }, 0, table)
    }
  }

  func testMissingProviderDeniesDispatchBeforeDurableIntent() async throws {
    let f = try fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let i = f.identity
    let authority = JobRecoveryPolicy.Authority(input: .librarySummary(version: i.input.uuidString),
      config: .generation(String(i.configurationGeneration)),
      paper: .init(id: i.paperID.uuidString, generation: i.generation.uuidString),
      epoch: i.epoch.uuidString, prerequisitesAvailable: true)
    let pending = try JobRecoveryPolicy.create(job: i.job.uuidString, role: .librarySummary,
      authority: authority, reservation: .init(attempt: i.attempt.uuidString,
        fence: i.fence.uuidString, correlation: i.correlation.uuidString))
    let running = JobRecoveryPolicy.apply(.claim(pending.current.lineage), to: pending).snapshot
    let admitted = JobRecoveryPolicy.apply(.dispatch(running.current.lineage), to: running).snapshot
    do {
      _ = try await LibrarySummaryService(database: f.db, geometry: originalGeometry(f))
        .dispatch(f.request, identity: i, snapshot: admitted)
      XCTFail("Missing provider must deny dispatch")
    } catch {
      XCTAssertEqual(error as? LibrarySummaryError, .providerUnavailable)
    }
    XCTAssertEqual(try f.db.adapterRead { try Int.fetchOne($0,
      sql: "SELECT COUNT(*) FROM librarySummaryJob") }, 0)
  }

  func testQuoteMismatchDeniesReservationBeforeAnyJobIsSaved() throws {
    let f = try fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    try f.db.adapterWrite { sql in
      try sql.execute(sql: "UPDATE extractionSentence SET text = 'wrong source' WHERE revision = ? AND sentenceID = 0",
        arguments: [f.identity.revision.uuidString])
    }
    XCTAssertThrowsError(try reserve(f)) {
      XCTAssertEqual($0 as? LibrarySummaryError, .invalidGrounding)
    }
    XCTAssertEqual(try f.db.adapterRead { try Int.fetchOne($0,
      sql: "SELECT COUNT(*) FROM librarySummaryJob") }, 0)
  }

  func testWireGenerationOrdinalIsStableAcrossReopenAndRejectsReplacedGeneration() throws {
    let f = try fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let first = try f.db.summaryGenerationOrdinal(paperID: f.identity.paperID,
      generation: f.identity.generation)
    let reopened = try ProductDatabase.open(at: f.root)
    XCTAssertEqual(try reopened.summaryGenerationOrdinal(paperID: f.identity.paperID,
      generation: f.identity.generation), first)
    let replacement = UUID()
    try f.db.adapterWrite {
      try $0.execute(sql: "UPDATE paper SET generation = ? WHERE id = ?",
        arguments: [replacement.uuidString, f.identity.paperID.uuidString])
    }
    let next = try reopened.summaryGenerationOrdinal(paperID: f.identity.paperID,
      generation: replacement)
    XCTAssertGreaterThan(next, first)
    XCTAssertThrowsError(try reopened.summaryGenerationOrdinal(paperID: f.identity.paperID,
      generation: f.identity.generation))
    XCTAssertThrowsError(try f.db.reserveLibrarySummary(f.identity, frozen: f.frozen,
      geometry: originalGeometry(f)))
  }

  @MainActor private final class SummaryLease: ReaderReadLease {
    var revoked = false
    var closed = false
    var onValidate: (() throws -> Void)?
    func validate() throws {
      if revoked || closed { throw ReaderError.revoked }
      try onValidate?()
    }
    func withReadAccess<T>(_ operation: () throws -> T) throws -> T {
      try validate(); let result = try operation(); try validate(); return result
    }
    func close() { closed = true }
  }

  @MainActor private final class SummaryLeases: ReaderLeaseProvider {
    let lease = SummaryLease()
    var paperLeases: [UUID: SummaryLease] = [:]
    var callback: (@MainActor () -> Void)?
    func acquireReadLease(for snapshot: ReaderPaperSnapshot,
      onRevoked: @escaping @MainActor () -> Void) throws -> any ReaderReadLease {
      callback = onRevoked
      return paperLeases[snapshot.paperID] ?? lease
    }
    func revoke() { lease.revoked = true; callback?() }
  }

  @MainActor private final class SummaryProvider: LibrarySummaryProviding {
    var calls = 0
    var outputLanguages: [String] = []
    var suspend = false
    var continuation: CheckedContinuation<Void, Never>?
    var beforeResult: ((LibrarySummaryIdentity) throws -> Void)?
    func execute(_ request: AuthorizedProviderRequest, identity: LibrarySummaryIdentity) async throws
      -> ValidatedProviderResult {
      calls += 1
      guard case .librarySummary(let language, let evidence) = request.wire.typedInput else {
        throw LibrarySummaryError.invalidResult
      }
      outputLanguages.append(language)
      if suspend { await withCheckedContinuation { continuation = $0 } }
      try beforeResult?(identity)
      let value: [String: Any] = [
        "summary": ["text": evidence.items.isEmpty ? "Insufficient evidence" : "Grounded summary",
          "kind": evidence.items.isEmpty ? "insufficient" : "paper",
          "evidenceIndices": evidence.items.isEmpty ? [] : [0]],
        "insufficiency": evidence.insufficiency,
      ]
      let authority = try ProviderRequest()
      let rebound = try LibrarySummaryFrozen(request: request).authorized(using: authority)
      return try authority.wrapModelResult(JSONSerialization.data(withJSONObject: value), request: rebound)
    }
  }

  private func prepareCoordinator(_ f: Fixture) throws {
    let owners = try canonicalOwners(f)
    try f.db.adapterWrite { db in
      for owner in owners {
        try db.execute(sql: """
          INSERT INTO extractionGeometryOwner(revision, sentenceID, page, maximumErrorPDFPoints, originalAnchor)
          VALUES (?, ?, ?, 0, ?)
          """, arguments: [f.identity.revision.uuidString, owner.identity.sentenceID,
            owner.identity.pageIndex, CanonicalExtractionGeometryValidator.encodeCanonicalAnchor(owner)])
      }
    }
    _ = try f.db.compareAndSwapProviderConfiguration(expected: f.db.providerConfiguration(),
      replacementKind: .openAIAPIKey, replacementSlotID: UUID(), replacementModel: "fixture-model")
    let paper = f.db.root.appendingPathComponent("papers/\(f.identity.paperID.uuidString)")
    try FileManager.default.createDirectory(at: paper, withIntermediateDirectories: true)
    try Data("%PDF-1.4\nsynthetic summary fixture\n%%EOF".utf8)
      .write(to: paper.appendingPathComponent("document.pdf"))
  }

  @MainActor func testLibraryGenerationReadinessFollowsPublishedSourceAndProviderWithoutDispatch() throws {
    let f = try fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let provider = SummaryProvider()
    let coordinator = LibrarySummaryCoordinator(database: f.db, epoch: UUID(), leases: SummaryLeases(),
      authority: try ProviderRequest(), provider: provider)
    func blocker(providerAvailable: Bool = true) throws -> LibrarySummaryCoordinator.GenerationBlocker? {
      let facts = try f.db.organizationObservation(filter: .init()).facts.first
      return coordinator.generationBlocker(paperID: f.identity.paperID,
        observation: try XCTUnwrap(facts?.summary), providerAvailable: providerAvailable)
    }

    XCTAssertEqual(coordinator.generationBlocker(paperID: f.identity.paperID,
      observation: nil, providerAvailable: true), .unconfirmed)
    XCTAssertEqual(try blocker(), .geometryUnavailable)
    try prepareCoordinator(f)
    let ready = try XCTUnwrap(f.db.organizationObservation(filter: .init()).facts.first?.summary)
    XCTAssertEqual(ready.availability, .notSaved)
    XCTAssertNil(ready.record)
    XCTAssertNil(try blocker())
    XCTAssertEqual(try blocker(providerAvailable: false), .providerUnavailable)
    try f.db.adapterWrite { db in
      try db.execute(sql: "DELETE FROM extractionGeometryOwner WHERE revision = ? AND sentenceID = 1",
        arguments: [f.identity.revision.uuidString])
    }
    XCTAssertEqual(try blocker(), .geometryUnavailable, "A partial owner archive is not sufficient")
    try f.db.adapterWrite { db in
      try db.execute(sql: "DELETE FROM extractionVisible WHERE paperID = ?",
        arguments: [f.identity.paperID.uuidString])
    }
    XCTAssertEqual(try blocker(), .needsParsing)
    XCTAssertEqual(provider.calls, 0)
    XCTAssertEqual(try f.db.adapterRead { try Int.fetchOne($0,
      sql: "SELECT COUNT(*) FROM librarySummaryJob") }, 0)
  }

  @MainActor func testSkippedSummaryWritePreservesPriorResultAndNeverDispatchesWithoutSavedOwners() async throws {
    let f = try fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    try prepareCoordinator(f)
    let provider = SummaryProvider()
    let epoch = UUID()
    let authority = try ProviderRequest()
    func generate() async throws -> LibrarySummaryRecord {
      let coordinator = LibrarySummaryCoordinator(database: f.db, epoch: epoch, leases: SummaryLeases(),
        authority: authority, provider: provider)
      return try await coordinator.generate(paperID: f.identity.paperID,
        generation: f.identity.generation, outputLanguage: "en")
    }
    let previous = try await generate()
    let failedWrites: [(trigger: String, dispatches: Bool)] = [
      ("BEFORE INSERT ON librarySummaryJob BEGIN SELECT RAISE(IGNORE); END", false),
      ("BEFORE INSERT ON librarySummaryOwner BEGIN SELECT RAISE(IGNORE); END", false),
      ("BEFORE INSERT ON librarySummaryOwnerAnchor WHEN NEW.sentenceID = 1 BEGIN SELECT RAISE(IGNORE); END", false),
      ("BEFORE INSERT ON librarySummaryResult BEGIN SELECT RAISE(IGNORE); END", true),
      ("BEFORE UPDATE OF state ON librarySummaryJob WHEN NEW.state = 'succeeded' BEGIN SELECT RAISE(IGNORE); END", true),
      ("BEFORE UPDATE ON librarySummaryVisible BEGIN SELECT RAISE(IGNORE); END", true),
      ("""
        AFTER UPDATE ON librarySummaryVisible
        BEGIN UPDATE librarySummaryVisible SET resultID = OLD.resultID WHERE paperID = NEW.paperID; END
        """, true),
      ("""
        AFTER INSERT ON librarySummaryResult
        BEGIN UPDATE librarySummaryResult SET result = X'00' WHERE id = NEW.id; END
        """, true)
    ]
    let store = LibrarySummaryService(database: f.db)
    for (trigger, dispatches) in failedWrites {
      let calls = provider.calls
      let jobsBefore = try f.db.adapterRead { try Int.fetchOne($0,
        sql: "SELECT count(*) FROM librarySummaryJob") }
      try f.db.adapterWrite { db in
        try db.execute(sql: "CREATE TRIGGER failSummaryWrite \(trigger)")
      }
      do {
        _ = try await generate()
        XCTFail("Unconfirmed write was reported as success: \(trigger)")
      } catch {
        XCTAssertEqual(error as? LibrarySummaryError, .persistenceFailure, "\(trigger): \(error)")
      }
      XCTAssertEqual(provider.calls, calls + (dispatches ? 1 : 0), trigger)
      try f.db.adapterRead { db in
        if dispatches {
          let attempt = try XCTUnwrap(Row.fetchOne(db, sql: """
            SELECT state, failure, resultID, permit FROM librarySummaryJob ORDER BY rowid DESC LIMIT 1
            """))
          XCTAssertEqual(attempt["state"] as String, "failed", trigger)
          XCTAssertEqual(attempt["failure"] as String?, LibrarySummaryFailure.persistenceFailure.rawValue, trigger)
          XCTAssertNil(attempt["resultID"] as String?, trigger)
          XCTAssertNil(attempt["permit"] as String?, trigger)
        } else {
          XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM librarySummaryJob"),
            jobsBefore, trigger)
        }
        XCTAssertEqual(try String.fetchAll(db, sql: "SELECT id FROM librarySummaryResult"),
          [previous.id.uuidString], trigger)
        XCTAssertEqual(try String.fetchOne(db, sql: "SELECT resultID FROM librarySummaryVisible"),
          previous.id.uuidString, trigger)
      }
      XCTAssertEqual(try store.restore(paperID: f.identity.paperID)?.claimAnchors,
        previous.claimAnchors, trigger)
      try f.db.adapterWrite { try $0.execute(sql: "DROP TRIGGER failSummaryWrite") }
    }
    let replacement = try await generate()
    XCTAssertNotEqual(replacement.id, previous.id)
  }

  @MainActor func testUnrecordedSummaryTerminationPreservesSavedResultAndRecoversWithoutReplay() async throws {
    let failures = [
      ("BEFORE", "SELECT RAISE(IGNORE);", false),
      ("BEFORE", "SELECT RAISE(ABORT, 'fixture write failure');", true),
      ("AFTER", "UPDATE librarySummaryJob SET failure = 'network' WHERE job = NEW.job;", false)
    ]
    for (timing, body, cancelled) in failures {
      let f = try fixture()
      defer { try? FileManager.default.removeItem(at: f.root) }
      try prepareCoordinator(f)
      let authority = try ProviderRequest(), provider = SummaryProvider(), epoch = UUID()
      let initial = LibrarySummaryCoordinator(database: f.db, epoch: epoch, leases: SummaryLeases(),
        authority: authority, provider: provider)
      let saved = try await initial.generate(paperID: f.identity.paperID, generation: f.identity.generation,
        outputLanguage: "ko")
      try f.db.adapterWrite { db in
        try db.execute(sql: """
          CREATE TRIGGER failTerminalWrite \(timing) UPDATE OF state ON librarySummaryJob
          WHEN NEW.state = 'failed' BEGIN \(body) END;
          """)
      }
      let leases = SummaryLeases()
      let coordinator = LibrarySummaryCoordinator(database: f.db, epoch: epoch, leases: leases,
        authority: authority, provider: provider)
      provider.beforeResult = { _ in throw URLError(.timedOut) }
      provider.suspend = cancelled
      XCTAssertTrue(coordinator.requestGeneration(paperID: f.identity.paperID,
        generation: f.identity.generation, outputLanguage: "en"))
      if cancelled {
        for _ in 0..<1000 where provider.continuation == nil { await Task.yield() }
        let completion = try XCTUnwrap(provider.continuation)
        coordinator.cancel()
        XCTAssertFalse(leases.lease.closed)
        provider.beforeResult = nil
        completion.resume(); provider.continuation = nil
      }
      for _ in 0..<1000 where coordinator.activePaperID != nil { await Task.yield() }
      XCTAssertNil(coordinator.activePaperID)
      XCTAssertEqual(coordinator.requestFailure, .persistenceFailure)
      XCTAssertTrue(leases.lease.closed)
      XCTAssertEqual(provider.calls, 2)
      let observation = try XCTUnwrap(f.db.librarySortFacts().first?.summary)
      let unresolved = try XCTUnwrap(observation.recentAttempt)
      XCTAssertEqual(unresolved.activity, .running)
      XCTAssertNil(unresolved.failure)
      XCTAssertEqual(coordinator.generationBlocker(paperID: f.identity.paperID,
        observation: observation, providerAvailable: false), .terminationWriteFailed(unresolved.identity))
      XCTAssertEqual(observation.record?.id, saved.id)
      XCTAssertEqual(observation.record?.claimAnchors, saved.claimAnchors)
      do {
        try coordinator.recoverTermination(unresolved.identity)
        XCTFail("Rejected termination write reported success")
      } catch { }
      XCTAssertEqual(coordinator.generationBlocker(paperID: f.identity.paperID,
        observation: observation, providerAvailable: false), .terminationWriteFailed(unresolved.identity))

      try f.db.adapterWrite { try $0.execute(sql: "DROP TRIGGER failTerminalWrite") }
      try coordinator.recoverTermination(saved.identity)
      XCTAssertEqual(try f.db.librarySortFacts().first?.summary?.recentAttempt?.activity, .running)
      let failure: LibrarySummaryFailure
      if timing == "AFTER" {
        // A fresh owner sees a durable unresolved job but no live recovery action.
        let recovery = try ProductJobRecovery(database: f.db).recoverStartup(currentEpoch: UUID())
        XCTAssertEqual(recovery.interruptedJobs.map(\.jobID), [unresolved.identity.job])
        failure = .interrupted
      } else {
        failure = cancelled ? .cancelled : .timedOut
      }
      try coordinator.recoverTermination(unresolved.identity)
      let reopened = try ProductDatabase.open(at: f.root), nextEpoch = UUID()
      let recovered = try XCTUnwrap(reopened.librarySortFacts().first?.summary?.recentAttempt)
      XCTAssertEqual(recovered.identity, unresolved.identity)
      XCTAssertEqual(recovered.failure, failure)
      XCTAssertTrue(recovered.canRetry)
      let retained = try LibrarySummaryService(database: reopened).restore(paperID: f.identity.paperID)
      XCTAssertEqual(retained?.id, saved.id)
      XCTAssertEqual(retained?.claimAnchors, saved.claimAnchors)
      XCTAssertEqual(provider.calls, 2, "Saving the terminal status and restoring do not send a request")

      provider.suspend = false
      provider.beforeResult = nil
      let retry = LibrarySummaryCoordinator(database: reopened, epoch: nextEpoch, leases: SummaryLeases(),
        authority: authority, provider: provider)
      XCTAssertTrue(retry.requestRetry(recovered.identity))
      for _ in 0..<1000 where retry.activePaperID != nil { await Task.yield() }
      XCTAssertNil(retry.activePaperID)
      XCTAssertNil(retry.requestFailure)
      XCTAssertEqual(provider.outputLanguages, ["ko", "en", "en"])
      XCTAssertNotEqual(try LibrarySummaryService(database: reopened).restore(paperID: f.identity.paperID)?.id, saved.id)
    }
  }

  @MainActor func testStaleSummaryTerminationRecoveryCannotChangeDeletingPaper() async throws {
    let f = try fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    try prepareCoordinator(f)
    let provider = SummaryProvider()
    provider.beforeResult = { _ in throw URLError(.timedOut) }
    let coordinator = LibrarySummaryCoordinator(database: f.db, epoch: UUID(), leases: SummaryLeases(),
      authority: try ProviderRequest(), provider: provider)
    try f.db.adapterWrite { db in
      try db.execute(sql: """
        CREATE TRIGGER ignoreSummaryTermination BEFORE UPDATE OF state ON librarySummaryJob
        WHEN NEW.state = 'failed' BEGIN SELECT RAISE(IGNORE); END;
        """)
    }
    do {
      try await coordinator.generate(paperID: f.identity.paperID, generation: f.identity.generation,
        outputLanguage: "ko")
      XCTFail("Uncommitted termination reported success")
    } catch { XCTAssertEqual(error as? LibrarySummaryError, .persistenceFailure) }
    let pending = try XCTUnwrap(f.db.librarySortFacts().first?.summary?.recentAttempt).identity
    _ = try XCTUnwrap(f.db.beginDeletion(f.identity.paperID))
    // Even if the deletion-side terminal update did not stick, the revoked paper
    // must not be touched by an older recovery button callback.
    try f.db.adapterWrite { try $0.execute(sql: "DROP TRIGGER ignoreSummaryTermination") }
    try coordinator.recoverTermination(pending)
    XCTAssertEqual(try f.db.adapterRead { try String.fetchOne($0, sql: "SELECT state FROM librarySummaryJob") }, "running")
    XCTAssertNil(try LibrarySummaryService(database: f.db).restore(paperID: f.identity.paperID))
    XCTAssertEqual(provider.calls, 1)
  }

  @MainActor func testExplicitCoordinatorDispatchPublishesGroundedResultAndRestoresWithoutRequest() async throws {
    let f = try fixture(tail: "appendix acknowledgments")
    defer { try? FileManager.default.removeItem(at: f.root) }
    try prepareCoordinator(f)
    let leases = SummaryLeases(), provider = SummaryProvider()
    let coordinator = LibrarySummaryCoordinator(database: f.db, epoch: UUID(), leases: leases,
      authority: try ProviderRequest(), provider: provider)
    XCTAssertEqual(provider.calls, 0)
    let saved = try await coordinator.generate(paperID: f.identity.paperID,
      generation: f.identity.generation, outputLanguage: "ko")
    XCTAssertEqual(provider.calls, 1)
    XCTAssertTrue(leases.lease.closed)
    XCTAssertNil(coordinator.activePaperID)
    XCTAssertEqual(saved.evidence.items.map(\.quote), ["main contribution alpha", "results conclusion beta"])
    XCTAssertEqual(saved.claimAnchors.map(\.fullSourceQuote), ["main contribution alpha"])
    let restored = try XCTUnwrap(LibrarySummaryService(database: ProductDatabase.open(at: f.root))
      .restore(paperID: f.identity.paperID))
    XCTAssertEqual(restored.id, saved.id)
    XCTAssertEqual(restored.claimAnchors, saved.claimAnchors)
    XCTAssertEqual(provider.calls, 1)
    let files = try FileManager.default.contentsOfDirectory(atPath:
      f.db.root.appendingPathComponent("papers/\(f.identity.paperID.uuidString)").path)
    XCTAssertEqual(files, ["document.pdf"])
  }

  @MainActor func testLateSummaryAfterReparseKeepsPriorSourceLabelAndEvidence() async throws {
    let f = try fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    try prepareCoordinator(f)
    let provider = SummaryProvider()
    let authority = try ProviderRequest(), epoch = UUID()
    let initial = LibrarySummaryCoordinator(database: f.db, epoch: epoch, leases: SummaryLeases(),
      authority: authority, provider: provider)
    let paperID = f.identity.paperID
    let generation = f.identity.generation
    let saved = try await initial.generate(paperID: paperID, generation: generation, outputLanguage: "en")
    XCTAssertFalse(saved.claimAnchors.isEmpty)
    XCTAssertEqual(try f.db.librarySortFacts().first?.summary?.savedSource, .current)

    let newer = UUID()
    provider.beforeResult = { identity in
      XCTAssertEqual(identity.revision, saved.identity.revision)
      let parse = ExtractionIdentity(paperID: paperID, generation: generation, pdfSHA256: f.identity.pdfSHA256,
        pdfReference: "papers/\(paperID.uuidString)/document.pdf", revision: newer, job: UUID(),
        attempt: UUID(), fence: UUID(), correlation: UUID(), input: UUID(), epoch: UUID(),
        configuration: try f.db.providerConfiguration())
      try f.db.reserveExtraction(parse)
      try f.db.publishExtraction(parse, sentences: [
        .init(page: 0, sentenceID: 0, text: "New source revision", geometry: Data(), originalOwner: nil),
      ], checkBudget: {})
    }
    let coordinator = LibrarySummaryCoordinator(database: f.db, epoch: epoch, leases: SummaryLeases(),
      authority: authority, provider: provider)
    do {
      _ = try await coordinator.generate(paperID: paperID, generation: generation, outputLanguage: "en")
      XCTFail("The in-flight response must not publish for a superseded extraction")
    } catch { XCTAssertEqual(error as? LibrarySummaryError, .staleIdentity) }

    let reopened = try ProductDatabase.open(at: f.root)
    let summary = try XCTUnwrap(reopened.librarySortFacts().first?.summary)
    XCTAssertEqual(summary.source?.revision, newer)
    XCTAssertEqual(summary.savedSource, .previous)
    XCTAssertEqual(summary.recentAttempt?.failure, .staleIdentity)
    XCTAssertEqual(summary.record?.id, saved.id)
    XCTAssertEqual(summary.record?.identity.revision, saved.identity.revision)
    XCTAssertEqual(summary.record?.claimAnchors, saved.claimAnchors)
    XCTAssertEqual(try reopened.adapterRead { try Int.fetchOne($0,
      sql: "SELECT COUNT(*) FROM librarySummaryResult") }, 1)
    try reopened.adapterWrite { try $0.execute(sql: "DELETE FROM extractionVisible") }
    let unpublished = try XCTUnwrap(reopened.librarySortFacts().first?.summary)
    XCTAssertEqual(unpublished.savedSource, .noCurrentSource)
    XCTAssertEqual(unpublished.record?.claimAnchors, saved.claimAnchors)
    XCTAssertEqual(provider.calls, 2)
  }

  @MainActor func testRevocationCancelsSummaryButRetainsLeaseUntilActualProviderReturn() async throws {
    let f = try fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    try prepareCoordinator(f)
    let leases = SummaryLeases(), provider = SummaryProvider()
    provider.suspend = true
    let coordinator = LibrarySummaryCoordinator(database: f.db, epoch: UUID(), leases: leases,
      authority: try ProviderRequest(), provider: provider)
    let task = Task { try await coordinator.generate(paperID: f.identity.paperID,
      generation: f.identity.generation, outputLanguage: "en") }
    for _ in 0..<1000 where provider.continuation == nil { await Task.yield() }
    guard let completion = provider.continuation else {
      _ = try await task.value
      return XCTFail("Provider did not enter controlled execution")
    }
    leases.revoke()
    XCTAssertFalse(leases.lease.closed, "Cancellation acceptance cannot release the actual producer pin")
    completion.resume(); provider.continuation = nil
    do { _ = try await task.value; XCTFail("Revoked generation cannot publish") }
    catch { XCTAssertTrue(error is CancellationError) }
    XCTAssertTrue(leases.lease.closed)
    XCTAssertNil(try LibrarySummaryService(database: f.db).restore(paperID: f.identity.paperID))
    XCTAssertEqual(try f.db.adapterRead { try String.fetchOne($0,
      sql: "SELECT state FROM librarySummaryJob") }, "failed")
    XCTAssertEqual(try f.db.librarySortFacts().first?.summary?.recentAttempt?.failure, .cancelled)
  }

  @MainActor func testLibraryRequestReturnsImmediatelyAndSurvivesPresentationLifetime() async throws {
    let f = try fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    try prepareCoordinator(f)
    let leases = SummaryLeases(), provider = SummaryProvider()
    provider.suspend = true
    let coordinator = LibrarySummaryCoordinator(database: f.db, epoch: UUID(), leases: leases,
      authority: try ProviderRequest(), provider: provider)
    XCTAssertTrue(coordinator.requestGeneration(paperID: f.identity.paperID,
      generation: f.identity.generation, outputLanguage: "ko"))
    XCTAssertEqual(coordinator.activePaperID, f.identity.paperID)
    XCTAssertFalse(coordinator.requestGeneration(paperID: UUID(), generation: UUID(), outputLanguage: "en"))
    do {
      _ = try await coordinator.generate(paperID: f.identity.paperID,
        generation: f.identity.generation, outputLanguage: "en")
      XCTFail("A queued Library request must retain exclusive generation ownership")
    } catch { XCTAssertEqual(error as? LibrarySummaryError, .requestInProgress) }
    for _ in 0..<1000 where provider.continuation == nil { await Task.yield() }
    let completion = try XCTUnwrap(provider.continuation)
    // No view task or awaiting caller owns this request. Presentation can end while
    // the retained coordinator continues and the original PDF remains readable.
    XCTAssertEqual(coordinator.activePaperID, f.identity.paperID)
    XCTAssertFalse(leases.lease.closed)
    XCTAssertNil(coordinator.completionRevision)
    let paper = try f.db.readerSnapshot(paperID: f.identity.paperID)
    XCTAssertFalse(try Data(contentsOf: f.db.root.appendingPathComponent(paper.pdfReference)).isEmpty)
    completion.resume(); provider.continuation = nil
    for _ in 0..<1000 where coordinator.activePaperID != nil { await Task.yield() }
    XCTAssertNil(coordinator.activePaperID)
    XCTAssertNil(coordinator.requestFailure)
    XCTAssertNotNil(coordinator.completionRevision)
    XCTAssertTrue(leases.lease.closed)
    XCTAssertEqual(provider.calls, 1)
    XCTAssertNotNil(try LibrarySummaryService(database: f.db).restore(paperID: f.identity.paperID))
  }

  @MainActor func testLibraryRequestCancellationWaitsForActualProducerReturn() async throws {
    let f = try fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    try prepareCoordinator(f)
    let leases = SummaryLeases(), provider = SummaryProvider()
    provider.suspend = true
    let coordinator = LibrarySummaryCoordinator(database: f.db, epoch: UUID(), leases: leases,
      authority: try ProviderRequest(), provider: provider)
    XCTAssertTrue(coordinator.requestGeneration(paperID: f.identity.paperID,
      generation: f.identity.generation, outputLanguage: "ko"))
    for _ in 0..<1000 where provider.continuation == nil { await Task.yield() }
    let completion = try XCTUnwrap(provider.continuation)
    coordinator.cancel()
    XCTAssertFalse(leases.lease.closed)
    XCTAssertEqual(coordinator.activePaperID, f.identity.paperID)
    XCTAssertFalse(coordinator.requestGeneration(paperID: UUID(), generation: UUID(), outputLanguage: "en"))
    completion.resume(); provider.continuation = nil
    for _ in 0..<1000 where coordinator.activePaperID != nil { await Task.yield() }
    XCTAssertNil(coordinator.activePaperID)
    XCTAssertNil(coordinator.requestFailure, "Explicit cancellation must not show a delayed failure alert")
    XCTAssertNotNil(coordinator.completionRevision)
    XCTAssertTrue(leases.lease.closed)
    XCTAssertNil(try LibrarySummaryService(database: f.db).restore(paperID: f.identity.paperID))
    XCTAssertEqual(try f.db.librarySortFacts().first?.summary?.recentAttempt?.failure, .cancelled)
  }

  @MainActor func testLibraryRequestReportsParsingUnavailableWithConfiguredProvider() async throws {
    let f = try fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    try prepareCoordinator(f)
    try f.db.adapterWrite { db in
      try db.execute(sql: "DELETE FROM extractionVisible WHERE paperID = ?",
        arguments: [f.identity.paperID.uuidString])
    }
    let provider = SummaryProvider()
    let coordinator = LibrarySummaryCoordinator(database: f.db, epoch: UUID(), leases: SummaryLeases(),
      authority: try ProviderRequest(), provider: provider)
    for _ in 0..<2 {
      let previous = coordinator.completionRevision
      XCTAssertTrue(coordinator.requestGeneration(paperID: f.identity.paperID,
        generation: f.identity.generation, outputLanguage: "ko"))
      XCTAssertEqual(coordinator.completionRevision, previous)
      for _ in 0..<1000 where coordinator.activePaperID != nil { await Task.yield() }
      XCTAssertNil(coordinator.activePaperID)
      XCTAssertEqual(coordinator.requestFailure, .geometryUnavailable)
      XCTAssertNotEqual(coordinator.completionRevision, previous)
    }
    XCTAssertEqual(provider.calls, 0)
    XCTAssertNil(try f.db.librarySortFacts().first?.summary?.recentAttempt)
    XCTAssertNoThrow(try f.db.readerSnapshot(paperID: f.identity.paperID))
  }

  @MainActor func testSummaryAnnouncementCanCancelBeforeDispatchAndCannotAdmitSecondRequest() async throws {
    for libraryRequest in [true, false] {
      let f = try fixture()
      defer { try? FileManager.default.removeItem(at: f.root) }
      try prepareCoordinator(f)
      let leases = SummaryLeases(), provider = SummaryProvider()
      let coordinator = LibrarySummaryCoordinator(database: f.db, epoch: UUID(), leases: leases,
        authority: try ProviderRequest(), provider: provider)
      var announced = false
      let subscription = coordinator.$activePaperID.sink { paperID in
        guard !announced, paperID == f.identity.paperID else { return }
        announced = true
        XCTAssertFalse(coordinator.requestGeneration(paperID: f.identity.paperID,
          generation: f.identity.generation, outputLanguage: "en"))
        coordinator.cancel()
      }
      defer { subscription.cancel() }
      if libraryRequest {
        XCTAssertTrue(coordinator.requestGeneration(paperID: f.identity.paperID,
          generation: f.identity.generation, outputLanguage: "ko"))
        for _ in 0..<1000 where coordinator.activePaperID != nil { await Task.yield() }
      } else {
        do {
          _ = try await coordinator.generate(paperID: f.identity.paperID,
            generation: f.identity.generation, outputLanguage: "ko")
          XCTFail("Cancellation at announcement must prevent dispatch")
        } catch { XCTAssertTrue(error is CancellationError) }
      }
      XCTAssertTrue(announced)
      XCTAssertNil(coordinator.activePaperID)
      XCTAssertNil(coordinator.requestFailure)
      XCTAssertEqual(provider.calls, 0)
      XCTAssertEqual(try f.db.adapterRead { try Int.fetchOne($0,
        sql: "SELECT COUNT(*) FROM librarySummaryJob") }, 0)
    }
  }

  @MainActor func testSummaryStageCleanupFailureBlocksOnlyItsPaperAndPreservesPreviousResult() async throws {
    let f = try fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    try prepareCoordinator(f)
    let otherPaper = try fixture(database: f.db)
    try prepareCoordinator(otherPaper)
    let provider = SummaryProvider()
    let authority = try ProviderRequest(), epoch = UUID()
    let initial = LibrarySummaryCoordinator(database: f.db, epoch: epoch, leases: SummaryLeases(),
      authority: authority, provider: provider)
    let previous = try await initial.generate(paperID: f.identity.paperID,
      generation: f.identity.generation, outputLanguage: "ko")
    var stagingDirectory: URL?
    let leases = SummaryLeases()
    let foreignBytes = Data("test-owned sentinel".utf8)
    provider.beforeResult = { identity in
      stagingDirectory = f.root.appendingPathComponent(
        "papers/\(identity.paperID.uuidString)/.summary-\(identity.job.uuidString)")
    }
    leases.lease.onValidate = {
      guard let stagingDirectory, FileManager.default.fileExists(atPath:
        stagingDirectory.appendingPathComponent("result.json").path) else { return }
      try foreignBytes.write(to: stagingDirectory.appendingPathComponent("foreign"))
    }
    let coordinator = LibrarySummaryCoordinator(database: f.db, epoch: epoch, leases: leases,
      authority: authority, provider: provider)
    do {
      _ = try await coordinator.generate(paperID: f.identity.paperID,
        generation: f.identity.generation, outputLanguage: "en")
      XCTFail("Unconfirmed staging cleanup must prevent publication")
    } catch { XCTAssertEqual(error as? LibrarySummaryError, .cleanupUnavailable) }

    let foreign = try XCTUnwrap(stagingDirectory).appendingPathComponent("foreign")
    XCTAssertEqual(try Data(contentsOf: foreign), foreignBytes)
    XCTAssertFalse(leases.lease.closed)
    let reopened = try ProductDatabase.open(at: f.root)
    let restored = try XCTUnwrap(LibrarySummaryService(database: reopened)
      .restore(paperID: f.identity.paperID))
    XCTAssertEqual(restored.id, previous.id)
    XCTAssertEqual(restored.claimAnchors, previous.claimAnchors)
    let facts = try reopened.librarySortFacts()
    let observation = try XCTUnwrap(facts.first { $0.paperID == f.identity.paperID }?.summary)
    XCTAssertEqual(observation.recentAttempt?.failure, .cleanupUnavailable)
    XCTAssertEqual(coordinator.generationBlocker(paperID: f.identity.paperID,
      observation: observation, providerAvailable: true), .cleanupUnavailable)
    do {
      _ = try await coordinator.generate(paperID: f.identity.paperID,
        generation: f.identity.generation, outputLanguage: "en")
      XCTFail("The affected paper must stay blocked while its stage and lease are retained")
    } catch { XCTAssertEqual(error as? LibrarySummaryError, .cleanupUnavailable) }
    XCTAssertEqual(provider.calls, 2)

    let otherPaperID = otherPaper.identity.paperID
    let otherObservation = try XCTUnwrap(facts.first { $0.paperID == otherPaperID }?.summary)
    XCTAssertNil(coordinator.generationBlocker(paperID: otherPaperID,
      observation: otherObservation, providerAvailable: true))
    let revokeFirst = try XCTUnwrap(leases.callback)
    let otherLease = SummaryLease()
    leases.paperLeases[otherPaperID] = otherLease
    provider.beforeResult = nil
    provider.suspend = true
    XCTAssertTrue(coordinator.requestGeneration(paperID: otherPaperID,
      generation: otherPaper.identity.generation, outputLanguage: "ko"))
    for _ in 0..<1000 where provider.continuation == nil { await Task.yield() }
    let completion = try XCTUnwrap(provider.continuation)
    leases.lease.revoked = true
    revokeFirst()
    completion.resume(); provider.continuation = nil
    for _ in 0..<1000 where coordinator.activePaperID != nil { await Task.yield() }
    XCTAssertNil(coordinator.activePaperID)
    XCTAssertNil(coordinator.requestFailure)
    XCTAssertTrue(otherLease.closed)
    XCTAssertFalse(leases.lease.closed)
    XCTAssertEqual(provider.calls, 3)
    XCTAssertEqual(try Data(contentsOf: foreign), foreignBytes)
    XCTAssertNotNil(try LibrarySummaryService(database: reopened).restore(paperID: otherPaperID))
  }

  @MainActor func testLibraryRequestRetainsSafeFailureUntilDismissedWithoutRetry() async throws {
    let f = try fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    try prepareCoordinator(f)
    let leases = SummaryLeases(), provider = SummaryProvider()
    provider.beforeResult = { _ in throw APIKeyConnectionError.authentication }
    let coordinator = LibrarySummaryCoordinator(database: f.db, epoch: UUID(), leases: leases,
      authority: try ProviderRequest(), provider: provider)
    XCTAssertTrue(coordinator.requestGeneration(paperID: f.identity.paperID,
      generation: f.identity.generation, outputLanguage: "ko"))
    for _ in 0..<1000 where coordinator.activePaperID != nil { await Task.yield() }
    XCTAssertNil(coordinator.activePaperID)
    XCTAssertEqual(coordinator.requestFailure, .authentication)
    XCTAssertTrue(leases.lease.closed)
    XCTAssertEqual(provider.calls, 1)
    coordinator.clearRequestFailure()
    XCTAssertNil(coordinator.requestFailure)
    XCTAssertEqual(provider.calls, 1, "Dismissing a failure is never a new request")
  }

  @MainActor func testExplicitSummaryRetryAfterReopenKeepsLanguageAndPriorResultUntilNewSuccess() async throws {
    let f = try fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    try prepareCoordinator(f)
    let authority = try ProviderRequest(), provider = SummaryProvider(), epoch = UUID()
    let first = LibrarySummaryCoordinator(database: f.db, epoch: epoch, leases: SummaryLeases(),
      authority: authority, provider: provider)
    let old = try await first.generate(paperID: f.identity.paperID, generation: f.identity.generation,
      outputLanguage: "ko")
    provider.beforeResult = { _ in throw URLError(.timedOut) }
    let second = LibrarySummaryCoordinator(database: f.db, epoch: epoch, leases: SummaryLeases(),
      authority: authority, provider: provider)
    XCTAssertTrue(second.requestGeneration(paperID: f.identity.paperID, generation: f.identity.generation,
      outputLanguage: "en"))
    for _ in 0..<1000 where second.activePaperID != nil { await Task.yield() }
    XCTAssertEqual(second.requestFailure, .timedOut)

    let reopened = try ProductDatabase.open(at: f.root)
    let failure = try XCTUnwrap(reopened.librarySortFacts().first?.summary?.recentAttempt)
    XCTAssertTrue(failure.canRetry)
    XCTAssertEqual(failure.failure, .timedOut)
    let configuration = try reopened.compareAndSwapProviderConfiguration(expected: reopened.providerConfiguration(),
      replacementKind: .openAIAPIKey, replacementSlotID: UUID(), replacementModel: "updated-fixture-model")
    let retryEpoch = UUID()
    let restored = LibrarySummaryService(database: reopened)
    let retry = LibrarySummaryCoordinator(database: reopened, epoch: retryEpoch, leases: SummaryLeases(),
      authority: authority, provider: provider)
    XCTAssertEqual(try restored.restore(paperID: f.identity.paperID)?.id, old.id)
    XCTAssertEqual(provider.calls, 2)
    provider.suspend = true
    provider.beforeResult = nil
    XCTAssertTrue(retry.requestRetry(failure.identity))
    XCTAssertFalse(retry.requestRetry(failure.identity))
    for _ in 0..<1000 where provider.continuation == nil { await Task.yield() }
    let completion = try XCTUnwrap(provider.continuation)
    defer { provider.continuation?.resume(); provider.continuation = nil }
    XCTAssertEqual(provider.outputLanguages, ["ko", "en", "en"])
    XCTAssertEqual(try restored.restore(paperID: f.identity.paperID)?.id, old.id)
    XCTAssertEqual(try restored.restore(paperID: f.identity.paperID)?.claimAnchors, old.claimAnchors)
    let running = try XCTUnwrap(reopened.librarySortFacts().first?.summary?.recentAttempt)
    XCTAssertEqual(running.activity, .running)
    XCTAssertNotEqual(running.identity.job, failure.identity.job)
    XCTAssertNotEqual(running.identity.attempt, failure.identity.attempt)
    XCTAssertNotEqual(running.identity.fence, failure.identity.fence)
    XCTAssertNotEqual(running.identity.correlation, failure.identity.correlation)
    XCTAssertNotEqual(running.identity.input, failure.identity.input)
    XCTAssertEqual(running.identity.configurationGeneration, configuration.generation)
    XCTAssertEqual(running.identity.epoch, retryEpoch)
    let competingProvider = SummaryProvider()
    let competitor = LibrarySummaryCoordinator(database: f.db, epoch: retryEpoch, leases: SummaryLeases(),
      authority: authority, provider: competingProvider)
    XCTAssertTrue(competitor.requestRetry(failure.identity))
    for _ in 0..<1000 where competitor.activePaperID != nil { await Task.yield() }
    XCTAssertEqual(competitor.requestFailure, .staleIdentity)
    XCTAssertEqual(competingProvider.calls, 0, "Another coordinator cannot send while the accepted retry runs")
    completion.resume(); provider.continuation = nil
    for _ in 0..<1000 where retry.activePaperID != nil { await Task.yield() }
    XCTAssertNil(retry.requestFailure)
    XCTAssertEqual(try restored.restore(paperID: f.identity.paperID)?.identity, running.identity)
    XCTAssertEqual(try reopened.adapterRead { try String.fetchOne($0,
      sql: "SELECT failure FROM librarySummaryJob WHERE job = ? AND state = 'failed'",
      arguments: [failure.identity.job.uuidString]) }, "timedOut")
    XCTAssertTrue(retry.requestRetry(failure.identity))
    for _ in 0..<1000 where retry.activePaperID != nil { await Task.yield() }
    XCTAssertEqual(retry.requestFailure, .staleIdentity)
    XCTAssertEqual(provider.calls, 3, "An old failure cannot dispatch after a newer attempt completes")
  }

  @MainActor func testSummaryRetryRechecksFailureInsideReservationAndRejectsUnknownReasons() async throws {
    let f = try fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    try prepareCoordinator(f)
    let authority = try ProviderRequest(), provider = SummaryProvider(), epoch = UUID()
    provider.beforeResult = { _ in throw URLError(.timedOut) }
    let first = LibrarySummaryCoordinator(database: f.db, epoch: epoch, leases: SummaryLeases(),
      authority: authority, provider: provider)
    XCTAssertTrue(first.requestGeneration(paperID: f.identity.paperID, generation: f.identity.generation,
      outputLanguage: "en"))
    for _ in 0..<1000 where first.activePaperID != nil { await Task.yield() }
    let failed = try XCTUnwrap(f.db.librarySortFacts().first?.summary?.recentAttempt)
    XCTAssertTrue(failed.canRetry)
    let leases = SummaryLeases()
    // Change the durable failure after language lookup and before the reservation write.
    leases.lease.onValidate = {
      try f.db.adapterWrite { db in
        try db.execute(sql: "UPDATE librarySummaryJob SET failure = ? WHERE job = ?",
          arguments: [LibrarySummaryFailure.cleanupUnavailable.rawValue, failed.identity.job.uuidString])
      }
    }
    let retry = LibrarySummaryCoordinator(database: f.db, epoch: epoch, leases: leases,
      authority: authority, provider: provider)
    XCTAssertTrue(retry.requestRetry(failed.identity))
    for _ in 0..<1000 where retry.activePaperID != nil { await Task.yield() }
    XCTAssertEqual(retry.requestFailure, .staleIdentity)
    XCTAssertEqual(provider.calls, 1)
    XCTAssertTrue(leases.lease.closed)
    XCTAssertEqual(try f.db.adapterRead { try Int.fetchOne($0,
      sql: "SELECT COUNT(*) FROM librarySummaryJob") }, 1)
    XCTAssertEqual(try f.db.librarySortFacts().first?.summary?.recentAttempt?.canRetry, false)

    try f.db.adapterWrite { db in
      try db.execute(sql: "UPDATE librarySummaryJob SET failure = 'unknown_reason' WHERE job = ?",
        arguments: [failed.identity.job.uuidString])
    }
    let unknown = try XCTUnwrap(f.db.librarySortFacts().first?.summary?.recentAttempt)
    XCTAssertEqual(unknown.failure, .terminated)
    XCTAssertFalse(unknown.canRetry)
    XCTAssertThrowsError(try f.db.summaryRetryLanguage(for: unknown.identity))
  }

  @MainActor func testActualSummaryFailuresPersistRedactedReasonsAcrossReopenWithoutRetry() async throws {
    let cases: [(any Error, LibrarySummaryFailure)] = [
      (APIKeyConnectionError.authentication, .authentication),
      (APIKeyConnectionError.rateLimited, .rateLimited),
      (URLError(.timedOut), .timedOut),
      (AgentRPCConnection.Failure.timeout, .timedOut),
      (AgentRPCConnection.Failure.remote("unavailable"), .providerUnavailable),
      (AgentRPCConnection.Failure.remote("private-remote-error"), .invalidResponse),
      (LibrarySummaryError.invalidGrounding, .invalidGrounding),
      (LibrarySummaryError.cleanupUnavailable, .cleanupUnavailable),
      (NSError(domain: "secret-provider-body", code: 7,
        userInfo: [NSLocalizedDescriptionKey: "secret-key-paper-text"]), .terminated),
    ]
    for (error, expected) in cases {
      let f = try fixture()
      defer { try? FileManager.default.removeItem(at: f.root) }
      try prepareCoordinator(f)
      let leases = SummaryLeases(), provider = SummaryProvider()
      provider.beforeResult = { _ in throw error }
      let coordinator = LibrarySummaryCoordinator(database: f.db, epoch: UUID(), leases: leases,
        authority: try ProviderRequest(), provider: provider)
      do {
        _ = try await coordinator.generate(paperID: f.identity.paperID,
          generation: f.identity.generation, outputLanguage: "ko")
        XCTFail("Failed provider request must not publish")
      } catch { }
      let stored = try f.db.adapterRead { try String.fetchOne($0,
        sql: "SELECT failure FROM librarySummaryJob") }
      XCTAssertEqual(stored, expected.rawValue)
      let reopened = try ProductDatabase.open(at: f.root)
      let recent = try XCTUnwrap(reopened.librarySortFacts().first?.summary?.recentAttempt)
      XCTAssertEqual(recent.failure, expected)
      XCTAssertEqual(recent.identity.paperID, f.identity.paperID)
      XCTAssertFalse(expected.koreanMessage.contains("secret"))
      XCTAssertEqual(provider.calls, 1, "Reading a failure must never retry generation")
      XCTAssertEqual(leases.lease.closed, expected != .cleanupUnavailable)
    }
  }

  func testSummaryFailureProjectionReadsLegacyAndUnknownCodesWithoutExposingRawText() throws {
    let f = try fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    try reserve(f)
    try f.db.failLibrarySummary(f.identity)
    let codes: [String?] = ["terminated", nil, "private-unknown-provider-error", "interrupted", "paperUnavailable"]
    for code in codes {
      try f.db.adapterWrite { db in
        try db.execute(sql: "UPDATE librarySummaryJob SET failure = ?", arguments: [code])
      }
      let recent = try XCTUnwrap(f.db.librarySortFacts().first?.summary?.recentAttempt)
      XCTAssertEqual(recent.failure, code.flatMap(LibrarySummaryFailure.init(rawValue:)) ?? .terminated)
      XCTAssertFalse(recent.failure!.koreanMessage.contains("private"))
    }
  }

  @MainActor func testCoordinatorPreservesUnownedStageAndRejectsPublicationAfterConfigurationChange() async throws {
    for createUnownedStage in [false, true] {
      let f = try fixture()
      defer { try? FileManager.default.removeItem(at: f.root) }
      try prepareCoordinator(f)
      let leases = SummaryLeases(), provider = SummaryProvider()
      var sentinel: URL?
      provider.beforeResult = { identity in
        if createUnownedStage {
          let directory = f.db.root.appendingPathComponent("papers/\(identity.paperID.uuidString)/.summary-\(identity.job.uuidString)")
          try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
          sentinel = directory.appendingPathComponent("unowned")
          try Data("preserve".utf8).write(to: sentinel!)
        } else {
          _ = try f.db.compareAndSwapProviderConfiguration(expected: f.db.providerConfiguration(),
            replacementKind: .openAIAPIKey, replacementSlotID: UUID(), replacementModel: "changed-model")
        }
      }
      let coordinator = LibrarySummaryCoordinator(database: f.db, epoch: UUID(), leases: leases,
        authority: try ProviderRequest(), provider: provider)
      do {
        _ = try await coordinator.generate(paperID: f.identity.paperID,
          generation: f.identity.generation, outputLanguage: "ko")
        XCTFail("Unowned stage/configuration replacement must reject publication")
      } catch { }
      if let sentinel { XCTAssertEqual(try Data(contentsOf: sentinel), Data("preserve".utf8)) }
      XCTAssertTrue(leases.lease.closed)
      XCTAssertNil(try LibrarySummaryService(database: f.db).restore(paperID: f.identity.paperID))
    }
  }

  @MainActor func testDurableSelectorRoutesChatGPTWithoutAPIKeyAdapter() async throws {
    for kind in [ProviderKind.codexChatGPT, .openAIAPIKey] {
      let f = try fixture()
      defer { try? FileManager.default.removeItem(at: f.root) }
      try prepareCoordinator(f)
      _ = try f.db.compareAndSwapProviderConfiguration(expected: f.db.providerConfiguration(),
        replacementKind: kind, replacementSlotID: UUID(), replacementModel: "fixture-model")
      let apiKey = SummaryProvider(), chatGPT = SummaryProvider()
      let selected = SelectedLibrarySummaryProvider(database: f.db, apiKey: apiKey, chatGPT: chatGPT)
      let leases = SummaryLeases()
      let coordinator = LibrarySummaryCoordinator(database: f.db, epoch: UUID(), leases: leases,
        authority: try ProviderRequest(), provider: selected)
      let saved = try await coordinator.generate(paperID: f.identity.paperID,
        generation: f.identity.generation, outputLanguage: "ko")
      XCTAssertEqual(apiKey.calls, kind == .openAIAPIKey ? 1 : 0)
      XCTAssertEqual(chatGPT.calls, kind == .codexChatGPT ? 1 : 0)
      XCTAssertEqual(saved.claimAnchors.count, 1)
      XCTAssertTrue(leases.lease.closed)
    }
  }

  @MainActor func testUnknownProducerRetirementRetainsPaperLeaseAndBlocksReplacement() async throws {
    let f = try fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    try prepareCoordinator(f)
    let provider = SummaryProvider(), leases = SummaryLeases()
    provider.beforeResult = { _ in throw LibrarySummaryError.cleanupUnavailable }
    let coordinator = LibrarySummaryCoordinator(database: f.db, epoch: UUID(), leases: leases,
      authority: try ProviderRequest(), provider: provider)
    do {
      _ = try await coordinator.generate(paperID: f.identity.paperID,
        generation: f.identity.generation, outputLanguage: "ko")
      XCTFail("Unknown physical retirement must not publish")
    } catch { XCTAssertEqual(error as? LibrarySummaryError, .cleanupUnavailable) }
    XCTAssertFalse(leases.lease.closed)
    do {
      _ = try await coordinator.generate(paperID: f.identity.paperID,
        generation: f.identity.generation, outputLanguage: "ko")
      XCTFail("Unknown producer ownership must block replacement")
    } catch { XCTAssertEqual(error as? LibrarySummaryError, .requestInProgress) }
    XCTAssertEqual(provider.calls, 1)
    XCTAssertNil(try LibrarySummaryService(database: f.db).restore(paperID: f.identity.paperID))
  }

  @MainActor func testMissingChatGPTConnectionDoesNotFallBackToAPIKey() async throws {
    let f = try fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    try prepareCoordinator(f)
    _ = try f.db.compareAndSwapProviderConfiguration(expected: f.db.providerConfiguration(),
      replacementKind: .codexChatGPT, replacementSlotID: UUID(), replacementModel: "fixture-model")
    let authority = try ProviderRequest(), apiKey = SummaryProvider(), leases = SummaryLeases()
    let selected = SelectedLibrarySummaryProvider(database: f.db, apiKey: apiKey,
      chatGPT: NativeCodexSummaryProvider(connection: nil, authority: authority))
    let coordinator = LibrarySummaryCoordinator(database: f.db, epoch: UUID(), leases: leases,
      authority: authority, provider: selected)
    do {
      _ = try await coordinator.generate(paperID: f.identity.paperID,
        generation: f.identity.generation, outputLanguage: "ko")
      XCTFail("An unavailable selected provider must not publish")
    } catch { XCTAssertEqual(error as? LibrarySummaryError, .providerUnavailable) }
    XCTAssertEqual(apiKey.calls, 0)
    XCTAssertTrue(leases.lease.closed)
    XCTAssertNil(try LibrarySummaryService(database: f.db).restore(paperID: f.identity.paperID))
  }

  @MainActor func testSummaryStageRejectsReplacedFileBeforeRenameOrUnlink() throws {
    let f = try fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    try prepareCoordinator(f)
    let job = UUID()
    let paper = try f.db.readerSnapshot(paperID: f.identity.paperID)
    let stage = SummaryStage(root: f.db.root, paper: paper, job: job)
    try stage.prepare()
    try stage.write(Data("owned result".utf8))
    let directory = f.db.root.appendingPathComponent("papers/\(paper.paperID.uuidString)/.summary-\(job.uuidString)")
    let original = directory.appendingPathComponent("result.tmp")
    let displaced = directory.appendingPathComponent("displaced")
    try FileManager.default.moveItem(at: original, to: displaced)
    try Data("unowned replacement".utf8).write(to: original)
    XCTAssertThrowsError(try stage.rename())
    XCTAssertThrowsError(try stage.remove())
    XCTAssertEqual(try Data(contentsOf: original), Data("unowned replacement".utf8))
    XCTAssertEqual(try Data(contentsOf: displaced), Data("owned result".utf8))
    // Restore exact synthetic ownership so this test can close its actual directory FDs.
    try FileManager.default.removeItem(at: original)
    try FileManager.default.moveItem(at: displaced, to: original)
    let occupiedTarget = directory.appendingPathComponent("result.json")
    try Data("preserve target".utf8).write(to: occupiedTarget)
    XCTAssertThrowsError(try stage.rename())
    XCTAssertEqual(try Data(contentsOf: occupiedTarget), Data("preserve target".utf8))
    try FileManager.default.removeItem(at: occupiedTarget)
    try stage.remove()
    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
  }
}
