import Darwin
import Darwin.bsm.libbsm
import Foundation

/// Stateless public-Darwin observations. No descriptor ownership, process ownership,
/// SDK authentication, signing acceptance, or cleanup authority lives here.
enum NativeBrokerABI {
  enum Failure: Error, Equatable {
    case syscall(String, Int32)
    case observation(String)
    case ancillary(String)
    case overflow
    case admission
  }

  static func align32(_ count: Int) throws -> Int {
    guard count >= 0 else { throw Failure.overflow }
    let mask = MemoryLayout<UInt32>.size - 1
    let (sum, overflow) = count.addingReportingOverflow(mask)
    guard !overflow else { throw Failure.overflow }
    return sum & ~mask
  }

  static var headerBytes: Int { MemoryLayout<cmsghdr>.size }
  static var dataOffset: Int { get throws { try align32(headerBytes) } }

  static func cmsgLen(_ payload: Int) throws -> Int {
    guard payload >= 0 else { throw Failure.overflow }
    let (length, overflow) = try dataOffset.addingReportingOverflow(payload)
    guard !overflow else { throw Failure.overflow }
    return length
  }

  static func cmsgSpace(_ payload: Int) throws -> Int {
    try cmsgLen(align32(payload))
  }

  /// The caller MUST retain this object in its existing operation root before
  /// recvmsg begins, including through unknown and late syscall completion.
  /// deinit releases only byte storage; it NEVER closes any descriptor.
  final class ReceiveStorage {
    let capacity: Int
    fileprivate let bytes: UnsafeMutableRawPointer
    fileprivate(set) var syscallResult: Int?
    fileprivate(set) var syscallErrno: Int32 = 0
    fileprivate(set) var flags: Int32 = 0
    fileprivate(set) var returnedControlBytes: Int = 0
    fileprivate(set) var marker: UInt8 = 0
    fileprivate(set) var capturedDescriptors: [Int32] = []

    init(controlCapacity: Int = 4096) throws {
      guard controlCapacity >= NativeBrokerABI.headerBytes,
        socklen_t(exactly: controlCapacity) != nil
      else {
        throw Failure.ancillary("invalid storage capacity")
      }
      capacity = controlCapacity
      bytes = .allocate(
        byteCount: controlCapacity,
        alignment: max(MemoryLayout<cmsghdr>.alignment, MemoryLayout<UInt32>.alignment))
      bytes.initializeMemory(as: UInt8.self, repeating: 0, count: controlCapacity)
      capturedDescriptors.reserveCapacity(controlCapacity / MemoryLayout<Int32>.size)
    }

    deinit { bytes.deallocate() }

    /// Includes the entire allocated buffer, even if returned metadata is invalid.
    var rawControlBytes: [UInt8] {
      Array(UnsafeRawBufferPointer(start: bytes, count: capacity))
    }
  }

  enum Offer: Equatable {
    case wouldBlock
    case descriptor(Int32)
  }

