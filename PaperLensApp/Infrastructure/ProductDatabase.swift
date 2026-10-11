import Foundation
import GRDB

public struct ProviderConfiguration: Equatable, Sendable {
  public let slotID: UUID?
  public let generation: Int64
  public let model: String?
  public init(slotID: UUID?, generation: Int64, model: String?) {
    self.slotID = slotID
    self.generation = generation
    self.model = model
  }
}

public enum LibraryStatus: String, Hashable, Sendable {
  case importing, ready, importFailed, deleting, deletionFailed, tombstone
}

public struct LibraryRecord: Identifiable, Equatable, Sendable {
  public let id: UUID
  public let title: String
  public let status: LibraryStatus
  public let bytesCopied: Int64
  public let failure: String?
  public let cleanupDebt: Bool
}

public enum ProductDatabaseError: Error, Equatable, Sendable {
  case staleConfiguration, staleImport, invalidRecord, unsafeRoot, generationExhausted
}

struct ImportIdentity: Sendable {
  let paperID: UUID
  let generation: UUID
  let jobID: UUID
  let attempt: UUID
  let fence: UUID
  let correlation: UUID
  let input: UUID
  let epoch: UUID
  let writer: UUID
  let publication: UUID
}

/// Sole durable visibility owner. The caller supplies a private, product-owned root.
public final class ProductDatabase: @unchecked Sendable {
  public let root: URL
  private let queue: DatabaseQueue

  public static func open(at root: URL) throws -> ProductDatabase {
    try ProductDatabase(root: root)
  }

  private init(root: URL) throws {
    guard root.isFileURL else { throw ProductDatabaseError.unsafeRoot }
    let fm = FileManager.default
    try fm.createDirectory(at: root, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard values.isDirectory == true, values.isSymbolicLink != true else {
      throw ProductDatabaseError.unsafeRoot
    }
    for child in ["library.sqlite", "papers"] {
      let url = root.appendingPathComponent(child)
      if fm.fileExists(atPath: url.path),
        try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
        throw ProductDatabaseError.unsafeRoot
      }
    }
    try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    self.root = root
    var configuration = Configuration()
    configuration.prepareDatabase { db in
      try db.execute(sql: "PRAGMA foreign_keys = ON")
      try db.execute(sql: "PRAGMA synchronous = FULL")
    }
    queue = try DatabaseQueue(path: root.appendingPathComponent("library.sqlite").path,
      configuration: configuration)
    var migrator = DatabaseMigrator()
    migrator.registerMigration("localLibraryV1") { db in
      try db.execute(sql: """
        CREATE TABLE paper (
          id TEXT PRIMARY KEY NOT NULL, generation TEXT NOT NULL, title TEXT NOT NULL,
          status TEXT NOT NULL, pdfReference TEXT, pdfSHA256 TEXT, cleanupDebt INTEGER NOT NULL DEFAULT 0,
          deletionID TEXT, createdAt REAL NOT NULL
        );
        CREATE TABLE importJob (
          id TEXT PRIMARY KEY NOT NULL, paperID TEXT NOT NULL UNIQUE REFERENCES paper(id),
          attempt TEXT NOT NULL, fence TEXT NOT NULL, correlation TEXT NOT NULL,
          input TEXT NOT NULL, epoch TEXT NOT NULL, writer TEXT NOT NULL,
          publication TEXT NOT NULL, state TEXT NOT NULL, bytesCopied INTEGER NOT NULL DEFAULT 0,
          failure TEXT
        );
        CREATE TABLE providerConfig (
          singleton INTEGER PRIMARY KEY CHECK(singleton = 1), slotID TEXT,
          generation INTEGER NOT NULL CHECK(generation >= 0), model TEXT
        );
        INSERT INTO providerConfig(singleton, generation) VALUES (1, 0);
        """)
    }
    Self.registerReaderMigrations(in: &migrator)
    Self.registerAnnotationMigrations(in: &migrator)
    Self.registerFolderMigrations(in: &migrator)
    Self.registerExtractionMigrations(in: &migrator)
    Self.registerLibrarySummaryMigrations(in: &migrator)
    Self.registerReaderMetadataMigrations(in: &migrator)
    Self.registerOrganizationMigrations(in: &migrator)
    Self.registerImportRecoveryMigrations(in: &migrator)
    migrator.registerMigration("localLibraryDeletionDiagnosticV1") { db in
      try db.execute(sql: """
        ALTER TABLE paper ADD COLUMN deletionFailure TEXT
          CHECK (deletionFailure IS NULL OR deletionFailure IN
            ('agentPurgeUnavailable', 'agentClosureUnproved', 'deletionIncomplete'))
        """)
    }
    try migrator.migrate(queue)
    try fm.setAttributes([.posixPermissions: 0o600],
      ofItemAtPath: root.appendingPathComponent("library.sqlite").path)
  }

