import Foundation
import XCTest
#if SWIFT_PACKAGE
import ProviderRPC
#endif
@testable import PaperLensProduct

/// Supplied-frame conformance only; these fixtures do not authenticate or certify a real peer.
@MainActor
final class AgentRPCConnectionTests: XCTestCase {
  private func ready(now: ContinuousClock.Instant) throws -> AgentRPCConnection {
    let connection = try AgentRPCConnection(now: now)
    let hello = try XCTUnwrap(connection.takeOutbound())
    let request = try ProviderRPC.decode(hello.frame)
    try ProviderRPC.validateRequest(request)
    XCTAssertEqual(request["id"] as? String, hello.id.uuidString.lowercased())
    XCTAssertEqual(request["method"] as? String, "hello")
    connection.receive(try result(hello.id, ["major": 1, "minor": 1,
      "capabilities": ["topology-v1"]]), now: now)
    XCTAssertEqual(connection.state, .ready)
    return connection
  }

  private func result(_ id: UUID, _ value: [String: Any]) throws -> Data {
    try ProviderRPC.encode(["kind": "result", "id": id.uuidString.lowercased(), "result": value])
  }

  func testHandshakeRequiredAndUnsupportedProductOperationsNeverQueue() throws {
    let now = ContinuousClock().now
    let connection = try AgentRPCConnection(now: now)
    XCTAssertThrowsError(try connection.request(method: "topology.wait",
      params: ["durationMs": 1], timeoutMs: 10, now: now)) {
      XCTAssertEqual($0 as? AgentRPCConnection.Failure, .notReady)
    }
    let admitted = try ready(now: now)
    for method in ["login", "auth", "chat", "usable", "hello"] {
      XCTAssertThrowsError(try admitted.request(method: method, params: [:],
        timeoutMs: 10, now: now)) {
        XCTAssertEqual($0 as? AgentRPCConnection.Failure, .unsupportedOperation)
      }
    }
    XCTAssertNil(admitted.takeOutbound())
    XCTAssertEqual(admitted.outstandingCount, 0)
  }

  func testFragmentedValidatedResponseSelectsOneTerminal() throws {
    let now = ContinuousClock().now
    let connection = try ready(now: now)
    let id = try connection.request(method: "topology.wait", params: ["durationMs": 1],
      timeoutMs: 100, now: now)
    let outbound = try XCTUnwrap(connection.takeOutbound())
    XCTAssertEqual(outbound.id, id)
    let request = try ProviderRPC.decode(outbound.frame)
    try ProviderRPC.validateRequest(request)
    XCTAssertEqual(request["id"] as? String, id.uuidString.lowercased())
    var completed: [UUID] = []
    connection.onTerminal = { identifier, terminal in
      completed.append(identifier)
      if case .result(let value) = terminal { XCTAssertEqual(value["elapsed"] as? Bool, true) }
      else { XCTFail("Expected validated result") }
    }
    let frame = try result(id, ["elapsed": true])
    connection.receive(Data(frame.prefix(3)), now: now)
    XCTAssertTrue(completed.isEmpty)
    connection.receive(Data(frame.dropFirst(3)), now: now)
    XCTAssertEqual(completed, [id])
    connection.receive(frame, now: now)
    XCTAssertEqual(completed, [id])
    XCTAssertEqual(connection.state, .poisoned)
    XCTAssertFalse(connection.transportClosureObserved)
  }

  func testMalformedBatchCannotPublishEarlierValidResult() throws {
    let now = ContinuousClock().now
    let connection = try ready(now: now)
    let first = try connection.request(method: "topology.wait", params: ["durationMs": 1],
      timeoutMs: 100, now: now)
    let second = try connection.request(method: "topology.wait", params: ["durationMs": 1],
      timeoutMs: 100, now: now)
    _ = connection.takeOutbound()
    _ = connection.takeOutbound()
    var successes = 0
    var failures = 0
    connection.onTerminal = { _, terminal in
      switch terminal { case .result: successes += 1; case .failure: failures += 1 }
    }
    var bytes = try result(first, ["elapsed": true])
    bytes.append(try result(second, ["accepted": true])) // Wrong method's result schema.
    connection.receive(bytes, now: now)
    XCTAssertEqual(successes, 0)
    XCTAssertEqual(failures, 2)
    XCTAssertEqual(connection.state, .poisoned)
  }

