"""Story 1.1 only: bounded ProviderRPC and a real, unauthenticated SDK probe."""
from __future__ import annotations

import asyncio
from dataclasses import dataclass, field
import errno
import importlib
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
import uuid

# The signed resources directory is the only additional import root.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from provider_rpc import (  # noqa: E402
    CONTRACT, FrameDecoder, ProtocolError, encode_frame, decode_frame,
    validate_request, validate_terminal,
)

PROFILE = Path('/Users/paperlens-topology')
MAIN_ID = 'io.github.jinzer0.PaperLens'
AGENT_ID = MAIN_ID + '.ProviderAgent'
GROUP_ID = '397452Z366.io.github.jinzer0.PaperLens.TopologyFixture'
MARKER = b'PaperLens topology canary\n'
LIMITS = CONTRACT['limits']


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


class Fixtures:
    def __init__(self) -> None:
        self.prepared: set[str] = set()
        self.owned: dict[str, dict[Path, tuple[int, int] | None]] = {}

    @staticmethod
    def identity(path: Path) -> tuple[int, int]:
        info = path.lstat()
        return info.st_dev, info.st_ino

    def roots(self) -> tuple[Path, Path]:
        if Path(pwd.getpwuid(os.getuid()).pw_dir) != PROFILE:
            raise PermissionError('fixtureProfileUnavailable')
        root = PROFILE / 'Library/Containers' / AGENT_ID / 'Data'
        if Path.home() != root or Path(os.environ.get('HOME', '')) != root:
            raise PermissionError('containerMismatch')
        return root, PROFILE / 'Library/Containers' / MAIN_ID / 'Data'

    def own_paths(self, run: str) -> tuple[Path, Path]:
        root, _ = self.roots()
        safe_uuid(run)
        return (root / 'Library/Application Support/PaperLensTopology' / run / 'secret.canary',
                root / 'Library/Caches/PaperLensTopology' / run / 'cache.canary')

    def prepare(self, run: str) -> dict:
        paths = self.own_paths(run)
        root, _ = self.roots()
        if run in self.prepared or any(p.parent.exists() for p in paths):
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
            self.owned[run] = {owned: created[owned] for path in paths for owned in (path.parent, path)}
            self.prepared.add(run)
            return {'prepared': True}
        except BaseException:
            for path, identity in reversed(created.items()):
                try:
                    if self.identity(path) != identity:
                        continue
                    if path.is_dir():
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
            return {'absent': not any(p.parent.exists() for p in paths)}
        owned = self.owned[run]
        for path in paths:
            try:
                if self.identity(path.parent) != owned[path.parent] or path.parent.is_symlink():
                    raise PermissionError('fixtureReplaced')
            except FileNotFoundError:
                owned[path.parent] = None
                owned[path] = None
                continue
            # Remove only the known files created by this process; never recursively delete fixtures.
            for link in ('main.link', 'external.link', 'group.link'):
                candidate = path.parent / link
                if candidate.is_symlink():
                    candidate.unlink()
            try:
                if self.identity(path) != owned[path] or path.is_symlink():
                    raise PermissionError('fixtureReplaced')
            except FileNotFoundError:
                owned[path] = None
            else:
                path.unlink()
                owned[path] = None
            path.parent.rmdir()
            owned[path.parent] = None
        self.prepared.remove(run)
        del self.owned[run]
        return {'absent': not any(p.parent.exists() for p in paths)}

    def probe(self, run: str, case: str) -> dict:
        root, main = self.roots()
        own, cache = self.own_paths(run)
        if run not in self.prepared:
            return {'outcome': 'inconclusive', 'reason': 'missingFixture'}
        if case == 'inboundListen':
            try:
                with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
                    sock.settimeout(2)
                    sock.bind(('127.0.0.1', 18766))
                    sock.listen(1)
                return {'outcome': 'allowed', 'reason': 'none'}
            except OSError as error:
                return self.denial(error)
        if case == 'ownZoneReadWrite':
            try:
                for path in (own, cache):
                    self.access(path, write=False)
                    self.access(path, write=True)
                return {'outcome': 'allowed', 'reason': 'none'}
            except OSError:
                return {'outcome': 'inconclusive', 'reason': 'controlFailed'}
        targets = {
            'main': main / 'Library/Application Support/PaperLensTopology' / run / 'db.canary',
            'external': PROFILE / 'Library/Application Support/PaperLensTopologyFixtureHost' / run / 'external.canary',
            'group': PROFILE / 'Library/Group Containers' / GROUP_ID / 'PaperLensTopology' / run / 'group.canary',
        }
        key = 'main' if case.startswith('main') else 'external' if case.startswith('external') else 'group'
        path = targets[key]
        follow = 'Symlink' in case
        if follow:
            link = own.parent / (key + '.link')
            try:
                link.symlink_to(path)
            except FileExistsError:
                if not link.is_symlink() or os.readlink(link) != str(path):
                    raise PermissionError('fixtureReplaced')
            path = link
        try:
            self.access(path, write=case.endswith('Write'), follow=follow)
            return {'outcome': 'allowed', 'reason': 'none'}
        except OSError as error:
            return self.denial(error)

    @staticmethod
    def access(path: Path, *, write: bool, follow: bool = False) -> None:
        flags = os.O_RDWR if write else os.O_RDONLY
        flags |= os.O_NONBLOCK
        if not follow:
            flags |= os.O_NOFOLLOW
        fd = os.open(path, flags)
        try:
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
                raise OSError(errno.EINVAL, 'notFixture')
            if os.pread(fd, len(MARKER) + 1, 0) != MARKER:
                raise OSError(errno.EINVAL, 'controlFailed')
            if write:
                os.pwrite(fd, MARKER[:1], 0)
        finally:
            os.close(fd)

    @staticmethod
    def denial(error: OSError) -> dict:
        # The harness must correlate an OS sandbox denial and positive controls.
        if error.errno in (errno.EACCES, errno.EPERM):
            return {'outcome': 'denied', 'reason': 'permissionDenied'}
        return {'outcome': 'inconclusive', 'reason': 'missingFixture' if error.errno == errno.ENOENT else 'unexpectedErrno'}


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
        machine = platform.machine()
        if machine not in ('arm64', 'x86_64'):
            raise RuntimeError('unsupportedCPU')
        resources = Path(__file__).resolve().parent
        executable = resources.parent / 'MacOS/codex'
        if not executable.is_file():
            raise RuntimeError('runtimeUnavailable')
        sdk = importlib.import_module('openai_codex')
        sdk_path = Path(sdk.__file__).resolve()
        if resources.parent not in sdk_path.parents or sdk.__version__ != '0.160.0':
            raise RuntimeError('sdkIdentityMismatch')
        from openai_codex.client import CodexClient, CodexConfig
        home = Path(os.environ['CODEX_HOME'])
        container = Path(pwd.getpwuid(os.getuid()).pw_dir) / 'Library/Containers' / AGENT_ID / 'Data'
        if Path.home() != container or container not in home.resolve().parents:
            raise PermissionError('containerMismatch')
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
            elif params['major'] != 1:
                self.error(identifier, 'versionMismatch', method)
                self.closed = True
            elif min(params['minor'], 0) != 0:
                self.error(identifier, 'invalidParams', method)
            else:
                self.ready = True
                self.emit({'kind': 'result', 'id': identifier, 'result': {
                    'major': 1, 'minor': 0, 'capabilities': ['topology-v1']}}, method)
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
            elif method == 'topology.cleanup':
                result = self.fixtures.cleanup(params['runID'])
            else:
                result = self.fixtures.probe(params['runID'], params['caseID'])
            if asyncio.get_running_loop().time() >= deadline:
                self.terminate(identifier, 'timeout')
            else:
                self.finish(identifier, result=result)
        except asyncio.CancelledError:
            self.terminate(identifier, 'cancelled')
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
