import Darwin
import Dispatch
import Foundation

#if SWIFT_PACKAGE
  import ProviderRPC
#endif

@MainActor
internal protocol OwnedChildSession: AnyObject {
  func close()
}

/// Implemented by the actual transport owner in the Main-only adapter, never a proof payload.
@MainActor
internal protocol OwnedChildTransport: AnyObject, Sendable {
  var ownerIdentity: UUID { get }
  var checkedEndpointsClosed: Bool { get }
  func requestClose()
  func quiesceNotifications()
  func releaseCleanRoot()
  func testingPhysicalTeardown()
}

/// Native direct-child retirement. Clean proves owned retirement, not metadata admission or SDK work.
public final class OwnedChildRetirement: @unchecked Sendable {
  public enum Fixture: Sendable { case trueUtility, cat }
  internal struct BackupLaunch: Sendable {
    let namespace: TopologyOwnedFixtures
    let interpreter: URL
    let script: URL
    let reference: String
  }
  internal struct WorkerLaunch: Sendable {
    let namespace: TopologyOwnedFixtures
    let interpreter: URL
    let script: URL

    private init(namespace: TopologyOwnedFixtures, interpreter: URL, script: URL) {
      self.namespace = namespace
      self.interpreter = interpreter
      self.script = script
    }

    static func bundled(namespace: TopologyOwnedFixtures, mainBundle: URL) -> Self? {
      let bundle = mainBundle.appendingPathComponent("Contents/XPCServices/ProviderAgent.xpc")
      guard let paths = validatedProviderBundle(bundle) else { return nil }
      return Self(namespace: namespace, interpreter: paths.0, script: paths.1)
    }

