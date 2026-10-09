import Foundation
import GRDB

public enum ProductJobRecoveryError: Error, Equatable, Sendable {
  case invalidLineage, recoveryConflict, readbackMismatch
}

public struct ProductJobRecoveryReceipt: Equatable, Sendable {
  public enum Kind: Equatable, Sendable { case `import`, extraction, librarySummary }

  public struct InterruptedJob: Equatable, Sendable {
    public let kind: Kind
    public let paperID: UUID
    public let jobID: UUID
    public let attempt: UUID
    public let fence: UUID
    public let correlation: UUID
    public let inputVersion: UUID
    public let capturedEpoch: UUID
    /// The retained pointer is not an attestation of current usability or producer closure.
    public let retainedExtractionRevision: UUID?
    public let retainedSummaryResult: UUID?
    public let cleanupDebt: Bool
  }

  public let currentEpoch: UUID
  public let interruptedJobs: [InterruptedJob]
}

/// Startup only, before admitting producers. Uses Main's existing epoch and sole GRDB queue.
/// No policy commands are executed: prior-process cancellation cannot prove physical closure.
public struct ProductJobRecovery: Sendable {
  private let database: ProductDatabase

  public init(database: ProductDatabase) { self.database = database }

  public func recoverStartup(currentEpoch: UUID) throws -> ProductJobRecoveryReceipt {
    try database.adapterWrite { db in
      var recovered: [ProductJobRecoveryReceipt.InterruptedJob] = []
      for kind in [ProductJobRecoveryReceipt.Kind.import, .extraction] {
        let table = kind == .import ? "importJob" : "extractionAttempt"
        let jobColumn = kind == .import ? "id" : "job"
        let rows = try Row.fetchAll(db, sql: """
          SELECT * FROM \(table) WHERE state = 'running' AND epoch != ? ORDER BY paperID
          """, arguments: [currentEpoch.uuidString])
        for row in rows {
          let paperID = try Self.uuid(row, "paperID")
          guard let paper = try Row.fetchOne(db, sql: "SELECT * FROM paper WHERE id = ?",
            arguments: [paperID.uuidString]) else {
            throw ProductJobRecoveryError.invalidLineage
          }
          let generation = try Self.uuid(kind == .import ? paper : row, "generation")
          let job = try Self.uuid(row, jobColumn)
          let attempt = try Self.uuid(row, "attempt")
          let fence = try Self.uuid(row, "fence")
          let correlation = try Self.uuid(row, "correlation")
          let input = try Self.uuid(row, "input")
          let epoch = try Self.uuid(row, "epoch")
          if kind == .import {
            _ = try Self.uuid(row, "writer")
            _ = try Self.uuid(row, "publication")
          } else {
            _ = try Self.uuid(row, "revision")
          }
          let beforeRevision = try Self.retainedRevision(db, paperID: paperID)
          let authority = JobRecoveryPolicy.Authority(
            input: kind == .import ? .source(version: input.uuidString) : .parser(version: input.uuidString),
            config: .inapplicable,
            paper: .init(id: paperID.uuidString, generation: generation.uuidString),
            epoch: epoch.uuidString, prerequisitesAvailable: false)
          let lineage = JobRecoveryPolicy.Lineage(job: job.uuidString,
            reservation: .init(attempt: attempt.uuidString, fence: fence.uuidString,
              correlation: correlation.uuidString), captured: authority)
          // Rehydration records persisted running state, not a new claim or permit grant.
          // These schemas store neither dispatch/permit history nor prior-result lineage.
          // The transient snapshot supplies only startup's inputs; it is never persisted or
          // returned as execution authority. Retained pointers are read separately.
          let snapshot = JobRecoveryPolicy.Snapshot(job: job.uuidString,
            role: kind == .import ? .import : .parsing, authority: authority,
            executions: [.init(lineage: lineage, state: .running, dispatch: .none, result: nil)],
            usableResult: nil, permits: [], usedPermitIDs: [], revoked: false,
            usedOperationIDs: [], pendingRemoval: nil, removalDebt: nil, removedPapers: [])
          let decision = JobRecoveryPolicy.apply(.startup(currentEpoch: currentEpoch.uuidString),
            to: snapshot)
          guard decision.rejection == nil, decision.snapshot.current.state == .failed(.interrupted),
            decision.snapshot.current.lineage == lineage else {
            throw ProductJobRecoveryError.recoveryConflict
          }
          // Selection, exact-lineage CAS and readback share one serialized transaction.
          try db.execute(sql: """
            UPDATE \(table) SET state = 'failed', failure = 'interrupted'
            WHERE paperID = ? AND \(jobColumn) = ? AND attempt = ? AND fence = ?
              AND correlation = ? AND input = ? AND epoch = ? AND state = 'running'
            """, arguments: [paperID.uuidString, job.uuidString, attempt.uuidString,
              fence.uuidString, correlation.uuidString, input.uuidString, epoch.uuidString])
          guard db.changesCount == 1 else { throw ProductJobRecoveryError.recoveryConflict }
          if kind == .import {
            // Never infer absence, erase an existing reference or complete a deletion saga.
            try db.execute(sql: """
              UPDATE paper SET cleanupDebt = 1,
                status = CASE WHEN status = 'importing' THEN 'importFailed' ELSE status END
              WHERE id = ?
              """, arguments: [paperID.uuidString])
            guard db.changesCount == 1 else { throw ProductJobRecoveryError.recoveryConflict }
          }
          guard let after = try Row.fetchOne(db, sql: "SELECT * FROM \(table) WHERE paperID = ?",
            arguments: [paperID.uuidString]),
            let afterPaper = try Row.fetchOne(db, sql: "SELECT * FROM paper WHERE id = ?",
              arguments: [paperID.uuidString]) else {
            throw ProductJobRecoveryError.readbackMismatch
          }
          let state: String = after["state"]
          let failure: String? = after["failure"]
          guard state == "failed", failure == "interrupted",
            Self.matches(row, after, except: ["state", "failure"]),
            Self.matches(paper, afterPaper,
              except: kind == .import ? ["status", "cleanupDebt"] : []),
            try Self.retainedRevision(db, paperID: paperID) == beforeRevision else {
            throw ProductJobRecoveryError.readbackMismatch
          }
          let debt: Bool = afterPaper["cleanupDebt"]
          let status: String = afterPaper["status"]
          let oldStatus: String = paper["status"]
          guard kind != .import || (debt && status == (oldStatus == "importing" ? "importFailed" : oldStatus))
          else { throw ProductJobRecoveryError.readbackMismatch }
          recovered.append(.init(kind: kind, paperID: paperID, jobID: job, attempt: attempt,
            fence: fence, correlation: correlation, inputVersion: input, capturedEpoch: epoch,
            retainedExtractionRevision: beforeRevision, retainedSummaryResult: nil, cleanupDebt: debt))
        }
      }
      let summaries = try Row.fetchAll(db, sql: """
        SELECT * FROM librarySummaryJob WHERE state = 'running' AND epoch != ? ORDER BY job
        """, arguments: [currentEpoch.uuidString])
      for row in summaries {
        let paperID = try Self.uuid(row, "paperID")
        let job = try Self.uuid(row, "job")
        let attempt = try Self.uuid(row, "attempt")
        let fence = try Self.uuid(row, "fence")
        let correlation = try Self.uuid(row, "correlation")
        let input = try Self.uuid(row, "input")
        let epoch = try Self.uuid(row, "epoch")
        let identityData: Data = row["identity"]
        let identity = try JSONDecoder().decode(LibrarySummaryIdentity.self, from: identityData)
        guard identity.paperID == paperID, identity.job == job, identity.attempt == attempt,
          identity.fence == fence, identity.correlation == correlation, identity.input == input,
          identity.epoch == epoch,
          let paper = try Row.fetchOne(db, sql: "SELECT * FROM paper WHERE id = ?",
            arguments: [paperID.uuidString]) else { throw ProductJobRecoveryError.invalidLineage }
        // Captured generation/configuration come from the saved identity, never current
        // provider selection or a guessed Paper generation. No dispatch is reconstructed.
        let authority = JobRecoveryPolicy.Authority(input: .librarySummary(version: input.uuidString),
          config: .generation(String(identity.configurationGeneration)),
          paper: .init(id: paperID.uuidString, generation: identity.generation.uuidString),
          epoch: epoch.uuidString, prerequisitesAvailable: false)
        let lineage = JobRecoveryPolicy.Lineage(job: job.uuidString,
          reservation: .init(attempt: attempt.uuidString, fence: fence.uuidString,
            correlation: correlation.uuidString), captured: authority)
        let snapshot = JobRecoveryPolicy.Snapshot(job: job.uuidString, role: .librarySummary,
          authority: authority,
          executions: [.init(lineage: lineage, state: .running, dispatch: .none, result: nil)],
          usableResult: nil, permits: [], usedPermitIDs: [], revoked: false,
          usedOperationIDs: [], pendingRemoval: nil, removalDebt: nil, removedPapers: [])
        let decision = JobRecoveryPolicy.apply(.startup(currentEpoch: currentEpoch.uuidString), to: snapshot)
        guard decision.rejection == nil, decision.snapshot.current.state == .failed(.interrupted),
          decision.snapshot.current.lineage == lineage else { throw ProductJobRecoveryError.recoveryConflict }
        let beforeRevision = try Self.retainedRevision(db, paperID: paperID)
        let visible = try Row.fetchAll(db, sql: "SELECT * FROM librarySummaryVisible WHERE paperID = ?",
          arguments: [paperID.uuidString])
        let results = try Row.fetchAll(db,
          sql: "SELECT * FROM librarySummaryResult WHERE paperID = ? ORDER BY id",
          arguments: [paperID.uuidString])
        let retainedSummary = try visible.first.map { try Self.uuid($0, "resultID") }
        try db.execute(sql: """
          UPDATE librarySummaryJob SET state = 'failed', failure = 'interrupted'
          WHERE job = ? AND paperID = ? AND attempt = ? AND fence = ? AND correlation = ?
            AND input = ? AND epoch = ? AND identity = ? AND state = 'running'
          """, arguments: [job.uuidString, paperID.uuidString, attempt.uuidString, fence.uuidString,
            correlation.uuidString, input.uuidString, epoch.uuidString, identityData])
        guard db.changesCount == 1 else { throw ProductJobRecoveryError.recoveryConflict }
        guard let after = try Row.fetchOne(db, sql: "SELECT * FROM librarySummaryJob WHERE job = ?",
          arguments: [job.uuidString]),
          let afterPaper = try Row.fetchOne(db, sql: "SELECT * FROM paper WHERE id = ?",
            arguments: [paperID.uuidString]) else { throw ProductJobRecoveryError.readbackMismatch }
        let state: String = after["state"]
        let failure: String? = after["failure"]
        let afterVisible = try Row.fetchAll(db, sql: "SELECT * FROM librarySummaryVisible WHERE paperID = ?",
          arguments: [paperID.uuidString])
        let afterResults = try Row.fetchAll(db,
          sql: "SELECT * FROM librarySummaryResult WHERE paperID = ? ORDER BY id",
          arguments: [paperID.uuidString])
        guard state == "failed", failure == "interrupted",
          Self.matches(row, after, except: ["state", "failure"]),
          Self.matches(paper, afterPaper, except: []),
          visible == afterVisible, results == afterResults,
          try Self.retainedRevision(db, paperID: paperID) == beforeRevision else {
          throw ProductJobRecoveryError.readbackMismatch
        }
        recovered.append(.init(kind: .librarySummary, paperID: paperID, jobID: job,
          attempt: attempt, fence: fence, correlation: correlation, inputVersion: input,
          capturedEpoch: epoch, retainedExtractionRevision: beforeRevision,
          retainedSummaryResult: retainedSummary, cleanupDebt: afterPaper["cleanupDebt"]))
      }
      // DatabaseQueue.write commits before this receipt escapes; any throw rolls back all kinds.
      return ProductJobRecoveryReceipt(currentEpoch: currentEpoch, interruptedJobs: recovered)
    }
  }

