import asyncio
import errno
import importlib.util
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
        self.server.accept(request('hello', {'major': 1, 'minor': 0, 'capabilities': ['topology-v1']}))
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
            home = container / 'codex'
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
                    patch.object(agent.pwd, 'getpwuid', return_value=SimpleNamespace(pw_dir=str(base))), \
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


class FixtureTests(unittest.TestCase):
    def test_missing_profile_does_not_touch_user_data(self):
        fixtures = agent.Fixtures()
        fake_user = type('User', (), {'pw_dir': '/not-the-fixture-profile'})()
        with patch.object(agent.pwd, 'getpwuid', return_value=fake_user):
            with self.assertRaises(PermissionError):
                fixtures.prepare(str(uuid.uuid4()))

    def test_errno_is_observation_not_sandbox_pass(self):
        self.assertEqual(agent.Fixtures.denial(OSError(errno.ENOENT, 'path')),
                         {'outcome': 'inconclusive', 'reason': 'missingFixture'})
        value = agent.Fixtures.denial(OSError(errno.EACCES, 'private'))
        self.assertEqual(value, {'outcome': 'denied', 'reason': 'permissionDenied'})
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
            path = Path(directory) / 'canary'
            with self.assertRaises(FileNotFoundError):
                agent.Fixtures.access(path, write=True)
            path.write_bytes(agent.MARKER)
            agent.Fixtures.access(path, write=True)
            self.assertEqual(path.read_bytes(), agent.MARKER)
            path.write_bytes(b'not a canary')
            with self.assertRaises(OSError):
                agent.Fixtures.access(path, write=False)

    def test_prepare_open_failure_rolls_back_only_new_paths(self):
        for failed_open in (1, 2):
            with self.subTest(failed_open=failed_open), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
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
            root = Path(directory)
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
            root = Path(directory)
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
                root = Path(directory)
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
