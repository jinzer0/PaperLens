import Combine
import Darwin
import Foundation
import SwiftUI
import XCTest
#if SWIFT_PACKAGE
import ProviderRequest
#endif
@testable import PaperLensProduct

@MainActor
private final class SettingsSelectorFixture: APIKeySelectorPersistence {
  var selection: APIKeySelection?
  var commits = 0
  func currentSelection() throws -> APIKeySelection? { selection }
  func selectionMatchesConfiguration(_ configuration: NativeOpenAIConfiguration) throws -> Bool {
    selection != nil && configuration.model == "fixture-snapshot"
  }
  func compareAndSwap(expected: APIKeySelection?, slotID: UUID) throws -> APIKeySelection? {
    guard selection == expected else { return nil }
    let winner = APIKeySelection(slotID: slotID,
      configGeneration: (selection?.configGeneration ?? 0) + 1)
    selection = winner
    commits += 1
    return winner
  }
}

/// Synthetic correlated responses exercise arbitration, never real authentication.
@MainActor
final class SettingsSuspendedTransport: NativeConnectionTestTransport {
  private var pending: [(AuthorizedProviderRequest, ProviderRequest,
    CheckedContinuation<NativeProbeResponse, any Error>)] = []
  var count: Int { pending.count }

  func probe(key: String, configuration: NativeOpenAIConfiguration,
    request: AuthorizedProviderRequest, authority: ProviderRequest) async throws -> NativeProbeResponse {
    try await withCheckedThrowingContinuation { pending.append((request, authority, $0)) }
  }

  func complete(_ index: Int, evidence: NativeProbeEvidence = .authenticatedGenerationResponse) throws {
    let (request, authority, continuation) = pending[index]
    continuation.resume(returning: NativeProbeResponse(
      result: try authority.wrapModelResult(Data("PAPERLENS_OK".utf8), request: request),
      evidence: evidence))
  }

  func fail(_ index: Int) {
    pending[index].2.resume(throwing: APIKeyConnectionError.authentication)
  }
}

@MainActor
final class ProviderSettingsTests: XCTestCase {
  private struct Fixture {
    let root: URL
    let slots: APIKeySlotStore
    let selector: SettingsSelectorFixture
    let transport: SettingsSuspendedTransport
    let connection: NativeAPIKeyConnection
    let service: ProviderSettingsService
  }

  private func fixtureRoot() throws -> URL {
    let alias = FileManager.default.temporaryDirectory
      .appendingPathComponent("paperlens-settings-fixture-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: alias, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    guard let physicalPath = realpath(alias.path, nil) else {
      throw APIKeyConnectionError.unsafeStorage
    }
    defer { free(physicalPath) }
    return URL(fileURLWithPath: String(cString: physicalPath), isDirectory: true)
  }

  private func fixture(lastGood: Bool = true) throws -> Fixture {
    let root = try fixtureRoot()
    let slots = try APIKeySlotStore(directory: root.appendingPathComponent("slots", isDirectory: true))
    let selector = SettingsSelectorFixture()
    if lastGood {
      selector.selection = APIKeySelection(slotID: try slots.create(key: "fixture-last-good"),
        configGeneration: 41)
    }
    let transport = SettingsSuspendedTransport()
    let connection = NativeAPIKeyConnection(
      configuration: try NativeOpenAIConfiguration(model: "fixture-snapshot"), slots: slots,
      persistence: selector, transport: transport, authority: try ProviderRequest())
    let service = ProviderSettingsService(connection: connection)
    service.restore()
    return Fixture(root: root, slots: slots, selector: selector, transport: transport,
      connection: connection, service: service)
  }

  private func waitUntil(_ predicate: () -> Bool, file: StaticString = #filePath,
    line: UInt = #line) async {
    for _ in 0..<2000 {
      if predicate() { return }
      await Task.yield()
    }
    XCTFail("Deterministic Settings operation did not settle", file: file, line: line)
  }

  private func removeFixture(_ root: URL) throws {
    try FileManager.default.removeItem(at: root)
  }

