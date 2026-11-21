import Combine
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
    syntheticLogin: Bool = false, holdProbe: Bool = false, closeAfterProbe: Bool = false) -> String {
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
                if params['mode'] == 'browser':
                    instructions = dict(mode='browser', authUrl='https://example.invalid/login')
                else:
                    instructions = dict(mode='device', verificationUrl='https://example.invalid/device', userCode='TEST-CODE')
                result = dict(identity, instructions=instructions)
            elif \(syntheticLogin ? "True" : "False") and method == 'product.loginObserve':
                assert params == identity
                result = dict(identity, state='authenticated')
            elif \(syntheticLogin ? "True" : "False") and method == 'product.connectionTest':
                if \(holdProbe ? "True" : "False"):
                    mark('probe-received')
                    gate('release-probe')
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
            if \(closeAfterProbe ? "True" : "False") and method == 'product.connectionTest':
                gate('close-product-output')
                os.close(1)
                return
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

  func testClosingWorkspaceSettingsRejectsLateProbeButKeepsCommittedLogin() async throws {
    let (root, _, template) = try workerFixture(
      script: controlWorkerScript(holdResult: false, syntheticLogin: true, holdProbe: true))
    defer { try? FileManager.default.removeItem(at: root) }
    let database = try ProductDatabase.open(at: root.appendingPathComponent("database"))
    let configuration = try NativeOpenAIConfiguration(model: "fixture-model")
    let slots = try APIKeySlotStore(directory: root.appendingPathComponent("slots"))
    let oldSlot = try slots.create(key: "synthetic-last-good")
    let selected = try database.compareAndSwapProviderConfiguration(expected: database.providerConfiguration(),
      replacementKind: .openAIAPIKey, replacementSlotID: oldSlot, replacementModel: configuration.model)
    let apiKey = NativeAPIKeyConnection(configuration: configuration, slots: slots,
      persistence: DatabaseAPIKeySelector(database: database, configuration: configuration),
      transport: RejectNetwork(), authority: try ProviderRequest())
    apiKey.restore()
    var prepared: URL?
    let codex = NativeCodexConnection(database: database, root: root.appendingPathComponent("codex-scopes"),
      apiKey: apiKey) { namespace in
        guard namespace.prepareBackupExclusionFixture(
          agentScript: root.appendingPathComponent("resources/agent.py"),
          interpreter: SyntheticPython.metadataInterpreter) else { return nil }
        prepared = namespace.directoryURL
        return .testing(namespace: namespace, interpreter: template.interpreter, script: template.script)
      }
    let library = try await LocalLibraryLifecycle.open(database: database)
    let workspace = try ProductWorkspace(database: database, lifecycle: library, connection: apiKey, codex: codex)

    workspace.sheet = .settings
    let closeDuringStartup = codex.$phase.dropFirst().sink { phase in
      if phase == .starting { workspace.sheet = nil }
    }
    codex.connect(mode: "browser")
    closeDuringStartup.cancel()
    let unstarted = try XCTUnwrap(prepared)
    XCTAssertNil(workspace.sheet)
    XCTAssertEqual(codex.phase, .idle)
    XCTAssertFalse(FileManager.default.fileExists(atPath: unstarted.path))
    XCTAssertEqual(try database.providerConfiguration(), selected)
    workspace.presentationDidDismiss()

    workspace.sheet = .settings
    codex.connect(mode: "browser")
    let firstDirectory = try XCTUnwrap(prepared)
    XCTAssertNotEqual(firstDirectory, unstarted)
    try await waitFor { codex.phase == .signingIn }
    codex.checkLogin()
    try await waitForMarker("probe-received", directory: firstDirectory)
    XCTAssertEqual(codex.phase, .probing)
    workspace.sheet = nil
    XCTAssertEqual(codex.phase, .retiring)
    XCTAssertTrue(workspace.settings.eligibleForEntry)
    try Data().write(to: marker("release-probe", directory: firstDirectory))
    try await waitForMarker("retirement-received", directory: firstDirectory)
    try Data().write(to: marker("release-retirement", directory: firstDirectory))
    try await waitFor { codex.phase == .idle }
    XCTAssertTrue(codex.offersRetry)
    XCTAssertEqual(try database.providerConfiguration(), selected)
    XCTAssertEqual(try slots.validatedSlotIDs(), [oldSlot])
    XCTAssertFalse(FileManager.default.fileExists(atPath: firstDirectory.path))

    workspace.presentationDidDismiss()
    workspace.sheet = .settings
    // Close during the synchronous notifications after CAS but before `.connected`.
    let closing = apiKey.$activeSelection.dropFirst().sink { selection in
      if selection == nil { workspace.dismissSheet() }
    }
    defer { closing.cancel() }
    codex.connect(mode: "browser")
    let retryDirectory = try XCTUnwrap(prepared)
    XCTAssertNotEqual(retryDirectory, firstDirectory)
    try await waitFor { codex.phase == .signingIn }
    codex.checkLogin()
    try await waitForMarker("probe-received", directory: retryDirectory)
    try Data().write(to: marker("release-probe", directory: retryDirectory))
    try await waitFor { codex.eligibleForEntry }
    XCTAssertNil(workspace.sheet)
    let committed = try database.providerConfiguration()
    XCTAssertEqual(committed.kind, .codexChatGPT)
    XCTAssertEqual(committed.generation, selected.generation + 1)

    workspace.sheet = .settings
    workspace.sheet = nil
    XCTAssertTrue(codex.eligibleForEntry)
    XCTAssertEqual(try database.providerConfiguration(), committed)
    codex.cancel()
    try await waitForMarker("retirement-received", directory: retryDirectory)
    try Data().write(to: marker("release-retirement", directory: retryDirectory))
    try await waitFor { codex.phase == .idle }
  }

  func testReloginPreservesLastGoodUntilCurrentProbeCommitsAndOldOwnerRetires() async throws {
    let (root, _, template) = try workerFixture(
      script: controlWorkerScript(holdResult: false, syntheticLogin: true, holdProbe: true))
    defer { try? FileManager.default.removeItem(at: root) }
    let database = try ProductDatabase.open(at: root.appendingPathComponent("database"))
    let configuration = try NativeOpenAIConfiguration(model: "fixture-model")
    let apiKey = NativeAPIKeyConnection(configuration: configuration,
      slots: try APIKeySlotStore(directory: root.appendingPathComponent("slots")),
      persistence: DatabaseAPIKeySelector(database: database, configuration: configuration),
      transport: RejectNetwork(), authority: try ProviderRequest())
    apiKey.restore()
    var prepared: [URL] = []
    var summaryDirectory: URL?
    let loginRoot = root.appendingPathComponent("codex-scopes", isDirectory: true)
    let codex = NativeCodexConnection(database: database, root: loginRoot,
      apiKey: apiKey) { namespace in
        guard namespace.prepareBackupExclusionFixture(
          agentScript: root.appendingPathComponent("resources/agent.py"),
          interpreter: SyntheticPython.metadataInterpreter) else { return nil }
        if namespace.directoryURL.deletingLastPathComponent().path == loginRoot.path {
          prepared.append(namespace.directoryURL)
        } else {
          summaryDirectory = namespace.directoryURL
        }
        return .testing(namespace: namespace, interpreter: template.interpreter, script: template.script)
      }
    defer { codex.cancel() }
    let beforeLogin = try database.providerConfiguration()
    codex.connect(mode: "browser")
    let initial = try XCTUnwrap(prepared.last)
    try await waitFor { codex.phase == .signingIn }
    codex.checkLogin()
    try await waitForMarker("probe-received", directory: initial)
    try Data().write(to: marker("release-probe", directory: initial))
    try await waitFor { codex.eligibleForEntry }
    let lastGood = try database.providerConfiguration()
    XCTAssertEqual(lastGood.kind, .codexChatGPT)
    XCTAssertEqual(lastGood.generation, beforeLogin.generation + 1)
    XCTAssertTrue(codex.canStart)

    codex.connect(mode: "device")
    let cancelled = try XCTUnwrap(prepared.last)
    XCTAssertNotEqual(cancelled, initial)
    XCTAssertEqual(try database.providerConfiguration(), lastGood)
    XCTAssertTrue(codex.eligibleForEntry)
    try await waitFor { codex.phase == .signingIn }
    XCTAssertEqual(codex.instructions?.userCode, "TEST-CODE")
    codex.checkLogin()
    try await waitForMarker("probe-received", directory: cancelled)
    XCTAssertTrue(codex.eligibleForEntry)
    codex.cancel()
    XCTAssertEqual(try database.providerConfiguration(), lastGood)
    XCTAssertTrue(codex.eligibleForEntry)
    try Data().write(to: marker("release-probe", directory: cancelled))
    try await waitForMarker("retirement-received", directory: cancelled)
    XCTAssertFalse(codex.canStart)
    try Data().write(to: marker("release-retirement", directory: cancelled))
    try await waitFor { codex.phase == .connected && codex.canStart }
    XCTAssertTrue(codex.offersRetry)
    XCTAssertEqual(try database.providerConfiguration(), lastGood)
    XCTAssertTrue(FileManager.default.fileExists(atPath: initial.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: cancelled.path))

    codex.connect(mode: "browser")
    let retry = try XCTUnwrap(prepared.last)
    XCTAssertEqual(prepared.count, 3)
    XCTAssertNotEqual(retry, initial)
    XCTAssertNotEqual(retry, cancelled)
    try await waitFor { codex.phase == .signingIn }
    XCTAssertTrue(codex.eligibleForEntry)
    codex.checkLogin()
    try await waitForMarker("probe-received", directory: retry)
    XCTAssertEqual(try database.providerConfiguration(), lastGood)
    let paperID = UUID()
    let (authority, request, _) = try parameters(paperID: paperID)
    let identity = LibrarySummaryIdentity(paperID: paperID, generation: UUID(), requestPaperGeneration: 1,
      pdfSHA256: String(repeating: "a", count: 64), revision: UUID(),
      configurationGeneration: lastGood.generation, job: UUID(), attempt: UUID(), fence: UUID(),
      correlation: UUID(), input: UUID(), epoch: UUID())
    let summary = Task { try await codex.executeLibrarySummary(request, identity: identity, authority: authority) }
    defer { summary.cancel() }
    try await waitFor { summaryDirectory != nil }
    let summaryScope = try XCTUnwrap(summaryDirectory)
    try await waitForMarker("retirement-received", directory: summaryScope)
    try Data().write(to: marker("release-probe", directory: retry))
    try await waitForMarker("retirement-received", directory: initial)
    let winner = try database.providerConfiguration()
    XCTAssertEqual(winner.kind, .codexChatGPT)
    XCTAssertEqual(winner.generation, lastGood.generation + 1)
    XCTAssertNotEqual(winner.slotID, lastGood.slotID)
    XCTAssertEqual(codex.phase, .connected)
    XCTAssertTrue(codex.eligibleForEntry)
    XCTAssertFalse(codex.canStart)
    XCTAssertTrue(FileManager.default.fileExists(atPath: initial.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: summaryScope.path))
    try Data().write(to: marker("release-retirement", directory: summaryScope))
    do {
      _ = try await summary.value
      XCTFail("Old-generation result must not publish through the new connection")
    } catch { XCTAssertEqual(error as? LibrarySummaryError, .staleIdentity) }
    XCTAssertFalse(FileManager.default.fileExists(atPath: summaryScope.path))
    try Data().write(to: marker("release-retirement", directory: initial))
    try await waitFor { codex.canStart }
    XCTAssertFalse(FileManager.default.fileExists(atPath: initial.path))
    XCTAssertEqual(try database.providerConfiguration(), winner)
    XCTAssertTrue(codex.eligibleForEntry)

    codex.cancel()
    try await waitForMarker("retirement-received", directory: retry)
    try Data().write(to: marker("release-retirement", directory: retry))
    try await waitFor { codex.phase == .idle }
    XCTAssertFalse(codex.eligibleForEntry)
    XCTAssertNil(try database.providerConfiguration().slotID)
    XCTAssertFalse(FileManager.default.fileExists(atPath: retry.path))
  }

  func testUnexpectedLoginChannelClosureRetainsCommittedSelectionForExplicitReconnect() async throws {
    let (root, _, template) = try workerFixture(script: controlWorkerScript(
      holdResult: false, syntheticLogin: true, closeAfterProbe: true))
    defer { try? FileManager.default.removeItem(at: root) }
    let database = try ProductDatabase.open(at: root.appendingPathComponent("database"))
    let configuration = try NativeOpenAIConfiguration(model: "fixture-model")
    let slots = try APIKeySlotStore(directory: root.appendingPathComponent("slots"))
    let apiKey = NativeAPIKeyConnection(configuration: configuration, slots: slots,
      persistence: DatabaseAPIKeySelector(database: database, configuration: configuration),
      transport: RejectNetwork(), authority: try ProviderRequest())
    var prepared: [URL] = []
    let codex = NativeCodexConnection(database: database, root: root.appendingPathComponent("login"),
      apiKey: apiKey) { namespace in
        guard namespace.prepareBackupExclusionFixture(
          agentScript: root.appendingPathComponent("resources/agent.py"),
          interpreter: SyntheticPython.metadataInterpreter) else { return nil }
        prepared.append(namespace.directoryURL)
        return .testing(namespace: namespace, interpreter: template.interpreter, script: template.script)
      }
    defer { codex.cancel() }
    codex.connect(mode: "browser")
    let login = try XCTUnwrap(prepared.last)
    try await waitFor { codex.phase == .signingIn }
    codex.checkLogin()
    try await waitFor { codex.eligibleForEntry }
    let selected = try database.providerConfiguration()
    XCTAssertEqual(selected.kind, .codexChatGPT)
    try Data().write(to: marker("close-product-output", directory: login))
    try await waitForMarker("retirement-received", directory: login)
    XCTAssertFalse(codex.eligibleForEntry)
    XCTAssertFalse(codex.canStart)
    XCTAssertEqual(try database.providerConfiguration(), selected)
    try Data().write(to: marker("release-retirement", directory: login))
    try await waitFor { codex.phase == .idle && codex.canStart }

    XCTAssertFalse(FileManager.default.fileExists(atPath: login.path))
    XCTAssertEqual(try database.providerConfiguration(), selected)
    XCTAssertTrue(codex.offersRetry)
    XCTAssertFalse(codex.eligibleForEntry)
    XCTAssertEqual(prepared, [login], "Connection loss must not replay login or the probe")
    let settings = ProviderSettingsService(connection: apiKey, codex: codex)
    XCTAssertEqual(settings.currentProviderLabel, "ChatGPT")
    XCTAssertFalse(settings.eligibleForEntry)
  }

  func testSwitchingProviderPreservesLastGoodAndRetiresOnlySupersededResources() async throws {
    let (root, _, template) = try workerFixture(
      script: controlWorkerScript(holdResult: false, syntheticLogin: true, holdProbe: true))
    defer { try? FileManager.default.removeItem(at: root) }
    let database = try ProductDatabase.open(at: root.appendingPathComponent("database"))
    let configuration = try NativeOpenAIConfiguration(model: "fixture-model")
    let slots = try APIKeySlotStore(directory: root.appendingPathComponent("slots"))
    let selector = DatabaseAPIKeySelector(database: database, configuration: configuration)
    let transport = SettingsSuspendedTransport()
    let apiKey = NativeAPIKeyConnection(configuration: configuration, slots: slots,
      persistence: selector, transport: transport, authority: try ProviderRequest())
    var prepared: [URL] = []
    let codex = NativeCodexConnection(database: database, root: root.appendingPathComponent("login"),
      apiKey: apiKey) { namespace in
        guard namespace.prepareBackupExclusionFixture(
          agentScript: root.appendingPathComponent("resources/agent.py"),
          interpreter: SyntheticPython.metadataInterpreter) else { return nil }
        prepared.append(namespace.directoryURL)
        return .testing(namespace: namespace, interpreter: template.interpreter, script: template.script)
      }
    defer { codex.cancel() }
    let settings = ProviderSettingsService(connection: apiKey, codex: codex)
    settings.restore()
    codex.connect(mode: "browser")
    let first = try XCTUnwrap(prepared.last)
    try await waitFor { codex.phase == .signingIn }
    codex.checkLogin()
    try await waitForMarker("probe-received", directory: first)
    try Data().write(to: marker("release-probe", directory: first))
    try await waitFor { codex.eligibleForEntry }
    let lastGood = try database.providerConfiguration()
    settings.restore()
    XCTAssertNil(try selector.currentSelection())
    XCTAssertEqual(settings.phase, .idle)
    XCTAssertEqual(settings.currentProviderLabel, "ChatGPT")
    XCTAssertTrue(settings.eligibleForEntry)
    XCTAssertFalse(settings.candidatesBlocked)

    settings.reconnect(key: "fixture-invalid")
    try await waitFor { transport.count == 1 }
    XCTAssertTrue(settings.eligibleForEntry)
    XCTAssertFalse(codex.canStart)
    transport.fail(0)
    try await waitFor { settings.phase == .failed(.authentication) }
    XCTAssertEqual(try database.providerConfiguration(), lastGood)
    XCTAssertTrue(settings.eligibleForEntry)
    XCTAssertTrue(try slots.validatedSlotIDs().isEmpty)

    settings.reconnect(key: "fixture-cancelled")
    try await waitFor { transport.count == 2 }
    settings.cancelUncommittedConnections()
    try transport.complete(1)
    try await waitFor { codex.canStart }
    XCTAssertEqual(settings.phase, .failed(.cancelled))
    XCTAssertEqual(try database.providerConfiguration(), lastGood)
    XCTAssertTrue(settings.eligibleForEntry)
    XCTAssertTrue(try slots.validatedSlotIDs().isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: marker("retirement-received", directory: first).path))

    settings.reconnect(key: "fixture-validated")
    try await waitFor { transport.count == 3 }
    XCTAssertEqual(try database.providerConfiguration(), lastGood)
    XCTAssertTrue(codex.eligibleForEntry)
    try transport.complete(2)
    try await waitForMarker("retirement-received", directory: first)
    let winner = try database.providerConfiguration()
    XCTAssertEqual(winner.kind, .openAIAPIKey)
    XCTAssertEqual(winner.generation, lastGood.generation + 1)
    XCTAssertEqual(settings.currentProviderLabel, "OpenAI API")
    XCTAssertTrue(settings.eligibleForEntry)
    XCTAssertTrue(settings.candidatesBlocked)
    XCTAssertFalse(codex.eligibleForEntry)
    XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
    try Data().write(to: marker("release-retirement", directory: first))
    try await waitFor { codex.phase == .idle && codex.canStart }
    XCTAssertEqual(try database.providerConfiguration(), winner)
    XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))

    codex.connect(mode: "device")
    let second = try XCTUnwrap(prepared.last)
    XCTAssertNotEqual(first, second)
    try await waitFor { codex.phase == .signingIn }
    XCTAssertEqual(settings.currentProviderLabel, "OpenAI API")
    let lease = try apiKey.acquireLease()
    XCTAssertTrue(try apiKey.mayPublish(lease))
    codex.checkLogin()
    try await waitForMarker("probe-received", directory: second)
    XCTAssertEqual(try database.providerConfiguration(), winner)
    XCTAssertTrue(settings.eligibleForEntry)
    try Data().write(to: marker("release-probe", directory: second))
    try await waitFor { codex.eligibleForEntry }
    let switchedBack = try database.providerConfiguration()
    XCTAssertEqual(switchedBack.kind, .codexChatGPT)
    XCTAssertEqual(switchedBack.generation, winner.generation + 1)
    XCTAssertFalse(try apiKey.mayPublish(lease))
    XCTAssertEqual(try apiKey.key(for: lease), "fixture-validated")
    try apiKey.releaseAfterTermination(lease)
    XCTAssertTrue(try slots.validatedSlotIDs().isEmpty)
    XCTAssertEqual(try database.providerConfiguration(), switchedBack)

    codex.disconnect()
    try await waitForMarker("retirement-received", directory: second)
    try Data().write(to: marker("release-retirement", directory: second))
    try await waitFor { codex.phase == .idle }
    XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
  }

  func testApplicationTerminationStartsAllOwnedDrainsBeforeWaitingAndPreservesSelection() async throws {
    let (root, _, template) = try workerFixture(script: controlWorkerScript(
      holdResult: true, syntheticLogin: true, holdProbe: true))
    defer { try? FileManager.default.removeItem(at: root) }
    let database = try ProductDatabase.open(at: root.appendingPathComponent("database"))
    let configuration = try NativeOpenAIConfiguration(model: "fixture-model")
    let apiKey = NativeAPIKeyConnection(configuration: configuration,
      slots: try APIKeySlotStore(directory: root.appendingPathComponent("slots")),
      persistence: DatabaseAPIKeySelector(database: database, configuration: configuration),
      transport: RejectNetwork(), authority: try ProviderRequest())
    apiKey.restore()
    let loginRoot = root.appendingPathComponent("codex-scopes", isDirectory: true)
    var loginDirectories: [URL] = []
    var summaryDirectory: URL?
    let codex = NativeCodexConnection(database: database, root: loginRoot, apiKey: apiKey) { namespace in
      guard namespace.prepareBackupExclusionFixture(
        agentScript: root.appendingPathComponent("resources/agent.py"),
        interpreter: SyntheticPython.metadataInterpreter) else { return nil }
      if namespace.directoryURL.deletingLastPathComponent().path == loginRoot.path {
        loginDirectories.append(namespace.directoryURL)
      } else {
        summaryDirectory = namespace.directoryURL
      }
      return .testing(namespace: namespace, interpreter: template.interpreter, script: template.script)
    }
    codex.connect(mode: "browser")
    let active = try XCTUnwrap(loginDirectories.last)
    try await waitFor { codex.phase == .signingIn }
    codex.checkLogin()
    try await waitForMarker("probe-received", directory: active)
    try Data().write(to: marker("release-probe", directory: active))
    try await waitFor { codex.eligibleForEntry }
    let selected = try database.providerConfiguration()

    codex.connect(mode: "device")
    let replacement = try XCTUnwrap(loginDirectories.last)
    XCTAssertNotEqual(replacement, active)
    try await waitFor { codex.phase == .signingIn }
    codex.checkLogin()
    try await waitForMarker("probe-received", directory: replacement)
    let paperID = UUID()
    let (authority, request, _) = try parameters(paperID: paperID)
    let identity = LibrarySummaryIdentity(paperID: paperID, generation: UUID(), requestPaperGeneration: 1,
      pdfSHA256: String(repeating: "a", count: 64), revision: UUID(),
      configurationGeneration: selected.generation, job: UUID(), attempt: UUID(), fence: UUID(),
      correlation: UUID(), input: UUID(), epoch: UUID())
    let summary = Task { try await codex.executeLibrarySummary(request, identity: identity, authority: authority) }
    defer { summary.cancel() }
    try await waitFor { summaryDirectory != nil }
    let summaryScope = try XCTUnwrap(summaryDirectory)
    try await waitForMarker("summary-received", directory: summaryScope)

    let completed = Completion()
    let shutdown = Task {
      defer { completed.returned = true }
      return await codex.retireForApplicationTermination()
    }
    // The held replacement must not delay admission of the current login's drain.
    try await waitForMarker("retirement-received", directory: active)
    XCTAssertFalse(completed.returned)
    XCTAssertFalse(codex.canStart)
    XCTAssertFalse(codex.eligibleForEntry)
    codex.connect(mode: "browser")
    XCTAssertEqual(loginDirectories.count, 2)
    do {
      _ = try await codex.executeLibrarySummary(request, identity: identity, authority: authority)
      XCTFail("Termination must deny new Summary work")
    } catch { XCTAssertEqual(error as? LibrarySummaryError, .providerUnavailable) }

    // Each drain must reach its own terminal handshake while all peers remain held.
    try Data().write(to: marker("release-probe", directory: replacement))
    try await waitForMarker("retirement-received", directory: replacement)
    try Data().write(to: marker("release-result", directory: summaryScope))
    try await waitForMarker("retirement-received", directory: summaryScope)
    XCTAssertFalse(completed.returned)
    try Data().write(to: marker("release-retirement", directory: active))
    try await waitFor { !FileManager.default.fileExists(atPath: active.path) }
    XCTAssertFalse(completed.returned)
    XCTAssertEqual(try database.providerConfiguration(), selected)
    try Data().write(to: marker("release-retirement", directory: replacement))
    try await waitFor { !FileManager.default.fileExists(atPath: replacement.path) }
    XCTAssertFalse(completed.returned)
    XCTAssertEqual(try database.providerConfiguration(), selected)

    try Data().write(to: marker("release-retirement", directory: summaryScope))
    let clean = await shutdown.value
    XCTAssertTrue(clean)
    XCTAssertTrue(completed.returned)
    do {
      _ = try await summary.value
      XCTFail("A Summary cancelled for termination must reject its late result")
    } catch { XCTAssertTrue(error is CancellationError) }
    XCTAssertEqual(try database.providerConfiguration(), selected)
    XCTAssertEqual(try ProductDatabase.open(at: database.root).providerConfiguration(), selected)
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: loginRoot.path).isEmpty)
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: codex.summaryRoot.path).isEmpty)
    XCTAssertFalse(codex.canStart)
    codex.cancelApplicationTermination()
    XCTAssertTrue(codex.canStart)
    XCTAssertEqual(try database.providerConfiguration(), selected)
  }

  func testApplicationTerminationKeepsUnverifiedNamespaceAndReportsFailure() async throws {
    let (root, _, template) = try workerFixture(script: controlWorkerScript(
      holdResult: false, syntheticLogin: true))
    defer { try? FileManager.default.removeItem(at: root) }
    let database = try ProductDatabase.open(at: root.appendingPathComponent("database"))
    let configuration = try NativeOpenAIConfiguration(model: "fixture-model")
    let apiKey = NativeAPIKeyConnection(configuration: configuration,
      slots: try APIKeySlotStore(directory: root.appendingPathComponent("slots")),
      persistence: DatabaseAPIKeySelector(database: database, configuration: configuration),
      transport: RejectNetwork(), authority: try ProviderRequest())
    var loginDirectory: URL?
    let codex = NativeCodexConnection(database: database,
      root: root.appendingPathComponent("codex-scopes"), apiKey: apiKey) { namespace in
      guard namespace.prepareBackupExclusionFixture(
        agentScript: root.appendingPathComponent("resources/agent.py"),
        interpreter: SyntheticPython.metadataInterpreter) else { return nil }
      loginDirectory = namespace.directoryURL
      return .testing(namespace: namespace, interpreter: template.interpreter, script: template.script)
    }
    codex.connect(mode: "browser")
    let login = try XCTUnwrap(loginDirectory)
    try await waitFor { codex.phase == .signingIn }
    codex.checkLogin()
    try await waitFor { codex.eligibleForEntry }
    let selected = try database.providerConfiguration()
    let owner = try XCTUnwrap(codex.testingOwner)
    // The test, rather than the process owner, creates this top-level entry.
    let unknown = login.appendingPathComponent("unowned-fixture")
    let bytes = Data("fixture".utf8)
    try bytes.write(to: unknown)

    let shutdown = Task { await codex.retireForApplicationTermination() }
    try await waitForMarker("retirement-received", directory: login)
    try Data().write(to: marker("release-retirement", directory: login))
    let cleaned = await shutdown.value
    XCTAssertFalse(cleaned)
    XCTAssertEqual(owner.terminal, .unknown(.namespaceCleanup))
    XCTAssertTrue(owner.testingReaped)
    XCTAssertEqual(try Data(contentsOf: unknown), bytes)
    XCTAssertEqual(try database.providerConfiguration(), selected)
    codex.cancelApplicationTermination()
    XCTAssertEqual(codex.phase, .blocked)
    XCTAssertTrue(codex.blocksReplacement)
    XCTAssertFalse(codex.canStart)
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
