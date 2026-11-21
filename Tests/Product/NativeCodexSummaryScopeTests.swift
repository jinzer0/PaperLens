import Darwin
import Foundation
import XCTest
import ProviderRequest
@testable import PaperLensProduct

/// Synthetic protocol responses under the actual native process/namespace owner.
/// These tests never import an SDK or contact a provider.
@MainActor final class NativeCodexSummaryScopeTests: XCTestCase {
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
        agentScript: resources.appendingPathComponent("agent.py"),
        interpreter: SyntheticPython.metadataInterpreter))
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
    let launcher = try SyntheticPython.override?.path ?? XCTUnwrap(
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

  private func controlWorkerScript(holdResult: Bool, remoteTimeout: Bool = false,
    syntheticLogin: Bool = false) -> String {
    """
    import array, json, os, select, socket, struct, subprocess, sys, time
    end = time.monotonic() + 3
    run_id = os.environ['PAPERLENS_BROKER_RUN_ID']
    wrong_order = False
    product_login = True
    retirement = True
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
    def send(sock, op, **fields):
        body = json.dumps(dict(v=2, runID=run_id, op=op, **fields)).encode()
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
            elif \(syntheticLogin ? "True" : "False") and method == 'product.loginStart':
                identity = dict(stageID=params['stageID'], intentID=params['intentID'])
                fd = os.open('codex/auth.json', os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
                with os.fdopen(fd, 'w') as auth:
                    auth.write('{}')
                result = dict(identity, instructions=dict(mode='browser', authUrl='https://example.invalid/login'))
            elif \(syntheticLogin ? "True" : "False") and method == 'product.loginObserve':
                assert params == identity
                result = dict(identity, state='authenticated')
            elif \(syntheticLogin ? "True" : "False") and method == 'product.connectionTest':
                result = dict(identity, expectedSelector=params['expectedSelector'], state='usable', text='PAPERLENS_OK')
            elif \(syntheticLogin ? "True" : "False") and method == 'product.loginCancel':
                assert params == identity
                result = dict(identity, accepted=True)
            elif method == 'product.librarySummary':
                mark('summary-received')
                if \(holdResult ? "True" : "False"):
                    gate('release-result')
                result = dict(params)
                result.pop('requestJSON')
                result['resultJSON'] = json.dumps(dict(summary=dict(text='Insufficient evidence', kind='insufficient', evidenceIndices=[]), insufficiency='noEvidence'))
            else:
                raise AssertionError('forbidden synthetic product method: ' + method)
            if method == 'product.librarySummary' and \(remoteTimeout ? "True" : "False"):
                response = dict(kind='error', id=request['id'], code='timeout')
            else:
                response = dict(kind='result', id=request['id'], result=result)
            body = json.dumps(response).encode()
            frame = struct.pack('!I', len(body)) + body
            while frame:
                count = os.write(1, frame)
                assert count > 0
                frame = frame[count:]
            if retirement and method in ('product.librarySummary', 'product.loginCancel'):
                return
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
            if retirement:
                message = receive(broker, 'revoke', ('retirementID',))
                send(broker, 'preLaunchRetired', retirementID=message['retirementID'])
            else:
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
                    if retirement:
                        message = receive(lifecycle, 'revoke', ('retirementID',))
                        identity = message['retirementID']
                        mark('retirement-received')
                        gate('release-retirement')
                        message = receive(lifecycle, 'reapBroker', ('retirementID',))
                        assert message['retirementID'] == identity
                        status = broker.wait(timeout=3)
                        assert status == 0
                        listener.close()
                        os.unlink('b')
                        send(lifecycle, 'brokerReaped', retirementID=identity, waitStatus=0)
                        while True:
                            time.sleep(1)
                    else:
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


  private final class Completion { var returned = false }

  private struct RejectNetwork: NativeConnectionTestTransport {
    func probe(key: String, configuration: NativeOpenAIConfiguration,
      request: AuthorizedProviderRequest, authority: ProviderRequest) async throws -> NativeProbeResponse {
      XCTFail("Synthetic Codex connection attempted a network call")
      throw APIKeyConnectionError.authentication
    }
  }

  private func waitFor(_ condition: () -> Bool) async throws {
    for _ in 0..<200 {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw LibrarySummaryError.providerUnavailable
  }

  private func marker(_ name: String, directory: URL) -> URL {
    directory.appendingPathComponent("work/" + name)
  }

  private func waitForMarker(_ name: String, directory: URL) async throws {
    for _ in 0..<200 {
      if FileManager.default.fileExists(atPath: marker(name, directory: directory).path) { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("Synthetic worker did not reach " + name)
    throw LibrarySummaryError.providerUnavailable
  }

  private func parameters(paperID: UUID = UUID()) throws
    -> (ProviderRequest, AuthorizedProviderRequest, [String: Any]) {
    let authority = try ProviderRequest()
    let paper = paperID.uuidString.lowercased()
    let sources = RequestSources.librarySummary(outputLanguage: "en")
    let context = try TrustedRequestContext(authority: authority, sources: sources,
      identity: .init(paperID: paper, paperGeneration: 1,
        pdfSHA256: String(repeating: "a", count: 64),
        extractionRevision: UUID().uuidString.lowercased()))
    let request = try authority.buildRequest(sources: sources, context: context,
      requestID: UUID().uuidString.lowercased())
    let params: [String: Any] = ["requestID": request.wire.requestID, "paperID": paper,
      "paperGeneration": 1, "configGeneration": 1, "model": "fixture-model",
      "requestJSON": String(decoding: try authority.encodeRequest(request), as: UTF8.self)]
    return (authority, request, params)
  }

  func testResultWaitsForActualRetirementAndNamespaceRemoval() async throws {
    let (root, namespace, launch) = try workerFixture(script: controlWorkerScript(holdResult: false))
    defer { try? FileManager.default.removeItem(at: root) }
    let (authority, request, params) = try parameters()
    let scope = NativeCodexSummaryScope(launch: launch, paperID: UUID(), params: params)
    let completion = Completion()
    let task = Task { defer { completion.returned = true }; return try await scope.execute() }
    try await waitForMarker("retirement-received", directory: namespace.directoryURL)
    XCTAssertFalse(completion.returned, "A typed wire result is not physical producer closure")
    XCTAssertFalse(scope.clean)
    XCTAssertTrue(FileManager.default.fileExists(atPath: namespace.directoryURL.path))
    try Data().write(to: marker("release-retirement", directory: namespace.directoryURL))
    let bytes = try await task.value
    XCTAssertTrue(scope.clean)
    XCTAssertFalse(FileManager.default.fileExists(atPath: namespace.directoryURL.path))
    let result = try authority.wrapModelResult(bytes, request: request)
    XCTAssertEqual(result.operation, .librarySummary)
    XCTAssertEqual(result.requestID, request.wire.requestID)
  }

  func testOtherPaperPurgeKeepsBoundSummaryAndRejectsUnownedEntry() async throws {
    let (root, _, template) = try workerFixture(
      script: controlWorkerScript(holdResult: true, syntheticLogin: true))
    defer { try? FileManager.default.removeItem(at: root) }
    let database = try ProductDatabase.open(at: root.appendingPathComponent("database"))
    let configuration = try NativeOpenAIConfiguration(model: "fixture-model")
    let apiKey = NativeAPIKeyConnection(configuration: configuration,
      slots: try APIKeySlotStore(directory: root.appendingPathComponent("slots")),
      persistence: DatabaseAPIKeySelector(database: database, configuration: configuration),
      transport: RejectNetwork(), authority: try ProviderRequest())
    let loginRoot = root.appendingPathComponent("codex-scopes", isDirectory: true)
    var loginDirectory: URL?
    var summaryDirectory: URL?
    let codex = NativeCodexConnection(database: database, root: loginRoot, apiKey: apiKey) { namespace in
      guard namespace.prepareBackupExclusionFixture(
        agentScript: root.appendingPathComponent("resources/agent.py"),
        interpreter: SyntheticPython.metadataInterpreter) else { return nil }
      if namespace.directoryURL.deletingLastPathComponent().path == loginRoot.path {
        loginDirectory = namespace.directoryURL
      } else {
        summaryDirectory = namespace.directoryURL
      }
      return .testing(namespace: namespace, interpreter: template.interpreter, script: template.script)
    }
    let peer = IsolatedAgentLibraryPurge(unsupportedPaperRoot: root.appendingPathComponent("legacy"),
      summaryRoot: codex.summaryRoot)
    peer.bind(codex)
    let library = try await LocalLibraryLifecycle.open(database: database, agentPurge: peer)
    let pdf = root.appendingPathComponent("source.pdf")
    try Data("%PDF-1.7\nsynthetic deletion isolation\n%%EOF\n".utf8).write(to: pdf)
    let paper = try await library.importPDF(from: pdf)
    let other = try await library.importPDF(from: pdf)
    codex.connect(mode: "browser")
    try await waitFor { codex.phase == .signingIn }
    let login = try XCTUnwrap(loginDirectory)
    defer { codex.cancel() }
    codex.checkLogin()
    try await waitFor { codex.eligibleForEntry }
    let (authority, request, _) = try parameters(paperID: paper)
    let identity = LibrarySummaryIdentity(paperID: paper, generation: UUID(), requestPaperGeneration: 1,
      pdfSHA256: String(repeating: "a", count: 64), revision: UUID(),
      configurationGeneration: try database.providerConfiguration().generation, job: UUID(),
      attempt: UUID(), fence: UUID(), correlation: UUID(), input: UUID(), epoch: UUID())
    let summary = Task { try await codex.executeLibrarySummary(request, identity: identity, authority: authority) }
    try await waitFor { summaryDirectory != nil }
    let live = try XCTUnwrap(summaryDirectory)
    try await waitForMarker("summary-received", directory: live)
    do {
      try await library.delete(paperID: other)
      let records = try await library.list()
      XCTAssertEqual(records.map(\.id), [paper])
      XCTAssertEqual(records.first?.status, .ready)
    } catch {
      XCTFail("Purging a different paper refused a bound unrelated worker: \(error)")
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: live.path))
    let unknown = codex.summaryRoot.appendingPathComponent("unowned")
    try FileManager.default.createDirectory(at: unknown, withIntermediateDirectories: false)
    do {
      _ = try await codex.purgeSummaryPaper(paperID: other, deletionID: UUID())
      XCTFail("Purging acknowledged an unowned namespace")
    } catch { XCTAssertEqual(error as? LocalLibraryError, .producerClosureUnknown) }
    XCTAssertTrue(FileManager.default.fileExists(atPath: unknown.path))
    try FileManager.default.removeItem(at: unknown)
    let displaced = root.appendingPathComponent("displaced-summary")
    try FileManager.default.moveItem(at: live, to: displaced)
    try FileManager.default.createDirectory(at: live, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    do {
      _ = try await codex.purgeSummaryPaper(paperID: other, deletionID: UUID())
      XCTFail("Purging trusted a replacement reusing the owned directory name")
    } catch { XCTAssertEqual(error as? LocalLibraryError, .producerClosureUnknown) }
    try FileManager.default.removeItem(at: live)
    try FileManager.default.moveItem(at: displaced, to: live)
    try Data().write(to: marker("release-result", directory: live))
    try await waitForMarker("retirement-received", directory: live)
    try Data().write(to: marker("release-retirement", directory: live))
    let result = try await summary.value
    XCTAssertEqual(result.requestID, request.wire.requestID)
    codex.cancel()
    try await waitForMarker("retirement-received", directory: login)
    try Data().write(to: marker("release-retirement", directory: login))
    try await waitFor { codex.phase == .idle }
  }

  func testCancellationRejectsLateResultAndWaitsForActualRetirement() async throws {
    let (root, namespace, launch) = try workerFixture(script: controlWorkerScript(holdResult: true))
    defer { try? FileManager.default.removeItem(at: root) }
    let (_, _, params) = try parameters()
    let scope = NativeCodexSummaryScope(launch: launch, paperID: UUID(), params: params)
    let completion = Completion()
    let task = Task { defer { completion.returned = true }; return try await scope.execute() }
    try await waitForMarker("summary-received", directory: namespace.directoryURL)
    task.cancel()
    // A late synthetic result still arrives after cancellation was accepted.
    await Task.yield()
    try Data().write(to: marker("release-result", directory: namespace.directoryURL))
    try await waitForMarker("retirement-received", directory: namespace.directoryURL)
    XCTAssertFalse(completion.returned)
    XCTAssertFalse(scope.clean)
    try Data().write(to: marker("release-retirement", directory: namespace.directoryURL))
    do { _ = try await task.value; XCTFail("Cancelled execution must not return a late result") }
    catch { XCTAssertTrue(error is CancellationError) }
    XCTAssertTrue(scope.clean)
    XCTAssertFalse(FileManager.default.fileExists(atPath: namespace.directoryURL.path))
  }

  func testRemoteTimeoutIsPreservedOnlyAfterActualRetirementAndNamespaceRemoval() async throws {
    let (root, namespace, launch) = try workerFixture(
      script: controlWorkerScript(holdResult: false, remoteTimeout: true))
    defer { try? FileManager.default.removeItem(at: root) }
    let (_, _, params) = try parameters()
    let scope = NativeCodexSummaryScope(launch: launch, paperID: UUID(), params: params)
    let completion = Completion()
    let task = Task { defer { completion.returned = true }; return try await scope.execute() }
    try await waitForMarker("retirement-received", directory: namespace.directoryURL)
    XCTAssertFalse(completion.returned, "A remote error cannot substitute for physical retirement")
    XCTAssertFalse(scope.clean)
    XCTAssertTrue(FileManager.default.fileExists(atPath: namespace.directoryURL.path))
    try Data().write(to: marker("release-retirement", directory: namespace.directoryURL))
    do { _ = try await task.value; XCTFail("The remote failure must not become a result") }
    catch {
      XCTAssertEqual(error as? AgentRPCConnection.Failure, .remote("timeout"))
      XCTAssertEqual(LibrarySummaryFailure.classify(error), .timedOut)
    }
    XCTAssertTrue(scope.clean)
    XCTAssertFalse(FileManager.default.fileExists(atPath: namespace.directoryURL.path))
  }

  func testUnknownNamespaceCleanupRetainsDebtAndRefusesResult() async throws {
    let (root, namespace, launch) = try workerFixture(script: controlWorkerScript(holdResult: false))
    defer { try? FileManager.default.removeItem(at: root) }
    let (_, _, params) = try parameters()
    let scope = NativeCodexSummaryScope(launch: launch, paperID: UUID(), params: params)
    let external = root.appendingPathComponent("external-fixture.txt")
    let bytes = Data("preserve independently owned file".utf8)
    try bytes.write(to: external)
    let linked = namespace.directoryURL.appendingPathComponent("work/external-link")
    let task = Task { try await scope.execute() }
    try await waitForMarker("retirement-received", directory: namespace.directoryURL)
    try FileManager.default.linkItem(at: external, to: linked)
    try Data().write(to: marker("release-retirement", directory: namespace.directoryURL))
    do { _ = try await task.value; XCTFail("Unknown namespace cleanup must not return a result") }
    catch { XCTAssertEqual(error as? LibrarySummaryError, .cleanupUnavailable) }
    XCTAssertFalse(scope.clean)
    XCTAssertTrue(FileManager.default.fileExists(atPath: namespace.directoryURL.path))
    XCTAssertEqual(try Data(contentsOf: linked), bytes)
    XCTAssertEqual(try Data(contentsOf: external), bytes)
  }

}
