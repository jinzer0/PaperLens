import Foundation
import GRDB
import Darwin

/// Stored attestations only: neither this record nor its replay grants physical authority.
struct ImportRecoveryRecord: Sendable {
  let journal: ImportRecoveryJournal
  let encoded: Data
}

struct ImportDeletionCapture: Sendable {
  let saga: UUID
  let histories: [ImportRecoveryRecord]
  let legacyJobCount: Int
}

/// Written only by the transaction's actual mover, retained by its physical owner.
final class ImportPublicationReceipt: @unchecked Sendable {
  let stage: ClosedImportStage
  private let lock = NSLock()
  private var physicalMove = false
  init(stage: ClosedImportStage) { self.stage = stage }
  var moved: Bool { lock.withLock { physicalMove } }
  fileprivate func didMove() { lock.withLock { physicalMove = true } }
}

/// Memory-only observation. Construction grants neither read authority nor closure proof.
/// The producer owner must independently check closure before issuing this value.
struct ClosedImportStage: Sendable {
  let file: URL
  let sha256: String
  let bytes: Int64
}

enum ImportRecoveryPersistenceError: Error, Equatable {
  case missingHistory, staleHistory, invalidHistory
}

enum ImportAbortFailure: String, Sendable {
  case cancelled, sourceChanged, importFailed, urlImportFailed, publicationRejected
}

/// Transaction-local observation, not an SQLite hook replacement. GRDB retains
/// this observer through the actual commit/rollback with .nextTransaction.
private final class ImportFailureWriteScope: TransactionObserver {
  private let paperRowID: Int64
  private let jobRowID: Int64
  private var violated = false

  init(paperRowID: Int64, jobRowID: Int64) {
    self.paperRowID = paperRowID
    self.jobRowID = jobRowID
  }

  var databaseEventObservationStrategy: DatabaseEventObservationStrategy {
    var strategy = DatabaseEventObservationStrategy.default
    // Universal observation also prevents truncate-delete optimization.
    strategy.requiresDatabaseEventKind = false
    return strategy
  }

  func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool { true }
  func databaseDidChange() { violated = true }

  func databaseDidChange(with event: DatabaseEvent) {
    guard event.kind == .update, event.databaseName == "main",
      (event.tableName == "paper" && event.rowID == paperRowID)
        || (event.tableName == "importJob" && event.rowID == jobRowID) else {
      violated = true
      return
    }
  }

  func validate() throws {
    if violated { throw ImportRecoveryPersistenceError.invalidHistory }
  }

  func databaseWillCommit() throws { try validate() }
  func databaseDidCommit(_ db: Database) { }
  func databaseDidRollback(_ db: Database) { }
}

/// Default-strategy observation inspects GRDB's compiled statement event kinds,
/// including trigger writes for which SQLite does not emit row-update events.
private final class ImportFailureShadowWriteScope: TransactionObserver {
  private let shadowTables: Set<String>
  private var violated = false

  init(shadowTables: Set<String>) { self.shadowTables = shadowTables }

  func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool {
    if shadowTables.contains(eventKind.tableName.lowercased()) { violated = true }
    return true
  }

  func databaseDidChange() { violated = true }
  func databaseDidChange(with event: DatabaseEvent) { }
  func validate() throws {
    if violated { throw ImportRecoveryPersistenceError.invalidHistory }
  }
  func databaseWillCommit() throws { try validate() }
  func databaseDidCommit(_ db: Database) { }
  func databaseDidRollback(_ db: Database) { }
}

extension ProductDatabase {
  func captureRetryableImport(paperID: UUID, generation: UUID) throws -> ImportRecoveryRecord {
    try adapterRead { db in
      try Self.retryableImport(paperID: paperID, generation: generation, in: db)
    }
  }

  private static func retryableImport(paperID: UUID, generation: UUID,
    in db: Database) throws -> ImportRecoveryRecord {
    let jobs = try boundedDeletionJobs(paperID, in: db)
    guard jobs.count == 1, let jobID = recoveryString(jobs[0], "id"),
      UUID(uuidString: jobID)?.uuidString == jobID,
      let record = try readImportRecoveryForAdmission(jobID: jobID, saga: nil, in: db) else {
      throw ImportRecoveryPersistenceError.invalidHistory
    }
    let identity = try record.journal.currentCapture().identity
    guard identity.paperID == paperID, identity.generation == generation else {
      throw ImportRecoveryPersistenceError.staleHistory
    }
    try validateExpectedRecovery(record)
    let snapshot = try record.journal.snapshot()
    let row = try recoveryRow(identity,
      maximumBytes: ProductJobRecovery.maximumImportRecoveryJournalBytes, in: db)
    guard case .failed = snapshot.current.state, !snapshot.revoked,
      snapshot.permits.isEmpty, snapshot.removalDebt == nil, snapshot.pendingRemoval == nil,
      recoveryString(row, "paperStatus") == "importFailed",
      recoveryString(row, "jobState") == "failed",
      Int64.fromDatabaseValue(row["cleanupDebt"]) == 0,
      nullColumns(row, ["deletionID", "pdfReference"]) else {
      throw ImportRecoveryPersistenceError.invalidHistory
    }
    return record
  }

  func reserveJournaledImportRetry(expected: ImportRecoveryRecord, identity: ImportIdentity,
    confirmedInput: ImportRecoveryJournal.ConfirmedInput, currentEpoch: UUID) throws -> ImportRecoveryRecord {
    guard identity.epoch == currentEpoch, confirmedInput.expectedSHA256 != nil else {
      throw ImportRecoveryPersistenceError.invalidHistory
    }
    return try adapterWrite { db in
      let maximum = ProductJobRecovery.maximumImportRecoveryJournalBytes
      try Self.validateExpectedRecovery(expected)
      let oldIdentity = try expected.journal.currentCapture().identity
      guard identity.paperID == oldIdentity.paperID, identity.generation == oldIdentity.generation,
        identity.jobID == oldIdentity.jobID else { throw ImportRecoveryPersistenceError.staleHistory }
      let current = try Self.retryableImport(paperID: identity.paperID, generation: identity.generation, in: db)
      guard current.encoded == expected.encoded else { throw ImportRecoveryPersistenceError.staleHistory }
      try Self.validateImportDestination(confirmedInput.destinationFolderID, in: db)
      var journal = expected.journal
      if try journal.snapshot().authority.epoch != currentEpoch.uuidString {
        journal = try journal.recording(.startup(currentEpoch: currentEpoch.uuidString))
      }
      journal = try journal.retrying(identity: identity, confirmedInput: confirmedInput)
      let lineage = try journal.snapshot().current.lineage
      journal = try journal.recording(.claim(lineage))
      journal = try journal.recording(.acquireWriter(lineage, permit: identity.writer.uuidString))
      let opened = try journal.recording(.writerClosure(lineage, permit: identity.writer.uuidString, .open))
      try LocalLibraryLifecycle.preflight(opened)
      guard try journal.extends(expected.journal, maximumBytes: maximum) else {
        throw ImportRecoveryPersistenceError.invalidHistory
      }
      let bytes = try Self.recoveryEncode(journal, maximumBytes: maximum)
      let before = try Self.importRows(oldIdentity, in: db)
      let folder = try Self.importFolder(identity.paperID, in: db)
      guard let schemaVersion = try Int64.fetchOne(db, sql: "PRAGMA main.schema_version"),
        let paperRowID = try Int64.fetchOne(db, sql: "SELECT rowid FROM main.paper WHERE id = ?",
          arguments: [identity.paperID.uuidString]),
        let jobRowID = try Int64.fetchOne(db, sql: "SELECT rowid FROM main.importJob WHERE id = ?",
          arguments: [identity.jobID.uuidString]) else { throw ImportRecoveryPersistenceError.invalidHistory }
      let databases = try Row.fetchAll(db, sql: "PRAGMA database_list")
      let scope = ImportFailureWriteScope(paperRowID: paperRowID, jobRowID: jobRowID)
      let shadowScope = ImportFailureShadowWriteScope(shadowTables:
        try Self.importRecoveryShadowTables(databases: databases, in: db))
      db.add(transactionObserver: scope, extent: .nextTransaction)
      db.add(transactionObserver: shadowScope, extent: .nextTransaction)
      let changesBefore = try Int64.fetchOne(db, sql: "SELECT total_changes()")
      let old = Self.recoveryIDs(oldIdentity)
      let fresh = Self.recoveryIDs(identity)
      try db.execute(sql: """
        UPDATE importJob SET attempt = ?, fence = ?, correlation = ?, input = ?, epoch = ?,
          writer = ?, publication = ?, recoveryJournal = ?, state = 'running', failure = NULL, bytesCopied = 0
        WHERE id = ? AND paperID = ? AND attempt = ? AND fence = ? AND correlation = ?
          AND input = ? AND epoch = ? AND writer = ? AND publication = ? AND recoveryJournal IS ?
          AND state = 'failed' AND failure IS ?
          AND EXISTS (SELECT 1 FROM paper p WHERE p.id = importJob.paperID AND p.generation = ?
            AND p.status = 'importFailed' AND p.cleanupDebt = 0 AND p.deletionID IS NULL AND p.pdfReference IS NULL)
        """, arguments: [fresh[3], fresh[4], fresh[5], fresh[6], fresh[7], fresh[8], fresh[9], bytes,
          old[2], old[0], old[3], old[4], old[5], old[6], old[7], old[8], old[9], expected.encoded,
          Self.recoveryString(before.1, "failure"), old[1]])
      guard db.changesCount == 1 else { throw ImportRecoveryPersistenceError.staleHistory }
      try db.execute(sql: """
        UPDATE paper SET status = 'importing' WHERE id = ? AND generation = ?
          AND status = 'importFailed' AND cleanupDebt = 0 AND deletionID IS NULL AND pdfReference IS NULL
        """, arguments: [old[0], old[1]])
      guard db.changesCount == 1 else { throw ImportRecoveryPersistenceError.staleHistory }
      let readback = try Self.readImportRecovery(identity, maximumBytes: maximum, in: db)
      try Self.validateRecoveryExecution(readback.journal,
        row: Self.recoveryRow(identity, maximumBytes: maximum, in: db), identity: identity, revoked: false)
      let after = try Self.importRows(identity, in: db)
      let changesAfter = try Int64.fetchOne(db, sql: "SELECT total_changes()")
      try scope.validate()
      try shadowScope.validate()
      guard Self.sameRow(before.0, after.0, except: ["status"]),
        Self.sameRow(before.1, after.1, except: ["attempt", "fence", "correlation", "input", "epoch",
          "writer", "publication", "recoveryJournal", "state", "failure", "bytesCopied"]),
        Self.recoveryString(after.0, "status") == "importing",
        Self.recoveryString(after.1, "state") == "running", Self.nullColumns(after.1, ["failure"]),
        Int64.fromDatabaseValue(after.1["bytesCopied"]) == 0,
        try Self.importFolder(identity.paperID, in: db) == folder,
        try Int64.fetchOne(db, sql: "PRAGMA main.schema_version") == schemaVersion,
        try Row.fetchAll(db, sql: "PRAGMA database_list") == databases,
        // Job CAS, Paper availability and revokeReaderPosition's same-Paper update.
        let changesBefore, let changesAfter, changesAfter - changesBefore == 3,
        readback.encoded == bytes, try readback.journal.snapshot() == journal.snapshot() else {
        throw ImportRecoveryPersistenceError.invalidHistory
      }
      _ = try Self.guardRunningImport(identity, in: db)
      return readback
    }
  }

