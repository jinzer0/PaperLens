import JobRecoveryPolicy
import XCTest

// Contract fixtures only: opaque versions and class-owner attestations are not physical drain,
// authenticated provider output, SQLite transactions, allocator durability, or product wiring.
final class JobRecoveryPolicyTests: XCTestCase {
  private typealias P = JobRecoveryPolicy
  private let result = P.Result(id: "validated-result")

  private func input(_ role: P.Role, version: String = "input-1") -> P.Input {
    switch role {
    case .import: return .source(version: version)
    case .parsing: return .parser(version: version)
    case .translation: return .translation(version: version)
    case .chatPreparation: return .chatPreparation(version: version)
    case .chatRequest: return .chatRequest(version: version)
    case .brief: return .brief(version: version, templateGeneration: "template-1")
    case .librarySummary: return .librarySummary(version: version)
    }
  }

  private func authority(
    _ role: P.Role = .translation, version: String = "input-1", config: P.Config? = nil,
    paper: P.Paper = P.Paper(id: "paper", generation: "paper-1"),
    epoch: String = "process-1", available: Bool = true
  ) -> P.Authority {
    let provider =
      role == .translation || role == .chatRequest || role == .brief || role == .librarySummary
    return P.Authority(
      input: input(role, version: version),
      config: config ?? (provider ? .generation("config-1") : .inapplicable),
      paper: paper, epoch: epoch, prerequisitesAvailable: available)
  }

  private func reservation(_ suffix: String = "1") -> P.Reservation {
    P.Reservation(
      attempt: "attempt-" + suffix, fence: "fence-" + suffix,
      correlation: "correlation-" + suffix)
  }

  private func pending(_ role: P.Role = .translation) throws -> P.Snapshot {
    try P.create(job: "job", role: role, authority: authority(role), reservation: reservation())
  }

  @discardableResult
  private func admit(
    _ event: P.Event, _ snapshot: inout P.Snapshot, file: StaticString = #filePath,
    line: UInt = #line
  ) -> [P.Command] {
    let decision = P.apply(event, to: snapshot)
    XCTAssertNil(decision.rejection, file: file, line: line)
    snapshot = decision.snapshot
    return decision.commands
  }

  private func rejects(
    _ event: P.Event, _ snapshot: P.Snapshot, _ error: P.Rejection,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    let decision = P.apply(event, to: snapshot)
    XCTAssertEqual(decision.rejection, error, file: file, line: line)
    XCTAssertEqual(decision.snapshot, snapshot, file: file, line: line)
    XCTAssertEqual(decision.commands, [], file: file, line: line)
  }

  private func running(_ role: P.Role = .translation) throws -> P.Snapshot {
    var s = try pending(role)
    admit(.claim(s.current.lineage), &s)
    return s
  }

  private func finishCleanup(
    _ owner: P.Lineage, permit: String, _ s: inout P.Snapshot,
    operation: String = "cleanup-1", succeeded: Bool = true
  ) {
    let invocation = P.Operation(id: operation, paper: owner.captured.paper)
    XCTAssertEqual(
      admit(.requestCleanup(owner, permit: permit, operation: operation), &s),
      [.removeOwnedBytes(owner, permit, invocation)])
    admit(.cleanupFinished(owner, permit: permit, operation: invocation, succeeded: succeeded), &s)
  }

  private func writer(_ role: P.Role = .translation) throws -> P.Snapshot {
    var s = try running(role)
    let owner = s.current.lineage
    XCTAssertEqual(
      admit(.acquireWriter(owner, permit: "writer"), &s),
      [.acquirePermit(owner, "writer", .writer)])
    return s
  }

  private func publisher(_ role: P.Role = .translation, renamed: Bool = true) throws -> P.Snapshot {
    var s = try writer(role)
    let owner = s.current.lineage
    admit(.writerClosure(owner, permit: "writer", .closed(.validated(result))), &s)
    XCTAssertEqual(
      admit(.acquirePublication(owner, writer: "writer", permit: "publisher"), &s),
      [.acquirePermit(owner, "publisher", .publication), .releasePermit(owner, "writer")])
    if renamed {
      XCTAssertEqual(
        admit(.rename(owner, permit: "publisher"), &s),
        [.rename(owner, "publisher", result)])
      admit(.renameFinished(owner, permit: "publisher", succeeded: true), &s)
    }
    return s
  }

  private func changedLineage(
    _ l: P.Lineage, job: String? = nil, attempt: String? = nil, fence: String? = nil,
    correlation: String? = nil, captured: P.Authority? = nil
  ) -> P.Lineage {
    P.Lineage(
      job: job ?? l.job,
      reservation: P.Reservation(
        attempt: attempt ?? l.reservation.attempt,
        fence: fence ?? l.reservation.fence, correlation: correlation ?? l.reservation.correlation),
      captured: captured ?? l.captured)
  }

  func testAllSevenRolesHaveExplicitApplicabilityAndGuardedSuccess() throws {
    for role in P.Role.allCases {
      var s = try publisher(role)
      let owner = s.current.lineage
      XCTAssertEqual(
        admit(.publish(owner, permit: "publisher", result), &s),
        [.commit(owner, "publisher", result)])
      XCTAssertEqual(s.current.state, .succeeded)
      XCTAssertEqual(s.usableResult, P.UsableResult(lineage: owner, result: result))
      let winner = s
      rejects(.publish(owner, permit: "publisher", result), winner, .state)
      rejects(.terminate(owner, .timeout), winner, .state)
      XCTAssertEqual(
        admit(.release(owner, permit: "publisher"), &s),
        [.releasePermit(owner, "publisher")])
      XCTAssertTrue(s.permits.isEmpty)
      XCTAssertEqual(s.usableResult, winner.usableResult)
    }
  }

