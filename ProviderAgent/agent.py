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


class AttemptFixtures:
    """Private synthetic crash-recovery substrate; not an SDK outcome ledger."""
    namespace = 'PaperLensAttemptFixturesV1'
    marker = b'PaperLens synthetic attempt fixture\n'
    lock = threading.Lock()

    def __init__(self) -> None:
        self.used: set[str] = set()

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
            os.close(fd)
            raise

    @staticmethod
    def entries(fd: int) -> set[str]:
        names = set()
        with os.scandir(fd) as entries:
            for entry in entries:
                if len(names) == 64:
                    raise PermissionError('fixtureBound')
                names.add(entry.name)
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
            os.close(fd)

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
            os.close(fd)

    @contextmanager
    def root(self, create: bool):
        if not self.lock.acquire(blocking=False):
            raise AttemptBusy()
        try:
            _, container = fixture_profile()
            with ExitStack() as stack:
                fd = os.open('/', os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_NONBLOCK)
                stack.callback(os.close, fd)
                # System ancestors are not private fixture directories, but must be real dirs.
                for component in container.parts[1:]:
                    fd = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW |
                                 os.O_NONBLOCK, dir_fd=fd)
                    stack.callback(os.close, fd)
                if os.fstat(fd).st_uid != os.getuid():
                    raise PermissionError('unsafeContainer')
                for component in ('Library', 'Application Support'):
                    if create:
                        try:
                            os.mkdir(component, 0o700, dir_fd=fd)
                        except FileExistsError:
                            pass
                    try:
                        fd = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW |
                                     os.O_NONBLOCK, dir_fd=fd)
                    except FileNotFoundError:
                        if create:
                            raise
                        yield None
                        return
                    stack.callback(os.close, fd)
                    if os.fstat(fd).st_uid != os.getuid():
                        raise PermissionError('unsafeParent')
                created = False
                if create:
                    try:
                        os.mkdir(self.namespace, 0o700, dir_fd=fd)
                        created = True
                    except FileExistsError:
                        pass
                try:
                    root = self.open_dir(fd, self.namespace)
                except FileNotFoundError:
                    if create:
                        raise
                    yield None
                    return
                stack.callback(os.close, root)
                expected = {'version': 1, 'kind': 'root', 'directory': self.identity(root)}
                if created:
                    self.write_receipt(root, '.owner.json', expected)
                owner_receipt = self.receipt(root, '.owner.json', expected)
                owner = os.open('.owner.json', os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
                                dir_fd=root)
                stack.callback(os.close, owner)
                self.check(owner, False)
                if self.identity(owner) != owner_receipt['self']:
                    raise PermissionError('receiptIdentity')
                try:
                    fcntl.flock(owner, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    raise AttemptBusy() from None
                self.receipt(root, '.owner.json', expected)
                yield root
        finally:
            self.lock.release()

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

    def inspect_run(self, root: int, run: str, stack: ExitStack):
        name = run + '.owner.json'
        try:
            receipt = self.receipt(root, name)
        except FileNotFoundError:
            try:
                os.stat(run, dir_fd=root, follow_symlinks=False)
            except FileNotFoundError:
                return None, []
            raise PermissionError('unownedRun')
        if (set(receipt) != {'version', 'kind', 'runID', 'directory', 'self'}
                or type(receipt['version']) is not int or receipt['version'] != 1
                or receipt['kind'] != 'run' or receipt['runID'] != run
                or not self.inode(receipt['directory'])):
            raise PermissionError('runReceipt')
        try:
            fd = self.open_dir(root, run)
        except FileNotFoundError:
            return None, []
        stack.callback(os.close, fd)
        if self.identity(fd) != receipt['directory']:
            raise PermissionError('runIdentity')
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
                stack.callback(os.close, child)
                if self.identity(child) != value['directory']:
                    raise PermissionError('attemptIdentity')
                entries = self.entries(child)
                if entries - {'marker.bin'}:
                    raise PermissionError('extraEntry')
                if 'marker.bin' in entries:
                    marker = os.open('marker.bin', os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
                                     dir_fd=child)
                    stack.callback(os.close, marker)
                    self.check(marker, False)
                    if self.identity(marker) != value['marker']:
                        raise PermissionError('markerIdentity')
            attempts.append((correlation, value, child))
        return fd, attempts

    def prepare(self, runID: str, paperID: str, generation: int, correlationID: str) -> dict:
        identity = self.params(runID, paperID, generation, correlationID)
        with self.root(True) as root, ExitStack() as stack:
            if correlationID in self.used or len(self.used) >= 256:
                raise PermissionError('correlationBound')
            run, attempts = self.inspect_run(root, runID, stack)
            if run is None:
                # An existing receipt, even for an absent run, cannot be overwritten.
                try:
                    os.stat(runID + '.owner.json', dir_fd=root, follow_symlinks=False)
                except FileNotFoundError:
                    pass
                else:
                    raise PermissionError('existingRun')
                os.mkdir(runID, 0o700, dir_fd=root)
                run = self.open_dir(root, runID)
                stack.callback(os.close, run)
                self.write_receipt(root, runID + '.owner.json', {
                    'version': 1, 'kind': 'run', 'runID': runID, 'directory': self.identity(run)})
            if len(attempts) >= 32 or any(item[0] == correlationID for item in attempts):
                raise PermissionError('existingAttempt')
            self.used.add(correlationID)
            os.mkdir(correlationID, 0o700, dir_fd=run)
            child = self.open_dir(run, correlationID)
            stack.callback(os.close, child)
            marker = os.open('marker.bin', os.O_WRONLY | os.O_CREAT | os.O_EXCL |
                             os.O_NOFOLLOW | os.O_NONBLOCK, 0o600, dir_fd=child)
            stack.callback(os.close, marker)
            self.check(marker, False)
            self.write_receipt(run, correlationID + '.owner.json', {
                'version': 1, 'kind': 'attempt', **identity,
                'directory': self.identity(child), 'marker': self.identity(marker)})
            os.fsync(child)
            offset = 0
            while offset < len(self.marker):
                count = os.write(marker, self.marker[offset:])
                if count <= 0:
                    raise OSError('markerWrite')
                offset += count
            os.fsync(marker)
            return {'prepared': True}

    def cleanup(self, runID: str, identity: dict | None = None) -> dict:
        safe_uuid(runID)
        with self.root(False) as root, ExitStack() as stack:
            if root is None:
                return {'absent': True}
            run, attempts = self.inspect_run(root, runID, stack)
            selected = attempts
            if identity is not None:
                selected = [item for item in attempts if item[0] == identity['correlationID']]
                if selected and any(selected[0][1][key] != value for key, value in identity.items()):
                    raise PermissionError('identityMismatch')
            for correlation, _, child in selected:
                if child is not None:
                    if 'marker.bin' in self.entries(child):
                        os.unlink('marker.bin', dir_fd=child)
                        os.fsync(child)
                    os.rmdir(correlation, dir_fd=run)
                    os.fsync(run)
                os.unlink(correlation + '.owner.json', dir_fd=run)
                os.fsync(run)
            if run is not None and not self.entries(run):
                os.rmdir(runID, dir_fd=root)
                os.fsync(root)
                run = None
            if run is None:
                try:
                    os.unlink(runID + '.owner.json', dir_fd=root)
                    os.fsync(root)
                except FileNotFoundError:
                    pass
            return {'absent': True}

    def terminal(self, runID: str, paperID: str, generation: int,
                 correlationID: str, outcome: str) -> dict:
        if type(outcome) is not str or outcome not in CONTRACT['definitions']['attemptOutcome']['enum']:
            raise ValueError('outcome')
        return self.cleanup(runID, self.params(runID, paperID, generation, correlationID))

    def recover(self, runID: str) -> dict:
        return self.cleanup(runID)


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


class Server:
    def __init__(self, runtime: RuntimeProbe | None = None, fixtures: Fixtures | None = None) -> None:
        self.runtime = runtime or RuntimeProbe()
        self.fixtures = fixtures or Fixtures()
        self.attempts = AttemptFixtures()
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
                result = self.attempts.prepare(**params)
            elif method == 'topology.attemptTerminal':
                result = self.attempts.terminal(**params)
            elif method == 'topology.attemptRecover':
                result = self.attempts.recover(**params)
            else:
                result = self.fixtures.probe(params['runID'], params['caseID'])
            if asyncio.get_running_loop().time() >= deadline:
                self.terminate(identifier, 'timeout')
            else:
                self.finish(identifier, result=result)
        except asyncio.CancelledError:
            self.terminate(identifier, 'cancelled')
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
