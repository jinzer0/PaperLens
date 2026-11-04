import Foundation

#if SWIFT_PACKAGE
  import ProviderRPC
#endif

/// One explicitly selected wire session. Readiness is protocol compatibility, not authentication,
/// product admission, producer closure, or permission to execute topology controls.
@MainActor
public final class AgentRPCConnection {
  public enum Mode: Equatable { case topology, product }
  public enum State: Equatable { case handshaking, ready, draining, closing, poisoned, closed }
  public enum Failure: Error, Equatable {
    case unsupportedOperation, notReady, busy, exhausted, invalidRequest
    case remote(String)
    case timeout, unavailable, protocolViolation
  }
  public enum Terminal {
    case result([String: Any])
    case failure(Failure)
  }
  public struct Outbound {
    public let id: UUID
    public let frame: Data
  }
  private struct Pending {
    let method: String
    let params: [String: Any]
    let deadline: ContinuousClock.Instant
  }

  public let mode: Mode
  public private(set) var state: State = .handshaking
  public private(set) var transportClosureObserved = false
  public var onTerminal: ((UUID, Terminal) -> Void)?
  private let decoder = ProviderFrameDecoder()
  private var pending: [UUID: Pending] = [:]
  private var used: Set<UUID> = []
  private var dispatched: Set<UUID> = []
  private var queue: [Outbound] = []
  private var queuedBytes = 0
  // Product lifetime admission is independent of the currently queued transport work.
  // Neither dispatch, cancellation, readiness nor termination refunds these totals.
  private(set) var inboundBytes = 0
  private(set) var outboundBytes = 0
  private(set) var inboundRecords = 0
  private(set) var outboundRecords = 0
  private let limits: [String: Int]
  private let handshakeID: UUID

  public var closeRequested: Bool { state == .closing || state == .poisoned }
  public var outstandingCount: Int { pending.count }
  public var nextDeadline: ContinuousClock.Instant? { pending.values.map(\.deadline).min() }

  public init(mode: Mode, now: ContinuousClock.Instant = ContinuousClock().now) throws {
    self.mode = mode
    let names = [
      "maxOutstandingRequests", "maxOrdinaryRequests", "maxCancelRequests",
      "maxQueuedFrames", "maxQueuedBytes", "maxRequestsPerConnection", "handshakeTimeoutMs",
      "minTimeoutMs", "maxTimeoutMs",
    ]
    var loaded: [String: Int] = [:]
    for name in names { loaded[name] = try ProviderRPC.limit(name) }
    limits = loaded
    handshakeID = UUID()
    try enqueue(
      id: handshakeID, method: mode == .product ? "product.hello" : "hello",
      params: [
        "major": mode == .product ? 2 : 1, "minor": mode == .product ? 0 : 1,
        "capabilities": [mode == .product ? "product-v1" : "topology-v1"],
      ],
      timeoutMs: loaded["handshakeTimeoutMs"]!, now: now)
  }

  /// Only methods in the finalized authority can cross this boundary. No SDK JSON passthrough.
  @discardableResult
  public func request(
    method: String, params: [String: Any], timeoutMs: Int,
    now: ContinuousClock.Instant = ContinuousClock().now
  ) throws -> UUID {
    guard method != "hello", method != "product.hello",
      method == "cancel"
        || (mode == .product
          ? method.hasPrefix("product.")
          : method.hasPrefix("topology."))
    else { throw Failure.unsupportedOperation }
    guard state == .ready || (state == .draining && method == "cancel") else {
      throw Failure.notReady
    }
    let id = UUID()
    try enqueue(id: id, method: method, params: params, timeoutMs: timeoutMs, now: now)
    return id
  }

  @discardableResult
  public func cancel(
    targetID: UUID, timeoutMs: Int,
    now: ContinuousClock.Instant = ContinuousClock().now
  ) throws -> UUID {
    // An accepted cancellation is not a producer/FD drain ACK.
    try request(
      method: "cancel", params: ["targetID": targetID.uuidString.lowercased()],
      timeoutMs: timeoutMs, now: now)
  }

  private func enqueue(
    id: UUID, method: String, params: [String: Any], timeoutMs: Int,
    now: ContinuousClock.Instant
  ) throws {
    let object: [String: Any] = [
      "kind": "request", "id": id.uuidString.lowercased(),
      "method": method, "timeoutMs": timeoutMs, "params": params,
    ]
    do { try ProviderRPC.validateRequest(object) } catch ProviderRPCError.unknownMethod {
      throw Failure.unsupportedOperation
    } catch { throw Failure.invalidRequest }
    guard used.count < limits["maxRequestsPerConnection"]! else {
      if mode == .product { terminate(.exhausted) }
      throw Failure.exhausted
    }
    let laneCount = pending.values.filter { ($0.method == "cancel") == (method == "cancel") }.count
    let laneLimit = limits[method == "cancel" ? "maxCancelRequests" : "maxOrdinaryRequests"]!
    guard laneCount < laneLimit, pending.count < limits["maxOutstandingRequests"]! else {
      throw Failure.busy
    }
    let frame = try ProviderRPC.encode(object)
    guard queue.count < limits["maxQueuedFrames"]!,
      frame.count <= limits["maxQueuedBytes"]! - queuedBytes
    else { throw Failure.busy }
    if mode == .product {
      guard frame.count <= limits["maxQueuedBytes"]! - outboundBytes else {
        terminate(.exhausted)
        throw Failure.exhausted
      }
      outboundBytes += frame.count
      outboundRecords += 1
    }
    guard used.insert(id).inserted else { throw Failure.invalidRequest }
    pending[id] = Pending(
      method: method, params: params,
      deadline: now.advanced(by: .milliseconds(timeoutMs)))
    queue.append(Outbound(id: id, frame: frame))
    queuedBytes += frame.count
  }