  func reserveJournaledImport(_ identity: ImportIdentity, title: String,
    confirmedInput: ImportRecoveryJournal.ConfirmedInput) throws -> ImportRecoveryRecord {
    try adapterWrite { db in
      let maximum = ProductJobRecovery.maximumImportRecoveryJournalBytes
      try Self.validateImportDestination(confirmedInput.destinationFolderID, in: db)
      let initial = try ImportRecoveryJournal(identity: identity, confirmedInput: confirmedInput)
      let lineage = try initial.snapshot().current.lineage
      let claimed = try initial.recording(.claim(lineage))
      let createdAt = Date().timeIntervalSince1970
      try Self.insertImport(identity, title: title, createdAt: createdAt, in: db)
      try Self.initializeImportRecovery(claimed, maximumBytes: maximum, in: db)
      let previous = try Self.readImportRecovery(identity, maximumBytes: maximum, in: db)
      let acquired = try claimed.recording(.acquireWriter(lineage, permit: identity.writer.uuidString))
      let record = try Self.compareAndSwapImportRecovery(expected: previous.encoded,
        replacement: acquired, maximumBytes: maximum, in: db)
      let (paper, job) = try Self.importRows(identity, in: db)
      guard Self.recoveryString(paper, "title") == title,
        Double.fromDatabaseValue(paper["createdAt"]) == createdAt,
        Self.recoveryString(paper, "status") == "importing",
        Self.recoveryString(job, "state") == "running",
        Int64.fromDatabaseValue(job["bytesCopied"]) == 0,
        Int64.fromDatabaseValue(paper["cleanupDebt"]) == 0,
        Self.nullColumns(paper, ["pdfReference", "pdfSHA256", "deletionID"]),
        Self.nullColumns(job, ["failure"]),
        try Self.importFolder(identity.paperID, in: db) == nil,
        Data.fromDatabaseValue(job["recoveryJournal"]) == record.encoded,
        try record.journal.snapshot() == acquired.snapshot() else {
        throw ImportRecoveryPersistenceError.invalidHistory
      }
      _ = try Self.guardRunningImport(identity, in: db)
      return record
    }
  }

  func appendJournaledImport(expected: ImportRecoveryRecord,
    replacement: ImportRecoveryJournal) throws -> ImportRecoveryRecord {
    try adapterWrite { db in
      try Self.validateExpectedRecovery(expected)
      let identity = try expected.journal.currentCapture().identity
      let current = try Self.readImportRecovery(identity,
        maximumBytes: ProductJobRecovery.maximumImportRecoveryJournalBytes, in: db)
      guard current.encoded == expected.encoded else { throw ImportRecoveryPersistenceError.staleHistory }
      let before = try Self.importRows(identity, in: db)
      let folder = try Self.importFolder(identity.paperID, in: db)
      let record = try Self.compareAndSwapImportRecovery(expected: expected.encoded,
        replacement: replacement, maximumBytes: ProductJobRecovery.maximumImportRecoveryJournalBytes, in: db)
      let after = try Self.importRows(identity, in: db)
      guard Self.sameRow(before.0, after.0),
        Self.sameRow(before.1, after.1, except: ["recoveryJournal"]),
        Data.fromDatabaseValue(after.1["recoveryJournal"]) == record.encoded,
        try Self.importFolder(identity.paperID, in: db) == folder else {
        throw ImportRecoveryPersistenceError.invalidHistory
      }
      return record
    }
  }

  /// No receipt reconciliation here: SQL rollback cannot undo the physical rename.
  /// On a post-move failure preserve the final bytes and throw to the future owner bridge.
  func publishJournaledImport(expected: ImportRecoveryRecord,
    closedStage: ClosedImportStage, receipt: ImportPublicationReceipt) throws -> ImportRecoveryRecord {
    try adapterWrite { db in
      let maximum = ProductJobRecovery.maximumImportRecoveryJournalBytes
      try Self.validateExpectedRecovery(expected)
      let capture = try expected.journal.currentCapture()
      let identity = capture.identity
      let current = try Self.readImportRecovery(identity, maximumBytes: maximum, in: db)
      guard current.encoded == expected.encoded else { throw ImportRecoveryPersistenceError.staleHistory }
      let progress = try Self.guardRunningImport(identity, in: db)
      let before = try Self.importRows(identity, in: db)
      let snapshot = try expected.journal.snapshot()
      let lineage = snapshot.current.lineage
      let result = JobRecoveryPolicy.Result(id: identity.attempt.uuidString)
      guard snapshot.current.state == .running, !snapshot.revoked,
        let permit = snapshot.permits.first(where: { $0.id == identity.publication.uuidString }),
        permit.owner == lineage, permit.kind == .publication, permit.phase == .renaming,
        !permit.revoked, permit.cleanup == .none, permit.cleanupOperation == nil,
        permit.stage == .validated(result), permit.closure == .unknown,
        closedStage.bytes > 0, progress <= closedStage.bytes,
        closedStage.sha256.utf8.count == 64,
        closedStage.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
        capture.confirmedInput.expectedSHA256 == nil || capture.confirmedInput.expectedSHA256 == closedStage.sha256,
        Self.nullColumns(before.0, ["pdfReference", "pdfSHA256", "deletionID"]),
        Self.nullColumns(before.1, ["failure"]),
        Int64.fromDatabaseValue(before.0["cleanupDebt"]) == 0 else {
        throw ImportRecoveryPersistenceError.invalidHistory
      }
      try Self.validateImportDestination(capture.confirmedInput.destinationFolderID, in: db)
      // This preview is admission only. It is never stored before an actual successful move.
      let renamed = try expected.journal.recording(.renameFinished(lineage,
        permit: identity.publication.uuidString, succeeded: true))
      let published = try renamed.recording(.publish(lineage, permit: identity.publication.uuidString, result))
      let completed = try published.recording(.release(lineage, permit: identity.publication.uuidString))
      let finalBytes = try Self.recoveryEncode(completed, maximumBytes: maximum)
      let final = try Self.closedStageDestination(closedStage, identity: identity, root: root)
      try FileManager.default.moveItem(at: closedStage.file, to: final)
      receipt.didMove()
      let stored = try Self.compareAndSwapImportRecovery(expected: expected.encoded,
        replacement: completed, maximumBytes: maximum, in: db)
      try Self.publishImportRows(identity, sha256: closedStage.sha256,
        destinationFolderID: capture.confirmedInput.destinationFolderID, in: db)
      let readback = try Self.readImportRecovery(identity, maximumBytes: maximum, in: db)
      let after = try Self.importRows(identity, in: db)
      guard Self.sameRow(before.0, after.0, except: ["status", "pdfReference", "pdfSHA256"]),
        Self.sameRow(before.1, after.1, except: ["state", "failure", "recoveryJournal"]),
        Self.recoveryString(after.0, "status") == "ready",
        Self.recoveryString(after.0, "pdfReference") == "papers/\(identity.paperID.uuidString)/document.pdf",
        Self.recoveryString(after.0, "pdfSHA256") == closedStage.sha256,
        Self.recoveryString(after.1, "state") == "succeeded", Self.nullColumns(after.1, ["failure"]),
        Int64.fromDatabaseValue(after.1["bytesCopied"]) == progress,
        try Self.importFolder(identity.paperID, in: db) == capture.confirmedInput.destinationFolderID?.uuidString,
        stored.encoded == finalBytes, readback.encoded == finalBytes,
        Data.fromDatabaseValue(after.1["recoveryJournal"]) == finalBytes,
        try readback.journal.snapshot() == completed.snapshot() else {
        throw ImportRecoveryPersistenceError.invalidHistory
      }
      return readback
    }
  }

