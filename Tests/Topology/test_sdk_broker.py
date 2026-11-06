"""Offline public-Darwin CLI and callable-role fixtures; never import the SDK.

Every actual owner lives in a fresh -I -B native Python process. Unknown roots and
one-shot invocation state are never reset, including by physical fixture teardown.
"""
import errno
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import struct
import tempfile
import time
import unittest
import uuid
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('sdk_broker_under_test', ROOT / 'ProviderAgent/broker.py')
broker = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(broker)


def environment(root):
    return {'PATH': '/usr/bin:/bin', 'LANG': 'C', 'LC_ALL': 'C',
            'HOME': str(root), 'CODEX_HOME': str(root / 'codex'), 'TMPDIR': str(root / 'tmp')}


# Executed only by the tests, never while importing this test module. The owner
# fixture's own Python child is also fixed -I -B; all directories are newly made.
_CASE = r'''
import ctypes
import errno
import gc
import importlib.util
import json
import os
from pathlib import Path
import select
import signal
import sys
import time
import weakref
import uuid

spec = importlib.util.spec_from_file_location('broker', Path(sys.argv[1]) / 'ProviderAgent/broker.py')
broker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(broker)
case = sys.argv[2]
root = Path(sys.argv[3]).resolve()
root.chmod(0o700)
(root / 'codex').mkdir(mode=0o700)
(root / 'tmp').mkdir(mode=0o700)
env = {'PATH': '/usr/bin:/bin', 'LANG': 'C', 'LC_ALL': 'C',
       'HOME': str(root), 'CODEX_HOME': str(root / 'codex'), 'TMPDIR': str(root / 'tmp')}
cwd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
owner = None
retirement = str(uuid.uuid4())
original_cwd = os.stat('.')
setup_failure = []
original_setup = broker._CLIResourceOwner._setup

def fixture_setup(self, *arguments):
    try:
        return original_setup(self, *arguments)
    except Exception as error:
        setup_failure.append((type(error).__name__, str(error)))
        raise

broker._CLIResourceOwner._setup = fixture_setup
original_bindings = broker._DarwinSpawn.__init__

def fixture_bindings(self):
    original_bindings(self)
    native_spawn = self.lib.posix_spawn
    def captured_spawn(*arguments):
        result = native_spawn(*arguments)
        if result:
            setup_failure.append(('posix_spawn', result))
        return result
    self.lib.posix_spawn = captured_spawn

broker._DarwinSpawn.__init__ = fixture_bindings

def readable(fd, deadline):
    remaining = deadline - time.monotonic_ns()
    assert remaining > 0
    ready, _, _ = select.select([fd], [], [], remaining / 1_000_000_000)
    assert ready == [fd]
    # Fixed small fixtures only. Never accumulate unbounded stdout/stderr.
    return os.read(fd, 4096)

def retained(snapshot):
    assert owner.state == 'unknown'
    try:
        owner.endpoints
    except broker.OwnershipError:
        pass
    else:
        raise AssertionError('unknown endpoints exposed')
    assert broker._ROOTS == [owner]
    assert broker._INVOKED
    assert snapshot == owner._fds
    for name, fd in snapshot.items():
        if fd is not None:
            os.fstat(fd)
    assert owner.cleanup(retirement, terminate=True)['state'] == 'unknown'
    assert owner.resume()['state'] == 'unknown'
    assert owner._fds == snapshot
    try:
        broker.fixture_true(cwd, env)
    except broker.OwnershipError:
        pass
    else:
        raise AssertionError('replacement invocation accepted')

try:
    factory = broker.fixture_fork if case == 'fork' else (
        broker.fixture_cat if case in ('cat', 'invalidIdentity', 'nonV4', 'changedIdentity', 'slowCleanup',
                                      'facadeLoss', 'terminate') else broker.fixture_true)
    owner = factory(cwd, env)
    assert owner.state == 'suspended', (dict(owner.record), setup_failure)
    assert owner.pid > 0 and owner._registered
    assert not owner._attr_live and not owner._actions_live
    assert owner._fds['cwd'] is None
    assert all(owner._fds[name] is None for name in ('childStdin', 'childStdout', 'childStderr'))
    assert os.stat('.').st_ino == original_cwd.st_ino
    assert os.stat('.').st_dev == original_cwd.st_dev
    os.fstat(cwd)  # Borrowed directory remains open.
    for name in ('stdin', 'stdout', 'stderr'):
        assert not os.get_inheritable(owner._fds[name])
        assert not os.get_blocking(owner._fds[name])
    assert not os.get_inheritable(owner._fds['kqueue'])
    try:
        owner.endpoints
    except broker.OwnershipError:
        pass
    else:
        raise AssertionError('suspended endpoints exposed')

    if case == 'suspended':
        # Real public waitpid stop observation, not absence over a quiet period.
        pid, status = os.waitpid(owner.pid, os.WUNTRACED | os.WNOHANG)
        assert pid == owner.pid and os.WIFSTOPPED(status)
        # Darwin reports START_SUSPENDED's initial stop without delivering a
        # stop signal (measured status 0x7f), unlike an external SIGSTOP.
        assert os.WSTOPSIG(status) == 0, (status, os.WSTOPSIG(status))
        assert owner._wait_status is None
        assert owner.resume()['state'] == 'running'
        assert owner.cleanup(retirement)['state'] == 'clean'
    else:
        assert owner.resume()['state'] == 'running'
        endpoints = dict(owner.endpoints)
        if case == 'cat':
            assert os.write(endpoints['stdin'], b'fixture-echo\n') == 13
            deadline = time.monotonic_ns() + 300_000_000
            assert owner.close_stdin(retirement)['state'] == 'running'
            assert owner._fds['stdin'] is None
            assert readable(endpoints['stdout'], deadline) == b'fixture-echo\n'
            assert owner.cleanup(retirement)['state'] == 'clean'
        elif case == 'fork':
            # This fixed output is emitted only AFTER the real fixture parent
            # waitpid has reaped its immediate fork. Descendant absence is NOT proof.
            assert readable(endpoints['stdout'], time.monotonic_ns() + 5_000_000_000) == b'reaped\n'
            snapshot = dict(owner._fds)
            assert owner.cleanup(retirement)['state'] == 'unknown'
            assert owner._wait_status is None
            retained(snapshot)
            os.fstat(owner._fds['kqueue'])
        elif case in ('invalidIdentity', 'nonV4'):
            snapshot = dict(owner._fds)
            queue_fd = owner._fds['kqueue']
            identity = 123 if case == 'invalidIdentity' else str(uuid.UUID(int=0))
            assert owner.cleanup(identity, terminate=True)['state'] == 'unknown'
            assert owner._retirement_id is None
            assert owner._wait_status is None and not owner._exit_observed
            assert owner._fds['kqueue'] == queue_fd
            os.kill(owner.pid, 0)  # Actual cat is still owned and alive.
            retained(snapshot)
        elif case == 'changedIdentity':
            owner.close_stdin(retirement)
            assert owner._fds['stdin'] is None
            snapshot = dict(owner._fds)
            assert owner.cleanup(str(uuid.uuid4()))['state'] == 'unknown'
            assert owner._retirement_id == retirement
            retained(snapshot)
        elif case == 'slowCleanup':
            owner.close_stdin(retirement)
            time.sleep(0.35)  # Delayed caller is not failed physical ownership.
            assert owner.cleanup(retirement)['state'] == 'clean'
        elif case == 'facadeLoss':
            snapshot = dict(owner._fds)
            owner.cleanup('invalid')
            reference = weakref.ref(owner)
            del owner
            gc.collect()
            owner = reference()
            assert owner is broker._ROOTS[0]
            retained(snapshot)
        elif case == 'badClose':
            # Real public OS EBADF, no fake close success or synthetic closure.
            # Deliberately violate endpoint borrowing to exercise fail-closed debt.
            os.close(endpoints['stdout'])
            assert owner.cleanup(retirement)['state'] == 'unknown'
            assert owner._exit_observed and owner._wait_status is not None
            assert owner._fds['stdout'] == endpoints['stdout']
            assert 'stdout' in owner._uncertain_fds
            assert owner._fds['stderr'] is not None
            os.fstat(owner._fds['stderr'])
            os.fstat(owner._fds['kqueue'])
            snapshot = dict(owner._fds)
            assert owner.cleanup(retirement)['state'] == 'unknown'
            assert owner._fds == snapshot
        elif case == 'injectedCloseEINTR':
            # INJECTED raw return/errno, NOT an actual OS interruption. The
            # real known stdout descriptor is deliberately left physically open.
            native_close = owner._spawn.lib.close
            attempts = []
            def injected_close(fd):
                attempts.append(fd)
                if fd == endpoints['stdout']:
                    ctypes.set_errno(errno.EINTR)
                    return -1
                return native_close(fd)
            owner._spawn.lib.close = injected_close
            assert owner.cleanup(retirement)['state'] == 'unknown'
            assert owner._exit_observed and owner._wait_status is not None
            assert attempts.count(endpoints['stdout']) == 1
            assert owner._close_errors['stdout'] == errno.EINTR
            assert 'stdout' in owner._uncertain_fds
            assert owner._fds['stdout'] == endpoints['stdout']
            os.fstat(endpoints['stdout'])
            snapshot = dict(owner._fds)
            prior_attempts = tuple(attempts)
            retained(snapshot)
            assert tuple(attempts) == prior_attempts
            owner._spawn.lib.close = native_close
            retained(snapshot)
            assert tuple(attempts) == prior_attempts
        elif case == 'terminate':
            assert owner.cleanup(retirement, terminate=True)['state'] == 'clean'
            assert os.WIFSIGNALED(owner._wait_status)
            assert os.WTERMSIG(owner._wait_status) == signal.SIGKILL
        elif case == 'true':
            descriptors = tuple(fd for fd in owner._fds.values() if fd is not None)
            assert owner.cleanup(retirement)['state'] == 'clean'
            for fd in descriptors:
                try:
                    os.fstat(fd)
                except OSError as error:
                    assert error.errno == errno.EBADF
                else:
                    raise AssertionError('descriptor physically open')
        else:
            raise AssertionError('unknown fixture case')

    if owner.state == 'clean':
        assert owner._exit_observed and owner._wait_status is not None
        assert all(fd is None for fd in owner._fds.values())
        assert owner._fds['kqueue'] is None
        assert owner._retirement_id == retirement
        assert owner.cleanup(retirement, terminate=True)['state'] == 'clean'
        assert owner.close_stdin(retirement)['state'] == 'clean'
        for completed in (owner.cleanup, owner.close_stdin):
            try:
                completed(str(uuid.uuid4()))
            except broker.OwnershipError:
                pass
            else:
                raise AssertionError('clean receipt returned for another retirement')
        try:
            os.waitpid(owner.pid, os.WNOHANG)
        except ChildProcessError:
            pass
        else:
            raise AssertionError('direct child not actually reaped')
        if case != 'terminate':
            assert os.WIFEXITED(owner._wait_status)
            assert os.WEXITSTATUS(owner._wait_status) == 0
        assert owner.record['scope'] == 'localDirectCLIResources'
        assert 'absent' not in owner.record
        try:
            owner.endpoints
        except broker.OwnershipError:
            pass
        else:
            raise AssertionError('clean endpoints exposed')
        try:
            broker.fixture_true(cwd, env)
        except broker.OwnershipError:
            pass
        else:
            raise AssertionError('clean allowed a replacement invocation')
    before = dict(owner.record)
    debt = dict(owner._fds)
    invocation = broker._INVOKED
    roots = tuple(broker._ROOTS)
finally:
    if owner is not None:
        owner.fixture_teardown()
    os.close(cwd)
assert dict(owner.record) == before
assert owner._fds == debt and broker._INVOKED == invocation
assert tuple(broker._ROOTS) == roots
print(json.dumps({'case': case, 'state': owner.state}))
'''


