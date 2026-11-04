import Darwin
import Foundation

private final class PythonBridge: NSObject, ProviderFrameTransport, @unchecked Sendable {
  private let queue = DispatchQueue(label: "PaperLens.ProviderAgent.bridge")
  private let admission = NSLock()
  private var admittedFrames = 0
  private var admittedBytes = 0
  private var accepting = true
  private var maxQueuedFrames = 0
  private var maxQueuedBytes = 0
  private var connection: NSXPCConnection?
  private var pid: pid_t = 0
  private var input: Int32 = -1
  private var output: Int32 = -1
  private var errors: Int32 = -1
  private var reader: DispatchSourceRead?
  private var stderrReader: DispatchSourceRead?
  private var writer: DispatchSourceWrite?
  private var exitWatcher: DispatchSourceProcess?
  private var pending: [Data] = []
  private var offset = 0
  private var outgoingFrames = 0
  private var outgoingBytes = 0
  private let decoder = ProviderFrameDecoder()
  private var closed = false
  private var runtimeDirectory: TopologyOwnedFixtures?
  private var identityRequests: [String: String] = [:]
  private var identityRun: String?

  init(connection: NSXPCConnection) {
    self.connection = connection
    super.init()
  }

  func start() {
    queue.async {
      guard self.launch() else {
        self.stop()
        return
      }
      self.connection?.resume()
    }
  }

  func disconnect() { queue.async { self.stop() } }

  func sendFrame(_ frame: Data) {
    // Bound admission before dispatch, not just after an unbounded queue.
    admission.lock()
    let wasAccepting = accepting
    let permitted =
      accepting && frame.count <= ProviderRPC.maxFrameBytes && admittedFrames < maxQueuedFrames
      && admittedBytes + frame.count <= maxQueuedBytes
    if permitted {
      admittedFrames += 1
      admittedBytes += frame.count
    } else {
      accepting = false
    }
    admission.unlock()
    guard permitted else {
      if wasAccepting { disconnect() }
      return
    }
    queue.async {
      guard !self.closed else {
        self.release(frame.count)
        return
      }
      do {
        // The Python endpoint owns semantic admission and its bounded
        // unknownMethod/invalidParams terminals; native checks are limited to
        // framing and correlation of the identity candidate below.
        let object = try ProviderRPC.decode(frame)
        if object["method"] as? String == "topology.identity" {
          // Semantic errors still belong to Python. Correlate only a request
          // accepted by the central closed schema, never an arbitrary payload.
          if (try? ProviderRPC.validateRequest(object)) != nil,
            let identifier = object["id"] as? String,
            let params = object["params"] as? [String: Any],
            let run = params["runID"] as? String
          {
            guard self.identityRequests[identifier] == nil else {
              throw ProviderRPCError.protocolViolation
            }
            self.identityRequests[identifier] = run
          }
        }
        self.pending.append(frame)
        self.flush()
      } catch {
        self.release(frame.count)
        self.stop()
      }
    }
  }

  private func release(_ bytes: Int) {
    admission.lock()
    admittedFrames -= 1
    admittedBytes -= bytes
    admission.unlock()
  }

