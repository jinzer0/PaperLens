#!/usr/bin/env python3
"""Pinned, stdlib-only topology acquisition. No gclient hooks or host pip."""
from __future__ import annotations

import argparse
import ast
import base64
import csv
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import platform
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import urllib.parse
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[2]
LOCK_PATH = Path(__file__).with_name("dependencies.json")
ARCHES = ("arm64", "x86_64")
SHA256 = re.compile(r"[0-9a-f]{64}\Z")
COMMIT = re.compile(r"[0-9a-f]{40}\Z")
GIT_HOSTS = {"pdfium.googlesource.com", "chromium.googlesource.com", "skia.googlesource.com"}
DOWNLOAD_HOSTS = {"pypi.org", "files.pythonhosted.org", "github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com", "commondatastorage.googleapis.com", "storage.googleapis.com", "chrome-infra-packages.appspot.com"}
MAX_ARCHIVE_BYTES = 12 * 1024**3
PDFIUM_PATCH = {
    "path": "scripts/topology/patches/pdfium-bounded-roll.patch",
    "sha256": "3bc8f7337144cbfe6a6c7d97fc4b470c97c370c0a1f6285c34e08295e64ccded",
    "target": "core/fpdfapi/page/cpdf_psengine.cpp",
    "beforeSha256": "deb4d8dbe96ba81a803c0930b5acf3a4e47af863c5b04929b9b6c9973435f5a6",
    "afterSha256": "296d940f32ed604db4f61218f96d677704e40e72ded0c73eb018850aa29fc2a7",
}


class Failure(Exception):
    """Only fixed safe codes, never raw upstream exception text."""


def require(value, code):
    if not value:
        raise Failure(code)


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def check_hash(path, expected):
    require(isinstance(expected, str) and SHA256.fullmatch(expected), "invalid_sha256_pin")
    require(not Path(path).is_symlink() and sha256(path) == expected, "sha256_mismatch")


def safe_path(root, name, *, allow_leaf_link=False):
    """Refuse ambiguous paths and every existing symlink ancestor."""
    require(isinstance(name, str) and name and "\\" not in name and "\x00" not in name, "unsafe_path")
    relative = PurePosixPath(name)
    require(not relative.is_absolute() and ".." not in relative.parts, "unsafe_path")
    require(relative.parts and relative.parts[0] not in ("", "."), "unsafe_path")
    result = Path(root).joinpath(*relative.parts)
    current = Path(root)
    require(not current.is_symlink(), "symlink_root")
    for index, part in enumerate(relative.parts):
        current = current / part
        require(not current.is_symlink() or (allow_leaf_link and index == len(relative.parts) - 1), "symlink_path")
    return result


def ensure_root(path):
    path = Path(path).absolute()
    for ancestor in [*reversed(path.parents), path]:
        require(not ancestor.is_symlink(), "symlink_root")
    path.mkdir(parents=True, exist_ok=True)
    require(path.is_dir(), "invalid_root")
    return path


def exclusive_bytes(path, data, mode=0o644):
    ensure_root(path.parent)
    with path.open("xb") as stream:
        stream.write(data)
    path.chmod(mode & 0o777)


def save_json(path, value):
    exclusive_bytes(path, (json.dumps(value, sort_keys=True, indent=2) + "\n").encode())


def member_name(name):
    while name.startswith("./"):
        name = name[2:]
    return name.rstrip("/")


def link_destination(name, target, hard=False):
    require(target and not target.startswith("/") and "\\" not in target and "\x00" not in target, "unsafe_link")
    parts = [] if hard else list(PurePosixPath(name).parent.parts)
    for component in PurePosixPath(target).parts:
        if component == "..":
            require(parts, "escaping_link")
            parts.pop()
        elif component != ".":
            parts.append(component)
    require(parts, "unsafe_link")
    return "/".join(parts)


def resolve_internal_link(path, root):
    # Python 3.13 no longer reports cycles with resolve(strict=False).
    # Only a missing target is allowed; ELOOP and other resolution errors fail.
    try:
        try:
            resolved = path.resolve(strict=True)
        except FileNotFoundError:
            resolved = path.resolve(strict=False)
    except (OSError, RuntimeError):
        raise Failure("cyclic_or_invalid_link") from None
    require(resolved.is_relative_to(root.resolve()), "escaping_link")
    return resolved


