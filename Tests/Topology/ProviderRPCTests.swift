import Foundation
import ProviderRPC
import XCTest

final class ProviderRPCTests: XCTestCase {
  private let id = "01234567-89ab-4cde-8123-456789abcdef"

  override func setUpWithError() throws {
    #if SWIFT_PACKAGE
      // No source path is configured: the target's Bundle.module must supply its contract.
      _ = try ProviderRPC.encode([:])
    #else
      let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      try ProviderRPC.configure(
        contractURL: root.appendingPathComponent("Contracts/ProviderRPC/contract.json"))
    #endif
  }

  private func request(_ method: String = "topology.runtime", params: [String: Any] = [:])
    -> [String: Any]
  {
    ["kind": "request", "id": id, "method": method, "timeoutMs": 10000, "params": params]
  }

  private func terminal(_ result: [String: Any]) -> [String: Any] {
    ["kind": "result", "id": id, "result": result]
  }

  private var probe: [String: Any] {
    [
      "outcome": "denied", "reason": "permissionDenied", "syscallObserved": true,
      "syscallResult": -1, "errno": 13, "beganAtNs": 1, "endedAtNs": 2,
    ]
  }

  private func raw(_ body: Data) -> Data {
    let count = UInt32(body.count)
    var frame = prefix(count)
    frame.append(body)
    return frame
  }

  private func raw(_ body: String) -> Data { raw(Data(body.utf8)) }

  private func prefix(_ count: UInt32) -> Data {
    Data([
      UInt8((count >> 24) & 255), UInt8((count >> 16) & 255), UInt8((count >> 8) & 255),
      UInt8(count & 255),
    ])
  }

  private func rejects<T>(
    _ expected: ProviderRPCError = .protocolViolation,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ action: () throws -> T
  ) {
    XCTAssertThrowsError(try action(), file: file, line: line) { error in
      XCTAssertEqual(error as? ProviderRPCError, expected, file: file, line: line)
    }
  }

  private var cases: [(String, [String: Any], [String: Any])] {
    [
      (
        "hello", ["major": 1, "minor": 1, "capabilities": ["topology-v1"]],
        ["major": 1, "minor": 1, "capabilities": ["topology-v1"]]
      ),
      (
        "topology.runtime", [:],
        ["sdkImported": true, "cliInitialized": false, "architecture": "arm64"]
      ),
      ("topology.prepare", ["runID": id], ["prepared": true]),
      ("topology.identity", ["runID": id], ["bridgePID": 1, "pythonPID": 2_147_483_647]),
      (
        "topology.probe", ["runID": id, "caseID": "ownZoneReadWrite"],
        probe
      ),
      ("topology.cleanup", ["runID": id], ["absent": true]),
      ("topology.wait", ["durationMs": 1], ["elapsed": true]),
      (
        "topology.attemptPrepare",
        ["runID": id, "paperID": id, "generation": 1, "correlationID": id],
        ["prepared": true]
      ),
      (
        "topology.attemptTerminal",
        ["runID": id, "paperID": id, "generation": 1, "correlationID": id, "outcome": "success"],
        ["absent": true]
      ),
      ("topology.attemptRecover", ["runID": id], ["absent": true]),
      (
        "topology.paperPurge",
        ["runID": id, "paperID": id, "generation": 1, "correlationID": id],
        ["absent": true, "drained": true]
      ),
      ("cancel", ["targetID": id], ["accepted": false]),
    ]
  }

