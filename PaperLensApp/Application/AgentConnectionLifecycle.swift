import Foundation

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
public final class AgentConnectionLifecycle {
  public let connection: AgentRPCConnection
  public var onTerminal: ((UUID, AgentRPCConnection.Terminal) -> Void)?
  private let channel: any AgentRPCChannel
  private var reader: Task<Void, Never>?
  private var writer: Task<Void, Never>?
  private var timer: Task<Void, Never>?
  private var started = false
  private var closeIssued = false
  private var closureReported = false

  public init(channel: any AgentRPCChannel) throws {
    self.channel = channel
    connection = try AgentRPCConnection()
    connection.onTerminal = { [weak self] id, terminal in
      self?.onTerminal?(id, terminal)
    }
  }

  public func start() throws {
    guard !started, !closeIssued, !closureReported else { throw AgentRPCConnection.Failure.notReady }
    started = true
    connection.expire()
    guard !connection.closeRequested else { synchronize(); return }
    reader = Task { [weak self] in
      guard let self else { return }
      do {
        while !closeIssued {
          guard let bytes = try await channel.read() else {
            closureReported = true
            connection.transportFailed()
            break
          }
          guard !closeIssued else { break }
          connection.receive(bytes)
          synchronize()
        }
      } catch {
        // A thrown read is not an observed closure ACK.
        connection.transportFailed()
      }
      reader = nil
      synchronize()
    }
    synchronize()
  }

  @discardableResult
  public func request(method: String, params: [String: Any], timeoutMs: Int) throws -> UUID {
    guard started else { throw AgentRPCConnection.Failure.notReady }
    connection.expire()
    synchronize()
    let id = try connection.request(method: method, params: params, timeoutMs: timeoutMs)
    synchronize()
    return id
  }

  @discardableResult
  public func cancel(targetID: UUID, timeoutMs: Int) throws -> UUID {
    try request(method: "cancel", params: ["targetID": targetID.uuidString.lowercased()], timeoutMs: timeoutMs)
  }

  public func drain() {
    connection.drain()
    synchronize()
  }

  public func close() {
    connection.transportFailed()
    synchronize()
  }

  /// Record external invalidation; started I/O must return before publishing closure.
  public func transportDidClose() {
    closureReported = true
    connection.transportFailed()
    synchronize()
  }

  private func synchronize() {
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
    if let deadline = connection.nextDeadline {
      timer = Task { [weak self] in
        do { try await ContinuousClock().sleep(until: deadline) }
        catch { return }
        guard let self else { return }
        connection.expire()
        synchronize()
      }
    }
    if writer == nil {
      writer = Task { [weak self] in
        guard let self else { return }
        do {
          while !Task.isCancelled {
            connection.expire()
            guard let outbound = connection.takeOutbound() else { break }
            try await channel.write(outbound.frame)
          }
        } catch { connection.transportFailed() }
        writer = nil
        // Do not spin an empty writer. New requests/reads resume the pump.
        if connection.closeRequested { synchronize() }
      }
    }
  }
}
