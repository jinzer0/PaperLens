import Foundation
import GRDB
import XCTest
import ProviderRequest
@testable import PaperLensProduct

/// Owned PDF/GRDB fixture with a locally validated frozen request; never a provider send.
struct StartupSummaryFixture {
  struct Geometry: LibrarySummaryGeometryValidating {
    func resolve(_ hit: ExtractionSearchHit, identity: PDFSentenceIdentity) throws -> PDFSentenceAnchor {
      guard hit.canonicalGeometry == Data("startup-quad".utf8) else {
        throw LibrarySummaryError.invalidGrounding
      }
      let page = try PDFPageGeometry(pageIndex: identity.pageIndex,
        cropOrigin: .init(x: 0, y: 0), width: 100, height: 100, rotation: 0)
      let quad = try PDFQuad(topLeft: .init(x: 10, y: 20), topRight: .init(x: 20, y: 20),
        bottomRight: .init(x: 20, y: 10), bottomLeft: .init(x: 10, y: 10), page: page)
      return try PDFSentenceAnchor(identity: identity, fullSourceQuote: hit.text, page: page, quads: [quad])
    }
  }
  let database: ProductDatabase
  let identity: LibrarySummaryIdentity
  let frozen: LibrarySummaryFrozen
  let result: ValidatedProviderResult

  init(database: ProductDatabase, lifecycle: LocalLibraryLifecycle, epoch: UUID) async throws {
    self.database = database
    let source = database.root.appendingPathComponent("startup-\(UUID().uuidString).pdf")
    try Data("%PDF-1.7\nsynthetic owned summary PDF\n%%EOF\n".utf8).write(to: source)
    defer { try? FileManager.default.removeItem(at: source) }
    let paper = try await lifecycle.importPDF(from: source)
    let row = try database.adapterRead { db in
      try XCTUnwrap(Row.fetchOne(db, sql: "SELECT generation, pdfSHA256, status FROM paper WHERE id = ?",
        arguments: [paper.uuidString]))
    }
    let generation: String = row["generation"]
    let hash = try XCTUnwrap(String.fromDatabaseValue(row["pdfSHA256"]),
      "Actual owned summary import must publish: \(row)")
    let extraction = ExtractionIdentity(paperID: paper,
      generation: try XCTUnwrap(UUID(uuidString: generation)), pdfSHA256: hash,
      pdfReference: "papers/\(paper.uuidString)/document.pdf", revision: UUID(), job: UUID(),
      attempt: UUID(), fence: UUID(), correlation: UUID(), input: UUID(), epoch: lifecycle.epoch,
      configuration: try database.providerConfiguration())
    try database.reserveExtraction(extraction)
    let quotes = ["main contribution alpha", "results conclusion beta"]
    try publishFixtureExtraction(database, extraction, sentences: quotes.enumerated().map {
      .init(page: 0, sentenceID: $0.offset, text: $0.element, geometry: Data("startup-quad".utf8))
    })
    // Explicit synthetic trusted-context generation, not derived from a durable UUID.
    identity = LibrarySummaryIdentity(paperID: paper, generation: extraction.generation,
      requestPaperGeneration: 1, pdfSHA256: hash, revision: extraction.revision,
      configurationGeneration: extraction.configuration.generation, job: UUID(), attempt: UUID(),
      fence: UUID(), correlation: UUID(), input: UUID(), epoch: epoch)
    let authority = try ProviderRequest()
    let sources = RequestSources.librarySummary(outputLanguage: "en")
    let context = try TrustedRequestContext(authority: authority, sources: sources,
      identity: .init(paperID: paper.uuidString.lowercased(), paperGeneration: 1,
        pdfSHA256: hash, extractionRevision: extraction.revision.uuidString.lowercased()),
      sentences: quotes.enumerated().map {
        .init(anchor: .init(pageIndex: 0, sentenceID: $0.offset), quote: $0.element)
      }, rankedCandidates: [1, 0])
    let request = try authority.buildRequest(sources: sources, context: context,
      requestID: identity.correlation.uuidString.lowercased())
    frozen = try LibrarySummaryFrozen(request: request)
    guard case .librarySummary(_, let bundle) = request.wire.typedInput else {
      throw LibrarySummaryError.invalidResult
    }
    result = try authority.wrapModelResult(JSONSerialization.data(withJSONObject: [
      "summary": ["text": "Retained grounded summary", "kind": "paper", "evidenceIndices": [0, 1]],
      "insufficiency": bundle.insufficiency
    ]), request: request)
  }

  func reserve() throws {
    try database.reserveLibrarySummary(identity, frozen: frozen, geometry: Geometry())
  }

  func publish() throws -> LibrarySummaryRecord {
    try database.publishLibrarySummary(identity, frozen: frozen, result: result,
      bytes: ProviderRequest.canonicalBytes(result.value), permit: UUID().uuidString,
      resultID: UUID(), geometry: Geometry())
  }

  init(previous: StartupSummaryFixture, epoch: UUID) throws {
    database = previous.database
    let old = previous.identity
    identity = .init(paperID: old.paperID, generation: old.generation,
      requestPaperGeneration: old.requestPaperGeneration, pdfSHA256: old.pdfSHA256,
      revision: old.revision, configurationGeneration: old.configurationGeneration,
      job: UUID(), attempt: UUID(), fence: UUID(), correlation: UUID(),
      input: UUID(), epoch: epoch)
    let authority = try ProviderRequest()
    let restored = try previous.frozen.authorized(using: authority)
    let request = try authority.buildRequest(sources: RequestSources.librarySummary(outputLanguage: "en"),
      context: restored.context, requestID: identity.correlation.uuidString.lowercased())
    frozen = try LibrarySummaryFrozen(request: request)
    guard case .librarySummary(_, let bundle) = request.wire.typedInput else {
      throw LibrarySummaryError.invalidResult
    }
    result = try authority.wrapModelResult(JSONSerialization.data(withJSONObject: [
      "summary": ["text": "Retained grounded summary", "kind": "paper", "evidenceIndices": [0, 1]],
      "insufficiency": bundle.insufficiency
    ]), request: request)
  }
}

