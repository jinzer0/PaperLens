// Pure admission/accounting only. Commands run outside arbitration; no command is durable proof.
public enum JobRecoveryPolicy {
  public enum Role: CaseIterable, Equatable {
    case `import`, parsing, translation, chatPreparation, chatRequest, brief, librarySummary
  }

  // Opaque versions are supplied by the class owner; this policy defines no input schema.
  public enum Input: Equatable {
    case source(version: String)
    case parser(version: String)
    case translation(version: String)
    case chatPreparation(version: String)
    case chatRequest(version: String)
    case brief(version: String, templateGeneration: String)
    case librarySummary(version: String)

    public var role: Role {
      switch self {
      case .source: return .import
      case .parser: return .parsing
      case .translation: return .translation
      case .chatPreparation: return .chatPreparation
      case .chatRequest: return .chatRequest
      case .brief: return .brief
      case .librarySummary: return .librarySummary
      }
    }

    fileprivate var valid: Bool {
      switch self {
      case .source(let v), .parser(let v), .translation(let v), .chatPreparation(let v),
        .chatRequest(let v), .librarySummary(let v):
        return !v.isEmpty
      case .brief(let v, let generation): return !v.isEmpty && !generation.isEmpty
      }
    }
  }

  public enum Config: Equatable {
    case inapplicable
    case generation(String)
  }

  public struct Paper: Equatable {
    public let id: String
    public let generation: String
    public init(id: String, generation: String) {
      self.id = id
      self.generation = generation
    }
  }

  public struct Authority: Equatable {
    public let input: Input
    public let config: Config
    public let paper: Paper
    public let epoch: String
    public let prerequisitesAvailable: Bool
    public init(
      input: Input, config: Config, paper: Paper, epoch: String,
      prerequisitesAvailable: Bool
    ) {
      self.input = input
      self.config = config
      self.paper = paper
      self.epoch = epoch
      self.prerequisitesAvailable = prerequisitesAvailable
    }
  }

  // The caller reserves all three identities before submitting an event. No allocator is implied.
  public struct Reservation: Equatable {
    public let attempt: String
    public let fence: String
    public let correlation: String
    public init(attempt: String, fence: String, correlation: String) {
      self.attempt = attempt
      self.fence = fence
      self.correlation = correlation
    }
  }

  public struct Lineage: Equatable {
    public let job: String
    public let reservation: Reservation
    public let captured: Authority
    public init(job: String, reservation: Reservation, captured: Authority) {
      self.job = job
      self.reservation = reservation
      self.captured = captured
    }
  }

  public enum Failure: Equatable { case failed, cancelled, timeout, interrupted, paperDeleting }
  public enum State: Equatable { case pending, running, succeeded, failed(Failure) }
  public enum Dispatch: Equatable { case none, intentRecorded, mayHaveSent }
  public struct Result: Equatable {
    public let id: String
    public init(id: String) { self.id = id }
  }
  // These are class-owner attestations, not payload validation or physical closure performed here.
  public enum Stage: Equatable { case unvalidated, validated(Result) }
  public enum Closure: Equatable { case unknown, open, closed(Stage) }
  public enum PermitKind: Equatable { case writer, publication }
  public enum PublicationPhase: Equatable { case acquired, renaming, renamed, committed }
  public enum Cleanup: Equatable { case none, required, requested, failed, cleaned }

  // Caller-reserved invocation identity and immutable filesystem target, not execution proof.
  public struct Operation: Equatable {
    public let id: String
    public let paper: Paper
    public init(id: String, paper: Paper) {
      self.id = id
      self.paper = paper
    }
  }

  public struct Permit: Equatable {
    public let id: String
    public let owner: Lineage
    public let kind: PermitKind
    public let closure: Closure
    public let stage: Stage
    public let phase: PublicationPhase
    public let cleanup: Cleanup
    public let cleanupOperation: Operation?
    public let revoked: Bool
  }

  public struct Execution: Equatable {
    public let lineage: Lineage
    public let state: State
    public let dispatch: Dispatch
    public let result: Result?
  }

