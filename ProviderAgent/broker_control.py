"""Authenticated broker lifecycle; never an SDK RPC transport.

All effects use one lane. Unknown owners deliberately remain rooted and alive.
Startup is bounded separately. Retirement uses an immutable UUID4 and actual
resource observations, never a completion deadline or SDK FileObject proof.
"""
from __future__ import annotations

import array
from collections import deque
import ctypes
from dataclasses import dataclass
import errno
import json
import os
import select
import socket
import stat
import struct
import sys
import time
from typing import NoReturn
import uuid

import broker
from provider_rpc import CONTRACT

_BODY = 65536
_FRAME = _BODY + 4
_QUEUE = CONTRACT['limits']['maxQueuedFrames']
_BYTES = CONTRACT['limits']['maxQueuedBytes']
if (_QUEUE, _BYTES) != (4, 262160):
    raise RuntimeError('brokerLimitsChanged')
_MAX_CONTROL = 1024
_UINT64 = (1 << 64) - 1
_FIELDS = {
    'hello': (), 'run': ('startupDeadlineNs', 'cwdDevice', 'cwdInode'),
    'running': (), 'dispatch': (), 'dispatching': (),
    'revokeNeeded': ('code',), 'revoke': ('retirementID',),
    'cliRetired': ('retirementID', 'scope', 'waitStatus'),
    'preLaunchRetired': ('retirementID',), 'unknown': ('code',),
    'brokerOffered': (), 'reapBroker': ('retirementID',),
    'brokerReaped': ('retirementID', 'waitStatus'),

}
_CODES = frozenset(('startupDeadline', 'stdioEOF', 'cliExit', 'sessionLimit', 'scopeRetire'))
_UNKNOWN_CODES = frozenset(('roleUncertain', 'controlUncertain', 'relayUncertain'))


class ControlError(RuntimeError):
    pass


def _uuid(value):
    if type(value) is not str or str(uuid.UUID(value)) != value:
        raise ControlError('invalidRunID')
    return value


def _uint(value):
    return type(value) is int and 0 <= value <= _UINT64


def retirement_id(value):
    try:
        parsed = uuid.UUID(value) if type(value) is str else None
    except ValueError:
        parsed = None
    if parsed is None or parsed.version != 4 or str(parsed) != value:
        raise ControlError('invalidRetirementID')
    return value


def _pairs(items):
    result = {}
    for key, value in items:
        if key in result:
            raise ControlError('duplicateKey')
        result[key] = value
    return result


def _validate(message):
    if type(message) is not dict:
        raise ControlError('invalidMessage')
    op = message.get('op')
    if type(op) is not str or op not in _FIELDS:
        raise ControlError('invalidOperation')
    if set(message) != {'v', 'runID', 'op', *_FIELDS[op]}:
        raise ControlError('closedMessageRequired')
    if type(message['v']) is not int or message['v'] != 2:
        raise ControlError('invalidVersion')
    _uuid(message['runID'])
    if 'retirementID' in message:
        retirement_id(message['retirementID'])
    for name in ('startupDeadlineNs', 'cwdDevice', 'cwdInode'):
        if name in message and not _uint(message[name]):
            raise ControlError('invalidInteger')
    if 'waitStatus' in message and type(message['waitStatus']) is not int:
        raise ControlError('invalidWaitStatus')
    if op == 'cliRetired' and message['scope'] != 'localDirectCLIResources':
        raise ControlError('invalidScope')
    if op == 'revokeNeeded' and message['code'] not in _CODES:
        raise ControlError('invalidCode')
    if op == 'unknown' and message['code'] not in _UNKNOWN_CODES:
        raise ControlError('invalidCode')
    return message


def encode_control(run_id, op, **fields):
    message = _validate(dict(v=2, runID=run_id, op=op, **fields))
    body = json.dumps(message, separators=(',', ':'), ensure_ascii=True).encode('utf-8')
    if not 0 < len(body) <= _MAX_CONTROL:
        raise ControlError('controlTooLarge')
    return struct.pack('!I', len(body)) + body


