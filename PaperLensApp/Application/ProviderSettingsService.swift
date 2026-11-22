import Combine
import Foundation
#if SWIFT_PACKAGE
import ProviderRequest
#endif

/// Retains the current login while one separately owned replacement is verified.
/// SQLite remains the only provider selector.
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
    case cancelled, disconnected, superseded, applicationTermination, failure(String)

    var message: String {
      switch self {
      case .cancelled: return "ChatGPT 연결을 취소했습니다."
      case .disconnected: return "ChatGPT 연결을 해제했습니다."
      case .superseded: return "이전 ChatGPT 연결을 교체했습니다."
      case .applicationTermination: return "앱 종료를 위해 ChatGPT 연결을 닫습니다."
      case .failure(let reason): return reason
      }
    }

    var failed: Bool {
      if case .failure = self { return true }
      return false
    }
  }

  @MainActor private final class LoginScope {
    let namespace: TopologyOwnedFixtures
    let expected: ProviderConfiguration
    let intentID = UUID()
    let stageID = UUID()
    var owner: OwnedChildRetirement?
    var lifecycle: AgentConnectionLifecycle?
    var prepared = false
    var committed: ProviderConfiguration?
    var requests: [UUID: Operation] = [:]
    var ending: Ending?
    var retirementSettled = false
    var retirementWaiter: CheckedContinuation<Void, Never>?

    init(namespace: TopologyOwnedFixtures, expected: ProviderConfiguration) {
      self.namespace = namespace
      self.expected = expected
    }

    var identityParams: [String: Any] {
      ["stageID": stageID.uuidString.lowercased(), "intentID": intentID.uuidString.lowercased()]
    }
  }
  @Published public private(set) var phase: Phase = .idle
  @Published public private(set) var instructions: Instructions?
  @Published public private(set) var message = "브라우저 또는 기기 코드로 ChatGPT에 연결하세요."
  private(set) var loginStorageBlocked: Bool
  public private(set) var intentID: UUID?
  public private(set) var stageID: UUID?
  private let database: ProductDatabase
  private let root: URL
  private let apiKey: NativeAPIKeyConnection
  private var apiKeyObservation: AnyCancellable?
  private let prepareWorker: (TopologyOwnedFixtures) -> OwnedChildRetirement.WorkerLaunch?
  private var candidate: LoginScope?
  private var activeLogin: LoginScope?
  private var predecessor: LoginScope?
  private var ending: Ending?
  private var intendedPhase: Phase = .idle
  private var publishingPhase = false
  private var summaryScopes: [UUID: NativeCodexSummaryScope] = [:]
  // The single admitted setup may leave a bound namespace before any summary worker starts.
  private var summaryNamespaceDebt: (paperID: UUID, namespace: TopologyOwnedFixtures)?
  private(set) var preparingForApplicationTermination = false

  public var summaryRoot: URL { root.deletingLastPathComponent().appendingPathComponent("codex-summary-scopes") }

  public func executeLibrarySummary(_ request: AuthorizedProviderRequest,
    identity: LibrarySummaryIdentity, authority: ProviderRequest) async throws -> ValidatedProviderResult {
    try Task.checkCancellation()
    guard let login = usableActiveLogin, let selected = login.committed,
      selected.generation == identity.configurationGeneration, let model = selected.model,
      request.wire.operation == .librarySummary, summaryScopes.isEmpty,
      summaryNamespaceDebt == nil else { throw LibrarySummaryError.providerUnavailable }
    let raw = try authority.encodeRequest(request)
    guard raw.count <= 49_152 else { throw LibrarySummaryError.invalidResult }
    try IsolatedAgentLibraryPurge.verifySummaryRoot(summaryRoot)
    let requestID = UUID()
    guard let target = TopologyOwnedFixtures(root: summaryRoot, runID: requestID.uuidString.lowercased())
    else { throw LibrarySummaryError.cleanupUnavailable }
    guard let launch = prepareWorker(target), target.prepareRuntimeDirectories(),
      login.namespace.copyLoginAuthentication(to: target) else {
      if !target.cleanupUnlaunchedWorkerNamespace() {
        summaryNamespaceDebt = (identity.paperID, target)
        if target.hasPendingUnlaunchedRemoval { throw LibrarySummaryError.unlaunchedCleanupPending }
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
      removeSummaryScope(requestID)
      guard !scope.isCancelled else { throw CancellationError() }
      guard currentConfiguration == selected, eligibleForEntry else {
        throw LibrarySummaryError.staleIdentity
      }
      try Task.checkCancellation()
      return try authority.wrapModelResult(result, request: request)
    } catch {
      if scope.clean { removeSummaryScope(requestID) }
      throw error
    }
  }

  public func purgeSummaryPaper(paperID: UUID, deletionID: UUID) async throws -> AgentLibraryPurgeReceipt {
    let scopes = summaryScopes.filter { $0.value.paperID == paperID }
    for (id, scope) in scopes {
      await scope.retireAndWait()
      guard scope.clean else { throw LocalLibraryError.producerClosureUnknown }
      removeSummaryScope(id)
    }
    // A different Paper's known namespace may remain. Any unexpected root entry
    // or replacement still prevents a purge receipt.
    if let debt = summaryNamespaceDebt {
      if debt.paperID == paperID {
        guard debt.namespace.cleanupUnlaunchedWorkerNamespace() else {
          throw LocalLibraryError.producerClosureUnknown
        }
        summaryNamespaceDebt = nil
        objectWillChange.send()
        try IsolatedAgentLibraryPurge.verifySummaryRoot(summaryRoot)
      } else {
        try IsolatedAgentLibraryPurge.verifySummaryRoot(summaryRoot, allowing: debt.namespace)
      }
    } else if let other = summaryScopes.values.first(where: { $0.paperID != paperID }) {
      try other.verifyNamespaceForUnrelatedPurge(at: summaryRoot)
    } else {
      try IsolatedAgentLibraryPurge.verifySummaryRoot(summaryRoot)
    }
    return AgentLibraryPurgeReceipt(paperID: paperID, deletionID: deletionID)
  }

  private func removeSummaryScope(_ id: UUID) {
    if summaryScopes.removeValue(forKey: id) != nil, summaryScopes.isEmpty {
      objectWillChange.send()
    }
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
    loginStorageBlocked = TopologyOwnedFixtures.verifyInventory(at: root, allowing: []) == .unverified
    apiKeyObservation = apiKey.$ownerReplacementAvailable.dropFirst().sink { [weak self] _ in
      self?.objectWillChange.send()
    }
  }

  public var currentConfiguration: ProviderConfiguration? { try? database.providerConfiguration() }
  internal var testingOwner: OwnedChildRetirement? { candidate?.owner ?? activeLogin?.owner }

  /// Replacing the coordinator itself must wait for all of its owners to drain.
  public var blocksReplacement: Bool {
    candidate != nil || activeLogin != nil || predecessor != nil
      || !summaryScopes.isEmpty || summaryNamespaceDebt != nil
  }

  public var canStart: Bool {
    guard !loginStorageBlocked, !preparingForApplicationTermination, !publishingPhase, candidate == nil,
      predecessor == nil, summaryNamespaceDebt == nil,
      apiKey.canReplaceOwner else { return false }
    if activeLogin == nil { return phase == .idle && summaryScopes.isEmpty }
    return phase == .connected && eligibleForEntry
  }

  var hasPendingLogin: Bool {
    guard let candidate else { return false }
    return candidate.ending == nil && candidate.prepared
  }

  var canDisconnect: Bool {
    guard !preparingForApplicationTermination, let activeLogin,
      activeLogin.ending == nil, let owner = activeLogin.owner,
      owner.terminal == nil else { return false }
    return candidate == nil || phase == .blocked
  }

  private var savedConnectionNeedsLogin: Bool {
    phase == .idle && ending == nil && currentConfiguration?.kind == .codexChatGPT
  }

  var statusMessage: String {
    if loginStorageBlocked {
      let blocked = "이전 ChatGPT 전용 저장소의 상태를 확인할 수 없어 새 로그인을 중단했습니다."
      return blocksReplacement ? blocked : "\(blocked) OpenAI API 키를 연결할 수 있습니다."
    }
    return savedConnectionNeedsLogin
      ? "저장된 ChatGPT 연결을 사용할 수 없습니다. 다시 로그인하거나 OpenAI API 키를 연결하세요."
      : message
  }

  var showsFailure: Bool {
    loginStorageBlocked || phase == .blocked || ending?.failed == true || savedConnectionNeedsLogin
  }
  var offersRetry: Bool {
    guard !loginStorageBlocked else { return false }
    if savedConnectionNeedsLogin { return true }
    switch ending {
    case .cancelled, .applicationTermination, .failure:
      return candidate == nil && (phase == .idle || phase == .connected)
    case .disconnected, .superseded, nil: return false
    }
  }

  public var eligibleForEntry: Bool { usableActiveLogin != nil }

  var configurationAvailableForAPIKeyPromotion: ProviderConfiguration? {
    guard candidate == nil, predecessor == nil, summaryNamespaceDebt == nil else { return nil }
    return usableActiveLogin?.committed
  }

  func retireAfterAPIKeyPromotion(replacing expected: ProviderConfiguration,
    winner: APIKeySelection) {
    guard let activeLogin, activeLogin.committed == expected,
      currentConfiguration == ProviderConfiguration(kind: .openAIAPIKey,
        slotID: winner.slotID, generation: winner.configGeneration, model: apiKey.configuration.model)
    else { return }
    retire(activeLogin, because: .superseded, sendCancel: true)
  }

  private var usableActiveLogin: LoginScope? {
    guard !preparingForApplicationTermination, let login = activeLogin,
      login.ending == nil, let owner = login.owner,
      owner.core.allowsIO, login.lifecycle?.connection.state == .ready,
      let committed = login.committed, committed.kind == .codexChatGPT,
      committed.slotID?.uuidString.lowercased() == login.namespace.runID,
      currentConfiguration == committed else { return nil }
    return login
  }

  public func connect(mode: String) {
    guard canStart, mode == "browser" || mode == "device" else { return }
    if let reason = loginStorageFailure() { return reportFailure(reason) }
    ending = nil
    guard let expected = currentConfiguration,
      let model = apiKey.configuration.model.nilIfEmpty else {
      reportFailure("저장된 Provider 설정을 읽지 못했습니다.")
      return
    }
    guard let namespace = TopologyOwnedFixtures(root: root, runID: UUID().uuidString.lowercased()) else {
      reportFailure("전용 로그인 저장소를 준비하지 못했습니다.")
      return
    }
    let login = LoginScope(namespace: namespace, expected: expected)
    if let reason = loginStorageFailure(staging: namespace) {
      if namespace.cleanupUnlaunchedWorkerNamespace() {
        reportFailure(reason)
      } else {
        candidate = login
        block(login, "아직 시작하지 않은 로그인 저장소를 정리하지 못했습니다.")
      }
      return
    }
    // Retain setup failures until their namespace closure can be proved.
    candidate = login
    intentID = login.intentID
    stageID = login.stageID
    guard let worker = prepareWorker(namespace) else {
      block(login, "서명된 로그인 구성 요소 또는 비백업 저장소를 준비하지 못했습니다.")
      return
    }
    login.prepared = true
    publishPhase(.starting)
    guard login.ending == nil else { return }
    message = "전용 ChatGPT 프로세스를 시작하고 있습니다."
    guard login.ending == nil else { return }
    let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
    let owner = OwnedChildRetirement(worker: worker, deadlineUptimeNanoseconds: deadline)
    login.owner = owner
    owner.observeTerminal { [weak self, weak login] terminal in
      Task { @MainActor in
        guard let self, let login else { return }
        self.finish(login, terminal: terminal)
      }
    }
    owner.startProduct(startDeadlineUptimeNanoseconds: deadline) { [weak self, weak login] result in
      guard let self, let login, self.candidate === login, let owner = login.owner,
        owner.terminal == nil else { return }
      switch result {
      case .failure:
        self.fail(login, "ChatGPT 연결 프로세스를 시작하지 못했습니다.")
        owner.retire()
      case .success(let lifecycle):
        login.lifecycle = lifecycle
        guard login.ending == nil else { owner.retire(); return }
        lifecycle.onTerminal = { [weak self, weak login] id, terminal in
          guard let self, let login else { return }
          self.receive(login, id: id, terminal: terminal)
        }
        var params = login.identityParams
        params["mode"] = mode
        params["model"] = model
        params["expectedSelector"] = self.selector(login.expected)
        self.send(.login(mode: mode), method: "product.loginStart", params: params, for: login)
      }
    }
  }

  /// Renew only the current intent's observation. The shared channel/session owns
  /// request and traffic limits; observation adds no polling interval or expiry.
  public func checkLogin() {
    guard let intentID else { return }
    checkLogin(intentID: intentID)
  }

  func checkLogin(intentID: UUID) {
    guard intendedPhase == .signingIn, let candidate, candidate.intentID == intentID,
      candidate.ending == nil else { return }
    if let reason = loginStorageFailure(staging: candidate.namespace) { return fail(candidate, reason) }
    publishPhase(.observing)
    send(.observe, method: "product.loginObserve", params: candidate.identityParams, for: candidate)
  }

  func loginPageURL(intentID: UUID) -> URL? {
    guard intendedPhase == .signingIn || intendedPhase == .observing,
      let candidate, candidate.intentID == intentID, fenced(candidate) else { return nil }
    return instructions?.url
  }

  private func loginStorageFailure(staging namespace: TopologyOwnedFixtures? = nil) -> String? {
    let unverified = "이전 ChatGPT 전용 저장소의 상태를 확인하지 못했습니다."
    if loginStorageBlocked { return unverified }
    let active = activeLogin
    let owned = [active?.namespace, namespace].compactMap { $0 }
    let mayBeAbsent: (TopologyOwnedFixtures) -> Bool = { missing in
      guard let active, active.namespace === missing, let owner = active.owner else { return false }
      // The background owner can unlink the directory before MainActor receives its receipt.
      return !owner.core.allowsIO
    }
    var inventory = TopologyOwnedFixtures.verifyInventory(at: root, allowing: owned,
      mayBeAbsent: mayBeAbsent)
    if inventory == .changed {
      inventory = TopologyOwnedFixtures.verifyInventory(at: root, allowing: owned,
        mayBeAbsent: mayBeAbsent)
    }
    switch inventory {
    case .verified:
      return nil
    case .changed:
      return "확인 중 로그인 저장소가 변경되었습니다. 다시 시도하세요."
    case .unverified:
      loginStorageBlocked = true
      return unverified
    }
  }

  public func cancel() {
    if hasPendingLogin { cancelUncommittedLogin() }
    else { disconnect() }
  }

  func cancelUncommittedLogin() {
    guard hasPendingLogin, let candidate else { return }
    retire(candidate, because: .cancelled, sendCancel: true)
  }

  func disconnect() {
    guard canDisconnect, let activeLogin else { return }
    retire(activeLogin, because: .disconnected, sendCancel: true)
    for scope in summaryScopes.values { scope.cancel() }
  }

  /// Fence admission before requesting all retirements. The app keeps each owner
  /// until its actual terminal and leaves the durable selection for the next launch.
  func retireForApplicationTermination() async -> Bool {
    guard !preparingForApplicationTermination else { return false }
    preparingForApplicationTermination = true
    objectWillChange.send()
    let logins = [candidate, activeLogin, predecessor].compactMap { $0 }
    let summaries = summaryScopes
    for login in logins { retire(login, because: .applicationTermination, sendCancel: true) }
    for scope in summaries.values { scope.cancel() }
    for login in logins where login.owner != nil && !login.retirementSettled {
      await withCheckedContinuation { login.retirementWaiter = $0 }
    }
    for (id, scope) in summaries {
      await scope.retireAndWait()
      if scope.clean { removeSummaryScope(id) }
    }
    return !blocksReplacement
  }

  func cancelApplicationTermination() {
    preparingForApplicationTermination = false
    objectWillChange.send()
  }

  private func selector(_ value: ProviderConfiguration) -> [String: Any] {
    [
      "kind": value.kind.map { $0.rawValue as Any } ?? NSNull(),
      "slotID": value.slotID.map { $0.uuidString.lowercased() as Any } ?? NSNull(),
      "generation": value.generation, "model": value.model.map { $0 as Any } ?? NSNull(),
    ]
  }

  private func fenced(_ login: LoginScope) -> Bool {
    candidate === login && login.ending == nil && login.owner?.terminal == nil
      && login.lifecycle?.connection.state == .ready && currentConfiguration == login.expected
  }

  private func send(_ operation: Operation, method: String, params: [String: Any], for login: LoginScope) {
    guard candidate === login, login.ending == nil else { return }
    guard fenced(login), let lifecycle = login.lifecycle else { return fail(login) }
    do {
      // MainActor request does not suspend; correlation is installed before the writer can run.
      let id = try lifecycle.request(method: method, params: params, timeoutMs: 10_000)
      login.requests[id] = operation
    } catch { fail(login) }
  }

  private func receive(_ login: LoginScope, id: UUID, terminal: AgentRPCConnection.Terminal) {
    guard candidate === login, login.ending == nil,
      let operation = login.requests.removeValue(forKey: id) else { return }
    if case .failure(let failure) = terminal {
      switch failure {
      case .timeout, .remote("timeout"):
        fail(login, "ChatGPT 응답을 기다리다 시간이 초과되었습니다.")
      case .remote("cancelled"):
        fail(login, "ChatGPT 요청이 취소되었습니다.")
      default:
        if case .probe = operation { fail(login, "ChatGPT 연결 테스트에 실패했습니다.") }
        else { fail(login, "ChatGPT 로그인 응답을 확인하지 못했습니다.") }
      }
      return
    }
    guard fenced(login), case .result(let result) = terminal,
      result["stageID"] as? String == login.stageID.uuidString.lowercased(),
      result["intentID"] as? String == login.intentID.uuidString.lowercased() else { return fail(login) }
    switch operation {
    case .login(let requestedMode):
      guard let value = result["instructions"] as? [String: Any],
        let mode = value["mode"] as? String, mode == requestedMode,
        let address = value[mode == "browser" ? "authUrl" : "verificationUrl"] as? String,
        let url = URL(string: address), url.scheme == "https", url.host != nil,
        mode == "browser" || (mode == "device" && value["userCode"] is String)
      else { return fail(login) }
      instructions = Instructions(url: url, userCode: value["userCode"] as? String)
      guard login.ending == nil else { instructions = nil; return }
      publishPhase(.signingIn)
      guard login.ending == nil else { return }
      message = "로그인을 마친 뒤 ‘로그인 완료 확인’을 선택하세요. 인증 완료 후 실제 생성 검사에 사용량이 발생할 수 있습니다."
    case .observe:
      switch result["state"] as? String {
      case "pending": publishPhase(.signingIn)
      case "authenticated":
        instructions = nil
        if let reason = loginStorageFailure(staging: login.namespace) { return fail(login, reason) }
        guard login.ending == nil else { return }
        publishPhase(.probing)
        guard login.ending == nil else { return }
        message = "인증된 세션에서 실제 PAPERLENS_OK 생성 응답을 확인합니다."
        var params = login.identityParams
        params["expectedSelector"] = selector(login.expected)
        send(.probe, method: "product.connectionTest", params: params, for: login)
      case "failed": fail(login, "ChatGPT 로그인에 실패했습니다.")
      case "cancelled": fail(login, "ChatGPT 로그인 요청이 취소되었습니다.")
      case "timeout": fail(login, "ChatGPT 로그인을 기다리다 시간이 초과되었습니다.")
      case "exited": fail(login, "ChatGPT 로그인 프로세스가 종료되었습니다.")
      default: fail(login)
      }
    case .probe:
      promote(login, result: result)
    }
  }

  private func promote(_ login: LoginScope, result: [String: Any]) {
    guard result["state"] as? String == "usable", result["text"] as? String == "PAPERLENS_OK",
      let observed = result["expectedSelector"] as? [String: Any],
      NSDictionary(dictionary: observed).isEqual(to: selector(login.expected)), fenced(login),
      let slotID = UUID(uuidString: login.namespace.runID) else { return fail(login) }
    if let reason = loginStorageFailure(staging: login.namespace) { return fail(login, reason) }
    do {
      login.committed = try database.compareAndSwapProviderConfiguration(expected: login.expected,
        replacementKind: .codexChatGPT, replacementSlotID: slotID, replacementModel: apiKey.configuration.model)
    } catch { return fail(login, "새 Provider 설정을 저장하지 못했습니다.") }

    // Own the winner before publishing, including synchronous Settings dismissal.
    let previous = activeLogin
    activeLogin = login
    candidate = nil
    predecessor = previous
    if let previous { retire(previous, because: .superseded, sendCancel: true) }
    do {
      try apiKey.retireSupersededSelection()
    } catch {
      // The durable selector already points to this independently validated login.
      guard login.ending == nil else { return }
      reportFailure("이전 API 키의 안전한 정리를 확인하지 못해 Provider 교체가 차단되었습니다.")
      return
    }
    guard login.ending == nil else { return }
    ending = nil
    if let previous {
      if case .unknown = previous.owner?.terminal {
        let reason = "새 ChatGPT 연결을 적용했습니다. 이전 연결의 정리를 확인하지 못해 다음 교체가 차단됩니다."
        ending = .failure(reason)
        message = reason
      } else {
        message = "새 ChatGPT 연결을 적용했습니다. 이전 연결의 프로세스와 전용 저장소를 정리합니다."
      }
    } else {
      message = "ChatGPT 연결이 완료되었습니다. Library에서 논문 요약을 생성할 수 있습니다."
    }
    if login.ending == nil { publishPhase(.connected) }
  }

  private func fail(_ login: LoginScope, _ reason: String = "ChatGPT 연결을 검증하지 못했습니다.") {
    retire(login, because: .failure(reason), sendCancel: false)
  }

  private func retire(_ login: LoginScope, because reason: Ending, sendCancel: Bool) {
    guard login.ending == nil else { return }
    // Fence result handling before any synchronous publication or cancellation callback.
    login.ending = reason
    login.requests.removeAll()
    if predecessor !== login {
      instructions = nil
      ending = reason
      publishPhase(.retiring)
      message = "\(reason.message) 프로세스 종료와 전용 저장소 정리를 확인하고 있습니다."
    }
    guard let owner = login.owner else {
      if login.namespace.cleanupUnlaunchedWorkerNamespace() { completeCleanLogin(login) }
      else { block(login, "아직 시작하지 않은 로그인 저장소를 정리하지 못했습니다.") }
      return
    }
    // If cancellation wins during startup, let the already admitted startup
    // report its handoff so the owner can retire without dispatching login.
    guard let lifecycle = login.lifecycle else { return }
    if sendCancel, lifecycle.connection.state == .ready {
      owner.retire(cancelling: lifecycle, params: login.identityParams)
    } else {
      owner.retire()
    }
  }

  private func finish(_ login: LoginScope, terminal: OwnedChildRetirement.Terminal) {
    defer {
      login.retirementSettled = true
      let waiter = login.retirementWaiter
      login.retirementWaiter = nil
      waiter?.resume()
    }
    guard candidate === login || activeLogin === login || predecessor === login else { return }
    guard case .clean = terminal else {
      block(login, "프로세스 또는 전용 저장소 정리를 확인하지 못했습니다.")
      return
    }
    completeCleanLogin(login)
  }

  private func completeCleanLogin(_ login: LoginScope) {
    if case .disconnected = login.ending, let committed = login.committed {
      do {
        // Process loss retires the login scope but only explicit disconnect clears its selection.
        if try database.providerConfiguration() == committed {
          _ = try database.compareAndSwapProviderConfiguration(expected: committed,
            replacementKind: nil, replacementSlotID: nil, replacementModel: nil)
        }
      } catch {
        block(login, "저장된 Provider 선택을 갱신하지 못했습니다.")
        return
      }
    }
    if predecessor === login {
      predecessor = nil
      if phase == .connected {
        message = "새 ChatGPT 연결을 사용 중입니다. 이전 전용 로그인 저장소 정리를 완료했습니다."
      } else if activeLogin == nil, candidate == nil {
        publishPhase(.idle)
        message = "이전 전용 로그인 저장소 정리를 완료했습니다."
      }
      return
    }
    if activeLogin === login {
      activeLogin = nil
      // The candidate has its own UI and will recheck the captured selector.
      if candidate?.ending == nil, candidate != nil {
        objectWillChange.send()
        return
      }
    }
    if candidate === login { candidate = nil }
    let reason = login.ending ?? .failure("ChatGPT 연결 프로세스가 종료되었습니다.")
    instructions = nil
    ending = reason
    if candidate != nil || predecessor != nil || (activeLogin != nil && !eligibleForEntry) {
      publishPhase(.blocked)
    } else {
      publishPhase(eligibleForEntry ? .connected : .idle)
    }
    message = "\(reason.message) 전용 로그인 저장소 정리를 완료했습니다."
  }

  private func reportFailure(_ reason: String) {
    ending = .failure(reason)
    publishPhase(eligibleForEntry ? .connected : .idle)
    message = reason
  }

  private func block(_ login: LoginScope, _ reason: String) {
    let failure = Ending.failure("\(reason) 정리를 확인할 때까지 재연결과 Provider 교체가 차단됩니다.")
    login.ending = failure
    if activeLogin === login, candidate?.ending == nil, candidate != nil {
      objectWillChange.send()
      return
    }
    ending = failure
    if predecessor !== login {
      instructions = nil
      publishPhase(.blocked)
    }
    message = failure.message
  }

  private func publishPhase(_ next: Phase) {
    // A synchronous observer may close Settings while a candidate phase is emitted.
    // Commit the latest phase after the outer notification finishes.
    intendedPhase = next
    guard !publishingPhase else { return }
    publishingPhase = true
    defer { publishingPhase = false }
    while phase != intendedPhase { phase = intendedPhase }
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
  private let namespace: TopologyOwnedFixtures
  private let owner: OwnedChildRetirement
  private let params: [String: Any]
  private var lifecycle: AgentConnectionLifecycle?
  private var requestID: UUID?
  private var outcome: Result<Data, any Error>?
  private var continuation: CheckedContinuation<Data, any Error>?
  private var waiters: [CheckedContinuation<Void, Never>] = []
  private var terminalReceived = false
  private(set) var clean = false
  private(set) var isCancelled = false

  init(launch: OwnedChildRetirement.WorkerLaunch, paperID: UUID, params: [String: Any]) {
    self.paperID = paperID; self.params = params
    namespace = launch.namespace
    owner = OwnedChildRetirement(worker: launch,
      deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 5_000_000_000)
  }

  func verifyNamespaceForUnrelatedPurge(at root: URL) throws {
    switch owner.terminal {
    case .clean:
      try IsolatedAgentLibraryPurge.verifySummaryRoot(root)
    case .unknown:
      throw LocalLibraryError.producerClosureUnknown
    case nil:
      do {
        try IsolatedAgentLibraryPurge.verifySummaryRoot(root, allowing: namespace)
      } catch {
        // The background owner can complete retirement during the scan.
        guard case .clean = owner.terminal else { throw error }
        try IsolatedAgentLibraryPurge.verifySummaryRoot(root)
      }
      if case .unknown = owner.terminal { throw LocalLibraryError.producerClosureUnknown }
    }
  }

  func execute() async throws -> Data {
    let result: Data = try await withTaskCancellationHandler {
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
    // Purge is independent of the caller task and can revoke a buffered success
    // while the process and its namespace are still retiring.
    guard !isCancelled else { throw CancellationError() }
    try Task.checkCancellation()
    return result
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

  func cancel() {
    isCancelled = true
    fail(CancellationError())
  }

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
  public var activeSelection: APIKeySelection? {
    guard let selected = savedConfiguration else { return nil }
    return connection.usableSelection(for: selected)
  }
  public var eligibleForEntry: Bool {
    guard let selected = savedConfiguration else { return false }
    return isAvailable(selected)
  }
  public var currentProviderLabel: String {
    guard let selected = savedConfiguration else { return "확인 불가" }
    return providerLabel(selected.kind)
  }
  private var savedConfiguration: ProviderConfiguration? {
    if let codex { return codex.currentConfiguration }
    return connection.savedConfiguration
  }
  private func isAvailable(_ selected: ProviderConfiguration) -> Bool {
    switch selected.kind {
    case .codexChatGPT: return codex?.eligibleForEntry == true
    case .openAIAPIKey: return connection.usableSelection(for: selected) != nil
    case nil: return false
    }
  }
  private func providerLabel(_ kind: ProviderKind?) -> String {
    switch kind {
    case .codexChatGPT: return "ChatGPT"
    case .openAIAPIKey: return "OpenAI API"
    case nil: return "없음"
    }
  }
  var keyStorageBlocked: Bool { connection.storageBlocked }
  public var candidatesBlocked: Bool {
    if keyStorageBlocked { return true }
    guard let codex else { return false }
    return codex.preparingForApplicationTermination
      || (codex.blocksReplacement && codex.configurationAvailableForAPIKeyPromotion == nil)
  }
  public var model: String { connection.configuration.model }
  public var isTesting: Bool { connection.hasUncommittedProbe }
  public var availabilityMessage: String {
    guard let selected = savedConfiguration else { return "저장된 Provider 상태를 확인할 수 없습니다." }
    if isAvailable(selected) { return "현재 \(providerLabel(selected.kind)) 연결을 사용할 수 있습니다." }
    return "현재 선택을 사용할 수 없습니다. 명시적으로 연결 상태를 확인하세요."
  }
  public func restore() {
    guard !isTesting else { return }
    connection.restore(preservingRetryableFailure: true)
  }
  public func reconnect(key: String) {
    guard !keyStorageBlocked, codex?.preparingForApplicationTermination != true else { return }
    guard let codex, codex.blocksReplacement else { return connection.connect(key: key) }
    guard let expected = codex.configurationAvailableForAPIKeyPromotion else { return }
    connection.connect(key: key, replacing: expected) { [weak codex] winner in
      codex?.retireAfterAPIKeyPromotion(replacing: expected, winner: winner)
    }
  }
  public func cancel() { connection.cancel() }
  func cancelUncommittedConnections() {
    connection.cancelUncommittedProbe()
    codex?.cancelUncommittedLogin()
  }
  public func candidateEdited() { if isTesting { connection.invalidateCandidate() } }
  public func acquireLease() throws -> APIKeyConnectionLease { try connection.acquireLease() }
  public func mayPublish(_ lease: APIKeyConnectionLease) throws -> Bool {
    try connection.mayPublish(lease)
  }
  public func releaseAfterTermination(_ lease: APIKeyConnectionLease) throws {
    try connection.releaseAfterTermination(lease)
  }
}