def extract_archive(archive, destination):
    """Validate the entire layout, then extract files, then internal links.

    Never use extractall, follow archive links, remove a tree, or overwrite a
    different existing file. Internal symlinks are needed by standalone Python.
    """
    destination = ensure_root(destination)
    members = []
    opened = zipfile.ZipFile(archive) if zipfile.is_zipfile(archive) else tarfile.open(archive, "r:*")
    with opened:
        if isinstance(opened, zipfile.ZipFile):
            for entry in opened.infolist():
                mode = entry.external_attr >> 16
                kind = "dir" if entry.is_dir() else "link" if stat.S_ISLNK(mode) else "file"
                require(not stat.S_IFMT(mode) or stat.S_IFMT(mode) in (stat.S_IFREG, stat.S_IFDIR, stat.S_IFLNK), "special_archive_member")
                require(not entry.flag_bits & 1, "encrypted_archive")
                require(kind != "link" or entry.file_size <= 4096, "archive_link_size_limit")
                target = opened.read(entry).decode("utf-8") if kind == "link" else None
                members.append((member_name(entry.filename), kind, mode, entry.file_size, target, entry))
        else:
            for entry in opened.getmembers():
                kind = "dir" if entry.isdir() else "file" if entry.isfile() else "link" if entry.issym() else "hard" if entry.islnk() else "special"
                require(kind != "special", "special_archive_member")
                members.append((member_name(entry.name), kind, entry.mode, entry.size, entry.linkname, entry))
        names = {}
        total = 0
        for name, kind, mode, size, target, entry in members:
            if not name and kind == "dir":
                continue
            candidate = safe_path(destination, name, allow_leaf_link=kind == "link")
            if candidate.is_symlink():
                require(os.readlink(candidate) == target, "archive_collision")
            require(name not in names, "duplicate_archive_member")
            require(not mode & (stat.S_ISUID | stat.S_ISGID), "privileged_archive_member")
            names[name] = kind
            require(size >= 0, "archive_size_limit")
            total += size
            require(total <= MAX_ARCHIVE_BYTES, "archive_size_limit")
            if kind in ("link", "hard"):
                link_destination(name, target, kind == "hard")
        for name in names:
            for parent in PurePosixPath(name).parents:
                require(names.get(str(parent), "dir") == "dir", "archive_link_parent")
        for name, kind, mode, size, target, entry in members:
            if not name or kind in ("link", "hard"):
                continue
            path = safe_path(destination, name)
            if kind == "dir":
                ensure_root(path)
                continue
            ensure_root(path.parent)
            source = opened.open(entry) if isinstance(opened, zipfile.ZipFile) else opened.extractfile(entry)
            require(source is not None, "archive_member_unreadable")
            with source:
                if path.exists():
                    require(path.is_file(), "archive_collision")
                    digest = hashlib.sha256()
                    for chunk in iter(lambda: source.read(1024 * 1024), b""):
                        digest.update(chunk)
                    require(sha256(path) == digest.hexdigest(), "archive_collision")
                    require(stat.S_IMODE(path.stat().st_mode) == ((mode & 0o777) or 0o644), "archive_mode_mismatch")
                else:
                    with path.open("xb") as output:
                        shutil.copyfileobj(source, output)
                    path.chmod((mode & 0o777) or 0o644)
        pending = [(n, k, t) for n, k, _, _, t, _ in members if k in ("link", "hard")]
        while pending:
            progress = False
            for name, kind, target in pending[:]:
                target_name = link_destination(name, target, kind == "hard")
                resolved = destination / target_name
                resolve_internal_link(resolved, destination)
                if kind == "hard" and not resolved.exists():
                    continue
                path = safe_path(destination, name, allow_leaf_link=kind == "link")
                ensure_root(path.parent)
                if path.is_symlink():
                    require(kind == "link" and os.readlink(path) == target, "archive_collision")
                elif path.exists():
                    require(kind == "hard" and path.is_file() and os.path.samefile(path, resolved), "archive_collision")
                elif kind == "hard":
                    require(not resolved.is_symlink() and resolved.is_file(), "unsafe_hardlink")
                    os.link(resolved, path)
                else:
                    path.symlink_to(target)
                pending.remove((name, kind, target))
                progress = True
            require(progress, "dangling_or_cyclic_archive_link")
        # Chromium's exact macOS Clang archive intentionally contains dangling
        # internal Linux-runtime aliases. Preserve them without following them;
        # cycles/escapes remain invalid and hardlinks still require real files.
        for name, kind, _, _, _, _ in members:
            if kind == "link":
                resolve_internal_link(destination / name, destination)


def tree_inventory(root):
    result = []
    for path in sorted(Path(root).rglob("*")):
        relative = path.relative_to(root).as_posix()
        if path.is_symlink():
            resolve_internal_link(path, Path(root))
            result.append({"path": relative, "link": os.readlink(path)})
        elif path.is_file():
            result.append({"path": relative, "sha256": sha256(path), "mode": stat.S_IMODE(path.stat().st_mode)})
    return result


def select_asset(entry, arch):
    require(arch in ARCHES, "unsupported_arch")
    asset = entry.get("any", entry.get(arch))
    require(isinstance(asset, dict), "missing_arch_pin")
    name = asset.get("filename", "")
    other = "x86_64" if arch == "arm64" else "arm64"
    require(other not in name and not (arch == "x86_64" and "aarch64" in name), "asset_arch_mismatch")
    require(SHA256.fullmatch(asset.get("sha256", "")), "invalid_sha256_pin")
    return asset


def load_lock():
    lock = json.loads(LOCK_PATH.read_text())
    require(lock["schemaRevision"] == "topology-v1" and len(lock["wheels"]) == 8, "invalid_dependency_lock")
    require(lock["pdfium"]["commit"] == "ad5bc13610718aefe737bd9b2f1b258d08e39428", "pdfium_pin_mismatch")
    require(lock["approvalCommit"] == "fd8f8b93f726350e3b00ea5dcf2193925561e79f" and lock["pdfium"].get("patch") == PDFIUM_PATCH, "pdfium_patch_pin_mismatch")
    for arch in ARCHES:
        select_asset(lock["python"], arch)
        for wheel in lock["wheels"]:
            select_asset(wheel, arch)
    return lock


class SafeRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, msg, headers, newurl):
        validate_url(newurl)
        return super().redirect_request(request, fp, code, msg, headers, newurl)


def validate_url(url):
    parts = urllib.parse.urlsplit(url)
    require(parts.scheme == "https" and parts.hostname in DOWNLOAD_HOSTS and parts.port in (None, 443) and not parts.username and not parts.password, "undeclared_download_host")


def request(url):
    validate_url(url)
    return urllib.request.build_opener(SafeRedirect()).open(urllib.request.Request(url, headers={"User-Agent": "PaperLensTopology/1"}), timeout=120)


def metadata(url):
    with request(url) as response:
        body = response.read(8 * 1024**2 + 1)
    require(len(body) <= 8 * 1024**2, "metadata_size_limit")
    return json.loads(body)


