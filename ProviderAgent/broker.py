"""Callable Darwin CLI ownership primitive, not an Agent role or SDK transport.

Setup, kevent, close and waitpid can block. A future native enclosing owner must
supply its own independent deadline; this Python primitive is NOT bounded.
The queue is a raw public libc kqueue, not a Python wrapper whose close can
discard errors or whose destructor could close a reused descriptor.
Endpoints are borrowed raw descriptors, never transferred closure authority.
There are no output/diagnostic buffers here. A future transport must bound its
own buffers. A clean record proves only this no-fork direct CLI's resources,
not SDK FileObject closure, content purge, absent=true, or full P3.
"""
from __future__ import annotations

import ctypes
import os
from pathlib import Path
import select
import signal
import stat
import sys
import time
from types import MappingProxyType

# Public Darwin sys/spawn.h and spawn.h: opaque handles are void *, pid_t int,
# flags short, sigset_t uint32_t. No private spawn or process interfaces.
_START_SUSPENDED = 0x0080
_CLOEXEC_DEFAULT = 0x4000
_SETSIGDEF = 0x0004
_SETSIGMASK = 0x0008
# Public sys/event.h; CPython select does not export EV_RECEIPT.
_EV_RECEIPT = 0x0040
_ENV_KEYS = frozenset(('PATH', 'LANG', 'LC_ALL', 'HOME', 'CODEX_HOME', 'TMPDIR'))
_ROOTS = []                         # Deliberate process-lifetime actual owners.
_INVOKED = False                    # One invocation, including failed setup.
_FORK_SNIPPET = (
    'import os; s=os.stat("."); h=os.stat(os.environ["HOME"]); '
    'assert (s.st_dev,s.st_ino) == (h.st_dev,h.st_ino); '
    'p=os.fork(); '
    'os._exit(0) if p == 0 else None; '
    'r,s=os.waitpid(p,0); '
    'assert r == p and os.WIFEXITED(s); '
    'os.write(1,b"reaped\\n")'
)


class OwnershipError(RuntimeError):
    """A fixed, non-diagnostic local failure code; never arbitrary CLI output."""


def _environment(environment):
    if not isinstance(environment, dict) or set(environment) != _ENV_KEYS:
        raise ValueError('closedEnvironmentRequired')
    result = dict(environment)
    for value in result.values():
        if (not isinstance(value, str) or not value or len(value.encode('utf-8')) > 4096
                or any(ord(c) < 32 or ord(c) == 127 for c in value)):
            raise ValueError('invalidEnvironment')
    # No empty/relative PATH component (and thus no implicit cwd or host lookup).
    for value in [*result['PATH'].split(':'), result['HOME'],
                  result['CODEX_HOME'], result['TMPDIR']]:
        path = Path(value)
        if not path.is_absolute() or str(path) != value or '..' in path.parts or value == '/':
            raise ValueError('invalidEnvironmentPath')
    return result


def _platform():
    if sys.platform != 'darwin':
        raise PermissionError('darwinRequired')


def _production_command():
    # This is the sole production selector. Never accept a caller path/argv,
    # resolve PATH, or fall back to a host interpreter, SDK, or another binary.
    base = Path(__file__).resolve(strict=True).parent.parent
    command = base / 'MacOS' / 'codex'
    resolved = command.resolve(strict=True)
    if not resolved.is_relative_to(base):
        raise PermissionError('externalCLIResolution')
    info = command.stat()
    if not stat.S_ISREG(info.st_mode) or not info.st_mode & 0o111:
        raise PermissionError('invalidPackagedCLI')
    return (str(command), 'app-server', '--listen', 'stdio://')


def production(cwd_fd, environment):
    """Spawn only Resources/../MacOS/codex suspended and register before resume.

    environment is a complete replacement supplied by the trusted native worker;
    cwd_fd is a borrowed real private directory descriptor. No worker exists yet.
    """
    _platform()
    environment = _environment(environment)
    return _create(_production_command(), cwd_fd, environment, fixture=False)


