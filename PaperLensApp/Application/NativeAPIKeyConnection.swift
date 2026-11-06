import Combine
import Foundation

#if SWIFT_PACKAGE
  import ProviderRequest
#endif

public enum APIKeyConnectionError: Error, Equatable, Sendable {
  case invalidKey, invalidConfiguration, unsupportedProfile, unsafeStorage, cleanupBlocked
  case authentication, rateLimited, providerUnavailable, transport, deadline, invalidResponse
  case cancelled, staleCandidate, persistenceUnavailable, selectorConflict, persistenceFailure

  public var koreanMessage: String {
    switch self {
    case .invalidKey: return "API 키를 확인해 주세요. 공백 없이 입력해야 합니다."
    case .invalidConfiguration: return "지원되는 엔드포인트와 명시적인 모델 설정이 필요합니다."
    case .unsupportedProfile: return "이 모델의 실제 제한 적용은 아직 검증되지 않았습니다."
    case .unsafeStorage: return "키 저장소의 소유권, 권한 또는 백업 제외를 확인할 수 없습니다."
    case .cleanupBlocked: return "키 저장소의 안전한 정리가 확인되지 않아 새 연결을 차단합니다."
    case .authentication: return "API 키 인증에 실패했습니다. 키를 확인하고 다시 시도해 주세요."
    case .rateLimited: return "요청 한도에 도달했습니다. 잠시 후 다시 시도해 주세요."
    case .providerUnavailable: return "서비스가 연결 요청을 처리하지 못했습니다."
    case .transport: return "네트워크 연결을 확인하고 다시 시도해 주세요."
    case .deadline: return "연결 확인 시간이 초과되었습니다."
    case .invalidResponse: return "연결 확인 응답이 정해진 형식과 일치하지 않습니다."
    case .cancelled: return "연결 확인을 취소했습니다."
    case .staleCandidate: return "변경된 연결 요청입니다. 다시 시도해 주세요."
    case .persistenceUnavailable: return "연결 선택 저장소가 연결되지 않았습니다."
    case .selectorConflict: return "다른 연결이 먼저 저장되었습니다. 다시 시도해 주세요."
    case .persistenceFailure: return "연결 선택을 안전하게 저장하지 못했습니다."
    }
  }
}

public struct APIKeySelection: Equatable, Sendable {
  public let slotID: UUID
  public let configGeneration: Int64
  public init(slotID: UUID, configGeneration: Int64) {
    self.slotID = slotID
    self.configGeneration = configGeneration
  }
}

/// The product DB adapter owns the only selector. CAS and generation allocation MUST
/// occur in one durable transaction; nil means comparison failed (never a local winner).
/// These synchronous calls do not suspend Application's winner/lease serialization.
@MainActor
public protocol APIKeySelectorPersistence: AnyObject {
  func currentSelection() throws -> APIKeySelection?
  func selectionMatchesConfiguration(_ configuration: NativeOpenAIConfiguration) throws -> Bool
  func compareAndSwap(expected: APIKeySelection?, slotID: UUID) throws -> APIKeySelection?
}

public struct NativeOpenAIConfiguration: Equatable, Sendable {
  public static let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!
  public let model: String
  public init(model: String, endpoint: URL = NativeOpenAIConfiguration.endpoint) throws {
    guard endpoint == Self.endpoint, !model.isEmpty, model.utf8.count <= 128,
      model.utf8.allSatisfy({
        (65...90).contains($0) || (97...122).contains($0)
          || (48...57).contains($0) || $0 == 45 || $0 == 46 || $0 == 95
      })
    else { throw APIKeyConnectionError.invalidConfiguration }
    self.model = model
  }

  /// Explicit wire configuration is not actual tokenizer/model/profile certification.
  public func requireCertifiedEnforcement() throws {
    throw APIKeyConnectionError.unsupportedProfile
  }
}

public enum NativeProbeEvidence: Equatable, Sendable {
  case authenticatedGenerationResponse
  case deterministicFixture
}
public struct NativeProbeResponse: Sendable {
  public let result: ValidatedProviderResult
  public let evidence: NativeProbeEvidence
  public init(result: ValidatedProviderResult, evidence: NativeProbeEvidence) {
    self.result = result
    self.evidence = evidence
  }
}
@MainActor
public protocol NativeConnectionTestTransport {
  func probe(
    key: String, configuration: NativeOpenAIConfiguration,
    request: AuthorizedProviderRequest, authority: ProviderRequest
  ) async throws -> NativeProbeResponse
}