  func testChatGPTSetupFailureCleansItsStageAndAllowsRetryOrChangingLoginMethod() throws {
    let root = try fixtureRoot()
    defer { try? removeFixture(root) }
    let database = try ProductDatabase.open(at: root.appendingPathComponent("database"))
    let slots = try APIKeySlotStore(directory: root.appendingPathComponent("slots"))
    let slotID = try slots.create(key: "fixture-last-good")
    let configuration = try NativeOpenAIConfiguration(model: "fixture-snapshot")
    let committed = try database.compareAndSwapProviderConfiguration(
      expected: database.providerConfiguration(), replacementKind: .openAIAPIKey,
      replacementSlotID: slotID, replacementModel: configuration.model)
    let transport = SettingsSuspendedTransport()
    let apiKey = NativeAPIKeyConnection(configuration: configuration, slots: slots,
      persistence: DatabaseAPIKeySelector(database: database, configuration: configuration),
      transport: transport, authority: try ProviderRequest())
    apiKey.restore()
    let loginRoot = root.appendingPathComponent("codex-scopes", isDirectory: true)
    var attemptedDirectories = [URL]()
    let codex = NativeCodexConnection(database: database, root: loginRoot, apiKey: apiKey) {
      attemptedDirectories.append($0.directoryURL)
      return nil
    }
    let settings = ProviderSettingsService(connection: apiKey, codex: codex)

    for mode in ["browser", "device"] {
      XCTAssertTrue(codex.canStart)
      codex.connect(mode: mode)
      XCTAssertEqual(codex.phase, .idle)
      XCTAssertTrue(codex.showsFailure)
      XCTAssertTrue(codex.offersRetry)
      XCTAssertTrue(codex.statusMessage.contains("전용 로그인 저장소 정리를 완료했습니다."))
      XCTAssertFalse(codex.blocksReplacement)
      XCTAssertNil(codex.testingOwner)
      XCTAssertTrue(settings.eligibleForEntry)
      XCTAssertEqual(try database.providerConfiguration(), committed)
      XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: loginRoot.path).isEmpty)
    }
    XCTAssertEqual(Set(attemptedDirectories).count, 2)
    XCTAssertEqual(transport.count, 0)
  }

  func testChatGPTSetupFailureKeepsStageBlockedWhileMetadataOwnerHasNotReleasedIt() throws {
    let f = try fixture(lastGood: false)
    defer { try? removeFixture(f.root) }
    let database = try ProductDatabase.open(at: f.root.appendingPathComponent("database"))
    let committed = try database.providerConfiguration()
    let loginRoot = f.root.appendingPathComponent("codex-scopes", isDirectory: true)
    let metadataOwner = UUID()
    var namespace: TopologyOwnedFixtures?
    let codex = NativeCodexConnection(database: database, root: loginRoot, apiKey: f.connection) { attempt in
      XCTAssertNil(namespace, "An unverified retirement must prevent starting another attempt")
      namespace = attempt
      XCTAssertTrue(attempt.beginMetadataMutation(owner: metadataOwner))
      return nil
    }

    codex.connect(mode: "device")
    let retained = try XCTUnwrap(namespace)
    defer { retained.endMetadataMutation(owner: metadataOwner) }
    XCTAssertEqual(codex.phase, .blocked)
    XCTAssertFalse(codex.canStart)
    XCTAssertFalse(codex.offersRetry)
    XCTAssertTrue(codex.blocksReplacement)
    XCTAssertNil(codex.testingOwner)
    codex.connect(mode: "browser")
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: loginRoot.path), [retained.runID])
    XCTAssertEqual(try database.providerConfiguration(), committed)
    XCTAssertEqual(f.transport.count, 0)
  }

  func testClosingWorkspaceSettingsCancelsOnlyUncommittedAPIKeyProbe() async throws {
    let f = try fixture()
    defer { try? removeFixture(f.root) }
    let database = try ProductDatabase.open(at: f.root.appendingPathComponent("database"))
    let library = try await LocalLibraryLifecycle.open(database: database)
    let workspace = try ProductWorkspace(database: database, lifecycle: library, connection: f.connection)
    let lastGood = try XCTUnwrap(f.selector.selection)
    workspace.sheet = .settings
    workspace.settings.reconnect(key: "synthetic-cancelled-key")
    await waitUntil { f.transport.count == 1 }
    guard f.transport.count == 1 else { return }

    workspace.dismissSheet()
    XCTAssertEqual(workspace.settings.phase, .failed(.cancelled))
    try f.transport.complete(0)
    await waitUntil { f.connection.canReplaceOwner }
    XCTAssertEqual(f.selector.selection, lastGood)
    XCTAssertEqual(try f.slots.validatedSlotIDs(), [lastGood.slotID])

    workspace.sheet = .settings
    let closing = f.connection.$activeSelection.dropFirst().sink { _ in workspace.sheet = nil }
    defer { closing.cancel() }
    workspace.settings.reconnect(key: "synthetic-committed-key")
    await waitUntil { f.transport.count == 2 }
    guard f.transport.count == 2 else { return }
    try f.transport.complete(1)
    await waitUntil { f.connection.canReplaceOwner }
    let committed = try XCTUnwrap(f.selector.selection)
    XCTAssertNil(workspace.sheet)
    XCTAssertEqual(committed.configGeneration, lastGood.configGeneration + 1)
    XCTAssertEqual(workspace.settings.phase, .connected(committed))
    XCTAssertTrue(workspace.settings.eligibleForEntry)
    XCTAssertEqual(try f.slots.validatedSlotIDs(), [committed.slotID])
  }

  func testClosingSettingsDuringProbeStartKeepsLastGoodWithoutSending() async throws {
    let f = try fixture()
    defer { try? removeFixture(f.root) }
    let database = try ProductDatabase.open(at: f.root.appendingPathComponent("database"))
    let library = try await LocalLibraryLifecycle.open(database: database)
    let workspace = try ProductWorkspace(database: database, lifecycle: library, connection: f.connection)
    let lastGood = try XCTUnwrap(f.selector.selection)
    workspace.sheet = .settings
    let closing = f.connection.$phase.dropFirst().sink { phase in
      if phase == .probing { workspace.sheet = nil }
    }
    defer { closing.cancel() }

    workspace.settings.reconnect(key: "synthetic-dismissed-before-send")
    XCTAssertNil(workspace.sheet)
    XCTAssertEqual(workspace.settings.phase, .failed(.cancelled))
    await waitUntil { f.connection.canReplaceOwner || f.transport.count > 0 }
    XCTAssertEqual(f.transport.count, 0)
    if f.transport.count > 0 { f.transport.fail(0) }
    await waitUntil { f.connection.canReplaceOwner }
    XCTAssertEqual(f.selector.commits, 0)
    XCTAssertEqual(f.selector.selection, lastGood)
    XCTAssertEqual(try f.slots.validatedSlotIDs(), [lastGood.slotID])
    XCTAssertTrue(workspace.settings.eligibleForEntry)
  }

  func testEditingKeyDuringProbeStartInvalidatesCandidateBeforeSending() async throws {
    let f = try fixture()
    defer { try? removeFixture(f.root) }
    let lastGood = try XCTUnwrap(f.selector.selection)
    var entry = "synthetic-about-to-send"
    let binding = providerSettingsKeyBinding(Binding(get: { entry }, set: { entry = $0 }),
      service: f.service)
    let editing = f.connection.$phase.dropFirst().sink { phase in
      if phase == .probing { binding.wrappedValue = "synthetic-edited" }
    }
    defer { editing.cancel() }

    f.service.reconnect(key: entry)
    XCTAssertEqual(entry, "synthetic-edited")
    XCTAssertFalse(f.service.isTesting)
    XCTAssertEqual(f.service.phase, .connected(lastGood))
    await waitUntil { f.connection.canReplaceOwner || f.transport.count > 0 }
    XCTAssertEqual(f.transport.count, 0)
    if f.transport.count > 0 { f.transport.fail(0) }
    await waitUntil { f.connection.canReplaceOwner }
    XCTAssertEqual(f.selector.commits, 0)
    XCTAssertEqual(try f.slots.validatedSlotIDs(), [lastGood.slotID])
  }

  func testChatGPTControlsObserveLeaseDrainAndCancelledProbeCompletion() async throws {
    let root = try fixtureRoot()
    defer { try? removeFixture(root) }
    let database = try ProductDatabase.open(at: root.appendingPathComponent("database"))
    let slots = try APIKeySlotStore(directory: root.appendingPathComponent("slots"))
    let configuration = try NativeOpenAIConfiguration(model: "fixture-snapshot")
    let oldSlot = try slots.create(key: "fixture-last-good")
    _ = try database.compareAndSwapProviderConfiguration(expected: database.providerConfiguration(),
      replacementKind: .openAIAPIKey, replacementSlotID: oldSlot, replacementModel: configuration.model)
    let transport = SettingsSuspendedTransport()
    let apiKey = NativeAPIKeyConnection(configuration: configuration, slots: slots,
      persistence: DatabaseAPIKeySelector(database: database, configuration: configuration),
      transport: transport, authority: try ProviderRequest())
    let codex = NativeCodexConnection(database: database,
      root: root.appendingPathComponent("codex-scopes"), apiKey: apiKey,
      prepareWorker: { _ in
        XCTFail("ChatGPT was admitted while OpenAI still owned work")
        return nil
      })
    let service = ProviderSettingsService(connection: apiKey, codex: codex)
    service.restore()
    var observedAvailability: [Bool] = []
    let observation = codex.objectWillChange.sink { observedAvailability.append(codex.canStart) }
    defer { observation.cancel() }
    XCTAssertTrue(codex.canStart)

    let firstLease = try service.acquireLease()
    let finalLease = try service.acquireLease()
    XCTAssertEqual(observedAvailability, [false])
    XCTAssertFalse(codex.canStart)
    service.reconnect(key: "fixture-new-selection")
    await waitUntil { transport.count == 1 }
    guard transport.count == 1 else { return }
    try transport.complete(0)
    await waitUntil { !service.isTesting }
    let active = try XCTUnwrap(service.activeSelection)
    XCTAssertNotEqual(active.slotID, oldSlot)
    XCTAssertEqual(try slots.read(oldSlot), "fixture-last-good")
    try service.releaseAfterTermination(firstLease)
    XCTAssertEqual(observedAvailability, [false])
    XCTAssertFalse(codex.canStart)
    try service.releaseAfterTermination(finalLease)
    XCTAssertEqual(try slots.validatedSlotIDs(), [active.slotID])
    XCTAssertTrue(codex.canStart)
    XCTAssertEqual(observedAvailability, [false, true])

    service.reconnect(key: "fixture-cancelled-candidate")
    XCTAssertFalse(codex.canStart)
    codex.connect(mode: "device")
    XCTAssertNil(codex.intentID)
    await waitUntil { transport.count == 2 }
    guard transport.count == 2 else { return }
    service.cancel()
    XCTAssertFalse(codex.canStart)
    XCTAssertEqual(observedAvailability, [false, true, false])
    try transport.complete(1)
    await waitUntil { codex.canStart }
    XCTAssertEqual(observedAvailability, [false, true, false, true])
    XCTAssertEqual(service.phase, .failed(.cancelled))
    XCTAssertEqual(try slots.validatedSlotIDs(), [active.slotID])
    XCTAssertEqual(try database.providerConfiguration().slotID, active.slotID)
  }

  func testSettingsRejectsStaleEmptySelectorAndRetriesAfterChatGPTDisconnect() async throws {
    let root = try fixtureRoot()
    defer { try? removeFixture(root) }
    let database = try ProductDatabase.open(at: root.appendingPathComponent("database"))
    let slots = try APIKeySlotStore(directory: root.appendingPathComponent("slots"))
    let configuration = try NativeOpenAIConfiguration(model: "fixture-snapshot")
    let selector = DatabaseAPIKeySelector(database: database, configuration: configuration)
    let transport = SettingsSuspendedTransport()
    let connection = NativeAPIKeyConnection(configuration: configuration, slots: slots,
      persistence: selector, transport: transport, authority: try ProviderRequest())
    let service = ProviderSettingsService(connection: connection)
    service.restore()
    service.reconnect(key: "fixture-stale-candidate")
    await waitUntil { transport.count == 1 }
    guard transport.count == 1 else { return }

    // Reproduce the durable selector transitions made by Codex activation and cleanup.
    let codex = try database.compareAndSwapProviderConfiguration(expected: selector.selectorSnapshot(),
      replacementKind: .codexChatGPT, replacementSlotID: UUID(), replacementModel: configuration.model)
    let cleared = try database.compareAndSwapProviderConfiguration(expected: codex,
      replacementKind: nil, replacementSlotID: nil, replacementModel: nil)
    try transport.complete(0)
    await waitUntil { service.phase == .failed(.selectorConflict) }
    XCTAssertEqual(try database.providerConfiguration(), cleared)
    XCTAssertFalse(service.eligibleForEntry)
    XCTAssertTrue(try slots.validatedSlotIDs().isEmpty)
    XCTAssertEqual(transport.count, 1)

    service.reconnect(key: "fixture-fresh-candidate")
    await waitUntil { transport.count == 2 }
    guard transport.count == 2 else { return }
    try transport.complete(1)
    await waitUntil { !service.isTesting }
    let winner = try XCTUnwrap(service.activeSelection)
    XCTAssertTrue(service.eligibleForEntry)
    XCTAssertEqual(winner.configGeneration, cleared.generation + 1)
    XCTAssertEqual(try ProductDatabase.open(at: database.root).providerConfiguration(),
      ProviderConfiguration(kind: .openAIAPIKey, slotID: winner.slotID,
        generation: winner.configGeneration, model: configuration.model))
    XCTAssertEqual(try slots.read(winner.slotID), "fixture-fresh-candidate")
  }

  func testSettingsAvailabilityRequiresTheCurrentDurableSelectionDuringAProbe() async throws {
    let root = try fixtureRoot()
    defer { try? removeFixture(root) }
    let database = try ProductDatabase.open(at: root.appendingPathComponent("database"))
    let slots = try APIKeySlotStore(directory: root.appendingPathComponent("slots"))
    let configuration = try NativeOpenAIConfiguration(model: "fixture-snapshot")
    let slot = try slots.create(key: "fixture-last-good")
    let previous = try database.compareAndSwapProviderConfiguration(expected: database.providerConfiguration(),
      replacementKind: .openAIAPIKey, replacementSlotID: slot, replacementModel: configuration.model)
    let transport = SettingsSuspendedTransport()
    let connection = NativeAPIKeyConnection(configuration: configuration, slots: slots,
      persistence: DatabaseAPIKeySelector(database: database, configuration: configuration),
      transport: transport, authority: try ProviderRequest())
    let codex = NativeCodexConnection(database: database,
      root: root.appendingPathComponent("codex-scopes"), apiKey: connection, prepareWorker: { _ in nil })
    let service = ProviderSettingsService(connection: connection, codex: codex)
    service.restore()
    let lease = try service.acquireLease()
    service.reconnect(key: "fixture-late-candidate")
    await waitUntil { transport.count == 1 }
    guard transport.count == 1 else { return }
    XCTAssertTrue(service.eligibleForEntry)

    // Simulate another authorized selector writer committing a newer generation of the same slot.
    let current = try database.compareAndSwapProviderConfiguration(expected: previous,
      replacementKind: .openAIAPIKey, replacementSlotID: slot, replacementModel: configuration.model)
    XCTAssertEqual(service.currentProviderLabel, "OpenAI API")
    XCTAssertFalse(service.eligibleForEntry)
    XCTAssertNil(service.activeSelection)
    XCTAssertFalse(try service.mayPublish(lease))
    XCTAssertThrowsError(try service.acquireLease())

    try transport.complete(0)
    await waitUntil { service.phase == .failed(.selectorConflict) }
    XCTAssertFalse(service.eligibleForEntry)
    XCTAssertEqual(try database.providerConfiguration(), current)
    XCTAssertEqual(try slots.validatedSlotIDs(), [slot])
    try service.releaseAfterTermination(lease)
    service.restore()
    XCTAssertEqual(service.activeSelection?.configGeneration, current.generation)
    XCTAssertTrue(service.eligibleForEntry)
    XCTAssertEqual(transport.count, 1, "Restoring the selected slot must not replay the old probe")
  }

  func testKeyBindingInvalidatesSharedCandidateBeforeChangedEntryWriteAndRejectsLateSuccess() async throws {
    let f = try fixture()
    let old = try XCTUnwrap(f.service.activeSelection)
    let lease = try f.service.acquireLease()
    var entry = "fixture-binding-candidate"
    var phasesAtWrite: [APIKeyConnectionPhase] = []
    let draft = Binding(get: { entry }, set: { next in
      phasesAtWrite.append(f.service.phase)
      XCTAssertEqual(f.service.activeSelection, old)
      XCTAssertEqual(f.selector.commits, 0)
      entry = next
    })
    let binding = providerSettingsKeyBinding(draft, service: f.service)
    submitProviderAPIKey(draft, service: f.service)
    await waitUntil { f.transport.count == 1 }
    binding.wrappedValue = entry // An unchanged native assignment is not an edit.
    XCTAssertEqual(phasesAtWrite, [.probing])
    XCTAssertTrue(f.service.isTesting)
    binding.wrappedValue = "fixture-binding-edited"
    XCTAssertEqual(phasesAtWrite.count, 2)
    XCTAssertNotEqual(phasesAtWrite.last, .probing)
    XCTAssertFalse(f.service.isTesting)
    XCTAssertEqual(binding.wrappedValue, "fixture-binding-edited")
    let editedPhase = f.service.phase
    try f.transport.complete(0)
    await waitUntil {
      (try? FileManager.default.contentsOfDirectory(atPath: f.root.appendingPathComponent("slots").path).count) == 1
    }
    XCTAssertEqual(f.service.phase, editedPhase)
    XCTAssertEqual(f.service.activeSelection, old)
    XCTAssertEqual(f.selector.selection, old)
    XCTAssertEqual(f.selector.commits, 0)
    XCTAssertEqual(entry, "fixture-binding-edited")
    XCTAssertEqual(f.transport.count, 1) // Entry edits never send an automatic probe.
    XCTAssertTrue(f.service.eligibleForEntry)
    XCTAssertTrue(try f.service.mayPublish(lease))
    XCTAssertEqual(try f.slots.read(old.slotID), "fixture-last-good")
    try f.service.releaseAfterTermination(lease)
    try removeFixture(f.root)
  }

  func testKeyBindingEditWithoutLastGoodCannotActivateLateSyntheticCandidate() async throws {
    let f = try fixture(lastGood: false)
    var entry = "fixture-unselected-candidate"
    let binding = providerSettingsKeyBinding(Binding(get: { entry }, set: { next in
      XCTAssertFalse(f.service.isTesting)
      entry = next
    }), service: f.service)
    f.service.reconnect(key: entry)
    await waitUntil { f.transport.count == 1 }
    binding.wrappedValue = "fixture-unselected-edited"
    let editedPhase = f.service.phase
    try f.transport.complete(0)
    await waitUntil {
      (try? FileManager.default.contentsOfDirectory(atPath: f.root.appendingPathComponent("slots").path).count) == 0
    }
    XCTAssertEqual(f.service.phase, editedPhase)
    XCTAssertNil(f.service.activeSelection)
    XCTAssertNil(f.selector.selection)
    XCTAssertEqual(f.selector.commits, 0)
    XCTAssertFalse(f.service.eligibleForEntry)
    XCTAssertEqual(f.transport.count, 1)
    try removeFixture(f.root)
  }

  func testFailedReplacementPreservesLastGoodAndExplicitRetryPromotesNewGeneration() async throws {
    let f = try fixture()
    let old = try XCTUnwrap(f.service.activeSelection)
    let lease = try f.service.acquireLease()
    var entry = "fixture-retry-key"
    let draft = Binding(get: { entry }, set: { entry = $0 })
    submitProviderAPIKey(draft, service: f.service)
    await waitUntil { f.transport.count == 1 }
    XCTAssertTrue(f.service.isTesting)
    XCTAssertTrue(f.service.eligibleForEntry)
    XCTAssertEqual(f.service.activeSelection, old)
    f.service.restore() // Opening Settings while probing must not overwrite progress.
    XCTAssertTrue(f.service.isTesting)
    f.transport.fail(0)
    await waitUntil { f.service.phase == .failed(.authentication) }
    f.service.restore() // Reopening Settings keeps the previous replacement outcome.
    XCTAssertEqual(f.service.phase, .failed(.authentication))
    XCTAssertEqual(f.transport.count, 1)
    XCTAssertEqual(f.service.activeSelection, old)
    XCTAssertTrue(f.service.eligibleForEntry)
    XCTAssertEqual(f.selector.commits, 0)
    XCTAssertTrue(try f.service.mayPublish(lease))
    XCTAssertFalse(f.service.availabilityMessage.contains("fixture-last-good"))
    XCTAssertEqual(entry, "fixture-retry-key")

    submitProviderAPIKey(draft, service: f.service)
    await waitUntil { f.transport.count == 2 }
    try f.transport.complete(1)
    await waitUntil { !f.service.isTesting }
    let new = try XCTUnwrap(f.service.activeSelection)
    XCTAssertNotEqual(new.slotID, old.slotID)
    XCTAssertEqual(new.configGeneration, 42)
    XCTAssertEqual(f.service.phase, .connected(new))
    XCTAssertEqual(f.selector.selection, new)
    XCTAssertEqual(f.selector.commits, 1)
    XCTAssertTrue(entry.isEmpty)
    XCTAssertEqual(try f.slots.read(new.slotID), "fixture-retry-key")
    submitProviderAPIKey(draft, service: f.service) // A second Return has no credential to send.
    XCTAssertFalse(f.service.isTesting)
    XCTAssertEqual(f.transport.count, 2)
    XCTAssertFalse(try f.service.mayPublish(lease))
    XCTAssertEqual(try f.slots.read(old.slotID), "fixture-last-good")
    let currentLease = try f.service.acquireLease()
    XCTAssertEqual(currentLease.selection, new)
    try f.service.releaseAfterTermination(lease)
    XCTAssertFalse(FileManager.default.fileExists(
      atPath: f.root.appendingPathComponent("slots").appendingPathComponent(old.slotID.uuidString).path))
    try f.service.releaseAfterTermination(currentLease)
    try removeFixture(f.root)
  }

  func testEditAndCancelRejectLateCandidatesWithoutChangingCurrentSelection() async throws {
    let f = try fixture()
    let old = f.service.activeSelection
    f.service.reconnect(key: "fixture-edited")
    await waitUntil { f.transport.count == 1 }
    f.service.candidateEdited()
    XCTAssertFalse(f.service.isTesting)
    f.service.reconnect(key: "fixture-cancelled")
    await waitUntil { f.transport.count == 2 }
    f.service.cancel()
    XCTAssertEqual(f.service.phase, .failed(.cancelled))
    var entry = "fixture-cancelled"
    let binding = providerSettingsKeyBinding(Binding(get: { entry }, set: { entry = $0 }),
      service: f.service)
    binding.wrappedValue = "fixture-edit-after-cancel"
    XCTAssertEqual(f.service.phase, .failed(.cancelled))
    try f.transport.complete(1)
    try f.transport.complete(0)
    await waitUntil {
      (try? FileManager.default.contentsOfDirectory(atPath: f.root.appendingPathComponent("slots").path).count) == 1
    }
    XCTAssertEqual(f.service.phase, .failed(.cancelled))
    XCTAssertEqual(f.service.activeSelection, old)
    XCTAssertEqual(f.selector.selection, old)
    XCTAssertTrue(f.service.eligibleForEntry)
    XCTAssertEqual(f.selector.commits, 0)
    try removeFixture(f.root)
  }

  func testNewestCandidateWinsWithReverseCompletionsAndNoStaleDisplay() async throws {
    let f = try fixture()
    f.service.reconnect(key: "fixture-older-candidate")
    await waitUntil { f.transport.count == 1 }
    f.service.reconnect(key: "fixture-newer-candidate")
    await waitUntil { f.transport.count == 2 }
    try f.transport.complete(1)
    await waitUntil { !f.service.isTesting }
    let winner = try XCTUnwrap(f.service.activeSelection)
    XCTAssertEqual(winner.configGeneration, 42)
    try f.transport.complete(0)
    await waitUntil {
      (try? FileManager.default.contentsOfDirectory(atPath: f.root.appendingPathComponent("slots").path).count) == 1
    }
    XCTAssertEqual(f.service.phase, .connected(winner))
    XCTAssertEqual(f.service.activeSelection, winner)
    XCTAssertEqual(f.selector.selection, winner)
    XCTAssertEqual(f.selector.commits, 1)
    XCTAssertEqual(try f.slots.read(winner.slotID), "fixture-newer-candidate")
    try removeFixture(f.root)
  }

  func testFixtureEvidenceDoesNotActivateMissingConnectionAndRestoreDoesNotSend() async throws {
    let f = try fixture(lastGood: false)
    XCTAssertFalse(f.service.eligibleForEntry)
    f.service.reconnect(key: "fixture-not-authenticated")
    await waitUntil { f.transport.count == 1 }
    try f.transport.complete(0, evidence: .deterministicFixture)
    await waitUntil { f.service.phase == .failed(.authentication) }
    XCTAssertNil(f.selector.selection)
    XCTAssertNil(f.service.activeSelection)
    XCTAssertFalse(f.service.eligibleForEntry)
    XCTAssertThrowsError(try f.service.acquireLease())
    f.service.restore()
    XCTAssertEqual(f.transport.count, 1)
    XCTAssertEqual(f.service.phase, .failed(.authentication))
    try removeFixture(f.root)
  }

  func testRestoringSettingsStillDetectsMissingSelectedKeyAfterFailedReplacement() async throws {
    let f = try fixture()
    defer { try? removeFixture(f.root) }
    let old = try XCTUnwrap(f.service.activeSelection)
    f.service.reconnect(key: "fixture-rejected")
    await waitUntil { f.transport.count == 1 }
    guard f.transport.count == 1 else { return }
    f.transport.fail(0)
    await waitUntil { f.service.phase == .failed(.authentication) }

    try f.slots.remove(old.slotID)
    f.service.restore()
    XCTAssertEqual(f.selector.selection, old)
    XCTAssertNil(f.service.activeSelection)
    XCTAssertFalse(f.service.eligibleForEntry)
    XCTAssertEqual(f.service.phase, .failed(.unsafeStorage))
    XCTAssertEqual(f.transport.count, 1)
  }

  func testCleanupDebtPropagatesAndRemainsVisibleDuringEntryEdits() async throws {
    let f = try fixture()
    let old = try XCTUnwrap(f.service.activeSelection)
    let lease = try f.service.acquireLease()
    f.service.reconnect(key: "fixture-replacement")
    await waitUntil { f.transport.count == 1 }
    try f.transport.complete(0)
    await waitUntil { !f.service.isTesting }
    let oldURL = f.root.appendingPathComponent("slots").appendingPathComponent(old.slotID.uuidString)
    XCTAssertEqual(chmod(oldURL.path, 0o644), 0)
    XCTAssertThrowsError(try f.service.releaseAfterTermination(lease)) { error in
      XCTAssertEqual(error as? APIKeyConnectionError, .cleanupBlocked)
    }
    XCTAssertEqual(f.service.phase, .failed(.cleanupBlocked))
    XCTAssertFalse(f.service.eligibleForEntry)
    var entry = "fixture-replacement"
    let binding = providerSettingsKeyBinding(Binding(get: { entry }, set: { entry = $0 }),
      service: f.service)
    binding.wrappedValue = "fixture-edit-with-cleanup-debt"
    XCTAssertEqual(f.service.phase, .failed(.cleanupBlocked))
    XCTAssertTrue(FileManager.default.fileExists(atPath: oldURL.path))
    XCTAssertThrowsError(try f.service.acquireLease())
    // Removing this wholly test-owned fixture is not production cleanup remediation.
    try removeFixture(f.root)
  }
}
