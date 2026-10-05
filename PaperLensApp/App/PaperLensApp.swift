import Darwin
import Foundation
import SwiftUI

@main
struct PaperLensApp: App {
  @StateObject private var model = TopologyModel()

  var body: some Scene {
    WindowGroup("PaperLens — Topology Prototype") {
      VStack(alignment: .leading, spacing: 16) {
        Text("Signed topology smoke").font(.title)
        Text("격리 프로토타입 전용 · 인증, 논문 열기, 추출 기능 없음")
        Text("Runtime: \(model.runtime)")
        Text("Fixture profile: \(model.fixtures)")
        Text(model.status).textSelection(.enabled)
        Button("Run topology smoke") { model.run() }.disabled(model.running)
        Text("거부 errno만으로 sandbox PASS를 판정하지 않습니다. 두 CPU / P-1 검증 결과가 아닙니다.")
          .font(.caption)
      }
      .padding(24)
      .frame(minWidth: 540, minHeight: 250)
      .task { model.automate() }
    }
  }
}

@MainActor
private final class TopologyModel: ObservableObject {
  @Published var runtime = "not run"
  @Published var fixtures = "not run"
  @Published var status = "컨테이너 내부에 안전한 report.json만 기록합니다."
  @Published var running = false
  private var coordinator: TopologyCoordinator?
  private var automated = false

  func automate() {
    guard !automated, CommandLine.arguments.contains("--topology-smoke") else { return }
    automated = true
    run()
  }

  func run() {
    guard !running else { return }
    running = true
    runtime = "running"
    fixtures = "pending"
    let arguments = CommandLine.arguments
    var id = UUID().uuidString.lowercased()
    if let index = arguments.firstIndex(of: "--run-id") {
      guard arguments.indices.contains(index + 1), TopologyFixtures.validRunID(arguments[index + 1])
      else {
        running = false
        status = "invalid run ID"
        runtime = "failed"
        return
      }
      id = arguments[index + 1]
    }
    let coordinator = TopologyCoordinator(runID: id) { [weak self] runtime, fixtures, saved in
      Task { @MainActor in
        self?.runtime = runtime
        self?.fixtures = fixtures
        self?.status =
          saved ? "안전한 로컬 report.json 기록 완료 · 외부 통제/OS denial 증거 별도 필요" : "안전한 report 기록 실패"
        self?.running = false
        self?.coordinator = nil
      }
    }
    self.coordinator = coordinator
    coordinator.start()
  }
}

private final class TopologyCoordinator: NSObject, ProviderFrameReceiver, @unchecked Sendable {
  private struct Request {
    let method: String
    let completion: ([String: Any]?) -> Void
  }
  private let queue = DispatchQueue(label: "PaperLens.Main.topology")
  private let admission = NSLock()
  private var incomingFrames = 0
  private var incomingBytes = 0
  private var acceptingIncoming = true
  private var outgoingFrames = 0
  private var outgoingBytes = 0
  private var maxQueuedFrames = 0
  private var maxQueuedBytes = 0
  private var maxOutstandingRequests = 0
  private var maxOrdinaryRequests = 0
  private var maxCancelRequests = 0
  private var maxRequestsPerConnection = 0
  private var handshakeTimeoutMs = 0
  private var maxTimeoutMs = 0
  private var connection: NSXPCConnection?
  private var worker: NSXPCConnection?
  private var requests: [String: Request] = [:]
  private var usedIDs = Set<String>()
  private var completedIDs = Set<String>()
  private var completedMethods: [String: String] = [:]
  private var localTerminals = Set<String>()
  private var disconnected = false
  private var finished = false
  private var handshaken = false
  private var requestCount = 0
  private let runID: String
  private var runtimeStatus = "failed"
  private var providerRuntimeStatus = "failed"
  private var pdfiumRuntimeStatus = "blocked"
  private var fixtureStatus = "blocked"
  private var runtimeResult: [String: Any] = [:]
  private var cases: [[String: Any]] = []
  private var terminals: [[String: String]] = []
  private var own: TopologyOwnedFixtures?
  private var ownerPre = false
  private var agentOwnerPre: String?
  private var agentOwnerPost: String?
  private var pdfPending = false
  private var pdfContinuation: (() -> Void)?
  private var pdfHandle: FileHandle?
  private let completion: @Sendable (String, String, Bool) -> Void

  init(runID: String, completion: @escaping @Sendable (String, String, Bool) -> Void) {
    self.runID = runID
    self.completion = completion
  }