/// Probe semantics over the same completion-owned HTTP machinery used for generation.
@MainActor
public final class URLSessionOpenAIConnectionTransport: NativeConnectionTestTransport {
  private let generation: URLSessionOpenAIGenerationTransport
  public init(configuration: URLSessionConfiguration = .ephemeral) {
    generation = URLSessionOpenAIGenerationTransport(configuration: configuration)
  }

  public func probe(
    key: String, configuration: NativeOpenAIConfiguration,
    request: AuthorizedProviderRequest, authority: ProviderRequest
  ) async throws -> NativeProbeResponse {
    guard !Task.isCancelled else { throw APIKeyConnectionError.cancelled }
    guard request.wire.operation == .connectionTest else {
      throw APIKeyConnectionError.invalidConfiguration
    }
    let result = try await generation.execute(
      key: key, configuration: configuration, request: request, authority: authority)
    return NativeProbeResponse(result: result, evidence: .authenticatedGenerationResponse)
  }
}

@MainActor
fileprivate final class APIKeyLeaseRetention {
  var ownership: APIKeySlotOwnership?
  init(ownership: APIKeySlotOwnership) { self.ownership = ownership }
}

public struct APIKeyConnectionLease: Equatable, Sendable {
  public let id: UUID
  public let selection: APIKeySelection
  fileprivate let retention: APIKeyLeaseRetention

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.id == rhs.id && lhs.selection == rhs.selection && lhs.retention === rhs.retention
  }
}
public enum APIKeyConnectionPhase: Equatable, Sendable {
  case idle, probing
  case connected(APIKeySelection)
  case failed(APIKeyConnectionError)
}

@MainActor
public final class NativeAPIKeyConnection: ObservableObject {
  @Published public private(set) var phase: APIKeyConnectionPhase = .idle
  @Published public private(set) var activeSelection: APIKeySelection?
  @Published public private(set) var eligibleForEntry = false
  public let configuration: NativeOpenAIConfiguration
  private let slots: APIKeySlotStore
  private let persistence: (any APIKeySelectorPersistence)?
  private let transport: any NativeConnectionTestTransport
  private let authority: ProviderRequest
  private var intent = UUID()
  private var running: Task<Void, Never>?
  private var probes: Set<UUID> = []
  private var retired: Set<UUID> = []
  private var leases: [UUID: APIKeySelection] = [:]
  private var storageBlocked = false
  // Unlike unsafe storage, unresolved unselected ownership does not revoke a
  // separately validated last-good selection. It denies all replacement.
  private var unresolvedSlots = false
  private var ownerRetired = false

  /// Cancellation acceptance does not release transport or consumer references.
  public var canReplaceOwner: Bool {
    !ownerRetired && !storageBlocked && !unresolvedSlots
      && probes.isEmpty && leases.isEmpty && retired.isEmpty
  }

  /// MainActor arbitration fences all future references before a replacement exists.
  public func retireAfterDrain() throws {
    guard canReplaceOwner else { throw APIKeyConnectionError.staleCandidate }
    ownerRetired = true
    intent = UUID()
    running?.cancel()
    running = nil
    eligibleForEntry = false
    phase = .failed(.staleCandidate)
  }

  public init(
    configuration: NativeOpenAIConfiguration, slots: APIKeySlotStore,
    persistence: (any APIKeySelectorPersistence)?,
    transport: any NativeConnectionTestTransport, authority: ProviderRequest
  ) {
    self.configuration = configuration
    self.slots = slots
    self.persistence = persistence
    self.transport = transport
    self.authority = authority
  }

  /// Startup never replays a probe or infers a selection from files. Only recorded
  /// crash orphans under the store's exclusive lifetime lock can be removed.
  public func restore() {
    eligibleForEntry = false
    do {
      guard !ownerRetired else { throw APIKeyConnectionError.staleCandidate }
      guard !storageBlocked else { throw APIKeyConnectionError.cleanupBlocked }
      guard let persistence else { throw APIKeyConnectionError.persistenceUnavailable }
      try slots.validate()
      let selected = try persistence.currentSelection()
      if let selected {
        guard selected.configGeneration > 0 else { throw APIKeyConnectionError.persistenceFailure }
        guard try persistence.selectionMatchesConfiguration(configuration) else {
          throw APIKeyConnectionError.unsupportedProfile
        }
        _ = try slots.read(selected.slotID)
      }
      try reconcileSlotInventory(selected: selected)
      activeSelection = selected
      eligibleForEntry = selected != nil
      phase = unresolvedSlots ? .failed(.cleanupBlocked)
        : selected.map(APIKeyConnectionPhase.connected) ?? .idle
    } catch {
      activeSelection = nil
      fail(error)
    }
  }