class ControlFrames:
    """At most one current frame; callers consume before reading another byte."""
    def __init__(self):
        self.buffer = bytearray()

    @property
    def remaining(self):
        if len(self.buffer) < 4:
            return 4 - len(self.buffer)
        size, = struct.unpack('!I', self.buffer[:4])
        if not 0 < size <= _MAX_CONTROL:
            raise ControlError('invalidLength')
        return 4 + size - len(self.buffer)

    def feed(self, data):
        if not data or len(data) > self.remaining:
            raise ControlError('invalidControlRead')
        self.buffer.extend(data)
        if self.remaining:
            return None
        raw = bytes(self.buffer[4:])
        message = _validate(json.loads(raw.decode('utf-8', errors='strict'),
                                       object_pairs_hook=_pairs))
        self.buffer.clear()
        return message


def _record_counts(data, records, partial, limit=_QUEUE):
    for value in data:
        partial += 1
        if partial > _FRAME:
            raise ControlError('relayRecordTooLarge')
        if value == 10:
            records += 1
            partial = 0
        if records + bool(partial) > limit:
            raise ControlError('relayCumulativeRecords')
    return records, partial


class _RelayBuffer:
    """Rooted records, including a partially written head and one open tail.

    readv fills a reserved byte in the tail itself: no unaccounted read spill.
    A forwarded startup prefix is removed, but its open record keeps its slot.
    """
    def __init__(self):
        self.closed = deque()
        self.partial = bytearray()
        self.open = False
        self.bytes = 0

    @property
    def slots(self):
        return len(self.closed) + self.open

    def clear(self):
        self.closed.clear()
        self.partial.clear()
        self.open = False
        self.bytes = 0

    def read_byte(self, fd):
        if self.bytes >= _BYTES or (not self.open and self.slots >= _QUEUE):
            return None
        was_open = self.open
        self.partial.append(0)  # Reserve before the syscall; rooted on any fault.
        self.bytes += 1
        self.open = True
        try:
            view = memoryview(self.partial)[-1:]
            try:
                count = os.readv(fd, [view])
            finally:
                view.release()
        except BlockingIOError:
            self.partial.pop()
            self.bytes -= 1
            self.open = was_open
            return None
        if count == 0:
            self.partial.pop()
            self.bytes -= 1
            self.open = was_open
            return False
        if count != 1:
            raise ControlError('relayReadUncertain')
        value = self.partial[-1]
        if value == 10:
            self.closed.append(self.partial)
            self.partial = bytearray()
            self.open = False
        return value

    def write(self, fd, live):
        head = self.closed[0] if self.closed else (None if live else self.partial)
        if not head:
            return
        view = memoryview(head)
        try:
            count = os.write(fd, view)
        except BlockingIOError:
            return
        finally:
            view.release()
        if not 0 < count <= len(head):
            raise ControlError('relayWriteUncertain')
        self.bytes -= count
        del head[:count]
        if self.closed:
            if not head:
                self.closed.popleft()


class _AuditToken(ctypes.Structure):
    # Opaque public audit_token_t, never interpreted using offsets or bitfields.
    _fields_ = [('opaque', ctypes.c_uint32 * 8)]


class _BSD(ctypes.Structure):
    _fields_ = ([(name, ctypes.c_uint32) for name in (
        'flags', 'status', 'xstatus', 'pid', 'ppid', 'uid', 'gid', 'ruid',
        'rgid', 'svuid', 'svgid', 'rfu_1')] +
        [('comm', ctypes.c_char * 16), ('name', ctypes.c_char * 32)] +
        [(name, ctypes.c_uint32) for name in ('nfiles', 'pgid', 'pjobc', 'e_tdev', 'e_tpgid')] +
        [('nice', ctypes.c_int32), ('start_tvsec', ctypes.c_uint64),
         ('start_tvusec', ctypes.c_uint64)])


@dataclass(frozen=True)
class KernelPeer:
    uid: int
    gid: int
    pid: int
    pid_version: int
    parent_pid: int
    start_sec: int
    start_usec: int
    token: bytes


def _borrow_socket(fd, method, *args):
    borrowed = socket.socket(fileno=fd)
    try:
        return getattr(borrowed, method)(*args)
    finally:
        borrowed.detach()  # No closure authority over the rooted raw descriptor.


