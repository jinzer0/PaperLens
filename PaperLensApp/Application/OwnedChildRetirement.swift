import Darwin
import Dispatch
import Foundation

/// Fixture-only native direct-child retirement. This is not a Provider/SDK adapter.
public final class OwnedChildRetirement: @unchecked Sendable {
  public enum Fixture: Sendable { case trueUtility, cat }
  public enum Failure: Sendable, Equatable {
    case deadline, setup, spawn, close, wait, admissionBlocked
  }
  public struct Proof: Sendable, Equatable {
    public let checkedDescriptorCloses: Int
    public let childReaped: Bool
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

  private final class Core: @unchecked Sendable {
    let identity = UUID()
    let fixture: Fixture
    let cwd: URL
    let deadline: UInt64
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

    init(fixture: Fixture, cwd: URL, deadline: UInt64, hooks: Hooks) {
      self.fixture = fixture
      self.cwd = cwd
      self.deadline = deadline
      self.hooks = hooks
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
      terminalLane.async { for callback in callbacks { callback(selected) } }
    }
    func permit(_ effect: Effect) -> Bool {
      hooks.before(effect)
      return withinDeadline()
    }
    func withinDeadline() -> Bool {
      if DispatchTime.now().uptimeNanoseconds >= deadline {
        select(.unknown(.deadline))
        return false
      }
      return lock.withLock { terminal == nil }
    }
    func failed(_ failure: Failure) { select(.unknown(failure)) }
    func closeOwned(_ descriptor: Int32) -> Bool {
      guard permit(.close) else { return false }
      let target: Int32 = hooks.closeFault() ? -1 : descriptor
      guard withinDeadline() else { return false }
      // No retry, including EINTR: uncertain descriptor identity remains rooted.
      guard Darwin.close(target) == 0, target == descriptor else {
        failed(.close)
        return false
      }
      lock.withLock {
        descriptors.remove(descriptor)
        closes += 1
      }
      return true
    }
    func run() {
      guard permit(.pipe) else { return }
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
      guard posix_spawn_file_actions_addchdir_np(&actions, cwd.path) == 0 else {
        failed(.setup)
        return
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
        let executable = fixture == .trueUtility ? "/usr/bin/true" : "/bin/cat"
        let strings = [executable, "PATH=/usr/bin:/bin:/usr/sbin:/sbin", "LANG=C", "LC_ALL=C"]
        let allocated = strings.map { strdup($0) }
        if allocated.allSatisfy({ $0 != nil }), permit(.spawn) {
          var argv = [allocated[0], nil]
          var environment = [allocated[1], allocated[2], allocated[3], nil]
          spawnResult = argv.withUnsafeMutableBufferPointer { args in
            environment.withUnsafeMutableBufferPointer { env in
              posix_spawn(
                &spawned, executable, &actions, &attributes, args.baseAddress!, env.baseAddress!)
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
      let proof = lock.withLock { Proof(checkedDescriptorCloses: closes, childReaped: reaped) }
      select(.clean(proof))
    }
  }

  private let core: Core
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
      fixture: fixture, cwd: privateWorkingDirectory,
      deadline: deadlineUptimeNanoseconds, hooks: hooks)
  }
  public func retire() { core.invoke() }
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
      done(allWereOpen)
    }
  }
}
