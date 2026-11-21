import Combine
import Foundation
#if SWIFT_PACKAGE
import ProviderRequest
#endif

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
  private enum Operation { case login(mode: String), observe, probe }
  private enum Ending {
    case cancelled, disconnected, failure(String)

    var message: String {
      switch self {
      case .cancelled: return "ChatGPT 연결을 취소했습니다."
      case .disconnected: return "ChatGPT 연결을 해제했습니다."
      case .failure(let reason): return reason
      }
    }

    var failed: Bool {
      if case .failure = self { return true }
      return false
    }
  }
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
  private var ending: Ending?
  private var cancelled = false
  private var retirementRequested = false
  private var summaryScopes: [UUID: NativeCodexSummaryScope] = [:]
  private var summaryNamespaceDebt: [TopologyOwnedFixtures] = []

  public var summaryRoot: URL { root.deletingLastPathComponent().appendingPathComponent("codex-summary-scopes") }

  public func executeLibrarySummary(_ request: AuthorizedProviderRequest,
    identity: LibrarySummaryIdentity, authority: ProviderRequest) async throws -> ValidatedProviderResult {
    try Task.checkCancellation()
    guard eligibleForEntry, let loginNamespace = namespace, let selected = committed,
      selected.generation == identity.configurationGeneration, let model = selected.model,
      request.wire.operation == .librarySummary, summaryScopes.isEmpty,
      summaryNamespaceDebt.isEmpty else { throw LibrarySummaryError.providerUnavailable }
    let raw = try authority.encodeRequest(request)
    guard raw.count <= 49_152 else { throw LibrarySummaryError.invalidResult }
    try IsolatedAgentLibraryPurge.requireEmptySummaryRoot(summaryRoot)
    let requestID = UUID()
    guard let target = TopologyOwnedFixtures(root: summaryRoot, runID: requestID.uuidString.lowercased())
    else { throw LibrarySummaryError.cleanupUnavailable }
    guard let launch = prepareWorker(target), target.prepareRuntimeDirectories(),
      loginNamespace.copyLoginAuthentication(to: target) else {
      if !target.cleanupUnlaunchedWorkerNamespace() {
        summaryNamespaceDebt.append(target)
        throw LibrarySummaryError.cleanupUnavailable
      }
      throw LibrarySummaryError.providerUnavailable
    }
    let params: [String: Any] = ["requestID": request.wire.requestID,
      "paperID": identity.paperID.uuidString.lowercased(),
      "paperGeneration": identity.requestPaperGeneration,
      "configGeneration": identity.configurationGeneration, "model": model,
      "requestJSON": String(decoding: raw, as: UTF8.self)]
    let scope = NativeCodexSummaryScope(launch: launch, paperID: identity.paperID, params: params)
    summaryScopes[requestID] = scope
    do {
      let result = try await scope.execute()
      summaryScopes.removeValue(forKey: requestID)
      guard currentConfiguration == selected, eligibleForEntry else {
        throw LibrarySummaryError.staleIdentity
      }
      try Task.checkCancellation()
      return try authority.wrapModelResult(result, request: request)
    } catch {
      if scope.clean { summaryScopes.removeValue(forKey: requestID) }
      throw error
    }
  }

  public func purgeSummaryPaper(paperID: UUID, deletionID: UUID) async throws -> AgentLibraryPurgeReceipt {
    guard summaryNamespaceDebt.isEmpty else { throw LocalLibraryError.producerClosureUnknown }
    let scopes = summaryScopes.filter { $0.value.paperID == paperID }
    for (id, scope) in scopes {
      await scope.retireAndWait()
      guard scope.clean else { throw LocalLibraryError.producerClosureUnknown }
      summaryScopes.removeValue(forKey: id)
    }
    try IsolatedAgentLibraryPurge.requireEmptySummaryRoot(summaryRoot)
    return AgentLibraryPurgeReceipt(paperID: paperID, deletionID: deletionID)
  }

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
  public var blocksReplacement: Bool {
    namespace != nil || owner != nil || !summaryScopes.isEmpty || !summaryNamespaceDebt.isEmpty
  }
  public var canStart: Bool { !blocksReplacement && apiKey.canReplaceOwner }
  var showsFailure: Bool { phase == .blocked || ending?.failed == true }
  var offersRetry: Bool {
    guard phase == .idle, let ending else { return false }
    if case .disconnected = ending { return false }
    return true
  }
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
    ending = nil
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
            self.message = self.endMessage(
              followedBy: "프로세스 또는 전용 저장소 정리를 확인하지 못해 재연결과 Provider 교체가 차단됩니다.")
          case .clean:
            do {
              if self.ending == nil {
                self.ending = .failure("ChatGPT 연결 프로세스가 종료되었습니다.")
              }
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
              self.retirementRequested = false
              self.phase = .idle
              self.message = self.endMessage(followedBy: "전용 로그인 저장소 정리를 완료했습니다.")
            } catch {
              self.phase = .blocked
              self.message = self.endMessage(
                followedBy: "저장된 Provider 선택을 갱신하지 못했습니다. 설정을 확인하세요.")
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
          self.failClosed("ChatGPT 연결 프로세스를 시작하지 못했습니다.")
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
          self.send(.login(mode: mode), method: "product.loginStart", params: params)
        }
      }
    } catch { failClosed("저장된 Provider 설정을 읽지 못했습니다.") }
  }

  /// Renew only the current intent's observation. The shared channel/session owns
  /// request and traffic limits; observation adds no polling interval or expiry.
  public func checkLogin() {
    guard phase == .signingIn else { return }
    guard fenced else {
      failClosed("현재 로그인 요청을 확인할 수 없습니다.")
      return
    }
    phase = .observing
    send(.observe, method: "product.loginObserve", params: identityParams)
  }

  public func cancel() {
    guard owner != nil, !retirementRequested else { return }
    ending = phase == .connected ? .disconnected : .cancelled
    cancelled = true
    instructions = nil
    phase = .retiring
    message = "로그인 취소와 종료를 요청했습니다. 실제 정리는 아직 입증되지 않았습니다."
    retirementRequested = true
    for scope in summaryScopes.values { scope.cancel() }
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
    guard let operation = requests.removeValue(forKey: id) else { return }
    guard !cancelled, !retirementRequested else { return }
    if case .failure(let failure) = terminal {
      switch failure {
      case .timeout, .remote("timeout"):
        failClosed("ChatGPT 응답을 기다리다 시간이 초과되었습니다.")
      case .remote("cancelled"):
        failClosed("ChatGPT 요청이 취소되었습니다.")
      default:
        if case .probe = operation { failClosed("ChatGPT 연결 테스트에 실패했습니다.") }
        else { failClosed("ChatGPT 로그인 응답을 확인하지 못했습니다.") }
      }
      return
    }
    guard fenced, case .result(let result) = terminal,
      result["stageID"] as? String == stageID?.uuidString.lowercased(),
      result["intentID"] as? String == intentID?.uuidString.lowercased()
    else {
      failClosed()
      return
    }
    switch operation {
    case .login(let requestedMode):
      guard let value = result["instructions"] as? [String: Any],
        let mode = value["mode"] as? String, mode == requestedMode,
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
      case "failed": failClosed("ChatGPT 로그인에 실패했습니다.")
      case "cancelled": failClosed("ChatGPT 로그인 요청이 취소되었습니다.")
      case "timeout": failClosed("ChatGPT 로그인을 기다리다 시간이 초과되었습니다.")
      case "exited": failClosed("ChatGPT 로그인 프로세스가 종료되었습니다.")
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
          "ChatGPT 연결이 완료되었습니다. Library에서 논문 요약을 생성할 수 있습니다."
      } catch {
        failClosed(committed == nil
          ? "새 Provider 설정을 저장하지 못했습니다."
          : "새 설정을 저장한 뒤 이전 키를 정리하지 못해 연결을 중단했습니다.")
      }
    }
  }

  private func endMessage(followedBy status: String) -> String {
    guard let ending else { return status }
    return "\(ending.message) \(status)"
  }

  private func failClosed(_ reason: String = "ChatGPT 연결을 검증하지 못했습니다.") {
    guard !retirementRequested else { return }
    instructions = nil
    ending = .failure(reason)
    if let owner, owner.terminal == nil {
      retirementRequested = true
      phase = .retiring
      message = endMessage(followedBy: "재연결 전에 프로세스와 전용 저장소를 정리합니다.")
      owner.retire()
    } else if blocksReplacement {
      phase = .blocked
      message = endMessage(followedBy: "정리를 확인할 때까지 재연결을 차단합니다.")
    } else {
      expected = nil
      phase = .idle
      message = endMessage(followedBy: "다시 연결할 수 있습니다.")
    }
  }
}

