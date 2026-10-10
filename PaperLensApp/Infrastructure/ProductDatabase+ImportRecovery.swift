import Foundation
import GRDB
import Darwin

/// Stored attestations only: neither this record nor its replay grants physical authority.
struct ImportRecoveryRecord: Sendable {
  let journal: ImportRecoveryJournal
  let encoded: Data
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

extension ProductDatabase {
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
    closedStage: ClosedImportStage) throws -> ImportRecoveryRecord {
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
    return try recoveryRecord(row, identity: identity, maximumBytes: maximumBytes)
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

  private static func validateDeletingExecution(_ journal: ImportRecoveryJournal,
    row: Row, identity: ImportIdentity) throws {
    let snapshot = try journal.snapshot()
    let captured = JobRecoveryPolicy.Authority(input: .source(version: identity.input.uuidString),
      config: .inapplicable, paper: .init(id: identity.paperID.uuidString,
        generation: identity.generation.uuidString), epoch: identity.epoch.uuidString,
      prerequisitesAvailable: true)
    let lineage = JobRecoveryPolicy.Lineage(job: identity.jobID.uuidString,
      reservation: .init(attempt: identity.attempt.uuidString, fence: identity.fence.uuidString,
        correlation: identity.correlation.uuidString), captured: captured)
    guard snapshot.role == .import, snapshot.job == identity.jobID.uuidString,
      snapshot.revoked, snapshot.current.lineage == lineage else {
      throw ImportRecoveryPersistenceError.invalidHistory
    }
    switch snapshot.current.state {
    case .succeeded:
      guard recoveryString(row, "jobState") == "succeeded", nullColumns(row, ["jobFailure"]) else {
        throw ImportRecoveryPersistenceError.invalidHistory
      }
    case .failed(let failure):
      guard recoveryString(row, "jobState") == "failed",
        let code = recoveryString(row, "jobFailure"), deletionRecoveryFailure(code) == failure else {
        throw ImportRecoveryPersistenceError.invalidHistory
      }
    case .pending, .running: throw ImportRecoveryPersistenceError.invalidHistory
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
        p.status AS paperStatus, p.deletionID, j.state AS jobState, j.failure AS jobFailure,
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
