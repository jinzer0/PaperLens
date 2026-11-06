import Foundation

extension OwnedChildRetirement {
  @MainActor
  internal func retire(cancelling lifecycle: AgentConnectionLifecycle, params: [String: Any]) {
    core.revoke(dispatchCancellation: true)
    do {
      try lifecycle.dispatchCancellation(params: params) { [core] in core.revoke() }
    } catch { core.revoke() }
  }
}

/// Implemented by the actual process/XPC channel owner, not by a synthetic production peer.
/// write completes only after the frame is handed to the channel in order. read returns nil
/// only on observed closure. requestClose must revoke IO and unblock both pending operations;
/// it is a request, not proof of producer shutdown, scoped content absence, or process reaping.
@MainActor
public protocol AgentRPCChannel: AnyObject {
  func write(_ frame: Data) async throws
  func read() async throws -> Data?
  func requestClose()
}

/// One channel, one read loop, one serialized writer, and one aggregate deadline timer.
/// Does not own a second job/credential store or turn transport loss into job cleanup evidence.
@MainActor
public final class AgentConnectionLifecycle: OwnedChildSession {
  public let connection: AgentRPCConnection
  public var onTerminal: ((UUID, AgentRPCConnection.Terminal) -> Void)?
  private let channel: any AgentRPCChannel
  private var reader: Task<Void, Never>?
  private var writer: Task<Void, Never>?
  private var timer: Task<Void, Never>?
  private var started = false
  private var closeIssued = false
  private var closureReported = false
  private var ownerHandshake: (@MainActor @Sendable () -> Void)?
  private var ownerFailure: (@MainActor @Sendable () -> Void)?
  private var ownerPermit: (@MainActor @Sendable () -> Bool)?
  private var ownerPermitted: Bool { ownerPermit?() ?? true }
  private var cancellationID: UUID?
  private var cancellationDispatched: (() -> Void)?

  internal func bindOwner(
    permit: @escaping @MainActor @Sendable () -> Bool,
    handshake: @escaping @MainActor @Sendable () -> Void,
    failure: @escaping @MainActor @Sendable () -> Void
  ) {
    precondition(!started && ownerFailure == nil)
    ownerPermit = permit
    ownerHandshake = handshake
    ownerFailure = failure
  }

  public init(channel: any AgentRPCChannel, mode: AgentRPCConnection.Mode) throws {
    self.channel = channel
    connection = try AgentRPCConnection(mode: mode)
    connection.onTerminal = { [weak self] id, terminal in
      self?.onTerminal?(id, terminal)
    }
  }

  /// Exclusive Main-owned FIFO transfer. Construct/bind before any I/O; start remains
  /// explicit. Duplex endpoint closure is not SDK shutdown or process-reaping proof.
  public static func ownedPipe(
    readStdout: FileHandle, writeStdin: FileHandle,
    mode: AgentRPCConnection.Mode
  ) throws
    -> AgentConnectionLifecycle
  {
    let channel = try OwnedPipeAgentRPCChannel(readStdout: readStdout, writeStdin: writeStdin)
    return try AgentConnectionLifecycle(ownedPipe: channel, mode: mode)
  }

  public convenience init(
    ownedPipe channel: OwnedPipeAgentRPCChannel,
    mode: AgentRPCConnection.Mode
  ) throws {
    guard !channel.lifecycleBound else { throw OwnedPipeAgentRPCChannel.Failure.busy }
    do {
      try self.init(channel: channel, mode: mode)
      channel.bindLifecycleClosure { [weak self] outcome in
        guard outcome.bothClosed else { return }
        self?.transportDidClose()
      }
    } catch {
      channel.requestClose()
      throw error
    }
  }

