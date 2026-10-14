import CryptoKit
import Darwin
import Foundation
import GRDB
import ProviderRequest
import XCTest

@testable import PaperLensProduct

private enum SyntheticPurgeError: Error { case failed, stillPresent }

private enum OwnedCopyFault: Error { case close, open }

private enum OwnedNamespaceFixtureError: Error { case prerequisite(String) }

/// Effects operate only on this test's real private files/handles. Scope counters model a
/// granted scope; they are not evidence of a sandbox extension on ordinary temporary URLs.
private final class OwnedCopyEffects: @unchecked Sendable {
  private let lock = NSLock()
  private var closeAttempts: [ActualCopyEndpoint] = []
  private var starts = 0
  private var stops = 0
  private weak var input: FileHandle?
  private weak var output: FileHandle?
  private var inputFD: Int32?
  private var outputFD: Int32?
  private var completions: [ActualCopyCompletionObservation] = []
  private var completionCloseCensus: [[ActualCopyEndpoint]] = []
  private var completionScopeCensus: [[Int]] = []
  private var completionClosedFDs: [Bool] = []
  private var outputSeals: [Bool] = []
  private var outputSizes: [Int64] = []
  let failures: Set<ActualCopyEndpoint>
  let beforeOpen: @Sendable (ActualCopyEndpoint, URL) throws -> Void

  init(failures: Set<ActualCopyEndpoint> = [],
    beforeOpen: @escaping @Sendable (ActualCopyEndpoint, URL) throws -> Void = { _, _ in }) {
    self.failures = failures
    self.beforeOpen = beforeOpen
  }

  var effects: ActualCopyEffects {
    ActualCopyEffects(beforeOpen: beforeOpen, checkedClose: { endpoint, handle in
      self.lock.withLock {
        self.closeAttempts.append(endpoint)
        // Capture before attempting close. Runtime never uses descriptor-number probes.
        if endpoint == .input { self.input = handle; self.inputFD = handle.fileDescriptor }
        else {
          self.output = handle
          self.outputFD = handle.fileDescriptor
          var info = stat()
          let inspected = Darwin.fstat(handle.fileDescriptor, &info) == 0
          self.outputSeals.append(inspected && info.st_mode & 0o7777 == 0o400)
          self.outputSizes.append(inspected ? info.st_size : -1)
        }
      }
      if self.failures.contains(endpoint) { throw OwnedCopyFault.close }
      try handle.close()
    }, startScope: { _ in self.lock.withLock { self.starts += 1 }; return true },
      stopScope: { _ in self.lock.withLock { self.stops += 1 } },
      completed: { observation in
        self.lock.withLock {
          self.completions.append(observation)
          self.completionCloseCensus.append(self.closeAttempts)
          self.completionScopeCensus.append([self.starts, self.stops])
          // Fixture-only probes record timing, never grant runtime closure authority.
          self.completionClosedFDs.append([self.inputFD, self.outputFD].compactMap { $0 }
            .allSatisfy { Darwin.fcntl($0, F_GETFD) == -1 })
        }
      })
  }

  var observations: [ActualCopyCompletionObservation] { lock.withLock { completions } }
  var observedCloseCensus: [[ActualCopyEndpoint]] { lock.withLock { completionCloseCensus } }
  var observedScopeCensus: [[Int]] { lock.withLock { completionScopeCensus } }
  var observedClosedFDs: [Bool] { lock.withLock { completionClosedFDs } }
  var observedOutputSeals: [Bool] { lock.withLock { outputSeals } }
  var observedOutputSizes: [Int64] { lock.withLock { outputSizes } }
  var census: [ActualCopyEndpoint] { lock.withLock { closeAttempts } }
  var scopeCensus: [Int] { lock.withLock { [starts, stops] } }
  func retained(_ endpoint: ActualCopyEndpoint) -> Bool {
    lock.withLock { endpoint == .input ? input != nil : output != nil }
  }
  func acquiredFD(_ endpoint: ActualCopyEndpoint) -> Int32? {
    lock.withLock { endpoint == .input ? inputFD : outputFD }
  }

  func physicallyTearDown(_ debt: ActualCopyDebt) throws {
    // Numeric fixture teardown is not a second checked close, scope ACK or quota release.
    for endpoint in [ActualCopyEndpoint.output, .input] {
      let known = endpoint == .output ? debt.outputClosed : debt.inputClosed
      if !known {
        let fd = try XCTUnwrap(acquiredFD(endpoint))
        guard Darwin.close(fd) == 0 else {
          throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
      }
    }
  }
}

/// Test-only peer owns and actually removes a separate synthetic Agent namespace.
private actor SyntheticAgentPurge: AgentLibraryPurging {
  let root: URL
  var shouldFail = false
  var wrongReceipt = false
  var invocations: [UUID] = []
  var hold = false
  var held: CheckedContinuation<Void, Never>?
  var observed: [CheckedContinuation<Void, Never>] = []

  init(root: URL) { self.root = root }
  func fail(_ value: Bool) { shouldFail = value }
  func mismatch(_ value: Bool) { wrongReceipt = value }
  func setHold() { hold = true }
  func waitForInvocation() async {
    if !invocations.isEmpty { return }
    await withCheckedContinuation { observed.append($0) }
  }
  func release() {
    hold = false
    held?.resume()
    held = nil
  }
  func sagaIDs() -> [UUID] { invocations }

  func purgeLibraryPaper(paperID: UUID, deletionID: UUID) async throws -> AgentLibraryPurgeReceipt {
    invocations.append(deletionID)
    for continuation in observed { continuation.resume() }
    observed.removeAll()
    if hold { await withCheckedContinuation { held = $0 } }
    if shouldFail { throw SyntheticPurgeError.failed }
    let namespace = root.appendingPathComponent(paperID.uuidString)
    if FileManager.default.fileExists(atPath: namespace.path) {
      try FileManager.default.removeItem(at: namespace)
    }
    guard !FileManager.default.fileExists(atPath: namespace.path) else {
      throw SyntheticPurgeError.stillPresent
    }
    return AgentLibraryPurgeReceipt(paperID: wrongReceipt ? UUID() : paperID, deletionID: deletionID)
  }
}

final class LocalLibraryLifecycleTests: XCTestCase, @unchecked Sendable {
  private var temporary: URL!
  private var retainsUnknownFixture = false
  private var root: URL { temporary.appendingPathComponent("product", isDirectory: true) }

  override func setUpWithError() throws {
    temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
  }

  override func tearDownWithError() throws {
    if let temporary, !retainsUnknownFixture { try FileManager.default.removeItem(at: temporary) }
    temporary = nil
  }

  private func source(_ name: String = "synthetic.pdf", bytes: Data? = nil) throws -> URL {
    let url = temporary.appendingPathComponent(name)
    try (bytes ?? Data("%PDF-1.7\nprivate synthetic bytes\n%%EOF\n".utf8)).write(to: url)
    return url
  }

  private func namespace(_ id: UUID) -> URL {
    root.appendingPathComponent("papers").appendingPathComponent(id.uuidString)
  }

  private func identity() -> ImportIdentity {
    ImportIdentity(paperID: UUID(), generation: UUID(), jobID: UUID(), attempt: UUID(),
      fence: UUID(), correlation: UUID(), input: UUID(), epoch: UUID(), writer: UUID(), publication: UUID())
  }

  private func makeAgent() -> SyntheticAgentPurge {
    SyntheticAgentPurge(root: temporary.appendingPathComponent("agent"))
  }

  private func observeImport(_ db: ProductDatabase, _ id: ImportIdentity) throws -> [String] {
    try db.adapterRead { sql in
      let row = try XCTUnwrap(Row.fetchOne(sql, sql: """
        SELECT p.status AS paperStatus, p.generation, p.pdfReference, p.pdfSHA256,
          p.cleanupDebt, p.deletionID, j.state AS jobState, j.bytesCopied, j.failure,
          j.attempt, j.fence, j.correlation, j.input, j.epoch, j.writer, j.publication
        FROM paper p, importJob j WHERE p.id = ? AND j.id = ?
        """, arguments: [id.paperID.uuidString, id.jobID.uuidString]))
      let columns = ["paperStatus", "generation", "pdfReference", "pdfSHA256", "deletionID",
        "jobState", "failure", "attempt", "fence", "correlation", "input", "epoch", "writer", "publication"]
      let text = columns.map { column -> String in
        let value: String? = row[column]
        return value ?? "<absent>"
      }
      let debt: Int64 = row["cleanupDebt"]
      let bytes: Int64 = row["bytesCopied"]
      return text + [String(debt), String(bytes)]
    }
  }

  func testEveryImportMutationRejectsEachForeignExecutionIdentity() throws {
    let db = try ProductDatabase.open(at: root)
    let current = identity()
    try reserveLegacyImportFixture(in: db, identity: current, title: "owned exact lineage")
    try db.recordProgress(current, bytes: 7)
    let original = try observeImport(db, current)
    let owned = namespace(current.paperID)
    try FileManager.default.createDirectory(at: owned, withIntermediateDirectories: true)
    let stage = owned.appendingPathComponent("guard.stage")
    let final = owned.appendingPathComponent("document.pdf")
    let marker = Data("owned guarded stage".utf8)
    try marker.write(to: stage)
    for field in ["paper", "generation", "job", "attempt", "fence", "correlation", "input", "epoch", "writer", "publication"] {
      let foreign = ImportIdentity(paperID: field == "paper" ? UUID() : current.paperID,
        generation: field == "generation" ? UUID() : current.generation,
        jobID: field == "job" ? UUID() : current.jobID,
        attempt: field == "attempt" ? UUID() : current.attempt,
        fence: field == "fence" ? UUID() : current.fence,
        correlation: field == "correlation" ? UUID() : current.correlation,
        input: field == "input" ? UUID() : current.input,
        epoch: field == "epoch" ? UUID() : current.epoch,
        writer: field == "writer" ? UUID() : current.writer,
        publication: field == "publication" ? UUID() : current.publication)
      XCTAssertThrowsError(try db.recordProgress(foreign, bytes: 99)) {
        XCTAssertEqual($0 as? ProductDatabaseError, .staleImport, field)
      }
      XCTAssertThrowsError(try db.failImport(foreign, failure: "late", cleanupDebt: true)) {
        XCTAssertEqual($0 as? ProductDatabaseError, .staleImport, field)
      }
      XCTAssertThrowsError(try db.recordImportAbort(foreign, failure: "late", cleanupDebt: true)) {
        XCTAssertEqual($0 as? ProductDatabaseError, .staleImport, field)
      }
      XCTAssertThrowsError(try db.publish(foreign, stage: stage, final: final,
        sha256: String(repeating: "a", count: 64))) {
        XCTAssertEqual($0 as? ProductDatabaseError, .staleImport, field)
      }
      XCTAssertEqual(try observeImport(db, current), original, field)
      XCTAssertEqual(try Data(contentsOf: stage), marker, field)
      XCTAssertFalse(FileManager.default.fileExists(atPath: final.path), field)
    }
  }

  func testOldImportFailureAndProgressCannotMutateReopenedNewerExecution() throws {
    var db: ProductDatabase? = try ProductDatabase.open(at: root)
    let old = identity()
    try reserveLegacyImportFixture(in: db!, identity: old, title: "owned old execution")
    let next = ImportIdentity(paperID: old.paperID, generation: old.generation, jobID: old.jobID,
      attempt: UUID(), fence: UUID(), correlation: UUID(), input: UUID(), epoch: UUID(), writer: UUID(), publication: UUID())
    // Adversarial owned SQL fixture, not an implemented Retry or fabricated history API.
    try db!.adapterWrite { sql in
      try sql.execute(sql: """
        UPDATE importJob SET attempt = ?, fence = ?, correlation = ?, input = ?, epoch = ?,
          writer = ?, publication = ? WHERE id = ?
        """, arguments: [next.attempt.uuidString, next.fence.uuidString, next.correlation.uuidString,
          next.input.uuidString, next.epoch.uuidString, next.writer.uuidString,
          next.publication.uuidString, next.jobID.uuidString])
    }
    db = nil
    let reopened = try ProductDatabase.open(at: root)
    let before = try observeImport(reopened, next)
    XCTAssertThrowsError(try reopened.failImport(old, failure: "late", cleanupDebt: true)) {
      XCTAssertEqual($0 as? ProductDatabaseError, .staleImport)
    }
    XCTAssertThrowsError(try reopened.recordProgress(old, bytes: 40)) {
      XCTAssertEqual($0 as? ProductDatabaseError, .staleImport)
    }
    XCTAssertEqual(try observeImport(reopened, next), before)
    try reopened.recordProgress(next, bytes: 8)
    try reopened.failImport(next, failure: "current", cleanupDebt: false)
    let record = try XCTUnwrap(reopened.libraryRecords().first)
    XCTAssertEqual(record.status, .importFailed)
    XCTAssertEqual(record.bytesCopied, 8)
    XCTAssertEqual(record.failure, "current")
    XCTAssertFalse(record.cleanupDebt)
    let terminal = try observeImport(reopened, next)
    XCTAssertThrowsError(try reopened.failImport(next, failure: "duplicate", cleanupDebt: true))
    XCTAssertEqual(try observeImport(reopened, next), terminal)
  }

  func testImportFailureRowRefusalRollsBackPaperAndDebtAtomically() throws {
    let db = try ProductDatabase.open(at: root)
    let current = identity()
    try reserveLegacyImportFixture(in: db, identity: current, title: "owned rollback")
    let before = try observeImport(db, current)
    try db.adapterWrite { sql in
      try sql.execute(sql: """
        CREATE TRIGGER refuse_import_failure BEFORE UPDATE OF state ON importJob
        WHEN NEW.state = 'failed' BEGIN SELECT RAISE(IGNORE); END
        """)
    }
    XCTAssertThrowsError(try db.failImport(current, failure: "owned fault", cleanupDebt: true)) {
      XCTAssertEqual($0 as? ProductDatabaseError, .staleImport)
    }
    XCTAssertEqual(try observeImport(db, current), before)
    try db.adapterWrite { try $0.execute(sql: "DROP TRIGGER refuse_import_failure") }
    try db.failImport(current, failure: "current", cleanupDebt: true)
    let record = try XCTUnwrap(db.libraryRecords().first)
    XCTAssertEqual(record.status, .importFailed)
    XCTAssertEqual(record.failure, "current")
    XCTAssertTrue(record.cleanupDebt)
  }