  /// Independent post-transaction reconciliation; a moved path is not a SQL commit.
  func reconcileJournaledPublication(expected: ImportRecoveryRecord,
    closedStage: ClosedImportStage) throws -> ImportRecoveryRecord? {
    try adapterRead { db in
      try Self.validateExpectedRecovery(expected)
      let capture = try expected.journal.currentCapture()
      let identity = capture.identity
      let lineage = try expected.journal.snapshot().current.lineage
      let renamed = try expected.journal.recording(.renameFinished(lineage,
        permit: identity.publication.uuidString, succeeded: true))
      let published = try renamed.recording(.publish(lineage, permit: identity.publication.uuidString,
        .init(id: identity.attempt.uuidString)))
      let completed = try published.recording(.release(lineage, permit: identity.publication.uuidString))
      let bytes = try completed.encoded(maximumBytes: ProductJobRecovery.maximumImportRecoveryJournalBytes)
      let current = try Self.readImportRecovery(identity,
        maximumBytes: ProductJobRecovery.maximumImportRecoveryJournalBytes, in: db)
      let rows = try Self.importRows(identity, in: db)
      if current.encoded == expected.encoded {
        guard Self.recoveryString(rows.0, "status") == "importing",
          Self.recoveryString(rows.1, "state") == "running",
          Self.nullColumns(rows.0, ["pdfReference", "pdfSHA256", "deletionID"]),
          Self.nullColumns(rows.1, ["failure"]),
          try Self.importFolder(identity.paperID, in: db) == nil else {
          throw ImportRecoveryPersistenceError.invalidHistory
        }
        return nil
      }
      guard current.encoded == bytes,
        Self.recoveryString(rows.0, "status") == "ready",
        Self.recoveryString(rows.0, "pdfReference") == "papers/\(identity.paperID.uuidString)/document.pdf",
        Self.recoveryString(rows.0, "pdfSHA256") == closedStage.sha256,
        Self.recoveryString(rows.1, "state") == "succeeded",
        Self.nullColumns(rows.1, ["failure"]),
        Self.nullColumns(rows.0, ["deletionID"]),
        Int64.fromDatabaseValue(rows.0["cleanupDebt"]) == 0,
        Int64.fromDatabaseValue(rows.1["bytesCopied"]) == closedStage.bytes,
        try Self.importFolder(identity.paperID, in: db) == capture.confirmedInput.destinationFolderID?.uuidString else {
        throw ImportRecoveryPersistenceError.invalidHistory
      }
      return current
    }
  }

  func appendDeletingImport(expected: ImportRecoveryRecord, replacement: ImportRecoveryJournal,
    saga: UUID) throws -> ImportRecoveryRecord {
    try adapterWrite { db in
      try Self.validateExpectedRecovery(expected)
      return try Self.compareAndSwapImportRecoveryForDeletion(expected: expected.encoded,
        replacement: replacement, saga: saga,
        maximumBytes: ProductJobRecovery.maximumImportRecoveryJournalBytes, in: db)
    }
  }

  func completeFailedImportCleanup(expected: ImportRecoveryRecord) throws {
    try adapterWrite { db in
      try Self.validateExpectedRecovery(expected)
      let identity = try expected.journal.currentCapture().identity
      let maximum = ProductJobRecovery.maximumImportRecoveryJournalBytes
      let current = try Self.readImportRecovery(identity, maximumBytes: maximum, in: db)
      let snapshot = try current.journal.snapshot()
      guard current.encoded == expected.encoded, !snapshot.revoked,
        snapshot.current.state == .failed(.failed), snapshot.permits.isEmpty,
        snapshot.pendingRemoval == nil, snapshot.removalDebt == nil else {
        throw ImportRecoveryPersistenceError.invalidHistory
      }
      let before = try Self.importRows(identity, in: db)
      guard Self.recoveryString(before.0, "status") == "importFailed",
        Self.recoveryString(before.1, "state") == "failed",
        let code = Self.recoveryString(before.1, "failure"),
        ImportAbortFailure(rawValue: code) != nil else { throw ImportRecoveryPersistenceError.invalidHistory }
      let folder = try Self.importFolder(identity.paperID, in: db)
      guard let paperRowID = try Int64.fetchOne(db, sql: "SELECT rowid FROM main.paper WHERE id = ?",
        arguments: [identity.paperID.uuidString]),
        let jobRowID = try Int64.fetchOne(db, sql: "SELECT rowid FROM main.importJob WHERE id = ?",
          arguments: [identity.jobID.uuidString]) else { throw ImportRecoveryPersistenceError.invalidHistory }
      let databases = try Row.fetchAll(db, sql: "PRAGMA database_list")
      let scope = ImportFailureWriteScope(paperRowID: paperRowID, jobRowID: jobRowID)
      let shadowScope = ImportFailureShadowWriteScope(shadowTables:
        try Self.importRecoveryShadowTables(databases: databases, in: db))
      db.add(transactionObserver: scope, extent: .nextTransaction)
      db.add(transactionObserver: shadowScope, extent: .nextTransaction)
      let changesBefore = try Int64.fetchOne(db, sql: "SELECT total_changes()")
      try db.execute(sql: "UPDATE paper SET cleanupDebt = 0 WHERE id = ? AND status = 'importFailed' AND deletionID IS NULL",
        arguments: [identity.paperID.uuidString])
      guard db.changesCount == 1 else { throw ImportRecoveryPersistenceError.staleHistory }
      let after = try Self.importRows(identity, in: db)
      let changesAfter = try Int64.fetchOne(db, sql: "SELECT total_changes()")
      try scope.validate()
      try shadowScope.validate()
      guard Self.sameRow(before.0, after.0, except: ["cleanupDebt"]),
        Self.sameRow(before.1, after.1), Int64.fromDatabaseValue(after.0["cleanupDebt"]) == 0,
        try Self.importFolder(identity.paperID, in: db) == folder,
        try Row.fetchAll(db, sql: "PRAGMA database_list") == databases,
        let changesBefore, let changesAfter, changesAfter - changesBefore == 1 else {
        throw ImportRecoveryPersistenceError.invalidHistory
      }
    }
  }

