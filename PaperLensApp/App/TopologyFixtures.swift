import CoreFoundation
import CryptoKit
import Darwin
import Foundation

// Independent CODE-artifact identities, supplied by setup before SQLite opens.
// Unlike canary fixtures, these descriptors never authorize automatic deletion.
struct TopologyDBOwnerContext: @unchecked Sendable {
  let worktreePath: String
  let worktree: Int32
  let topology: Int32
  let namespace: Int32
  let worktreeIdentity: stat
  let topologyIdentity: stat
  let namespaceIdentity: stat
  let databaseIdentity: stat
  let uid: uid_t
  let ownerID: String
  let runID: String
  let attemptID: String
  var entry: String { "local-grdb-probe-" + runID }
  var databasePath: String { worktreePath + "/.build/topology/" + entry + "/db.sqlite" }

  func validateDirectory() -> Bool {
    guard uid == getuid(), uid == geteuid(), TopologyFixtures.validRunID(runID),
      TopologyFixtures.validRunID(ownerID), TopologyFixtures.validRunID(attemptID),
      worktreePath.hasPrefix("/"),
      URL(fileURLWithPath: worktreePath).standardizedFileURL.path == worktreePath
    else { return false }
    func same(_ fd: Int32, _ expected: stat, privateMode: Bool) -> Bool {
      var current = stat()
      guard fstat(fd, &current) == 0, current.st_dev == expected.st_dev,
        current.st_ino == expected.st_ino, current.st_uid == uid,
        expected.st_uid == uid, current.st_mode & S_IFMT == S_IFDIR
      else { return false }
      return !privateMode || TopologyFixtures.privateDirectory(fd, info: &current)
    }
    guard same(worktree, worktreeIdentity, privateMode: false),
      same(topology, topologyIdentity, privateMode: false),
      same(namespace, namespaceIdentity, privateMode: true),
      TopologyFixtures.matches(directory: topology, name: entry, info: namespaceIdentity),
      let root = TopologyFixtures.directory(URL(fileURLWithPath: worktreePath), create: false)
    else { return false }
    defer { close(root) }
    guard same(root, worktreeIdentity, privateMode: false),
      let parent = TopologyFixtures.directory(
        URL(fileURLWithPath: worktreePath + "/.build/topology"), create: false)
    else { return false }
    defer { close(parent) }
    return same(parent, topologyIdentity, privateMode: false)
      && TopologyFixtures.matches(directory: parent, name: entry, info: namespaceIdentity)
  }

  func validate() -> Bool {
    validateDirectory() && validateFile("db.sqlite", identity: databaseIdentity)
      && validateDirectory()
  }

  func validateFile(_ name: String, identity: stat) -> Bool {
    var current = stat()
    return identity.st_uid == uid
      && TopologyFixtures.privateNamedFile(
        directory: namespace, name: name,
        path: worktreePath + "/.build/topology/" + entry + "/" + name, info: &current)
      && current.st_dev == identity.st_dev && current.st_ino == identity.st_ino
      && TopologyFixtures.matches(directory: namespace, name: name, info: identity)
  }

  func entries() -> Set<String>? {
    let fd = openat(namespace, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { return nil }
    guard let directory = fdopendir(fd) else {
      close(fd)
      return nil
    }
    defer { closedir(directory) }
    var result = Set<String>()
    errno = 0
    while let entry = readdir(directory) {
      let name = withUnsafePointer(to: &entry.pointee.d_name) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
          String(cString: $0)
        }
      }
      if name != "." && name != ".." { result.insert(name) }
      if result.count > 4 { return nil }
      errno = 0
    }
    return errno == 0 ? result : nil
  }
}

