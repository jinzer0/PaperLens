import Darwin
import Dispatch
import Foundation

#if SWIFT_PACKAGE
  import ProviderRPC
#endif

extension OwnedChildRetirement {
  @MainActor
  public func startProduct(
    startDeadlineUptimeNanoseconds: UInt64,
    ready: @escaping @MainActor @Sendable (Result<AgentConnectionLifecycle, Failure>) -> Void
  ) {
    guard core.isWorker else {
      ready(.failure(.setup))
      return
    }
    core.begin(
      startDeadlineUptimeNanoseconds,
      consume: { core in
        do {
          let channel = try OwnedPipeAgentRPCChannel.consumePipes(from: core)
          guard core.allowsIO else { return }
          let lifecycle = try AgentConnectionLifecycle(ownedPipe: channel, mode: .product)
          channel.retainSession(lifecycle)
          lifecycle.bindOwner(
            permit: { core.allowsIO },
            handshake: { [weak lifecycle] in
              guard let lifecycle, core.markRunning() else { return }
              ready(.success(lifecycle))
            }, failure: { core.revoke() })
          guard core.allowsIO else { return }
          try lifecycle.start()
        } catch { core.failed(.setup) }
      }, failure: { ready(.failure($0)) })
  }

  @MainActor
  internal func start(
    startDeadlineUptimeNanoseconds: UInt64,
    ready: @escaping @MainActor @Sendable (Result<OwnedPipeAgentRPCChannel, Failure>) -> Void
  ) {
    guard !core.isWorker else {
      ready(.failure(.control))
      return
    }
    core.begin(
      startDeadlineUptimeNanoseconds,
      consume: { core in
        do {
          let actual = try OwnedPipeAgentRPCChannel.consumePipes(from: core)
          if core.markRunning() { ready(.success(actual)) }
        } catch { core.revoke() }
      }, failure: { ready(.failure($0)) })
  }

  @MainActor internal var testingChannel: OwnedPipeAgentRPCChannel? {
    core.lock.withLock { core.channel as? OwnedPipeAgentRPCChannel }
  }
}

/// The caller exclusively transfers these handles after preflight. fstat cannot attest
/// absence of external dup aliases, readers, writers, handlers or closers.
@MainActor
public final class OwnedPipeAgentRPCChannel: AgentRPCChannel, OwnedChildTransport {
  public enum Failure: Error, Equatable {
    case invalidEndpoint
    case setup(Int32)
    case busy, frameTooLarge, closed
    case io(Int32)
    case closureDebt
  }
  public enum EndpointClosure: Equatable { case pending, closed, unknown }
  public struct ClosureOutcome: Equatable {
    public let read: EndpointClosure
    public let write: EndpointClosure
    public var bothClosed: Bool { read == .closed && write == .closed }
  }

  private let owner: Owner
  private var retainedSession: (any OwnedChildSession)?
  internal func retainSession(_ session: any OwnedChildSession) {
    precondition(retainedSession == nil)
    retainedSession = session
  }
  public var closureOutcome: ClosureOutcome { owner.outcome }
  internal var checkedEndpointsClosed: Bool { owner.outcome.bothClosed }

  public init(readStdout: FileHandle, writeStdin: FileHandle) throws {
    try Self.validate(readStdout, writeStdin)
    owner = Owner(readStdout: readStdout, writeStdin: writeStdin, close: { try $0.close() })
    try owner.setup()
  }

  // Only for local owned-FD tests. Throwing close retains the actual handle as debt.
  init(
    readStdout: FileHandle, writeStdin: FileHandle,
    close: @escaping (FileHandle) throws -> Void
  ) throws {
    try Self.validate(readStdout, writeStdin)
    owner = Owner(readStdout: readStdout, writeStdin: writeStdin, close: close)
    try owner.setup()
  }

  /// Callback lives on the actual retained ownership root, not on the facade.
  public func observeClosure(_ callback: @escaping (ClosureOutcome) -> Void) {
    owner.onClosure = callback
    if owner.finished { callback(owner.outcome) }
  }

  internal var lifecycleBound: Bool { owner.onLifecycleClosure != nil }

  internal func bindLifecycleClosure(_ callback: @escaping (ClosureOutcome) -> Void) {
    precondition(!lifecycleBound)
    owner.onLifecycleClosure = callback
    if owner.finished { callback(owner.outcome) }
  }

  public func write(_ frame: Data) async throws { try await owner.write(frame) }
  public func read() async throws -> Data? { try await owner.read() }
  public func requestClose() { owner.shutdown() }