  func testAllRolesRejectWrongInputAndConfigApplicabilityAndMissingPrerequisites() throws {
    for role in P.Role.allCases {
      let a = authority(role)
      let provider = a.config != .inapplicable
      let wrongConfig: P.Config = provider ? .inapplicable : .generation("config-1")
      XCTAssertThrowsError(
        try P.create(
          job: "job", role: role,
          authority: authority(role, config: wrongConfig), reservation: reservation())
      ) {
        XCTAssertEqual($0 as? P.Rejection, .invalidApplicability)
      }
      let wrongRole: P.Role = role == .parsing ? .import : .parsing
      XCTAssertThrowsError(
        try P.create(
          job: "job", role: role,
          authority: authority(wrongRole), reservation: reservation())
      ) {
        XCTAssertEqual($0 as? P.Rejection, .invalidApplicability)
      }
      XCTAssertThrowsError(
        try P.create(
          job: "job", role: role,
          authority: authority(role, available: false), reservation: reservation())
      ) {
        XCTAssertEqual($0 as? P.Rejection, .prerequisitesUnavailable)
      }
      var s = try running(role)
      admit(.terminate(s.current.lineage, .failed), &s)
      rejects(
        .retry(reservation("2"), authority(role, available: false)), s, .prerequisitesUnavailable)
      rejects(
        .retry(reservation("2"), authority(role, config: wrongConfig)), s, .invalidApplicability)
      admit(.retry(reservation("2"), authority(role, version: "input-2")), &s)
      XCTAssertEqual(s.current.state, .pending)
      XCTAssertEqual(s.executions[0].lineage.captured, a)
    }
  }

  func testTwoClaimsAndDispatchIntentHaveExactlyOneAdmission() throws {
    for role in P.Role.allCases {
      var s = try pending(role)
      let owner = s.current.lineage
      rejects(.dispatch(owner), s, .state)
      rejects(.claim(changedLineage(owner, fence: "foreign")), s, .fence)
      XCTAssertEqual(admit(.claim(owner), &s), [])
      rejects(.claim(owner), s, .state)
      XCTAssertEqual(admit(.dispatch(owner), &s), [.recordDispatchIntent(owner), .send(owner)])
      XCTAssertEqual(s.current.dispatch, .intentRecorded)
      rejects(.dispatch(owner), s, .dispatchAlreadyAdmitted)
      admit(.sendMayHaveHappened(owner), &s)
      XCTAssertEqual(s.current.dispatch, .mayHaveSent)
      rejects(.dispatch(owner), s, .dispatchAlreadyAdmitted)
    }
  }

  func testStartupMixedStatesIsIdempotentAndDoesNotRenewFence() throws {
    for role in P.Role.allCases {
      let p = try pending(role)
      let r = try running(role)
      var f = r
      admit(.terminate(f.current.lineage, .failed), &f)
      var success = try publisher(role)
      admit(.publish(success.current.lineage, permit: "publisher", result), &success)
      admit(.release(success.current.lineage, permit: "publisher"), &success)
      for initial in [p, r, f, success] {
        var s = initial
        let commands = admit(.startup(currentEpoch: "process-2"), &s)
        XCTAssertEqual(s.current.lineage, initial.current.lineage)
        XCTAssertEqual(s.current.dispatch, initial.current.dispatch)
        XCTAssertEqual(s.usableResult, initial.usableResult)
        if initial.current.state == .running {
          XCTAssertEqual(s.current.state, .failed(.interrupted))
          XCTAssertEqual(commands, [.cancel(initial.current.lineage)])
        } else {
          XCTAssertEqual(s.current.state, initial.current.state)
          XCTAssertEqual(commands, [])
        }
        let once = s
        XCTAssertEqual(admit(.startup(currentEpoch: "process-2"), &s), [])
        XCTAssertEqual(s, once)
      }
      var sameProcess = r
      XCTAssertEqual(admit(.startup(currentEpoch: "process-1"), &sameProcess), [])
      XCTAssertEqual(sameProcess, r)
    }
  }

  func testAmbiguousDispatchDoesNotReplayAndExplicitRetryRetainsHistory() throws {
    for mayHaveSent in [false, true] {
      var s = try running()
      let old = s.current.lineage
      admit(.dispatch(old), &s)
      if mayHaveSent { admit(.sendMayHaveHappened(old), &s) }
      admit(.startup(currentEpoch: "process-2"), &s)
      let oldExecution = s.current
      rejects(.dispatch(old), s, .state)
      rejects(.claim(old), s, .state)
      XCTAssertEqual(admit(.retry(reservation("2"), authority(epoch: "process-2")), &s), [])
      XCTAssertEqual(s.executions[0], oldExecution)
      XCTAssertEqual(s.current.dispatch, .none)
      XCTAssertNotEqual(s.current.lineage.reservation, old.reservation)
      rejects(.claim(old), s, .attempt)
      admit(.claim(s.current.lineage), &s)
      let newOwner = s.current.lineage
      admit(.sendMayHaveHappened(old), &s)
      XCTAssertEqual(s.current.lineage, newOwner)
      XCTAssertEqual(s.current.dispatch, .none)
      XCTAssertEqual(s.executions[0].dispatch, .mayHaveSent)
    }
  }

