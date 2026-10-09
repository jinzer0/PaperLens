import Foundation

/// Composes the retained Library owner and Main's already captured parser allowance.
/// No helper, geometry capability or fresh allowance is created here.
public actor LibraryPDFiumInputAcquirer {
  private let lifecycle: LocalLibraryLifecycle
  private let closeSender: @Sendable (FileHandle) throws -> Void
  private let beforeConstruct: (@Sendable (FileHandle) throws -> Void)?

  public init(lifecycle: LocalLibraryLifecycle) {
    self.lifecycle = lifecycle
    closeSender = { try $0.close() }
    beforeConstruct = nil
  }

  /// Explicit fault injection on real owned descriptors, not a replacement constructor.
  internal init(lifecycle: LocalLibraryLifecycle,
    testingCloseSender: @escaping @Sendable (FileHandle) throws -> Void,
    testingBeforeConstruct: @escaping @Sendable (FileHandle) throws -> Void) {
    self.lifecycle = lifecycle
    closeSender = testingCloseSender
    beforeConstruct = testingBeforeConstruct
  }

  public func acquireInput(resources: PDFiumExtractionResourceOwner,
    onRevoked: @escaping @MainActor () -> Void) async throws -> PDFiumPinnedInput {
    let identity = resources.identity
    let operation = resources.operationID
    // Rejected reuse must not finish the allowance already transferred to another input.
    try resources.claimInputAcquisition()
    let database = lifecycle.readLeaseDatabase
    var pin: LibraryExtractionReadPin?
    var sender: FileHandle?
    do {
      guard identity.epoch == lifecycle.epoch else { throw ExtractionError.staleAttempt }
      try resources.checkBudget()
      let snapshot = try database.extractionReadSnapshot(identity)
      let acquired = try await MainActor.run {
        try LibraryReadLeaseProvider(lifecycle: lifecycle).acquireExtractionReadPin(
          for: snapshot, operationID: operation, onRevoked: onRevoked)
      }
      pin = acquired
      try acquired.validate()
      try resources.checkBudget()
      try validateSnapshot(database.extractionReadSnapshot(identity), against: snapshot)
      let transferred = try acquired.takeSenderPDF()
      sender = transferred
      try acquired.validate()
      try resources.checkBudget()
      try validateSnapshot(database.extractionReadSnapshot(identity), against: snapshot)
      try beforeConstruct?(transferred)
      let input = try PDFiumPinnedInput(operationID: operation, identity: identity,
        senderPDF: transferred, limits: resources.limits,
        deadlineUptimeNanoseconds: resources.deadlineUptimeNanoseconds,
        checkBudget: {
          // This callback also runs inside the publication writer transaction.
          try acquired.validate()
          try resources.checkBudget()
        }, releaseReadPin: { try await acquired.release(operationID: $0) },
        finishOperation: { try resources.finishOperation($0) })
      try acquired.validate()
      try resources.checkBudget()
      try validateSnapshot(database.extractionReadSnapshot(identity), against: snapshot)
      return input
    } catch {
      let cause = error
      if let sender, let pin {
        do { try closeSender(sender) }
        catch {
          pin.retainUncertainSender(sender)
          throw LocalLibraryError.producerClosureUnknown
        }
      }
      // A failed transfer/open may already have recorded physical closure debt.
      if cause as? LocalLibraryError == .producerClosureUnknown { throw cause }
      if let pin {
        do { try await pin.release(operationID: operation) }
        catch { throw LocalLibraryError.producerClosureUnknown }
      }
      try resources.finishOperation(operation)
      throw cause
    }
  }

  private func validateSnapshot(_ current: ReaderPaperSnapshot,
    against captured: ReaderPaperSnapshot) throws {
    guard current.paperID == captured.paperID, current.generation == captured.generation,
      current.pdfReference.utf8.elementsEqual(captured.pdfReference.utf8) else {
      throw ExtractionError.staleAttempt
    }
  }
}