  internal static func consumePipes(from core: OwnedChildRetirement.Core) throws
    -> OwnedPipeAgentRPCChannel
  {
    let endpoints = try core.reservedEndpoints()
    let read = FileHandle(fileDescriptor: endpoints.0, closeOnDealloc: false)
    let write = FileHandle(fileDescriptor: endpoints.1, closeOnDealloc: false)
    let channel = OwnedPipeAgentRPCChannel(read: read, write: write, core: core)
    core.capture(channel)
    guard core.allowsIO else { throw Failure.closed }
    try validate(read, write, permit: { core.allowsIO })
    core.hooks.beforeChannelSetup()
    guard core.allowsIO else { throw Failure.closed }
    try channel.owner.setup()
    return channel
  }

  private init(read: FileHandle, write: FileHandle, core: OwnedChildRetirement.Core) {
    owner = Owner(
      readStdout: read, writeStdin: write,
      close: { [weak core] handle in
        if core?.hooks.closeFault() == true {
          _ = Darwin.close(-1)
          throw Failure.io(EBADF)
        }
        try handle.close()
        core?.hooks.afterClose()
      }, internalClosure: { [weak core] identity in core?.channelClosed(ownerIdentity: identity) },
      standaloneRetention: false)
    owner.core = core
  }

  internal var ownerIdentity: UUID { owner.id }

  internal func releaseCleanRoot() {
    guard let core = owner.core,
      core.lock.withLock({
        if case .clean? = core.terminal { return true }
        return false
      }),
      owner.outcome.bothClosed
    else { return }
    owner.releaseCleanRoot()
  }

  internal func testingPhysicalTeardown() {
    // Fixture hygiene only: never updates closure outcome, roots, debt or lease.
    if owner.outcome.read != .closed { try? owner.readHandle.close() }
    if owner.outcome.write != .closed { try? owner.writeHandle.close() }
  }

  internal func quiesceNotifications() {
    owner.quiesceNotifications()
  }

  internal var testingReadinessSourceCount: Int { owner.readinessSourceCount }

  private static func validate(
    _ read: FileHandle, _ write: FileHandle,
    permit: () -> Bool = { true }
  ) throws {
    let r = read.fileDescriptor
    let w = write.fileDescriptor
    var rs = stat()
    var ws = stat()
    guard r > STDERR_FILENO, w > STDERR_FILENO, r != w,
      permit(), fstat(r, &rs) == 0, permit(), fstat(w, &ws) == 0,
      (rs.st_mode & S_IFMT) == S_IFIFO, (ws.st_mode & S_IFMT) == S_IFIFO,
      rs.st_dev != ws.st_dev || rs.st_ino != ws.st_ino
    else { throw Failure.invalidEndpoint }
    guard permit() else { throw Failure.closed }
    let rf = fcntl(r, F_GETFL)
    guard permit() else { throw Failure.closed }
    let wf = fcntl(w, F_GETFL)
    guard rf >= 0, wf >= 0, rf & O_ACCMODE == O_RDONLY,
      wf & O_ACCMODE == O_WRONLY
    else { throw Failure.invalidEndpoint }
    var readInfo = pipe_fdinfo()
    var writeInfo = pipe_fdinfo()
    let infoSize = Int32(MemoryLayout<pipe_fdinfo>.size)
    guard permit(),
      proc_pidfdinfo(getpid(), r, PROC_PIDFDPIPEINFO, &readInfo, infoSize) == infoSize,
      permit(), proc_pidfdinfo(getpid(), w, PROC_PIDFDPIPEINFO, &writeInfo, infoSize) == infoSize,
      readInfo.pipeinfo.pipe_handle != 0, readInfo.pipeinfo.pipe_peerhandle != 0,
      writeInfo.pipeinfo.pipe_handle != 0, writeInfo.pipeinfo.pipe_peerhandle != 0,
      readInfo.pipeinfo.pipe_handle != writeInfo.pipeinfo.pipe_handle,
      readInfo.pipeinfo.pipe_handle != writeInfo.pipeinfo.pipe_peerhandle,
      readInfo.pipeinfo.pipe_peerhandle != writeInfo.pipeinfo.pipe_handle
    else { throw Failure.invalidEndpoint }
  }

  @MainActor
  private final class Owner {
    // Retains genuine ownership through suspended IO and unknown close outcomes.
    // No retry, fd-number probe or destructor can discharge this debt.
    private static var retained: [UUID: Owner] = [:]
    let id = UUID()
    let readHandle: FileHandle
    let writeHandle: FileHandle
    let closeHandle: (FileHandle) throws -> Void
    var outcome = ClosureOutcome(read: .pending, write: .pending)
    var onClosure: ((ClosureOutcome) -> Void)?
    var onLifecycleClosure: ((ClosureOutcome) -> Void)?
    var finished = false
    var core: OwnedChildRetirement.Core?
    let internalClosure: ((UUID) -> Void)?
    private var ioPermitted: Bool { core?.allowsIO ?? true }
    private var revoked = false
    private var generation: UInt64 = 0
    private var readWait: CheckedContinuation<Data?, Error>?
    private var writeWait: CheckedContinuation<Void, Error>?
    private var reading = false
    private var writing = false
    private var readOperation = UUID()
    private var writeOperation = UUID()
    private var frame: Data?
    private var offset = 0
    private var eof = false
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var readToken: UInt64 = 0
    private var writeToken: UInt64 = 0
    private var cancellingSources = 0
    private var activeIO = 0
    var readinessSourceCount: Int { (readSource == nil ? 0 : 1) + (writeSource == nil ? 0 : 1) }