  func testReservationsRejectEveryReusedComponentWithoutPartialMutation() throws {
    var s = try running()
    let old = s.current.lineage
    rejects(.retry(reservation("2"), authority()), s, .state)
    admit(.terminate(old, .failed), &s)
    let bad: [P.Reservation] = [
      .init(attempt: old.reservation.attempt, fence: "new-f", correlation: "new-c"),
      .init(attempt: "new-a", fence: old.reservation.fence, correlation: "new-c"),
      .init(attempt: "new-a", fence: "new-f", correlation: old.reservation.correlation),
      .init(attempt: "", fence: "new-f", correlation: "new-c"),
      .init(attempt: "new-a", fence: "", correlation: "new-c"),
      .init(attempt: "new-a", fence: "new-f", correlation: ""),
    ]
    for candidate in bad {
      rejects(.retry(candidate, authority(version: "input-2")), s, .reservationUnavailable)
    }
    rejects(
      .retry(reservation("2"), authority(paper: .init(id: "another-paper", generation: "p2"))),
      s, .paper)
    XCTAssertThrowsError(
      try P.create(
        job: "", role: .translation, authority: authority(),
        reservation: reservation())
    ) { XCTAssertEqual($0 as? P.Rejection, .invalidIdentity) }
    for candidate in bad.suffix(3) {
      XCTAssertThrowsError(
        try P.create(
          job: "job", role: .translation, authority: authority(),
          reservation: candidate)
      ) { XCTAssertEqual($0 as? P.Rejection, .reservationUnavailable) }
    }
    admit(.retry(reservation("2"), authority(version: "input-2")), &s)
    XCTAssertEqual(s.executions[0].lineage, old)
    XCTAssertEqual(s.current.lineage.captured.input, input(.translation, version: "input-2"))
  }

  func testEveryPublicationGuardIndependentlyRejectsForeignCallbackWithoutTouchingOwner() throws {
    let s = try publisher()
    let owner = s.current.lineage
    let mutations: [(P.Lineage, P.Rejection)] = [
      (changedLineage(owner, job: "other-job"), .job),
      (changedLineage(owner, attempt: "other-attempt"), .attempt),
      (changedLineage(owner, fence: "other-fence"), .fence),
      (changedLineage(owner, correlation: "other-correlation"), .correlation),
      (changedLineage(owner, captured: authority(version: "other-input")), .input),
      (changedLineage(owner, captured: authority(config: .generation("other-config"))), .config),
      (changedLineage(owner, captured: authority(config: .inapplicable)), .config),
      (
        changedLineage(
          owner, captured: authority(paper: .init(id: "other", generation: "paper-1"))), .paper
      ),
      (
        changedLineage(owner, captured: authority(paper: .init(id: "paper", generation: "other"))),
        .paper
      ),
      (changedLineage(owner, captured: authority(epoch: "other-epoch")), .epoch),
    ]
    for (lineage, error) in mutations {
      rejects(.publish(lineage, permit: "publisher", result), s, error)
    }
    rejects(.publish(owner, permit: "foreign-permit", result), s, .permitOwnership)
    let combined = changedLineage(
      owner, job: "other", attempt: "other", fence: "other",
      captured: authority(version: "other", epoch: "other"))
    rejects(.publish(combined, permit: "publisher", result), s, .job)
  }

  func testEveryLiveAuthorityGuardRejectsOwnedPublicationAndRequiresCleanup() throws {
    let changes: [(P.Authority, P.Rejection)] = [
      (authority(version: "input-2"), .input),
      (authority(config: .generation("config-2")), .config),
      (authority(paper: .init(id: "paper", generation: "paper-2")), .paper),
      (authority(epoch: "process-2"), .epoch),
      (authority(available: false), .prerequisitesUnavailable),
    ]
    for (new, error) in changes {
      var s = try publisher()
      let owner = s.current.lineage
      XCTAssertEqual(admit(.authorityChanged(new), &s), [])
      let decision = P.apply(.publish(owner, permit: "publisher", result), to: s)
      XCTAssertEqual(decision.rejection, error)
      XCTAssertNil(decision.snapshot.usableResult)
      XCTAssertNotEqual(decision.snapshot.current.state, .succeeded)
      rejects(.release(owner, permit: "publisher"), decision.snapshot, .cleanupOutstanding)
      finishCleanup(owner, permit: "publisher", &s)
      admit(.release(owner, permit: "publisher"), &s)
      XCTAssertTrue(s.permits.isEmpty)
    }
    for role in [P.Role.import, .parsing, .chatPreparation] {
      let s = try publisher(role)
      let owner = s.current.lineage
      rejects(
        .publish(
          changedLineage(owner, captured: authority(role, config: .generation("wildcard"))),
          permit: "publisher", result), s, .config)
    }
  }

  func testClosedValidatedStageAndDistinctPermitAreRequiredBeforeRename() throws {
    var s = try writer()
    let owner = s.current.lineage
    rejects(
      .acquirePublication(owner, writer: "writer", permit: "publisher"), s, .stageNotValidated)
    rejects(.rename(owner, permit: "writer"), s, .permitKind)
    rejects(.publish(owner, permit: "writer", result), s, .permitKind)
    rejects(.release(owner, permit: "writer"), s, .closureUnknown)
    admit(.writerClosure(owner, permit: "writer", .open), &s)
    rejects(
      .acquirePublication(owner, writer: "writer", permit: "publisher"), s, .stageNotValidated)
    rejects(
      .writerClosure(owner, permit: "writer", .closed(.validated(.init(id: "")))), s,
      .malformedResult)
    admit(.writerClosure(owner, permit: "writer", .closed(.unvalidated)), &s)
    rejects(
      .acquirePublication(owner, writer: "writer", permit: "publisher"), s, .stageNotValidated)
    rejects(
      .writerClosure(owner, permit: "writer", .closed(.validated(result))), s, .invalidTransition)
    rejects(.release(owner, permit: "writer"), s, .cleanupOutstanding)
    admit(.terminate(owner, .failed), &s)
    finishCleanup(owner, permit: "writer", &s)
    admit(.release(owner, permit: "writer"), &s)

    var good = try writer()
    admit(.writerClosure(owner, permit: "writer", .closed(.validated(result))), &good)
    rejects(.acquirePublication(owner, writer: "writer", permit: "writer"), good, .permitIdentity)
    admit(.acquirePublication(owner, writer: "writer", permit: "publisher"), &good)
    XCTAssertEqual(good.permits.count, 1)
    XCTAssertEqual(good.permits[0].kind, .publication)
    rejects(.writerClosure(owner, permit: "publisher", .open), good, .permitKind)
    rejects(.acquirePublication(owner, writer: "writer", permit: "another"), good, .permitOwnership)
  }

