import Foundation
import GRDB
#if SWIFT_PACKAGE
import ProviderRequest
#endif

extension ProductDatabase {
  /// Parent registers on the existing migrator before opening the sole ProductDatabase queue.
  public static func registerLibrarySummaryMigrations(in migrator: inout DatabaseMigrator) {
    migrator.registerMigration("groundedLibrarySummaryV1") { db in
      try db.execute(sql: """
        CREATE TABLE librarySummaryJob (
          job TEXT PRIMARY KEY NOT NULL,
          paperID TEXT NOT NULL REFERENCES paper(id) ON DELETE CASCADE,
          attempt TEXT NOT NULL UNIQUE, fence TEXT NOT NULL UNIQUE,
          correlation TEXT NOT NULL UNIQUE, input TEXT NOT NULL UNIQUE, epoch TEXT NOT NULL,
          identity BLOB NOT NULL, frozen BLOB NOT NULL,
          state TEXT NOT NULL CHECK(state IN ('running', 'failed', 'succeeded')),
          failure TEXT, resultID TEXT, permit TEXT
        );
        CREATE UNIQUE INDEX librarySummaryActive ON librarySummaryJob(paperID) WHERE state = 'running';
        CREATE TABLE librarySummaryResult (
          id TEXT PRIMARY KEY NOT NULL,
          paperID TEXT NOT NULL REFERENCES paper(id) ON DELETE CASCADE,
          revision TEXT NOT NULL REFERENCES extractionRevision(id),
          job TEXT NOT NULL UNIQUE REFERENCES librarySummaryJob(job),
          identity BLOB NOT NULL, frozen BLOB NOT NULL, result BLOB NOT NULL
        );
        CREATE TABLE librarySummaryVisible (
          paperID TEXT PRIMARY KEY NOT NULL REFERENCES paper(id) ON DELETE CASCADE,
          resultID TEXT NOT NULL REFERENCES librarySummaryResult(id)
        );
        CREATE TRIGGER librarySummaryDeleting AFTER UPDATE OF status, generation ON paper
        WHEN NEW.status != 'ready' OR NEW.generation != OLD.generation
        BEGIN
          UPDATE librarySummaryJob SET state = 'failed', failure = 'paperUnavailable'
            WHERE paperID = NEW.id AND state = 'running';
          DELETE FROM librarySummaryVisible WHERE paperID = NEW.id;
        END;
        CREATE TRIGGER librarySummaryTombstone AFTER UPDATE OF status ON paper
        WHEN NEW.status = 'tombstone'
        BEGIN
          DELETE FROM librarySummaryVisible WHERE paperID = NEW.id;
          DELETE FROM librarySummaryResult WHERE paperID = NEW.id;
          DELETE FROM librarySummaryJob WHERE paperID = NEW.id;
        END;
        """)
    }
  }

  private func guardSummaryPaper(_ i: LibrarySummaryIdentity, db: Database,
    currentInput: Bool) throws {
    guard try Int.fetchOne(db, sql: """
      SELECT COUNT(*) FROM paper JOIN extractionRevision ON extractionRevision.paperID = paper.id
      WHERE paper.id = ? AND paper.generation = ? AND paper.pdfSHA256 = ?
        AND paper.status = 'ready' AND paper.deletionID IS NULL AND paper.pdfReference = ?
        AND extractionRevision.id = ? AND extractionRevision.generation = paper.generation
        AND extractionRevision.pdfSHA256 = paper.pdfSHA256
        AND extractionRevision.pdfReference = paper.pdfReference
      """, arguments: [i.paperID.uuidString, i.generation.uuidString, i.pdfSHA256,
        "papers/\(i.paperID.uuidString)/document.pdf", i.revision.uuidString]) == 1
    else { throw LibrarySummaryError.staleIdentity }
    if currentInput {
      guard try Int.fetchOne(db, sql: """
        SELECT COUNT(*) FROM extractionVisible, providerConfig
        WHERE extractionVisible.paperID = ? AND extractionVisible.revision = ?
          AND providerConfig.singleton = 1 AND providerConfig.generation = ?
        """, arguments: [i.paperID.uuidString, i.revision.uuidString, i.configurationGeneration]) == 1
      else { throw LibrarySummaryError.staleIdentity }
    }
  }