  func testUnsentAndUnknownCorrelationsPoison() throws {
    let now = ContinuousClock().now
    let connection = try AgentRPCConnection(now: now)
    connection.receive(try result(UUID(), ["major": 1, "minor": 1,
      "capabilities": ["topology-v1"]]), now: now)
    XCTAssertEqual(connection.state, .poisoned)
    XCTAssertNil(connection.takeOutbound())
    let unsent = try ready(now: now)
    let id = try unsent.request(method: "topology.wait", params: ["durationMs": 1],
      timeoutMs: 100, now: now)
    unsent.receive(try result(id, ["elapsed": true]), now: now)
    XCTAssertEqual(unsent.state, .poisoned)
  }

  func testReservedCancelLaneAndAcceptedIsNotTargetClosure() throws {
    let now = ContinuousClock().now
    let connection = try ready(now: now)
    let count = try ProviderRPC.limit("maxOrdinaryRequests")
    var targets: [UUID] = []
    for _ in 0..<count {
      targets.append(try connection.request(method: "topology.wait", params: ["durationMs": 1],
        timeoutMs: 100, now: now))
      _ = connection.takeOutbound()
    }
    XCTAssertThrowsError(try connection.request(method: "topology.wait",
      params: ["durationMs": 1], timeoutMs: 100, now: now)) {
      XCTAssertEqual($0 as? AgentRPCConnection.Failure, .busy)
    }
    let cancelID = try connection.cancel(targetID: targets[0], timeoutMs: 100, now: now)
    let cancel = try XCTUnwrap(connection.takeOutbound())
    XCTAssertEqual(cancel.id, cancelID)
    let request = try ProviderRPC.decode(cancel.frame)
    try ProviderRPC.validateRequest(request)
    XCTAssertEqual(request["method"] as? String, "cancel")
    XCTAssertEqual((request["params"] as? [String: Any])?["targetID"] as? String,
      targets[0].uuidString.lowercased())
    XCTAssertThrowsError(try connection.cancel(targetID: targets[0], timeoutMs: 100, now: now))
    connection.receive(try result(cancelID, ["accepted": true]), now: now)
    XCTAssertEqual(connection.outstandingCount, count)
    XCTAssertFalse(connection.transportClosureObserved)
    connection.receive(try ProviderRPC.encode(["kind": "error", "id": targets[0].uuidString.lowercased(),
      "code": "cancelled"]), now: now)
    XCTAssertEqual(connection.outstandingCount, count - 1)
    XCTAssertFalse(connection.transportClosureObserved)
  }

  func testTimeoutFailsClosedAndLateResponseCannotWin() throws {
    let now = ContinuousClock().now
    let connection = try ready(now: now)
    let id = try connection.request(method: "topology.wait", params: ["durationMs": 1],
      timeoutMs: 1, now: now)
    _ = connection.takeOutbound()
    var failures: [AgentRPCConnection.Failure] = []
    connection.onTerminal = { _, terminal in
      if case .failure(let failure) = terminal { failures.append(failure) }
      else { XCTFail("Timeout must win") }
    }
    connection.expire(now: now.advanced(by: .milliseconds(1)))
    connection.receive(try result(id, ["elapsed": true]), now: now.advanced(by: .milliseconds(2)))
    XCTAssertEqual(failures, [.timeout])
    XCTAssertEqual(connection.state, .closing)
    XCTAssertFalse(connection.transportClosureObserved)
    connection.transportDidClose()
    XCTAssertEqual(connection.state, .closed)
    XCTAssertTrue(connection.transportClosureObserved)
    XCTAssertEqual(failures, [.timeout])
  }

