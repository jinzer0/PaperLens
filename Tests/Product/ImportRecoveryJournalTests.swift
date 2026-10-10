import Foundation
import XCTest
@testable import PaperLensProduct

final class ImportRecoveryJournalTests: XCTestCase {
  // These synthetic owner attestations exercise policy replay only. No FD is closed,
  // byte removed, input admitted, or result published by this fixture or its codec.
  private let bound = 262_144
  private let facts = ImportRecoveryJournal.ConfirmedInput(
    expectedSHA256: String(repeating: "a", count: 64), destinationFolderID: nil)

  private func identity() -> ImportIdentity {
    ImportIdentity(paperID: UUID(), generation: UUID(), jobID: UUID(), attempt: UUID(),
      fence: UUID(), correlation: UUID(), input: UUID(), epoch: UUID(), writer: UUID(), publication: UUID())
  }
  private func retryIdentity(_ old: ImportIdentity, epoch: UUID? = nil) -> ImportIdentity {
    ImportIdentity(paperID: old.paperID, generation: old.generation, jobID: old.jobID,
      attempt: UUID(), fence: UUID(), correlation: UUID(), input: UUID(), epoch: epoch ?? old.epoch,
      writer: UUID(), publication: UUID())
  }
  private func initial(_ id: ImportIdentity) throws -> ImportRecoveryJournal {
    try ImportRecoveryJournal(identity: id, confirmedInput: facts)
  }
  private func roundTrip(_ journal: ImportRecoveryJournal,
    file: StaticString = #filePath, line: UInt = #line) throws {
    let bytes = try journal.encoded(maximumBytes: bound)
    let decoded = try ImportRecoveryJournal.decode(bytes, maximumBytes: bound)
    XCTAssertEqual(try decoded.snapshot(), try journal.snapshot(), file: file, line: line)
    XCTAssertEqual(try decoded.encoded(maximumBytes: bound), bytes, file: file, line: line)
  }
  private func append(_ events: [JobRecoveryPolicy.Event], to journal: ImportRecoveryJournal) throws
    -> ImportRecoveryJournal {
    var result = journal
    var expected = try journal.snapshot()
    for event in events {
      let decision = JobRecoveryPolicy.apply(event, to: expected)
      XCTAssertNil(decision.rejection)
      expected = decision.snapshot
      result = try result.recording(event)
      XCTAssertEqual(try result.snapshot(), expected)
      try roundTrip(result)
    }
    return result
  }
  private func assertRejection(_ expected: JobRecoveryPolicy.Rejection,
    _ action: () throws -> ImportRecoveryJournal,
    file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertThrowsError(try action(), file: file, line: line) {
      XCTAssertEqual($0 as? JobRecoveryPolicy.Rejection, expected, file: file, line: line)
    }
  }
  private func mutate(_ bytes: Data, _ transform: (inout [String: Any]) -> Void) throws -> Data {
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    transform(&object)
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
  }

  func testPendingThenPublicationAndImmutablePriorValue() throws {
    let id = identity()
    let pending = try initial(id)
    let oldBytes = try pending.encoded(maximumBytes: bound)
    let l = try pending.snapshot().current.lineage
    let result = JobRecoveryPolicy.Result(id: "synthetic-opaque-result")
    let journal = try append([
      .claim(l), .acquireWriter(l, permit: id.writer.uuidString),
      .writerClosure(l, permit: id.writer.uuidString, .open),
      .writerClosure(l, permit: id.writer.uuidString, .closed(.validated(result))),
      .acquirePublication(l, writer: id.writer.uuidString, permit: id.publication.uuidString),
      .rename(l, permit: id.publication.uuidString),
      .renameFinished(l, permit: id.publication.uuidString, succeeded: true),
      .publish(l, permit: id.publication.uuidString, result),
      .release(l, permit: id.publication.uuidString)
    ], to: pending)
    let state = try journal.snapshot()
    XCTAssertEqual(state.current.state, .succeeded)
    XCTAssertEqual(state.usableResult, .init(lineage: l, result: result))
    XCTAssertEqual(state.usedPermitIDs, [id.writer.uuidString, id.publication.uuidString])
    XCTAssertTrue(state.permits.isEmpty)
    XCTAssertEqual(try pending.snapshot().current.state, .pending)
    XCTAssertEqual(try pending.encoded(maximumBytes: bound), oldBytes)

    let next = retryIdentity(id)
    let retried = try journal.retrying(identity: next, confirmedInput: facts)
    XCTAssertEqual(try retried.snapshot().usableResult, state.usableResult)
    XCTAssertEqual(try retried.snapshot().executions.first, state.executions.first)
    XCTAssertEqual(try retried.snapshot().current.state, .pending)
    try roundTrip(retried)
  }

