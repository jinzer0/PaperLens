import asyncio
from contextlib import ExitStack
import errno
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import threading
from types import ModuleType, SimpleNamespace
import unittest
from unittest.mock import patch
import uuid

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'Contracts/ProviderRPC'))
spec = importlib.util.spec_from_file_location('topology_agent', ROOT / 'ProviderAgent/agent.py')
agent = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = agent
spec.loader.exec_module(agent)
from provider_rpc import ProtocolError, decode_frame


def request(method, params=None, timeout=1000):
    return {'kind': 'request', 'id': str(uuid.uuid4()), 'method': method,
            'timeoutMs': timeout, 'params': params or {}}


def fixture_root(directory):
    root = Path(directory).resolve() / 'Library/Containers' / agent.AGENT_ID / 'Data'
    root.mkdir(parents=True)
    return root


class Runtime:
    def __init__(self):
        self.cancelled = set()

    def cancel(self, identifier):
        self.cancelled.add(identifier)

    def run(self, identifier):
        raise RuntimeError('secret raw exception must not leak')


class BlockingRuntime(Runtime):
    def __init__(self):
        super().__init__()
        self.started = threading.Event()
        self.release = threading.Event()
        self.calls = []

    def run(self, identifier):
        self.calls.append(identifier)
        self.started.set()
        if not self.release.wait(5):
            raise RuntimeError('test barrier timed out')
        return {'sdkImported': True, 'cliInitialized': True, 'architecture': 'arm64'}


class ServerTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.server = agent.Server(runtime=Runtime())
        self.server.accept(request('hello', {'major': 1, 'minor': 1, 'capabilities': ['topology-v1']}))
        await self.take()

    async def asyncTearDown(self):
        self.server.closed = True
        tasks = [p.task for p in self.server.pending.values() if p.task]
        for identifier in list(self.server.pending):
            self.server.terminate(identifier, 'cancelled')
        await asyncio.gather(*tasks, return_exceptions=True)
        await asyncio.sleep(0)

    async def take(self):
        identifier, frame = await asyncio.wait_for(self.server.outgoing.get(), 1)
        self.server.delivered(identifier)
        self.server.outgoing.task_done()
        return decode_frame(frame)

    async def test_cancel_before_task_starts_has_one_terminal(self):
        target = request('topology.wait', {'durationMs': 1000})
        self.server.accept(target)
        cancellation = request('cancel', {'targetID': target['id']})
        self.server.accept(cancellation)
        results = [await self.take(), await self.take()]
        by_id = {result['id']: result for result in results}
        self.assertTrue(by_id[cancellation['id']]['result']['accepted'])
        self.assertEqual(by_id[target['id']]['code'], 'cancelled')
        await asyncio.sleep(0)
        self.assertEqual(self.server.pending, {})
        self.assertTrue(self.server.outgoing.empty())

    async def test_cancel_running_and_late_cancel_are_distinct(self):
        target = request('topology.wait', {'durationMs': 1000})
        self.server.accept(target)
        await asyncio.sleep(0)
        self.server.accept(request('cancel', {'targetID': target['id']}))
        first, second = await self.take(), await self.take()
        self.assertEqual({first['kind'], second['kind']}, {'result', 'error'})
        self.server.accept(request('cancel', {'targetID': target['id']}))
        self.assertFalse((await self.take())['result']['accepted'])
        self.assertTrue(self.server.outgoing.empty())

    async def test_deadline_fences_late_result(self):
        target = request('topology.wait', {'durationMs': 50}, timeout=1)
        self.server.accept(target)
        reply = await self.take()
        self.assertEqual((reply['id'], reply['code']), (target['id'], 'timeout'))
        await asyncio.sleep(0.06)
        self.assertTrue(self.server.outgoing.empty())

    async def test_capacity_reserves_cancel_lane(self):
        targets = [request('topology.wait', {'durationMs': 1000}) for _ in range(3)]
        for value in targets:
            self.server.accept(value)
        rejected = request('topology.wait', {'durationMs': 1000})
        self.server.accept(rejected)
        self.assertEqual((await self.take())['code'], 'busy')
        self.server.accept(request('cancel', {'targetID': targets[0]['id']}))
        self.assertEqual((await self.take())['code'], 'cancelled')
        self.assertTrue((await self.take())['result']['accepted'])

    async def test_duplicate_request_closes_instead_of_replaying(self):
        value = request('topology.wait', {'durationMs': 1})
        self.server.accept(value)
        self.assertEqual((await self.take())['kind'], 'result')
        with self.assertRaises(ProtocolError):
            self.server.accept(value)
        self.assertTrue(self.server.outgoing.empty())

    async def test_unknown_method_and_invalid_params_are_typed(self):
        self.server.accept(request('arbitrary.shell', {'command': 'not executed'}))
        self.assertEqual((await self.take())['code'], 'unknownMethod')
        self.server.accept(request('topology.wait', {'durationMs': 5001}))
        self.assertEqual((await self.take())['code'], 'invalidParams')

    async def test_runtime_error_has_no_raw_diagnostics(self):
        self.server.accept(request('topology.runtime'))
        reply = await self.take()
        self.assertEqual(set(reply), {'kind', 'id', 'code'})
        self.assertEqual(reply['code'], 'unavailable')
        self.assertNotIn('secret', str(reply))

    async def test_major_mismatch_fails_closed_after_error(self):
        fresh = agent.Server(runtime=Runtime())
        fresh.accept(request('hello', {'major': 2, 'minor': 0, 'capabilities': ['topology-v1']}))
        reply = decode_frame(fresh.outgoing.get_nowait()[1])
        self.assertEqual(reply['code'], 'versionMismatch')
        self.assertTrue(fresh.closed)

    async def test_uninitialized_probe_does_not_invoke_runtime(self):
        fresh = agent.Server(runtime=Runtime())
        fresh.accept(request('topology.runtime'))
        self.assertEqual(decode_frame(fresh.outgoing.get_nowait()[1])['code'], 'handshakeRequired')

    async def test_unsupported_minor_never_negotiates(self):
        for minor in (0, 2):
            fresh = agent.Server(runtime=Runtime())
            fresh.accept(request('hello', {'major': 1, 'minor': minor,
                                          'capabilities': ['topology-v1']}))
            self.assertEqual(decode_frame(fresh.outgoing.get_nowait()[1])['code'], 'versionMismatch')
            self.assertTrue(fresh.closed)
            self.assertFalse(fresh.ready)

    async def test_identity_requires_exact_prepared_run_and_live_python_values(self):
        run = str(uuid.uuid4())
        self.server.accept(request('topology.identity', {'runID': run}))
        self.assertEqual((await self.take())['code'], 'unavailable')
        with tempfile.TemporaryDirectory() as directory, ExitStack() as stack:
            root = fixture_root(directory)
            stack.enter_context(patch.object(self.server.fixtures, 'roots', return_value=(root, root)))
            self.server.accept(request('topology.prepare', {'runID': run}))
            self.assertEqual((await self.take())['result'], {'prepared': True})
            self.server.accept(request('topology.identity', {'runID': str(uuid.uuid4())}))
            self.assertEqual((await self.take())['code'], 'unavailable')
            self.server.accept(request('topology.identity', {'runID': run}))
            self.assertEqual((await self.take())['result'],
                             {'bridgePID': os.getppid(), 'pythonPID': os.getpid()})
            self.server.accept(request('topology.cleanup', {'runID': run}))
            self.assertEqual((await self.take())['result'], {'absent': True})
            self.server.accept(request('topology.identity', {'runID': run}))
            self.assertEqual((await self.take())['code'], 'unavailable')

    async def test_queue_overflow_fails_closed(self):
        for _ in range(4):
            self.server.accept(request('cancel', {'targetID': str(uuid.uuid4())}))
        with self.assertRaises(ProtocolError):
            self.server.accept(request('cancel', {'targetID': str(uuid.uuid4())}))
        self.assertTrue(self.server.closed)
        self.assertEqual(self.server.outgoing.qsize(), 4)

    async def test_cancel_lane_stays_reserved_until_ack_written(self):
        first = request('cancel', {'targetID': str(uuid.uuid4())})
        second = request('cancel', {'targetID': str(uuid.uuid4())})
        self.server.accept(first)
        self.server.accept(second)
        self.assertEqual((await self.take())['id'], first['id'])
        self.assertEqual((await self.take())['code'], 'busy')
        self.server.accept(request('cancel', {'targetID': str(uuid.uuid4())}))
        self.assertEqual((await self.take())['kind'], 'result')

    async def test_timeout_winner_cannot_be_overwritten_by_cancel(self):
        target = request('topology.wait', {'durationMs': 1000})
        self.server.accept(target)
        self.assertTrue(self.server.terminate(target['id'], 'timeout'))
        self.server.accept(request('cancel', {'targetID': target['id']}))
        self.assertEqual((await self.take())['code'], 'timeout')
        self.assertFalse((await self.take())['result']['accepted'])
        await asyncio.sleep(0)
        self.assertTrue(self.server.outgoing.empty())

    async def test_cancel_winner_cannot_be_overwritten_by_timeout(self):
        target = request('topology.wait', {'durationMs': 1000})
        self.server.accept(target)
        self.server.accept(request('cancel', {'targetID': target['id']}))
        self.assertFalse(self.server.terminate(target['id'], 'timeout'))
        self.assertEqual((await self.take())['code'], 'cancelled')
        self.assertTrue((await self.take())['result']['accepted'])
        await asyncio.sleep(0)
        self.assertTrue(self.server.outgoing.empty())

    async def test_deadline_uses_receive_time_not_task_start(self):
        value = request('topology.runtime', timeout=1)
        self.server.accept(value, received=asyncio.get_running_loop().time() - 1)
        self.assertEqual((await self.take())['code'], 'timeout')
        self.assertEqual(self.server.pending, {})

    async def test_cancelled_runtime_keeps_worker_lane_after_terminal_delivery(self):
        runtime = BlockingRuntime()
        self.server.runtime = runtime
        target = request('topology.runtime')
        self.server.accept(target)
        workers = []
        try:
            self.assertTrue(await asyncio.to_thread(runtime.started.wait, 1))
            workers = list(self.server.runtime_workers.values())
            self.server.terminate(target['id'], 'cancelled')
            self.assertEqual((await self.take())['code'], 'cancelled')
            self.assertNotIn(target['id'], self.server.inflight)
            self.assertIn(target['id'], self.server.runtime_workers)
            for _ in range(3):
                self.server.accept(request('topology.runtime'))
                self.assertEqual((await self.take())['code'], 'busy')
            self.assertEqual(runtime.calls, [target['id']])
            self.assertFalse(workers[0].cancelled())
        finally:
            runtime.release.set()
            await asyncio.gather(*workers, return_exceptions=True)
            await asyncio.sleep(0)
        self.assertEqual(self.server.runtime_workers, {})
        self.assertTrue(self.server.outgoing.empty())
        self.server.accept(request('topology.runtime'))
        self.assertEqual((await self.take())['kind'], 'result')

    async def test_queue_failure_cleans_selected_original_record(self):
        for terminal in ('cancelled', 'timeout', 'result'):
            with self.subTest(terminal=terminal):
                server = agent.Server(runtime=Runtime())
                server.ready = True
                target = request('topology.runtime')
                server.accept(target)
                record = server.pending[target['id']]
                for index in range(server.outgoing.maxsize):
                    server.outgoing.put_nowait((str(index), b'occupied'))
                try:
                    with self.assertRaises(ProtocolError):
                        if terminal == 'result':
                            server.finish(target['id'], result={
                                'sdkImported': True, 'cliInitialized': True, 'architecture': 'arm64'})
                        else:
                            server.terminate(target['id'], terminal)
                    self.assertTrue(server.closed)
                    self.assertTrue(server.fatal.is_set())
                    self.assertNotIn(target['id'], server.pending)
                    self.assertIn(target['id'], server.inflight)
                    self.assertIn(target['id'], server.runtime.cancelled)
                    self.assertTrue(record.timer.cancelled())
                    self.assertTrue(record.task.cancelling())
                    self.assertFalse(server.terminate(target['id'], 'cancelled'))
                    self.assertEqual(server.outgoing.qsize(), server.outgoing.maxsize)
                finally:
                    record.task.cancel()
                    await asyncio.gather(record.task, return_exceptions=True)

    async def test_deadline_fences_late_fixture_error_before_timer_runs(self):
        loop = asyncio.get_running_loop()
        now = [loop.time()]
        target = request('topology.prepare', {'runID': str(uuid.uuid4())})
        self.server.accept(target, received=now[0])
        record = self.server.pending[target['id']]
        def late_error(_):
            now[0] += 2
            raise OSError('private fixture details')
        with patch.object(loop, 'time', side_effect=lambda: now[0]), \
                patch.object(self.server.fixtures, 'prepare', side_effect=late_error):
            await asyncio.gather(record.task, return_exceptions=True)
        reply = await self.take()
        self.assertEqual((reply['id'], reply['code']), (target['id'], 'timeout'))
        self.assertTrue(record.timer.cancelled())
        self.assertFalse(self.server.terminate(target['id'], 'cancelled'))
        self.assertTrue(self.server.outgoing.empty())


