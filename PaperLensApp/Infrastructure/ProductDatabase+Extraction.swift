import Foundation
import GRDB
#if SWIFT_PACKAGE
import ProviderRequest
#endif

extension ProductDatabase {
  public static func registerExtractionMigrations(in migrator: inout DatabaseMigrator) {
    migrator.registerMigration("extractionRevisionV1") { db in
      try db.execute(sql: """
        CREATE TABLE extractionInvocation (
          attempt TEXT PRIMARY KEY, fence TEXT NOT NULL UNIQUE, revision TEXT NOT NULL UNIQUE,
          paperID TEXT NOT NULL REFERENCES paper(id) ON DELETE CASCADE
        );
        CREATE TABLE extractionAttempt (
          paperID TEXT PRIMARY KEY REFERENCES paper(id) ON DELETE CASCADE,
          generation TEXT NOT NULL, pdfSHA256 TEXT NOT NULL, pdfReference TEXT NOT NULL,
          revision TEXT NOT NULL UNIQUE, job TEXT NOT NULL, attempt TEXT NOT NULL,
          fence TEXT NOT NULL, correlation TEXT NOT NULL, input TEXT NOT NULL, epoch TEXT NOT NULL,
          configSlot TEXT, configGeneration INTEGER NOT NULL, state TEXT NOT NULL, failure TEXT
        );
        CREATE TABLE extractionRevision (
          id TEXT PRIMARY KEY, paperID TEXT NOT NULL REFERENCES paper(id) ON DELETE CASCADE,
          generation TEXT NOT NULL, pdfSHA256 TEXT NOT NULL, pdfReference TEXT NOT NULL
        );
        CREATE TABLE extractionVisible (
          paperID TEXT PRIMARY KEY REFERENCES paper(id) ON DELETE CASCADE,
          revision TEXT NOT NULL REFERENCES extractionRevision(id) ON DELETE CASCADE
        );
        CREATE TABLE extractionSentence (
          id INTEGER PRIMARY KEY, revision TEXT NOT NULL REFERENCES extractionRevision(id) ON DELETE CASCADE,
          page INTEGER NOT NULL, sentenceID INTEGER NOT NULL, text TEXT NOT NULL,
          geometry BLOB NOT NULL, UNIQUE(revision, sentenceID)
        );
        CREATE VIRTUAL TABLE extractionFTS USING fts5(text);
        CREATE TRIGGER extractionSentenceInsert AFTER INSERT ON extractionSentence BEGIN
          INSERT INTO extractionFTS(rowid, text) VALUES (new.id, new.text);
        END;
        CREATE TRIGGER extractionSentenceDelete AFTER DELETE ON extractionSentence BEGIN
          DELETE FROM extractionFTS WHERE rowid = old.id;
        END;
        CREATE TRIGGER extractionTombstone AFTER UPDATE OF status ON paper
        WHEN new.status = 'tombstone' BEGIN
          DELETE FROM extractionVisible WHERE paperID = new.id;
          DELETE FROM extractionRevision WHERE paperID = new.id;
          DELETE FROM extractionAttempt WHERE paperID = new.id;
          DELETE FROM extractionInvocation WHERE paperID = new.id;
        END;
        """)
    }
  }

  private func guardExtractionPaper(_ db: Database, _ identity: ExtractionIdentity) throws {
    let count = try Int.fetchOne(db, sql: """
      SELECT COUNT(*) FROM paper, providerConfig
      WHERE paper.id = ? AND paper.generation = ? AND paper.pdfSHA256 = ?
        AND paper.pdfReference = ? AND paper.status = 'ready' AND paper.deletionID IS NULL
        AND providerConfig.singleton = 1 AND providerConfig.generation = ? AND providerConfig.slotID IS ?
        AND providerConfig.model IS ? AND providerConfig.kind IS ?
      """, arguments: [identity.paperID.uuidString, identity.generation.uuidString,
        identity.pdfSHA256, identity.pdfReference, identity.configuration.generation,
        identity.configuration.slotID?.uuidString, identity.configuration.model,
        identity.configuration.kind?.rawValue])
    guard count == 1 else { throw ExtractionError.staleAttempt }
  }

  private func guardExtractionAttempt(_ db: Database, _ identity: ExtractionIdentity,
    requireCurrentPaper: Bool = true) throws {
    if requireCurrentPaper { try guardExtractionPaper(db, identity) }
    let count = try Int.fetchOne(db, sql: """
      SELECT COUNT(*) FROM extractionAttempt WHERE paperID = ? AND generation = ?
        AND pdfSHA256 = ? AND pdfReference = ? AND revision = ? AND job = ? AND attempt = ?
        AND fence = ? AND correlation = ? AND input = ? AND epoch = ?
        AND configSlot IS ? AND configGeneration = ? AND configKind IS ? AND state = 'running'
      """, arguments: attemptArguments(identity))
    guard count == 1 else { throw ExtractionError.staleAttempt }
  }