  func testFailedCleanupReleaseThenSameJobFreshRetryRetainsFullCaptures() throws {
    let id = identity()
    let pending = try initial(id)
    let l = try pending.snapshot().current.lineage
    let op = JobRecoveryPolicy.Operation(id: UUID().uuidString, paper: l.captured.paper)
    let failed = try append([
      .claim(l), .acquireWriter(l, permit: id.writer.uuidString),
      .writerClosure(l, permit: id.writer.uuidString, .closed(.unvalidated)),
      .terminate(l, .failed), .requestCleanup(l, permit: id.writer.uuidString, operation: op.id),
      .cleanupFinished(l, permit: id.writer.uuidString, operation: op, succeeded: true),
      .release(l, permit: id.writer.uuidString)
    ], to: pending)
    let original = try failed.encoded(maximumBytes: bound)
    let next = retryIdentity(id)
    let newFacts = ImportRecoveryJournal.ConfirmedInput(expectedSHA256: nil, destinationFolderID: UUID())
    let retried = try failed.retrying(identity: next, confirmedInput: newFacts)
    let before = try failed.snapshot()
    let after = try retried.snapshot()
    XCTAssertEqual(after.job, before.job)
    XCTAssertEqual(after.executions.first, before.executions.first)
    XCTAssertEqual(after.usedOperationIDs, [op.id])
    XCTAssertEqual(after.usedPermitIDs, before.usedPermitIDs)
    XCTAssertEqual(after.current.lineage.captured.input, .source(version: next.input.uuidString))
    XCTAssertEqual(try failed.encoded(maximumBytes: bound), original)
    try roundTrip(retried)
    let json = try XCTUnwrap(JSONSerialization.jsonObject(
      with: retried.encoded(maximumBytes: bound)) as? [String: Any])
    let capture = try XCTUnwrap(json["initial"] as? [String: Any])
    XCTAssertEqual(capture["publication"] as? String, id.publication.uuidString)
    let input = try XCTUnwrap(capture["confirmedInput"] as? [String: Any])
    XCTAssertEqual(input["expectedSHA256"] as? String, facts.expectedSHA256)
    XCTAssertThrowsError(try retried.recording(.claim(l)))
  }

  func testOpenWriterBlocksPublicationCleanupReleaseAndRetry() throws {
    let id = identity()
    let pending = try initial(id)
    let l = try pending.snapshot().current.lineage
    let open = try append([
      .claim(l), .acquireWriter(l, permit: id.writer.uuidString),
      .writerClosure(l, permit: id.writer.uuidString, .open)
    ], to: pending)
    assertRejection(.stageNotValidated) {
      try open.recording(.acquirePublication(l, writer: id.writer.uuidString, permit: id.publication.uuidString))
    }
    let failed = try append([.terminate(l, .cancelled)], to: open)
    assertRejection(.cleanupOutstanding) {
      try failed.retrying(identity: retryIdentity(id), confirmedInput: facts)
    }
    assertRejection(.closureUnknown) { try failed.recording(.release(l, permit: id.writer.uuidString)) }
    let closed = try append([
      .writerClosure(l, permit: id.writer.uuidString, .closed(.unvalidated))
    ], to: failed)
    XCTAssertThrowsError(try closed.recording(
      .requestCleanup(l, permit: id.writer.uuidString, operation: id.publication.uuidString)))
    let op = JobRecoveryPolicy.Operation(id: UUID().uuidString, paper: l.captured.paper)
    let requested = try append([
      .requestCleanup(l, permit: id.writer.uuidString, operation: op.id)
    ], to: closed)
    let foreign = JobRecoveryPolicy.Operation(id: UUID().uuidString, paper: l.captured.paper)
    assertRejection(.operationMismatch) {
      try requested.recording(.cleanupFinished(l, permit: id.writer.uuidString, operation: foreign, succeeded: true))
    }
    try roundTrip(requested)
  }

