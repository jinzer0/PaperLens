import Darwin
import Foundation

/// Plaintext secret storage. The caller supplies a private, already-owned parent directory.
/// Existing paths are verified, never adopted or permission-repaired.
@MainActor
public final class APIKeySlotStore {
  private let root: URL
  private let device: dev_t
  private let inode: ino_t
  private var identities: [UUID: (dev_t, ino_t)] = [:]
  private struct ContentStamp: Equatable {
    let size: Int64
    let seconds: Int64
    let nanoseconds: Int64
    init(_ info: stat) {
      size = Int64(info.st_size)
      seconds = Int64(info.st_mtimespec.tv_sec)
      nanoseconds = Int64(info.st_mtimespec.tv_nsec)
    }
  }
  private var contentStamps: [UUID: ContentStamp] = [:]

  private static func excludedFromBackup(_ url: URL) -> Bool {
    var current = url
    current.removeAllCachedResourceValues()
    return (try? current.resourceValues(forKeys: [.isExcludedFromBackupKey])
      .isExcludedFromBackup) == true
  }

  public init(directory: URL) throws {
    guard directory.isFileURL,
      !directory.pathComponents.contains("."), !directory.pathComponents.contains("..")
    else { throw APIKeyConnectionError.unsafeStorage }
    let root = directory
    var ancestor = root.deletingLastPathComponent()
    while ancestor.path != "/" {
      var parentInfo = stat()
      guard lstat(ancestor.path, &parentInfo) == 0,
        parentInfo.st_mode & S_IFMT == S_IFDIR else { throw APIKeyConnectionError.unsafeStorage }
      ancestor.deleteLastPathComponent()
    }
    var info = stat()
    var createdRoot: (dev_t, ino_t)?
    if lstat(root.path, &info) != 0 {
      let rootError = errno
      var parentInfo = stat()
      guard lstat(root.deletingLastPathComponent().path, &parentInfo) == 0,
        parentInfo.st_uid == geteuid(), parentInfo.st_mode & 0o7777 == 0o700
      else { throw APIKeyConnectionError.unsafeStorage }
      guard rootError == ENOENT, mkdir(root.path, 0o700) == 0 else {
        throw APIKeyConnectionError.unsafeStorage
      }
      guard lstat(root.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
        info.st_uid == geteuid(), info.st_mode & 0o7777 == 0o700 else {
        throw APIKeyConnectionError.unsafeStorage
      }
      createdRoot = (info.st_dev, info.st_ino)
      do {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = root
        try url.setResourceValues(values)
      } catch { throw APIKeyConnectionError.unsafeStorage }
    }
    guard lstat(root.path, &info) == 0, info.st_uid == geteuid(),
      info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o7777 == 0o700,
      Self.excludedFromBackup(root)
    else { throw APIKeyConnectionError.unsafeStorage }
    if let createdRoot {
      guard createdRoot.0 == info.st_dev, createdRoot.1 == info.st_ino else {
        throw APIKeyConnectionError.unsafeStorage
      }
    }
    self.root = root
    device = info.st_dev
    inode = info.st_ino
    try validate()
  }

  private func openRoot() throws -> Int32 {
    // Refuse symlink ancestors as well as a replaced root.
    var ancestor = root
    while ancestor.path != "/" {
      var info = stat()
      guard lstat(ancestor.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
        throw APIKeyConnectionError.unsafeStorage
      }
      ancestor.deleteLastPathComponent()
    }
    let fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw APIKeyConnectionError.unsafeStorage }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_dev == device, info.st_ino == inode,
      info.st_uid == geteuid(), info.st_mode & 0o7777 == 0o700,
      Self.excludedFromBackup(root)
    else {
      close(fd)
      throw APIKeyConnectionError.unsafeStorage
    }
    return fd
  }

  private func checkedFile(_ id: UUID, rootFD: Int32) throws -> Int32 {
    let fd = openat(rootFD, id.uuidString, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw APIKeyConnectionError.unsafeStorage }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_uid == geteuid(),
      info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o7777 == 0o600,
      info.st_nlink == 1, info.st_size > 0, info.st_size <= 4096,
      Self.excludedFromBackup(root.appendingPathComponent(id.uuidString))
    else {
      close(fd)
      throw APIKeyConnectionError.unsafeStorage
    }
    if let known = identities[id] {
      guard known.0 == info.st_dev, known.1 == info.st_ino else {
        close(fd)
        throw APIKeyConnectionError.unsafeStorage
      }
    } else {
      identities[id] = (info.st_dev, info.st_ino)
    }
    let stamp = ContentStamp(info)
    if let known = contentStamps[id], known != stamp {
      close(fd)
      throw APIKeyConnectionError.unsafeStorage
    }
    contentStamps[id] = stamp
    return fd
  }

