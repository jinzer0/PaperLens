"""Lazy official SDK owner. Importing this module acquires no OS resources.

Only Native can select the immutable retirement identity. Broker retirement
proves neither public SDK FileObject closure nor namespace purge. Unknown is a
permanent, retained state, not an exception-driven cleanup opportunity.
"""
from __future__ import annotations

import asyncio
from dataclasses import dataclass, field
import errno
import importlib
import importlib.util
import json
import os
from pathlib import Path
import select
import stat
import sys
import threading
import time
import uuid

_ROOTS = []
_ENV_KEYS = frozenset(('PATH', 'LANG', 'LC_ALL', 'HOME', 'CODEX_HOME', 'TMPDIR'))
_MARKER = 'PAPERLENS_OK'
_MARKER_SCHEMA = {
    'type': 'object', 'properties': {'text': {'type': 'string', 'const': _MARKER}},
    'required': ['text'], 'additionalProperties': False,
}
_SUMMARY_SCHEMA = {
    'type': 'object', 'additionalProperties': False,
    'required': ['summary', 'insufficiency'], 'properties': {
        'summary': {'type': 'object', 'additionalProperties': False,
            'required': ['text', 'kind', 'evidenceIndices'], 'properties': {
                'text': {'type': 'string'},
                'kind': {'type': 'string', 'enum': ['paper', 'analysis', 'insufficient']},
                'evidenceIndices': {'type': 'array', 'items': {'type': 'integer'}}}},
        'insufficiency': {'type': 'string', 'enum': ['none', 'noEvidence', 'budgetLimited']}}}


def ProtocolError(code):
    # Keep standalone module import free of contract-file reads as well as SDK
    # imports and OS acquisition. The raised instance is the shared wire error.
    from provider_rpc import ProtocolError as WireError
    return WireError(code)


class ClosedApproval(RuntimeError):
    """Unexpected SDK server request; no fabricated response or default accept."""


def _deny_approval(method, params):
    raise ClosedApproval('unexpectedServerRequest')


def _projection(value):
    return value.model_dump(by_alias=True, mode='json', exclude_none=True)


def _value(value):
    return getattr(value, 'value', value)


def _same(first, second):
    return (first.st_dev, first.st_ino, first.st_mode, first.st_uid) == (
        second.st_dev, second.st_ino, second.st_mode, second.st_uid)


@dataclass(repr=False)
class SDKJob:
    request_id: str
    reserved: bool
    future: object
    stage: object = None
    thread: object = None
    result: object = None
    error: object = None
    failed: bool = False
    completed: bool = False
    terminal: str | None = None


@dataclass(repr=False)
class Stage:
    stage_id: str
    intent_id: str
    selector: dict
    model: str
    controller: object
    intent: object
    stale: bool = False
    cancel_selected: bool = False
    login_ids: list = field(default_factory=list)
    thread_ids: list = field(default_factory=list)
    turn_ids: list = field(default_factory=list)
    instructions: dict | None = None
    probe_validated: bool = False
    probe_started: bool = False