  func testStartupKeepsOldEpochAndUnknownPermitDebtBlocksRetry() throws {
    let id = identity()
    let pending = try initial(id)
    let l = try pending.snapshot().current.lineage
    let epoch = UUID()
    let interrupted = try append([
      .claim(l), .acquireWriter(l, permit: id.writer.uuidString), .startup(currentEpoch: epoch.uuidString)
    ], to: pending)
    let state = try interrupted.snapshot()
    XCTAssertEqual(state.authority.epoch, epoch.uuidString)
    XCTAssertEqual(state.current.lineage.captured.epoch, id.epoch.uuidString)
    XCTAssertEqual(state.current.state, .failed(.interrupted))
    XCTAssertEqual(state.permits.first?.closure, .unknown)
    XCTAssertEqual(state.permits.first?.cleanup, .required)
    let next = retryIdentity(id, epoch: epoch)
    assertRejection(.cleanupOutstanding) { try interrupted.retrying(identity: next, confirmedInput: facts) }
    assertRejection(.closureUnknown) {
      try interrupted.recording(.requestCleanup(l, permit: id.writer.uuidString, operation: UUID().uuidString))
    }
    let op = JobRecoveryPolicy.Operation(id: UUID().uuidString, paper: l.captured.paper)
    let debt = try append([
      .writerClosure(l, permit: id.writer.uuidString, .closed(.unvalidated)),
      .requestCleanup(l, permit: id.writer.uuidString, operation: op.id),
      .cleanupFinished(l, permit: id.writer.uuidString, operation: op, succeeded: false)
    ], to: interrupted)
    assertRejection(.cleanupOutstanding) { try debt.retrying(identity: next, confirmedInput: facts) }
    let secondOp = JobRecoveryPolicy.Operation(id: UUID().uuidString, paper: l.captured.paper)
    let clean = try append([
      .requestCleanup(l, permit: id.writer.uuidString, operation: secondOp.id),
      .cleanupFinished(l, permit: id.writer.uuidString, operation: secondOp, succeeded: true),
      .release(l, permit: id.writer.uuidString)
    ], to: debt)
    assertRejection(.epoch) { try clean.retrying(identity: retryIdentity(id), confirmedInput: facts) }
    let retried = try clean.retrying(identity: next, confirmedInput: facts)
    XCTAssertEqual(try retried.snapshot().executions.first?.lineage.captured.epoch, id.epoch.uuidString)
    XCTAssertEqual(try retried.snapshot().usedOperationIDs, [op.id, secondOp.id])
    try roundTrip(retried)
  }

  func testDispatchLateHistoryAndAuthorityObservationRoundTrip() throws {
    let id = identity()
    let pending = try initial(id)
    let l = try pending.snapshot().current.lineage
    let failed = try append([.claim(l), .dispatch(l), .terminate(l, .timeout)], to: pending)
    let retried = try failed.retrying(identity: retryIdentity(id), confirmedInput: facts)
    let late = try append([.sendMayHaveHappened(l)], to: retried)
    XCTAssertEqual(try late.snapshot().executions.first?.dispatch, .mayHaveSent)
    XCTAssertEqual(try late.snapshot().current.dispatch, .none)
    let a = try late.snapshot().authority
    let unavailable = JobRecoveryPolicy.Authority(input: a.input, config: a.config,
      paper: a.paper, epoch: a.epoch, prerequisitesAvailable: false)
    _ = try append([.authorityChanged(unavailable)], to: late)
  }