  public struct UsableResult: Equatable {
    public let lineage: Lineage
    public let result: Result
    public init(lineage: Lineage, result: Result) {
      self.lineage = lineage
      self.result = result
    }
  }

  public struct Snapshot: Equatable {
    public let job: String
    public let role: Role
    public let authority: Authority
    public let executions: [Execution]
    public let usableResult: UsableResult?
    public let permits: [Permit]
    public let usedPermitIDs: [String]
    public let revoked: Bool
    public let usedOperationIDs: [String]
    public let pendingRemoval: Operation?
    public let removalDebt: Paper?
    public let removedPapers: [Paper]
    public var removalRequested: Bool { pendingRemoval != nil }
    public var namespaceRemoved: Bool { removedPapers.contains(authority.paper) }
    public var current: Execution { executions[executions.count - 1] }
  }

  public enum Event: Equatable {
    case authorityChanged(Authority)
    case claim(Lineage)
    case startup(currentEpoch: String)
    case dispatch(Lineage)
    case sendMayHaveHappened(Lineage)
    case terminate(Lineage, Failure)
    case retry(Reservation, Authority)
    case acquireWriter(Lineage, permit: String)
    case writerClosure(Lineage, permit: String, Closure)
    case acquirePublication(Lineage, writer: String, permit: String)
    case rename(Lineage, permit: String)
    case renameFinished(Lineage, permit: String, succeeded: Bool)
    case publish(Lineage, permit: String, Result)
    case revoke
    case requestCleanup(Lineage, permit: String, operation: String)
    case cleanupFinished(Lineage, permit: String, operation: Operation, succeeded: Bool)
    case release(Lineage, permit: String)
    case removeNamespace(operation: String)
    case namespaceRemovalFinished(operation: Operation, succeeded: Bool)
  }

  public enum Command: Equatable {
    case recordDispatchIntent(Lineage)
    case send(Lineage)
    case cancel(Lineage)
    case acquirePermit(Lineage, String, PermitKind)
    case releasePermit(Lineage, String)
    case rename(Lineage, String, Result)
    case commit(Lineage, String, Result)
    case awaitClosure(Lineage, String)
    case removeOwnedBytes(Lineage, String, Operation)
    case removeNamespace(Operation)
  }

  public enum Rejection: Error, Equatable {
    case invalidIdentity, invalidApplicability, prerequisitesUnavailable, reservationUnavailable
    case state, job, attempt, fence, correlation, input, config, paper, epoch, revoked
    case dispatchAlreadyAdmitted, permitOwnership, permitIdentity, permitKind
    case stageNotValidated, closureUnknown, invalidTransition, cleanupOutstanding
    case malformedResult, resultMismatch, resultAlreadyCommitted, permitsOutstanding,
      removalNotRequested
    case operationIdentity, operationMismatch, removalOutstanding
  }

  public struct Decision: Equatable {
    public let snapshot: Snapshot
    public let commands: [Command]
    public let rejection: Rejection?
  }

  public static func create(
    job: String, role: Role, authority: Authority, reservation: Reservation
  ) throws -> Snapshot {
    guard !job.isEmpty else { throw Rejection.invalidIdentity }
    if let error = validate(authority, role: role) { throw error }
    guard fresh(reservation, history: []) else { throw Rejection.reservationUnavailable }
    let lineage = Lineage(job: job, reservation: reservation, captured: authority)
    return Snapshot(
      job: job, role: role, authority: authority,
      executions: [Execution(lineage: lineage, state: .pending, dispatch: .none, result: nil)],
      usableResult: nil, permits: [], usedPermitIDs: [], revoked: false,
      usedOperationIDs: [], pendingRemoval: nil, removalDebt: nil, removedPapers: [])
  }

  private static func validate(_ authority: Authority, role: Role) -> Rejection? {
    guard authority.input.role == role, authority.input.valid else { return .invalidApplicability }
    let provider =
      role == .translation || role == .chatRequest || role == .brief || role == .librarySummary
    switch authority.config {
    case .inapplicable: if provider { return .invalidApplicability }
    case .generation(let value): if !provider || value.isEmpty { return .invalidApplicability }
    }
    guard !authority.paper.id.isEmpty, !authority.paper.generation.isEmpty, !authority.epoch.isEmpty
    else { return .invalidIdentity }
    guard authority.prerequisitesAvailable else { return .prerequisitesUnavailable }
    return nil
  }