  func testReverseOrderMalformedAndMismatchedPublicationRequireCleanup() throws {
    for candidate in [P.Result(id: ""), P.Result(id: "different-result")] {
      let s = try publisher()
      let owner = s.current.lineage
      let d = P.apply(.publish(owner, permit: "publisher", candidate), to: s)
      XCTAssertEqual(d.rejection, candidate.id.isEmpty ? .malformedResult : .resultMismatch)
      XCTAssertEqual(d.commands, [])
      XCTAssertEqual(d.snapshot.permits[0].cleanup, .required)
      XCTAssertNil(d.snapshot.usableResult)
      rejects(.release(owner, permit: "publisher"), d.snapshot, .cleanupOutstanding)
    }
    var beforeRename = try publisher(renamed: false)
    let owner = beforeRename.current.lineage
    rejects(
      .renameFinished(owner, permit: "publisher", succeeded: true), beforeRename, .invalidTransition
    )
    let early = P.apply(.publish(owner, permit: "publisher", result), to: beforeRename)
    XCTAssertEqual(early.rejection, .invalidTransition)
    XCTAssertEqual(early.commands, [])
    admit(.rename(owner, permit: "publisher"), &beforeRename)
    let inFlight = P.apply(.publish(owner, permit: "publisher", result), to: beforeRename)
    XCTAssertEqual(inFlight.rejection, .invalidTransition)
    XCTAssertEqual(inFlight.commands, [.awaitClosure(owner, "publisher")])
    rejects(
      .cleanupFinished(
        owner, permit: "publisher", operation: .init(id: "cleanup-1", paper: owner.captured.paper),
        succeeded: true), inFlight.snapshot, .closureUnknown)
    rejects(.release(owner, permit: "publisher"), inFlight.snapshot, .closureUnknown)
  }

  func testTwoTerminalOrdersAndSuccessFailureRacePreserveOnlyWinner() throws {
    for first in [P.Failure.failed, .cancelled, .timeout] {
      var s = try running()
      let owner = s.current.lineage
      admit(.terminate(owner, first), &s)
      for late in [P.Failure.failed, .cancelled, .timeout] {
        rejects(.terminate(owner, late), s, .state)
      }
      XCTAssertEqual(s.current.state, .failed(first))
    }
    var failureWins = try publisher()
    let owner = failureWins.current.lineage
    admit(.terminate(owner, .timeout), &failureWins)
    let lateSuccess = P.apply(.publish(owner, permit: "publisher", result), to: failureWins)
    XCTAssertEqual(lateSuccess.rejection, .state)
    XCTAssertEqual(lateSuccess.snapshot.current.state, .failed(.timeout))
    XCTAssertNil(lateSuccess.snapshot.usableResult)
    var successWins = try publisher()
    admit(.publish(owner, permit: "publisher", result), &successWins)
    rejects(.terminate(owner, .cancelled), successWins, .state)
    rejects(.publish(owner, permit: "publisher", result), successWins, .state)
    XCTAssertEqual(successWins.usableResult?.result, result)
  }

  func testRetryPreservesOldUsablePointerUntilExactlyOneNewSuccess() throws {
    var s = try publisher()
    let old = s.current.lineage
    admit(.publish(old, permit: "publisher", result), &s)
    admit(.release(old, permit: "publisher"), &s)
    let oldPointer = s.usableResult
    let oldExecution = s.current
    admit(.retry(reservation("2"), authority(version: "input-2")), &s)
    let second = s.current.lineage
    XCTAssertEqual(s.usableResult, oldPointer)
    XCTAssertEqual(s.executions[0], oldExecution)
    admit(.claim(second), &s)
    admit(.terminate(second, .failed), &s)
    XCTAssertEqual(s.usableResult, oldPointer)
    admit(.retry(reservation("3"), authority(version: "input-3")), &s)
    let third = s.current.lineage
    admit(.claim(third), &s)
    admit(.acquireWriter(third, permit: "writer-3"), &s)
    let newResult = P.Result(id: "new-result")
    admit(.writerClosure(third, permit: "writer-3", .closed(.validated(newResult))), &s)
    admit(.acquirePublication(third, writer: "writer-3", permit: "publisher-3"), &s)
    admit(.rename(third, permit: "publisher-3"), &s)
    admit(.renameFinished(third, permit: "publisher-3", succeeded: true), &s)
    rejects(.publish(old, permit: "publisher-3", result), s, .attempt)
    XCTAssertEqual(s.usableResult, oldPointer)
    admit(.publish(third, permit: "publisher-3", newResult), &s)
    XCTAssertEqual(s.usableResult, .init(lineage: third, result: newResult))
    XCTAssertEqual(s.executions[0], oldExecution)
    rejects(.publish(third, permit: "publisher-3", newResult), s, .state)
    rejects(.retry(reservation("4"), authority()), s, .cleanupOutstanding)
  }