  // Feature persistence adapters share this queue; Domain and UI do not execute SQL.
  func adapterRead<T>(_ body: (Database) throws -> T) throws -> T {
    try queue.read(body)
  }

  func adapterWrite<T>(_ body: (Database) throws -> T) throws -> T {
    try queue.write(body)
  }

  public func extractionStatuses(paperID: UUID) -> AsyncValueObservation<ExtractionStatus> {
    ValueObservation.tracking { db in
      try Self.fetchExtractionStatus(paperID: paperID, in: db)
    }.values(in: queue, bufferingPolicy: .bufferingNewest(1))
  }

  public func providerConfiguration() throws -> ProviderConfiguration {
    try queue.read { db in
      guard let row = try Row.fetchOne(db, sql: "SELECT slotID, generation, model FROM providerConfig")
      else { throw ProductDatabaseError.invalidRecord }
      let slot: String? = row["slotID"]
      if let slot, UUID(uuidString: slot) == nil { throw ProductDatabaseError.invalidRecord }
      return ProviderConfiguration(slotID: slot.flatMap(UUID.init(uuidString:)),
        generation: row["generation"], model: row["model"])
    }
  }

  public func compareAndSwapProviderConfiguration(
    expected: ProviderConfiguration, replacementSlotID: UUID?, replacementModel: String?
  ) throws -> ProviderConfiguration {
    guard expected.generation >= 0, expected.generation < Int64.max else {
      throw ProductDatabaseError.generationExhausted
    }
    return try queue.write { db in
      try db.execute(sql: """
        UPDATE providerConfig SET slotID = ?, model = ?, generation = generation + 1
        WHERE singleton = 1 AND generation = ? AND slotID IS ? AND model IS ?
        """, arguments: [replacementSlotID?.uuidString, replacementModel, expected.generation,
          expected.slotID?.uuidString, expected.model])
      guard db.changesCount == 1 else { throw ProductDatabaseError.staleConfiguration }
      return ProviderConfiguration(slotID: replacementSlotID, generation: expected.generation + 1,
        model: replacementModel)
    }
  }

  public func libraryRecords() throws -> [LibraryRecord] {
    try queue.read { db in
      try Row.fetchAll(db, sql: """
        SELECT paper.id, title, status, cleanupDebt, bytesCopied,
          importJob.id AS importJobID, importJob.state AS importJobState,
          CASE WHEN status IN ('deleting', 'deletionFailed') THEN paper.deletionFailure
            ELSE importJob.failure END AS failure
        FROM paper LEFT JOIN importJob ON importJob.paperID = paper.id
        WHERE status != 'tombstone' ORDER BY createdAt DESC, paper.id
        """).map { row in
          let id: String = row["id"]
          let status: String = row["status"]
          guard let uuid = UUID(uuidString: id), let state = LibraryStatus(rawValue: status)
          else { throw ProductDatabaseError.invalidRecord }
          var failure: String? = row["failure"]
          if state == .importFailed, String.fromDatabaseValue(row["importJobState"]) == "succeeded" {
            guard let jobID = String.fromDatabaseValue(row["importJobID"]) else {
              throw ProductDatabaseError.invalidRecord
            }
            _ = try Self.readUnavailableSucceededImport(jobID: jobID, in: db)
            failure = "missingPDF"
          }
          return LibraryRecord(id: uuid, title: row["title"], status: state,
            bytesCopied: row["bytesCopied"] ?? 0, failure: failure,
            cleanupDebt: row["cleanupDebt"])
        }
    }
  }