@objc protocol PDFTopologyService {
  func identify(_ runID: String, withReply reply: @escaping (Data) -> Void)
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
      lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == uid
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
    var owned = stat()
    guard privateFile(fd, info: &owned) else {
      removeOwned(directory: directory, name: temporary, info: owned)
      close(fd)
      return false
    }
    defer {
      close(fd)
      removeOwned(directory: directory, name: temporary, info: owned)
    }
    guard writeAll(report, descriptor: fd), sync(fd),
      matches(directory: directory, name: temporary, info: owned),
      privateFile(fd, info: &owned)
    else { return false }
    // Publication cannot replace a prior report, even if it races the verifier.
    return renameatx_np(directory, temporary, directory, "report.json", UInt32(RENAME_EXCL)) == 0
  }

  static func writeAll(_ data: Data, descriptor: Int32) -> Bool {
    data.withUnsafeBytes { bytes -> Bool in
      var offset = 0
      while offset < bytes.count {
        let count = Darwin.write(
          descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else { return false }
        offset += count
      }
      return true
    }
  }

  static func sync(_ descriptor: Int32) -> Bool {
    while fsync(descriptor) != 0 {
      if errno != EINTR { return false }
    }
    return true
  }

  static func emptyACL(_ descriptor: Int32) -> Bool {
    guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
      return errno == ENOENT
    }
    return emptyACLValue(acl)
  }

  private static func emptyACLValue(_ acl: acl_t) -> Bool {
    defer { acl_free(UnsafeMutableRawPointer(acl)) }
    var entry: acl_entry_t?
    errno = 0
    let result = acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry)
    return result == -1 && errno == EINVAL
  }

  static func privateDirectory(_ descriptor: Int32, info: inout stat) -> Bool {
    fstat(descriptor, &info) == 0 && info.st_uid == getuid()
      && info.st_mode & S_IFMT == S_IFDIR && info.st_mode & 0o7777 == 0o700
      && info.st_nlink >= 2 && emptyACL(descriptor)
  }

  static func privateFile(_ descriptor: Int32, info: inout stat) -> Bool {
    fstat(descriptor, &info) == 0 && privateFileIdentity(info) && emptyACL(descriptor)
  }

  private static func privateFileIdentity(_ info: stat) -> Bool {
    info.st_uid == getuid() && info.st_mode & S_IFMT == S_IFREG
      && info.st_mode & 0o7777 == 0o600 && info.st_nlink == 1
  }

  // Do not open/close an auxiliary DB or SHM descriptor while SQLite is live:
  // closing another descriptor can release process-owned POSIX file locks.
  // ACL lookup is the public no-follow named metadata API. The caller must
  // validate its retained namespace/path before and after these checks.
  static func privateNamedFile(
    directory: Int32, name: String, path: String,
    info: inout stat
  ) -> Bool {
    guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
      privateFileIdentity(info)
    else { return false }
    guard let acl = acl_get_link_np(path, ACL_TYPE_EXTENDED) else { return errno == ENOENT }
    return emptyACLValue(acl)
  }

  static func matches(directory: Int32, name: String, info: stat) -> Bool {
    var current = stat()
    return fstatat(directory, name, &current, AT_SYMLINK_NOFOLLOW) == 0
      && current.st_dev == info.st_dev && current.st_ino == info.st_ino
      && current.st_mode & S_IFMT == info.st_mode & S_IFMT
  }

  @discardableResult static func removeOwned(directory: Int32, name: String, info: stat) -> Bool {
    guard matches(directory: directory, name: name, info: info) else { return false }
    return unlinkat(directory, name, 0) == 0
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
    result: Int, error: Int32 = 0, matched: Bool = true,
    observed: Bool = false, beganAtNs: Int64 = 0, endedAtNs: Int64 = 0
  ) -> [String: Any] {
    let verdict: String
    if !observed || !matched || error == ENOENT {
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
      "posixACLControl": "unverified", "syscallResult": observed ? result : 0,
      "errno": observed ? Int(error) : 0,
      "sandboxDenialRef": NSNull(), "promptObserved": "unverified", "verdict": verdict,
      "syscallObserved": observed, "beganAtNs": observed ? beganAtNs : Int64(0),
      "endedAtNs": observed ? endedAtNs : Int64(0),
      "intervalRef": actor + "." + alias + "." + operation,
    ]
  }

  static func probe(
    runID: String, actor: String, alias: String, operation: String,
    symlinkDirectory: Int32? = nil
  ) -> [String: Any] {
    guard ["read", "write", "symlinkRead"].contains(operation),
      let target = path(alias, runID: runID)
    else {
      return observation(
        runID: runID, actor: actor, alias: alias, operation: operation,
        result: -1, matched: false)
    }
    var fd: Int32 = -1
    var openError: Int32 = 0
    var verification: Int32 = -1
    var began: Int64 = 0
    var ended: Int64 = 0
    defer { if verification >= 0 { close(verification) } }
    if operation == "symlinkRead" {
      guard let directory = symlinkDirectory else {
        return observation(
          runID: runID, actor: actor, alias: alias, operation: operation,
          result: -1, matched: false)
      }
      let name = alias + ".link"
      var linkInfo = stat()
      var linkBytes = [UInt8](repeating: 0, count: 4096)
      let length = readlinkat(directory, name, &linkBytes, linkBytes.count)
      guard fstatat(directory, name, &linkInfo, AT_SYMLINK_NOFOLLOW) == 0,
        linkInfo.st_mode & S_IFMT == S_IFLNK, linkInfo.st_uid == getuid(),
        linkInfo.st_nlink == 1, length > 0,
        String(bytes: linkBytes.prefix(length), encoding: .utf8) == target
      else {
        return observation(
          runID: runID, actor: actor, alias: alias, operation: operation,
          result: -1, matched: false)
      }
      began = Int64(DispatchTime.now().uptimeNanoseconds)
      fd = openat(directory, name, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
      openError = fd < 0 ? errno : 0
      ended = Int64(DispatchTime.now().uptimeNanoseconds)
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
      began = Int64(DispatchTime.now().uptimeNanoseconds)
      fd = openat(
        directory, url.lastPathComponent,
        (operation == "write" ? O_WRONLY : O_RDONLY) | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
      openError = fd < 0 ? errno : 0
      ended = Int64(DispatchTime.now().uptimeNanoseconds)
      if fd >= 0 && operation == "write" {
        verification = openat(
          directory, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
      }
    }
    guard fd >= 0 else {
      return observation(
        runID: runID, actor: actor, alias: alias, operation: operation,
        result: -1, error: openError, observed: true, beganAtNs: began, endedAtNs: ended)
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
    began = Int64(DispatchTime.now().uptimeNanoseconds)
    let result = operation == "write" ? pwrite(fd, &byte, 1, 0) : pread(fd, &byte, 1, 0)
    let code = result < 0 ? errno : 0
    ended = Int64(DispatchTime.now().uptimeNanoseconds)
    return observation(
      runID: runID, actor: actor, alias: alias, operation: operation,
      result: result, error: code, observed: true, beganAtNs: began, endedAtNs: ended)
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
    let began = Int64(DispatchTime.now().uptimeNanoseconds)
    let result = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    let code: Int32 = result < 0 ? errno : 0
    let ended = Int64(DispatchTime.now().uptimeNanoseconds)
    var connected = result == 0
    if result < 0 && code == EINPROGRESS {
      if wait(Int16(POLLOUT)) {
        var size = socklen_t(MemoryLayout<Int32>.size)
        var socketError: Int32 = 0
        connected =
          getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &size) == 0
          && socketError == 0
      }
    }
    row = observation(
      runID: runID, actor: actor, alias: "network", operation: "connect",
      result: Int(result), error: code, observed: true, beganAtNs: began, endedAtNs: ended)
    if !expectAllowed && connected {
      // Preserve the original connect tuple, including EINPROGRESS, while
      // separately recording a completed forbidden connection as failure.
      row["verdict"] = "failed"
    }
    if expectAllowed && connected {
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
      let echoed = sent == nonce.count && response == nonce
      row["echoMatched"] = echoed
      row["verdict"] = echoed ? "pass" : "inconclusive"
    }
    return row
  }

  static func json(_ value: [String: Any]) -> Data {
    // All callers construct closed, finite, path-free dictionaries.
    (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]))
      ?? Data("{\"status\":\"failed\"}".utf8)
  }
}