  private func reconcileSlotInventory(selected: APIKeySelection?) throws {
    var known = probes.union(retired)
    known.formUnion(leases.values.map(\.slotID))
    if let selected { known.insert(selected.slotID) }
    try slots.reconcileStartup(preserving: known)
    let inventory = try slots.validatedSlotIDs()
    if !inventory.subtracting(known).isEmpty {
      // Reading valid files does not adopt them. Do not enqueue unknown slots in
      // retired: that queue authorizes unlink after this owner's references drain.
      // Keep the barrier even if a later scan no longer sees the unknown file.
      unresolvedSlots = true
    }
  }

  /// Retire only a selection actually superseded in the sole durable selector.
  /// Existing consumers retain their key until their real termination releases the lease.
  public func retireSupersededSelection() throws {
    guard let persistence else { throw APIKeyConnectionError.persistenceUnavailable }
    guard let previous = activeSelection else { return }
    guard try persistence.currentSelection() != previous else {
      throw APIKeyConnectionError.selectorConflict
    }
    retired.insert(previous.slotID)
    activeSelection = nil
    eligibleForEntry = false
    phase = .idle
    do { try drainRetired() } catch {
      storageBlocked = true
      phase = .failed(.cleanupBlocked)
      throw APIKeyConnectionError.cleanupBlocked
    }
  }

  /// Edits invalidate intent immediately, even when the user has not pressed Retry.
  public func invalidateCandidate() {
    guard !ownerRetired else { return }
    intent = UUID()
    running?.cancel()
    running = nil
    phase = unresolvedSlots ? .failed(.cleanupBlocked)
      : activeSelection.map(APIKeyConnectionPhase.connected) ?? .idle
  }
  public func cancel() {
    invalidateCandidate()
    phase = .failed(.cancelled)
  }
  public func connect(key: String) {
    guard !ownerRetired else {
      fail(APIKeyConnectionError.staleCandidate)
      return
    }
    invalidateCandidate()
    let attempt = intent
    phase = .probing
    running = Task { [weak self] in
      guard let self else { return }
      await self.perform(key: key, attempt: attempt)
    }
  }

  private func perform(key: String, attempt: UUID) async {
    var staged: UUID?
    do {
      try Task.checkCancellation()
      guard intent == attempt else { throw APIKeyConnectionError.staleCandidate }
      guard !storageBlocked else { throw APIKeyConnectionError.cleanupBlocked }
      guard let persistence else { throw APIKeyConnectionError.persistenceUnavailable }
      let expected = try persistence.currentSelection()
      try reconcileSlotInventory(selected: expected)
      guard !unresolvedSlots else {
        // Preserve validated last-good availability; no stage or request is made.
        phase = .failed(.cleanupBlocked)
        return
      }
      let slot = try slots.create(key: key)
      staged = slot
      probes.insert(slot)
      phase = .probing
      let context = try TrustedRequestContext(authority: authority, sources: .connectionTest)
      let request = try authority.buildRequest(
        sources: .connectionTest, context: context,
        requestID: UUID().uuidString.lowercased())
      let stagedKey = try slots.read(slot)
      guard stagedKey == key else { throw APIKeyConnectionError.unsafeStorage }
      let response = try await transport.probe(
        key: stagedKey, configuration: configuration,
        request: request, authority: authority)
      try Task.checkCancellation()
      guard intent == attempt else { throw APIKeyConnectionError.staleCandidate }
      guard response.evidence == .authenticatedGenerationResponse else {
        throw APIKeyConnectionError.authentication
      }
      let validated = try authority.validateResult(
        ProviderRequest.canonicalBytes(response.result.value), request: request)
      guard validated.result == .connectionTest("PAPERLENS_OK") else {
        throw APIKeyConnectionError.invalidResponse
      }
      try reconcileSlotInventory(selected: try persistence.currentSelection())
      guard try slots.read(slot) == stagedKey else { throw APIKeyConnectionError.unsafeStorage }
      // No suspension between final validation, CAS and publication.
      guard !unresolvedSlots else { throw APIKeyConnectionError.cleanupBlocked }
      guard let winner = try persistence.compareAndSwap(expected: expected, slotID: slot) else {
        throw APIKeyConnectionError.selectorConflict
      }
      // CAS returning a malformed receipt is ambiguous: keep the staged secret and block.
      guard winner.slotID == slot, winner.configGeneration > (expected?.configGeneration ?? 0),
        try persistence.currentSelection() == winner,
        try persistence.selectionMatchesConfiguration(configuration)
      else {
        staged = nil
        storageBlocked = true
        throw APIKeyConnectionError.persistenceFailure
      }
      probes.remove(slot)
      staged = nil
      activeSelection = winner
      eligibleForEntry = true
      phase = .connected(winner)
      if let expected { retired.insert(expected.slotID) }
      try drainRetired()
    } catch {
      if let staged {
        probes.remove(staged)
        if let persistence, (try? persistence.currentSelection())?.slotID == staged {
          // A commit can be ambiguous even when its adapter throws. Never delete or
          // publish a possibly selected candidate on the strength of that error.
          storageBlocked = true
          eligibleForEntry = false
          phase = .failed(.persistenceFailure)
          return
        }
        retired.insert(staged)
        do { try drainRetired() } catch {
          storageBlocked = true
          eligibleForEntry = false
          phase = .failed(.cleanupBlocked)
          return
        }
      }
      if attempt == intent {
        if unresolvedSlots, !storageBlocked, error as? APIKeyConnectionError == .cleanupBlocked {
          phase = .failed(.cleanupBlocked)
        } else {
          fail(error)
        }
      }
    }
  }