  static func insertImport(_ identity: ImportIdentity, title: String, createdAt: Double,
    in db: Database) throws {
      try db.execute(sql: """
        INSERT INTO paper(id, generation, title, status, createdAt) VALUES (?, ?, ?, 'importing', ?)
        """, arguments: [identity.paperID.uuidString, identity.generation.uuidString, title,
          createdAt])
      guard db.changesCount == 1 else { throw ProductDatabaseError.staleImport }
      try db.execute(sql: """
        INSERT INTO importJob(id, paperID, attempt, fence, correlation, input, epoch, writer,
          publication, state) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'running')
        """, arguments: [identity.jobID.uuidString, identity.paperID.uuidString,
          identity.attempt.uuidString, identity.fence.uuidString, identity.correlation.uuidString,
          identity.input.uuidString, identity.epoch.uuidString, identity.writer.uuidString,
          identity.publication.uuidString])
      guard db.changesCount == 1 else { throw ProductDatabaseError.staleImport }
  }

  func recordProgress(_ identity: ImportIdentity, bytes: Int64) throws {
    try queue.write { db in
      let currentBytes = try Self.guardRunningImport(identity, in: db)
      guard bytes >= currentBytes else { throw ProductDatabaseError.invalidRecord }
      try db.execute(sql: "UPDATE importJob SET bytesCopied = ? WHERE id = ?",
        arguments: [bytes, identity.jobID.uuidString])
      guard db.changesCount == 1 else { throw ProductDatabaseError.staleImport }
    }
  }

  static func guardRunningImport(_ identity: ImportIdentity, in db: Database) throws -> Int64 {
    guard let bytes = try Int64.fetchOne(db, sql: """
      SELECT j.bytesCopied FROM paper p JOIN importJob j ON p.id = j.paperID
      WHERE p.id = ? AND p.generation = ? AND p.status = 'importing' AND p.deletionID IS NULL
        AND j.id = ? AND j.attempt = ? AND j.fence = ? AND j.correlation = ?
        AND j.input = ? AND j.epoch = ? AND j.writer = ? AND j.publication = ? AND j.state = 'running'
      """, arguments: [identity.paperID.uuidString, identity.generation.uuidString,
        identity.jobID.uuidString, identity.attempt.uuidString, identity.fence.uuidString,
        identity.correlation.uuidString, identity.input.uuidString, identity.epoch.uuidString,
        identity.writer.uuidString, identity.publication.uuidString]) else {
      throw ProductDatabaseError.staleImport
    }
    guard bytes >= 0 else { throw ProductDatabaseError.invalidRecord }
    return bytes
  }

  /// Rename and reference publication share the guarded transaction. Failure never leaves a
  /// visible success; the Application owner synchronously removes any renamed bytes on error.
  func publish(_ identity: ImportIdentity, stage: URL, final: URL, sha256: String,
    destinationFolderID: UUID? = nil) throws {
    try queue.write { db in
      try Self.validateImportDestination(destinationFolderID, in: db)
      _ = try Self.guardRunningImport(identity, in: db)
      try FileManager.default.moveItem(at: stage, to: final)
      try Self.publishImportRows(identity, sha256: sha256, destinationFolderID: destinationFolderID, in: db)
    }
  }

  static func publishImportRows(_ identity: ImportIdentity, sha256: String,
    destinationFolderID: UUID?, in db: Database) throws {
    _ = try guardRunningImport(identity, in: db)
    try db.execute(sql: """
      UPDATE paper SET status = 'ready', pdfReference = ?, pdfSHA256 = ?
      WHERE id = ? AND generation = ? AND status = 'importing' AND deletionID IS NULL
      """, arguments: ["papers/\(identity.paperID.uuidString)/document.pdf", sha256,
        identity.paperID.uuidString, identity.generation.uuidString])
    guard db.changesCount == 1 else { throw ProductDatabaseError.staleImport }
    try assignImportedPaper(identity.paperID, folderID: destinationFolderID, in: db)
    try db.execute(sql: "UPDATE importJob SET state = 'succeeded', failure = NULL WHERE id = ? AND state = 'running'",
      arguments: [identity.jobID.uuidString])
    guard db.changesCount == 1 else { throw ProductDatabaseError.staleImport }
  }

  func failImport(_ identity: ImportIdentity, failure: String, cleanupDebt: Bool) throws {
    try queue.write { db in
      try Self.failRunningImport(identity, failure: failure, cleanupDebt: cleanupDebt, in: db)
    }
  }

