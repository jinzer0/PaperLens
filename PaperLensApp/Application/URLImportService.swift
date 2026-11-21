import Combine
import Foundation
#if SWIFT_PACKAGE
import ProviderRequest
#endif

/// The lifecycle must admit a real current writer before returning this capability.
/// The directory already exists in that writer's owned namespace. Publication consumes
/// the closed stage under a distinct publication permit and performs guarded rename/DB
/// commit. No default implementation grants any permission or constructs any path.
public protocol URLImportWriter: Sendable {
  var stagingDirectory: URL { get }
  func assertCurrent() throws
  /// Synchronously mark the current producer revoked; must not report drain here.
  func revoke()
  func publish(_ stage: ClosedHTTPSPDFStage) async throws -> UUID
  /// Runs after network drain. closureUnknown forbids declaring the file producer
  /// closed or erasing its namespace; retain closure/cleanup debt in the lifecycle.
  func abort(reason: URLImportError) async throws
}

private final class URLImportAdmission: @unchecked Sendable {
  private let lock = NSLock()
  private enum Phase { case confirming, continued, granted, cancelled }
  private var phase = Phase.confirming
  private var failedQuery: (@Sendable () async throws -> ImportRecoveryRecord)?
  private var queryBound = false
  var granted: Bool { lock.withLock { phase == .granted } }
  var reservationAcknowledged: Bool { lock.withLock { queryBound } }
  func bindFailedQuery(_ query: @escaping @Sendable () async throws -> ImportRecoveryRecord) throws {
    try lock.withLock {
      guard phase == .granted, !queryBound else { throw URLImportError.writerUnavailable }
      queryBound = true
      failedQuery = query
    }
  }
  func captureFailed() async throws -> ImportRecoveryRecord {
    let query = lock.withLock {
      let query = failedQuery
      failedQuery = nil
      return query
    }
    guard let query else { throw URLImportError.writerUnavailable }
    return try await query()
  }
  func continueOnce() -> Bool {
    lock.withLock {
      guard phase == .confirming else { return false }
      phase = .continued
      return true
    }
  }
  func grantOnce() -> Bool {
    lock.withLock {
      guard phase == .continued else { return false }
      phase = .granted
      return true
    }
  }
  func cancel() { lock.withLock { if phase == .confirming { phase = .cancelled } } }
}

private extension ImportRecoveryRecord {
  var paperID: UUID? { try? journal.currentCapture().identity.paperID }
}

public struct URLImportConfirmation: Identifiable, Sendable {
  enum Purpose: Sendable {
    case newPaper, retry(ImportRecoveryRecord)

    fileprivate var retryPaperID: UUID? {
      guard case .retry(let record) = self else { return nil }
      return record.paperID
    }
  }
  public let id: UUID
  public let destination: String
  public let destinationFolderID: UUID?
  public let possibleDuplicate: Bool
  public var sourceKind: String { route.sourceKind }
  let inputKind: URLImportInputKind
  let purpose: Purpose
  fileprivate let route: ValidatedRequestURL
  fileprivate let admission = URLImportAdmission()
  func consumeWriterGrant() -> Bool { admission.grantOnce() }
  func bindFailedQuery(_ query: @escaping @Sendable () async throws -> ImportRecoveryRecord) throws {
    try admission.bindFailedQuery(query)
  }
  func authorizesURLRetry(_ expected: ImportRecoveryRecord) -> Bool {
    guard admission.granted, case .retry(let record) = purpose,
      record.encoded == expected.encoded else { return false }
    return sourceKind == "httpsPDF" || sourceKind == "arxivPDF"
  }
}

@MainActor
public final class URLImportService: ObservableObject {
  public enum State: Equatable {
    case idle, confirming, downloading, ready(UUID), failed(URLImportError)
  }
  @Published public private(set) var state: State = .idle
  @Published public private(set) var confirmation: URLImportConfirmation?
  private let adapter: HTTPSPDFImportAdapter
  private let grant: (@Sendable (URLImportConfirmation) async throws -> any URLImportWriter)?
  private let sessionConfiguration: URLSessionConfiguration?
  private var writer: (any URLImportWriter)?
  private var operation: Task<Void, Never>?
  private var dismissedPaperIDs: Set<UUID> = []
  private var starting = false
  private var startCancellationRequested = false
  private var lastInput: String?
  private var lastDestination = ""
  private var lastDestinationFolderID: UUID?
  private var lastDuplicate = false
  private var failedIntent: URLImportConfirmation?
  private var retryRecord: ImportRecoveryRecord?
  private var admittedFailure = false
  private var failureBeforeRetry: URLImportError?