def peer_identity(fd: int) -> KernelPeer:
    """Fail-closed kernel token + bracketed BSD identity, not nonce authority."""
    if sys.platform != 'darwin':
        raise ControlError('darwinRequired')
    lib = ctypes.CDLL('/usr/lib/libSystem.B.dylib', use_errno=True)
    proc = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
    bsm = ctypes.CDLL('/usr/lib/libbsm.dylib', use_errno=True)
    lib.getpeereid.argtypes = [ctypes.c_int, ctypes.POINTER(ctypes.c_uint32),
                               ctypes.POINTER(ctypes.c_uint32)]
    lib.getpeereid.restype = ctypes.c_int
    proc.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64,
                                  ctypes.c_void_p, ctypes.c_int]
    proc.proc_pidinfo.restype = ctypes.c_int
    proc.proc_pidpath_audittoken.argtypes = [ctypes.POINTER(_AuditToken),
                                            ctypes.c_void_p, ctypes.c_uint32]
    proc.proc_pidpath_audittoken.restype = ctypes.c_int
    for name, result in (('pid', ctypes.c_int32), ('pidversion', ctypes.c_int),
                          ('euid', ctypes.c_uint32), ('egid', ctypes.c_uint32)):
        function = getattr(bsm, 'audit_token_to_' + name)
        function.argtypes, function.restype = [_AuditToken], result

    def snapshot_peer():
        uid, gid = ctypes.c_uint32(), ctypes.c_uint32()
        if lib.getpeereid(fd, ctypes.byref(uid), ctypes.byref(gid)) != 0:
            raise ControlError('peerCredentialsDenied')
        try:
            raw_pid = _borrow_socket(fd, 'getsockopt', 0, 2, ctypes.sizeof(ctypes.c_int))
            raw_token = _borrow_socket(fd, 'getsockopt', 0, 6, ctypes.sizeof(_AuditToken))
        except OSError:
            raise ControlError('peerSocketUnavailable') from None
        if len(raw_pid) != 4 or len(raw_token) != 32:
            raise ControlError('shortPeerIdentity')
        pid, = struct.unpack('=i', raw_pid)
        token = _AuditToken.from_buffer_copy(raw_token)
        version = bsm.audit_token_to_pidversion(token)
        if (pid <= 0 or version < 0 or bsm.audit_token_to_pid(token) != pid
                or bsm.audit_token_to_euid(token) != uid.value
                or bsm.audit_token_to_egid(token) != gid.value):
            raise ControlError('peerTokenMismatch')
        return uid.value, gid.value, pid, version, raw_token

    first = snapshot_peer()
    token = _AuditToken.from_buffer_copy(first[4])
    path = ctypes.create_string_buffer(4096)
    if not 0 < proc.proc_pidpath_audittoken(ctypes.byref(token), path, len(path)) < len(path):
        raise ControlError('tokenProcessDenied')
    info = _BSD()
    if proc.proc_pidinfo(first[2], 3, 0, ctypes.byref(info), ctypes.sizeof(info)) != ctypes.sizeof(info):
        raise ControlError('shortProcessIdentity')
    if not 0 < proc.proc_pidpath_audittoken(ctypes.byref(token), path, len(path)) < len(path):
        raise ControlError('tokenProcessChanged')
    if snapshot_peer() != first or (info.pid, info.uid, info.gid) != (first[2], first[0], first[1]):
        raise ControlError('processIdentityChanged')
    if first[0] != os.getuid() or os.getuid() != os.geteuid() or not info.start_tvsec:
        raise ControlError('peerUIDMismatch')
    return KernelPeer(*first[:4], info.ppid, info.start_tvsec, info.start_tvusec, first[4])


def _directory(fd):
    info = os.fstat(fd)
    current = os.stat('.')
    if (not stat.S_ISDIR(info.st_mode) or stat.S_IMODE(info.st_mode) != 0o700
            or info.st_uid != os.getuid() or os.getuid() != os.geteuid()
            or (info.st_dev, info.st_ino) != (current.st_dev, current.st_ino)):
        raise ControlError('privateCurrentDirectoryRequired')
    return info