// A reservation never adopts or removes a prior namespace, including on failure.
final class TopologyReportReservation: @unchecked Sendable {
  let descriptor: Int32
  let directoryURL: URL
  private let root: Int32
  private let parent: Int32
  private let runID: String
  private let identity: stat
  private let parentIdentity: stat

  init?(container: URL, runID: String) {
    guard TopologyFixtures.validRunID(runID),
      let root = TopologyFixtures.directory(
        container.appendingPathComponent("Library/Application Support/PaperLensTopology"),
        create: true)
    else { return nil }
    if mkdirat(root, "Reports", 0o700) != 0 && errno != EEXIST {
      close(root)
      return nil
    }
    let parent = openat(root, "Reports", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard parent >= 0 else {
      close(root)
      return nil
    }
    var parentInfo = stat()
    guard TopologyFixtures.privateDirectory(parent, info: &parentInfo),
      TopologyFixtures.matches(directory: root, name: "Reports", info: parentInfo),
      mkdirat(parent, runID, 0o700) == 0
    else {
      close(parent)
      close(root)
      return nil
    }
    let descriptor = openat(parent, runID, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    var info = stat()
    guard descriptor >= 0, TopologyFixtures.privateDirectory(descriptor, info: &info),
      TopologyFixtures.matches(directory: parent, name: runID, info: info)
    else {
      if descriptor >= 0 { close(descriptor) }
      close(parent)
      close(root)
      return nil
    }
    self.descriptor = descriptor
    self.root = root
    self.parent = parent
    self.runID = runID
    identity = info
    parentIdentity = parentInfo
    directoryURL = container.appendingPathComponent(
      "Library/Application Support/PaperLensTopology/Reports/" + runID, isDirectory: true)
  }

  func publish(_ data: Data) -> Bool {
    var current = stat()
    var currentParent = stat()
    guard TopologyFixtures.privateDirectory(descriptor, info: &current),
      current.st_dev == identity.st_dev, current.st_ino == identity.st_ino,
      TopologyFixtures.privateDirectory(parent, info: &currentParent),
      currentParent.st_dev == parentIdentity.st_dev,
      currentParent.st_ino == parentIdentity.st_ino,
      TopologyFixtures.matches(directory: root, name: "Reports", info: parentIdentity),
      TopologyFixtures.matches(directory: parent, name: runID, info: identity)
    else { return false }
    return TopologyFixtures.publishReport(data, directory: descriptor)
  }

  deinit {
    close(descriptor)
    close(parent)
    close(root)
  }
}

enum TopologyReadiness {
  static var contractHash: String? {
    guard let url = Bundle.main.url(forResource: "contract", withExtension: "json"),
      let data = try? Data(contentsOf: url)
    else { return nil }
    return hash(data)
  }

  static func hash(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func integer(_ value: Any?) -> Int64? {
    guard let number = value as? NSNumber,
      CFGetTypeID(number) != CFBooleanGetTypeID(),
      ["c", "s", "i", "l", "q", "C", "S", "I", "L", "Q"].contains(
        String(cString: number.objCType)),
      number.decimalValue >= 0, number.decimalValue <= Decimal(Int64.max)
    else { return nil }
    return number.int64Value
  }

  private static func ack(_ bytes: Data) -> [String: String]? {
    guard String(data: bytes, encoding: .utf8) != nil,
      let value = try? JSONSerialization.jsonObject(with: bytes) as? [String: String],
      Set(value.keys) == Set(["schemaRevision", "runID", "phase", "readyHash", "artifactHash"])
    else { return nil }
    // Foundation collapses duplicate JSON keys. Every value in this closed
    // object is a string, so five unquoted separators also reject duplicates.
    var quoted = false
    var escaped = false
    var separators = 0
    for byte in bytes {
      if quoted {
        if escaped {
          escaped = false
        } else if byte == 92 {
          escaped = true
        } else if byte == 34 {
          quoted = false
        }
      } else if byte == 34 {
        quoted = true
      } else if byte == 58 {
        separators += 1
      }
    }
    return separators == 5 ? value : nil
  }

  private static let providerCaseIDs: Set<String> = {
    guard let url = Bundle.main.url(forResource: "contract", withExtension: "json"),
      let bytes = try? Data(contentsOf: url),
      let value = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
      let definitions = value["definitions"] as? [String: Any],
      let schema = definitions["caseID"] as? [String: Any],
      let cases = schema["enum"] as? [String]
    else { return [] }
    return Set(cases)
  }()

  private static func validCaseID(_ value: String) -> Bool {
    if providerCaseIDs.contains(value) { return true }
    if ["Main.pre.network.connect", "Main.post.network.connect"].contains(value) { return true }
    let parts = value.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3, ["Main", "PDFiumXPC"].contains(String(parts[0])),
      (TopologyFixtures.aliases + ["network"]).contains(String(parts[1]))
    else { return false }
    if ["descriptorRead", "descriptorWrite"].contains(String(parts[2])) {
      return parts[0] == "PDFiumXPC" && parts[1] == "PDF"
    }
    return ["read", "write", "symlinkRead", "connect"].contains(String(parts[2]))
  }

  static func fence(
    directory: Int32, runID: String, phase: String, actors: [[String: Any]],
    links: [[String: String]], intervals: [[String: Any]], ownerControl: Bool,
    timeoutMs: Int, completion: @escaping @Sendable (Bool) -> Void
  ) {
    let roles = Set(["Main", "ProviderAgent", "Python", "PDFiumXPC"])
    guard TopologyFixtures.validRunID(runID), ["pre", "post"].contains(phase),
      timeoutMs > 0, timeoutMs <= 10_000, let contractHash,
      !actors.isEmpty, actors.count <= roles.count,
      Set(actors.compactMap { $0["role"] as? String }).count == actors.count,
      actors.allSatisfy({ actor in
        guard Set(actor.keys) == Set(["role", "pid"]), let role = actor["role"] as? String,
          roles.contains(role), let pid = integer(actor["pid"])
        else { return false }
        return pid > 0 && pid <= Int64(Int32.max)
      }),
      Set(links.compactMap { $0["alias"] }).count == links.count,
      links.allSatisfy({ link in
        guard Set(link.keys) == Set(["alias", "name"]), let alias = link["alias"] else {
          return false
        }
        return TopologyFixtures.aliases.contains(alias) && link["name"] == alias + ".link"
      }),
      Set(intervals.compactMap { $0["caseID"] as? String }).count == intervals.count,
      intervals.allSatisfy({ interval in
        guard Set(interval.keys) == Set(["caseID", "beganAtNs", "endedAtNs"]),
          let caseID = interval["caseID"] as? String,
          let began = integer(interval["beganAtNs"]),
          let ended = integer(interval["endedAtNs"])
        else { return false }
        return validCaseID(caseID)
          && began <= ended && ((began == 0) == (ended == 0))
      })
    else {
      completion(false)
      return
    }
    let bytes = TopologyFixtures.json([
      "schemaRevision": "topology-readiness-v1", "runID": runID, "phase": phase,
      "contractHash": contractHash, "clock": "darwin-uptime-ns", "actors": actors,
      "links": links, "intervals": intervals, "ownerControl": ownerControl,
    ])
    guard bytes.count <= 64 * 1024,
      let fence = Fence(
        directory: directory, runID: runID, phase: phase,
        bytes: bytes, timeoutMs: timeoutMs, completion: completion)
    else {
      completion(false)
      return
    }
    fence.start()
  }

  private final class Fence: @unchecked Sendable {
    private let directory: Int32
    private let directoryInfo: stat
    private let readyInfo: stat
    private let readyName: String
    private let ackName: String
    private let readyHash: String
    private let runID: String
    private let phase: String
    private let deadline: UInt64
    private let completion: @Sendable (Bool) -> Void
    private let timer: DispatchSourceTimer
    private var finished = false
    private var acknowledged: stat?
    private var acknowledgedHash: String?
    private var readyRemoved = false

    init?(
      directory: Int32, runID: String, phase: String, bytes: Data,
      timeoutMs: Int, completion: @escaping @Sendable (Bool) -> Void
    ) {
      let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeoutMs) * 1_000_000
      let directory = fcntl(directory, F_DUPFD_CLOEXEC, 0)
      guard directory >= 0 else { return nil }
      var directoryInfo = stat()
      let readyName = phase == "pre" ? "ready.json" : "post-ready.json"
      let ackName = phase == "pre" ? "continue.json" : "post-continue.json"
      var existing = stat()
      guard TopologyFixtures.privateDirectory(directory, info: &directoryInfo),
        fstatat(directory, ackName, &existing, AT_SYMLINK_NOFOLLOW) == -1, errno == ENOENT
      else {
        close(directory)
        return nil
      }
      let temporary = UUID().uuidString.lowercased() + ".ready"
      let fd = openat(
        directory, temporary,
        O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
      guard fd >= 0 else {
        close(directory)
        return nil
      }
      var readyInfo = stat()
      let safe =
        TopologyFixtures.privateFile(fd, info: &readyInfo)
        && TopologyFixtures.writeAll(bytes, descriptor: fd) && TopologyFixtures.sync(fd)
        && TopologyFixtures.matches(directory: directory, name: temporary, info: readyInfo)
        && renameatx_np(directory, temporary, directory, readyName, UInt32(RENAME_EXCL)) == 0
        && TopologyFixtures.matches(directory: directory, name: readyName, info: readyInfo)
      close(fd)
      guard safe else {
        TopologyFixtures.removeOwned(directory: directory, name: temporary, info: readyInfo)
        TopologyFixtures.removeOwned(directory: directory, name: readyName, info: readyInfo)
        close(directory)
        return nil
      }
      self.directory = directory
      self.directoryInfo = directoryInfo
      self.readyInfo = readyInfo
      self.readyName = readyName
      self.ackName = ackName
      readyHash = TopologyReadiness.hash(bytes)
      self.runID = runID
      self.phase = phase
      self.deadline = deadline
      self.completion = completion
      timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "topology.readiness"))
    }

    func start() {
      timer.setEventHandler { [self] in poll() }
      timer.schedule(deadline: .now(), repeating: .milliseconds(20))
      timer.resume()
    }

    private func read(_ name: String, expected: stat? = nil) -> Data? {
      let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
      guard fd >= 0 else { return nil }
      defer { close(fd) }
      var before = stat()
      guard TopologyFixtures.privateFile(fd, info: &before), before.st_size > 0,
        before.st_size <= 64 * 1024,
        expected == nil || (before.st_dev == expected!.st_dev && before.st_ino == expected!.st_ino),
        TopologyFixtures.matches(directory: directory, name: name, info: before)
      else { return nil }
      var bytes = [UInt8](repeating: 0, count: Int(before.st_size))
      let complete = bytes.withUnsafeMutableBytes { buffer -> Bool in
        var offset = 0
        while offset < buffer.count {
          let count = pread(
            fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, off_t(offset))
          if count < 0 && errno == EINTR { continue }
          guard count > 0 else { return false }
          offset += count
        }
        return true
      }
      var after = stat()
      guard complete, TopologyFixtures.privateFile(fd, info: &after),
        before.st_ino == after.st_ino, before.st_dev == after.st_dev,
        before.st_size == after.st_size, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
        before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
        TopologyFixtures.matches(directory: directory, name: name, info: after)
      else { return nil }
      return Data(bytes)
    }

    private func poll() {
      guard !finished else { return }
      var current = stat()
      guard DispatchTime.now().uptimeNanoseconds < deadline,
        TopologyFixtures.privateDirectory(directory, info: &current),
        current.st_dev == directoryInfo.st_dev, current.st_ino == directoryInfo.st_ino
      else {
        finish(false)
        return
      }
      if let acknowledged {
        var unexpectedReady = stat()
        guard fstatat(directory, readyName, &unexpectedReady, AT_SYMLINK_NOFOLLOW) == -1,
          errno == ENOENT
        else {
          finish(false)
          return
        }
        var currentAck = stat()
        if fstatat(directory, ackName, &currentAck, AT_SYMLINK_NOFOLLOW) != 0 {
          finish(errno == ENOENT)
          return
        }
        guard let bytes = read(ackName, expected: acknowledged),
          TopologyReadiness.hash(bytes) == acknowledgedHash
        else {
          finish(false)
          return
        }
        return
      }
      guard let ready = read(readyName, expected: readyInfo),
        TopologyReadiness.hash(ready) == readyHash
      else {
        finish(false)
        return
      }
      var info = stat()
      if fstatat(directory, ackName, &info, AT_SYMLINK_NOFOLLOW) != 0 {
        if errno != ENOENT { finish(false) }
        return
      }
      guard let bytes = read(ackName, expected: info),
        let ack = TopologyReadiness.ack(bytes),
        ack["schemaRevision"] == "topology-readiness-v1", ack["runID"] == runID,
        ack["phase"] == phase, ack["readyHash"] == readyHash,
        let artifact = ack["artifactHash"], artifact.utf8.count == 64,
        artifact.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
      else {
        finish(false)
        return
      }
      guard TopologyFixtures.removeOwned(directory: directory, name: readyName, info: readyInfo)
      else {
        finish(false)
        return
      }
      readyRemoved = true
      acknowledged = info
      acknowledgedHash = TopologyReadiness.hash(bytes)
    }

    private func finish(_ success: Bool) {
      guard !finished else { return }
      finished = true
      timer.setEventHandler {}
      timer.cancel()
      let removed =
        readyRemoved
        || TopologyFixtures.removeOwned(directory: directory, name: readyName, info: readyInfo)
      close(directory)
      completion(success && removed)
    }
  }
}

// An instance owns only an exclusively created run directory. Cleanup never
// traverses or removes a pre-existing run, and never recursively removes trees.
final class TopologyOwnedFixtures: @unchecked Sendable {
  let runID: String
  let descriptor: Int32
  private let parent: Int32
  private let directoryInode: ino_t
  private let directoryDevice: dev_t
  private var files: [(String, Data, ino_t, dev_t)] = []
  private var ownedLinks: [(alias: String, target: String, info: stat)] = []
  var links: [[String: String]] {
    ownedLinks.map { ["alias": $0.alias, "name": $0.alias + ".link"] }
  }
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
      close(parent)
      return nil
    }
    var info = stat()
    guard TopologyFixtures.privateDirectory(fd, info: &info),
      TopologyFixtures.matches(directory: parent, name: runID, info: info)
    else {
      close(fd)
      close(parent)
      return nil
    }
    self.parent = parent
    directoryInode = info.st_ino
    directoryDevice = info.st_dev
    descriptor = fd
    self.runID = runID
  }

  func prepareLinks(_ aliases: [String]) -> Bool {
    guard !cleaned, ownedLinks.isEmpty, !aliases.isEmpty,
      Set(aliases).count == aliases.count,
      aliases.allSatisfy({ TopologyFixtures.aliases.contains($0) })
    else { return false }
    for alias in aliases {
      guard let target = TopologyFixtures.path(alias, runID: runID),
        symlinkat(target, descriptor, alias + ".link") == 0
      else { return false }
      var info = stat()
      guard fstatat(descriptor, alias + ".link", &info, AT_SYMLINK_NOFOLLOW) == 0,
        info.st_mode & S_IFMT == S_IFLNK, info.st_uid == getuid(), info.st_nlink == 1
      else { return false }
      ownedLinks.append((alias, target, info))
    }
    return checkLinks()
  }

  func checkLinks() -> Bool {
    var info = stat()
    guard !cleaned, !ownedLinks.isEmpty,
      TopologyFixtures.privateDirectory(descriptor, info: &info),
      info.st_ino == directoryInode, info.st_dev == directoryDevice
    else { return false }
    return ownedLinks.allSatisfy { link in
      var current = stat()
      var bytes = [UInt8](repeating: 0, count: 4096)
      let name = link.alias + ".link"
      guard fstatat(descriptor, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
        current.st_dev == link.info.st_dev, current.st_ino == link.info.st_ino,
        current.st_mode & S_IFMT == S_IFLNK, current.st_uid == getuid(), current.st_nlink == 1
      else { return false }
      let count = readlinkat(descriptor, name, &bytes, bytes.count)
      return count > 0 && String(bytes: bytes.prefix(count), encoding: .utf8) == link.target
        && TopologyFixtures.matches(directory: descriptor, name: name, info: link.info)
    }
  }

  func create(_ alias: String) -> Bool {
    let names = ["M": "db.canary", "PDF": "input.pdf", "G": "group.canary"]
    guard let name = names[alias] else { return false }
    let bytes = TopologyFixtures.marker(alias, runID: runID)
    let fd = openat(descriptor, name, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    var info = stat()
    guard TopologyFixtures.privateFile(fd, info: &info) else {
      TopologyFixtures.removeOwned(directory: descriptor, name: name, info: info)
      return false
    }
    files.append((name, bytes, info.st_ino, info.st_dev))
    return TopologyFixtures.writeAll(bytes, descriptor: fd)
  }

  func readOnlyPDF() -> FileHandle? {
    guard let item = files.first(where: { $0.0 == "input.pdf" }) else { return nil }
    let fd = openat(descriptor, "input.pdf", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { return nil }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_ino == item.2, info.st_dev == item.3,
      info.st_mode & S_IFMT == S_IFREG,
      info.st_nlink == 1, info.st_uid == getuid(), info.st_size == item.1.count
    else {
      close(fd)
      return nil
    }
    return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
  }

  func check() -> Bool {
    guard !cleaned, !files.isEmpty else { return false }
    return files.allSatisfy { name, expected, inode, device in
      let fd = openat(descriptor, name, O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
      guard fd >= 0 else { return false }
      defer { close(fd) }
      var info = stat()
      guard fstat(fd, &info) == 0, info.st_ino == inode, info.st_dev == device,
        info.st_uid == getuid(),
        info.st_mode & 0o777 == 0o600, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
        info.st_size == expected.count, TopologyFixtures.emptyACL(fd)
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
    for link in ownedLinks {
      var info = stat()
      let name = link.alias + ".link"
      if fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 {
        if !TopologyFixtures.removeOwned(directory: descriptor, name: name, info: link.info) {
          success = false
        }
      } else if errno != ENOENT {
        success = false
      }
    }
    for (name, _, inode, device) in files {
      var info = stat()
      if fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 {
        if info.st_ino != inode || info.st_dev != device || info.st_mode & S_IFMT != S_IFREG {
          success = false
          continue
        }
        if unlinkat(descriptor, name, 0) != 0 { success = false }
      } else if errno != ENOENT {
        success = false
      }
    }
    var info = stat()
    if fstatat(parent, runID, &info, AT_SYMLINK_NOFOLLOW) != 0 || info.st_ino != directoryInode
      || info.st_dev != directoryDevice || info.st_mode & S_IFMT != S_IFDIR
    {
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
