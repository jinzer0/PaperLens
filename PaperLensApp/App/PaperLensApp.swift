import AppKit
import CoreFoundation
import Darwin
import Foundation
import OSLog
import SwiftUI

private let topologyLog = Logger(
  subsystem: "io.github.jinzer0.PaperLens.TopologySmoke", category: "lifecycle")

@main
struct PaperLensApp: App {
  @NSApplicationDelegateAdaptor(TopologyApplicationDelegate.self) private var delegate

  var body: some Scene {
    WindowGroup(CommandLine.arguments.contains("--topology-smoke")
      ? "PaperLens — Topology Prototype" : "PaperLens") {
      if SyntheticWorkspaceSmoke.launch(CommandLine.arguments) != .absent {
        SyntheticWorkspaceSmokeView()
      } else if SyntheticPDFGeometryCalibration.launch(CommandLine.arguments) != .absent {
        Text("합성 PDF geometry 진단 전용 · 결과는 별도 run 디렉터리에 기록합니다.")
          .padding()
      } else if CommandLine.arguments.contains("--topology-smoke") {
        TopologyView(model: delegate.model)
      } else {
        ProductRootView()
      }
    }
  }
}

@MainActor
private final class TopologyApplicationDelegate: NSObject, NSApplicationDelegate {
  let model = TopologyModel()

  func applicationDidFinishLaunching(_ notification: Notification) {
    if SyntheticWorkspaceSmoke.launch(CommandLine.arguments) != .absent { return }
    if SyntheticPDFGeometryCalibration.launch(CommandLine.arguments) != .absent {
      Task { await SyntheticPDFGeometryCalibration.run(arguments: CommandLine.arguments) }
      return
    }
    topologyLog.notice("application_finished_launching")
    model.automate()
  }
}

private struct TopologyView: View {
  @ObservedObject var model: TopologyModel