_REGISTRATION_CASE = _CASE.split('try:\n    factory =', 1)[0] + r'''
original_register = broker._CLIResourceOwner._register
registration_results = []

def physically_bad_registration(self):
    queue_fd = self._fds['kqueue']
    assert self.pid > 0 and not self._registered
    assert self._spawn.lib.close(queue_fd) == 0  # Actual public OS close.
    try:
        original_register(self)  # Actual kevent sees EBADF, never fake success.
    except broker.OwnershipError:
        registration_results.append(ctypes.get_errno())
        raise
    raise AssertionError('registration unexpectedly succeeded')

broker._CLIResourceOwner._register = physically_bad_registration
try:
    owner = broker.fixture_true(cwd, env)
    assert owner.state == 'unknown', (dict(owner.record), setup_failure)
    assert registration_results == [errno.EBADF]
    assert owner.pid > 0 and not owner._registered
    assert owner._attr_live and owner._actions_live
    assert not owner._exit_observed and owner._wait_status is None
    pid, status = os.waitpid(owner.pid, os.WUNTRACED | os.WNOHANG)
    assert pid == owner.pid and os.WIFSTOPPED(status)
    assert os.WSTOPSIG(status) == 0
    snapshot = dict(owner._fds)
    for name, fd in snapshot.items():
        if name != 'kqueue':
            os.fstat(fd)
    try:
        os.fstat(snapshot['kqueue'])
    except OSError as error:
        assert error.errno == errno.EBADF
    else:
        raise AssertionError('fault queue physically open')
    assert owner.resume()['state'] == 'unknown'
    assert owner.cleanup('invalid', terminate=True)['state'] == 'unknown'
    assert owner.close_stdin('invalid')['state'] == 'unknown'
    assert owner._fds == snapshot
    assert broker._ROOTS == [owner] and broker._INVOKED
    try:
        broker.fixture_true(cwd, env)
    except broker.OwnershipError:
        pass
    else:
        raise AssertionError('replacement accepted after registration fault')
    before = dict(owner.record)
    debt = dict(owner._fds)
    roots = tuple(broker._ROOTS)
finally:
    if owner is not None:
        owner.fixture_teardown()
    os.close(cwd)
assert dict(owner.record) == before and owner._fds == debt
assert tuple(broker._ROOTS) == roots and broker._INVOKED
print(json.dumps({'case': case, 'state': owner.state}))
'''