  static func failRunningImport(_ identity: ImportIdentity, failure: String,
    cleanupDebt: Bool, in db: Database) throws {
    _ = try guardRunningImport(identity, in: db)
    try db.execute(sql: """
      UPDATE paper SET status = 'importFailed', pdfReference = NULL, cleanupDebt = ?
      WHERE id = ? AND status = 'importing'
      """, arguments: [cleanupDebt, identity.paperID.uuidString])
    guard db.changesCount == 1 else { throw ProductDatabaseError.staleImport }
    try db.execute(sql: """
      UPDATE importJob SET state = 'failed', failure = ? WHERE id = ? AND state = 'running'
      """, arguments: [failure, identity.jobID.uuidString])
    guard db.changesCount == 1 else { throw ProductDatabaseError.staleImport }
  }

  /// Producer abort may finish after deletion revoked this exact execution. It must
  /// preserve the saga and other debts, never turn a deleting Paper back into a failure.
  func recordImportAbort(_ identity: ImportIdentity, failure: String, cleanupDebt: Bool) throws {
    try queue.write { db in
      guard let row = try Row.fetchOne(db, sql: """
        SELECT p.status, p.deletionID FROM paper p JOIN importJob j ON p.id = j.paperID
        WHERE p.id = ? AND p.generation = ? AND j.id = ? AND j.attempt = ? AND j.fence = ?
          AND j.correlation = ? AND j.input = ? AND j.epoch = ? AND j.writer = ? AND j.publication = ?
          AND ((p.status = 'importing' AND p.deletionID IS NULL AND j.state = 'running')
            OR (p.status = 'deleting' AND p.deletionID IS NOT NULL
              AND j.state = 'failed' AND j.failure = 'paperDeleting'))
        """, arguments: [identity.paperID.uuidString, identity.generation.uuidString,
          identity.jobID.uuidString, identity.attempt.uuidString, identity.fence.uuidString,
          identity.correlation.uuidString, identity.input.uuidString, identity.epoch.uuidString,
          identity.writer.uuidString, identity.publication.uuidString]) else {
        throw ProductDatabaseError.staleImport
      }
      let status: String = row["status"]
      if status == "importing" {
        try Self.failRunningImport(identity, failure: failure, cleanupDebt: cleanupDebt, in: db)
      } else {
        let saga: String = row["deletionID"]
        guard let parsed = UUID(uuidString: saga), parsed.uuidString == saga else {
          throw ProductDatabaseError.invalidRecord
        }
        if cleanupDebt {
          try db.execute(sql: "UPDATE paper SET cleanupDebt = 1 WHERE id = ? AND deletionID = ?",
            arguments: [identity.paperID.uuidString, saga])
          guard db.changesCount == 1 else { throw ProductDatabaseError.staleImport }
        }
      }
    }
  }