  /// Namespace absence is supplied by the actual owner. Completion/readback and
  /// privacy erasure share the same transaction; no acknowledged receipt registry.
  func finalizeJournaledDeletion(_ paperID: UUID, saga: UUID,
    expected: [ImportRecoveryRecord]) throws {
    try adapterWrite { db in
      let maximum = ProductJobRecovery.maximumImportRecoveryJournalBytes
      let jobs = try Row.fetchAll(db, sql: "SELECT id, typeof(recoveryJournal) AS payloadType FROM importJob WHERE paperID = ?",
        arguments: [paperID.uuidString])
      let journaled = jobs.filter { Self.recoveryString($0, "payloadType") != "null" }
      guard Set(journaled.compactMap { Self.recoveryString($0, "id") }) ==
        Set(try expected.map { try $0.journal.currentCapture().identity.jobID.uuidString }) else {
        throw ImportRecoveryPersistenceError.invalidHistory
      }
      for record in expected {
        try Self.validateExpectedRecovery(record)
        let capture = try record.journal.currentCapture()
        guard capture.identity.paperID == paperID,
          let pending = try record.journal.snapshot().pendingRemoval else {
          throw ImportRecoveryPersistenceError.invalidHistory
        }
        let completed = try record.journal.recording(.namespaceRemovalFinished(operation: pending, succeeded: true))
        _ = try Self.compareAndSwapImportRecoveryForDeletion(expected: record.encoded,
          replacement: completed, saga: saga, maximumBytes: maximum, in: db)
      }
      try Self.finalizeDeletionRows(paperID, saga: saga, in: db)
    }
  }

  /// Durable failure metadata only. Neither retained debt nor synthetic closure
  /// observations acknowledge physical cleanup or grant producer authority.
  func recordJournaledImportFailure(expected: ImportRecoveryRecord,
    replacement: ImportRecoveryJournal, failure: ImportAbortFailure,
    cleanupDebt: Bool) throws -> ImportRecoveryRecord {
    try adapterWrite { db in
      let maximum = ProductJobRecovery.maximumImportRecoveryJournalBytes
      try Self.recoveryBound(maximum)
      try Self.validateExpectedRecovery(expected)
      let bytes = try Self.recoveryEncode(replacement, maximumBytes: maximum)
      let capture = try expected.journal.currentCapture()
      let nextCapture = try replacement.currentCapture()
      let old = try expected.journal.snapshot()
      let next = try replacement.snapshot()
      guard Self.recoveryIDs(capture.identity) == Self.recoveryIDs(nextCapture.identity),
        capture.confirmedInput == nextCapture.confirmedInput,
        try replacement.extends(expected.journal, maximumBytes: maximum),
        old.current.state == .running, !old.revoked, !next.revoked,
        old.role == next.role, old.job == next.job, old.authority == next.authority,
        old.executions.count == next.executions.count,
        Array(old.executions.dropLast()) == Array(next.executions.dropLast()),
        old.current.lineage == next.current.lineage,
        old.current.dispatch == next.current.dispatch,
        old.current.result == next.current.result,
        next.current.state == .failed(.failed),
        old.usableResult == next.usableResult,
        old.usedPermitIDs == next.usedPermitIDs,
        cleanupDebt || (next.permits.isEmpty && next.removalDebt == nil && next.pendingRemoval == nil) else {
        throw ImportRecoveryPersistenceError.invalidHistory
      }
      let identity = capture.identity
      let current = try Self.readImportRecovery(identity, maximumBytes: maximum, in: db)
      guard current.encoded == expected.encoded else { throw ImportRecoveryPersistenceError.staleHistory }
      let row = try Self.recoveryRow(identity, maximumBytes: maximum, in: db)
      try Self.validateRecoveryExecution(expected.journal, row: row, identity: identity, revoked: false)
      _ = try Self.guardRunningImport(identity, in: db)
      let before = try Self.importRows(identity, in: db)
      let folder = try Self.importFolder(identity.paperID, in: db)
      guard let debt = Int64.fromDatabaseValue(before.0["cleanupDebt"]), debt == 0 || debt == 1 else {
        throw ImportRecoveryPersistenceError.invalidHistory
      }
      let retainedDebt = cleanupDebt || debt == 1
      guard let paperRowID = try Int64.fetchOne(db, sql: "SELECT rowid FROM main.paper WHERE id = ?",
        arguments: [identity.paperID.uuidString]),
        let jobRowID = try Int64.fetchOne(db, sql: "SELECT rowid FROM main.importJob WHERE id = ?",
          arguments: [identity.jobID.uuidString]),
        let schemaVersion = try Int64.fetchOne(db, sql: "PRAGMA main.schema_version") else {
        throw ImportRecoveryPersistenceError.invalidHistory
      }
      let databases = try Row.fetchAll(db, sql: "PRAGMA database_list")
      // Update hooks cannot observe WITHOUT ROWID writes. Admit only schemas
      // whose user tables satisfy the observer's rowid coverage prerequisite.
      let shadowTables = try Self.importRecoveryShadowTables(databases: databases, in: db)
      let scope = ImportFailureWriteScope(paperRowID: paperRowID, jobRowID: jobRowID)
      db.add(transactionObserver: scope, extent: .nextTransaction)
      let shadowScope = ImportFailureShadowWriteScope(shadowTables: shadowTables)
      db.add(transactionObserver: shadowScope, extent: .nextTransaction)
      let changesBefore = try Int64.fetchOne(db, sql: "SELECT total_changes()")
      // CAS must precede the existing running-only operational guard.
      let stored = try Self.compareAndSwapImportRecovery(expected: expected.encoded,
        replacement: replacement, maximumBytes: maximum, in: db)
      try Self.failRunningImport(identity, failure: failure.rawValue, cleanupDebt: retainedDebt, in: db)
      let readback = try Self.readImportRecovery(identity, maximumBytes: maximum, in: db)
      try Self.validateRecoveryExecution(readback.journal,
        row: Self.recoveryRow(identity, maximumBytes: maximum, in: db), identity: identity, revoked: false)
      let after = try Self.importRows(identity, in: db)
      let changesAfter = try Int64.fetchOne(db, sql: "SELECT total_changes()")
      try scope.validate()
      try shadowScope.validate()
      guard Self.sameRow(before.0, after.0, except: ["status", "pdfReference", "cleanupDebt"]),
        Self.sameRow(before.1, after.1, except: ["state", "failure", "recoveryJournal"]),
        Self.recoveryString(after.0, "status") == "importFailed",
        Self.nullColumns(after.0, ["pdfReference", "deletionID"]),
        Int64.fromDatabaseValue(after.0["cleanupDebt"]) == (retainedDebt ? 1 : 0),
        Self.recoveryString(after.1, "state") == "failed",
        Self.recoveryString(after.1, "failure") == failure.rawValue,
        try Self.importFolder(identity.paperID, in: db) == folder,
        try Int64.fetchOne(db, sql: "PRAGMA main.schema_version") == schemaVersion,
        try Row.fetchAll(db, sql: "PRAGMA database_list") == databases,
        // CAS + Paper failure + Job failure + the existing revokeReaderPosition
        // trigger's Paper UPDATE (even when its reader fields already equal NULL/0).
        // Whole-row checks above require those reader fields to remain unchanged.
        // Additional check only: row-scope observation rejects compensating writes.
        let changesBefore, let changesAfter, changesAfter - changesBefore == 4,
        stored.encoded == bytes, readback.encoded == bytes,
        try readback.journal.snapshot() == next else {
        throw ImportRecoveryPersistenceError.invalidHistory
      }
      return readback
    }
  }

