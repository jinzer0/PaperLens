import Darwin
import Foundation
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