    func releaseCleanRoot() {
      core = nil
      Self.retained[id] = nil
    }

    init(
      readStdout: FileHandle, writeStdin: FileHandle,
      close: @escaping (FileHandle) throws -> Void,
      internalClosure: ((UUID) -> Void)? = nil,
      standaloneRetention: Bool = true
    ) {
      readHandle = readStdout
      writeHandle = writeStdin
      closeHandle = close
      self.internalClosure = internalClosure
      if standaloneRetention { Self.retained[id] = self }
    }

    func setup() throws {
      do {
        for handle in [readHandle, writeHandle] {
          guard ioPermitted else { throw Failure.closed }
          let fd = handle.fileDescriptor
          let flags = fcntl(fd, F_GETFL)
          guard ioPermitted else { throw Failure.closed }
          guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw Failure.setup(errno)
          }
          guard ioPermitted else { throw Failure.closed }
          let actual = fcntl(fd, F_GETFL)
          guard actual >= 0, actual == flags | O_NONBLOCK else { throw Failure.setup(errno) }
        }
        // Public Darwin sys/fcntl.h commands (not a socket option).
        let setNoSIGPIPE: Int32 = 73
        let getNoSIGPIPE: Int32 = 74
        guard ioPermitted else { throw Failure.closed }
        guard fcntl(writeHandle.fileDescriptor, setNoSIGPIPE, 1) == 0,
          ioPermitted, fcntl(writeHandle.fileDescriptor, getNoSIGPIPE) == 1
        else {
          throw Failure.setup(errno)
        }
      } catch {
        shutdown()
        throw error
      }
    }