  public func start() throws {
    guard !started, !closeIssued, !closureReported, ownerPermitted else {
      throw AgentRPCConnection.Failure.notReady
    }
    started = true
    connection.expire()
    guard !connection.closeRequested else {
      synchronize()
      return
    }
    reader = Task { [weak self] in
      guard let self else { return }
      do {
        while !closeIssued {
          guard ownerPermitted else { return }
          guard let bytes = try await channel.read() else {
            guard ownerPermitted else { return }
            closureReported = true
            connection.transportFailed()
            break
          }
          guard ownerPermitted, cancellationID == nil else { return }
          guard !closeIssued else { break }
          connection.receive(bytes)
          synchronize()
        }
      } catch {
        // A thrown read is not an observed closure ACK.
        guard ownerPermitted else { return }
        connection.transportFailed()
      }
      reader = nil
      synchronize()
    }
    synchronize()
  }

  @discardableResult
  public func request(method: String, params: [String: Any], timeoutMs: Int) throws -> UUID {
    guard started, ownerPermitted, cancellationID == nil else {
      throw AgentRPCConnection.Failure.notReady
    }
    connection.expire()
    synchronize()
    defer { synchronize() }
    let id = try connection.request(method: method, params: params, timeoutMs: timeoutMs)
    return id
  }

  @discardableResult
  public func cancel(targetID: UUID, timeoutMs: Int) throws -> UUID {
    try request(
      method: "cancel", params: ["targetID": targetID.uuidString.lowercased()], timeoutMs: timeoutMs
    )
  }

  /// Owner-authorized final write only. Neither a write nor an SDK reply proves cleanup.
  internal func dispatchCancellation(params: [String: Any], dispatched: @escaping () -> Void) throws
  {
    guard started, ownerPermitted, cancellationID == nil else {
      throw AgentRPCConnection.Failure.notReady
    }
    let id = try connection.request(method: "product.loginCancel", params: params, timeoutMs: 1000)
    cancellationID = id
    cancellationDispatched = dispatched
    timer?.cancel()
    timer = nil
    synchronize()
  }

  public func drain() {
    guard ownerPermitted else { return }
    connection.drain()
    synchronize()
  }

  public func close() {
    guard ownerPermitted else { return }
    connection.transportFailed()
    synchronize()
  }

  /// Record external invalidation; started I/O must return before publishing closure.
  public func transportDidClose() {
    guard ownerPermitted else { return }
    closureReported = true
    connection.transportFailed()
    synchronize()
  }

  private func synchronize() {
    guard ownerPermitted else { return }
    if connection.state == .ready, let handshake = ownerHandshake {
      ownerHandshake = nil
      handshake()
    }
    if connection.closeRequested || connection.transportClosureObserved {
      ownerHandshake = nil
      let failure = ownerFailure
      ownerFailure = nil
      failure?()
    }
    timer?.cancel()
    timer = nil
    if connection.closeRequested || connection.transportClosureObserved {
      reader?.cancel()
      writer?.cancel()
      if !closeIssued {
        closeIssued = true
        channel.requestClose()
      }
      // Cancellation/revocation requests do not join suspended channel effects.
      // Task handles stay present until each loop has returned from its channel call.
      if closureReported, reader == nil, writer == nil {
        connection.transportDidClose()
      }
      return
    }
    if cancellationID == nil, let deadline = connection.nextDeadline {
      timer = Task { [weak self] in
        do { try await ContinuousClock().sleep(until: deadline) } catch { return }
        guard let self else { return }
        guard ownerPermitted else { return }
        connection.expire()
        synchronize()
      }
    }
    if writer == nil {
      writer = Task { [weak self] in
        guard let self else { return }
        do {
          while !Task.isCancelled {
            guard ownerPermitted else { return }
            connection.expire()
            guard let outbound = connection.takeOutbound() else { break }
            // Drop unrelated queued work without refunding its lifetime admission.
            if let cancellationID, outbound.id != cancellationID { continue }
            try await channel.write(outbound.frame)
            if outbound.id == cancellationID {
              let dispatched = cancellationDispatched
              cancellationDispatched = nil
              dispatched?()
              break
            }
          }
        } catch {
          guard ownerPermitted else { return }
          connection.transportFailed()
        }
        writer = nil
        // Do not spin an empty writer. New requests/reads resume the pump.
        if connection.closeRequested { synchronize() }
      }
    }
  }
}