def fixture_true(cwd_fd, environment):
    """Controlled OS fixture, not a production fallback."""
    _platform()
    return _create(('/usr/bin/true',), cwd_fd, _environment(environment), fixture=True)


def fixture_cat(cwd_fd, environment):
    """Controlled stdio fixture, not a production fallback."""
    _platform()
    return _create(('/bin/cat',), cwd_fd, _environment(environment), fixture=True)


def fixture_stdin_sink(cwd_fd, environment):
    """Controlled non-echoing consumer; output limits cannot mask input faults."""
    _platform()
    return _create((str(Path(sys.executable).resolve(strict=True)), '-I', '-B', '-c',
                    'import os\nwhile os.read(0, 4096): pass'),
                   cwd_fd, _environment(environment), fixture=True)


def fixture_fork(cwd_fd, environment):
    """Fixed host-Python fixture; its direct parent actually reaps its fork."""
    _platform()
    return _create((str(Path(sys.executable).resolve(strict=True)), '-I', '-B', '-c',
                    _FORK_SNIPPET), cwd_fd, _environment(environment), fixture=True)


class _Kevent(ctypes.Structure):
    # Public Darwin sys/event.h explicitly uses #pragma pack(4).
    _pack_ = 4
    _fields_ = [('ident', ctypes.c_size_t), ('filter', ctypes.c_int16),
                ('flags', ctypes.c_uint16), ('fflags', ctypes.c_uint32),
                ('data', ctypes.c_ssize_t), ('udata', ctypes.c_void_p)]


class _Timespec(ctypes.Structure):
    # Public arm/_types.h and sys/_types/_timespec.h: time_t and nsec long.
    _fields_ = [('tv_sec', ctypes.c_long), ('tv_nsec', ctypes.c_long)]


class _DarwinSpawn:
    def __init__(self):
        self.lib = ctypes.CDLL('/usr/lib/libSystem.B.dylib', use_errno=True)
        handle = ctypes.POINTER(ctypes.c_void_p)
        sigset = ctypes.POINTER(ctypes.c_uint32)
        strings = ctypes.POINTER(ctypes.c_char_p)
        signatures = {
            'posix_spawnattr_init': [handle],
            'posix_spawnattr_destroy': [handle],
            'posix_spawnattr_setflags': [handle, ctypes.c_short],
            'posix_spawnattr_setsigdefault': [handle, sigset],
            'posix_spawnattr_setsigmask': [handle, sigset],
            'posix_spawn_file_actions_init': [handle],
            'posix_spawn_file_actions_destroy': [handle],
            'posix_spawn_file_actions_adddup2': [handle, ctypes.c_int, ctypes.c_int],
            'posix_spawn_file_actions_addclose': [handle, ctypes.c_int],
            # Public Darwin extension, available from macOS 10.15.
            'posix_spawn_file_actions_addfchdir_np': [handle, ctypes.c_int],
            'posix_spawn': [ctypes.POINTER(ctypes.c_int), ctypes.c_char_p,
                            handle, handle, strings, strings],
            'sigemptyset': [sigset],
            'sigaddset': [sigset, ctypes.c_int],
            'close': [ctypes.c_int],
            'waitpid': [ctypes.c_int, ctypes.POINTER(ctypes.c_int), ctypes.c_int],
            'kqueue': [],
            'kevent': [ctypes.c_int, ctypes.POINTER(_Kevent), ctypes.c_int,
                       ctypes.POINTER(_Kevent), ctypes.c_int, ctypes.POINTER(_Timespec)],
        }
        for name, arguments in signatures.items():
            function = getattr(self.lib, name)
            function.argtypes = arguments
            function.restype = ctypes.c_int

    def checked(self, name, *arguments):
        if getattr(self.lib, name)(*arguments) != 0:
            raise OwnershipError('publicSpawnFailure')


