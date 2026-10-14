import Foundation
import ProviderRequest
import XCTest
@testable import PaperLensProduct

/// Owned-unit Main accounting only; no helper, PDFium, renderer or product trial.
@MainActor final class PDFiumExtractionResourceOwnerTests: XCTestCase {
  private enum ObserverError: Error { case unavailable }
  private final class Observations: @unchecked Sendable {
    private let lock = NSLock()
    private var time: UInt64 = 1_000_000
    private var bytes: UInt64 = 1
    private var unavailable = false
    private var calls = 0
    private var hook: (@Sendable () throws -> Void)?
    func clock() -> UInt64 { lock.withLock { time } }
    func setTime(_ value: UInt64) { lock.withLock { time = value } }
    func setBytes(_ value: UInt64) { lock.withLock { bytes = value } }
    func fail(_ value: Bool) { lock.withLock { unavailable = value } }
    func setHook(_ value: @escaping @Sendable () throws -> Void) { lock.withLock { hook = value } }
    func callCount() -> Int { lock.withLock { calls } }
    func resident() throws -> UInt64 {
      let callback = lock.withLock { calls += 1; return hook }
      try callback?()
      return try lock.withLock {
        if unavailable { throw ObserverError.unavailable }
        return bytes
      }
    }
  }
  private final class Outcome: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Error?
    func capture(_ body: () throws -> Void) {
      do { try body() } catch { lock.withLock { value = error } }
    }
    func error() -> Error? { lock.withLock { value } }
  }
  private func identity() -> ExtractionIdentity {
    .init(paperID: UUID(), generation: UUID(), pdfSHA256: String(repeating: "a", count: 64),
      pdfReference: "synthetic.pdf", revision: UUID(), job: UUID(), attempt: UUID(), fence: UUID(),
      correlation: UUID(), input: UUID(), epoch: UUID(),
      configuration: ProviderConfiguration(kind: nil, slotID: nil, generation: 0, model: nil))
  }
  private func owner(_ observations: Observations, authority: ProviderRequest,
    identity: ExtractionIdentity? = nil, operationID: UUID = UUID()) throws -> PDFiumExtractionResourceOwner {
    try .init(identity: identity ?? self.identity(), operationID: operationID, authority: authority,
      testingClock: { observations.clock() }, testingResidentBytes: { try observations.resident() })
  }
  private func assertFailure(_ code: PDFiumFailureCode,
    _ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertThrowsError(try body(), file: file, line: line) {
      XCTAssertEqual(($0 as? PDFiumFailure)?.code, code, file: file, line: line)
    }
  }

  func testUsesActualParserPoolAndExactAuthorityLimits() throws {
    let authority = try ProviderRequest(), observations = Observations()
    let pool = try RequestResourcePool(authority: authority, kind: "parser")
    let id = identity(), operation = UUID(), start = observations.clock()
    let captured = try owner(observations, authority: authority, identity: id, operationID: operation)
    defer { try? captured.finishOperation(operation) }
    XCTAssertEqual(captured.identity, id)
    XCTAssertEqual(captured.operationID, operation)
    XCTAssertEqual(captured.deadlineUptimeNanoseconds,
      start + UInt64(authority.limit("parserElapsedMs")) * 1_000_000)
    let limits = captured.limits
    XCTAssertEqual(limits.maximumInputBytes, Int64(authority.limit("pdfBytes")))
    XCTAssertEqual(limits.maximumPages, authority.limit("pages"))
    XCTAssertEqual(limits.maximumSentences, authority.limit("sentences"))
    XCTAssertEqual(limits.maximumSentenceBytes, authority.limit("sentenceBytes"))
    XCTAssertEqual(limits.maximumTextBytes, authority.limit("textBytes"))
    XCTAssertEqual(limits.maximumQuadsPerSentence, authority.limit("quadsPerSentence"))
    XCTAssertEqual(limits.maximumQuads, authority.limit("quads"))
    XCTAssertEqual(limits.maximumBatchSentences, authority.limit("batchSentences"))
    XCTAssertEqual(limits.maximumBatchBytes, authority.limit("batchBytes"))
    XCTAssertEqual(limits.maximumResidentBytes, UInt64(authority.limit("rssBytes")))
    XCTAssertEqual(pool.active, 1)
    XCTAssertNil(pool.acquire())
    assertFailure(.busy) { _ = try owner(observations, authority: authority) }
    observations.setBytes(limits.maximumResidentBytes)
    try captured.checkBudget()
    observations.setBytes(limits.maximumResidentBytes + 1)
    assertFailure(.resourceExceeded) { try captured.checkBudget() }
    XCTAssertEqual(pool.active, 1)
  }

  func testExistingPoolLeaseDeniesAdmission() throws {
    let authority = try ProviderRequest()
    let pool = try RequestResourcePool(authority: authority, kind: "parser")
    let lease = try XCTUnwrap(pool.acquire())
    defer { lease.close() }
    assertFailure(.busy) { _ = try owner(Observations(), authority: authority) }
    XCTAssertEqual(pool.active, 1)
  }

  func testOriginalDeadlineNeverRenewsAndFailureIsSticky() throws {
    let authority = try ProviderRequest(), observations = Observations()
    let captured = try owner(observations, authority: authority)
    defer { try? captured.finishOperation(captured.operationID) }
    let deadline = captured.deadlineUptimeNanoseconds
    observations.setTime(deadline - 1)
    try captured.checkBudget()
    assertFailure(.invalidRequest) { try captured.finishOperation(UUID()) }
    XCTAssertEqual(captured.deadlineUptimeNanoseconds, deadline)
    observations.setTime(deadline)
    assertFailure(.resourceExceeded) { try captured.checkBudget() }
    let calls = observations.callCount()
    observations.setTime(deadline - 1)
    assertFailure(.resourceExceeded) { try captured.checkBudget() }
    XCTAssertEqual(observations.callCount(), calls)
  }

  func testSubMillisecondBackwardsClockIsRejectedWithoutReleasing() throws {
    let authority = try ProviderRequest(), observations = Observations()
    let captured = try owner(observations, authority: authority)
    defer { try? captured.finishOperation(captured.operationID) }
    observations.setTime(1_000_002)
    try captured.checkBudget()
    observations.setTime(1_000_001)
    assertFailure(.resourceExceeded) { try captured.checkBudget() }
    observations.setTime(1_000_003)
    assertFailure(.resourceExceeded) { try captured.checkBudget() }
    XCTAssertNil(try RequestResourcePool(authority: authority, kind: "parser").acquire())
  }

  func testDeadlineOverflowFailsBeforeLeaseAcquisition() throws {
    let authority = try ProviderRequest(), observations = Observations()
    observations.setTime(UInt64.max)
    assertFailure(.resourceExceeded) { _ = try owner(observations, authority: authority) }
    XCTAssertEqual(try RequestResourcePool(authority: authority, kind: "parser").active, 0)
    XCTAssertEqual(observations.callCount(), 0)
  }

  func testConstructorObserverFailureOrZeroOrOverflowClosesOnlyNewLease() throws {
    let authority = try ProviderRequest(), observations = Observations()
    let pool = try RequestResourcePool(authority: authority, kind: "parser")
    observations.fail(true)
    assertFailure(.resourceExceeded) { _ = try owner(observations, authority: authority) }
    XCTAssertEqual(pool.active, 0)
    observations.fail(false)
    for bytes in [UInt64(0), UInt64.max] {
      observations.setBytes(bytes)
      assertFailure(.resourceExceeded) { _ = try owner(observations, authority: authority) }
      XCTAssertEqual(pool.active, 0)
    }
    observations.setBytes(1)
    let captured = try owner(observations, authority: authority)
    try captured.finishOperation(captured.operationID)
    XCTAssertEqual(pool.active, 0)
  }

  func testActualMainPublicKernelObservationIsPositive() throws {
    XCTAssertGreaterThan(try PDFiumExtractionResourceOwner.observeMainResidentBytes(), 0)
  }

  func testObserverFailureSticksAndHoldsPoolUntilExplicitFinish() throws {
    let authority = try ProviderRequest(), observations = Observations()
    let pool = try RequestResourcePool(authority: authority, kind: "parser")
    let captured = try owner(observations, authority: authority)
    defer { try? captured.finishOperation(captured.operationID) }
    observations.fail(true)
    assertFailure(.resourceExceeded) { try captured.checkBudget() }
    observations.fail(false)
    let calls = observations.callCount()
    assertFailure(.resourceExceeded) { try captured.checkBudget() }
    XCTAssertEqual(observations.callCount(), calls)
    XCTAssertEqual(pool.active, 1)
    try captured.finishOperation(captured.operationID)
    XCTAssertEqual(pool.active, 0)
  }

  func testCancellationSticksAcrossUncancelledCallbackAndDoesNotRelease() async throws {
    let authority = try ProviderRequest(), observations = Observations()
    let captured = try owner(observations, authority: authority)
    defer { try? captured.finishOperation(captured.operationID) }
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      self.assertFailure(.cancelled) { try captured.checkBudget() }
    }
    await task.value
    assertFailure(.cancelled) { try captured.checkBudget() }
    XCTAssertEqual(try RequestResourcePool(authority: authority, kind: "parser").active, 1)
    try captured.finishOperation(captured.operationID)
  }

  func testCancelledConstructorDoesNotAcquireLease() async throws {
    let authority = try ProviderRequest(), observations = Observations()
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      XCTAssertThrowsError(try self.owner(observations, authority: authority)) {
        XCTAssertTrue($0 is CancellationError)
      }
    }
    try await task.value
    XCTAssertEqual(try RequestResourcePool(authority: authority, kind: "parser").active, 0)
  }

  func testCancellationDuringResidentObservationCannotReturnSuccess() async throws {
    let authority = try ProviderRequest(), observations = Observations()
    let captured = try owner(observations, authority: authority)
    defer { try? captured.finishOperation(captured.operationID) }
    observations.setHook { withUnsafeCurrentTask { $0?.cancel() } }
    let task = Task {
      self.assertFailure(.cancelled) { try captured.checkBudget() }
    }
    await task.value
    assertFailure(.cancelled) { try captured.checkBudget() }
    XCTAssertEqual(try RequestResourcePool(authority: authority, kind: "parser").active, 1)
  }

  func testWrongIDDoesNothingCorrectFinishIsIdempotentAndReleasedCheckFails() throws {
    let authority = try ProviderRequest(), observations = Observations()
    let captured = try owner(observations, authority: authority)
    defer { try? captured.finishOperation(captured.operationID) }
    let pool = try RequestResourcePool(authority: authority, kind: "parser")
    assertFailure(.invalidRequest) { try captured.finishOperation(UUID()) }
    XCTAssertEqual(pool.active, 1)
    try captured.checkBudget()
    try captured.finishOperation(captured.operationID)
    let next = try owner(Observations(), authority: authority)
    defer { try? next.finishOperation(next.operationID) }
    try captured.finishOperation(captured.operationID)
    assertFailure(.invalidRequest) { try captured.finishOperation(UUID()) }
    assertFailure(.cleanupIncomplete) { try captured.checkBudget() }
    XCTAssertEqual(pool.active, 1, "old idempotent finish must not close the new allocation")
  }

  func testUnknownCleanupRetainsActualLeaseAfterFacadeDrop() throws {
    let authority = try ProviderRequest(), observations = Observations()
    let pool = try RequestResourcePool(authority: authority, kind: "parser")
    let operation = UUID()
    var facade: PDFiumExtractionResourceOwner? = try owner(observations,
      authority: authority, operationID: operation)
    weak var retained = facade
    observations.fail(true)
    assertFailure(.resourceExceeded) { try XCTUnwrap(facade).checkBudget() }
    facade = nil
    XCTAssertNotNil(retained, "ARC is not physical closure evidence")
    XCTAssertEqual(pool.active, 1)
    XCTAssertNil(pool.acquire())
    assertFailure(.busy) { _ = try owner(observations, authority: authority) }
    try XCTUnwrap(retained).finishOperation(operation)
    XCTAssertEqual(pool.active, 0)
  }

  func testConsumedOriginalOperationCannotRenewAfterSuccessfulOrExpiredFinish() throws {
    let authority = try ProviderRequest()
    let pool = try RequestResourcePool(authority: authority, kind: "parser")
    for expire in [false, true] {
      let observations = Observations(), id = identity(), operation = UUID()
      let captured = try owner(observations, authority: authority, identity: id, operationID: operation)
      if expire {
        observations.setTime(captured.deadlineUptimeNanoseconds)
        assertFailure(.resourceExceeded) { try captured.checkBudget() }
      }
      try captured.finishOperation(operation)
      XCTAssertEqual(pool.active, 0)
      observations.setTime(captured.deadlineUptimeNanoseconds + 1)
      assertFailure(.busy) {
        _ = try owner(observations, authority: authority, identity: id, operationID: operation)
      }
      XCTAssertEqual(pool.active, 0)
      let fresh = try owner(observations, authority: authority, identity: id, operationID: UUID())
      try captured.finishOperation(operation)
      XCTAssertEqual(pool.active, 1)
      try fresh.finishOperation(fresh.operationID)
    }
  }

  func testConcurrentFinishCannotForgetOriginalOperationBeforeRecapture() throws {
    let authority = try ProviderRequest(), observations = Observations()
    let id = identity(), operation = UUID()
    let captured = try owner(observations, authority: authority, identity: id, operationID: operation)
    defer { try? captured.finishOperation(operation) }
    let entered = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0)
    let checked = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
    let replayed = DispatchSemaphore(value: 0)
    let check = Outcome(), finish = Outcome(), replay = Outcome()
    let replayObservations = Observations()
    observations.setHook {
      entered.signal()
      guard resume.wait(timeout: .now() + 5) == .success else { throw ObserverError.unavailable }
    }
    DispatchQueue.global().async {
      check.capture { try captured.checkBudget() }
      checked.signal()
    }
    XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
    DispatchQueue.global().async {
      finish.capture { try captured.finishOperation(operation) }
      finished.signal()
    }
    DispatchQueue.global().async {
      replay.capture {
        guard finished.wait(timeout: .now() + 5) == .success else { throw ObserverError.unavailable }
        let renewed = try PDFiumExtractionResourceOwner(identity: id, operationID: operation,
          authority: authority, testingClock: { replayObservations.clock() },
          testingResidentBytes: { try replayObservations.resident() })
        try renewed.finishOperation(operation)
      }
      replayed.signal()
    }
    resume.signal()
    XCTAssertEqual(checked.wait(timeout: .now() + 5), .success)
    XCTAssertEqual(replayed.wait(timeout: .now() + 5), .success)
    XCTAssertNil(check.error())
    XCTAssertNil(finish.error())
    XCTAssertEqual((replay.error() as? PDFiumFailure)?.code, .busy)
    XCTAssertEqual(try RequestResourcePool(authority: authority, kind: "parser").active, 0)
  }

  func testFinishSerializesWithObservationAndCannotPublishStaleSuccess() throws {
    let authority = try ProviderRequest(), observations = Observations()
    let captured = try owner(observations, authority: authority)
    defer { try? captured.finishOperation(captured.operationID) }
    let entered = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0)
    let checked = DispatchSemaphore(value: 0), finishing = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    let checkOutcome = Outcome(), finishOutcome = Outcome()
    observations.setHook {
      entered.signal()
      guard resume.wait(timeout: .now() + 5) == .success else { throw ObserverError.unavailable }
    }
    DispatchQueue.global().async {
      checkOutcome.capture { try captured.checkBudget() }
      checked.signal()
    }
    XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
    DispatchQueue.global().async {
      finishing.signal()
      finishOutcome.capture { try captured.finishOperation(captured.operationID) }
      finished.signal()
    }
    XCTAssertEqual(finishing.wait(timeout: .now() + 5), .success)
    XCTAssertEqual(finished.wait(timeout: .now()), .timedOut)
    observations.setTime(captured.deadlineUptimeNanoseconds)
    resume.signal()
    XCTAssertEqual(checked.wait(timeout: .now() + 5), .success)
    XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
    XCTAssertEqual((checkOutcome.error() as? PDFiumFailure)?.code, .resourceExceeded)
    XCTAssertNil(finishOutcome.error())
    assertFailure(.cleanupIncomplete) { try captured.checkBudget() }
    XCTAssertEqual(try RequestResourcePool(authority: authority, kind: "parser").active, 0)
  }
}