  /// Exactly one nonblocking recvmsg, reading only the offer byte. The nonthrowing
  /// callback may ONLY record metadata in the caller's existing FD authority.
  /// It runs for EVERY safely identifiable delivered right before any rejection,
  /// fstat, socket configuration, identity lookup, or caller admission decision.
  /// No error path closes, retries, or takes ownership of a descriptor.
  static func receiveOffer(
    socket: Int32, storage: ReceiveStorage, admit: () -> Bool, capture: (Int32) -> Void
  ) throws -> Offer {
    guard storage.syscallResult == nil else {
      throw Failure.ancillary("receive storage is single use")
    }
    var marker: UInt8 = 0
    var message = msghdr()
    guard admit() else { throw Failure.admission }
    let result = withUnsafeMutablePointer(to: &marker) { pointer in
      var vector = iovec(iov_base: pointer, iov_len: 1)
      return withUnsafeMutablePointer(to: &vector) { vectorPointer in
        message.msg_iov = vectorPointer
        message.msg_iovlen = 1
        message.msg_control = storage.bytes
        message.msg_controllen = socklen_t(storage.capacity)
        return recvmsg(socket, &message, MSG_DONTWAIT)
      }
    }
    let savedErrno = result < 0 ? errno : 0
    storage.syscallResult = result
    storage.syscallErrno = savedErrno
    storage.marker = marker
    storage.flags = message.msg_flags
    storage.returnedControlBytes = Int(message.msg_controllen)

    // Capture precedes ALL validation of returned flags, marker and shape.
    // Bounds are needed solely to avoid interpreting bytes outside public headers.
    let count = min(storage.capacity, storage.returnedControlBytes)
    let offset = try dataOffset  // Constant public layout, cannot overflow.
    var cursor = 0
    var malformed = storage.returnedControlBytes > storage.capacity
    var unexpectedHeader = false
    var rightsHeaders = 0
    while cursor <= count, count - cursor >= headerBytes {
      let header = storage.bytes.advanced(by: cursor).loadUnaligned(as: cmsghdr.self)
      let length = Int(header.cmsg_len)
      guard length >= offset else {
        malformed = true
        break
      }
      let available = count - cursor
      let payload = min(length, available) - offset
      if header.cmsg_level == SOL_SOCKET && header.cmsg_type == SCM_RIGHTS {
        rightsHeaders += 1
        if payload >= 0 {
          var index = 0
          while payload - index >= MemoryLayout<Int32>.size {
            let fd = storage.bytes.advanced(by: cursor + offset + index)
              .loadUnaligned(as: Int32.self)
            storage.capturedDescriptors.append(fd)
            capture(fd)
            index += MemoryLayout<Int32>.size
          }
          if payload % MemoryLayout<Int32>.size != 0 { malformed = true }
        }
      } else {
        unexpectedHeader = true
      }
      guard length <= available else {
        malformed = true
        break
      }
      // Public NXTHDR advances by ALIGN32(cmsg_len), then requires a whole
      // header. A final header need not include its trailing alignment padding.
      let step = try align32(length)
      guard step <= available else { break }
      cursor += step
      if count - cursor < headerBytes { break }
    }

    guard admit() else { throw Failure.admission }
    if result < 0 {
      if savedErrno == EAGAIN || savedErrno == EWOULDBLOCK { return .wouldBlock }
      throw Failure.syscall("recvmsg", savedErrno)
    }
    guard !malformed, !unexpectedHeader, count >= headerBytes,
      message.msg_flags & (MSG_CTRUNC | MSG_TRUNC) == 0,
      result == 1, marker == 0x42, rightsHeaders == 1,
      storage.capturedDescriptors.count == 1,
      let fd = storage.capturedDescriptors.first, fd >= 0
    else { throw Failure.ancillary("invalid descriptor offer; retain capture") }
    guard admit() else { throw Failure.admission }
    return .descriptor(fd)
  }

  struct ProcessSnapshot: Equatable {
    let pid: pid_t
    let parentPID: pid_t
    let uid: uid_t
    let gid: gid_t
    let birthSeconds: UInt64
    let birthMicroseconds: UInt64
  }

  struct PeerSnapshot {
    let uid: uid_t
    let gid: gid_t
    let pid: pid_t
    let pidVersion: Int32
    let token: audit_token_t
    let tokenBytes: [UInt8]

    func isSamePeer(as other: PeerSnapshot) -> Bool {
      uid == other.uid && gid == other.gid && pid == other.pid
        && pidVersion == other.pidVersion && tokenBytes == other.tokenBytes
    }
  }

  struct PeerObservation {
    let peer: PeerSnapshot
    let process: ProcessSnapshot
    let executablePath: String
  }

  /// Caller-retained metadata, rooted before any observation. Raw public values
  /// and actual results survive a post-syscall admission loss without more I/O.
  final class ObservationStorage {
    enum Record {
      case localID(String, UInt32)
      case credentials(Int32, Int32, uid_t, gid_t)
      case peerPID(Int32, Int32, socklen_t, pid_t)
      case peerToken(Int32, Int32, socklen_t, audit_token_t)
      case process(Int32, Int32, proc_bsdinfo)
      case path(Int32, Int32, [UInt8])
    }
    fileprivate(set) var records: [Record] = []
  }