final class ProductJobRecoveryTests: XCTestCase, @unchecked Sendable {
  private var root: URL!
  private var database: ProductDatabase!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    database = try ProductDatabase.open(at: root)
  }

  override func tearDownWithError() throws {
    database = nil
    if let root { try FileManager.default.removeItem(at: root) }
    root = nil
  }

  private func importJob(epoch: UUID, state: String = "running") throws -> ImportIdentity {
    let identity = ImportIdentity(paperID: UUID(), generation: UUID(), jobID: UUID(),
      attempt: UUID(), fence: UUID(), correlation: UUID(), input: UUID(), epoch: epoch,
      writer: UUID(), publication: UUID())
    try reserveLegacyImportFixture(in: database, identity: identity, title: "Synthetic import")
    if state != "running" {
      try database.adapterWrite { db in
        try db.execute(sql: "UPDATE importJob SET state = ?, failure = 'fixture' WHERE id = ?",
          arguments: [state, identity.jobID.uuidString])
      }
    }
    return identity
  }

  private func extractionPaper() throws -> (UUID, UUID) {
    let paper = UUID(), generation = UUID()
    try database.adapterWrite { db in
      try db.execute(sql: """
        INSERT INTO paper(id, generation, title, status, pdfSHA256, pdfReference, createdAt)
        VALUES (?, ?, 'Synthetic extraction', 'ready', ?, ?, 0)
        """, arguments: [paper.uuidString, generation.uuidString, String(repeating: "a", count: 64),
          "papers/\(paper.uuidString)/document.pdf"])
    }
    return (paper, generation)
  }

  private func extraction(_ paper: UUID, _ generation: UUID, epoch: UUID) throws -> ExtractionIdentity {
    .init(paperID: paper, generation: generation, pdfSHA256: String(repeating: "a", count: 64),
      pdfReference: "papers/\(paper.uuidString)/document.pdf", revision: UUID(), job: UUID(),
      attempt: UUID(), fence: UUID(), correlation: UUID(), input: UUID(), epoch: epoch,
      configuration: try database.providerConfiguration())
  }

  private func row(_ table: String, paper: UUID) throws -> Row {
    try database.adapterRead { db in
      try XCTUnwrap(Row.fetchOne(db, sql: "SELECT * FROM \(table) WHERE \(table == "paper" ? "id" : "paperID") = ?",
        arguments: [paper.uuidString]))
    }
  }

  private func assertUnchanged(_ before: Row, _ after: Row,
    except ignored: Set<String> = [], file: StaticString = #filePath, line: UInt = #line) {
    for column in before.columnNames where !ignored.contains(column) {
      let old: DatabaseValue = before[column]
      let new: DatabaseValue = after[column]
      XCTAssertEqual(old.storage, new.storage, column, file: file, line: line)
    }
  }

  private let journalBound = ProductJobRecovery.maximumImportRecoveryJournalBytes
  private let journalFacts = ImportRecoveryJournal.ConfirmedInput(
    expectedSHA256: String(repeating: "a", count: 64), destinationFolderID: UUID())

  // Synthetic owner attestations only: these fixtures close no handles or physical writers.
  private func initializeJournal(_ identity: ImportIdentity) throws -> ImportRecoveryJournal {
    let initial = try ImportRecoveryJournal(identity: identity, confirmedInput: journalFacts)
    let claimed = try initial.recording(.claim(initial.snapshot().current.lineage))
    try database.adapterWrite {
      try ProductDatabase.initializeImportRecovery(claimed, maximumBytes: journalBound, in: $0)
    }
    return claimed
  }

  private func appendJournal(_ journal: ImportRecoveryJournal,
    _ events: [JobRecoveryPolicy.Event]) throws -> ImportRecoveryJournal {
    var previous = journal
    for event in events {
      let next = try previous.recording(event)
      let bytes = try previous.encoded(maximumBytes: journalBound)
      _ = try database.adapterWrite {
        try ProductDatabase.compareAndSwapImportRecovery(expected: bytes, replacement: next,
          maximumBytes: journalBound, in: $0)
      }
      previous = next
    }
    return previous
  }

  private func journalRecord(_ identity: ImportIdentity) throws -> ImportRecoveryRecord {
    try database.adapterRead {
      try ProductDatabase.readImportRecovery(identity, maximumBytes: journalBound, in: $0)
    }
  }

  private func capturedIDs(_ identity: ImportIdentity) -> [UUID] {
    [identity.paperID, identity.generation, identity.jobID, identity.attempt, identity.fence,
      identity.correlation, identity.input, identity.epoch, identity.writer, identity.publication]
  }

  // Test-only execution-column transition with a genuine replayed Retry capture. Production
  // Retry reservation is deliberately not implemented or admitted by this startup slice.
  private func retryJournal(_ journal: ImportRecoveryJournal) throws -> (ImportIdentity, ImportRecoveryJournal) {
    let old = try journal.currentCapture().identity
    let next = ImportIdentity(paperID: old.paperID, generation: old.generation, jobID: old.jobID,
      attempt: UUID(), fence: UUID(), correlation: UUID(), input: UUID(), epoch: old.epoch,
      writer: UUID(), publication: UUID())
    let facts = ImportRecoveryJournal.ConfirmedInput(expectedSHA256: nil, destinationFolderID: UUID())
    let pending = try journal.retrying(identity: next, confirmedInput: facts)
    let claimed = try pending.recording(.claim(pending.snapshot().current.lineage))
    let bytes = try claimed.encoded(maximumBytes: journalBound)
    try database.adapterWrite { db in
      try db.execute(sql: """
        UPDATE importJob SET attempt = ?, fence = ?, correlation = ?, input = ?, epoch = ?,
          writer = ?, publication = ?, state = 'running', failure = NULL, recoveryJournal = ?
        WHERE id = ? AND recoveryJournal = ?
        """, arguments: [next.attempt.uuidString, next.fence.uuidString, next.correlation.uuidString,
          next.input.uuidString, next.epoch.uuidString, next.writer.uuidString,
          next.publication.uuidString, bytes, next.jobID.uuidString,
          try journal.encoded(maximumBytes: journalBound)])
      XCTAssertEqual(db.changesCount, 1)
      XCTAssertEqual(try ProductDatabase.readImportRecovery(next,
        maximumBytes: journalBound, in: db).encoded, bytes)
    }
    return (next, claimed)
  }

  func testJournalStartupRetainsOpenWriterDebtAllCapturesAndObservedEpochWithoutRenewal() throws {
    let identity = try importJob(epoch: UUID())
    let claimed = try initializeJournal(identity)
    let lineage = try claimed.snapshot().current.lineage
    let journal = try appendJournal(claimed, [
      .acquireWriter(lineage, permit: identity.writer.uuidString),
      .writerClosure(lineage, permit: identity.writer.uuidString, .open)])
    let before = try row("importJob", paper: identity.paperID)
    let beforePaper = try row("paper", paper: identity.paperID)
    let bytes = try journal.encoded(maximumBytes: journalBound)
    let observed = UUID()
    let receipt = try ProductJobRecovery(database: database).recoverStartup(currentEpoch: observed)
    XCTAssertEqual(receipt.interruptedJobs.first?.capturedEpoch, identity.epoch)
    let record = try journalRecord(identity)
    let expected = try journal.recording(.startup(currentEpoch: observed.uuidString))
    XCTAssertEqual(record.encoded, try expected.encoded(maximumBytes: journalBound))
    XCTAssertTrue(try record.journal.extends(journal, maximumBytes: journalBound))
    let snapshot = try record.journal.snapshot()
    XCTAssertEqual(snapshot, try expected.snapshot())
    XCTAssertEqual(snapshot.authority.epoch, observed.uuidString)
    XCTAssertEqual(snapshot.current.lineage, lineage)
    XCTAssertEqual(snapshot.current.state, .failed(.interrupted))
    XCTAssertEqual(snapshot.usedPermitIDs, [identity.writer.uuidString])
    let permit = try XCTUnwrap(snapshot.permits.first)
    // Existing policy retains .open; epoch change does not synthesize an .unknown attestation.
    XCTAssertEqual(permit.closure, .open)
    XCTAssertTrue(permit.revoked)
    XCTAssertEqual(permit.cleanup, .required)
    XCTAssertEqual(permit.owner, lineage)
    XCTAssertEqual(capturedIDs(try record.journal.currentCapture().identity), capturedIDs(identity))
    XCTAssertEqual(try record.journal.currentCapture().confirmedInput, journalFacts)
    assertUnchanged(before, try row("importJob", paper: identity.paperID),
      except: ["state", "failure", "recoveryJournal"])
    assertUnchanged(beforePaper, try row("paper", paper: identity.paperID), except: ["status", "cleanupDebt"])
    XCTAssertEqual(try journal.encoded(maximumBytes: journalBound), bytes)
    let after = try row("importJob", paper: identity.paperID)
    XCTAssertTrue(try ProductJobRecovery(database: database).recoverStartup(currentEpoch: UUID()).interruptedJobs.isEmpty)
    assertUnchanged(after, try row("importJob", paper: identity.paperID))
    database = nil
    database = try ProductDatabase.open(at: root)
    XCTAssertEqual(try journalRecord(identity).encoded, record.encoded)
  }

  func testJournalStartupRetainsPriorResultOlderRetryCapturesAndKnownCleanupDebt() throws {
    let first = try importJob(epoch: UUID())
    var journal = try initializeJournal(first)
    let l = try journal.snapshot().current.lineage
    let result = JobRecoveryPolicy.Result(id: "synthetic-prior-result-not-physical-proof")
    journal = try appendJournal(journal, [
      .acquireWriter(l, permit: first.writer.uuidString),
      .writerClosure(l, permit: first.writer.uuidString, .closed(.validated(result))),
      .acquirePublication(l, writer: first.writer.uuidString, permit: first.publication.uuidString),
      .rename(l, permit: first.publication.uuidString),
      .renameFinished(l, permit: first.publication.uuidString, succeeded: true),
      .publish(l, permit: first.publication.uuidString, result),
      .release(l, permit: first.publication.uuidString)])
    let (second, retried) = try retryJournal(journal)
    journal = retried
    let secondLineage = try journal.snapshot().current.lineage
    let oldOperation = JobRecoveryPolicy.Operation(id: UUID().uuidString, paper: secondLineage.captured.paper)
    journal = try appendJournal(journal, [
      .acquireWriter(secondLineage, permit: second.writer.uuidString),
      .writerClosure(secondLineage, permit: second.writer.uuidString, .closed(.unvalidated)),
      .terminate(secondLineage, .failed),
      .requestCleanup(secondLineage, permit: second.writer.uuidString, operation: oldOperation.id),
      .cleanupFinished(secondLineage, permit: second.writer.uuidString, operation: oldOperation, succeeded: true),
      .release(secondLineage, permit: second.writer.uuidString)])
    let (third, current) = try retryJournal(journal)
    let currentLineage = try current.snapshot().current.lineage
    let operation = JobRecoveryPolicy.Operation(id: UUID().uuidString, paper: currentLineage.captured.paper)
    let authority = currentLineage.captured
    journal = try appendJournal(current, [
      .acquireWriter(currentLineage, permit: third.writer.uuidString),
      .writerClosure(currentLineage, permit: third.writer.uuidString, .closed(.unvalidated)),
      .authorityChanged(.init(input: authority.input, config: authority.config, paper: authority.paper,
        epoch: authority.epoch, prerequisitesAvailable: false)),
      .requestCleanup(currentLineage, permit: third.writer.uuidString, operation: operation.id),
      .cleanupFinished(currentLineage, permit: third.writer.uuidString, operation: operation, succeeded: false)])
    let before = try journal.snapshot()
    let observed = UUID()
    _ = try ProductJobRecovery(database: database).recoverStartup(currentEpoch: observed)
    let record = try journalRecord(third)
    let after = try record.journal.snapshot()
    XCTAssertEqual(after, try journal.recording(.startup(currentEpoch: observed.uuidString)).snapshot())
    XCTAssertEqual(Array(after.executions.dropLast()), Array(before.executions.dropLast()))
    XCTAssertEqual(after.usableResult, before.usableResult)
    XCTAssertEqual(after.usableResult?.result, result)
    XCTAssertEqual(after.permits, before.permits)
    XCTAssertEqual(after.permits.first?.cleanup, .failed)
    XCTAssertEqual(after.usedOperationIDs, [oldOperation.id, operation.id])
    XCTAssertEqual(after.usedPermitIDs, before.usedPermitIDs)
    XCTAssertTrue(try record.journal.extends(journal, maximumBytes: journalBound))
    XCTAssertEqual(capturedIDs(try record.journal.currentCapture().identity), capturedIDs(third))
    XCTAssertEqual(try record.journal.currentCapture().confirmedInput, try current.currentCapture().confirmedInput)
  }

  func testJournalStartupRejectsCorruptNonBlobOversizedAndNonRunningHistoryWithoutFallback() async throws {
    let lifecycle = try await LocalLibraryLifecycle.open(database: database)
    let summary = try await StartupSummaryFixture(database: database, lifecycle: lifecycle, epoch: UUID())
    try summary.reserve()
    let (paperID, generation) = try extractionPaper()
    let extraction = try extraction(paperID, generation, epoch: UUID())
    try database.reserveExtraction(extraction)
    let imports = try [importJob(epoch: UUID()), importJob(epoch: UUID())]
      .sorted { $0.paperID.uuidString < $1.paperID.uuidString }
    let earlier = imports[0], identity = imports[1]
    _ = try initializeJournal(earlier)
    let journal = try initializeJournal(identity)
    let earlierRow = try row("importJob", paper: earlier.paperID)
    let earlierPaper = try row("paper", paper: earlier.paperID)
    let extractionRow = try row("extractionAttempt", paper: paperID)
    let summaryRow = try row("librarySummaryJob", paper: summary.identity.paperID)
    let pending = try ImportRecoveryJournal(identity: identity, confirmedInput: journalFacts)
    let terminated = try journal.recording(.terminate(journal.snapshot().current.lineage, .failed))
    let payloads: [DatabaseValue] = [Data().databaseValue, Data("corrupt".utf8).databaseValue,
      Data(repeating: 0, count: journalBound + 1).databaseValue, "text-not-blob".databaseValue,
      42.databaseValue, try pending.encoded(maximumBytes: journalBound).databaseValue,
      try terminated.encoded(maximumBytes: journalBound).databaseValue]
    for payload in payloads {
      try database.adapterWrite {
        try $0.execute(sql: "UPDATE importJob SET recoveryJournal = ? WHERE id = ?",
          arguments: [payload, identity.jobID.uuidString])
      }
      let before = try row("importJob", paper: identity.paperID)
      let paper = try row("paper", paper: identity.paperID)
      XCTAssertThrowsError(try ProductJobRecovery(database: database).recoverStartup(currentEpoch: UUID())) {
        XCTAssertEqual($0 as? ProductJobRecoveryError, .invalidLineage)
      }
      assertUnchanged(before, try row("importJob", paper: identity.paperID))
      assertUnchanged(paper, try row("paper", paper: identity.paperID))
      assertUnchanged(earlierRow, try row("importJob", paper: earlier.paperID))
      assertUnchanged(earlierPaper, try row("paper", paper: earlier.paperID))
      assertUnchanged(extractionRow, try row("extractionAttempt", paper: paperID))
      assertUnchanged(summaryRow, try row("librarySummaryJob", paper: summary.identity.paperID))
    }
  }

  func testJournalStartupRetainsUnknownWriterWithoutInventingClosure() throws {
    let identity = try importJob(epoch: UUID())
    let claimed = try initializeJournal(identity)
    let lineage = try claimed.snapshot().current.lineage
    let journal = try appendJournal(claimed, [.acquireWriter(lineage, permit: identity.writer.uuidString)])
    let observed = UUID()
    _ = try ProductJobRecovery(database: database).recoverStartup(currentEpoch: observed)
    let snapshot = try journalRecord(identity).journal.snapshot()
    XCTAssertEqual(snapshot, try journal.recording(.startup(currentEpoch: observed.uuidString)).snapshot())
    XCTAssertEqual(snapshot.permits.count, 1)
    XCTAssertEqual(snapshot.permits.first?.closure, .unknown)
    XCTAssertEqual(snapshot.permits.first?.cleanup, .required)
    XCTAssertEqual(snapshot.permits.first?.revoked, true)
    XCTAssertEqual(snapshot.usedPermitIDs, [identity.writer.uuidString])
  }

  func testJournalStartupRejectsEveryReboundCapturedUUID() throws {
    let identity = try importJob(epoch: UUID())
    _ = try initializeJournal(identity)
    let values = capturedIDs(identity)
    let columns = ["paperID", "generation", "id", "attempt", "fence", "correlation", "input", "epoch", "writer", "publication"]
    for index in columns.indices {
      let table = index == 1 ? "paper" : "importJob"
      // paperID is FK-bound: rebind ownership to another genuine owned Paper.
      let replacement: UUID
      if index == 0 { replacement = try extractionPaper().0 } else { replacement = UUID() }
      let scope = index == 1 ? " WHERE id = '\(identity.paperID.uuidString)'" : ""
      try database.adapterWrite { try $0.execute(sql: "UPDATE \(table) SET \(columns[index]) = ?\(scope)",
        arguments: [replacement.uuidString]) }
      let rows = try database.adapterRead { try Row.fetchAll($0, sql: "SELECT * FROM importJob") }
      let papers = try database.adapterRead { try Row.fetchAll($0, sql: "SELECT * FROM paper ORDER BY id") }
      XCTAssertThrowsError(try ProductJobRecovery(database: database).recoverStartup(currentEpoch: UUID())) {
        XCTAssertEqual($0 as? ProductJobRecoveryError, .invalidLineage)
      }
      XCTAssertEqual(rows, try database.adapterRead { try Row.fetchAll($0, sql: "SELECT * FROM importJob") })
      XCTAssertEqual(papers, try database.adapterRead { try Row.fetchAll($0, sql: "SELECT * FROM paper ORDER BY id") })
      try database.adapterWrite { try $0.execute(sql: "UPDATE \(table) SET \(columns[index]) = ?\(scope)",
        arguments: [values[index].uuidString]) }
    }
  }

  func testJournalCurrentEpochAndTerminalRecordsAreNotReadOrRewritten() throws {
    let epoch = UUID()
    let current = try importJob(epoch: epoch)
    _ = try initializeJournal(current)
    let terminal = try importJob(epoch: UUID())
    _ = try initializeJournal(terminal)
    try database.adapterWrite { db in
      try db.execute(sql: "UPDATE importJob SET state = 'failed', recoveryJournal = X'00' WHERE id = ?",
        arguments: [terminal.jobID.uuidString])
    }
    let before = try [current, terminal].map { try row("importJob", paper: $0.paperID) }
    XCTAssertTrue(try ProductJobRecovery(database: database).recoverStartup(currentEpoch: epoch).interruptedJobs.isEmpty)
    for (index, identity) in [current, terminal].enumerated() {
      assertUnchanged(before[index], try row("importJob", paper: identity.paperID))
    }
  }

  func testIgnoredJournalCASRollsBackEarlierImportsOtherKindsAndTriggerMarker() async throws {
    try await journalTriggerRollback(corrupt: false)
  }

  func testCorruptedJournalCASRollsBackEarlierImportsOtherKindsAndTriggerMarker() async throws {
    try await journalTriggerRollback(corrupt: true)
  }

  func testJournalFinalReadbackRejectsPostStateCorruptionAndUnrelatedColumnMutation() throws {
    let identity = try importJob(epoch: UUID())
    _ = try initializeJournal(identity)
    let before = try row("importJob", paper: identity.paperID)
    let paper = try row("paper", paper: identity.paperID)
    for assignment in ["recoveryJournal = X'00'", "recoveryJournal = NULL", "bytesCopied = bytesCopied + 1"] {
      try database.adapterWrite { db in
        try db.execute(sql: """
          CREATE TRIGGER corruptFinalReadback AFTER UPDATE OF state ON importJob
          BEGIN UPDATE importJob SET \(assignment) WHERE id = NEW.id; END;
          """)
      }
      XCTAssertThrowsError(try ProductJobRecovery(database: database).recoverStartup(currentEpoch: UUID())) {
        XCTAssertEqual($0 as? ProductJobRecoveryError, .readbackMismatch)
      }
      assertUnchanged(before, try row("importJob", paper: identity.paperID))
      assertUnchanged(paper, try row("paper", paper: identity.paperID))
      try database.adapterWrite { try $0.execute(sql: "DROP TRIGGER corruptFinalReadback") }
    }
  }

  private func journalTriggerRollback(corrupt: Bool) async throws {
    let lifecycle = try await LocalLibraryLifecycle.open(database: database)
    let summary = try await StartupSummaryFixture(database: database, lifecycle: lifecycle, epoch: UUID())
    try summary.reserve()
    let (paper, generation) = try extractionPaper()
    let extraction = try extraction(paper, generation, epoch: UUID())
    try database.reserveExtraction(extraction)
    let imports = try [importJob(epoch: UUID()), importJob(epoch: UUID())]
      .sorted { $0.paperID.uuidString < $1.paperID.uuidString }
    for identity in imports { _ = try initializeJournal(identity) }
    let jobs = try imports.map { try row("importJob", paper: $0.paperID) }
    let papers = try imports.map { try row("paper", paper: $0.paperID) }
    let extractionRow = try row("extractionAttempt", paper: paper)
    let summaryRow = try row("librarySummaryJob", paper: summary.identity.paperID)
    let configuration = try database.providerConfiguration()
    try database.adapterWrite { db in
      let action = corrupt
        ? "UPDATE importJob SET recoveryJournal = X'00' WHERE id = NEW.id;"
        : "SELECT RAISE(IGNORE);"
      try db.execute(sql: """
        CREATE TRIGGER refuseJournal \(corrupt ? "AFTER" : "BEFORE") UPDATE OF recoveryJournal ON importJob
        WHEN NEW.id = '\(imports[1].jobID.uuidString)'
        BEGIN
          UPDATE providerConfig SET generation = generation + 1;
          UPDATE extractionAttempt SET state = 'failed', failure = 'trigger-marker';
          UPDATE librarySummaryJob SET state = 'failed', failure = 'trigger-marker';
          \(action)
        END;
        """)
    }
    XCTAssertThrowsError(try ProductJobRecovery(database: database).recoverStartup(currentEpoch: lifecycle.epoch)) {
      XCTAssertEqual($0 as? ProductJobRecoveryError, corrupt ? .readbackMismatch : .recoveryConflict)
    }
    for (index, identity) in imports.enumerated() {
      assertUnchanged(jobs[index], try row("importJob", paper: identity.paperID))
      assertUnchanged(papers[index], try row("paper", paper: identity.paperID))
    }
    assertUnchanged(extractionRow, try row("extractionAttempt", paper: paper))
    assertUnchanged(summaryRow, try row("librarySummaryJob", paper: summary.identity.paperID))
    XCTAssertEqual(try database.providerConfiguration().generation, configuration.generation)
  }

  func testSummaryRecoveryRetainsCurrentTerminalFrozenLineageAndVisibleResult() async throws {
    let lifecycle = try await LocalLibraryLifecycle.open(database: database)
    let saved = try await StartupSummaryFixture(database: database, lifecycle: lifecycle, epoch: UUID())
    try saved.reserve()
    let visible = try saved.publish()
    let failed = try StartupSummaryFixture(previous: saved, epoch: UUID())
    try failed.reserve()
    try database.failLibrarySummary(failed.identity)
    let old = try StartupSummaryFixture(previous: saved, epoch: UUID())
    try old.reserve()
    let current = try await StartupSummaryFixture(database: database, lifecycle: lifecycle,
      epoch: lifecycle.epoch)
    try current.reserve()
    func job(_ id: UUID) throws -> Row {
      try database.adapterRead { db in
        try XCTUnwrap(Row.fetchOne(db, sql: "SELECT * FROM librarySummaryJob WHERE job = ?",
          arguments: [id.uuidString]))
      }
    }
    let before = try job(old.identity.job)
    let untouched = try [saved, failed, current].map { try job($0.identity.job) }
    let receipt = try ProductJobRecovery(database: database).recoverStartup(currentEpoch: lifecycle.epoch)
    let recovered = try XCTUnwrap(receipt.interruptedJobs.first { $0.kind == .librarySummary })
    XCTAssertEqual(receipt.interruptedJobs.count, 1)
    XCTAssertEqual(recovered.jobID, old.identity.job)
    XCTAssertEqual(recovered.attempt, old.identity.attempt)
    XCTAssertEqual(recovered.fence, old.identity.fence)
    XCTAssertEqual(recovered.correlation, old.identity.correlation)
    XCTAssertEqual(recovered.inputVersion, old.identity.input)
    XCTAssertEqual(recovered.capturedEpoch, old.identity.epoch)
    XCTAssertEqual(recovered.retainedSummaryResult, visible.id)
    XCTAssertEqual(recovered.retainedExtractionRevision, saved.identity.revision)
    let after = try job(old.identity.job)
    XCTAssertEqual(after["state"] as String, "failed")
    XCTAssertEqual(after["failure"] as String, "interrupted")
    assertUnchanged(before, after, except: ["state", "failure"])
    for (index, fixture) in [saved, failed, current].enumerated() {
      assertUnchanged(untouched[index], try job(fixture.identity.job))
    }
    let restored = try XCTUnwrap(LibrarySummaryService(database: database,
      geometry: StartupSummaryFixture.Geometry()).restore(paperID: saved.identity.paperID))
    XCTAssertEqual(restored.id, visible.id)
    XCTAssertEqual(restored.identity, saved.identity)
    XCTAssertEqual(restored.result, visible.result)
    XCTAssertThrowsError(try old.publish())
    XCTAssertTrue(try ProductJobRecovery(database: database)
      .recoverStartup(currentEpoch: lifecycle.epoch).interruptedJobs.isEmpty)
  }

  func testMalformedOrReboundSummaryLineageRollsBackEarlierJobKinds() async throws {
    let lifecycle = try await LocalLibraryLifecycle.open(database: database)
    let summary = try await StartupSummaryFixture(database: database, lifecycle: lifecycle, epoch: UUID())
    try summary.reserve()
    let oldImport = try importJob(epoch: UUID())
    _ = try initializeJournal(oldImport)
    let oldExtraction = ExtractionIdentity(paperID: summary.identity.paperID,
      generation: summary.identity.generation, pdfSHA256: summary.identity.pdfSHA256,
      pdfReference: "papers/\(summary.identity.paperID.uuidString)/document.pdf",
      revision: UUID(), job: UUID(), attempt: UUID(), fence: UUID(), correlation: UUID(),
      input: UUID(), epoch: UUID(), configuration: try database.providerConfiguration())
    try database.reserveExtraction(oldExtraction)
    let beforeImport = try row("importJob", paper: oldImport.paperID)
    let beforePaper = try row("paper", paper: oldImport.paperID)
    let beforeExtraction = try row("extractionAttempt", paper: summary.identity.paperID)
    let originalFence = summary.identity.fence.uuidString
    try database.adapterWrite { db in
      try db.execute(sql: "UPDATE librarySummaryJob SET fence = ? WHERE job = ?",
        arguments: [UUID().uuidString, summary.identity.job.uuidString])
    }
    XCTAssertThrowsError(try ProductJobRecovery(database: database).recoverStartup(currentEpoch: lifecycle.epoch)) {
      XCTAssertEqual($0 as? ProductJobRecoveryError, .invalidLineage)
    }
    assertUnchanged(beforeImport, try row("importJob", paper: oldImport.paperID))
    assertUnchanged(beforePaper, try row("paper", paper: oldImport.paperID))
    assertUnchanged(beforeExtraction, try row("extractionAttempt", paper: summary.identity.paperID))
    try database.adapterWrite { db in
      try db.execute(sql: "UPDATE librarySummaryJob SET fence = ? WHERE job = ?",
        arguments: [originalFence, summary.identity.job.uuidString])
      try db.execute(sql: """
        CREATE TRIGGER rebindSummaryRecovery AFTER UPDATE OF state ON librarySummaryJob
        BEGIN UPDATE librarySummaryJob SET fence = '\(UUID().uuidString)' WHERE job = new.job; END;
        """)
    }
    XCTAssertThrowsError(try ProductJobRecovery(database: database).recoverStartup(currentEpoch: lifecycle.epoch)) {
      XCTAssertEqual($0 as? ProductJobRecoveryError, .readbackMismatch)
    }
    assertUnchanged(beforeImport, try row("importJob", paper: oldImport.paperID))
    assertUnchanged(beforeExtraction, try row("extractionAttempt", paper: summary.identity.paperID))
  }

  func testMixedStatesAndCurrentEpochRemainUnchangedWhilePriorRunningFails() throws {
    let epoch = UUID()
    let old = try importJob(epoch: UUID())
    let current = try importJob(epoch: epoch)
    var untouched = [current]
    for state in ["pending", "succeeded", "failed"] {
      untouched.append(try importJob(epoch: UUID(), state: state))
    }
    let before = try untouched.map { (try row("importJob", paper: $0.paperID), try row("paper", paper: $0.paperID)) }
    let oldRow = try row("importJob", paper: old.paperID)
    let oldPaper = try row("paper", paper: old.paperID)
    let (paper, generation) = try extractionPaper()
    let currentExtraction = try extraction(paper, generation, epoch: epoch)
    try database.reserveExtraction(currentExtraction)
    let currentExtractionRow = try row("extractionAttempt", paper: paper)

    let receipt = try ProductJobRecovery(database: database).recoverStartup(currentEpoch: epoch)
    XCTAssertEqual(receipt.currentEpoch, epoch)
    XCTAssertEqual(receipt.interruptedJobs.count, 1)
    let recovered = try XCTUnwrap(receipt.interruptedJobs.first)
    XCTAssertEqual(recovered.kind, .import)
    XCTAssertEqual(recovered.paperID, old.paperID)
    XCTAssertEqual(recovered.jobID, old.jobID)
    XCTAssertEqual(recovered.attempt, old.attempt)
    XCTAssertEqual(recovered.fence, old.fence)
    XCTAssertEqual(recovered.correlation, old.correlation)
    XCTAssertEqual(recovered.inputVersion, old.input)
    XCTAssertEqual(recovered.capturedEpoch, old.epoch)
    XCTAssertTrue(recovered.cleanupDebt)
    let failed = try row("importJob", paper: old.paperID)
    XCTAssertEqual(failed["state"] as String, "failed")
    XCTAssertEqual(failed["failure"] as String, "interrupted")
    assertUnchanged(oldRow, failed, except: ["state", "failure"])
    let failedPaper = try row("paper", paper: old.paperID)
    XCTAssertEqual(failedPaper["status"] as String, "importFailed")
    assertUnchanged(oldPaper, failedPaper, except: ["status", "cleanupDebt"])
    for (index, identity) in untouched.enumerated() {
      assertUnchanged(before[index].0, try row("importJob", paper: identity.paperID))
      assertUnchanged(before[index].1, try row("paper", paper: identity.paperID))
    }
    assertUnchanged(currentExtractionRow, try row("extractionAttempt", paper: paper))
    XCTAssertTrue(try ProductJobRecovery(database: database).recoverStartup(currentEpoch: epoch).interruptedJobs.isEmpty)
  }

  func testPriorExtractionPendingAndTerminalStatesAreUnchanged() throws {
    var saved: [(UUID, Row, Row)] = []
    for state in ["pending", "succeeded", "failed"] {
      let (paper, generation) = try extractionPaper()
      let identity = try extraction(paper, generation, epoch: UUID())
      try database.reserveExtraction(identity)
      try database.adapterWrite { db in
        try db.execute(sql: "UPDATE extractionAttempt SET state = ?, failure = 'fixture' WHERE paperID = ?",
          arguments: [state, paper.uuidString])
      }
      saved.append((paper, try row("extractionAttempt", paper: paper), try row("paper", paper: paper)))
    }
    let receipt = try ProductJobRecovery(database: database).recoverStartup(currentEpoch: UUID())
    XCTAssertTrue(receipt.interruptedJobs.isEmpty)
    for (paper, attempt, metadata) in saved {
      assertUnchanged(attempt, try row("extractionAttempt", paper: paper))
      assertUnchanged(metadata, try row("paper", paper: paper))
    }
  }

  func testExistingReadyImportReferenceIsRetainedWithoutAssertingCleanup() throws {
    let identity = try importJob(epoch: UUID())
    let reference = "papers/\(identity.paperID.uuidString)/document.pdf"
    try database.adapterWrite { db in
      try db.execute(sql: "UPDATE paper SET status = 'ready', pdfReference = ?, pdfSHA256 = ? WHERE id = ?",
        arguments: [reference, String(repeating: "c", count: 64), identity.paperID.uuidString])
    }
    let before = try row("paper", paper: identity.paperID)
    let receipt = try ProductJobRecovery(database: database).recoverStartup(currentEpoch: UUID())
    XCTAssertEqual(receipt.interruptedJobs.first?.cleanupDebt, true)
    let after = try row("paper", paper: identity.paperID)
    assertUnchanged(before, after, except: ["cleanupDebt"])
    XCTAssertEqual(after["status"] as String, "ready")
    XCTAssertEqual(after["pdfReference"] as String, reference)
  }

  func testBothKindsPersistAcrossReopenAndRetainUsableExtractionWithoutReplay() throws {
    let oldImport = try importJob(epoch: UUID())
    let namespace = root.appendingPathComponent("papers/\(oldImport.paperID.uuidString)")
    try FileManager.default.createDirectory(at: namespace, withIntermediateDirectories: true)
    let marker = namespace.appendingPathComponent("stage.pdf")
    let bytes = Data("synthetic uncertain producer bytes".utf8)
    try bytes.write(to: marker)
    let (paper, generation) = try extractionPaper()
    let first = try extraction(paper, generation, epoch: UUID())
    try database.reserveExtraction(first)
    // Storage-only fixture: does not assert calibrated geometry or renderer acceptance.
    try publishFixtureExtraction(database, first,
      sentences: [.init(page: 0, sentenceID: 0, text: "retained original", geometry: Data([1, 2, 3]))])
    let interrupted = try extraction(paper, generation, epoch: UUID())
    try database.reserveExtraction(interrupted)
    let before = try row("extractionAttempt", paper: paper)
    let beforePaper = try row("paper", paper: paper)
    let epoch = UUID()
    let receipt = try ProductJobRecovery(database: database).recoverStartup(currentEpoch: epoch)
    XCTAssertEqual(Set(receipt.interruptedJobs.map(\.jobID)), Set([oldImport.jobID, interrupted.job]))
    let extracted = try XCTUnwrap(receipt.interruptedJobs.first { $0.kind == .extraction })
    XCTAssertEqual(extracted.attempt, interrupted.attempt)
    XCTAssertEqual(extracted.capturedEpoch, interrupted.epoch)
    XCTAssertEqual(extracted.retainedExtractionRevision, first.revision)
    XCTAssertFalse(extracted.cleanupDebt)
    assertUnchanged(before, try row("extractionAttempt", paper: paper), except: ["state", "failure"])
    assertUnchanged(beforePaper, try row("paper", paper: paper))
    XCTAssertEqual(try Data(contentsOf: marker), bytes)
    XCTAssertThrowsError(try publishFixtureExtraction(database, interrupted,
      sentences: [.init(page: 0, sentenceID: 0, text: "late stale output", geometry: Data([4]))]))
    XCTAssertThrowsError(try database.publish(oldImport, stage: marker,
      final: namespace.appendingPathComponent("document.pdf"), sha256: String(repeating: "b", count: 64)))
    XCTAssertEqual(try Data(contentsOf: marker), bytes)

    database = nil
    database = try ProductDatabase.open(at: root)
    let status = try database.extractionStatus(paperID: paper)
    XCTAssertEqual(status.state, "failed")
    XCTAssertEqual(status.failure, "interrupted")
    XCTAssertEqual(status.usableRevision, first.revision)
    let hits = try database.searchExtraction(paperID: paper, matching: "retained")
    XCTAssertEqual(hits.map(\.text), ["retained original"])
    XCTAssertEqual(hits.first?.canonicalGeometry, Data([1, 2, 3]))
    XCTAssertEqual(try row("importJob", paper: oldImport.paperID)["failure"] as String, "interrupted")
    XCTAssertTrue(try ProductJobRecovery(database: database).recoverStartup(currentEpoch: epoch).interruptedJobs.isEmpty)
  }

  func testDeletionScopeAndExistingCleanupDebtAreNeverCleared() throws {
    let identity = try importJob(epoch: UUID())
    let saga = UUID()
    try database.adapterWrite { db in
      try db.execute(sql: "UPDATE paper SET status = 'deletionFailed', cleanupDebt = 1, deletionID = ? WHERE id = ?",
        arguments: [saga.uuidString, identity.paperID.uuidString])
    }
    let before = try row("paper", paper: identity.paperID)
    _ = try ProductJobRecovery(database: database).recoverStartup(currentEpoch: UUID())
    assertUnchanged(before, try row("paper", paper: identity.paperID))

    let (paper, generation) = try extractionPaper()
    let next = try extraction(paper, generation, epoch: UUID())
    try database.reserveExtraction(next)
    try database.adapterWrite { db in
      try db.execute(sql: "UPDATE paper SET cleanupDebt = 1, status = 'deleting', deletionID = ? WHERE id = ?",
        arguments: [saga.uuidString, paper.uuidString])
    }
    let deleting = try row("paper", paper: paper)
    let receipt = try ProductJobRecovery(database: database).recoverStartup(currentEpoch: UUID())
    XCTAssertEqual(receipt.interruptedJobs.first?.cleanupDebt, true)
    assertUnchanged(deleting, try row("paper", paper: paper))
  }

  func testExtractionWriteFailureRollsBackEarlierImportRecovery() throws {
    let identity = try importJob(epoch: UUID())
    _ = try initializeJournal(identity)
    let (paper, generation) = try extractionPaper()
    let next = try extraction(paper, generation, epoch: UUID())
    try database.reserveExtraction(next)
    let beforeImport = try row("importJob", paper: identity.paperID)
    let beforePaper = try row("paper", paper: identity.paperID)
    let beforeExtraction = try row("extractionAttempt", paper: paper)
    try database.adapterWrite { db in
      try db.execute(sql: """
        CREATE TRIGGER rejectRecovery BEFORE UPDATE OF state ON extractionAttempt
        BEGIN SELECT RAISE(ABORT, 'synthetic recovery write failure'); END;
        """)
    }
    XCTAssertThrowsError(try ProductJobRecovery(database: database).recoverStartup(currentEpoch: UUID()))
    assertUnchanged(beforeImport, try row("importJob", paper: identity.paperID))
    assertUnchanged(beforePaper, try row("paper", paper: identity.paperID))
    assertUnchanged(beforeExtraction, try row("extractionAttempt", paper: paper))
  }

  func testReadbackRejectsReboundLineageAndRollsBack() throws {
    let identity = try importJob(epoch: UUID())
    let before = try row("importJob", paper: identity.paperID)
    let beforePaper = try row("paper", paper: identity.paperID)
    try database.adapterWrite { db in
      try db.execute(sql: """
        CREATE TRIGGER rebindRecovery AFTER UPDATE OF state ON importJob
        BEGIN UPDATE importJob SET fence = '\(UUID().uuidString)' WHERE id = new.id; END;
        """)
    }
    XCTAssertThrowsError(try ProductJobRecovery(database: database).recoverStartup(currentEpoch: UUID())) { error in
      XCTAssertEqual(error as? ProductJobRecoveryError, .readbackMismatch)
    }
    assertUnchanged(before, try row("importJob", paper: identity.paperID))
    assertUnchanged(beforePaper, try row("paper", paper: identity.paperID))
  }

  func testMalformedDurableLineageRollsBackAllKinds() throws {
    let identity = try importJob(epoch: UUID())
    _ = try initializeJournal(identity)
    let (paper, generation) = try extractionPaper()
    let next = try extraction(paper, generation, epoch: UUID())
    try database.reserveExtraction(next)
    try database.adapterWrite { db in
      try db.execute(sql: "UPDATE extractionAttempt SET epoch = 'not-an-epoch' WHERE paperID = ?",
        arguments: [paper.uuidString])
    }
    let before = try row("importJob", paper: identity.paperID)
    let beforePaper = try row("paper", paper: identity.paperID)
    XCTAssertThrowsError(try ProductJobRecovery(database: database).recoverStartup(currentEpoch: UUID())) { error in
      XCTAssertEqual(error as? ProductJobRecoveryError, .invalidLineage)
    }
    assertUnchanged(before, try row("importJob", paper: identity.paperID))
    assertUnchanged(beforePaper, try row("paper", paper: identity.paperID))
    XCTAssertEqual(try row("extractionAttempt", paper: paper)["state"] as String, "running")
  }
}