  func start() { queue.async { self.connect() } }

  private func connect() {
    guard TopologyIdentity.container(TopologyIdentity.main) != nil,
      let contract = Bundle.main.url(forResource: "contract", withExtension: "json")
    else {
      finish()
      return
    }
    do {
      try ProviderRPC.configure(contractURL: contract)
      maxOutstandingRequests = try ProviderRPC.limit("maxOutstandingRequests")
      maxOrdinaryRequests = try ProviderRPC.limit("maxOrdinaryRequests")
      maxCancelRequests = try ProviderRPC.limit("maxCancelRequests")
      maxRequestsPerConnection = try ProviderRPC.limit("maxRequestsPerConnection")
      handshakeTimeoutMs = try ProviderRPC.limit("handshakeTimeoutMs")
      maxTimeoutMs = try ProviderRPC.limit("maxTimeoutMs")
      let frames = try ProviderRPC.limit("maxQueuedFrames")
      let bytes = try ProviderRPC.limit("maxQueuedBytes")
      admission.lock()
      maxQueuedFrames = frames
      maxQueuedBytes = bytes
      admission.unlock()
    } catch {
      finish()
      return
    }
    let connection = NSXPCConnection(serviceName: TopologyIdentity.agent)
    connection.setCodeSigningRequirement(TopologyIdentity.requirement(TopologyIdentity.agent))
    connection.remoteObjectInterface = NSXPCInterface(with: ProviderFrameTransport.self)
    connection.exportedInterface = NSXPCInterface(with: ProviderFrameReceiver.self)
    connection.exportedObject = self
    connection.interruptionHandler = { [weak self] in self?.invalidate() }
    connection.invalidationHandler = { [weak self] in self?.invalidate() }
    self.connection = connection
    connection.resume()
    request(
      "hello", params: ["major": 1, "minor": 0, "capabilities": ["topology-v1"]],
      timeout: handshakeTimeoutMs
    ) { value in
      guard value != nil else {
        self.finish()
        return
      }
      self.handshaken = true
      self.request("topology.runtime", params: [:]) { value in
        guard let value else {
          self.finish()
          return
        }
        self.runtimeResult = value
        self.providerRuntimeStatus =
          (value["sdkImported"] as? Bool == true && value["cliInitialized"] as? Bool == true)
          ? "pass" : "failed"
        guard self.providerRuntimeStatus == "pass" else {
          self.finish()
          return
        }
        self.prepare()
      }
    }
  }

  @discardableResult
  private func request(
    _ method: String, params: [String: Any], timeout requestedTimeout: Int? = nil,
    completion: @escaping ([String: Any]?) -> Void
  ) -> String? {
    let timeout = requestedTimeout ?? maxTimeoutMs
    let ordinary = requests.values.filter { $0.method != "cancel" }.count
    let cancellations = requests.count - ordinary
    guard !finished, !disconnected, requestCount < maxRequestsPerConnection,
      method == "hello" || handshaken,
      requests.count < maxOutstandingRequests,
      method == "cancel" ? cancellations < maxCancelRequests : ordinary < maxOrdinaryRequests
    else {
      completion(nil)
      return nil
    }
    let id = UUID().uuidString.lowercased()
    guard usedIDs.insert(id).inserted else {
      invalidate()
      completion(nil)
      return nil
    }
    do {
      let value: [String: Any] = [
        "kind": "request", "id": id, "method": method,
        "timeoutMs": timeout, "params": params,
      ]
      try ProviderRPC.validateRequest(value)
      let frame = try ProviderRPC.encode(value)
      guard outgoingFrames < maxQueuedFrames, outgoingBytes + frame.count <= maxQueuedBytes else {
        completion(nil)
        failConnection()
        return nil
      }
      requests[id] = Request(method: method, completion: completion)
      requestCount += 1
      guard let connection,
        let proxy = connection.remoteObjectProxyWithErrorHandler({ [weak self] _ in
          self?.invalidate()
        }) as? ProviderFrameTransport
      else {
        failConnection()
        return nil
      }
      outgoingFrames += 1
      outgoingBytes += frame.count
      proxy.sendFrame(frame)
      let size = frame.count
      connection.scheduleSendBarrierBlock { [weak self] in
        guard let self else { return }
        self.queue.async {
          self.outgoingFrames -= 1
          self.outgoingBytes -= size
        }
      }
      queue.asyncAfter(deadline: .now() + .milliseconds(timeout)) { [weak self] in
        guard let self, let pending = self.requests.removeValue(forKey: id) else { return }
        self.completedIDs.insert(id)
        self.completedMethods[id] = pending.method
        self.localTerminals.insert(id)
        self.terminals.append([
          "id": id, "method": pending.method, "origin": "local", "code": "timeout",
        ])
        // The cancelled target already crossed its local fence. Its late
        // terminal is discarded, never delivered to the caller a second time.
        if self.handshaken && pending.method != "cancel" {
          self.request("cancel", params: ["targetID": id], timeout: 1000) { _ in }
        }
        pending.completion(nil)
      }
      return id
    } catch {
      completion(nil)
      failConnection()
      return nil
    }
  }