  /// Ground the entire frozen corpus before selecting bundle anchors inside the SQL snapshot.
  private func summaryAnchors(_ i: LibrarySummaryIdentity, frozen: LibrarySummaryFrozen,
    db: Database, geometry: any LibrarySummaryGeometryValidating) throws
    -> (RequestEvidenceBundle, [PDFSentenceAnchor]) {
    let authorized = try frozen.authorized()
    guard case .librarySummary(_, let bundle) = authorized.wire.typedInput,
      bundle.identity.paperID == i.paperID.uuidString.lowercased(),
      bundle.identity.paperGeneration == i.requestPaperGeneration,
      bundle.identity.pdfSHA256 == i.pdfSHA256,
      bundle.identity.extractionRevision == i.revision.uuidString.lowercased(),
      authorized.wire.requestID == i.correlation.uuidString.lowercased()
    else { throw LibrarySummaryError.invalidGrounding }
    var verified: [PDFSentenceAnchor] = []
    for sentence in frozen.sentences {
      guard let row = try Row.fetchOne(db, sql: """
        SELECT text, geometry FROM extractionSentence WHERE revision = ? AND page = ? AND sentenceID = ?
        """, arguments: [i.revision.uuidString, sentence.page, sentence.id])
      else { throw LibrarySummaryError.invalidGrounding }
      let text: String = row["text"]
      let data: Data = row["geometry"]
      guard text.utf8.elementsEqual(sentence.quote.utf8) else { throw LibrarySummaryError.invalidGrounding }
      let key = try PDFSentenceIdentity(paperID: i.paperID, pdfSHA256: i.pdfSHA256,
        extractionRevision: i.revision.uuidString.lowercased(), pageIndex: sentence.page,
        sentenceID: sentence.id)
      let hit = ExtractionSearchHit(revision: i.revision, page: sentence.page,
        sentenceID: sentence.id, text: text, canonicalGeometry: data)
      let anchor = try geometry.resolve(hit, identity: key)
      try anchor.validateResolution(expected: key, publishedMembership: [key])
      guard anchor.fullSourceQuote.utf8.elementsEqual(text.utf8) else {
        throw LibrarySummaryError.invalidGrounding
      }
      verified.append(anchor)
    }
    // TrustedRequestContext enforces sentenceID == corpus index. Never rerank on restore.
    let anchors = try bundle.items.map { item in
      guard verified.indices.contains(item.anchor.sentenceID) else {
        throw LibrarySummaryError.invalidGrounding
      }
      let anchor = verified[item.anchor.sentenceID]
      guard anchor.identity.pageIndex == item.anchor.pageIndex,
        anchor.fullSourceQuote.utf8.elementsEqual(item.quote.utf8) else {
        throw LibrarySummaryError.invalidGrounding
      }
      return anchor
    }
    return (bundle, anchors)
  }

  func reserveLibrarySummary(_ i: LibrarySummaryIdentity, frozen: LibrarySummaryFrozen,
    geometry: any LibrarySummaryGeometryValidating) throws {
    let identity = try JSONEncoder().encode(i)
    let saved = try JSONEncoder().encode(frozen)
    try adapterWrite { db in
      try guardSummaryPaper(i, db: db, currentInput: true)
      _ = try summaryAnchors(i, frozen: frozen, db: db, geometry: geometry)
      // Never replace an invocation or clear previous usable data to make another send fit.
      try db.execute(sql: """
        INSERT INTO librarySummaryJob(job, paperID, attempt, fence, correlation, input, epoch,
          identity, frozen, state) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'running')
        """, arguments: [i.job.uuidString, i.paperID.uuidString, i.attempt.uuidString,
          i.fence.uuidString, i.correlation.uuidString, i.input.uuidString, i.epoch.uuidString,
          identity, saved])
    }
  }