def download(cache, url, expected, generation=None):
    require(SHA256.fullmatch(expected), "invalid_sha256_pin")
    validate_url(url)
    cache = ensure_root(cache)
    path = safe_path(cache, expected)
    receipt = safe_path(cache, expected + ".json")
    declaration = {"url": url, "sha256": expected, "generation": generation}
    if path.exists():
        check_hash(path, expected)
        require(receipt.is_file() and json.loads(receipt.read_text()) == declaration, "cache_provenance_mismatch")
        return path
    require(not receipt.exists(), "incomplete_cache")
    fd, temporary = tempfile.mkstemp(prefix="fetch-", dir=cache)
    # A failed download leaves only its uniquely owned partial file, not a
    # mutable cache entry. No cleanup operation can remove a caller's tree.
    with os.fdopen(fd, "wb") as output, request(url) as response:
        if generation is not None:
            require(response.headers.get("x-goog-generation") == str(generation), "gcs_generation_mismatch")
        digest = hashlib.sha256()
        total = 0
        while chunk := response.read(1024 * 1024):
            total += len(chunk)
            require(total <= MAX_ARCHIVE_BYTES, "download_size_limit")
            digest.update(chunk)
            output.write(chunk)
    require(digest.hexdigest() == expected, "sha256_mismatch")
    # Hard-link creation is exclusive: a concurrent fetch cannot overwrite.
    os.link(temporary, path)
    Path(temporary).unlink()
    save_json(receipt, declaration)
    return path


def pypi_asset(lock, entry, asset):
    url = lock["pypiURL"].format(project=entry["project"], version=entry["version"])
    document = metadata(url)
    require(document["info"]["version"] == entry["version"], "pypi_version_mismatch")
    matches = [item for item in document["urls"] if item["filename"] == asset["filename"]]
    require(len(matches) == 1, "pypi_filename_mismatch")
    item = matches[0]
    require(not item.get("yanked") and item["digests"]["sha256"] == asset["sha256"], "pypi_hash_mismatch")
    require(urllib.parse.urlsplit(item["url"]).hostname == "files.pythonhosted.org", "pypi_host_mismatch")
    require(urllib.parse.unquote(urllib.parse.urlsplit(item["url"]).path).endswith("/" + asset["filename"]), "pypi_filename_mismatch")
    return item["url"]


def clean_env():
    return {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": str(Path.home()), "LANG": "C", "LC_ALL": "C", "PYTHONDONTWRITEBYTECODE": "1", "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer", "TOOLCHAINS": "com.apple.dt.toolchain.XcodeDefault", "DEPOT_TOOLS_UPDATE": "0", "DEPOT_TOOLS_METRICS": "0", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_TERMINAL_PROMPT": "0"}