  func testFailedRenameAndPublicationGuardsRetainCleanupAndOldJournal() throws {
    let id = identity()
    let pending = try initial(id)
    let l = try pending.snapshot().current.lineage
    let result = JobRecoveryPolicy.Result(id: "controlled-test-attestation")
    let renaming = try append([
      .claim(l), .acquireWriter(l, permit: id.writer.uuidString),
      .writerClosure(l, permit: id.writer.uuidString, .unknown),
      .writerClosure(l, permit: id.writer.uuidString, .closed(.validated(result))),
      .acquirePublication(l, writer: id.writer.uuidString, permit: id.publication.uuidString),
      .rename(l, permit: id.publication.uuidString)
    ], to: pending)
    let renamed = try append([
      .renameFinished(l, permit: id.publication.uuidString, succeeded: true)
    ], to: renaming)
    let bytes = try renamed.encoded(maximumBytes: bound)
    assertRejection(.resultMismatch) {
      try renamed.recording(.publish(l, permit: id.publication.uuidString, .init(id: "wrong-result")))
    }
    assertRejection(.malformedResult) {
      try renamed.recording(.publish(l, permit: id.publication.uuidString, .init(id: "")))
    }
    XCTAssertEqual(try renamed.encoded(maximumBytes: bound), bytes)
    let failed = try append([
      .renameFinished(l, permit: id.publication.uuidString, succeeded: false), .terminate(l, .failed)
    ], to: renaming)
    assertRejection(.cleanupOutstanding) {
      try failed.retrying(identity: retryIdentity(id), confirmedInput: facts)
    }
    let op = JobRecoveryPolicy.Operation(id: UUID().uuidString, paper: l.captured.paper)
    let clean = try append([
      .requestCleanup(l, permit: id.publication.uuidString, operation: op.id),
      .cleanupFinished(l, permit: id.publication.uuidString, operation: op, succeeded: true),
      .release(l, permit: id.publication.uuidString)
    ], to: failed)
    XCTAssertNil(try clean.snapshot().usableResult)
    try roundTrip(clean.retrying(identity: retryIdentity(id), confirmedInput: facts))
  }

  func testRevocationRemovalDebtAndPermanentRemovalNeverRetry() throws {
    let id = identity()
    let pending = try initial(id)
    let revoked = try append([.revoke], to: pending)
    assertRejection(.revoked) { try revoked.retrying(identity: retryIdentity(id), confirmedInput: facts) }
    let paper = try revoked.snapshot().authority.paper
    let op = JobRecoveryPolicy.Operation(id: UUID().uuidString, paper: paper)
    let debt = try append([
      .removeNamespace(operation: op.id), .namespaceRemovalFinished(operation: op, succeeded: false)
    ], to: revoked)
    XCTAssertEqual(try debt.snapshot().removalDebt, paper)
    let next = JobRecoveryPolicy.Operation(id: UUID().uuidString, paper: paper)
    let removed = try append([
      .removeNamespace(operation: next.id), .namespaceRemovalFinished(operation: next, succeeded: true)
    ], to: debt)
    XCTAssertTrue(try removed.snapshot().namespaceRemoved)
    XCTAssertEqual(try removed.snapshot().usedOperationIDs, [op.id, next.id])
    assertRejection(.revoked) { try removed.retrying(identity: retryIdentity(id), confirmedInput: facts) }
  }