  private static func fresh(_ reservation: Reservation, history: [Execution]) -> Bool {
    guard !reservation.attempt.isEmpty, !reservation.fence.isEmpty, !reservation.correlation.isEmpty
    else { return false }
    return !history.contains {
      $0.lineage.reservation.attempt == reservation.attempt
        || $0.lineage.reservation.fence == reservation.fence
        || $0.lineage.reservation.correlation == reservation.correlation
    }
  }

  // Each comparison is intentionally independent, including explicit inapplicable config equality.
  private static func guardLineage(_ supplied: Lineage, snapshot: Snapshot) -> Rejection? {
    let current = snapshot.current.lineage
    guard supplied.job == snapshot.job else { return .job }
    guard supplied.reservation.attempt == current.reservation.attempt else { return .attempt }
    guard supplied.reservation.fence == current.reservation.fence else { return .fence }
    guard supplied.reservation.correlation == current.reservation.correlation else {
      return .correlation
    }
    guard supplied.captured.input == current.captured.input,
      supplied.captured.input == snapshot.authority.input
    else { return .input }
    guard supplied.captured.config == current.captured.config,
      supplied.captured.config == snapshot.authority.config
    else { return .config }
    guard supplied.captured.paper == current.captured.paper,
      supplied.captured.paper == snapshot.authority.paper
    else { return .paper }
    guard supplied.captured.epoch == current.captured.epoch,
      supplied.captured.epoch == snapshot.authority.epoch
    else { return .epoch }
    guard !snapshot.revoked else { return .revoked }
    guard snapshot.authority.prerequisitesAvailable else { return .prerequisitesUnavailable }
    return nil
  }

