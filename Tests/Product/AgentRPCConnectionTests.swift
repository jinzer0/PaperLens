import Foundation
import XCTest

@testable import PaperLensProduct

#if SWIFT_PACKAGE
  import ProviderRPC
#endif

/// Supplied-frame conformance only; these fixtures do not authenticate or certify a real peer.
@MainActor
final class AgentRPCConnectionTests: XCTestCase {
  private func ready(now: ContinuousClock.Instant) throws -> AgentRPCConnection {
    let connection = try AgentRPCConnection(mode: .topology, now: now)
    let hello = try XCTUnwrap(connection.takeOutbound())
    let request = try ProviderRPC.decode(hello.frame)
    try ProviderRPC.validateRequest(request)
    XCTAssertEqual(request["id"] as? String, hello.id.uuidString.lowercased())
    XCTAssertEqual(request["method"] as? String, "hello")
    connection.receive(
      try result(
        hello.id,
        [
          "major": 1, "minor": 1,
          "capabilities": ["topology-v1"],
        ]), now: now)
    XCTAssertEqual(connection.state, .ready)
    return connection
  }

  private func result(_ id: UUID, _ value: [String: Any]) throws -> Data {
    try ProviderRPC.encode(["kind": "result", "id": id.uuidString.lowercased(), "result": value])
  }

  private var productHello: [String: Any] {
    ["major": 2, "minor": 0, "capabilities": ["product-v1"]]
  }

  private var selector: [String: Any] {
    ["kind": NSNull(), "slotID": NSNull(), "generation": 0, "model": NSNull()]
  }

  private func productReady(now: ContinuousClock.Instant) throws -> AgentRPCConnection {
    let connection = try AgentRPCConnection(mode: .product, now: now)
    let hello = try XCTUnwrap(connection.takeOutbound())
    let request = try ProviderRPC.decode(hello.frame)
    try ProviderRPC.validateRequest(request)
    XCTAssertEqual(request["method"] as? String, "product.hello")
    XCTAssertTrue(
      NSDictionary(dictionary: try XCTUnwrap(request["params"] as? [String: Any]))
        .isEqual(to: productHello))
    XCTAssertEqual(connection.outboundBytes, hello.frame.count)
    connection.receive(try result(hello.id, productHello), now: now)
    XCTAssertEqual(connection.state, .ready)
    XCTAssertEqual(connection.inboundRecords, 1)
    XCTAssertEqual(connection.outboundRecords, 1)
    return connection
  }

  private func identity() -> [String: Any] {
    ["stageID": UUID().uuidString.lowercased(), "intentID": UUID().uuidString.lowercased()]
  }

  private func exchange(
    _ connection: AgentRPCConnection, method: String,
    params: [String: Any], response: [String: Any], now: ContinuousClock.Instant
  ) throws {
    let id = try connection.request(method: method, params: params, timeoutMs: 100, now: now)
    let outbound = try XCTUnwrap(connection.takeOutbound())
    XCTAssertEqual(outbound.id, id)
    let request = try ProviderRPC.decode(outbound.frame)
    try ProviderRPC.validateRequest(request)
    XCTAssertEqual(request["method"] as? String, method)
    var successes = 0
    connection.onTerminal = { actualID, terminal in
      XCTAssertEqual(actualID, id)
      if case .result(let value) = terminal {
        XCTAssertTrue(NSDictionary(dictionary: value).isEqual(to: response))
        successes += 1
      } else {
        XCTFail("Expected correlated product result")
      }
    }
    connection.receive(try result(id, response), now: now)
    XCTAssertEqual(successes, 1)
    XCTAssertEqual(connection.state, .ready)
    connection.onTerminal = nil
  }

  func testProductSuppliedLoginObserveUsableAndBothCancelTranscripts() throws {
    let now = ContinuousClock().now
    let connection = try productReady(now: now)
    let ids = identity()
    var start = ids
    start.merge(["expectedSelector": selector, "mode": "browser", "model": "fixture-model"]) {
      _, n in n
    }
    var started = ids
    started["instructions"] = ["mode": "browser", "authUrl": "https://example.invalid/login"]
    try exchange(
      connection, method: "product.loginStart", params: start, response: started, now: now)
    for state in ["pending", "authenticated"] {
      var observed = ids
      observed["state"] = state
      try exchange(
        connection, method: "product.loginObserve", params: ids,
        response: observed, now: now)
    }
    var probe = ids
    probe["expectedSelector"] = selector
    var usable = probe
    usable["state"] = "usable"
    usable["text"] = "PAPERLENS_OK"
    try exchange(
      connection, method: "product.connectionTest", params: probe,
      response: usable, now: now)
    var cancelled = ids
    cancelled["accepted"] = true
    try exchange(
      connection, method: "product.loginCancel", params: ids,
      response: cancelled, now: now)
    let target = try connection.request(
      method: "product.loginObserve", params: ids,
      timeoutMs: 100, now: now)
    _ = connection.takeOutbound()
    let cancel = try connection.cancel(targetID: target, timeoutMs: 100, now: now)
    let frame = try XCTUnwrap(connection.takeOutbound())
    XCTAssertEqual(try ProviderRPC.decode(frame.frame)["method"] as? String, "cancel")
    connection.receive(try result(cancel, ["accepted": true]), now: now)
    XCTAssertEqual(connection.outstandingCount, 1)
    XCTAssertFalse(connection.transportClosureObserved)
  }

