import Darwin
import Foundation

@objc protocol PDFTopologyService {
  func inspect(_ runID: String, pdf: FileHandle, withReply reply: @escaping (Data) -> Void)
}

enum TopologyIdentity {
  static let main = "io.github.jinzer0.PaperLens"
  static let worker = main + ".PDFiumXPC"
  static let agent = main + ".ProviderAgent"
  static let groupOwner = main + ".TopologyFixtureOwner"
  static let group = "397452Z366." + main + ".TopologyFixture"

  static func requirement(_ identifier: String) -> String {
    "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"397452Z366\" and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
  }

  // Only OS account metadata selects the profile; sandbox HOME is not the
  // account home. Invalid metadata must not produce a fallback fixture path.
  static func accountHome() -> URL? {
    let uid = getuid()
    guard uid >= 500, geteuid() == uid,
      let entry = getpwuid(uid), entry.pointee.pw_uid == uid,
      let directory = entry.pointee.pw_dir,
      let path = String(validatingCString: directory), path.hasPrefix("/"), path != "/"
    else { return nil }
    let home = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    var info = stat()
    guard home.path == path, home.resolvingSymlinksInPath() == home,
      lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR
    else { return nil }
    return home
  }

  // Check the bundle identity and actual sandbox container against the same
  // OS-derived account home, never using sandbox HOME to select the profile.
  static func container(_ identifier: String) -> URL? {
    guard Bundle.main.bundleIdentifier == identifier, let home = accountHome()
    else { return nil }
    let expected =
      home
      .appendingPathComponent("Library/Containers/\(identifier)/Data", isDirectory: true)
    let actual = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).standardizedFileURL
    var info = stat()
    guard actual == expected.standardizedFileURL,
      actual.resolvingSymlinksInPath() == actual,
      lstat(actual.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR
    else { return nil }
    return actual
  }
}

