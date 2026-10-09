import Combine
import Foundation

/// A safe Settings projection of the shared Application connection owner.
/// The owner, not this feature, stages secrets and commits the durable selector.
@MainActor
public final class ProviderSettingsService: ObservableObject {
  private let connection: NativeAPIKeyConnection
  private var observation: AnyCancellable?

  public init(connection: NativeAPIKeyConnection) {
    self.connection = connection
    observation = connection.objectWillChange.sink { [weak self] in
      self?.objectWillChange.send()
    }
  }

  public var phase: APIKeyConnectionPhase { connection.phase }
  public var activeSelection: APIKeySelection? { connection.activeSelection }
  public var eligibleForEntry: Bool { connection.eligibleForEntry }
  public var model: String { connection.configuration.model }
  public var isTesting: Bool { phase == .probing }

  public var availabilityMessage: String {
    if eligibleForEntry {
      return isTesting ? "기존 연결을 유지하며 새 연결을 확인합니다." : "현재 OpenAI API 연결을 사용할 수 있습니다."
    }
    return activeSelection == nil
      ? "사용 가능한 연결이 없습니다. API 키로 연결을 확인하세요."
      : "저장된 연결을 현재 사용할 수 없습니다. 연결 상태를 확인하세요."
  }

  /// Restoring is local validation only; never sends a probe or retries Paper work.
  /// An already running shared candidate must not be overwritten by opening Settings.
  public func restore() {
    guard !isTesting else { return }
    connection.restore()
  }

  public func reconnect(key: String) { connection.connect(key: key) }
  public func cancel() { connection.cancel() }

  public func candidateEdited() {
    // Keep terminal errors (particularly cleanup debt) visible while editing.
    if isTesting { connection.invalidateCandidate() }
  }

  public func acquireLease() throws -> APIKeyConnectionLease {
    try connection.acquireLease()
  }

  public func mayPublish(_ lease: APIKeyConnectionLease) throws -> Bool {
    try connection.mayPublish(lease)
  }

  /// Caller must prove actual termination, not merely cancellation acceptance.
  public func releaseAfterTermination(_ lease: APIKeyConnectionLease) throws {
    try connection.releaseAfterTermination(lease)
  }
}