  var canRetry: Bool {
    guard case .failed = state, lastInput != nil else { return false }
    return retryPurpose != nil
  }

  private var retryPurpose: URLImportConfirmation.Purpose? {
    if let retryRecord { return .retry(retryRecord) }
    guard !admittedFailure, let failedIntent, case .newPaper = failedIntent.purpose else {
      return nil
    }
    return .newPaper
  }

  public convenience init(authority: ProviderRequest,
    grantWriter: (@Sendable (URLImportConfirmation) async throws -> any URLImportWriter)? = nil) {
    self.init(authority: authority, sessionConfiguration: nil, grantWriter: grantWriter)
  }

  init(authority: ProviderRequest, sessionConfiguration: URLSessionConfiguration?,
    grantWriter: (@Sendable (URLImportConfirmation) async throws -> any URLImportWriter)?) {
    adapter = HTTPSPDFImportAdapter(authority: authority)
    self.sessionConfiguration = sessionConfiguration
    grant = grantWriter
  }

  func dismissStatus(for paperID: UUID) {
    switch state {
    case .ready(let readyPaperID) where readyPaperID == paperID:
      state = .idle
    case .downloading:
      // Publication or failure capture can return after Library starts deleting the row.
      dismissedPaperIDs.insert(paperID)
    case .failed, .confirming:
      guard (confirmation?.purpose.retryPaperID ?? retryRecord?.paperID) == paperID else { return }
      confirmation?.admission.cancel()
      confirmation = nil
      discardFailure()
    default:
      break
    }
  }

  private func discardFailure() {
    lastInput = nil
    failedIntent = nil
    retryRecord = nil
    admittedFailure = false
    failureBeforeRetry = nil
    state = .idle
  }

  /// Destination and duplicate information come from the actual Library caller.
  /// This method validates only; it performs no Job, network, file, or DB effect.
  public func supports(_ input: String) -> Bool { (try? adapter.route(input)) != nil }

  public func prepare(_ input: String, destination: String, possibleDuplicate: Bool,
    destinationFolderID: UUID? = nil) throws {
    try prepare(input, destination: destination, possibleDuplicate: possibleDuplicate,
      destinationFolderID: destinationFolderID, purpose: .newPaper)
  }

  /// Reopens a failed durable URL import after relaunch without storing its URL.
  /// The supplied URL is validated for this confirmation only. No Paper, Job,
  /// writer, file or network effect occurs until the user explicitly continues.
  func prepareRetry(_ input: String, destination: String, possibleDuplicate: Bool,
    destinationFolderID: UUID? = nil, expected: ImportRecoveryRecord) throws {
    guard confirmation == nil, state != .confirming, state != .downloading
    else { throw URLImportError.rejected }
    try prepare(input, destination: destination, possibleDuplicate: possibleDuplicate,
      destinationFolderID: destinationFolderID, purpose: .retry(expected))
  }

  private func prepare(_ input: String, destination: String, possibleDuplicate: Bool,
    destinationFolderID: UUID?, purpose: URLImportConfirmation.Purpose,
    restoringFailure: URLImportError? = nil) throws {
    guard !starting, operation == nil else { throw URLImportError.rejected }
    let recognized: (kind: URLImportInputKind, request: ValidatedRequestURL)
    do { recognized = try adapter.recognize(input) } catch { throw URLImportError.rejected }
    lastInput = input
    lastDestination = destination
    lastDestinationFolderID = destinationFolderID
    lastDuplicate = possibleDuplicate
    failureBeforeRetry = restoringFailure
    if restoringFailure == nil {
      failedIntent = nil
      retryRecord = nil
      admittedFailure = false
    }
    confirmation = URLImportConfirmation(id: UUID(), destination: destination,
      destinationFolderID: destinationFolderID, possibleDuplicate: possibleDuplicate,
      inputKind: recognized.kind, purpose: purpose, route: recognized.request)
    state = .confirming
  }