  func testReservationsRemainReservedEvenWhenNeverConsumed() throws {
    let id = identity()
    let pending = try initial(id)
    let l = try pending.snapshot().current.lineage
    let failed = try pending.recording(.terminate(l, .cancelled))
    XCTAssertThrowsError(try failed.recording(.retry(l.reservation, l.captured))) {
      XCTAssertEqual($0 as? ImportRecoveryJournal.JournalError, .retryRequiresCapture)
    }
    assertRejection(.reservationUnavailable) { try failed.retrying(identity: id, confirmedInput: facts) }
    let next = retryIdentity(id)
    let collision = ImportIdentity(paperID: next.paperID, generation: next.generation, jobID: next.jobID,
      attempt: next.attempt, fence: next.fence, correlation: next.correlation, input: next.input,
      epoch: next.epoch, writer: id.publication, publication: next.publication)
    XCTAssertThrowsError(try failed.retrying(identity: collision, confirmedInput: facts))
    let cross = ImportIdentity(paperID: next.paperID, generation: next.generation, jobID: next.jobID,
      attempt: id.writer, fence: next.fence, correlation: next.correlation, input: next.input,
      epoch: next.epoch, writer: next.writer, publication: next.publication)
    XCTAssertThrowsError(try failed.retrying(identity: cross, confirmedInput: facts))
    let aliased = ImportIdentity(paperID: id.paperID, generation: id.generation, jobID: id.jobID,
      attempt: id.attempt, fence: id.attempt, correlation: id.correlation, input: id.input,
      epoch: id.epoch, writer: id.writer, publication: id.publication)
    XCTAssertThrowsError(try initial(aliased))
    XCTAssertThrowsError(try failed.retrying(identity: identity(), confirmedInput: facts))
    let changedGeneration = ImportIdentity(paperID: next.paperID, generation: UUID(), jobID: next.jobID,
      attempt: next.attempt, fence: next.fence, correlation: next.correlation, input: next.input,
      epoch: next.epoch, writer: next.writer, publication: next.publication)
    XCTAssertThrowsError(try failed.retrying(identity: changedGeneration, confirmedInput: facts))
    let running = try pending.recording(.claim(l))
    XCTAssertThrowsError(try running.recording(.acquireWriter(l, permit: UUID().uuidString)))
    XCTAssertThrowsError(try running.recording(.acquireWriter(l, permit: id.publication.uuidString)))
  }

  func testRoleConfigurationAndLineageRebindingReject() throws {
    let id = identity()
    let pending = try initial(id)
    let l = try pending.snapshot().current.lineage
    let wrongRole = JobRecoveryPolicy.Authority(input: .parser(version: id.input.uuidString),
      config: .inapplicable, paper: l.captured.paper, epoch: id.epoch.uuidString, prerequisitesAvailable: true)
    XCTAssertThrowsError(try pending.recording(.authorityChanged(wrongRole)))
    let wrongConfig = JobRecoveryPolicy.Authority(input: l.captured.input, config: .generation(UUID().uuidString),
      paper: l.captured.paper, epoch: id.epoch.uuidString, prerequisitesAvailable: true)
    XCTAssertThrowsError(try pending.recording(.authorityChanged(wrongConfig)))
    let wrongJob = JobRecoveryPolicy.Lineage(job: UUID().uuidString,
      reservation: l.reservation, captured: l.captured)
    assertRejection(.job) { try pending.recording(.claim(wrongJob)) }
    let wrongPaper = JobRecoveryPolicy.Authority(input: l.captured.input, config: .inapplicable,
      paper: .init(id: id.paperID.uuidString, generation: UUID().uuidString),
      epoch: id.epoch.uuidString, prerequisitesAvailable: true)
    let wrongGeneration = JobRecoveryPolicy.Lineage(job: l.job, reservation: l.reservation, captured: wrongPaper)
    assertRejection(.paper) { try pending.recording(.claim(wrongGeneration)) }
    XCTAssertThrowsError(try pending.recording(.authorityChanged(wrongPaper)))
  }

