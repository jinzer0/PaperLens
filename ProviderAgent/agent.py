"""Topology SDK probe and Agent-owned synthetic attempt-cleanup fixtures."""
from __future__ import annotations

import asyncio
from dataclasses import dataclass, field
import errno
from contextlib import contextmanager, ExitStack
import fcntl
import importlib
import json
import os
from pathlib import Path
import platform
import pwd
import shutil
import socket
import stat
import subprocess
import sys
import threading
import time
import uuid

# The signed resources directory is the only additional import root.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from provider_rpc import (  # noqa: E402
    CONTRACT, FrameDecoder, ProtocolError, encode_frame, decode_frame,
    validate_request, validate_terminal,
)

MAIN_ID = 'io.github.jinzer0.PaperLens'
AGENT_ID = MAIN_ID + '.ProviderAgent'
GROUP_ID = '397452Z366.io.github.jinzer0.PaperLens.TopologyFixture'
MARKER = b'PaperLens topology canary\n'
LIMITS = CONTRACT['limits']


def fixture_profile() -> tuple[Path, Path]:
    """Resolve account metadata, never sandbox HOME or a caller-selected profile."""
    uid = os.getuid()
    if uid < 500 or os.geteuid() != uid:
        raise PermissionError('fixtureProfileUnavailable')
    account = pwd.getpwuid(uid)
    home = Path(account.pw_dir)
    if account.pw_uid != uid or not home.is_absolute() or home == Path('/'):
        raise PermissionError('fixtureProfileUnavailable')
    info = home.lstat()
    if (not stat.S_ISDIR(info.st_mode) or info.st_uid != uid
            or home.resolve(strict=True) != home):
        raise PermissionError('fixtureProfileUnavailable')
    map_path = Path(__file__).resolve().parent / 'fixture-map.json'
    fd = os.open(map_path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_size > 4096:
            raise PermissionError('fixtureMapMismatch')
        with os.fdopen(fd, 'rb', closefd=False) as source:
            pairs = json.loads(source.read(4097), object_pairs_hook=list)
        if (not isinstance(pairs, list) or len(pairs) != 2
                or sorted(pairs) != sorted([
                    ('profile', 'current-user'), ('groupID', GROUP_ID)])):
            raise PermissionError('fixtureMapMismatch')
    finally:
        os.close(fd)
    root = home / 'Library/Containers' / AGENT_ID / 'Data'
    if Path.home() != root or Path(os.environ.get('HOME', '')) != root:
        raise PermissionError('containerMismatch')
    for directory in (home / 'Library', home / 'Library/Containers', root.parent, root):
        info = directory.lstat()
        if (not stat.S_ISDIR(info.st_mode) or info.st_uid != uid
                or directory.resolve(strict=True) != directory):
            raise PermissionError('containerMismatch')
    return home, root


def private_directory(path: Path, *, strict: bool = True) -> bool:
    """Never follow a pre-existing symlink or modify an existing directory mode."""
    try:
        path.mkdir(mode=0o700)
    except FileExistsError:
        info = path.lstat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
            raise PermissionError('unsafeDirectory')
        if strict and stat.S_IMODE(info.st_mode) != 0o700:
            raise PermissionError('unsafePermissions')
        return False
    return True


def safe_uuid(value: str) -> str:
    parsed = uuid.UUID(value)
    if parsed.version != 4 or str(parsed) != value:
        raise ValueError('invalidID')
    return value


class AttemptBusy(Exception):
    pass


class AttemptCancelled(Exception):
    pass


class AttemptInvalid(ValueError):
    pass


@dataclass
class AttemptProducer:
    identity: dict
    stop: threading.Event = field(default_factory=threading.Event)
    closed: threading.Event = field(default_factory=threading.Event)
    success: bool = False
    deadline: float = field(default_factory=lambda: time.monotonic() + LIMITS['maxTimeoutMs'] / 1000)


class AttemptSession:
    """Lease and census for only the registered synthetic prepare function."""
    def __init__(self):
        self.state = threading.RLock()
        self.gate = threading.Lock()
        self.records: dict[str, tuple[str, dict]] = {}
        self.used: set[str] = set()
        self.producers: dict[str, AttemptProducer] = {}
        self.revoked: dict[tuple[str, str], int] = {}
        self.admitted_runs: set[str] = set()
        self.cleaning_runs: set[str] = set()
        self.closing = False
        self.released = False
        self.failed_closure = False
        self.lease = None
        self.root_fd = None
        self.owner_fd = None

    def reserve(self, kind, identity):
        correlation = identity['correlationID']
        previous = self.records.get(correlation)
        if previous is not None:
            if previous != (kind, identity):
                raise AttemptInvalid('correlationIdentity')
            return
        if len(self.records) >= 256:
            raise AttemptBusy()
        self.records[correlation] = (kind, dict(identity))

    @contextmanager
    def state_until(self, deadline=None):
        end = time.monotonic() + 0.3 if deadline is None else deadline
        if not self.state.acquire(timeout=max(0, end - time.monotonic())):
            raise TimeoutError('stateDeadline')
        try:
            if time.monotonic() >= end:
                raise TimeoutError('stateDeadline')
            yield
        finally:
            self.state.release()

    def register(self, identity, deadline=None):
        end = time.monotonic() + LIMITS['maxTimeoutMs'] / 1000 if deadline is None else deadline
        with self.state_until(end):
            known = self.records.get(identity['correlationID'])
            if known is not None and known != ('attempt', identity):
                raise AttemptInvalid('correlationIdentity')
            if self.closing or identity['runID'] in self.cleaning_runs:
                raise AttemptBusy()
            if (identity['runID'], identity['paperID']) in self.revoked:
                raise AttemptCancelled()
            self.reserve('attempt', identity)
            if identity['correlationID'] in self.used:
                raise AttemptInvalid('consumedAttempt')
            previous = self.producers.get(identity['correlationID'])
            if previous is not None and (not previous.closed.is_set() or previous.success):
                raise AttemptInvalid('consumedAttempt')
            producer = AttemptProducer(dict(identity), deadline=end)
            self.producers[identity['correlationID']] = producer
            return producer

    def select(self, producer):
        with self.state_until(producer.deadline):
            if self.producers.get(producer.identity['correlationID']) is not producer:
                raise PermissionError('unregisteredProducer')
            if self.failed_closure:
                raise PermissionError('descriptorClosureUnknown')
            if (producer.stop.is_set() or self.closing
                    or (producer.identity['runID'], producer.identity['paperID']) in self.revoked):
                raise AttemptCancelled()
            producer.success = True

    def require_producer(self, producer):
        with self.state_until(producer.deadline):
            if (self.producers.get(producer.identity['correlationID']) is not producer
                    or producer.closed.is_set()):
                raise PermissionError('unregisteredProducer')

    @contextmanager
    def cleanup_admission(self, runID, deadline):
        with self.state_until(deadline):
            if any(not p.closed.is_set() and p.identity['runID'] == runID
                   for p in self.producers.values()):
                raise AttemptBusy()
            self.cleaning_runs.add(runID)
        try:
            yield
        finally:
            # Expired/failed cleanup keeps admission fenced until a bounded retry.
            if time.monotonic() < deadline:
                with self.state_until(deadline):
                    self.cleaning_runs.discard(runID)

    def validate(self, store):
        _, container = fixture_profile()
        with ExitStack() as stack:
            current = os.open('/', os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_NONBLOCK)
            stack.callback(store.close_fd, current)
            for index, component in enumerate((*container.parts[1:], 'Library', 'Application Support')):
                current = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW |
                                  os.O_NONBLOCK, dir_fd=current)
                stack.callback(store.close_fd, current)
                if (index >= len(container.parts) - 2
                        and os.fstat(current).st_uid != os.getuid()):
                    raise PermissionError('unsafeParent')
            named = store.open_dir(current, store.namespace)
            stack.callback(store.close_fd, named)
            store.check(self.root_fd, True)
            store.check(self.owner_fd, False)
            if store.identity(named) != store.identity(self.root_fd):
                raise PermissionError('rootIdentity')
            receipt = store.receipt(named, '.owner.json', {
                'version': 1, 'kind': 'root', 'directory': store.identity(self.root_fd)})
            if receipt['self'] != store.identity(self.owner_fd):
                raise PermissionError('receiptIdentity')

    def close(self, store, timeout=0.3):
        end = time.monotonic() + min(timeout, 0.3)
        with self.state_until(end):
            self.closing = True
            producers = list(self.producers.values())
            for producer in producers:
                producer.stop.set()
        for producer in producers:
            if not producer.closed.wait(max(0, end - time.monotonic())):
                raise PermissionError('producerClosureUnknown')
        if not self.gate.acquire(timeout=max(0, end - time.monotonic())):
            raise PermissionError('operationClosureUnknown')
        try:
            if self.failed_closure:
                raise PermissionError('descriptorClosureUnknown')
            if self.lease is not None:
                previous = getattr(store.local, 'session', None)
                store.local.session = self
                try:
                    self.lease.__exit__(None, None, None)
                finally:
                    store.local.session = previous
                self.lease = None
                self.root_fd = None
                self.owner_fd = None
            self.released = True
        finally:
            self.gate.release()