  public func cancelConfirmation() {
    guard !starting, state == .confirming else { return }
    confirmation?.admission.cancel()
    confirmation = nil
    let failure = failureBeforeRetry
    failureBeforeRetry = nil
    if let failure {
      state = .failed(failure)
    } else {
      lastInput = nil
      state = .idle
    }
  }

  public func continueImport(confirmationID: UUID) {
    guard !starting, operation == nil, state == .confirming,
      let intent = confirmation, intent.id == confirmationID,
      intent.admission.continueOnce() else { return }
    starting = true
    startCancellationRequested = false
    defer {
      starting = false
      startCancellationRequested = false
    }
    confirmation = nil // Consume once, before any suspension or effect.
    failureBeforeRetry = nil
    failedIntent = intent
    retryRecord = nil
    admittedFailure = false
    guard let grant else { state = .failed(.writerUnavailable); return }
    state = .downloading
    operation = Task {
      defer {
        dismissedPaperIDs.removeAll()
        writer = nil
        operation = nil
      }
      var ownedWriter: (any URLImportWriter)?
      do {
        try Task.checkCancellation()
        let capability = try await grant(intent)
        ownedWriter = capability
        writer = capability
        try Task.checkCancellation()
        try capability.assertCurrent()
        let download = Task {
          try await adapter.download(route: intent.route,
            stagingDirectory: capability.stagingDirectory,
            assertCurrent: { try capability.assertCurrent() },
            configuration: sessionConfiguration ?? .ephemeral, effects: .actual)
        }
        // This main-actor child cannot begin until registration completes. Bind the
        // exact task, not the mutable service operation (which may later be a retry).
        try (capability as? LibraryURLImportWriter)?.bindDownload(download)
        let closed = try await withTaskCancellationHandler {
          try await download.value
        } onCancel: { download.cancel() }
        try Task.checkCancellation()
        try capability.assertCurrent()
        let paper = try await capability.publish(closed)
        state = dismissedPaperIDs.contains(paper) ? .idle : .ready(paper)
        lastInput = nil
        failedIntent = nil
      } catch {
        var safe = error as? URLImportError ??
          (Task.isCancelled || (error as? LocalLibraryError) == .cancelled ? .cancelled : .rejected)
        if let ownedWriter {
          ownedWriter.revoke()
          do { try await ownedWriter.abort(reason: safe) } catch { safe = .cleanupFailed }
        }
        admittedFailure = ownedWriter != nil || intent.admission.granted
        // Main's query is bound to the acknowledged execution, never to an error
        // label. It runs only after the real writer's abort/drain has returned.
        retryRecord = try? await intent.admission.captureFailed()
        if retryRecord == nil, ownedWriter == nil, !intent.admission.reservationAcknowledged,
          case .retry(let expected) = intent.purpose {
          // No replacement execution was acknowledged. The next Continue still
          // revalidates the genuine original history with the exact durable CAS.
          retryRecord = expected
        }
        if !dismissedPaperIDs.isEmpty,
          let paperID = (ownedWriter as? LibraryURLImportWriter)?.identity.paperID
            ?? retryRecord?.paperID ?? intent.purpose.retryPaperID,
          dismissedPaperIDs.contains(paperID) {
          discardFailure()
        } else {
          state = .failed(safe)
        }
      }
    }
    // Published setters may synchronously request Cancel before this Task exists.
    if startCancellationRequested { operation?.cancel() }
  }

  public func cancelDownload() {
    if starting { startCancellationRequested = true }
    writer?.revoke()
    operation?.cancel()
  }

  /// A retry reopens confirmation, never automatically grants another writer/Job.
  public func retry() throws {
    guard !starting, operation == nil, confirmation == nil,
      case .failed(let reason) = state, let input = lastInput
    else { return }
    guard let purpose = retryPurpose else { throw URLImportError.writerUnavailable }
    try prepare(input, destination: lastDestination, possibleDuplicate: lastDuplicate,
      destinationFolderID: lastDestinationFolderID, purpose: purpose, restoringFailure: reason)
  }
}