  /// Transport must serialize writes and hold at most one removed frame at a time.
  public func takeOutbound() -> Outbound? {
    guard !closeRequested, !transportClosureObserved, !queue.isEmpty else { return nil }
    let frame = queue.removeFirst()
    queuedBytes -= frame.frame.count
    dispatched.insert(frame.id)
    return frame
  }

  public func receive(_ bytes: Data, now: ContinuousClock.Instant = ContinuousClock().now) {
    guard !closeRequested, !transportClosureObserved else { return }
    if mode == .product {
      guard bytes.count <= limits["maxQueuedBytes"]! - inboundBytes else {
        terminate(.exhausted)
        return
      }
      inboundBytes += bytes.count
    }
    expire(now: now)
    guard !closeRequested else { return }
    do {
      // Validate the whole supplied batch before selecting any terminal.
      var terminals: [(UUID, [String: Any], Pending)] = []
      var batchIDs: Set<UUID> = []
      let frames = try decoder.feed(bytes)
      if mode == .product {
        guard frames.count <= limits["maxRequestsPerConnection"]! - inboundRecords else {
          terminate(.exhausted)
          return
        }
        inboundRecords += frames.count
      }
      for frame in frames {
        let value = try ProviderRPC.decode(frame)
        guard let rawID = value["id"] as? String, let id = UUID(uuidString: rawID),
          batchIDs.insert(id).inserted, dispatched.contains(id), let record = pending[id]
        else {
          throw Failure.protocolViolation
        }
        try ProviderRPC.validateTerminal(value, method: record.method)
        if mode == .product, let result = value["result"] as? [String: Any] {
          // Schema validity alone does not correlate a stale product intent/selector.
          for key in [
            "stageID", "intentID", "expectedSelector", "cleanupID", "paperID",
            "generation", "correlationID",
          ] where record.params[key] != nil && result[key] != nil {
            guard let expected = record.params[key], let actual = result[key],
              NSDictionary(dictionary: [key: expected]).isEqual(to: [key: actual])
            else {
              throw Failure.protocolViolation
            }
          }
        }
        terminals.append((id, value, record))
      }
      var selected: [(UUID, Terminal)] = []
      var failedHandshake = false
      for (id, value, _) in terminals {
        pending.removeValue(forKey: id)
        if let code = value["code"] as? String {
          selected.append((id, .failure(.remote(code))))
          if id == handshakeID { failedHandshake = true }
        } else if let result = value["result"] as? [String: Any] {
          if id == handshakeID { state = .ready }
          selected.append((id, .result(result)))
        }
      }
      if failedHandshake { terminate(.unavailable) }
      finishDrain()
      for (id, terminal) in selected { onTerminal?(id, terminal) }
    } catch { terminate(.protocolViolation, poison: true) }
  }

  public func expire(now: ContinuousClock.Instant = ContinuousClock().now) {
    guard !closeRequested, !transportClosureObserved else { return }
    let expired = Set(pending.filter { $0.value.deadline <= now }.keys)
    guard !expired.isEmpty else { return }
    // Fail closed: a local timeout cannot attest that the remote producer stopped.
    terminate(.unavailable, expired: expired)
  }

  public func drain() {
    guard state == .ready else {
      terminate(.unavailable)
      return
    }
    state = .draining
    finishDrain()
  }

  private func finishDrain() {
    if (state == .draining && pending.isEmpty)
      || (state == .ready && pending.isEmpty && used.count == limits["maxRequestsPerConnection"]!)
    {
      state = .closing
    }
  }

  public func transportFailed() { terminate(.unavailable) }

  /// Call only after observed EOF/invalidation AND all started channel I/O has ceased.
  /// Neither requesting close nor observing inbound EOF alone proves duplex quiescence.
  public func transportDidClose() {
    guard !transportClosureObserved else { return }
    do { try decoder.finish() } catch { terminate(.protocolViolation, poison: true) }
    terminate(.unavailable)
    transportClosureObserved = true
    if state != .poisoned { state = .closed }
  }

  private func terminate(_ failure: Failure, poison: Bool = false, expired: Set<UUID> = []) {
    if transportClosureObserved { return }
    if poison { state = .poisoned } else if state != .poisoned { state = .closing }
    let ids = Array(pending.keys)
    pending.removeAll()
    queue.removeAll()
    queuedBytes = 0
    for id in ids { onTerminal?(id, .failure(expired.contains(id) ? .timeout : failure)) }
  }
}