  /// Library reconciliation follows atomic job recovery, still before owner admission.
  /// Neither missing files nor process restart attest Agent drain or namespace absence.
  func reconcileLibraryStartup() throws {
    try database.adapterWrite { db in
      try db.execute(sql: """
        UPDATE paper SET status = 'deletionFailed', cleanupDebt = 1 WHERE status = 'deleting'
        """)
    }
    let references: [(String, String)] = try database.adapterRead { db in
      try Row.fetchAll(db, sql: "SELECT id, pdfReference FROM paper WHERE status = 'ready'").map {
        ($0["id"], $0["pdfReference"])
      }
    }
    for (id, reference) in references {
      let expected = "papers/\(id)/document.pdf"
      let url = database.root.appendingPathComponent(reference)
      let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      if reference != expected || values?.isRegularFile != true || values?.isSymbolicLink == true {
        try database.adapterWrite { db in
          try db.execute(sql: """
            UPDATE paper SET status = 'importFailed', pdfReference = NULL, cleanupDebt = 1
            WHERE id = ? AND status = 'ready' AND pdfReference = ?
            """, arguments: [id, reference])
          guard db.changesCount == 1 else { throw ProductJobRecoveryError.recoveryConflict }
          try db.execute(sql: "UPDATE importJob SET state = 'failed', failure = 'missingPDF' WHERE paperID = ?",
            arguments: [id])
        }
      }
    }
  }

  private static func uuid(_ row: Row, _ column: String) throws -> UUID {
    let value: String? = row[column]
    guard let value, let uuid = UUID(uuidString: value), uuid.uuidString == value else {
      throw ProductJobRecoveryError.invalidLineage
    }
    return uuid
  }

  private static func retainedRevision(_ db: Database, paperID: UUID) throws -> UUID? {
    guard let value = try String.fetchOne(db,
      sql: "SELECT revision FROM extractionVisible WHERE paperID = ?",
      arguments: [paperID.uuidString]) else { return nil }
    guard let revision = UUID(uuidString: value), revision.uuidString == value else {
      throw ProductJobRecoveryError.invalidLineage
    }
    return revision
  }

  private static func matches(_ before: Row, _ after: Row, except ignored: Set<String>) -> Bool {
    for column in before.columnNames where !ignored.contains(column) {
      let old: DatabaseValue = before[column]
      let new: DatabaseValue = after[column]
      if old.storage != new.storage { return false }
    }
    return true
  }
}