  func receiveFrame(_ frame: Data) {
    admission.lock()
    let wasAccepting = acceptingIncoming
    let allowed =
      acceptingIncoming && frame.count <= ProviderRPC.maxFrameBytes
      && incomingFrames < maxQueuedFrames && incomingBytes + frame.count <= maxQueuedBytes
    if allowed {
      incomingFrames += 1
      incomingBytes += frame.count
    } else {
      acceptingIncoming = false
    }
    admission.unlock()
    guard allowed else {
      if wasAccepting { invalidate() }
      return
    }
    queue.async {
      defer {
        self.admission.lock()
        self.incomingFrames -= 1
        self.incomingBytes -= frame.count
        self.admission.unlock()
      }
      guard !self.finished, !self.disconnected else { return }
      do {
        let envelope = try ProviderRPC.decode(frame)
        guard let id = envelope["id"] as? String else {
          self.failConnection()
          return
        }
        if self.localTerminals.contains(id), let method = self.completedMethods[id] {
          try ProviderRPC.validateTerminal(envelope, method: method)
          return
        }
        guard let pending = self.requests[id], !self.completedIDs.contains(id) else {
          self.failConnection()
          return
        }
        try ProviderRPC.validateTerminal(envelope, method: pending.method)
        self.requests.removeValue(forKey: id)
        self.completedIDs.insert(id)
        self.completedMethods[id] = pending.method
        self.terminals.append([
          "id": id, "method": pending.method, "origin": "peer",
          "code": envelope["code"] as? String ?? "result",
        ])
        pending.completion(envelope["result"] as? [String: Any])
      } catch { self.failConnection() }
    }
  }

  private func invalidate() { queue.async { self.failConnection() } }

  private func failConnection() {
    guard !disconnected else { return }
    disconnected = true
    admission.lock()
    acceptingIncoming = false
    admission.unlock()
    let pending = requests
    requests.removeAll()
    connection?.invalidate()
    connection = nil
    for (id, value) in pending {
      completedIDs.insert(id)
      localTerminals.insert(id)
      completedMethods[id] = value.method
      terminals.append(["id": id, "method": value.method, "origin": "local", "code": "unavailable"])
    }
    for value in pending.values { value.completion(nil) }
    // A new run makes a new connection/hello; no operation is replayed.
  }

  private func prepare() {
    guard TopologyFixtures.profileMatches(TopologyIdentity.main) else {
      finish()
      return
    }
    let root = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(
      "Library/Application Support/PaperLensTopology")
    guard let own = TopologyOwnedFixtures(root: root, runID: runID) else {
      finish()
      return
    }
    self.own = own
    guard own.create("M"), own.create("PDF"), own.check() else {
      fixtureStatus = "failed"
      finish()
      return
    }
    ownerPre = true
    cases.append(TopologyFixtures.network(runID: runID, actor: "Main.pre", expectAllowed: true))
    request("topology.prepare", params: ["runID": runID]) { value in
      guard value?["prepared"] as? Bool == true else {
        self.finish()
        return
      }
      self.fixtureStatus = "inconclusive"
      self.agentProbe("ownZoneReadWrite") {
        for alias in ["A", "C"] {
          for operation in ["read", "write", "symlinkRead"] {
            self.cases.append(
              TopologyFixtures.probe(
                runID: self.runID, actor: "Main", alias: alias,
                operation: operation, symlinkDirectory: own.descriptor))
          }
        }
        self.inspectPDF { self.probeAgent(index: 0) }
      }
    }
  }

  private static let agentCases = [
    "mainCanaryRead", "mainCanaryWrite", "mainCanarySymlinkRead",
    "externalCanaryRead", "externalCanaryWrite", "externalCanarySymlinkRead",
    "foreignGroupCanaryRead", "foreignGroupCanaryWrite", "foreignGroupCanarySymlinkRead",
    "inboundListen",
  ]