  private func attemptArguments(_ i: ExtractionIdentity) -> StatementArguments {
    [i.paperID.uuidString, i.generation.uuidString, i.pdfSHA256, i.pdfReference,
      i.revision.uuidString, i.job.uuidString, i.attempt.uuidString, i.fence.uuidString,
      i.correlation.uuidString, i.input.uuidString, i.epoch.uuidString,
      i.configuration.slotID?.uuidString, i.configuration.generation,
      i.configuration.kind?.rawValue]
  }

  /// Admission facts from one read snapshot; never claims or moves a Reader session.
  func extractionReadSnapshot(_ identity: ExtractionIdentity) throws -> ReaderPaperSnapshot {
    try adapterRead { db in
      try guardExtractionAttempt(db, identity)
      guard let row = try Row.fetchOne(db, sql: """
        SELECT generation, pdfReference, title FROM paper
        WHERE id = ? AND status = 'ready' AND deletionID IS NULL
        """, arguments: [identity.paperID.uuidString]),
        let generation = UUID(uuidString: row["generation"]),
        let reference: String = row["pdfReference"],
        reference.utf8.elementsEqual("papers/\(identity.paperID.uuidString)/document.pdf".utf8),
        generation == identity.generation,
        reference.utf8.elementsEqual(identity.pdfReference.utf8) else {
        throw ExtractionError.staleAttempt
      }
      return ReaderPaperSnapshot(paperID: identity.paperID, generation: generation,
        pdfReference: reference, title: row["title"])
    }
  }