  func testProductRejectsWrongFamilyVersionCapabilitiesAndPendingHelloFailure() throws {
    let now = ContinuousClock().now
    let product = try productReady(now: now)
    let topology = try ready(now: now)
    for method in [
      "hello", "topology.runtime", "topology.wait", "product.hello", "product.missing",
    ] {
      XCTAssertThrowsError(
        try product.request(method: method, params: [:], timeoutMs: 100, now: now)
      ) {
        XCTAssertEqual($0 as? AgentRPCConnection.Failure, .unsupportedOperation)
      }
    }
    XCTAssertThrowsError(
      try topology.request(
        method: "product.loginObserve", params: identity(),
        timeoutMs: 100, now: now)
    ) {
      XCTAssertEqual($0 as? AgentRPCConnection.Failure, .unsupportedOperation)
    }
    let topologyID = try topology.request(
      method: "topology.wait", params: ["durationMs": 1],
      timeoutMs: 100, now: now)
    _ = topology.takeOutbound()
    var productResponse = identity()
    productResponse["state"] = "authenticated"
    topology.receive(try result(topologyID, productResponse), now: now)
    XCTAssertEqual(topology.state, .poisoned)
    let incompatible: [[String: Any]] = [
      ["major": 1, "minor": 1, "capabilities": ["topology-v1"]],
      ["major": 2, "minor": 1, "capabilities": ["product-v1"]],
      ["major": 2, "minor": 0, "capabilities": ["topology-v1"]],
      ["major": 2, "minor": 0, "capabilities": ["product-v1", "topology-v1"]],
    ]
    for reply in incompatible {
      let connection = try AgentRPCConnection(mode: .product, now: now)
      let hello = try XCTUnwrap(connection.takeOutbound())
      connection.receive(try result(hello.id, reply), now: now)
      XCTAssertEqual(connection.state, .poisoned)
    }
    for timeout in [false, true] {
      let connection = try AgentRPCConnection(mode: .product, now: now)
      XCTAssertThrowsError(
        try connection.request(
          method: "product.loginObserve", params: identity(),
          timeoutMs: 100, now: now))
      let hello = try XCTUnwrap(connection.takeOutbound())
      var failure: AgentRPCConnection.Failure?
      connection.onTerminal = { _, terminal in
        if case .failure(let value) = terminal { failure = value }
      }
      if timeout {
        connection.expire(now: now.advanced(by: .milliseconds(5000)))
      } else {
        connection.receive(
          try ProviderRPC.encode([
            "kind": "error",
            "id": hello.id.uuidString.lowercased(), "code": "versionMismatch",
          ]), now: now)
      }
      XCTAssertEqual(connection.state, .closing)
      XCTAssertEqual(failure, timeout ? .timeout : .remote("versionMismatch"))
      connection.receive(try result(hello.id, productHello), now: now)
      XCTAssertEqual(connection.state, .closing)
    }
  }

  func testProductUsableProjectionRequiresMatchingResponseAndIntentSelector() throws {
    let now = ContinuousClock().now
    for mutation in [
      "envelopeID", "stageID", "intentID", "expectedSelector", "text", "family",
      "unsent", "kind",
    ] {
      let connection = try productReady(now: now)
      var params = identity()
      params["expectedSelector"] = selector
      let id = try connection.request(
        method: "product.connectionTest", params: params,
        timeoutMs: 100, now: now)
      if mutation != "unsent" { _ = connection.takeOutbound() }
      var response = params
      response["state"] = "usable"
      response["text"] = "PAPERLENS_OK"
      switch mutation {
      case "stageID", "intentID": response[mutation] = UUID().uuidString.lowercased()
      case "expectedSelector":
        var changed = selector
        changed["generation"] = 1
        response[mutation] = changed
      case "text": response[mutation] = "OTHER"
      case "family": response = ["elapsed": true]
      default: break
      }
      var successes = 0
      connection.onTerminal = { _, terminal in if case .result = terminal { successes += 1 } }
      let frame: Data
      if mutation == "kind" {
        frame = try ProviderRPC.encode([
          "kind": "event", "id": id.uuidString.lowercased(),
          "result": response,
        ])
      } else {
        frame = try result(mutation == "envelopeID" ? UUID() : id, response)
      }
      connection.receive(frame, now: now)
      XCTAssertEqual(connection.state, .poisoned)
      XCTAssertEqual(successes, 0)
    }
  }