def _create(command, cwd_fd, environment, *, fixture):
    global _INVOKED
    if type(cwd_fd) is not int or cwd_fd < 0:
        raise ValueError('invalidDirectoryDescriptor')
    info = os.fstat(cwd_fd)
    if (not stat.S_ISDIR(info.st_mode) or stat.S_IMODE(info.st_mode) != 0o700
            or info.st_uid != os.getuid() or os.geteuid() != os.getuid()):
        raise PermissionError('privateDirectoryRequired')
    if _INVOKED:
        raise OwnershipError('invocationAlreadyUsed')
    _INVOKED = True
    owner = _CLIResourceOwner(fixture)
    _ROOTS.append(owner)             # Root BEFORE the first owned effect.
    try:
        owner._setup(command, cwd_fd, environment, info)
    except BaseException as error:
        owner._unknown('setupUncertain')
        if not isinstance(error, Exception):
            raise
    return owner


class _CLIResourceOwner:
    """Actual resources, rooted even after facade loss or terminal unknown.

    Use only the factories; do not concurrently call methods or close/reconfigure
    borrowed endpoints. No __del__, context-manager cleanup, retry, or late clean.
    """
    def __init__(self, fixture):
        self._state = 'settingUp'
        self._reason = None
        # Native output storage belongs to the rooted owner BEFORE spawn. Even
        # a Python cancellation delivered at the ctypes return cannot lose PID.
        self._pid = ctypes.c_int()
        self._fds = {}
        self._identities = {}
        self._uncertain_fds = set()
        self._close_errors = {}
        self._spawn = None
        self._attr = ctypes.c_void_p()
        self._actions = ctypes.c_void_p()
        self._attr_live = False
        self._actions_live = False
        self._fixture = fixture
        self._registered = False
        self._exit_observed = False
        self._wait_status = None
        self._deadline = None

    @property
    def pid(self):
        return self._pid.value if self._pid.value > 0 else None

    @property
    def state(self):
        return self._state

    def _unknown(self, reason):
        if self.state not in ('unknown', 'clean'):
            self._state, self._reason = 'unknown', reason
        return self.record

    def mark_unknown(self, fixed_code):
        """Latch uncertainty without granting any resource retirement authority."""
        if fixed_code not in ('roleUncertain', 'controlUncertain', 'relayUncertain'):
            raise ValueError('invalidUnknownCode')
        return self._unknown(fixed_code)

    def observe_pending(self):
        """Drain the actual watch to empty, including events queued after EXIT."""
        if self.state in ('unknown', 'clean'):
            return self.record
        try:
            self._events(0)
        except BaseException as error:
            self._unknown('watchUncertain')
            if not isinstance(error, Exception):
                raise
        return self.record

    @property
    def record(self):
        return MappingProxyType({'state': self.state, 'reason': self._reason,
                                 'pid': self.pid, 'exitObserved': self._exit_observed,
                                 'waitStatus': self._wait_status,
                                 'scope': 'localDirectCLIResources'})

    def _own_fd(self, name, fd):
        # Capture immediately, before fstat/set_inheritable can fail.
        self._fds[name] = fd
        self._identities[name] = os.fstat(fd)
        os.set_inheritable(fd, False)
        return fd

    def _close_fd(self, name):
        fd = self._fds[name]
        if fd is not None:
            try:
                if self._registered:
                    self._events(0)
                actual = os.fstat(fd)
                expected = self._identities[name]
                if (actual.st_dev, actual.st_ino, actual.st_mode) != (
                        expected.st_dev, expected.st_ino, expected.st_mode):
                    raise OwnershipError('descriptorIdentityChanged')
                # os.close / kqueue.close can normalize or discard EINTR.
                # Exactly one public raw close attempt; an error is permanent
                # uncertainty, not permission to retry a possibly reused fd.
                ctypes.set_errno(0)
                if self._deadline is not None:
                    self._clock()
                result = self._spawn.lib.close(fd)
                error = ctypes.get_errno()
                if result != 0:
                    self._close_errors[name] = error
                    raise OwnershipError('physicalCloseUncertain')
            except BaseException:
                self._uncertain_fds.add(name)
                raise
            self._fds[name] = None

    def _setup(self, command, cwd_fd, environment, expected):
        self._spawn = api = _DarwinSpawn()
        cwd = self._own_fd('cwd', os.dup(cwd_fd))
        actual = os.fstat(cwd)
        if ((actual.st_dev, actual.st_ino, actual.st_uid, actual.st_mode)
                != (expected.st_dev, expected.st_ino, expected.st_uid, expected.st_mode)):
            raise OwnershipError('directoryIdentityChanged')
        for first, second in (('childStdin', 'stdin'), ('stdout', 'childStdout'),
                              ('stderr', 'childStderr')):
            pair = os.pipe()
            # Capture BOTH before any fallible descriptor observation.
            self._fds[first], self._fds[second] = pair
            self._own_fd(first, pair[0])
            self._own_fd(second, pair[1])
        api.checked('posix_spawnattr_init', ctypes.byref(self._attr))
        self._attr_live = True
        api.checked('posix_spawn_file_actions_init', ctypes.byref(self._actions))
        self._actions_live = True
        defaults, mask = ctypes.c_uint32(), ctypes.c_uint32()
        api.checked('sigemptyset', ctypes.byref(defaults))
        api.checked('sigemptyset', ctypes.byref(mask))
        # Reset all catchable dispositions, notably Python's ignored SIGPIPE.
        for number in signal.valid_signals():
            if number not in (signal.SIGKILL, signal.SIGSTOP):
                api.checked('sigaddset', ctypes.byref(defaults), int(number))
        api.checked('posix_spawnattr_setsigdefault', ctypes.byref(self._attr),
                    ctypes.byref(defaults))
        api.checked('posix_spawnattr_setsigmask', ctypes.byref(self._attr), ctypes.byref(mask))
        api.checked('posix_spawnattr_setflags', ctypes.byref(self._attr),
                    _START_SUSPENDED | _CLOEXEC_DEFAULT | _SETSIGDEF | _SETSIGMASK)
        api.checked('posix_spawn_file_actions_addfchdir_np', ctypes.byref(self._actions), cwd)
        for name, target in (('childStdin', 0), ('childStdout', 1), ('childStderr', 2)):
            # Keeping source descriptors above stdio avoids dup2 cross-aliasing.
            if self._fds[name] <= 2:
                raise OwnershipError('stdioDescriptorCollision')
            api.checked('posix_spawn_file_actions_adddup2', ctypes.byref(self._actions),
                        self._fds[name], target)
        # Do not rely on CLOEXEC_DEFAULT's treatment of descriptors mentioned
        # in file actions: close every original after fchdir/dup2 in the child.
        for fd in self._fds.values():
            if fd <= 2:
                raise OwnershipError('stdioDescriptorCollision')
            api.checked('posix_spawn_file_actions_addclose', ctypes.byref(self._actions), fd)
        argv = (ctypes.c_char_p * (len(command) + 1))(
            *(os.fsencode(value) for value in command), None)
        values = [os.fsencode(key + '=' + environment[key]) for key in sorted(environment)]
        envp = (ctypes.c_char_p * (len(values) + 1))(*values, None)
        result = api.lib.posix_spawn(ctypes.byref(self._pid), os.fsencode(command[0]),
                                    ctypes.byref(self._actions), ctypes.byref(self._attr),
                                    argv, envp)
        # On success, native code has ALREADY captured PID in this rooted owner;
        # no Python observation, wrapper, or detached process facade intervenes.
        if result != 0:
            raise OwnershipError('spawnFailed')
        if self.pid is None:
            raise OwnershipError('invalidSpawnIdentity')
        # A kqueue is process-private, not an inherited child close action.
        # The captured child is still suspended throughout queue registration.
        self._fds['kqueue'] = api.lib.kqueue()
        if self._fds['kqueue'] < 0:
            self._fds['kqueue'] = None
            raise OwnershipError('queueCreationFailed')
        self._own_fd('kqueue', self._fds['kqueue'])
        self._register()
        # Every setup retirement is checked, with no best-effort finally cleanup.
        api.checked('posix_spawn_file_actions_destroy', ctypes.byref(self._actions))
        self._actions_live = False
        api.checked('posix_spawnattr_destroy', ctypes.byref(self._attr))
        self._attr_live = False
        for name in ('childStdin', 'childStdout', 'childStderr', 'cwd'):
            self._close_fd(name)
        for name in ('stdin', 'stdout', 'stderr'):
            os.set_blocking(self._fds[name], False)
        self._state = 'suspended'

    def _register(self):
        change = _Kevent(self.pid, select.KQ_FILTER_PROC,
                         select.KQ_EV_ADD | select.KQ_EV_CLEAR | _EV_RECEIPT,
                         select.KQ_NOTE_FORK | select.KQ_NOTE_EXIT, 0, None)
        receipts = self._kevents(change, 0)
        if len(receipts) != 1:
            raise OwnershipError('missingRegistrationReceipt')
        receipt = receipts[0]
        if (receipt.ident != self.pid or receipt.filter != select.KQ_FILTER_PROC
                or not receipt.flags & select.KQ_EV_ERROR or receipt.data != 0):
            raise OwnershipError('badRegistrationReceipt')
        self._registered = True

    def _kevents(self, change, timeout_ns):
        seconds, nanos = divmod(timeout_ns, 1_000_000_000)
        duration = _Timespec(seconds, nanos)
        event = _Kevent()
        if self._deadline is not None:
            self._clock()
        count = self._spawn.lib.kevent(
            self._fds['kqueue'], ctypes.byref(change) if change is not None else None,
            int(change is not None), ctypes.byref(event), 1, ctypes.byref(duration))
        if count < 0 or count > 1:
            raise OwnershipError('publicEventFailure')
        return [event] if count else []

    def resume(self):
        if self.state != 'suspended' or not self._registered:
            return self._unknown('resumeWithoutRegistration')
        try:
            self._events(0)
            # A successful registration while START_SUSPENDED prevents the
            # unobserved pre-registration fork gap. No TRACK/CHILD delegation.
            os.kill(self.pid, signal.SIGCONT)
            self._state = 'running'
        except BaseException as error:
            self._unknown('resumeUncertain')
            if not isinstance(error, Exception):
                raise
        return self.record

    @property
    def endpoints(self):
        if self.state != 'running':
            raise OwnershipError('endpointsNotRunning')
        return MappingProxyType({name: self._fds[name] for name in ('stdin', 'stdout', 'stderr')})

    def _clock(self):
        if time.monotonic_ns() >= self._deadline:
            raise OwnershipError('cleanupExpired')

    def _begin_cleanup(self, deadline):
        now = time.monotonic_ns()
        if (type(deadline) is not int or not 0 <= deadline <= 0xffffffffffffffff
                or deadline <= now or deadline - now > 300_000_000):
            raise OwnershipError('invalidCleanupDeadline')
        if self._deadline is None:
            self._deadline = deadline
        elif deadline != self._deadline:
            raise OwnershipError('cleanupDeadlineChanged')
        self._clock()

    def _effect(self, function, *arguments):
        self._clock()
        result = function(*arguments)
        self._clock()
        return result

    def close_stdin(self, deadline):
        """Checked EOF sharing cleanup's UInt64 monotonic-nanosecond deadline."""
        if self.state in ('unknown', 'clean'):
            return self.record
        try:
            if self.state != 'running':
                raise OwnershipError('notRunning')
            self._begin_cleanup(deadline)
            self._effect(self._events, 0)
            self._effect(self._close_fd, 'stdin')
        except BaseException as error:
            self._unknown('stdinCloseUncertain')
            if not isinstance(error, Exception):
                raise
        return self.record

    def _events(self, timeout_ns):
        while True:
            events = self._kevents(None, timeout_ns)
            if not events:
                return
            timeout_ns = 0
            event, = events
            if (event.ident != self.pid or event.filter != select.KQ_FILTER_PROC
                    or event.flags & select.KQ_EV_ERROR
                    or event.fflags & ~(select.KQ_NOTE_FORK | select.KQ_NOTE_EXIT)
                    or not event.fflags):
                raise OwnershipError('eventIdentityUncertain')
            if event.fflags & select.KQ_NOTE_FORK:
                raise OwnershipError('forkObserved')
            if event.fflags & select.KQ_NOTE_EXIT:
                self._exit_observed = True

    def cleanup(self, deadline, *, terminate=False):
        """Attempt retirement using one <=300ms proof window, NOT a time bound.

        No signal, EOF, cancellation, boolean, or pipe closure is exit proof.
        Unknown is terminal: no further production effects, even on later calls.
        terminate targets only the owned unreaped direct child, never a group.
        deadline is an integer UInt64 absolute MONOTONIC nanosecond value,
        at most 300_000_000ns ahead; no float conversion or grace period.
        """
        if self.state in ('unknown', 'clean'):
            return self.record
        try:
            if self.state not in ('running', 'suspended') or type(terminate) is not bool:
                raise OwnershipError('invalidCleanupState')
            self._begin_cleanup(deadline)
            self._effect(self._events, 0)
            if terminate and not self._exit_observed:
                self._effect(os.kill, self.pid, signal.SIGKILL)
            while not self._exit_observed:
                self._clock()
                self._effect(self._events, max(0, self._deadline - time.monotonic_ns()))
            # Capture waitpid result immediately, even if the post-effect clock
            # expires: it must never cause a second wait or reused-PID signal.
            status = ctypes.c_int()
            self._effect(self._events, 0)
            self._clock()
            reaped = self._spawn.lib.waitpid(self.pid, ctypes.byref(status), 0)
            if reaped == self.pid:
                self._wait_status = status.value
            self._clock()
            if reaped != self.pid or not (
                    os.WIFEXITED(status.value) or os.WIFSIGNALED(status.value)):
                raise OwnershipError('waitIdentityUncertain')
            for name in tuple(self._fds):
                self._effect(self._events, 0)
                self._effect(self._close_fd, name)
            if self._attr_live or self._actions_live or self._uncertain_fds:
                raise OwnershipError('setupRetirementUncertain')
            self._clock()
            self._state = 'clean'
        except BaseException as error:
            self._unknown('cleanupUncertain')
            if not isinstance(error, Exception):
                raise
        return self.record

    def fixture_teardown(self):
        """TEST ONLY: physical teardown, never repairs proof/debt/invocation/root.

        Only the captured direct fixture child is killable/reapable. This cannot
        assert anything about descendants or erase an unknown result.
        """
        if not self._fixture:
            raise PermissionError('fixtureRequired')
        if self.pid is not None and self._wait_status is None:
            try:
                reaped, _ = os.waitpid(self.pid, os.WNOHANG)
                if reaped == 0:
                    os.kill(self.pid, signal.SIGKILL)
                    os.waitpid(self.pid, 0)
            except ChildProcessError:
                pass
        for name, fd in self._fds.items():
            if fd is None:
                continue
            expected = self._identities.get(name)
            if expected is None:
                continue
            try:
                actual = os.fstat(fd)
                if (actual.st_dev, actual.st_ino, actual.st_mode) == (
                        expected.st_dev, expected.st_ino, expected.st_mode):
                    os.close(fd)
            except OSError:
                pass
