import Foundation
import GRDB
import XCTest
import ProviderRequest
@testable import PaperLensProduct

final class LibrarySummaryServiceTests: XCTestCase {
  // Controlled storage fixture only. This decoder validates a known test encoding;
  // it is not PDFium calibration, certified live enforcement or closure acceptance.
  private struct FixtureGeometry: LibrarySummaryGeometryValidating {
    func resolve(_ hit: ExtractionSearchHit, identity: PDFSentenceIdentity) throws -> PDFSentenceAnchor {
      guard hit.canonicalGeometry == Data("fixture-quad".utf8) else {
        throw LibrarySummaryError.invalidGrounding
      }
      let page = try PDFPageGeometry(pageIndex: identity.pageIndex,
        cropOrigin: .init(x: 0, y: 0), width: 100, height: 100, rotation: 0)
      let quad = try PDFQuad(topLeft: .init(x: 10, y: 20), topRight: .init(x: 20, y: 20),
        bottomRight: .init(x: 20, y: 10), bottomLeft: .init(x: 10, y: 10), page: page)
      return try PDFSentenceAnchor(identity: identity, fullSourceQuote: hit.text,
        page: page, quads: [quad])
    }
  }
  private struct Fixture {
    let db: ProductDatabase
    let root: URL
    let identity: LibrarySummaryIdentity
    let request: AuthorizedProviderRequest
    let frozen: LibrarySummaryFrozen
    let result: ValidatedProviderResult
  }

  private func fixture(tail: String? = nil, rankTail: Bool = false) throws -> Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    // Parent must register registerLibrarySummaryMigrations in ProductDatabase.open first.
    let db = try ProductDatabase.open(at: root)
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
          """, arguments: [revision.uuidString, id, quote, Data("fixture-quad".utf8)])
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
    return Fixture(db: db, root: root, identity: identity, request: request,
      frozen: try LibrarySummaryFrozen(request: request), result: result)
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
      replacementSlotID: nil, replacementModel: "new configuration")
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
      replacementSlotID: nil, replacementModel: "new configuration")
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
    try f.db.reserveLibrarySummary(f.identity, frozen: f.frozen, geometry: FixtureGeometry())
  }
  private func publish(_ f: Fixture) throws -> LibrarySummaryRecord {
    try f.db.publishLibrarySummary(f.identity, frozen: f.frozen, result: f.result,
      bytes: ProviderRequest.canonicalBytes(f.result.value), permit: UUID().uuidString,
      resultID: UUID(), geometry: FixtureGeometry())
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
        geometry: FixtureGeometry())) {
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
        permit: UUID().uuidString, resultID: UUID(), geometry: FixtureGeometry())) {
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
      let service = LibrarySummaryService(database: f.db, geometry: FixtureGeometry())
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
      XCTAssertEqual($0 as? LibrarySummaryError, .invalidGrounding)
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
      geometry: FixtureGeometry()).restore(paperID: f.identity.paperID))
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
    let service = LibrarySummaryService(database: f.db, geometry: FixtureGeometry())
    try f.db.adapterWrite { sql in
      try sql.execute(sql: "UPDATE extractionSentence SET text = 'unrelated' WHERE revision = ? AND sentenceID = 1",
        arguments: [f.identity.revision.uuidString])
    }
    XCTAssertThrowsError(try service.restore(paperID: f.identity.paperID))
    try f.db.adapterWrite { sql in
      try sql.execute(sql: "UPDATE extractionSentence SET text = 'results conclusion beta', geometry = ? WHERE revision = ? AND sentenceID = 1",
        arguments: [Data([0]), f.identity.revision.uuidString])
    }
    XCTAssertThrowsError(try service.restore(paperID: f.identity.paperID))
    try f.db.adapterWrite { sql in
      try sql.execute(sql: "DELETE FROM extractionSentence WHERE revision = ? AND sentenceID = 1",
        arguments: [f.identity.revision.uuidString])
    }
    XCTAssertThrowsError(try service.restore(paperID: f.identity.paperID))
  }

  func testGuardedCommitRejectsConfigurationChangeWithoutPartialResult() throws {
    let f = try fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    try reserve(f)
    _ = try f.db.compareAndSwapProviderConfiguration(expected: f.db.providerConfiguration(),
      replacementSlotID: nil, replacementModel: "changed")
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
      replacementSlotID: nil, replacementModel: "changed")
    try f.db.failLibrarySummary(f.identity)
    let restored = try XCTUnwrap(LibrarySummaryService(database: f.db,
      geometry: FixtureGeometry()).restore(paperID: f.identity.paperID))
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
      geometry: FixtureGeometry()).restore(paperID: f.identity.paperID))
  }

  func testFrozenContextRoundTripAndInvalidSummaryAreValidatedLocally() throws {
    let f = try fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let restored = try JSONDecoder().decode(LibrarySummaryFrozen.self,
      from: JSONEncoder().encode(f.frozen))
    let authority = try ProviderRequest()
    XCTAssertEqual(try authority.encodeRequest(restored.authorized(using: authority)), f.frozen.request)
    XCTAssertEqual(try restored.validate(result: ProviderRequest.canonicalBytes(f.result.value)), f.result)
    for text in ["   ", "line one\nline two"] {
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

  func testMissingGeometryDeniesRestoreRatherThanDisplayingUngroundedData() throws {
    let f = try fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    XCTAssertThrowsError(try LibrarySummaryService(database: f.db).restore(paperID: f.identity.paperID)) {
      XCTAssertEqual($0 as? LibrarySummaryError, .geometryUnavailable)
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
      _ = try await LibrarySummaryService(database: f.db, geometry: FixtureGeometry())
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
    XCTAssertThrowsError(try reserve(f))
    XCTAssertEqual(try f.db.adapterRead { try Int.fetchOne($0,
      sql: "SELECT COUNT(*) FROM librarySummaryJob") }, 0)
  }
}