class _Resources:
    """Raw descriptor accounting only; CLI ownership stays in broker.py."""
    def __init__(self):
        self.fds = {}
        self.identities = {}
        self.uncertain_fds = set()
        self.state = 'settingUp'
        self.reason = None
        self.retirement_id = None
        self.pending_socket = None
        self.lib = None
        broker._ROOTS.append(self)  # Before opening/accepting any resource.

    def own(self, name, fd):
        self.fds[name] = fd
        self.identities[name] = os.fstat(fd)
        os.set_inheritable(fd, False)
        return fd

    def new_socket(self, name):
        if self.state in ('unknown', 'clean'):
            raise ControlError('resourceTerminal')
        self.pending_socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.fds[name] = self.pending_socket.detach()
        self.pending_socket = None
        return self.own(name, self.fds[name])

    def clock(self, deadline=None):
        if self.state in ('unknown', 'clean'):
            raise ControlError('resourceTerminal')
        if self.retirement_id is not None:
            if deadline is not None:
                raise ControlError('startupBoundDuringRetirement')
            return
        if not _uint(deadline) or time.monotonic_ns() >= deadline:
            raise ControlError('deadlineExpired')

    def latch(self, identity):
        identity = retirement_id(identity)
        if self.retirement_id is not None and identity != self.retirement_id:
            raise ControlError('retirementChanged')
        self.retirement_id = identity

    def close(self, name, deadline=None):
        if self.state in ('unknown', 'clean') or name in self.uncertain_fds:
            raise ControlError('resourceTerminal')
        try:
            self.clock(deadline)
            fd = self.fds[name]
            if fd is None:
                return
            actual, expected = os.fstat(fd), self.identities[name]
            # Darwin socket permission bits describe current read/write readiness;
            # peer exit changes them without changing this owned socket instance.
            actual_mode, expected_mode = actual.st_mode, expected.st_mode
            if stat.S_ISSOCK(expected_mode):
                actual_mode, expected_mode = stat.S_IFMT(actual_mode), stat.S_IFMT(expected_mode)
            if (actual.st_dev, actual.st_ino, actual_mode) != (
                    expected.st_dev, expected.st_ino, expected_mode):
                raise ControlError('descriptorChanged')
            if self.lib is None:
                self.lib = ctypes.CDLL('/usr/lib/libSystem.B.dylib', use_errno=True)
                self.lib.close.argtypes, self.lib.close.restype = [ctypes.c_int], ctypes.c_int
            self.clock(deadline)
            result = self.lib.close(fd)
            if result != 0:
                raise ControlError('closeUncertain')
            self.fds[name] = None  # Capture actual result before the clock check.
            self.clock(deadline)
        except BaseException:
            self.uncertain_fds.add(name)
            self.unknown()
            raise

    def unknown(self, code='roleUncertain'):
        if self.state != 'clean':
            self.state, self.reason = 'unknown', self.reason or code

    def park(self) -> NoReturn:
        # No notification, descriptor operation, voluntary exit or late cleanup.
        while True:
            try:
                time.sleep(3600)
            except BaseException:
                pass


@dataclass(frozen=True)
class ReapRecord:
    retirement_id: str
    wait_status: int
    scope: str = 'localDirectBrokerProcess'


class AuthenticatedBroker(_Resources):
    def __init__(self, rendezvous):
        super().__init__()
        self.rendezvous = rendezvous
        self.peer = None
        self.offered = False
        self.wait_attempted = False
        self.reaped = None
        self.wait_status = ctypes.c_int()

    def wait_direct_child(self, identity: str) -> ReapRecord:
        if self.state == 'unknown' or self.wait_attempted:
            raise ControlError('brokerWaitAlreadyUsed')
        try:
            self.latch(identity)
            if self.peer.parent_pid != os.getpid():
                raise ControlError('notDirectChild')
            self.lib = ctypes.CDLL('/usr/lib/libSystem.B.dylib', use_errno=True)
            self.lib.waitpid.argtypes = [ctypes.c_int, ctypes.POINTER(ctypes.c_int), ctypes.c_int]
            self.lib.waitpid.restype = ctypes.c_int
            self.lib.close.argtypes, self.lib.close.restype = [ctypes.c_int], ctypes.c_int
            while True:
                self.clock()
                # WNOHANG zero means no completed wait, not an uncertain retry.
                pid = self.lib.waitpid(self.peer.pid, ctypes.byref(self.wait_status), os.WNOHANG)
                if pid != 0:
                    self.wait_attempted = True
                    if pid == self.peer.pid:
                        self.reaped = ReapRecord(identity, self.wait_status.value)
                    self.clock()
                    if (pid != self.peer.pid or not os.WIFEXITED(self.wait_status.value)
                            or os.WEXITSTATUS(self.wait_status.value) != 0):
                        raise ControlError('brokerExitUncertain')
                    self.state = 'reaped'
                    return self.reaped
                select.select([], [], [], 0.001)
        except BaseException:
            self.wait_attempted = True
            self.unknown()
            raise


