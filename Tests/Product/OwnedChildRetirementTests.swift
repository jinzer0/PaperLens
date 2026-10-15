import Darwin
import Dispatch
import Foundation
import XCTest

@testable import PaperLensProduct

/// Run EACH method in a fresh isolated test process. Unknown roots intentionally never reset.
/// Fixture teardown is physical hygiene only; it cannot discharge production debt.
@MainActor
final class OwnedChildRetirementTests: XCTestCase {
  // Existing aggregate owned-cleanup AC, not a new production duration/default/grace.
  private let cleanupBudgetNanoseconds: UInt64 = 300_000_000

  private final class Counts: @unchecked Sendable {
    let lock = NSLock()
    var effects = 0
    var terminals = 0
    var closeAttempts = 0
    var capturedChild: OwnedChildRetirement?
    func effect() { lock.withLock { effects += 1 } }
    func terminal() { lock.withLock { terminals += 1 } }
    func closeAttempt() { lock.withLock { closeAttempts += 1 } }
    func revokeCapturedChild() {
      let child = lock.withLock { capturedChild }
      child?.revoke()
    }
    var snapshot: (Int, Int, Int) { lock.withLock { (effects, terminals, closeAttempts) } }
  }
  private func cwd() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    XCTAssertEqual(chmod(directory.path, 0o700), 0)
    return directory
  }
  private func owner(
    _ fixture: OwnedChildRetirement.Fixture, _ directory: URL,
    hooks: OwnedChildRetirement.Hooks = .init(), remaining: UInt64? = nil
  ) -> OwnedChildRetirement {
    OwnedChildRetirement(
      fixture: fixture, privateWorkingDirectory: directory,
      deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds
        + (remaining ?? cleanupBudgetNanoseconds),
      hooks: hooks)
  }
  private func terminalExpectation(_ owner: OwnedChildRetirement, counts: Counts? = nil)
    -> XCTestExpectation
  {
    let done = expectation(description: "native terminal")
    owner.observeTerminal { _ in
      counts?.terminal()
      done.fulfill()
    }
    return done
  }
  private var budgetSeconds: TimeInterval { Double(cleanupBudgetNanoseconds) / 1_000_000_000 }
  private final class Switch: @unchecked Sendable {
    let lock = NSLock()
    private var armed = false
    var value: Bool { lock.withLock { armed } }
    func arm() { lock.withLock { armed = true } }
  }
  private func start(_ child: OwnedChildRetirement) async throws -> OwnedPipeAgentRPCChannel {
    try await withCheckedThrowingContinuation { continuation in
      child.start(
        startDeadlineUptimeNanoseconds:
          DispatchTime.now().uptimeNanoseconds + 1_000_000_000
      ) { result in
        continuation.resume(with: result.mapError { $0 as Error })
      }
    }
  }

  func testRunningCatFramedEchoSameLifecycleAndFixedFirstRevoke() async throws {
    let directory = try cwd()
    defer { try? FileManager.default.removeItem(at: directory) }
    let child = OwnedChildRetirement(runningFixture: .cat, privateWorkingDirectory: directory)
    let channel = try await start(child)
    XCTAssertTrue(child.testingChannel === channel)
    XCTAssertNil(child.terminal)
    XCTAssertFalse(child.testingReaped)
    let lifecycle = try AgentConnectionLifecycle(ownedPipe: channel)
    let frame = Data([0, 0, 0, 3, 1, 2, 3])
    try await channel.write(frame)
    var echoed = Data()
    while echoed.count < frame.count {
      let bytes = try await channel.read()
      echoed.append(try XCTUnwrap(bytes))
    }
    XCTAssertEqual(echoed, frame)
    XCTAssertNil(child.terminal)
    let done = terminalExpectation(child)
    let t0 = DispatchTime.now().uptimeNanoseconds
    let deadline = child.revoke()
    XCTAssertLessThanOrEqual(deadline - t0, cleanupBudgetNanoseconds + 1_000_000)
    XCTAssertEqual(child.revoke(), deadline)
    do {
      try await channel.write(frame)
      XCTFail("Revoke admitted new channel IO")
    } catch {
      XCTAssertEqual(error as? OwnedPipeAgentRPCChannel.Failure, .closed)
    }
    lifecycle.close()
    await fulfillment(of: [done], timeout: 1)
    XCTAssertEqual(child.revoke(), deadline)
    XCTAssertTrue(channel.closureOutcome.bothClosed)
    assertClean(child)
  }

  func testRunningFacadeLossRevokesActualChannelAndReapsCat() async throws {
    let directory = try cwd()
    defer { try? FileManager.default.removeItem(at: directory) }
    var child: OwnedChildRetirement? = OwnedChildRetirement(
      runningFixture: .cat, privateWorkingDirectory: directory)
    let channel = try await start(try XCTUnwrap(child))
    let done = terminalExpectation(try XCTUnwrap(child))
    let rooted = try XCTUnwrap(child).testingRootWitness
    weak var facade = child
    child = nil
    XCTAssertNil(facade)
    await fulfillment(of: [done], timeout: 1)
    XCTAssertTrue(channel.closureOutcome.bothClosed)
    XCTAssertFalse(rooted())
  }

  func testRunningTrueEOFUsesImmutableActualOwnerCallbackDespiteObserverReplacement() async throws {
    let directory = try cwd()
    defer { try? FileManager.default.removeItem(at: directory) }
    let child = OwnedChildRetirement(
      runningFixture: .trueUtility, privateWorkingDirectory: directory)
    let channel = try await start(child)
    let done = terminalExpectation(child)
    channel.observeClosure { _ in XCTFail("Replaced external callback ran") }
    let external = expectation(description: "replaceable external closure notification")
    channel.observeClosure { outcome in
      XCTAssertTrue(outcome.bothClosed)
      external.fulfill()
    }
    let eof = try await channel.read()
    XCTAssertNil(eof)
    await fulfillment(of: [done, external], timeout: 1)
    assertClean(child)
  }

  func testRunningPartialChannelSetupCapturedBeforeIndependentDeadlineNoLateClean() async throws {
    let directory = try cwd()
    defer { try? FileManager.default.removeItem(at: directory) }
    let release = DispatchSemaphore(value: 0)
    let counts = Counts()
    var hooks = OwnedChildRetirement.Hooks()
    hooks.before = { _ in counts.effect() }
    // This is the real MainActor setup interval after actual Owner capture.
    hooks.beforeChannelSetup = { release.wait() }
    let child = OwnedChildRetirement(
      runningFixture: .cat, privateWorkingDirectory: directory, hooks: hooks)
    let done = expectation(
      description: "startup expiry and cleanup expiry independent of MainActor")
    child.observeTerminal { terminal in
      XCTAssertEqual(terminal, .unknown(.deadline))
      counts.terminal()
      release.signal()
      done.fulfill()
    }
    let ready = expectation(description: "no late ready success")
    child.start(
      startDeadlineUptimeNanoseconds:
        DispatchTime.now().uptimeNanoseconds + 1_000_000_000
    ) { result in
      if case .success = result { XCTFail("Late setup published running") }
      ready.fulfill()
    }
    await fulfillment(of: [done, ready], timeout: 3)
    XCTAssertNotNil(child.testingChannel)
    XCTAssertEqual(child.testingDescriptorCount, 1)
    XCTAssertTrue(child.testingRetained)
    XCTAssertFalse(child.testingReaped)
    let effects = counts.snapshot.0
    let deadline = child.revoke()
    XCTAssertEqual(child.revoke(), deadline)
    XCTAssertEqual(counts.snapshot.0, effects)
    let hygiene = expectation(description: "physical hygiene without debt discharge")
    child.testingPhysicalTeardown { _ in hygiene.fulfill() }
    await fulfillment(of: [hygiene], timeout: 1)
    XCTAssertTrue(child.testingRetained)
    XCTAssertEqual(child.terminal, .unknown(.deadline))
    let replacement = owner(.trueUtility, directory)
    let refused = terminalExpectation(replacement)
    replacement.retire()
    await fulfillment(of: [refused], timeout: 1)
    XCTAssertEqual(replacement.terminal, .unknown(.admissionBlocked))
    XCTAssertEqual(counts.snapshot.1, 1)
  }

  func testRevokedCapturedStartupCompletesFailureOnceDespiteCleanRetirement() async throws {
    let directory = try cwd()
    defer { try? FileManager.default.removeItem(at: directory) }
    let counts = Counts()
    var hooks = OwnedChildRetirement.Hooks()
    hooks.beforeChannelSetup = { counts.revokeCapturedChild() }
    let child = OwnedChildRetirement(
      runningFixture: .cat, privateWorkingDirectory: directory, hooks: hooks)
    counts.lock.withLock { counts.capturedChild = child }
    defer { counts.lock.withLock { counts.capturedChild = nil } }
    let done = terminalExpectation(child)
    let ready = expectation(description: "captured startup resolves even when retirement is clean")
    ready.assertForOverFulfill = true
    child.start(
      startDeadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 5_000_000_000
    ) { result in
      if case .success = result { XCTFail("Revoked setup published running") }
      ready.fulfill()
    }
    await fulfillment(of: [ready, done], timeout: 2)
    assertClean(child)
  }

  func testRunningHeldActualChannelCloseStopsAtOneAbsoluteDeadline() async throws {
    let directory = try cwd()
    defer { try? FileManager.default.removeItem(at: directory) }
    let gate = Switch()
    let release = DispatchSemaphore(value: 0)
    let counts = Counts()
    var hooks = OwnedChildRetirement.Hooks()
    hooks.before = { _ in counts.effect() }
    hooks.afterClose = { if gate.value { release.wait() } }
    let child = OwnedChildRetirement(
      runningFixture: .cat, privateWorkingDirectory: directory, hooks: hooks)
    let channel = try await start(child)
    let done = expectation(description: "terminal lane does not join held MainActor close")
    child.observeTerminal { terminal in
      XCTAssertEqual(terminal, .unknown(.deadline))
      counts.terminal()
      release.signal()
      done.fulfill()
    }
    gate.arm()
    let deadline = child.revoke()
    await fulfillment(of: [done], timeout: 1)
    XCTAssertEqual(child.revoke(), deadline)
    XCTAssertFalse(channel.closureOutcome.bothClosed)
    XCTAssertEqual(channel.closureOutcome.read, .closed)
    XCTAssertEqual(channel.closureOutcome.write, .unknown)
    XCTAssertTrue(child.testingRetained)
    let effects = counts.snapshot.0
    channel.requestClose()
    XCTAssertEqual(counts.snapshot.0, effects)
    let hygiene = expectation(description: "actual fixture hygiene")
    child.testingPhysicalTeardown { _ in hygiene.fulfill() }
    await fulfillment(of: [hygiene], timeout: 1)
    XCTAssertEqual(child.terminal, .unknown(.deadline))
    XCTAssertTrue(child.testingRetained)
    XCTAssertEqual(counts.snapshot.1, 1)
  }

  func testRunningActualChannelCloseFailureNoSecondCloseRetryOrLateClean() async throws {
    let directory = try cwd()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fault = Switch()
    let counts = Counts()
    var hooks = OwnedChildRetirement.Hooks()
    hooks.closeFault = {
      if fault.value {
        counts.closeAttempt()
        return true
      }
      return false
    }
    let child = OwnedChildRetirement(
      runningFixture: .cat, privateWorkingDirectory: directory, hooks: hooks)
    let channel = try await start(child)
    let done = terminalExpectation(child, counts: counts)
    fault.arm()
    let deadline = child.revoke()
    await fulfillment(of: [done], timeout: 1)
    XCTAssertEqual(child.terminal, .unknown(.close))
    XCTAssertEqual(channel.closureOutcome.read, .unknown)
    XCTAssertEqual(channel.closureOutcome.write, .unknown)
    XCTAssertEqual(counts.snapshot.2, 1)
    channel.requestClose()
    XCTAssertEqual(child.revoke(), deadline)
    XCTAssertEqual(counts.snapshot.2, 1)
    let hygiene = expectation(description: "failed-close fixture hygiene")
    child.testingPhysicalTeardown { _ in hygiene.fulfill() }
    await fulfillment(of: [hygiene], timeout: 1)
    XCTAssertTrue(child.testingRetained)
    XCTAssertEqual(child.terminal, .unknown(.close))
    XCTAssertEqual(counts.snapshot.1, 1)
  }
  private func assertClean(_ owner: OwnedChildRetirement) {
    XCTAssertEqual(
      owner.terminal,
      .clean(.init(checkedDescriptorCloses: 6, childReaped: true, childExitStatus: 0)))
    XCTAssertTrue(owner.testingChildExists)
    XCTAssertTrue(owner.testingReaped)
    XCTAssertEqual(owner.testingDescriptorCount, 0)
    XCTAssertFalse(owner.testingRetained)
  }

  func testTrueActualReapAndSixCheckedClosesSoleInvocation() async throws {
    let directory = try cwd()
    defer { try? FileManager.default.removeItem(at: directory) }
    let counts = Counts()
    var hooks = OwnedChildRetirement.Hooks()
    hooks.before = { _ in counts.effect() }
    let child = owner(.trueUtility, directory, hooks: hooks)
    let done = terminalExpectation(child, counts: counts)
    child.retire()
    child.retire()
    await fulfillment(of: [done], timeout: budgetSeconds)
    assertClean(child)
    let before = counts.snapshot
    child.retire()
    XCTAssertEqual(counts.snapshot.0, before.0)
    XCTAssertEqual(counts.snapshot.1, 1)
  }

  func testCatActualStdinEOFThenWaitpidAndCheckedCloses() async throws {
    let directory = try cwd()
    defer { try? FileManager.default.removeItem(at: directory) }
    let child = owner(.cat, directory)
    let done = terminalExpectation(child)
    child.retire()
    await fulfillment(of: [done], timeout: budgetSeconds)
    assertClean(child)
  }

  func testTrueAlreadyExitedUnreapedNativeChild() async throws {
    let directory = try cwd()
    defer { try? FileManager.default.removeItem(at: directory) }
    let exited = expectation(description: "kernel observed exited without reaping")
    var hooks = OwnedChildRetirement.Hooks()
    hooks.afterSpawn = { actualChild in
      var information = siginfo_t()
      // A genuine blocking native observation on the operation lane, not a forged PID/proof.
      let result = waitid(P_PID, id_t(actualChild), &information, WEXITED | WNOWAIT)
      XCTAssertEqual(result, 0)
      XCTAssertEqual(information.si_pid, actualChild)
      exited.fulfill()
    }
    let child = owner(.trueUtility, directory, hooks: hooks)
    let done = terminalExpectation(child)
    child.retire()
    await fulfillment(of: [exited, done], timeout: budgetSeconds)
    assertClean(child)
  }

  func testHeldRealLaneIndependentExpiryFacadeLossNoLateCleanOrReplacement() async throws {
    let directory = try cwd()
    defer { try? FileManager.default.removeItem(at: directory) }
    let counts = Counts()
    let held = expectation(description: "real spawned child lane held")
    let release = DispatchSemaphore(value: 0)
    var hooks = OwnedChildRetirement.Hooks()
    hooks.before = { effect in
      counts.effect()
      if case .close = effect {
        held.fulfill()
        release.wait()
      }
    }
    let start = DispatchTime.now().uptimeNanoseconds
    var facade: OwnedChildRetirement? = owner(
      .cat, directory, hooks: hooks,
      remaining: cleanupBudgetNanoseconds / 2)
    weak var weakFacade = facade
    let rooted = facade!.testingRootWitness
    let done = terminalExpectation(facade!, counts: counts)
    facade!.retire()
    await fulfillment(of: [held, done], timeout: budgetSeconds)
    XCTAssertLessThan(DispatchTime.now().uptimeNanoseconds - start, cleanupBudgetNanoseconds)
    XCTAssertEqual(facade!.terminal, .unknown(.deadline))
    XCTAssertTrue(facade!.testingChildExists)
    XCTAssertFalse(facade!.testingReaped)
    XCTAssertEqual(facade!.testingDescriptorCount, 6)
    let effects = counts.snapshot.0
    facade!.retire()
    XCTAssertEqual(counts.snapshot.0, effects)
    XCTAssertTrue(rooted())
    // Capture hygiene before dropping the facade; the production root owns the actual core.
    let hygiene = expectation(description: "separate physical teardown")
    facade!.testingPhysicalTeardown { allWereOpen in
      XCTAssertTrue(allWereOpen)
      hygiene.fulfill()
    }
    facade = nil
    XCTAssertNil(weakFacade)
    XCTAssertTrue(rooted())
    release.signal()
    await fulfillment(of: [hygiene], timeout: budgetSeconds)
    XCTAssertTrue(rooted())
    XCTAssertEqual(counts.snapshot.0, effects)
    XCTAssertEqual(counts.snapshot.1, 1)
    let replacement = owner(.trueUtility, directory)
    let refused = terminalExpectation(replacement)
    replacement.retire()
    await fulfillment(of: [refused], timeout: budgetSeconds)
    XCTAssertEqual(replacement.terminal, .unknown(.admissionBlocked))
    XCTAssertFalse(replacement.testingChildExists)
    XCTAssertEqual(replacement.testingDescriptorCount, 0)
  }

  func testPartialSetupActualPipeRetentionNoRetry() async throws {
    let directory = try cwd()
    defer { try? FileManager.default.removeItem(at: directory) }
    let counts = Counts()
    var hooks = OwnedChildRetirement.Hooks()
    hooks.before = { _ in counts.effect() }
    hooks.afterPipeFault = { true }
    let child = owner(.trueUtility, directory, hooks: hooks)
    let done = terminalExpectation(child, counts: counts)
    child.retire()
    await fulfillment(of: [done], timeout: budgetSeconds)
    XCTAssertEqual(child.terminal, .unknown(.setup))
    XCTAssertEqual(child.testingDescriptorCount, 2)
    XCTAssertFalse(child.testingChildExists)
    XCTAssertTrue(child.testingRetained)
    let before = counts.snapshot.0
    child.retire()
    XCTAssertEqual(counts.snapshot.0, before)
    let hygiene = expectation(description: "physical pipe teardown")
    child.testingPhysicalTeardown { allWereOpen in
      XCTAssertTrue(allWereOpen)
      hygiene.fulfill()
    }
    await fulfillment(of: [hygiene], timeout: budgetSeconds)
    XCTAssertTrue(child.testingRetained)
    XCTAssertEqual(child.terminal, .unknown(.setup))
  }

  func testActualCloseEBADFLeavesAllOwnedFDsAndNoRetry() async throws {
    let directory = try cwd()
    defer { try? FileManager.default.removeItem(at: directory) }
    let counts = Counts()
    var hooks = OwnedChildRetirement.Hooks()
    hooks.closeFault = {
      counts.closeAttempt()
      return true
    }
    let child = owner(.cat, directory, hooks: hooks)
    let done = terminalExpectation(child, counts: counts)
    child.retire()
    await fulfillment(of: [done], timeout: budgetSeconds)
    XCTAssertEqual(child.terminal, .unknown(.close))
    XCTAssertTrue(child.testingChildExists)
    XCTAssertEqual(child.testingDescriptorCount, 6)
    XCTAssertFalse(child.testingReaped)
    XCTAssertTrue(child.testingRetained)
    child.retire()
    XCTAssertEqual(counts.snapshot.2, 1)
    let hygiene = expectation(description: "physical child teardown")
    child.testingPhysicalTeardown { allWereOpen in
      XCTAssertTrue(allWereOpen)
      hygiene.fulfill()
    }
    await fulfillment(of: [hygiene], timeout: budgetSeconds)
    XCTAssertTrue(child.testingRetained)
    XCTAssertEqual(child.terminal, .unknown(.close))
    XCTAssertEqual(counts.snapshot.1, 1)
  }

  func testAlreadyExpiredDeadlineAdmitsNoNativeEffect() async throws {
    let directory = try cwd()
    defer { try? FileManager.default.removeItem(at: directory) }
    let child = OwnedChildRetirement(
      fixture: .trueUtility, privateWorkingDirectory: directory,
      deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds)
    let done = terminalExpectation(child)
    child.retire()
    await fulfillment(of: [done], timeout: budgetSeconds)
    XCTAssertEqual(child.terminal, .unknown(.deadline))
    XCTAssertFalse(child.testingChildExists)
    XCTAssertEqual(child.testingDescriptorCount, 0)
  }

  func testBackupAlreadyExpiredDeadlineOwnsNamespaceWithoutDuplicatingDescriptors() async throws {
    let repository = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let directory = repository.appendingPathComponent(
      ".build/owned-backup-deadline-" + UUID().uuidString.lowercased(), isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: directory) }
    let namespace = try XCTUnwrap(
      TopologyOwnedFixtures(root: directory, runID: UUID().uuidString.lowercased()))
    let child = OwnedChildRetirement(
      backup: .init(
        namespace: namespace, interpreter: URL(fileURLWithPath: "/usr/bin/python3"),
        script: URL(fileURLWithPath: "/unopened-agent.py"), reference: "unopened-reference"),
      deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds)
    let done = terminalExpectation(child)
    child.retire()
    await fulfillment(of: [done], timeout: budgetSeconds)
    XCTAssertEqual(child.terminal, .unknown(.deadline))
    XCTAssertFalse(child.testingChildExists)
    XCTAssertEqual(child.testingDescriptorCount, 0)
    XCTAssertTrue(child.testingRetained)
    XCTAssertGreaterThanOrEqual(fcntl(namespace.descriptor, F_GETFD), 0)
    XCTAssertGreaterThanOrEqual(fcntl(namespace.metadataParentDescriptor, F_GETFD), 0)
    XCTAssertFalse(namespace.permitsNamespaceMutation)
    XCTAssertFalse(namespace.cleanup())
    XCTAssertFalse(namespace.create("M"))
    XCTAssertFalse(namespace.prepareLinks(["M"]))
    var entry = stat()
    XCTAssertEqual(
      fstatat(namespace.metadataParentDescriptor, namespace.runID, &entry, AT_SYMLINK_NOFOLLOW), 0)
  }
}
