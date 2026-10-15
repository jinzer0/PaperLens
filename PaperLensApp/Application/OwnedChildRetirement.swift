import Darwin
import Dispatch
import Foundation

/// Implemented by the actual transport owner in the Main-only adapter, never a proof payload.
@MainActor
internal protocol OwnedChildTransport: AnyObject, Sendable {
  var ownerIdentity: UUID { get }
  var checkedEndpointsClosed: Bool { get }
  func requestClose()
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
  internal enum Command: Sendable {
    case fixture(Fixture, URL)
    case backup(BackupLaunch)
  }
  public enum Failure: Error, Sendable, Equatable {
    case deadline, setup, spawn, close, wait, admissionBlocked, revoked
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
  internal enum Effect: Sendable { case pipe, spawn, close, wait }
  internal struct Hooks: Sendable {
    var before: @Sendable (Effect) -> Void = { _ in }
    var afterSpawn: @Sendable (pid_t) -> Void = { _ in }
    // Private EBADF injection leaves the real descriptor owned, never certifies closure.
    var closeFault: @Sendable () -> Bool = { false }
    var afterPipeFault: @Sendable () -> Bool = { false }
    var beforeChannelSetup: @Sendable () -> Void = {}
    var afterClose: @Sendable () -> Void = {}
  }

  // Lifetime roots, not a second product store. Unknown debt permanently closes admission.
  private final class Roots: @unchecked Sendable {
    static let shared = Roots()
    let lock = NSLock()
    var owners: [UUID: Core] = [:]
    var debt = false
    func admit(_ core: Core) -> Bool {
      lock.withLock {
        guard !debt else { return false }
        owners[core.identity] = core
        return true
      }
    }
    func finish(_ core: Core, clean: Bool) {
      lock.withLock {
        if clean { owners.removeValue(forKey: core.identity) } else { debt = true }
      }
    }
  }

  internal final class Core: @unchecked Sendable {
    let identity = UUID()
    let command: Command
    var deadline: UInt64
    let runningFixture: Bool
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
    var child: pid_t?
    var reaped = false
    var closes = 0
    // Setup handles are real ownership too and survive partial setup/expiry.
    var actions: posix_spawn_file_actions_t?
    var attributes: posix_spawnattr_t?
    var startupTimer: DispatchSourceTimer?
    var revoked = false
    var handoff = false
    var endpoints: (Int32, Int32)?
    var channel: (any OwnedChildTransport)?
    var stderrSource: DispatchSourceRead?
    var stderrJoined = true
    var cleanupQueued = false
    var readyFailure: (@MainActor @Sendable (Failure) -> Void)?
    var consumeTransport: (@MainActor @Sendable (Core) -> Void)?

    init(command: Command, deadline: UInt64, hooks: Hooks, runningFixture: Bool = false) {
      self.command = command
      self.deadline = deadline
      self.hooks = hooks
      self.runningFixture = runningFixture
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
      operation.async { [self] in run() }
    }
    @discardableResult
    func revoke(startupOnly: Bool = false) -> UInt64 {
      guard runningFixture else {
        invoke()
        return lock.withLock { deadline }
      }
      var needsAdmission = false
      let first = lock.withLock { () -> Bool in
        guard !revoked else { return false }
        if startupOnly {
          guard startupTimer != nil, DispatchTime.now().uptimeNanoseconds >= deadline else {
            return false
          }
        }
        needsAdmission = !invoked
        invoked = true
        revoked = true
        deadline = DispatchTime.now().uptimeNanoseconds + 300_000_000
        return true
      }
      if first {
        if needsAdmission, !Roots.shared.admit(self) {
          select(.unknown(.admissionBlocked))
          return lock.withLock { deadline }
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
        operation.async { [self] in beginRunningCleanup() }
      }
      return lock.withLock { deadline }
    }
    func reservedEndpoints() throws -> (Int32, Int32) {
      try lock.withLock {
        guard handoff, let endpoints else { throw Failure.setup }
        return endpoints
      }
    }
    @MainActor
    func markRunning() -> Bool {
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
      lock.withLock { timer = source }
      source.setEventHandler { [self] in select(.unknown(.deadline)) }
      source.schedule(deadline: DispatchTime(uptimeNanoseconds: deadline), leeway: .nanoseconds(0))
      source.resume()
      operation.async { [self] in run() }
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
        if case .clean = proposed, DispatchTime.now().uptimeNanoseconds >= deadline {
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
      let source = lock.withLock { () -> DispatchSourceTimer? in
        let source = timer
        timer = nil
        return source
      }
      source?.cancel()
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
      if runningFixture, lock.withLock({ revoked }) {
        switch effect {
        case .pipe, .spawn: return false
        case .close, .wait: break
        }
      }
      hooks.before(effect)
      if runningFixture, lock.withLock({ revoked }) {
        switch effect {
        case .pipe, .spawn: return false
        case .close, .wait: break
        }
      }
      return withinDeadline()
    }
    func withinDeadline() -> Bool {
      if DispatchTime.now().uptimeNanoseconds >= lock.withLock({ deadline }) {
        if runningFixture, !lock.withLock({ revoked }) {
          revoke(startupOnly: true)
          return false
        }
        select(.unknown(.deadline))
        return false
      }
      return lock.withLock { terminal == nil }
    }
    func failed(_ failure: Failure) {
      if runningFixture { revoke() }
      select(.unknown(failure))
    }
    func closeOwned(_ descriptor: Int32) -> Bool {
      guard permit(.close) else { return false }
      let target: Int32 = hooks.closeFault() ? -1 : descriptor
      guard withinDeadline() else { return false }
      // No retry, including EINTR: uncertain descriptor identity remains rooted.
      guard Darwin.close(target) == 0, target == descriptor else {
        failed(.close)
        return false
      }
      hooks.afterClose()
      lock.withLock {
        descriptors.remove(descriptor)
        closes += 1
      }
      return withinDeadline()
    }
    func run() {
      guard permit(.pipe) else { return }
      var aliases: [Int32] = []
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
        guard pair.allSatisfy({ $0 > STDERR_FILENO }) else {
          failed(.setup)
          return
        }
        if hooks.afterPipeFault() {
          failed(.setup)
          return
        }
        for fd in pair {
          guard permit(.pipe) else { return }
          guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else {
            failed(.setup)
            return
          }
        }
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
      case .backup:
        directoryResult = posix_spawn_file_actions_addfchdir_np(&actions, aliases[0])
      }
      guard directoryResult == 0 else {
        failed(.setup)
        return
      }
      // High aliases cannot collide with stdio sources or the fixed metadata targets.
      for (source, target) in zip(aliases, [Int32(3), Int32(4)]) {
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
        }
        let strings = arguments + environmentStrings
        let allocated = strings.map { strdup($0) }
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
            hooks.afterSpawn(spawned)
          }
        }
        for pointer in allocated { free(pointer) }
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
      if runningFixture {
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
  @discardableResult internal func revoke() -> UInt64 { core.revoke() }
  deinit { if core.runningFixture { core.revoke() } }
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
  public func retire() {
    if core.runningFixture { core.revoke() } else { core.invoke() }
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