def run(argv, cwd=None, env=None, offline=False):
    if offline:
        # GN/Ninja/source scripts cannot silently fetch undeclared inputs.
        argv = ["/usr/bin/sandbox-exec", "-p", "(version 1)(allow default)(deny network*)", *map(str, argv)]
    completed = subprocess.run(list(map(str, argv)), cwd=cwd, env=env or clean_env(), stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    require(completed.returncode == 0, "subprocess_failed")
    return completed.stdout.decode("utf-8", errors="strict").strip()


def toolchain(lock):
    require(sys.platform == "darwin", "macos_required")
    expected = lock["toolchain"]
    require(run(["/usr/bin/xcodebuild", "-version"]) == f"Xcode {expected['xcode']}\nBuild version {expected['build']}", "xcode_mismatch")
    require(run(["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-version"]) == expected["sdk"], "sdk_mismatch")
    swift = run(["/usr/bin/xcrun", "--toolchain", "com.apple.dt.toolchain.XcodeDefault", "swiftc", "--version"])
    require(re.search(r"Apple Swift version 6\.4(?:\s|\.)", swift), "swift_mismatch")
    sdk = run(["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-path"])
    require(Path(sdk).is_relative_to(expected["developerDir"]) and Path(sdk).is_dir(), "sdk_path_mismatch")
    return sdk


def git(path, *args):
    return run(["/usr/bin/git", "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false", "-c", "core.filemode=true", "-c", "core.ignorestat=false", "-c", "protocol.file.allow=never", "-C", path, *args])


def checkout_base(path, url, commit):
    require(COMMIT.fullmatch(commit), "mutable_git_revision")
    parts = urllib.parse.urlsplit(url)
    require(parts.scheme == "https" and parts.hostname in GIT_HOSTS and not parts.query and not parts.fragment and not parts.username, "undeclared_git_host")
    ensure_root(path.parent)
    require(not path.is_symlink(), "symlink_checkout")
    if not path.exists():
        path.mkdir()
        git(path, "init")
        git(path, "fetch", "--depth=1", "--no-tags", url, commit)
        git(path, "checkout", "--detach", commit)
    require(git(path, "rev-parse", "HEAD") == commit, "git_commit_mismatch")


def checkout(path, url, commit):
    checkout_base(path, url, commit)
    git(path, "diff", "--exit-code", "HEAD", "--")
    require(git(path, "ls-files", "--deleted") == "", "missing_git_source")


def pdfium_patch_receipt(lock):
    require(lock["pdfium"].get("patch") == PDFIUM_PATCH, "pdfium_patch_pin_mismatch")
    require(lock["pdfium"]["commit"] == "ad5bc13610718aefe737bd9b2f1b258d08e39428" and lock["pdfium"]["tree"] == "7a17f761fbcaca163cef3575ed98a0a2058dbb3d" and lock["pdfium"]["depsBlob"] == "169680f06af94277eba6ec9e9597635b40092daf", "pdfium_pin_mismatch")
    return {"baseCommit": lock["pdfium"]["commit"], **PDFIUM_PATCH}


def pdfium_checkout(lock, source):
    """Apply only the approved roll fix; never reset or repair a dirty tree."""
    evidence = pdfium_patch_receipt(lock)
    patch = safe_path(ROOT, PDFIUM_PATCH["path"])
    require(patch.is_file(), "pdfium_patch_missing")
    check_hash(patch, PDFIUM_PATCH["sha256"])
    checkout_base(source, lock["pdfium"]["url"], lock["pdfium"]["commit"])
    require(git(source, "rev-parse", "HEAD^{tree}") == lock["pdfium"]["tree"], "pdfium_tree_mismatch")
    require(git(source, "rev-parse", "HEAD:DEPS") == lock["pdfium"]["depsBlob"], "deps_blob_mismatch")
    flags = git(source, "ls-files", "-v").splitlines()
    require(all(line.startswith("H ") for line in flags), "pdfium_hidden_source")
    target = safe_path(source, PDFIUM_PATCH["target"])
    require(target.is_file() and stat.S_IMODE(target.stat().st_mode) == 0o644, "pdfium_patch_target_mode")
    require(git(source, "diff", "--cached", "--name-only", "-z", "HEAD", "--") == "", "pdfium_staged_source")
    require(git(source, "ls-files", "--deleted") == "", "missing_git_source")
    changed = git(source, "diff", "--no-ext-diff", "--no-textconv", "--ignore-submodules=none", "--raw", "--no-abbrev", "HEAD", "--")
    digest = sha256(target)
    if digest == PDFIUM_PATCH["beforeSha256"]:
        require(changed == "", "pdfium_dirty_source")
        git(source, "apply", "--check", "--whitespace=error", patch)
        git(source, "apply", "--whitespace=error", patch)
        digest = sha256(safe_path(source, PDFIUM_PATCH["target"]))
        changed = git(source, "diff", "--no-ext-diff", "--no-textconv", "--ignore-submodules=none", "--raw", "--no-abbrev", "HEAD", "--")
    require(digest == PDFIUM_PATCH["afterSha256"], "pdfium_patch_source_mismatch")
    require(re.fullmatch(r":100644 100644 [0-9a-f]{40} 0{40} M\t" + re.escape(PDFIUM_PATCH["target"]), changed), "pdfium_dirty_source")
    require(stat.S_IMODE(target.stat().st_mode) == 0o644, "pdfium_patch_target_mode")
    return evidence


class DepsReader:
    """Interpret only data expressions; never exec a fetched DEPS file."""
    def __init__(self, source, host, overrides):
        self.values = {"host_os": "mac", "host_cpu": "arm64" if host == "arm64" else "x64", "checkout_mac": True, "checkout_linux": False, "checkout_win": False, "checkout_android": False, "checkout_ios": False}
        self.variables = dict(overrides)
        self.overrides = overrides
        for statement in ast.parse(source).body:
            require(isinstance(statement, ast.Assign) and len(statement.targets) == 1 and isinstance(statement.targets[0], ast.Name), "unsupported_deps_statement")
            name = statement.targets[0].id
            # Hooks are parsed as inert data, never invoked.
            self.values[name] = self.expression(statement.value)
            if name == "vars":
                self.variables = self.values[name] | overrides
        require(isinstance(self.values.get("deps"), dict), "invalid_deps")

    def expression(self, node):
        if isinstance(node, ast.Constant):
            require(type(node.value) in (str, int, bool, type(None)), "unsupported_deps_literal")
            return node.value
        if isinstance(node, (ast.List, ast.Tuple)):
            return [self.expression(item) for item in node.elts]
        if isinstance(node, ast.Dict):
            return {self.expression(key): self.expression(value) for key, value in zip(node.keys, node.values)}
        if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Add):
            return self.expression(node.left) + self.expression(node.right)
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and len(node.args) == 1 and not node.keywords:
            argument = self.expression(node.args[0])
            if node.func.id == "Str":
                return argument
            if node.func.id == "Var":
                require(argument in self.variables or argument in self.values, "unknown_deps_variable")
                return self.variables.get(argument, self.values.get(argument))
        if isinstance(node, ast.Name):
            if node.id in self.values:
                return self.values[node.id]
            require(node.id in self.variables, "unknown_deps_condition")
            value = self.variables[node.id]
            if isinstance(value, str) and (node.id.startswith("checkout_") and node.id != "checkout_configuration" or value in ("True", "False")):
                return self.expression(ast.parse(value, mode="eval").body)
            return value
        if isinstance(node, ast.BoolOp):
            if isinstance(node.op, ast.And):
                return all(bool(self.expression(item)) for item in node.values)
            return any(bool(self.expression(item)) for item in node.values)
        if isinstance(node, ast.UnaryOp) and isinstance(node.op, ast.Not):
            return not self.expression(node.operand)
        if isinstance(node, ast.Compare) and len(node.ops) == 1:
            left, right = self.expression(node.left), self.expression(node.comparators[0])
            if isinstance(node.ops[0], ast.Eq):
                return left == right
            if isinstance(node.ops[0], ast.NotEq):
                return left != right
        raise Failure("unsupported_deps_expression")

    def enabled(self, item):
        return bool(self.expression(ast.parse(item.get("condition", "True"), mode="eval").body))


def instance_sha(instance):
    require(re.fullmatch(r"[A-Za-z0-9_-]{44}", instance), "invalid_cipd_instance")
    decoded = base64.urlsafe_b64decode(instance)
    require(len(decoded) == 33 and decoded[-1] == 2, "unsupported_cipd_digest")
    return decoded[:-1].hex()


