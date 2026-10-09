import Darwin
import Foundation
#if SWIFT_PACKAGE
import ProviderRequest
#endif

/// Main's captured parser allowance, not a combined Main/helper memory bound.
/// The producer must call finish only after disposal and genuine read-pin release.
/// Unknown cleanup deliberately retains the actual lease, even if callers drop us.
public final class PDFiumExtractionResourceOwner: @unchecked Sendable {
  public let identity: ExtractionIdentity
  public let operationID: UUID
  public let limits: PDFiumExtractionLimits
  public let deadlineUptimeNanoseconds: UInt64

  // Lifetime storage only: all admission/counting belongs to RequestResourcePool.
  private final class CapturedAllocations: @unchecked Sendable {
    static let shared = CapturedAllocations()
    let lock = NSLock()
    var owners: [UUID: PDFiumExtractionResourceOwner] = [:]
    var consumed: Set<UUID> = []
  }
  private let lease: RequestResourceLease
  private let budget: RequestResourceBudget
  private let startUptimeNanoseconds: UInt64
  private let clock: @Sendable () -> UInt64
  private let residentBytes: @Sendable () throws -> UInt64
  // Per-operation effect ownership serializes kernel/clock observations and finish.
  // The short allocation arbitration lock is never held during these observations.
  private let effectLock = NSLock()
  private var lastUptimeNanoseconds: UInt64
  private var failure: PDFiumFailure?
  private var released = false
  private var inputClaimed = false

  public convenience init(identity: ExtractionIdentity, operationID: UUID,
    authority: ProviderRequest) throws {
    try self.init(identity: identity, operationID: operationID, authority: authority,
      testingClock: { DispatchTime.now().uptimeNanoseconds },
      testingResidentBytes: { try Self.observeMainResidentBytes() })
  }

  /// Explicit synthetic dependencies for owned-unit tests only; no default success.
  internal init(identity: ExtractionIdentity, operationID: UUID, authority: ProviderRequest,
    testingClock: @escaping @Sendable () -> UInt64,
    testingResidentBytes: @escaping @Sendable () throws -> UInt64) throws {
    try Task.checkCancellation()
    let elapsedMs = authority.limit("parserElapsedMs")
    guard elapsedMs > 0, authority.limit("rssBytes") > 0,
      authority.limit("parserConcurrency") > 0 else {
      throw PDFiumFailure(code: .invalidRequest)
    }
    let duration = UInt64(elapsedMs).multipliedReportingOverflow(by: 1_000_000)
    let start = testingClock()
    let deadline = start.addingReportingOverflow(duration.partialValue)
    guard !duration.overflow, !deadline.overflow, deadline.partialValue > start else {
      throw PDFiumFailure(code: .resourceExceeded)
    }
    let limits = try PDFiumExtractionLimits(
      maximumInputBytes: Int64(authority.limit("pdfBytes")), maximumPages: authority.limit("pages"),
      maximumSentences: authority.limit("sentences"), maximumSentenceBytes: authority.limit("sentenceBytes"),
      maximumTextBytes: authority.limit("textBytes"), maximumQuadsPerSentence: authority.limit("quadsPerSentence"),
      maximumQuads: authority.limit("quads"), maximumBatchSentences: authority.limit("batchSentences"),
      maximumBatchBytes: authority.limit("batchBytes"), maximumResidentBytes: UInt64(authority.limit("rssBytes")))
    _ = try PDFiumExtractionKey(operationID: operationID, paperID: identity.paperID,
      generation: identity.generation, revision: identity.revision, job: identity.job,
      attempt: identity.attempt, fence: identity.fence, correlation: identity.correlation,
      input: identity.input, epoch: identity.epoch, pdfSHA256: identity.pdfSHA256,
      pdfReference: identity.pdfReference)
    let budget = try RequestResourceBudget(authority: authority, kind: "parser")
    let pool = try RequestResourcePool(authority: authority, kind: "parser")
    guard let lease = pool.acquire() else { throw PDFiumFailure(code: .busy) }
    self.identity = identity
    self.operationID = operationID
    self.limits = limits
    self.deadlineUptimeNanoseconds = deadline.partialValue
    self.startUptimeNanoseconds = start
    self.lastUptimeNanoseconds = start
    self.clock = testingClock
    self.residentBytes = testingResidentBytes
    self.budget = budget
    self.lease = lease
    do {
      try checkBudget()
      let allocations = CapturedAllocations.shared
      try allocations.lock.withLock {
        guard !allocations.consumed.contains(operationID) else { throw PDFiumFailure(code: .busy) }
        allocations.consumed.insert(operationID)
        allocations.owners[operationID] = self
      }
    } catch {
      // Constructor has not handed off any input/effect ownership.
      lease.close()
      throw error
    }
  }