    static func validatedProviderBundle(_ bundle: URL) -> (URL, URL)? {
      guard Bundle(url: bundle)?.bundleIdentifier == TopologyIdentity.agent else { return nil }
      let contents = bundle.appendingPathComponent("Contents").standardizedFileURL
      guard contents.resolvingSymlinksInPath() == contents else { return nil }
      let interpreter = contents.appendingPathComponent("MacOS/python3")
      let canonical = interpreter.resolvingSymlinksInPath()
      var info = stat()
      guard canonical.path.hasPrefix(contents.path + "/"),
        lstat(canonical.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
        FileManager.default.isExecutableFile(atPath: interpreter.path)
      else { return nil }
      for name in ["agent.py", "sdk_worker.py", "broker_control.py"] {
        let resource = contents.appendingPathComponent("Resources/" + name)
        guard resource.resolvingSymlinksInPath() == resource,
          lstat(resource.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG
        else { return nil }
      }
      return (interpreter, contents.appendingPathComponent("Resources/agent.py"))
    }

    // Code-only test seam. Never selected by production argv, environment or bundle lookup.
    static func testing(namespace: TopologyOwnedFixtures, interpreter: URL, script: URL) -> Self {
      Self(namespace: namespace, interpreter: interpreter, script: script)
    }
  }
  internal enum Command: Sendable {
    case fixture(Fixture, URL)
    case backup(BackupLaunch)
    case worker(WorkerLaunch)
  }
  public enum Failure: Error, Sendable, Equatable {
    case deadline, setup, spawn, close, wait, admissionBlocked, revoked
    case identity, control, sdkClosureUnproven
  }
  public struct Proof: Sendable, Equatable {
    public let checkedDescriptorCloses: Int
    public let childReaped: Bool
    public let childExitStatus: Int32
  }
  public enum Terminal: Sendable, Equatable {
    case clean(Proof)
    case unknown(Failure)
  }
  internal enum Effect: Sendable { case pipe, socket, duplicate, namespace, spawn, close, wait }
  internal enum DescriptorRole: Sendable, Equatable {
    case productInput, productOutput, stderrRead, childPipe, namespaceAlias
    case workerLifecycle, childLifecycle, lifecycleAlias
    case brokerControl
  }
  internal struct Hooks: Sendable {
    var before: @Sendable (Effect) -> Void = { _ in }
    var afterSpawn: @Sendable (pid_t) -> Void = { _ in }
    // Private EBADF injection leaves the real descriptor owned, never certifies closure.
    var closeFault: @Sendable () -> Bool = { false }
    var afterPipeFault: @Sendable () -> Bool = { false }
    var beforeChannelSetup: @Sendable () -> Void = {}
    var afterClose: @Sendable () -> Void = {}
    var afterSocketFault: @Sendable () -> Bool = { false }
    var afterDuplicateFault: @Sendable () -> Bool = { false }
    var workerLaunched: @Sendable () -> Void = {}
  }

  // Lifetime roots, not a second product store. Worker debt retains its namespace,
  // never poisons unrelated namespaces. One-shot fixture/backup debt is unchanged.
  private final class Roots: @unchecked Sendable {
    static let shared = Roots()
    let lock = NSLock()
    var owners: [UUID: Core] = [:]
    var debt = false
    func admit(_ core: Core) -> Bool {
      lock.withLock {
        if case .worker(let launch) = core.command {
          guard !owners.values.contains(where: { existing in
            guard existing !== core else { return false }
            switch existing.command {
            case .worker(let owned):
              return owned.namespace.runID == launch.namespace.runID
                || owned.namespace.directoryURL == launch.namespace.directoryURL
            case .backup(let owned):
              return owned.namespace.runID == launch.namespace.runID
                || owned.namespace.directoryURL == launch.namespace.directoryURL
            case .fixture: return false
            }
          }) else { return false }
        } else {
          guard !debt else { return false }
        }
        owners[core.identity] = core
        return true
      }
    }
    func finish(_ core: Core, clean: Bool) {
      lock.withLock {
        if clean { owners.removeValue(forKey: core.identity) }
        else if !core.isWorker { debt = true }
      }
    }
  }

  internal final class Core: @unchecked Sendable {
    let identity = UUID()
    let command: Command
    var deadline: UInt64
    let runsUntilRevoked: Bool
    var startupDeadline: UInt64
    let hooks: Hooks
    // Prepared before the invocation. The terminal lane never joins the operation lane.
    let operation = DispatchQueue(label: "PaperLens.fixture.child.operation")
    let terminalLane = DispatchQueue(label: "PaperLens.fixture.child.terminal")
    let lock = NSLock()
    var invoked = false
    var terminal: Terminal?
    var observers: [@Sendable (Terminal) -> Void] = []
    var timer: DispatchSourceTimer?
    var descriptors: Set<Int32> = []
    // Observations only: descriptors remains the sole raw-FD closure authority.
    var descriptorRoles: [Int32: DescriptorRole] = [:]
    var descriptorIdentities: [Int32: stat] = [:]
    var uncertainCloses: Set<Int32> = []
    var spawnStrings: [UnsafeMutablePointer<CChar>?] = []
    var spawnArguments: [String] = []
    var spawnEnvironment: [String] = []
    var child: pid_t?
    var reaped = false
    var closes = 0
    // Setup handles are real ownership too and survive partial setup/expiry.
    var actions: posix_spawn_file_actions_t?
    var attributes: posix_spawnattr_t?
    var startupTimer: DispatchSourceTimer?
    var revoked = false
    var retirementID: String?
    var cancelDispatchPending = false
    var handoff = false
    var endpoints: (Int32, Int32)?
    var channel: (any OwnedChildTransport)?
    var stderrSource: DispatchSourceRead?
    var stderrJoined = true
    var cleanupQueued = false
    var readyFailure: (@MainActor @Sendable (Failure) -> Void)?
    var consumeTransport: (@MainActor @Sendable (Core) -> Void)?
    enum WorkerPhase {
      case offer, hello, running, dispatching, product, retiring, brokerEOF, reaping
    }
    var workerPhase: WorkerPhase = .offer
    var workerAtSpawn: NativeBrokerABI.ProcessSnapshot?
    let identityStorage = NativeBrokerABI.ObservationStorage()
    var offerStorage: NativeBrokerABI.ReceiveStorage?
    var brokerIdentity: NativeBrokerABI.PeerObservation?
    var controlSources: [Int32: DispatchSourceRead] = [:]
    var controlWrites: [Int32: DispatchSourceWrite] = [:]
    var controlInput: [Int32: Data] = [:]
    var controlOutput: [Int32: Data] = [:]
    var brokerFD: Int32?
    var workerFD: Int32?
    var brokerOffered = false
    var localCLIWaitStatus: UInt64?
    var brokerWaitStatus: UInt64?
    var revokeSent = false
    var dispatchAcknowledged = false

    init(command: Command, deadline: UInt64, hooks: Hooks, runningFixture: Bool = false) {
      self.command = command
      self.deadline = deadline
      self.startupDeadline = deadline
      self.hooks = hooks
      if case .worker = command {
        self.runsUntilRevoked = true
      } else {
        self.runsUntilRevoked = runningFixture
      }
    }
    var isWorker: Bool {
      if case .worker = command { return true }
      return false
    }
    func captureOwned(_ fd: Int32, role: DescriptorRole) {
      lock.withLock {
        descriptors.insert(fd)
        descriptorRoles[fd] = role
      }
    }
    func observeOwned(_ fd: Int32, type: mode_t, effect: Effect) -> Bool {
      guard permit(effect) else { return false }
      var info = stat()
      let result = fstat(fd, &info)
      if result == 0 { lock.withLock { descriptorIdentities[fd] = info } }
      guard withinDeadline() else { return false }
      guard result == 0, info.st_mode & S_IFMT == type else {
        failed(.identity)
        return false
      }
      return true
    }
    var allowsIO: Bool {
      lock.withLock {
        terminal == nil && !revoked && DispatchTime.now().uptimeNanoseconds < deadline
      }
    }
    @MainActor
    func begin(
      _ startupDeadline: UInt64,
      consume: @escaping @MainActor @Sendable (Core) -> Void,
      failure: @escaping @MainActor @Sendable (Failure) -> Void
    ) {
      let first = lock.withLock { () -> Bool in
        guard !invoked else { return false }
        invoked = true
        deadline = startupDeadline
        self.startupDeadline = startupDeadline
        readyFailure = failure
        consumeTransport = consume
        return true
      }
      guard first else { return }
      guard Roots.shared.admit(self) else {
        failed(.admissionBlocked)
        return
      }
      let source = DispatchSource.makeTimerSource(queue: terminalLane)
      source.setEventHandler { @Sendable [self] in revoke(startupOnly: true) }
      source.schedule(
        deadline: DispatchTime(uptimeNanoseconds: startupDeadline), leeway: .nanoseconds(0))
      lock.withLock { startupTimer = source }
      source.resume()
      operation.async { [self] in
        guard allowsIO else { return }
        if case .worker(let launch) = command,
          !launch.namespace.beginMetadataMutation(owner: identity)
        {
          if allowsIO { failed(.setup) }
          return
        }
        guard allowsIO else { return }
        run()
      }
    }
    func revoke(startupOnly: Bool = false, dispatchCancellation: Bool = false) {
      if isWorker {
        var needsAdmission = false
        var beginCleanup = false
        let first = lock.withLock { () -> Bool in
          guard terminal == nil, !revoked else { return false }
          if cancelDispatchPending {
            guard !dispatchCancellation else { return false }
            cancelDispatchPending = false
            revoked = true
            beginCleanup = true
            return false
          }
          if startupOnly {
            guard startupTimer != nil, DispatchTime.now().uptimeNanoseconds >= startupDeadline
            else { return false }
          }
          needsAdmission = !invoked
          invoked = true
          cancelDispatchPending = dispatchCancellation
          revoked = !dispatchCancellation
          beginCleanup = !dispatchCancellation
          retirementID = UUID().uuidString.lowercased()
          return true
        }
        if first {
          if needsAdmission, !Roots.shared.admit(self) {
            select(.unknown(.admissionBlocked))
            return
          }
          let startup = lock.withLock { () -> DispatchSourceTimer? in
            let result = startupTimer
            startupTimer = nil
            return result
          }
          startup?.cancel()
          resolveStartupFailure(startupOnly ? .deadline : .revoked)
          if dispatchCancellation {
            // AgentConnectionLifecycle synchronously fences ordinary requests and
            // admits only its final cancellation frame. This independent handoff
            // bound is not a deadline for the subsequent observed cleanup.
            terminalLane.asyncAfter(deadline: .now() + .milliseconds(50)) { [self] in
              revoke()
            }
          }
        }
        if beginCleanup { operation.async { [self] in retireWorker() } }
        return
      }
      guard runsUntilRevoked else {
        invoke()
        return
      }
      var needsAdmission = false
      var beginCleanup = false
      let first = lock.withLock { () -> Bool in
        guard terminal == nil, !revoked else { return false }
        if cancelDispatchPending {
          guard !dispatchCancellation else { return false }
          cancelDispatchPending = false
          revoked = true
          beginCleanup = true
          return false
        }
        if startupOnly {
          guard startupTimer != nil, DispatchTime.now().uptimeNanoseconds >= deadline else {
            return false
          }
        }
        needsAdmission = !invoked
        invoked = true
        cancelDispatchPending = dispatchCancellation
        revoked = !dispatchCancellation
        beginCleanup = !dispatchCancellation
        let now = DispatchTime.now().uptimeNanoseconds
        let (bound, overflow) = now.addingReportingOverflow(300_000_000)
        deadline = overflow ? UInt64.max : bound
        return true
      }
      if first {
        if needsAdmission, !Roots.shared.admit(self) {
          select(.unknown(.admissionBlocked))
          return
        }
        let source = DispatchSource.makeTimerSource(queue: terminalLane)
        source.setEventHandler { [self] in select(.unknown(.deadline)) }
        let (deadline, startup) = lock.withLock { () -> (UInt64, DispatchSourceTimer?) in
          let startup = startupTimer
          startupTimer = nil
          timer = source
          return (self.deadline, startup)
        }
        startup?.cancel()
        source.schedule(
          deadline: DispatchTime(uptimeNanoseconds: deadline), leeway: .nanoseconds(0))
        source.resume()
        resolveStartupFailure(startupOnly ? .deadline : .revoked)
        if dispatchCancellation {
          // This independent lane revokes even if MainActor or the writer stalls.
          // The total 300ms deadline above is never restarted by dispatch completion.
          terminalLane.asyncAfter(deadline: .now() + .milliseconds(50)) { [self] in
            revoke()
          }
        }
      }
      if beginCleanup {
        operation.async { [self] in
          if isWorker { retireWorker() } else { beginRunningCleanup() }
        }
      }
    }
    func reservedEndpoints() throws -> (Int32, Int32) {
      try lock.withLock {
        guard handoff, let endpoints else { throw Failure.setup }
        return endpoints
      }
    }
    @MainActor
    func markRunning() -> Bool {
      // Startup cannot be discharged before the authenticated handoff has
      // transferred the product endpoints into their transport owner.
      guard lock.withLock({ channel != nil }) else { return false }
      var startup: DispatchSourceTimer?
      let accepted = lock.withLock { () -> Bool in
        guard terminal == nil, !revoked,
          DispatchTime.now().uptimeNanoseconds < deadline
        else { return false }
        startup = startupTimer
        startupTimer = nil
        deadline = UInt64.max
        readyFailure = nil
        return true
      }
      startup?.cancel()
      if !accepted { revoke(startupOnly: true) }
      return accepted
    }
    @MainActor
    func capture(_ actual: any OwnedChildTransport) {
      lock.withLock {
        channel = actual
        if let endpoints {
          descriptors.remove(endpoints.0)
          descriptors.remove(endpoints.1)
        }
        endpoints = nil
        handoff = false
      }
      // Even a late capture remains retained. No effects are authorized after unknown.
      if lock.withLock({ terminal == nil && revoked }) {
        operation.async { [self] in beginRunningCleanup() }
      }
    }
    func permitChannelClose() -> Bool { permit(.close) }
    func recordChannelClose(_ closed: Bool) {
      if closed { lock.withLock { closes += 1 } }
      _ = withinDeadline()
    }
    @MainActor
    func channelClosed(ownerIdentity: UUID) {
      guard let actual = lock.withLock({ terminal == nil ? channel : nil }),
        actual.ownerIdentity == ownerIdentity
      else { return }
      guard actual.checkedEndpointsClosed else {
        failed(.close)
        return
      }
      operation.async { [self] in beginRunningCleanup() }
    }
    func beginRunningCleanup() {
      guard !isWorker else { return }
      guard lock.withLock({ revoked }) else { return }
      guard withinDeadline() else { return }
      let state = lock.withLock { (handoff, channel, stderrSource, stderrJoined) }
      guard !state.0 else { return }
      if let source = state.2 {
        lock.withLock { stderrSource = nil }
        source.cancel()
        return  // cancel handler joins the actual discard work on this same lane
      }
      guard state.3 else { return }
      if let actual = state.1 {
        Task { @MainActor [self] in
          guard withinDeadline() else { return }
          if actual.checkedEndpointsClosed {
            operation.async { [self] in finishRunningCleanup() }
          } else {
            actual.requestClose()
          }
        }
      } else {
        finishRunningCleanup()
      }
    }
    func finishRunningCleanup() {
      guard !isWorker else { return }
      guard withinDeadline() else { return }
      let first = lock.withLock { () -> Bool in
        guard !cleanupQueued else { return false }
        cleanupQueued = true
        return true
      }
      guard first else { return }
      if actions != nil {
        guard permit(.close) else { return }
        let result = posix_spawn_file_actions_destroy(&actions)
        if result == 0 { actions = nil }
        guard withinDeadline() else { return }
        guard result == 0 else {
          failed(.setup)
          return
        }
      }
      if attributes != nil {
        guard permit(.close) else { return }
        let result = posix_spawnattr_destroy(&attributes)
        if result == 0 { attributes = nil }
        guard withinDeadline() else { return }
        guard result == 0 else {
          failed(.setup)
          return
        }
      }
      // Channel has joined its actual IO before its checked physical closure.
      let remaining = lock.withLock { descriptors }
      for fd in remaining { guard closeOwned(fd) else { return } }
      let pid = lock.withLock { child }
      guard let pid, permit(.wait) else {
        failed(.wait)
        return
      }
      var status: Int32 = 0
      let result = waitpid(pid, &status, 0)
      if result == pid { lock.withLock { reaped = true } }
      guard withinDeadline() else { return }
      guard result == pid else {
        failed(.wait)
        return
      }
      let proof = lock.withLock {
        Proof(checkedDescriptorCloses: closes, childReaped: reaped, childExitStatus: status)
      }
      select(.clean(proof))
    }
    func invoke() {
      let first = lock.withLock { () -> Bool in
        guard !invoked else { return false }
        invoked = true
        return true
      }
      guard first else { return }
      guard Roots.shared.admit(self) else {
        select(.unknown(.admissionBlocked))
        return
      }
      if case .backup(let launch) = command,
        !launch.namespace.beginMetadataMutation(owner: identity)
      {
        select(.unknown(.setup))
        return
      }
      let source = DispatchSource.makeTimerSource(queue: terminalLane)
      if isWorker {
        lock.withLock { startupTimer = source }
        source.setEventHandler { [self] in revoke(startupOnly: true) }
      } else {
        lock.withLock { timer = source }
        source.setEventHandler { [self] in select(.unknown(.deadline)) }
      }
      source.schedule(deadline: DispatchTime(uptimeNanoseconds: deadline), leeway: .nanoseconds(0))
      source.resume()
      operation.async { [self] in
        if case .worker(let launch) = command {
          guard allowsIO else { return }
          guard launch.namespace.beginMetadataMutation(owner: identity) else {
            if allowsIO { failed(.setup) }
            return
          }
          guard allowsIO else { return }
        }
        run()
      }
    }
    func observe(_ observer: @escaping @Sendable (Terminal) -> Void) {
      let selected = lock.withLock { () -> Terminal? in
        if let terminal { return terminal }
        observers.append(observer)
        return nil
      }
      if let selected { terminalLane.async { observer(selected) } }
    }
    func select(_ proposed: Terminal) {
      let delivery = lock.withLock { () -> (Terminal, [@Sendable (Terminal) -> Void])? in
        guard terminal == nil else { return nil }
        // A delayed timer or delayed completion is never evidence of on-time cleanup.
        let selected: Terminal
        if isWorker, case .clean = proposed {
          selected = .unknown(.sdkClosureUnproven)
        } else if case .clean = proposed, DispatchTime.now().uptimeNanoseconds >= deadline {
          selected = .unknown(.deadline)
        } else {
          selected = proposed
        }
        let clean: Bool
        if case .clean = selected { clean = true } else { clean = false }
        if clean, case .backup(let launch) = command {
          launch.namespace.endMetadataMutation(owner: identity)
        }
        Roots.shared.finish(self, clean: clean)
        terminal = selected
        let callbacks = observers
        observers.removeAll()
        return (selected, callbacks)
      }
      guard let (selected, callbacks) = delivery else { return }
      let sources = lock.withLock { () -> (DispatchSourceTimer?, DispatchSourceTimer?) in
        let sources = (timer, startupTimer)
        timer = nil
        startupTimer = nil
        return sources
      }
      sources.0?.cancel()
      sources.1?.cancel()
      // Notification cancellation is not descriptor closure or retirement proof.
      // Keep every uncertain resource rooted, but stop level-triggered EOF loops.
      operation.async { [self] in
        for source in controlSources.values { source.cancel() }
        for source in controlWrites.values { source.cancel() }
        controlSources.removeAll()
        controlWrites.removeAll()
        let stderr = lock.withLock {
          let source = stderrSource
          stderrSource = nil
          return source
        }
        stderr?.cancel()
      }
      if let actual = lock.withLock({ channel }) {
        Task { @MainActor in actual.quiesceNotifications() }
      }
      if case .clean = selected {
        let actual = lock.withLock { channel }
        if let actual { Task { @MainActor in actual.releaseCleanRoot() } }
      }
      if case .unknown(let failure) = selected {
        resolveStartupFailure(failure)
      } else {
        resolveStartupFailure(.revoked)
      }
      terminalLane.async { for callback in callbacks { callback(selected) } }
    }
    func resolveStartupFailure(_ failure: Failure) {
      let completion = lock.withLock { () -> (@MainActor @Sendable (Failure) -> Void)? in
        let completion = readyFailure
        readyFailure = nil
        return completion
      }
      if let completion {
        Task { @MainActor in completion(failure) }
      }
    }
    func permit(_ effect: Effect) -> Bool {
      guard withinDeadline() else { return false }
      if isWorker, lock.withLock({ revoked }) { return false }
      if runsUntilRevoked, lock.withLock({ revoked }) {
        switch effect {
        case .pipe, .socket, .duplicate, .namespace, .spawn: return false
        case .close, .wait: break
        }
      }
      hooks.before(effect)
      if isWorker, lock.withLock({ revoked }) { return false }
      if runsUntilRevoked, lock.withLock({ revoked }) {
        switch effect {
        case .pipe, .socket, .duplicate, .namespace, .spawn: return false
        case .close, .wait: break
        }
      }
      return withinDeadline()
    }
    func withinDeadline() -> Bool {
      if isWorker, lock.withLock({ revoked }) {
        return lock.withLock { terminal == nil }
      }
      if DispatchTime.now().uptimeNanoseconds >= lock.withLock({ deadline }) {
        if runsUntilRevoked, !lock.withLock({ revoked }) {
          revoke(startupOnly: true)
          return false
        }
        select(.unknown(.deadline))
        return false
      }
      return lock.withLock { terminal == nil }
    }
    func failed(_ failure: Failure) {
      if runsUntilRevoked { revoke() }
      select(.unknown(failure))
    }
    func closeOwned(_ descriptor: Int32) -> Bool {
      guard permit(.close) else { return false }
      let target: Int32 = hooks.closeFault() ? -1 : descriptor
      guard withinDeadline() else { return false }
      if isWorker, !allowsIO { return false }
      // No retry, including EINTR: uncertain descriptor identity remains rooted.
      guard Darwin.close(target) == 0, target == descriptor else {
        lock.withLock { _ = uncertainCloses.insert(descriptor) }
        failed(.close)
        return false
      }
      lock.withLock {
        descriptors.remove(descriptor)
        closes += 1
      }
      hooks.afterClose()
      return withinDeadline()
    }
    // All control buffers, identities and readiness sources belong to this same Core.
    // The terminal lane can seal unknown while any operation below is blocked.
    var controlPermitted: Bool {
      lock.withLock {
        terminal == nil && (isWorker && revoked || DispatchTime.now().uptimeNanoseconds < deadline)
      }
    }
    func armControl(_ fd: Int32) {
      guard controlPermitted, controlSources[fd] == nil else { return }
      let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: operation)
      controlSources[fd] = source
      source.setEventHandler { [self] in pumpControl(fd) }
      source.activate()
    }
    func queueControl(_ fd: Int32, _ op: String, _ fields: [String: Any] = [:]) throws {
      guard controlPermitted, case .worker(let launch) = command else { return }
      var message = fields
      message["v"] = 2
      message["runID"] = launch.namespace.runID
      message["op"] = op
      let frame = try ProviderRPC.encode(message)
      guard frame.count <= 1028, frame.count <= 2056 - (controlOutput[fd]?.count ?? 0) else {
        throw Failure.control
      }
      guard controlPermitted else { return }
      controlOutput[fd, default: Data()].append(frame)
      flushControl(fd)
    }
    func flushControl(_ fd: Int32) {
      guard controlPermitted else { return }
      for _ in 0..<4 {
        guard controlPermitted, let bytes = controlOutput[fd], !bytes.isEmpty else { break }
        let count = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        let code = errno
        if count > 0 { controlOutput[fd]?.removeFirst(count) }
        guard controlPermitted else { return }
        if count < 0, code == EINTR { continue }
        if count < 0, code == EAGAIN { break }
        if count <= 0 {
          failed(.control)
          return
        }
      }
      guard controlPermitted else { return }
      if controlOutput[fd]?.isEmpty != false {
        controlWrites.removeValue(forKey: fd)?.cancel()
        if fd == workerFD, workerPhase == .dispatching, !lock.withLock({ revoked }) {
          workerPhase = .product
          handoffProduct()
        }
      } else if controlWrites[fd] == nil {
        let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: operation)
        controlWrites[fd] = source
        source.setEventHandler { [self] in flushControl(fd) }
        source.activate()
      }
    }
    func pumpControl(_ fd: Int32) {
      guard controlPermitted else { return }
      do {
        if fd == workerFD, brokerFD == nil {
          guard allowsIO else { return }
          let storage = try NativeBrokerABI.ReceiveStorage()
          offerStorage = storage
          let offer = try NativeBrokerABI.receiveOffer(
            socket: fd, storage: storage,
            admit: { self.allowsIO }, capture: { self.captureOwned($0, role: .brokerControl) })
          guard allowsIO else { return }
          guard case .descriptor(let broker) = offer else { return }
          brokerFD = broker
          guard observeOwned(broker, type: S_IFSOCK, effect: .socket), allowsIO else { return }
          let flags = fcntl(broker, F_GETFL)
          guard allowsIO else { return }
          guard flags >= 0, fcntl(broker, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw Failure.control
          }
          guard allowsIO else { return }
          var noSignal: Int32 = 1
          guard
            setsockopt(
              broker, SOL_SOCKET, SO_NOSIGPIPE, &noSignal,
              socklen_t(MemoryLayout<Int32>.size)) == 0
          else { throw Failure.control }
          guard allowsIO, let workerAtSpawn, let child,
            case .worker(let launch) = command
          else { return }
          let credentials = try NativeBrokerABI.observeLocalCredentials(
            storage: identityStorage, admit: { self.allowsIO })
          let observation = try NativeBrokerABI.observeIdentity(
            socket: broker,
            storage: identityStorage, admit: { self.allowsIO })
          let workerNow = try NativeBrokerABI.observeProcess(
            pid: child,
            storage: identityStorage, admit: { self.allowsIO })
          guard allowsIO else { return }
          let canonical = launch.interpreter.resolvingSymlinksInPath().path
          guard allowsIO else { return }
          try NativeBrokerABI.checkBrokerChain(
            workerAtSpawn: workerAtSpawn,
            workerNow: workerNow, nativePID: getpid(), nativeCredentials: credentials,
            broker: observation, canonicalInterpreterPath: canonical)
          brokerIdentity = observation
          guard allowsIO else { return }
          workerPhase = .hello
          armControl(broker)
        }
        for _ in 0..<16 {
          guard controlPermitted else { return }
          let current = controlInput[fd] ?? Data()
          let target: Int
          if current.count < 4 {
            target = 4
          } else {
            let size = current.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
            guard size > 0, size <= 1024 else { throw Failure.control }
            target = size + 4
          }
          var bytes = [UInt8](repeating: 0, count: target - current.count)
          let count = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
          let code = errno
          if count > 0 { controlInput[fd, default: Data()].append(contentsOf: bytes.prefix(count)) }
          guard controlPermitted else { return }
          if count == 0 {
            guard fd == brokerFD, workerPhase == .brokerEOF, current.isEmpty,
              let workerFD, controlOutput[fd]?.isEmpty != false
            else { throw Failure.control }
            controlSources.removeValue(forKey: fd)?.cancel()
            workerPhase = .reaping
            guard let retirementID = lock.withLock({ self.retirementID }) else { throw Failure.control }
            try queueControl(workerFD, "reapBroker", ["retirementID": retirementID])
            return
          }
          if count < 0 {
            if code == EINTR { continue }
            if code == EAGAIN { return }
            throw Failure.control
          }
          if let frame = controlInput[fd], frame.count >= 4 {
            let length = frame.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
            guard length > 0, length <= 1024 else { throw Failure.control }
            if frame.count == length + 4 {
              let message = try ProviderRPC.decode(frame)
              controlInput[fd] = Data()
              try receiveControl(message, from: fd)
            }
          }
        }
      } catch { if controlPermitted { failed(.control) } }
    }
    func receiveControl(_ message: [String: Any], from fd: Int32) throws {
      guard controlPermitted, case .worker(let launch) = command,
        ProviderRPC.exactUInt64(message["v"]) == 2,
        message["runID"] as? String == launch.namespace.runID,
        let op = message["op"] as? String
      else { throw Failure.control }
      let extras: [String]
      switch op {
      case "hello", "running", "dispatching", "brokerOffered": extras = []
      case "revokeNeeded", "unknown": extras = ["code"]
      case "cliRetired": extras = ["retirementID", "scope", "waitStatus"]
      case "preLaunchRetired": extras = ["retirementID"]
      case "brokerReaped": extras = ["retirementID", "waitStatus"]
      default: throw Failure.control
      }
      guard Set(message.keys) == Set(["v", "runID", "op"] + extras) else { throw Failure.control }
      if extras.contains("retirementID") {
        guard let value = message["retirementID"] as? String,
          let expected = lock.withLock({ retirementID }), value == expected
        else { throw Failure.control }
      }
      switch op {
      case "hello" where fd == brokerFD && workerPhase == .hello && allowsIO:
        guard allowsIO else { return }
        var info = stat()
        let result = fstat(launch.namespace.descriptor, &info)
        guard allowsIO else { return }
        guard result == 0, let device = UInt64(exactly: info.st_dev) else { throw Failure.identity }
        workerPhase = .running
        try queueControl(
          fd, "run",
          [
            "startupDeadlineNs": startupDeadline,
            "cwdDevice": device, "cwdInode": info.st_ino,
          ])
      case "running" where fd == brokerFD && workerPhase == .running && allowsIO:
        workerPhase = .dispatching
        try queueControl(fd, "dispatch")
      case "dispatching" where fd == brokerFD && workerPhase == .dispatching && allowsIO:
        guard !dispatchAcknowledged else { throw Failure.control }
        dispatchAcknowledged = true
        try forwardDispatch()
      case "brokerOffered" where fd == workerFD && !brokerOffered && allowsIO:
        brokerOffered = true
        try forwardDispatch()
      case "revokeNeeded":
        guard [brokerFD, workerFD].contains(fd),
          let code = message["code"] as? String,
          ["startupDeadline", "stdioEOF", "cliExit", "sessionLimit", "scopeRetire"].contains(code)
        else { throw Failure.control }
        revoke()
      case "cliRetired", "preLaunchRetired":
        guard fd == brokerFD, workerPhase == .retiring
        else { throw Failure.control }
        if op == "cliRetired" {
          guard message["scope"] as? String == "localDirectCLIResources",
            let status = ProviderRPC.exactUInt64(message["waitStatus"])
          else { throw Failure.control }
          localCLIWaitStatus = status
        }
        workerPhase = .brokerEOF
      case "brokerReaped":
        guard fd == workerFD, workerPhase == .reaping,
          let status = ProviderRPC.exactUInt64(message["waitStatus"])
        else { throw Failure.control }
        brokerWaitStatus = status
        select(.unknown(.sdkClosureUnproven))
      default: throw Failure.control
      }
    }
    func forwardDispatch() throws {
      guard allowsIO, dispatchAcknowledged, brokerOffered, workerPhase == .dispatching,
        let workerFD
      else { return }
      try queueControl(workerFD, "dispatching")
    }
    func handoffProduct() {
      guard allowsIO else { return }
      let captured = lock.withLock { () -> Bool in
        guard let read = descriptorRoles.first(where: { $0.value == .productOutput })?.key,
          let write = descriptorRoles.first(where: { $0.value == .productInput })?.key
        else { return false }
        endpoints = (read, write)
        handoff = true
        return true
      }
      guard captured else {
        failed(.setup)
        return
      }
      Task { @MainActor [self] in
        guard allowsIO else { return }
        let consume = lock.withLock { () -> (@MainActor @Sendable (Core) -> Void)? in
          let result = consumeTransport
          consumeTransport = nil
          return result
        }
        consume?(self)
      }
    }
    func retireWorker() {
      guard controlPermitted, !revokeSent else { return }
      revokeSent = true
      workerPhase = .retiring
      guard let retirementID = lock.withLock({ self.retirementID }) else { return }
      do {
        if let brokerFD, brokerIdentity != nil {
          try queueControl(brokerFD, "revoke", ["retirementID": retirementID])
        }
        if let workerFD { try queueControl(workerFD, "revoke", ["retirementID": retirementID]) }
      } catch { if controlPermitted { failed(.control) } }
    }
    func run() {
      guard permit(.pipe) else { return }
      var aliases: [Int32] = []
      var lifecycleChild: Int32?
      switch command {
      case .fixture(_, let cwd):
        var info = stat()
        guard lstat(cwd.path, &info) == 0,
          info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
          info.st_mode & 0o777 == 0o700, info.st_uid == getuid()
        else {
          failed(.setup)
          return
        }
        guard permit(.pipe) else { return }
        guard (try? FileManager.default.contentsOfDirectory(atPath: cwd.path).isEmpty) == true
        else {
          failed(.setup)
          return
        }
      case .backup(let launch):
        for descriptor in [launch.namespace.descriptor, launch.namespace.metadataParentDescriptor] {
          guard permit(.pipe) else { return }
          let alias = fcntl(descriptor, F_DUPFD_CLOEXEC, 64)
          guard alias >= 0 else {
            failed(.setup)
            return
          }
          // Record actual ownership immediately, including partial/late setup.
          lock.withLock { _ = descriptors.insert(alias) }
          aliases.append(alias)
        }
      case .worker(let launch):
        guard
          launch.namespace.prepareWorkerDirectories(
            owner: identity,
            permit: {
              self.permit(.namespace)
            })
        else {
          if withinDeadline() { failed(.setup) }
          return
        }
        guard permit(.duplicate) else { return }
        let alias = fcntl(launch.namespace.descriptor, F_DUPFD_CLOEXEC, 64)
        if alias >= 0 { captureOwned(alias, role: .namespaceAlias) }
        guard withinDeadline() else { return }
        guard alias >= 0, !hooks.afterDuplicateFault() else {
          failed(.setup)
          return
        }
        guard observeOwned(alias, type: S_IFDIR, effect: .duplicate) else { return }
        aliases.append(alias)
      }
      var pipes: [[Int32]] = []
      for _ in 0..<3 {
        guard permit(.pipe) else { return }
        var pair: [Int32] = [-1, -1]
        guard Darwin.pipe(&pair) == 0 else {
          failed(.setup)
          return
        }
        // Actual ownership transfer is recorded even if setup completed after expiry.
        lock.withLock { descriptors.formUnion(pair) }
        pipes.append(pair)
        if isWorker {
          let roles: [[DescriptorRole]] = [
            [.childPipe, .productInput], [.productOutput, .childPipe], [.stderrRead, .childPipe],
          ]
          for (fd, role) in zip(pair, roles[pipes.count - 1]) { captureOwned(fd, role: role) }
        }
        guard withinDeadline() else { return }
        guard pair.allSatisfy({ $0 > STDERR_FILENO }) else {
          failed(.setup)
          return
        }
        if hooks.afterPipeFault() {
          failed(.setup)
          return
        }
        for fd in pair {
          if isWorker, !observeOwned(fd, type: S_IFIFO, effect: .pipe) { return }
          guard permit(.pipe) else { return }
          guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else {
            failed(.setup)
            return
          }
        }
      }
      if isWorker {
        guard permit(.socket) else { return }
        var pair: [Int32] = [-1, -1]
        let result = socketpair(AF_UNIX, SOCK_STREAM, 0, &pair)
        if result == 0 {
          captureOwned(pair[0], role: .workerLifecycle)
          captureOwned(pair[1], role: .childLifecycle)
          workerFD = pair[0]
        }
        guard withinDeadline() else { return }
        guard result == 0, !hooks.afterSocketFault(), pair.allSatisfy({ $0 > STDERR_FILENO })
        else {
          failed(.setup)
          return
        }
        lifecycleChild = pair[1]
        for fd in pair {
          guard observeOwned(fd, type: S_IFSOCK, effect: .socket) else { return }
          guard permit(.socket) else { return }
          guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else {
            failed(.setup)
            return
          }
        }
        guard permit(.socket) else { return }
        let flags = fcntl(pair[0], F_GETFL)
        guard permit(.socket) else { return }
        guard flags >= 0, fcntl(pair[0], F_SETFL, flags | O_NONBLOCK) == 0 else {
          failed(.setup)
          return
        }
        guard permit(.socket) else { return }
        var noSignal: Int32 = 1
        guard
          setsockopt(
            pair[0], SOL_SOCKET, SO_NOSIGPIPE, &noSignal,
            socklen_t(MemoryLayout<Int32>.size)) == 0
        else {
          failed(.setup)
          return
        }
        guard permit(.duplicate) else { return }
        let alias = fcntl(pair[1], F_DUPFD_CLOEXEC, 64)
        if alias >= 0 { captureOwned(alias, role: .lifecycleAlias) }
        guard withinDeadline() else { return }
        guard alias >= 0, !hooks.afterDuplicateFault() else {
          failed(.setup)
          return
        }
        guard observeOwned(alias, type: S_IFSOCK, effect: .duplicate) else { return }
        aliases.append(alias)
      }
      guard permit(.spawn) else { return }
      guard posix_spawn_file_actions_init(&actions) == 0 else {
        failed(.setup)
        return
      }
      guard permit(.spawn) else { return }
      guard posix_spawnattr_init(&attributes) == 0 else {
        failed(.setup)
        return
      }
      // Opaque setup objects stay on the operation lane; their destruction is checked.
      for (source, target) in [
        (pipes[0][0], STDIN_FILENO), (pipes[1][1], STDOUT_FILENO),
        (pipes[2][1], STDERR_FILENO),
      ] {
        guard permit(.spawn) else { return }
        guard posix_spawn_file_actions_adddup2(&actions, source, target) == 0 else {
          failed(.setup)
          return
        }
      }
      guard permit(.spawn) else { return }
      let directoryResult: Int32
      switch command {
      case .fixture(_, let cwd):
        directoryResult = posix_spawn_file_actions_addchdir_np(&actions, cwd.path)
      case .backup, .worker:
        directoryResult = posix_spawn_file_actions_addfchdir_np(&actions, aliases[0])
      }
      guard directoryResult == 0 else {
        failed(.setup)
        return
      }
      // High aliases cannot collide with stdio sources or the fixed metadata targets.
      let mappings: [(Int32, Int32)]
      if isWorker {
        mappings = [(aliases[1], 5)]
      } else {
        mappings = Array(zip(aliases, [Int32(3), Int32(4)]))
      }
      for (source, target) in mappings {
        guard permit(.spawn) else { return }
        guard posix_spawn_file_actions_adddup2(&actions, source, target) == 0 else {
          failed(.setup)
          return
        }
      }
      guard permit(.spawn) else { return }
      guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0
      else {
        failed(.setup)
        return
      }
      var spawned: pid_t = 0
      var spawnResult: Int32 = EINVAL
      if permit(.spawn) {
        let arguments: [String]
        var environmentStrings = ["PATH=/usr/bin:/bin:/usr/sbin:/sbin", "LANG=C", "LC_ALL=C"]
        switch command {
        case .fixture(let fixture, _):
          arguments = [fixture == .trueUtility ? "/usr/bin/true" : "/bin/cat"]
        case .backup(let launch):
          arguments = [launch.interpreter.path, "-I", "-B", launch.script.path, "--private-backup"]
          environmentStrings += [
            "PAPERLENS_BACKUP_REFERENCE=" + launch.reference,
            "PAPERLENS_BACKUP_RUN_ID=" + launch.namespace.runID,
          ]
        case .worker(let launch):
          arguments = [
            launch.interpreter.path, "-I", "-B", launch.script.path, "--official-sdk-worker",
          ]
          let namespace = launch.namespace.directoryURL.path
          environmentStrings = [
            "PATH=" + launch.interpreter.deletingLastPathComponent().path
              + ":/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG=C", "LC_ALL=C", "HOME=" + namespace,
            "CODEX_HOME=" + namespace + "/codex", "TMPDIR=" + namespace + "/tmp",
            "PAPERLENS_BROKER_RUN_ID=" + launch.namespace.runID,
            "PAPERLENS_BROKER_START_DEADLINE_NS=" + String(startupDeadline),
          ]
        }
        let strings = arguments + environmentStrings
        let allocated = strings.map { strdup($0) }
        if isWorker {
          lock.withLock {
            spawnStrings = allocated
            spawnArguments = arguments
            spawnEnvironment = environmentStrings
          }
        }
        if allocated.allSatisfy({ $0 != nil }), permit(.spawn) {
          var argv = Array(allocated.prefix(arguments.count)) + [nil]
          var environment = Array(allocated.dropFirst(arguments.count)) + [nil]
          spawnResult = argv.withUnsafeMutableBufferPointer { args in
            environment.withUnsafeMutableBufferPointer { env in
              posix_spawn(
                &spawned, arguments[0], &actions, &attributes, args.baseAddress!, env.baseAddress!)
            }
          }
          if spawnResult == 0 {
            lock.withLock { child = spawned }
            if isWorker {
              do {
                workerAtSpawn = try NativeBrokerABI.observeProcess(
                  pid: spawned,
                  storage: identityStorage, admit: { self.allowsIO })
              } catch {
                if allowsIO { failed(.identity) }
                return
              }
            }
            hooks.afterSpawn(spawned)
          }
        }
        if isWorker, !allowsIO { return }
        for pointer in allocated { free(pointer) }
        if isWorker { lock.withLock { spawnStrings.removeAll() } }
      }
      guard spawnResult == 0 else {
        failed(.spawn)
        return
      }
      guard permit(.spawn) else { return }
      guard posix_spawnattr_destroy(&attributes) == 0 else {
        failed(.setup)
        return
      }
      attributes = nil
      guard permit(.spawn) else { return }
      guard posix_spawn_file_actions_destroy(&actions) == 0 else {
        failed(.setup)
        return
      }
      actions = nil
      for fd in aliases { guard closeOwned(fd) else { return } }
      if isWorker {
        for fd in [pipes[0][0], pipes[1][1], pipes[2][1], lifecycleChild!] {
          guard closeOwned(fd) else { return }
        }
        guard allowsIO else { return }
        // No product handoff or ready publication before authenticated control slices.
        hooks.workerLaunched()
        guard allowsIO, let workerFD else { return }
        armControl(workerFD)
        let stderr = pipes[2][0]
        guard allowsIO else { return }
        let flags = fcntl(stderr, F_GETFL)
        guard allowsIO else { return }
        guard flags >= 0, fcntl(stderr, F_SETFL, flags | O_NONBLOCK) == 0 else {
          failed(.setup)
          return
        }
        guard allowsIO else { return }
        let source = DispatchSource.makeReadSource(fileDescriptor: stderr, queue: operation)
        lock.withLock { stderrSource = source }
        source.setEventHandler { [self] in
          var bytes = [UInt8](repeating: 0, count: 4096)
          for _ in 0..<4 {
            guard allowsIO else { return }
            let count = bytes.withUnsafeMutableBytes {
              Darwin.read(stderr, $0.baseAddress, $0.count)
            }
            let code = errno
            guard allowsIO else { return }
            if count == 0 {
              source.cancel()
              return
            }
            if count < 0 {
              if code == EINTR { continue }
              if code != EAGAIN { failed(.control) }
              return
            }
          }
        }
        source.activate()
        return
      }
      if runsUntilRevoked {
        for fd in [pipes[0][0], pipes[1][1], pipes[2][1]] {
          guard closeOwned(fd) else { return }
        }
        guard allowsIO else { return }
        let fd = pipes[2][0]
        let flags = fcntl(fd, F_GETFL)
        guard allowsIO else { return }
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
          failed(.setup)
          return
        }
        guard allowsIO else { return }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: operation)
        lock.withLock {
          stderrSource = source
          stderrJoined = false
        }
        source.setEventHandler { [self] in
          guard allowsIO else { return }
          var bytes = [UInt8](repeating: 0, count: 4096)
          for _ in 0..<4 {
            guard allowsIO else { return }
            let count = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            let code = errno
            guard allowsIO else { return }
            if count == 0 {
              let current = lock.withLock { () -> DispatchSourceRead? in
                let current = stderrSource
                stderrSource = nil
                return current
              }
              current?.cancel()
              return
            }
            if count < 0 {
              if code == EINTR { continue }
              if code != EAGAIN { failed(.setup) }
              return
            }
          }
        }
        source.setCancelHandler { [self] in
          lock.withLock { stderrJoined = true }
          beginRunningCleanup()
        }
        source.activate()
        lock.withLock {
          handoff = true
          endpoints = (pipes[1][0], pipes[0][1])
        }
        Task { @MainActor [self] in
          let consume = lock.withLock { () -> (@MainActor @Sendable (Core) -> Void)? in
            let consume = consumeTransport
            consumeTransport = nil
            return consume
          }
          consume?(self)
        }
        return
      }
      // Close the parent's child-side copies, then no-input EOF. No pipe read is needed.
      for fd in [pipes[0][0], pipes[1][1], pipes[2][1], pipes[0][1]] {
        guard closeOwned(fd) else { return }
      }
      guard permit(.wait) else { return }
      var status: Int32 = 0
      guard waitpid(spawned, &status, 0) == spawned else {
        failed(.wait)
        return
      }
      lock.withLock { reaped = true }
      for fd in [pipes[1][0], pipes[2][0]] { guard closeOwned(fd) else { return } }
      let proof = lock.withLock {
        Proof(checkedDescriptorCloses: closes, childReaped: reaped, childExitStatus: status)
      }
      select(.clean(proof))
    }
  }

  internal let core: Core
  internal init(runningFixture: Fixture, privateWorkingDirectory: URL, hooks: Hooks = Hooks()) {
    core = Core(
      command: .fixture(runningFixture, privateWorkingDirectory),
      deadline: UInt64.max, hooks: hooks, runningFixture: true)
  }
  internal func revoke() { core.revoke() }
  deinit { if core.runsUntilRevoked { core.revoke() } }
  /// Caller supplies the existing absolute monotonic cleanup deadline and a fresh 0700 cwd.
  /// No child exists until the sole `retire` invocation; no arbitrary executable/PID is accepted.
  public convenience init(
    fixture: Fixture, privateWorkingDirectory: URL,
    deadlineUptimeNanoseconds: UInt64
  ) {
    self.init(
      fixture: fixture, privateWorkingDirectory: privateWorkingDirectory,
      deadlineUptimeNanoseconds: deadlineUptimeNanoseconds, hooks: Hooks())
  }
  internal init(
    fixture: Fixture, privateWorkingDirectory: URL,
    deadlineUptimeNanoseconds: UInt64, hooks: Hooks
  ) {
    core = Core(
      command: .fixture(fixture, privateWorkingDirectory),
      deadline: deadlineUptimeNanoseconds, hooks: hooks)
  }
  internal init(
    backup: BackupLaunch, deadlineUptimeNanoseconds: UInt64, hooks: Hooks = Hooks()
  ) {
    core = Core(
      command: .backup(backup), deadline: deadlineUptimeNanoseconds, hooks: hooks)
  }
  internal init(
    worker: WorkerLaunch, deadlineUptimeNanoseconds: UInt64, hooks: Hooks = Hooks()
  ) {
    core = Core(command: .worker(worker), deadline: deadlineUptimeNanoseconds, hooks: hooks)
  }
  // Internal capture-layer entry only. Does not publish ready or start a product session.
  internal func launchWorker() {
    guard core.isWorker else { return }
    core.invoke()
  }
  public func retire() {
    if core.runsUntilRevoked { core.revoke() } else { core.invoke() }
  }
  public func observeTerminal(_ observer: @escaping @Sendable (Terminal) -> Void) {
    core.observe(observer)
  }
  public var terminal: Terminal? { core.lock.withLock { core.terminal } }

  internal var testingRetained: Bool {
    Roots.shared.lock.withLock { Roots.shared.owners[core.identity] === core }
  }
  internal var testingDescriptorCount: Int { core.lock.withLock { core.descriptors.count } }
  internal var testingChildExists: Bool { core.lock.withLock { core.child != nil } }
  internal var testingReaped: Bool { core.lock.withLock { core.reaped } }
  internal var testingRootWitness: @Sendable () -> Bool {
    let identity = core.identity
    return { Roots.shared.lock.withLock { Roots.shared.owners[identity] != nil } }
  }
  /// Fixture physical teardown only. Neither debt nor roots nor terminal/proof is modified.
  /// Parent must release any test gate first. This never runs on the terminal lane.
  internal func testingPhysicalTeardown(_ done: @escaping @Sendable (Bool) -> Void) {
    core.operation.async { [core] in
      let (child, reaped, fds) = core.lock.withLock { (core.child, core.reaped, core.descriptors) }
      let allWereOpen = fds.allSatisfy { fcntl($0, F_GETFD) >= 0 }
      for fd in fds { _ = Darwin.close(fd) }
      if let child, !reaped {
        _ = kill(child, SIGKILL)
        var status: Int32 = 0
        _ = waitpid(child, &status, 0)
      }
      let actual = core.lock.withLock { core.channel }
      if let actual {
        Task { @MainActor in
          actual.testingPhysicalTeardown()
          done(allWereOpen)
        }
      } else {
        done(allWereOpen)
      }
    }
  }
}
