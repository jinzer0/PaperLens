import Foundation

public enum LibraryExtractionPinError: Error, Equatable {
  case wrongOperation
  case senderAlreadyTaken
  case duplicateFailed(Int32)
}

/// Ephemeral evidence for exactly one registry token, never a persistence authority.
final class LibraryPinClosureObservation: @unchecked Sendable {
  private let lock = NSLock()
  private var outcome: Result<Void, any Error>?
  private var waiters: [CheckedContinuation<Void, any Error>] = []

  func finish(_ result: Result<Void, any Error>) {
    let pending: [CheckedContinuation<Void, any Error>] = lock.withLock {
      guard outcome == nil else { return [] }
      outcome = result
      let pending = waiters
      waiters.removeAll()
      return pending
    }
    for waiter in pending { waiter.resume(with: result) }
  }

  func wait() async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
      let result: Result<Void, any Error>? = lock.withLock {
        if let outcome { return outcome }
        waiters.append(continuation)
        return nil
      }
      if let result { continuation.resume(with: result) }
    }
  }
}

/// A child of the actual Library lifecycle. Producer disposal must precede release.
/// Neither revocation, cancellation nor deallocation is evidence of physical closure.
public final class LibraryExtractionReadPin: @unchecked Sendable {
  public let operationID: UUID
  private let registry: LibraryReadLeaseRegistry
  private let token: UUID
  private let closure: LibraryPinClosureObservation

  init(operationID: UUID, registry: LibraryReadLeaseRegistry, token: UUID) {
    self.operationID = operationID
    self.registry = registry
    self.token = token
    closure = registry.closureObservation(token)
  }

  public func validate() throws { try registry.validate(token) }

  /// Transfers one owned readonly descriptor to PDFiumPinnedInput. Caller must dispose it.
  public func takeSenderPDF() throws -> FileHandle { try registry.takeSenderPDF(token) }

  public func release(operationID: UUID) async throws {
    guard operationID == self.operationID else { throw LibraryExtractionPinError.wrongOperation }
    registry.close(token)
    try await closure.wait()
  }
}