def resolve_cipd(lock, package, version, known=None, cache=None):
    require(version and version not in ("latest", "head") and (":" in version or COMMIT.fullmatch(version)), "mutable_cipd_version")
    query = urllib.parse.urlencode({"package_name": package, "version": version})
    resolution_file = None
    if cache is not None:
        resolution_file = safe_path(ensure_root(cache), "cipd-" + hashlib.sha256(query.encode()).hexdigest() + ".json")
    cached = json.loads(resolution_file.read_text()) if resolution_file is not None and resolution_file.exists() else None
    if cached is not None:
        require(cached["package"] == package and cached["version"] == version, "cipd_resolution_mismatch")
        instance = cached["instance"]
    else:
        response = metadata(lock["cipdBaseURL"] + "/_ah/api/repo/v1/instance/resolve?" + query)
        require(response.get("status") == "SUCCESS", "cipd_resolution_failed")
        instance = response["instance_id"]
    digest = instance_sha(instance)
    if known:
        require(known["package"] == package and known["instance"] == instance and known["sha256"] == digest, "cipd_pin_mismatch")
    pin = {"package": package, "version": version, "instance": instance, "sha256": digest}
    if cached is not None:
        require(cached == pin, "cipd_resolution_mismatch")
    elif resolution_file is not None:
        save_json(resolution_file, pin)
    return pin


def gcs_object(lock, item, bucket):
    require(bucket in ("chromium-browser-clang", "chromium-clang-format"), "undeclared_gcs_bucket")
    require(str(item["generation"]).isdigit() and SHA256.fullmatch(item["sha256sum"]), "invalid_gcs_pin")
    name = item["object_name"]
    require(not PurePosixPath(name).is_absolute() and ".." not in PurePosixPath(name).parts, "unsafe_gcs_object")
    base = "https://commondatastorage.googleapis.com/" + bucket + "/"
    return {"url": base + urllib.parse.quote(name, safe="/") + "?generation=" + str(item["generation"]), "sha256": item["sha256sum"], "generation": str(item["generation"])}


def source_graph(lock, work, host, cache, prior=None):
    source = work / "pdfium" / "src"
    if prior is not None:
        require(source.is_dir(), "prepared_source_missing")
    patch_evidence = pdfium_checkout(lock, source)
    deps = DepsReader((source / "DEPS").read_text(), host, lock["pdfium"]["vars"])
    archives, repositories = [], []
    pending = [("", deps)]
    visited = set()
    while pending:
        prefix, reader = pending.pop(0)
        require(prefix not in visited and len(visited) < 32, "recursive_deps_cycle")
        visited.add(prefix)
        require(reader.values.get("use_relative_paths") is True, "unsupported_deps_path_base")
        for relative, item in reader.values["deps"].items():
            relative = str(PurePosixPath(prefix) / relative)
            destination = safe_path(source, relative)
            item = {"url": item} if isinstance(item, str) else item
            require(isinstance(item, dict), "unknown_dependency_layout")
            if not reader.enabled(item):
                continue
            kind = item.get("dep_type", "git")
            if kind == "git":
                url, revision = item["url"].rsplit("@", 1)
                expected = lock["pdfium"]["sourcePins"].get(relative)
                require(expected is None or expected == revision, "deps_revision_mismatch")
                if prior is not None:
                    require(destination.is_dir(), "prepared_source_missing")
                checkout(destination, url, revision)
                repositories.append({"path": relative, "url": url, "commit": revision})
            elif kind == "cipd":
                for package in item["packages"]:
                    cpu = "arm64" if host == "arm64" else "amd64"
                    name = package["package"].replace("${{platform}}", "mac-" + cpu).replace("${{arch}}", cpu)
                    known = next((pin for pin in lock["cipd"][host].values() if pin["package"] == name), None)
                    if relative == "buildtools/mac":
                        require(package["version"] == lock["pdfium"]["gnVersion"], "gn_version_mismatch")
                    if relative == "third_party/ninja":
                        require(package["version"] == lock["pdfium"]["ninjaVersion"], "ninja_version_mismatch")
                    if prior is None:
                        pin = resolve_cipd(lock, name, package["version"], known, cache=cache)
                    else:
                        matches = [entry for entry in prior["archives"] if entry.get("package") == name and entry["path"] == relative]
                        require(len(matches) == 1 and matches[0]["version"] == package["version"], "cipd_provenance_mismatch")
                        pin = {key: matches[0][key] for key in ("package", "version", "instance", "sha256")}
                        require(instance_sha(pin["instance"]) == pin["sha256"], "cipd_digest_mismatch")
                        if known:
                            require(all(pin[key] == known[key] for key in known), "cipd_pin_mismatch")
                    url = lock["cipdBaseURL"] + "/dl/" + name + "/+/" + pin["instance"]
                    if prior is not None:
                        require((cache / pin["sha256"]).is_file(), "cached_input_missing")
                    download(cache, url, pin["sha256"])
                    archives.append(pin | {"path": relative, "url": url, "generation": None})
            elif kind == "gcs":
                for obj in item["objects"]:
                    if reader.enabled(obj):
                        pin = gcs_object(lock, obj, item["bucket"])
                        if prior is not None:
                            require((cache / pin["sha256"]).is_file(), "cached_input_missing")
                        download(cache, pin["url"], pin["sha256"], pin["generation"])
                        record = pin | {"path": relative}
                        if "output_file" in obj:
                            safe_path(destination, obj["output_file"])
                            record["outputFile"] = obj["output_file"]
                        archives.append(record)
            else:
                raise Failure("undeclared_dependency_type")
        for child in reader.values.get("recursedeps", []):
            require(isinstance(child, str), "unsupported_recursive_deps")
            relative = str(PurePosixPath(prefix) / child)
            path = safe_path(source, relative)
            require(any(item["path"] == relative for item in repositories), "undeclared_recursive_deps")
            blob = git(path, "rev-parse", "HEAD:DEPS")
            require(COMMIT.fullmatch(blob), "recursive_deps_blob_missing")
            pending.append((relative, DepsReader((path / "DEPS").read_text(), host, reader.variables)))
    require(set(lock["pdfium"]["sourcePins"]) <= {item["path"] for item in repositories}, "missing_source_pin")
    for pin in lock["clang"][host]:
        # Cross-check every approved compiler object against the DEPS authority,
        # even when its upstream condition is for non-Git source distribution.
        objects = deps.values["deps"]["third_party/llvm-build/Release+Asserts"]["objects"]
        matches = [obj for obj in objects if obj["object_name"] == pin["object"]]
        require(len(matches) == 1 and str(matches[0]["generation"]) == pin["generation"] and matches[0]["sha256sum"] == pin["sha256"], "clang_deps_mismatch")
        entry = gcs_object(lock, matches[0], "chromium-browser-clang")
        if prior is not None:
            require((cache / entry["sha256"]).is_file(), "cached_input_missing")
        download(cache, entry["url"], entry["sha256"], entry["generation"])
        record = entry | {"path": "third_party/llvm-build/Release+Asserts"}
        if record not in archives:
            archives.append(record)
    management = (source / "tools/clang/scripts/update.py").read_text()
    constants = {
        statement.targets[0].id: statement.value.value
        for statement in ast.parse(management).body
        if isinstance(statement, ast.Assign) and len(statement.targets) == 1
        and isinstance(statement.targets[0], ast.Name) and isinstance(statement.value, ast.Constant)
    }
    require(str(constants.get("CLANG_REVISION")) + "-" + str(constants.get("CLANG_SUB_REVISION")) == lock["pdfium"]["clangVersion"], "clang_management_mismatch")
    return {"repositories": repositories, "archives": archives, "pdfiumPatch": patch_evidence}