  func publishLibrarySummary(_ i: LibrarySummaryIdentity, frozen: LibrarySummaryFrozen,
    result: ValidatedProviderResult, bytes: Data, permit: String, resultID: UUID,
    geometry: any LibrarySummaryGeometryValidating) throws -> LibrarySummaryRecord {
    try adapterWrite { db in
      try guardSummaryPaper(i, db: db, currentInput: true)
      guard let job = try Row.fetchOne(db, sql: """
        SELECT identity, frozen FROM librarySummaryJob WHERE job = ? AND state = 'running'
          AND attempt = ? AND fence = ? AND correlation = ? AND input = ? AND epoch = ?
        """, arguments: [i.job.uuidString, i.attempt.uuidString, i.fence.uuidString,
          i.correlation.uuidString, i.input.uuidString, i.epoch.uuidString]),
        try JSONDecoder().decode(LibrarySummaryIdentity.self, from: job["identity"]) == i,
        try JSONDecoder().decode(LibrarySummaryFrozen.self, from: job["frozen"]) == frozen
      else { throw LibrarySummaryError.staleIdentity }
      let validated = try frozen.validate(result: bytes)
      guard validated == result else { throw LibrarySummaryError.invalidResult }
      let (bundle, anchors) = try summaryAnchors(i, frozen: frozen, db: db, geometry: geometry)
      let claim = try summaryClaimAnchors(validated, anchors: anchors)
      let identityData: Data = job["identity"]
      let frozenData: Data = job["frozen"]
      try db.execute(sql: """
        INSERT INTO librarySummaryResult(id, paperID, revision, job, identity, frozen, result)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        """, arguments: [resultID.uuidString, i.paperID.uuidString, i.revision.uuidString,
          i.job.uuidString, identityData, frozenData, bytes])
      try db.execute(sql: """
        UPDATE librarySummaryJob SET state = 'succeeded', resultID = ?, permit = ? WHERE job = ?;
        """, arguments: [resultID.uuidString, permit, i.job.uuidString])
      try db.execute(sql: """
        INSERT INTO librarySummaryVisible(paperID, resultID) VALUES (?, ?)
        ON CONFLICT(paperID) DO UPDATE SET resultID = excluded.resultID
        """, arguments: [i.paperID.uuidString, resultID.uuidString])
      return LibrarySummaryRecord(id: resultID, identity: i, result: validated,
        evidence: bundle, claimAnchors: claim)
    }
  }

  private func summaryClaimAnchors(_ result: ValidatedProviderResult,
    anchors: [PDFSentenceAnchor]) throws -> [PDFSentenceAnchor] {
    guard case .librarySummary(let summary, _) = result.result else {
      throw LibrarySummaryError.invalidResult
    }
    guard summary.evidenceIndices.allSatisfy({ anchors.indices.contains($0) }),
      summary.kind != "paper" || !summary.evidenceIndices.isEmpty
    else { throw LibrarySummaryError.invalidGrounding }
    return summary.evidenceIndices.map { anchors[$0] }
  }

  func restoreLibrarySummary(paperID: UUID, geometry: any LibrarySummaryGeometryValidating) throws
    -> LibrarySummaryRecord? {
    try adapterRead { db in
      guard let row = try Row.fetchOne(db, sql: """
        SELECT r.*, j.identity AS jobIdentity, j.frozen AS jobFrozen, j.permit AS publicationPermit
        FROM librarySummaryVisible v JOIN librarySummaryResult r ON r.id = v.resultID
        JOIN librarySummaryJob j ON j.job = r.job AND j.state = 'succeeded' AND j.resultID = r.id
        WHERE v.paperID = ? AND r.paperID = v.paperID AND j.paperID = r.paperID
        """, arguments: [paperID.uuidString]) else { return nil }
      let identity = try JSONDecoder().decode(LibrarySummaryIdentity.self, from: row["identity"])
      let frozen = try JSONDecoder().decode(LibrarySummaryFrozen.self, from: row["frozen"])
      let id: String = row["id"]
      let revision: String = row["revision"]
      let job: String = row["job"]
      let permit: String? = row["publicationPermit"]
      guard identity.paperID == paperID, revision == identity.revision.uuidString,
        job == identity.job.uuidString, let resultID = UUID(uuidString: id),
        let permit, !permit.isEmpty,
        try JSONDecoder().decode(LibrarySummaryIdentity.self, from: row["jobIdentity"]) == identity,
        try JSONDecoder().decode(LibrarySummaryFrozen.self, from: row["jobFrozen"]) == frozen
      else { throw LibrarySummaryError.staleIdentity }
      // Prior config/revision may differ from current input, but never relabel the saved identity.
      try guardSummaryPaper(identity, db: db, currentInput: false)
      let result = try frozen.validate(result: row["result"])
      let (bundle, anchors) = try summaryAnchors(identity, frozen: frozen, db: db, geometry: geometry)
      return LibrarySummaryRecord(id: resultID, identity: identity, result: result,
        evidence: bundle, claimAnchors: try summaryClaimAnchors(result, anchors: anchors))
    }
  }

  /// Parent calls only after its policy termination; this does not attest physical closure/purge.
  public func failLibrarySummary(_ identity: LibrarySummaryIdentity) throws {
    try adapterWrite { db in
      guard let data = try Data.fetchOne(db, sql: "SELECT identity FROM librarySummaryJob WHERE job = ?",
        arguments: [identity.job.uuidString]),
        try JSONDecoder().decode(LibrarySummaryIdentity.self, from: data) == identity else {
        throw LibrarySummaryError.staleIdentity
      }
      try db.execute(sql: "UPDATE librarySummaryJob SET state = 'failed', failure = 'terminated' WHERE job = ? AND state = 'running'",
        arguments: [identity.job.uuidString])
    }
  }

}