  func testImportProgressCannotDecreaseOrCrossDeletionFence() throws {
    let db = try ProductDatabase.open(at: root)
    let current = identity()
    try reserveLegacyImportFixture(in: db, identity: current, title: "owned progress")
    try db.recordProgress(current, bytes: 12)
    let before = try observeImport(db, current)
    for bytes in [Int64(-1), 0, 11] {
      XCTAssertThrowsError(try db.recordProgress(current, bytes: bytes)) {
        XCTAssertEqual($0 as? ProductDatabaseError, .invalidRecord)
      }
      XCTAssertEqual(try observeImport(db, current), before)
    }
    try db.recordProgress(current, bytes: 12)
    _ = try db.beginDeletion(current.paperID)
    let deleting = try observeImport(db, current)
    XCTAssertThrowsError(try db.recordProgress(current, bytes: 13)) {
      XCTAssertEqual($0 as? ProductDatabaseError, .staleImport)
    }
    XCTAssertThrowsError(try db.failImport(current, failure: "late", cleanupDebt: true)) {
      XCTAssertEqual($0 as? ProductDatabaseError, .staleImport)
    }
    XCTAssertEqual(try observeImport(db, current), deleting)
  }

  func testExactDeletingAbortPreservesSagaFailureAndOtherCleanupDebt() throws {
    let db = try ProductDatabase.open(at: root)
    let current = identity()
    try reserveLegacyImportFixture(in: db, identity: current, title: "owned deleting abort")
    _ = try db.beginDeletion(current.paperID)
    let before = try observeImport(db, current)
    try db.recordImportAbort(current, failure: "cancelled", cleanupDebt: false)
    XCTAssertEqual(try observeImport(db, current), before)
    try db.recordImportAbort(current, failure: "cancelled", cleanupDebt: true)
    var indebted = before
    indebted[indebted.count - 2] = "1"
    XCTAssertEqual(try observeImport(db, current), indebted)
    try db.recordImportAbort(current, failure: "cancelled", cleanupDebt: false)
    XCTAssertEqual(try observeImport(db, current), indebted)
    let foreign = ImportIdentity(paperID: current.paperID, generation: current.generation,
      jobID: current.jobID, attempt: current.attempt, fence: UUID(), correlation: current.correlation,
      input: current.input, epoch: current.epoch, writer: current.writer, publication: current.publication)
    XCTAssertThrowsError(try db.recordImportAbort(foreign, failure: "late", cleanupDebt: true)) {
      XCTAssertEqual($0 as? ProductDatabaseError, .staleImport)
    }
    XCTAssertEqual(try observeImport(db, current), indebted)
    try db.adapterWrite { sql in
      try sql.execute(sql: "UPDATE paper SET deletionID = 'malformed' WHERE id = ?",
        arguments: [current.paperID.uuidString])
    }
    let malformed = try observeImport(db, current)
    XCTAssertThrowsError(try db.recordImportAbort(current, failure: "late", cleanupDebt: true)) {
      XCTAssertEqual($0 as? ProductDatabaseError, .invalidRecord)
    }
    XCTAssertEqual(try observeImport(db, current), malformed)
  }

  private func assertActualPoolDenial(_ pool: RequestResourcePool, authority: ProviderRequest,
    file: StaticString = #filePath, line: UInt = #line) {
    let occupied = pool.active
    var acquired: [RequestResourceLease] = []
    while let lease = pool.acquire() { acquired.append(lease) }
    XCTAssertEqual(occupied + acquired.count, authority.limit("importConcurrency"), file: file, line: line)
    XCTAssertNil(pool.acquire(), file: file, line: line)
    for lease in acquired { lease.close() }
    XCTAssertEqual(pool.active, occupied, file: file, line: line)
  }

  func testActualCopyCheckedEndpointCensusAndScopePoolRelease() async throws {
    let authority = try ProviderRequest()
    let pool = try RequestResourcePool(authority: authority, kind: "import")
    let baseline = pool.active
    let db = try ProductDatabase.open(at: root)
    let effects = OwnedCopyEffects()
    let lifecycle = try await LocalLibraryLifecycle.openForOwnedCopyFixtures(database: db, effects: effects.effects)
    let original = try source()
    let bytes = try Data(contentsOf: original)
    let sha = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    let id = try await lifecycle.importPDF(from: original, expectedSHA256: sha)
    XCTAssertEqual(try db.libraryRecords().first?.status, .ready)
    XCTAssertEqual(effects.observations.count, 1)
    let observation = try XCTUnwrap(effects.observations.first)
    XCTAssertEqual(observation.status, .closedValidated)
    XCTAssertEqual(observation.identity.paperID, id)
    XCTAssertEqual(observation.sha256, sha)
    XCTAssertEqual(observation.bytes, Int64(bytes.count))
    XCTAssertNil(observation.error)
    XCTAssertEqual(effects.observedCloseCensus, [[.output, .input]])
    XCTAssertEqual(effects.observedScopeCensus, [[1, 1]])
    XCTAssertEqual(effects.observedClosedFDs, [true])
    XCTAssertEqual(effects.observedOutputSeals, [true])
    XCTAssertEqual(effects.observedOutputSizes, [Int64(bytes.count)])
    let rows = try observeImport(db, observation.identity)
    XCTAssertEqual(rows[0], "ready")
    XCTAssertEqual(rows[3], sha)
    XCTAssertEqual(Array(rows[7...13]), [observation.identity.attempt.uuidString,
      observation.identity.fence.uuidString, observation.identity.correlation.uuidString,
      observation.identity.input.uuidString, observation.identity.epoch.uuidString,
      observation.identity.writer.uuidString, observation.identity.publication.uuidString])
    XCTAssertEqual(rows[1], observation.identity.generation.uuidString)
    let history = try db.adapterRead { sql in
      try ProductDatabase.readImportRecovery(observation.identity,
        maximumBytes: ProductJobRecovery.maximumImportRecoveryJournalBytes, in: sql)
    }
    let capture = try history.journal.currentCapture()
    XCTAssertEqual(capture.confirmedInput,
      .init(expectedSHA256: sha, destinationFolderID: nil))
    let published = try history.journal.snapshot()
    XCTAssertEqual(published.current.state, .succeeded)
    XCTAssertTrue(published.permits.isEmpty)
    XCTAssertEqual(published.usedPermitIDs,
      [observation.identity.writer.uuidString, observation.identity.publication.uuidString])
    XCTAssertEqual(published.usableResult?.result.id, observation.identity.attempt.uuidString)
    XCTAssertEqual(try history.journal.encoded(
      maximumBytes: ProductJobRecovery.maximumImportRecoveryJournalBytes), history.encoded)
    let owned = namespace(id).appendingPathComponent("document.pdf")
    XCTAssertEqual(try Data(contentsOf: owned), bytes)
    let attributes = try FileManager.default.attributesOfItem(atPath: owned.path)
    XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o400)
    try Data("changed fixture source".utf8).write(to: original)
    let reopened = try ProductDatabase.open(at: root)
    XCTAssertEqual(try observeImport(reopened, observation.identity), rows)
    XCTAssertEqual(try reopened.adapterRead { sql in
      try ProductDatabase.readImportRecovery(observation.identity,
        maximumBytes: ProductJobRecovery.maximumImportRecoveryJournalBytes, in: sql).encoded
    }, history.encoded)
    XCTAssertEqual(try Data(contentsOf: owned), bytes)
    XCTAssertEqual(effects.census, [.output, .input])
    XCTAssertEqual(effects.scopeCensus, [1, 1])
    XCTAssertEqual(pool.active, baseline)
    XCTAssertFalse(LocalLibraryLifecycle.actualCopyDebts.contains { $0.identity.paperID == id })
    assertActualPoolDenial(pool, authority: authority)
  }

  func testJournalReservationRefusalHasNoActualScopeDescriptorOrNamespaceEffects() async throws {
    let authority = try ProviderRequest()
    let pool = try RequestResourcePool(authority: authority, kind: "import")
    let baseline = pool.active
    let db = try ProductDatabase.open(at: root)
    try db.adapterWrite { sql in
      try sql.execute(sql: """
        CREATE TRIGGER rejectActualJournalReservation BEFORE UPDATE OF recoveryJournal ON importJob
        BEGIN SELECT RAISE(IGNORE); END
        """)
    }
    let effects = OwnedCopyEffects()
    let lifecycle = try await LocalLibraryLifecycle.openForOwnedCopyFixtures(database: db, effects: effects.effects)
    let original = try source()
    let bytes = try Data(contentsOf: original)
    do {
      _ = try await lifecycle.importPDF(from: original)
      XCTFail("Refused durable reservation admitted the actual producer")
    } catch {
      XCTAssertEqual(error as? ImportRecoveryPersistenceError, .staleHistory)
    }
    XCTAssertTrue(effects.census.isEmpty)
    XCTAssertTrue(effects.observations.isEmpty)
    XCTAssertEqual(effects.scopeCensus, [0, 0])
    XCTAssertEqual(pool.active, baseline)
    XCTAssertTrue(try db.libraryRecords().isEmpty)
    XCTAssertEqual(try db.adapterRead { sql in
      try Int.fetchOne(sql, sql: "SELECT COUNT(*) FROM importJob")
    }, 0)
    XCTAssertFalse(FileManager.default.fileExists(atPath: db.root.appendingPathComponent("papers").path),
      "Failed durable reservation must not create even the namespace parent")
    XCTAssertEqual(try Data(contentsOf: original), bytes)
  }

  func testActualBodyClosureUnknownLabelDoesNotOverrideKnownPhysicalClosure() async throws {
    let authority = try ProviderRequest()
    let pool = try RequestResourcePool(authority: authority, kind: "import")
    let baseline = pool.active
    let db = try ProductDatabase.open(at: root)
    let effects = OwnedCopyEffects(beforeOpen: { endpoint, _ in
      if endpoint == .output { throw LocalLibraryError.producerClosureUnknown }
    })
    let lifecycle = try await LocalLibraryLifecycle.openForOwnedCopyFixtures(database: db, effects: effects.effects)
    let id = try await lifecycle.importPDF(from: source())
    XCTAssertEqual(effects.observations.count, 1)
    let observation = try XCTUnwrap(effects.observations.first)
    XCTAssertEqual(observation.identity.paperID, id)
    XCTAssertEqual(observation.status, .closedUnvalidated)
    XCTAssertEqual(observation.error as? LocalLibraryError, .producerClosureUnknown)
    XCTAssertNil(observation.sha256)
    XCTAssertNil(observation.bytes)
    XCTAssertEqual(effects.census, [.input])
    XCTAssertEqual(effects.observedCloseCensus, [[.input]])
    XCTAssertEqual(effects.observedClosedFDs, [true])
    XCTAssertEqual(effects.observedScopeCensus, [[1, 1]])
    XCTAssertEqual(pool.active, baseline)
    XCTAssertFalse(LocalLibraryLifecycle.actualCopyDebts.contains { $0.identity.paperID == id })
    XCTAssertFalse(FileManager.default.fileExists(atPath: namespace(id).path))
    let rows = try observeImport(db, observation.identity)
    XCTAssertEqual(rows[0], "importFailed")
    XCTAssertEqual(rows[5], "failed")
    XCTAssertEqual(rows[6], "importFailed")
    XCTAssertEqual(rows[14], "0")
    let history = try db.adapterRead { sql in
      try ProductDatabase.readImportRecovery(observation.identity,
        maximumBytes: ProductJobRecovery.maximumImportRecoveryJournalBytes, in: sql)
    }
    let failed = try history.journal.snapshot()
    XCTAssertEqual(failed.current.state, .failed(.failed))
    XCTAssertTrue(failed.permits.isEmpty, "Actual known closure and cleanup must be durably acknowledged")
    XCTAssertEqual(failed.usedOperationIDs.count, 1)
    let reopened = try ProductDatabase.open(at: root)
    XCTAssertEqual(try observeImport(reopened, observation.identity), rows)
    XCTAssertEqual(try reopened.adapterRead { sql in
      try ProductDatabase.readImportRecovery(observation.identity,
        maximumBytes: ProductJobRecovery.maximumImportRecoveryJournalBytes, in: sql).encoded
    }, history.encoded)
    XCTAssertFalse(try XCTUnwrap(reopened.libraryRecords().first { $0.id == id }).cleanupDebt)
  }

  func testActualConfirmedHashMismatchClosesButNeverValidates() async throws {
    let authority = try ProviderRequest()
    let pool = try RequestResourcePool(authority: authority, kind: "import")
    let baseline = pool.active
    let db = try ProductDatabase.open(at: root)
    let effects = OwnedCopyEffects()
    let lifecycle = try await LocalLibraryLifecycle.openForOwnedCopyFixtures(database: db, effects: effects.effects)
    let original = try source()
    let bytes = try Data(contentsOf: original)
    let id = try await lifecycle.importPDF(from: original, expectedSHA256: String(repeating: "0", count: 64))
    XCTAssertEqual(effects.observations.count, 1)
    let observation = try XCTUnwrap(effects.observations.first)
    XCTAssertEqual(observation.identity.paperID, id)
    XCTAssertEqual(observation.status, .closedUnvalidated)
    XCTAssertEqual(observation.error as? FolderImportError, .sourceChanged)
    XCTAssertNil(observation.sha256)
    XCTAssertNil(observation.bytes)
    XCTAssertEqual(effects.census, [.output, .input])
    XCTAssertEqual(effects.observedCloseCensus, [[.output, .input]])
    XCTAssertEqual(effects.observedScopeCensus, [[1, 1]])
    XCTAssertEqual(effects.observedClosedFDs, [true])
    XCTAssertEqual(effects.observedOutputSeals, [true])
    XCTAssertEqual(effects.observedOutputSizes, [Int64(bytes.count)])
    XCTAssertEqual(pool.active, baseline)
    XCTAssertFalse(LocalLibraryLifecycle.actualCopyDebts.contains { $0.identity.paperID == id })
    XCTAssertFalse(FileManager.default.fileExists(atPath: namespace(id).path))
    let rows = try observeImport(db, observation.identity)
    XCTAssertEqual(rows[0], "importFailed")
    XCTAssertEqual(rows[2], "<absent>")
    XCTAssertEqual(rows[3], "<absent>")
    XCTAssertEqual(rows[5], "failed")
    XCTAssertEqual(rows[6], "sourceChanged")
    XCTAssertEqual(rows[14], "0")
    XCTAssertEqual(rows[15], String(bytes.count))
    let history = try db.adapterRead { sql in
      try ProductDatabase.readImportRecovery(observation.identity,
        maximumBytes: ProductJobRecovery.maximumImportRecoveryJournalBytes, in: sql)
    }
    XCTAssertEqual(try history.journal.currentCapture().confirmedInput,
      .init(expectedSHA256: String(repeating: "0", count: 64), destinationFolderID: nil))
    let failed = try history.journal.snapshot()
    XCTAssertEqual(failed.current.state, .failed(.failed))
    XCTAssertTrue(failed.permits.isEmpty)
    XCTAssertNil(failed.usableResult)
    XCTAssertEqual(failed.usedOperationIDs.count, 1)
    let reopened = try ProductDatabase.open(at: root)
    XCTAssertEqual(try observeImport(reopened, observation.identity), rows)
    XCTAssertEqual(try reopened.adapterRead { sql in
      try ProductDatabase.readImportRecovery(observation.identity,
        maximumBytes: ProductJobRecovery.maximumImportRecoveryJournalBytes, in: sql).encoded
    }, history.encoded)
  }