  var body: some View {
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
    topologyLog.notice("smoke_automation_invoked")
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
    let deadline: UInt64
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
  private var reservation: TopologyReportReservation?
  private var actorCandidates: [[String: Any]] = []
  private let actorRefs = Dictionary(
    uniqueKeysWithValues: ["Main", "ProviderAgent", "Python", "PDFiumXPC"].map {
      ($0, "actor-" + UUID().uuidString.lowercased())
    })
  private var phasePending = false
  private var phaseContinuation: (() -> Void)?
  private var workerIdentityPending = false
  private var workerIdentityDeadline: UInt64 = 0
  private var workerIdentityContinuation: (() -> Void)?
  private var ownerPre = false
  private var agentOwnerPre: String?
  private var agentOwnerPost: String?
  private var pdfPending = false
  private var pdfDeadline: UInt64 = 0
  private var pdfContinuation: (() -> Void)?
  private var pdfHandle: FileHandle?
  private let completion: @Sendable (String, String, Bool) -> Void

  init(runID: String, completion: @escaping @Sendable (String, String, Bool) -> Void) {
    self.runID = runID
    self.completion = completion
  }

  func start() { queue.async { self.connect() } }

  private func connect() {
    topologyLog.notice(
      "smoke_connect account_valid=\(TopologyIdentity.accountHome() != nil, privacy: .public) container_valid=\(TopologyIdentity.container(TopologyIdentity.main) != nil, privacy: .public) map_valid=\(TopologyFixtures.groupMapMatches(), privacy: .public)"
    )
    guard let root = TopologyIdentity.container(TopologyIdentity.main),
      let reservation = TopologyReportReservation(container: root, runID: runID)
    else {
      // No service is resumed and no ordinary finish/save path is entered
      // when exclusive reservation fails. Existing evidence stays untouched.
      finished = true
      completion("blocked", "blocked", false)
      return
    }
    self.reservation = reservation
    guard
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
      "hello", params: ["major": 1, "minor": 1, "capabilities": ["topology-v1"]],
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
      let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeout) * 1_000_000
      requests[id] = Request(method: method, deadline: deadline, completion: completion)
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
      queue.asyncAfter(deadline: DispatchTime(uptimeNanoseconds: deadline)) { [weak self] in
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
    let receivedAt = DispatchTime.now().uptimeNanoseconds
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
        if receivedAt >= pending.deadline {
          self.requests.removeValue(forKey: id)
          self.completedIDs.insert(id)
          self.completedMethods[id] = pending.method
          self.localTerminals.insert(id)
          self.terminals.append([
            "id": id, "method": pending.method, "origin": "local", "code": "timeout",
          ])
          if self.handshaken && pending.method != "cancel" {
            self.request("cancel", params: ["targetID": id], timeout: 1000) { _ in }
          }
          pending.completion(nil)
          return
        }
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
    guard own.create("M"), own.create("PDF"), own.prepareLinks(["A", "C"]), own.check() else {
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
      self.request("topology.identity", params: ["runID": self.runID]) { identity in
        guard let identity,
          let bridge = Self.integer(identity["bridgePID"]), bridge > 0,
          let python = Self.integer(identity["pythonPID"]), python > 0,
          self.connection?.processIdentifier == Int32(bridge),
          self.connection?.effectiveUserIdentifier == getuid()
        else {
          self.abortReadiness()
          return
        }
        self.actorCandidates = [
          ["role": "Main", "pid": Int(getpid())],
          ["role": "ProviderAgent", "pid": Int(bridge)],
          ["role": "Python", "pid": Int(python)],
        ]
        self.identifyPDF {
          guard self.actorCandidates.count == 4 else {
            self.abortReadiness()
            return
          }
          self.fence("pre") {
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
        self.cases.append(
          TopologyFixtures.network(runID: self.runID, actor: "Main.post", expectAllowed: true))
        self.fence("post") {
          self.request("topology.cleanup", params: ["runID": self.runID]) { value in
            if value?["absent"] as? Bool != true { self.fixtureStatus = "failed" }
            self.finish()
          }
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
        result: Int(Self.integer(value?["syscallResult"]) ?? 0),
        error: Int32(Self.integer(value?["errno"]) ?? 0), matched: value != nil,
        observed: value?["syscallObserved"] as? Bool == true,
        beganAtNs: Self.integer(value?["beganAtNs"]) ?? 0,
        endedAtNs: Self.integer(value?["endedAtNs"]) ?? 0)
      row["caseID"] = caseID
      row["intervalRef"] = caseID
      row["outcome"] = value?["outcome"] ?? "inconclusive"
      row["reason"] = value?["reason"] ?? "controlFailed"
      if value?["reason"] as? String == "missingFixture" {
        row["verdict"] = "blocked"
      } else if value?["outcome"] as? String == "allowed",
        ownZone || value?["syscallObserved"] as? Bool == true
      {
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
        row["intervalRef"] = row["caseID"]
      }
      self.cases.append(row)
      completion()
    }
  }

  private static func integer(_ value: Any?) -> Int64? {
    guard let number = value as? NSNumber,
      CFGetTypeID(number) != CFBooleanGetTypeID(),
      ["c", "s", "i", "l", "q", "C", "S", "I", "L", "Q"].contains(
        String(cString: number.objCType)),
      number.compare(NSNumber(value: Int64.max)) != .orderedDescending,
      number.compare(NSNumber(value: Int64.min)) != .orderedAscending
    else { return nil }
    return number.int64Value
  }

  private static func boolean(_ value: Any?) -> Bool? {
    guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID()
    else { return nil }
    return number.boolValue
  }

  private func peersMatch() -> Bool {
    guard actorCandidates.count == 4,
      let agent = actorCandidates.first(where: { $0["role"] as? String == "ProviderAgent" }),
      let pdf = actorCandidates.first(where: { $0["role"] as? String == "PDFiumXPC" }),
      let bridgePID = Self.integer(agent["pid"]), let workerPID = Self.integer(pdf["pid"])
    else { return false }
    return connection?.processIdentifier == Int32(bridgePID)
      && connection?.effectiveUserIdentifier == getuid()
      && worker?.processIdentifier == Int32(workerPID)
      && worker?.effectiveUserIdentifier == getuid()
  }

  private func fence(_ phase: String, completion: @escaping () -> Void) {
    guard !finished, !phasePending, requests.isEmpty,
      let reservation, let own, own.check(), own.checkLinks(), peersMatch()
    else {
      abortReadiness()
      return
    }
    phasePending = true
    phaseContinuation = completion
    let intervals: [[String: Any]] =
      phase == "post"
      ? cases.compactMap { row in
        guard row["syscallObserved"] as? Bool == true,
          let caseID = row["caseID"] as? String,
          let began = Self.integer(row["beganAtNs"]), let ended = Self.integer(row["endedAtNs"]),
          began > 0, ended >= began
        else { return nil }
        return ["caseID": caseID, "beganAtNs": began, "endedAtNs": ended]
      } : []
    TopologyReadiness.fence(
      directory: reservation.descriptor, runID: runID, phase: phase,
      actors: actorCandidates, links: own.links, intervals: intervals,
      ownerControl: own.check() && own.checkLinks(), timeoutMs: 10000
    ) { [weak self] accepted in
      guard let self else { return }
      self.queue.async {
        guard !self.finished, self.phasePending else { return }
        self.phasePending = false
        let continuation = self.phaseContinuation
        self.phaseContinuation = nil
        guard accepted, self.peersMatch() else {
          self.abortReadiness()
          return
        }
        continuation?()
      }
    }
  }

  private func abortReadiness() {
    guard !finished else { return }
    fixtureStatus = "blocked"
    phasePending = false
    phaseContinuation = nil
    request("topology.cleanup", params: ["runID": runID]) { _ in self.finish() }
  }

  private func identifyPDF(completion: @escaping () -> Void) {
    workerIdentityPending = true
    workerIdentityDeadline = DispatchTime.now().uptimeNanoseconds + 10_000_000_000
    workerIdentityContinuation = completion
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
      completeWorkerIdentity(nil)
      return
    }
    proxy.identify(runID) { [weak self] bytes in
      guard let self else { return }
      let receivedAt = DispatchTime.now().uptimeNanoseconds
      self.queue.async { self.completeWorkerIdentity(bytes, receivedAt: receivedAt) }
    }
    queue.asyncAfter(deadline: DispatchTime(uptimeNanoseconds: workerIdentityDeadline)) {
      [weak self] in
      self?.completeWorkerIdentity(nil)
    }
  }

  private func completeWorkerIdentity(_ bytes: Data?, receivedAt: UInt64? = nil) {
    guard workerIdentityPending, !finished else { return }
    workerIdentityPending = false
    let continuation = workerIdentityContinuation
    workerIdentityContinuation = nil
    if let receivedAt, receivedAt < workerIdentityDeadline,
      let bytes, bytes.count <= 65536,
      let value = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
      Set(value.keys) == Set(["runID", "pid"]), value["runID"] as? String == runID,
      let pid = Self.integer(value["pid"]), (1...Int64(Int32.max)).contains(pid),
      worker?.processIdentifier == Int32(pid), worker?.effectiveUserIdentifier == getuid()
    {
      actorCandidates.append(["role": "PDFiumXPC", "pid": Int(pid)])
    } else {
      pdfiumRuntimeStatus = "blocked"
    }
    continuation?()
  }

  private func inspectPDF(completion: @escaping () -> Void) {
    guard peersMatch(), let worker, let pdf = own?.readOnlyPDF() else {
      fixtureStatus = "blocked"
      completion()
      return
    }
    pdfHandle = pdf
    pdfContinuation = completion
    pdfPending = true
    pdfDeadline = DispatchTime.now().uptimeNanoseconds + 10_000_000_000
    guard
      let proxy = worker.remoteObjectProxyWithErrorHandler({ [weak self] _ in
        self?.workerFailed()
      }) as? PDFTopologyService
    else {
      completePDF(nil)
      return
    }
    proxy.inspect(runID, pdf: pdf) { [weak self] bytes in
      guard let self else { return }
      let receivedAt = DispatchTime.now().uptimeNanoseconds
      self.queue.async { self.completePDF(bytes, receivedAt: receivedAt) }
    }
    queue.asyncAfter(deadline: DispatchTime(uptimeNanoseconds: pdfDeadline)) { [weak self] in
      self?.completePDF(nil)
    }
  }

  private func workerFailed() {
    queue.async {
      guard !self.finished else { return }
      if self.workerIdentityPending {
        self.completeWorkerIdentity(nil)
      } else if self.pdfPending {
        self.completePDF(nil)
      } else if self.phasePending {
        self.abortReadiness()
      }
    }
  }

  private func completePDF(_ bytes: Data?, receivedAt: UInt64? = nil) {
    guard pdfPending else { return }
    pdfPending = false
    defer {
      try? pdfHandle?.close()
      pdfHandle = nil
      let continuation = pdfContinuation
      pdfContinuation = nil
      continuation?()
    }
    guard let receivedAt, receivedAt < pdfDeadline,
      let bytes, bytes.count <= 32768,
      let report = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
      Set(report.keys) == Set(["status", "pdfiumInitialized", "expectedRootMatched", "cases"]),
      let workerStatus = report["status"] as? String,
      ["inconclusive", "blocked", "failed"].contains(workerStatus),
      let initialized = Self.boolean(report["pdfiumInitialized"]),
      let matched = Self.boolean(report["expectedRootMatched"]),
      let rows = report["cases"] as? [[String: Any]], rows.count <= 19
    else {
      pdfiumRuntimeStatus = "failed"
      fixtureStatus = "failed"
      return
    }
    guard initialized else {
      pdfiumRuntimeStatus = report["status"] as? String == "blocked" ? "blocked" : "failed"
      fixtureStatus = pdfiumRuntimeStatus
      return
    }
    pdfiumRuntimeStatus = "pass"
    if workerStatus == "failed" || workerStatus == "blocked" { fixtureStatus = workerStatus }
    guard matched else {
      fixtureStatus = "blocked"
      return
    }
    if rows.count < 19 && fixtureStatus != "failed" { fixtureStatus = "blocked" }
    var safe: [[String: Any]] = []
    for row in rows {
      guard row["runID"] as? String == runID, row["actorInstanceRef"] as? String == "PDFiumXPC",
        let alias = row["fixtureID"] as? String,
        ["M", "A", "C", "E", "G", "PDF", "network"].contains(alias),
        let operation = row["operation"] as? String,
        ["read", "write", "symlinkRead", "descriptorRead", "descriptorWrite", "connect"].contains(
          operation),
        let result = Self.integer(row["syscallResult"]), (-1...4096).contains(result),
        let code = Self.integer(row["errno"]), (0...Int64(Int32.max)).contains(code),
        let observed = Self.boolean(row["syscallObserved"]),
        let began = Self.integer(row["beganAtNs"]), let ended = Self.integer(row["endedAtNs"]),
        observed
          ? (began > 0 && ended >= began) : (began == 0 && ended == 0 && result == 0 && code == 0),
        let root = Self.boolean(row["expectedRootMatched"]),
        let verdict = row["verdict"] as? String,
        ["pass", "failed", "blocked", "inconclusive"].contains(verdict)
      else {
        fixtureStatus = "failed"
        return
      }
      var item = TopologyFixtures.observation(
        runID: runID, actor: "PDFiumXPC", alias: alias,
        operation: operation, result: Int(result), error: Int32(code), matched: root,
        observed: observed, beganAtNs: began, endedAtNs: ended)
      if alias == "PDF" && ["descriptorRead", "descriptorWrite"].contains(operation) {
        item["verdict"] = verdict
      } else if observed && verdict == "failed" {
        // Async connect completion can establish forbidden success even
        // while the recorded immediate syscall tuple is EINPROGRESS.
        item["verdict"] = "failed"
      }
      safe.append(item)
    }
    guard Set(safe.compactMap { $0["caseID"] as? String }).count == rows.count else {
      fixtureStatus = "failed"
      return
    }
    cases.append(contentsOf: safe)
  }

  private func finish() {
    guard !finished else { return }
    finished = true
    phasePending = false
    phaseContinuation = nil
    workerIdentityPending = false
    workerIdentityContinuation = nil
    failConnection()
    let ownerPost = (own?.check() ?? false) && (own?.checkLinks() ?? false)
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
    let bindings: [[String: Any]] = ["Main", "ProviderAgent", "Python", "PDFiumXPC"].map {
      ["role": $0, "actorInstanceRef": actorRefs[$0]!, "identityVerified": false]
    }
    let safeCases: [[String: Any]] = cases.map { original in
      var row = original
      let candidate = row["actorInstanceRef"] as? String ?? ""
      let role = candidate == "Agent" ? "Python" : candidate.hasPrefix("Main") ? "Main" : candidate
      row["actorInstanceRef"] = actorRefs[role] ?? "unbound"
      row.removeValue(forKey: "beganAtNs")
      row.removeValue(forKey: "endedAtNs")
      return row
    }
    let report: [String: Any] = [
      "schemaRevision": "topology-evidence-v2", "runID": runID,
      "runtimeStatus": runtimeStatus, "runtime": runtimeResult,
      "providerRuntimeStatus": providerRuntimeStatus,
      "pdfiumRuntimeStatus": pdfiumRuntimeStatus,
      "fixtureStatus": fixtureStatus, "cases": safeCases, "terminals": terminals,
      "actorBindings": bindings,
      "isolationVerdict": fixtureStatus == "failed" ? "failed" : "inconclusive",
      "p1": "unverified", "actualTwoCPU": false,
    ]
    let saved = save(TopologyFixtures.json(report))
    topologyLog.notice(
      "smoke_finish provider=\(self.providerRuntimeStatus, privacy: .public) pdfium=\(self.pdfiumRuntimeStatus, privacy: .public) report_saved=\(saved, privacy: .public)"
    )
    worker?.invalidate()
    worker = nil
    completion(runtimeStatus, fixtureStatus, saved)
  }

  private func save(_ report: Data) -> Bool {
    guard report.count <= 1024 * 1024 else { return false }
    return reservation?.publish(report) ?? false
  }
}