  public func validate() throws {
    let fd = try openRoot()
    defer { close(fd) }
    let entries: [URL]
    do { entries = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) }
    catch { throw APIKeyConnectionError.unsafeStorage }
    for entry in entries {
      guard let id = UUID(uuidString: entry.lastPathComponent), id.uuidString == entry.lastPathComponent else {
        throw APIKeyConnectionError.unsafeStorage
      }
      let file = try checkedFile(id, rootFD: fd)
      close(file)
    }
  }

  public func create(key: String) throws -> UUID {
    guard !key.isEmpty, key.utf8.count <= 4096,
      key.utf8.allSatisfy({ $0 >= 0x21 && $0 <= 0x7e })
    else { throw APIKeyConnectionError.invalidKey }
    try validate()
    let rootFD = try openRoot()
    defer { close(rootFD) }
    let id = UUID()
    let fd = openat(rootFD, id.uuidString, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw APIKeyConnectionError.unsafeStorage }
    defer { close(fd) }
    var created = stat()
    guard fstat(fd, &created) == 0, created.st_uid == geteuid(),
      created.st_mode & S_IFMT == S_IFREG, created.st_mode & 0o7777 == 0o600,
      created.st_nlink == 1 else { throw APIKeyConnectionError.unsafeStorage }
    identities[id] = (created.st_dev, created.st_ino)
    do {
      let data = Data(key.utf8)
      try data.withUnsafeBytes { buffer in
        var offset = 0
        while offset < buffer.count {
          let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
          if count < 0 && errno == EINTR { continue }
          guard count > 0 else { throw APIKeyConnectionError.unsafeStorage }
          offset += count
        }
      }
      guard fsync(fd) == 0 else { throw APIKeyConnectionError.unsafeStorage }
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      var url = root.appendingPathComponent(id.uuidString)
      try url.setResourceValues(values)
      guard fsync(fd) == 0, fsync(rootFD) == 0 else { throw APIKeyConnectionError.unsafeStorage }
      try validate()
      return id
    } catch {
      // A failed write is a storage barrier, not a successful cleanup.
      throw APIKeyConnectionError.unsafeStorage
    }
  }

  public func read(_ id: UUID) throws -> String {
    try validate()
    let rootFD = try openRoot()
    defer { close(rootFD) }
    let fd = try checkedFile(id, rootFD: rootFD)
    defer { close(fd) }
    var bytes = [UInt8](repeating: 0, count: 4097)
    var offset = 0
    while offset < bytes.count {
      let count = bytes.withUnsafeMutableBytes {
        Darwin.read(fd, $0.baseAddress!.advanced(by: offset), $0.count - offset)
      }
      if count < 0 && errno == EINTR { continue }
      guard count >= 0 else { throw APIKeyConnectionError.unsafeStorage }
      if count == 0 { break }
      offset += count
    }
    var afterRead = stat()
    var named = stat()
    guard fstat(fd, &afterRead) == 0, contentStamps[id] == ContentStamp(afterRead),
      fstatat(rootFD, id.uuidString, &named, AT_SYMLINK_NOFOLLOW) == 0,
      afterRead.st_dev == named.st_dev, afterRead.st_ino == named.st_ino,
      contentStamps[id] == ContentStamp(named), named.st_uid == geteuid(),
      named.st_mode & S_IFMT == S_IFREG, named.st_mode & 0o7777 == 0o600
    else {
      throw APIKeyConnectionError.unsafeStorage
    }
    guard offset > 0, offset <= 4096,
      bytes.prefix(offset).allSatisfy({ $0 >= 0x21 && $0 <= 0x7e }),
      let key = String(bytes: bytes.prefix(offset), encoding: .utf8)
    else { throw APIKeyConnectionError.unsafeStorage }
    return key
  }

  /// Only Application, after proving zero references, may request removal.
  public func remove(_ id: UUID) throws {
    try validate()
    let rootFD = try openRoot()
    defer { close(rootFD) }
    let fd = try checkedFile(id, rootFD: rootFD)
    defer { close(fd) }
    var opened = stat()
    var named = stat()
    guard fstat(fd, &opened) == 0,
      fstatat(rootFD, id.uuidString, &named, AT_SYMLINK_NOFOLLOW) == 0,
      opened.st_dev == named.st_dev, opened.st_ino == named.st_ino,
      unlinkat(rootFD, id.uuidString, 0) == 0, fsync(rootFD) == 0
    else { throw APIKeyConnectionError.cleanupBlocked }
    identities.removeValue(forKey: id)
    contentStamps.removeValue(forKey: id)
  }
}