  private func fail(_ error: Error) {
    let safe: APIKeyConnectionError
    if let typed = error as? APIKeyConnectionError {
      safe = typed
    } else if error is CancellationError {
      safe = .cancelled
    } else if error is RequestContractError {
      safe = .invalidResponse
    } else {
      safe = .persistenceFailure
    }
    if safe == .unsafeStorage || safe == .cleanupBlocked || storageBlocked {
      storageBlocked = true
      eligibleForEntry = false
    }
    phase = .failed(safe)
  }

  public func acquireLease() throws -> APIKeyConnectionLease {
    guard !ownerRetired, !storageBlocked, eligibleForEntry, let persistence,
      let selection = try persistence.currentSelection(), selection == activeSelection,
      try persistence.selectionMatchesConfiguration(configuration)
    else {
      throw APIKeyConnectionError.persistenceUnavailable
    }
    do { _ = try slots.read(selection.slotID) } catch {
      fail(error)
      throw error
    }
    let lease = APIKeyConnectionLease(id: UUID(), selection: selection,
      retention: APIKeyLeaseRetention(ownership: slots.ownership))
    leases[lease.id] = selection
    return lease
  }
  public func key(for lease: APIKeyConnectionLease) throws -> String {
    guard !storageBlocked else { throw APIKeyConnectionError.cleanupBlocked }
    guard leases[lease.id] == lease.selection else { throw APIKeyConnectionError.staleCandidate }
    do { return try slots.read(lease.selection.slotID) } catch {
      fail(error)
      throw error
    }
  }
  public func mayPublish(_ lease: APIKeyConnectionLease) throws -> Bool {
    guard !ownerRetired, !storageBlocked, let persistence else { return false }
    do { try slots.validate() } catch {
      fail(error)
      throw error
    }
    let selected = try persistence.currentSelection()
    let modelMatches = try persistence.selectionMatchesConfiguration(configuration)
    return leases[lease.id] == lease.selection && selected == lease.selection
      && modelMatches
  }
  /// Invoke only after the caller's transport/work has really terminated, not on cancel acceptance.
  public func releaseAfterTermination(_ lease: APIKeyConnectionLease) throws {
    guard leases[lease.id] == lease.selection else { throw APIKeyConnectionError.staleCandidate }
    leases.removeValue(forKey: lease.id)
    lease.retention.ownership = nil
    do { try drainRetired() } catch {
      storageBlocked = true
      eligibleForEntry = false
      phase = .failed(.cleanupBlocked)
      throw APIKeyConnectionError.cleanupBlocked
    }
  }
  private func drainRetired() throws {
    guard let persistence else { throw APIKeyConnectionError.persistenceUnavailable }
    let selected = try persistence.currentSelection()?.slotID
    for id in Array(retired)
    where id != selected && !probes.contains(id)
      && !leases.values.contains(where: { $0.slotID == id })
    {
      try slots.remove(id)
      retired.remove(id)
    }
  }
}