  func reserveExtraction(_ identity: ExtractionIdentity) throws {
    try adapterWrite { db in
      try guardExtractionPaper(db, identity)
      guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM extractionRevision WHERE id = ?",
        arguments: [identity.revision.uuidString]) == 0 else { throw ExtractionError.staleAttempt }
      guard try Int.fetchOne(db, sql: """
        SELECT COUNT(*) FROM extractionInvocation WHERE attempt = ? OR fence = ? OR revision = ?
        """, arguments: [identity.attempt.uuidString, identity.fence.uuidString,
          identity.revision.uuidString]) == 0 else { throw ExtractionError.staleAttempt }
      // Reservations are immutable: an old invocation cannot renew or overwrite its fence.
      guard try Int.fetchOne(db, sql: """
        SELECT COUNT(*) FROM extractionAttempt WHERE paperID = ?
          AND (state = 'running' OR attempt = ? OR revision = ?)
        """, arguments: [identity.paperID.uuidString, identity.attempt.uuidString,
          identity.revision.uuidString]) == 0 else { throw ExtractionError.staleAttempt }
      try db.execute(sql: "INSERT INTO extractionInvocation(attempt, fence, revision, paperID) VALUES (?, ?, ?, ?)",
        arguments: [identity.attempt.uuidString, identity.fence.uuidString,
          identity.revision.uuidString, identity.paperID.uuidString])
      try db.execute(sql: "DELETE FROM extractionAttempt WHERE paperID = ?",
        arguments: [identity.paperID.uuidString])
      try db.execute(sql: """
        INSERT INTO extractionAttempt(paperID, generation, pdfSHA256, pdfReference, revision,
          job, attempt, fence, correlation, input, epoch, configSlot, configGeneration, configKind, state)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'running')
        """, arguments: attemptArguments(identity))
    }
  }

  func publishExtraction(_ identity: ExtractionIdentity, sentences: [ValidatedExtractionSentence],
    checkBudget: @Sendable () throws -> Void) throws {
    guard !sentences.isEmpty else { throw ExtractionError.invalidBatch }
    try adapterWrite { db in
      try checkBudget()
      try guardExtractionAttempt(db, identity)
      try db.execute(sql: """
        INSERT INTO extractionRevision(id, paperID, generation, pdfSHA256, pdfReference)
        VALUES (?, ?, ?, ?, ?)
        """, arguments: [identity.revision.uuidString, identity.paperID.uuidString,
          identity.generation.uuidString, identity.pdfSHA256, identity.pdfReference])
      for sentence in sentences {
        try checkBudget()
        try db.execute(sql: """
          INSERT INTO extractionSentence(revision, page, sentenceID, text, geometry) VALUES (?, ?, ?, ?, ?)
          """, arguments: [identity.revision.uuidString, sentence.page, sentence.sentenceID,
            sentence.text, sentence.geometry])
      }
      try checkBudget()
      try guardExtractionAttempt(db, identity)
      try db.execute(sql: """
        INSERT INTO extractionVisible(paperID, revision) VALUES (?, ?)
        ON CONFLICT(paperID) DO UPDATE SET revision = excluded.revision
        """, arguments: [identity.paperID.uuidString, identity.revision.uuidString])
      try db.execute(sql: "UPDATE extractionAttempt SET state = 'succeeded', failure = NULL WHERE paperID = ?",
        arguments: [identity.paperID.uuidString])
      try checkBudget()
    }
  }

  func failExtraction(_ identity: ExtractionIdentity, failure: ExtractionError) throws {
    try adapterWrite { db in
      // A stale callback must neither fail a newer attempt nor erase prior usable content.
      guard try Int.fetchOne(db, sql: """
        SELECT COUNT(*) FROM paper WHERE id = ? AND status = 'ready' AND deletionID IS NULL
        """, arguments: [identity.paperID.uuidString]) == 1 else { return }
      do { try guardExtractionAttempt(db, identity, requireCurrentPaper: false) }
      catch ExtractionError.staleAttempt { return }
      try db.execute(sql: "UPDATE extractionAttempt SET state = 'failed', failure = ? WHERE paperID = ?",
        arguments: [failure.rawValue, identity.paperID.uuidString])
    }
  }

  public func extractionStatus(paperID: UUID) throws -> ExtractionStatus {
    try adapterRead { db in
      try Self.fetchExtractionStatus(paperID: paperID, in: db)
    }
  }

  static func fetchExtractionStatus(paperID: UUID, in db: Database) throws -> ExtractionStatus {
    guard let row = try Row.fetchOne(db, sql: """
        SELECT paper.status AS paperStatus, extractionAttempt.state, extractionAttempt.failure,
          extractionRevision.id AS revision FROM paper
        LEFT JOIN extractionAttempt ON extractionAttempt.paperID = paper.id
        LEFT JOIN extractionVisible ON extractionVisible.paperID = paper.id
        LEFT JOIN extractionRevision ON extractionRevision.id = extractionVisible.revision
          AND extractionRevision.paperID = paper.id AND extractionRevision.generation = paper.generation
          AND extractionRevision.pdfSHA256 = paper.pdfSHA256
          AND extractionRevision.pdfReference = paper.pdfReference
        WHERE paper.id = ?
        """, arguments: [paperID.uuidString]) else { throw ProductDatabaseError.invalidRecord }
    let paperStatus: String = row["paperStatus"]
    guard paperStatus == "ready" else { return .init(state: "unavailable", failure: nil, usableRevision: nil) }
    let state: String? = row["state"]
    let revision: String? = row["revision"]
    return .init(state: state == "succeeded" && revision == nil ? "unavailable" : state ?? "notStarted",
      failure: row["failure"],
      usableRevision: revision.flatMap(UUID.init(uuidString:)))
  }

  public func lookupExtraction(_ identity: ExtractionSentenceIdentity) throws -> ExtractionSearchHit? {
    try adapterRead { db in
      guard let row = try Row.fetchOne(db, sql: """
        SELECT extractionSentence.text, geometry FROM paper
        JOIN extractionRevision ON extractionRevision.paperID = paper.id
        JOIN extractionSentence ON extractionSentence.revision = extractionRevision.id
        WHERE paper.id = ? AND paper.status = 'ready' AND paper.deletionID IS NULL
          AND paper.pdfSHA256 = ? AND extractionRevision.id = ?
          AND extractionRevision.generation = paper.generation
          AND extractionRevision.pdfSHA256 = paper.pdfSHA256
          AND extractionRevision.pdfReference = paper.pdfReference
          AND page = ? AND sentenceID = ?
        """, arguments: [identity.paperID.uuidString, identity.pdfSHA256,
          identity.revision.uuidString, identity.page, identity.sentenceID]) else { return nil }
      return .init(revision: identity.revision, page: identity.page, sentenceID: identity.sentenceID,
        text: row["text"], canonicalGeometry: row["geometry"])
    }
  }

  /// Captures pointer and every row under one sole-queue read snapshot. A retained revision
  /// may be supplied by the parent's read lease; this adapter never reclaims old revisions.
  public func searchExtraction(paperID: UUID, matching query: String,
    revision: UUID? = nil, limit: Int = 32) throws -> [ExtractionSearchHit] {
    let authority = try ProviderRequest()
    guard !query.isEmpty, query.utf8.count <= authority.limit("sentenceBytes"),
      limit > 0, limit <= authority.limit("batchSentences") else {
      throw ExtractionError.invalidBatch
    }
    return try adapterRead { db in
      guard let selected = try String.fetchOne(db, sql: """
        SELECT extractionRevision.id FROM paper
        JOIN extractionVisible ON extractionVisible.paperID = paper.id
        JOIN extractionRevision ON extractionRevision.paperID = paper.id
          AND extractionRevision.id = COALESCE(?, extractionVisible.revision)
        WHERE paper.id = ? AND paper.status = 'ready' AND paper.deletionID IS NULL
          AND extractionRevision.generation = paper.generation
          AND extractionRevision.pdfSHA256 = paper.pdfSHA256
          AND extractionRevision.pdfReference = paper.pdfReference
        """, arguments: [revision?.uuidString, paperID.uuidString]),
        let revisionID = UUID(uuidString: selected) else { return [] }
      return try Row.fetchAll(db, sql: """
        SELECT page, sentenceID, extractionSentence.text, geometry
        FROM extractionFTS JOIN extractionSentence ON extractionSentence.id = extractionFTS.rowid
        WHERE extractionFTS MATCH ? AND revision = ? ORDER BY rank, sentenceID LIMIT ?
        """, arguments: [query, selected, limit]).map {
          .init(revision: revisionID, page: $0["page"], sentenceID: $0["sentenceID"],
            text: $0["text"], canonicalGeometry: $0["geometry"])
        }
    }
  }
}