class RuntimeProbeTests(unittest.TestCase):
    def test_cancel_kills_and_reaps_without_initialize_returning(self):
        initialized = threading.Event()
        release = threading.Event()
        reaped = threading.Event()
        calls = []
        errors = []
        class Process:
            returncode = None

            def poll(self):
                return self.returncode

            def terminate(self):
                calls.append('terminate')

            def kill(self):
                calls.append('kill')
                self.returncode = -9

            def wait(self, timeout):
                calls.append(('wait', timeout))
                if self.returncode is None:
                    raise agent.subprocess.TimeoutExpired('mock-codex', timeout)
                reaped.set()
                return self.returncode

        process = Process()
        class Client:
            _proc = None

            def __init__(self, config, approval_handler):
                self.config = config
                self.approval_handler = approval_handler
                clients.append(self)

            def start(self):
                self._proc = process

            def initialize(self):
                initialized.set()
                if not release.wait(5):
                    raise RuntimeError('test barrier timed out')
                raise RuntimeError('transport closed')

            def close(self):
                calls.append('close')

        clients = []
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory).resolve()
            resources = base / 'Bundle/Contents/Resources'
            container = base / 'Library/Containers' / agent.AGENT_ID / 'Data'
            container.mkdir(parents=True)
            runtime_root = container / 'Library/Application Support/PaperLensTopologyRuntime'
            runtime_root.mkdir(parents=True, mode=0o700)
            invocation = runtime_root / str(uuid.uuid4())
            invocation.mkdir(mode=0o700)
            home = invocation / 'codex'
            sdk = ModuleType('openai_codex')
            sdk.__file__ = str(resources / 'openai_codex/__init__.py')
            sdk.__version__ = '0.160.0'
            client_module = ModuleType('openai_codex.client')
            client_module.CodexClient = Client
            client_module.CodexConfig = SimpleNamespace
            runtime = agent.RuntimeProbe()
            identifier = str(uuid.uuid4())
            def run():
                try:
                    runtime.run(identifier)
                except Exception as error:
                    errors.append(error)
            with patch.object(agent, '__file__', str(resources / 'agent.py')), \
                    patch.object(agent.platform, 'machine', return_value='arm64'), \
                    patch.object(Path, 'is_file', return_value=True), \
                    patch.object(Path, 'home', return_value=container), \
                    patch.object(agent, 'fixture_profile', return_value=(base, container)), \
                    patch.dict(os.environ, {'CODEX_HOME': str(home)}), \
                    patch.dict(sys.modules, {'openai_codex': sdk, 'openai_codex.client': client_module}):
                worker = threading.Thread(target=run)
                worker.start()
                stopper = None
                try:
                    self.assertTrue(initialized.wait(1))
                    runtime.cancel(identifier)
                    stopper = runtime.active[identifier].stopper
                    self.assertTrue(reaped.wait(1))
                    stopper.join(1)
                    self.assertFalse(stopper.is_alive())
                    self.assertTrue(worker.is_alive())
                    self.assertIn(identifier, runtime.active)
                    with self.assertRaisesRegex(RuntimeError, 'runtimeBusy'):
                        runtime.run(str(uuid.uuid4()))
                    runtime.cancel(identifier)
                    self.assertIs(runtime.active[identifier].stopper, stopper)
                    self.assertEqual(calls, ['terminate', ('wait', 2), 'kill', ('wait', 2)])
                    self.assertEqual(len(clients), 1)
                    self.assertEqual(clients[0].config.codex_bin, str(resources.parent / 'MacOS/codex'))
                    attempt = home / ('topology-' + identifier)
                    self.assertEqual(clients[0].config.env, {'CODEX_HOME': str(attempt)})
                    self.assertEqual(clients[0].config.cwd, str(attempt))
                    self.assertEqual(attempt.stat().st_mode & 0o777, 0o700)
                finally:
                    release.set()
                    worker.join(2)
                    if stopper is not None:
                        stopper.join(1)
                self.assertFalse(worker.is_alive())
                self.assertEqual(runtime.active, {})
                self.assertFalse((home / ('topology-' + identifier)).exists())
                self.assertEqual(len(errors), 1)
                self.assertEqual(calls[-1], 'close')

    def test_failed_reap_retains_process_ownership(self):
        runtime = agent.RuntimeProbe()
        process = SimpleNamespace(
            poll=lambda: None, terminate=lambda: None, kill=lambda: None,
        )
        def wait(timeout):
            raise agent.subprocess.TimeoutExpired('mock-codex', timeout)
        process.wait = wait
        identifier = str(uuid.uuid4())
        def failed_worker(_, worker):
            worker.process = process
            runtime.stop(worker)
            raise RuntimeError('runtimeShutdownFailed')
        with patch.object(runtime, 'run_owned', side_effect=failed_worker):
            with self.assertRaisesRegex(RuntimeError, 'runtimeShutdownFailed'):
                runtime.run(identifier)
            self.assertIn(identifier, runtime.active)
            with self.assertRaisesRegex(RuntimeError, 'runtimeBusy'):
                runtime.run(str(uuid.uuid4()))


class ProfileTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.home = Path(temporary.name).resolve()
        self.container = self.home / 'Library/Containers' / agent.AGENT_ID / 'Data'
        self.container.mkdir(parents=True)
        self.resources = self.home / 'Bundle/Contents/Resources'
        self.resources.mkdir(parents=True)
        self.map_path = self.resources / 'fixture-map.json'
        self.map_path.write_text(json.dumps({'profile': 'current-user', 'groupID': agent.GROUP_ID}))
        self.account = SimpleNamespace(pw_uid=501, pw_dir=str(self.home))
        real_lstat = Path.lstat
        def owned_metadata(path):
            values = list(real_lstat(path))
            values[4] = 501
            return os.stat_result(values)
        for context in (
            patch.object(agent.os, 'getuid', return_value=501),
            patch.object(agent.os, 'geteuid', return_value=501),
            patch.object(agent.pwd, 'getpwuid', return_value=self.account),
            patch.object(agent, '__file__', str(self.resources / 'agent.py')),
            patch.object(Path, 'home', return_value=self.container),
            patch.object(Path, 'lstat', new=owned_metadata),
            patch.dict(os.environ, {'HOME': str(self.container)}),
        ):
            context.start()
            self.addCleanup(context.stop)

    def test_current_account_derives_only_invocation_synthetic_targets(self):
        fixtures = agent.Fixtures()
        run = str(uuid.uuid4())
        self.assertEqual(fixtures.roots(), (
            self.container, self.home / 'Library/Containers' / agent.MAIN_ID / 'Data'))
        fixtures.prepare(run)
        expected = agent.Fixtures.observation('allowed', 'none')
        with patch.object(fixtures, 'access', return_value=expected) as access:
            for case, target in (
                ('mainRead', self.home / 'Library/Containers' / agent.MAIN_ID / 'Data/Library/Application Support/PaperLensTopology' / run / 'db.canary'),
                ('externalRead', self.home / 'Library/Application Support/PaperLensTopologyFixtureHost' / run / 'external.canary'),
                ('groupRead', self.home / 'Library/Group Containers' / agent.GROUP_ID / 'PaperLensTopology' / run / 'group.canary'),
            ):
                self.assertEqual(fixtures.probe(run, case), expected)
                access.assert_called_with(target, write=False, follow=False)
        self.assertEqual(fixtures.cleanup(run), {'absent': True})

    def test_root_system_and_sudo_uids_fail_before_account_lookup(self):
        for uid, euid in ((0, 0), (499, 499), (501, 0), (501, 502)):
            with self.subTest(uid=uid, euid=euid), \
                    patch.object(agent.os, 'getuid', return_value=uid), \
                    patch.object(agent.os, 'geteuid', return_value=euid), \
                    patch.object(agent.pwd, 'getpwuid') as lookup:
                with self.assertRaises(PermissionError):
                    agent.Fixtures().prepare(str(uuid.uuid4()))
                lookup.assert_not_called()

    def test_invalid_account_home_fails_without_fixture_creation(self):
        link = self.home / 'home-link'
        link.symlink_to(self.home, target_is_directory=True)
        file = self.home / 'home-file'
        file.write_bytes(b'preserve')
        for uid, home in ((502, str(self.home)), (501, 'relative'), (501, '/'),
                          (501, str(link)), (501, str(file)), (501, str(self.home / 'missing'))):
            with self.subTest(home=home), patch.object(
                    agent.pwd, 'getpwuid', return_value=SimpleNamespace(pw_uid=uid, pw_dir=home)):
                with self.assertRaises((PermissionError, FileNotFoundError)):
                    agent.Fixtures().prepare(str(uuid.uuid4()))
        self.assertEqual(file.read_bytes(), b'preserve')
        self.assertFalse((self.container / 'Library').exists())

    def test_foreign_home_owner_is_rejected(self):
        real_lstat = Path.lstat
        def foreign_metadata(path):
            values = list(real_lstat(path))
            if path == self.home:
                values[4] = 502
            return os.stat_result(values)
        with patch.object(Path, 'lstat', new=foreign_metadata):
            with self.assertRaises(PermissionError):
                agent.fixture_profile()

    def test_map_rejects_old_profile_extra_fields_wrong_group_and_duplicates(self):
        for value in (
            '{"profile":"dedicated","groupID":"' + agent.GROUP_ID + '"}',
            json.dumps({'profile': 'current-user', 'groupID': 'arbitrary'}),
            json.dumps({'profile': 'current-user', 'groupID': agent.GROUP_ID, 'home': str(self.home)}),
            '{"profile":"current-user","profile":"current-user","groupID":"' + agent.GROUP_ID + '"}',
            '[]', '{}', 'not JSON',
        ):
            with self.subTest(value=value):
                self.map_path.write_text(value)
                with self.assertRaises((PermissionError, ValueError)):
                    agent.fixture_profile()
        self.assertFalse((self.container / 'Library').exists())

    def test_symlink_map_and_container_are_rejected(self):
        saved_map = self.map_path.with_name('saved-map.json')
        self.map_path.rename(saved_map)
        self.map_path.symlink_to(saved_map)
        with self.assertRaises(OSError):
            agent.fixture_profile()
        self.map_path.unlink()
        saved_map.rename(self.map_path)
        saved_container = self.container.with_name('saved-Data')
        self.container.rename(saved_container)
        self.container.symlink_to(saved_container, target_is_directory=True)
        with self.assertRaises(PermissionError):
            agent.fixture_profile()

    def test_missing_oversized_and_nonregular_map_fail_closed(self):
        self.map_path.unlink()
        with self.assertRaises(FileNotFoundError):
            agent.fixture_profile()
        self.map_path.write_bytes(b' ' * 4097)
        with self.assertRaises(PermissionError):
            agent.fixture_profile()
        self.map_path.unlink()
        self.map_path.mkdir()
        with self.assertRaises((PermissionError, IsADirectoryError)):
            agent.fixture_profile()
        self.assertFalse((self.container / 'Library').exists())

    def test_foreign_container_owner_is_rejected(self):
        real_lstat = Path.lstat
        def foreign_metadata(path):
            values = list(real_lstat(path))
            if path == self.container:
                values[4] = 502
            return os.stat_result(values)
        with patch.object(Path, 'lstat', new=foreign_metadata):
            with self.assertRaises(PermissionError):
                agent.fixture_profile()

    def test_home_environment_cannot_select_another_profile(self):
        for home in (self.home, self.home / 'other-container'):
            with self.subTest(home=home), patch.dict(os.environ, {'HOME': str(home)}):
                with self.assertRaises(PermissionError):
                    agent.fixture_profile()
        with patch.object(Path, 'home', return_value=self.home):
            with self.assertRaises(PermissionError):
                agent.fixture_profile()

    def test_existing_current_user_fixture_is_preserved_and_blocks(self):
        fixtures = agent.Fixtures()
        run = str(uuid.uuid4())
        own, _ = fixtures.own_paths(run)
        own.parent.mkdir(parents=True)
        own.write_bytes(b'prior invocation')
        before = set(self.container.rglob('*'))
        with self.assertRaises(FileExistsError):
            fixtures.prepare(run)
        self.assertEqual(own.read_bytes(), b'prior invocation')
        self.assertEqual(set(self.container.rglob('*')), before)
        self.assertNotIn(run, fixtures.owned)

    def test_runtime_rejects_arbitrary_codex_home_before_sdk_import(self):
        runtime_root = self.container / 'Library/Application Support/PaperLensTopologyRuntime'
        runtime_root.mkdir(parents=True, mode=0o700)
        invocation = runtime_root / str(uuid.uuid4())
        invocation.mkdir(mode=0o700)
        target = invocation / 'existing-config'
        target.mkdir(mode=0o700)
        (target / 'auth.json').write_bytes(b'never read')
        link = invocation / 'codex'
        link.symlink_to(target, target_is_directory=True)
        for home in (self.home / 'credentials', self.container / 'codex',
                     runtime_root / 'not-a-uuid/codex', link):
            with self.subTest(home=home), \
                    patch.dict(os.environ, {'CODEX_HOME': str(home)}), \
                    patch.object(Path, 'is_file', return_value=True), \
                    patch.object(agent.platform, 'machine', return_value='arm64'), \
                    patch.object(agent.importlib, 'import_module') as sdk_import:
                with self.assertRaises((PermissionError, ValueError)):
                    agent.RuntimeProbe().run(str(uuid.uuid4()))
                sdk_import.assert_not_called()
        self.assertEqual((target / 'auth.json').read_bytes(), b'never read')


