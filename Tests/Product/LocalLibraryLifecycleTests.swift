import Foundation
import ProviderRequest
import XCTest

@testable import PaperLensProduct

private enum SyntheticPurgeError: Error { case failed, stillPresent }

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
    do {
      try await lifecycle.delete(paperID: id)
      XCTFail("Absent Agent integration cannot prove deletion")
    } catch { XCTAssertEqual(error as? LocalLibraryError, .agentPurgeUnavailable) }
    let records = try await lifecycle.list()
    XCTAssertEqual(records.first?.status, .deletionFailed)
    XCTAssertEqual(records.first?.failure, "agentPurgeUnavailable")
    XCTAssertEqual(records.first?.cleanupDebt, true)
    XCTAssertTrue(FileManager.default.fileExists(atPath: namespace(id).path))
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