  func testDrainRejectsNewWorkAndWaitsForPendingTerminalsThenObservedEOF() throws {
    let now = ContinuousClock().now
    let connection = try ready(now: now)
    let id = try connection.request(method: "topology.wait", params: ["durationMs": 1],
      timeoutMs: 100, now: now)
    _ = connection.takeOutbound()
    connection.drain()
    XCTAssertEqual(connection.state, .draining)
    XCTAssertThrowsError(try connection.request(method: "topology.wait",
      params: ["durationMs": 1], timeoutMs: 100, now: now))
    connection.receive(try result(id, ["elapsed": true]), now: now)
    XCTAssertTrue(connection.closeRequested)
    XCTAssertFalse(connection.transportClosureObserved)
    connection.transportDidClose()
    XCTAssertTrue(connection.transportClosureObserved)
    XCTAssertEqual(connection.state, .closed)
  }

  func testTruncatedEOFAndVersionMismatchDoNotProduceReadiness() throws {
    let now = ContinuousClock().now
    let connection = try AgentRPCConnection(now: now)
    let hello = try XCTUnwrap(connection.takeOutbound())
    connection.receive(try ProviderRPC.encode(["kind": "error", "id": hello.id.uuidString.lowercased(),
      "code": "versionMismatch"]), now: now)
    XCTAssertEqual(connection.state, .closing)
    XCTAssertFalse(connection.transportClosureObserved)
    let truncated = try ready(now: now)
    truncated.receive(Data([0, 0]), now: now)
    truncated.transportDidClose()
    XCTAssertEqual(truncated.state, .poisoned)
    XCTAssertTrue(truncated.transportClosureObserved)
  }

  func testConnectionRequestBudgetCannotBeResetBySuccessfulReplies() throws {
    let now = ContinuousClock().now
    let connection = try ready(now: now)
    let count = try ProviderRPC.limit("maxRequestsPerConnection")
    for _ in 1..<count { // The handshake consumes one request identity.
      let id = try connection.request(method: "topology.wait", params: ["durationMs": 1],
        timeoutMs: 100, now: now)
      _ = connection.takeOutbound()
      connection.receive(try result(id, ["elapsed": true]), now: now)
    }
    XCTAssertEqual(connection.state, .closing)
    XCTAssertNil(connection.takeOutbound())
    XCTAssertThrowsError(try connection.request(method: "topology.wait",
      params: ["durationMs": 1], timeoutMs: 100, now: now))
  }

  func testTimeoutBoundsAndUnknownParamsDoNotConsumeRequestSlots() throws {
    let now = ContinuousClock().now
    let connection = try ready(now: now)
    let minimum = try ProviderRPC.limit("minTimeoutMs")
    let maximum = try ProviderRPC.limit("maxTimeoutMs")
    for timeout in [minimum - 1, maximum + 1] {
      XCTAssertThrowsError(try connection.request(method: "topology.wait",
        params: ["durationMs": 1], timeoutMs: timeout, now: now)) {
        XCTAssertEqual($0 as? AgentRPCConnection.Failure, .invalidRequest)
      }
    }
    XCTAssertThrowsError(try connection.request(method: "topology.wait",
      params: ["durationMs": 1, "extra": true], timeoutMs: minimum, now: now))
    XCTAssertEqual(connection.outstandingCount, 0)
    XCTAssertNil(connection.takeOutbound())
    _ = try connection.request(method: "topology.wait", params: ["durationMs": 1],
      timeoutMs: maximum, now: now)
    XCTAssertEqual(connection.outstandingCount, 1)
  }

  private func settle(_ predicate: () -> Bool,
    file: StaticString = #filePath, line: UInt = #line) async {
    for _ in 0..<10_000 {
      if predicate() { return }
      await Task.yield()
    }
    XCTFail("Lifecycle did not reach the expected barrier", file: file, line: line)
  }

  func testLifecycleEOFDoesNotPublishClosureWhileWriteIsSuspended() async throws {
    let channel = SuspendedRPCChannel()
    let lifecycle = try AgentConnectionLifecycle(channel: channel)
    var terminals = 0
    lifecycle.onTerminal = { _, _ in terminals += 1 }
    try lifecycle.start()
    await settle { channel.readPending && channel.writePending }
    channel.finishRead(nil)
    await settle { channel.closeRequests == 1 }
    XCTAssertTrue(channel.writePending)
    XCTAssertEqual(lifecycle.connection.state, .closing)
    XCTAssertFalse(lifecycle.connection.transportClosureObserved)
    XCTAssertEqual(terminals, 1)
    XCTAssertThrowsError(try lifecycle.request(method: "topology.wait",
      params: ["durationMs": 1], timeoutMs: 100))
    channel.finishWrite()
    await settle { lifecycle.connection.transportClosureObserved }
    XCTAssertEqual(lifecycle.connection.state, .closed)
    lifecycle.transportDidClose()
    lifecycle.close()
    lifecycle.drain()
    XCTAssertEqual(lifecycle.connection.state, .closed)
    XCTAssertEqual(channel.readCalls, 1)
    XCTAssertEqual(channel.writeCalls, 1)
    XCTAssertEqual(channel.closeRequests, 1)
    XCTAssertEqual(terminals, 1)
  }

