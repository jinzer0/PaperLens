import CryptoKit
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
    migrator.registerMigration("extractionOriginalGeometryOwnersV1") { db in
      // Deliberately no INSERT SELECT/backfill: candidate blobs cannot establish originals.
      try db.execute(sql: """
        CREATE TABLE extractionGeometryOwner (
          revision TEXT NOT NULL,
          sentenceID INTEGER NOT NULL,
          page INTEGER NOT NULL,
          maximumErrorPDFPoints REAL NOT NULL CHECK(maximumErrorPDFPoints >= 0),
          originalAnchor BLOB NOT NULL
            CHECK(length(originalAnchor) > 0 AND length(originalAnchor) <= \(SummaryOwnerArchive.maximumBytes)),
          PRIMARY KEY(revision, sentenceID),
          FOREIGN KEY(revision, sentenceID)
            REFERENCES extractionSentence(revision, sentenceID) ON DELETE CASCADE
        );
        """)
    }
  }

  static func registerExtractionHistoryMigration(in migrator: inout DatabaseMigrator) {
    migrator.registerMigration("extractionAttemptHistoryV1") { db in
      try db.execute(sql: """
        CREATE TABLE extractionAttemptHistory (
          attempt TEXT PRIMARY KEY NOT NULL REFERENCES extractionInvocation(attempt) ON DELETE CASCADE,
          generation TEXT NOT NULL, pdfSHA256 TEXT NOT NULL, pdfReference TEXT NOT NULL,
          job TEXT NOT NULL, correlation TEXT NOT NULL, input TEXT NOT NULL, epoch TEXT NOT NULL,
          configSlot TEXT, configGeneration INTEGER NOT NULL, configKind TEXT,
          state TEXT NOT NULL CHECK(state IN ('failed', 'succeeded')), failure TEXT
        );
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
    guard try matchesExtractionAttempt(db, identity, state: "running") else {
      throw ExtractionError.staleAttempt
    }
  }

  func matchesExtractionAttempt(_ db: Database, _ identity: ExtractionIdentity,
    state: String, failure: ExtractionError? = nil) throws -> Bool {
    try Int.fetchOne(db, sql: """
      SELECT COUNT(*) FROM extractionAttempt WHERE paperID = ? AND generation = ?
        AND pdfSHA256 = ? AND pdfReference = ? AND revision = ? AND job = ? AND attempt = ?
        AND fence = ? AND correlation = ? AND input = ? AND epoch = ?
        AND configSlot IS ? AND configGeneration = ? AND configKind IS ?
        AND state = ? AND failure IS ?
      """, arguments: attemptArguments(identity) + [state, failure?.rawValue]) == 1
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

  func reserveExtraction(_ identity: ExtractionIdentity, firstInvocationOnly: Bool = false) throws {
    try adapterWrite { db in
      try guardExtractionPaper(db, identity)
      if firstInvocationOnly, try !isFirstExtractionInvocation(db, paperID: identity.paperID) {
        throw ExtractionError.staleAttempt
      }
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
      try replaceExtractionAttempt(identity, in: db)
    }
  }

  /// Record the failure after the initial reservation rolled back. Nothing was sent to the parser.
  func recordInitialExtractionFailure(_ identity: ExtractionIdentity) throws {
    try adapterWrite { db in
      guard try isFirstExtractionInvocation(db, paperID: identity.paperID) else { return }
      do { try guardExtractionPaper(db, identity) }
      catch ExtractionError.staleAttempt { return }
      try insertExtractionInvocation(db, identity, failure: .reservationFailure)
    }
  }

  private func isFirstExtractionInvocation(_ db: Database, paperID: UUID) throws -> Bool {
    try Int.fetchOne(db, sql: """
      SELECT EXISTS (SELECT 1 FROM extractionInvocation WHERE paperID = ?)
        OR EXISTS (SELECT 1 FROM extractionAttempt WHERE paperID = ?)
      """, arguments: [paperID.uuidString, paperID.uuidString]) == 0
  }

  /// Preserve a terminal attempt in the same transaction as its replacement.
  /// The invocation owns the archived row and cascades Paper deletion to it.
  func replaceExtractionAttempt(_ identity: ExtractionIdentity, in db: Database) throws {
    let paperID = identity.paperID.uuidString
    try db.execute(sql: """
      INSERT INTO extractionAttemptHistory(attempt, generation, pdfSHA256, pdfReference,
        job, correlation, input, epoch, configSlot, configGeneration, configKind, state, failure)
      SELECT a.attempt, a.generation, a.pdfSHA256, a.pdfReference, a.job, a.correlation,
        a.input, a.epoch, a.configSlot, a.configGeneration, a.configKind, a.state, a.failure
      FROM extractionAttempt a JOIN extractionInvocation i
        ON i.attempt = a.attempt AND i.fence = a.fence AND i.revision = a.revision AND i.paperID = a.paperID
      WHERE a.paperID = ? AND a.state IN ('failed', 'succeeded')
      """, arguments: [paperID])
    let archived = db.changesCount
    try db.execute(sql: "DELETE FROM extractionAttempt WHERE paperID = ?", arguments: [paperID])
    guard db.changesCount == archived else { throw ProductDatabaseError.invalidRecord }
    try insertExtractionInvocation(db, identity)
  }

  private func insertExtractionInvocation(_ db: Database, _ identity: ExtractionIdentity,
    failure: ExtractionError? = nil) throws {
    let state = failure == nil ? "running" : "failed"
    try db.execute(sql: "INSERT INTO extractionInvocation(attempt, fence, revision, paperID) VALUES (?, ?, ?, ?)",
      arguments: [identity.attempt.uuidString, identity.fence.uuidString,
        identity.revision.uuidString, identity.paperID.uuidString])
    try db.execute(sql: """
      INSERT INTO extractionAttempt(paperID, generation, pdfSHA256, pdfReference, revision,
        job, attempt, fence, correlation, input, epoch, configSlot, configGeneration, configKind, state, failure)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      """, arguments: attemptArguments(identity) + [state, failure?.rawValue])
    try guardExtractionPaper(db, identity)
    guard try matchesExtractionAttempt(db, identity, state: state, failure: failure),
      try Int.fetchOne(db, sql: """
        SELECT COUNT(*) FROM extractionInvocation
        WHERE attempt = ? AND fence = ? AND revision = ? AND paperID = ?
        """, arguments: [identity.attempt.uuidString, identity.fence.uuidString,
          identity.revision.uuidString, identity.paperID.uuidString]) == 1
    else { throw ExtractionError.reservationFailure }
  }

  func publishExtraction(_ identity: ExtractionIdentity, sentences: [ValidatedExtractionSentence],
    sourceMetadata: ReaderMetadataSnapshot = .init(), checkBudget: @Sendable () throws -> Void) throws {
    guard !sentences.isEmpty else { throw ExtractionError.invalidBatch }
    let ownedCount = sentences.reduce(0) { $0 + ($1.originalOwner == nil ? 0 : 1) }
    guard ownedCount == 0 || ownedCount == sentences.count else { throw ExtractionError.invalidBatch }
    try adapterWrite { db in
      try checkBudget()
      try guardExtractionAttempt(db, identity)
      try db.execute(sql: """
        INSERT INTO extractionRevision(id, paperID, generation, pdfSHA256, pdfReference)
        VALUES (?, ?, ?, ?, ?)
        """, arguments: [identity.revision.uuidString, identity.paperID.uuidString,
          identity.generation.uuidString, identity.pdfSHA256, identity.pdfReference])
      guard db.changesCount == 1 else { throw ExtractionError.storageFailure }
      var ownerPrecision: PDFGeometryPrecision?
      var originalDigests: [SHA256.Digest] = []
      originalDigests.reserveCapacity(ownedCount)
      for sentence in sentences {
        try checkBudget()
        try db.execute(sql: """
          INSERT INTO extractionSentence(revision, page, sentenceID, text, geometry) VALUES (?, ?, ?, ?, ?)
          """, arguments: [identity.revision.uuidString, sentence.page, sentence.sentenceID,
            sentence.text, sentence.geometry])
        guard db.changesCount == 1 else { throw ExtractionError.storageFailure }
        if let owner = sentence.originalOwner {
          if let ownerPrecision, ownerPrecision != owner.precision { throw ExtractionError.invalidBatch }
          ownerPrecision = owner.precision
          let key = ExtractionSentenceIdentity(paperID: identity.paperID, pdfSHA256: identity.pdfSHA256,
            revision: identity.revision, page: sentence.page, sentenceID: sentence.sentenceID)
          let archive = try owner.archive(for: key, text: sentence.text, candidate: sentence.geometry)
          guard archive.anchors.count == 1, let original = archive.anchors.first else {
            throw ExtractionError.invalidBatch
          }
          originalDigests.append(SHA256.hash(data: original.bytes))
          try checkBudget()
          try db.execute(sql: """
            INSERT INTO extractionGeometryOwner(revision, sentenceID, page, maximumErrorPDFPoints, originalAnchor)
            VALUES (?, ?, ?, ?, ?)
            """, arguments: [identity.revision.uuidString, sentence.sentenceID, sentence.page,
              archive.maximumErrorPDFPoints, original.bytes])
          guard db.changesCount == 1 else { throw ExtractionError.storageFailure }
        }
      }
      try checkBudget()
      try guardExtractionAttempt(db, identity)
      try db.execute(sql: """
        INSERT INTO extractionVisible(paperID, revision) VALUES (?, ?)
        ON CONFLICT(paperID) DO UPDATE SET revision = excluded.revision
        """, arguments: [identity.paperID.uuidString, identity.revision.uuidString])
      if !sourceMetadata.isEmpty {
        let metadataIdentity = ReaderMetadataIdentity(paperID: identity.paperID, generation: identity.generation,
          pdfSHA256: identity.pdfSHA256, pdfReference: identity.pdfReference, revisionID: identity.revision)
        _ = try Self.mergeReaderPDFSource(sourceMetadata, for: metadataIdentity, in: db)
      }
      try db.execute(sql: "UPDATE extractionAttempt SET state = 'succeeded', failure = NULL WHERE paperID = ?",
        arguments: [identity.paperID.uuidString])
      try guardExtractionPaper(db, identity)
      guard try matchesExtractionAttempt(db, identity, state: "succeeded"),
        try Int.fetchOne(db, sql: """
          SELECT COUNT(*) FROM extractionVisible v
          JOIN extractionRevision r ON r.id = v.revision AND r.paperID = v.paperID
          WHERE v.paperID = ? AND r.id = ? AND r.generation = ?
            AND r.pdfSHA256 = ? AND r.pdfReference = ?
          """, arguments: [identity.paperID.uuidString, identity.revision.uuidString,
            identity.generation.uuidString, identity.pdfSHA256, identity.pdfReference]) == 1
      else { throw ExtractionError.storageFailure }
      // Read the final rows after all publication writes. Row counts alone cannot
      // detect a rewritten page, quote or anchor. The cursor keeps one row at a time.
      let stored = try Row.fetchCursor(db, sql: """
        SELECT s.page, s.sentenceID, CAST(s.text AS BLOB) AS textBytes, s.geometry, o.originalAnchor,
          o.page AS ownerPage, o.maximumErrorPDFPoints,
          CAST(f.text AS BLOB) = CAST(s.text AS BLOB) AS indexedTextMatches
        FROM extractionSentence s
        LEFT JOIN extractionFTS f ON f.rowid = s.id
        LEFT JOIN extractionGeometryOwner o ON o.revision = s.revision
          AND o.sentenceID = s.sentenceID
        WHERE s.revision = ? ORDER BY s.sentenceID
        """, arguments: [identity.revision.uuidString])
      for (index, expected) in sentences.enumerated() {
        try checkBudget()
        guard let row = try stored.next(),
          (row["indexedTextMatches"] as Bool?) == true,
          (row["page"] as DatabaseValue).storage == expected.page.databaseValue.storage,
          (row["sentenceID"] as DatabaseValue).storage == expected.sentenceID.databaseValue.storage,
          try row.withUnsafeData(named: "textBytes", { $0?.elementsEqual(expected.text.utf8) == true }),
          try row.withUnsafeData(named: "geometry", { $0 == expected.geometry })
        else { throw ExtractionError.storageFailure }
        if let ownerPrecision {
          guard (row["maximumErrorPDFPoints"] as DatabaseValue) == ownerPrecision.maximumErrorPDFPoints.databaseValue,
            (row["ownerPage"] as DatabaseValue).storage == expected.page.databaseValue.storage,
            try row.withUnsafeData(named: "originalAnchor", {
              $0.map { SHA256.hash(data: $0) } == originalDigests[index]
            }) else { throw ExtractionError.storageFailure }
        } else if !(row["ownerPage"] as DatabaseValue).isNull {
          throw ExtractionError.storageFailure
        }
      }
      guard try stored.next() == nil else { throw ExtractionError.storageFailure }
      try checkBudget()
    }
  }

  func failExtraction(_ identity: ExtractionIdentity, failure: ExtractionError) throws {
    try adapterWrite { db in
      // A stale callback must neither fail a newer attempt nor erase prior usable content.
      guard try Int.fetchOne(db, sql: """
        SELECT COUNT(*) FROM paper WHERE id = ? AND status = 'ready' AND deletionID IS NULL
          AND generation = ? AND pdfSHA256 = ? AND pdfReference = ?
        """, arguments: [identity.paperID.uuidString, identity.generation.uuidString,
          identity.pdfSHA256, identity.pdfReference]) == 1 else { return }
      do { try guardExtractionAttempt(db, identity, requireCurrentPaper: false) }
      catch ExtractionError.staleAttempt { return }
      try db.execute(sql: "UPDATE extractionAttempt SET state = 'failed', failure = ? WHERE paperID = ?",
        arguments: [failure.rawValue, identity.paperID.uuidString])
      guard try matchesExtractionAttempt(db, identity, state: "failed", failure: failure)
      else { throw ExtractionError.storageFailure }
    }
  }

  public func extractionStatus(paperID: UUID) throws -> ExtractionStatus {
    try adapterRead { db in
      try Self.fetchExtractionStatus(paperID: paperID, in: db)
    }
  }

  static func fetchExtractionStatus(paperID: UUID, in db: Database) throws -> ExtractionStatus {
    guard let row = try Row.fetchOne(db, sql: """
        SELECT paper.status AS paperStatus, paper.deletionID, extractionAttempt.state, extractionAttempt.failure,
          extractionAttempt.generation = paper.generation AND extractionAttempt.pdfSHA256 = paper.pdfSHA256
            AND extractionAttempt.pdfReference = paper.pdfReference AS currentAttempt,
          extractionAttempt.revision AS attemptRevision,
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
    let deletionID: String? = row["deletionID"]
    guard paperStatus == "ready", deletionID == nil else {
      return .init(state: "unavailable", failure: nil, usableRevision: nil)
    }
    let state: String? = row["state"]
    let usable = String.fromDatabaseValue(row["revision"]).flatMap(UUID.init(uuidString:))
    let currentAttempt: Bool? = row["currentAttempt"]
    let attempted = String.fromDatabaseValue(row["attemptRevision"]).flatMap(UUID.init(uuidString:))
    if (state != nil && currentAttempt != true) || (state == "succeeded" && (usable == nil || usable != attempted)) {
      return .init(state: "unavailable", failure: nil, usableRevision: usable)
    }
    return .init(state: state ?? "notStarted", failure: row["failure"], usableRevision: usable)
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

  /// Read-only original facts for an exact retained revision of the current live Paper.
  /// Does not pin a job, dispatch work, authorize publication, or certify calibration.
  /// Legacy/missing owners return nil; candidate geometry is never read or backfilled.
  public func originalExtractionGeometryOwners(paperID: UUID, generation: UUID, pdfSHA256: String,
    revision: UUID, sentences: Set<PDFSentenceIdentity>) throws -> CanonicalExtractionGeometryValidator? {
    guard !sentences.isEmpty, sentences.count <= SummaryOwnerArchive.maximumBytes / 128,
      sentences.allSatisfy({
        $0.paperID == paperID && $0.pdfSHA256 == pdfSHA256
          && $0.extractionRevision == revision.uuidString.lowercased()
      }) else { throw ExtractionError.invalidBatch }
    return try adapterRead { db in
      guard try Int.fetchOne(db, sql: """
        SELECT COUNT(*) FROM paper p JOIN extractionRevision r ON r.paperID = p.id
        WHERE p.id = ? AND p.generation = ? AND p.pdfSHA256 = ?
          AND p.status = 'ready' AND p.deletionID IS NULL AND r.id = ?
          AND r.generation = p.generation AND r.pdfSHA256 = p.pdfSHA256
          AND r.pdfReference = p.pdfReference
        """, arguments: [paperID.uuidString, generation.uuidString, pdfSHA256, revision.uuidString]) == 1
      else { return nil }
      var originals: [PDFSentenceAnchor] = []
      var precision: PDFGeometryPrecision?
      var totalBytes = 0
      for identity in sentences.sorted(by: { ($0.pageIndex, $0.sentenceID) < ($1.pageIndex, $1.sentenceID) }) {
        let arguments: StatementArguments = [revision.uuidString, identity.sentenceID, identity.pageIndex]
        // Check aggregate length before materializing the BLOB, under the same read snapshot.
        guard let row = try Row.fetchOne(db, sql: """
          SELECT length(originalAnchor) AS byteCount, maximumErrorPDFPoints
          FROM extractionGeometryOwner WHERE revision = ? AND sentenceID = ? AND page = ?
          """, arguments: arguments) else { return nil }
        let byteCount: Int = row["byteCount"]
        guard byteCount > 0, byteCount <= SummaryOwnerArchive.maximumBytes - totalBytes else {
          throw ExtractionError.invalidBatch
        }
        let recorded = try PDFGeometryPrecision(maximumErrorPDFPoints: row["maximumErrorPDFPoints"])
        if let precision, precision != recorded { throw ExtractionError.invalidBatch }
        precision = recorded
        guard let bytes = try Data.fetchOne(db, sql: """
          SELECT originalAnchor FROM extractionGeometryOwner
          WHERE revision = ? AND sentenceID = ? AND page = ?
          """, arguments: arguments), bytes.count == byteCount else { throw ExtractionError.invalidBatch }
        let original = try CanonicalExtractionGeometryValidator.decodeCanonicalAnchor(bytes)
        guard original.identity == identity else { throw ExtractionError.invalidBatch }
        originals.append(original)
        totalBytes += byteCount
      }
      guard let precision else { return nil }
      let validator = try CanonicalExtractionGeometryValidator(owningAnchors: originals, precision: precision)
      // Reuse the existing archive's conservative quote/quad and aggregate limits.
      _ = try validator.captureSummaryOwners(sentences)
      return validator
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