  /// Late producer metadata only, after actual beginDeletion revoked a running Job.
  /// New cleanup operations belong to the separate deleting metadata boundary.
  func recordJournaledDeletingImportAbort(expected: ImportRecoveryRecord,
    replacement: ImportRecoveryJournal, saga: UUID, cleanupDebt: Bool) throws -> ImportRecoveryRecord {
    try adapterWrite { db in
      let maximum = ProductJobRecovery.maximumImportRecoveryJournalBytes
      try Self.recoveryBound(maximum)
      try Self.validateExpectedRecovery(expected)
      let bytes = try Self.recoveryEncode(replacement, maximumBytes: maximum)
      let capture = try expected.journal.currentCapture()
      let nextCapture = try replacement.currentCapture()
      let identity = capture.identity
      let old = try expected.journal.snapshot()
      let next = try replacement.snapshot()
      guard Self.recoveryIDs(identity) == Self.recoveryIDs(nextCapture.identity),
        capture.confirmedInput == nextCapture.confirmedInput,
        try replacement.extends(expected.journal, maximumBytes: maximum),
        old.revoked, next.revoked, old.current.state == .failed(.paperDeleting),
        old.role == next.role, old.job == next.job, old.authority == next.authority,
        old.executions == next.executions, old.usableResult == next.usableResult,
        old.usedPermitIDs == next.usedPermitIDs, old.usedOperationIDs == next.usedOperationIDs,
        old.pendingRemoval == next.pendingRemoval, old.removalDebt == next.removalDebt,
        old.removedPapers == next.removedPapers,
        cleanupDebt || (next.permits.isEmpty && next.removalDebt == nil && next.pendingRemoval == nil) else {
        throw ImportRecoveryPersistenceError.invalidHistory
      }
      let current = try Self.readImportRecoveryForDeletion(identity, saga: saga, maximumBytes: maximum, in: db)
      guard current.encoded == expected.encoded else { throw ImportRecoveryPersistenceError.staleHistory }
      let before = try Self.importRows(identity, in: db)
      let folder = try Self.importFolder(identity.paperID, in: db)
      guard Self.recoveryString(before.1, "state") == "failed",
        Self.recoveryString(before.1, "failure") == "paperDeleting",
        let debt = Int64.fromDatabaseValue(before.0["cleanupDebt"]), debt == 0 || debt == 1,
        let paperRowID = try Int64.fetchOne(db, sql: "SELECT rowid FROM main.paper WHERE id = ?",
          arguments: [identity.paperID.uuidString]),
        let jobRowID = try Int64.fetchOne(db, sql: "SELECT rowid FROM main.importJob WHERE id = ?",
          arguments: [identity.jobID.uuidString]),
        let schemaVersion = try Int64.fetchOne(db, sql: "PRAGMA main.schema_version") else {
        throw ImportRecoveryPersistenceError.invalidHistory
      }
      let retainedDebt = cleanupDebt || debt == 1
      let updateDebt = retainedDebt && debt == 0
      let databases = try Row.fetchAll(db, sql: "PRAGMA database_list")
      let shadowTables = try Self.importRecoveryShadowTables(databases: databases, in: db)
      let scope = ImportFailureWriteScope(paperRowID: paperRowID, jobRowID: jobRowID)
      let shadowScope = ImportFailureShadowWriteScope(shadowTables: shadowTables)
      db.add(transactionObserver: scope, extent: .nextTransaction)
      db.add(transactionObserver: shadowScope, extent: .nextTransaction)
      let changesBefore = try Int64.fetchOne(db, sql: "SELECT total_changes()")
      let stored = try Self.compareAndSwapImportRecoveryForDeletion(expected: expected.encoded,
        replacement: replacement, saga: saga, maximumBytes: maximum, in: db)
      if updateDebt {
        let ids = Self.recoveryIDs(identity)
        try db.execute(sql: """
          UPDATE paper SET cleanupDebt = 1
          WHERE id = ? AND generation = ? AND status = 'deleting' AND deletionID = ? AND cleanupDebt = 0
            AND EXISTS (SELECT 1 FROM importJob j WHERE j.paperID = paper.id AND j.id = ?
              AND j.attempt = ? AND j.fence = ? AND j.correlation = ? AND j.input = ?
              AND j.epoch = ? AND j.writer = ? AND j.publication = ?
              AND j.state = 'failed' AND j.failure = 'paperDeleting' AND j.recoveryJournal IS ?)
          """, arguments: [ids[0], ids[1], saga.uuidString, ids[2], ids[3], ids[4], ids[5],
            ids[6], ids[7], ids[8], ids[9], bytes])
        guard db.changesCount == 1 else { throw ImportRecoveryPersistenceError.staleHistory }
      }
      let readback = try Self.readImportRecoveryForDeletion(identity, saga: saga, maximumBytes: maximum, in: db)
      let after = try Self.importRows(identity, in: db)
      let changesAfter = try Int64.fetchOne(db, sql: "SELECT total_changes()")
      try scope.validate()
      try shadowScope.validate()
      guard Self.sameRow(before.0, after.0, except: ["cleanupDebt"]),
        Self.sameRow(before.1, after.1, except: ["recoveryJournal"]),
        Int64.fromDatabaseValue(after.0["cleanupDebt"]) == (retainedDebt ? 1 : 0),
        try Self.importFolder(identity.paperID, in: db) == folder,
        try Int64.fetchOne(db, sql: "PRAGMA main.schema_version") == schemaVersion,
        try Row.fetchAll(db, sql: "PRAGMA database_list") == databases,
        // CAS plus optional debt-only UPDATE. No status UPDATE / Reader trigger.
        // Additional check, never a substitute for public row/shadow observation.
        let changesBefore, let changesAfter, changesAfter - changesBefore == (updateDebt ? 2 : 1),
        stored.encoded == bytes, readback.encoded == bytes,
        try readback.journal.snapshot() == next else {
        throw ImportRecoveryPersistenceError.invalidHistory
      }
      return readback
    }
  }

  private static func importRecoveryShadowTables(databases: [Row], in db: Database) throws -> Set<String> {
    let tables = try Row.fetchAll(db, sql: "PRAGMA table_list")
    guard !tables.isEmpty else { throw ImportRecoveryPersistenceError.invalidHistory }
    var listedSchemas = Set<String>()
    var shadowTables = Set<String>()
    for table in tables {
      guard table.hasColumn("wr"), let schema = recoveryString(table, "schema"),
        let name = recoveryString(table, "name"), let type = recoveryString(table, "type"),
        ["table", "view", "virtual", "shadow"].contains(type),
        case .int64(let withoutRowID) = (table["wr"] as DatabaseValue).storage,
        withoutRowID == 0 || withoutRowID == 1,
        name.hasPrefix("sqlite_") || type == "shadow" || withoutRowID == 0 else {
        throw ImportRecoveryPersistenceError.invalidHistory
      }
      if type == "shadow" { shadowTables.insert(name.lowercased()) }
      listedSchemas.insert(schema)
    }
    for database in databases {
      guard let name = recoveryString(database, "name"), listedSchemas.contains(name) else {
        throw ImportRecoveryPersistenceError.invalidHistory
      }
    }
    return shadowTables
  }

  private static func validateExpectedRecovery(_ expected: ImportRecoveryRecord) throws {
    guard try recoveryEncode(expected.journal,
      maximumBytes: ProductJobRecovery.maximumImportRecoveryJournalBytes) == expected.encoded else {
      throw ImportRecoveryPersistenceError.invalidHistory
    }
  }

  private static func importRows(_ identity: ImportIdentity, in db: Database) throws -> (Row, Row) {
    guard let paper = try Row.fetchOne(db, sql: "SELECT * FROM paper WHERE id = ?",
      arguments: [identity.paperID.uuidString]),
      let job = try Row.fetchOne(db, sql: "SELECT * FROM importJob WHERE id = ?",
        arguments: [identity.jobID.uuidString]) else { throw ImportRecoveryPersistenceError.missingHistory }
    return (paper, job)
  }

  private static func nullColumns(_ row: Row, _ columns: [String]) -> Bool {
    columns.allSatisfy { name in
      let value: DatabaseValue = row[name]
      return value.isNull
    }
  }

  private static func sameRow(_ before: Row, _ after: Row, except ignored: Set<String> = []) -> Bool {
    guard Array(before.columnNames) == Array(after.columnNames) else { return false }
    return before.columnNames.filter { !ignored.contains($0) }.allSatisfy { name in
      let old: DatabaseValue = before[name]
      let new: DatabaseValue = after[name]
      return old.storage == new.storage
    }
  }

  private static func importFolder(_ paperID: UUID, in db: Database) throws -> String? {
    try String.fetchOne(db, sql: "SELECT folderID FROM paperFolder WHERE paperID = ?",
      arguments: [paperID.uuidString])
  }