  private func probeAgent(index: Int) {
    guard index < Self.agentCases.count else {
      agentProbe("ownZoneReadWrite") {
        self.request("topology.cleanup", params: ["runID": self.runID]) { value in
          if value?["absent"] as? Bool != true { self.fixtureStatus = "failed" }
          self.cases.append(
            TopologyFixtures.network(runID: self.runID, actor: "Main.post", expectAllowed: true))
          self.finish()
        }
      }
      return
    }
    agentProbe(Self.agentCases[index]) { self.probeAgent(index: index + 1) }
  }

  private func agentProbe(_ caseID: String, completion: @escaping () -> Void) {
    request("topology.probe", params: ["runID": runID, "caseID": caseID]) { value in
      let ownZone = caseID == "ownZoneReadWrite"
      let alias =
        ownZone
        ? "A/C"
        : caseID.hasPrefix("main")
          ? "M" : caseID.hasPrefix("external") ? "E" : caseID.hasPrefix("foreign") ? "G" : "network"
      let operation =
        ownZone
        ? "readWrite"
        : caseID.hasSuffix("SymlinkRead")
          ? "symlinkRead"
          : caseID.hasSuffix("Write") ? "write" : caseID == "inboundListen" ? "listen" : "read"
      var row = TopologyFixtures.observation(
        runID: self.runID, actor: "Agent", alias: alias, operation: operation,
        result: -1, matched: value != nil)
      row["caseID"] = caseID
      // ProviderRPC deliberately has no errno field; never invent one.
      row["errno"] = NSNull()
      row["syscallResult"] = NSNull()
      row["outcome"] = value?["outcome"] ?? "inconclusive"
      row["reason"] = value?["reason"] ?? "controlFailed"
      if value?["reason"] as? String == "missingFixture" {
        row["verdict"] = "blocked"
      } else if value?["outcome"] as? String == "allowed" {
        row["verdict"] = ownZone ? "pass" : "failed"
      } else if ownZone {
        row["verdict"] = "inconclusive"
      }
      if ownZone {
        let state = row["verdict"] as? String ?? "inconclusive"
        if self.agentOwnerPre == nil {
          self.agentOwnerPre = state
          row["caseID"] = "ownZoneReadWrite.pre"
        } else {
          self.agentOwnerPost = state
          row["caseID"] = "ownZoneReadWrite.post"
        }
      }
      self.cases.append(row)
      completion()
    }
  }

  private func inspectPDF(completion: @escaping () -> Void) {
    guard let pdf = own?.readOnlyPDF() else {
      fixtureStatus = "failed"
      completion()
      return
    }
    pdfHandle = pdf
    pdfContinuation = completion
    pdfPending = true
    let worker = NSXPCConnection(serviceName: TopologyIdentity.worker)
    worker.setCodeSigningRequirement(TopologyIdentity.requirement(TopologyIdentity.worker))
    worker.remoteObjectInterface = NSXPCInterface(with: PDFTopologyService.self)
    worker.interruptionHandler = { [weak self] in self?.workerFailed() }
    worker.invalidationHandler = { [weak self] in self?.workerFailed() }
    self.worker = worker
    worker.resume()
    guard
      let proxy = worker.remoteObjectProxyWithErrorHandler({ [weak self] _ in self?.workerFailed() }
      ) as? PDFTopologyService
    else {
      completePDF(nil)
      return
    }
    proxy.inspect(runID, pdf: pdf) { [weak self] bytes in
      guard let self else { return }
      self.queue.async { self.completePDF(bytes) }
    }
    queue.asyncAfter(deadline: .now() + .seconds(10)) { [weak self] in self?.completePDF(nil) }
  }

  private func workerFailed() { queue.async { self.completePDF(nil) } }