class BrokerValidationTests(unittest.TestCase):
    def test_retirement_is_canonical_uuid4_without_conversion_or_reset(self):
        identity = str(uuid.uuid4())
        for invalid in (True, False, 1.0, None, -1, 1 << 64, '',
                        identity.upper(), identity.replace('-', ''), str(uuid.UUID(int=0))):
            with self.subTest(identity=invalid):
                owner = broker._CLIResourceOwner(False)
                with self.assertRaises(broker.OwnershipError):
                    owner._begin_cleanup(invalid)
                self.assertIsNone(owner._retirement_id)
                self.assertEqual(owner._fds, {})
        owner = broker._CLIResourceOwner(False)
        owner._begin_cleanup(identity)
        owner._begin_cleanup(identity)
        with self.assertRaises(broker.OwnershipError):
            owner._begin_cleanup(str(uuid.uuid4()))
        self.assertEqual(owner._retirement_id, identity)

    def test_non_darwin_has_no_owner_or_native_effects(self):
        with patch.object(broker.sys, 'platform', 'linux'), \
                patch.object(broker, '_production_command') as command, \
                patch.object(broker, '_create') as create:
            with self.assertRaises(PermissionError):
                broker.production(999, {})
            command.assert_not_called()
            create.assert_not_called()

    def test_closed_replacement_environment_rejects_credentials_and_malformed_paths(self):
        valid = environment(Path('/private/fixture'))
        invalid = [dict(valid, OPENAI_API_KEY='not-a-credential'),
                   dict(valid, CODEX_API_KEY='not-a-credential'),
                   dict(valid, PYTHONPATH='/tmp'),
                   {key: value for key, value in valid.items() if key != 'HOME'}]
        for key, value in (('PATH', ':/bin'), ('PATH', '/bin:.'),
                           ('HOME', '/'), ('HOME', '../profile'), ('HOME', '/tmp/../profile'),
                           ('HOME', '/tmp//profile'), ('HOME', '/tmp/'),
                           ('LANG', 'C\x00bad'), ('LC_ALL', ''), ('TMPDIR', True)):
            invalid.append(dict(valid, **{key: value}))
        for candidate in invalid:
            with self.subTest(candidate=candidate), \
                    patch.object(broker.sys, 'platform', 'darwin'), \
                    patch.object(broker, '_production_command') as command, \
                    patch.object(broker, '_create') as create:
                with self.assertRaises((ValueError, UnicodeError)):
                    broker.production(999, candidate)
                command.assert_not_called()
                create.assert_not_called()

    def test_production_selector_rejects_missing_or_external_symlink_without_spawn(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            resources, macos = root / 'Resources', root / 'MacOS'
            resources.mkdir(mode=0o700)
            macos.mkdir(mode=0o700)
            script = resources / 'broker.py'
            script.write_text('# fixture path only\n')
            with patch.object(broker.sys, 'platform', 'darwin'), \
                    patch.object(broker, '__file__', str(script)), \
                    patch.object(broker, '_create') as create:
                with self.assertRaises(FileNotFoundError):
                    broker.production(999, environment(root))
                (macos / 'codex').symlink_to('/usr/bin/true')
                with self.assertRaises(PermissionError):
                    broker.production(999, environment(root))
                create.assert_not_called()

    def test_selector_has_exact_fixed_argv_and_no_path_lookup(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            (root / 'Resources').mkdir(mode=0o700)
            (root / 'MacOS').mkdir(mode=0o700)
            script = root / 'Resources/broker.py'
            script.write_text('# fixture path only\n')
            cli = root / 'MacOS/codex'
            cli.write_bytes(b'not executed')
            cli.chmod(0o700)
            with patch.object(broker, '__file__', str(script)):
                self.assertEqual(broker._production_command(),
                                 (str(cli), 'app-server', '--listen', 'stdio://'))
                cli.unlink()
                internal = root / 'Frameworks/PythonRuntime.framework/codex'
                internal.parent.mkdir(parents=True)
                internal.write_bytes(b'not executed')
                internal.chmod(0o700)
                cli.symlink_to(os.path.relpath(internal, cli.parent))
                self.assertEqual(broker._production_command(),
                                 (str(cli), 'app-server', '--listen', 'stdio://'))


@unittest.skipUnless(sys.platform == 'darwin', 'public Darwin spawn/kqueue fixtures')
class DarwinCLIResourceOwnerTests(unittest.TestCase):
    def test_fresh_process_per_actual_resource_case(self):
        for case in ('suspended', 'true', 'cat', 'fork', 'invalidIdentity', 'nonV4',
                     'changedIdentity', 'slowCleanup', 'facadeLoss', 'badClose', 'terminate',
                     'badRegistration', 'injectedCloseEINTR'):
            with self.subTest(case=case), tempfile.TemporaryDirectory() as directory:
                root = Path(directory).resolve()
                # This subprocess inherits no user's HOME, CODEX_HOME, credentials,
                # Python import settings, or arbitrary parent environment.
                script = _REGISTRATION_CASE if case == 'badRegistration' else _CASE
                result = subprocess.run(
                    [sys.executable, '-I', '-B', '-c', script, str(ROOT), case, str(root)],
                    env=environment(root), capture_output=True, timeout=15, check=False)
                self.assertEqual(result.returncode, 0, result.stderr.decode('utf-8', 'replace'))
                import json
                record = json.loads(result.stdout)
                self.assertEqual(record['case'], case)
                self.assertEqual(record['state'], 'unknown' if case in (
                    'fork', 'invalidIdentity', 'nonV4', 'changedIdentity', 'facadeLoss',
                    'badClose', 'badRegistration', 'injectedCloseEINTR') else 'clean')


def load_control():
    spec = importlib.util.spec_from_file_location(
        'broker_control_under_test', ROOT / 'ProviderAgent/broker_control.py')
    module = importlib.util.module_from_spec(spec)
    with patch.dict(sys.modules, {'broker': broker, spec.name: module}), \
            patch.object(sys, 'path', [str(ROOT / 'Contracts/ProviderRPC'), *sys.path]):
        spec.loader.exec_module(module)
    return module


class BrokerControlValidationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.control = load_control()

    def decode(self, raw):
        decoder = self.control.ControlFrames()
        result = None
        for byte in raw:
            result = decoder.feed(bytes([byte]))
        self.assertEqual(decoder.buffer, b'')
        return result

    def test_closed_frames_split_at_every_byte(self):
        run = str(uuid.uuid4())
        retirement = str(uuid.uuid4())
        cases = [('hello', {}), ('run', dict(startupDeadlineNs=123, cwdDevice=1, cwdInode=2)),
                 ('running', {}), ('dispatch', {}), ('dispatching', {}),
                 ('revokeNeeded', dict(code='cliExit')),
                 ('revokeNeeded', dict(code='sessionLimit')),
                 ('revokeNeeded', dict(code='scopeRetire')),
                 ('revoke', dict(retirementID=retirement)),
                 ('cliRetired', dict(retirementID=retirement, scope='localDirectCLIResources', waitStatus=0)),
                 ('preLaunchRetired', dict(retirementID=retirement)), ('brokerOffered', {}),
                 ('reapBroker', dict(retirementID=retirement)),
                 ('brokerReaped', dict(retirementID=retirement, waitStatus=0))]
        for op, fields in cases:
            with self.subTest(op=op):
                self.assertEqual(self.decode(self.control.encode_control(run, op, **fields)),
                                 dict(v=2, runID=run, op=op, **fields))

    def test_malformed_closed_json_and_lengths(self):
        run = str(uuid.uuid4())
        retirement = str(uuid.uuid4())
        valid = dict(v=2, runID=run, op='revoke', retirementID=retirement)
        invalid = [dict(valid, v=True), dict(valid, v=1),
                   dict(v=1, runID=run, op='revoke', deadlineNs=123),
                   dict(valid, retirementID=True), dict(valid, retirementID=1.0),
                   dict(valid, retirementID=retirement.upper()),
                   dict(valid, retirementID=retirement.replace('-', '')),
                   dict(valid, retirementID=str(uuid.UUID(int=0))),
                   dict(valid, deadlineNs=123), dict(valid, pid=os.getpid()),
                   dict(valid, runID=run.upper()), dict(valid, op='initialize'),
                   {key: value for key, value in valid.items() if key != 'retirementID'}]
        for value in invalid:
            raw = json.dumps(value).encode()
            with self.subTest(value=value), self.assertRaises((ValueError, self.control.ControlError)):
                self.decode(struct.pack('!I', len(raw)) + raw)
        for raw in (b'{"v":1,"v":1}', b'\xff', b'[]', b'{'):
            with self.subTest(raw=raw), self.assertRaises((ValueError, self.control.ControlError)):
                self.decode(struct.pack('!I', len(raw)) + raw)
        for size in (0, 1025, (1 << 32) - 1):
            decoder = self.control.ControlFrames()
            with self.assertRaises(self.control.ControlError):
                decoder.feed(struct.pack('!I', size))

    def test_stdout_cumulative_record_and_byte_budgets_never_reset_on_drain(self):
        role = self.control._Role(broker.fixture_cat)
        role.stdout_count(b'a' * (65540 - 1))
        role.stdout_count(b'\n')
        role.output.clear()
        role.stdout_count(b'b\nc\nd\n')
        with self.assertRaises(self.control.ControlError):
            role.stdout_count(b'e')
        role = self.control._Role(broker.fixture_cat)
        with self.assertRaises(self.control.ControlError):
            role.stdout_count(b'x' * 65541)
        role = self.control._Role(broker.fixture_cat)
        for _ in range(4):
            role.stdout_count(b'x' * 65539 + b'\n')
            role.output.clear()
        self.assertEqual(role.stdout_bytes, 262160)
        with self.assertRaises(self.control.ControlError):
            role.stdout_count(b'\n')

    def test_input_record_limits_are_cumulative_across_drains_and_split_reads(self):
        role = self.control._Role(broker.fixture_stdin_sink)
        for data in (b'a\n', b'b\n', b'c\n', b'd\n'):
            role.input_count(data)
            role.input.clear()
        self.assertEqual(role.input_lines, 4)
        self.assertEqual(role.stdout_bytes, 0)
        with self.assertRaises(self.control.ControlError):
            role.input_count(b'e')
        role = self.control._Role(broker.fixture_stdin_sink)
        role.input_count(b'x' * 65539)
        role.input.clear()
        role.input_count(b'x')
        self.assertEqual(role.input_partial, 65540)
        with self.assertRaises(self.control.ControlError):
            role.input_count(b'x')
        role = self.control._Role(broker.fixture_stdin_sink)
        role.input_count(b'x' * 65539 + b'\n')
        self.assertEqual((role.input_lines, role.input_partial), (1, 0))

    def test_live_lifetime_boundaries_include_startup_and_never_reset(self):
        # Pure accounting, not actual CLI/SDK execution evidence.
        for count_name, lines_name, bytes_name in (
                ('input_count', 'input_lines', 'input_bytes'),
                ('stdout_count', 'stdout_lines', 'stdout_bytes')):
            role = self.control._Role(broker.fixture_cat)
            count = getattr(role, count_name)
            count(b'start\n')
            role.dispatch_seen = True
            for _ in range(255):
                count(b'\n')
            self.assertEqual(getattr(role, lines_name), 256)
            before = getattr(role, bytes_name)
            with self.assertRaises(self.control.ControlError):
                count(b'\n')
            self.assertEqual(getattr(role, bytes_name), before)
            role = self.control._Role(broker.fixture_cat)
            role.dispatch_seen = True
            count = getattr(role, count_name)
            for _ in range(4):
                count(b'x' * 65539 + b'\n')
            self.assertEqual(getattr(role, bytes_name), 262160)
            with self.assertRaises(self.control.ControlError):
                count(b'x')
            self.assertEqual(getattr(role, bytes_name), 262160)

    def test_dispatch_authenticated_phase_snapshot_and_cleanup_priority(self):
        # Injected control reads only; kernel authority is tested by _ROLE_CASE.
        run = str(uuid.uuid4())
        role = self.control._Role(broker.fixture_cat)
        role.run_id = run
        role.fds['control'] = 999
        role.state = 'relaying'
        role.running_sent = True
        role.startup_deadline = 100
        role.input_count(b'prefix\x00')
        def receive(raw):
            with patch.object(self.control.os, 'read', side_effect=[raw[:4], raw[4:], BlockingIOError()]):
                role.receive()
        with patch.object(self.control.time, 'monotonic_ns', return_value=1):
            receive(self.control.encode_control(run, 'dispatch'))
        self.assertTrue(role.dispatch_seen)
        snapshot = role.startup_counters
        self.assertEqual(snapshot, (7, 0, 7, 0, 0, 0, 0))
        self.assertEqual(self.decode(bytes(role.control_out))['op'], 'dispatching')
        role.input_count(b' continuation\n')
        self.assertEqual(role.startup_counters, snapshot)
        with self.assertRaises(self.control.ControlError):
            receive(self.control.encode_control(run, 'dispatch'))
        with patch.object(role, 'receive'), patch.object(role, 'observe'), \
                patch.object(self.control.time, 'monotonic_ns', return_value=200):
            role.priority()  # Dispatch disables only the startup timer.
            self.assertFalse(role.frozen)
            role.latch(str(uuid.uuid4()))
            with patch.object(role, 'retire', side_effect=RuntimeError('actualD')) as retire:
                with self.assertRaisesRegex(RuntimeError, 'actualD'):
                    role.priority()
                retire.assert_called_once_with()
        for state, sent, stale in (('awaitingRun', False, False),
                                    ('relaying', False, False), ('relaying', True, True)):
            role = self.control._Role(broker.fixture_cat)
            role.run_id, role.fds['control'] = run, 999
            role.state, role.running_sent = state, sent
            role.startup_deadline = 100
            raw = self.control.encode_control(str(uuid.uuid4()) if stale else run, 'dispatch')
            with patch.object(self.control.os, 'read', side_effect=[raw[:4], raw[4:]]), \
                    patch.object(self.control.time, 'monotonic_ns', return_value=1):
                with self.assertRaises(self.control.ControlError):
                    role.receive()
            self.assertFalse(role.dispatch_seen)

    def test_real_pipe_four_slots_partial_head_and_no_fifth_read(self):
        # Real nonblocking pipe pressure, not an SDK queue/purge claim.
        pending = self.control._RelayBuffer()
        source, writer = os.pipe()
        sink, destination = os.pipe()
        try:
            for fd in (source, writer, sink, destination):
                os.set_blocking(fd, False)
            os.write(writer, b'a\nb\nc\nd\ne\n')
            for _ in range(8):
                self.assertIsNotNone(pending.read_byte(source))
            self.assertEqual((pending.slots, pending.bytes), (4, 8))
            self.assertIsNone(pending.read_byte(source))
            # Fill the actual destination, then verify the head stays rooted.
            while True:
                try:
                    os.write(destination, b'p' * 4096)
                except BlockingIOError:
                    break
            first = pending.closed[0]
            pending.write(destination, True)
            self.assertIs(pending.closed[0], first)
            self.assertEqual(pending.slots, 4)
            while True:
                try:
                    os.read(sink, 4096)
                except BlockingIOError:
                    break
            # Injected short write delegates the actual byte to the real pipe.
            actual_write = os.write
            with patch.object(self.control.os, 'write', side_effect=lambda fd, data: actual_write(fd, data[:1])):
                pending.write(destination, True)
            self.assertEqual((pending.slots, pending.bytes), (4, 7))
            self.assertIsNone(pending.read_byte(source))
            pending.write(destination, True)
            self.assertEqual(pending.slots, 3)
            self.assertEqual(pending.read_byte(source), ord('e'))
            self.assertEqual(pending.read_byte(source), 10)
            self.assertEqual(pending.slots, 4)
            self.assertEqual(os.read(sink, 2), b'a\n')
            self.assertEqual([bytes(record) for record in pending.closed], [b'b\n', b'c\n', b'd\n', b'e\n'])
        finally:
            for fd in (source, writer, sink, destination):
                os.close(fd)

    def test_real_pipe_session_limit_freezes_before_fifth_and_waits_for_actual_d(self):
        # Inject only priority/kernel watching; these are real pipe bytes, not SDK evidence.
        role = self.control._Role(broker.fixture_cat)
        role.run_id = str(uuid.uuid4())
        source, writer = os.pipe()
        empty, empty_writer = os.pipe()
        sink, destination = os.pipe()
        try:
            for fd in (source, writer, empty, empty_writer, sink, destination):
                os.set_blocking(fd, False)
            role.fds.update(stdin=source, stdout=destination)
            role.endpoints = dict(stdin=destination, stdout=empty, stderr=empty)
            os.write(writer, b'a\nb\nc\nd\ne\n')
            with patch.object(role, 'priority'):
                for _ in range(5):
                    role.relay_once()
            self.assertTrue(role.frozen)
            self.assertIsNone(role.retirement_id)
            self.assertEqual((role.input_bytes, role.input_lines), (8, 4))
            self.assertEqual(os.read(source, 2), b'e\n')
            self.assertEqual(self.decode(bytes(role.control_out))['code'], 'sessionLimit')
            snapshot = (role.input_bytes, role.input.slots, role.input.bytes)
            with patch.object(role, 'priority'), patch.object(self.control.os, 'readv') as readv, \
                    patch.object(self.control.os, 'write') as write:
                role.relay_once()
                readv.assert_not_called()
                write.assert_not_called()
            self.assertEqual((role.input_bytes, role.input.slots, role.input.bytes), snapshot)
        finally:
            for fd in (source, writer, empty, empty_writer, sink, destination):
                os.close(fd)

    def test_read_reservation_stays_rooted_on_uncertain_syscall(self):
        # Injected failure, never a claim that the OS actually returned uncertain IO.
        pending = self.control._RelayBuffer()
        with patch.object(self.control.os, 'readv', side_effect=OSError(errno.EIO, 'injected')):
            with self.assertRaises(OSError):
                pending.read_byte(999)
        self.assertEqual((pending.slots, pending.bytes), (1, 1))
        self.assertEqual(pending.partial, b'\x00')

    def test_real_pipe_startup_prefix_transition_never_replays(self):
        pending = self.control._RelayBuffer()
        source, writer = os.pipe()
        sink, destination = os.pipe()
        try:
            os.set_blocking(source, False)
            os.set_blocking(sink, False)
            os.write(writer, b'opaque\x00')
            for _ in range(7):
                pending.read_byte(source)
            pending.write(destination, False)
            self.assertEqual(os.read(sink, 7), b'opaque\x00')
            self.assertEqual((pending.slots, pending.bytes), (1, 0))
            os.write(writer, b' tail')
            for _ in range(5):
                pending.read_byte(source)
            pending.write(destination, True)
            with self.assertRaises(BlockingIOError):
                os.read(sink, 1)
            os.write(writer, b'\n')
            pending.read_byte(source)
            pending.write(destination, True)
            self.assertEqual(os.read(sink, 6), b' tail\n')
            self.assertEqual((pending.slots, pending.bytes), (0, 0))
        finally:
            for fd in (source, writer, sink, destination):
                os.close(fd)

    def test_single_retirement_and_sticky_primitive_observation(self):
        now = 9_000_000_000
        owner = self.control._Resources()
        with patch.object(self.control.time, 'monotonic_ns', return_value=now):
            for bad in (True, 1.0, now, '', str(uuid.UUID(int=0))):
                with self.assertRaises(self.control.ControlError):
                    owner.latch(bad)
            identity = str(uuid.uuid4())
            owner.latch(identity)
            owner.latch(identity)
            with self.assertRaises(self.control.ControlError):
                owner.latch(str(uuid.uuid4()))
        with patch.object(self.control.time, 'monotonic_ns', return_value=now + 10_000_000_000):
            owner.clock()  # Slow cleanup does not expire.
        primitive = broker._CLIResourceOwner(False)
        primitive._state = 'running'
        with patch.object(primitive, '_events', side_effect=broker.OwnershipError('forkObserved')) as events:
            result = primitive.observe_pending()
            self.assertEqual(result['state'], 'unknown')
            with self.assertRaises(TypeError):
                result['state'] = 'clean'
            primitive.observe_pending()
            primitive.mark_unknown('roleUncertain')
            self.assertEqual(events.call_count, 1)

    def test_injected_identity_denied_short_and_mismatched_token_fail_closed(self):
        # These are injected API failures, NOT actual kernel authentication.
        for failure in ('denied', 'short', 'tokenMismatch', 'missingExport', 'disconnected'):
            lib, proc, bsm = Mock(), Mock(), Mock()
            lib.getpeereid.return_value = -1 if failure == 'denied' else 0
            bsm.audit_token_to_pidversion.return_value = 1
            bsm.audit_token_to_pid.return_value = 0
            if failure == 'missingExport':
                del bsm.audit_token_to_pidversion
            pid = b'' if failure == 'short' else struct.pack('=i', 999)
            observations = OSError(57, 'fixture disconnected socket') if failure == 'disconnected' else [pid, bytes(32)]
            with self.subTest(failure=failure), \
                    patch.object(self.control.sys, 'platform', 'darwin'), \
                    patch.object(self.control.ctypes, 'CDLL', side_effect=[lib, proc, bsm]), \
                    patch.object(self.control, '_borrow_socket', side_effect=observations):
                with self.assertRaises((self.control.ControlError, AttributeError)):
                    self.control.peer_identity(999)
                proc.proc_pidinfo.assert_not_called()


_ROLE_CASE = r'''
import array
import ctypes
import errno
import json
import os
from pathlib import Path
import select
import signal
import socket
import struct
import sys
import time
import uuid

source = Path(sys.argv[1])
case = sys.argv[2]
root = Path(sys.argv[3]).resolve()
sys.path[:0] = [str(source / 'ProviderAgent'), str(source / 'Contracts/ProviderRPC')]
import agent
import broker
import broker_control as control

fixture_exit = os._exit
owned_fixture_child = None
def physical_teardown(*unused):
    # Fixture-only exact captured-child teardown, never group/descendant discovery
    # and never a clean result. Keep this independent of patched role os._exit.
    for owner in broker._ROOTS:
        if isinstance(owner, broker._CLIResourceOwner) and owner._fixture:
            owner.fixture_teardown()
    if owned_fixture_child is not None:
        try:
            child, _ = os.waitpid(owned_fixture_child, os.WNOHANG)
            if child == 0:
                os.kill(owned_fixture_child, signal.SIGTERM)
                os.waitpid(owned_fixture_child, 0)
        except (ProcessLookupError, ChildProcessError):
            pass
    fixture_exit(97)

original_exception_hook = sys.excepthook
def failed_fixture(kind, value, traceback):
    original_exception_hook(kind, value, traceback)
    physical_teardown()
sys.excepthook = failed_fixture
signal.signal(signal.SIGTERM, physical_teardown)
signal.signal(signal.SIGALRM, physical_teardown)
signal.alarm(15)

def exact(fd, size):
    value = bytearray()
    end = time.monotonic_ns() + 5_000_000_000
    while len(value) < size:
        assert time.monotonic_ns() < end, ('readExpired', case)
        ready, _, _ = select.select([fd], [], [], max(0, (end - time.monotonic_ns()) / 1e9))
        assert ready, ('notReadable', case)
        try:
            data = os.read(fd, size - len(value))
        except BlockingIOError:
            continue
        assert data, ('EOF', case, bytes(value))
        value.extend(data)
    return bytes(value)

def message(fd):
    size, = struct.unpack('!I', exact(fd, 4))
    assert 0 < size <= 1024
    return json.loads(exact(fd, size))

def send(fd, run, op, **fields):
    raw = control.encode_control(run, op, **fields)
    while raw:
        try:
            count = os.write(fd, raw)
        except BlockingIOError:
            select.select([], [fd], [], 1)
            continue
        assert count > 0
        raw = raw[count:]

def packet(fd, value):
    raw = json.dumps(value).encode()
    os.write(fd, struct.pack('!I', len(raw)) + raw)

root.chmod(0o700)
if case == 'longCwd':
    for _ in range(4):
        root = root / ('private-directory-' + 'x' * 30)
        root.mkdir(mode=0o700)
assert case != 'longCwd' or len(os.fsencode(root)) > 104
(root / 'codex').mkdir(mode=0o700)
(root / 'tmp').mkdir(mode=0o700)
cwd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
original = os.stat('.')
run = str(uuid.uuid4())
retirement = str(uuid.uuid4())
startup = time.monotonic_ns() + (3_000_000_000 if case == 'dispatchDeadline' else 8_000_000_000)
report_r, report_w = os.pipe()
native, lifecycle = socket.socketpair()
worker = os.fork()
if worker == 0:
    signal.alarm(12)
    owned_fixture_child = None
    native.close()
    os.close(report_r)
    # Reserve the real lifecycle FD5, without overwriting another fixture owner.
    if report_w == 5:
        report_w = os.dup(report_w)
    if cwd == 5:
        cwd = os.dup(cwd)
    original_lifecycle = lifecycle.detach()
    os.dup2(original_lifecycle, 5)
    if original_lifecycle != 5:
        os.close(original_lifecycle)
    lifecycle = socket.socket(fileno=5)
    lifecycle_owner = control._Resources()
    lifecycle_owner.own('lifecycle', 5)
    # Fixture worker, not the controller, starts in the required real cwd.
    os.fchdir(cwd)
    rendezvous = control.open_worker_rendezvous(cwd, run_id=run, startup_deadline_ns=startup)
    before = os.stat('.')
    child_in, parent_in = os.pipe()
    parent_out, child_out = os.pipe()
    evidence_r, evidence_w = os.pipe()
    teardown_r, teardown_w = os.pipe()
    wrong_parent = None
    # A listener created by this worker cannot authenticate its grandchild as
    # direct child. In the wrong-parent fixture the intermediary forks broker.
    broker_pid = os.fork()
    if broker_pid:
        owned_fixture_child = broker_pid
    if broker_pid == 0 and case == 'wrongParent':
        nested = os.fork()
        if nested:
            owned_fixture_child = nested
            _, status = os.waitpid(nested, 0)
            os._exit(os.WEXITSTATUS(status))
    if broker_pid == 0:
        signal.alarm(10)
        owned_fixture_child = None
        os.close(evidence_r)
        os.close(teardown_w)
        os.close(report_w)
        lifecycle.close()
        os.close(parent_in)
        os.close(parent_out)
        # Do not inherit the worker listener as an accidental extra witness.
        os.close(rendezvous.fds['listener'])
        os.close(rendezvous.fds['cwd'])
        os.close(cwd)
        os.dup2(child_in, 0)
        os.dup2(child_out, 1)
        diagnostic = os.open('/dev/null', os.O_WRONLY)
        os.dup2(diagnostic, 2)
        os.close(diagnostic)
        os.close(child_in)
        os.close(child_out)
        os.environ.clear()
        os.environ.update(PATH='/usr/bin:/bin', LANG='C', LC_ALL='C', HOME=str(root),
                          CODEX_HOME=str(root / 'codex'), TMPDIR=str(root / 'tmp'),
                          PAPERLENS_BROKER_RUN_ID=run,
                          PAPERLENS_BROKER_START_DEADLINE_NS=str(startup))
        # These cannot choose a backend or enter the CLI replacement environment.
        os.environ['PAPERLENS_BROKER_FACTORY'] = 'fixture_true'
        os.environ['OPENAI_API_KEY'] = 'not-a-credential'
        sys.argv = ['agent.py', '--native-broker']
        raw_exit = os._exit
        raw_write = os.write
        factory_calls = []
        close_calls = []
        physical_pressure = []
        original_close = control._Role.close
        original_park = control._Role.park
        original_send_pending = control._Role.send_pending

        def checked_exit(status):
            role = next(item for item in broker._ROOTS if isinstance(item, control._Role))
            if status == 0:
                assert role.state == 'clean'
                assert all(fd is None for fd in role.fds.values())
                assert role.retirement_id == retirement
                if role.factory_entered:
                    assert role.cli.record['state'] == 'clean'
                    assert role.cli.record['scope'] == 'localDirectCLIResources'
                    assert role.cli.record['waitStatus'] is not None
                    assert all(fd is None for fd in role.cli._fds.values())
                else:
                    assert not factory_calls and not broker._INVOKED
            packet(evidence_w, dict(exit=status, calls=len(factory_calls),
                                    closes=close_calls, state=role.state,
                                    inputBytes=role.input_bytes, stdoutBytes=role.stdout_bytes,
                                    inputLines=role.input_lines, stdoutLines=role.stdout_lines,
                                    startupCounters=role.startup_counters,
                                    physicalPressure=len(physical_pressure)))
            raw_exit(status)

        def fixture_park(role):
            assert role.state == 'unknown' and role in broker._ROOTS
            cli = role.cli
            debt = dict(cli._fds) if cli is not None else None
            record = dict(cli.record) if cli is not None else None
            role_debt = dict(role.fds)
            live = {}
            for name, fd in role.fds.items():
                if fd is not None:
                    try:
                        os.fstat(fd)
                        live[name] = True
                    except OSError:
                        live[name] = False
            if cli is not None and cli.state == 'unknown':
                assert cli in broker._ROOTS
                assert cli.observe_pending()['state'] == 'unknown'
                assert cli.cleanup(retirement, terminate=True)['state'] == 'unknown'
                assert cli._fds == debt
            fork_reaped = False
            if case == 'fork':
                # Fixture-only observation after production has permanently stopped.
                assert exact(cli._fds['stdout'], 7) == b'reaped\n'
                fork_reaped = True
            if case in ('inputRecordFlood', 'inputLineFlood'):
                assert role.stdout_bytes == 0 and role.read_buffer
                assert role.input_bytes < 262160
            packet(evidence_w, dict(state=role.state, factoryEntered=role.factory_entered,
                calls=len(factory_calls), cli=record, live=live, forkReaped=fork_reaped,
                closes=close_calls, roots=len(broker._ROOTS)))
            assert exact(teardown_r, 1) == b'T'
            if cli is not None:
                cli.fixture_teardown()  # Physical fixture action, NOT proof discharge.
                assert dict(cli.record) == record and cli._fds == debt
            assert role.state == 'unknown' and role.fds == role_debt
            packet(evidence_w, dict(teardown=True, state=role.state))
            original_park(role)

        def role_close(role, name, deadline=None):
            close_calls.append(name)
            if case == 'afterCleanClose' and name == 'stdin':
                assert role.cli.state == 'clean'
                os.close(role.fds[name])  # Real EBADF in checked raw close path.
            if case == 'afterCleanEINTR' and name == 'stdin':
                assert role.cli.state == 'clean'
                role.lib = ctypes.CDLL('/usr/lib/libSystem.B.dylib', use_errno=True)
                role.lib.close.argtypes, role.lib.close.restype = [ctypes.c_int], ctypes.c_int
                def injected_close(fd):
                    assert fd == role.fds['stdin']
                    ctypes.set_errno(errno.EINTR)
                    return -1  # Injected error; the actual descriptor stays open.
                role.lib.close = injected_close
            result = original_close(role, name, deadline)
            if case == 'lateClose' and name == 'stdin':
                # Inject a delayed return after the actual checked close.
                time.sleep(0.35)
            return result

        def send_pending(role, deadline=None):
            if case == 'preHelloRevoke' and role.retirement_id is None:
                packet(evidence_w, dict(helloPending=True))
                assert exact(teardown_r, 1) == b'H'
            if case == 'afterCleanSend' and role.cli is not None and role.cli.state == 'clean':
                os.close(role.fds['control'])  # Actual EBADF, not a fabricated ACK.
            return original_send_pending(role, deadline)

        def factory(fd, environment):
            factory_calls.append(1)
            assert set(environment) == broker._ENV_KEYS
            assert environment['HOME'] == str(root)
            chosen = broker.fixture_true if case == 'earlyExit' else (
                broker.fixture_fork if case == 'fork' else (
                    broker.fixture_stdin_sink if case in ('inputRecordFlood', 'inputLineFlood', 'dispatchSink', 'dispatchBytes')
                    else broker.fixture_cat))
            cli = chosen(fd, environment)
            if case == 'fork':
                actual_resume = cli.resume
                def resumed_after_real_fork_reap():
                    result = actual_resume()
                    # This fixture's sole line is written only after its real
                    # child waitpid. Leave bytes untouched for unknown inspection.
                    ready, _, _ = select.select([cli._fds['stdout']], [], [], 5)
                    assert ready
                    return result
                cli.resume = resumed_after_real_fork_reap
            if case == 'watchError':
                def failed_events(*args):
                    raise broker.OwnershipError('injectedWatchError')
                cli._kevents = failed_events
            if case == 'waitECHILD':
                def failed_wait(*args):
                    ctypes.set_errno(errno.ECHILD)
                    return -1  # Injected errno, not an actual external reap.
                cli._spawn.lib.waitpid = failed_wait
            if case == 'factoryRevoke':
                packet(evidence_w, dict(factoryCaptured=True))
                assert exact(teardown_r, 1) == b'R'
            return cli

        if case == 'dispatchPressure':
            def observed_write(fd, data):
                try:
                    return raw_write(fd, data)
                except BlockingIOError:
                    if fd == 1:
                        physical_pressure.append(True)  # Actual kernel EAGAIN, not injection.
                    raise
            os.write = observed_write
        if case == 'partialIO':
            attempts = {}
            def partial_write(fd, data):
                role = next((item for item in broker._ROOTS if isinstance(item, control._Role)), None)
                if role is not None and role.cli is not None and fd in (1, role.cli._fds.get('stdin')):
                    attempts[fd] = attempts.get(fd, 0) + 1
                    if attempts[fd] % 3 == 1:
                        raise BlockingIOError(errno.EAGAIN, 'injected')
                    return raw_write(fd, data[:3])
                return raw_write(fd, data)
            os.write = partial_write
        control._Role.park = fixture_park
        control._Role.close = role_close
        control._Role.send_pending = send_pending
        if case == 'wrongParent':
            actual_peer_identity = control.peer_identity
            def observe_listener_after_worker_rejection(fd):
                # Keep this actual grandchild connected while the worker
                # observes its kernel parent, before the role refuses itself.
                assert exact(teardown_r, 1) == b'a'
                return actual_peer_identity(fd)
            control.peer_identity = observe_listener_after_worker_rejection
        os._exit = checked_exit
        agent.main(_broker_resource_factory=factory)
        raise AssertionError('role returned')

    os.close(child_in)
    os.close(child_out)
    os.close(evidence_w)
    os.close(teardown_r)
    if case == 'wrongParent':
        try:
            rendezvous.accept_broker()
        except control.ControlError:
            assert rendezvous.state == 'unknown'
            assert rendezvous.accepted.peer.parent_pid != os.getpid()
        else:
            raise AssertionError('grandchild admitted')
        os.write(teardown_w, b'a')
        refused = message(evidence_r)
        assert refused['exit'] == 1 and refused['calls'] == 0
        pid, status = os.waitpid(broker_pid, 0)
        assert pid == broker_pid and os.WIFEXITED(status) and os.WEXITSTATUS(status) == 1
        packet(report_w, dict(case=case, outcome='refused'))
        os._exit(0)
    authenticated = rendezvous.accept_broker()
    assert authenticated.peer.pid == broker_pid
    assert authenticated.peer.parent_pid == os.getpid()
    assert authenticated.peer.uid == os.getuid() and len(authenticated.peer.token) == 32
    assert (os.stat('.').st_dev, os.stat('.').st_ino) == (before.st_dev, before.st_ino)
    try:
        rendezvous.accept_broker()
    except control.ControlError:
        pass
    else:
        raise AssertionError('second admission')
    fd = authenticated.fds['control']
    if case == 'scmRights':
        assert lifecycle.fileno() == 5
        rendezvous.offer_to_native(5, authenticated)
        packet(report_w, dict(worker=os.getpid(), broker=broker_pid))
        instruction = message(lifecycle.fileno())
        assert instruction['op'] == 'reapBroker' and instruction['runID'] == run
        retirement = instruction['retirementID']
        reaped = authenticated.wait_direct_child(retirement)
        assert reaped.wait_status == 0
        rendezvous.retire(retirement)
        assert rendezvous.state == 'clean' and rendezvous.entry is None
        send(lifecycle.fileno(), run, 'brokerReaped', retirementID=retirement, waitStatus=reaped.wait_status)
        lifecycle_owner.latch(retirement)
        lifecycle_owner.close('lifecycle')
        lifecycle.detach()
        packet(report_w, dict(case=case, outcome='clean'))
        os._exit(0)
    if case == 'preHelloRevoke':
        assert message(evidence_r)['helloPending']
        send(fd, run, 'revoke', retirementID=retirement)
        os.write(teardown_w, b'H')
    assert message(fd)['op'] == 'hello'
    if case == 'preHelloRevoke':
        retired = message(fd)
        assert retired['op'] == 'preLaunchRetired' and retired['retirementID'] == retirement
    elif case in ('preFactory', 'preFactoryRun'):
        raw = control.encode_control(run, 'revoke', retirementID=retirement)
        if case == 'preFactoryRun':
            info = os.fstat(cwd)
            raw = control.encode_control(run, 'run', startupDeadlineNs=startup,
                                        cwdDevice=info.st_dev, cwdInode=info.st_ino) + raw
        os.write(fd, raw)
        retired = message(fd)
        assert retired['op'] == 'preLaunchRetired'
    elif case == 'earlyDispatch':
        send(fd, run, 'dispatch')
    else:
        info = os.fstat(cwd)
        send(fd, run, 'run', startupDeadlineNs=startup, cwdDevice=info.st_dev,
             cwdInode=info.st_ino + (1 if case == 'wrongNamespace' else 0))
        if case == 'factoryRevoke':
            assert message(evidence_r)['factoryCaptured']
            send(fd, run, 'revoke', retirementID=retirement)
            os.write(teardown_w, b'R')
            retired = message(fd)
            assert retired['op'] == 'cliRetired'
        elif case in ('fork', 'watchError', 'wrongNamespace'):
            retired = None
        else:
            running = message(fd)
            assert running['op'] == 'running'
            if case.startswith('dispatch') or case in ('duplicateDispatch', 'staleDispatch'):
                if case == 'dispatchPartial':
                    os.write(parent_in, b'prefix\x00')
                    assert exact(parent_out, 7) == b'prefix\x00'
                send(fd, run, 'dispatch')
                ack = message(fd)
                assert ack == dict(v=2, runID=run, op='dispatching')
                if case == 'dispatchDeadline':
                    time.sleep(max(0, (startup - time.monotonic_ns()) / 1e9) + 0.05)
                if case in ('dispatchCat', 'dispatchPartial', 'dispatchDeadline'):
                    payload = b'opaque\x00 live\n' if case != 'dispatchPartial' else b' tail\n'
                    os.write(parent_in, payload)
                    assert exact(parent_out, len(payload)) == payload
                if case == 'dispatchSink':
                    os.write(parent_in, b'not echoed\x00\n')
                    assert not select.select([parent_out], [], [], 0.02)[0]
                if case == 'dispatchPressure':
                    payload = (b'opaque\x00' + b'x' * 64992 + b'\n') * 4
                    assert len(payload) == 260000
                    for offset in range(0, len(payload), 4096):
                        os.write(parent_in, payload[offset:offset + 4096])
                    time.sleep(0.05)  # Parent deliberately withholds the real pipe drain.
                    assert exact(parent_out, len(payload)) == payload
            if case in ('cat', 'longCwd', 'partialIO'):
                for data in (b'opaque\x00', b' split', b'\nsecond\n'):
                    os.write(parent_in, data)
                    assert exact(parent_out, len(data)) == data
            if case == 'earlyExit':
                needed = message(fd)
                assert needed['op'] == 'revokeNeeded' and needed['code'] in ('cliExit', 'stdioEOF')
            if case == 'dispatchRecords':
                for _ in range(255):
                    os.write(parent_in, b'x\n')
                    assert exact(parent_out, 2) == b'x\n'
                os.write(parent_in, b'last\nnot admitted\n')
            elif case == 'dispatchBytes':
                data = (b'x' * 65539 + b'\n') * 4 + b'!'
                while data:
                    count = os.write(parent_in, data[:4096])
                    data = data[count:]
            elif case in ('duplicateDispatch', 'staleDispatch'):
                send(fd, str(uuid.uuid4()) if case == 'staleDispatch' else run, 'dispatch')
            elif case == 'inputRecordFlood':
                os.write(parent_in, b'a\nb\nc\nd\ne\n')
            elif case == 'inputLineFlood':
                data = b'x' * 65541
                while data:
                    count = os.write(parent_in, data[:4096])
                    data = data[count:]
            elif case == 'cumulativeFlood':
                for _ in range(3):
                    os.write(parent_in, b'x\n')
                    assert exact(parent_out, 2) == b'x\n'
                os.write(parent_in, b'fourth\nfifth\n')
            elif case == 'lineFlood':
                data = b'x' * 65541
                while data:
                    count = os.write(parent_in, data[:4096])
                    data = data[count:]
                    # Drain startup output but never reset its record counter.
                    ready, _, _ = select.select([parent_out], [], [], 0.01)
                    if ready:
                        os.read(parent_out, 4096)
            elif case == 'controlEOF':
                os.close(fd)
            elif case == 'badLength':
                os.write(fd, struct.pack('!I', 1025))
            elif case == 'badJSON':
                raw = b'{"v":1,"v":1}'
                os.write(fd, struct.pack('!I', len(raw)) + raw)
            elif case == 'duplicateRun':
                send(fd, run, 'run', startupDeadlineNs=startup, cwdDevice=info.st_dev, cwdInode=info.st_ino)
            elif case in ('boolRetirement', 'numericRetirement', 'nonV4Retirement', 'noncanonicalRetirement'):
                value = {'boolRetirement': True, 'numericRetirement': 123,
                         'nonV4Retirement': str(uuid.UUID(int=0)),
                         'noncanonicalRetirement': retirement.upper()}[case]
                packet(fd, dict(v=2, runID=run, op='revoke', retirementID=value))
            elif case == 'oldVersion':
                packet(fd, dict(v=1, runID=run, op='revoke', deadlineNs=123))
            else:
                raw = control.encode_control(run, 'revoke', retirementID=retirement)
                if case in ('duplicateRetirement', 'dispatchDuplicateRetirement'):
                    raw += raw
                if case == 'changedRetirement':
                    raw += control.encode_control(run, 'revoke', retirementID=str(uuid.uuid4()))
                if case == 'partialControl':
                    raw += b'\x00\x00'
                os.write(fd, raw)
                if case not in ('changedRetirement', 'waitECHILD', 'afterCleanSend'):
                    retired = message(fd)
                    assert retired['op'] == 'cliRetired' and retired['retirementID'] == retirement
                    assert retired['scope'] == 'localDirectCLIResources'
    if case in ('cumulativeFlood', 'lineFlood', 'inputRecordFlood', 'inputLineFlood', 'dispatchRecords', 'dispatchBytes'):
        needed = message(fd)
        assert needed['op'] == 'revokeNeeded' and needed['code'] == 'sessionLimit'
        send(fd, run, 'revoke', retirementID=retirement)
        retired = message(fd)
        assert retired['op'] == 'cliRetired' and retired['retirementID'] == retirement
        assert retired['scope'] == 'localDirectCLIResources'
    unknown = case in ('fork', 'watchError', 'wrongNamespace', 'waitECHILD', 'controlEOF',
        'earlyDispatch', 'duplicateDispatch', 'staleDispatch',
        'badLength', 'badJSON', 'duplicateRun', 'boolRetirement', 'numericRetirement',
        'nonV4Retirement', 'noncanonicalRetirement', 'oldVersion', 'changedRetirement', 'afterCleanClose', 'afterCleanEINTR', 'afterCleanSend',
        'partialControl')
    if unknown:
        evidence = message(evidence_r)
        assert evidence['state'] == 'unknown'
        if case in ('afterCleanClose', 'afterCleanEINTR'):
            assert evidence['cli']['state'] == 'clean'
            assert evidence['closes'].count('stdin') == 1
            assert evidence['live']['stdin'] == (case == 'afterCleanEINTR')
        elif case == 'afterCleanSend':
            assert evidence['cli']['state'] == 'clean' and not evidence['live']['control']
        elif case == 'partialControl':
            assert evidence['cli']['state'] == 'clean' and evidence['live']['control']
        elif case in ('wrongNamespace', 'earlyDispatch'):
            assert evidence['cli'] is None and not evidence['factoryEntered']
        else:
            assert evidence['cli']['state'] == 'unknown'
        assert evidence['roots'] >= 2
        assert evidence['forkReaped'] == (case == 'fork')
        os.write(teardown_w, b'T')
        assert message(evidence_r) == dict(teardown=True, state='unknown')
        os.kill(broker_pid, signal.SIGKILL)  # Fixture physical teardown only.
        pid, status = os.waitpid(broker_pid, 0)
        assert pid == broker_pid and os.WIFSIGNALED(status)
        assert authenticated.reaped is None
        packet(report_w, dict(case=case, outcome='unknown'))
    else:
        record = authenticated.wait_direct_child(retirement)
        assert record.wait_status == 0 and record.retirement_id == retirement
        evidence = message(evidence_r)
        assert evidence['exit'] == 0 and evidence['state'] == 'clean'
        assert evidence['inputBytes'] <= 262160 and evidence['stdoutBytes'] <= 262160
        if case == 'dispatchRecords':
            assert evidence['inputLines'] == 256 and evidence['inputBytes'] == 515
        if case == 'dispatchBytes':
            assert evidence['inputBytes'] == 262160 and evidence['inputLines'] == 4
            assert evidence['stdoutBytes'] == 0
        if case == 'dispatchPartial':
            assert evidence['startupCounters'] == [7, 0, 7, 7, 0, 7, 0]
            assert evidence['inputBytes'] == 13 and evidence['stdoutBytes'] == 13
        if case == 'dispatchPressure':
            assert evidence['physicalPressure'] > 0
            assert evidence['inputBytes'] == 260000 and evidence['stdoutBytes'] == 260000
        assert evidence['calls'] == (0 if case in ('preFactory', 'preFactoryRun', 'preHelloRevoke') else 1)
        rendezvous.retire(retirement)
        assert rendezvous.state == 'clean'
        packet(report_w, dict(case=case, outcome='clean'))
    os._exit(0)

owned_fixture_child = worker
lifecycle.close()
os.close(report_w)
if case == 'scmRights':
    offered = message(report_r)
    # Receive/capture all actual descriptors BEFORE validating the ancillary data.
    marker, ancillary, flags, _ = native.recvmsg(1, socket.CMSG_SPACE(8 * array.array('i').itemsize))
    received = []
    for level, kind, raw in ancillary:
        assert level == socket.SOL_SOCKET and kind == socket.SCM_RIGHTS
        rights = array.array('i')
        rights.frombytes(raw[:len(raw) - len(raw) % rights.itemsize])
        received.extend(rights)
    assert marker == b'B' and not flags & (socket.MSG_CTRUNC | socket.MSG_TRUNC)
    assert len(received) == 1
    endpoint = received[0]
    identity = control.peer_identity(endpoint)
    assert identity.pid == offered['broker'] and identity.parent_pid == worker == offered['worker']
    # The lifecycle socketpair peer PID is its creator, not worker authority.
    assert message(native.fileno())['op'] == 'brokerOffered'
    assert message(endpoint)['op'] == 'hello'
    info = os.fstat(cwd)
    send(endpoint, run, 'run', startupDeadlineNs=startup, cwdDevice=info.st_dev, cwdInode=info.st_ino)
    assert message(endpoint)['op'] == 'running'
    send(endpoint, run, 'revoke', retirementID=retirement)
    retired = message(endpoint)
    assert retired['op'] == 'cliRetired' and retired['scope'] == 'localDirectCLIResources'
    send(native.fileno(), run, 'reapBroker', retirementID=retirement)
    reaped = message(native.fileno())
    assert reaped['op'] == 'brokerReaped' and reaped['waitStatus'] == 0
    assert reaped['retirementID'] == retirement
    os.close(endpoint)  # Fixture Native-owned duplicate, not worker's witness.
result = message(report_r)
pid, status = os.waitpid(worker, 0)
assert pid == worker and os.WIFEXITED(status) and os.WEXITSTATUS(status) == 0
assert (os.stat('.').st_dev, os.stat('.').st_ino) == (original.st_dev, original.st_ino)
assert result['case'] == case
print(json.dumps(result))
'''


@unittest.skipUnless(sys.platform == 'darwin', 'authenticated public Darwin broker role')
class DarwinBrokerRoleTests(unittest.TestCase):
    def test_direct_authenticated_close_is_irreversible_after_retirement(self):
        script = r'''
import ctypes
import errno
import os
from pathlib import Path
import signal
import socket
import sys
import time
import uuid
from unittest.mock import patch
source, case = Path(sys.argv[1]), sys.argv[2]
sys.path[:0] = [str(source / 'ProviderAgent'), str(source / 'Contracts/ProviderRPC')]
import broker_control as control
cwd = os.open('.', os.O_RDONLY | os.O_DIRECTORY)
rendezvous = control.open_worker_rendezvous(
    cwd, run_id=str(uuid.uuid4()),
    startup_deadline_ns=time.monotonic_ns() + 5_000_000_000)
child = os.fork()
if child == 0:
    for fd in rendezvous.fds.values():
        os.close(fd)
    os.close(cwd)
    peer = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    peer.connect('b')
    os.read(peer.fileno(), 1)
    os._exit(0)
owner = None
try:
    owner = rendezvous.accept_broker()
    assert owner.peer.pid == child and owner.peer.parent_pid == os.getpid()
    owner.own('other', os.dup(cwd))
    actual_fstat = os.fstat
    raw = ctypes.CDLL('/usr/lib/libSystem.B.dylib', use_errno=True)
    raw.close.argtypes, raw.close.restype = [ctypes.c_int], ctypes.c_int
    close_calls = []
    owner.lib = raw
    retirement = str(uuid.uuid4())
    if case == 'failedWait':
        def failed_wait(*args):
            ctypes.set_errno(errno.ECHILD)
            return -1  # Injected wait failure; the actual child remains owned.
        raw.waitpid = failed_wait
        with patch.object(control.ctypes, 'CDLL', return_value=raw):
            try:
                owner.wait_direct_child(retirement)
            except control.ControlError:
                pass
            else:
                raise AssertionError('injected failed wait succeeded')
    else:
        owner.latch(retirement)
        if case == 'unknown':
            owner.unknown()
        elif case == 'eintr':
            def injected_close(fd):
                close_calls.append(fd)
                ctypes.set_errno(errno.EINTR)
                return -1  # Actual descriptor stays open; never an OS EINTR claim.
            raw.close = injected_close
    def refuse(name, explicit=None):
        try:
            owner.close(name, explicit)
        except control.ControlError:
            return
        raise AssertionError(('descriptor effect accepted', case, name))
    with patch.object(control.os, 'fstat', wraps=actual_fstat) as observations:
        explicit = {'startupBound': time.monotonic_ns() + 300_000_000, 'bool': True,
                    'float': 1.0, 'huge': 1 << 64}.get(case)
        refuse('control', explicit)
        assert owner.state == 'unknown' and owner.fds['control'] is not None
        before = observations.call_count
        refuse('control', time.monotonic_ns() + 1)
        refuse('other')
        assert observations.call_count == before, 'observation after uncertainty'
        assert len(close_calls) == (1 if case == 'eintr' else 0)
        for fd in owner.fds.values():
            actual_fstat(fd)
    snapshot = dict(owner.fds)
finally:
    # Physical fixture teardown, never callable-owner cleanup or debt discharge.
    if owner is not None:
        before_state, before_fds = owner.state, dict(owner.fds)
        for fd in owner.fds.values():
            if fd is not None:
                os.close(fd)
        assert owner.state == before_state and owner.fds == before_fds
    os.kill(child, signal.SIGKILL)
    pid, _ = os.waitpid(child, 0)
    assert pid == child
    for fd in rendezvous.fds.values():
        os.close(fd)
    os.close(cwd)
'''
        for case in ('unknown', 'eintr', 'failedWait', 'startupBound', 'bool', 'float', 'huge'):
            with self.subTest(case=case), tempfile.TemporaryDirectory() as directory:
                root = Path(directory).resolve()
                root.chmod(0o700)
                result = subprocess.run(
                    [sys.executable, '-I', '-B', '-c', script, str(ROOT), case],
                    env=environment(root), cwd=root, capture_output=True, timeout=10, check=False)
                self.assertEqual(result.returncode, 0, result.stderr.decode('utf-8', 'replace'))

    def test_missing_listener_is_actual_pre_cli_nonzero_refusal(self):
        script = r'''
import os
from pathlib import Path
import sys
root = Path(sys.argv[1])
sys.path[:0] = [str(root / 'ProviderAgent'), str(root / 'Contracts/ProviderRPC')]
import agent
def forbidden(*args):
    raise AssertionError('factory entered without listener')
sys.argv = ['agent.py', '--native-broker']
agent.main(_broker_resource_factory=forbidden)
raise AssertionError('role returned')
'''
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            root.chmod(0o700)
            values = dict(environment(root), PAPERLENS_BROKER_RUN_ID=str(uuid.uuid4()),
                          PAPERLENS_BROKER_START_DEADLINE_NS=str(time.monotonic_ns() + 5_000_000_000))
            result = subprocess.run([sys.executable, '-I', '-B', '-c', script, str(ROOT)],
                                    env=values, cwd=root, capture_output=True, timeout=10, check=False)
            self.assertEqual(result.returncode, 1, result.stderr.decode('utf-8', 'replace'))
            self.assertEqual(result.stdout, b'')
            self.assertFalse((root / 'b').exists())

    def test_existing_relative_entry_is_not_unlinked_or_repaired(self):
        script = r'''
import os
from pathlib import Path
import sys
import time
import uuid
source = Path(sys.argv[1])
sys.path[:0] = [str(source / 'ProviderAgent'), str(source / 'Contracts/ProviderRPC')]
import broker
import broker_control as control
fd = os.open('.', os.O_RDONLY | os.O_DIRECTORY)
before = os.stat('b', follow_symlinks=False)
try:
    control.open_worker_rendezvous(fd, run_id=str(uuid.uuid4()),
                                   startup_deadline_ns=time.monotonic_ns() + 1_000_000_000)
except control.ControlError:
    owner = broker._ROOTS[-1]
    assert owner.state == 'unknown' and owner.fds['cwd'] is not None
    os.fstat(owner.fds['cwd'])
else:
    raise AssertionError('unknown entry replaced')
after = os.stat('b', follow_symlinks=False)
assert (before.st_dev, before.st_ino, before.st_mode) == (after.st_dev, after.st_ino, after.st_mode)
assert Path('b').read_bytes() == b'untouched'
snapshot = dict(owner.fds)
os.close(owner.fds['cwd'])  # Fixture-only physical teardown, not a debt discharge.
assert owner.state == 'unknown' and owner.fds == snapshot
os.close(fd)
'''
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            root.chmod(0o700)
            (root / 'b').write_bytes(b'untouched')
            result = subprocess.run([sys.executable, '-I', '-B', '-c', script, str(ROOT)],
                                    env=environment(root), cwd=root, capture_output=True,
                                    timeout=10, check=False)
            self.assertEqual(result.returncode, 0, result.stderr.decode('utf-8', 'replace'))

    def test_actual_fresh_role_lifecycle_and_retained_unknown(self):
        unknown = {'fork', 'watchError', 'wrongNamespace', 'waitECHILD', 'controlEOF',
                   'earlyDispatch', 'duplicateDispatch', 'staleDispatch',
                   'badLength', 'badJSON', 'duplicateRun', 'boolRetirement', 'numericRetirement',
                   'nonV4Retirement', 'noncanonicalRetirement', 'oldVersion', 'changedRetirement', 'afterCleanClose', 'afterCleanEINTR', 'afterCleanSend',
                   'partialControl'}
        cases = ('cat', 'partialIO', 'earlyExit', 'preFactory', 'preFactoryRun', 'preHelloRevoke', 'factoryRevoke', 'longCwd',
                 'cumulativeFlood', 'lineFlood', 'inputRecordFlood', 'inputLineFlood',
                 'dispatchCat', 'dispatchPartial', 'dispatchDeadline', 'dispatchSink', 'dispatchRecords', 'dispatchBytes',
                 'dispatchDuplicateRetirement', 'lateClose',
                 'dispatchPressure',
                 'duplicateRetirement', 'scmRights', 'wrongParent', *sorted(unknown))
        for case in cases:
            with self.subTest(case=case), tempfile.TemporaryDirectory() as directory:
                root = Path(directory).resolve()
                result = subprocess.run(
                    [sys.executable, '-I', '-B', '-c', _ROLE_CASE, str(ROOT), case, str(root)],
                    env=environment(root), capture_output=True, timeout=20, check=False)
                self.assertEqual(result.returncode, 0, result.stderr.decode('utf-8', 'replace'))
                record = json.loads(result.stdout)
                self.assertEqual(record['outcome'], 'unknown' if case in unknown else (
                    'refused' if case == 'wrongParent' else 'clean'))


if __name__ == '__main__':
    unittest.main()