  func testSummaryResultRequiresExactRequestProviderAndPaperIdentity() throws {
    for changed in ["requestID", "paperID", "paperGeneration", "configGeneration", "model"] {
      let now = ContinuousClock().now
      let connection = try productReady(now: now)
      let identity: [String: Any] = ["requestID": UUID().uuidString.lowercased(),
        "paperID": UUID().uuidString.lowercased(), "paperGeneration": 1,
        "configGeneration": 1, "model": "test-model"]
      var params = identity; params["requestJSON"] = "{}"
      let id = try connection.request(method: "product.librarySummary", params: params,
        timeoutMs: 120000, now: now)
      _ = connection.takeOutbound()
      var response = identity; response["resultJSON"] = "{}"
      if changed == "model" { response[changed] = "other-model" }
      else if changed.hasSuffix("Generation") { response[changed] = 2 }
      else { response[changed] = UUID().uuidString.lowercased() }
      connection.receive(try result(id, response), now: now)
      XCTAssertEqual(connection.state, .poisoned, changed)
    }
  }

  /// Legal JSON whitespace changes wire length without weakening the closed result schema.
  private func padded(_ frame: Data, count: Int) throws -> Data {
    XCTAssertGreaterThanOrEqual(count, frame.count)
    XCTAssertLessThanOrEqual(count, ProviderRPC.maxFrameBytes)
    let bodyCount = count - 4
    var value = Data([
      UInt8((bodyCount >> 24) & 255), UInt8((bodyCount >> 16) & 255),
      UInt8((bodyCount >> 8) & 255), UInt8(bodyCount & 255),
    ])
    value.append(frame.dropFirst(4))
    value.append(Data(repeating: 32, count: count - frame.count))
    _ = try ProviderRPC.decode(value)
    return value
  }

  func testProductExactInboundBytesFragmentedAndOneByteOverCloseWithoutRefund() throws {
    let now = ContinuousClock().now
    let limit = try ProviderRPC.limit("maxQueuedBytes")
    let maximum = ProviderRPC.maxFrameBytes
    for extraByte in [false, true] {
      let connection = try AgentRPCConnection(mode: .product, now: now)
      let hello = try XCTUnwrap(connection.takeOutbound())
      let helloReply = try padded(result(hello.id, productHello), count: maximum)
      connection.receive(Data(helloReply.prefix(3)), now: now)
      XCTAssertEqual(connection.inboundBytes, 3)
      XCTAssertEqual(connection.inboundRecords, 0)
      connection.receive(Data(helloReply.dropFirst(3)), now: now)
      XCTAssertEqual(connection.state, .ready)
      XCTAssertEqual(connection.inboundBytes, maximum)  // Hello does not reset counters.
      var batch = Data()
      for _ in 0..<3 {
        let params = identity()
        let id = try connection.request(
          method: "product.loginObserve", params: params,
          timeoutMs: 100, now: now)
        _ = connection.takeOutbound()
        var response = params
        response["state"] = "pending"
        batch.append(try padded(result(id, response), count: maximum))
      }
      if extraByte { batch.append(0) }
      connection.receive(batch, now: now)
      if extraByte {
        XCTAssertEqual(connection.state, .closing)
        XCTAssertEqual(connection.inboundRecords, 1)
        XCTAssertEqual(connection.outstandingCount, 0)
      } else {
        XCTAssertEqual(connection.state, .ready)
        XCTAssertEqual(connection.inboundBytes, limit)
        XCTAssertEqual(connection.inboundRecords, 4)
        connection.receive(Data([0]), now: now)
        XCTAssertEqual(connection.state, .closing)
        XCTAssertEqual(connection.inboundBytes, limit)
      }
      XCTAssertFalse(connection.transportClosureObserved)
      XCTAssertLessThan(connection.outboundBytes, limit)
    }
  }

  func testProductExactLifetimeRecordsAndInboundPlusOneBatchFailClosed() throws {
    let now = ContinuousClock().now
    let limit = try ProviderRPC.limit("maxRequestsPerConnection")
    for extraRecord in [false, true] {
      let connection = try productReady(now: now)
      for record in 1..<limit {
        let params = identity()
        let id = try connection.request(
          method: "product.loginObserve", params: params,
          timeoutMs: 100, now: now)
        _ = connection.takeOutbound()
        var response = params
        response["state"] = "pending"
        var bytes = try result(id, response)
        if extraRecord && record == limit - 1 { bytes.append(bytes) }
        connection.receive(bytes, now: now)
      }
      XCTAssertEqual(connection.outboundRecords, limit)
      XCTAssertEqual(connection.inboundRecords, extraRecord ? limit - 1 : limit)
      XCTAssertEqual(connection.state, .closing)
      XCTAssertNil(connection.takeOutbound())
      XCTAssertThrowsError(try connection.cancel(targetID: UUID(), timeoutMs: 100, now: now))
    }
    // The 257th outbound admission must fail closed even while the last request is pending.
    let connection = try productReady(now: now)
    for _ in 1..<limit - 1 {
      let id = try connection.cancel(targetID: UUID(), timeoutMs: 100, now: now)
      _ = connection.takeOutbound()
      connection.receive(try result(id, ["accepted": true]), now: now)
    }
    _ = try connection.cancel(targetID: UUID(), timeoutMs: 100, now: now)
    XCTAssertEqual(connection.outboundRecords, limit)
    XCTAssertThrowsError(
      try connection.request(
        method: "product.loginObserve", params: identity(),
        timeoutMs: 100, now: now)
    ) {
      XCTAssertEqual($0 as? AgentRPCConnection.Failure, .exhausted)
    }
    XCTAssertEqual(connection.state, .closing)
    XCTAssertNil(connection.takeOutbound())
    XCTAssertEqual(connection.outboundRecords, limit)
  }