enum TopologyFixtures {
  static var home: String? { TopologyIdentity.accountHome()?.path }
  static var groupRoot: String? {
    guard let home else { return nil }
    return home + "/Library/Group Containers/" + TopologyIdentity.group
  }
  static let aliases = ["M", "A", "C", "E", "G", "PDF"]
  static let nonce = Data("PaperLensTopology\n".utf8)
  private static let syntheticPDF: Data = {
    var bytes = Data("%PDF-1.4\n".utf8)
    let objects = [
      "<< /Type /Catalog /Pages 2 0 R >>",
      "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
      "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 72 72] /Resources << >> >>",
    ]
    var offsets: [Int] = []
    for (index, object) in objects.enumerated() {
      offsets.append(bytes.count)
      bytes.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8))
    }
    let xref = bytes.count
    bytes.append(Data("xref\n0 4\n0000000000 65535 f \n".utf8))
    for offset in offsets {
      bytes.append(Data(String(format: "%010ld 00000 n \n", offset).utf8))
    }
    bytes.append(Data("trailer\n<< /Size 4 /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
    return bytes
  }()

  static func validRunID(_ value: String) -> Bool {
    guard let uuid = UUID(uuidString: value), uuid.uuidString.lowercased() == value else {
      return false
    }
    let chars = Array(value)
    return chars[14] == "4" && "89ab".contains(chars[19])
  }

  static func profileMatches(_ identifier: String) -> Bool {
    guard groupMapMatches(), let home, let root = TopologyIdentity.container(identifier)
    else { return false }
    return root.path == home + "/Library/Containers/\(identifier)/Data"
  }

  static func groupMapMatches() -> Bool {
    guard let url = Bundle.main.url(forResource: "fixture-map", withExtension: "json"),
      let bytes = try? Data(contentsOf: url), bytes.count <= 4096,
      let map = try? JSONSerialization.jsonObject(with: bytes) as? [String: String]
    else { return false }
    return map == ["profile": "current-user", "groupID": TopologyIdentity.group]
  }

  static func path(_ alias: String, runID: String) -> String? {
    guard validRunID(runID), groupMapMatches(), let home else { return nil }
    let main = home + "/Library/Containers/" + TopologyIdentity.main + "/Data"
    let agent = home + "/Library/Containers/" + TopologyIdentity.agent + "/Data"
    switch alias {
    case "M": return main + "/Library/Application Support/PaperLensTopology/\(runID)/db.canary"
    case "PDF": return main + "/Library/Application Support/PaperLensTopology/\(runID)/input.pdf"
    case "A": return agent + "/Library/Application Support/PaperLensTopology/\(runID)/secret.canary"
    case "C": return agent + "/Library/Caches/PaperLensTopology/\(runID)/cache.canary"
    case "E":
      return home
        + "/Library/Application Support/PaperLensTopologyFixtureHost/\(runID)/external.canary"
    case "G":
      guard let groupRoot else { return nil }
      return groupRoot + "/PaperLensTopology/\(runID)/group.canary"
    default: return nil
    }
  }

  static func marker(_ alias: String, runID: String) -> Data {
    alias == "PDF" ? syntheticPDF : Data("PaperLens topology canary\n".utf8)
  }

  static func publishReport(_ report: Data, directory: Int32) -> Bool {
    let temporary = UUID().uuidString.lowercased() + ".report"
    let fd = openat(
      directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { return false }
    defer {
      close(fd)
      unlinkat(directory, temporary, 0)
    }
    let written = report.withUnsafeBytes { bytes -> Bool in
      var offset = 0
      while offset < bytes.count {
        let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else { return false }
        offset += count
      }
      return true
    }
    guard written, fsync(fd) == 0 else { return false }
    // Publication cannot replace a prior report, even if it races the verifier.
    return renameatx_np(directory, temporary, directory, "report.json", UInt32(RENAME_EXCL)) == 0
  }

  // Walk with directory descriptors: neither a pre-existing symlink nor a
  // concurrently replaced ancestor may redirect creation into user files.
  static func directory(_ url: URL, create: Bool) -> Int32? {
    guard url.isFileURL, url.path.hasPrefix("/") else { return nil }
    var fd = open("/", O_SEARCH | O_CLOEXEC | O_NOFOLLOW)
    guard fd >= 0 else { return nil }
    for part in url.pathComponents.dropFirst() {
      // Ancestors need search, not directory listing or write permission.
      // Try existing metadata first; create only a genuinely missing segment.
      var next = openat(fd, part, O_SEARCH | O_CLOEXEC | O_NOFOLLOW)
      if next < 0 && errno == ENOENT && create {
        if mkdirat(fd, part, 0o700) != 0 && errno != EEXIST {
          let failure = errno
          close(fd)
          errno = failure
          return nil
        }
        next = openat(fd, part, O_SEARCH | O_CLOEXEC | O_NOFOLLOW)
      }
      let failure = next < 0 ? errno : 0
      close(fd)
      guard next >= 0 else {
        errno = failure
        return nil
      }
      fd = next
    }
    return fd
  }

  static func observation(
    runID: String, actor: String, alias: String, operation: String,
    result: Int, error: Int32 = 0, matched: Bool = true
  ) -> [String: Any] {
    let verdict: String
    if !matched || error == ENOENT {
      verdict = "blocked"
    } else if result >= 0 {
      verdict = "failed"
    }  // A forbidden operation succeeded.
    else {
      verdict = "inconclusive"
    }  // An errno is NOT OS sandbox attribution.
    return [
      "runID": runID, "caseID": actor + "." + alias + "." + operation,
      "fixtureID": alias, "actorInstanceRef": actor, "operation": operation,
      "ownerPre": "unverified", "ownerPost": "unverified",
      "sameUIDControl": "unverified", "expectedRootMatched": matched,
      "posixACLControl": "unverified", "syscallResult": result, "errno": Int(error),
      "sandboxDenialRef": NSNull(), "promptObserved": "unverified", "verdict": verdict,
    ]
  }

  static func probe(
    runID: String, actor: String, alias: String, operation: String,
    symlinkDirectory: Int32? = nil
  ) -> [String: Any] {
    guard let target = path(alias, runID: runID) else {
      return observation(
        runID: runID, actor: actor, alias: alias, operation: operation,
        result: -1, matched: false)
    }
    var fd: Int32 = -1
    var openError: Int32 = 0
    var verification: Int32 = -1
    defer { if verification >= 0 { close(verification) } }
    if operation == "symlinkRead" {
      guard let directory = symlinkDirectory else {
        return observation(
          runID: runID, actor: actor, alias: alias, operation: operation,
          result: -1, matched: false)
      }
      let name = alias + ".link"
      guard symlinkat(target, directory, name) == 0 else {
        return observation(
          runID: runID, actor: actor, alias: alias, operation: operation,
          result: -1, error: errno)
      }
      defer { unlinkat(directory, name, 0) }
      fd = openat(directory, name, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
      openError = fd < 0 ? errno : 0
    } else {
      // Never create or truncate a target. All fixed-path ancestors are
      // opened without following symlinks; only our explicit link is followed.
      let url = URL(fileURLWithPath: target)
      guard let directory = directory(url.deletingLastPathComponent(), create: false) else {
        return observation(
          runID: runID, actor: actor, alias: alias, operation: operation,
          result: -1, error: errno)
      }
      defer { close(directory) }
      fd = openat(
        directory, url.lastPathComponent,
        (operation == "write" ? O_WRONLY : O_RDONLY) | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
      openError = fd < 0 ? errno : 0
      if fd >= 0 && operation == "write" {
        verification = openat(
          directory, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
      }
    }
    guard fd >= 0 else {
      return observation(
        runID: runID, actor: actor, alias: alias, operation: operation,
        result: -1, error: openError)
    }
    defer { close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
      info.st_nlink == 1, info.st_size > 0, info.st_size <= 4096
    else {
      return observation(
        runID: runID, actor: actor, alias: alias, operation: operation,
        result: -1, matched: false)
    }
    if operation == "write" {
      let expected = marker(alias, runID: runID)
      var bytes = [UInt8](repeating: 0, count: expected.count)
      var verificationInfo = stat()
      // Probe write permission independently. If it unexpectedly succeeds,
      // verify the public marker through a second descriptor before writing
      // its first byte unchanged. Never mutate an unverified/replaced file.
      guard verification >= 0, fstat(verification, &verificationInfo) == 0,
        verificationInfo.st_ino == info.st_ino, verificationInfo.st_dev == info.st_dev,
        info.st_size == expected.count, pread(verification, &bytes, bytes.count, 0) == bytes.count,
        Data(bytes) == expected
      else {
        return observation(
          runID: runID, actor: actor, alias: alias, operation: operation,
          result: -1, matched: false)
      }
    }
    var byte = marker(alias, runID: runID).first!
    let result = operation == "write" ? pwrite(fd, &byte, 1, 0) : pread(fd, &byte, 1, 0)
    return observation(
      runID: runID, actor: actor, alias: alias, operation: operation,
      result: result, error: result < 0 ? errno : 0)
  }

  static func network(runID: String, actor: String, expectAllowed: Bool) -> [String: Any] {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    var row = observation(
      runID: runID, actor: actor, alias: "network", operation: "connect",
      result: -1, error: fd < 0 ? errno : 0)
    guard fd >= 0 else { return row }
    defer { close(fd) }
    var noSignal: Int32 = 1
    guard
      setsockopt(
        fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal)))
        == 0,
      fcntl(fd, F_SETFL, O_NONBLOCK) >= 0
    else {
      row["errno"] = Int(errno)
      row["verdict"] = "inconclusive"
      return row
    }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = UInt16(18765).bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let start = DispatchTime.now().uptimeNanoseconds
    func wait(_ events: Int16) -> Bool {
      let elapsed = (DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
      guard elapsed < 2000 else { return false }
      var descriptor = pollfd(fd: fd, events: events, revents: 0)
      return poll(&descriptor, 1, Int32(2000 - elapsed)) > 0
    }
    var result = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    var code: Int32 = result < 0 ? errno : 0
    if result < 0 && code == EINPROGRESS {
      if wait(Int16(POLLOUT)) {
        var size = socklen_t(MemoryLayout<Int32>.size)
        if getsockopt(fd, SOL_SOCKET, SO_ERROR, &code, &size) == 0 {
          result = code == 0 ? 0 : -1
        } else {
          code = errno
        }
      } else {
        code = ETIMEDOUT
      }
    }
    row = observation(
      runID: runID, actor: actor, alias: "network", operation: "connect",
      result: Int(result), error: code)
    if expectAllowed && result == 0 {
      var sent = 0
      while sent < nonce.count && wait(Int16(POLLOUT)) {
        let count = nonce.withUnsafeBytes {
          send(fd, $0.baseAddress!.advanced(by: sent), nonce.count - sent, 0)
        }
        guard count > 0 else { break }
        sent += count
      }
      var response = Data()
      while response.count < nonce.count && wait(Int16(POLLIN)) {
        var bytes = [UInt8](repeating: 0, count: nonce.count - response.count)
        let count = recv(fd, &bytes, bytes.count, 0)
        guard count > 0 else { break }
        response.append(contentsOf: bytes.prefix(count))
      }
      row["verdict"] = sent == nonce.count && response == nonce ? "pass" : "inconclusive"
    }
    return row
  }

  static func json(_ value: [String: Any]) -> Data {
    // All callers construct closed, finite, path-free dictionaries.
    (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]))
      ?? Data("{\"status\":\"failed\"}".utf8)
  }
}

// An instance owns only an exclusively created run directory. Cleanup never
// traverses or removes a pre-existing run, and never recursively removes trees.
final class TopologyOwnedFixtures: @unchecked Sendable {
  let runID: String
  let descriptor: Int32
  private let parent: Int32
  private let directoryInode: ino_t
  private var files: [(String, Data, ino_t)] = []
  private var cleaned = false

  init?(root: URL, runID: String) {
    guard TopologyFixtures.validRunID(runID),
      let parent = TopologyFixtures.directory(root, create: true)
    else { return nil }
    guard mkdirat(parent, runID, 0o700) == 0 else {
      close(parent)
      return nil
    }
    let fd = openat(parent, runID, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else {
      unlinkat(parent, runID, AT_REMOVEDIR)
      close(parent)
      return nil
    }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o777 == 0o700 else {
      close(fd)
      close(parent)
      return nil
    }
    self.parent = parent
    directoryInode = info.st_ino
    descriptor = fd
    self.runID = runID
  }

  func create(_ alias: String) -> Bool {
    let names = ["M": "db.canary", "PDF": "input.pdf", "G": "group.canary"]
    guard let name = names[alias] else { return false }
    let bytes = TopologyFixtures.marker(alias, runID: runID)
    let fd = openat(descriptor, name, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0 else {
      unlinkat(descriptor, name, 0)
      return false
    }
    files.append((name, bytes, info.st_ino))
    return bytes.withUnsafeBytes { pwrite(fd, $0.baseAddress!, bytes.count, 0) } == bytes.count
  }

  func readOnlyPDF() -> FileHandle? {
    guard let item = files.first(where: { $0.0 == "input.pdf" }) else { return nil }
    let fd = openat(descriptor, "input.pdf", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { return nil }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_ino == item.2, info.st_mode & S_IFMT == S_IFREG,
      info.st_nlink == 1, info.st_uid == getuid(), info.st_size == item.1.count
    else {
      close(fd)
      return nil
    }
    return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
  }

  func check() -> Bool {
    guard !cleaned, !files.isEmpty else { return false }
    return files.allSatisfy { name, expected, inode in
      let fd = openat(descriptor, name, O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
      guard fd >= 0 else { return false }
      defer { close(fd) }
      var info = stat()
      guard fstat(fd, &info) == 0, info.st_ino == inode, info.st_uid == getuid(),
        info.st_mode & 0o777 == 0o600, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
        info.st_size == expected.count
      else { return false }
      var bytes = [UInt8](repeating: 0, count: expected.count)
      guard pread(fd, &bytes, bytes.count, 0) == bytes.count, Data(bytes) == expected else {
        return false
      }
      // Verify existing-file write permission only after checking integrity.
      var byte = bytes[0]
      return pwrite(fd, &byte, 1, 0) == 1
    }
  }

  @discardableResult func cleanup() -> Bool {
    guard !cleaned else { return true }
    var success = true
    for (name, _, inode) in files {
      var info = stat()
      if fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 {
        if info.st_ino != inode || info.st_mode & S_IFMT != S_IFREG {
          success = false
          continue
        }
        if unlinkat(descriptor, name, 0) != 0 { success = false }
      } else if errno != ENOENT {
        success = false
      }
    }
    var info = stat()
    if fstatat(parent, runID, &info, AT_SYMLINK_NOFOLLOW) != 0 || info.st_ino != directoryInode {
      success = false
    } else if unlinkat(parent, runID, AT_REMOVEDIR) != 0 {
      success = false
    }
    cleaned = true
    return success
  }

  deinit {
    cleanup()
    close(descriptor)
    close(parent)
  }
}