  private static func closedStageDestination(_ stage: ClosedImportStage, identity: ImportIdentity,
    root: URL) throws -> URL {
    var rootInfo = stat()
    guard lstat(root.path, &rootInfo) == 0, rootInfo.st_mode & S_IFMT == S_IFDIR,
      rootInfo.st_uid == geteuid() else { throw ProductDatabaseError.unsafeRoot }
    let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
    let papers = canonicalRoot.appendingPathComponent("papers", isDirectory: true)
    let namespace = papers.appendingPathComponent(identity.paperID.uuidString, isDirectory: true)
    let file = stage.file
    guard file.isFileURL, file.host == nil || file.host == "" || file.host == "localhost",
      !file.path.utf8.contains(0), file.query == nil, file.fragment == nil,
      file.standardizedFileURL.path == file.path, file.resolvingSymlinksInPath().path == file.path,
      file.deletingLastPathComponent().path == namespace.path,
      !["", ".", "..", "document.pdf"].contains(file.lastPathComponent) else {
      throw ProductDatabaseError.unsafeRoot
    }
    for directory in [canonicalRoot, papers, namespace] {
      var info = stat()
      guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
        info.st_uid == geteuid() else { throw ProductDatabaseError.unsafeRoot }
    }
    var info = stat()
    guard lstat(file.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
      info.st_uid == geteuid(), info.st_nlink == 1, info.st_mode & 0o7777 == 0o400,
      info.st_size == stage.bytes else { throw ProductDatabaseError.unsafeRoot }
    let final = namespace.appendingPathComponent("document.pdf")
    var existing = stat()
    guard lstat(final.path, &existing) != 0, errno == ENOENT else {
      throw ProductDatabaseError.unsafeRoot
    }
    // These checks do not isolate against hostile same-UID in-place/path races.
    return final
  }

  static func registerImportRecoveryMigrations(in migrator: inout DatabaseMigrator) {
    migrator.registerMigration("importRecoveryJournalV1") { db in
      try db.execute(sql: "ALTER TABLE importJob ADD COLUMN recoveryJournal BLOB")
    }
  }

  /// Internal new-reservation hook only. The reservation owner must call this in its
  /// existing insertion transaction; never use it to backfill a legacy NULL history.
  static func initializeImportRecovery(_ journal: ImportRecoveryJournal,
    maximumBytes: Int, in db: Database) throws {
    try recoveryBound(maximumBytes)
    let bytes = try recoveryEncode(journal, maximumBytes: maximumBytes)
    let capture = try journal.currentCapture()
    let identity = capture.identity
    let row = try recoveryRow(identity, maximumBytes: maximumBytes, in: db)
    try validateRecoveryRow(row, identity: identity)
    guard recoveryString(row, "payloadType") == "null" else {
      throw ImportRecoveryPersistenceError.staleHistory
    }
    let initial = try ImportRecoveryJournal(identity: identity, confirmedInput: capture.confirmedInput)
    let admitted: ImportRecoveryJournal
    switch recoveryString(row, "jobState") {
    case "pending": admitted = initial
    case "running": admitted = try initial.recording(.claim(initial.snapshot().current.lineage))
    default: throw ImportRecoveryPersistenceError.invalidHistory
    }
    guard bytes == (try recoveryEncode(admitted, maximumBytes: maximumBytes)),
      recoveryString(row, "paperStatus") == "importing" else {
      throw ImportRecoveryPersistenceError.invalidHistory
    }
    try recoveryUpdate(identity, expected: nil, replacement: bytes, in: db)
    let stored = try readImportRecovery(identity, maximumBytes: maximumBytes, in: db)
    guard stored.encoded == bytes else { throw ImportRecoveryPersistenceError.invalidHistory }
  }

  static func readImportRecovery(_ identity: ImportIdentity,
    maximumBytes: Int, in db: Database) throws -> ImportRecoveryRecord {
    try recoveryBound(maximumBytes)
    let row = try recoveryRow(identity, maximumBytes: maximumBytes, in: db)
    try validateRecoveryRow(row, identity: identity)
    let record = try recoveryRecord(row, identity: identity, maximumBytes: maximumBytes)
    if recoveryString(row, "paperStatus") == "importFailed",
      recoveryString(row, "jobState") == "succeeded" {
      try validateRecoveryExecution(record.journal, row: row, identity: identity, revoked: false)
    }
    return record
  }

  /// Missing bytes change availability, not the committed execution. NULL legacy
  /// history remains a separate path and is never reconstructed from these rows.
  static func reconcileUnavailableImport(_ paperID: UUID, reference: String,
    in db: Database) throws {
    guard let before = try Row.fetchOne(db, sql: "SELECT * FROM paper WHERE id = ?",
      arguments: [paperID.uuidString]), recoveryString(before, "status") == "ready",
      recoveryString(before, "pdfReference") == reference, nullColumns(before, ["deletionID"]) else {
      throw ProductJobRecoveryError.recoveryConflict
    }
    let jobs = try boundedDeletionJobs(paperID, in: db)
    let histories = try jobs.map { job -> ImportRecoveryRecord? in
      guard let jobID = recoveryString(job, "id") else {
        throw ImportRecoveryPersistenceError.invalidHistory
      }
      let record = try readImportRecoveryForAdmission(jobID: jobID, saga: nil, in: db)
      if let record {
        guard try record.journal.snapshot().current.state == .succeeded else {
          throw ImportRecoveryPersistenceError.invalidHistory
        }
      }
      return record
    }
    let folder = try importFolder(paperID, in: db)
    try db.execute(sql: """
      UPDATE paper SET status = 'importFailed', pdfReference = NULL, cleanupDebt = 1
      WHERE id = ? AND status = 'ready' AND pdfReference = ? AND deletionID IS NULL
      """, arguments: [paperID.uuidString, reference])
    guard db.changesCount == 1 else { throw ProductJobRecoveryError.recoveryConflict }
    try db.execute(sql: """
      UPDATE importJob SET state = 'failed', failure = 'missingPDF'
      WHERE paperID = ? AND recoveryJournal IS NULL
      """, arguments: [paperID.uuidString])
    guard db.changesCount == histories.filter({ $0 == nil }).count,
      let after = try Row.fetchOne(db, sql: "SELECT * FROM paper WHERE id = ?",
        arguments: [paperID.uuidString]),
      sameRow(before, after, except: ["status", "pdfReference", "cleanupDebt"]),
      recoveryString(after, "status") == "importFailed", nullColumns(after, ["pdfReference"]),
      Int64.fromDatabaseValue(after["cleanupDebt"]) == 1,
      try importFolder(paperID, in: db) == folder else {
      throw ProductJobRecoveryError.readbackMismatch
    }
    let readback = try boundedDeletionJobs(paperID, in: db)
    guard jobs.count == readback.count else { throw ProductJobRecoveryError.readbackMismatch }
    for (index, pair) in zip(jobs, readback).enumerated() {
      if let history = histories[index] {
        let record = try readUnavailableSucceededImport(jobID: history.journal.currentCapture().identity.jobID.uuidString,
          in: db)
        guard sameRow(pair.0, pair.1), record.encoded == history.encoded else {
          throw ProductJobRecoveryError.readbackMismatch
        }
      } else {
        guard sameRow(pair.0, pair.1, except: ["state", "failure"]),
          recoveryString(pair.1, "state") == "failed",
          recoveryString(pair.1, "failure") == "missingPDF", nullColumns(pair.1, ["recoveryJournal"]) else {
          throw ProductJobRecoveryError.readbackMismatch
        }
      }
    }
  }

  static func readUnavailableSucceededImport(jobID: String, in db: Database) throws -> ImportRecoveryRecord {
    let record = try readImportRecoveryForAdmission(jobID: jobID, saga: nil, in: db)
    guard let record else { throw ImportRecoveryPersistenceError.missingHistory }
    let identity = try record.journal.currentCapture().identity
    let row = try recoveryRow(identity,
      maximumBytes: ProductJobRecovery.maximumImportRecoveryJournalBytes, in: db)
    guard try record.journal.snapshot().current.state == .succeeded,
      unavailableSucceededImportRow(row) else { throw ImportRecoveryPersistenceError.invalidHistory }
    return record
  }

  private static func unavailableSucceededImportRow(_ row: Row) -> Bool {
    guard recoveryString(row, "paperStatus") == "importFailed",
      recoveryString(row, "jobState") == "succeeded",
      nullColumns(row, ["pdfReference", "deletionID", "jobFailure"]),
      Int64.fromDatabaseValue(row["cleanupDebt"]) == 1,
      let sha = recoveryString(row, "pdfSHA256"), sha.utf8.count == 64,
      sha.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return false }
    return true
  }

  private static func recoveryRecord(_ row: Row, identity: ImportIdentity,
    maximumBytes: Int) throws -> ImportRecoveryRecord {
    if recoveryString(row, "payloadType") == "null" {
      throw ImportRecoveryPersistenceError.missingHistory
    }
    // CASE in SQL refuses to materialize anything except an in-bound BLOB.
    guard recoveryString(row, "payloadType") == "blob",
      let bytes = Data.fromDatabaseValue(row["payload"]), !bytes.isEmpty else {
      throw ImportRecoveryPersistenceError.invalidHistory
    }
    let journal = try recoveryDecode(bytes, maximumBytes: maximumBytes)
    guard recoveryIDs(try journal.currentCapture().identity) == recoveryIDs(identity) else {
      throw ImportRecoveryPersistenceError.invalidHistory
    }
    return ImportRecoveryRecord(journal: journal, encoded: bytes)
  }