  struct LocalCredentials {
    let realUID: uid_t
    let effectiveUID: uid_t
    let effectiveGID: gid_t
  }

  static func observeLocalCredentials(
    storage: ObservationStorage, admit: () -> Bool
  ) throws -> LocalCredentials {
    guard admit() else { throw Failure.admission }
    let real = getuid()
    storage.records.append(.localID("getuid", real))
    guard admit() else { throw Failure.admission }
    let effective = geteuid()
    storage.records.append(.localID("geteuid", effective))
    guard admit() else { throw Failure.admission }
    let group = getegid()
    storage.records.append(.localID("getegid", group))
    guard admit() else { throw Failure.admission }
    guard real == effective else { throw Failure.observation("Native real/effective UID mismatch") }
    return LocalCredentials(realUID: real, effectiveUID: effective, effectiveGID: group)
  }

  static func observeProcess(
    pid: pid_t, storage: ObservationStorage, admit: () -> Bool
  ) throws -> ProcessSnapshot {
    guard pid > 0 else { throw Failure.observation("nonpositive PID") }
    var info = proc_bsdinfo()
    let size = MemoryLayout<proc_bsdinfo>.size
    guard admit() else { throw Failure.admission }
    let result = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size))
    let savedErrno = result <= 0 ? errno : 0
    storage.records.append(.process(result, savedErrno, info))
    guard admit() else { throw Failure.admission }
    guard result == Int32(size) else {
      throw Failure.observation("missing, denied or short PROC_PIDTBSDINFO")
    }
    guard info.pbi_pid == UInt32(pid), info.pbi_ppid > 0,
      let parent = pid_t(exactly: info.pbi_ppid),
      info.pbi_start_tvsec > 0, info.pbi_start_tvusec < 1_000_000
    else { throw Failure.observation("invalid public BSD process snapshot") }
    guard admit() else { throw Failure.admission }
    return ProcessSnapshot(
      pid: pid, parentPID: parent, uid: info.pbi_uid, gid: info.pbi_gid,
      birthSeconds: info.pbi_start_tvsec, birthMicroseconds: info.pbi_start_tvusec)
  }

  static func observePeer(
    socket: Int32, storage: ObservationStorage, admit: () -> Bool
  ) throws -> PeerSnapshot {
    _ = try observeLocalCredentials(storage: storage, admit: admit)
    var uid: uid_t = 0
    var gid: gid_t = 0
    guard admit() else { throw Failure.admission }
    let credentialsResult = getpeereid(socket, &uid, &gid)
    let credentialsErrno = credentialsResult < 0 ? errno : 0
    storage.records.append(.credentials(credentialsResult, credentialsErrno, uid, gid))
    guard admit() else { throw Failure.admission }
    guard credentialsResult == 0 else {
      throw Failure.syscall("getpeereid", credentialsErrno)
    }
    var pid: pid_t = 0
    var pidSize = socklen_t(MemoryLayout<pid_t>.size)
    guard admit() else { throw Failure.admission }
    let pidResult = getsockopt(socket, SOL_LOCAL, LOCAL_PEERPID, &pid, &pidSize)
    let pidErrno = pidResult < 0 ? errno : 0
    storage.records.append(.peerPID(pidResult, pidErrno, pidSize, pid))
    guard admit() else { throw Failure.admission }
    guard pidResult == 0 else {
      throw Failure.syscall("LOCAL_PEERPID", pidErrno)
    }
    guard pidSize == MemoryLayout<pid_t>.size else {
      throw Failure.observation("short LOCAL_PEERPID")
    }
    var token = audit_token_t()
    var tokenSize = socklen_t(MemoryLayout<audit_token_t>.size)
    guard admit() else { throw Failure.admission }
    let tokenResult = getsockopt(socket, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &tokenSize)
    let tokenErrno = tokenResult < 0 ? errno : 0
    storage.records.append(.peerToken(tokenResult, tokenErrno, tokenSize, token))
    guard admit() else { throw Failure.admission }
    guard tokenResult == 0 else {
      throw Failure.syscall("LOCAL_PEERTOKEN", tokenErrno)
    }
    guard tokenSize == MemoryLayout<audit_token_t>.size else {
      throw Failure.observation("short LOCAL_PEERTOKEN")
    }
    let version = audit_token_to_pidversion(token)
    guard pid > 0, version > 0, audit_token_to_pid(token) == pid,
      audit_token_to_euid(token) == uid, audit_token_to_egid(token) == gid
    else { throw Failure.observation("inconsistent socket credentials/token") }
    guard admit() else { throw Failure.admission }
    return PeerSnapshot(
      uid: uid, gid: gid, pid: pid, pidVersion: version, token: token,
      tokenBytes: withUnsafeBytes(of: token) { Array($0) })
  }

  static func tokenBoundPath(
    _ peer: PeerSnapshot, storage: ObservationStorage, admit: () -> Bool
  ) throws -> String {
    // Public libproc.h defines PROC_PIDPATHINFO_MAXSIZE as 4 * MAXPATHLEN.
    var bytes = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
    var token = peer.token
    guard admit() else { throw Failure.admission }
    let result = bytes.withUnsafeMutableBytes {
      proc_pidpath_audittoken(&token, $0.baseAddress, UInt32($0.count))
    }
    let savedErrno = result <= 0 ? errno : 0
    storage.records.append(.path(result, savedErrno, bytes))
    guard admit() else { throw Failure.admission }
    guard result > 0, result < bytes.count,
      let end = bytes.firstIndex(of: 0), end > 0,
      let path = String(bytes: bytes[..<end], encoding: .utf8), path.first == "/"
    else { throw Failure.observation("missing, denied or invalid token-bound path") }
    guard admit() else { throw Failure.admission }
    return path
  }

  /// Repeated socket/token, token-bound image and public BSD birth observations.
  /// A self socketpair observes its creator, NOT the process holding the alias.
  static func observeIdentity(
    socket: Int32, storage: ObservationStorage, admit: () -> Bool
  ) throws -> PeerObservation {
    let before = try observePeer(socket: socket, storage: storage, admit: admit)
    let pathBefore = try tokenBoundPath(before, storage: storage, admit: admit)
    let process = try observeProcess(pid: before.pid, storage: storage, admit: admit)
    let processAfter = try observeProcess(pid: before.pid, storage: storage, admit: admit)
    let pathAfter = try tokenBoundPath(before, storage: storage, admit: admit)
    let after = try observePeer(socket: socket, storage: storage, admit: admit)
    guard before.isSamePeer(as: after), process == processAfter,
      process.uid == before.uid, process.gid == before.gid, pathBefore == pathAfter
    else { throw Failure.observation("unstable peer image/birth/credentials") }
    guard admit() else { throw Failure.admission }
    return PeerObservation(peer: before, process: process, executablePath: pathBefore)
  }

  /// Explicit caller check against its ACTUAL spawn snapshot and canonical bundle
  /// path. Payload PID/runID and lifecycle socketpair credentials are not inputs.
  /// This checks image/ancestry observations only, never Python module or SDK state.
  static func checkBrokerChain(
    workerAtSpawn: ProcessSnapshot, workerNow: ProcessSnapshot,
    nativePID: pid_t, nativeCredentials: LocalCredentials,
    broker: PeerObservation, canonicalInterpreterPath: String
  ) throws {
    guard nativePID > 0, workerAtSpawn == workerNow,
      nativeCredentials.realUID == nativeCredentials.effectiveUID,
      workerNow.parentPID == nativePID, workerNow.uid == nativeCredentials.effectiveUID,
      workerNow.gid == nativeCredentials.effectiveGID, broker.process.parentPID == workerNow.pid,
      broker.process.pid == broker.peer.pid, broker.process.uid == workerNow.uid,
      broker.process.gid == workerNow.gid, broker.peer.uid == workerNow.uid,
      broker.peer.gid == workerNow.gid,
      broker.executablePath == canonicalInterpreterPath,
      canonicalInterpreterPath.first == "/"
    else { throw Failure.observation("broker does not match actual spawned-worker chain") }
  }
}
