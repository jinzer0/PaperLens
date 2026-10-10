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
private final class SettingsSuspendedTransport: NativeConnectionTestTransport {
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
    let service: ProviderSettingsService
  }

  private func fixture(lastGood: Bool = true) throws -> Fixture {
    let alias = FileManager.default.temporaryDirectory
      .appendingPathComponent("paperlens-settings-fixture-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: alias, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    guard let physicalPath = realpath(alias.path, nil) else {
      throw APIKeyConnectionError.unsafeStorage
    }
    defer { free(physicalPath) }
    let root = URL(fileURLWithPath: String(cString: physicalPath), isDirectory: true)
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
    return Fixture(root: root, slots: slots, selector: selector, transport: transport, service: service)
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

  func testKeyBindingInvalidatesSharedCandidateBeforeChangedEntryWriteAndRejectsLateSuccess() async throws {
    let f = try fixture()
    let old = try XCTUnwrap(f.service.activeSelection)
    let lease = try f.service.acquireLease()
    var entry = "fixture-binding-candidate"
    var phasesAtWrite: [APIKeyConnectionPhase] = []
    let binding = providerSettingsKeyBinding(Binding(get: { entry }, set: { next in
      phasesAtWrite.append(f.service.phase)
      XCTAssertEqual(f.service.activeSelection, old)
      XCTAssertEqual(f.selector.commits, 0)
      entry = next
    }), service: f.service)
    f.service.reconnect(key: entry)
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
    f.service.reconnect(key: "fixture-rejected")
    await waitUntil { f.transport.count == 1 }
    XCTAssertTrue(f.service.isTesting)
    XCTAssertTrue(f.service.eligibleForEntry)
    XCTAssertEqual(f.service.activeSelection, old)
    f.service.restore() // Opening Settings while probing must not overwrite progress.
    XCTAssertTrue(f.service.isTesting)
    f.transport.fail(0)
    await waitUntil { f.service.phase == .failed(.authentication) }
    XCTAssertEqual(f.service.activeSelection, old)
    XCTAssertTrue(f.service.eligibleForEntry)
    XCTAssertEqual(f.selector.commits, 0)
    XCTAssertTrue(try f.service.mayPublish(lease))
    XCTAssertFalse(f.service.availabilityMessage.contains("fixture-last-good"))

    f.service.reconnect(key: "fixture-retry")
    await waitUntil { f.transport.count == 2 }
    try f.transport.complete(1)
    await waitUntil { !f.service.isTesting }
    let new = try XCTUnwrap(f.service.activeSelection)
    XCTAssertNotEqual(new.slotID, old.slotID)
    XCTAssertEqual(new.configGeneration, 42)
    XCTAssertEqual(f.service.phase, .connected(new))
    XCTAssertEqual(f.selector.selection, new)
    XCTAssertEqual(f.selector.commits, 1)
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
    XCTAssertEqual(f.service.phase, .idle)
    try removeFixture(f.root)
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