  /// Ordinary metadata append only. Retry's execution-column transition belongs
  /// to the reservation owner, not to this journal-only update.
  static func compareAndSwapImportRecovery(expected: Data, replacement: ImportRecoveryJournal,
    maximumBytes: Int, in db: Database) throws -> ImportRecoveryRecord {
    try recoveryBound(maximumBytes)
    let previous = try recoveryDecode(expected, maximumBytes: maximumBytes)
    let oldCapture = try previous.currentCapture()
    let newCapture = try replacement.currentCapture()
    guard recoveryIDs(oldCapture.identity) == recoveryIDs(newCapture.identity),
      oldCapture.confirmedInput == newCapture.confirmedInput else {
      throw ImportRecoveryPersistenceError.invalidHistory
    }
    let bytes = try recoveryEncode(replacement, maximumBytes: maximumBytes)
    guard try replacement.extends(previous, maximumBytes: maximumBytes) else {
      throw ImportRecoveryPersistenceError.invalidHistory
    }
    let stored = try readImportRecovery(oldCapture.identity, maximumBytes: maximumBytes, in: db)
    guard stored.encoded == expected else { throw ImportRecoveryPersistenceError.staleHistory }
    try recoveryUpdate(oldCapture.identity, expected: expected, replacement: bytes, in: db)
    let readback = try readImportRecovery(oldCapture.identity, maximumBytes: maximumBytes, in: db)
    guard readback.encoded == bytes else { throw ImportRecoveryPersistenceError.invalidHistory }
    return readback
  }

  /// Deletion metadata only, inside the caller's transaction. Revocation is not
  /// physical producer closure, and retained success/failure is not a new grant.
  static func readImportRecoveryForDeletion(_ identity: ImportIdentity, saga: UUID,
    maximumBytes: Int, in db: Database) throws -> ImportRecoveryRecord {
    try recoveryBound(maximumBytes)
    let row = try recoveryRow(identity, maximumBytes: maximumBytes, in: db)
    try validateRecoveryIdentity(row, identity: identity)
    guard recoveryString(row, "paperStatus") == "deleting",
      recoveryString(row, "deletionID") == saga.uuidString else {
      throw ImportRecoveryPersistenceError.invalidHistory
    }
    let record = try recoveryRecord(row, identity: identity, maximumBytes: maximumBytes)
    try validateDeletingExecution(record.journal, row: row, identity: identity)
    return record
  }

  static func compareAndSwapImportRecoveryForDeletion(expected: Data,
    replacement: ImportRecoveryJournal, saga: UUID, maximumBytes: Int,
    in db: Database) throws -> ImportRecoveryRecord {
    try recoveryBound(maximumBytes)
    let previous = try recoveryDecode(expected, maximumBytes: maximumBytes)
    let oldCapture = try previous.currentCapture()
    let newCapture = try replacement.currentCapture()
    let oldSnapshot = try previous.snapshot()
    let newSnapshot = try replacement.snapshot()
    let bytes = try recoveryEncode(replacement, maximumBytes: maximumBytes)
    guard recoveryIDs(oldCapture.identity) == recoveryIDs(newCapture.identity),
      oldCapture.confirmedInput == newCapture.confirmedInput,
      oldSnapshot.revoked, newSnapshot.revoked,
      oldSnapshot.executions == newSnapshot.executions,
      oldSnapshot.usedPermitIDs == newSnapshot.usedPermitIDs,
      try replacement.extends(previous, maximumBytes: maximumBytes) else {
      throw ImportRecoveryPersistenceError.invalidHistory
    }
    let identity = oldCapture.identity
    let stored = try readImportRecoveryForDeletion(identity, saga: saga,
      maximumBytes: maximumBytes, in: db)
    guard stored.encoded == expected else { throw ImportRecoveryPersistenceError.staleHistory }
    let before = try deletionRecoveryRows(identity, maximumBytes: maximumBytes, in: db)
    let ids = recoveryIDs(identity)
    try db.execute(sql: """
      UPDATE importJob SET recoveryJournal = ?
      WHERE recoveryJournal IS ? AND id = ? AND paperID = ? AND attempt = ? AND fence = ?
        AND correlation = ? AND input = ? AND epoch = ? AND writer = ? AND publication = ?
        AND EXISTS (SELECT 1 FROM paper p WHERE p.id = importJob.paperID AND p.generation = ?
          AND p.status = 'deleting' AND p.deletionID = ?)
      """, arguments: [bytes, expected, ids[2], ids[0], ids[3], ids[4], ids[5], ids[6],
        ids[7], ids[8], ids[9], ids[1], saga.uuidString])
    guard db.changesCount == 1 else { throw ImportRecoveryPersistenceError.staleHistory }
    let readback = try readImportRecoveryForDeletion(identity, saga: saga,
      maximumBytes: maximumBytes, in: db)
    let after = try deletionRecoveryRows(identity, maximumBytes: maximumBytes, in: db)
    guard readback.encoded == bytes, sameRow(before.0, after.0),
      sameRow(before.1, after.1, except: ["recoveryJournal"]) else {
      throw ImportRecoveryPersistenceError.invalidHistory
    }
    return readback
  }

  /// Availability/deletion admission; a deleting row requires the actual saga.
  /// Ordinary and deleting guards remain distinct. NULL is explicit legacy history.
  static func readImportRecoveryForAdmission(jobID: String, saga: UUID?,
    in db: Database) throws -> ImportRecoveryRecord? {
    let maximum = ProductJobRecovery.maximumImportRecoveryJournalBytes
    guard let payload = try Row.fetchOne(db, sql: """
      SELECT typeof(recoveryJournal) AS payloadType,
        CASE WHEN typeof(recoveryJournal) = 'blob' AND length(recoveryJournal) <= ?
          THEN recoveryJournal ELSE NULL END AS payload
      FROM importJob WHERE id = ?
      """, arguments: [maximum, jobID]) else { throw ImportRecoveryPersistenceError.missingHistory }
    if recoveryString(payload, "payloadType") == "null" { return nil }
    guard recoveryString(payload, "payloadType") == "blob",
      let bytes = Data.fromDatabaseValue(payload["payload"]), !bytes.isEmpty else {
      throw ImportRecoveryPersistenceError.invalidHistory
    }
    let journal = try recoveryDecode(bytes, maximumBytes: maximum)
    let identity = try journal.currentCapture().identity
    guard identity.jobID.uuidString == jobID else { throw ImportRecoveryPersistenceError.invalidHistory }
    let row = try recoveryRow(identity, maximumBytes: maximum, in: db)
    try validateRecoveryIdentity(row, identity: identity)
    let record: ImportRecoveryRecord
    if ["deleting", "deletionFailed"].contains(recoveryString(row, "paperStatus") ?? "") {
      guard let saga, recoveryString(row, "deletionID") == saga.uuidString else {
        throw ImportRecoveryPersistenceError.invalidHistory
      }
      record = try recoveryRecord(row, identity: identity, maximumBytes: maximum)
      try validateDeletingExecution(record.journal, row: row, identity: identity)
    } else {
      record = try readImportRecovery(identity, maximumBytes: maximum, in: db)
      try validateRecoveryExecution(record.journal, row: row, identity: identity, revoked: false)
    }
    guard record.encoded == bytes else { throw ImportRecoveryPersistenceError.staleHistory }
    return record
  }

  /// Sole beginDeletion transition: old bytes were admitted BEFORE operational
  /// mutation. Do not route through deleting CAS, whose old journal is revoked.
  static func revokeImportRecoveryForBeginDeletion(_ previous: ImportRecoveryRecord,
    saga: UUID, in db: Database) throws -> ImportRecoveryRecord {
    let maximum = ProductJobRecovery.maximumImportRecoveryJournalBytes
    try validateExpectedRecovery(previous)
    let identity = try previous.journal.currentCapture().identity
    let replacement = try previous.journal.recording(.revoke)
    try LocalLibraryLifecycle.preflight(replacement)
    let bytes = try recoveryEncode(replacement, maximumBytes: maximum)
    guard try replacement.extends(previous.journal, maximumBytes: maximum) else {
      throw ImportRecoveryPersistenceError.invalidHistory
    }
    let row = try recoveryRow(identity, maximumBytes: maximum, in: db)
    try validateRecoveryIdentity(row, identity: identity)
    guard recoveryString(row, "paperStatus") == "deleting",
      recoveryString(row, "deletionID") == saga.uuidString,
      try recoveryRecord(row, identity: identity, maximumBytes: maximum).encoded == previous.encoded else {
      throw ImportRecoveryPersistenceError.staleHistory
    }
    try validateDeletingExecution(replacement, row: row, identity: identity)
    let before = try deletionRecoveryRows(identity, maximumBytes: maximum, in: db)
    let ids = recoveryIDs(identity)
    try db.execute(sql: """
      UPDATE importJob SET recoveryJournal = ?
      WHERE recoveryJournal IS ? AND id = ? AND paperID = ? AND attempt = ? AND fence = ?
        AND correlation = ? AND input = ? AND epoch = ? AND writer = ? AND publication = ?
        AND EXISTS (SELECT 1 FROM paper p WHERE p.id = importJob.paperID AND p.generation = ?
          AND p.status = 'deleting' AND p.deletionID = ?)
      """, arguments: [bytes, previous.encoded, ids[2], ids[0], ids[3], ids[4], ids[5], ids[6],
        ids[7], ids[8], ids[9], ids[1], saga.uuidString])
    guard db.changesCount == 1 else { throw ImportRecoveryPersistenceError.staleHistory }
    let readback = try readImportRecoveryForDeletion(identity, saga: saga, maximumBytes: maximum, in: db)
    let after = try deletionRecoveryRows(identity, maximumBytes: maximum, in: db)
    guard readback.encoded == bytes, sameRow(before.0, after.0),
      sameRow(before.1, after.1, except: ["recoveryJournal"]) else {
      throw ImportRecoveryPersistenceError.invalidHistory
    }
    return readback
  }