  func testExtensionRequiresExactImmutablePrefixAndAnAdditionalEvent() throws {
    let first = identity()
    let pending = try initial(first)
    let claimed = try pending.recording(.claim(pending.snapshot().current.lineage))
    XCTAssertTrue(try claimed.extends(pending, maximumBytes: bound))
    XCTAssertFalse(try pending.extends(pending, maximumBytes: bound))
    XCTAssertFalse(try pending.extends(claimed, maximumBytes: bound))
    let revoked = try pending.recording(.revoke)
    XCTAssertFalse(try revoked.extends(claimed, maximumBytes: bound))
    let observed = try pending.recording(.authorityChanged(pending.snapshot().authority))
    let divergent = try observed.recording(.claim(observed.snapshot().current.lineage))
    XCTAssertFalse(try divergent.extends(claimed, maximumBytes: bound))
    let altered = try ImportRecoveryJournal(identity: first, confirmedInput:
      .init(expectedSHA256: nil, destinationFolderID: UUID()))
    let alteredClaimed = try altered.recording(.claim(altered.snapshot().current.lineage))
    XCTAssertFalse(try alteredClaimed.extends(pending, maximumBytes: bound))
    XCTAssertThrowsError(try claimed.extends(pending, maximumBytes: 0))
    let pendingBytes = try pending.encoded(maximumBytes: bound)
    XCTAssertThrowsError(try claimed.extends(pending, maximumBytes: pendingBytes.count))
    XCTAssertEqual(try pending.encoded(maximumBytes: bound), pendingBytes)
  }

  func testCurrentCaptureRetainsAllReservedIDsFactsAndCapturedEpoch() throws {
    func ids(_ value: ImportIdentity) -> [UUID] {
      [value.paperID, value.generation, value.jobID, value.attempt, value.fence,
        value.correlation, value.input, value.epoch, value.writer, value.publication]
    }
    let first = identity()
    let pending = try initial(first)
    XCTAssertEqual(ids(try pending.currentCapture().identity), ids(first))
    XCTAssertEqual(try pending.currentCapture().confirmedInput, facts)
    let failed = try append([.claim(pending.snapshot().current.lineage),
      .terminate(pending.snapshot().current.lineage, .timeout)], to: pending)
    let next = retryIdentity(first)
    let newFacts = ImportRecoveryJournal.ConfirmedInput(expectedSHA256: nil, destinationFolderID: UUID())
    let retried = try failed.retrying(identity: next, confirmedInput: newFacts)
    let observedEpoch = UUID()
    let observed = try retried.recording(.startup(currentEpoch: observedEpoch.uuidString))
    XCTAssertEqual(try observed.snapshot().authority.epoch, observedEpoch.uuidString)
    XCTAssertEqual(ids(try observed.currentCapture().identity), ids(next))
    XCTAssertEqual(try observed.currentCapture().confirmedInput, newFacts)
    XCTAssertEqual(ids(try pending.currentCapture().identity), ids(first))
    let decoded = try ImportRecoveryJournal.decode(observed.encoded(maximumBytes: bound), maximumBytes: bound)
    XCTAssertEqual(ids(try decoded.currentCapture().identity), ids(next))
    XCTAssertEqual(try decoded.currentCapture().confirmedInput, newFacts)
  }

  func testCanonicalBytesRejectHiddenDuplicateEventsAndNestedEscapedKeys() throws {
    let pending = try initial(identity())
    let bytes = try pending.encoded(maximumBytes: bound)
    let text = try XCTUnwrap(String(data: bytes, encoding: .utf8))
    let replacements = [
      ("\"events\":[]", "\"events\":[],\"events\":[{\"revoke\":{}}],\"events\":[]"),
      ("\"events\":[]", "\"events\":[],\"events\":[{\"unknown\":{}}],\"events\":[]"),
      ("\"events\":[]", "\"events\":[],\"ev\\u0065nts\":[]"),
      ("\"destinationFolderID\":null", "\"destinationFolderID\":null,\"destinationFolderID\":null"),
      ("\"destinationFolderID\":null", "\"destinationFolderID\":null,\"destinationFolderI\\u0044\":null")
    ]
    for (original, replacement) in replacements {
      XCTAssertTrue(text.contains(original))
      let mutated = Data(text.replacingOccurrences(of: original, with: replacement).utf8)
      XCTAssertThrowsError(try ImportRecoveryJournal.decode(mutated, maximumBytes: bound))
    }
    XCTAssertThrowsError(try ImportRecoveryJournal.decode(Data((" " + text).utf8), maximumBytes: bound))
    XCTAssertNoThrow(try ImportRecoveryJournal.decode(bytes, maximumBytes: bound))
    XCTAssertEqual(try pending.encoded(maximumBytes: bound), bytes)
  }

