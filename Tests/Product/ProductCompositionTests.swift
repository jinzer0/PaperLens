import Darwin
import Foundation
import GRDB
import XCTest
import ProviderRequest
@testable import PaperLensProduct

/// Synthetic replies and synthetic keys only. These tests never perform networking,
/// render UI, read an existing profile, or establish real provider authentication.
@MainActor
private final class CompositionProbe: NativeConnectionTestTransport {
  var calls = 0
  var evidence: NativeProbeEvidence = .deterministicFixture
  func probe(key: String, configuration: NativeOpenAIConfiguration,
    request: AuthorizedProviderRequest, authority: ProviderRequest) async throws -> NativeProbeResponse {
    calls += 1
    return NativeProbeResponse(
      result: try authority.wrapModelResult(Data("PAPERLENS_OK".utf8), request: request),
      evidence: evidence)
  }
}

@MainActor
final class ProductCompositionTests: XCTestCase {
  private func privateRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent("paperlens-composition-fixture-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    guard let physicalPath = realpath(root.path, nil) else {
      throw APIKeyConnectionError.unsafeStorage
    }
    defer { free(physicalPath) }
    return URL(fileURLWithPath: String(cString: physicalPath), isDirectory: true)
  }

  private func waitForProbe(_ connection: NativeAPIKeyConnection) async throws {
    for _ in 0..<200 {
      if connection.phase != .probing { return }
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTFail("Synthetic probe did not terminate")
  }

  func testSelectorPersistsSlotModelAndGenerationAcrossReopen() throws {
    let root = try privateRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let database = try ProductDatabase.open(at: root.appendingPathComponent("database"))
    let configuration = try NativeOpenAIConfiguration(model: "fixture-model")
    let store = try APIKeySlotStore(directory: root.appendingPathComponent("slots"))
    let slot = try store.create(key: "synthetic-key-not-a-credential")
    let adapter = DatabaseAPIKeySelector(database: database, configuration: configuration)
    XCTAssertNil(try adapter.currentSelection())
    let committed = try XCTUnwrap(adapter.compareAndSwap(expected: nil, slotID: slot))
    let reopened = try ProductDatabase.open(at: database.root)
    let restored = DatabaseAPIKeySelector(database: reopened, configuration: configuration)
    XCTAssertEqual(try restored.currentSelection(), committed)
    XCTAssertEqual(try reopened.providerConfiguration().model, configuration.model)
    XCTAssertTrue(try restored.selectionMatchesConfiguration(configuration))
    XCTAssertFalse(try restored.selectionMatchesConfiguration(
      NativeOpenAIConfiguration(model: "different-model")))
    XCTAssertEqual(try store.read(slot), "synthetic-key-not-a-credential")
  }

  func testNilABAAndStaleSelectionNeverWin() throws {
    let root = try privateRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let database = try ProductDatabase.open(at: root.appendingPathComponent("database"))
    let configuration = try NativeOpenAIConfiguration(model: "fixture-model")
    let adapter = DatabaseAPIKeySelector(database: database, configuration: configuration)
    XCTAssertNil(try adapter.currentSelection())
    let initial = try database.providerConfiguration()
    let selected = try database.compareAndSwapProviderConfiguration(expected: initial,
      replacementSlotID: UUID(), replacementModel: configuration.model)
    let cleared = try database.compareAndSwapProviderConfiguration(expected: selected,
      replacementSlotID: nil, replacementModel: nil)
    XCTAssertNil(try adapter.currentSelection())
    XCTAssertNil(try adapter.compareAndSwap(expected: nil, slotID: UUID()))
    XCTAssertEqual(try database.providerConfiguration(), cleared)
    let retry = DatabaseAPIKeySelector(database: database, configuration: configuration)
    XCTAssertNil(try retry.currentSelection())
    let winner = try XCTUnwrap(retry.compareAndSwap(expected: nil, slotID: UUID()))
    XCTAssertGreaterThan(winner.configGeneration, selected.generation)
    XCTAssertNil(try adapter.compareAndSwap(
      expected: APIKeySelection(slotID: selected.slotID!, configGeneration: selected.generation),
      slotID: UUID()))
  }

  func testSyntheticFixtureCannotCommitOrEnterLibrary() async throws {
    let root = try privateRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let transport = CompositionProbe()
    let composition = ProductAppComposition(root: root, transport: transport)
    await composition.start()
    try composition.configure(model: "fixture-model")
    guard case .connection(let connection) = composition.phase else {
      return XCTFail("Expected key entry")
    }
    XCTAssertThrowsError(try composition.continueToLibrary())
    connection.connect(key: "synthetic-key-not-a-credential")
    try await waitForProbe(connection)
    XCTAssertEqual(connection.phase, .failed(.authentication))
    XCTAssertThrowsError(try composition.continueToLibrary())
    let database = try ProductDatabase.open(at: root.appendingPathComponent("database"))
    XCTAssertNil(try database.providerConfiguration().slotID)
    XCTAssertEqual(transport.calls, 1)
  }

  func testSyntheticCommittedConnectionRequiresExplicitContinueAndRestoresBinding() async throws {
    let root = try privateRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let transport = CompositionProbe()
    // This is an injected synthetic label solely to exercise the success branch.
    // It is not real authentication evidence and cannot certify any product gate.
    transport.evidence = .authenticatedGenerationResponse
    let composition = ProductAppComposition(root: root, transport: transport)
    await composition.start()
    try composition.configure(model: "fixture-model")
    guard case .connection(let connection) = composition.phase else {
      return XCTFail("Expected key entry")
    }
    connection.connect(key: "synthetic-key-not-a-credential")
    try await waitForProbe(connection)
    XCTAssertTrue(connection.eligibleForEntry)
    guard case .connection = composition.phase else {
      return XCTFail("Probe must not enter Library")
    }
    try composition.continueToLibrary()
    guard case .library = composition.phase else { return XCTFail("Continue must compose Library") }

    let restored = ProductAppComposition(root: root, transport: transport)
    await restored.start()
    guard case .connection(let restoredConnection) = restored.phase else {
      return XCTFail("Startup must still require Continue")
    }
    XCTAssertTrue(restoredConnection.eligibleForEntry)
    XCTAssertEqual(transport.calls, 1, "Restore must not replay a provider request")
    restored.changeModel()
    try restored.configure(model: "changed-model")
    guard case .connection(let changedConnection) = restored.phase else {
      return XCTFail("Expected changed model entry")
    }
    XCTAssertFalse(changedConnection.eligibleForEntry)
    XCTAssertThrowsError(try restored.continueToLibrary())
  }

  func testLegacySelectorWithoutModelCannotRestoreEntry() async throws {
    let root = try privateRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let database = try ProductDatabase.open(at: root.appendingPathComponent("database"))
    let slots = try APIKeySlotStore(directory: root.appendingPathComponent("api-key-slots"))
    let slot = try slots.create(key: "synthetic-legacy-key")
    try database.adapterWrite { db in
      try db.execute(sql: "UPDATE providerConfig SET slotID = ?, generation = 1, model = NULL WHERE singleton = 1",
        arguments: [slot.uuidString])
    }
    let transport = CompositionProbe()
    let composition = ProductAppComposition(root: root, transport: transport)
    await composition.start()
    guard case .modelRequired = composition.phase else {
      return XCTFail("Legacy selector must not infer a model")
    }
    try composition.configure(model: "explicit-new-model")
    guard case .connection(let connection) = composition.phase else {
      return XCTFail("Expected key entry")
    }
    XCTAssertFalse(connection.eligibleForEntry)
    XCTAssertThrowsError(try composition.continueToLibrary())
    XCTAssertEqual(transport.calls, 0)
  }

  func testModelReplacementCannotAbandonAnUnterminatedLease() async throws {
    let root = try privateRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let transport = CompositionProbe()
    transport.evidence = .authenticatedGenerationResponse
    let composition = ProductAppComposition(root: root, transport: transport)
    await composition.start()
    try composition.configure(model: "fixture-model")
    guard case .connection(let old) = composition.phase else { return XCTFail("Expected connection") }
    old.connect(key: "synthetic-held-key")
    try await waitForProbe(old)
    let lease = try old.acquireLease()
    XCTAssertFalse(old.canReplaceOwner)
    XCTAssertThrowsError(try composition.configure(model: "new-fixture-model"))
    composition.changeModel()
    guard case .connection(let retained) = composition.phase else {
      return XCTFail("Model change must retain the reference owner")
    }
    XCTAssertTrue(retained === old)
    XCTAssertEqual(try old.key(for: lease), "synthetic-held-key")
    XCTAssertTrue(try old.mayPublish(lease))
    XCTAssertEqual(transport.calls, 1)
    try old.releaseAfterTermination(lease)
    XCTAssertTrue(old.canReplaceOwner)
    composition.changeModel()
    try composition.configure(model: "new-fixture-model")
    guard case .connection(let replacement) = composition.phase else { return XCTFail("Expected replacement") }
    XCTAssertThrowsError(try old.acquireLease())
    old.restore()
    XCTAssertFalse(old.eligibleForEntry)
    old.connect(key: "synthetic-retired-owner-key")
    await Task.yield()
    XCTAssertEqual(transport.calls, 1)
    XCTAssertFalse(try old.mayPublish(lease))
    replacement.connect(key: "synthetic-replacement-key")
    try await waitForProbe(replacement)
    XCTAssertTrue(replacement.eligibleForEntry)
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("api-key-slots")
      .appendingPathComponent(lease.selection.slotID.uuidString).path))
  }

  func testStartupRecoversBeforeCommandsWithoutProviderReplay() async throws {
    let root = try privateRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let database = try ProductDatabase.open(at: root.appendingPathComponent("database"))
    let original = try await LocalLibraryLifecycle.open(database: database)
    let source = root.appendingPathComponent("synthetic.pdf")
    try Data("%PDF-1.7\nsynthetic startup PDF\n%%EOF\n".utf8).write(to: source)
    let ready = try await original.importPDF(from: source)
    let metadata = try database.adapterRead { db in
      try XCTUnwrap(Row.fetchOne(db, sql: "SELECT generation, pdfSHA256 FROM paper WHERE id = ?",
        arguments: [ready.uuidString]))
    }
    let generation: String = metadata["generation"]
    let digest: String = metadata["pdfSHA256"]
    let extraction = ExtractionIdentity(paperID: ready,
      generation: try XCTUnwrap(UUID(uuidString: generation)), pdfSHA256: digest,
      pdfReference: "papers/\(ready.uuidString)/document.pdf", revision: UUID(), job: UUID(),
      attempt: UUID(), fence: UUID(), correlation: UUID(), input: UUID(), epoch: original.epoch,
      configuration: try database.providerConfiguration())
    try database.reserveExtraction(extraction)
    let pending = ImportIdentity(paperID: UUID(), generation: UUID(), jobID: UUID(),
      attempt: UUID(), fence: UUID(), correlation: UUID(), input: UUID(), epoch: original.epoch,
      writer: UUID(), publication: UUID())
    try database.reserveImport(pending, title: "Startup interrupted import")
    let directory = database.root.appendingPathComponent("papers/\(pending.paperID.uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let stage = directory.appendingPathComponent("\(pending.attempt.uuidString).stage")
    let bytes = Data("%PDF-1.7\nuncertain startup bytes".utf8)
    try bytes.write(to: stage)
    let transport = CompositionProbe()
    let composition = ProductAppComposition(root: root, transport: transport)
    XCTAssertThrowsError(try composition.configure(model: "fixture-model"))
    XCTAssertThrowsError(try composition.continueToLibrary())
    await composition.start()
    guard case .modelRequired = composition.phase else { return XCTFail("Expected recovered entry") }
    XCTAssertNil(composition.workspace)
    XCTAssertEqual(transport.calls, 0)
    XCTAssertEqual(try database.extractionStatus(paperID: ready).failure, "interrupted")
    XCTAssertEqual(try database.libraryRecords().first { $0.id == pending.paperID }?.failure, "interrupted")
    XCTAssertEqual(try database.libraryRecords().first { $0.id == pending.paperID }?.cleanupDebt, true)
    XCTAssertEqual(try Data(contentsOf: stage), bytes)
    try composition.configure(model: "fixture-model")
    XCTAssertThrowsError(try composition.continueToLibrary())
    await composition.start()
    XCTAssertEqual(transport.calls, 0, "Repeated start never retries or sends")
    XCTAssertThrowsError(try publishFixtureExtraction(database, extraction,
      sentences: [.init(page: 0, sentenceID: 0, text: "late output", geometry: Data([1]))]))
  }

  func testRecoveryFailureExposesNoCommandOwnersAndRollsBack() async throws {
    let root = try privateRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let database = try ProductDatabase.open(at: root.appendingPathComponent("database"))
    let pending = ImportIdentity(paperID: UUID(), generation: UUID(), jobID: UUID(),
      attempt: UUID(), fence: UUID(), correlation: UUID(), input: UUID(), epoch: UUID(),
      writer: UUID(), publication: UUID())
    try database.reserveImport(pending, title: "Recovery rollback fixture")
    try database.adapterWrite { db in
      try db.execute(sql: """
        CREATE TRIGGER rejectStartupRecovery BEFORE UPDATE OF state ON importJob
        BEGIN SELECT RAISE(ABORT, 'synthetic startup recovery failure'); END;
        """)
    }
    let transport = CompositionProbe()
    let composition = ProductAppComposition(root: root, transport: transport)
    await composition.start()
    guard case .failed = composition.phase else { return XCTFail("Recovery must block startup") }
    XCTAssertThrowsError(try composition.configure(model: "fixture-model"))
    XCTAssertThrowsError(try composition.continueToLibrary())
    XCTAssertNil(composition.workspace)
    XCTAssertEqual(transport.calls, 0)
    let state = try database.adapterRead { db in
      try String.fetchOne(db, sql: "SELECT state FROM importJob WHERE id = ?",
        arguments: [pending.jobID.uuidString])
    }
    XCTAssertEqual(state, "running", "Failed recovery cannot partially commit")
    XCTAssertEqual(try database.libraryRecords().first?.status, .importing)
  }

  func testCompositionRestartInterruptsSummaryBeforeEntryAndRetainsPreviousVisibleData() async throws {
    let root = try privateRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let database = try ProductDatabase.open(at: root.appendingPathComponent("database"))
    let original = try await LocalLibraryLifecycle.open(database: database)
    let saved = try await StartupSummaryFixture(database: database, lifecycle: original, epoch: original.epoch)
    try saved.reserve()
    let visible = try saved.publish()
    let failed = try StartupSummaryFixture(previous: saved, epoch: original.epoch)
    try failed.reserve()
    try database.failLibrarySummary(failed.identity)
    let priorCurrent = try StartupSummaryFixture(previous: saved, epoch: original.epoch)
    try priorCurrent.reserve()
    let before = try database.adapterRead { db in
      try Row.fetchAll(db, sql: "SELECT * FROM librarySummaryJob WHERE state != 'running' ORDER BY job")
    }
    let owned = database.root.appendingPathComponent("papers/\(saved.identity.paperID.uuidString)/document.pdf")
    let bytes = try Data(contentsOf: owned)
    let transport = CompositionProbe()
    let composition = ProductAppComposition(root: root, transport: transport)
    await composition.start()
    guard case .modelRequired = composition.phase else { return XCTFail("Recovered startup must require entry") }
    XCTAssertNil(composition.workspace)
    XCTAssertThrowsError(try composition.continueToLibrary())
    let reopened = try ProductDatabase.open(at: database.root)
    let interrupted = try reopened.adapterRead { db in
      try XCTUnwrap(Row.fetchOne(db, sql: "SELECT * FROM librarySummaryJob WHERE job = ?",
        arguments: [priorCurrent.identity.job.uuidString]))
    }
    XCTAssertEqual(interrupted["state"] as String, "failed")
    XCTAssertEqual(interrupted["failure"] as String, "interrupted")
    XCTAssertEqual(interrupted["epoch"] as String, original.epoch.uuidString)
    XCTAssertEqual(try JSONDecoder().decode(LibrarySummaryIdentity.self, from: interrupted["identity"]),
      priorCurrent.identity)
    XCTAssertEqual(try JSONDecoder().decode(LibrarySummaryFrozen.self, from: interrupted["frozen"]),
      priorCurrent.frozen)
    let terminal = try reopened.adapterRead { db in
      try Row.fetchAll(db, sql: "SELECT * FROM librarySummaryJob WHERE job != ? ORDER BY job",
        arguments: [priorCurrent.identity.job.uuidString])
    }
    XCTAssertEqual(before, terminal)
    let restored = try XCTUnwrap(LibrarySummaryService(database: reopened,
      geometry: StartupSummaryFixture.Geometry()).restore(paperID: saved.identity.paperID))
    XCTAssertEqual(restored.id, visible.id)
    XCTAssertEqual(restored.identity, visible.identity)
    XCTAssertEqual(restored.result, visible.result)
    XCTAssertEqual(try reopened.extractionStatus(paperID: saved.identity.paperID).usableRevision,
      saved.identity.revision)
    XCTAssertEqual(try Data(contentsOf: owned), bytes)
    XCTAssertThrowsError(try priorCurrent.publish())
    await composition.start()
    XCTAssertEqual(transport.calls, 0, "Neither restart nor restoration sends or retries")
  }

  func testSummaryRecoverySQLFailureRollsBackAllKindsAndExposesNoOwners() async throws {
    let root = try privateRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let database = try ProductDatabase.open(at: root.appendingPathComponent("database"))
    let original = try await LocalLibraryLifecycle.open(database: database)
    let summary = try await StartupSummaryFixture(database: database, lifecycle: original, epoch: original.epoch)
    try summary.reserve()
    let pending = ImportIdentity(paperID: UUID(), generation: UUID(), jobID: UUID(),
      attempt: UUID(), fence: UUID(), correlation: UUID(), input: UUID(), epoch: original.epoch,
      writer: UUID(), publication: UUID())
    try database.reserveImport(pending, title: "Summary failure atomic rollback")
    let extraction = ExtractionIdentity(paperID: summary.identity.paperID,
      generation: summary.identity.generation, pdfSHA256: summary.identity.pdfSHA256,
      pdfReference: "papers/\(summary.identity.paperID.uuidString)/document.pdf", revision: UUID(), job: UUID(),
      attempt: UUID(), fence: UUID(), correlation: UUID(), input: UUID(), epoch: original.epoch,
      configuration: try database.providerConfiguration())
    try database.reserveExtraction(extraction)
    func rows() throws -> [Row] {
      try database.adapterRead { db in
        try Row.fetchAll(db, sql: "SELECT * FROM importJob ORDER BY id") +
          Row.fetchAll(db, sql: "SELECT * FROM extractionAttempt ORDER BY paperID") +
          Row.fetchAll(db, sql: "SELECT * FROM librarySummaryJob ORDER BY job") +
          Row.fetchAll(db, sql: "SELECT * FROM paper ORDER BY id")
      }
    }
    let before = try rows()
    try database.adapterWrite { db in
      try db.execute(sql: """
        CREATE TRIGGER rejectSummaryStartup BEFORE UPDATE OF state ON librarySummaryJob
        BEGIN SELECT RAISE(ABORT, 'synthetic summary startup SQL failure'); END;
        """)
    }
    let transport = CompositionProbe()
    let composition = ProductAppComposition(root: root, transport: transport)
    await composition.start()
    guard case .failed = composition.phase else { return XCTFail("Summary recovery must block all admission") }
    XCTAssertThrowsError(try composition.configure(model: "fixture-model"))
    XCTAssertThrowsError(try composition.continueToLibrary())
    XCTAssertNil(composition.workspace)
    XCTAssertEqual(transport.calls, 0)
    XCTAssertEqual(try rows(), before, "Summary SQL failure must roll back import/extraction and paper updates")
    XCTAssertEqual(try database.extractionStatus(paperID: summary.identity.paperID).usableRevision,
      summary.identity.revision)
  }

  func testUnsafeRootFailsWithoutPermissionRepairOrNetwork() async throws {
    let root = try privateRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
    let transport = CompositionProbe()
    let composition = ProductAppComposition(root: root, transport: transport)
    await composition.start()
    guard case .failed = composition.phase else { return XCTFail("Unsafe root must fail") }
    let attributes = try FileManager.default.attributesOfItem(atPath: root.path)
    XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o755)
    XCTAssertEqual(transport.calls, 0)
  }
}
