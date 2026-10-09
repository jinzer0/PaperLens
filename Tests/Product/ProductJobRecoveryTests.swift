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
      try XCTUnwrap(Row.fetchOne(db, sql: "SELECT generation, pdfSHA256 FROM paper WHERE id = ?",
        arguments: [paper.uuidString]))
    }
    let generation: String = row["generation"]
    let hash: String = row["pdfSHA256"]
    let extraction = ExtractionIdentity(paperID: paper,
      generation: try XCTUnwrap(UUID(uuidString: generation)), pdfSHA256: hash,
      pdfReference: "papers/\(paper.uuidString)/document.pdf", revision: UUID(), job: UUID(),
      attempt: UUID(), fence: UUID(), correlation: UUID(), input: UUID(), epoch: lifecycle.epoch,
      configuration: try database.providerConfiguration())
    try database.reserveExtraction(extraction)
    let quotes = ["main contribution alpha", "results conclusion beta"]
    try database.publishExtraction(extraction, sentences: quotes.enumerated().map {
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
    try database.reserveImport(identity, title: "Synthetic import")
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
    try database.publishExtraction(first,
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
    XCTAssertThrowsError(try database.publishExtraction(interrupted,
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