def fetch(lock, work, host, arch, cache):
    receipt_path = safe_path(work, "acquisition.json")
    if receipt_path.exists():
        return validate_receipt(lock, work, host, arch, cache)
    assets = []
    python = select_asset(lock["python"], arch)
    url = lock["python"]["baseURL"] + urllib.parse.quote(python["filename"])
    download(cache, url, python["sha256"])
    assets.append(python | {"kind": "python", "url": url})
    for wheel in lock["wheels"]:
        asset = select_asset(wheel, arch)
        url = pypi_asset(lock, wheel, asset)
        download(cache, url, asset["sha256"])
        assets.append(asset | {"kind": "wheel", "url": url})
    asset = lock["sdkSource"]
    url = pypi_asset(lock, asset, asset)
    download(cache, url, asset["sha256"])
    assets.append(asset | {"kind": "source", "url": url})
    graph = source_graph(lock, work, host, cache)
    receipt = {"schemaRevision": "topology-v1", "lockHash": sha256(LOCK_PATH), "arch": arch, "host": host, "assets": assets, **graph}
    save_json(receipt_path, receipt)
    return receipt


def validate_receipt(lock, work, host, arch, cache):
    path = safe_path(work, "acquisition.json")
    require(path.is_file(), "fetch_required")
    receipt = json.loads(path.read_text())
    require(receipt["lockHash"] == sha256(LOCK_PATH) and receipt["arch"] == arch and receipt["host"] == host, "acquisition_pin_or_arch_mismatch")
    require(receipt.get("pdfiumPatch") == pdfium_patch_receipt(lock), "pdfium_patch_receipt_mismatch")
    expected_assets = [select_asset(lock["python"], arch), *[select_asset(wheel, arch) for wheel in lock["wheels"]], lock["sdkSource"]]
    require(len(receipt["assets"]) == len(expected_assets), "asset_inventory_mismatch")
    kinds = ["python", *(["wheel"] * len(lock["wheels"])), "source"]
    for item, expected, kind in zip(receipt["assets"], expected_assets, kinds):
        require(item["filename"] == expected["filename"] and item["sha256"] == expected["sha256"] and item["kind"] == kind, "asset_pin_mismatch")
    for item in [*receipt["assets"], *receipt["archives"]]:
        check_hash(safe_path(cache, item["sha256"]), item["sha256"])
        cached = json.loads(safe_path(cache, item["sha256"] + ".json").read_text())
        require(cached == {"url": item["url"], "sha256": item["sha256"], "generation": item.get("generation")}, "cache_provenance_mismatch")
    graph = source_graph(lock, work, host, cache, prior=receipt)
    require(graph["repositories"] == receipt["repositories"] and graph["archives"] == receipt["archives"] and graph["pdfiumPatch"] == receipt["pdfiumPatch"], "dependency_graph_mismatch")
    return receipt