  private func launch() -> Bool {
    guard let container = TopologyIdentity.container(TopologyIdentity.agent),
      let contract = Bundle.main.url(forResource: "contract", withExtension: "json")
    else { return false }
    do {
      try ProviderRPC.configure(contractURL: contract)
      let frames = try ProviderRPC.limit("maxQueuedFrames")
      let bytes = try ProviderRPC.limit("maxQueuedBytes")
      admission.lock()
      maxQueuedFrames = frames
      maxQueuedBytes = bytes
      admission.unlock()
    } catch { return false }
    let root = container.appendingPathComponent(
      "Library/Application Support/PaperLensTopologyRuntime")
    let id = UUID().uuidString.lowercased()
    guard let own = TopologyOwnedFixtures(root: root, runID: id) else { return false }
    runtimeDirectory = own
    guard own.prepareBackupExclusion() else { return false }
    guard own.prepareRuntimeDirectories() else { return false }
    guard own.hasBackupExclusion() else { return false }
    let privateRoot = root.appendingPathComponent(id)
    let macOS = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS")
    let interpreter = macOS.appendingPathComponent("python3")
    let script = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/agent.py")
    // The signed interpreter may be an internal framework symlink. No host fallback.
    let resolved = interpreter.resolvingSymlinksInPath().path
    guard resolved.hasPrefix(Bundle.main.bundleURL.path + "/Contents/"),
      FileManager.default.isExecutableFile(atPath: interpreter.path),
      FileManager.default.fileExists(atPath: script.path)
    else { return false }
    var stdinPipe: [Int32] = [-1, -1]
    var stdoutPipe: [Int32] = [-1, -1]
    var stderrPipe: [Int32] = [-1, -1]
    guard pipe(&stdinPipe) == 0 else { return false }
    guard pipe(&stdoutPipe) == 0 else {
      stdinPipe.forEach { close($0) }
      return false
    }
    guard pipe(&stderrPipe) == 0 else {
      (stdinPipe + stdoutPipe).forEach { close($0) }
      return false
    }
    let all = stdinPipe + stdoutPipe + stderrPipe
    all.forEach { _ = fcntl($0, F_SETFD, FD_CLOEXEC) }
    var actions: posix_spawn_file_actions_t?
    var attributes: posix_spawnattr_t?
    guard posix_spawn_file_actions_init(&actions) == 0 else {
      all.forEach { close($0) }
      return false
    }
    defer { posix_spawn_file_actions_destroy(&actions) }
    guard posix_spawnattr_init(&attributes) == 0 else {
      all.forEach { close($0) }
      return false
    }
    defer { posix_spawnattr_destroy(&attributes) }
    var setup = posix_spawn_file_actions_adddup2(&actions, stdinPipe[0], STDIN_FILENO)
    setup |= posix_spawn_file_actions_adddup2(&actions, stdoutPipe[1], STDOUT_FILENO)
    setup |= posix_spawn_file_actions_adddup2(&actions, stderrPipe[1], STDERR_FILENO)
    if #available(macOS 26.0, *) {
      setup |= posix_spawn_file_actions_addchdir(
        &actions, privateRoot.appendingPathComponent("work").path)
    } else {
      setup |= posix_spawn_file_actions_addchdir_np(
        &actions, privateRoot.appendingPathComponent("work").path)
    }
    for fd in all { setup |= posix_spawn_file_actions_addclose(&actions, fd) }
    // Establish the owned group atomically at spawn, before Python can spawn
    // CLI. Python also calls setpgid(0,0); neither process shares Main's group.
    setup |= posix_spawnattr_setpgroup(&attributes, 0)
    setup |= posix_spawnattr_setflags(
      &attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
    let argv =
      [interpreter.path, "-I", "-B", script.path].map {
        $0.withCString { strdup($0) }
      } + [nil]
    let env =
      [
        "HOME=\(container.path)", "TMPDIR=\(privateRoot.appendingPathComponent("tmp").path)",
        "CODEX_HOME=\(privateRoot.appendingPathComponent("codex").path)", "PATH=\(macOS.path)",
        "LANG=C", "LC_ALL=C",
      ].map { value in value.withCString { strdup($0) } } + [nil]
    defer {
      argv.forEach { free($0) }
      env.forEach { free($0) }
    }
    guard setup == 0, argv.dropLast().allSatisfy({ $0 != nil }),
      env.dropLast().allSatisfy({ $0 != nil })
    else {
      all.forEach { close($0) }
      return false
    }
    var child: pid_t = 0
    let result = argv.withUnsafeBufferPointer { arguments in
      env.withUnsafeBufferPointer { environment in
        posix_spawn(
          &child, interpreter.path, &actions, &attributes,
          UnsafeMutablePointer(mutating: arguments.baseAddress!),
          UnsafeMutablePointer(mutating: environment.baseAddress!))
      }
    }
    close(stdinPipe[0])
    close(stdoutPipe[1])
    close(stderrPipe[1])
    guard result == 0 else {
      close(stdinPipe[1])
      close(stdoutPipe[0])
      close(stderrPipe[0])
      return false
    }
    pid = child
    input = stdinPipe[1]
    output = stdoutPipe[0]
    errors = stderrPipe[0]
    for fd in [input, output, errors] {
      guard fcntl(fd, F_SETFL, O_NONBLOCK) >= 0 else { return false }
    }
    guard fcntl(input, F_SETNOSIGPIPE, 1) >= 0 else { return false }
    let readSource = DispatchSource.makeReadSource(fileDescriptor: output, queue: queue)
    readSource.setEventHandler { [weak self] in self?.readOutput() }
    reader = readSource
    readSource.resume()
    let errorSource = DispatchSource.makeReadSource(fileDescriptor: errors, queue: queue)
    errorSource.setEventHandler { [weak self] in self?.discardErrors() }
    stderrReader = errorSource
    errorSource.resume()
    let exitSource = DispatchSource.makeProcessSource(
      identifier: child, eventMask: .exit, queue: queue)
    exitSource.setEventHandler { [weak self] in self?.stop() }
    exitWatcher = exitSource
    exitSource.resume()
    return true
  }