class OfficialSDKWorker:
    def __init__(self):
        # The actual owner is rooted before fstat/open/CDLL/import/thread/start.
        _ROOTS.append(self)
        self.fds, self.identities = {}, {}
        self.unknown = False
        self.reason = None
        self.client = None
        self.sdk_start_attempted = False
        self.models = None
        self.rendezvous = None
        self.broker = None
        self.server = None
        self.loop = None
        self.lifecycle_task = None
        self.lifecycle_fd = None
        self.parent = None
        self.cwd = None
        self.contents = None
        self.python = None
        self.agent = None
        self.run_id = None
        self.startup_deadline_ns = None
        self.retirement_id = None
        self.environment_replaced = False
        self.dispatch_enabled = False
        self.initialized = False
        self.initialization = None
        self.stage = None
        self.jobs = []
        self.occupied = []
        self.wire_terminals = {}
        self.request_deadlines = {}
        self.readers = []
        self.reader_failures = []
        self.notifications = []
        self.sdk_objects = []
        self.cleanup_requests = []
        self.retirement_requested = False
        self.control_output = bytearray()
        self.control_frames = None
        self.acl_library = None
        self.acl_objects = []
        self.reap_record = None
        self.reap_started = False
        self.retirement_thread = None
        self.control_lock = threading.Lock()
        self.captured = False
        self.event_loop = None
        self.transport_decoder = None
        self.transport_input = None
        self.transport_output = None
        self.failure = None
        self.state_lock = threading.RLock()
        self.summary_admitted = False

    def own(self, name, fd):
        self.fds[name] = fd
        self.identities[name] = os.fstat(fd)
        return fd

    def select_unknown(self, reason='ownershipUnknown'):
        with self.state_lock:
            self.unknown = True
            self.reason = self.reason or reason
        if self.server is not None:
            self.server.fatal.set()
        if self.event_loop is not None:
            # stop() only latches the loop flag. Do not close/deregister its
            # selector/self-pipe, run finalizers, or drain ready/pending data.
            self.event_loop.call_soon_threadsafe(self.event_loop.stop)

    async def park_async(self):
        # Retain frames, jobs, SDK queues, descriptors and namespace indefinitely.
        await asyncio.Future()

    def park(self):
        while True:
            try:
                time.sleep(3600)
            except BaseException:
                pass

    def _check(self, request_id=None):
        if self.unknown:
            raise ProtocolError('unavailable')
        if (request_id in self.request_deadlines and self.loop is not None
                and self.loop.time() >= self.request_deadlines[request_id]
                and request_id not in self.wire_terminals):
            try:
                running_loop = asyncio.get_running_loop()
            except RuntimeError:
                running_loop = None
            # SDK threads may refuse expired work, but only the event loop
            # selects wire/stage terminals. No background invalidation can
            # overtake final loop acceptance before its immediate publication.
            if running_loop is self.loop:
                self.wire_terminal(request_id, 'timeout')
            raise ProtocolError('timeout')
        if request_id is not None and request_id in self.wire_terminals:
            raise ProtocolError(self.wire_terminals[request_id])

    def _identity(self, name):
        actual, expected = os.fstat(self.fds[name]), self.identities[name]
        actual_mode, expected_mode = actual.st_mode, expected.st_mode
        if stat.S_ISSOCK(expected_mode):
            actual_mode, expected_mode = stat.S_IFMT(actual_mode), stat.S_IFMT(expected_mode)
        if (actual.st_dev, actual.st_ino, actual_mode, actual.st_uid) != (
                expected.st_dev, expected.st_ino, expected_mode, expected.st_uid):
            raise ProtocolError('unavailable')

    def _empty_acl(self, fd):
        import ctypes
        if self.acl_library is None:
            self.acl_library = ctypes.CDLL('/usr/lib/libSystem.B.dylib', use_errno=True)
            self.acl_library.acl_get_fd_np.argtypes = [ctypes.c_int, ctypes.c_int]
            self.acl_library.acl_get_fd_np.restype = ctypes.c_void_p
            self.acl_library.acl_get_entry.argtypes = [ctypes.c_void_p, ctypes.c_int,
                                                      ctypes.POINTER(ctypes.c_void_p)]
            self.acl_library.acl_get_entry.restype = ctypes.c_int
            self.acl_library.acl_free.argtypes = [ctypes.c_void_p]
            self.acl_library.acl_free.restype = ctypes.c_int
        ctypes.set_errno(0)
        acl = self.acl_library.acl_get_fd_np(fd, 0x100)  # ACL_TYPE_EXTENDED
        if not acl:
            if ctypes.get_errno() == errno.ENOENT:
                return
            raise ProtocolError('unavailable')
        self.acl_objects.append(acl)
        entry = ctypes.c_void_p()
        ctypes.set_errno(0)
        result = self.acl_library.acl_get_entry(acl, 0, ctypes.byref(entry))
        # Darwin's public ACL API ends at -1/EINVAL, not POSIX's zero.
        empty = result == -1 and ctypes.get_errno() == errno.EINVAL and not entry.value
        if self.acl_library.acl_free(acl) != 0:
            raise ProtocolError('unavailable')
        self.acl_objects.remove(acl)
        if not empty:
            raise ProtocolError('unavailable')

    def _directory(self, name):
        info = os.fstat(self.fds[name])
        if (not stat.S_ISDIR(info.st_mode) or stat.S_IMODE(info.st_mode) != 0o700
                or info.st_uid != os.getuid() or os.getuid() != os.geteuid()):
            raise ProtocolError('unavailable')
        self._empty_acl(self.fds[name])
        return info

    def capture(self, lifecycle_fd):
        # Capture all inherited roles before environment mutation or SDK effects.
        if lifecycle_fd != 5 or self.captured:
            raise ProtocolError('unavailable')
        self.captured = True
        for name, fd in (('stdin', 0), ('stdout', 1), ('stderr', 2), ('lifecycle', 5)):
            self.own(name, fd)
        self.lifecycle_fd = lifecycle_fd
        if not stat.S_ISSOCK(self.identities['lifecycle'].st_mode):
            raise ProtocolError('unavailable')
        os.set_inheritable(5, False)
        self.own('cwd', os.open('.', os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW))
        os.set_inheritable(self.fds['cwd'], False)
        self.cwd = Path(os.getcwd())
        root = self._directory('cwd')
        if self.cwd.resolve(strict=True) != self.cwd or not _same(root, self.cwd.lstat()):
            raise ProtocolError('unavailable')
        for name in ('codex', 'tmp', 'work'):
            fd = self.own(name, os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                                       dir_fd=self.fds['cwd']))
            os.set_inheritable(fd, False)
            info = self._directory(name)
            if not _same(info, os.stat(name, dir_fd=self.fds['cwd'], follow_symlinks=False)):
                raise ProtocolError('unavailable')
        if sys.platform != 'darwin':
            raise ProtocolError('unavailable')
        from broker_control import peer_identity, ControlFrames
        self.parent = peer_identity(5)
        if self.parent.pid != os.getppid():
            raise ProtocolError('unavailable')
        self.control_frames = ControlFrames()
        self.run_id = os.environ.get('PAPERLENS_BROKER_RUN_ID')
        if str(uuid.UUID(self.run_id)) != self.run_id:
            raise ProtocolError('unavailable')
        text = os.environ.get('PAPERLENS_BROKER_START_DEADLINE_NS', '')
        if not text.isascii() or not text.isdecimal() or len(text) > 20:
            raise ProtocolError('unavailable')
        self.startup_deadline_ns = int(text)
        if not time.monotonic_ns() < self.startup_deadline_ns <= (1 << 64) - 1:
            raise ProtocolError('unavailable')
        self._packaged_identity()
        environment = {
            'PATH': str(self.contents / 'MacOS') + ':/usr/bin:/bin:/usr/sbin:/sbin',
            'LANG': 'C', 'LC_ALL': 'C', 'HOME': str(self.cwd),
            'CODEX_HOME': str(self.cwd / 'codex'), 'TMPDIR': str(self.cwd / 'tmp'),
        }
        if set(environment) != _ENV_KEYS or self.environment_replaced:
            raise ProtocolError('unavailable')
        os.environ.clear()
        os.environ.update(environment)
        self.environment_replaced = True
        os.set_blocking(5, False)

    def _packaged_identity(self):
        source = Path(__file__).resolve(strict=True)
        resources = source.parent
        self.contents = resources.parent
        if resources.name != 'Resources' or self.contents.name != 'Contents':
            raise ProtocolError('unavailable')
        self.python = self.contents / 'MacOS' / 'python3'
        self.agent = resources / 'agent.py'
        for path, executable in ((self.python, True), (self.agent, False)):
            resolved = path.resolve(strict=True)
            info = resolved.stat()
            if (not resolved.is_relative_to(self.contents) or not stat.S_ISREG(info.st_mode)
                    or (executable and not info.st_mode & 0o111)):
                raise ProtocolError('unavailable')

    def _sdk_module(self, name):
        spec = importlib.util.find_spec(name)
        if (spec is None or not spec.origin
                or not Path(spec.origin).resolve(strict=True).is_relative_to(self.contents)):
            raise ProtocolError('unavailable')
        module = importlib.import_module(name)
        if not Path(module.__file__).resolve(strict=True).is_relative_to(self.contents):
            raise ProtocolError('unavailable')
        return module

    def start(self):
        self._check()
        with self.state_lock:
            if (self.unknown or not self.environment_replaced or self.client is not None
                    or self.sdk_start_attempted or self.retirement_requested
                    or self.retirement_id is not None):
                raise ProtocolError('unavailable')
            # One-start admission is consumed before any constructor/start effect,
            # including failure. This is not cleanup or resource-closure proof.
            self.sdk_start_attempted = True
        sdk = self._sdk_module('openai_codex')
        if sdk.__version__ != '0.160.0':
            raise ProtocolError('unavailable')
        public = self._sdk_module('openai_codex.client')
        self.models = self._sdk_module('openai_codex.generated.v2_all')
        from broker_control import open_worker_rendezvous
        # This helper roots its actual owner before any acquisition, including
        # failures which cannot return an object to this additional owner root.
        self.rendezvous = open_worker_rendezvous(self.fds['cwd'], run_id=self.run_id,
            startup_deadline_ns=self.startup_deadline_ns)
        config = public.CodexConfig(
            cwd=str(self.cwd),
            launch_args_override=(str(self.python), '-I', '-B', str(self.agent), '--native-broker'),
            env={'PAPERLENS_BROKER_RUN_ID': self.run_id,
                 'PAPERLENS_BROKER_START_DEADLINE_NS': str(self.startup_deadline_ns)},
        )
        self.client = public.CodexClient(config, approval_handler=_deny_approval)
        self.client.start()
        self.broker = self.rendezvous.accept_broker()
        self.rendezvous.offer_to_native(5, self.broker)
        while not self.dispatch_enabled and not self.unknown:
            if self.retirement_id is None:
                self._startup_clock()
            ready, _, _ = select.select([5], [], [], 0.05 if self.retirement_id is not None else max(
                0, (self.startup_deadline_ns - time.monotonic_ns()) / 1e9))
            if ready:
                self._control_read()
        self._check()

    def _startup_clock(self):
        if time.monotonic_ns() >= self.startup_deadline_ns:
            raise ProtocolError('unavailable')

    def _control_read(self):
        self._check()
        self._identity('lifecycle')
        try:
            byte = os.read(5, 1)
        except BlockingIOError:
            return
        if not byte:
            raise ProtocolError('unavailable')
        message = self.control_frames.feed(byte)
        if message is not None:
            self._control(message)

    def _control(self, message):
        from broker_control import ControlError, _validate
        try:
            _validate(message)
        except (ControlError, ValueError):
            raise ProtocolError('unavailable') from None
        if message['runID'] != self.run_id:
            raise ProtocolError('unavailable')
        op = message['op']
        if op == 'dispatching' and not self.dispatch_enabled and self.retirement_id is None:
            self._startup_clock()
            self.dispatch_enabled = True
        elif op == 'revoke':
            identity = message['retirementID']
            with self.state_lock:
                if self.retirement_id is None:
                    self.retirement_id = identity
                    self.retirement_requested = True
                    if self.stage is not None:
                        self.stage.stale = True
                elif identity != self.retirement_id:
                    raise ProtocolError('unavailable')
        elif op == 'reapBroker' and self.retirement_id == message['retirementID']:
            if self.reap_started:
                return
            self.reap_started = True
            self.retirement_thread = threading.Thread(
                target=self._reap_broker, name='PaperLensBrokerRetirement', daemon=True)
            self.retirement_thread.start()
        else:
            raise ProtocolError('unavailable')

    def _reap_broker(self):
        try:
            self.reap_record = self.broker.wait_direct_child(self.retirement_id)
            self.rendezvous.retire(self.retirement_id)
            # Actual local broker wait only; never SDK FileObject closure or purge.
            self._send_control('brokerReaped', retirementID=self.retirement_id,
                               waitStatus=self.reap_record.wait_status)
            # Native now terminates and waitpid-reaps this exclusively owned worker.
            # Never run SDK destructors or present this local wait as namespace purge.
        except BaseException as error:
            self.failure = self.failure or error
            self.select_unknown('brokerRetirementUncertain')

    def _send_control(self, op, **fields):
        with self.control_lock:
            self._write_control(op, **fields)

    def _write_control(self, op, **fields):
        self._check()
        from broker_control import encode_control
        self.control_output.extend(encode_control(self.run_id, op, **fields))
        while self.control_output:
            self._check()
            if (self.retirement_id is None and op != 'revokeNeeded'
                    and time.monotonic_ns() >= self.startup_deadline_ns):
                raise ProtocolError('unavailable')
            self._identity('lifecycle')
            try:
                count = os.write(5, self.control_output)
            except BlockingIOError:
                if op == 'brokerReaped':
                    # Only the retained retirement thread waits for cleanup delivery.
                    select.select([], [5], [], 0.05)
                    continue
                raise ProtocolError('unavailable') from None
            if count <= 0:
                raise ProtocolError('unavailable')
            del self.control_output[:count]

    async def lifecycle(self):
        loop = asyncio.get_running_loop()
        while not self.unknown:
            future = loop.create_future()
            def readable():
                if not future.done():
                    future.set_result(None)
            loop.add_reader(5, readable)
            try:
                await future
                self._control_read()
            except BaseException as error:
                self.failure = self.failure or error
                self.select_unknown('lifecycleUncertain')
            finally:
                if not self.unknown:
                    loop.remove_reader(5)

    def wire_terminal(self, request_id, code):
        with self.state_lock:
            self.wire_terminals.setdefault(request_id, code)
            for job in self.jobs:
                if job.request_id == request_id:
                    job.terminal = self.wire_terminals[request_id]
                    # Only a validated ordinary stage job owns this authority.
                    # Unstarted requests, hello, observe and unowned scopes do
                    # not acquire authority merely by receiving a wire terminal.
                    if not job.reserved and job.stage is not None:
                        job.stage.stale = True
                        job.stage.controller.fail(job.stage.intent)

    def _current(self, params):
        stage = self.stage
        if (stage is None or params['stageID'] != stage.stage_id
                or params['intentID'] != stage.intent_id):
            raise ProtocolError('invalidParams')
        return stage

    def _admit(self, request_id=None, stage=None):
        # Pure metadata only, serialized with cancellation/retirement. An
        # admitted effect may finish late; admission is never cleanup proof.
        self._check()
        if self.retirement_id is not None or self.retirement_requested:
            raise ProtocolError('unavailable')
        self._check(request_id)
        if stage is not None and (self.stage is not stage or stage.stale or stage.cancel_selected):
            raise ProtocolError('cancelled')

    def _notification(self, call, *, stage=None, request_id=None):
        with self.state_lock:
            self._admit(request_id, stage)
        result = call()
        # Root even a notification arriving after wire terminal or unknown.
        self.notifications.append(result)
        return result

    def _start_reader(self, target, name):
        self._check()
        reader = threading.Thread(target=target, name=name, daemon=True)
        self.readers.append(reader)
        reader.start()

    def _global_reader(self):
        try:
            for _ in range(256):
                self._notification(self.client.next_notification)
                if self.unknown:
                    return
            self.loop.call_soon_threadsafe(self._session_limit)
        except BaseException as error:
            self.reader_failures.append(error)
            if not self.unknown and self.retirement_id is None and not self.retirement_requested:
                self.loop.call_soon_threadsafe(self.select_unknown, 'notificationUncertain')

    def _session_limit(self):
        with self.state_lock:
            if self.unknown or self.retirement_requested:
                return
            self.retirement_requested = True
            if self.stage is not None:
                self.stage.stale = True
        try:
            self._send_control('revokeNeeded', code='sessionLimit')
        except BaseException:
            self.select_unknown('sessionLimitRequestUncertain')

    async def _job(self, request_id, deadline, call, *, reserved=False, stage=None, probe=False):
        self._check(request_id)
        if self.retirement_id is not None or self.retirement_requested:
            raise ProtocolError('unavailable')
        loop = asyncio.get_running_loop()
        if loop.time() >= deadline:
            raise ProtocolError('timeout')
        if sum(job.reserved == reserved for job in self.occupied) >= (1 if reserved else 3):
            raise ProtocolError('busy')
        with self.state_lock:
            self._admit(request_id, stage)
            job = SDKJob(request_id, reserved, loop.create_future(), stage=stage)
            self.request_deadlines[request_id] = deadline
            self.jobs.append(job)
            self.occupied.append(job)
        def completed():
            if not job.future.done():
                job.future.set_result(None)
        def run():
            try:
                self._check(request_id)
                job.result = call()
            except BaseException as error:
                # Raw SDK exceptions and tracebacks never escape to the wire.
                job.error = error
                job.failed = True
            job.completed = True
            if not self.unknown:
                loop.call_soon_threadsafe(completed)
        job.thread = threading.Thread(target=run, name='PaperLensSDKJob', daemon=True)
        job.thread.start()
        await asyncio.shield(job.future)
        self._check(request_id)
        if loop.time() >= deadline:
            self.wire_terminal(request_id, 'timeout')
            raise ProtocolError('timeout')
        with self.state_lock:
            # Thread completion is not publication authority. Reject and retain
            # both result and occupied debt when this exact stage lost authority.
            self._admit(request_id, stage)
            if job in self.occupied:
                self.occupied.remove(job)
            if job.failed:
                raise ProtocolError('unavailable')
            if probe:
                stage.probe_validated = True
            return job.result

    def _call(self, request_id, function, *args, stage=None):
        with self.state_lock:
            self._admit(request_id, stage)
        result = function(*args)
        self.sdk_objects.append(result)  # Includes every late returned object.
        return result

    def _start_login(self, request_id, stage, mode):
        m = self.models
        inner = (m.ChatgptLoginAccountParams(type='chatgpt') if mode == 'browser' else
                 m.ChatgptDeviceCodeLoginAccountParams(type='chatgptDeviceCode'))
        response = self._call(request_id, self.client.account_login_start,
                              m.LoginAccountParams(root=inner), stage=stage)
        actual_id = getattr(response.root, 'login_id', None)
        if actual_id is not None:
            stage.login_ids.append(actual_id)
        payload = _projection(response.root)
        # Capture cancellation targets BEFORE checking current presentation.
        login_id = payload.get('loginId')
        if type(login_id) is str and login_id not in stage.login_ids:
            stage.login_ids.append(login_id)
        with self.state_lock:
            if self.unknown or stage.stale or request_id in self.wire_terminals:
                return None
            self._check(request_id)
            stage.controller.accept_instructions(stage.intent, payload)
            instructions = stage.controller.instructions
            if mode == 'browser':
                stage.instructions = {'mode': 'browser', 'authUrl': instructions.auth_url}
            else:
                stage.instructions = {'mode': 'device', 'userCode': instructions.user_code,
                                      'verificationUrl': instructions.verification_url}
        # One actual login reader; registration is performed by SDK start itself.
        self.loop.call_soon_threadsafe(self._login_reader_start, stage)
        return {'stageID': stage.stage_id, 'intentID': stage.intent_id,
                'instructions': dict(stage.instructions)}

    def _login_reader_start(self, stage):
        with self.state_lock:
            if (self.unknown or self.stage is not stage or stage.stale
                    or self.retirement_id is not None or self.retirement_requested):
                return
        self._start_reader(lambda: self._login_reader(stage), 'PaperLensSDKLogin')

    def _login_reader(self, stage):
        try:
            for _ in range(256):
                notification = self._notification(
                    lambda: self.client.next_login_notification(stage.controller.login_id), stage=stage)
                if self.unknown or stage.stale:
                    return
                if notification.method == 'account/login/completed':
                    payload = _projection(notification.payload)
                    with self.state_lock:
                        if self.unknown or stage.stale:
                            return
                        stage.controller.accept_completion(stage.intent, payload)
                        if stage.controller.state in ('authCompleted', 'failed'):
                            return
            self.loop.call_soon_threadsafe(self._session_limit)
        except BaseException as error:
            self.reader_failures.append(error)
            with self.state_lock:
                stage.controller.fail(stage.intent)

    def _probe(self, request_id, stage):
        m = self.models
        thread = self._call(request_id, self.client.thread_start, m.ThreadStartParams(
            model=stage.model, cwd=str(self.cwd), ephemeral=True,
            approval_policy=m.AskForApproval(root='never'), sandbox=m.SandboxMode.read_only,
            developer_instructions='Reply exactly PAPERLENS_OK.'), stage=stage)
        thread_id = thread.thread.id
        stage.thread_ids.append(thread_id)
        if type(thread_id) is not str or not thread_id:
            raise ProtocolError('unavailable')
        self._check(request_id)
        if stage.stale:
            raise ProtocolError('cancelled')
        turn = self._call(request_id, self.client.turn_start, thread_id, [], m.TurnStartParams(
            thread_id=thread_id, input=[], model=stage.model, cwd=str(self.cwd),
            approval_policy=m.AskForApproval(root='never'),
            sandbox_policy=m.ReadOnlySandboxPolicy(type='readOnly', network_access=False),
            output_schema=_MARKER_SCHEMA), stage=stage)
        turn_id = turn.turn.id
        stage.turn_ids.append(turn_id)
        if type(turn_id) is not str or not turn_id:
            raise ProtocolError('unavailable')
        for _ in range(256):
            self._check(request_id)
            if stage.stale:
                raise ProtocolError('cancelled')
            notification = self._notification(lambda: self.client.next_turn_notification(turn_id),
                                              stage=stage, request_id=request_id)
            if self.unknown:
                return None
            if notification.method != 'turn/completed':
                continue
            payload = notification.payload
            if not self._valid_marker(payload, thread_id, turn_id):
                raise ProtocolError('unavailable')
            self._check(request_id)
            if stage.stale:
                raise ProtocolError('cancelled')
            return {'stageID': stage.stage_id, 'intentID': stage.intent_id,
                    'expectedSelector': dict(stage.selector), 'state': 'usable', 'text': _MARKER}
        self.loop.call_soon_threadsafe(self._session_limit)
        raise ProtocolError('unavailable')

    @staticmethod
    def _valid_marker(payload, thread_id, turn_id):
        turn = payload.turn
        if (payload.thread_id != thread_id or turn.id != turn_id
                or _value(turn.status) != 'completed' or turn.error is not None
                or _value(turn.items_view) != 'full'):
            return False
        messages = [item.root for item in turn.items
                    if getattr(item.root, 'type', None) == 'agentMessage'
                    and _value(getattr(item.root, 'phase', None)) == 'final_answer']
        if len(messages) != 1:
            return False
        try:
            # Duplicate keys, trailing tokens and non-object values are rejected.
            def pairs(items):
                result = {}
                for key, value in items:
                    if key in result:
                        raise ValueError('duplicateKey')
                    result[key] = value
                return result
            return json.loads(messages[0].text, object_pairs_hook=pairs) == {'text': _MARKER}
        except (TypeError, ValueError):
            return False

    def _cancel(self, request_id, stage):
        from account_login import validate_cancel_status
        if stage.login_ids:
            result = self._call(request_id, self.client.account_login_cancel, stage.login_ids[0])
            validate_cancel_status(_projection(result))
        if stage.thread_ids and stage.turn_ids:
            self._call(request_id, self.client.turn_interrupt,
                       stage.thread_ids[-1], stage.turn_ids[-1])
        return {'stageID': stage.stage_id, 'intentID': stage.intent_id, 'accepted': True}

    @staticmethod
    def _summary_config_allowed(config):
        # Empty table overlays do not erase inherited TOML tables. Inspect the
        # effective configuration before a thread can receive any paper bytes.
        if any(config.get(key) for key in ('mcp_servers', 'hooks', 'model_providers',
                'instructions', 'developer_instructions', 'compact_prompt',
                'browser_use', 'computer_use', 'desktop', 'permissions',
                'model_catalog_json',
                'model_instructions_file', 'skills', 'notify', 'apps', 'plugins', 'tools')):
            return False
        if config.get('model_provider') not in (None, 'openai'):
            return False
        if (config.get('chatgpt_base_url') not in (None, 'https://chatgpt.com/backend-api/')
                or config.get('openai_base_url') not in (None, '')
                or config.get('respect_system_proxy') not in (None, False)):
            return False
        if config.get('cli_auth_credentials_store') != 'file' or config.get('web_search') != 'disabled':
            return False
        features = config.get('features', {})
        return (isinstance(features, dict) and all(value is None or value is False for value in features.values())
                and all(features.get(key) is False for key in
                    ('apps', 'plugins', 'multi_agent', 'shell_tool', 'view_image')))

    def _library_summary(self, request_id, params):
        authority = self._sdk_module('provider_request.provider_request')
        wire = authority.parse_request(params['requestJSON'].encode('utf-8'))
        if (wire.operation != 'librarySummary' or wire.requestID != params['requestID']
                or wire.input['evidence']['paperID'] != params['paperID']
                or wire.input['evidence']['paperGeneration'] != params['paperGeneration']):
            raise ProtocolError('invalidParams')
        if authority.input_charge(wire) > 8192:
            raise ProtocolError('invalidParams')
        m = self.models
        config = self._call(request_id, lambda: self.client.request('config/read',
            {'cwd': str(self.cwd / 'work'), 'includeLayers': False},
            response_model=m.ConfigReadResponse))
        if not self._summary_config_allowed(_projection(config.config)):
            raise ProtocolError('unavailable')
        messages = authority.render_messages(wire)
        work = str(self.cwd / 'work')
        thread = self._call(request_id, self.client.thread_start, {
            'model': params['model'], 'cwd': work, 'ephemeral': True,
            'approvalPolicy': 'never', 'environments': [],
            'baseInstructions': messages[0].content,
            'config': {'default_permissions': 'paperlens', 'permissions': {
                'paperlens': {'filesystem': {work: 'read'}, 'network': {'enabled': False}}}}})
        thread_id = thread.thread.id
        if type(thread_id) is not str or not thread_id:
            raise ProtocolError('unavailable')
        turn = self._call(request_id, self.client.turn_start, thread_id,
            [{'type': 'text', 'text': messages[-1].content, 'text_elements': []}], {
                'threadId': thread_id, 'model': params['model'], 'cwd': work,
                'approvalPolicy': 'never', 'environments': [], 'outputSchema': _SUMMARY_SCHEMA})
        turn_id = turn.turn.id
        if type(turn_id) is not str or not turn_id:
            raise ProtocolError('unavailable')
        for _ in range(256):
            notification = self._notification(lambda: self.client.next_turn_notification(turn_id),
                                              request_id=request_id)
            method = notification.method
            # No execution event is permissible even if an upstream runtime
            # unexpectedly exposes a tool despite the disabled environment.
            if method in ('item/started', 'item/completed'):
                item = getattr(notification.payload, 'item', None)
                item = getattr(item, 'root', item)
                if getattr(item, 'type', None) not in ('userMessage', 'agentMessage', 'reasoning'):
                    raise ProtocolError('unavailable')
            if method != 'turn/completed':
                continue
            payload = notification.payload
            completed = payload.turn
            if (payload.thread_id != thread_id or completed.id != turn_id
                    or _value(completed.status) != 'completed' or completed.error is not None
                    or _value(completed.items_view) != 'full'):
                raise ProtocolError('unavailable')
            items = [item.root for item in completed.items]
            if any(getattr(item, 'type', None) not in ('userMessage', 'agentMessage', 'reasoning') for item in items):
                raise ProtocolError('unavailable')
            final = [item.text for item in items if getattr(item, 'type', None) == 'agentMessage'
                     and _value(getattr(item, 'phase', None)) == 'final_answer']
            if len(final) != 1 or len(final[0].encode('utf-8')) > 2048:
                raise ProtocolError('unavailable')
            # The native authority validates the result against its original
            # unforgeable authorization and immutable grounding after drainage.
            self._check(request_id)
            return {key: params[key] for key in ('requestID', 'paperID', 'paperGeneration',
                'configGeneration', 'model')} | {'resultJSON': final[0]}
        raise ProtocolError('unavailable')

    async def dispatch(self, method, params, *, request_id, deadline):
        self._check(request_id)
        self.loop = asyncio.get_running_loop()
        if self.loop.time() >= deadline:
            raise ProtocolError('timeout')
        if method == 'product.hello':
            if self.initialized or self.initialization is not None or not self.dispatch_enabled:
                raise ProtocolError('invalidParams')
            self.initialization = request_id
            result = await self._job(request_id, deadline,
                                     lambda: self._call(request_id, self.client.initialize))
            if result is None:
                raise ProtocolError('unavailable')
            self._check(request_id)
            self.initialized = True
            self._start_reader(self._global_reader, 'PaperLensSDKGlobal')
            return {'major': 2, 'minor': 0, 'capabilities': ['product-v1']}
        if not self.initialized:
            raise ProtocolError('handshakeRequired')
        if method == 'product.librarySummary':
            with self.state_lock:
                if self.stage is not None or self.summary_admitted or self.occupied:
                    raise ProtocolError('busy')
                self.summary_admitted = True
            return await self._job(request_id, deadline,
                lambda: self._library_summary(request_id, params))
        if method == 'product.loginStart':
            from account_login import AccountLoginController
            if self.stage is not None or self.occupied:
                raise ProtocolError('busy')
            controller = AccountLoginController('chatgpt' if params['mode'] == 'browser' else 'chatgptDeviceCode')
            with self.state_lock:
                stage = Stage(params['stageID'], params['intentID'], dict(params['expectedSelector']),
                              params['model'], controller, controller.replace_intent())
                self.stage = stage
            return await self._job(request_id, deadline,
                lambda: self._start_login(request_id, stage, params['mode']), stage=stage)
        if method in ('product.loginObserve', 'product.connectionTest', 'product.loginCancel', 'product.stageRetire'):
            stage = self._current(params)
            if method == 'product.loginObserve':
                with self.state_lock:
                    state = {'authCompleted': 'authenticated', 'failed': 'failed',
                             'cancelled': 'cancelled'}.get(stage.controller.state, 'pending')
                return {'stageID': stage.stage_id, 'intentID': stage.intent_id, 'state': state}
            if method == 'product.connectionTest':
                with self.state_lock:
                    if params['expectedSelector'] != stage.selector or stage.stale:
                        raise ProtocolError('invalidParams')
                    if stage.controller.state != 'authCompleted' or stage.probe_started:
                        raise ProtocolError('busy')
                    if any(not j.completed for j in self.occupied):
                        raise ProtocolError('busy')
                    stage.probe_started = True
                return await self._job(request_id, deadline, lambda: self._probe(request_id, stage),
                                       stage=stage, probe=True)
            if method == 'product.loginCancel':
                with self.state_lock:
                    if stage.cancel_selected:
                        return {'stageID': stage.stage_id, 'intentID': stage.intent_id, 'accepted': False}
                    stage.cancel_selected = True
                    accepted = stage.controller.cancel(stage.intent)
                    # A failed/stale presentation cannot erase actual returned
                    # cancellation targets rooted independently of the helper.
                    accepted = accepted or bool(stage.login_ids or stage.thread_ids or stage.turn_ids)
                    stage.stale = True
                if not accepted:
                    return {'stageID': stage.stage_id, 'intentID': stage.intent_id, 'accepted': False}
                return await self._job(request_id, deadline, lambda: self._cancel(request_id, stage), reserved=True)
        if method == 'product.paperPurge':
            # No actual paper producer/registry/binding belongs to this worker.
            # Refusal must precede even local retirement bookkeeping.
            raise ProtocolError('invalidParams')
        if method in ('product.stageRetire', 'product.startupCleanup'):
            if method == 'product.startupCleanup':
                if self.stage is None or params['expectedSelector'] != self.stage.selector:
                    raise ProtocolError('invalidParams')
            with self.state_lock:
                self.cleanup_requests.append((method, dict(params)))
                if self.stage is not None:
                    self.stage.stale = True
                    self.stage.controller.cancel(self.stage.intent)
                request_retirement = not self.retirement_requested
                if request_retirement:
                    self.retirement_requested = True
            if request_retirement:
                try:
                    self._send_control('revokeNeeded', code='scopeRetire')
                except BaseException:
                    self.select_unknown('retirementRequestUncertain')
            # Lifecycle continues to consume retirementID and reapBroker. No
            # cleanup result is emitted: the public SDK has no whole-scope proof.
            await self.park_async()
        raise ProtocolError('unknownMethod')


def worker_main(*, lifecycle_fd=5):
    owner = OfficialSDKWorker()
    try:
        owner.capture(lifecycle_fd)
        owner.start()
        async def serve():
            from agent import Server
            owner.loop = asyncio.get_running_loop()
            owner.server = Server(mode='product', worker=owner)
            owner.lifecycle_task = asyncio.create_task(owner.lifecycle())
            await owner.server.serve()
        # Root before run's self-pipe/kqueue setup. There is deliberately no
        # asyncio.run, loop.close, executor shutdown or uncertain finalization.
        owner.event_loop = asyncio.SelectorEventLoop.__new__(asyncio.SelectorEventLoop)
        asyncio.SelectorEventLoop.__init__(owner.event_loop)
        asyncio.set_event_loop(owner.event_loop)
        owner.event_loop.run_until_complete(serve())
    except BaseException as error:
        owner.failure = owner.failure or error
        owner.select_unknown('workerUncertain')
    # Never unwind through SDK destructors, close the retained client, or exit
    # voluntarily with uncertain writers/threads/namespace/ownership debt.
    owner.park()