    func read() async throws -> Data? {
      guard !revoked, ioPermitted else {
        throw finished && !outcome.bothClosed ? Failure.closureDebt : Failure.closed
      }
      guard !reading else { throw Failure.busy }
      try Task.checkCancellation()
      reading = true
      defer { reading = false }
      let operation = UUID()
      readOperation = operation
      return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
          readWait = continuation
          pumpRead()
        }
      } onCancel: {
        Task { @MainActor in
          guard self.readOperation == operation, self.readWait != nil else { return }
          self.shutdown(error: CancellationError())
        }
      }
    }

    func write(_ bytes: Data) async throws {
      guard !revoked, ioPermitted else {
        throw finished && !outcome.bothClosed ? Failure.closureDebt : Failure.closed
      }
      guard !writing else { throw Failure.busy }
      guard bytes.count <= ProviderRPC.maxFrameBytes else { throw Failure.frameTooLarge }
      try Task.checkCancellation()
      writing = true
      defer { writing = false }
      let operation = UUID()
      writeOperation = operation
      try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
          frame = bytes
          offset = 0
          writeWait = continuation
          pumpWrite()
        }
      } onCancel: {
        Task { @MainActor in
          guard self.writeOperation == operation, self.writeWait != nil else { return }
          self.shutdown(error: CancellationError())
        }
      }
    }

    private func pumpRead() {
      guard !revoked, ioPermitted, readWait != nil else { return }
      var bytes = [UInt8](repeating: 0, count: ProviderRPC.maxFrameBytes)
      for _ in 0..<16 {
        guard !revoked, ioPermitted else { return }
        activeIO += 1
        let count = bytes.withUnsafeMutableBytes {
          Darwin.read(readHandle.fileDescriptor, $0.baseAddress, $0.count)
        }
        let code = errno
        activeIO -= 1
        guard ioPermitted else {
          if count == 0 { eof = true }
          return
        }
        if count > 0 {
          let continuation = readWait
          readWait = nil
          continuation?.resume(returning: Data(bytes.prefix(count)))
          return
        }
        if count == 0 {
          eof = true
          shutdown()
          return
        }
        if code == EINTR { continue }
        if code == EAGAIN {
          armRead()
          return
        }
        shutdown(error: Failure.io(code))
        return
      }
      let turn = generation
      Task { @MainActor in
        await Task.yield()
        guard !self.revoked, self.generation == turn else { return }
        self.pumpRead()
      }
    }

    private func pumpWrite() {
      guard !revoked, ioPermitted, writeWait != nil, let bytes = frame else { return }
      for _ in 0..<16 {
        guard !revoked, ioPermitted else { return }
        if offset == bytes.count {
          let continuation = writeWait
          writeWait = nil
          frame = nil
          continuation?.resume()
          return
        }
        activeIO += 1
        let count = bytes.withUnsafeBytes {
          Darwin.write(
            writeHandle.fileDescriptor, $0.baseAddress!.advanced(by: offset), bytes.count - offset)
        }
        let code = errno
        activeIO -= 1
        if count > 0 {
          offset += count
          guard ioPermitted else { return }
          continue
        }
        guard ioPermitted else { return }
        if count < 0, code == EINTR { continue }
        if count < 0, code == EAGAIN {
          armWrite()
          return
        }
        shutdown(error: Failure.io(count == 0 ? EIO : code))
        return
      }
      let turn = generation
      Task { @MainActor in
        await Task.yield()
        guard !self.revoked, self.generation == turn else { return }
        self.pumpWrite()
      }
    }

    private func armRead() {
      guard readSource == nil, !revoked, ioPermitted else { return }
      readToken &+= 1
      let token = readToken
      let turn = generation
      let source = DispatchSource.makeReadSource(
        fileDescriptor: readHandle.fileDescriptor, queue: .main)
      readSource = source
      cancellingSources += 1
      source.setEventHandler {
        Task { @MainActor in
          guard self.generation == turn, self.readToken == token,
            let source = self.readSource
          else { return }
          self.readSource = nil
          source.cancel()
          guard !self.revoked, self.ioPermitted else { return }
          self.pumpRead()
        }
      }
      source.setCancelHandler { Task { @MainActor in self.sourceCancelled() } }
      source.activate()
    }

    private func armWrite() {
      guard writeSource == nil, !revoked, ioPermitted else { return }
      writeToken &+= 1
      let token = writeToken
      let turn = generation
      let source = DispatchSource.makeWriteSource(
        fileDescriptor: writeHandle.fileDescriptor, queue: .main)
      writeSource = source
      cancellingSources += 1
      source.setEventHandler {
        Task { @MainActor in
          guard self.generation == turn, self.writeToken == token,
            let source = self.writeSource
          else { return }
          self.writeSource = nil
          source.cancel()
          guard !self.revoked, self.ioPermitted else { return }
          self.pumpWrite()
        }
      }
      source.setCancelHandler { Task { @MainActor in self.sourceCancelled() } }
      source.activate()
    }

    private func sourceCancelled() {
      cancellingSources -= 1
      finishClose()
    }

    func quiesceNotifications() {
      readToken &+= 1
      writeToken &+= 1
      readSource?.cancel()
      writeSource?.cancel()
      readSource = nil
      writeSource = nil
    }

    func shutdown(error: Error = Failure.closed) {
      core?.revoke()
      // Keep endpoints until the independent control lane has observed CLI and
      // broker retirement and selected native worker termination. The Core still
      // requires actual worker wait and namespace removal before publishing clean.
      if let core, core.isWorker, !core.lock.withLock({ core.workerProcessesRetired }) {
        quiesceNotifications()
        return
      }
      guard core?.withinDeadline() ?? true else { return }
      guard !revoked else { return }
      revoked = true
      generation &+= 1
      readSource?.cancel()
      writeSource?.cancel()
      readSource = nil
      writeSource = nil
      if !eof {
        let continuation = readWait
        readWait = nil
        continuation?.resume(throwing: error)
      }
      let continuation = writeWait
      writeWait = nil
      frame = nil
      continuation?.resume(throwing: error)
      finishClose()
    }

    private func finishClose() {
      guard revoked, !finished, cancellingSources == 0, activeIO == 0 else { return }
      var read: EndpointClosure = .unknown
      var write: EndpointClosure = .unknown
      if core?.permitChannelClose() ?? true {
        do {
          try closeHandle(readHandle)
          read = .closed
        } catch { core?.failed(.close) }
        core?.recordChannelClose(read == .closed)
      }
      if core?.permitChannelClose() ?? true {
        do {
          try closeHandle(writeHandle)
          write = .closed
        } catch { core?.failed(.close) }
        core?.recordChannelClose(write == .closed)
      }
      outcome = ClosureOutcome(read: read, write: write)
      finished = true
      // Late/uncertain results are observations only, never new continuation effects.
      if let core, !core.withinDeadline() { return }
      internalClosure?(id)
      let continuation = readWait
      readWait = nil
      onLifecycleClosure?(outcome)
      if outcome.bothClosed {
        continuation?.resume(returning: nil)
        onClosure?(outcome)
        if core == nil { Self.retained[id] = nil }
      } else {
        continuation?.resume(throwing: Failure.closureDebt)
        onClosure?(outcome)
      }
    }
  }
}
