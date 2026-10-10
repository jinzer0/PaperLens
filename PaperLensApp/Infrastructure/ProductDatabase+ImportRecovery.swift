import Foundation
import GRDB

/// Stored attestations only: neither this record nor its replay grants physical authority.
struct ImportRecoveryRecord: Sendable {
  let journal: ImportRecoveryJournal
  let encoded: Data
}

enum ImportRecoveryPersistenceError: Error, Equatable {
  case missingHistory, staleHistory, invalidHistory
}

extension ProductDatabase {
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
        p.status AS paperStatus, p.deletionID, j.state AS jobState,
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
    let deletion: DatabaseValue = row["deletionID"]
    guard deletion.isNull,
      let status = recoveryString(row, "paperStatus"),
      ["importing", "ready", "importFailed"].contains(status),
      let state = recoveryString(row, "jobState"),
      ["pending", "running", "succeeded", "failed"].contains(state) else {
      throw ImportRecoveryPersistenceError.invalidHistory
    }
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