extension String {
  fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// Safe projection of the shared owners, never a second selector or credential store.
/// Each request owns a real worker. A wire result is retained until native
/// termination, waitpid, transport closure and namespace removal have completed.
@MainActor
internal final class NativeCodexSummaryScope {
  let paperID: UUID
  private let owner: OwnedChildRetirement
  private let params: [String: Any]
  private var lifecycle: AgentConnectionLifecycle?
  private var requestID: UUID?
  private var outcome: Result<Data, any Error>?
  private var continuation: CheckedContinuation<Data, any Error>?
  private var waiters: [CheckedContinuation<Void, Never>] = []
  private var terminalReceived = false
  private(set) var clean = false

  init(launch: OwnedChildRetirement.WorkerLaunch, paperID: UUID, params: [String: Any]) {
    self.paperID = paperID; self.params = params
    owner = OwnedChildRetirement(worker: launch,
      deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 5_000_000_000)
  }

  func execute() async throws -> Data {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        self.continuation = continuation
        owner.observeTerminal { [weak self] terminal in
          Task { @MainActor in self?.finished(terminal) }
        }
        owner.startProduct(startDeadlineUptimeNanoseconds:
          DispatchTime.now().uptimeNanoseconds + 5_000_000_000) { [self] result in
          switch result {
          case .failure: fail(LibrarySummaryError.providerUnavailable)
          case .success(let lifecycle):
            guard outcome == nil, !terminalReceived else { owner.retire(); return }
            self.lifecycle = lifecycle
            lifecycle.onTerminal = { [self] id, terminal in receive(id, terminal: terminal) }
            do {
              requestID = try lifecycle.request(method: "product.librarySummary", params: params,
                timeoutMs: 120_000)
            } catch { fail(error) }
          }
        }
      }
    } onCancel: {
      Task { @MainActor [self] in cancel() }
    }
  }

  private func receive(_ id: UUID, terminal: AgentRPCConnection.Terminal) {
    guard id == requestID, outcome == nil else { return }
    if case .failure(let error) = terminal { fail(error); return }
    guard case .result(let result) = terminal,
      let json = result["resultJSON"] as? String, json.utf8.count <= 32_768 else {
      fail(LibrarySummaryError.invalidResult); return
    }
    var expected = params
    expected.removeValue(forKey: "requestJSON")
    var actual = result
    actual.removeValue(forKey: "resultJSON")
    guard NSDictionary(dictionary: expected).isEqual(to: actual) else {
      fail(LibrarySummaryError.staleIdentity); return
    }
    outcome = .success(Data(json.utf8))
    owner.retire()
  }

  private func fail(_ error: any Error) {
    if outcome == nil { outcome = .failure(error) }
    owner.retire()
  }

  func cancel() { fail(CancellationError()) }

  func retireAndWait() async {
    cancel()
    if terminalReceived { return }
    await withCheckedContinuation { waiters.append($0) }
  }

  private func finished(_ terminal: OwnedChildRetirement.Terminal) {
    guard !terminalReceived else { return }
    terminalReceived = true
    if case .clean = terminal { clean = true }
    let result: Result<Data, any Error> = clean
      ? outcome ?? .failure(LibrarySummaryError.providerUnavailable)
      : .failure(LibrarySummaryError.cleanupUnavailable)
    lifecycle = nil
    let pending = continuation; continuation = nil
    pending?.resume(with: result)
    let waiting = waiters; waiters.removeAll()
    for waiter in waiting { waiter.resume() }
  }
}

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