class FixtureTests(unittest.TestCase):

    def test_retained_links_keep_exact_inode_and_target_until_cleanup(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory).resolve()
            root = home / 'Library/Containers' / agent.AGENT_ID / 'Data'
            main = home / 'Library/Containers' / agent.MAIN_ID / 'Data'
            root.mkdir(parents=True)
            fixtures = agent.Fixtures()
            run = str(uuid.uuid4())
            with patch.object(fixtures, 'roots', return_value=(root, main)):
                fixtures.prepare(run)
                own, _ = fixtures.own_paths(run)
                targets = fixtures.targets(run)
                for alias, case in (('M', 'mainCanarySymlinkRead'),
                                    ('E', 'externalCanarySymlinkRead'),
                                    ('G', 'foreignGroupCanarySymlinkRead')):
                    target = targets[alias]
                    target.parent.mkdir(parents=True, mode=0o700)
                    target.write_bytes(agent.MARKER)
                    target.chmod(0o600)
                    link = own.parent / (alias + '.link')
                    before = fixtures.identity(link)
                    self.assertEqual(os.readlink(link), str(target))
                    reply = fixtures.probe(run, case)
                    self.assertEqual(reply['outcome'], 'allowed')
                    self.assertTrue(reply['syscallObserved'])
                    self.assertEqual(fixtures.identity(link), before)
                    self.assertEqual(os.readlink(link), str(target))
                self.assertEqual(fixtures.cleanup(run), {'absent': True})
                self.assertTrue(all(target.read_bytes() == agent.MARKER for target in targets.values()))

    def test_replaced_link_is_not_adopted_probed_or_removed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = fixture_root(directory)
            fixtures = agent.Fixtures()
            run = str(uuid.uuid4())
            with patch.object(fixtures, 'roots', return_value=(root, root)):
                fixtures.prepare(run)
                own, _ = fixtures.own_paths(run)
                link = own.parent / 'M.link'
                target = os.readlink(link)
                link.rename(root / 'retained-original-link')
                link.symlink_to(target)
                with patch.object(fixtures, 'access') as access:
                    self.assertEqual(fixtures.probe(run, 'mainCanarySymlinkRead'),
                                     fixtures.observation())
                    access.assert_not_called()
                with self.assertRaisesRegex(PermissionError, 'fixtureReplaced'):
                    fixtures.cleanup(run)
                self.assertEqual(os.readlink(link), target)
                self.assertTrue(own.exists())

    def test_ancestor_denial_and_aggregate_are_not_leaf_observations(self):
        with patch.object(agent.Fixtures, 'parent_descriptor', side_effect=OSError(errno.EACCES, 'ancestor')):
            self.assertEqual(agent.Fixtures.access(Path('/synthetic/leaf'), write=False),
                             agent.Fixtures.observation())
        with tempfile.TemporaryDirectory() as directory:
            root = fixture_root(directory)
            fixtures = agent.Fixtures()
            run = str(uuid.uuid4())
            with patch.object(fixtures, 'roots', return_value=(root, root)):
                self.assertEqual(fixtures.probe(run, 'ownZoneReadWrite'),
                                 fixtures.observation(reason='missingFixture'))
                fixtures.prepare(run)
                self.assertEqual(fixtures.probe(run, 'ownZoneReadWrite'),
                                 fixtures.observation('allowed', 'none'))
                with patch.object(fixtures, 'access', return_value=fixtures.observation()):
                    self.assertEqual(fixtures.probe(run, 'ownZoneReadWrite'), fixtures.observation())
                fixtures.cleanup(run)

    def test_cleanup_preserves_same_inode_modified_canary(self):
        with tempfile.TemporaryDirectory() as directory:
            root = fixture_root(directory)
            fixtures = agent.Fixtures()
            run = str(uuid.uuid4())
            with patch.object(fixtures, 'roots', return_value=(root, root)):
                fixtures.prepare(run)
                own, _ = fixtures.own_paths(run)
                original = fixtures.identity(own)
                own.write_bytes(b'x' * len(agent.MARKER))
                with self.assertRaisesRegex(PermissionError, 'fixtureReplaced'):
                    fixtures.cleanup(run)
                self.assertEqual(fixtures.identity(own), original)
                self.assertEqual(own.read_bytes(), b'x' * len(agent.MARKER))
                self.assertIn(run, fixtures.prepared)

    def test_write_open_denial_is_observed_but_marker_read_denial_is_not(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory).resolve() / 'canary'
            path.write_bytes(agent.MARKER)
            path.chmod(0o600)
            original_open = os.open
            for denied_flag, observed in ((os.O_WRONLY, True), (os.O_RDONLY, False)):
                flags_seen = []
                def denied_leaf(name, flags, *args, **kwargs):
                    if name == path.name:
                        flags_seen.append(flags)
                        if flags & os.O_ACCMODE == denied_flag:
                            raise OSError(errno.EACCES, 'leaf')
                    return original_open(name, flags, *args, **kwargs)
                with self.subTest(denied_flag=denied_flag), \
                        patch.object(agent.os, 'open', side_effect=denied_leaf), \
                        patch.object(agent.os, 'pwrite') as write, \
                        patch.object(agent.time, 'monotonic_ns', side_effect=range(100, 200)):
                    result = agent.Fixtures.access(path, write=True)
                    self.assertEqual(result['syscallObserved'], observed)
                    self.assertEqual(flags_seen[0] & os.O_ACCMODE, os.O_WRONLY)
                    self.assertTrue(all(flags & os.O_ACCMODE != os.O_RDWR for flags in flags_seen))
                    write.assert_not_called()
                    if observed:
                        self.assertEqual((result['syscallResult'], result['errno']), (-1, errno.EACCES))
                        self.assertEqual((result['beganAtNs'], result['endedAtNs']), (100, 101))
                    else:
                        self.assertEqual(result, agent.Fixtures.observation())
                self.assertEqual(path.read_bytes(), agent.MARKER)

    def test_write_requires_marker_control_and_records_original_pwrite(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory).resolve() / 'canary'
            path.write_bytes(b'x' * len(agent.MARKER))
            path.chmod(0o600)
            with patch.object(agent.os, 'pwrite') as write:
                self.assertEqual(agent.Fixtures.access(path, write=True), agent.Fixtures.observation())
                write.assert_not_called()
            path.write_bytes(agent.MARKER)
            with patch.object(agent.os, 'pwrite', side_effect=OSError(errno.EPERM, 'write')), \
                    patch.object(agent.time, 'monotonic_ns', side_effect=(10, 20, 30, 40)):
                result = agent.Fixtures.access(path, write=True)
            self.assertEqual(result, agent.Fixtures.observation('denied', 'permissionDenied',
                             observed=True, result=-1, error=errno.EPERM, began=30, ended=40))
            self.assertEqual(path.read_bytes(), agent.MARKER)

    def test_read_records_individual_syscall_not_descriptor_number(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory).resolve() / 'canary'
            path.write_bytes(agent.MARKER)
            path.chmod(0o600)
            with patch.object(agent.time, 'monotonic_ns', side_effect=(10, 20, 30, 40)):
                result = agent.Fixtures.access(path, write=False)
            self.assertEqual(result, agent.Fixtures.observation('allowed', 'none',
                             observed=True, result=len(agent.MARKER), began=30, ended=40))
            with patch.object(agent.os, 'pread', side_effect=OSError(errno.EACCES, 'read')), \
                    patch.object(agent.time, 'monotonic_ns', side_effect=(10, 20, 30, 40)):
                result = agent.Fixtures.access(path, write=False)
            self.assertEqual(result, agent.Fixtures.observation('denied', 'permissionDenied',
                             observed=True, result=-1, error=errno.EACCES, began=30, ended=40))

    def test_bind_failure_never_becomes_listen_denial(self):
        fixtures = agent.Fixtures()
        run = str(uuid.uuid4())
        fixtures.prepared.add(run)
        for stage in ('bind', 'listen', 'success'):
            sock = unittest.mock.MagicMock()
            sock.__enter__.return_value = sock
            if stage != 'success':
                getattr(sock, stage).side_effect = OSError(errno.EPERM, stage)
            with self.subTest(stage=stage), patch.object(fixtures, 'own_paths', return_value=(Path('/a'), Path('/c'))), \
                    patch.object(agent.socket, 'socket', return_value=sock), \
                    patch.object(agent.time, 'monotonic_ns', side_effect=(100, 200)):
                result = fixtures.probe(run, 'inboundListen')
            if stage == 'bind':
                self.assertEqual(result, fixtures.observation())
                sock.listen.assert_not_called()
            else:
                self.assertTrue(result['syscallObserved'])
                self.assertEqual((result['beganAtNs'], result['endedAtNs']), (100, 200))
                self.assertEqual(result['syscallResult'], -1 if stage == 'listen' else 0)
                self.assertEqual(result['errno'], errno.EPERM if stage == 'listen' else 0)
                self.assertEqual(result['outcome'], 'denied' if stage == 'listen' else 'allowed')

    def test_errno_is_observation_not_sandbox_pass(self):
        self.assertEqual(agent.Fixtures.denial(OSError(errno.ENOENT, 'path'), began=10, ended=20),
                         agent.Fixtures.observation('inconclusive', 'missingFixture',
                            observed=True, result=-1, error=errno.ENOENT, began=10, ended=20))
        value = agent.Fixtures.denial(OSError(errno.EACCES, 'private'), began=10, ended=20)
        self.assertEqual(value, agent.Fixtures.observation('denied', 'permissionDenied',
                            observed=True, result=-1, error=errno.EACCES, began=10, ended=20))
        self.assertNotIn('verdict', value)

    def test_private_directory_never_follows_symlink_or_chmods(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            target = base / 'target'
            target.mkdir(mode=0o755)
            mode = target.stat().st_mode
            link = base / 'link'
            link.symlink_to(target)
            with self.assertRaises(PermissionError):
                agent.private_directory(link)
            with self.assertRaises(PermissionError):
                agent.private_directory(target)
            self.assertEqual(target.stat().st_mode, mode)

    def test_probe_never_truncates_or_creates_missing_file(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory).resolve() / 'canary'
            result = agent.Fixtures.access(path, write=True)
            self.assertEqual(result['reason'], 'missingFixture')
            self.assertTrue(result['syscallObserved'])
            self.assertFalse(path.exists())
            path.write_bytes(agent.MARKER)
            path.chmod(0o600)
            result = agent.Fixtures.access(path, write=True)
            self.assertEqual(result['outcome'], 'allowed')
            self.assertEqual(result['syscallResult'], len(agent.MARKER))
            self.assertTrue(result['syscallObserved'])
            self.assertEqual(path.read_bytes(), agent.MARKER)
            path.write_bytes(b'not a canary')
            self.assertEqual(agent.Fixtures.access(path, write=False), agent.Fixtures.observation())

    def test_prepare_open_failure_rolls_back_only_new_paths(self):
        for failed_open in (1, 2):
            with self.subTest(failed_open=failed_open), tempfile.TemporaryDirectory() as directory:
                root = fixture_root(directory)
                prior = root / 'Library/Application Support/PaperLensTopology'
                prior.mkdir(parents=True, mode=0o700)
                sentinel = prior / 'prior-fixture'
                sentinel.write_bytes(b'prior data')
                before = set(root.rglob('*'))
                fixtures = agent.Fixtures()
                run = str(uuid.uuid4())
                real_open = os.open
                count = 0
                def fail_open(path, flags, mode):
                    nonlocal count
                    count += 1
                    if count == failed_open:
                        raise PermissionError('mock canary open failure')
                    return real_open(path, flags, mode)
                with patch.object(fixtures, 'roots', return_value=(root, root)):
                    with patch.object(agent.os, 'open', side_effect=fail_open):
                        with self.assertRaises(PermissionError):
                            fixtures.prepare(run)
                    self.assertEqual(set(root.rglob('*')), before)
                    self.assertEqual(sentinel.read_bytes(), b'prior data')
                    self.assertNotIn(run, fixtures.prepared)
                    self.assertNotIn(run, fixtures.owned)
                    self.assertEqual(fixtures.prepare(run), {'prepared': True})
                    self.assertEqual(fixtures.cleanup(run), {'absent': True})

    def test_prepare_never_rolls_back_prior_run_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            root = fixture_root(directory)
            fixtures = agent.Fixtures()
            run = str(uuid.uuid4())
            with patch.object(fixtures, 'roots', return_value=(root, root)):
                own, _ = fixtures.own_paths(run)
                own.parent.mkdir(parents=True)
                own.write_bytes(b'prior data')
                with self.assertRaises(FileExistsError):
                    fixtures.prepare(run)
                self.assertEqual(own.read_bytes(), b'prior data')

    def test_cleanup_retry_accepts_already_deleted_owned_paths(self):
        with tempfile.TemporaryDirectory() as directory:
            root = fixture_root(directory)
            fixtures = agent.Fixtures()
            run = str(uuid.uuid4())
            with patch.object(fixtures, 'roots', return_value=(root, root)):
                fixtures.prepare(run)
                own, cache = fixtures.own_paths(run)
                real_rmdir = Path.rmdir
                def fail_cache(path):
                    if path == cache.parent:
                        raise PermissionError('mock partial cleanup')
                    return real_rmdir(path)
                with patch.object(Path, 'rmdir', new=fail_cache):
                    with self.assertRaises(PermissionError):
                        fixtures.cleanup(run)
                self.assertFalse(own.parent.exists())
                self.assertTrue(cache.parent.exists())
                self.assertFalse(cache.exists())
                self.assertIn(run, fixtures.prepared)
                self.assertEqual(fixtures.cleanup(run), {'absent': True})
                self.assertEqual(fixtures.cleanup(run), {'absent': True})
                self.assertNotIn(run, fixtures.owned)

    def test_cleanup_retry_refuses_replaced_directory_or_file(self):
        for replacement in ('directory', 'file', 'deleted-file', 'deleted-directory', 'symlink'):
            with self.subTest(replacement=replacement), tempfile.TemporaryDirectory() as directory:
                root = fixture_root(directory)
                fixtures = agent.Fixtures()
                run = str(uuid.uuid4())
                with patch.object(fixtures, 'roots', return_value=(root, root)):
                    fixtures.prepare(run)
                    own, cache = fixtures.own_paths(run)
                    real_rmdir = Path.rmdir
                    real_unlink = Path.unlink
                    def fail_cache(path):
                        if path == cache.parent and replacement != 'file':
                            raise PermissionError('mock partial cleanup')
                        return real_rmdir(path)
                    def fail_file(path, *args, **kwargs):
                        if path == cache and replacement == 'file':
                            raise PermissionError('mock partial cleanup')
                        return real_unlink(path, *args, **kwargs)
                    with patch.object(Path, 'rmdir', new=fail_cache), \
                            patch.object(Path, 'unlink', new=fail_file):
                        with self.assertRaises(PermissionError):
                            fixtures.cleanup(run)
                    if replacement == 'directory':
                        cache.parent.rename(root / 'retained-original')
                        cache.parent.mkdir()
                        cache.write_bytes(b'replacement')
                    elif replacement in ('file', 'deleted-file'):
                        # Keep the old inode allocated so this tests replacement, not inode reuse.
                        if replacement == 'file':
                            cache.rename(root / 'retained-original')
                        cache.write_bytes(b'replacement')
                    elif replacement == 'deleted-directory':
                        own.parent.mkdir()
                        own.write_bytes(b'replacement')
                    else:
                        target = root / 'outside'
                        target.mkdir()
                        (target / own.name).write_bytes(b'replacement')
                        own.parent.symlink_to(target, target_is_directory=True)
                    with self.assertRaisesRegex(PermissionError, 'fixtureReplaced'):
                        fixtures.cleanup(run)
                    remaining = own if replacement in ('symlink', 'deleted-directory') else cache
                    self.assertEqual(remaining.read_bytes(), b'replacement')
                    self.assertIn(run, fixtures.prepared)


if __name__ == '__main__':
    unittest.main()