  private func completePDF(_ bytes: Data?) {
    guard pdfPending else { return }
    pdfPending = false
    defer {
      worker?.invalidate()
      worker = nil
      try? pdfHandle?.close()
      pdfHandle = nil
      let continuation = pdfContinuation
      pdfContinuation = nil
      continuation?()
    }
    guard let bytes, bytes.count <= 32768,
      let report = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
      Set(report.keys) == Set(["status", "pdfiumInitialized", "expectedRootMatched", "cases"]),
      report["pdfiumInitialized"] as? Bool == true,
      let matched = report["expectedRootMatched"] as? Bool,
      let rows = report["cases"] as? [[String: Any]], rows.count <= 19
    else {
      pdfiumRuntimeStatus = "failed"
      fixtureStatus = "failed"
      return
    }
    pdfiumRuntimeStatus = "pass"
    guard matched, rows.count == 19 else {
      fixtureStatus = "blocked"
      return
    }
    var safe: [[String: Any]] = []
    for row in rows {
      guard row["runID"] as? String == runID, row["actorInstanceRef"] as? String == "PDFiumXPC",
        let alias = row["fixtureID"] as? String,
        ["M", "A", "C", "E", "G", "PDF", "network"].contains(alias),
        let operation = row["operation"] as? String,
        ["read", "write", "symlinkRead", "descriptorRead", "descriptorWrite", "connect"].contains(
          operation),
        let result = row["syscallResult"] as? Int, (-1...4096).contains(result),
        let code = row["errno"] as? Int, (0...4096).contains(code),
        let root = row["expectedRootMatched"] as? Bool,
        let verdict = row["verdict"] as? String,
        ["pass", "failed", "blocked", "inconclusive"].contains(verdict)
      else {
        fixtureStatus = "failed"
        return
      }
      var item = TopologyFixtures.observation(
        runID: runID, actor: "PDFiumXPC", alias: alias,
        operation: operation, result: result, error: Int32(code), matched: root)
      if alias == "PDF" && ["descriptorRead", "descriptorWrite"].contains(operation) {
        item["verdict"] = verdict
      }
      safe.append(item)
    }
    guard Set(safe.compactMap { $0["caseID"] as? String }).count == 19 else {
      fixtureStatus = "failed"
      return
    }
    cases.append(contentsOf: safe)
  }

  private func finish() {
    guard !finished else { return }
    finished = true
    failConnection()
    let ownerPost = own?.check() ?? false
    if let own {
      if !ownerPost { fixtureStatus = "failed" }
      for index in cases.indices
      where cases[index]["fixtureID"] as? String == "M"
        || cases[index]["fixtureID"] as? String == "PDF"
      {
        cases[index]["ownerPre"] = ownerPre ? "pass" : "failed"
        cases[index]["ownerPost"] = ownerPost ? "pass" : "failed"
      }
      if !own.cleanup() { fixtureStatus = "failed" }
    }
    own = nil
    for index in cases.indices
    where ["A", "C", "A/C"].contains(cases[index]["fixtureID"] as? String ?? "") {
      cases[index]["ownerPre"] = agentOwnerPre ?? "unverified"
      cases[index]["ownerPost"] = agentOwnerPost ?? "unverified"
    }
    if cases.contains(where: { $0["verdict"] as? String == "failed" }) { fixtureStatus = "failed" }
    runtimeStatus =
      providerRuntimeStatus == "failed" || pdfiumRuntimeStatus == "failed"
      ? "failed" : pdfiumRuntimeStatus == "pass" ? "pass" : "blocked"
    let report: [String: Any] = [
      "schemaRevision": "topology-v1", "runID": runID,
      "runtimeStatus": runtimeStatus, "runtime": runtimeResult,
      "providerRuntimeStatus": providerRuntimeStatus,
      "pdfiumRuntimeStatus": pdfiumRuntimeStatus,
      "fixtureStatus": fixtureStatus, "cases": cases, "terminals": terminals,
      "isolationVerdict": fixtureStatus == "failed" ? "failed" : "inconclusive",
      "p1": "unverified", "actualTwoCPU": false,
    ]
    let saved = save(TopologyFixtures.json(report))
    worker?.invalidate()
    worker = nil
    completion(runtimeStatus, fixtureStatus, saved)
  }

  private func save(_ report: Data) -> Bool {
    guard let root = TopologyIdentity.container(TopologyIdentity.main),
      let directory = TopologyFixtures.directory(
        root.appendingPathComponent("Library/Application Support/PaperLensTopology"), create: true)
    else { return false }
    defer { close(directory) }
    let temporary = UUID().uuidString.lowercased() + ".report"
    let fd = openat(
      directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { return false }
    defer {
      close(fd)
      unlinkat(directory, temporary, 0)
    }
    let count = report.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, report.count) }
    guard count == report.count, fsync(fd) == 0 else { return false }
    // Atomic replacement of this app's fixed report, never an argv-selected path.
    return renameat(directory, temporary, directory, "report.json") == 0
  }
}