  func testActualNonFileAndNULInputsFailBeforeScopeOrEndpoints() async throws {
    let db = try ProductDatabase.open(at: root)
    let effects = OwnedCopyEffects()
    let lifecycle = try await LocalLibraryLifecycle.openForOwnedCopyFixtures(database: db, effects: effects.effects)
    let nul = URL(filePath: try source().path + "\0tail")
    XCTAssertTrue(nul.path(percentEncoded: false).utf8.contains(0))
    let remote = try XCTUnwrap(URL(string: "https://fixture.invalid/paper.pdf"))
    for candidate in [remote, nul] {
      let id = try await lifecycle.importPDF(from: candidate)
      let record = try XCTUnwrap(db.libraryRecords().first { $0.id == id })
      XCTAssertEqual(record.status, .importFailed)
      XCTAssertFalse(record.cleanupDebt)
      XCTAssertFalse(FileManager.default.fileExists(atPath: namespace(id).path))
    }
    XCTAssertTrue(effects.census.isEmpty)
    XCTAssertEqual(effects.scopeCensus, [0, 0])
    XCTAssertEqual(effects.observations.map(\.status), [.neverStarted, .neverStarted])
  }

  func testActualSourceFIFOAndSymlinkRejectBeforeAcquisition() async throws {
    let db = try ProductDatabase.open(at: root)
    let effects = OwnedCopyEffects()
    let lifecycle = try await LocalLibraryLifecycle.openForOwnedCopyFixtures(database: db, effects: effects.effects)
    let fifo = temporary.appendingPathComponent("fifo.pdf")
    XCTAssertEqual(fifo.withUnsafeFileSystemRepresentation { Darwin.mkfifo($0!, mode_t(0o600)) }, 0)
    let link = temporary.appendingPathComponent("link.pdf")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source())
    for candidate in [fifo, link] {
      let id = try await lifecycle.importPDF(from: candidate)
      let record = try XCTUnwrap(db.libraryRecords().first { $0.id == id })
      XCTAssertEqual(record.status, .importFailed)
      XCTAssertFalse(record.cleanupDebt)
      XCTAssertFalse(FileManager.default.fileExists(atPath: namespace(id).path))
    }
    XCTAssertTrue(effects.census.isEmpty)
    XCTAssertEqual(effects.scopeCensus, [2, 2])
  }

  func testActualCopyAdmissionAtFullContractPoolHasNoEndpointsOrScope() async throws {
    let authority = try ProviderRequest()
    let pool = try RequestResourcePool(authority: authority, kind: "import")
    let baseline = pool.active
    var held: [RequestResourceLease] = []
    while let lease = pool.acquire() { held.append(lease) }
    defer { for lease in held { lease.close() } }
    XCTAssertEqual(baseline + held.count, authority.limit("importConcurrency"))
    XCTAssertNil(pool.acquire())
    let db = try ProductDatabase.open(at: root)
    let effects = OwnedCopyEffects()
    let lifecycle = try await LocalLibraryLifecycle.openForOwnedCopyFixtures(database: db, effects: effects.effects)
    let id = try await lifecycle.importPDF(from: source())
    let record = try XCTUnwrap(db.libraryRecords().first { $0.id == id })
    XCTAssertEqual(record.status, .importFailed)
    XCTAssertFalse(record.cleanupDebt)
    XCTAssertFalse(FileManager.default.fileExists(atPath: namespace(id).path))
    XCTAssertTrue(effects.census.isEmpty)
    XCTAssertEqual(effects.scopeCensus, [0, 0])
    XCTAssertEqual(pool.active, baseline + held.count)
    XCTAssertEqual(effects.observations.count, 1)
    XCTAssertEqual(effects.observations.first?.status, .neverStarted)
    XCTAssertEqual(effects.observations.first?.error as? LocalLibraryError, .importCapacity)
  }

  func testActualSourceSwapToFIFOOrSymlinkOrOtherRegularRejectsPinnedObject() async throws {
    let authority = try ProviderRequest()
    let pool = try RequestResourcePool(authority: authority, kind: "import")
    let baseline = pool.active
    let db = try ProductDatabase.open(at: root)
    for kind in 0..<3 {
      let original = try source("swap-\(kind).pdf")
      let replacement = try source("replacement-\(kind).pdf")
      let parked = temporary.appendingPathComponent("parked-\(kind).pdf")
      let effects = OwnedCopyEffects(beforeOpen: { endpoint, url in
        guard endpoint == .input else { return }
        // Preserve the selected inode under another name: replacement cannot reuse it.
        try FileManager.default.moveItem(at: url, to: parked)
        if kind == 0 {
          guard url.withUnsafeFileSystemRepresentation({ Darwin.mkfifo($0!, mode_t(0o600)) }) == 0
          else { throw OwnedCopyFault.open }
        } else if kind == 1 {
          try FileManager.default.createSymbolicLink(at: url, withDestinationURL: replacement)
        } else { try FileManager.default.moveItem(at: replacement, to: url) }
      })
      let lifecycle = try await LocalLibraryLifecycle.openForOwnedCopyFixtures(database: db, effects: effects.effects)
      let id = try await lifecycle.importPDF(from: original)
      let record = try XCTUnwrap(db.libraryRecords().first { $0.id == id })
      XCTAssertEqual(record.status, .importFailed)
      XCTAssertFalse(record.cleanupDebt)
      XCTAssertEqual(effects.census, kind == 1 ? [] : [.input])
      XCTAssertEqual(effects.scopeCensus, [1, 1])
      XCTAssertEqual(pool.active, baseline)
      XCTAssertFalse(FileManager.default.fileExists(atPath: namespace(id).path))
    }
  }

  func testActualOutputOpenFailureClosesAcquiredInputAndReleases() async throws {
    let authority = try ProviderRequest()
    let pool = try RequestResourcePool(authority: authority, kind: "import")
    let baseline = pool.active
    let db = try ProductDatabase.open(at: root)
    let untouched = try source("collision-target.pdf")
    let originalBytes = try Data(contentsOf: untouched)
    for collision in 0..<3 {
      let effects = OwnedCopyEffects(beforeOpen: { endpoint, stage in
        guard endpoint == .output else { return }
        if collision == 0 { throw OwnedCopyFault.open }
        if collision == 1 { try Data("owned fixture collision".utf8).write(to: stage) }
        else { try FileManager.default.createSymbolicLink(at: stage, withDestinationURL: untouched) }
      })
      let lifecycle = try await LocalLibraryLifecycle.openForOwnedCopyFixtures(database: db, effects: effects.effects)
      let id = try await lifecycle.importPDF(from: source("open-\(collision).pdf"))
      let record = try XCTUnwrap(db.libraryRecords().first { $0.id == id })
      XCTAssertEqual(record.status, .importFailed)
      XCTAssertFalse(record.cleanupDebt)
      XCTAssertEqual(effects.census, [.input])
      XCTAssertEqual(effects.scopeCensus, [1, 1])
      XCTAssertEqual(pool.active, baseline)
      XCTAssertFalse(FileManager.default.fileExists(atPath: namespace(id).path))
      XCTAssertEqual(try Data(contentsOf: untouched), originalBytes)
    }
  }

  func testActualInputCloseUnknownRetainsRealFDPoolScopeAndNamespaceAcrossFacadeLoss() async throws {
    try await assertActualCloseUnknown(failures: [.input])
  }

  func testActualOutputCloseUnknownRetainsRealFDPoolScopeAndNamespaceAcrossFacadeLoss() async throws {
    try await assertActualCloseUnknown(failures: [.output])
  }

  func testActualBothClosesUnknownRetainRealFDsPoolScopeAndNamespaceAcrossFacadeLoss() async throws {
    try await assertActualCloseUnknown(failures: [.input, .output])
  }

  private func assertActualCloseUnknown(failures: Set<ActualCopyEndpoint>) async throws {
    retainsUnknownFixture = true
    let authority = try ProviderRequest()
    let pool = try RequestResourcePool(authority: authority, kind: "import")
    let baseline = pool.active
    let db = try ProductDatabase.open(at: root)
    let original = try source("unknown-close.pdf")
    let effects = OwnedCopyEffects(failures: failures)
    var lifecycle: LocalLibraryLifecycle? = try await LocalLibraryLifecycle.openForOwnedCopyFixtures(
      database: db, effects: effects.effects)
    weak var facade = lifecycle
    let id = try await XCTUnwrap(lifecycle).importPDF(from: original)
    var tornDown = false
    defer {
      if !tornDown, let debt = LocalLibraryLifecycle.actualCopyDebts.first(where: { $0.identity.paperID == id }) {
        do { try effects.physicallyTearDown(debt) }
        catch { XCTFail("Owned numeric fixture teardown failed: \(error)") }
      }
    }
    lifecycle = nil
    XCTAssertNil(facade)
    for endpoint in failures {
      XCTAssertTrue(effects.retained(endpoint))
      XCTAssertNotEqual(Darwin.fcntl(try XCTUnwrap(effects.acquiredFD(endpoint)), F_GETFD), -1)
    }
    let record = try XCTUnwrap(db.libraryRecords().first { $0.id == id })
    XCTAssertEqual(record.status, .importFailed)
    XCTAssertTrue(record.cleanupDebt)
    XCTAssertEqual(try db.libraryRecords().filter { $0.cleanupDebt }.count, 1)
    XCTAssertEqual(effects.census, [.output, .input])
    XCTAssertEqual(effects.scopeCensus, [1, 0])
    XCTAssertEqual(pool.active, baseline + 1)
    let debt = try XCTUnwrap(LocalLibraryLifecycle.actualCopyDebts.first { $0.identity.paperID == id })
    XCTAssertEqual(effects.observations.count, 1)
    let observation = try XCTUnwrap(effects.observations.first)
    XCTAssertEqual(observation.status, .unknown)
    XCTAssertEqual(observation.identity.paperID, id)
    XCTAssertEqual(observation.identity.attempt, debt.identity.attempt)
    XCTAssertNil(observation.sha256)
    XCTAssertNil(observation.bytes)
    XCTAssertEqual(effects.observedCloseCensus, [[.output, .input]])
    XCTAssertEqual(effects.observedScopeCensus, [[1, 0]])
    XCTAssertEqual(effects.observedClosedFDs, [false])
    XCTAssertEqual(debt.source, original)
    XCTAssertEqual(debt.inputClosed, !failures.contains(.input))
    XCTAssertEqual(debt.outputClosed, !failures.contains(.output))
    XCTAssertEqual(try Data(contentsOf: debt.stage), try Data(contentsOf: original))
    XCTAssertFalse(FileManager.default.fileExists(atPath: namespace(id).appendingPathComponent("document.pdf").path))
    let history = try db.adapterRead { sql in
      try ProductDatabase.readImportRecovery(observation.identity,
        maximumBytes: ProductJobRecovery.maximumImportRecoveryJournalBytes, in: sql)
    }
    let failed = try history.journal.snapshot()
    XCTAssertEqual(failed.current.state, .failed(.failed))
    XCTAssertEqual(failed.permits.count, 1)
    XCTAssertTrue(failed.usedOperationIDs.isEmpty, "Unknown producer cannot authorize cleanup")
    assertActualPoolDenial(pool, authority: authority)
    XCTAssertThrowsError(try db.captureRetryableImport(paperID: id, generation: observation.identity.generation)) {
      XCTAssertEqual($0 as? ImportRecoveryPersistenceError, .invalidHistory)
    }
    tornDown = true
    try effects.physicallyTearDown(debt)
    XCTAssertEqual(pool.active, baseline + 1, "Numeric teardown must not return runtime quota")
    XCTAssertEqual(effects.scopeCensus, [1, 0], "Numeric teardown is not scope-close authority")
    XCTAssertEqual(effects.census, [.output, .input])
    XCTAssertTrue(LocalLibraryLifecycle.actualCopyDebts.contains { $0.identity.attempt == debt.identity.attempt })
    XCTAssertTrue(FileManager.default.fileExists(atPath: debt.stage.path))
    XCTAssertTrue(try XCTUnwrap(db.libraryRecords().first { $0.id == id }).cleanupDebt)
    XCTAssertThrowsError(try db.captureRetryableImport(paperID: id, generation: observation.identity.generation)) {
      XCTAssertEqual($0 as? ImportRecoveryPersistenceError, .invalidHistory)
    }
  }

  func testActualPartialOpenUnknownRetainsOnlyAcquiredInputAndPreservesCollision() async throws {
    retainsUnknownFixture = true
    let authority = try ProviderRequest()
    let pool = try RequestResourcePool(authority: authority, kind: "import")
    let baseline = pool.active
    let db = try ProductDatabase.open(at: root)
    let effects = OwnedCopyEffects(failures: [.input], beforeOpen: { endpoint, stage in
      if endpoint == .output { try Data("owned collision never adopted".utf8).write(to: stage) }
    })
    var lifecycle: LocalLibraryLifecycle? = try await LocalLibraryLifecycle.openForOwnedCopyFixtures(
      database: db, effects: effects.effects)
    weak var facade = lifecycle
    let id = try await XCTUnwrap(lifecycle).importPDF(from: source())
    var tornDown = false
    defer {
      if !tornDown, let debt = LocalLibraryLifecycle.actualCopyDebts.first(where: { $0.identity.paperID == id }) {
        do { try effects.physicallyTearDown(debt) }
        catch { XCTFail("Owned physical teardown failed: \(error)") }
      }
    }
    lifecycle = nil
    XCTAssertNil(facade)
    XCTAssertTrue(effects.retained(.input))
    XCTAssertNotEqual(Darwin.fcntl(try XCTUnwrap(effects.acquiredFD(.input)), F_GETFD), -1)
    let debt = try XCTUnwrap(LocalLibraryLifecycle.actualCopyDebts.first { $0.identity.paperID == id })
    XCTAssertNil(debt.output)
    XCTAssertTrue(debt.outputClosed)
    XCTAssertFalse(debt.inputClosed)
    XCTAssertEqual(effects.observations.count, 1)
    let observation = try XCTUnwrap(effects.observations.first)
    XCTAssertEqual(observation.status, .unknown)
    XCTAssertEqual(observation.identity.paperID, id)
    XCTAssertEqual(observation.identity.attempt, debt.identity.attempt)
    XCTAssertNil(observation.sha256)
    XCTAssertNil(observation.bytes)
    XCTAssertEqual(effects.observedCloseCensus, [[.input]])
    XCTAssertEqual(effects.observedScopeCensus, [[1, 0]])
    XCTAssertEqual(effects.observedClosedFDs, [false])
    XCTAssertEqual(effects.census, [.input])
    XCTAssertEqual(effects.scopeCensus, [1, 0])
    XCTAssertEqual(try Data(contentsOf: debt.stage), Data("owned collision never adopted".utf8))
    XCTAssertFalse(FileManager.default.fileExists(atPath: namespace(id).appendingPathComponent("document.pdf").path))
    XCTAssertEqual(try db.libraryRecords().first?.status, .importFailed)
    XCTAssertEqual(try db.libraryRecords().filter { $0.cleanupDebt }.count, 1)
    XCTAssertEqual(pool.active, baseline + 1)
    assertActualPoolDenial(pool, authority: authority)
    tornDown = true
    try effects.physicallyTearDown(debt)
    XCTAssertEqual(pool.active, baseline + 1)
    XCTAssertEqual(effects.scopeCensus, [1, 0])
    XCTAssertEqual(effects.census, [.input])
    XCTAssertTrue(LocalLibraryLifecycle.actualCopyDebts.contains { $0.identity.attempt == debt.identity.attempt })
  }

  func testActualCopyIsIndependentAndPersistsAcrossRestart() async throws {
    let db = try ProductDatabase.open(at: root)
    let lifecycle = try await LocalLibraryLifecycle.open(database: db)
    let original = try source()
    let expected = try Data(contentsOf: original)
    let id = try await lifecycle.importPDF(from: original)
    let records = try await lifecycle.list()
    XCTAssertEqual(records.map(\.id), [id])
    XCTAssertEqual(records.first?.status, .ready)
    XCTAssertEqual(records.first?.bytesCopied, Int64(expected.count))
    let owned = namespace(id).appendingPathComponent("document.pdf")
    try Data("changed source".utf8).write(to: original)
    try FileManager.default.removeItem(at: original)
    XCTAssertEqual(try Data(contentsOf: owned), expected)
    let attributes = try FileManager.default.attributesOfItem(atPath: owned.path)
    XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o400)
    let restartedDB = try ProductDatabase.open(at: root)
    let restarted = try await LocalLibraryLifecycle.open(database: restartedDB)
    let restartedRecords = try await restarted.list()
    XCTAssertEqual(restartedRecords.first?.status, .ready)
  }

  func testSelectionWithoutConfirmationHasZeroDurableOrFileEffects() async throws {
    let db = try ProductDatabase.open(at: root)
    let lifecycle = try await LocalLibraryLifecycle.open(database: db)
    _ = try source() // Represents selecting then cancelling: no use-case invocation.
    let records = try await lifecycle.list()
    XCTAssertTrue(records.isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("papers").path))
  }

  func testMagicAndDeclaredTypeFailuresNeverBecomeReady() async throws {
    let db = try ProductDatabase.open(at: root)
    let lifecycle = try await LocalLibraryLifecycle.open(database: db)
    let wrongMagic = try source("bad.pdf", bytes: Data("not a PDF".utf8))
    let wrongType = try source("bad.txt")
    let first = try await lifecycle.importPDF(from: wrongMagic)
    let second = try await lifecycle.importPDF(from: wrongType)
    let records = try await lifecycle.list()
    XCTAssertEqual(Set(records.map(\.status)), [.importFailed])
    XCTAssertFalse(FileManager.default.fileExists(atPath: namespace(first).path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: namespace(second).path))
    XCTAssertTrue(records.allSatisfy { !$0.cleanupDebt })
  }

  func testSharedExactSizeAndOneOverBoundary() async throws {
    let authority = try ProviderRequest()
    let maximum = authority.limit("pdfBytes")
    let db = try ProductDatabase.open(at: root)
    let lifecycle = try await LocalLibraryLifecycle.open(database: db)
    // Sparse synthetic input avoids a second full-size in-memory fixture.
    let exact = try source("exact.pdf")
    let handle = try FileHandle(forWritingTo: exact)
    try handle.truncate(atOffset: UInt64(maximum))
    try handle.close()
    let exactID = try await lifecycle.importPDF(from: exact)
    let exactRecords = try await lifecycle.list()
    XCTAssertEqual(exactRecords.first(where: { $0.id == exactID })?.status, .ready)
    let tooLarge = try source("one-over.pdf")
    let oversized = try FileHandle(forWritingTo: tooLarge)
    try oversized.truncate(atOffset: UInt64(maximum + 1))
    try oversized.close()
    let overID = try await lifecycle.importPDF(from: tooLarge)
    let overRecords = try await lifecycle.list()
    XCTAssertEqual(overRecords.first(where: { $0.id == overID })?.status, .importFailed)
    XCTAssertFalse(FileManager.default.fileExists(atPath: namespace(overID).path))
  }

  func testActualDeletePurgesPeerAndOwnedCopyBeforeTombstone() async throws {
    let db = try ProductDatabase.open(at: root)
    let agent = makeAgent()
    let lifecycle = try await LocalLibraryLifecycle.open(database: db, agentPurge: agent)
    let id = try await lifecycle.importPDF(from: source())
    let peer = temporary.appendingPathComponent("agent").appendingPathComponent(id.uuidString)
    try FileManager.default.createDirectory(at: peer, withIntermediateDirectories: true)
    try Data("synthetic peer bytes".utf8).write(to: peer.appendingPathComponent("stage"))
    try await lifecycle.delete(paperID: id)
    let records = try await lifecycle.list()
    XCTAssertTrue(records.isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: namespace(id).path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: peer.path))
    let restarted = try await LocalLibraryLifecycle.open(database: ProductDatabase.open(at: root), agentPurge: agent)
    let restartedRecords = try await restarted.list()
    XCTAssertTrue(restartedRecords.isEmpty)
  }

  /// Explicit fake peer only: these cases certify local pathname checks, not Agent purge.
  private func prepareNamespaceDeletion(_ db: ProductDatabase) async throws
    -> (LocalLibraryLifecycle, UUID, Data) {
    let agent = makeAgent()
    let lifecycle = try await LocalLibraryLifecycle.open(database: db, agentPurge: agent)
    let selected = try source()
    let bytes = try Data(contentsOf: selected)
    let id = try await lifecycle.importPDF(from: selected)
    let peer = temporary.appendingPathComponent("agent").appendingPathComponent(id.uuidString)
    try FileManager.default.createDirectory(at: peer, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    try Data("explicit synthetic peer bytes".utf8).write(to: peer.appendingPathComponent("stage"))
    return (lifecycle, id, bytes)
  }

  private func inspectOwnedPath(_ url: URL) throws -> (result: Int32, failure: Int32, info: stat) {
    try url.withUnsafeFileSystemRepresentation { representation in
      let representation = try XCTUnwrap(representation)
      var info = stat()
      let result = Darwin.lstat(representation, &info)
      let failure = errno
      return (result, failure, info)
    }
  }

  private func assertRetainedNamespaceFailure(_ db: ProductDatabase, _ id: UUID, before: [Row]) throws {
    let after = try deletionRows(db, id)
    assertDeletionRowsEqual(before, after,
      paperExcept: ["status", "cleanupDebt", "deletionID", "deletionFailure", "pdfReference"],
      jobExcept: ["recoveryJournal"])
    for pair in zip(before.dropFirst(), after.dropFirst()) {
      let previous = try ImportRecoveryJournal.decode(
        XCTUnwrap(Data.fromDatabaseValue(pair.0["recoveryJournal"])),
        maximumBytes: ProductJobRecovery.maximumImportRecoveryJournalBytes)
      let current = try ImportRecoveryJournal.decode(
        XCTUnwrap(Data.fromDatabaseValue(pair.1["recoveryJournal"])),
        maximumBytes: ProductJobRecovery.maximumImportRecoveryJournalBytes)
      XCTAssertTrue(try current.extends(previous,
        maximumBytes: ProductJobRecovery.maximumImportRecoveryJournalBytes))
      let oldState = try previous.snapshot(), state = try current.snapshot()
      XCTAssertEqual(state.executions, oldState.executions)
      XCTAssertEqual(state.usedPermitIDs, oldState.usedPermitIDs)
      XCTAssertTrue(state.revoked)
      XCTAssertFalse(state.namespaceRemoved)
    }
    XCTAssertNil(String.fromDatabaseValue(after[0]["pdfReference"]))
    let record = try XCTUnwrap(db.libraryRecords().first { $0.id == id })
    XCTAssertEqual(record.status, .deletionFailed)
    XCTAssertEqual(record.failure, "deletionIncomplete")
    XCTAssertTrue(record.cleanupDebt)
    XCTAssertNotNil(String.fromDatabaseValue(after[0]["deletionID"]))
  }

  private func withInaccessibleOwnedPapers(_ operation: () async throws -> Void) async throws {
    let papers = root.appendingPathComponent("papers")
    let original = try inspectOwnedPath(papers)
    XCTAssertEqual(original.result, 0)
    XCTAssertEqual(original.info.st_uid, Darwin.getuid())
    guard original.result == 0, original.info.st_uid == Darwin.getuid(),
      original.info.st_mode & S_IFMT == S_IFDIR else {
      throw OwnedNamespaceFixtureError.prerequisite("Expected this fixture's owned papers directory")
    }
    let mode = original.info.st_mode & 0o7777
    let changed = papers.withUnsafeFileSystemRepresentation { representation in
      representation.map { Darwin.chmod($0, 0) } ?? -1
    }
    guard changed == 0 else {
      throw OwnedNamespaceFixtureError.prerequisite("Cannot chmod the owned papers fixture to 000")
    }
    defer {
      // Fixture teardown only, restoring the exact original mode even on assertion/error.
      let restored = papers.withUnsafeFileSystemRepresentation { representation in
        representation.map { Darwin.chmod($0, mode) } ?? -1
      }
      XCTAssertEqual(restored, 0, "Owned papers fixture must restore its original mode")
    }
    try await operation()
  }

  func testInaccessibleNamespaceAncestorCannotProveAbsenceOrFinalizeDeletion() async throws {
    let db = try ProductDatabase.open(at: root)
    let (lifecycle, id, bytes) = try await prepareNamespaceDeletion(db)
    let before = try deletionRows(db, id)
    try await withInaccessibleOwnedPapers {
      let blocked = try self.inspectOwnedPath(self.namespace(id))
      guard blocked.result == -1, blocked.failure == EACCES || blocked.failure == EPERM else {
        XCTFail("Owned chmod-000 fixture requires actual lstat EACCES/EPERM; got \(blocked.result)/\(blocked.failure)")
        throw OwnedNamespaceFixtureError.prerequisite("Runner must enforce owned ancestor search permissions")
      }
      do {
        try await lifecycle.delete(paperID: id)
        XCTFail("Inaccessible namespace must not be accepted as absent")
      } catch { XCTAssertEqual(error as? LocalLibraryError, .cleanupFailed) }
      try self.assertRetainedNamespaceFailure(db, id, before: before)
    }
    // The fixture's teardown above restores search permission before physical/reopen checks.
    let after = try deletionRows(db, id)
    let retained = try inspectOwnedPath(namespace(id))
    XCTAssertEqual(retained.result, 0)
    XCTAssertEqual(retained.info.st_mode & S_IFMT, S_IFDIR)
    XCTAssertEqual(try Data(contentsOf: namespace(id).appendingPathComponent("document.pdf")), bytes)
    let reopened = try ProductDatabase.open(at: root)
    _ = try await LocalLibraryLifecycle.open(database: reopened, agentPurge: makeAgent())
    try assertRetainedNamespaceFailure(reopened, id, before: before)
    assertDeletionRowsEqual(after, try deletionRows(reopened, id))
    XCTAssertEqual(try Data(contentsOf: namespace(id).appendingPathComponent("document.pdf")), bytes)
  }

  func testSymlinkNamespaceDeniesDeletionAndPreservesOwnedTargetAcrossReopen() async throws {
    let db = try ProductDatabase.open(at: root)
    let (lifecycle, id, bytes) = try await prepareNamespaceDeletion(db)
    let before = try deletionRows(db, id)
    let target = temporary.appendingPathComponent("moved-owned-namespace", isDirectory: true)
    try FileManager.default.moveItem(at: namespace(id), to: target)
    try FileManager.default.createSymbolicLink(at: namespace(id), withDestinationURL: target)
    let link = try inspectOwnedPath(namespace(id))
    XCTAssertEqual(link.result, 0)
    XCTAssertEqual(link.info.st_mode & S_IFMT, S_IFLNK)
    do {
      try await lifecycle.delete(paperID: id)
      XCTFail("Unexpected namespace symlink must not be followed or erased")
    } catch { XCTAssertEqual(error as? LocalLibraryError, .cleanupFailed) }
    try assertRetainedNamespaceFailure(db, id, before: before)
    XCTAssertEqual(try inspectOwnedPath(namespace(id)).info.st_mode & S_IFMT, S_IFLNK)
    XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("document.pdf")), bytes)
    let after = try deletionRows(db, id)
    let reopened = try ProductDatabase.open(at: root)
    _ = try await LocalLibraryLifecycle.open(database: reopened, agentPurge: makeAgent())
    try assertRetainedNamespaceFailure(reopened, id, before: before)
    assertDeletionRowsEqual(after, try deletionRows(reopened, id))
    let retained = try inspectOwnedPath(namespace(id))
    XCTAssertEqual(retained.result, 0)
    XCTAssertEqual(retained.info.st_mode & S_IFMT, S_IFLNK)
    XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: namespace(id).path), target.path)
    XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("document.pdf")), bytes)
  }

  func testRegularFileNamespaceDeniesDeletionAndPreservesObstructionAcrossReopen() async throws {
    let db = try ProductDatabase.open(at: root)
    let (lifecycle, id, bytes) = try await prepareNamespaceDeletion(db)
    let before = try deletionRows(db, id)
    let target = temporary.appendingPathComponent("moved-owned-namespace", isDirectory: true)
    try FileManager.default.moveItem(at: namespace(id), to: target)
    let obstruction = Data("owned regular-file obstruction".utf8)
    try obstruction.write(to: namespace(id))
    let present = try inspectOwnedPath(namespace(id))
    XCTAssertEqual(present.result, 0)
    XCTAssertEqual(present.info.st_mode & S_IFMT, S_IFREG)
    let child = try inspectOwnedPath(namespace(id).appendingPathComponent("document.pdf"))
    XCTAssertEqual(child.result, -1)
    XCTAssertEqual(child.failure, ENOTDIR)
    do {
      try await lifecycle.delete(paperID: id)
      XCTFail("Unexpected regular file must not be erased or accepted as absent")
    } catch { XCTAssertEqual(error as? LocalLibraryError, .cleanupFailed) }
    try assertRetainedNamespaceFailure(db, id, before: before)
    XCTAssertEqual(try Data(contentsOf: namespace(id)), obstruction)
    XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("document.pdf")), bytes)
    let after = try deletionRows(db, id)
    let reopened = try ProductDatabase.open(at: root)
    _ = try await LocalLibraryLifecycle.open(database: reopened, agentPurge: makeAgent())
    try assertRetainedNamespaceFailure(reopened, id, before: before)
    assertDeletionRowsEqual(after, try deletionRows(reopened, id))
    let retained = try inspectOwnedPath(namespace(id))
    XCTAssertEqual(retained.result, 0)
    XCTAssertEqual(retained.info.st_mode & S_IFMT, S_IFREG)
    XCTAssertEqual(try Data(contentsOf: namespace(id)), obstruction)
    XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("document.pdf")), bytes)
  }

  func testAlreadyAbsentNamespaceFinalizesDeletionOnlyAfterActualENOENT() async throws {
    let db = try ProductDatabase.open(at: root)
    let (lifecycle, id, _) = try await prepareNamespaceDeletion(db)
    try FileManager.default.removeItem(at: namespace(id))
    let absent = try inspectOwnedPath(namespace(id))
    XCTAssertEqual(absent.result, -1)
    XCTAssertEqual(absent.failure, ENOENT)
    try await lifecycle.delete(paperID: id)
    let records = try await lifecycle.list()
    XCTAssertTrue(records.isEmpty)
    let finalized = try inspectOwnedPath(namespace(id))
    XCTAssertEqual(finalized.result, -1)
    XCTAssertEqual(finalized.failure, ENOENT)
    let tombstone = try deletionRows(db, id)
    XCTAssertEqual(tombstone.count, 1)
    XCTAssertEqual(String.fromDatabaseValue(tombstone[0]["status"]), "tombstone")
    XCTAssertNil(String.fromDatabaseValue(tombstone[0]["pdfSHA256"]))
    XCTAssertNil(String.fromDatabaseValue(tombstone[0]["pdfReference"]))
    XCTAssertEqual(Int64.fromDatabaseValue(tombstone[0]["cleanupDebt"]), 0)
    let reopened = try ProductDatabase.open(at: root)
    let restarted = try await LocalLibraryLifecycle.open(database: reopened, agentPurge: makeAgent())
    try await restarted.delete(paperID: id)
    let reopenedRecords = try await restarted.list()
    XCTAssertTrue(reopenedRecords.isEmpty)
    assertDeletionRowsEqual(tombstone, try deletionRows(reopened, id))
  }

  func testMissingPurgeBlocksDeletionAndKeepsTruthfulDebt() async throws {
    let db = try ProductDatabase.open(at: root)
    let lifecycle = try await LocalLibraryLifecycle.open(database: db)
    let id = try await lifecycle.importPDF(from: source())
    let before = try deletionRows(db, id)
    do {
      try await lifecycle.delete(paperID: id)
      XCTFail("Absent Agent integration cannot prove deletion")
    } catch { XCTAssertEqual(error as? LocalLibraryError, .agentPurgeUnavailable) }
    let records = try await lifecycle.list()
    XCTAssertEqual(records.first?.status, .deletionFailed)
    XCTAssertEqual(records.first?.failure, "agentPurgeUnavailable")
    XCTAssertEqual(records.first?.cleanupDebt, true)
    XCTAssertTrue(FileManager.default.fileExists(atPath: namespace(id).path))
    let after = try deletionRows(db, id)
    XCTAssertEqual(Array(before[1].columnNames), Array(after[1].columnNames))
    for column in before[1].columnNames where column != "recoveryJournal" {
      let prior: DatabaseValue = before[1][column]
      let retained: DatabaseValue = after[1][column]
      XCTAssertEqual(prior.storage, retained.storage, column)
    }
    let beforeJournal = try ImportRecoveryJournal.decode(try XCTUnwrap(Data.fromDatabaseValue(before[1]["recoveryJournal"])),
      maximumBytes: ProductJobRecovery.maximumImportRecoveryJournalBytes)
    let afterJournal = try ImportRecoveryJournal.decode(try XCTUnwrap(Data.fromDatabaseValue(after[1]["recoveryJournal"])),
      maximumBytes: ProductJobRecovery.maximumImportRecoveryJournalBytes)
    XCTAssertTrue(try afterJournal.extends(beforeJournal, maximumBytes: ProductJobRecovery.maximumImportRecoveryJournalBytes))
    XCTAssertTrue(try afterJournal.snapshot().revoked)
    XCTAssertFalse(try afterJournal.snapshot().namespaceRemoved)
    let restarted = try await LocalLibraryLifecycle.open(database: ProductDatabase.open(at: root))
    let reopened = try await restarted.list()
    XCTAssertEqual(reopened, records)
  }

  func testFailedPurgeRetriesSameSagaAfterRestartWithoutResurrection() async throws {
    let agent = makeAgent()
    await agent.fail(true)
    let db = try ProductDatabase.open(at: root)
    let lifecycle = try await LocalLibraryLifecycle.open(database: db, agentPurge: agent)
    let id = try await lifecycle.importPDF(from: source())
    do { try await lifecycle.delete(paperID: id); XCTFail("Purge must fail") } catch {}
    let restarted = try await LocalLibraryLifecycle.open(database: ProductDatabase.open(at: root), agentPurge: agent)
    let before = try await restarted.list()
    XCTAssertEqual(before.first?.status, .deletionFailed)
    await agent.fail(false)
    try await restarted.retryDeletion(paperID: id)
    let sagas = await agent.sagaIDs()
    XCTAssertEqual(sagas.count, 2)
    XCTAssertEqual(sagas.first, sagas.last)
    let after = try await restarted.list()
    XCTAssertTrue(after.isEmpty)
  }

  func testMismatchedPeerReceiptCannotFinalize() async throws {
    let db = try ProductDatabase.open(at: root)
    let agent = makeAgent()
    await agent.mismatch(true)
    let lifecycle = try await LocalLibraryLifecycle.open(database: db, agentPurge: agent)
    let id = try await lifecycle.importPDF(from: source())
    do { try await lifecycle.delete(paperID: id); XCTFail("Wrong lineage receipt") }
    catch { XCTAssertEqual(error as? LocalLibraryError, .invalidPurgeReceipt) }
    let records = try await lifecycle.list()
    XCTAssertEqual(records.first?.status, .deletionFailed)
    XCTAssertTrue(FileManager.default.fileExists(atPath: namespace(id).path))
  }

  func testDeletionIsUnopenableAndArbitrationAvailableWhilePeerDrainWaits() async throws {
    let db = try ProductDatabase.open(at: root)
    let agent = makeAgent()
    await agent.setHold()
    let lifecycle = try await LocalLibraryLifecycle.open(database: db, agentPurge: agent)
    let id = try await lifecycle.importPDF(from: source())
    let deletion = Task { try await lifecycle.delete(paperID: id) }
    await agent.waitForInvocation()
    let during = try await lifecycle.list()
    XCTAssertEqual(during.first?.status, .deleting)
    XCTAssertTrue(FileManager.default.fileExists(atPath: namespace(id).path))
    await agent.release()
    try await deletion.value
    let after = try await lifecycle.list()
    XCTAssertTrue(after.isEmpty)
  }

  func testRestartInterruptsStageAndNeverPublishesOrphan() async throws {
    let db = try ProductDatabase.open(at: root)
    let pending = identity()
    try reserveLegacyImportFixture(in: db, identity: pending, title: "synthetic interrupted")
    let owned = namespace(pending.paperID)
    try FileManager.default.createDirectory(at: owned, withIntermediateDirectories: true)
    try Data("%PDF-1.7\npartial".utf8).write(to: owned.appendingPathComponent("\(pending.attempt.uuidString).stage"))
    let orphan = namespace(UUID())
    try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
    try Data("%PDF-1.7\norphan".utf8).write(to: orphan.appendingPathComponent("document.pdf"))
    let restarted = try await LocalLibraryLifecycle.open(database: ProductDatabase.open(at: root))
    let records = try await restarted.list()
    XCTAssertEqual(records.count, 1)
    XCTAssertEqual(records.first?.status, .importFailed)
    XCTAssertEqual(records.first?.failure, "interrupted")
    XCTAssertEqual(records.first?.cleanupDebt, true)
    XCTAssertFalse(FileManager.default.fileExists(atPath: owned.appendingPathComponent("document.pdf").path))
  }

  func testStartupUsesOwnedEpochForBothKindsAndRetainsUsableDataAndDeletionDebt() async throws {
    let db = try ProductDatabase.open(at: root)
    let original = try await LocalLibraryLifecycle.open(database: db)
    let ready = try await original.importPDF(from: source())
    let generation: String = try db.adapterRead { database in
      try XCTUnwrap(String.fetchOne(database, sql: "SELECT generation FROM paper WHERE id = ?",
        arguments: [ready.uuidString]))
    }
    let digest: String = try db.adapterRead { database in
      try XCTUnwrap(String.fetchOne(database, sql: "SELECT pdfSHA256 FROM paper WHERE id = ?",
        arguments: [ready.uuidString]))
    }
    func extraction() throws -> ExtractionIdentity {
      .init(paperID: ready, generation: try XCTUnwrap(UUID(uuidString: generation)),
        pdfSHA256: digest, pdfReference: "papers/\(ready.uuidString)/document.pdf",
        revision: UUID(), job: UUID(), attempt: UUID(), fence: UUID(), correlation: UUID(),
        input: UUID(), epoch: original.epoch, configuration: try db.providerConfiguration())
    }
    let usable = try extraction()
    try db.reserveExtraction(usable)
    // Storage fixture only: retained bytes do not attest calibrated geometry.
    try publishFixtureExtraction(db, usable,
      sentences: [.init(page: 0, sentenceID: 0, text: "retained startup text", geometry: Data([1]))])
    let interrupted = try extraction()
    try db.reserveExtraction(interrupted)
    let pending = identity()
    try reserveLegacyImportFixture(in: db, identity: pending, title: "Interrupted owned import")
    let marker = namespace(pending.paperID).appendingPathComponent("\(pending.attempt.uuidString).stage")
    try FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
    let bytes = Data("%PDF-1.7\nuncertain closed-or-open stage".utf8)
    try bytes.write(to: marker)
    let deleting = try await original.importPDF(from: source("deleting.pdf"))
    let saga = try XCTUnwrap(db.beginDeletion(deleting)).saga
    let deletingBytes = try Data(contentsOf: namespace(deleting).appendingPathComponent("document.pdf"))

    let reopened = try ProductDatabase.open(at: root)
    let restarted = try await LocalLibraryLifecycle.open(database: reopened)
    XCTAssertNotEqual(restarted.epoch, original.epoch)
    let running = try reopened.adapterRead { database in
      try Int.fetchOne(database, sql: """
        SELECT (SELECT COUNT(*) FROM importJob WHERE state = 'running') +
          (SELECT COUNT(*) FROM extractionAttempt WHERE state = 'running')
        """)
    }
    XCTAssertEqual(running, 0)
    let status = try reopened.extractionStatus(paperID: ready)
    XCTAssertEqual(status.failure, "interrupted")
    XCTAssertEqual(status.usableRevision, usable.revision)
    XCTAssertEqual(try reopened.searchExtraction(paperID: ready, matching: "retained").map(\.text),
      ["retained startup text"])
    let records = try await restarted.list()
    XCTAssertEqual(records.first { $0.id == ready }?.status, .ready)
    XCTAssertEqual(records.first { $0.id == pending.paperID }?.failure, "interrupted")
    XCTAssertEqual(records.first { $0.id == pending.paperID }?.cleanupDebt, true)
    XCTAssertEqual(records.first { $0.id == deleting }?.status, .deletionFailed)
    XCTAssertEqual(records.first { $0.id == deleting }?.cleanupDebt, true)
    let retainedSaga = try reopened.adapterRead { database in
      try String.fetchOne(database, sql: "SELECT deletionID FROM paper WHERE id = ?",
        arguments: [deleting.uuidString])
    }
    XCTAssertEqual(retainedSaga, saga.uuidString)
    XCTAssertEqual(try Data(contentsOf: marker), bytes)
    XCTAssertEqual(try Data(contentsOf: namespace(deleting).appendingPathComponent("document.pdf")), deletingBytes)
    XCTAssertThrowsError(try publishFixtureExtraction(reopened, interrupted,
      sentences: [.init(page: 0, sentenceID: 0, text: "stale", geometry: Data([2]))]))
    XCTAssertThrowsError(try reopened.publish(pending, stage: marker,
      final: namespace(pending.paperID).appendingPathComponent("document.pdf"),
      sha256: String(repeating: "a", count: 64)))
    let fresh = try await restarted.importPDF(from: source("fresh.pdf"))
    let freshEpoch = try reopened.adapterRead { database in
      try String.fetchOne(database, sql: "SELECT epoch FROM importJob WHERE paperID = ?",
        arguments: [fresh.uuidString])
    }
    XCTAssertEqual(freshEpoch, restarted.epoch.uuidString)
    XCTAssertTrue(try ProductJobRecovery(database: reopened)
      .recoverStartup(currentEpoch: restarted.epoch).interruptedJobs.isEmpty)
  }

  func testMissingReferencedPDFIsFailureOnRestart() async throws {
    let db = try ProductDatabase.open(at: root)
    let lifecycle = try await LocalLibraryLifecycle.open(database: db)
    let id = try await lifecycle.importPDF(from: source())
    let before = try deletionRows(db, id)
    try FileManager.default.removeItem(at: namespace(id).appendingPathComponent("document.pdf"))
    let reopened = try ProductDatabase.open(at: root)
    let restarted = try await LocalLibraryLifecycle.open(database: reopened)
    let records = try await restarted.list()
    XCTAssertEqual(records.first?.status, .importFailed)
    XCTAssertEqual(records.first?.failure, "missingPDF")
    XCTAssertEqual(records.first?.cleanupDebt, true)
    let unavailable = try deletionRows(reopened, id)
    assertDeletionRowsEqual(before, unavailable, paperExcept: ["status", "pdfReference", "cleanupDebt"])
    let capture = try XCTUnwrap(reopened.beginDeletion(id))
    XCTAssertEqual(capture.legacyJobCount, 0)
    XCTAssertEqual(capture.histories.count, 1)
    XCTAssertEqual(try capture.histories[0].journal.snapshot().current.state, .succeeded)
    try reopened.deletionFailed(id, saga: capture.saga, reason: "agentPurgeUnavailable")
    let deleting = try await LocalLibraryLifecycle.open(database: reopened, agentPurge: makeAgent())
    try await deleting.delete(paperID: id)
    let remaining = try await deleting.list()
    XCTAssertTrue(remaining.isEmpty)
    let final = try deletionRows(reopened, id)
    XCTAssertEqual(final.count, 1, "Finalization must erase importJob and full history")
    XCTAssertEqual(String.fromDatabaseValue(final[0]["status"]), "tombstone")
    XCTAssertFalse(FileManager.default.fileExists(atPath: namespace(id).path))
  }

  private func actualRetryFixture() async throws
    -> (ProductDatabase, LocalLibraryLifecycle, ImportRecoveryRecord, URL) {
    let db = try ProductDatabase.open(at: root)
    let lifecycle = try await LocalLibraryLifecycle.open(database: db)
    let selected = try source("initial-confirmed.pdf")
    let confirmed = try Data(contentsOf: selected)
    let digest = SHA256.hash(data: confirmed).map { String(format: "%02x", $0) }.joined()
    var changed = confirmed
    changed[changed.count - 1] = 88
    try changed.write(to: selected)
    let paperID = try await lifecycle.importPDF(from: selected, expectedSHA256: digest)
    let rows = try deletionRows(db, paperID)
    XCTAssertEqual(String.fromDatabaseValue(rows[0]["status"]), "importFailed")
    XCTAssertEqual(String.fromDatabaseValue(rows[1]["failure"]), "sourceChanged")
    XCTAssertEqual(Int64.fromDatabaseValue(rows[0]["cleanupDebt"]), 0)
    let generation = try XCTUnwrap(UUID(uuidString: XCTUnwrap(String.fromDatabaseValue(rows[0]["generation"]))))
    let capture = try db.captureRetryableImport(paperID: paperID, generation: generation)
    XCTAssertEqual(try capture.journal.currentCapture().confirmedInput.expectedSHA256, digest)
    XCTAssertFalse(FileManager.default.fileExists(atPath: namespace(paperID).path))
    return (db, lifecycle, capture, selected)
  }

  func testSameJobRetryPublishesFreshInputAndFolderWithImmutableOldFailureAcrossReopen() async throws {
    let (db, lifecycle, old, original) = try await actualRetryFixture()
    let prior = try old.journal.currentCapture()
    let priorSnapshot = try old.journal.snapshot()
    let originalBytes = try Data(contentsOf: original)
    let folder = try db.createFolder(name: "Fresh Retry destination")
    let bytes = Data("%PDF-1.7\nfresh confirmed retry bytes\n%%EOF\n".utf8)
    let selected = try source("fresh-retry.pdf", bytes: bytes)
    let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    let paperID = try await lifecycle.retryImportPDF(expected: old, from: selected,
      expectedSHA256: digest, destinationFolderID: folder.id)
    XCTAssertEqual(paperID, prior.identity.paperID)
    let rows = try deletionRows(db, paperID)
    let encoded = try XCTUnwrap(Data.fromDatabaseValue(rows[1]["recoveryJournal"]))
    let journal = try ImportRecoveryJournal.decode(encoded,
      maximumBytes: ProductJobRecovery.maximumImportRecoveryJournalBytes)
    let next = try journal.currentCapture()
    XCTAssertEqual(next.identity.paperID, prior.identity.paperID)
    XCTAssertEqual(next.identity.generation, prior.identity.generation)
    XCTAssertEqual(next.identity.jobID, prior.identity.jobID)
    XCTAssertEqual(next.identity.epoch, lifecycle.epoch)
    let fresh = [next.identity.attempt, next.identity.fence, next.identity.correlation,
      next.identity.input, next.identity.writer, next.identity.publication]
    let previous = [prior.identity.attempt, prior.identity.fence, prior.identity.correlation,
      prior.identity.input, prior.identity.writer, prior.identity.publication]
    XCTAssertEqual(Set(fresh).count, 6)
    XCTAssertTrue(Set(fresh).isDisjoint(with: previous))
    XCTAssertEqual(next.confirmedInput, .init(expectedSHA256: digest, destinationFolderID: folder.id))
    XCTAssertTrue(try journal.extends(old.journal, maximumBytes: ProductJobRecovery.maximumImportRecoveryJournalBytes))
    XCTAssertEqual(Array(try journal.snapshot().executions.dropLast()), priorSnapshot.executions)
    XCTAssertEqual(try journal.snapshot().current.state, .succeeded)
    XCTAssertEqual(String.fromDatabaseValue(rows[1]["state"]), "succeeded")
    XCTAssertEqual(Int64.fromDatabaseValue(rows[1]["bytesCopied"]), Int64(bytes.count))
    XCTAssertEqual(try db.folderID(for: paperID), folder.id)
    XCTAssertEqual(try Data(contentsOf: namespace(paperID).appendingPathComponent("document.pdf")), bytes)
    XCTAssertEqual(try Data(contentsOf: original), originalBytes)
    let reopened = try ProductDatabase.open(at: root)
    assertDeletionRowsEqual(rows, try deletionRows(reopened, paperID))
    XCTAssertEqual(try reopened.adapterRead { sql in try Int.fetchOne(sql, sql: "SELECT COUNT(*) FROM importJob") }, 1)
    XCTAssertThrowsError(try reopened.captureRetryableImport(paperID: paperID, generation: next.identity.generation))
  }

  func testSameJobRetryAfterRestartUsesActualCurrentEpochWithoutRewritingOldCapture() async throws {
    let (db, priorOwner, old, _) = try await actualRetryFixture()
    let captured = try old.journal.currentCapture()
    let reopened = try ProductDatabase.open(at: db.root)
    let current = try await LocalLibraryLifecycle.open(database: reopened)
    XCTAssertNotEqual(current.epoch, priorOwner.epoch)
    let fresh = try source("restart-retry.pdf")
    let bytes = try Data(contentsOf: fresh)
    let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    let paperID = try await current.retryImportPDF(expected: old, from: fresh,
      expectedSHA256: digest, destinationFolderID: nil)
    let rows = try deletionRows(reopened, paperID)
    let journal = try ImportRecoveryJournal.decode(XCTUnwrap(Data.fromDatabaseValue(rows[1]["recoveryJournal"])),
      maximumBytes: ProductJobRecovery.maximumImportRecoveryJournalBytes)
    XCTAssertEqual(try journal.currentCapture().identity.epoch, current.epoch)
    XCTAssertEqual(try journal.snapshot().executions.first?.lineage.captured.epoch, captured.identity.epoch.uuidString)
    XCTAssertTrue(try journal.extends(old.journal, maximumBytes: ProductJobRecovery.maximumImportRecoveryJournalBytes))
    XCTAssertEqual(try journal.snapshot().current.state, .succeeded)
  }

  func testStaleSameJobRetryHasNoActualCopierScopeDescriptorOrNamespaceEffects() async throws {
    let (db, _, old, _) = try await actualRetryFixture()
    let identity = try old.journal.currentCapture().identity
    let updated = try db.appendJournaledImport(expected: old,
      replacement: old.journal.recording(.authorityChanged(old.journal.snapshot().authority)))
    let before = try deletionRows(db, identity.paperID)
    let effects = OwnedCopyEffects()
    let lifecycle = try await LocalLibraryLifecycle.openForOwnedCopyFixtures(database: db, effects: effects.effects)
    let selected = try source("stale-retry.pdf")
    let bytes = try Data(contentsOf: selected)
    let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    do {
      _ = try await lifecycle.retryImportPDF(expected: old, from: selected,
        expectedSHA256: digest, destinationFolderID: nil)
      XCTFail("Stale full history admitted Retry")
    } catch { XCTAssertEqual(error as? ImportRecoveryPersistenceError, .staleHistory) }
    XCTAssertTrue(effects.census.isEmpty)
    XCTAssertTrue(effects.observations.isEmpty)
    XCTAssertEqual(effects.scopeCensus, [0, 0])
    assertDeletionRowsEqual(before, try deletionRows(db, identity.paperID))
    XCTAssertEqual(try db.captureRetryableImport(paperID: identity.paperID,
      generation: identity.generation).encoded, updated.encoded)
    XCTAssertFalse(FileManager.default.fileExists(atPath: namespace(identity.paperID).path))
  }

  private func freshRetryIdentity(_ previous: ImportIdentity, epoch: UUID,
    attempt: UUID = UUID()) -> ImportIdentity {
    ImportIdentity(paperID: previous.paperID, generation: previous.generation, jobID: previous.jobID,
      attempt: attempt, fence: UUID(), correlation: UUID(), input: UUID(), epoch: epoch,
      writer: UUID(), publication: UUID())
  }

  func testRetryCaptureRejectsWrongGenerationEpochReusedIDsAndMissingConfirmedHashWithoutWrites() async throws {
    let (db, lifecycle, old, _) = try await actualRetryFixture()
    let previous = try old.journal.currentCapture().identity
    let before = try deletionRows(db, previous.paperID)
    XCTAssertThrowsError(try db.captureRetryableImport(paperID: previous.paperID, generation: UUID()))
    let facts = ImportRecoveryJournal.ConfirmedInput(expectedSHA256: String(repeating: "a", count: 64),
      destinationFolderID: nil)
    XCTAssertThrowsError(try db.reserveJournaledImportRetry(expected: old,
      identity: freshRetryIdentity(previous, epoch: UUID()), confirmedInput: facts, currentEpoch: lifecycle.epoch))
    XCTAssertThrowsError(try db.reserveJournaledImportRetry(expected: old,
      identity: freshRetryIdentity(previous, epoch: lifecycle.epoch, attempt: previous.attempt),
      confirmedInput: facts, currentEpoch: lifecycle.epoch))
    XCTAssertThrowsError(try db.reserveJournaledImportRetry(expected: old,
      identity: freshRetryIdentity(previous, epoch: lifecycle.epoch),
      confirmedInput: .init(expectedSHA256: nil, destinationFolderID: nil), currentEpoch: lifecycle.epoch))
    assertDeletionRowsEqual(before, try deletionRows(db, previous.paperID))
    assertDeletionRowsEqual(before, try deletionRows(ProductDatabase.open(at: root), previous.paperID))
    XCTAssertFalse(FileManager.default.fileExists(atPath: namespace(previous.paperID).path))
  }

  func testSameJobRetryNamespaceCollisionRetainsOwnedBytesAndHasNoCopierEffects() async throws {
    let (db, _, old, _) = try await actualRetryFixture()
    let identity = try old.journal.currentCapture().identity
    let collision = namespace(identity.paperID)
    try FileManager.default.createDirectory(at: collision, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let sentinel = collision.appendingPathComponent("existing-owned-obligation")
    let retained = Data("not cleanup authority".utf8)
    try retained.write(to: sentinel)
    let before = try deletionRows(db, identity.paperID)
    let effects = OwnedCopyEffects()
    let lifecycle = try await LocalLibraryLifecycle.openForOwnedCopyFixtures(database: db, effects: effects.effects)
    let selected = try source("collision-retry.pdf")
    let digest = try SHA256.hash(data: Data(contentsOf: selected)).map { String(format: "%02x", $0) }.joined()
    do {
      _ = try await lifecycle.retryImportPDF(expected: old, from: selected,
        expectedSHA256: digest, destinationFolderID: nil)
      XCTFail("Retry admission erased a namespace collision")
    } catch { XCTAssertEqual(error as? LocalLibraryError, .cleanupFailed) }
    XCTAssertEqual(try Data(contentsOf: sentinel), retained)
    XCTAssertTrue(effects.census.isEmpty)
    XCTAssertEqual(effects.scopeCensus, [0, 0])
    assertDeletionRowsEqual(before, try deletionRows(db, identity.paperID))
  }

  func testRetryReservationIgnoresCorruptionForeignWritesAndUserWithoutRowidAllRollBack() async throws {
    let (db, lifecycle, old, _) = try await actualRetryFixture()
    let previous = try old.journal.currentCapture().identity
    let before = try deletionRows(db, previous.paperID)
    let fixtures = [
      ("CREATE TRIGGER rejectRetry BEFORE UPDATE OF state ON importJob WHEN NEW.state = 'running' BEGIN SELECT RAISE(IGNORE); END", "DROP TRIGGER rejectRetry"),
      ("CREATE TRIGGER rejectRetry BEFORE UPDATE OF status ON paper WHEN NEW.status = 'importing' BEGIN SELECT RAISE(IGNORE); END", "DROP TRIGGER rejectRetry"),
      ("CREATE TRIGGER rejectRetry AFTER UPDATE OF state ON importJob WHEN NEW.state = 'running' BEGIN UPDATE importJob SET bytesCopied = 7 WHERE id = NEW.id; END", "DROP TRIGGER rejectRetry"),
      ("CREATE TABLE unrelatedRetry (id INTEGER PRIMARY KEY); CREATE TRIGGER rejectRetry AFTER UPDATE OF state ON importJob WHEN NEW.state = 'running' BEGIN INSERT INTO unrelatedRetry VALUES (1); DELETE FROM unrelatedRetry; END", "DROP TRIGGER rejectRetry; DROP TABLE unrelatedRetry"),
      ("CREATE TABLE invisibleRetry (id TEXT PRIMARY KEY) WITHOUT ROWID", "DROP TABLE invisibleRetry")
    ]
    for (setup, teardown) in fixtures {
      try db.adapterWrite { try $0.execute(sql: setup) }
      XCTAssertThrowsError(try db.reserveJournaledImportRetry(expected: old,
        identity: freshRetryIdentity(previous, epoch: lifecycle.epoch),
        confirmedInput: .init(expectedSHA256: String(repeating: "a", count: 64), destinationFolderID: nil),
        currentEpoch: lifecycle.epoch), setup)
      assertDeletionRowsEqual(before, try deletionRows(db, previous.paperID))
      assertDeletionRowsEqual(before, try deletionRows(ProductDatabase.open(at: root), previous.paperID))
      XCTAssertFalse(FileManager.default.fileExists(atPath: namespace(previous.paperID).path))
      try db.adapterWrite { try $0.execute(sql: teardown) }
    }
  }

  func testFreshRetrySourceOrDestinationChangeConsumesIntentWithoutNewExecution() async throws {
    for changeSource in [true, false] {
      let (db, lifecycle, old, _) = try await actualRetryFixture()
      let identity = try old.journal.currentCapture().identity
      let service = FolderImportService(database: db, lifecycle: lifecycle)
      let folder = try db.createFolder(name: "Fresh chosen destination")
      let selected = try source("confirmation-guard.pdf")
      let confirmed = try await service.prepareRetry(source: selected, paperID: identity.paperID,
        generation: identity.generation, destinationFolderID: folder.id)
      let before = try deletionRows(db, identity.paperID)
      if changeSource {
        try Data("%PDF-1.7\nchanged after fresh confirmation\n%%EOF\n".utf8).write(to: selected)
      } else { try db.deleteFolder(id: folder.id) }
      do {
        _ = try await service.continueImport(confirmed.id, destinationFolderID: folder.id)
        XCTFail("Changed fresh Retry prerequisites admitted")
      } catch { XCTAssertEqual(error as? FolderImportError, changeSource ? .sourceChanged : .missingFolder) }
      assertDeletionRowsEqual(before, try deletionRows(db, identity.paperID))
      XCTAssertFalse(FileManager.default.fileExists(atPath: namespace(identity.paperID).path))
      do { _ = try await service.continueImport(confirmed.id, destinationFolderID: nil); XCTFail("Failed consumed Retry replayed") }
      catch { XCTAssertEqual(error as? FolderImportError, .consumedIntent) }
    }
  }

  func testRetryPreparationRejectsLegacySucceededUnavailableAndDeletingJobsWithoutReconstruction() async throws {
    let (db, lifecycle, old, _) = try await actualRetryFixture()
    let service = FolderImportService(database: db, lifecycle: lifecycle)
    let legacy = identity()
    try reserveLegacyImportFixture(in: db, identity: legacy, title: "owned NULL-history fixture")
    try db.failImport(legacy, failure: "sourceChanged", cleanupDebt: false)
    let legacyBefore = try deletionRows(db, legacy.paperID)
    do {
      _ = try await service.prepareRetry(source: source("legacy-selected.pdf"),
        paperID: legacy.paperID, generation: legacy.generation)
      XCTFail("Legacy NULL history reconstructed for Retry")
    } catch { XCTAssertEqual(error as? ImportRecoveryPersistenceError, .invalidHistory) }
    assertDeletionRowsEqual(legacyBefore, try deletionRows(db, legacy.paperID))
    let oldIdentity = try old.journal.currentCapture().identity
    _ = try db.beginDeletion(oldIdentity.paperID)
    let deletingBefore = try deletionRows(db, oldIdentity.paperID)
    do {
      _ = try await service.prepareRetry(source: source("deleting-selected.pdf"),
        paperID: oldIdentity.paperID, generation: oldIdentity.generation)
      XCTFail("Deleting Job admitted Retry")
    } catch { XCTAssertEqual(error as? ImportRecoveryPersistenceError, .invalidHistory) }
    assertDeletionRowsEqual(deletingBefore, try deletionRows(db, oldIdentity.paperID))
    let ready = try await lifecycle.importPDF(from: source("ready-not-retry.pdf"))
    let readyRows = try deletionRows(db, ready)
    let generation = try XCTUnwrap(UUID(uuidString: XCTUnwrap(String.fromDatabaseValue(readyRows[0]["generation"]))))
    XCTAssertThrowsError(try db.captureRetryableImport(paperID: ready, generation: generation))
    try FileManager.default.removeItem(at: namespace(ready).appendingPathComponent("document.pdf"))
    let reopened = try ProductDatabase.open(at: root)
    _ = try await LocalLibraryLifecycle.open(database: reopened)
    let unavailable = try deletionRows(reopened, ready)
    XCTAssertEqual(String.fromDatabaseValue(unavailable[0]["status"]), "importFailed")
    XCTAssertEqual(String.fromDatabaseValue(unavailable[1]["state"]), "succeeded")
    XCTAssertThrowsError(try reopened.captureRetryableImport(paperID: ready, generation: generation))
    assertDeletionRowsEqual(unavailable, try deletionRows(reopened, ready))
  }

  func testSameJobRetryJournalQuotaRefusalHasNoExecutionOrPhysicalEffects() async throws {
    let (db, _, original, _) = try await actualRetryFixture()
    let identity = try original.journal.currentCapture().identity
    let maximum = ProductJobRecovery.maximumImportRecoveryJournalBytes
    let observed = try original.journal.recording(.authorityChanged(original.journal.snapshot().authority))
      .encoded(maximumBytes: maximum)
    let increment = observed.count - original.encoded.count
    XCTAssertGreaterThan(increment, 0)
    var document = try XCTUnwrap(JSONSerialization.jsonObject(with: original.encoded) as? [String: Any])
    var events = try XCTUnwrap(document["events"] as? [Any])
    let extended = try XCTUnwrap(JSONSerialization.jsonObject(with: observed) as? [String: Any])
    let observation = try XCTUnwrap((extended["events"] as? [Any])?.last)
    events += Array(repeating: observation, count: (maximum - original.encoded.count) / increment)
    document["events"] = events
    let bytes = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
    let padded = try ImportRecoveryJournal.decode(bytes, maximumBytes: maximum)
    XCTAssertEqual(try padded.encoded(maximumBytes: maximum), bytes)
    let current = try db.appendJournaledImport(expected: original, replacement: padded)
    let before = try deletionRows(db, identity.paperID)
    let effects = OwnedCopyEffects()
    let lifecycle = try await LocalLibraryLifecycle.openForOwnedCopyFixtures(database: db, effects: effects.effects)
    let selected = try source("quota-retry.pdf")
    let digest = try SHA256.hash(data: Data(contentsOf: selected)).map { String(format: "%02x", $0) }.joined()
    do {
      _ = try await lifecycle.retryImportPDF(expected: current, from: selected,
        expectedSHA256: digest, destinationFolderID: nil)
      XCTFail("Retry consumed terminal metadata headroom")
    } catch { XCTAssertEqual(error as? ImportRecoveryJournal.JournalError, .byteLimitExceeded) }
    XCTAssertTrue(effects.census.isEmpty)
    XCTAssertTrue(effects.observations.isEmpty)
    XCTAssertEqual(effects.scopeCensus, [0, 0])
    assertDeletionRowsEqual(before, try deletionRows(db, identity.paperID))
    assertDeletionRowsEqual(before, try deletionRows(ProductDatabase.open(at: root), identity.paperID))
    XCTAssertFalse(FileManager.default.fileExists(atPath: namespace(identity.paperID).path))
  }

  func testDurableRevocationRejectsLatePublicationWithoutRename() throws {
    let db = try ProductDatabase.open(at: root)
    let pending = identity()
    try reserveLegacyImportFixture(in: db, identity: pending, title: "synthetic late")
    let owned = namespace(pending.paperID)
    try FileManager.default.createDirectory(at: owned, withIntermediateDirectories: true)
    let stage = owned.appendingPathComponent("\(pending.attempt.uuidString).stage")
    try Data("%PDF-1.7\nclosed".utf8).write(to: stage)
    _ = try db.beginDeletion(pending.paperID)
    let final = owned.appendingPathComponent("document.pdf")
    XCTAssertThrowsError(try db.publish(pending, stage: stage, final: final, sha256: String(repeating: "a", count: 64))) {
      XCTAssertEqual($0 as? ProductDatabaseError, .staleImport)
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: stage.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: final.path))
    XCTAssertEqual(try db.libraryRecords().first?.status, .deleting)
  }

  private func deletionRows(_ db: ProductDatabase, _ id: UUID) throws -> [Row] {
    try db.adapterRead { sql in
      [try XCTUnwrap(Row.fetchOne(sql, sql: "SELECT * FROM paper WHERE id = ?",
        arguments: [id.uuidString]))] + (try Row.fetchAll(sql,
          sql: "SELECT * FROM importJob WHERE paperID = ? ORDER BY id", arguments: [id.uuidString]))
    }
  }

  private func assertDeletionRowsEqual(_ before: [Row], _ after: [Row],
    paperExcept ignored: Set<String> = [], jobExcept ignoredJob: Set<String> = [],
    file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(before.count, after.count, file: file, line: line)
    for (index, pair) in zip(before, after).enumerated() {
      XCTAssertEqual(Array(pair.0.columnNames), Array(pair.1.columnNames), file: file, line: line)
      let excluded = index == 0 ? ignored : ignoredJob
      for name in pair.0.columnNames where !excluded.contains(name) {
        let old: DatabaseValue = pair.0[name]
        let new: DatabaseValue = pair.1[name]
        XCTAssertEqual(old.storage, new.storage, "row \(index) column \(name)", file: file, line: line)
      }
    }
  }

  func testActualAndReopenedLifecycleListSeparatesFailedImportAndDeletionCauses() async throws {
    let db = try ProductDatabase.open(at: root)
    let current = identity()
    try reserveLegacyImportFixture(in: db, identity: current, title: "owned failed import deletion")
    try db.recordProgress(current, bytes: 9)
    try db.failImport(current, failure: "originalImportCause", cleanupDebt: false)
    let lifecycle = try await LocalLibraryLifecycle.open(database: db)
    let imports = try await lifecycle.list()
    XCTAssertEqual(imports.first?.status, .importFailed)
    XCTAssertEqual(imports.first?.failure, "originalImportCause")
    let before = try deletionRows(db, current.paperID)
    do {
      try await lifecycle.delete(paperID: current.paperID)
      XCTFail("Absent Agent integration cannot prove deletion")
    } catch { XCTAssertEqual(error as? LocalLibraryError, .agentPurgeUnavailable) }
    let records = try await lifecycle.list()
    XCTAssertEqual(records.first?.status, .deletionFailed)
    XCTAssertEqual(records.first?.failure, "agentPurgeUnavailable")
    assertDeletionRowsEqual([before[1]], [try deletionRows(db, current.paperID)[1]])
    let restarted = try await LocalLibraryLifecycle.open(database: ProductDatabase.open(at: root))
    let reopened = try await restarted.list()
    XCTAssertEqual(reopened, records)
  }

  func testDeletionDiagnosticPreservesWholeSucceededFailedAndInterruptedJobRows() throws {
    let db = try ProductDatabase.open(at: root)
    for (index, terminal) in ["succeeded", "failed", "running"].enumerated() {
      let current = identity()
      try reserveLegacyImportFixture(in: db, identity: current, title: "owned diagnostic \(terminal)")
      try db.recordProgress(current, bytes: 17)
      // An opaque owned sentinel is corruption, not an admitted recovery journal.
      let history = Data("owned retained history \(terminal)".utf8)
      try db.adapterWrite { sql in
        try sql.execute(sql: "UPDATE importJob SET recoveryJournal = ? WHERE id = ?",
          arguments: [history, current.jobID.uuidString])
      }
      if terminal == "succeeded" {
        let owned = namespace(current.paperID)
        try FileManager.default.createDirectory(at: owned, withIntermediateDirectories: true)
        let stage = owned.appendingPathComponent("owned.stage")
        try Data("%PDF-1.7\nowned success".utf8).write(to: stage)
        try db.publish(current, stage: stage, final: owned.appendingPathComponent("document.pdf"),
          sha256: String(repeating: "a", count: 64))
      } else if terminal == "failed" {
        try db.failImport(current, failure: "originalImportCause", cleanupDebt: false)
        XCTAssertEqual(try db.libraryRecords().first { $0.id == current.paperID }?.failure, "originalImportCause")
        XCTAssertEqual(try ProductDatabase.open(at: root).libraryRecords()
          .first { $0.id == current.paperID }?.failure, "originalImportCause")
      }
      let corruptBefore = try deletionRows(db, current.paperID)
      XCTAssertThrowsError(try db.beginDeletion(current.paperID))
      let corruptAfter = try deletionRows(db, current.paperID)
      assertDeletionRowsEqual(corruptBefore, corruptAfter)
      XCTAssertEqual(Data.fromDatabaseValue(corruptAfter[1]["recoveryJournal"]), history)
      // Restore this originally NULL legacy fixture; no product backfill or decoder fallback.
      try db.adapterWrite { sql in
        try sql.execute(sql: "UPDATE importJob SET recoveryJournal = NULL WHERE id = ?",
          arguments: [current.jobID.uuidString])
      }
      let saga = try XCTUnwrap(db.beginDeletion(current.paperID)).saga
      let before = try deletionRows(db, current.paperID)
      // Deleting list must not fall back to an original import failure or paperDeleting.
      XCTAssertNil(try db.libraryRecords().first { $0.id == current.paperID }?.failure)
      let reason = ["agentPurgeUnavailable", "agentClosureUnproved", "deletionIncomplete"][index]
      try db.deletionFailed(current.paperID, saga: saga, reason: reason)
      let after = try deletionRows(db, current.paperID)
      assertDeletionRowsEqual(before, after, paperExcept: ["status", "cleanupDebt", "deletionFailure"])
      XCTAssertEqual(String.fromDatabaseValue(after[0]["deletionFailure"]), reason)
      XCTAssertNil(Data.fromDatabaseValue(after[1]["recoveryJournal"]))
      XCTAssertEqual(String.fromDatabaseValue(after[1]["state"]), terminal == "running" ? "failed" : terminal)
      XCTAssertEqual(String.fromDatabaseValue(after[1]["failure"]),
        terminal == "running" ? "paperDeleting" : terminal == "failed" ? "originalImportCause" : nil)
      for owner in [db, try ProductDatabase.open(at: root)] {
        let record = try XCTUnwrap(owner.libraryRecords().first { $0.id == current.paperID })
        XCTAssertEqual(record.status, .deletionFailed)
        XCTAssertEqual(record.failure, reason)
        XCTAssertEqual(record.bytesCopied, 17)
        XCTAssertTrue(record.cleanupDebt)
      }
      if terminal == "running" {
        XCTAssertThrowsError(try db.recordImportAbort(current, failure: "late", cleanupDebt: true)) {
          XCTAssertEqual($0 as? ProductDatabaseError, .staleImport)
        }
        assertDeletionRowsEqual(after, try deletionRows(db, current.paperID))
      }
      XCTAssertEqual(try db.beginDeletion(current.paperID)?.saga, saga)
      let retry = try deletionRows(db, current.paperID)
      assertDeletionRowsEqual(after, retry, paperExcept: ["status", "deletionFailure"])
      XCTAssertNil(String.fromDatabaseValue(retry[0]["deletionFailure"]))
      XCTAssertEqual(String.fromDatabaseValue(retry[0]["deletionID"]), saga.uuidString)
      XCTAssertNil(try db.libraryRecords().first { $0.id == current.paperID }?.failure)
      if terminal == "running" {
        try db.recordImportAbort(current, failure: "late", cleanupDebt: false)
        assertDeletionRowsEqual(retry, try deletionRows(db, current.paperID))
      }
    }
  }

  func testDeletionDiagnosticRejectsInvalidReasonSagaGenerationAndStateWithoutEffects() throws {
    let db = try ProductDatabase.open(at: root)
    let cases = ["reason", "wrongSaga", "malformedSaga", "noncanonicalSaga", "missingSaga", "state", "unknownState", "generation"]
    for fault in cases {
      let current = identity()
      try reserveLegacyImportFixture(in: db, identity: current, title: "owned invalid \(fault)")
      let saga = try XCTUnwrap(db.beginDeletion(current.paperID)).saga
      try db.adapterWrite { sql in
        if fault == "malformedSaga" || fault == "noncanonicalSaga" {
          try sql.execute(sql: "UPDATE paper SET deletionID = ? WHERE id = ?",
            arguments: [fault == "malformedSaga" ? "malformed" : "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", current.paperID.uuidString])
        } else if fault == "missingSaga" {
          try sql.execute(sql: "UPDATE paper SET deletionID = NULL WHERE id = ?", arguments: [current.paperID.uuidString])
        } else if fault == "state" {
          try sql.execute(sql: "UPDATE paper SET status = 'importFailed' WHERE id = ?", arguments: [current.paperID.uuidString])
        } else if fault == "unknownState" {
          try sql.execute(sql: "UPDATE paper SET status = 'malformed' WHERE id = ?", arguments: [current.paperID.uuidString])
        } else if fault == "generation" {
          try sql.execute(sql: "UPDATE paper SET generation = '' WHERE id = ?", arguments: [current.paperID.uuidString])
        }
      }
      let before = try deletionRows(db, current.paperID)
      XCTAssertThrowsError(try db.deletionFailed(current.paperID,
        saga: fault == "wrongSaga" ? UUID() : saga, reason: fault == "reason" ? "arbitrary" : "deletionIncomplete")) {
        XCTAssertEqual($0 as? ProductDatabaseError, .invalidRecord, fault)
      }
      assertDeletionRowsEqual(before, try deletionRows(db, current.paperID))
      if ["malformedSaga", "noncanonicalSaga", "missingSaga", "unknownState", "generation"].contains(fault) {
        XCTAssertThrowsError(try db.beginDeletion(current.paperID)) {
          XCTAssertEqual($0 as? ProductDatabaseError, .invalidRecord, fault)
        }
        assertDeletionRowsEqual(before, try deletionRows(db, current.paperID))
      }
    }
  }

  func testDeletionDiagnosticTriggerRefusalAndFullRowCorruptionRollBack() throws {
    let db = try ProductDatabase.open(at: root)
    let current = identity()
    try reserveLegacyImportFixture(in: db, identity: current, title: "owned diagnostic rollback")
    try db.recordProgress(current, bytes: 19)
    let saga = try XCTUnwrap(db.beginDeletion(current.paperID)).saga
    let before = try deletionRows(db, current.paperID)
    let mutations = [
      "UPDATE paper SET deletionFailure = NULL WHERE id = NEW.id;",
      "UPDATE paper SET title = 'corrupt' WHERE id = NEW.id;",
      "UPDATE paper SET generation = 'corrupt' WHERE id = NEW.id;",
      "UPDATE paper SET pdfSHA256 = 'corrupt' WHERE id = NEW.id;",
      "UPDATE importJob SET failure = 'corrupt' WHERE paperID = NEW.id;",
      "UPDATE importJob SET state = 'succeeded' WHERE paperID = NEW.id;",
      "UPDATE importJob SET bytesCopied = 90 WHERE paperID = NEW.id;",
      "UPDATE importJob SET attempt = 'corrupt' WHERE paperID = NEW.id;",
      "UPDATE importJob SET recoveryJournal = X'010203' WHERE paperID = NEW.id;",
      "DELETE FROM importJob WHERE paperID = NEW.id;"
    ]
    for mutation in ["SELECT RAISE(IGNORE);"] + mutations {
      let timing = mutation == "SELECT RAISE(IGNORE);" ? "BEFORE" : "AFTER"
      try db.adapterWrite { sql in
        try sql.execute(sql: """
          CREATE TRIGGER corrupt_deletion \(timing) UPDATE OF deletionFailure ON paper
          WHEN NEW.status = 'deletionFailed' BEGIN \(mutation) END
          """)
      }
      XCTAssertThrowsError(try db.deletionFailed(current.paperID, saga: saga, reason: "agentClosureUnproved")) {
        XCTAssertEqual($0 as? ProductDatabaseError, .invalidRecord, mutation)
      }
      assertDeletionRowsEqual(before, try deletionRows(db, current.paperID))
      try db.adapterWrite { try $0.execute(sql: "DROP TRIGGER corrupt_deletion") }
    }
    try db.deletionFailed(current.paperID, saga: saga, reason: "agentClosureUnproved")
    XCTAssertEqual(try db.libraryRecords().first?.failure, "agentClosureUnproved")
  }

  func testDeletionRetryDiagnosticClearingIsCheckedAndAtomic() throws {
    let db = try ProductDatabase.open(at: root)
    let current = identity()
    try reserveLegacyImportFixture(in: db, identity: current, title: "owned retry rollback")
    let saga = try XCTUnwrap(db.beginDeletion(current.paperID)).saga
    try db.deletionFailed(current.paperID, saga: saga, reason: "deletionIncomplete")
    let before = try deletionRows(db, current.paperID)
    for mutation in ["SELECT RAISE(IGNORE);",
      "UPDATE paper SET deletionFailure = 'deletionIncomplete' WHERE id = NEW.id;",
      "UPDATE paper SET title = 'corrupt' WHERE id = NEW.id;",
      "UPDATE importJob SET failure = 'corrupt' WHERE paperID = NEW.id;"] {
      let timing = mutation == "SELECT RAISE(IGNORE);" ? "BEFORE" : "AFTER"
      try db.adapterWrite { sql in
        try sql.execute(sql: """
          CREATE TRIGGER corrupt_retry \(timing) UPDATE OF deletionFailure ON paper
          WHEN NEW.status = 'deleting' BEGIN \(mutation) END
          """)
      }
      XCTAssertThrowsError(try db.beginDeletion(current.paperID)) {
        XCTAssertEqual($0 as? ProductDatabaseError, .invalidRecord, mutation)
      }
      assertDeletionRowsEqual(before, try deletionRows(db, current.paperID))
      try db.adapterWrite { try $0.execute(sql: "DROP TRIGGER corrupt_retry") }
    }
    XCTAssertEqual(try db.beginDeletion(current.paperID)?.saga, saga)
    assertDeletionRowsEqual(before, try deletionRows(db, current.paperID), paperExcept: ["status", "deletionFailure"])
    XCTAssertNil(try db.libraryRecords().first?.failure)
  }

  func testDeletionTombstoneClearsDiagnosticAndJobWithCheckedRollback() throws {
    let db = try ProductDatabase.open(at: root)
    let current = identity()
    try reserveLegacyImportFixture(in: db, identity: current, title: "owned tombstone")
    let saga = try XCTUnwrap(db.beginDeletion(current.paperID)).saga
    try db.adapterWrite { sql in
      try sql.execute(sql: """
        UPDATE paper SET deletionFailure = 'agentPurgeUnavailable', pdfSHA256 = ?, pdfReference = ? WHERE id = ?
        """, arguments: [String(repeating: "a", count: 64), "owned-reference", current.paperID.uuidString])
    }
    let before = try deletionRows(db, current.paperID)
    for trigger in [
      "BEFORE UPDATE ON paper WHEN NEW.status = 'tombstone' BEGIN SELECT RAISE(IGNORE); END",
      "AFTER UPDATE ON paper WHEN NEW.status = 'tombstone' BEGIN UPDATE paper SET deletionFailure = 'deletionIncomplete' WHERE id = NEW.id; END",
      "AFTER UPDATE ON paper WHEN NEW.status = 'tombstone' BEGIN UPDATE paper SET title = 'corrupt' WHERE id = NEW.id; END",
      "BEFORE DELETE ON importJob BEGIN SELECT RAISE(IGNORE); END"
    ] {
      try db.adapterWrite { try $0.execute(sql: "CREATE TRIGGER corrupt_tombstone \(trigger)") }
      XCTAssertThrowsError(try db.finalizeDeletion(current.paperID, saga: saga)) {
        XCTAssertEqual($0 as? ProductDatabaseError, .invalidRecord, trigger)
      }
      assertDeletionRowsEqual(before, try deletionRows(db, current.paperID))
      try db.adapterWrite { try $0.execute(sql: "DROP TRIGGER corrupt_tombstone") }
    }
    try db.finalizeDeletion(current.paperID, saga: saga)
    let after = try deletionRows(db, current.paperID)
    XCTAssertEqual(after.count, 1)
    assertDeletionRowsEqual([before[0]], after,
      paperExcept: ["status", "title", "pdfReference", "pdfSHA256", "cleanupDebt", "deletionFailure"])
    XCTAssertEqual(String.fromDatabaseValue(after[0]["status"]), "tombstone")
    XCTAssertEqual(String.fromDatabaseValue(after[0]["title"]), "")
    XCTAssertEqual(Int64.fromDatabaseValue(after[0]["cleanupDebt"]), 0)
    for column in ["pdfReference", "pdfSHA256", "deletionFailure"] {
      let value: DatabaseValue = after[0][column]
      XCTAssertTrue(value.isNull, column)
    }
    XCTAssertTrue(try db.libraryRecords().isEmpty)
    XCTAssertThrowsError(try db.finalizeDeletion(current.paperID, saga: saga))
  }

  func testDeletionAdmissionJobInterruptionRefusalRollsBackDiagnosticClearing() throws {
    let db = try ProductDatabase.open(at: root)
    let current = identity()
    try reserveLegacyImportFixture(in: db, identity: current, title: "owned interruption rollback")
    try db.recordProgress(current, bytes: 11)
    try db.adapterWrite { sql in
      try sql.execute(sql: "UPDATE paper SET deletionFailure = 'deletionIncomplete' WHERE id = ?",
        arguments: [current.paperID.uuidString])
    }
    let before = try deletionRows(db, current.paperID)
    try db.adapterWrite { sql in
      try sql.execute(sql: """
        CREATE TRIGGER refuse_deletion_interruption BEFORE UPDATE OF state ON importJob
        WHEN NEW.failure = 'paperDeleting' BEGIN SELECT RAISE(IGNORE); END
        """)
    }
    XCTAssertThrowsError(try db.beginDeletion(current.paperID)) {
      XCTAssertEqual($0 as? ProductDatabaseError, .invalidRecord)
    }
    assertDeletionRowsEqual(before, try deletionRows(db, current.paperID))
    try db.adapterWrite { try $0.execute(sql: "DROP TRIGGER refuse_deletion_interruption") }
    _ = try XCTUnwrap(db.beginDeletion(current.paperID))
    let after = try deletionRows(db, current.paperID)
    XCTAssertNil(String.fromDatabaseValue(after[0]["deletionFailure"]))
    XCTAssertEqual(String.fromDatabaseValue(after[1]["state"]), "failed")
    XCTAssertEqual(String.fromDatabaseValue(after[1]["failure"]), "paperDeleting")
    XCTAssertEqual(Int64.fromDatabaseValue(after[1]["bytesCopied"]), 11)
  }

  func testForeignFenceCannotPublishAndRenameFailureCannotCommitSuccess() throws {
    let db = try ProductDatabase.open(at: root)
    let pending = identity()
    try reserveLegacyImportFixture(in: db, identity: pending, title: "synthetic guarded")
    let owned = namespace(pending.paperID)
    try FileManager.default.createDirectory(at: owned, withIntermediateDirectories: true)
    let stage = owned.appendingPathComponent("\(pending.attempt.uuidString).stage")
    let final = owned.appendingPathComponent("document.pdf")
    let bytes = Data("%PDF-1.7\nclosed".utf8)
    try bytes.write(to: stage)
    let foreign = ImportIdentity(paperID: pending.paperID, generation: pending.generation,
      jobID: pending.jobID, attempt: pending.attempt, fence: UUID(), correlation: pending.correlation,
      input: pending.input, epoch: pending.epoch, writer: pending.writer, publication: pending.publication)
    XCTAssertThrowsError(try db.publish(foreign, stage: stage, final: final, sha256: String(repeating: "b", count: 64))) {
      XCTAssertEqual($0 as? ProductDatabaseError, .staleImport)
  }
    XCTAssertFalse(FileManager.default.fileExists(atPath: final.path))
    try bytes.write(to: final) // Actual immutable destination collision, not an injected policy result.
    XCTAssertThrowsError(try db.publish(pending, stage: stage, final: final, sha256: String(repeating: "c", count: 64)))
    XCTAssertEqual(try db.libraryRecords().first?.status, .importing)
    XCTAssertTrue(FileManager.default.fileExists(atPath: stage.path))
  }

  func testProviderMetadataCASSurvivesRestartAndDisconnectRejectsABA() throws {
    let db = try ProductDatabase.open(at: root)
    let initial = try db.providerConfiguration()
    let slot = UUID()
    let connected = try db.compareAndSwapProviderConfiguration(expected: initial,
      replacementKind: .openAIAPIKey, replacementSlotID: slot,
      replacementModel: "explicit-test-snapshot")
    XCTAssertEqual(connected.slotID, slot)
    XCTAssertThrowsError(try db.compareAndSwapProviderConfiguration(expected: initial,
      replacementKind: .openAIAPIKey, replacementSlotID: UUID(),
      replacementModel: "explicit-test-snapshot"))
    let disconnected = try db.compareAndSwapProviderConfiguration(expected: connected,
      replacementKind: nil, replacementSlotID: nil,
      replacementModel: nil)
    XCTAssertNil(disconnected.slotID)
    XCTAssertGreaterThan(disconnected.generation, initial.generation)
    let restarted = try ProductDatabase.open(at: root)
    XCTAssertEqual(try restarted.providerConfiguration(), disconnected)
    XCTAssertThrowsError(try restarted.compareAndSwapProviderConfiguration(expected: initial,
      replacementKind: .openAIAPIKey, replacementSlotID: slot,
      replacementModel: "explicit-test-snapshot"))
  }
}