  func testHistoricalPointerCannotBeRetaggedOrItsLineageReused() throws {
    var s = try publisher()
    let old = s.current.lineage
    admit(.publish(old, permit: "publisher", result), &s)
    admit(.release(old, permit: "publisher"), &s)
    let pointer = s.usableResult
    admit(.retry(reservation("2"), authority(version: "input-2")), &s)
    XCTAssertEqual(s.usableResult, pointer)
    XCTAssertEqual(s.executions[0].lineage, old)
    admit(.claim(s.current.lineage), &s)
    admit(.terminate(s.current.lineage, .failed), &s)
    rejects(.retry(old.reservation, authority()), s, .reservationUnavailable)
    XCTAssertEqual(s.usableResult, pointer)
  }

  func testRevokedUnknownWriterRetainsObligationAcrossEpochAndFailedCleanup() throws {
    var s = try writer()
    let owner = s.current.lineage
    XCTAssertEqual(admit(.revoke, &s), [.cancel(owner), .awaitClosure(owner, "writer")])
    XCTAssertEqual(s.current.state, .failed(.paperDeleting))
    rejects(.claim(owner), s, .state)
    rejects(.retry(reservation("2"), authority()), s, .revoked)
    rejects(.acquireWriter(owner, permit: "new-writer"), s, .state)
    rejects(.dispatch(owner), s, .state)
    rejects(.removeNamespace(operation: "removal-1"), s, .permitsOutstanding)
    rejects(
      .cleanupFinished(
        owner, permit: "writer", operation: .init(id: "cleanup-1", paper: owner.captured.paper),
        succeeded: true), s, .closureUnknown)
    rejects(.release(owner, permit: "writer"), s, .closureUnknown)
    admit(.startup(currentEpoch: "process-2"), &s)
    XCTAssertEqual(s.permits[0].owner, owner)
    XCTAssertEqual(s.permits[0].cleanup, .required)
    XCTAssertEqual(
      admit(.writerClosure(owner, permit: "writer", .closed(.unvalidated)), &s),
      [])
    finishCleanup(owner, permit: "writer", &s, succeeded: false)
    XCTAssertEqual(s.permits[0].cleanup, .failed)
    rejects(.release(owner, permit: "writer"), s, .cleanupOutstanding)
    rejects(.removeNamespace(operation: "removal-1"), s, .permitsOutstanding)
    finishCleanup(owner, permit: "writer", &s, operation: "cleanup-2")
    admit(.release(owner, permit: "writer"), &s)
    let target = s.authority.paper
    XCTAssertEqual(
      admit(.removeNamespace(operation: "removal-1"), &s),
      [.removeNamespace(.init(id: "removal-1", paper: target))])
    XCTAssertFalse(s.namespaceRemoved)
    rejects(.removeNamespace(operation: "removal-2"), s, .removalOutstanding)
    admit(
      .namespaceRemovalFinished(operation: .init(id: "removal-1", paper: target), succeeded: false),
      &s)
    XCTAssertFalse(s.namespaceRemoved)
    admit(.removeNamespace(operation: "removal-2"), &s)
    admit(
      .namespaceRemovalFinished(operation: .init(id: "removal-2", paper: target), succeeded: true),
      &s)
    XCTAssertTrue(s.namespaceRemoved)
    rejects(.removeNamespace(operation: "removal-3"), s, .invalidTransition)
    rejects(.retry(reservation("3"), authority(epoch: "process-2")), s, .revoked)
  }

  func testRevocationAtEachProducerBoundaryBlocksRemovalAndSuccess() throws {
    // Acquisition, write/open, closed stage, publication handoff, rename in flight, rename complete.
    for boundary in 0..<6 {
      var s = try writer()
      let owner = s.current.lineage
      var id = "writer"
      if boundary >= 1 { admit(.writerClosure(owner, permit: id, .open), &s) }
      if boundary >= 2 { admit(.writerClosure(owner, permit: id, .closed(.validated(result))), &s) }
      if boundary >= 3 {
        admit(.acquirePublication(owner, writer: id, permit: "publisher"), &s)
        id = "publisher"
      }
      if boundary >= 4 { admit(.rename(owner, permit: id), &s) }
      if boundary >= 5 { admit(.renameFinished(owner, permit: id, succeeded: true), &s) }
      admit(.revoke, &s)
      rejects(.removeNamespace(operation: "removal-1"), s, .permitsOutstanding)
      if id == "writer" {
        rejects(.acquirePublication(owner, writer: id, permit: "publisher"), s, .state)
        if boundary < 2 {
          rejects(.release(owner, permit: id), s, .closureUnknown)
          admit(.writerClosure(owner, permit: id, .closed(.unvalidated)), &s)
        }
      } else {
        let d = P.apply(.publish(owner, permit: id, result), to: s)
        XCTAssertEqual(d.rejection, .state)
        XCTAssertNil(d.snapshot.usableResult)
        if boundary == 4 {
          rejects(
            .cleanupFinished(
              owner, permit: id, operation: .init(id: "cleanup-1", paper: owner.captured.paper),
              succeeded: true), s, .closureUnknown)
          XCTAssertEqual(
            admit(.renameFinished(owner, permit: id, succeeded: true), &s),
            [])
        }
      }
      rejects(.release(owner, permit: id), s, .cleanupOutstanding)
      finishCleanup(owner, permit: id, &s)
      admit(.release(owner, permit: id), &s)
      admit(.removeNamespace(operation: "removal-1"), &s)
      XCTAssertTrue(s.removalRequested)
      XCTAssertFalse(s.namespaceRemoved)
    }
  }

