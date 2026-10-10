import Darwin
import Foundation
import GRDB
import ProviderRequest
import XCTest

@testable import PaperLensProduct

private enum SyntheticPurgeError: Error { case failed, stillPresent }

private enum OwnedCopyFault: Error { case close, open }

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
        else { self.output = handle; self.outputFD = handle.fileDescriptor }
      }
      if self.failures.contains(endpoint) { throw OwnedCopyFault.close }
      try handle.close()
    }, startScope: { _ in self.lock.withLock { self.starts += 1 }; return true },
      stopScope: { _ in self.lock.withLock { self.stops += 1 } })
  }

  var census: [ActualCopyEndpoint] { lock.withLock { closeAttempts } }
  var scopeCensus: [Int] { lock.withLock { [starts, stops] } }
  func retained(_ endpoint: ActualCopyEndpoint) -> Bool {
    lock.withLock { endpoint == .input ? input != nil : output != nil }
  }
  func acquiredFD(_ endpoint: ActualCopyEndpoint) -> Int32? {
    lock.withLock { endpoint == .input ? inputFD : outputFD }
  }

  func physicallyTearDown(_ debt: ActualCopyDebt) throws {
    // Only test-owned descriptors. Do not mutate or ACK the runtime's unknown registry.
    if !debt.outputClosed { try XCTUnwrap(debt.output).close() }
    if !debt.inputClosed { try XCTUnwrap(debt.input).close() }
    if debt.scoped { effects.stopScope(debt.source) }
    debt.lease.close()
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
  private var root: URL { temporary.appendingPathComponent("product", isDirectory: true) }

  override func setUpWithError() throws {
    temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
  }

  override func tearDownWithError() throws {
    if let temporary { try FileManager.default.removeItem(at: temporary) }
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
    try db.reserveImport(current, title: "owned exact lineage")
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
    try db!.reserveImport(old, title: "owned old execution")
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
    try db.reserveImport(current, title: "owned rollback")
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
    try db.reserveImport(current, title: "owned progress")
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
    try db.reserveImport(current, title: "owned deleting abort")
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
    let id = try await lifecycle.importPDF(from: source())
    XCTAssertEqual(try db.libraryRecords().first?.status, .ready)
    XCTAssertEqual(effects.census, [.output, .input])
    XCTAssertEqual(effects.scopeCensus, [1, 1])
    XCTAssertEqual(pool.active, baseline)
    XCTAssertFalse(LocalLibraryLifecycle.actualCopyDebts.contains { $0.identity.paperID == id })
    assertActualPoolDenial(pool, authority: authority)
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

  func testActualCloseUnknownRetainsRealFDsPoolScopeAndNamespaceAcrossFacadeLoss() async throws {
    let authority = try ProviderRequest()
    let pool = try RequestResourcePool(authority: authority, kind: "import")
    let baseline = pool.active
    let db = try ProductDatabase.open(at: root)
    let faults: [Set<ActualCopyEndpoint>] = [[.input], [.output], [.input, .output]]
    for (index, failures) in faults.enumerated() {
      let original = try source("close-\(index).pdf")
      let effects = OwnedCopyEffects(failures: failures)
      var lifecycle: LocalLibraryLifecycle? = try await LocalLibraryLifecycle.openForOwnedCopyFixtures(
        database: db, effects: effects.effects)
      weak var facade = lifecycle
      let id = try await XCTUnwrap(lifecycle).importPDF(from: original)
      var tornDown = false
      defer {
        if !tornDown, let debt = LocalLibraryLifecycle.actualCopyDebts.first(where: { $0.identity.paperID == id }) {
          do { try effects.physicallyTearDown(debt) }
          catch { XCTFail("Owned physical teardown failed: \(error)") }
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
      XCTAssertEqual(try db.libraryRecords().filter { $0.cleanupDebt }.count, index + 1)
      XCTAssertEqual(effects.census, [.output, .input])
      XCTAssertEqual(effects.scopeCensus, [1, 0])
      XCTAssertEqual(pool.active, baseline + 1)
      let debt = try XCTUnwrap(LocalLibraryLifecycle.actualCopyDebts.first { $0.identity.paperID == id })
      XCTAssertEqual(debt.source, original)
      XCTAssertEqual(debt.inputClosed, !failures.contains(.input))
      XCTAssertEqual(debt.outputClosed, !failures.contains(.output))
      XCTAssertEqual(try Data(contentsOf: debt.stage), try Data(contentsOf: original))
      XCTAssertFalse(FileManager.default.fileExists(atPath: namespace(id).appendingPathComponent("document.pdf").path))
      assertActualPoolDenial(pool, authority: authority)
      tornDown = true
      try effects.physicallyTearDown(debt)
      XCTAssertEqual(pool.active, baseline)
      XCTAssertEqual(effects.scopeCensus, [1, 1])
      XCTAssertEqual(effects.census, [.output, .input])
      XCTAssertTrue(LocalLibraryLifecycle.actualCopyDebts.contains { $0.identity.attempt == debt.identity.attempt })
      XCTAssertTrue(FileManager.default.fileExists(atPath: debt.stage.path))
      XCTAssertTrue(try XCTUnwrap(db.libraryRecords().first { $0.id == id }).cleanupDebt)
    }
  }

  func testActualPartialOpenUnknownRetainsOnlyAcquiredInputAndPreservesCollision() async throws {
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
    XCTAssertEqual(pool.active, baseline)
    XCTAssertEqual(effects.scopeCensus, [1, 1])
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
    assertDeletionRowsEqual([before[1]], [after[1]])
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
    try db.reserveImport(pending, title: "synthetic interrupted")
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
    try db.reserveImport(pending, title: "Interrupted owned import")
    let marker = namespace(pending.paperID).appendingPathComponent("\(pending.attempt.uuidString).stage")
    try FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
    let bytes = Data("%PDF-1.7\nuncertain closed-or-open stage".utf8)
    try bytes.write(to: marker)
    let deleting = try await original.importPDF(from: source("deleting.pdf"))
    let saga = try XCTUnwrap(db.beginDeletion(deleting))
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
    try FileManager.default.removeItem(at: namespace(id).appendingPathComponent("document.pdf"))
    let restarted = try await LocalLibraryLifecycle.open(database: ProductDatabase.open(at: root))
    let records = try await restarted.list()
    XCTAssertEqual(records.first?.status, .importFailed)
    XCTAssertEqual(records.first?.failure, "missingPDF")
  }

  func testDurableRevocationRejectsLatePublicationWithoutRename() throws {
    let db = try ProductDatabase.open(at: root)
    let pending = identity()
    try db.reserveImport(pending, title: "synthetic late")
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
    paperExcept ignored: Set<String> = [], file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(before.count, after.count, file: file, line: line)
    for (index, pair) in zip(before, after).enumerated() {
      XCTAssertEqual(Array(pair.0.columnNames), Array(pair.1.columnNames), file: file, line: line)
      for name in pair.0.columnNames where index != 0 || !ignored.contains(name) {
        let old: DatabaseValue = pair.0[name]
        let new: DatabaseValue = pair.1[name]
        XCTAssertEqual(old.storage, new.storage, "row \(index) column \(name)", file: file, line: line)
      }
    }
  }

  func testActualAndReopenedLifecycleListSeparatesFailedImportAndDeletionCauses() async throws {
    let db = try ProductDatabase.open(at: root)
    let current = identity()
    try db.reserveImport(current, title: "owned failed import deletion")
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
      try db.reserveImport(current, title: "owned diagnostic \(terminal)")
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
      let saga = try XCTUnwrap(db.beginDeletion(current.paperID))
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
      XCTAssertEqual(try db.beginDeletion(current.paperID), saga)
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
      try db.reserveImport(current, title: "owned invalid \(fault)")
      let saga = try XCTUnwrap(db.beginDeletion(current.paperID))
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
    try db.reserveImport(current, title: "owned diagnostic rollback")
    try db.recordProgress(current, bytes: 19)
    let saga = try XCTUnwrap(db.beginDeletion(current.paperID))
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
    try db.reserveImport(current, title: "owned retry rollback")
    let saga = try XCTUnwrap(db.beginDeletion(current.paperID))
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
    XCTAssertEqual(try db.beginDeletion(current.paperID), saga)
    assertDeletionRowsEqual(before, try deletionRows(db, current.paperID), paperExcept: ["status", "deletionFailure"])
    XCTAssertNil(try db.libraryRecords().first?.failure)
  }

  func testDeletionTombstoneClearsDiagnosticAndJobWithCheckedRollback() throws {
    let db = try ProductDatabase.open(at: root)
    let current = identity()
    try db.reserveImport(current, title: "owned tombstone")
    let saga = try XCTUnwrap(db.beginDeletion(current.paperID))
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
    try db.reserveImport(current, title: "owned interruption rollback")
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
    try db.reserveImport(pending, title: "synthetic guarded")
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
    let connected = try db.compareAndSwapProviderConfiguration(expected: initial, replacementSlotID: slot,
      replacementModel: "explicit-test-snapshot")
    XCTAssertEqual(connected.slotID, slot)
    XCTAssertThrowsError(try db.compareAndSwapProviderConfiguration(expected: initial, replacementSlotID: UUID(),
      replacementModel: "explicit-test-snapshot"))
    let disconnected = try db.compareAndSwapProviderConfiguration(expected: connected, replacementSlotID: nil,
      replacementModel: nil)
    XCTAssertNil(disconnected.slotID)
    XCTAssertGreaterThan(disconnected.generation, initial.generation)
    let restarted = try ProductDatabase.open(at: root)
    XCTAssertEqual(try restarted.providerConfiguration(), disconnected)
    XCTAssertThrowsError(try restarted.compareAndSwapProviderConfiguration(expected: initial, replacementSlotID: slot,
      replacementModel: "explicit-test-snapshot"))
  }
}
