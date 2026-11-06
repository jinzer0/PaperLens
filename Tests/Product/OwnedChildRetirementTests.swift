import Darwin
import Dispatch
import Foundation
import XCTest

@testable import PaperLensProduct

#if SWIFT_PACKAGE
  import ProviderRequest
#endif

/// Run EACH method in a fresh isolated test process. Unknown roots intentionally never reset.
/// Fixture teardown is physical hygiene only; it cannot discharge production debt.
@MainActor
final class OwnedChildRetirementTests: XCTestCase {
  // One-shot native fixture budget, not an SDK retirement completion requirement.
  private let cleanupBudgetNanoseconds: UInt64 = 300_000_000

  private final class Counts: @unchecked Sendable {
    let lock = NSLock()
    var effects = 0
    var terminals = 0
    var closeAttempts = 0
    var duplicateCalls = 0
    var capturedChild: OwnedChildRetirement?
    func effect() { lock.withLock { effects += 1 } }
    func terminal() { lock.withLock { terminals += 1 } }
    func closeAttempt() { lock.withLock { closeAttempts += 1 } }
    func duplicateCall() -> Int {
      lock.withLock {
        duplicateCalls += 1
        return duplicateCalls
      }
    }
    func revokeCapturedChild() {
      let child = lock.withLock { capturedChild }
      child?.revoke()
    }
    var snapshot: (Int, Int, Int) { lock.withLock { (effects, terminals, closeAttempts) } }
  }
  private func cwd() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    XCTAssertEqual(chmod(directory.path, 0o700), 0)
    return directory
  }
  private func owner(
    _ fixture: OwnedChildRetirement.Fixture, _ directory: URL,
    hooks: OwnedChildRetirement.Hooks = .init(), remaining: UInt64? = nil
  ) -> OwnedChildRetirement {
    OwnedChildRetirement(
      fixture: fixture, privateWorkingDirectory: directory,
      deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds
        + (remaining ?? cleanupBudgetNanoseconds),
      hooks: hooks)
  }
  private func terminalExpectation(_ owner: OwnedChildRetirement, counts: Counts? = nil)
    -> XCTestExpectation
  {
    let done = expectation(description: "native terminal")
    owner.observeTerminal { _ in
      counts?.terminal()
      done.fulfill()
    }
    return done
  }
  private var budgetSeconds: TimeInterval { Double(cleanupBudgetNanoseconds) / 1_000_000_000 }
  private final class Switch: @unchecked Sendable {
    let lock = NSLock()
    private var armed = false
    var value: Bool { lock.withLock { armed } }
    func arm() { lock.withLock { armed = true } }
  }
  private func start(_ child: OwnedChildRetirement) async throws -> OwnedPipeAgentRPCChannel {
    try await withCheckedThrowingContinuation { continuation in
      child.start(
        startDeadlineUptimeNanoseconds:
          DispatchTime.now().uptimeNanoseconds + 1_000_000_000
      ) { result in
        continuation.resume(with: result.mapError { $0 as Error })
      }
    }
  }

  private func workerFixture(script: String? = nil, missingInterpreter: Bool = false) throws
    -> (URL, TopologyOwnedFixtures, OwnedChildRetirement.WorkerLaunch)
  {
    let repository = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    // Match the backup-exclusion fixtures: Foundation may retain the /var alias
    // even after resolvingSymlinksInPath, which the no-follow namespace rejects.
    let root = repository.appendingPathComponent(
      ".build/owned-worker-tests-" + UUID().uuidString.lowercased(), isDirectory: true)
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let resources = root.appendingPathComponent("resources")
    try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: false)
    for (source, name) in [
      ("ProviderAgent/agent.py", "agent.py"),
      ("Contracts/ProviderRPC/provider_rpc.py", "provider_rpc.py"),
      ("Contracts/ProviderRPC/contract.json", "contract.json"),
    ] {
      try FileManager.default.copyItem(
        at: repository.appendingPathComponent(source), to: resources.appendingPathComponent(name))
    }
    let namespace = try XCTUnwrap(
      TopologyOwnedFixtures(root: root, runID: UUID().uuidString.lowercased()))
    // Actual metadata helper, never a fabricated exclusion receipt or genuine SDK launch.
    XCTAssertTrue(
      namespace.prepareBackupExclusionFixture(
        agentScript: resources.appendingPathComponent("agent.py")))
    let worker = root.appendingPathComponent("synthetic_worker.py")
    let source =
      script ?? """
        import os, sys, json, socket
        lifecycle = socket.socket(fileno=5)
        closed = []
        for fd in (3, 4):
            try:
                os.fstat(fd)
            except OSError:
                closed.append(fd)
        info = os.stat('.')
        report = dict(env=dict(os.environ), argv=sys.argv, executable=sys.executable,
                      isolated=sys.flags.isolated, no_bytecode=sys.dont_write_bytecode,
                      cwd=os.getcwd(), dev=info.st_dev, ino=info.st_ino,
                      metadata_closed=closed, family=lifecycle.family,
                      sdk_imported=('sdk_worker' in sys.modules or 'claude_agent_sdk' in sys.modules))
        with open('work/observation.json', 'w') as output:
            json.dump(report, output)
        while lifecycle.recv(1):
            pass
        """
    try Data(source.utf8).write(to: worker)
    // Resolve without inherited secrets or user configuration. Xcode's framework
    // launcher can exec a different image even after symlink canonicalization.
    let probeEnvironment = [
      "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C",
      "HOME": namespace.directoryURL.path,
      "CODEX_HOME": namespace.directoryURL.path + "/codex",
      "TMPDIR": namespace.directoryURL.path + "/tmp",
    ]
    let resolver = Process()
    let resolved = Pipe()
    resolver.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    resolver.arguments = ["--find", "python3"]
    resolver.environment = probeEnvironment
    resolver.currentDirectoryURL = namespace.directoryURL
    resolver.standardOutput = resolved
    try resolver.run()
    resolver.waitUntilExit()
    XCTAssertEqual(resolver.terminationStatus, 0)
    let launcher = try XCTUnwrap(
      String(data: resolved.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines))
    guard launcher.hasPrefix("/") else { throw OwnedChildRetirement.Failure.identity }
    let imageProbe = Process()
    let imageOutput = Pipe()
    imageProbe.executableURL = URL(fileURLWithPath: launcher)
    imageProbe.arguments = [
      "-I", "-B", "-c",
      """
      import ctypes, os, signal
      signal.alarm(2)
      libproc = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
      libproc.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
      libproc.proc_pidpath.restype = ctypes.c_int
      path = ctypes.create_string_buffer(4096)
      count = libproc.proc_pidpath(os.getpid(), path, len(path))
      if not 0 < count < len(path) or not path.value.startswith(b'/'):
          raise RuntimeError('fixture kernel interpreter image unavailable')
      print(os.fsdecode(path.value))
      """,
    ]
    imageProbe.environment = probeEnvironment
    imageProbe.currentDirectoryURL = namespace.directoryURL
    imageProbe.standardOutput = imageOutput
    try imageProbe.run()
    imageProbe.waitUntilExit()
    guard imageProbe.terminationStatus == 0 else { throw OwnedChildRetirement.Failure.identity }
    let interpreter = try XCTUnwrap(
      String(data: imageOutput.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines))
    // Launch the exact kernel-observed image; never accept an alias/fallback in
    // production identity checks or substitute a fabricated observation.
    guard interpreter.hasPrefix("/"),
      URL(fileURLWithPath: interpreter).resolvingSymlinksInPath().path == interpreter,
      FileManager.default.isExecutableFile(atPath: interpreter)
    else { throw OwnedChildRetirement.Failure.identity }
    XCTAssertTrue(interpreter.hasPrefix("/"))
    return (
      root, namespace,
      .testing(
        namespace: namespace,
        interpreter: missingInterpreter
          ? root.appendingPathComponent("missing-python3")
          : URL(fileURLWithPath: interpreter),
        script: worker)
    )
  }

  private func physicalTeardown(_ child: OwnedChildRetirement) async {
    let done = expectation(description: "worker fixture physical hygiene, not proof")
    child.testingPhysicalTeardown { _ in done.fulfill() }
    await fulfillment(of: [done], timeout: 2)
  }

  // Scripted protocol only: the broker is an actual exec'd worker child, and
  // Core performs the unmodified Darwin peer-token/image/birth/ancestry checks.
  // Optional product replies remain synthetic pending login, never SDK import,
  // provider probing, authenticated login, or Provider acceptance.
  private func controlWorkerScript(wrongOrder: Bool, productLogin: Bool = false) -> String {
    """
    import array, json, os, select, socket, struct, subprocess, sys, time
    end = time.monotonic() + 3
    run_id = os.environ['PAPERLENS_BROKER_RUN_ID']
    wrong_order = \(wrongOrder ? "True" : "False")
    product_login = \(productLogin ? "True" : "False")
    def mark(name):
        with open('work/' + name, 'x'):
            pass
    def gate(name):
        if product_login and name in ('hello', 'running', 'dispatching', 'offered'):
            return
        while not os.path.exists('work/' + name):
            if os.path.exists('work/stop') or time.monotonic() >= end:
                raise TimeoutError(name)
            time.sleep(0.005)
    def send(sock, op):
        body = json.dumps(dict(v=2, runID=run_id, op=op)).encode()
        sock.sendall(struct.pack('!I', len(body)) + body)
    def exact(sock, count):
        result = b''
        while len(result) < count:
            if os.path.exists('work/stop') or time.monotonic() >= end:
                raise TimeoutError('fixture receive')
            if not select.select([sock], [], [], 0.005)[0]:
                continue
            part = sock.recv(count - len(result))
            if not part:
                raise EOFError()
            result += part
        return result
    def receive(sock, op, fields=()):
        size, = struct.unpack('!I', exact(sock, 4))
        assert 0 < size <= 1024
        message = json.loads(exact(sock, size))
        assert set(message) == set(('v', 'runID', 'op') + fields)
        assert message['v'] == 2 and message['runID'] == run_id
        assert message['op'] == op
        return message
    def product_exact(count):
        result = b''
        while len(result) < count:
            if os.path.exists('work/stop') or time.monotonic() >= end:
                raise TimeoutError('product fixture receive')
            if not select.select([0], [], [], 0.005)[0]:
                continue
            part = os.read(0, count - len(result))
            if not part:
                raise EOFError()
            result += part
        return result
    def product_loop():
        hello = dict(major=2, minor=0, capabilities=['product-v1'])
        identity = None
        for index in range(256):
            size, = struct.unpack('!I', product_exact(4))
            assert 0 < size <= 65536
            request = json.loads(product_exact(size))
            assert request['kind'] == 'request'
            method, params = request['method'], request['params']
            with open('work/product-methods', 'a') as log:
                log.write(method + '\\n')
            if method == 'product.hello':
                assert index == 0 and params == hello
                result = hello
            elif method == 'product.loginStart':
                assert identity is None and params['mode'] == 'browser'
                identity = dict(stageID=params['stageID'], intentID=params['intentID'])
                result = dict(identity, instructions=dict(mode='browser', authUrl='https://example.invalid/login'))
            elif method == 'product.loginObserve':
                assert identity is not None and params == identity
                result = dict(identity, state='pending')
            elif method == 'product.loginCancel':
                assert identity is not None and params == identity
                mark('cancel-received')
                result = dict(identity, accepted=True)
            else:
                raise AssertionError('forbidden synthetic product method: ' + method)
            body = json.dumps(dict(kind='result', id=request['id'], result=result)).encode()
            frame = struct.pack('!I', len(body)) + body
            while frame:
                count = os.write(1, frame)
                assert count > 0
                frame = frame[count:]
    if sys.argv[-1] == '--fixture-broker':
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as broker:
            broker.settimeout(3)
            broker.connect('b')
            gate('hello')
            send(broker, 'running' if wrong_order else 'hello')
            if not wrong_order:
                message = receive(broker, 'run', ('startupDeadlineNs', 'cwdDevice', 'cwdInode'))
                info = os.stat('.')
                assert message['cwdDevice'] == info.st_dev and message['cwdInode'] == info.st_ino
                assert message['startupDeadlineNs'] == int(os.environ['PAPERLENS_BROKER_START_DEADLINE_NS'])
                mark('run-received')
                gate('running')
                send(broker, 'running')
                receive(broker, 'dispatch')
                mark('dispatch-received')
                gate('dispatching')
                send(broker, 'dispatching')
            gate('stop')
    else:
        broker = None
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as listener:
                listener.settimeout(0.3)
                listener.bind('b')
                os.chmod('b', 0o600)
                listener.listen(1)
                broker = subprocess.Popen([sys.executable, '-I', '-B', __file__, '--fixture-broker'],
                                          stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                          stderr=subprocess.DEVNULL, close_fds=True)
                with listener.accept()[0] as peer, socket.socket(fileno=5) as lifecycle:
                    lifecycle.settimeout(3)
                    rights = array.array('i', [peer.fileno()])
                    assert lifecycle.sendmsg([b'B'], [(socket.SOL_SOCKET, socket.SCM_RIGHTS, rights)]) == 1
                    mark('right-offered')
                    if not wrong_order:
                        gate('offered')
                        send(lifecycle, 'brokerOffered')
                        receive(lifecycle, 'dispatching')
                        mark('worker-dispatching')
                        if product_login:
                            product_loop()
                    gate('stop')
        finally:
            # Physical fixture hygiene ONLY. This is not a control retirement
            # receipt and cannot discharge native roots or SDK closure debt.
            if broker is not None:
                if broker.poll() is None:
                    broker.terminate()
                try:
                    broker.wait(timeout=0.3)
                except subprocess.TimeoutExpired:
                    broker.kill()
                    broker.wait(timeout=0.3)
            mark('broker-reaped-physically')
    """
  }

  private func waitForControlMarker(_ name: String, in directory: URL) async throws {
    for _ in 0..<100 {
      if FileManager.default.fileExists(
        atPath: directory.appendingPathComponent("work/" + name).path)
      {
        return
      }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("Missing bounded synthetic control marker: \(name)")
    throw OwnedChildRetirement.Failure.control
  }

  private func controlGate(_ name: String, in directory: URL) throws {
    try Data().write(to: directory.appendingPathComponent("work/" + name))
  }

  private func waitForWorkerRetirement(_ child: OwnedChildRetirement) async throws {
    for _ in 0..<100 {
      if child.core.lock.withLock({ child.core.retirementID != nil }) { return }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("Worker startup did not revoke admission")
    throw OwnedChildRetirement.Failure.deadline
  }

  private func controlHandshake(offeredFirst: Bool, wrongOrder: Bool = false) async throws {
    let (root, namespace, launch) = try workerFixture(
      script: controlWorkerScript(wrongOrder: wrongOrder))
    defer { try? FileManager.default.removeItem(at: root) }
    let child = OwnedChildRetirement(
      worker: launch,
      deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 3_000_000_000)
    let directory = namespace.directoryURL
    let done = wrongOrder ? terminalExpectation(child) : nil
    child.launchWorker()
    var failure: Error?
    do {
      try await waitForControlMarker("right-offered", in: directory)
      // Inspect on Core's operation lane; never inject observations or call
      // receiveControl directly. Polling does not retry any ownership effect.
      var authenticated = false
      for _ in 0..<100 {
        authenticated = await withCheckedContinuation { continuation in
          child.core.operation.async {
            continuation.resume(returning: child.core.brokerIdentity != nil)
          }
        }
        if authenticated || child.terminal != nil { break }
        try await Task.sleep(nanoseconds: 10_000_000)
      }
      if !authenticated {
        // Read only the observations already retained by production Core. No
        // second identity syscall, admission bypass, or replacement observation.
        let diagnostic = await withCheckedContinuation { continuation in
          child.core.operation.async {
            let core = child.core
            var lines = [
              "terminal=\(String(describing: child.terminal))",
              "expectedInterpreter=\(launch.interpreter.path)",
              "expectedCanonicalInterpreter=\(launch.interpreter.resolvingSymlinksInPath().path)",
              "workerAtSpawn=\(String(describing: core.workerAtSpawn))",
              "brokerFD=\(String(describing: core.brokerFD))",
              "nativePID=\(getpid()) uid=\(getuid()) euid=\(geteuid()) egid=\(getegid())",
            ]
            if let offer = core.offerStorage {
              lines.append(
                "offer result=\(String(describing: offer.syscallResult)) errno=\(offer.syscallErrno) flags=\(offer.flags) controlBytes=\(offer.returnedControlBytes) marker=\(offer.marker) rights=\(offer.capturedDescriptors)"
              )
            }
            for (index, record) in core.identityStorage.records.enumerated() {
              let detail: String
              switch record {
              case .localID(let name, let value):
                detail = "localID \(name)=\(value)"
              case .credentials(let result, let code, let uid, let gid):
                detail = "credentials result=\(result) errno=\(code) uid=\(uid) gid=\(gid)"
              case .peerPID(let result, let code, let size, let pid):
                detail = "peerPID result=\(result) errno=\(code) size=\(size) pid=\(pid)"
              case .peerToken(let result, let code, let size, let token):
                detail = "peerToken result=\(result) errno=\(code) size=\(size) token=\(token)"
              case .path(let result, let code, let bytes):
                let path = String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
                detail =
                  "path result=\(result) errno=\(code) actual=\(path) canonicalMatches=\(path == launch.interpreter.resolvingSymlinksInPath().path)"
              case .process(let result, let code, let info):
                let snapshot = NativeBrokerABI.ProcessSnapshot(
                  pid: pid_t(info.pbi_pid), parentPID: pid_t(info.pbi_ppid),
                  uid: info.pbi_uid, gid: info.pbi_gid,
                  birthSeconds: info.pbi_start_tvsec, birthMicroseconds: info.pbi_start_tvusec)
                let isWorker = snapshot.pid == core.workerAtSpawn?.pid
                detail =
                  "process result=\(result) errno=\(code) snapshot=\(snapshot) isWorker=\(isWorker) equalsWorkerAtSpawn=\(core.workerAtSpawn == snapshot)"
              }
              lines.append("record[\(index)] \(detail)")
            }
            continuation.resume(returning: lines.joined(separator: "\n"))
          }
        }
        XCTFail("Actual Darwin broker chain rejected; retained observations:\n\(diagnostic)")
        throw OwnedChildRetirement.Failure.control
      }
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        child.core.operation.async {
          if let broker = child.core.brokerIdentity, let worker = child.core.workerAtSpawn {
            XCTAssertEqual(worker.parentPID, getpid())
            XCTAssertEqual(broker.process.parentPID, worker.pid)
            XCTAssertEqual(broker.peer.pid, broker.process.pid)
            XCTAssertNotEqual(broker.peer.pid, worker.pid)
            XCTAssertGreaterThan(broker.peer.pidVersion, 0)
            XCTAssertEqual(broker.peer.uid, geteuid())
            XCTAssertEqual(broker.peer.gid, getegid())
            XCTAssertEqual(broker.executablePath, launch.interpreter.resolvingSymlinksInPath().path)
          } else {
            XCTFail("Missing actual spawn and authenticated broker observations")
          }
          continuation.resume()
        }
      }
      XCTAssertNil(child.terminal)
      XCTAssertThrowsError(try child.core.reservedEndpoints())
      XCTAssertFalse(child.core.markRunning())
      try controlGate("hello", in: directory)
      if wrongOrder {
        await fulfillment(of: [try XCTUnwrap(done)], timeout: 1)
        XCTAssertEqual(child.terminal, .unknown(.control))
        XCTAssertThrowsError(try child.core.reservedEndpoints())
        XCTAssertFalse(child.core.markRunning())
      } else {
        try await waitForControlMarker("run-received", in: directory)
        XCTAssertThrowsError(try child.core.reservedEndpoints())
        try controlGate("running", in: directory)
        try await waitForControlMarker("dispatch-received", in: directory)
        XCTAssertThrowsError(try child.core.reservedEndpoints())
        try controlGate(offeredFirst ? "offered" : "dispatching", in: directory)
        var firstAcknowledged = false
        for _ in 0..<100 {
          firstAcknowledged = await withCheckedContinuation { continuation in
            child.core.operation.async {
              continuation.resume(
                returning:
                  offeredFirst ? child.core.brokerOffered : child.core.dispatchAcknowledged)
            }
          }
          if firstAcknowledged || child.terminal != nil { break }
          try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(firstAcknowledged)
        XCTAssertNil(child.terminal)
        XCTAssertThrowsError(
          try child.core.reservedEndpoints(), "Either half alone must not publish endpoints")
        XCTAssertFalse(child.core.markRunning())
        try controlGate(offeredFirst ? "dispatching" : "offered", in: directory)
        try await waitForControlMarker("worker-dispatching", in: directory)
        // The worker can observe the write before flushControl has recorded its
        // handoff. Join that operation slice, not a speculative timing delay.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
          child.core.operation.async { continuation.resume() }
        }
        let endpoints = try child.core.reservedEndpoints()
        XCTAssertNotEqual(endpoints.0, endpoints.1)
        XCTAssertGreaterThanOrEqual(fcntl(endpoints.0, F_GETFD), 0)
        XCTAssertGreaterThanOrEqual(fcntl(endpoints.1, F_GETFD), 0)
        XCTAssertNil(child.terminal)
        // Control handoff is not product/Provider acceptance: no transport has
        // captured these endpoints, and no scripted product hello is supplied.
        XCTAssertFalse(child.core.markRunning())
        child.revoke()
        let identity = try XCTUnwrap(child.core.lock.withLock { child.core.retirementID })
        child.revoke()
        XCTAssertEqual(child.core.lock.withLock { child.core.retirementID }, identity)
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertNil(child.terminal, "Slow SDK cleanup must remain pending, not expire at 300ms")
        XCTAssertFalse(child.core.allowsIO)
      }
      XCTAssertTrue(child.testingRetained)
      XCTAssertFalse(child.testingReaped)
      XCTAssertFalse(namespace.cleanup())
    } catch {
      failure = error
      child.revoke()
    }
    let terminal = child.terminal
    do {
      try controlGate("stop", in: directory)
      try await waitForControlMarker("broker-reaped-physically", in: directory)
    } catch {
      failure = failure ?? error
    }
    await physicalTeardown(child)
    if let terminal {
      XCTAssertEqual(child.terminal, terminal, "Physical hygiene cannot change runtime debt")
    } else if case .some(.clean(_)) = child.terminal {
      XCTFail("Physical hygiene is not a production clean receipt")
    }
    XCTAssertTrue(child.testingRetained)
    XCTAssertFalse(child.testingReaped)
    if let failure { throw failure }
  }

  func testWorkerRealBrokerControlWaitsForBrokerOfferedAfterDispatchAcknowledgement() async throws {
    try await controlHandshake(offeredFirst: false)
  }

  func testWorkerRealBrokerControlWaitsForDispatchAcknowledgementAfterBrokerOffered() async throws {
    try await controlHandshake(offeredFirst: true)
  }

  func testWorkerRealBrokerRunningBeforeHelloRejectsControlWithoutProductHandoff() async throws {
    try await controlHandshake(offeredFirst: false, wrongOrder: true)
  }

  private final class LoginNoNetworkTransport: NativeConnectionTestTransport {
    private(set) var calls = 0
    func probe(
      key: String, configuration: NativeOpenAIConfiguration,
      request: AuthorizedProviderRequest, authority: ProviderRequest
    ) async throws -> NativeProbeResponse {
      calls += 1
      XCTFail("Pending synthetic login must never probe a provider")
      throw APIKeyConnectionError.authentication
    }
  }

  func testNativeCodexPendingLoginCoalescesSameTurnAndAllowsImmediateExplicitObservationsBeyond100()
    async throws
  {
    // Product replies are synthetic pending states, NOT authenticated Provider
    // acceptance. Only the local process/control identity is kernel-authenticated.
    let (root, _, template) = try workerFixture(
      script: controlWorkerScript(wrongOrder: false, productLogin: true))
    defer { try? FileManager.default.removeItem(at: root) }
    let database = try ProductDatabase.open(at: root.appendingPathComponent("database"))
    let slots = try APIKeySlotStore(directory: root.appendingPathComponent("api-key-slots"))
    let configuration = try NativeOpenAIConfiguration(model: "fixture-model")
    _ = try database.compareAndSwapProviderConfiguration(
      expected: database.providerConfiguration(), replacementKind: .openAIAPIKey,
      replacementSlotID: slots.create(key: "synthetic-offline-key"),
      replacementModel: configuration.model)
    let selected = try database.providerConfiguration()
    let transport = LoginNoNetworkTransport()
    let apiKey = NativeAPIKeyConnection(
      configuration: configuration, slots: slots,
      persistence: DatabaseAPIKeySelector(database: database, configuration: configuration),
      transport: transport, authority: try ProviderRequest())
    apiKey.restore()
    var prepared: TopologyOwnedFixtures?
    let candidate = NativeCodexConnection(
      database: database, root: root, apiKey: apiKey,
      prepareWorker: { namespace in
        prepared = namespace
        guard
          namespace.prepareBackupExclusionFixture(
            agentScript: root.appendingPathComponent("resources/agent.py"))
        else { return nil }
        return .testing(
          namespace: namespace, interpreter: template.interpreter, script: template.script)
      })
    candidate.connect(mode: "browser")
    let owner = try XCTUnwrap(candidate.testingOwner)
    let directory = try XCTUnwrap(prepared).directoryURL
    var failure: Error?
    do {
      let bound = DispatchTime.now().uptimeNanoseconds + 3_000_000_000
      func awaitSigningIn() async throws {
        while candidate.phase != .signingIn {
          guard candidate.phase != .blocked,
            DispatchTime.now().uptimeNanoseconds < bound
          else {
            XCTFail("Synthetic pending login did not settle: \(candidate.phase)")
            throw OwnedChildRetirement.Failure.control
          }
          await Task.yield()
        }
      }
      func methods() throws -> [String] {
        try String(
          contentsOf: directory.appendingPathComponent("work/product-methods"),
          encoding: .utf8
        ).split(separator: "\n").map(String.init)
      }
      try await awaitSigningIn()
      XCTAssertEqual(candidate.instructions?.url.absoluteString, "https://example.invalid/login")
      XCTAssertEqual(try methods(), ["product.hello", "product.loginStart"])
      // No suspension between these calls: the first must fence the second
      // before any transport callback can return to this MainActor turn.
      candidate.checkLogin()
      XCTAssertEqual(candidate.phase, .observing)
      candidate.checkLogin()
      XCTAssertEqual(candidate.phase, .observing)
      try await awaitSigningIn()
      XCTAssertEqual(try methods().filter { $0 == "product.loginObserve" }.count, 1)
      // Each explicit user observation is accepted synchronously, without a
      // polling sleep/interval. 102 observations + hello/start stay below 256.
      for expectedCount in 2...102 {
        candidate.checkLogin()
        XCTAssertEqual(
          candidate.phase, .observing, "Immediate observation \(expectedCount) rejected")
        guard candidate.phase == .observing else { throw OwnedChildRetirement.Failure.control }
        try await awaitSigningIn()
        XCTAssertEqual(try methods().filter { $0 == "product.loginObserve" }.count, expectedCount)
        XCTAssertEqual(try database.providerConfiguration(), selected)
      }
      let transcript = try methods()
      XCTAssertEqual(transcript.count, 104)
      XCTAssertEqual(transcript.filter { $0 == "product.loginStart" }.count, 1)
      XCTAssertFalse(transcript.contains("product.connectionTest"))
      XCTAssertEqual(transport.calls, 0)
      XCTAssertEqual(candidate.phase, .signingIn)
      XCTAssertFalse(candidate.eligibleForEntry)
      XCTAssertNil(owner.terminal)
      XCTAssertEqual(try database.providerConfiguration(), selected)
      // Queue an observation in this same actor turn. Cancellation must discard
      // that undispatched frame and deliver only the actual stage cancellation.
      candidate.checkLogin()
      candidate.cancel()
      XCTAssertEqual(candidate.phase, .retiring)
      XCTAssertNil(candidate.instructions)
      XCTAssertFalse(candidate.eligibleForEntry)
      XCTAssertTrue(candidate.blocksReplacement)
      XCTAssertFalse(candidate.canStart)
      try await waitForControlMarker("cancel-received", in: directory)
      XCTAssertEqual(try methods(), transcript + ["product.loginCancel"])
      XCTAssertEqual(try database.providerConfiguration(), selected)
    } catch { failure = error }
    // Revoke once, then physically reap controlled fixture processes. Neither
    // this script nor teardown supplies a runtime clean/SDK closure ACK.
    owner.revoke()
    try await waitForWorkerRetirement(owner)
    let terminal = owner.terminal
    do {
      try controlGate("stop", in: directory)
      try await waitForControlMarker("broker-reaped-physically", in: directory)
    } catch { failure = failure ?? error }
    await physicalTeardown(owner)
    if let terminal {
      XCTAssertEqual(owner.terminal, terminal)
    } else if case .some(.clean(_)) = owner.terminal {
      XCTFail("Physical hygiene is not a production clean receipt")
    }
    XCTAssertTrue(owner.testingRetained)
    XCTAssertFalse(owner.testingReaped)
    XCTAssertEqual(transport.calls, 0)
    XCTAssertEqual(try database.providerConfiguration(), selected)
    if let failure { throw failure }
  }

  func testWorkerActualFD5CwdEnvironmentAndArgvNeverPublishesReadyOrClean() async throws {
    let (root, namespace, launch) = try workerFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let acquired = expectation(description: "ten setup FDs, six checked closes")
    let counts = Counts()
    var hooks = OwnedChildRetirement.Hooks()
    hooks.before = { _ in counts.effect() }
    hooks.workerLaunched = { acquired.fulfill() }
    let startup = DispatchTime.now().uptimeNanoseconds + 3_000_000_000
    let child = OwnedChildRetirement(
      worker: launch, deadlineUptimeNanoseconds: startup, hooks: hooks)
    child.launchWorker()
    await fulfillment(of: [acquired], timeout: 2)
    XCTAssertEqual(child.testingDescriptorCount, 4)
    XCTAssertEqual(child.core.lock.withLock { child.core.closes }, 6)
    XCTAssertFalse(namespace.permitsNamespaceMutation)
    XCTAssertFalse(namespace.cleanup())
    XCTAssertThrowsError(try child.core.reservedEndpoints())
    XCTAssertFalse(child.core.markRunning())
    XCTAssertNil(child.terminal)
    let reportURL = namespace.directoryURL.appendingPathComponent("work/observation.json")
    var report: [String: Any]?
    for _ in 0..<100 {
      if let bytes = try? Data(contentsOf: reportURL),
        let value = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any]
      {
        report = value
        break
      }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    let observed = try XCTUnwrap(report)
    XCTAssertEqual(observed["argv"] as? [String], [launch.script.path, "--official-sdk-worker"])
    XCTAssertEqual(
      child.core.lock.withLock { child.core.spawnArguments },
      [
        launch.interpreter.path, "-I", "-B", launch.script.path, "--official-sdk-worker",
      ])
    XCTAssertEqual(observed["isolated"] as? Int, 1)
    XCTAssertEqual(observed["no_bytecode"] as? Bool, true)
    XCTAssertEqual(
      observed["cwd"] as? String, namespace.directoryURL.resolvingSymlinksInPath().path)
    var identity = stat()
    XCTAssertEqual(fstat(namespace.descriptor, &identity), 0)
    XCTAssertEqual((observed["dev"] as? NSNumber)?.uint64Value, UInt64(identity.st_dev))
    XCTAssertEqual((observed["ino"] as? NSNumber)?.uint64Value, UInt64(identity.st_ino))
    XCTAssertEqual(observed["metadata_closed"] as? [Int], [3, 4])
    XCTAssertEqual(observed["family"] as? Int, Int(AF_UNIX))
    XCTAssertEqual(observed["sdk_imported"] as? Bool, false)
    let expectedEnvironment = [
      "PATH": launch.interpreter.deletingLastPathComponent().path
        + ":/usr/bin:/bin:/usr/sbin:/sbin",
      "LANG": "C", "LC_ALL": "C",
      "HOME": namespace.directoryURL.path, "CODEX_HOME": namespace.directoryURL.path + "/codex",
      "TMPDIR": namespace.directoryURL.path + "/tmp", "PAPERLENS_BROKER_RUN_ID": namespace.runID,
      "PAPERLENS_BROKER_START_DEADLINE_NS": String(startup),
    ]
    XCTAssertEqual(
      Set(child.core.lock.withLock { child.core.spawnEnvironment }),
      Set(expectedEnvironment.map { $0.key + "=" + $0.value }))
    let workerEnvironment = try XCTUnwrap(observed["env"] as? [String: String])
    for (key, value) in expectedEnvironment { XCTAssertEqual(workerEnvironment[key], value) }
    // CPython/CoreFoundation add locale metadata after exec, not inherited launch keys.
    // The exact pre-exec environment remains asserted above.
    XCTAssertTrue(
      Set(workerEnvironment.keys).subtracting(expectedEnvironment.keys).isSubset(
        of: ["LC_CTYPE", "__CF_USER_TEXT_ENCODING"]),
      "Unexpected worker environment keys: \(Set(workerEnvironment.keys).subtracting(expectedEnvironment.keys))"
    )
    if let encoding = workerEnvironment["__CF_USER_TEXT_ENCODING"] {
      XCTAssertTrue(encoding.hasPrefix("0x" + String(getuid(), radix: 16, uppercase: true) + ":"))
    }
    let fd = try XCTUnwrap(
      child.core.lock.withLock {
        child.core.descriptorRoles.first(where: { $0.value == .workerLifecycle })?.key
      })
    // The control owner is the sole reader. This synthetic worker deliberately
    // sends no broker offer and cannot authenticate or advance product startup.
    var socketType: Int32 = 0
    var socketTypeSize = socklen_t(MemoryLayout<Int32>.size)
    XCTAssertEqual(getsockopt(fd, SOL_SOCKET, SO_TYPE, &socketType, &socketTypeSize), 0)
    XCTAssertEqual(socketType, SOCK_STREAM)
    child.revoke()
    let retirementID = try XCTUnwrap(child.core.lock.withLock { child.core.retirementID })
    child.revoke()
    XCTAssertEqual(child.core.lock.withLock { child.core.retirementID }, retirementID)
    try await Task.sleep(nanoseconds: 400_000_000)
    XCTAssertNil(child.terminal)
    XCTAssertFalse(child.core.allowsIO)
    XCTAssertFalse(child.testingReaped)
    XCTAssertTrue(child.testingRetained)
    XCTAssertEqual(child.testingDescriptorCount, 4)
    let effects = counts.snapshot.0
    child.core.beginRunningCleanup()
    child.core.finishRunningCleanup()
    XCTAssertEqual(counts.snapshot.0, effects)
    let replacementDirectory = try cwd()
    defer { try? FileManager.default.removeItem(at: replacementDirectory) }
    let replacement = owner(.trueUtility, replacementDirectory)
    let completed = terminalExpectation(replacement)
    replacement.retire()
    await fulfillment(of: [completed], timeout: 1)
    assertClean(replacement)
    await physicalTeardown(child)
    if case .some(.clean(_)) = child.terminal {
      XCTFail("Physical hygiene is not a production clean receipt")
    }
    XCTAssertFalse(namespace.permitsNamespaceMutation)
  }

  private func workerSetupFailure(
    hooks: OwnedChildRetirement.Hooks, descriptors: Int, missingInterpreter: Bool = false
  ) async throws {
    let (root, namespace, launch) = try workerFixture(missingInterpreter: missingInterpreter)
    defer { try? FileManager.default.removeItem(at: root) }
    let child = OwnedChildRetirement(
      worker: launch,
      deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 3_000_000_000,
      hooks: hooks)
    let done = terminalExpectation(child)
    child.launchWorker()
    await fulfillment(of: [done], timeout: 2)
    XCTAssertEqual(child.terminal, .unknown(missingInterpreter ? .spawn : .setup))
    XCTAssertEqual(child.testingDescriptorCount, descriptors)
    XCTAssertEqual(child.core.lock.withLock { child.core.closes }, 0)
    XCTAssertFalse(child.testingChildExists)
    XCTAssertFalse(child.testingReaped)
    XCTAssertTrue(child.testingRetained)
    XCTAssertFalse(namespace.cleanup())
    XCTAssertFalse(namespace.permitsNamespaceMutation)
    await physicalTeardown(child)
  }

  func testWorkerPartialPipeCapturedBeforeFault() async throws {
    try await workerSetupFailure(hooks: .init(afterPipeFault: { true }), descriptors: 3)
  }

  func testWorkerPartialSocketpairCapturedBeforeFault() async throws {
    try await workerSetupFailure(hooks: .init(afterSocketFault: { true }), descriptors: 9)
  }

  func testWorkerCwdDuplicateCapturedBeforeFault() async throws {
    try await workerSetupFailure(hooks: .init(afterDuplicateFault: { true }), descriptors: 1)
  }

  func testWorkerLifecycleHighDuplicateCapturedBeforeFault() async throws {
    let counts = Counts()
    try await workerSetupFailure(
      hooks: .init(afterDuplicateFault: { counts.duplicateCall() == 2 }), descriptors: 10)
  }

  func testWorkerSpawnFailureRetainsAllTenActualFDs() async throws {
    try await workerSetupFailure(hooks: .init(), descriptors: 10, missingInterpreter: true)
  }

  func testWorkerLateActualSpawnNeverClosesWaitsOrPublishesReady() async throws {
    let (root, namespace, launch) = try workerFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let gate = DispatchSemaphore(value: 0)
    defer { gate.signal() }
    let spawned = expectation(description: "actual worker PID captured before held hook")
    let counts = Counts()
    let child = OwnedChildRetirement(
      worker: launch, deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 200_000_000,
      hooks: .init(
        before: { _ in counts.effect() },
        afterSpawn: { _ in
          spawned.fulfill()
          gate.wait()
        }, workerLaunched: { XCTFail("late worker launch publication") }))
    child.launchWorker()
    await fulfillment(of: [spawned], timeout: 2)
    try await waitForWorkerRetirement(child)
    XCTAssertNil(child.terminal)
    XCTAssertFalse(child.core.allowsIO)
    XCTAssertEqual(child.testingDescriptorCount, 10)
    XCTAssertTrue(child.testingChildExists)
    XCTAssertFalse(child.testingReaped)
    XCTAssertFalse(namespace.cleanup())
    let effects = counts.snapshot.0
    gate.signal()
    await physicalTeardown(child)
    XCTAssertEqual(counts.snapshot.0, effects)
    if case .some(.clean(_)) = child.terminal { XCTFail("Unproved cleanup became clean") }
    XCTAssertTrue(child.testingRetained)
    XCTAssertFalse(namespace.permitsNamespaceMutation)
  }

  private func workerLateCapture(_ stage: OwnedChildRetirement.Effect, descriptors: Int)
    async throws
  {
    let (root, namespace, launch) = try workerFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let gate = DispatchSemaphore(value: 0)
    defer { gate.signal() }
    let captured = expectation(
      description: "actual acquisition captured before held validation hook")
    let counts = Counts()
    let fault: @Sendable () -> Bool = {
      captured.fulfill()
      gate.wait()
      return false
    }
    var hooks = OwnedChildRetirement.Hooks()
    hooks.before = { _ in counts.effect() }
    hooks.workerLaunched = { XCTFail("late worker publication") }
    switch stage {
    case .pipe: hooks.afterPipeFault = fault
    case .socket: hooks.afterSocketFault = fault
    case .duplicate: hooks.afterDuplicateFault = fault
    default:
      XCTFail("unsupported acquisition fixture")
      return
    }
    let child = OwnedChildRetirement(
      worker: launch, deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 200_000_000,
      hooks: hooks)
    child.launchWorker()
    await fulfillment(of: [captured], timeout: 2)
    try await waitForWorkerRetirement(child)
    XCTAssertNil(child.terminal)
    XCTAssertFalse(child.core.allowsIO)
    XCTAssertEqual(child.testingDescriptorCount, descriptors)
    XCTAssertFalse(child.testingChildExists)
    XCTAssertEqual(child.core.lock.withLock { child.core.closes }, 0)
    let effects = counts.snapshot.0
    gate.signal()
    await physicalTeardown(child)
    XCTAssertEqual(counts.snapshot.0, effects)
    XCTAssertTrue(child.testingRetained)
    XCTAssertFalse(namespace.cleanup())
  }

  func testWorkerLatePipeCaptureCannotStartAnotherEffectAfterRevocation() async throws {
    try await workerLateCapture(.pipe, descriptors: 3)
  }

  func testWorkerLateSocketCaptureCannotStartAnotherEffectAfterRevocation() async throws {
    try await workerLateCapture(.socket, descriptors: 9)
  }

  func testWorkerLateDuplicateCaptureCannotStartAnotherEffectAfterRevocation() async throws {
    try await workerLateCapture(.duplicate, descriptors: 1)
  }

  func testExitedSyntheticWorkerCannotUseGenericWaitOrClean() async throws {
    let (root, namespace, launch) = try workerFixture(script: "import os\nos._exit(0)\n")
    defer { try? FileManager.default.removeItem(at: root) }
    let acquired = expectation(description: "synthetic exit-capable worker launched")
    let child = OwnedChildRetirement(
      worker: launch,
      deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 3_000_000_000,
      hooks: .init(workerLaunched: { acquired.fulfill() }))
    child.launchWorker()
    await fulfillment(of: [acquired], timeout: 2)
    child.retire()
    try await waitForWorkerRetirement(child)
    try await Task.sleep(nanoseconds: 400_000_000)
    XCTAssertNil(child.terminal)
    XCTAssertFalse(child.core.allowsIO)
    XCTAssertFalse(child.testingReaped)
    XCTAssertEqual(child.testingDescriptorCount, 4)
    XCTAssertTrue(child.testingRetained)
    XCTAssertFalse(namespace.cleanup())
    await physicalTeardown(child)
  }

  func testWorkerEOFBeforeOfferQuiescesNotificationsWithoutReleasingDebt() async throws {
    let (root, namespace, launch) = try workerFixture(script: "import os\nos._exit(0)\n")
    defer { try? FileManager.default.removeItem(at: root) }
    let child = OwnedChildRetirement(
      worker: launch,
      deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 3_000_000_000)
    let done = terminalExpectation(child)
    child.launchWorker()
    await fulfillment(of: [done], timeout: 2)
    XCTAssertEqual(child.terminal, .unknown(.control))
    let sourceCount = await withCheckedContinuation { continuation in
      child.core.operation.async {
        continuation.resume(
          returning:
            child.core.controlSources.count + child.core.controlWrites.count
            + child.core.lock.withLock { child.core.stderrSource == nil ? 0 : 1 })
      }
    }
    XCTAssertEqual(sourceCount, 0)
    XCTAssertEqual(child.testingDescriptorCount, 4)
    XCTAssertFalse(child.testingReaped)
    XCTAssertTrue(child.testingRetained)
    XCTAssertFalse(namespace.permitsNamespaceMutation)
    XCTAssertFalse(namespace.cleanup())
    await physicalTeardown(child)
    XCTAssertEqual(child.terminal, .unknown(.control))
  }

  func testRunningCatFramedEchoSameLifecycleAndFixedFirstRevoke() async throws {
    let directory = try cwd()
    defer { try? FileManager.default.removeItem(at: directory) }
    let child = OwnedChildRetirement(runningFixture: .cat, privateWorkingDirectory: directory)
    let channel = try await start(child)
    XCTAssertTrue(child.testingChannel === channel)
    XCTAssertNil(child.terminal)
    XCTAssertFalse(child.testingReaped)
    let lifecycle = try AgentConnectionLifecycle(ownedPipe: channel, mode: .topology)
    let frame = Data([0, 0, 0, 3, 1, 2, 3])
    try await channel.write(frame)
    var echoed = Data()
    while echoed.count < frame.count {
      let bytes = try await channel.read()
      echoed.append(try XCTUnwrap(bytes))
    }
    XCTAssertEqual(echoed, frame)
    XCTAssertNil(child.terminal)
    let done = terminalExpectation(child)
    let t0 = DispatchTime.now().uptimeNanoseconds
    child.revoke()
    let deadline = child.core.lock.withLock { child.core.deadline }
    XCTAssertLessThanOrEqual(deadline - t0, cleanupBudgetNanoseconds + 1_000_000)
    child.revoke()
    XCTAssertEqual(child.core.lock.withLock { child.core.deadline }, deadline)
    do {
      try await channel.write(frame)
      XCTFail("Revoke admitted new channel IO")
    } catch {
      XCTAssertEqual(error as? OwnedPipeAgentRPCChannel.Failure, .closed)
    }
    lifecycle.close()
    await fulfillment(of: [done], timeout: 1)
    child.revoke()
    XCTAssertEqual(child.core.lock.withLock { child.core.deadline }, deadline)
    XCTAssertTrue(channel.closureOutcome.bothClosed)
    assertClean(child)
  }

  func testRunningFacadeLossRevokesActualChannelAndReapsCat() async throws {
    let directory = try cwd()
    defer { try? FileManager.default.removeItem(at: directory) }
    var child: OwnedChildRetirement? = OwnedChildRetirement(
      runningFixture: .cat, privateWorkingDirectory: directory)
    let channel = try await start(try XCTUnwrap(child))
    let done = terminalExpectation(try XCTUnwrap(child))
    let rooted = try XCTUnwrap(child).testingRootWitness
    weak var facade = child
    child = nil
    XCTAssertNil(facade)
    await fulfillment(of: [done], timeout: 1)
    XCTAssertTrue(channel.closureOutcome.bothClosed)
    XCTAssertFalse(rooted())
  }

  func testRunningTrueEOFUsesImmutableActualOwnerCallbackDespiteObserverReplacement() async throws {
    let directory = try cwd()
    defer { try? FileManager.default.removeItem(at: directory) }
    let child = OwnedChildRetirement(
      runningFixture: .trueUtility, privateWorkingDirectory: directory)
    let channel = try await start(child)
    let done = terminalExpectation(child)
    channel.observeClosure { _ in XCTFail("Replaced external callback ran") }
    let external = expectation(description: "replaceable external closure notification")
    channel.observeClosure { outcome in
      XCTAssertTrue(outcome.bothClosed)
      external.fulfill()
    }
    let eof = try await channel.read()
    XCTAssertNil(eof)
    await fulfillment(of: [done, external], timeout: 1)
    assertClean(child)
  }

  func testRunningPartialChannelSetupCapturedBeforeIndependentDeadlineNoLateClean() async throws {
    let directory = try cwd()
    defer { try? FileManager.default.removeItem(at: directory) }
    let release = DispatchSemaphore(value: 0)
    let counts = Counts()
    var hooks = OwnedChildRetirement.Hooks()
    hooks.before = { _ in counts.effect() }
    // This is the real MainActor setup interval after actual Owner capture.
    hooks.beforeChannelSetup = { release.wait() }
    let child = OwnedChildRetirement(
      runningFixture: .cat, privateWorkingDirectory: directory, hooks: hooks)
    let done = expectation(
      description: "startup expiry and cleanup expiry independent of MainActor")
    child.observeTerminal { terminal in
      XCTAssertEqual(terminal, .unknown(.deadline))
      counts.terminal()
      release.signal()
      done.fulfill()
    }
    let ready = expectation(description: "no late ready success")
    child.start(
      startDeadlineUptimeNanoseconds:
        DispatchTime.now().uptimeNanoseconds + 1_000_000_000
    ) { result in
      if case .success = result { XCTFail("Late setup published running") }
      ready.fulfill()
    }
    await fulfillment(of: [done, ready], timeout: 3)
    XCTAssertNotNil(child.testingChannel)
    XCTAssertEqual(child.testingDescriptorCount, 1)
    XCTAssertTrue(child.testingRetained)
    XCTAssertFalse(child.testingReaped)
    let effects = counts.snapshot.0
    child.revoke()
    let deadline = child.core.lock.withLock { child.core.deadline }
    child.revoke()
    XCTAssertEqual(child.core.lock.withLock { child.core.deadline }, deadline)
    XCTAssertEqual(counts.snapshot.0, effects)
    let hygiene = expectation(description: "physical hygiene without debt discharge")
    child.testingPhysicalTeardown { _ in hygiene.fulfill() }
    await fulfillment(of: [hygiene], timeout: 1)
    XCTAssertTrue(child.testingRetained)
    XCTAssertEqual(child.terminal, .unknown(.deadline))
    let replacement = owner(.trueUtility, directory)
    let refused = terminalExpectation(replacement)
    replacement.retire()
    await fulfillment(of: [refused], timeout: 1)
    XCTAssertEqual(replacement.terminal, .unknown(.admissionBlocked))
    XCTAssertEqual(counts.snapshot.1, 1)
  }

  func testRevokedCapturedStartupCompletesFailureOnceDespiteCleanRetirement() async throws {
    let directory = try cwd()
    defer { try? FileManager.default.removeItem(at: directory) }
    let counts = Counts()
    var hooks = OwnedChildRetirement.Hooks()
    hooks.beforeChannelSetup = { counts.revokeCapturedChild() }
    let child = OwnedChildRetirement(
      runningFixture: .cat, privateWorkingDirectory: directory, hooks: hooks)
    counts.lock.withLock { counts.capturedChild = child }
    defer { counts.lock.withLock { counts.capturedChild = nil } }
    let done = terminalExpectation(child)
    let ready = expectation(description: "captured startup resolves even when retirement is clean")
    ready.assertForOverFulfill = true
    child.start(
      startDeadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 5_000_000_000
    ) { result in
      if case .success = result { XCTFail("Revoked setup published running") }
      ready.fulfill()
    }
    await fulfillment(of: [ready, done], timeout: 2)
    assertClean(child)
  }

  func testRunningHeldActualChannelCloseStopsAtOneAbsoluteDeadline() async throws {
    let directory = try cwd()
    defer { try? FileManager.default.removeItem(at: directory) }
    let gate = Switch()
    let release = DispatchSemaphore(value: 0)
    let counts = Counts()
    var hooks = OwnedChildRetirement.Hooks()
    hooks.before = { _ in counts.effect() }
    hooks.afterClose = { if gate.value { release.wait() } }
    let child = OwnedChildRetirement(
      runningFixture: .cat, privateWorkingDirectory: directory, hooks: hooks)
    let channel = try await start(child)
    let done = expectation(description: "terminal lane does not join held MainActor close")
    child.observeTerminal { terminal in
      XCTAssertEqual(terminal, .unknown(.deadline))
      counts.terminal()
      release.signal()
      done.fulfill()
    }
    gate.arm()
    child.revoke()
    let deadline = child.core.lock.withLock { child.core.deadline }
    await fulfillment(of: [done], timeout: 1)
    child.revoke()
    XCTAssertEqual(child.core.lock.withLock { child.core.deadline }, deadline)
    XCTAssertFalse(channel.closureOutcome.bothClosed)
    XCTAssertEqual(channel.closureOutcome.read, .closed)
    XCTAssertEqual(channel.closureOutcome.write, .unknown)
    XCTAssertTrue(child.testingRetained)
    let effects = counts.snapshot.0
    channel.requestClose()
    XCTAssertEqual(counts.snapshot.0, effects)
    let hygiene = expectation(description: "actual fixture hygiene")
    child.testingPhysicalTeardown { _ in hygiene.fulfill() }
    await fulfillment(of: [hygiene], timeout: 1)
    XCTAssertEqual(child.terminal, .unknown(.deadline))
    XCTAssertTrue(child.testingRetained)
    XCTAssertEqual(counts.snapshot.1, 1)
  }

  func testRunningActualChannelCloseFailureNoSecondCloseRetryOrLateClean() async throws {
    let directory = try cwd()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fault = Switch()
    let counts = Counts()
    var hooks = OwnedChildRetirement.Hooks()
    hooks.closeFault = {
      if fault.value {
        counts.closeAttempt()
        return true
      }
      return false
    }
    let child = OwnedChildRetirement(
      runningFixture: .cat, privateWorkingDirectory: directory, hooks: hooks)
    let channel = try await start(child)
    let done = terminalExpectation(child, counts: counts)
    fault.arm()
    child.revoke()
    let deadline = child.core.lock.withLock { child.core.deadline }
    await fulfillment(of: [done], timeout: 1)
    XCTAssertEqual(child.terminal, .unknown(.close))
    XCTAssertEqual(channel.closureOutcome.read, .unknown)
    XCTAssertEqual(channel.closureOutcome.write, .unknown)
    XCTAssertEqual(counts.snapshot.2, 1)
    channel.requestClose()
    child.revoke()
    XCTAssertEqual(child.core.lock.withLock { child.core.deadline }, deadline)
    XCTAssertEqual(counts.snapshot.2, 1)
    let hygiene = expectation(description: "failed-close fixture hygiene")
    child.testingPhysicalTeardown { _ in hygiene.fulfill() }
    await fulfillment(of: [hygiene], timeout: 1)
    XCTAssertTrue(child.testingRetained)
    XCTAssertEqual(child.terminal, .unknown(.close))
    XCTAssertEqual(counts.snapshot.1, 1)
  }
  private func assertClean(_ owner: OwnedChildRetirement) {
    XCTAssertEqual(
      owner.terminal,
      .clean(.init(checkedDescriptorCloses: 6, childReaped: true, childExitStatus: 0)))
    XCTAssertTrue(owner.testingChildExists)
    XCTAssertTrue(owner.testingReaped)
    XCTAssertEqual(owner.testingDescriptorCount, 0)
    XCTAssertFalse(owner.testingRetained)
  }

  func testTrueActualReapAndSixCheckedClosesSoleInvocation() async throws {
    let directory = try cwd()
    defer { try? FileManager.default.removeItem(at: directory) }
    let counts = Counts()
    var hooks = OwnedChildRetirement.Hooks()
    hooks.before = { _ in counts.effect() }
    let child = owner(.trueUtility, directory, hooks: hooks)
    let done = terminalExpectation(child, counts: counts)
    child.retire()
    child.retire()
    await fulfillment(of: [done], timeout: budgetSeconds)
    assertClean(child)
    let before = counts.snapshot
    child.retire()
    XCTAssertEqual(counts.snapshot.0, before.0)
    XCTAssertEqual(counts.snapshot.1, 1)
  }

  func testCatActualStdinEOFThenWaitpidAndCheckedCloses() async throws {
    let directory = try cwd()
    defer { try? FileManager.default.removeItem(at: directory) }
    let child = owner(.cat, directory)
    let done = terminalExpectation(child)
    child.retire()
    await fulfillment(of: [done], timeout: budgetSeconds)
    assertClean(child)
  }

  func testTrueAlreadyExitedUnreapedNativeChild() async throws {
    let directory = try cwd()
    defer { try? FileManager.default.removeItem(at: directory) }
    let exited = expectation(description: "kernel observed exited without reaping")
    var hooks = OwnedChildRetirement.Hooks()
    hooks.afterSpawn = { actualChild in
      var information = siginfo_t()
      // A genuine blocking native observation on the operation lane, not a forged PID/proof.
      let result = waitid(P_PID, id_t(actualChild), &information, WEXITED | WNOWAIT)
      XCTAssertEqual(result, 0)
      XCTAssertEqual(information.si_pid, actualChild)
      exited.fulfill()
    }
    let child = owner(.trueUtility, directory, hooks: hooks)
    let done = terminalExpectation(child)
    child.retire()
    await fulfillment(of: [exited, done], timeout: budgetSeconds)
    assertClean(child)
  }

  func testHeldRealLaneIndependentExpiryFacadeLossNoLateCleanOrReplacement() async throws {
    let directory = try cwd()
    defer { try? FileManager.default.removeItem(at: directory) }
    let counts = Counts()
    let held = expectation(description: "real spawned child lane held")
    let release = DispatchSemaphore(value: 0)
    var hooks = OwnedChildRetirement.Hooks()
    hooks.before = { effect in
      counts.effect()
      if case .close = effect {
        held.fulfill()
        release.wait()
      }
    }
    let start = DispatchTime.now().uptimeNanoseconds
    var facade: OwnedChildRetirement? = owner(
      .cat, directory, hooks: hooks,
      remaining: cleanupBudgetNanoseconds / 2)
    weak var weakFacade = facade
    let rooted = facade!.testingRootWitness
    let done = terminalExpectation(facade!, counts: counts)
    facade!.retire()
    await fulfillment(of: [held, done], timeout: budgetSeconds)
    XCTAssertLessThan(DispatchTime.now().uptimeNanoseconds - start, cleanupBudgetNanoseconds)
    XCTAssertEqual(facade!.terminal, .unknown(.deadline))
    XCTAssertTrue(facade!.testingChildExists)
    XCTAssertFalse(facade!.testingReaped)
    XCTAssertEqual(facade!.testingDescriptorCount, 6)
    let effects = counts.snapshot.0
    facade!.retire()
    XCTAssertEqual(counts.snapshot.0, effects)
    XCTAssertTrue(rooted())
    // Capture hygiene before dropping the facade; the production root owns the actual core.
    let hygiene = expectation(description: "separate physical teardown")
    facade!.testingPhysicalTeardown { allWereOpen in
      XCTAssertTrue(allWereOpen)
      hygiene.fulfill()
    }
    facade = nil
    XCTAssertNil(weakFacade)
    XCTAssertTrue(rooted())
    release.signal()
    await fulfillment(of: [hygiene], timeout: budgetSeconds)
    XCTAssertTrue(rooted())
    XCTAssertEqual(counts.snapshot.0, effects)
    XCTAssertEqual(counts.snapshot.1, 1)
    let replacement = owner(.trueUtility, directory)
    let refused = terminalExpectation(replacement)
    replacement.retire()
    await fulfillment(of: [refused], timeout: budgetSeconds)
    XCTAssertEqual(replacement.terminal, .unknown(.admissionBlocked))
    XCTAssertFalse(replacement.testingChildExists)
    XCTAssertEqual(replacement.testingDescriptorCount, 0)
  }

  func testPartialSetupActualPipeRetentionNoRetry() async throws {
    let directory = try cwd()
    defer { try? FileManager.default.removeItem(at: directory) }
    let counts = Counts()
    var hooks = OwnedChildRetirement.Hooks()
    hooks.before = { _ in counts.effect() }
    hooks.afterPipeFault = { true }
    let child = owner(.trueUtility, directory, hooks: hooks)
    let done = terminalExpectation(child, counts: counts)
    child.retire()
    await fulfillment(of: [done], timeout: budgetSeconds)
    XCTAssertEqual(child.terminal, .unknown(.setup))
    XCTAssertEqual(child.testingDescriptorCount, 2)
    XCTAssertFalse(child.testingChildExists)
    XCTAssertTrue(child.testingRetained)
    let before = counts.snapshot.0
    child.retire()
    XCTAssertEqual(counts.snapshot.0, before)
    let hygiene = expectation(description: "physical pipe teardown")
    child.testingPhysicalTeardown { allWereOpen in
      XCTAssertTrue(allWereOpen)
      hygiene.fulfill()
    }
    await fulfillment(of: [hygiene], timeout: budgetSeconds)
    XCTAssertTrue(child.testingRetained)
    XCTAssertEqual(child.terminal, .unknown(.setup))
  }

  func testActualCloseEBADFLeavesAllOwnedFDsAndNoRetry() async throws {
    let directory = try cwd()
    defer { try? FileManager.default.removeItem(at: directory) }
    let counts = Counts()
    var hooks = OwnedChildRetirement.Hooks()
    hooks.closeFault = {
      counts.closeAttempt()
      return true
    }
    let child = owner(.cat, directory, hooks: hooks)
    let done = terminalExpectation(child, counts: counts)
    child.retire()
    await fulfillment(of: [done], timeout: budgetSeconds)
    XCTAssertEqual(child.terminal, .unknown(.close))
    XCTAssertTrue(child.testingChildExists)
    XCTAssertEqual(child.testingDescriptorCount, 6)
    XCTAssertFalse(child.testingReaped)
    XCTAssertTrue(child.testingRetained)
    child.retire()
    XCTAssertEqual(counts.snapshot.2, 1)
    let hygiene = expectation(description: "physical child teardown")
    child.testingPhysicalTeardown { allWereOpen in
      XCTAssertTrue(allWereOpen)
      hygiene.fulfill()
    }
    await fulfillment(of: [hygiene], timeout: budgetSeconds)
    XCTAssertTrue(child.testingRetained)
    XCTAssertEqual(child.terminal, .unknown(.close))
    XCTAssertEqual(counts.snapshot.1, 1)
  }

  func testAlreadyExpiredDeadlineAdmitsNoNativeEffect() async throws {
    let directory = try cwd()
    defer { try? FileManager.default.removeItem(at: directory) }
    let child = OwnedChildRetirement(
      fixture: .trueUtility, privateWorkingDirectory: directory,
      deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds)
    let done = terminalExpectation(child)
    child.retire()
    await fulfillment(of: [done], timeout: budgetSeconds)
    XCTAssertEqual(child.terminal, .unknown(.deadline))
    XCTAssertFalse(child.testingChildExists)
    XCTAssertEqual(child.testingDescriptorCount, 0)
  }

  func testBackupAlreadyExpiredDeadlineOwnsNamespaceWithoutDuplicatingDescriptors() async throws {
    let repository = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let directory = repository.appendingPathComponent(
      ".build/owned-backup-deadline-" + UUID().uuidString.lowercased(), isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: directory) }
    let namespace = try XCTUnwrap(
      TopologyOwnedFixtures(root: directory, runID: UUID().uuidString.lowercased()))
    let child = OwnedChildRetirement(
      backup: .init(
        namespace: namespace, interpreter: URL(fileURLWithPath: "/usr/bin/python3"),
        script: URL(fileURLWithPath: "/unopened-agent.py"), reference: "unopened-reference"),
      deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds)
    let done = terminalExpectation(child)
    child.retire()
    await fulfillment(of: [done], timeout: budgetSeconds)
    XCTAssertEqual(child.terminal, .unknown(.deadline))
    XCTAssertFalse(child.testingChildExists)
    XCTAssertEqual(child.testingDescriptorCount, 0)
    XCTAssertTrue(child.testingRetained)
    XCTAssertGreaterThanOrEqual(fcntl(namespace.descriptor, F_GETFD), 0)
    XCTAssertGreaterThanOrEqual(fcntl(namespace.metadataParentDescriptor, F_GETFD), 0)
    XCTAssertFalse(namespace.permitsNamespaceMutation)
    XCTAssertFalse(namespace.cleanup())
    XCTAssertFalse(namespace.create("M"))
    XCTAssertFalse(namespace.prepareLinks(["M"]))
    var entry = stat()
    XCTAssertEqual(
      fstatat(namespace.metadataParentDescriptor, namespace.runID, &entry, AT_SYMLINK_NOFOLLOW), 0)
  }
}