  func testLifecycleInvalidationWaitsForBothStartedEffects() async throws {
    let channel = SuspendedRPCChannel()
    let lifecycle = try AgentConnectionLifecycle(channel: channel)
    try lifecycle.start()
    await settle { channel.readPending && channel.writePending }
    lifecycle.transportDidClose()
    XCTAssertEqual(channel.closeRequests, 1)
    XCTAssertTrue(channel.readPending)
    XCTAssertTrue(channel.writePending)
    XCTAssertFalse(lifecycle.connection.transportClosureObserved)
    channel.finishWrite()
    await settle { channel.writeReturns == 1 }
    XCTAssertFalse(lifecycle.connection.transportClosureObserved)
    // Even a late non-EOF read completion cannot restart I/O or publish a result.
    channel.finishRead(Data([0, 0]))
    await settle { lifecycle.connection.transportClosureObserved }
    XCTAssertEqual(lifecycle.connection.state, .closed)
    lifecycle.transportDidClose()
    XCTAssertThrowsError(try lifecycle.start())
    XCTAssertThrowsError(try lifecycle.cancel(targetID: UUID(), timeoutMs: 100))
    XCTAssertEqual(channel.readCalls, 1)
    XCTAssertEqual(channel.writeCalls, 1)
    XCTAssertEqual(channel.closeRequests, 1)
  }

  func testLifecycleQuiescentEOFPreservesTruncatedFramePoison() async throws {
    let channel = SuspendedRPCChannel()
    let lifecycle = try AgentConnectionLifecycle(channel: channel)
    try lifecycle.start()
    await settle { channel.readPending && channel.writePending }
    channel.finishRead(Data([0, 0]))
    await settle { channel.readCalls == 2 && channel.readPending }
    channel.finishRead(nil)
    await settle { channel.closeRequests == 1 }
    XCTAssertFalse(lifecycle.connection.transportClosureObserved)
    channel.finishWrite()
    await settle { lifecycle.connection.transportClosureObserved }
    XCTAssertEqual(lifecycle.connection.state, .poisoned)
    lifecycle.transportDidClose()
    lifecycle.close()
    XCTAssertEqual(lifecycle.connection.state, .poisoned)
    XCTAssertEqual(channel.closeRequests, 1)
  }
}

/// Cancellation and requestClose deliberately do not finish the held effects.
/// Tests release each actual channel call independently, through the real lifecycle pump.
@MainActor
private final class SuspendedRPCChannel: AgentRPCChannel {
  private var readContinuation: CheckedContinuation<Data?, Never>?
  private var writeContinuation: CheckedContinuation<Void, Never>?
  private(set) var readCalls = 0
  private(set) var writeCalls = 0
  private(set) var writeReturns = 0
  private(set) var closeRequests = 0
  var readPending: Bool { readContinuation != nil }
  var writePending: Bool { writeContinuation != nil }

  func read() async throws -> Data? {
    readCalls += 1
    return await withCheckedContinuation { readContinuation = $0 }
  }

  func write(_ frame: Data) async throws {
    writeCalls += 1
    await withCheckedContinuation { writeContinuation = $0 }
    writeReturns += 1
  }

  func requestClose() { closeRequests += 1 }

  func finishRead(_ bytes: Data?) {
    let continuation = readContinuation
    readContinuation = nil
    continuation?.resume(returning: bytes)
  }

  func finishWrite() {
    let continuation = writeContinuation
    writeContinuation = nil
    continuation?.resume()
  }
}
