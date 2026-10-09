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

public struct URLImportConfirmation: Identifiable, Sendable {
  public let id: UUID
  public let destination: String
  public let destinationFolderID: UUID?
  public let possibleDuplicate: Bool
  public let sourceKind: String
  fileprivate let route: ValidatedRequestURL
  fileprivate let admission = URLImportAdmission()
  func consumeWriterGrant() -> Bool { admission.grantOnce() }
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
  private var writer: (any URLImportWriter)?
  private var operation: Task<Void, Never>?
  private var lastInput: String?
  private var lastDestination = ""
  private var lastDestinationFolderID: UUID?
  private var lastDuplicate = false

  public init(authority: ProviderRequest,
    grantWriter: (@Sendable (URLImportConfirmation) async throws -> any URLImportWriter)? = nil) {
    adapter = HTTPSPDFImportAdapter(authority: authority)
    grant = grantWriter
  }

  /// Destination and duplicate information come from the actual Library caller.
  /// This method validates only; it performs no Job, network, file, or DB effect.
  public func supports(_ input: String) -> Bool { (try? adapter.route(input)) != nil }

  public func prepare(_ input: String, destination: String, possibleDuplicate: Bool,
    destinationFolderID: UUID? = nil) throws {
    guard operation == nil else { throw URLImportError.rejected }
    let route: ValidatedRequestURL
    do { route = try adapter.route(input) } catch { throw URLImportError.rejected }
    lastInput = input
    lastDestination = destination
    lastDestinationFolderID = destinationFolderID
    lastDuplicate = possibleDuplicate
    confirmation = URLImportConfirmation(id: UUID(), destination: destination,
      destinationFolderID: destinationFolderID, possibleDuplicate: possibleDuplicate,
      sourceKind: route.sourceKind, route: route)
    state = .confirming
  }

  public func cancelConfirmation() {
    guard state == .confirming else { return }
    confirmation?.admission.cancel()
    confirmation = nil
    lastInput = nil
    state = .idle
  }

  public func continueImport(confirmationID: UUID) {
    guard operation == nil, state == .confirming,
      let intent = confirmation, intent.id == confirmationID,
      intent.admission.continueOnce() else { return }
    confirmation = nil // Consume once, before any suspension or effect.
    guard let grant else { state = .failed(.writerUnavailable); return }
    state = .downloading
    operation = Task {
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
            assertCurrent: { try capability.assertCurrent() })
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
        state = .ready(paper) // Library stays put; navigation belongs to explicit UI action.
        lastInput = nil
      } catch {
        var safe = error as? URLImportError ??
          (Task.isCancelled || (error as? LocalLibraryError) == .cancelled ? .cancelled : .rejected)
        if let ownedWriter {
          ownedWriter.revoke()
          do { try await ownedWriter.abort(reason: safe) } catch { safe = .cleanupFailed }
        }
        state = .failed(safe)
      }
      writer = nil
      operation = nil
    }
  }

  public func cancelDownload() {
    writer?.revoke()
    operation?.cancel()
  }

  /// A retry reopens confirmation, never automatically grants another writer/Job.
  public func retry() throws {
    guard case .failed = state, let input = lastInput else { return }
    try prepare(input, destination: lastDestination, possibleDuplicate: lastDuplicate,
      destinationFolderID: lastDestinationFolderID)
  }
}