  func beginDeletion(_ paperID: UUID) throws -> ImportDeletionCapture? {
    try queue.write { db in
      guard let row = try Row.fetchOne(db, sql: "SELECT * FROM paper WHERE id = ?",
        arguments: [paperID.uuidString]) else { throw ProductDatabaseError.invalidRecord }
      guard let status = String.fromDatabaseValue(row["status"]),
        let state = LibraryStatus(rawValue: status),
        let generation = String.fromDatabaseValue(row["generation"]), !generation.isEmpty else {
        throw ProductDatabaseError.invalidRecord
      }
      if state == .tombstone { return nil }
      let existing: String? = row["deletionID"]
      let saga: UUID
      if let existing {
        guard let parsed = UUID(uuidString: existing), parsed.uuidString == existing else {
          throw ProductDatabaseError.invalidRecord
        }
        saga = parsed
      } else {
        guard state != .deleting, state != .deletionFailed else { throw ProductDatabaseError.invalidRecord }
        saga = UUID()
      }
      let jobs = try Self.boundedDeletionJobs(paperID, in: db)
      let histories = try jobs.map { job -> ImportRecoveryRecord? in
        guard let id = String.fromDatabaseValue(job["id"]) else { throw ProductDatabaseError.invalidRecord }
        return try Self.readImportRecoveryForAdmission(jobID: id, saga: saga, in: db)
      }
      try db.execute(sql: """
        UPDATE paper SET status = 'deleting', deletionID = ?, pdfReference = NULL,
          deletionFailure = NULL WHERE id = ?
        """, arguments: [saga.uuidString, paperID.uuidString])
      guard db.changesCount == 1 else { throw ProductDatabaseError.invalidRecord }
      try db.execute(sql: """
        UPDATE importJob SET state = 'failed', failure = 'paperDeleting'
        WHERE paperID = ? AND state = 'running'
        """, arguments: [paperID.uuidString])
      let running = jobs.filter { String.fromDatabaseValue($0["state"]) == "running" }.count
      guard db.changesCount == running,
        let after = try Row.fetchOne(db, sql: "SELECT * FROM paper WHERE id = ?",
          arguments: [paperID.uuidString]),
        Self.sameDeletionRow(row, after, except: ["status", "deletionID", "pdfReference", "deletionFailure"]),
        String.fromDatabaseValue(after["status"]) == "deleting",
        String.fromDatabaseValue(after["deletionID"]) == saga.uuidString,
        after["pdfReference"] == DatabaseValue.null, after["deletionFailure"] == DatabaseValue.null else {
        throw ProductDatabaseError.invalidRecord
      }
      let acknowledgments = try histories.map { history -> ImportRecoveryRecord? in
        guard let history else { return nil }
        return try Self.revokeImportRecoveryForBeginDeletion(history, saga: saga, in: db)
      }
      let readback = try Self.boundedDeletionJobs(paperID, in: db)
      guard jobs.count == readback.count else { throw ProductDatabaseError.invalidRecord }
      for (index, pair) in zip(jobs, readback).enumerated() {
        let (before, after) = pair
        var ignored: Set<String> = []
        if let acknowledgment = acknowledgments[index] {
          guard Data.fromDatabaseValue(after["recoveryJournal"]) == acknowledgment.encoded else {
            throw ProductDatabaseError.invalidRecord
          }
          ignored.insert("recoveryJournal")
        }
        if String.fromDatabaseValue(before["state"]) == "running" {
          guard Self.sameDeletionRow(before, after, except: ignored.union(["state", "failure"])),
            String.fromDatabaseValue(after["state"]) == "failed",
            String.fromDatabaseValue(after["failure"]) == "paperDeleting" else {
            throw ProductDatabaseError.invalidRecord
          }
        } else if !Self.sameDeletionRow(before, after, except: ignored) { throw ProductDatabaseError.invalidRecord }
      }
      return ImportDeletionCapture(saga: saga, histories: acknowledgments.compactMap { $0 },
        legacyJobCount: acknowledgments.filter { $0 == nil }.count)
    }
  }

  func deletionFailed(_ paperID: UUID, saga: UUID, reason: String) throws {
    guard ["agentPurgeUnavailable", "agentClosureUnproved", "deletionIncomplete"].contains(reason) else {
      throw ProductDatabaseError.invalidRecord
    }
    try queue.write { db in
      let before = try Self.deletingPaper(paperID, saga: saga, in: db)
      let jobs = try Self.deletionJobs(paperID, in: db)
      try db.execute(sql: """
        UPDATE paper SET status = 'deletionFailed', cleanupDebt = 1, deletionFailure = ?
        WHERE id = ? AND deletionID = ? AND status = 'deleting'
        """, arguments: [reason, paperID.uuidString, saga.uuidString])
      guard db.changesCount == 1,
        let after = try Row.fetchOne(db, sql: "SELECT * FROM paper WHERE id = ?",
          arguments: [paperID.uuidString]),
        Self.sameDeletionRow(before, after, except: ["status", "cleanupDebt", "deletionFailure"]),
        String.fromDatabaseValue(after["status"]) == "deletionFailed",
        Int64.fromDatabaseValue(after["cleanupDebt"]) == 1,
        String.fromDatabaseValue(after["deletionFailure"]) == reason,
        Self.sameDeletionJobs(jobs, try Self.deletionJobs(paperID, in: db)) else {
        throw ProductDatabaseError.invalidRecord
      }
    }
  }