  func testStrictNestedJSONVersionVariantsTypesUUIDHashAndByteBounds() throws {
    let id = identity()
    let pending = try initial(id)
    let claimed = try pending.recording(.claim(pending.snapshot().current.lineage))
    let bytes = try claimed.encoded(maximumBytes: bound)
    let mutations: [(inout [String: Any]) -> Void] = [
      { $0["unexpected"] = "payload" },
      { $0["version"] = 2 },
      { $0["version"] = true },
      { var c = $0["initial"] as! [String: Any]; c["input"] = "not-UUID"; $0["initial"] = c },
      { var c = $0["initial"] as! [String: Any]; c["paperID"] = id.paperID.uuidString.lowercased(); $0["initial"] = c },
      { var c = $0["initial"] as! [String: Any]; c["secret"] = "unrecognized"; $0["initial"] = c },
      { var c = $0["initial"] as! [String: Any]; var f = c["confirmedInput"] as! [String: Any];
        f["expectedSHA256"] = String(repeating: "A", count: 64); c["confirmedInput"] = f; $0["initial"] = c },
      { var c = $0["initial"] as! [String: Any]; var f = c["confirmedInput"] as! [String: Any];
        f["path"] = "/synthetic/forbidden"; c["confirmedInput"] = f; $0["initial"] = c },
      { var c = $0["initial"] as! [String: Any]; var f = c["confirmedInput"] as! [String: Any];
        f.removeValue(forKey: "destinationFolderID"); c["confirmedInput"] = f; $0["initial"] = c },
      { $0["events"] = [["unknown": [:]]] },
      { var events = $0["events"] as! [[String: Any]]; var claim = events[0]["claim"] as! [String: Any];
        var l = claim["_0"] as! [String: Any]; var a = l["captured"] as! [String: Any];
        a["extra"] = false; l["captured"] = a; claim["_0"] = l; events[0]["claim"] = claim; $0["events"] = events },
      { var events = $0["events"] as! [[String: Any]]; var claim = events[0]["claim"] as! [String: Any];
        var l = claim["_0"] as! [String: Any]; var a = l["captured"] as! [String: Any];
        a["prerequisitesAvailable"] = 1; l["captured"] = a; claim["_0"] = l; events[0]["claim"] = claim; $0["events"] = events },
      { var c = $0["initial"] as! [String: Any]; c["input"] = UUID().uuidString; $0["initial"] = c }
    ]
    for mutation in mutations {
      XCTAssertThrowsError(try ImportRecoveryJournal.decode(mutate(bytes, mutation), maximumBytes: bound))
    }
    XCTAssertThrowsError(try claimed.encoded(maximumBytes: 0))
    XCTAssertThrowsError(try ImportRecoveryJournal.decode(bytes, maximumBytes: 0))
    XCTAssertThrowsError(try claimed.encoded(maximumBytes: -1))
    XCTAssertThrowsError(try ImportRecoveryJournal.decode(bytes, maximumBytes: -1))
    XCTAssertThrowsError(try ImportRecoveryJournal.decode(Data(bytes.dropLast()), maximumBytes: bound))
    XCTAssertThrowsError(try claimed.encoded(maximumBytes: bytes.count - 1))
    XCTAssertThrowsError(try ImportRecoveryJournal.decode(bytes, maximumBytes: bytes.count - 1))
    XCTAssertNoThrow(try ImportRecoveryJournal.decode(bytes, maximumBytes: bytes.count))
    XCTAssertEqual(try claimed.encoded(maximumBytes: bytes.count), bytes)
    XCTAssertThrowsError(try ImportRecoveryJournal(identity: id, confirmedInput:
      .init(expectedSHA256: "short", destinationFolderID: nil)))
  }
}