class WorkerRendezvous(_Resources):
    """Worker entry must park on rooted helper failure, never unwind/exit.

    Helpers expose fixed failures so a fixture can inspect the retained debt.
    These Python helpers do not establish an independent execution bound.
    """
    def __init__(self, run_id, startup_deadline_ns):
        super().__init__()
        self.run_id = run_id
        self.startup_deadline_ns = startup_deadline_ns
        self.accept_used = False
        self.accepted = None
        self.entry = None
        self.offer_started = False
        self.offer_bytes = bytearray()

    def accept_broker(self) -> AuthenticatedBroker:
        if self.accept_used or self.state != 'listening':
            raise ControlError('singleAcceptRequired')
        self.accept_used = True
        accepted = self.accepted = AuthenticatedBroker(self)
        try:
            self.clock(self.startup_deadline_ns)
            ready, _, _ = select.select([self.fds['listener']], [], [],
                max(0, (self.startup_deadline_ns - time.monotonic_ns()) / 1e9))
            if not ready:
                raise ControlError('acceptExpired')
            accepted.pending_socket, _ = _borrow_socket(self.fds['listener'], 'accept')
            accepted.fds['control'] = accepted.pending_socket.detach()
            accepted.pending_socket = None
            fd = accepted.own('control', accepted.fds['control'])
            os.set_blocking(fd, False)
            accepted.peer = peer_identity(fd)
            if accepted.peer.parent_pid != os.getpid():
                raise ControlError('brokerNotDirectChild')
            self.clock(self.startup_deadline_ns)
            accepted.state = 'authenticated'
            self.state = 'accepted'
            return accepted
        except BaseException:
            accepted.unknown()
            self.unknown()
            raise

    def offer_to_native(self, native_lifecycle_fd: int, authenticated_broker: AuthenticatedBroker) -> None:
        if (self.state != 'accepted' or self.offer_started or authenticated_broker is not self.accepted
                or authenticated_broker.state != 'authenticated'):
            raise ControlError('invalidBrokerOffer')
        self.offer_started = True
        try:
            self.clock(self.startup_deadline_ns)
            # FD5 is borrowed lifecycle transport. Its peer PID is NOT worker authority.
            rights = array.array('i', [authenticated_broker.fds['control']])
            sent = _borrow_socket(native_lifecycle_fd, 'sendmsg', [b'B'],
                                  [(socket.SOL_SOCKET, socket.SCM_RIGHTS, rights)], socket.MSG_DONTWAIT)
            if sent != 1:
                raise ControlError('offerUncertain')
            authenticated_broker.offered = True
            self.clock(self.startup_deadline_ns)
            self.offer_bytes.extend(encode_control(self.run_id, 'brokerOffered'))
            while self.offer_bytes:
                self.clock(self.startup_deadline_ns)
                try:
                    count = _borrow_socket(native_lifecycle_fd, 'send', self.offer_bytes, socket.MSG_DONTWAIT)
                except BlockingIOError:
                    select.select([], [native_lifecycle_fd], [],
                        max(0, (self.startup_deadline_ns - time.monotonic_ns()) / 1e9))
                    continue
                if count <= 0:
                    raise ControlError('offerWriteUncertain')
                del self.offer_bytes[:count]
            self.clock(self.startup_deadline_ns)
        except BaseException:
            self.unknown()
            authenticated_broker.unknown()
            raise

    def retire(self, identity: str):
        """Worker-only checked retirement, after its actual broker waitpid."""
        try:
            self.latch(identity)
            accepted = self.accepted
            if (self.state != 'accepted' or accepted is None or accepted.state != 'reaped'
                    or accepted.reaped.retirement_id != identity):
                raise ControlError('brokerNotReaped')
            accepted.close('control')
            self.close('listener')
            actual = os.stat('b', dir_fd=self.fds['cwd'], follow_symlinks=False)
            if (actual.st_dev, actual.st_ino, actual.st_mode) != self.entry:
                raise ControlError('socketEntryChanged')
            self.clock()
            os.unlink('b', dir_fd=self.fds['cwd'])
            self.entry = None
            self.clock()
            self.close('cwd')
            self.state = 'clean'
        except BaseException:
            self.unknown()
            raise