  func testExplicitContractURLAndFailedReconfiguration() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let url = root.appendingPathComponent("Contracts/ProviderRPC/contract.json")
    try ProviderRPC.configure(contractURL: url)
    let frame = try ProviderRPC.encode(request("topology.wait", params: ["durationMs": 5000]))
    try ProviderRPC.validateRequest(ProviderRPC.decode(frame))
    rejects { try ProviderRPC.configure(contractURL: url.appendingPathComponent("nonexistent")) }
    try ProviderRPC.validateRequest(ProviderRPC.decode(frame))
  }

  func testEveryMethodRoundTripAndClosedFields() throws {
    for (method, params, result) in cases {
      let original = request(method, params: params)
      let decoded = try ProviderRPC.decode(ProviderRPC.encode(original))
      XCTAssertTrue(NSDictionary(dictionary: original).isEqual(to: decoded))
      try ProviderRPC.validateRequest(decoded)
      let response = terminal(result)
      try ProviderRPC.validateTerminal(
        ProviderRPC.decode(ProviderRPC.encode(response)), method: method)
      var extra = params
      extra["path"] = "/tmp/forbidden"
      rejects(.invalidParams) { try ProviderRPC.validateRequest(request(method, params: extra)) }
      for key in params.keys {
        var missing = params
        missing.removeValue(forKey: key)
        rejects(.invalidParams) {
          try ProviderRPC.validateRequest(request(method, params: missing))
        }
      }
      var badEnvelope = response
      badEnvelope["message"] = "forbidden"
      rejects { try ProviderRPC.validateTerminal(badEnvelope, method: method) }
      var badResult = result
      badResult["message"] = "forbidden"
      rejects { try ProviderRPC.validateTerminal(terminal(badResult), method: method) }
      for key in result.keys {
        var missing = result
        missing.removeValue(forKey: key)
        rejects { try ProviderRPC.validateTerminal(terminal(missing), method: method) }
      }
      rejects { try ProviderRPC.validateTerminal(terminal([:]), method: method) }
    }
  }

  func testPaperPurgeIdentityBoundsAndEnvelopeSeparation() throws {
    let method = "topology.paperPurge"
    let identity: [String: Any] = [
      "runID": "11234567-89ab-4cde-8123-456789abcdef",
      "paperID": "21234567-89ab-4cde-8123-456789abcdef",
      "generation": 1, "correlationID": "31234567-89ab-4cde-8123-456789abcdef",
    ]
    let retryID = "41234567-89ab-4cde-8123-456789abcdef"
    for envelopeID in [id, retryID] {
      var original = request(method, params: identity)
      original["id"] = envelopeID
      let decoded = try ProviderRPC.decode(ProviderRPC.encode(original))
      try ProviderRPC.validateRequest(decoded)
      XCTAssertEqual(decoded["id"] as? String, envelopeID)
      let params = try XCTUnwrap(decoded["params"] as? [String: Any])
      XCTAssertTrue(NSDictionary(dictionary: identity).isEqual(to: params))
      XCTAssertNotEqual(decoded["id"] as? String, params["correlationID"] as? String)
      var response = terminal(["absent": true, "drained": true])
      response["id"] = envelopeID
      let decodedResponse = try ProviderRPC.decode(ProviderRPC.encode(response))
      try ProviderRPC.validateTerminal(decodedResponse, method: method)
      XCTAssertEqual(decodedResponse["id"] as? String, decoded["id"] as? String)
    }
    for generation in [1, 2_147_483_647] {
      var params = identity
      params["generation"] = generation
      try ProviderRPC.validateRequest(
        ProviderRPC.decode(ProviderRPC.encode(request(method, params: params))))
    }
    for generation in [0, -1, 2_147_483_648, true, false, 1.0, "1", NSNull()] as [Any] {
      var params = identity
      params["generation"] = generation
      let decoded = try ProviderRPC.decode(ProviderRPC.encode(request(method, params: params)))
      rejects(.invalidParams) { try ProviderRPC.validateRequest(decoded) }
    }
    for key in ["runID", "paperID", "correlationID"] {
      for invalid in [
        id.uppercased(), "../fixture", "01234567-89ab-1cde-8123-456789abcdef", true, false, 1,
        NSNull(),
      ] as [Any] {
        var params = identity
        params[key] = invalid
        let decoded = try ProviderRPC.decode(ProviderRPC.encode(request(method, params: params)))
        rejects(.invalidParams) { try ProviderRPC.validateRequest(decoded) }
      }
    }
    var invalidEnvelope = request(method, params: identity)
    invalidEnvelope["id"] = true
    rejects { try ProviderRPC.validateRequest(invalidEnvelope) }
    invalidEnvelope = request(method, params: identity)
    invalidEnvelope["correlationID"] = identity["correlationID"]
    rejects { try ProviderRPC.validateRequest(invalidEnvelope) }
    var invalidParams = identity
    invalidParams["id"] = id
    rejects(.invalidParams) {
      try ProviderRPC.validateRequest(request(method, params: invalidParams))
    }
  }

  func testPaperPurgeResultIsTrueOnly() throws {
    let method = "topology.paperPurge"
    let result: [String: Any] = ["absent": true, "drained": true]
    for key in result.keys {
      for invalid in [false, 0, 1, NSNull(), "true"] as [Any] {
        var invalidResult = result
        invalidResult[key] = invalid
        let decoded = try ProviderRPC.decode(ProviderRPC.encode(terminal(invalidResult)))
        rejects { try ProviderRPC.validateTerminal(decoded, method: method) }
      }
    }
    try ProviderRPC.validateTerminal(
      ["kind": "error", "id": id, "code": "unavailable"], method: method)
  }

  func testPaperPurgeDuplicateMalformedAndFramingRejection() throws {
    let params: [String: Any] = ["runID": id, "paperID": id, "generation": 1, "correlationID": id]
    let frame = try ProviderRPC.encode(request("topology.paperPurge", params: params))
    let body = String(decoding: frame.dropFirst(4), as: UTF8.self)
    let response = try ProviderRPC.encode(terminal(["absent": true, "drained": true]))
    let terminalBody = String(decoding: response.dropFirst(4), as: UTF8.self)
    let invalidBodies = [
      String(body.dropLast()), body + "{}",
      body.replacingOccurrences(of: "\"id\":", with: "\"id\":\"\(id)\",\"id\":"),
      body.replacingOccurrences(of: "\"runID\":", with: "\"runID\":\"\(id)\",\"runID\":"),
      body.replacingOccurrences(of: "\"generation\":1", with: "\"generation\":1,\"generation\":1"),
      terminalBody.replacingOccurrences(
        of: "\"absent\":true", with: "\"absent\":true,\"absent\":true"),
      terminalBody.replacingOccurrences(
        of: "\"drained\":true", with: "\"drained\":true,\"drained\":true"),
    ]
    for invalid in invalidBodies { rejects { try ProviderRPC.decode(raw(invalid)) } }
    for invalid in [Data(frame.dropLast()), frame + Data([120]), prefix(0) + frame.dropFirst(4)] {
      rejects { try ProviderRPC.decode(invalid) }
    }
    var decoder = ProviderFrameDecoder()
    XCTAssertEqual(try decoder.feed(Data(frame.prefix(3))), [])
    XCTAssertEqual(try decoder.feed(Data(frame.dropFirst(3))), [frame])
    try decoder.finish()
    decoder = ProviderFrameDecoder()
    XCTAssertEqual(try decoder.feed(Data(frame.dropLast())), [])
    rejects { try decoder.finish() }
    rejects { try decoder.feed(frame) }
  }

  func testGenericDecodeSeparatesTypedMethodFailures() throws {
    let unknown = request("arbitrary.execute", params: ["command": "not-executed"])
    let decoded = try ProviderRPC.decode(ProviderRPC.encode(unknown))
    rejects(.unknownMethod) { try ProviderRPC.validateRequest(decoded) }
    let invalid = request("topology.wait", params: ["durationMs": 0])
    let invalidDecoded = try ProviderRPC.decode(ProviderRPC.encode(invalid))
    rejects(.invalidParams) { try ProviderRPC.validateRequest(invalidDecoded) }
    rejects {
      try ProviderRPC.validateTerminal(terminal(["prepared": true]), method: "topology.cleanup")
    }
    rejects(.unknownMethod) { try ProviderRPC.validateTerminal(terminal([:]), method: "missing") }
    try ProviderRPC.validateTerminal(
      ["kind": "error", "id": id, "code": "unknownMethod"], method: "missing")
    var malformed = request("missing")
    malformed["id"] = "invalid"
    rejects { try ProviderRPC.validateRequest(malformed) }
    malformed = request("missing")
    malformed["params"] = [] as [Any]
    rejects { try ProviderRPC.validateRequest(malformed) }
  }

  func testAttemptIdentityGenerationAndOutcomeBoundaries() throws {
    let methods = ["topology.attemptPrepare", "topology.attemptTerminal"]
    for method in methods {
      var params: [String: Any] = [
        "runID": id, "paperID": id, "generation": 1, "correlationID": id,
      ]
      if method == "topology.attemptTerminal" { params["outcome"] = "success" }
      for generation in [1, 2_147_483_647] {
        params["generation"] = generation
        try ProviderRPC.validateRequest(
          ProviderRPC.decode(ProviderRPC.encode(request(method, params: params))))
      }
      for generation in [0, -1, 2_147_483_648, true, false, 1.0, "1", NSNull()] as [Any] {
        params["generation"] = generation
        rejects(.invalidParams) { try ProviderRPC.validateRequest(request(method, params: params)) }
      }
      params["generation"] = 1
      for key in ["runID", "paperID", "correlationID"] {
        for invalid in [id.uppercased(), "invalid", 1, NSNull()] as [Any] {
          var changed = params
          changed[key] = invalid
          rejects(.invalidParams) {
            try ProviderRPC.validateRequest(request(method, params: changed))
          }
        }
      }
    }
    var params: [String: Any] = [
      "runID": id, "paperID": id, "generation": 1, "correlationID": id,
    ]
    for outcome in ["success", "failure", "cancelled"] {
      params["outcome"] = outcome
      try ProviderRPC.validateRequest(request("topology.attemptTerminal", params: params))
    }
    for outcome in ["finished", true, 1, NSNull()] as [Any] {
      params["outcome"] = outcome
      rejects(.invalidParams) {
        try ProviderRPC.validateRequest(request("topology.attemptTerminal", params: params))
      }
    }
  }

  func testEnvelopeUUIDAndTimeoutValidation() throws {
    for key in request().keys {
      var missing = request()
      missing.removeValue(forKey: key)
      rejects { try ProviderRPC.validateRequest(missing) }
    }
    let changes: [(String, Any)] = [
      ("message", "forbidden"), ("kind", "event"), ("params", [] as [Any]), ("method", 1),
      ("timeoutMs", 0), ("timeoutMs", 10001), ("timeoutMs", true), ("timeoutMs", 1.0),
    ]
    for (key, value) in changes {
      var object = request()
      object[key] = value
      rejects { try ProviderRPC.validateRequest(object) }
    }
    for timeout in [1, 10000] {
      var object = request()
      object["timeoutMs"] = timeout
      try ProviderRPC.validateRequest(object)
    }
    let invalidIDs: [Any] = [
      id.uppercased(), id.replacingOccurrences(of: "4cde", with: "1cde"),
      id.replacingOccurrences(of: "8123", with: "7123"), "{" + id + "}",
      id.replacingOccurrences(of: "-", with: ""), id + "\n", 1,
    ]
    for invalid in invalidIDs {
      var object = request()
      object["id"] = invalid
      rejects { try ProviderRPC.validateRequest(object) }
      rejects(.invalidParams) {
        try ProviderRPC.validateRequest(request("topology.prepare", params: ["runID": invalid]))
      }
      rejects(.invalidParams) {
        try ProviderRPC.validateRequest(request("cancel", params: ["targetID": invalid]))
      }
      rejects {
        try ProviderRPC.validateTerminal(
          ["kind": "error", "id": invalid, "code": "busy"], method: "hello")
      }
    }
  }

  func testLargeIntegerVersionsAreNotNarrowedOrRejected() throws {
    for number in [
      "18446744073709551617", "-18446744073709551617", String(repeating: "9", count: 5000),
    ] {
      let body =
        "{\"kind\":\"request\",\"id\":\"\(id)\",\"method\":\"hello\",\"timeoutMs\":1,"
        + "\"params\":{\"major\":\(number),\"minor\":1,\"capabilities\":[\"topology-v1\"]}}"
      let decoded = try ProviderRPC.decode(raw(body))
      try ProviderRPC.validateRequest(decoded)
      try ProviderRPC.validateRequest(ProviderRPC.decode(ProviderRPC.encode(decoded)))
      let integerFrame = raw("{\"x\":\(number)}")
      XCTAssertEqual(try ProviderRPC.encode(ProviderRPC.decode(integerFrame)), integerFrame)
      let params = try XCTUnwrap(decoded["params"] as? [String: Any])
      let major = try XCTUnwrap(params["major"])
      XCTAssertNil(major as? Int)
      rejects(.invalidParams) {
        try ProviderRPC.validateRequest(request("topology.wait", params: ["durationMs": major]))
      }
      rejects { try ProviderRPC.validateTerminal(terminal(params), method: "hello") }
    }
  }

  func testMethodBoundsIntegerBooleanDistinctionAndVersions() throws {
    for value in [1, 5000] {
      try ProviderRPC.validateRequest(request("topology.wait", params: ["durationMs": value]))
    }
    for value in [0, 5001, true, 1.0, "1", NSNull()] as [Any] {
      rejects(.invalidParams) {
        try ProviderRPC.validateRequest(request("topology.wait", params: ["durationMs": value]))
      }
    }
    // A well-formed mismatch reaches the connection's version admission.
    try ProviderRPC.validateRequest(
      request("hello", params: ["major": 2, "minor": 1, "capabilities": ["topology-v1"]]))
    let invalidHello: [[String: Any]] = [
      ["major": true, "minor": 1, "capabilities": ["topology-v1"]],
      ["major": 1, "minor": 1.0, "capabilities": ["topology-v1"]],
      ["major": 1, "minor": 1, "capabilities": [] as [String]],
      ["major": 1, "minor": 1, "capabilities": ["topology-v1", "unknown"]],
    ]
    for params in invalidHello {
      rejects(.invalidParams) { try ProviderRPC.validateRequest(request("hello", params: params)) }
    }
    for (method, key) in [
      ("topology.prepare", "prepared"), ("topology.cleanup", "absent"),
      ("topology.attemptPrepare", "prepared"), ("topology.attemptTerminal", "absent"),
      ("topology.attemptRecover", "absent"),
      ("topology.wait", "elapsed"), ("cancel", "accepted"),
    ] {
      for value in [0, 1] {
        rejects { try ProviderRPC.validateTerminal(terminal([key: value]), method: method) }
      }
    }
    for architecture in ["arm64", "x86_64"] {
      try ProviderRPC.validateTerminal(
        terminal(["sdkImported": true, "cliInitialized": false, "architecture": architecture]),
        method: "topology.runtime")
    }
    rejects {
      try ProviderRPC.validateTerminal(
        terminal(["sdkImported": true, "cliInitialized": false, "architecture": "aarch64"]),
        method: "topology.runtime")
    }
    rejects {
      try ProviderRPC.validateTerminal(
        terminal(["major": 2, "minor": 1, "capabilities": ["topology-v1"]]), method: "hello")
    }
    let fractional = raw(
      "{\"kind\":\"request\",\"id\":\"\(id)\",\"method\":\"topology.wait\",\"timeoutMs\":1,\"params\":{\"durationMs\":1.0}}"
    )
    rejects(.invalidParams) { try ProviderRPC.validateRequest(ProviderRPC.decode(fractional)) }
    let exponent = raw(
      "{\"kind\":\"request\",\"id\":\"\(id)\",\"method\":\"topology.wait\",\"timeoutMs\":1e0,\"params\":{\"durationMs\":1}}"
    )
    rejects { try ProviderRPC.validateRequest(ProviderRPC.decode(exponent)) }
  }

  func testExactHelloResultAndIdentityBoundaries() throws {
    let versions: [(Any, Any)] = [(1, 0), (1, 2), (2, 1), (true, 1), (1, true), (1, 1.0)]
    for (major, minor) in versions {
      rejects {
        try ProviderRPC.validateTerminal(
          terminal(["major": major, "minor": minor, "capabilities": ["topology-v1"]]),
          method: "hello")
      }
    }
    rejects(.invalidParams) {
      try ProviderRPC.validateRequest(request("topology.identity", params: ["runID": "invalid"]))
    }
    for key in ["bridgePID", "pythonPID"] {
      for value in [1, 2_147_483_647] {
        var result: [String: Any] = ["bridgePID": 1, "pythonPID": 1]
        result[key] = value
        try ProviderRPC.validateTerminal(
          ProviderRPC.decode(ProviderRPC.encode(terminal(result))), method: "topology.identity")
      }
      for value in [0, -1, 2_147_483_648, true, false, 1.0, "1", NSNull(), UInt64.max] as [Any] {
        var result: [String: Any] = ["bridgePID": 1, "pythonPID": 1]
        result[key] = value
        rejects { try ProviderRPC.validateTerminal(terminal(result), method: "topology.identity") }
      }
    }
  }

  func testProbeObservationTypesRangesAndCoherence() throws {
    func validate(_ result: [String: Any]) throws {
      try ProviderRPC.validateTerminal(
        ProviderRPC.decode(ProviderRPC.encode(terminal(result))), method: "topology.probe")
    }
    var unobserved = probe
    unobserved["syscallObserved"] = false
    for key in ["syscallResult", "errno", "beganAtNs", "endedAtNs"] { unobserved[key] = 0 }
    try validate(unobserved)
    for key in ["syscallResult", "errno", "beganAtNs", "endedAtNs"] {
      rejects { try validate(unobserved.merging([key: 1]) { _, new in new }) }
      for value in [true, false, 1.0, "1", NSNull()] as [Any] {
        rejects { try validate(probe.merging([key: value]) { _, new in new }) }
      }
    }
    for value in [0, 1, "true", NSNull()] as [Any] {
      rejects { try validate(probe.merging(["syscallObserved": value]) { _, new in new }) }
    }
    let valid: [[String: Any]] = [
      ["syscallResult": -2_147_483_648], ["syscallResult": 2_147_483_647, "errno": 0],
      ["syscallResult": 0, "errno": 0], ["errno": 0], ["errno": 2_147_483_647], ["beganAtNs": 0],
      ["beganAtNs": Int64.max - 1, "endedAtNs": Int64.max],
    ]
    for changes in valid { try validate(probe.merging(changes) { _, new in new }) }
    let invalid: [[String: Any]] = [
      ["syscallResult": -2_147_483_649], ["syscallResult": 2_147_483_648],
      ["errno": -1], ["errno": 2_147_483_648],
      ["beganAtNs": -1], ["beganAtNs": UInt64(Int64.max) + 1],
      ["endedAtNs": -1], ["endedAtNs": UInt64(Int64.max) + 1],
      ["endedAtNs": 0], ["endedAtNs": 1],
      ["beganAtNs": 3], ["syscallResult": 0], ["syscallResult": 1],
    ]
    for changes in invalid {
      rejects { try validate(probe.merging(changes) { _, new in new }) }
    }
    rejects { try validate(["outcome": "denied", "reason": "permissionDenied"]) }
  }

  func testClosedProbeAndErrorEnums() throws {
    let caseIDs = [
      "ownZoneReadWrite", "mainCanaryRead", "mainCanaryWrite", "externalCanaryRead",
      "externalCanaryWrite", "mainCanarySymlinkRead", "externalCanarySymlinkRead",
      "foreignGroupCanaryRead", "foreignGroupCanaryWrite", "foreignGroupCanarySymlinkRead",
      "inboundListen",
    ]
    for caseID in caseIDs {
      try ProviderRPC.validateRequest(
        request("topology.probe", params: ["runID": id, "caseID": caseID]))
    }
    rejects(.invalidParams) {
      try ProviderRPC.validateRequest(
        request("topology.probe", params: ["runID": id, "caseID": "arbitraryPath"]))
    }
    for outcome in ["allowed", "denied", "inconclusive"] {
      for reason in [
        "none", "permissionDenied", "missingFixture", "controlFailed", "unexpectedErrno",
      ] {
        try ProviderRPC.validateTerminal(
          terminal(probe.merging(["outcome": outcome, "reason": reason]) { _, new in new }),
          method: "topology.probe")
      }
    }
    for result in [
      ["outcome": "success", "reason": "none"], ["outcome": "allowed", "reason": "ENOENT"],
    ] {
      rejects {
        try ProviderRPC.validateTerminal(
          terminal(probe.merging(result) { _, new in new }), method: "topology.probe")
      }
    }
    for code in [
      "versionMismatch", "handshakeRequired", "unknownMethod", "invalidParams", "busy", "cancelled",
      "timeout", "unavailable", "internal",
    ] {
      try ProviderRPC.validateTerminal(["kind": "error", "id": id, "code": code], method: "hello")
    }
    let invalid: [[String: Any]] = [
      ["kind": "error", "id": id, "code": "protocolViolation"],
      ["kind": "error", "id": id, "code": "busy", "message": "sensitive"],
      ["kind": "error", "id": id], ["kind": "event", "id": id, "code": "busy"],
    ]
    for object in invalid { rejects { try ProviderRPC.validateTerminal(object, method: "hello") } }
  }

  func testMalformedJSONAndDecodedDuplicateKeys() throws {
    let invalid = [
      #"{"x":1,"\u0078":2}"#, #"{"nested":{"x":1,"\u0078":2}}"#,
      #"{"x":"\ud800"}"#, #"{"x":"\udc00"}"#,
      #"{"x":NaN}"#, #"{"x":Infinity}"#, #"{"x":-Infinity}"#, #"{"x":1e9999}"#,
      #"{"x":01}"#, #"{"x":+1}"#, #"{"x":1.}"#, #"{"x":1e}"#,
      #"{"x":true,}"#, #"{"x":[1,]}"#, "{}{}", "[]", "null", "1", "\"text\"", " ", "{",
      "{\"x\":\"\u{0000}\"}", "\u{FEFF}{}",
    ]
    for text in invalid { rejects { try ProviderRPC.decode(raw(text)) } }
    for bytes in [[255], [192, 128], [237, 160, 128]] as [[UInt8]] {
      let body = Data("{\"x\":\"".utf8) + Data(bytes) + Data("\"}".utf8)
      rejects { try ProviderRPC.decode(raw(body)) }
    }
    for value in [Double.nan, Double.infinity, -Double.infinity] {
      rejects { try ProviderRPC.encode(["x": value]) }
    }
    rejects { try ProviderRPC.encode(["x": URL(fileURLWithPath: "/not-json")]) }
    let valid = try ProviderRPC.decode(raw(#"{"x":"\ud834\udd1e"}"#))
    XCTAssertEqual(valid["x"] as? String, "𝄞")
  }

  func testStructuralMaxAndPlusOne() throws {
    let valid: [[String: Any]] = [
      Dictionary(uniqueKeysWithValues: (0..<16).map { (String($0), $0 as Any) }),
      ["x": Array(0..<32)], ["x": String(repeating: "a", count: 256)],
      ["x": String(repeating: "é", count: 128)], [String(repeating: "k", count: 256): NSNull()],
    ]
    for object in valid {
      let decoded = try ProviderRPC.decode(ProviderRPC.encode(object))
      XCTAssertTrue(NSDictionary(dictionary: object).isEqual(to: decoded))
    }
    let invalid: [[String: Any]] = [
      Dictionary(uniqueKeysWithValues: (0..<17).map { (String($0), $0 as Any) }),
      ["x": Array(0..<33)], ["x": String(repeating: "a", count: 257)],
      ["x": String(repeating: "é", count: 128) + "x"],
      [String(repeating: "k", count: 257): NSNull()],
    ]
    for object in invalid {
      rejects { try ProviderRPC.encode(object) }
      let body = try JSONSerialization.data(withJSONObject: object)
      rejects { try ProviderRPC.decode(raw(body)) }
    }
    var nested: [Any] = []
    for _ in 0..<6 { nested = [nested] }
    _ = try ProviderRPC.decode(ProviderRPC.encode(["x": nested]))
    rejects { try ProviderRPC.encode(["x": [nested]]) }
    rejects {
      try ProviderRPC.decode(
        raw("{\"x\":" + String(repeating: "[", count: 8) + String(repeating: "]", count: 8) + "}"))
    }
    let escaped = try ProviderRPC.decode(
      raw("{\"x\":\"" + String(repeating: "\\u0061", count: 256) + "\"}"))
    XCTAssertEqual(escaped["x"] as? String, String(repeating: "a", count: 256))
  }

  func testExactBodyAndPrefixBoundaries() throws {
    let maximum = raw("{}" + String(repeating: " ", count: 65534))
    XCTAssertTrue(try ProviderRPC.decode(maximum).isEmpty)
    rejects { try ProviderRPC.decode(raw("{}" + String(repeating: " ", count: 65535))) }
    let invalid = [
      Data(), Data([0]), Data([0, 0, 0]), prefix(0), prefix(65537), prefix(UInt32.max),
      prefix(3) + Data("{}".utf8), prefix(1) + Data("{}".utf8), raw("{}") + Data([120]), raw("0"),
    ]
    for frame in invalid { rejects { try ProviderRPC.decode(frame) } }
    let strings = Array(repeating: String(repeating: "a", count: 256), count: 252)
    var arrays: [[String]] = []
    for start in stride(from: 0, to: strings.count, by: 32) {
      arrays.append(Array(strings[start..<min(start + 32, strings.count)]))
    }
    var object: [String: Any] = ["items": arrays, "pad": ""]
    let missing = 65540 - (try ProviderRPC.encode(object)).count
    XCTAssertGreaterThanOrEqual(missing, 0)
    XCTAssertLessThanOrEqual(missing, 256)
    object["pad"] = String(repeating: "b", count: missing)
    let encoded = try ProviderRPC.encode(object)
    XCTAssertEqual(encoded.count, 65540)
    XCTAssertTrue(NSDictionary(dictionary: object).isEqual(to: try ProviderRPC.decode(encoded)))
    object["pad"] = String(repeating: "b", count: missing + 1)
    rejects { try ProviderRPC.encode(object) }
  }

  func testSplitCoalescedAndPoisonedStreams() throws {
    let first = try ProviderRPC.encode(request())
    let second = try ProviderRPC.encode(request("topology.wait", params: ["durationMs": 5000]))
    for split in 0...first.count {
      let decoder = ProviderFrameDecoder()
      let frames =
        try decoder.feed(Data(first.prefix(split))) + decoder.feed(Data(first.dropFirst(split)))
      XCTAssertEqual(frames, [first])
    }
    var decoder = ProviderFrameDecoder()
    var frames: [Data] = []
    for byte in first + second { frames += try decoder.feed(Data([byte])) }
    XCTAssertEqual(frames, [first, second])
    decoder = ProviderFrameDecoder()
    XCTAssertEqual(try decoder.feed(first + second + first.prefix(3)), [first, second])
    XCTAssertEqual(try decoder.feed(Data(first.dropFirst(3))), [first])
    XCTAssertEqual(try decoder.feed(Data()), [])
    for count in [0, 65537, UInt32.max] as [UInt32] {
      decoder = ProviderFrameDecoder()
      XCTAssertEqual(try decoder.feed(Data(prefix(count).prefix(3))), [])
      rejects { try decoder.feed(Data(prefix(count).dropFirst(3))) }
      rejects { try decoder.feed(first) }
    }
    decoder = ProviderFrameDecoder()
    rejects { try decoder.feed(raw(#"{"x":1,"x":2}"#)) }
    rejects { try decoder.feed(first) }
    let maximum = raw("{}" + String(repeating: " ", count: 65534))
    decoder = ProviderFrameDecoder()
    XCTAssertEqual(
      try decoder.feed(maximum + maximum + maximum + maximum + maximum),
      Array(repeating: maximum, count: 5))
    decoder = ProviderFrameDecoder()
    XCTAssertEqual(try decoder.feed(Data(maximum.dropLast())), [])
    XCTAssertEqual(try decoder.feed(Data(maximum.suffix(1)) + first), [maximum, first])
  }

  func testSuccessfulEOFSealsEmptyCompleteAndFragmentedStreams() throws {
    let frame = try ProviderRPC.encode(request())
    for chunks in [[], [frame], [Data(frame.prefix(2)), Data(frame.dropFirst(2))]] as [[Data]] {
      let decoder = ProviderFrameDecoder()
      var frames: [Data] = []
      for chunk in chunks { frames += try decoder.feed(chunk) }
      XCTAssertEqual(frames, chunks.isEmpty ? [] : [frame])
      try decoder.finish()
      try decoder.finish()
      rejects { try decoder.feed(Data()) }
      rejects { try decoder.feed(frame) }
    }
  }

  func testMalformedCoalescedBatchReturnsNoFramesAndPoisonsStream() throws {
    let frame = try ProviderRPC.encode(request())
    let malformed = [
      raw(Data("{\"x\":\"".utf8) + Data([255]) + Data("\"}".utf8)),
      raw(#"{"x":1,"\u0078":2}"#), raw("null"), prefix(0),
    ]
    for invalid in malformed {
      let decoder = ProviderFrameDecoder()
      XCTAssertEqual(try decoder.feed(Data(frame.prefix(2))), [])
      rejects { try decoder.feed(Data(frame.dropFirst(2)) + invalid + frame) }
      rejects { try decoder.feed(Data()) }
      rejects { try decoder.feed(frame) }
      rejects { try decoder.finish() }
    }
  }

  func testEOFRejectsEveryTruncatedPrefixAndBody() throws {
    let frame = try ProviderRPC.encode(request())
    try ProviderFrameDecoder().finish()
    var decoder = ProviderFrameDecoder()
    XCTAssertEqual(try decoder.feed(frame), [frame])
    try decoder.finish()
    for length in 1..<frame.count {
      decoder = ProviderFrameDecoder()
      XCTAssertEqual(try decoder.feed(Data(frame.prefix(length))), [])
      rejects { try decoder.finish() }
      rejects { try decoder.feed(frame) }
    }
    decoder = ProviderFrameDecoder()
    XCTAssertEqual(try decoder.feed(frame + frame.prefix(2)), [frame])
    rejects { try decoder.finish() }
  }
}