  func testProductExactOutboundLifetimeBytesAndOneByteOver() throws {
    let now = ContinuousClock().now
    let limit = try ProviderRPC.limit("maxQueuedBytes")
    for extraByte in [false, true] {
      let connection = try productReady(now: now)
      var params = identity()
      params.merge(["mode": "browser", "expectedSelector": selector]) { _, n in n }
      func requestSize(model: String) throws -> Int {
        var value = params
        value["model"] = model
        return try ProviderRPC.encode([
          "kind": "request", "id": UUID().uuidString.lowercased(),
          "method": "product.loginStart", "params": value, "timeoutMs": 100,
        ]).count
      }
      let base = try requestSize(model: "a") - 1
      let maximum = base + 1500
      func send(size: Int) throws {
        let encodedLength = size - base
        // Six-byte JSON escapes plus ASCII permit exact byte targeting, within 256 model bytes.
        let model =
          String(repeating: "\u{1}", count: encodedLength / 6)
          + String(repeating: "a", count: encodedLength % 6)
        XCTAssertEqual(try requestSize(model: model), size)
        var request = params
        request["model"] = model
        let id = try connection.request(
          method: "product.loginStart", params: request,
          timeoutMs: 100, now: now)
        let frame = try XCTUnwrap(connection.takeOutbound())
        XCTAssertEqual(frame.frame.count, size)
        var response = params
        response.removeValue(forKey: "mode")
        response.removeValue(forKey: "expectedSelector")
        response["instructions"] = [
          "mode": "device", "userCode": "fixture",
          "verificationUrl": "https://example.invalid/device",
        ]
        connection.receive(try result(id, response), now: now)
      }
      while limit - connection.outboundBytes > maximum * 2 { try send(size: maximum) }
      let remaining = limit - connection.outboundBytes
      try send(size: remaining / 2)
      let lastSize = limit - connection.outboundBytes
      if extraByte {
        XCTAssertThrowsError(try send(size: lastSize + 1)) {
          XCTAssertEqual($0 as? AgentRPCConnection.Failure, .exhausted)
        }
        XCTAssertEqual(connection.outboundBytes, limit - lastSize)
      } else {
        try send(size: lastSize)
        XCTAssertEqual(connection.outboundBytes, limit)
        XCTAssertThrowsError(try connection.cancel(targetID: UUID(), timeoutMs: 100, now: now)) {
          XCTAssertEqual($0 as? AgentRPCConnection.Failure, .exhausted)
        }
      }
      XCTAssertEqual(connection.state, .closing)
      XCTAssertLessThan(connection.inboundBytes, limit)
      XCTAssertLessThan(connection.outboundRecords, 256)
    }
  }

  func testProductQueuedAndCancelledRequestsNeverRefundLifetimeAdmission() throws {
    let now = ContinuousClock().now
    let connection = try productReady(now: now)
    let before = connection.outboundBytes
    var targets: [UUID] = []
    for _ in 0..<3 {
      targets.append(
        try connection.request(
          method: "product.loginObserve", params: identity(),
          timeoutMs: 100, now: now))
    }
    let queued = connection.outboundBytes
    XCTAssertGreaterThan(queued, before)
    XCTAssertThrowsError(
      try connection.request(
        method: "product.loginCancel", params: identity(),
        timeoutMs: 100, now: now)
    ) {
      XCTAssertEqual($0 as? AgentRPCConnection.Failure, .busy)
    }
    XCTAssertEqual(connection.outboundBytes, queued)
    let cancel = try connection.cancel(targetID: targets[0], timeoutMs: 100, now: now)
    let admitted = connection.outboundBytes
    XCTAssertGreaterThan(admitted, queued)
    XCTAssertEqual(connection.outboundRecords, 5)
    for _ in 0..<4 { XCTAssertNotNil(connection.takeOutbound()) }
    XCTAssertEqual(connection.outboundBytes, admitted)
    connection.receive(try result(cancel, ["accepted": true]), now: now)
    XCTAssertEqual(connection.outstandingCount, 3)
    XCTAssertEqual(connection.outboundBytes, admitted)
    connection.transportFailed()
    XCTAssertEqual(connection.outboundBytes, admitted)
    XCTAssertEqual(connection.outboundRecords, 5)
    XCTAssertNil(connection.takeOutbound())
    let discarded = try productReady(now: now)
    _ = try discarded.request(
      method: "product.loginObserve", params: identity(), timeoutMs: 100, now: now)
    let total = discarded.outboundBytes
    discarded.transportFailed()
    XCTAssertEqual(discarded.outboundBytes, total)
    XCTAssertEqual(discarded.outboundRecords, 2)
    XCTAssertNil(discarded.takeOutbound())
  }