  private func flush() {
    guard !closed else { return }
    while let frame = pending.first {
      let count = frame.withUnsafeBytes {
        Darwin.write(input, $0.baseAddress!.advanced(by: offset), frame.count - offset)
      }
      if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
        if writer == nil {
          let source = DispatchSource.makeWriteSource(fileDescriptor: input, queue: queue)
          source.setEventHandler { [weak self] in self?.flush() }
          writer = source
          source.resume()
        }
        return
      }
      if count < 0 && errno == EINTR { continue }
      guard count > 0 else {
        stop()
        return
      }
      offset += count
      if offset == frame.count {
        pending.removeFirst()
        offset = 0
        release(frame.count)
      }
    }
    writer?.cancel()
    writer = nil
  }

  private func readOutput() {
    guard !closed else { return }
    // One bounded read per dispatch event; decoder never accepts oversized prefixes.
    var bytes = [UInt8](repeating: 0, count: 4096)
    let count = read(output, &bytes, bytes.count)
    if count < 0 && (errno == EAGAIN || errno == EINTR) { return }
    if count == 0 {
      do { try decoder.finish() } catch {
        stop()
        return
      }
      stop()
      return
    }
    guard count > 0 else {
      stop()
      return
    }
    do {
      let frames = try decoder.feed(Data(bytes.prefix(count)))
      guard outgoingFrames + frames.count <= maxQueuedFrames,
        outgoingBytes + frames.reduce(0, { $0 + $1.count }) <= maxQueuedBytes,
        let connection,
        let remote = connection.remoteObjectProxyWithErrorHandler({ [weak self] _ in
          self?.disconnect()
        }) as? ProviderFrameReceiver
      else {
        stop()
        return
      }
      for frame in frames {
        try validateIdentity(frame)
        outgoingFrames += 1
        outgoingBytes += frame.count
        remote.receiveFrame(frame)
        let size = frame.count
        connection.scheduleSendBarrierBlock { [weak self] in
          guard let self else { return }
          self.queue.async {
            self.outgoingFrames -= 1
            self.outgoingBytes -= size
          }
        }
      }
    } catch { stop() }
  }

  private func validateIdentity(_ frame: Data) throws {
    let object = try ProviderRPC.decode(frame)
    guard let identifier = object["id"] as? String else {
      throw ProviderRPCError.protocolViolation
    }
    let result = object["result"] as? [String: Any]
    guard let run = identityRequests.removeValue(forKey: identifier) else {
      if result?["bridgePID"] != nil || result?["pythonPID"] != nil {
        throw ProviderRPCError.protocolViolation
      }
      return
    }
    try ProviderRPC.validateTerminal(object, method: "topology.identity")
    // Python owns unavailable/timeout/cancel admission. Only successful
    // candidates establish a binding, and it cannot move to another run.
    guard object["kind"] as? String == "result" else { return }
    guard identityRun == nil || identityRun == run,
      let bridge = result?["bridgePID"] as? NSNumber,
      let python = result?["pythonPID"] as? NSNumber,
      bridge.int32Value == getpid(), python.int32Value == pid, pid > 0
    else { throw ProviderRPCError.protocolViolation }
    var info = siginfo_t()
    var status: Int32
    repeat {
      status = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT)
    } while status < 0 && errno == EINTR
    guard status == 0, info.si_pid == 0, getpgid(pid) == pid, kill(pid, 0) == 0 else {
      throw ProviderRPCError.protocolViolation
    }
    identityRun = run
  }

  private func discardErrors() {
    guard !closed else { return }
    var bytes = [UInt8](repeating: 0, count: 4096)
    let count = read(errors, &bytes, bytes.count)
    if count == 0 {
      stderrReader?.cancel()
      stderrReader = nil
    } else if count < 0 && errno != EAGAIN && errno != EINTR {
      stop()
    }
  }

  private func stop() {
    guard !closed else { return }
    closed = true
    admission.lock()
    accepting = false
    admission.unlock()
    reader?.cancel()
    reader = nil
    stderrReader?.cancel()
    stderrReader = nil
    writer?.cancel()
    writer = nil
    exitWatcher?.cancel()
    exitWatcher = nil
    if input >= 0 {
      close(input)
      input = -1
    }
    if pid > 0 {
      // No Foundation Process reaper: this PID remains ours until waitpid.
      // WNOWAIT checks liveness without releasing PID/group ownership.
      var info = siginfo_t()
      var status: Int32
      repeat {
        status = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT)
      } while status < 0 && errno == EINTR
      if status == 0 && (getpgid(pid) == pid || info.si_pid == pid) {
        // Even an exited, unreaped leader still owns this group; kill
        // surviving CLI descendants before reaping/releasing the PID.
        // The group was created atomically by POSIX_SPAWN_SETPGROUP.
        kill(-pid, SIGKILL)
      } else if status == 0 && info.si_pid == 0 {
        kill(pid, SIGKILL)
      }
      var childStatus: Int32 = 0
      while waitpid(pid, &childStatus, 0) < 0 && errno == EINTR {}
      pid = 0
    }
    // After group death, drain only a bounded amount and discard everything.
    for fd in [output, errors] where fd >= 0 {
      var bytes = [UInt8](repeating: 0, count: 4096)
      for _ in 0..<64 { if read(fd, &bytes, bytes.count) <= 0 { break } }
      close(fd)
    }
    output = -1
    errors = -1
    for frame in pending { release(frame.count) }
    pending.removeAll()
    identityRequests.removeAll()
    identityRun = nil
    let old = connection
    connection = nil
    old?.invalidate()
    if let own = runtimeDirectory, own.permitsNamespaceMutation {
      for name in ["tmp", "codex", "work"] { unlinkat(own.descriptor, name, AT_REMOVEDIR) }
      own.cleanup()
    }
    runtimeDirectory = nil
  }
}

private final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
  func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection)
    -> Bool
  {
    connection.setCodeSigningRequirement(TopologyIdentity.requirement(TopologyIdentity.main))
    connection.exportedInterface = NSXPCInterface(with: ProviderFrameTransport.self)
    connection.remoteObjectInterface = NSXPCInterface(with: ProviderFrameReceiver.self)
    let bridge = PythonBridge(connection: connection)
    connection.exportedObject = bridge
    connection.interruptionHandler = { [weak bridge] in bridge?.disconnect() }
    connection.invalidationHandler = { [weak bridge] in bridge?.disconnect() }
    bridge.start()
    return true
  }
}

@main
private enum ProviderServiceMain {
  static func main() {
    let delegate = ListenerDelegate()
    let listener = NSXPCListener.service()
    listener.delegate = delegate
    withExtendedLifetime(delegate) {
      listener.resume()
    }
  }
}