def install_wheel(archive, runtime, filename):
    """PEP 427 spread; preserve licenses and update installed RECORD paths."""
    site = runtime / "lib/python3.13/site-packages"
    ensure_root(site)
    with zipfile.ZipFile(archive) as wheel:
        names = [member_name(item.filename) for item in wheel.infolist() if not item.is_dir()]
        dist_infos = {name.split("/")[0] for name in names if name.split("/")[0].endswith(".dist-info")}
        require(len(dist_infos) == 1, "wheel_metadata_layout")
        info = dist_infos.pop()
        require({info + "/WHEEL", info + "/METADATA", info + "/RECORD"} <= set(names), "wheel_metadata_missing")
        wheel_metadata = wheel.read(info + "/WHEEL").decode("utf-8")
        require("Wheel-Version: 1.0" in wheel_metadata, "unsupported_wheel_version")
        rows = list(csv.reader(io.StringIO(wheel.read(info + "/RECORD").decode("utf-8"))))
        indexed = {row[0]: row for row in rows if len(row) == 3}
        require(len(indexed) == len(rows) and set(indexed) == set(names), "wheel_record_layout")
        planned = []
        for member in wheel.infolist():
            if member.is_dir():
                continue
            name = member_name(member.filename)
            safe_path(runtime, name)
            mode = member.external_attr >> 16
            require(not stat.S_IFMT(mode) or stat.S_ISREG(mode), "wheel_nonregular_member")
            require(not mode & (stat.S_ISUID | stat.S_ISGID), "privileged_wheel_member")
            parts = PurePosixPath(name).parts
            target = site / name
            script = False
            if parts[0].endswith(".data"):
                require(parts[0] == info.removesuffix(".dist-info") + ".data" and len(parts) >= 3, "unknown_wheel_data_layout")
                category, remainder = parts[1], "/".join(parts[2:])
                roots = {"purelib": site, "platlib": site, "data": runtime, "headers": runtime / "include/python3.13" / info.rsplit("-", 1)[0], "scripts": runtime / "bin"}
                require(category in roots, "unsupported_wheel_script_layout")
                target = safe_path(roots[category], remainder)
                script = category == "scripts"
            data = wheel.read(member)
            digest, length = indexed[name][1:]
            if name != info + "/RECORD":
                encoded = base64.urlsafe_b64encode(hashlib.sha256(data).digest()).rstrip(b"=").decode()
                require(digest == "sha256=" + encoded and length == str(len(data)), "wheel_record_mismatch")
            else:
                require(not digest and not length, "wheel_record_self_hash")
            if script:
                require(data.startswith((b"#!python\n", b"#!pythonw\n")) and len(parts) == 3, "unknown_wheel_executable")
                # Relocatable shell/Python launcher, never /usr/bin/env Python.
                data = b"#!/bin/sh\n'''exec' \"$(dirname \"$0\")/python3.13\" \"$0\" \"$@\"\n' '''\n" + data.split(b"\n", 1)[1]
                mode = 0o755
            if mode & 0o111:
                known_cli = filename.startswith("openai_codex_cli_bin-") and parts[0] == "codex_cli_bin"
                require(script or known_cli or name.endswith((".so", ".dylib")), "unknown_wheel_executable")
            safe_path(runtime, target.relative_to(runtime).as_posix())
            require(not target.exists(), "wheel_install_collision")
            planned.append((name, target, data, (mode & 0o777) or 0o644))
        require(len({item[1] for item in planned}) == len(planned), "wheel_install_collision")
        installed_rows = []
        for name, target, data, mode in planned:
            relative = os.path.relpath(target, site)
            if name != info + "/RECORD":
                exclusive_bytes(target, data, mode)
                encoded = base64.urlsafe_b64encode(hashlib.sha256(data).digest()).rstrip(b"=").decode()
                installed_rows.append([relative, "sha256=" + encoded, str(len(data))])
            else:
                record_target = target
                installed_rows.append([relative, "", ""])
        output = io.StringIO(newline="")
        csv.writer(output, lineterminator="\n").writerows(installed_rows)
        exclusive_bytes(record_target, output.getvalue().encode())


def runtime_stage(lock, work, receipt, cache):
    destination = safe_path(work, "runtime")
    receipt_path = safe_path(work, "runtime.json")
    if destination.exists():
        require(receipt_path.is_file(), "incomplete_runtime")
        expected = json.loads(receipt_path.read_text())
        require(expected["lockHash"] == sha256(LOCK_PATH) and expected["arch"] == receipt["arch"] and expected["files"] == tree_inventory(destination), "runtime_integrity_mismatch")
        return
    destination.mkdir()
    python = next(item for item in receipt["assets"] if item["kind"] == "python")
    extract_archive(cache / python["sha256"], destination)
    root = destination / "python"
    require(root.is_dir() and (root / "bin/python3.13").is_file(), "python_runtime_layout")
    require({item.name for item in destination.iterdir()} == {"python"}, "python_runtime_layout")
    for item in receipt["assets"]:
        if item["kind"] == "wheel":
            install_wheel(cache / item["sha256"], root, item["filename"])
    save_json(receipt_path, {"lockHash": sha256(LOCK_PATH), "arch": receipt["arch"], "files": tree_inventory(destination)})