  func testProductRemainingClosedMethodsUseAuthorityAndUnknownIsNotClean() throws {
    let now = ContinuousClock().now
    let connection = try productReady(now: now)
    var retire = identity()
    retire["cleanupID"] = UUID().uuidString.lowercased()
    let startup: [String: Any] = [
      "cleanupID": UUID().uuidString.lowercased(),
      "expectedSelector": selector,
    ]
    let purge: [String: Any] = [
      "cleanupID": UUID().uuidString.lowercased(),
      "paperID": UUID().uuidString.lowercased(), "generation": 1,
      "correlationID": UUID().uuidString.lowercased(),
    ]
    for (method, params) in [("product.stageRetire", retire), ("product.startupCleanup", startup)] {
      var unknown = params
      unknown.merge(["state": "unknown", "stopped": false, "closed": false, "absent": false]) {
        _, n in n
      }
      try exchange(connection, method: method, params: params, response: unknown, now: now)
    }
    let id = try connection.request(
      method: "product.paperPurge", params: purge,
      timeoutMs: 100, now: now)
    _ = connection.takeOutbound()
    var failure: AgentRPCConnection.Failure?
    connection.onTerminal = { _, terminal in
      if case .failure(let value) = terminal { failure = value }
    }
    connection.receive(
      try ProviderRPC.encode([
        "kind": "error", "id": id.uuidString.lowercased(),
        "code": "invalidParams",
      ]), now: now)
    XCTAssertEqual(failure, .remote("invalidParams"))
    XCTAssertEqual(connection.state, .ready)
    XCTAssertFalse(connection.transportClosureObserved)
  }

  func testHandshakeRequiredAndUnsupportedProductOperationsNeverQueue() throws {
    let now = ContinuousClock().now
    let connection = try AgentRPCConnection(mode: .topology, now: now)
    XCTAssertThrowsError(
      try connection.request(
        method: "topology.wait",
        params: ["durationMs": 1], timeoutMs: 10, now: now)
    ) {
      XCTAssertEqual($0 as? AgentRPCConnection.Failure, .notReady)
    }
    let admitted = try ready(now: now)
    for method in ["login", "auth", "chat", "usable", "hello"] {
      XCTAssertThrowsError(
        try admitted.request(
          method: method, params: [:],
          timeoutMs: 10, now: now)
      ) {
        XCTAssertEqual($0 as? AgentRPCConnection.Failure, .unsupportedOperation)
      }
    }
    XCTAssertNil(admitted.takeOutbound())
    XCTAssertEqual(admitted.outstandingCount, 0)
  }