  func testStartupKeepsWriterCleanupAndRetryWaitsForExactCompletion() throws {
    var s = try writer()
    let owner = s.current.lineage
    admit(.startup(currentEpoch: "process-2"), &s)
    XCTAssertEqual(s.current.state, .failed(.interrupted))
    rejects(.retry(reservation("2"), authority(epoch: "process-2")), s, .cleanupOutstanding)
    let foreign = changedLineage(owner, correlation: "rebound")
    rejects(.writerClosure(foreign, permit: "writer", .closed(.unvalidated)), s, .permitOwnership)
    rejects(
      .cleanupFinished(
        foreign, permit: "writer", operation: .init(id: "cleanup-1", paper: owner.captured.paper),
        succeeded: true), s, .permitOwnership)
    rejects(.release(foreign, permit: "writer"), s, .permitOwnership)
    admit(.writerClosure(owner, permit: "writer", .closed(.unvalidated)), &s)
    finishCleanup(owner, permit: "writer", &s)
    admit(.release(owner, permit: "writer"), &s)
    admit(.retry(reservation("2"), authority(epoch: "process-2")), &s)
    let newOwner = s.current.lineage
    admit(.claim(newOwner), &s)
    rejects(.acquireWriter(newOwner, permit: "writer"), s, .permitIdentity)
    admit(.acquireWriter(newOwner, permit: "writer-2"), &s)
    rejects(.release(owner, permit: "writer-2"), s, .permitOwnership)
    rejects(.publish(owner, permit: "writer-2", result), s, .attempt)
    XCTAssertEqual(s.permits[0].owner, newOwner)
    admit(.writerClosure(newOwner, permit: "writer-2", .closed(.unvalidated)), &s)
    admit(.terminate(newOwner, .failed), &s)
    rejects(
      .requestCleanup(newOwner, permit: "writer-2", operation: "cleanup-1"), s, .operationIdentity)
    XCTAssertEqual(s.usedOperationIDs, ["cleanup-1"])
    finishCleanup(newOwner, permit: "writer-2", &s, operation: "cleanup-2")
    admit(.release(newOwner, permit: "writer-2"), &s)
    XCTAssertEqual(s.usedOperationIDs, ["cleanup-1", "cleanup-2"])
  }

  func testFailedRenameAndCommittedPublisherHaveDifferentCleanupOwnership() throws {
    var failed = try publisher(renamed: false)
    let owner = failed.current.lineage
    admit(.rename(owner, permit: "publisher"), &failed)
    XCTAssertEqual(
      admit(.renameFinished(owner, permit: "publisher", succeeded: false), &failed),
      [])
    let rejected = P.apply(.publish(owner, permit: "publisher", result), to: failed)
    XCTAssertEqual(rejected.rejection, .cleanupOutstanding)
    rejects(.release(owner, permit: "publisher"), failed, .cleanupOutstanding)
    finishCleanup(owner, permit: "publisher", &failed)
    admit(.release(owner, permit: "publisher"), &failed)

    var committed = try publisher()
    admit(.publish(owner, permit: "publisher", result), &committed)
    let pointer = committed.usableResult
    XCTAssertEqual(admit(.revoke, &committed), [])
    XCTAssertEqual(committed.usableResult, pointer)
    rejects(.removeNamespace(operation: "removal-1"), committed, .permitsOutstanding)
    XCTAssertEqual(
      admit(.release(owner, permit: "publisher"), &committed),
      [.releasePermit(owner, "publisher")])
    XCTAssertEqual(committed.usableResult, pointer)
    admit(.removeNamespace(operation: "removal-1"), &committed)
  }

  func testResultIdentityCannotRebindOldUsableProvenance() throws {
    var s = try publisher()
    let old = s.current.lineage
    admit(.publish(old, permit: "publisher", result), &s)
    admit(.release(old, permit: "publisher"), &s)
    let pointer = s.usableResult
    admit(.retry(reservation("2"), authority(version: "input-2")), &s)
    let owner = s.current.lineage
    admit(.claim(owner), &s)
    admit(.acquireWriter(owner, permit: "writer-2"), &s)
    admit(.writerClosure(owner, permit: "writer-2", .closed(.validated(result))), &s)
    admit(.acquirePublication(owner, writer: "writer-2", permit: "publisher-2"), &s)
    admit(.rename(owner, permit: "publisher-2"), &s)
    admit(.renameFinished(owner, permit: "publisher-2", succeeded: true), &s)
    let d = P.apply(.publish(owner, permit: "publisher-2", result), to: s)
    XCTAssertEqual(d.rejection, .resultAlreadyCommitted)
    XCTAssertEqual(d.commands, [])
    XCTAssertEqual(d.snapshot.usableResult, pointer)
    XCTAssertEqual(d.snapshot.executions[0], s.executions[0])
    s = d.snapshot
    finishCleanup(owner, permit: "publisher-2", &s, succeeded: false)
    rejects(.release(owner, permit: "publisher-2"), s, .cleanupOutstanding)
    let afterFailure = P.apply(.publish(owner, permit: "publisher-2", result), to: s)
    XCTAssertEqual(afterFailure.rejection, .cleanupOutstanding)
    XCTAssertEqual(afterFailure.snapshot.usableResult, pointer)
    XCTAssertNotEqual(afterFailure.snapshot.current.state, .succeeded)
  }

  func testRevocationBeforeClaimAndBeforePermitCannotAdmitWork() throws {
    for initial in [try pending(), try running()] {
      var s = initial
      let owner = s.current.lineage
      admit(.revoke, &s)
      let once = s
      XCTAssertEqual(admit(.revoke, &s), [])
      XCTAssertEqual(s, once)
      rejects(.claim(owner), s, .state)
      rejects(.dispatch(owner), s, .state)
      rejects(.acquireWriter(owner, permit: "writer"), s, .state)
      rejects(.retry(reservation("2"), authority()), s, .revoked)
      rejects(
        .namespaceRemovalFinished(
          operation: .init(id: "removal-1", paper: s.authority.paper), succeeded: true), s,
        .removalNotRequested)
      XCTAssertTrue(s.usedPermitIDs.isEmpty)
      XCTAssertNil(s.usableResult)
    }
    var open = try writer()
    admit(.revoke, &open)
    let once = open
    XCTAssertEqual(admit(.revoke, &open), [])
    XCTAssertEqual(open, once)
  }