def open_worker_rendezvous(cwd_fd: int, *, run_id: str, startup_deadline_ns: int) -> WorkerRendezvous:
    owner = WorkerRendezvous(run_id, startup_deadline_ns)
    try:
        _uuid(run_id)
        if not _uint(startup_deadline_ns):
            raise ControlError('invalidStartupDeadline')
        owner.clock(startup_deadline_ns)
        _directory(cwd_fd)  # Caller must already be in the real directory.
        owner.own('cwd', os.dup(cwd_fd))
        try:
            os.stat('b', dir_fd=owner.fds['cwd'], follow_symlinks=False)
        except FileNotFoundError:
            pass
        else:
            raise ControlError('rendezvousExists')
        listener = owner.new_socket('listener')
        os.set_blocking(listener, False)
        _borrow_socket(listener, 'bind', 'b')
        info = os.stat('b', dir_fd=owner.fds['cwd'], follow_symlinks=False)
        owner.entry = (info.st_dev, info.st_ino, info.st_mode)
        if not stat.S_ISSOCK(info.st_mode) or info.st_uid != os.getuid():
            raise ControlError('socketEntryUncertain')
        _borrow_socket(listener, 'listen', 1)
        owner.clock(startup_deadline_ns)
        owner.state = 'listening'
        return owner
    except BaseException:
        owner.unknown()
        raise


