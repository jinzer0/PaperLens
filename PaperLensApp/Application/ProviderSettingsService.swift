import Combine
import Foundation

/// One user-triggered private SDK scope. SQLite remains the only provider selector.
@MainActor
public final class NativeCodexConnection: ObservableObject {
  public enum Phase: Equatable {
    case idle, starting, signingIn, observing, probing, connected, retiring, blocked
  }
  public struct Instructions: Equatable {
    public let url: URL
    public let userCode: String?
  }
  private enum Operation { case login, observe, probe }
  @Published public private(set) var phase: Phase = .idle
  @Published public private(set) var instructions: Instructions?
  @Published public private(set) var message = "브라우저 또는 기기 코드로 ChatGPT에 연결하세요."
  public private(set) var intentID: UUID?
  public private(set) var stageID: UUID?
  private let database: ProductDatabase
  private let root: URL
  private let apiKey: NativeAPIKeyConnection
  private let prepareWorker: (TopologyOwnedFixtures) -> OwnedChildRetirement.WorkerLaunch?
  private var namespace: TopologyOwnedFixtures?
  private var owner: OwnedChildRetirement?
  private var lifecycle: AgentConnectionLifecycle?
  private var expected: ProviderConfiguration?
  private var committed: ProviderConfiguration?
  private var requests: [UUID: Operation] = [:]
  private var results: [UUID: AgentRPCConnection.Terminal] = [:]
  private var cancelled = false
  private var retirementRequested = false

  public convenience init(database: ProductDatabase, root: URL, apiKey: NativeAPIKeyConnection) {
    self.init(
      database: database, root: root, apiKey: apiKey,
      prepareWorker: { $0.prepareBundledWorker(mainBundle: Bundle.main.bundleURL) })
  }

  // Internal dependency injection uses the same real namespace/process owner.
  // Production always selects the validated embedded bundle above.
  internal init(
    database: ProductDatabase, root: URL, apiKey: NativeAPIKeyConnection,
    prepareWorker: @escaping (TopologyOwnedFixtures) -> OwnedChildRetirement.WorkerLaunch?
  ) {
    self.database = database
    self.root = root
    self.apiKey = apiKey
    self.prepareWorker = prepareWorker
  }

  public var currentConfiguration: ProviderConfiguration? { try? database.providerConfiguration() }
  internal var testingOwner: OwnedChildRetirement? { owner }
  /// Even a successful login cannot authorize a second SDK scope or a provider switch.
  public var blocksReplacement: Bool { namespace != nil || owner != nil }
  public var canStart: Bool { !blocksReplacement && apiKey.canReplaceOwner }
  public var eligibleForEntry: Bool {
    guard phase == .connected, !cancelled, !retirementRequested,
      let owner, owner.terminal == nil, let lifecycle,
      lifecycle.connection.state == .ready, let committed,
      committed.kind == .codexChatGPT,
      committed.slotID?.uuidString.lowercased() == namespace?.runID,
      currentConfiguration == committed
    else { return false }
    return true
  }

