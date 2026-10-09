import Foundation
@testable import PaperLensProduct

// Synthetic unit-test allowance only; not native RSS accounting or product calibration.
final class ExtractionFixtureBudget: @unchecked Sendable {
  enum Failure: Error { case exhausted }
  private let lock = NSLock()
  private let deadline = DispatchTime.now().uptimeNanoseconds + 10_000_000_000
  private var remaining: Int
  init(maximumChecks: Int) { remaining = maximumChecks }
  func check() throws {
    try Task.checkCancellation()
    lock.lock(); defer { lock.unlock() }
    guard remaining > 0, DispatchTime.now().uptimeNanoseconds < deadline else {
      throw Failure.exhausted
    }
    remaining -= 1
  }
}

func fixtureExtractionScope() -> ExtractionConsumptionScope {
  let budget = ExtractionFixtureBudget(maximumChecks: 8192)
  return ExtractionConsumptionScope(checkBudget: { try budget.check() })
}

// Storage-only fixtures intentionally bypass geometry/native production admission.
func publishFixtureExtraction(_ database: ProductDatabase, _ identity: ExtractionIdentity,
  sentences: [ValidatedExtractionSentence]) throws {
  let scope = fixtureExtractionScope()
  try database.publishExtraction(identity, sentences: sentences,
    checkBudget: { try scope.checkBudget() })
}