class _Role(_Resources):
    def __init__(self, factory):
        super().__init__()
        self.factory = factory
        self.factory_entered = False
        self.cli = None
        self.run_id = None
        self.startup_deadline = None
        self.decoder = ControlFrames()
        self.control_out = bytearray()
        self.input = _RelayBuffer()
        self.output = _RelayBuffer()
        self.read_buffer = b''
        self.control_message = None
        self.input_bytes = 0
        self.input_lines = 0
        self.input_partial = 0
        self.stdout_bytes = 0
        self.stdout_lines = 0
        self.stdout_partial = 0
        self.stderr_bytes = 0
        self.peer = None
        self.run_seen = False
        self.dispatch_seen = False
        self.running_sent = False
        self.startup_counters = None
        self.revoke_needed = False
        self.frozen = False
        self.control_blocked = False
        self.endpoints = None
        self.definite_refusal = False

    def unknown(self, code='roleUncertain'):
        super().unknown(code)
        if self.cli is not None:
            self.cli.mark_unknown(code)

    def observe(self):
        if self.state == 'unknown':
            raise ControlError('roleUnknown')
        if self.cli is not None and self.cli.observe_pending()['state'] == 'unknown':
            raise ControlError('cliUnknown')

    def queue(self, op, **fields):
        frame = encode_control(self.run_id, op, **fields)
        if len(self.control_out) + len(frame) > _MAX_CONTROL + 4:
            raise ControlError('controlBackpressure')
        self.control_out.extend(frame)

    def request_revoke(self, code):
        self.frozen = True
        if not self.revoke_needed:
            self.revoke_needed = True
            self.queue('revokeNeeded', code=code)

    def receive(self):
        # Drain control first, bounded per turn so hostile duplicates cannot starve retirement.
        for _ in range(16):
            self.observe()
            try:
                data = os.read(self.fds['control'], self.decoder.remaining)
            except BlockingIOError:
                return
            if not data:
                raise ControlError('controlEOF')
            self.control_message = self.decoder.feed(data)
            message = self.control_message
            if message is None:
                continue
            if message['runID'] != self.run_id:
                raise ControlError('runIDMismatch')
            op = message['op']
            if op == 'revoke':
                self.latch(message['retirementID'])
                self.frozen = True
            elif op == 'run' and not self.run_seen and self.retirement_id is None and self.state == 'awaitingRun':
                self.run_seen = True
                info = os.fstat(self.fds['cwd'])
                if (message['startupDeadlineNs'] != self.startup_deadline
                        or (message['cwdDevice'], message['cwdInode']) != (info.st_dev, info.st_ino)):
                    raise ControlError('namespaceMismatch')
            elif (op == 'dispatch' and self.running_sent and not self.dispatch_seen
                  and self.state == 'relaying' and not self.frozen and self.retirement_id is None
                  and time.monotonic_ns() < self.startup_deadline):
                self.startup_counters = (self.input_bytes, self.input_lines, self.input_partial,
                                         self.stdout_bytes, self.stdout_lines, self.stdout_partial,
                                         self.stderr_bytes)
                self.dispatch_seen = True
                self.queue('dispatching')
            else:
                raise ControlError('invalidTransition')
            self.control_message = None
        raise ControlError('controlFlood')

    def priority(self):
        self.receive()
        self.observe()
        if self.retirement_id is not None:
            self.retire()
        if self.cli is not None and self.cli.record['exitObserved']:
            self.request_revoke('cliExit')
        if not self.dispatch_seen and time.monotonic_ns() >= self.startup_deadline:
            if self.control_blocked and self.control_out:
                raise ControlError('controlBackpressure')
            self.request_revoke('startupDeadline')

    def send_pending(self, deadline=None):
        while self.control_out:
            self.clock(None if self.retirement_id is not None else deadline)
            self.receive()
            self.observe()
            if self.retirement_id is not None:
                deadline = None
            self.clock(deadline)
            try:
                count = os.write(self.fds['control'], self.control_out)
            except BlockingIOError:
                select.select([self.fds['control']], [self.fds['control']], [],
                              None if deadline is None else max(0, (deadline - time.monotonic_ns()) / 1e9))
                continue
            if count <= 0:
                raise ControlError('controlWriteUncertain')
            del self.control_out[:count]
            self.clock(deadline)

    def setup(self):
        # Capture all inherited role stdio before any fallible observation.
        self.fds.update(stdin=0, stdout=1, stderr=2)
        for name in ('stdin', 'stdout', 'stderr'):
            self.own(name, self.fds[name])
        self.own('cwd', os.open('.', os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW))
        _directory(self.fds['cwd'])
        self.run_id = _uuid(os.environ['PAPERLENS_BROKER_RUN_ID'])
        raw_deadline = os.environ['PAPERLENS_BROKER_START_DEADLINE_NS']
        if not raw_deadline.isascii() or not raw_deadline.isdecimal():
            raise ControlError('invalidStartupDeadline')
        self.startup_deadline = int(raw_deadline)
        if not _uint(self.startup_deadline):
            raise ControlError('invalidStartupDeadline')
        self.clock(self.startup_deadline)
        control = self.new_socket('control')
        os.set_blocking(control, False)
        result = _borrow_socket(control, 'connect_ex', 'b')
        if result in (errno.ENOENT, errno.ECONNREFUSED):
            self.definite_refusal = True
            raise ControlError('missingListener')
        if result in (errno.EINPROGRESS, errno.EAGAIN):
            _, ready, _ = select.select([], [control], [],
                max(0, (self.startup_deadline - time.monotonic_ns()) / 1e9))
            if not ready or _borrow_socket(control, 'getsockopt', socket.SOL_SOCKET, socket.SO_ERROR):
                raise ControlError('connectUncertain')
        elif result != 0:
            raise ControlError('connectUncertain')
        self.peer = peer_identity(control)
        parent = os.getppid()
        if self.peer.pid != parent or os.getppid() != parent:
            self.definite_refusal = True
            raise ControlError('listenerNotParent')
        self.state = 'awaitingRun'
        self.queue('hello')
        self.send_pending(self.startup_deadline)
        for name in ('stdin', 'stdout', 'stderr'):
            os.set_blocking(self.fds[name], False)

    def start(self):
        self.priority()  # Queued pre-factory revoke takes precedence over run.
        if self.frozen:
            return
        _directory(self.fds['cwd'])
        # Exactly six keys; bootstrap selectors and ambient credentials excluded.
        environment = {key: os.environ[key] for key in broker._ENV_KEYS}
        self.priority()
        if self.frozen:
            return
        self.factory_entered = True
        self.state = 'creatingCLI'
        self.cli = self.factory(self.fds['cwd'], environment)
        self.priority()  # Capture returned primitive before fallible observation.
        if self.frozen:
            return
        if self.cli.resume()['state'] != 'running':
            raise ControlError('cliResumeUncertain')
        self.endpoints = self.cli.endpoints
        self.state = 'relaying'
        self.queue('running')

    def input_count(self, data):
        if self.input_bytes + len(data) > _BYTES:
            raise ControlError('inputCumulativeBytes')
        self.input_lines, self.input_partial = _record_counts(
            data, self.input_lines, self.input_partial, 256 if self.dispatch_seen else _QUEUE)
        self.input_bytes += len(data)

    def stdout_count(self, data):
        if self.stdout_bytes + len(data) > _BYTES:
            raise ControlError('stdoutCumulativeBytes')
        self.stdout_lines, self.stdout_partial = _record_counts(
            data, self.stdout_lines, self.stdout_partial, 256 if self.dispatch_seen else _QUEUE)
        self.stdout_bytes += len(data)

    def relay_once(self):
        self.priority()
        if self.frozen or self.endpoints is None:
            return
        source = self.endpoints
        for fd, target, kind in ((self.fds['stdin'], self.input, 'input'),
                                  (source['stdout'], self.output, 'output'),
                                  (source['stderr'], None, 'stderr')):
            self.priority()
            if self.frozen:
                return
            # Control and the actual CLI watch gate each bounded read burst;
            # polling both again for every byte needlessly multiplies syscalls.
            for _ in range(256):
                prefix = 'stdout' if kind == 'output' else kind
                total = getattr(self, prefix + '_bytes')
                if total == _BYTES:
                    self.request_revoke('sessionLimit')
                    return
                if target is not None:
                    lines = getattr(self, prefix + '_lines')
                    partial = getattr(self, prefix + '_partial')
                    if partial == _FRAME or (not partial and lines == (256 if self.dispatch_seen else _QUEUE)):
                        self.request_revoke('sessionLimit')
                        return
                    value = target.read_byte(fd)
                    if value is None:
                        break
                    if value is False:
                        self.request_revoke('stdioEOF')
                        return
                    # The only new byte is already rooted in its record.
                    if value == 10:
                        setattr(self, prefix + '_lines', lines + 1)
                        setattr(self, prefix + '_partial', 0)
                    else:
                        setattr(self, prefix + '_partial', partial + 1)
                else:
                    if self.output.bytes == _BYTES:
                        break  # Reserve stderr's one-byte scratch on the output lane.
                    try:
                        self.read_buffer = os.read(fd, 1)
                    except BlockingIOError:
                        break
                    if not self.read_buffer:
                        break
                    self.read_buffer = b''
                setattr(self, prefix + '_bytes', total + 1)
                if target is not None and value == 10:
                    break  # Give each completed record a write turn before admission.
        for fd, pending in ((source['stdin'], self.input), (self.fds['stdout'], self.output)):
            self.priority()
            if self.frozen:
                return
            pending.write(fd, self.dispatch_seen)

    def retire(self) -> NoReturn:
        self.frozen = True
        self.clock()
        self.observe()
        self.state = 'revoked'
        if not self.factory_entered:
            self.queue('preLaunchRetired', retirementID=self.retirement_id)
        else:
            if self.cli is None:
                raise ControlError('missingFactoryResult')
            record = self.cli.record
            if record['state'] == 'running':
                self.cli.close_stdin(self.retirement_id)
            record = self.cli.cleanup(self.retirement_id, terminate=True)
            if record['state'] != 'clean':
                raise ControlError('cliRetirementUncertain')
            self.queue('cliRetired', retirementID=self.retirement_id,
                       scope=record['scope'], waitStatus=record['waitStatus'])
        self.send_pending()
        for name in ('stdin', 'stdout', 'stderr', 'cwd'):
            self.close(name)
        self.receive()  # Changed retirement/queued malformed control cannot authorize exit.
        if self.decoder.buffer:
            raise ControlError('incompleteControlAtRetirement')
        self.close('control')
        self.clock()
        self.state = 'clean'
        os._exit(0)

    def run(self) -> NoReturn:
        try:
            self.setup()
            while True:
                self.priority()
                if self.run_seen and not self.factory_entered and not self.frozen:
                    self.start()
                self.relay_once()
                if self.control_out:
                    # Nonblocking single write; backpressure cannot stall control.
                    self.priority()
                    try:
                        count = os.write(self.fds['control'], self.control_out)
                    except BlockingIOError:
                        self.control_blocked = True
                        count = None
                    if count is not None:
                        if count <= 0:
                            raise ControlError('controlWriteUncertain')
                        self.control_blocked = False
                        del self.control_out[:count]
                        if not self.control_out and self.state == 'relaying':
                            self.running_sent = True
                select.select([self.fds['control']], [], [], 0.001)
        except BaseException:
            if self.definite_refusal and not self.factory_entered:
                try:
                    for name in tuple(self.fds):
                        self.close(name, self.startup_deadline)
                    os._exit(1)
                except BaseException:
                    pass
            self.unknown()
            self.park()


def native_broker_main(*, _resource_factory=broker.production) -> NoReturn:
    """Callable role. Factory injection is private code only, never argv/env."""
    role = _Role(_resource_factory)
    role.run()