  /// Successful public kernel observation of this process; no zero/error fallback.
  internal static func observeMainResidentBytes() throws -> UInt64 {
    var info = mach_task_basic_info()
    let expectedCount = mach_msg_type_number_t(
      MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    var count = expectedCount
    let result = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(expectedCount)) {
        task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
      }
    }
    guard result == KERN_SUCCESS, count == expectedCount,
      let bytes = UInt64(exactly: info.resident_size), bytes > 0 else {
      throw PDFiumFailure(code: .resourceExceeded)
    }
    return bytes
  }

  /// An actual allowance transfers to one input, even across separate acquirers.
  func claimInputAcquisition() throws {
    try effectLock.withLock {
      guard !inputClaimed else { throw PDFiumFailure(code: .busy) }
      guard !released else { throw PDFiumFailure(code: .cleanupIncomplete) }
      inputClaimed = true
    }
  }

  public func checkBudget() throws {
    try effectLock.withLock {
      guard !released else { throw PDFiumFailure(code: .cleanupIncomplete) }
      if let failure { throw failure }
      do {
        try checkTimeAndCancellation()
        let bytes = try residentBytes()
        guard bytes > 0, let value = Int(exactly: bytes) else {
          throw PDFiumFailure(code: .resourceExceeded)
        }
        try budget.observe("rssBytes", value: value)
        // Observation itself can consume time or coincide with cancellation.
        try checkTimeAndCancellation()
      } catch {
        let sticky = (error as? PDFiumFailure) ?? PDFiumFailure(code: .resourceExceeded)
        failure = sticky
        throw sticky
      }
    }
  }

  private func checkTimeAndCancellation() throws {
    guard !Task.isCancelled else { throw PDFiumFailure(code: .cancelled) }
    let now = clock()
    guard now >= lastUptimeNanoseconds, now >= startUptimeNanoseconds,
      now < deadlineUptimeNanoseconds,
      let elapsedMs = Int(exactly: (now - startUptimeNanoseconds) / 1_000_000) else {
      throw PDFiumFailure(code: .resourceExceeded)
    }
    try budget.observe("elapsedMs", value: elapsedMs)
    lastUptimeNanoseconds = now
    guard !Task.isCancelled else { throw PDFiumFailure(code: .cancelled) }
  }

  /// Request only: retains the original allowance until actual closure and finish.
  public func requestCancellation(operationID: UUID) throws {
    guard operationID == self.operationID else { throw PDFiumFailure(code: .invalidRequest) }
    try effectLock.withLock {
      guard !released else { throw PDFiumFailure(code: .cleanupIncomplete) }
      if failure == nil { failure = PDFiumFailure(code: .cancelled) }
    }
  }

  /// Correct-ID callback is closure evidence supplied by PDFiumPinnedInput, not ARC.
  /// Expiry/cancellation/failure cannot release ownership; explicit finish still can.
  public func finishOperation(_ operationID: UUID) throws {
    guard operationID == self.operationID else { throw PDFiumFailure(code: .invalidRequest) }
    effectLock.withLock {
      guard !released else { return }
      lease.close()
      released = true
      let allocations = CapturedAllocations.shared
      allocations.lock.withLock {
        if allocations.owners[operationID] === self {
          allocations.owners.removeValue(forKey: operationID)
        }
      }
    }
  }
}