  private static func validateDeletingExecution(_ journal: ImportRecoveryJournal,
    row: Row, identity: ImportIdentity) throws {
    try validateRecoveryExecution(journal, row: row, identity: identity, revoked: true)
  }

  private static func validateRecoveryExecution(_ journal: ImportRecoveryJournal,
    row: Row, identity: ImportIdentity, revoked: Bool) throws {
    let snapshot = try journal.snapshot()
    let captured = JobRecoveryPolicy.Authority(input: .source(version: identity.input.uuidString),
      config: .inapplicable, paper: .init(id: identity.paperID.uuidString,
        generation: identity.generation.uuidString), epoch: identity.epoch.uuidString,
      prerequisitesAvailable: true)
    let lineage = JobRecoveryPolicy.Lineage(job: identity.jobID.uuidString,
      reservation: .init(attempt: identity.attempt.uuidString, fence: identity.fence.uuidString,
        correlation: identity.correlation.uuidString), captured: captured)
    guard snapshot.role == .import, snapshot.job == identity.jobID.uuidString,
      snapshot.revoked == revoked, snapshot.current.lineage == lineage else {
      throw ImportRecoveryPersistenceError.invalidHistory
    }
    switch snapshot.current.state {
    case .succeeded:
      guard (revoked || recoveryString(row, "paperStatus") == "ready" || unavailableSucceededImportRow(row)),
        recoveryString(row, "jobState") == "succeeded", nullColumns(row, ["jobFailure"]) else {
        throw ImportRecoveryPersistenceError.invalidHistory
      }
    case .failed(let failure):
      guard (revoked || recoveryString(row, "paperStatus") == "importFailed"),
        recoveryString(row, "jobState") == "failed",
        let code = recoveryString(row, "jobFailure"), deletionRecoveryFailure(code) == failure else {
        throw ImportRecoveryPersistenceError.invalidHistory
      }
    case .pending: throw ImportRecoveryPersistenceError.invalidHistory
    case .running:
      guard !revoked, recoveryString(row, "paperStatus") == "importing",
        recoveryString(row, "jobState") == "running",
        nullColumns(row, ["jobFailure"]) else { throw ImportRecoveryPersistenceError.invalidHistory }
    }
  }

  // LocalLibraryLifecycle terminates with .failed for each of these fixed abort
  // codes, including cancellation. Startup uses .interrupted; beginDeletion uses
  // .paperDeleting only for an active execution. Never parse arbitrary row reasons.
  private static func deletionRecoveryFailure(_ code: String) -> JobRecoveryPolicy.Failure? {
    switch code {
    case "importFailed", "urlImportFailed", "sourceChanged", "publicationRejected", "cancelled": return .failed
    case "interrupted": return .interrupted
    case "paperDeleting": return .paperDeleting
    default: return nil
    }
  }

  private static func deletionRecoveryRows(_ identity: ImportIdentity, maximumBytes: Int,
    in db: Database) throws -> (Row, Row) {
    guard let paper = try Row.fetchOne(db, sql: "SELECT * FROM paper WHERE id = ?",
      arguments: [identity.paperID.uuidString]),
      let job = try Row.fetchOne(db, sql: """
        SELECT id, paperID, attempt, fence, correlation, input, epoch, writer, publication,
          state, bytesCopied, failure,
          CASE WHEN typeof(recoveryJournal) = 'blob' AND length(recoveryJournal) <= ?
            THEN recoveryJournal ELSE NULL END AS recoveryJournal
        FROM importJob WHERE id = ?
        """, arguments: [maximumBytes, identity.jobID.uuidString]) else {
      throw ImportRecoveryPersistenceError.missingHistory
    }
    return (paper, job)
  }

  private static func recoveryBound(_ maximumBytes: Int) throws {
    guard maximumBytes > 0 else { throw ImportRecoveryPersistenceError.invalidHistory }
  }

  private static func recoveryEncode(_ journal: ImportRecoveryJournal,
    maximumBytes: Int) throws -> Data {
    do { return try journal.encoded(maximumBytes: maximumBytes) }
    catch { throw ImportRecoveryPersistenceError.invalidHistory }
  }

  private static func recoveryDecode(_ bytes: Data, maximumBytes: Int) throws -> ImportRecoveryJournal {
    do { return try ImportRecoveryJournal.decode(bytes, maximumBytes: maximumBytes) }
    catch { throw ImportRecoveryPersistenceError.invalidHistory }
  }

  private static func recoveryIDs(_ identity: ImportIdentity) -> [String] {
    [identity.paperID, identity.generation, identity.jobID, identity.attempt, identity.fence,
      identity.correlation, identity.input, identity.epoch, identity.writer, identity.publication]
      .map(\.uuidString)
  }

  private static func recoveryString(_ row: Row, _ name: String) -> String? {
    let value: DatabaseValue = row[name]
    guard case .string(let string) = value.storage else { return nil }
    return string
  }

  private static func recoveryRow(_ identity: ImportIdentity, maximumBytes: Int,
    in db: Database) throws -> Row {
    guard let row = try Row.fetchOne(db, sql: """
      SELECT p.id AS paperID, p.generation, j.id AS jobID, j.attempt, j.fence,
        j.correlation, j.input, j.epoch, j.writer, j.publication,
        p.status AS paperStatus, p.deletionID, p.pdfReference, p.pdfSHA256, p.cleanupDebt,
        j.state AS jobState, j.failure AS jobFailure,
        typeof(j.recoveryJournal) AS payloadType,
        CASE WHEN typeof(j.recoveryJournal) = 'blob' AND length(j.recoveryJournal) <= ?
          THEN j.recoveryJournal ELSE NULL END AS payload
      FROM importJob j JOIN paper p ON p.id = j.paperID WHERE j.id = ?
      """, arguments: [maximumBytes, identity.jobID.uuidString]) else {
      throw ImportRecoveryPersistenceError.missingHistory
    }
    return row
  }

  private static func validateRecoveryRow(_ row: Row, identity: ImportIdentity) throws {
    try validateRecoveryIdentity(row, identity: identity)
    let deletion: DatabaseValue = row["deletionID"]
    guard deletion.isNull,
      let status = recoveryString(row, "paperStatus"),
      ["importing", "ready", "importFailed"].contains(status),
      let state = recoveryString(row, "jobState"),
      ["pending", "running", "succeeded", "failed"].contains(state) else {
      throw ImportRecoveryPersistenceError.invalidHistory
    }
  }

  private static func validateRecoveryIdentity(_ row: Row, identity: ImportIdentity) throws {
    let names = ["paperID", "generation", "jobID", "attempt", "fence", "correlation",
      "input", "epoch", "writer", "publication"]
    var actual: [String] = []
    for name in names {
      guard let value = recoveryString(row, name), UUID(uuidString: value)?.uuidString == value else {
        throw ImportRecoveryPersistenceError.invalidHistory
      }
      actual.append(value)
    }
    guard actual == recoveryIDs(identity) else { throw ImportRecoveryPersistenceError.staleHistory }
  }

  private static func recoveryUpdate(_ identity: ImportIdentity, expected: Data?,
    replacement: Data, in db: Database) throws {
    let ids = recoveryIDs(identity)
    try db.execute(sql: """
      UPDATE importJob SET recoveryJournal = ?
      WHERE recoveryJournal IS ? AND id = ? AND paperID = ? AND attempt = ? AND fence = ?
        AND correlation = ? AND input = ? AND epoch = ? AND writer = ? AND publication = ?
        AND EXISTS (SELECT 1 FROM paper p WHERE p.id = importJob.paperID AND p.generation = ?
          AND p.deletionID IS NULL AND p.status IN ('importing', 'ready', 'importFailed'))
      """, arguments: [replacement, expected, ids[2], ids[0], ids[3], ids[4], ids[5], ids[6],
        ids[7], ids[8], ids[9], ids[1]])
    guard db.changesCount == 1 else { throw ImportRecoveryPersistenceError.staleHistory }
  }
}