  public func connect(mode: String) {
    guard canStart, mode == "browser" || mode == "device" else { return }
    do {
      cancelled = false
      retirementRequested = false
      expected = try database.providerConfiguration()
      guard let model = apiKey.configuration.model.nilIfEmpty else { return }
      intentID = UUID()
      stageID = UUID()
      phase = .starting
      message = "전용 ChatGPT 프로세스를 시작하고 있습니다."
      let runID = UUID().uuidString.lowercased()
      guard let namespace = TopologyOwnedFixtures(root: root, runID: runID) else {
        phase = .blocked
        message = "전용 로그인 저장소를 준비하지 못했습니다."
        return
      }
      // Retain even setup failures: metadata/namespace cleanup is not fabricated.
      self.namespace = namespace
      guard let worker = prepareWorker(namespace) else {
        phase = .blocked
        message = "서명된 로그인 구성 요소 또는 비백업 저장소를 준비하지 못했습니다. 정리가 입증되지 않아 새 연결을 차단합니다."
        return
      }
      let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
      let owner = OwnedChildRetirement(worker: worker, deadlineUptimeNanoseconds: deadline)
      self.owner = owner
      let intent = intentID
      owner.observeTerminal { [weak self, weak owner] terminal in
        Task { @MainActor in
          guard let self, let owner, self.owner === owner else { return }
          self.instructions = nil
          switch terminal {
          case .unknown:
            self.phase = .blocked
            self.message = "ChatGPT 프로세스 또는 전용 저장소 정리를 확인하지 못했습니다. 재연결과 Provider 교체가 차단됩니다."
          case .clean:
            do {
              let selected = try self.database.providerConfiguration()
              if selected.kind == .codexChatGPT,
                selected.slotID?.uuidString.lowercased() == self.namespace?.runID {
                _ = try self.database.compareAndSwapProviderConfiguration(expected: selected,
                  replacementKind: nil, replacementSlotID: nil, replacementModel: nil)
              }
              self.lifecycle = nil
              self.owner = nil
              self.namespace = nil
              self.committed = nil
              self.expected = nil
              self.requests.removeAll()
              self.results.removeAll()
              self.retirementRequested = false
              self.phase = .idle
              self.message = "ChatGPT 프로세스 종료와 전용 저장소 정리를 완료했습니다. 다시 연결할 수 있습니다."
            } catch {
              self.phase = .blocked
              self.message = "ChatGPT 정리는 끝났지만 저장된 선택을 갱신하지 못했습니다. 다시 연결하기 전에 설정을 확인하세요."
            }
          }
        }
      }
      owner.startProduct(startDeadlineUptimeNanoseconds: deadline) {
        [weak self, weak owner] result in
        guard let self, let owner, self.owner === owner,
          self.intentID == intent, !self.cancelled, owner.terminal == nil
        else { return }
        switch result {
        case .failure:
          self.failClosed()
        case .success(let lifecycle):
          self.lifecycle = lifecycle
          lifecycle.onTerminal = { [weak self, weak lifecycle] id, terminal in
            guard let self, let lifecycle, self.lifecycle === lifecycle else { return }
            self.receive(id, terminal: terminal)
          }
          guard self.fenced else {
            self.failClosed()
            return
          }
          var params = self.identityParams
          params["mode"] = mode
          params["model"] = model
          params["expectedSelector"] = self.selector(self.expected!)
          self.send(.login, method: "product.loginStart", params: params)
        }
      }
    } catch { failClosed() }
  }

  /// Renew only the current intent's observation. The shared channel/session owns
  /// request and traffic limits; observation adds no polling interval or expiry.
  public func checkLogin() {
    guard phase == .signingIn, fenced else { return }
    phase = .observing
    send(.observe, method: "product.loginObserve", params: identityParams)
  }

  public func cancel() {
    guard owner != nil, !retirementRequested else { return }
    cancelled = true
    instructions = nil
    phase = .retiring
    message = "로그인 취소와 종료를 요청했습니다. 실제 정리는 아직 입증되지 않았습니다."
    retirementRequested = true
    // Only the final cancel frame retains bounded owner admission. Local publication
    // is fenced already; SDK cancellation acceptance is never retirement proof.
    if let lifecycle, lifecycle.connection.state == .ready, stageID != nil {
      owner?.retire(cancelling: lifecycle, params: identityParams)
    } else {
      owner?.retire()
    }
  }