  func finalizeDeletion(_ paperID: UUID, saga: UUID) throws {
    try queue.write { db in
      guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM importJob WHERE paperID = ? AND recoveryJournal IS NOT NULL",
        arguments: [paperID.uuidString]) == 0 else { throw ImportRecoveryPersistenceError.invalidHistory }
      try Self.finalizeDeletionRows(paperID, saga: saga, in: db)
    }
  }

  static func finalizeDeletionRows(_ paperID: UUID, saga: UUID, in db: Database) throws {
      let before = try Self.deletingPaper(paperID, saga: saga, in: db)
      let jobs = try Self.deletionJobs(paperID, in: db)
      try db.execute(sql: """
        UPDATE paper SET status = 'tombstone', title = '', pdfReference = NULL, pdfSHA256 = NULL,
          cleanupDebt = 0, deletionFailure = NULL
        WHERE id = ? AND deletionID = ? AND status = 'deleting'
        """, arguments: [paperID.uuidString, saga.uuidString])
      guard db.changesCount == 1 else { throw ProductDatabaseError.invalidRecord }
      try db.execute(sql: "DELETE FROM importJob WHERE paperID = ?", arguments: [paperID.uuidString])
      guard db.changesCount == jobs.count,
        try Self.deletionJobs(paperID, in: db).isEmpty,
        let after = try Row.fetchOne(db, sql: "SELECT * FROM paper WHERE id = ?",
          arguments: [paperID.uuidString]),
        Self.sameDeletionRow(before, after,
          except: ["status", "title", "pdfReference", "pdfSHA256", "cleanupDebt", "deletionFailure"]),
        String.fromDatabaseValue(after["status"]) == "tombstone",
        String.fromDatabaseValue(after["title"]) == "",
        Int64.fromDatabaseValue(after["cleanupDebt"]) == 0,
        after["pdfReference"] == DatabaseValue.null, after["pdfSHA256"] == DatabaseValue.null,
        after["deletionFailure"] == DatabaseValue.null else { throw ProductDatabaseError.invalidRecord }
  }

  private static func deletingPaper(_ paperID: UUID, saga: UUID, in db: Database) throws -> Row {
    guard let row = try Row.fetchOne(db, sql: "SELECT * FROM paper WHERE id = ?",
      arguments: [paperID.uuidString]),
      String.fromDatabaseValue(row["status"]) == "deleting",
      String.fromDatabaseValue(row["deletionID"]) == saga.uuidString,
      let generation = String.fromDatabaseValue(row["generation"]), !generation.isEmpty else {
      throw ProductDatabaseError.invalidRecord
    }
    return row
  }

  static func boundedDeletionJobs(_ paperID: UUID, in db: Database) throws -> [Row] {
    let maximum = ProductJobRecovery.maximumImportRecoveryJournalBytes
    // Admit type/size before any full-row capture, including trigger readbacks.
    let payloads = try Row.fetchAll(db, sql: """
      SELECT typeof(recoveryJournal) AS payloadType,
        CASE WHEN typeof(recoveryJournal) = 'blob' AND length(recoveryJournal) <= ?
          THEN recoveryJournal ELSE NULL END AS payload
      FROM importJob WHERE paperID = ? ORDER BY id
      """, arguments: [maximum, paperID.uuidString])
    for row in payloads {
      let type = String.fromDatabaseValue(row["payloadType"])
      guard type == "null" || (type == "blob" && Data.fromDatabaseValue(row["payload"]) != nil) else {
        throw ImportRecoveryPersistenceError.invalidHistory
      }
    }
    return try deletionJobs(paperID, in: db)
  }

  private static func deletionJobs(_ paperID: UUID, in db: Database) throws -> [Row] {
    try Row.fetchAll(db, sql: "SELECT * FROM importJob WHERE paperID = ? ORDER BY id",
      arguments: [paperID.uuidString])
  }

  private static func sameDeletionRow(_ before: Row, _ after: Row,
    except ignored: Set<String> = []) -> Bool {
    guard Array(before.columnNames) == Array(after.columnNames) else { return false }
    return before.columnNames.filter { !ignored.contains($0) }.allSatisfy { name in
      let old: DatabaseValue = before[name]
      let new: DatabaseValue = after[name]
      return old.storage == new.storage
    }
  }

  private static func sameDeletionJobs(_ before: [Row], _ after: [Row]) -> Bool {
    before.count == after.count && zip(before, after).allSatisfy { sameDeletionRow($0.0, $0.1) }
  }

}