  func testRemovalCompletionKeepsCapturedGenerationDuringAuthorityChange() throws {
    var s = try pending()
    admit(.revoke, &s)
    let a = P.Operation(id: "remove-A", paper: s.authority.paper)
    XCTAssertEqual(admit(.removeNamespace(operation: a.id), &s), [.removeNamespace(a)])
    let newer = authority(paper: .init(id: "paper", generation: "paper-2"))
    XCTAssertEqual(admit(.authorityChanged(newer), &s), [])
    XCTAssertEqual(s.pendingRemoval, a)
    rejects(.removeNamespace(operation: "remove-B"), s, .removalOutstanding)
    rejects(
      .namespaceRemovalFinished(operation: .init(id: a.id, paper: newer.paper), succeeded: true), s,
      .operationMismatch)
    admit(.namespaceRemovalFinished(operation: a, succeeded: true), &s)
    XCTAssertEqual(s.removedPapers, [a.paper])
    XCTAssertFalse(s.namespaceRemoved)
    rejects(.namespaceRemovalFinished(operation: a, succeeded: false), s, .removalNotRequested)
    let b = P.Operation(id: "remove-B", paper: newer.paper)
    XCTAssertEqual(admit(.removeNamespace(operation: b.id), &s), [.removeNamespace(b)])
    rejects(.namespaceRemovalFinished(operation: a, succeeded: true), s, .operationMismatch)
    XCTAssertEqual(s.pendingRemoval, b)
    admit(.namespaceRemovalFinished(operation: b, succeeded: true), &s)
    XCTAssertTrue(s.namespaceRemoved)
    XCTAssertEqual(s.removedPapers, [a.paper, b.paper])
  }

  func testRemovalAbsenceDoesNotFollowAuthorityAfterCompletion() throws {
    var s = try pending()
    admit(.revoke, &s)
    let a = P.Operation(id: "remove-A", paper: s.authority.paper)
    admit(.removeNamespace(operation: a.id), &s)
    admit(.namespaceRemovalFinished(operation: a, succeeded: true), &s)
    XCTAssertTrue(s.namespaceRemoved)
    admit(.authorityChanged(authority(paper: .init(id: "paper", generation: "paper-2"))), &s)
    XCTAssertFalse(s.namespaceRemoved)
    XCTAssertEqual(s.removedPapers, [a.paper])
    rejects(.removeNamespace(operation: a.id), s, .operationIdentity)
    rejects(.namespaceRemovalFinished(operation: a, succeeded: true), s, .removalNotRequested)
    admit(.removeNamespace(operation: "remove-B"), &s)
    XCTAssertEqual(s.pendingRemoval?.paper, s.authority.paper)
  }

  func testRemovalFailureRetryRejectsDuplicateAndReboundCompletion() throws {
    var s = try pending()
    admit(.revoke, &s)
    let a = P.Operation(id: "remove-A", paper: s.authority.paper)
    let b = P.Operation(id: "remove-B", paper: a.paper)
    rejects(.removeNamespace(operation: ""), s, .operationIdentity)
    admit(.removeNamespace(operation: a.id), &s)
    admit(.authorityChanged(authority(paper: .init(id: "paper", generation: "paper-2"))), &s)
    admit(.namespaceRemovalFinished(operation: a, succeeded: false), &s)
    XCTAssertEqual(s.removalDebt, a.paper)
    rejects(.removeNamespace(operation: a.id), s, .operationIdentity)
    XCTAssertEqual(admit(.removeNamespace(operation: b.id), &s), [.removeNamespace(b)])
    for succeeded in [false, true] {
      rejects(.namespaceRemovalFinished(operation: a, succeeded: succeeded), s, .operationMismatch)
    }
    rejects(.removeNamespace(operation: "remove-C"), s, .removalOutstanding)
    rejects(
      .namespaceRemovalFinished(
        operation: .init(id: b.id, paper: .init(id: "foreign", generation: "paper-1")),
        succeeded: true), s, .operationMismatch)
    XCTAssertEqual(s.pendingRemoval, b)
    XCTAssertFalse(s.namespaceRemoved)
    admit(.namespaceRemovalFinished(operation: b, succeeded: true), &s)
    XCTAssertNil(s.removalDebt)
    XCTAssertFalse(s.namespaceRemoved)
    XCTAssertEqual(s.removedPapers, [a.paper])
    rejects(.namespaceRemovalFinished(operation: b, succeeded: true), s, .removalNotRequested)
    XCTAssertEqual(s.usedOperationIDs, [a.id, b.id])
    admit(.removeNamespace(operation: "remove-C"), &s)
    XCTAssertEqual(s.pendingRemoval?.paper, s.authority.paper)
  }

