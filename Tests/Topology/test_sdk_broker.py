"""Offline public-Darwin fixtures; no SDK import, Agent role, or worker integration.

Every actual owner lives in a fresh -I -B native Python process. Unknown roots and
one-shot invocation state are never reset, including by physical fixture teardown.
"""
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

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
    assert owner.cleanup(time.monotonic_ns() + 300_000_000, terminate=True)['state'] == 'unknown'
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
        broker.fixture_cat if case in ('cat', 'expired', 'tooFar', 'changedDeadline',
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
        assert owner.cleanup(time.monotonic_ns() + 300_000_000)['state'] == 'clean'
    else:
        assert owner.resume()['state'] == 'running'
        endpoints = dict(owner.endpoints)
        if case == 'cat':
            assert os.write(endpoints['stdin'], b'fixture-echo\n') == 13
            deadline = time.monotonic_ns() + 300_000_000
            assert owner.close_stdin(deadline)['state'] == 'running'
            assert owner._fds['stdin'] is None
            assert readable(endpoints['stdout'], deadline) == b'fixture-echo\n'
            assert owner.cleanup(deadline)['state'] == 'clean'
        elif case == 'fork':
            # This fixed output is emitted only AFTER the real fixture parent
            # waitpid has reaped its immediate fork. Descendant absence is NOT proof.
            assert readable(endpoints['stdout'], time.monotonic_ns() + 5_000_000_000) == b'reaped\n'
            snapshot = dict(owner._fds)
            assert owner.cleanup(time.monotonic_ns() + 300_000_000)['state'] == 'unknown'
            assert owner._wait_status is None
            retained(snapshot)
            os.fstat(owner._fds['kqueue'])
        elif case in ('expired', 'tooFar'):
            snapshot = dict(owner._fds)
            queue_fd = owner._fds['kqueue']
            deadline = time.monotonic_ns() + (
                -1_000_000_000 if case == 'expired' else 1_000_000_000)
            assert owner.cleanup(deadline, terminate=True)['state'] == 'unknown'
            assert owner._deadline is None
            assert owner._wait_status is None and not owner._exit_observed
            assert owner._fds['kqueue'] == queue_fd
            os.kill(owner.pid, 0)  # Actual cat is still owned and alive.
            retained(snapshot)
        elif case == 'changedDeadline':
            deadline = time.monotonic_ns() + 300_000_000
            owner.close_stdin(deadline)
            assert owner._fds['stdin'] is None
            snapshot = dict(owner._fds)
            assert owner.cleanup(deadline - 1_000_000)['state'] == 'unknown'
            assert owner._deadline == deadline
            retained(snapshot)
        elif case == 'facadeLoss':
            snapshot = dict(owner._fds)
            owner.cleanup(time.monotonic_ns() - 1_000_000_000)
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
            assert owner.cleanup(time.monotonic_ns() + 300_000_000)['state'] == 'unknown'
            assert owner._exit_observed and owner._wait_status is not None
            assert owner._fds['stdout'] == endpoints['stdout']
            assert 'stdout' in owner._uncertain_fds
            assert owner._fds['stderr'] is not None
            os.fstat(owner._fds['stderr'])
            os.fstat(owner._fds['kqueue'])
            snapshot = dict(owner._fds)
            assert owner.cleanup(time.monotonic_ns() + 300_000_000)['state'] == 'unknown'
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
            assert owner.cleanup(time.monotonic_ns() + 300_000_000)['state'] == 'unknown'
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
            assert owner.cleanup(time.monotonic_ns() + 300_000_000, terminate=True)['state'] == 'clean'
            assert os.WIFSIGNALED(owner._wait_status)
            assert os.WTERMSIG(owner._wait_status) == signal.SIGKILL
        elif case == 'true':
            descriptors = tuple(fd for fd in owner._fds.values() if fd is not None)
            assert owner.cleanup(time.monotonic_ns() + 300_000_000)['state'] == 'clean'
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
        assert time.monotonic_ns() < owner._deadline
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
    assert owner.cleanup(time.monotonic_ns() + 300_000_000, terminate=True)['state'] == 'unknown'
    assert owner.close_stdin(time.monotonic_ns() + 300_000_000)['state'] == 'unknown'
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
    def test_deadline_is_uint64_monotonic_nanoseconds_without_conversion_or_reset(self):
        now = 9_000_000_000
        for deadline in (True, False, float(now + 1), None, -1, 1 << 64,
                         now, now - 1, now + 300_000_001):
            with self.subTest(deadline=deadline), \
                    patch.object(broker.time, 'monotonic_ns', return_value=now):
                owner = broker._CLIResourceOwner(False)
                with self.assertRaises(broker.OwnershipError):
                    owner._begin_cleanup(deadline)
                self.assertIsNone(owner._deadline)
                self.assertEqual(owner._fds, {})
        owner = broker._CLIResourceOwner(False)
        deadline = now + 300_000_000
        with patch.object(broker.time, 'monotonic_ns', return_value=now):
            owner._begin_cleanup(deadline)
            owner._begin_cleanup(deadline)
            with self.assertRaises(broker.OwnershipError):
                owner._begin_cleanup(deadline - 1_000_000)
        self.assertEqual(owner._deadline, deadline)
        with patch.object(broker.time, 'monotonic_ns', return_value=deadline):
            with self.assertRaises(broker.OwnershipError):
                owner._clock()

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
        for case in ('suspended', 'true', 'cat', 'fork', 'expired', 'tooFar',
                     'changedDeadline', 'facadeLoss', 'badClose', 'terminate',
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
                    'fork', 'expired', 'tooFar', 'changedDeadline', 'facadeLoss',
                    'badClose', 'badRegistration', 'injectedCloseEINTR') else 'clean')


if __name__ == '__main__':
    unittest.main()