class AttemptFixtures:
    """Private synthetic crash-recovery substrate; not an SDK outcome ledger."""
    namespace = 'PaperLensAttemptFixturesV1'
    marker = b'PaperLens synthetic attempt fixture\n'
    local = threading.local()

    def __init__(self, session: AttemptSession | None = None) -> None:
        self.session = session or AttemptSession()
        self.used = self.session.used

    def close(self, timeout=0.3):
        """Close the whole shared session, not an individual store's borrowed FDs."""
        self.session.close(self, timeout)

    def checkpoint(self, phase: str, producer: AttemptProducer):
        """Test barriers wrap the real writer; stop is checked after every barrier."""
        if producer.stop.is_set():
            raise AttemptCancelled()

    @classmethod
    def close_fd(cls, fd):
        try:
            os.close(fd)
        except BaseException:
            session = getattr(cls.local, 'session', None)
            if session is not None:
                session.failed_closure = True
            raise

    def close_bound_fd(self, fd, identity):
        """Deferred lease cleanup must not close a recycled descriptor number."""
        try:
            if self.identity(fd) != identity:
                raise PermissionError('descriptorIdentityUnknown')
        except BaseException:
            self.session.failed_closure = True
            raise
        self.close_fd(fd)

    @contextmanager
    def root(self, create: bool, deadline: float | None = None, *, admitted=False):
        """Even absence inspection requires the verified, retained named-root lease."""
        session = self.session
        end = time.monotonic() + 0.3 if deadline is None else deadline
        if not session.gate.acquire(timeout=max(0, end - time.monotonic())):
            raise TimeoutError('operationDeadline')
        previous = getattr(self.local, 'session', None)
        self.local.session = session
        try:
            if time.monotonic() >= end:
                raise TimeoutError('operationDeadline')
            if session.failed_closure:
                raise PermissionError('descriptorClosureUnknown')
            if session.released or (session.closing and not admitted):
                raise AttemptBusy()
            if session.lease is None:
                root, owner, lease = self.lease_root()
                session.lease = lease
                session.root_fd = root
                session.owner_fd = owner
            session.validate(self)
            yield session.root_fd
            session.validate(self)
        finally:
            self.local.session = previous
            session.gate.release()

    @staticmethod
    def identity(fd: int) -> list[int]:
        info = os.fstat(fd)
        return [info.st_dev, info.st_ino]

    @staticmethod
    def check(fd: int, directory: bool) -> None:
        info = os.fstat(fd)
        # Directory link counts vary by filesystem and child count; zero is unlinked.
        # Regular files must have exactly one link, including all ownership receipts.
        if (info.st_uid != os.getuid()
                or stat.S_IMODE(info.st_mode) != (0o700 if directory else 0o600)
                or not (stat.S_ISDIR(info.st_mode) if directory else stat.S_ISREG(info.st_mode))
                or (info.st_nlink < 1 if directory else info.st_nlink != 1)):
            raise PermissionError('unsafeFixture')

    @classmethod
    def open_dir(cls, parent: int, name: str) -> int:
        fd = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_NONBLOCK,
                     dir_fd=parent)
        try:
            cls.check(fd, True)
            return fd
        except BaseException:
            cls.close_fd(fd)
            raise

    @classmethod
    def entries(cls, fd: int) -> set[str]:
        names = set()
        entries = os.scandir(fd)
        try:
            for entry in entries:
                if len(names) == 64:
                    raise PermissionError('fixtureBound')
                names.add(entry.name)
        finally:
            try:
                entries.close()
            except BaseException:
                session = getattr(cls.local, 'session', None)
                if session is not None:
                    session.failed_closure = True
                raise
        return names

    @staticmethod
    def pairs(pairs: list) -> dict:
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError('duplicateReceipt')
            result[key] = value
        return result

    @classmethod
    def receipt(cls, parent: int, name: str, expected: dict | None = None) -> dict:
        fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
        try:
            cls.check(fd, False)
            if os.fstat(fd).st_size > 4096:
                raise PermissionError('receiptBound')
            data = bytearray()
            while len(data) <= 4096:
                part = os.read(fd, 4097 - len(data))
                if not part:
                    break
                data.extend(part)
            if len(data) > 4096:
                raise PermissionError('receiptBound')
            value = json.loads(data.decode('utf-8'), object_pairs_hook=cls.pairs)
            if (not isinstance(value, dict) or not cls.inode(value.get('self'))
                    or value['self'] != cls.identity(fd)):
                raise PermissionError('receiptIdentity')
            if expected is not None and json.dumps(value, sort_keys=True) != json.dumps(
                    {**expected, 'self': cls.identity(fd)}, sort_keys=True):
                raise PermissionError('receiptMismatch')
            return value
        finally:
            cls.close_fd(fd)

    @classmethod
    def write_receipt(cls, parent: int, name: str, value: dict) -> None:
        fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_NONBLOCK,
                     0o600, dir_fd=parent)
        try:
            cls.check(fd, False)
            data = json.dumps({**value, 'self': cls.identity(fd)}, separators=(',', ':')).encode()
            offset = 0
            while offset < len(data):
                count = os.write(fd, data[offset:])
                if count <= 0:
                    raise OSError('receiptWrite')
                offset += count
            os.fsync(fd)
            os.fsync(parent)
        finally:
            cls.close_fd(fd)

    def lease_root(self):
        # Explicit ExitStack ownership has no generator/GC-driven descriptor closure.
        with ExitStack() as ownership:
            _, container = fixture_profile()
            with ExitStack() as stack:
                fd = os.open('/', os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_NONBLOCK)
                stack.callback(self.close_bound_fd, fd, self.identity(fd))
                # System ancestors are not private fixture directories, but must be real dirs.
                for component in container.parts[1:]:
                    fd = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW |
                                 os.O_NONBLOCK, dir_fd=fd)
                    stack.callback(self.close_bound_fd, fd, self.identity(fd))
                if os.fstat(fd).st_uid != os.getuid():
                    raise PermissionError('unsafeContainer')
                for component in ('Library', 'Application Support'):
                    try:
                        os.mkdir(component, 0o700, dir_fd=fd)
                    except FileExistsError:
                        pass
                    fd = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW |
                                 os.O_NONBLOCK, dir_fd=fd)
                    stack.callback(self.close_bound_fd, fd, self.identity(fd))
                    if os.fstat(fd).st_uid != os.getuid():
                        raise PermissionError('unsafeParent')
                created = False
                try:
                    os.mkdir(self.namespace, 0o700, dir_fd=fd)
                    created = True
                except FileExistsError:
                    pass
                root = self.open_dir(fd, self.namespace)
                stack.callback(self.close_bound_fd, root, self.identity(root))
                expected = {'version': 1, 'kind': 'root', 'directory': self.identity(root)}
                if created:
                    self.write_receipt(root, '.owner.json', expected)
                owner_receipt = self.receipt(root, '.owner.json', expected)
                owner = os.open('.owner.json', os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
                                dir_fd=root)
                ownership.callback(self.release_owner, owner, self.identity(owner))
                self.check(owner, False)
                if self.identity(owner) != owner_receipt['self']:
                    raise PermissionError('receiptIdentity')
                try:
                    fcntl.flock(owner, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    raise AttemptBusy() from None
                locked_receipt = self.receipt(root, '.owner.json', expected)
                if locked_receipt['self'] != self.identity(owner):
                    raise PermissionError('receiptIdentity')
                current = os.open('/', os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_NONBLOCK)
                stack.callback(self.close_bound_fd, current, self.identity(current))
                for component in (*container.parts[1:], 'Library', 'Application Support'):
                    current = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW |
                                      os.O_NONBLOCK, dir_fd=current)
                    stack.callback(self.close_bound_fd, current, self.identity(current))
                named_root = self.open_dir(current, self.namespace)
                stack.callback(self.close_bound_fd, named_root, self.identity(named_root))
                if self.identity(named_root) != self.identity(root):
                    raise PermissionError('rootIdentity')
                # Local lease descriptors close before the flock descriptor.
                ownership.callback(stack.pop_all().close)
                return root, owner, ownership.pop_all()

    def release_owner(self, fd, identity):
        # The flock descriptor is last, and failed local closure must retain it.
        if self.session.failed_closure:
            raise PermissionError('descriptorClosureUnknown')
        self.close_bound_fd(fd, identity)

    @staticmethod
    def params(run: str, paper: str, generation: int, correlation: str) -> dict:
        for value in (run, paper, correlation):
            safe_uuid(value)
        bounds = CONTRACT['definitions']['generation']
        if type(generation) is not int or not bounds['minimum'] <= generation <= bounds['maximum']:
            raise ValueError('generation')
        return {'runID': run, 'paperID': paper, 'generation': generation,
                'correlationID': correlation}

    @classmethod
    def inode(cls, value: object) -> bool:
        return (type(value) is list and len(value) == 2
                and all(type(item) is int and item >= 0 for item in value))

    def inspect_run(self, root: int, run: str, stack: ExitStack, bindings=None):
        name = run + '.owner.json'
        try:
            receipt = self.receipt(root, name)
        except FileNotFoundError:
            try:
                os.stat(run, dir_fd=root, follow_symlinks=False)
            except FileNotFoundError:
                if bindings is not None:
                    bindings[(run,)] = None
                    bindings[(name,)] = None
                return None, []
            raise PermissionError('unownedRun')
        if (set(receipt) != {'version', 'kind', 'runID', 'directory', 'self'}
                or type(receipt['version']) is not int or receipt['version'] != 1
                or receipt['kind'] != 'run' or receipt['runID'] != run
                or not self.inode(receipt['directory'])):
            raise PermissionError('runReceipt')
        if bindings is not None:
            bindings[(name,)] = (receipt['self'], False, receipt)
            bindings[(run,)] = None
        try:
            fd = self.open_dir(root, run)
        except FileNotFoundError:
            return None, []
        stack.callback(self.close_fd, fd)
        if self.identity(fd) != receipt['directory']:
            raise PermissionError('runIdentity')
        if bindings is not None:
            bindings[(run,)] = (self.identity(fd), True, None)
        names = self.entries(fd)
        correlations = set()
        for entry in names:
            correlation = entry[:-11] if entry.endswith('.owner.json') else entry
            safe_uuid(correlation)
            correlations.add(correlation)
        if len(correlations) > 32:
            raise PermissionError('attemptBound')
        attempts = []
        for correlation in sorted(correlations):
            value = self.receipt(fd, correlation + '.owner.json')
            if set(value) != {'version', 'kind', 'runID', 'paperID', 'generation',
                              'correlationID', 'directory', 'marker', 'self'}:
                raise PermissionError('attemptReceipt')
            self.params(value['runID'], value['paperID'], value['generation'], value['correlationID'])
            if (type(value['version']) is not int or value['version'] != 1
                    or value['kind'] != 'attempt' or value['runID'] != run
                    or value['correlationID'] != correlation
                    or not self.inode(value['directory']) or not self.inode(value['marker'])):
                raise PermissionError('attemptReceipt')
            try:
                child = self.open_dir(fd, correlation)
            except FileNotFoundError:
                child = None
            if child is not None:
                stack.callback(self.close_fd, child)
                if self.identity(child) != value['directory']:
                    raise PermissionError('attemptIdentity')
                entries = self.entries(child)
                if entries - {'marker.bin'}:
                    raise PermissionError('extraEntry')
                if 'marker.bin' in entries:
                    marker = os.open('marker.bin', os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
                                     dir_fd=child)
                    stack.callback(self.close_fd, marker)
                    self.check(marker, False)
                    if self.identity(marker) != value['marker']:
                        raise PermissionError('markerIdentity')
            if bindings is not None:
                bindings[(run, correlation + '.owner.json')] = (value['self'], False, value)
                bindings[(run, correlation)] = (self.identity(child), True, None) if child is not None else None
                if child is not None:
                    bindings[(run, correlation, 'marker.bin')] = (
                        (value['marker'], False, None) if 'marker.bin' in entries else None)
            attempts.append((correlation, value, child))
        return fd, attempts

    def validate_census(self, attempts, deadline=None):
        with self.session.state_until(deadline):
            for correlation, value, _ in attempts:
                known = self.session.records.get(correlation)
                identity = {key: value[key] for key in (
                    'runID', 'paperID', 'generation', 'correlationID')}
                if known is not None and known != ('attempt', identity):
                    raise PermissionError('registeredReceiptMismatch')

    def prepare(self, runID: str, paperID: str, generation: int, correlationID: str,
                producer: AttemptProducer | None = None) -> dict:
        identity = self.params(runID, paperID, generation, correlationID)
        producer = producer or self.session.register(identity)
        if producer.identity != identity:
            raise AttemptInvalid('producerIdentity')
        try:
            self.session.require_producer(producer)
            result = self.prepare_owned(identity, producer)
            self.checkpoint('beforeTerminal', producer)
            self.session.select(producer)
            return result
        except AttemptCancelled:
            # Purge owns cleanup after revocation: never unlink ahead of its census.
            end = time.monotonic() + 0.3
            def budget():
                if time.monotonic() >= end:
                    raise TimeoutError('cleanupDeadline')
            with self.root(False, deadline=end, admitted=True) as root, ExitStack() as stack:
                bindings = {}
                run, attempts = self.inspect_run(root, runID, stack, bindings)
                self.validate_census(attempts, end)
                with self.session.state_until(end):
                    # Cleanup chosen before revocation drains before purge's census.
                    cleanup_selected = (runID, paperID) not in self.session.revoked
                if cleanup_selected:
                    selected = [item for item in attempts if item[0] == correlationID]
                    self.remove_attempts(root, runID, run, selected, budget, bindings)
                    budget()
            raise
        finally:
            # This is the underlying function's finally, not the asyncio wrapper's.
            if not self.session.failed_closure:
                producer.closed.set()

    def prepare_owned(self, identity: dict, producer: AttemptProducer) -> dict:
        self.session.require_producer(producer)
        runID, correlationID = identity['runID'], identity['correlationID']
        with self.root(True, deadline=producer.deadline, admitted=True) as root, ExitStack() as stack:
            self.checkpoint('beforeWrite', producer)
            if producer.stop.is_set():
                raise AttemptCancelled()
            self.session.validate(self)
            run, attempts = self.inspect_run(root, runID, stack)
            self.validate_census(attempts, producer.deadline)
            if run is not None and runID not in self.session.admitted_runs:
                raise PermissionError('namedRecoveryRequired')
            if run is None:
                # An existing receipt, even for an absent run, cannot be overwritten.
                try:
                    os.stat(runID + '.owner.json', dir_fd=root, follow_symlinks=False)
                except FileNotFoundError:
                    pass
                else:
                    raise PermissionError('existingRun')
                self.session.validate(self)
                os.mkdir(runID, 0o700, dir_fd=root)
                run = self.open_dir(root, runID)
                stack.callback(self.close_fd, run)
                self.session.validate(self)
                self.write_receipt(root, runID + '.owner.json', {
                    'version': 1, 'kind': 'run', 'runID': runID, 'directory': self.identity(run)})
                self.session.admitted_runs.add(runID)
            if any(item[0] == correlationID for item in attempts):
                raise PermissionError('existingAttempt')
            if len(attempts) >= 32:
                raise AttemptBusy()
            with self.session.state_until(producer.deadline):
                self.used.add(correlationID)
            self.session.validate(self)
            os.mkdir(correlationID, 0o700, dir_fd=run)
            child = self.open_dir(run, correlationID)
            stack.callback(self.close_fd, child)
            self.session.validate(self)
            marker = os.open('marker.bin', os.O_WRONLY | os.O_CREAT | os.O_EXCL |
                             os.O_NOFOLLOW | os.O_NONBLOCK, 0o600, dir_fd=child)
            stack.callback(self.close_fd, marker)
            self.check(marker, False)
            self.session.validate(self)
            self.write_receipt(run, correlationID + '.owner.json', {
                'version': 1, 'kind': 'attempt', **identity,
                'directory': self.identity(child), 'marker': self.identity(marker)})
            os.fsync(child)
            offset = 0
            while offset < len(self.marker):
                self.session.validate(self)
                if producer.stop.is_set():
                    raise AttemptCancelled()
                count = os.write(marker, self.marker[offset:])
                if count <= 0:
                    raise OSError('markerWrite')
                offset += count
            os.fsync(marker)
            self.checkpoint('afterMarker', producer)
            if producer.stop.is_set():
                raise AttemptCancelled()
            return {'prepared': True}

    def paper_purge(self, runID: str, paperID: str, generation: int, correlationID: str,
                    stop: threading.Event | None = None, deadline: float | None = None) -> dict:
        identity = self.params(runID, paperID, generation, correlationID)
        session = self.session
        scope = (runID, paperID)
        end = min(time.monotonic() + 0.3, float('inf') if deadline is None else deadline)

        def budget():
            if stop is not None and stop.is_set():
                raise AttemptCancelled()
            if time.monotonic() >= end:
                raise TimeoutError('purgeDeadline')

        budget()
        with session.state_until(end):
            if session.closing:
                raise AttemptBusy()
            if generation < session.revoked.get(scope, 0):
                raise AttemptInvalid('staleFence')
            producers = [p for p in session.producers.values()
                         if (p.identity['runID'], p.identity['paperID']) == scope]
            registered = [value for kind, value in session.records.values()
                          if kind == 'attempt' and (value['runID'], value['paperID']) == scope]
            if any(value['generation'] > generation for value in registered):
                raise AttemptInvalid('higherGeneration')
            if scope not in session.revoked and len(session.revoked) >= 256:
                raise AttemptBusy()
            session.reserve('purge', identity)
            budget()
            session.revoked[scope] = generation
            for producer in producers:
                producer.stop.set()
        # Never wait while holding the gate needed by the real writer's finally.
        for producer in producers:
            budget()
            if not producer.closed.wait(max(0, end - time.monotonic())):
                raise TimeoutError('producerClosureUnknown')
        budget()
        with self.root(False, deadline=end) as root, ExitStack() as stack:
            budget()
            bindings = {}
            run, attempts = self.inspect_run(root, runID, stack, bindings)
            selected = [item for item in attempts if item[1]['paperID'] == paperID]
            if any(item[1]['generation'] > generation for item in selected):
                raise AttemptInvalid('higherGeneration')
            self.validate_census(attempts, end)
            # ENTIRE run has been inspected before cancellation or purge unlinks.
            with session.state_until(end):
                # Recovery may have admitted persisted identities while we waited
                # for the gate. Absence cannot erase that registered generation.
                if generation < session.revoked.get(scope, 0):
                    raise AttemptInvalid('staleFence')
                if any(kind == 'attempt' and (value['runID'], value['paperID']) == scope
                       and value['generation'] > generation
                       for kind, value in session.records.values()):
                    raise AttemptInvalid('higherGeneration')
                if any(not producer.closed.is_set()
                       and (producer.identity['runID'], producer.identity['paperID']) == scope
                       for producer in session.producers.values()):
                    raise PermissionError('producerClosureUnknown')
            session.validate(self)
            budget()
            self.remove_attempts(root, runID, run, selected, budget, bindings)
            session.validate(self)
            with ExitStack() as reopened:
                _, remaining = self.inspect_run(root, runID, reopened)
                if any(item[1]['paperID'] == paperID for item in remaining):
                    raise PermissionError('purgeIncomplete')
            budget()
            return {'absent': True, 'drained': True}

    def validate_bindings(self, root, bindings):
        """Reopen descendant names; retained FDs alone cannot authorize an unlink."""
        with ExitStack() as stack:
            directories = {(): root}
            for path, expected in sorted(bindings.items(), key=lambda item: (len(item[0]), item[0])):
                parent = directories.get(path[:-1])
                if parent is None:
                    if expected is not None:
                        raise PermissionError('missingBindingParent')
                    continue
                try:
                    info = os.stat(path[-1], dir_fd=parent, follow_symlinks=False)
                except FileNotFoundError:
                    if expected is not None:
                        raise PermissionError('missingBinding') from None
                    continue
                if expected is None or [info.st_dev, info.st_ino] != expected[0]:
                    raise PermissionError('descendantIdentity')
                identity, directory, receipt = expected
                if directory:
                    fd = self.open_dir(parent, path[-1])
                    stack.callback(self.close_fd, fd)
                    if self.identity(fd) != identity:
                        raise PermissionError('descendantIdentity')
                    directories[path] = fd
                else:
                    fd = os.open(path[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
                                 dir_fd=parent)
                    stack.callback(self.close_fd, fd)
                    self.check(fd, False)
                    if self.identity(fd) != identity:
                        raise PermissionError('descendantIdentity')
                    if receipt is not None and self.receipt(parent, path[-1]) != receipt:
                        raise PermissionError('descendantReceipt')
            for path, fd in directories.items():
                if path:
                    expected_names = {key[-1] for key, value in bindings.items()
                                      if key[:-1] == path and value is not None}
                    if self.entries(fd) != expected_names:
                        raise PermissionError('descendantEntries')

    def remove_attempts(self, root, runID, run, selected, budget=None, bindings=None):
        if bindings is None:
            raise PermissionError('missingDeletionCensus')
        def validate():
            if budget is not None:
                budget()
            self.session.validate(self)
            self.validate_bindings(root, bindings)
            if budget is not None:
                budget()
        validate()
        for correlation, _, child in selected:
            validate()
            if child is not None:
                if 'marker.bin' in self.entries(child):
                    os.unlink('marker.bin', dir_fd=child)
                    bindings[(runID, correlation, 'marker.bin')] = None
                    os.fsync(child)
                validate()
                os.rmdir(correlation, dir_fd=run)
                bindings[(runID, correlation)] = None
                os.fsync(run)
            validate()
            os.unlink(correlation + '.owner.json', dir_fd=run)
            bindings[(runID, correlation + '.owner.json')] = None
            os.fsync(run)
        if run is not None and not self.entries(run):
            validate()
            os.rmdir(runID, dir_fd=root)
            bindings[(runID,)] = None
            os.fsync(root)
            run = None
        if run is None:
            validate()
            try:
                os.unlink(runID + '.owner.json', dir_fd=root)
                bindings[(runID + '.owner.json',)] = None
                os.fsync(root)
            except FileNotFoundError:
                pass
        validate()

    def cleanup(self, runID: str, identity: dict | None = None, *, recovered=False,
                deadline=None) -> dict:
        safe_uuid(runID)
        end = min(time.monotonic() + 0.3, float('inf') if deadline is None else deadline)
        def budget():
            if time.monotonic() >= end:
                raise TimeoutError('cleanupDeadline')
        with self.root(False, deadline=end) as root, self.session.cleanup_admission(runID, end), ExitStack() as stack:
            bindings = {}
            run, attempts = self.inspect_run(root, runID, stack, bindings)
            self.validate_census(attempts, end)
            identities = [{key: value[key] for key in (
                'runID', 'paperID', 'generation', 'correlationID')}
                for _, value, _ in attempts]
            with self.session.state_until(end):
                # Fence validation, recovered admission and cleanup selection are
                # one arbitration. No filesystem work runs under this lock.
                for item in identities:
                    fence = self.session.revoked.get((runID, item['paperID']))
                    if fence is not None and item['generation'] > fence:
                        raise AttemptInvalid('higherGeneration')
                    known = self.session.records.get(item['correlationID'])
                    if known is not None and known != ('attempt', item):
                        raise PermissionError('registeredReceiptMismatch')
                if recovered:
                    new = sum(item['correlationID'] not in self.session.records for item in identities)
                    if len(self.session.records) + new > 256:
                        raise AttemptBusy()
                    for item in identities:
                        self.session.reserve('attempt', item)
                        self.session.used.add(item['correlationID'])
                selected = attempts
                if identity is not None:
                    selected = [item for item in attempts if item[0] == identity['correlationID']]
                    if selected and any(selected[0][1][key] != value for key, value in identity.items()):
                        raise PermissionError('identityMismatch')
            self.remove_attempts(root, runID, run, selected, budget, bindings)
            budget()
            return {'absent': True}

    def terminal(self, runID: str, paperID: str, generation: int,
                 correlationID: str, outcome: str) -> dict:
        if type(outcome) is not str or outcome not in CONTRACT['definitions']['attemptOutcome']['enum']:
            raise ValueError('outcome')
        identity = self.params(runID, paperID, generation, correlationID)
        end = time.monotonic() + 0.3
        with self.session.state_until(end):
            self.session.reserve('attempt', identity)
            self.session.used.add(correlationID)
        return self.cleanup(runID, identity, deadline=end)

    def recover(self, runID: str) -> dict:
        return self.cleanup(runID, recovered=True)


class Fixtures:
    def __init__(self) -> None:
        self.prepared: set[str] = set()
        self.owned: dict[str, dict[Path, tuple[int, int] | None]] = {}
        self.links: dict[str, dict[Path, str]] = {}

    @staticmethod
    def identity(path: Path) -> tuple[int, int]:
        info = path.lstat()
        return info.st_dev, info.st_ino

    def roots(self) -> tuple[Path, Path]:
        home, root = fixture_profile()
        return root, home / 'Library/Containers' / MAIN_ID / 'Data'

    def own_paths(self, run: str) -> tuple[Path, Path]:
        root, _ = self.roots()
        safe_uuid(run)
        return (root / 'Library/Application Support/PaperLensTopology' / run / 'secret.canary',
                root / 'Library/Caches/PaperLensTopology' / run / 'cache.canary')

    def prepare(self, run: str) -> dict:
        paths = self.own_paths(run)
        root, _ = self.roots()
        if run in self.prepared or any(os.path.lexists(p.parent) for p in paths):
            raise FileExistsError('existingFixture')
        created: dict[Path, tuple[int, int]] = {}
        try:
            for parent in (root / 'Library', root / 'Library/Application Support', root / 'Library/Caches'):
                if private_directory(parent, strict=False):
                    created[parent] = self.identity(parent)
            for path in paths:
                # Library and its system-managed parents already belong to this container.
                if private_directory(path.parent.parent):
                    created[path.parent.parent] = self.identity(path.parent.parent)
                path.parent.mkdir(mode=0o700)
                created[path.parent] = self.identity(path.parent)
                fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
                with os.fdopen(fd, 'wb') as output:
                    info = os.fstat(output.fileno())
                    created[path] = (info.st_dev, info.st_ino)
                    output.write(MARKER)
            links = {}
            for alias, target in self.targets(run).items():
                link = paths[0].parent / (alias + '.link')
                link.symlink_to(target)
                created[link] = self.identity(link)
                links[link] = str(target)
            self.owned[run] = {owned: created[owned] for path in paths for owned in (path.parent, path)}
            self.owned[run].update({link: created[link] for link in links})
            self.links[run] = links
            self.prepared.add(run)
            return {'prepared': True}
        except BaseException:
            for path, identity in reversed(created.items()):
                try:
                    if self.identity(path) != identity:
                        continue
                    if stat.S_ISDIR(path.lstat().st_mode):
                        path.rmdir()
                    else:
                        path.unlink()
                except OSError:
                    # Never force removal of a replaced or nonempty directory.
                    continue
            raise

    def cleanup(self, run: str) -> dict:
        paths = self.own_paths(run)
        if run not in self.prepared:
            return {'absent': not any(os.path.lexists(p.parent) for p in paths)}
        owned = self.owned[run]
        for path in paths:
            try:
                parent_info = path.parent.lstat()
                if ((parent_info.st_dev, parent_info.st_ino) != owned[path.parent]
                        or not stat.S_ISDIR(parent_info.st_mode)
                        or parent_info.st_uid != os.getuid()
                        or stat.S_IMODE(parent_info.st_mode) != 0o700):
                    raise PermissionError('fixtureReplaced')
            except FileNotFoundError:
                owned[path.parent] = None
                owned[path] = None
                continue
            # Remove only the known files created by this process; never recursively delete fixtures.
            for candidate, target in self.links[run].items():
                if candidate.parent != path.parent:
                    continue
                try:
                    if (self.identity(candidate) != owned[candidate]
                            or not candidate.is_symlink() or os.readlink(candidate) != target):
                        raise PermissionError('fixtureReplaced')
                except FileNotFoundError:
                    owned[candidate] = None
                else:
                    candidate.unlink()
                    owned[candidate] = None
            try:
                if self.identity(path) != owned[path] or path.is_symlink():
                    raise PermissionError('fixtureReplaced')
            except FileNotFoundError:
                owned[path] = None
            else:
                fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
                try:
                    info = os.fstat(fd)
                    if (not self.valid_canary(info)
                            or (info.st_dev, info.st_ino) != owned[path]
                            or os.pread(fd, len(MARKER) + 1, 0) != MARKER):
                        raise PermissionError('fixtureReplaced')
                finally:
                    os.close(fd)
                path.unlink()
                owned[path] = None
            path.parent.rmdir()
            owned[path.parent] = None
        self.prepared.remove(run)
        del self.owned[run]
        del self.links[run]
        return {'absent': not any(os.path.lexists(p.parent) for p in paths)}

    def targets(self, run: str) -> dict[str, Path]:
        root, main = self.roots()
        return {
            'M': main / 'Library/Application Support/PaperLensTopology' / run / 'db.canary',
            'E': root.parents[3] / 'Library/Application Support/PaperLensTopologyFixtureHost' / run / 'external.canary',
            'G': root.parents[3] / 'Library/Group Containers' / GROUP_ID / 'PaperLensTopology' / run / 'group.canary',
        }

    @staticmethod
    def observation(outcome: str = 'inconclusive', reason: str = 'controlFailed', *,
                    observed: bool = False, result: int = 0, error: int = 0,
                    began: int = 0, ended: int = 0) -> dict:
        return {'outcome': outcome, 'reason': reason, 'syscallObserved': observed,
                'syscallResult': result, 'errno': error, 'beganAtNs': began, 'endedAtNs': ended}

    @classmethod
    def denial(cls, error: OSError, *, began: int, ended: int) -> dict:
        # This is only a syscall observation, never a sandbox PASS verdict.
        code = error.errno or 0
        denied = code in (errno.EACCES, errno.EPERM)
        reason = 'permissionDenied' if denied else 'missingFixture' if code == errno.ENOENT else 'unexpectedErrno'
        return cls.observation('denied' if denied else 'inconclusive', reason,
                               observed=True, result=-1, error=code, began=began, ended=ended)

    def probe(self, run: str, case: str) -> dict:
        if run not in self.prepared:
            return self.observation(reason='missingFixture')
        own, cache = self.own_paths(run)
        if case == 'inboundListen':
            try:
                with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
                    sock.settimeout(2)
                    try:
                        sock.bind(('127.0.0.1', 18766))
                    except OSError:
                        # The contracted operation is listen, not the preceding bind.
                        return self.observation()
                    began = time.monotonic_ns()
                    try:
                        sock.listen(1)
                    except OSError as error:
                        ended = time.monotonic_ns()
                        return self.denial(error, began=began, ended=ended)
                    ended = time.monotonic_ns()
                    return self.observation('allowed', 'none', observed=True,
                                            began=began, ended=ended)
            except OSError:
                return self.observation()
        if case == 'ownZoneReadWrite':
            for path in (own, cache):
                for write in (False, True):
                    if self.access(path, write=write)['outcome'] != 'allowed':
                        return self.observation()
            return self.observation('allowed', 'none')
        key = 'M' if case.startswith('main') else 'E' if case.startswith('external') else 'G'
        path = self.targets(run)[key]
        follow = 'Symlink' in case
        if follow:
            link = own.parent / (key + '.link')
            try:
                if (self.identity(own.parent) != self.owned[run][own.parent]
                        or not link.is_symlink() or self.identity(link) != self.owned[run][link]
                        or os.readlink(link) != self.links[run][link]):
                    return self.observation()
                # Traversal of the resolved target must succeed before a leaf
                # attempt through the retained link can be target evidence.
                target_parent = self.parent_descriptor(path.parent)
                os.close(target_parent)
            except OSError:
                return self.observation()
            path = link
        return self.access(path, write=case.endswith('Write'), follow=follow)

    @staticmethod
    def parent_descriptor(path: Path) -> int:
        # The pinned Darwin runtime exposes O_SEARCH. Traversal must not
        # request directory-data reads before the actual fixed leaf syscall.
        flags = os.O_SEARCH | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_NONBLOCK
        fd = os.open(path.anchor, flags)
        try:
            for component in path.parts[1:]:
                child = os.open(component, flags, dir_fd=fd)
                os.close(fd)
                fd = child
            return fd
        except BaseException:
            os.close(fd)
            raise

    @staticmethod
    def valid_canary(info: os.stat_result) -> bool:
        return (stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid()
                and stat.S_IMODE(info.st_mode) == 0o600 and info.st_nlink == 1
                and info.st_size == len(MARKER))

    @classmethod
    def access(cls, path: Path, *, write: bool, follow: bool = False) -> dict:
        try:
            parent = cls.parent_descriptor(path.parent)
        except OSError:
            return cls.observation()
        flags = (os.O_WRONLY if write else os.O_RDONLY) | os.O_NONBLOCK
        if not follow:
            flags |= os.O_NOFOLLOW
        fd = -1
        try:
            began = time.monotonic_ns()
            try:
                fd = os.open(path.name, flags, dir_fd=parent)
            except OSError as error:
                ended = time.monotonic_ns()
                return cls.denial(error, began=began, ended=ended)
            ended = time.monotonic_ns()
            info = os.fstat(fd)
            if not cls.valid_canary(info):
                return cls.observation()
            if write:
                # A read/control denial must not be reported as write denial.
                control = os.open(path.name, (flags & ~os.O_WRONLY) | os.O_RDONLY,
                                  dir_fd=parent)
                try:
                    other = os.fstat(control)
                    if (not cls.valid_canary(other)
                            or (info.st_dev, info.st_ino) != (other.st_dev, other.st_ino)
                            or os.pread(control, len(MARKER) + 1, 0) != MARKER):
                        return cls.observation()
                finally:
                    os.close(control)
            began = time.monotonic_ns()
            try:
                result = os.pwrite(fd, MARKER, 0) if write else os.pread(fd, len(MARKER) + 1, 0)
            except OSError as error:
                ended = time.monotonic_ns()
                return cls.denial(error, began=began, ended=ended)
            ended = time.monotonic_ns()
            if (write and result != len(MARKER)) or (not write and result != MARKER):
                return cls.observation()
            return cls.observation('allowed', 'none', observed=True,
                                   result=result if write else len(result), began=began, ended=ended)
        except OSError:
            return cls.observation()
        finally:
            if fd >= 0:
                os.close(fd)
            os.close(parent)


@dataclass
class RuntimeWorker:
    process: subprocess.Popen | None = None
    stop_lock: threading.Lock = field(default_factory=threading.Lock)
    stopper: threading.Thread | None = None
    reaped: bool = False


class RuntimeProbe:
    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.active: dict[str, RuntimeWorker] = {}
        self.cancelled: set[str] = set()

    def cancel(self, identifier: str) -> None:
        with self.lock:
            self.cancelled.add(identifier)
            worker = self.active.get(identifier)
            if worker is not None and worker.process is not None and worker.stopper is None:
                worker.stopper = threading.Thread(target=self.stop, args=(worker,), daemon=True)
                worker.stopper.start()

    @staticmethod
    def stop(worker: RuntimeWorker) -> None:
        # This path does not depend on the SDK's initialize waiter or client.close().
        with worker.stop_lock:
            if worker.reaped or worker.process is None:
                return
            process = worker.process
            try:
                if process.poll() is None:
                    try:
                        process.terminate()
                    except ProcessLookupError:
                        pass
                try:
                    process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    try:
                        process.kill()
                    except ProcessLookupError:
                        pass
                    process.wait(timeout=2)
                worker.reaped = True
            except (OSError, subprocess.TimeoutExpired):
                # Retain ownership and refuse another SDK worker if reaping failed.
                return

    def run(self, identifier: str) -> dict:
        worker = RuntimeWorker()
        with self.lock:
            if self.active:
                raise RuntimeError('runtimeBusy')
            self.active[identifier] = worker
        try:
            return self.run_owned(identifier, worker)
        finally:
            with self.lock:
                if worker.process is None or worker.reaped:
                    self.active.pop(identifier, None)
                self.cancelled.discard(identifier)

    def run_owned(self, identifier: str, worker: RuntimeWorker) -> dict:
        _, container = fixture_profile()
        machine = platform.machine()
        if machine not in ('arm64', 'x86_64'):
            raise RuntimeError('unsupportedCPU')
        resources = Path(__file__).resolve().parent
        executable = resources.parent / 'MacOS/codex'
        if not executable.is_file():
            raise RuntimeError('runtimeUnavailable')
        home = Path(os.environ['CODEX_HOME'])
        runtime_root = container / 'Library/Application Support/PaperLensTopologyRuntime'
        if (not home.is_absolute() or home.name != 'codex'
                or home.parent.parent != runtime_root):
            raise PermissionError('containerMismatch')
        safe_uuid(home.parent.name)
        if home.resolve() != home:
            raise PermissionError('containerMismatch')
        for directory in (runtime_root, home.parent):
            info = directory.lstat()
            if (not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid()
                    or stat.S_IMODE(info.st_mode) != 0o700):
                raise PermissionError('unsafeDirectory')
        sdk = importlib.import_module('openai_codex')
        sdk_path = Path(sdk.__file__).resolve()
        if resources.parent not in sdk_path.parents or sdk.__version__ != '0.160.0':
            raise RuntimeError('sdkIdentityMismatch')
        from openai_codex.client import CodexClient, CodexConfig
        private_directory(home)
        attempt = home / ('topology-' + safe_uuid(identifier))
        attempt.mkdir(mode=0o700)  # Unique; never reuse an existing auth/config home.
        client = None
        unexpected_request = threading.Event()
        try:
            def deny_approval(method: str, params: object) -> dict:
                if method in ('item/commandExecution/requestApproval', 'item/fileChange/requestApproval'):
                    return {'decision': 'decline'}
                unexpected_request.set()
                raise RuntimeError('unexpectedServerRequest')
            client = CodexClient(CodexConfig(codex_bin=str(executable), cwd=str(attempt),
                                             env={'CODEX_HOME': str(attempt)}), approval_handler=deny_approval)
            with self.lock:
                if identifier in self.cancelled:
                    raise RuntimeError('cancelled')
                try:
                    client.start()
                finally:
                    # Pinned SDK has no public process handle; retain even a partially started child.
                    worker.process = client._proc
            initialized = client.initialize()
            if initialized is None:
                raise RuntimeError('initializeFailed')
            return {'sdkImported': True, 'cliInitialized': True, 'architecture': machine}
        finally:
            try:
                self.stop(worker)
                if worker.process is not None and not worker.reaped:
                    raise RuntimeError('runtimeShutdownFailed')
                if client is not None:
                    client.close()
            finally:
                if worker.process is None or worker.reaped:
                    shutil.rmtree(attempt)
            if unexpected_request.is_set():
                raise RuntimeError('unexpectedServerRequest')


@dataclass
class Pending:
    method: str
    task: asyncio.Task | None = None
    timer: asyncio.TimerHandle | None = None
    producer: AttemptProducer | None = None
    worker: asyncio.Task | None = None
    stop: threading.Event = field(default_factory=threading.Event)


class Server:
    def __init__(self, runtime: RuntimeProbe | None = None, fixtures: Fixtures | None = None,
                 session: AttemptSession | None = None) -> None:
        self.runtime = runtime or RuntimeProbe()
        self.fixtures = fixtures or Fixtures()
        self.attempts = AttemptFixtures(session)
        self.seen: set[str] = set()
        self.pending: dict[str, Pending] = {}
        self.runtime_workers: dict[str, asyncio.Task] = {}
        self.inflight: dict[str, str] = {}
        self.outgoing: asyncio.Queue[tuple[str, bytes]] = asyncio.Queue(maxsize=LIMITS['maxQueuedFrames'])
        self.ready = False
        self.closed = False
        self.fatal = asyncio.Event()
        self.started = 0.0

    def emit(self, value: dict, method: str) -> None:
        if self.closed:
            return
        validate_terminal(value, method)
        try:
            self.outgoing.put_nowait((value['id'], encode_frame(value)))
        except asyncio.QueueFull:
            self.closed = True
            self.fatal.set()
            raise ProtocolError('protocolViolation')

    def error(self, identifier: str, code: str, method: str) -> None:
        self.emit({'kind': 'error', 'id': identifier, 'code': code}, method)

    def delivered(self, identifier: str) -> None:
        # A queued terminal still occupies its request lane until physically written.
        self.inflight.pop(identifier, None)

    def finish(self, identifier: str, *, result: dict | None = None, code: str | None = None,
               cancel: bool = False) -> bool:
        record = self.pending.pop(identifier, None)
        if record is None:
            return False
        if record.timer is not None:
            record.timer.cancel()
        emitted = False
        try:
            if code is not None:
                self.error(identifier, code, record.method)
            else:
                self.emit({'kind': 'result', 'id': identifier, 'result': result}, record.method)
            emitted = True
        finally:
            if cancel or not emitted:
                try:
                    record.stop.set()
                    if record.producer is not None:
                        record.producer.stop.set()
                    if record.method == 'topology.runtime':
                        self.runtime.cancel(identifier)
                finally:
                    if record.task is not None:
                        record.task.cancel()
        return True

    def terminate(self, identifier: str, code: str) -> bool:
        # The terminal winner is selected synchronously on this event loop, before task cancellation.
        return self.finish(identifier, code=code, cancel=True)

    def accept(self, request: dict, *, received: float | None = None) -> None:
        if self.closed:
            raise ProtocolError('protocolViolation')
        if received is None:
            received = asyncio.get_running_loop().time()
        validation_error = None
        try:
            validate_request(request)
        except ProtocolError as error:
            if error.code not in ('invalidParams', 'unknownMethod'):
                raise
            validation_error = error.code
        identifier, method, params = request['id'], request['method'], request['params']
        if identifier in self.seen or len(self.seen) >= LIMITS['maxRequestsPerConnection']:
            raise ProtocolError('protocolViolation')
        self.seen.add(identifier)
        cancel_count = sum(value == 'cancel' for value in self.inflight.values())
        ordinary_count = len(self.inflight) - cancel_count
        if ((method == 'cancel' and cancel_count >= LIMITS['maxCancelRequests']) or
                (method != 'cancel' and ordinary_count >= LIMITS['maxOrdinaryRequests'])):
            self.error(identifier, 'busy', method)
            return
        self.inflight[identifier] = method
        if validation_error is not None:
            self.error(identifier, validation_error, method)
            return
        deadline = received + request['timeoutMs'] / 1000
        if asyncio.get_running_loop().time() >= deadline:
            self.error(identifier, 'timeout', method)
            return
        if method == 'hello':
            if self.ready:
                self.error(identifier, 'invalidParams', method)
            elif params['major'] != 1 or params['minor'] != 1:
                self.error(identifier, 'versionMismatch', method)
                self.closed = True
            else:
                self.ready = True
                self.emit({'kind': 'result', 'id': identifier, 'result': {
                    'major': 1, 'minor': 1, 'capabilities': ['topology-v1']}}, method)
            return
        if not self.ready:
            self.error(identifier, 'handshakeRequired', method)
            return
        if method == 'cancel':
            target = params['targetID']
            accepted = self.terminate(target, 'cancelled')
            self.emit({'kind': 'result', 'id': identifier, 'result': {'accepted': accepted}}, method)
            return
        if method == 'topology.runtime' and (
                self.runtime_workers or any(p.method == method for p in self.pending.values())):
            self.error(identifier, 'busy', method)
            return
        record = Pending(method)
        if method == 'topology.attemptPrepare':
            try:
                identity = self.attempts.params(params['runID'], params['paperID'],
                                                params['generation'], params['correlationID'])
                record.producer = self.attempts.session.register(
                    identity, time.monotonic() + max(0, deadline - asyncio.get_running_loop().time()))
            except TimeoutError:
                self.error(identifier, 'timeout', method)
                return
            except AttemptBusy:
                self.error(identifier, 'busy', method)
                return
            except AttemptCancelled:
                self.error(identifier, 'cancelled', method)
                return
            except AttemptInvalid:
                self.error(identifier, 'invalidParams', method)
                return
            record.worker = asyncio.create_task(asyncio.to_thread(
                self.attempts.prepare, **params, producer=record.producer))
            record.worker.add_done_callback(
                lambda worker: None if worker.cancelled() else worker.exception())
        self.pending[identifier] = record
        record.timer = asyncio.get_running_loop().call_at(deadline, self.terminate, identifier, 'timeout')
        task = asyncio.create_task(self.execute(request, deadline))
        record.task = task
        def completed(finished: asyncio.Task) -> None:
            if finished.cancelled():
                self.terminate(identifier, 'cancelled')
            elif not finished.cancelled() and finished.exception() is not None:
                self.closed = True
                self.fatal.set()
        task.add_done_callback(completed)

    async def execute(self, request: dict, deadline: float) -> None:
        identifier, method, params = request['id'], request['method'], request['params']
        record = self.pending.get(identifier)
        try:
            if asyncio.get_running_loop().time() >= deadline:
                self.terminate(identifier, 'timeout')
                return
            if method == 'topology.wait':
                await asyncio.sleep(params['durationMs'] / 1000)
                result = {'elapsed': True}
            elif method == 'topology.runtime':
                worker = asyncio.create_task(asyncio.to_thread(self.runtime.run, identifier))
                self.runtime_workers[identifier] = worker
                def worker_finished(finished: asyncio.Task) -> None:
                    self.runtime_workers.pop(identifier, None)
                    if not finished.cancelled():
                        finished.exception()
                worker.add_done_callback(worker_finished)
                result = await asyncio.shield(worker)
            elif method == 'topology.prepare':
                result = self.fixtures.prepare(params['runID'])
            elif method == 'topology.identity':
                if params['runID'] not in self.fixtures.prepared:
                    raise PermissionError('missingFixture')
                result = {'bridgePID': os.getppid(), 'pythonPID': os.getpid()}
            elif method == 'topology.cleanup':
                result = self.fixtures.cleanup(params['runID'])
            elif method == 'topology.attemptPrepare':
                result = await asyncio.shield(record.worker)
            elif method == 'topology.attemptTerminal':
                result = await asyncio.to_thread(self.attempts.terminal, **params)
            elif method == 'topology.attemptRecover':
                result = await asyncio.to_thread(self.attempts.recover, **params)
            elif method == 'topology.paperPurge':
                worker = asyncio.create_task(asyncio.to_thread(
                    self.attempts.paper_purge, **params, stop=record.stop,
                    deadline=time.monotonic() + max(
                        0, deadline - asyncio.get_running_loop().time())))
                worker.add_done_callback(
                    lambda finished: None if finished.cancelled() else finished.exception())
                result = await asyncio.shield(worker)
            else:
                result = self.fixtures.probe(params['runID'], params['caseID'])
            if asyncio.get_running_loop().time() >= deadline:
                self.terminate(identifier, 'timeout')
            else:
                self.finish(identifier, result=result)
        except asyncio.CancelledError:
            if record is not None:
                record.stop.set()
                if record.producer is not None:
                    record.producer.stop.set()
            self.terminate(identifier, 'cancelled')
        except (AttemptCancelled, AttemptInvalid, TimeoutError) as error:
            code = ('timeout' if isinstance(error, TimeoutError) else
                    'cancelled' if isinstance(error, AttemptCancelled) else 'invalidParams')
            if asyncio.get_running_loop().time() >= deadline:
                code = 'timeout'
            self.terminate(identifier, code)
        except AttemptBusy:
            if asyncio.get_running_loop().time() >= deadline:
                self.terminate(identifier, 'timeout')
            else:
                self.finish(identifier, code='busy')
        except Exception:
            if asyncio.get_running_loop().time() >= deadline:
                self.terminate(identifier, 'timeout')
            else:
                self.finish(identifier, code='unavailable')

    async def serve(self) -> None:
        decoder = FrameDecoder()
        self.started = asyncio.get_running_loop().time()
        loop = asyncio.get_running_loop()
        os.set_blocking(0, False)
        os.set_blocking(1, False)
        async def read_chunk() -> bytes:
            future = loop.create_future()
            def readable() -> None:
                if future.done():
                    return
                try:
                    data = os.read(0, 4096)
                except BlockingIOError:
                    return
                except OSError as error:
                    future.set_exception(error)
                else:
                    future.set_result(data)
            loop.add_reader(0, readable)
            try:
                return await future
            finally:
                loop.remove_reader(0)
        async def writable() -> None:
            future = loop.create_future()
            def ready() -> None:
                if not future.done():
                    future.set_result(None)
            loop.add_writer(1, ready)
            try:
                await future
            finally:
                loop.remove_writer(1)
        async def write_frames() -> None:
            while True:
                identifier, frame = await self.outgoing.get()
                try:
                    offset = 0
                    while offset < len(frame):
                        try:
                            count = os.write(1, frame[offset:])
                        except BlockingIOError:
                            await writable()
                            continue
                        if count <= 0:
                            raise BrokenPipeError
                        offset += count
                    self.delivered(identifier)
                finally:
                    self.outgoing.task_done()
        writer = asyncio.create_task(write_frames())
        fatal = asyncio.create_task(self.fatal.wait())
        try:
            while not self.closed:
                if writer.done():
                    writer.result()
                timeout = None if self.ready else max(
                    0, LIMITS['handshakeTimeoutMs'] / 1000 -
                    (asyncio.get_running_loop().time() - self.started),
                )
                reader = asyncio.create_task(read_chunk())
                try:
                    finished, _ = await asyncio.wait(
                        (reader, writer, fatal), timeout=timeout,
                        return_when=asyncio.FIRST_COMPLETED,
                    )
                    if writer in finished:
                        writer.result()
                        raise BrokenPipeError
                    if fatal in finished:
                        raise ProtocolError('protocolViolation')
                    if reader not in finished:
                        raise TimeoutError
                    data = reader.result()
                finally:
                    reader.cancel()
                    await asyncio.gather(reader, return_exceptions=True)
                if not data:
                    decoder.finish()
                    break
                received = loop.time()
                for frame in decoder.feed(data):
                    self.accept(decode_frame(frame), received=received)
                    if self.closed:
                        break
                if len(self.seen) == LIMITS['maxRequestsPerConnection']:
                    await asyncio.gather(*(p.task for p in self.pending.values() if p.task), return_exceptions=True)
                    self.closed = True
            await asyncio.wait_for(self.outgoing.join(), 2)
        finally:
            self.closed = True
            remaining = list(self.pending.items())
            for identifier, _ in remaining:
                self.terminate(identifier, 'cancelled')
            for identifier in self.runtime_workers:
                self.runtime.cancel(identifier)
            await asyncio.gather(*(p.task for _, p in remaining if p.task), return_exceptions=True)
            try:
                await asyncio.to_thread(self.attempts.close)
            finally:
                writer.cancel()
                fatal.cancel()
                await asyncio.gather(writer, fatal, return_exceptions=True)


def main() -> int:
    try:
        os.umask(0o077)
        if os.getpgrp() != os.getpid():
            os.setpgid(0, 0)
        asyncio.run(Server().serve())
        return 0
    except BaseException:
        # No raw SDK exception, stream, environment or path crosses this process boundary.
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