  func testFragmentedValidatedResponseSelectsOneTerminal() throws {
    let now = ContinuousClock().now
    let connection = try ready(now: now)
    let id = try connection.request(
      method: "topology.wait", params: ["durationMs": 1],
      timeoutMs: 100, now: now)
    let outbound = try XCTUnwrap(connection.takeOutbound())
    XCTAssertEqual(outbound.id, id)
    let request = try ProviderRPC.decode(outbound.frame)
    try ProviderRPC.validateRequest(request)
    XCTAssertEqual(request["id"] as? String, id.uuidString.lowercased())
    var completed: [UUID] = []
    connection.onTerminal = { identifier, terminal in
      completed.append(identifier)
      if case .result(let value) = terminal {
        XCTAssertEqual(value["elapsed"] as? Bool, true)
      } else {
        XCTFail("Expected validated result")
      }
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
    let first = try connection.request(
      method: "topology.wait", params: ["durationMs": 1],
      timeoutMs: 100, now: now)
    let second = try connection.request(
      method: "topology.wait", params: ["durationMs": 1],
      timeoutMs: 100, now: now)
    _ = connection.takeOutbound()
    _ = connection.takeOutbound()
    var successes = 0
    var failures = 0
    connection.onTerminal = { _, terminal in
      switch terminal {
      case .result: successes += 1
      case .failure: failures += 1
      }
    }
    var bytes = try result(first, ["elapsed": true])
    bytes.append(try result(second, ["accepted": true]))  // Wrong method's result schema.
    connection.receive(bytes, now: now)
    XCTAssertEqual(successes, 0)
    XCTAssertEqual(failures, 2)
    XCTAssertEqual(connection.state, .poisoned)
  }

  func testUnsentAndUnknownCorrelationsPoison() throws {
    let now = ContinuousClock().now
    let connection = try AgentRPCConnection(mode: .topology, now: now)
    connection.receive(
      try result(
        UUID(),
        [
          "major": 1, "minor": 1,
          "capabilities": ["topology-v1"],
        ]), now: now)
    XCTAssertEqual(connection.state, .poisoned)
    XCTAssertNil(connection.takeOutbound())
    let unsent = try ready(now: now)
    let id = try unsent.request(
      method: "topology.wait", params: ["durationMs": 1],
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
      targets.append(
        try connection.request(
          method: "topology.wait", params: ["durationMs": 1],
          timeoutMs: 100, now: now))
      _ = connection.takeOutbound()
    }
    XCTAssertThrowsError(
      try connection.request(
        method: "topology.wait",
        params: ["durationMs": 1], timeoutMs: 100, now: now)
    ) {
      XCTAssertEqual($0 as? AgentRPCConnection.Failure, .busy)
    }
    let cancelID = try connection.cancel(targetID: targets[0], timeoutMs: 100, now: now)
    let cancel = try XCTUnwrap(connection.takeOutbound())
    XCTAssertEqual(cancel.id, cancelID)
    let request = try ProviderRPC.decode(cancel.frame)
    try ProviderRPC.validateRequest(request)
    XCTAssertEqual(request["method"] as? String, "cancel")
    XCTAssertEqual(
      (request["params"] as? [String: Any])?["targetID"] as? String,
      targets[0].uuidString.lowercased())
    XCTAssertThrowsError(try connection.cancel(targetID: targets[0], timeoutMs: 100, now: now))
    connection.receive(try result(cancelID, ["accepted": true]), now: now)
    XCTAssertEqual(connection.outstandingCount, count)
    XCTAssertFalse(connection.transportClosureObserved)
    connection.receive(
      try ProviderRPC.encode([
        "kind": "error", "id": targets[0].uuidString.lowercased(),
        "code": "cancelled",
      ]), now: now)
    XCTAssertEqual(connection.outstandingCount, count - 1)
    XCTAssertFalse(connection.transportClosureObserved)
  }

  func testTimeoutFailsClosedAndLateResponseCannotWin() throws {
    let now = ContinuousClock().now
    let connection = try ready(now: now)
    let id = try connection.request(
      method: "topology.wait", params: ["durationMs": 1],
      timeoutMs: 1, now: now)
    _ = connection.takeOutbound()
    var failures: [AgentRPCConnection.Failure] = []
    connection.onTerminal = { _, terminal in
      if case .failure(let failure) = terminal {
        failures.append(failure)
      } else {
        XCTFail("Timeout must win")
      }
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
    let id = try connection.request(
      method: "topology.wait", params: ["durationMs": 1],
      timeoutMs: 100, now: now)
    _ = connection.takeOutbound()
    connection.drain()
    XCTAssertEqual(connection.state, .draining)
    XCTAssertThrowsError(
      try connection.request(
        method: "topology.wait",
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
    let connection = try AgentRPCConnection(mode: .topology, now: now)
    let hello = try XCTUnwrap(connection.takeOutbound())
    connection.receive(
      try ProviderRPC.encode([
        "kind": "error", "id": hello.id.uuidString.lowercased(),
        "code": "versionMismatch",
      ]), now: now)
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
    for _ in 1..<count {  // The handshake consumes one request identity.
      let id = try connection.request(
        method: "topology.wait", params: ["durationMs": 1],
        timeoutMs: 100, now: now)
      _ = connection.takeOutbound()
      connection.receive(try result(id, ["elapsed": true]), now: now)
    }
    XCTAssertEqual(connection.state, .closing)
    XCTAssertNil(connection.takeOutbound())
    XCTAssertThrowsError(
      try connection.request(
        method: "topology.wait",
        params: ["durationMs": 1], timeoutMs: 100, now: now))
  }

  func testTimeoutBoundsAndUnknownParamsDoNotConsumeRequestSlots() throws {
    let now = ContinuousClock().now
    let connection = try ready(now: now)
    let minimum = try ProviderRPC.limit("minTimeoutMs")
    let maximum = try ProviderRPC.limit("maxTimeoutMs")
    for timeout in [minimum - 1, maximum + 1] {
      XCTAssertThrowsError(
        try connection.request(
          method: "topology.wait",
          params: ["durationMs": 1], timeoutMs: timeout, now: now)
      ) {
        XCTAssertEqual($0 as? AgentRPCConnection.Failure, .invalidRequest)
      }
    }
    XCTAssertThrowsError(
      try connection.request(
        method: "topology.wait",
        params: ["durationMs": 1, "extra": true], timeoutMs: minimum, now: now))
    XCTAssertEqual(connection.outstandingCount, 0)
    XCTAssertNil(connection.takeOutbound())
    _ = try connection.request(
      method: "topology.wait", params: ["durationMs": 1],
      timeoutMs: maximum, now: now)
    XCTAssertEqual(connection.outstandingCount, 1)
  }

  private func settle(
    _ predicate: () -> Bool,
    file: StaticString = #filePath, line: UInt = #line
  ) async {
    for _ in 0..<10_000 {
      if predicate() { return }
      await Task.yield()
    }
    XCTFail("Lifecycle did not reach the expected barrier", file: file, line: line)
  }

  func testCancellationOnlyDispatchDropsQueuedProbeAndFencesLateSuccess() async throws {
    let channel = SuspendedRPCChannel()
    let lifecycle = try AgentConnectionLifecycle(channel: channel, mode: .product)
    try lifecycle.start()
    await settle { channel.readPending && channel.writePending }
    let hello = try ProviderRPC.decode(XCTUnwrap(channel.frames.last))
    let helloID = try XCTUnwrap(UUID(uuidString: XCTUnwrap(hello["id"] as? String)))
    channel.finishWrite()
    channel.finishRead(try result(helloID, productHello))
    await settle { lifecycle.connection.state == .ready && channel.readPending }
    var params = identity()
    params["expectedSelector"] = selector
    let probe = try lifecycle.request(
      method: "product.connectionTest", params: params, timeoutMs: 10000)
    await settle { channel.writePending && channel.writeCalls == 2 }
    // One probe already entered the channel; another must never enter it.
    _ = try lifecycle.request(method: "product.connectionTest", params: params, timeoutMs: 10000)
    var dispatched = false
    var published = false
    lifecycle.onTerminal = { _, _ in published = true }
    try lifecycle.dispatchCancellation(params: identity()) { dispatched = true }
    XCTAssertThrowsError(
      try lifecycle.request(
        method: "product.loginObserve", params: identity(), timeoutMs: 10000))
    var usable = params
    usable["state"] = "usable"
    usable["text"] = "PAPERLENS_OK"
    channel.finishRead(try result(probe, usable))
    channel.finishWrite()
    await settle { channel.writePending && channel.writeCalls == 3 }
    XCTAssertEqual(
      try ProviderRPC.decode(XCTUnwrap(channel.frames.last))["method"] as? String,
      "product.loginCancel")
    XCTAssertFalse(published)
    XCTAssertFalse(dispatched)
    channel.finishWrite()
    await settle { dispatched }
    XCTAssertFalse(published)
    XCTAssertFalse(lifecycle.connection.transportClosureObserved)
    lifecycle.close()
  }

  func testStalledCancellationWriterCannotExtendOwnerDeadlineEvenWhenMainActorStalls() async throws
  {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: directory) }
    let owner = OwnedChildRetirement(runningFixture: .cat, privateWorkingDirectory: directory)
    let channel = SuspendedRPCChannel()
    let lifecycle = try AgentConnectionLifecycle(channel: channel, mode: .product)
    lifecycle.bindOwner(permit: { owner.core.allowsIO }, handshake: {}, failure: { owner.revoke() })
    try lifecycle.start()
    await settle { channel.readPending && channel.writePending }
    let hello = try ProviderRPC.decode(XCTUnwrap(channel.frames.last))
    let helloID = try XCTUnwrap(UUID(uuidString: XCTUnwrap(hello["id"] as? String)))
    channel.finishWrite()
    channel.finishRead(try result(helloID, productHello))
    await settle { lifecycle.connection.state == .ready && channel.readPending }
    // Hold cleanup independently of the channel and MainActor. No child or FD
    // proof is synthesized by this timer-only fixture.
    let cleanupGate = DispatchSemaphore(value: 0)
    owner.core.operation.async { _ = cleanupGate.wait(timeout: .now() + .seconds(2)) }
    defer { cleanupGate.signal() }
    let before = DispatchTime.now().uptimeNanoseconds
    owner.retire(cancelling: lifecycle, params: identity())
    let deadline = owner.core.lock.withLock { owner.core.deadline }
    XCTAssertGreaterThanOrEqual(deadline, before + 300_000_000)
    XCTAssertLessThan(deadline, before + 350_000_000)
    await settle { channel.writePending && channel.writeCalls == 2 }
    // Deliberately stall this actor, not the owner's independent terminal lane.
    let terminal = DispatchSemaphore(value: 0)
    owner.observeTerminal { _ in terminal.signal() }
    XCTAssertEqual(terminal.wait(timeout: .now() + .seconds(1)), .success)
    XCTAssertEqual(owner.terminal, .unknown(.deadline))
    XCTAssertEqual(owner.core.lock.withLock { owner.core.deadline }, deadline)
    XCTAssertTrue(owner.core.lock.withLock { owner.core.revoked })
    XCTAssertTrue(owner.testingRetained)
    channel.finishWrite()
    channel.finishRead(nil)
    await Task.yield()
    XCTAssertEqual(owner.terminal, .unknown(.deadline))
  }

  func testProductLifecycleUsableTranscriptAndIngressExhaustionClosesActualChannel() async throws {
    let channel = SuspendedRPCChannel()
    let lifecycle = try AgentConnectionLifecycle(channel: channel, mode: .product)
    try lifecycle.start()
    await settle { channel.readPending && channel.writePending }
    let hello = try ProviderRPC.decode(XCTUnwrap(channel.frames.last))
    XCTAssertEqual(hello["method"] as? String, "product.hello")
    let helloID = try XCTUnwrap(UUID(uuidString: XCTUnwrap(hello["id"] as? String)))
    let reply = try result(helloID, productHello)
    channel.finishWrite()
    channel.finishRead(Data(reply.prefix(3)))
    await settle { channel.readCalls == 2 && channel.readPending }
    XCTAssertEqual(lifecycle.connection.state, .handshaking)
    channel.finishRead(Data(reply.dropFirst(3)))
    await settle { lifecycle.connection.state == .ready && channel.readPending }
    var params = identity()
    params["expectedSelector"] = selector
    var response = params
    response["state"] = "usable"
    response["text"] = "PAPERLENS_OK"
    var successes = 0
    lifecycle.onTerminal = { _, terminal in
      if case .result(let value) = terminal {
        XCTAssertEqual(value["text"] as? String, "PAPERLENS_OK")
        successes += 1
      }
    }
    let probe = try lifecycle.request(
      method: "product.connectionTest", params: params, timeoutMs: 10000)
    await settle { channel.writeCalls == 2 && channel.writePending }
    channel.finishWrite()
    channel.finishRead(try result(probe, response))
    await settle { successes == 1 && channel.readPending }
    let limit = try ProviderRPC.limit("maxQueuedBytes")
    // Exceeds cumulative ingress before any decoder processing; actual lifecycle revokes IO.
    channel.finishRead(Data(repeating: 32, count: limit - lifecycle.connection.inboundBytes + 1))
    await settle { channel.closeRequests == 1 }
    XCTAssertEqual(lifecycle.connection.state, .closing)
    XCTAssertFalse(lifecycle.connection.transportClosureObserved)
    XCTAssertEqual(successes, 1)
    lifecycle.transportDidClose()
    await settle { lifecycle.connection.transportClosureObserved }
    XCTAssertEqual(channel.closeRequests, 1)
  }

  func testProductLifecycleThrownOutboundExhaustionClosesAndJoinsHeldRead() async throws {
    let channel = SuspendedRPCChannel()
    let lifecycle = try AgentConnectionLifecycle(channel: channel, mode: .product)
    try lifecycle.start()
    await settle { channel.readPending && channel.writePending }
    let hello = try ProviderRPC.decode(XCTUnwrap(channel.frames.last))
    let helloID = try XCTUnwrap(UUID(uuidString: XCTUnwrap(hello["id"] as? String)))
    channel.finishWrite()
    channel.finishRead(try result(helloID, productHello))
    await settle { lifecycle.connection.state == .ready && channel.readPending }
    let limit = try ProviderRPC.limit("maxRequestsPerConnection")
    for record in 1..<limit - 1 {
      let id = try lifecycle.cancel(targetID: UUID(), timeoutMs: 10000)
      await settle { channel.writeCalls == record + 1 && channel.writePending }
      channel.finishWrite()
      channel.finishRead(try result(id, ["accepted": true]))
      await settle { lifecycle.connection.outstandingCount == 0 && channel.readPending }
    }
    _ = try lifecycle.cancel(targetID: UUID(), timeoutMs: 10000)
    // Final record is admitted but deliberately not dispatched. The next request throws.
    XCTAssertThrowsError(
      try lifecycle.request(
        method: "product.loginObserve", params: identity(),
        timeoutMs: 10000)
    ) {
      XCTAssertEqual($0 as? AgentRPCConnection.Failure, .exhausted)
    }
    XCTAssertEqual(channel.closeRequests, 1)
    XCTAssertFalse(lifecycle.connection.transportClosureObserved)
    XCTAssertEqual(lifecycle.connection.outboundRecords, limit)
    channel.finishRead(nil)
    lifecycle.transportDidClose()
    await settle { lifecycle.connection.transportClosureObserved }
    XCTAssertEqual(channel.writeCalls, limit - 1)
    XCTAssertEqual(channel.closeRequests, 1)
  }

  func testLifecycleEOFDoesNotPublishClosureWhileWriteIsSuspended() async throws {
    let channel = SuspendedRPCChannel()
    let lifecycle = try AgentConnectionLifecycle(channel: channel, mode: .topology)
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
    XCTAssertThrowsError(
      try lifecycle.request(
        method: "topology.wait",
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
    let lifecycle = try AgentConnectionLifecycle(channel: channel, mode: .topology)
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
    let lifecycle = try AgentConnectionLifecycle(channel: channel, mode: .topology)
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
  private(set) var frames: [Data] = []
  var readPending: Bool { readContinuation != nil }
  var writePending: Bool { writeContinuation != nil }

  func read() async throws -> Data? {
    readCalls += 1
    return await withCheckedContinuation { readContinuation = $0 }
  }

  func write(_ frame: Data) async throws {
    writeCalls += 1
    frames.append(frame)
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