  func testCleanupRetriesRejectStaleDuplicatesAndKeepOutstandingInvocation() throws {
    for failB in [false, true] {
      var s = try writer()
      let owner = s.current.lineage
      let a = P.Operation(id: "cleanup-A", paper: owner.captured.paper)
      let b = P.Operation(id: "cleanup-B", paper: a.paper)
      let c = P.Operation(id: "cleanup-C", paper: a.paper)
      admit(.revoke, &s)
      rejects(.requestCleanup(owner, permit: "writer", operation: a.id), s, .closureUnknown)
      XCTAssertEqual(admit(.writerClosure(owner, permit: "writer", .closed(.unvalidated)), &s), [])
      rejects(.requestCleanup(owner, permit: "writer", operation: ""), s, .operationIdentity)
      XCTAssertEqual(
        admit(.requestCleanup(owner, permit: "writer", operation: a.id), &s),
        [.removeOwnedBytes(owner, "writer", a)])
      admit(.cleanupFinished(owner, permit: "writer", operation: a, succeeded: false), &s)
      rejects(
        .cleanupFinished(owner, permit: "writer", operation: a, succeeded: false), s,
        .invalidTransition)
      rejects(.requestCleanup(owner, permit: "writer", operation: a.id), s, .operationIdentity)
      XCTAssertEqual(
        admit(.requestCleanup(owner, permit: "writer", operation: b.id), &s),
        [.removeOwnedBytes(owner, "writer", b)])
      admit(.authorityChanged(authority(paper: .init(id: "paper", generation: "paper-2"))), &s)
      XCTAssertEqual(s.permits[0].cleanupOperation, b)
      for succeeded in [false, true] {
        rejects(
          .cleanupFinished(owner, permit: "writer", operation: a, succeeded: succeeded), s,
          .operationMismatch)
      }
      rejects(
        .cleanupFinished(
          owner, permit: "writer", operation: .init(id: b.id, paper: s.authority.paper),
          succeeded: true), s, .operationMismatch)
      rejects(.requestCleanup(owner, permit: "writer", operation: c.id), s, .invalidTransition)
      rejects(.release(owner, permit: "writer"), s, .cleanupOutstanding)
      rejects(.removeNamespace(operation: "remove"), s, .permitsOutstanding)
      admit(.cleanupFinished(owner, permit: "writer", operation: b, succeeded: !failB), &s)
      if failB {
        XCTAssertEqual(
          admit(.requestCleanup(owner, permit: "writer", operation: c.id), &s),
          [.removeOwnedBytes(owner, "writer", c)])
        rejects(
          .cleanupFinished(owner, permit: "writer", operation: b, succeeded: true), s,
          .operationMismatch)
        rejects(
          .cleanupFinished(owner, permit: "writer", operation: a, succeeded: false), s,
          .operationMismatch)
        rejects(.release(owner, permit: "writer"), s, .cleanupOutstanding)
        rejects(.removeNamespace(operation: "remove"), s, .permitsOutstanding)
        XCTAssertEqual(s.permits[0].cleanupOperation, c)
        admit(.cleanupFinished(owner, permit: "writer", operation: c, succeeded: true), &s)
        rejects(
          .cleanupFinished(owner, permit: "writer", operation: c, succeeded: true), s,
          .invalidTransition)
      } else {
        rejects(
          .cleanupFinished(owner, permit: "writer", operation: b, succeeded: true), s,
          .invalidTransition)
      }
      admit(.release(owner, permit: "writer"), &s)
      for operation in s.usedOperationIDs {
        rejects(.removeNamespace(operation: operation), s, .operationIdentity)
      }
      admit(.removeNamespace(operation: "remove"), &s)
      XCTAssertEqual(s.pendingRemoval?.paper, s.authority.paper)
    }
  }

  func testAllRolesPriorEpochPendingCanCancelThenExplicitlyRetryWithoutRenewal() throws {
    for role in P.Role.allCases {
      var s = try pending(role)
      let old = s.current.lineage
      XCTAssertEqual(admit(.startup(currentEpoch: "process-2"), &s), [])
      rejects(.claim(old), s, .epoch)
      let currentAuthority = authority(role, epoch: "process-2")
      rejects(.claim(changedLineage(old, captured: currentAuthority)), s, .epoch)
      rejects(.retry(reservation("2"), currentAuthority), s, .state)
      rejects(.terminate(changedLineage(old, captured: currentAuthority), .cancelled), s, .attempt)
      XCTAssertEqual(admit(.terminate(old, .cancelled), &s), [.cancel(old)])
      let historical = s.current
      XCTAssertEqual(admit(.retry(reservation("2"), currentAuthority), &s), [])
      XCTAssertEqual(s.executions[0], historical)
      XCTAssertEqual(s.executions[0].lineage, old)
      XCTAssertEqual(s.current.lineage.captured, currentAuthority)
      XCTAssertNotEqual(s.current.lineage.reservation, old.reservation)
      rejects(.claim(old), s, .attempt)
      XCTAssertEqual(admit(.claim(s.current.lineage), &s), [])
      XCTAssertEqual(s.current.state, .running)
      XCTAssertEqual(s.current.dispatch, .none)
      XCTAssertEqual(s.executions[0], historical)
      XCTAssertTrue(s.permits.isEmpty)
      XCTAssertNil(s.usableResult)
    }
  }

  func testCombinedAuthorityChangesAndRestorationCannotUnrevokePublisher() throws {
    for inputFirst in [true, false] {
      var s = try publisher()
      let owner = s.current.lineage
      let changed = authority(
        version: "input-2", config: .generation("config-2"),
        paper: .init(id: "paper", generation: "paper-2"), epoch: "process-2")
      let first =
        inputFirst ? authority(version: "input-2") : authority(config: .generation("config-2"))
      admit(.authorityChanged(first), &s)
      XCTAssertEqual(admit(.authorityChanged(changed), &s), [])
      XCTAssertEqual(P.apply(.publish(owner, permit: "publisher", result), to: s).rejection, .input)
      // A configuration returning to its old value is not renewal of a revoked permit.
      XCTAssertEqual(admit(.authorityChanged(authority()), &s), [])
      let d = P.apply(.publish(owner, permit: "publisher", result), to: s)
      XCTAssertEqual(d.rejection, .cleanupOutstanding)
      XCTAssertNil(d.snapshot.usableResult)
      rejects(.rename(owner, permit: "publisher"), s, .cleanupOutstanding)
      rejects(.release(owner, permit: "publisher"), s, .cleanupOutstanding)
    }
  }
}