  // The Application arbiter serializes replacement of its current snapshot. Applying stale
  // copies independently is not a compare-and-swap, persistence, or a concurrency primitive.
  public static func apply(_ event: Event, to snapshot: Snapshot) -> Decision {
    var authority = snapshot.authority
    var history = snapshot.executions
    var pointer = snapshot.usableResult
    var permits = snapshot.permits
    var usedIDs = snapshot.usedPermitIDs
    var revoked = snapshot.revoked
    var operationIDs = snapshot.usedOperationIDs
    var removing = snapshot.pendingRemoval
    var removalDebt = snapshot.removalDebt
    var removed = snapshot.removedPapers
    var commands: [Command] = []
    var rejection: Rejection?
    let last = history.count - 1

    func reject(_ reason: Rejection) -> Decision {
      Decision(snapshot: snapshot, commands: [], rejection: reason)
    }
    func replaceExecution(state: State? = nil, dispatch: Dispatch? = nil, result: Result? = nil) {
      let old = history[last]
      history[last] = Execution(
        lineage: old.lineage, state: state ?? old.state,
        dispatch: dispatch ?? old.dispatch, result: result ?? old.result)
    }
    func permitIndex(_ lineage: Lineage, _ id: String) -> Int? {
      permits.firstIndex { $0.id == id && $0.owner == lineage }
    }
    func replacePermit(
      _ index: Int, closure: Closure? = nil, phase: PublicationPhase? = nil,
      cleanup: Cleanup? = nil, revoked: Bool? = nil, stage: Stage? = nil,
      operation: Operation? = nil
    ) {
      let old = permits[index]
      permits[index] = Permit(
        id: old.id, owner: old.owner, kind: old.kind,
        closure: closure ?? old.closure, stage: stage ?? old.stage, phase: phase ?? old.phase,
        cleanup: cleanup ?? old.cleanup,
        cleanupOperation: (cleanup ?? old.cleanup) == .requested
          ? (operation ?? old.cleanupOperation) : nil,
        revoked: revoked ?? old.revoked)
    }
    func scheduleCleanup(_ index: Int) {
      let p = permits[index]
      if p.cleanup == .cleaned || p.cleanup == .requested || p.cleanup == .failed { return }
      // Committed bytes belong to the usable result, not to failed-stage cleanup.
      if p.kind == .publication && p.phase == .committed {
        replacePermit(index, revoked: true)
        return
      }
      if case .closed = p.closure {
        // No filesystem invocation without a caller-reserved fresh identity.
        replacePermit(index, cleanup: .required, revoked: true)
      } else {
        if p.cleanup != .required || !p.revoked {
          replacePermit(index, cleanup: .required, revoked: true)
          commands.append(.awaitClosure(p.owner, p.id))
        }
      }
    }
    func invalidatePermits() {
      for index in permits.indices { scheduleCleanup(index) }
    }
    func runningGuard(_ lineage: Lineage) -> Rejection? {
      guard snapshot.current.state == .running else { return .state }
      return guardLineage(lineage, snapshot: snapshot)
    }

    switch event {
    case .authorityChanged(let new):
      // Unavailable prerequisites are a valid observation but cannot admit new work.
      let available = Authority(
        input: new.input, config: new.config, paper: new.paper,
        epoch: new.epoch, prerequisitesAvailable: true)
      if let error = validate(available, role: snapshot.role) { return reject(error) }
      guard new.paper.id == authority.paper.id else { return reject(.paper) }
      authority = new
      if new != snapshot.authority { invalidatePermits() }

    case .claim(let lineage):
      guard snapshot.current.state == .pending else { return reject(.state) }
      if let error = guardLineage(lineage, snapshot: snapshot) { return reject(error) }
      replaceExecution(state: .running)

    case .startup(let epoch):
      guard !epoch.isEmpty else { return reject(.invalidIdentity) }
      authority = Authority(
        input: authority.input, config: authority.config, paper: authority.paper,
        epoch: epoch, prerequisitesAvailable: authority.prerequisitesAvailable)
      // Current-process running work is not a prior-process interruption.
      if snapshot.current.state == .running && snapshot.current.lineage.captured.epoch != epoch {
        replaceExecution(state: .failed(.interrupted))
        commands.append(.cancel(snapshot.current.lineage))
        invalidatePermits()
      }

    case .dispatch(let lineage):
      if let error = runningGuard(lineage) { return reject(error) }
      guard snapshot.current.dispatch == .none else { return reject(.dispatchAlreadyAdmitted) }
      replaceExecution(dispatch: .intentRecorded)
      commands = [.recordDispatchIntent(lineage), .send(lineage)]

    case .sendMayHaveHappened(let lineage):
      // Late send reports update only exact historical dispatch, never create authority.
      guard let index = history.firstIndex(where: { $0.lineage == lineage }),
        history[index].dispatch != .none
      else { return reject(.invalidTransition) }
      let old = history[index]
      history[index] = Execution(
        lineage: old.lineage, state: old.state,
        dispatch: .mayHaveSent, result: old.result)

    case .terminate(let lineage, let failure):
      guard snapshot.current.state == .pending || snapshot.current.state == .running
      else { return reject(.state) }
      guard lineage == snapshot.current.lineage else { return reject(.attempt) }
      guard failure != .interrupted && failure != .paperDeleting else {
        return reject(.invalidTransition)
      }
      replaceExecution(state: .failed(failure))
      commands.append(.cancel(lineage))
      invalidatePermits()

    case .retry(let reservation, let new):
      guard !revoked else { return reject(.revoked) }
      switch snapshot.current.state {
      case .pending, .running: return reject(.state)
      case .succeeded, .failed: break
      }
      if let error = validate(new, role: snapshot.role) { return reject(error) }
      guard new.paper.id == authority.paper.id else { return reject(.paper) }
      guard fresh(reservation, history: history) else { return reject(.reservationUnavailable) }
      // Outstanding old cleanup must finish before a new execution can access this namespace.
      guard permits.isEmpty else { return reject(.cleanupOutstanding) }
      authority = new
      let lineage = Lineage(job: snapshot.job, reservation: reservation, captured: new)
      history.append(Execution(lineage: lineage, state: .pending, dispatch: .none, result: nil))

    case .acquireWriter(let lineage, let id):
      if let error = runningGuard(lineage) { return reject(error) }
      guard !id.isEmpty, !usedIDs.contains(id) else { return reject(.permitIdentity) }
      guard permits.isEmpty else { return reject(.permitsOutstanding) }
      usedIDs.append(id)
      permits.append(
        Permit(
          id: id, owner: lineage, kind: .writer, closure: .unknown,
          stage: .unvalidated, phase: .acquired, cleanup: .none, cleanupOperation: nil,
          revoked: false))
      commands.append(.acquirePermit(lineage, id, .writer))

    case .writerClosure(let lineage, let id, let closure):
      guard let index = permitIndex(lineage, id) else { return reject(.permitOwnership) }
      guard permits[index].kind == .writer else { return reject(.permitKind) }
      if case .closed = permits[index].closure { return reject(.invalidTransition) }
      if case .closed(.validated(let result)) = closure, result.id.isEmpty {
        return reject(.malformedResult)
      }
      if case .closed(let stage) = closure {
        replacePermit(index, closure: closure, stage: stage)
      } else {
        replacePermit(index, closure: closure)
      }
      if permits[index].revoked { scheduleCleanup(index) }

    case .acquirePublication(let lineage, let writer, let id):
      if let error = runningGuard(lineage) { return reject(error) }
      guard let index = permitIndex(lineage, writer) else { return reject(.permitOwnership) }
      let p = permits[index]
      guard p.kind == .writer else { return reject(.permitKind) }
      guard !p.revoked, p.cleanup == .none else { return reject(.cleanupOutstanding) }
      guard case .closed(.validated) = p.closure else { return reject(.stageNotValidated) }
      guard !id.isEmpty, !usedIDs.contains(id) else { return reject(.permitIdentity) }
      // Atomic ownership transfer: no unowned stage gap between writer and publisher.
      permits.remove(at: index)
      usedIDs.append(id)
      permits.append(
        Permit(
          id: id, owner: lineage, kind: .publication, closure: p.closure,
          stage: p.stage, phase: .acquired, cleanup: .none, cleanupOperation: nil, revoked: false))
      commands = [.acquirePermit(lineage, id, .publication), .releasePermit(lineage, writer)]

    case .rename(let lineage, let id):
      if let error = runningGuard(lineage) { return reject(error) }
      guard let index = permitIndex(lineage, id) else { return reject(.permitOwnership) }
      let p = permits[index]
      guard p.kind == .publication else { return reject(.permitKind) }
      guard !p.revoked, p.cleanup == .none else { return reject(.cleanupOutstanding) }
      guard p.phase == .acquired else { return reject(.invalidTransition) }
      guard case .closed(.validated(let result)) = p.closure else {
        return reject(.stageNotValidated)
      }
      replacePermit(index, closure: .unknown, phase: .renaming)
      commands.append(.rename(lineage, id, result))

    case .renameFinished(let lineage, let id, let succeeded):
      guard let index = permitIndex(lineage, id) else { return reject(.permitOwnership) }
      let p = permits[index]
      guard p.kind == .publication, p.phase == .renaming else { return reject(.invalidTransition) }
      guard case .validated(let result) = p.stage else { return reject(.stageNotValidated) }
      replacePermit(index, closure: .closed(.validated(result)), phase: .renamed)
      if !succeeded || p.revoked { scheduleCleanup(index) }

    case .publish(let lineage, let id, let result):
      var error = runningGuard(lineage)
      // A foreign callback cannot acquire or clean another execution's permit.
      guard let index = permitIndex(lineage, id) else { return reject(error ?? .permitOwnership) }
      let p = permits[index]
      guard p.kind == .publication else { return reject(.permitKind) }
      guard p.phase != .committed else { return reject(.state) }
      if error == nil && (p.revoked || p.cleanup != .none) { error = .cleanupOutstanding }
      if error == nil && p.phase != .renamed { error = .invalidTransition }
      if error == nil {
        if case .closed(.validated(let expected)) = p.closure {
          if result.id.isEmpty {
            error = .malformedResult
          } else if result != expected {
            error = .resultMismatch
          } else if history.contains(where: { $0.result?.id == result.id }) {
            error = .resultAlreadyCommitted
          }
        } else {
          error = .stageNotValidated
        }
      }
      if let error {
        // A failed guard is an admitted synchronous cleanup obligation, not success or release.
        rejection = error
        scheduleCleanup(index)
      } else {
        replaceExecution(state: .succeeded, result: result)
        pointer = UsableResult(lineage: lineage, result: result)
        replacePermit(index, phase: .committed)
        commands.append(.commit(lineage, id, result))
      }

    case .revoke:
      revoked = true
      if snapshot.current.state == .pending || snapshot.current.state == .running {
        replaceExecution(state: .failed(.paperDeleting))
        commands.append(.cancel(snapshot.current.lineage))
      }
      invalidatePermits()

    case .requestCleanup(let lineage, let id, let operationID):
      guard let index = permitIndex(lineage, id) else { return reject(.permitOwnership) }
      let p = permits[index]
      guard p.revoked, p.cleanup == .required || p.cleanup == .failed
      else { return reject(.invalidTransition) }
      guard case .closed = p.closure else { return reject(.closureUnknown) }
      guard !operationID.isEmpty, !operationIDs.contains(operationID)
      else { return reject(.operationIdentity) }
      let operation = Operation(id: operationID, paper: p.owner.captured.paper)
      operationIDs.append(operationID)
      replacePermit(index, cleanup: .requested, operation: operation)
      commands.append(.removeOwnedBytes(lineage, id, operation))

    case .cleanupFinished(let lineage, let id, let operation, let succeeded):
      guard let index = permitIndex(lineage, id) else { return reject(.permitOwnership) }
      guard case .closed = permits[index].closure else { return reject(.closureUnknown) }
      guard permits[index].cleanup == .requested else { return reject(.invalidTransition) }
      guard permits[index].cleanupOperation == operation else { return reject(.operationMismatch) }
      replacePermit(index, cleanup: succeeded ? .cleaned : .failed)

    case .release(let lineage, let id):
      guard let index = permitIndex(lineage, id) else { return reject(.permitOwnership) }
      let p = permits[index]
      guard case .closed = p.closure else { return reject(.closureUnknown) }
      guard p.cleanup == .cleaned || (p.kind == .publication && p.phase == .committed)
      else { return reject(.cleanupOutstanding) }
      permits.remove(at: index)
      commands.append(.releasePermit(lineage, id))

    case .removeNamespace(let operationID):
      guard revoked else { return reject(.revoked) }
      guard permits.isEmpty else { return reject(.permitsOutstanding) }
      guard removing == nil else { return reject(.removalOutstanding) }
      // A failed old-scope invocation must be retried before targeting newer authority.
      let target = removalDebt ?? authority.paper
      guard !removed.contains(target) else { return reject(.invalidTransition) }
      guard !operationID.isEmpty, !operationIDs.contains(operationID)
      else { return reject(.operationIdentity) }
      let operation = Operation(id: operationID, paper: target)
      operationIDs.append(operationID)
      removing = operation
      removalDebt = target
      commands.append(.removeNamespace(operation))

    case .namespaceRemovalFinished(let operation, let succeeded):
      guard let pending = removing else { return reject(.removalNotRequested) }
      guard pending == operation else { return reject(.operationMismatch) }
      guard revoked, permits.isEmpty else { return reject(.permitsOutstanding) }
      removing = nil
      if succeeded {
        removed.append(pending.paper)
        removalDebt = nil
      }
    }

    return Decision(
      snapshot: Snapshot(
        job: snapshot.job, role: snapshot.role, authority: authority,
        executions: history, usableResult: pointer, permits: permits, usedPermitIDs: usedIDs,
        revoked: revoked, usedOperationIDs: operationIDs, pendingRemoval: removing,
        removalDebt: removalDebt, removedPapers: removed),
      commands: commands, rejection: rejection)
  }

}