def pdfium_stage(lock, work, receipt, cache):
    require(sys.version_info[:2] == (3, 13), "build_python_version_mismatch")
    sdk = toolchain(lock)
    source = work / "pdfium/src"
    require(receipt.get("pdfiumPatch") == pdfium_patch_receipt(lock), "pdfium_patch_receipt_mismatch")
    pdfium_checkout(lock, source)
    for item in receipt["repositories"]:
        checkout(safe_path(source, item["path"]), item["url"], item["commit"])
    tools_receipt = safe_path(work, "prepared-tools.json")
    if not tools_receipt.exists():
        for item in receipt["archives"]:
            destination = safe_path(source, item["path"])
            if "outputFile" in item:
                target = safe_path(destination, item["outputFile"])
                if target.exists():
                    check_hash(target, item["sha256"])
                else:
                    exclusive_bytes(target, (cache / item["sha256"]).read_bytes(), 0o755)
            else:
                extract_archive(cache / item["sha256"], destination)
        tool_paths = sorted({item["path"] for item in receipt["archives"]})
        save_json(tools_receipt, {path: tree_inventory(source / path) for path in tool_paths})
    for path, inventory in json.loads(tools_receipt.read_text()).items():
        require(inventory == tree_inventory(safe_path(source, path)), "prepared_tool_integrity_mismatch")
    # gclient's generated argument file is data, not a reason to run its hooks.
    generated = source / "build/config/gclient_args.gni"
    args_text = 'build_with_chromium = false\ncheckout_android = false\ncheckout_skia = false\nandroid_ndk_version = "2@30.0.15729638"\n'
    if generated.exists():
        require(not generated.is_symlink() and generated.read_text() == args_text, "gclient_args_mismatch")
    else:
        exclusive_bytes(generated, args_text.encode())
    output = ensure_root(work / "pdfium/out")
    # This pinned Chromium build declares SDK files as generated outputs, so its
    # own sdk_info.py alias must be used. It must resolve to the approved SDK.
    sdk_alias = output / "sdk/xcode_links" / f"MacOSX{lock['toolchain']['sdk']}.sdk"
    if sdk_alias.exists() or sdk_alias.is_symlink():
        require(sdk_alias.resolve() == Path(sdk).resolve(), "sdk_alias_mismatch")
    arguments = dict(lock["pdfium"]["gnArgs"], target_cpu="arm64" if receipt["arch"] == "arm64" else "x64", mac_sdk_path=str(sdk_alias))
    gn_args = "\n".join(f"{key} = {json.dumps(value)}" for key, value in arguments.items()) + "\n"
    args_file = safe_path(output, "args.gn")
    if args_file.exists():
        require(args_file.read_text() == gn_args, "gn_args_mismatch")
    else:
        exclusive_bytes(args_file, gn_args.encode())
    # Build scripts use python3. This is build-time only, never copied into app.
    env = clean_env()
    python_bin = ensure_root(work / "build-host-bin")
    launcher = python_bin / "python3"
    if launcher.is_symlink():
        require(launcher.resolve() == Path(sys.executable).resolve(), "build_python_mismatch")
    elif launcher.exists():
        raise Failure("build_python_mismatch")
    else:
        launcher.symlink_to(Path(sys.executable).resolve())
    env["PATH"] = str(python_bin) + ":" + env["PATH"]
    run([source / "buildtools/mac/gn", "gen", output, "--root=" + str(source), "--fail-on-unused-args"], cwd=source, env=env, offline=True)
    require(sdk_alias.is_symlink() and sdk_alias.resolve() == Path(sdk).resolve(), "sdk_alias_mismatch")
    run([source / "third_party/ninja/ninja", "-C", output, "pdfium"], cwd=source, env=env, offline=True)
    description = json.loads(run([source / "buildtools/mac/gn", "desc", output, "//:pdfium", "outputs", "--format=json"], cwd=source, env=env, offline=True))
    outputs = description.get("//:pdfium", {}).get("outputs", []) if isinstance(description, dict) else description
    libraries = [entry for entry in outputs if entry.endswith(".a")]
    require(len(libraries) == 1, "pdfium_static_output_missing")
    candidate = Path(libraries[0])
    if libraries[0].startswith("//"):
        candidate = source / libraries[0][2:]
    elif not candidate.is_absolute():
        candidate = output / candidate
    require(candidate.resolve().is_relative_to(work.resolve()) and candidate.is_file(), "pdfium_static_output_path")
    with candidate.open("rb") as stream:
        require(stream.read(8) == b"!<arch>\n", "pdfium_not_static_archive")
    require(run(["/usr/bin/lipo", "-archs", candidate]) == receipt["arch"], "pdfium_arch_mismatch")
    target = ensure_root(work / "deps") / "libpdfium.a"
    if target.exists():
        check_hash(target, sha256(candidate))
    else:
        with candidate.open("rb") as source_file, target.open("xb") as target_file:
            shutil.copyfileobj(source_file, target_file)
    result = safe_path(work, "pdfium-build.json")
    evidence = {"arch": receipt["arch"], "sourceCommit": lock["pdfium"]["commit"], "depsBlob": lock["pdfium"]["depsBlob"], "gnArgs": arguments, "sha256": sha256(target), "actualExecution": "not_checked"}
    if result.exists():
        require(json.loads(result.read_text()) == evidence, "pdfium_receipt_mismatch")
    else:
        save_json(result, evidence)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--arch", required=True, choices=ARCHES)
    parser.add_argument("--stage", required=True, choices=("fetch", "pdfium", "runtime"))
    args = parser.parse_args(argv)
    try:
        lock = load_lock()
        toolchain(lock)
        host = platform.machine()
        require(host in ARCHES, "unsupported_host_cpu")
        translated = subprocess.run(["/usr/sbin/sysctl", "-in", "sysctl.proc_translated"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=clean_env())
        if translated.returncode == 0:
            require(translated.stdout.strip() == b"0", "rosetta_or_unknown_host_forbidden")
        else:
            require(host == "x86_64" and run(["/usr/sbin/sysctl", "-n", "hw.optional.arm64"]) == "0", "native_build_host_not_proven")
        work = ensure_root(ROOT / ".build/topology" / args.arch)
        cache = ensure_root(ROOT / ".build/topology/downloads")
        receipt = fetch(lock, work, host, args.arch, cache) if args.stage == "fetch" else validate_receipt(lock, work, host, args.arch, cache)
        if args.stage == "pdfium":
            pdfium_stage(lock, work, receipt, cache)
        elif args.stage == "runtime":
            runtime_stage(lock, work, receipt, cache)
        print(json.dumps({"stage": args.stage, "arch": args.arch, "verdict": "pass", "scope": "preparation_only"}))
        return 0
    except Failure as error:
        print(json.dumps({"stage": args.stage, "arch": args.arch, "verdict": "blocked", "reason": str(error)}))
    except (OSError, ValueError, KeyError, TypeError, IndexError, StopIteration, SyntaxError, tarfile.TarError, zipfile.BadZipFile):
        print(json.dumps({"stage": args.stage, "arch": args.arch, "verdict": "blocked", "reason": "acquisition_failed"}))
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