  private var identityParams: [String: Any] {
    guard let stageID, let intentID else { return [:] }
    return [
      "stageID": stageID.uuidString.lowercased(), "intentID": intentID.uuidString.lowercased(),
    ]
  }
  private func selector(_ value: ProviderConfiguration) -> [String: Any] {
    [
      "kind": value.kind.map { $0.rawValue as Any } ?? NSNull(),
      "slotID": value.slotID.map { $0.uuidString.lowercased() as Any } ?? NSNull(),
      "generation": value.generation, "model": value.model.map { $0 as Any } ?? NSNull(),
    ]
  }
  private var fenced: Bool {
    !cancelled && !retirementRequested && owner?.terminal == nil && owner != nil
      && lifecycle?.connection.state == .ready && expected != nil
      && currentConfiguration == expected
  }
  private func send(_ operation: Operation, method: String, params: [String: Any]) {
    guard let lifecycle else {
      failClosed()
      return
    }
    do {
      // MainActor request does not suspend; correlation is installed before the writer can run.
      let id = try lifecycle.request(method: method, params: params, timeoutMs: 10_000)
      requests[id] = operation
    } catch { failClosed() }
  }
  private func receive(_ id: UUID, terminal: AgentRPCConnection.Terminal) {
    guard let operation = requests[id] else { return }
    results[id] = terminal
    guard !cancelled, !retirementRequested, fenced else {
      if !retirementRequested { failClosed() }
      return
    }
    guard case .result(let result) = terminal,
      result["stageID"] as? String == stageID?.uuidString.lowercased(),
      result["intentID"] as? String == intentID?.uuidString.lowercased()
    else {
      failClosed()
      return
    }
    switch operation {
    case .login:
      guard let value = result["instructions"] as? [String: Any],
        let mode = value["mode"] as? String,
        let address = value[mode == "browser" ? "authUrl" : "verificationUrl"] as? String,
        let url = URL(string: address), url.scheme == "https", url.host != nil,
        mode == "browser" || (mode == "device" && value["userCode"] is String)
      else {
        failClosed()
        return
      }
      instructions = Instructions(url: url, userCode: value["userCode"] as? String)
      phase = .signingIn
      message = "로그인을 마친 뒤 ‘로그인 완료 확인’을 선택하세요. 인증 완료 후 실제 생성 검사에 사용량이 발생할 수 있습니다."
    case .observe:
      switch result["state"] as? String {
      case "pending": phase = .signingIn
      case "authenticated":
        instructions = nil
        phase = .probing
        message = "인증된 세션에서 실제 PAPERLENS_OK 생성 응답을 확인합니다."
        var params = identityParams
        params["expectedSelector"] = selector(expected!)
        send(.probe, method: "product.connectionTest", params: params)
      default: failClosed()
      }
    case .probe:
      guard result["state"] as? String == "usable", result["text"] as? String == "PAPERLENS_OK",
        let observed = result["expectedSelector"] as? [String: Any], let expected,
        NSDictionary(dictionary: observed).isEqual(to: selector(expected)), fenced,
        let slotID = namespace.flatMap({ UUID(uuidString: $0.runID) })
      else {
        failClosed()
        return
      }
      do {
        committed = try database.compareAndSwapProviderConfiguration(
          expected: expected,
          replacementKind: .codexChatGPT, replacementSlotID: slotID,
          replacementModel: apiKey.configuration.model)
        try apiKey.retireSupersededSelection()
        phase = .connected
        message =
          "ChatGPT 생성 검사와 선택 저장이 완료되었습니다. 일반 논문 추론은 아직 제공되지 않습니다."
      } catch { failClosed() }
    }
  }
  private func failClosed() {
    instructions = nil
    phase = .blocked
    message =
      committed == nil
      ? "연결을 검증하거나 저장하지 못했습니다. 이전 Provider 선택은 유지됩니다. SDK 정리가 입증될 때까지 새 연결을 차단합니다."
      : "새 선택은 저장됐지만 이전 키 정리를 완료하지 못해 연결을 중단했습니다. SDK 정리가 입증될 때까지 새 연결을 차단합니다."
    if !retirementRequested, let owner {
      retirementRequested = true
      owner.retire()
    }
  }
}

extension String {
  fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// Safe projection of the shared owners, never a second selector or credential store.
@MainActor
public final class ProviderSettingsService: ObservableObject {
  private let connection: NativeAPIKeyConnection
  public let codex: NativeCodexConnection?
  private var observation: AnyCancellable?
  private var codexObservation: AnyCancellable?

  public init(connection: NativeAPIKeyConnection, codex: NativeCodexConnection? = nil) {
    self.connection = connection
    self.codex = codex
    observation = connection.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
    codexObservation = codex?.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
  }
  public var phase: APIKeyConnectionPhase { connection.phase }
  public var activeSelection: APIKeySelection? { connection.activeSelection }
  public var eligibleForEntry: Bool {
    if let codex, codex.currentConfiguration?.kind == .codexChatGPT {
      return codex.eligibleForEntry
    }
    return connection.eligibleForEntry
  }
  public var currentProviderLabel: String {
    if let codex {
      switch codex.currentConfiguration?.kind {
      case .codexChatGPT: return "ChatGPT"
      case .openAIAPIKey: return "OpenAI API"
      case nil: return "없음"
      }
    }
    return activeSelection == nil ? "없음" : "OpenAI API"
  }
  public var candidatesBlocked: Bool { codex?.blocksReplacement == true }
  public var model: String { connection.configuration.model }
  public var isTesting: Bool { phase == .probing }
  public var availabilityMessage: String {
    if eligibleForEntry { return "현재 \(currentProviderLabel) 연결을 사용할 수 있습니다." }
    return "현재 선택을 사용할 수 없습니다. 명시적으로 연결 상태를 확인하세요."
  }
  public func restore() {
    guard !isTesting else { return }
    connection.restore()
  }
  public func reconnect(key: String) {
    guard !candidatesBlocked else { return }
    connection.connect(key: key)
  }
  public func cancel() { connection.cancel() }
  public func candidateEdited() { if isTesting { connection.invalidateCandidate() } }
  public func acquireLease() throws -> APIKeyConnectionLease { try connection.acquireLease() }
  public func mayPublish(_ lease: APIKeyConnectionLease) throws -> Bool {
    try connection.mayPublish(lease)
  }
  public func releaseAfterTermination(_ lease: APIKeyConnectionLease) throws {
    try connection.releaseAfterTermination(lease)
  }
}
