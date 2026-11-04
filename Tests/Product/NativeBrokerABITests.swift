import Darwin
import Foundation
import XCTest

@testable import PaperLensProduct

/// Synthetic OS fixtures only. No SDK, credentials, user paths, or clean proof.
final class NativeBrokerABITests: XCTestCase {
  private func sockets() throws -> [Int32] {
    var pair: [Int32] = [-1, -1]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else {
      throw NativeBrokerABI.Failure.syscall("fixture socketpair", errno)
    }
    return pair
  }

  private func checkedClose(
    _ descriptors: [Int32], file: StaticString = #filePath, line: UInt = #line
  ) {
    for fd in descriptors {
      XCTAssertEqual(close(fd), 0, "fixture actual close", file: file, line: line)
    }
  }

  private func nullDescriptor() throws -> Int32 {
    let fd = open("/dev/null", O_RDONLY | O_CLOEXEC)
    guard fd >= 0 else { throw NativeBrokerABI.Failure.syscall("fixture open", errno) }
    return fd
  }

  private func sendRights(
    _ rights: [Int32], socket: Int32, data: [UInt8] = [0x42]
  ) throws {
    let payload = rights.count * MemoryLayout<Int32>.size
    let capacity = try NativeBrokerABI.cmsgSpace(payload)
    let bytes = UnsafeMutableRawPointer.allocate(
      byteCount: capacity, alignment: MemoryLayout<cmsghdr>.alignment)
    defer { bytes.deallocate() }
    bytes.initializeMemory(as: UInt8.self, repeating: 0, count: capacity)
    var header = cmsghdr()
    header.cmsg_len = socklen_t(try NativeBrokerABI.cmsgLen(payload))
    header.cmsg_level = SOL_SOCKET
    header.cmsg_type = SCM_RIGHTS
    bytes.storeBytes(of: header, as: cmsghdr.self)
    let offset = try NativeBrokerABI.dataOffset
    for (index, fd) in rights.enumerated() {
      bytes.advanced(by: offset + index * MemoryLayout<Int32>.size).storeBytes(
        of: fd, as: Int32.self)
    }
    let sent = data.withUnsafeBytes { buffer in
      var vector = iovec(
        iov_base: UnsafeMutableRawPointer(mutating: buffer.baseAddress), iov_len: buffer.count)
      return withUnsafeMutablePointer(to: &vector) { vectorPointer in
        var message = msghdr()
        message.msg_iov = vectorPointer
        message.msg_iovlen = 1
        message.msg_control = bytes
        message.msg_controllen = socklen_t(capacity)
        return sendmsg(socket, &message, 0)
      }
    }
    guard sent == data.count else {
      throw NativeBrokerABI.Failure.syscall("fixture sendmsg", errno)
    }
  }

  func testPublicAlignmentCheckedArithmetic() throws {
    let mask = MemoryLayout<UInt32>.size - 1
    for payload in [0, 1, 3, 4, 5, 8, 17] {
      let offset = (MemoryLayout<cmsghdr>.size + mask) & ~mask
      XCTAssertEqual(try NativeBrokerABI.cmsgLen(payload), offset + payload)
      XCTAssertEqual(try NativeBrokerABI.cmsgSpace(payload), offset + ((payload + mask) & ~mask))
    }
    XCTAssertThrowsError(try NativeBrokerABI.align32(-1))
    XCTAssertThrowsError(try NativeBrokerABI.align32(Int.max))
    XCTAssertThrowsError(try NativeBrokerABI.cmsgLen(Int.max))
    XCTAssertThrowsError(try NativeBrokerABI.cmsgSpace(Int.max))
  }

  func testRealRightsTransferIdentityAndOnlyOneDataByteConsumed() throws {
    let pair = try sockets()
    defer { checkedClose(pair) }
    let original = try nullDescriptor()
    defer { checkedClose([original]) }
    let storage = try NativeBrokerABI.ReceiveStorage()  // Rooted BEFORE recvmsg.
    var captured: [Int32] = []
    defer { checkedClose(captured) }
    try sendRights([original], socket: pair[0], data: [0x42, 0x10, 0x20, 0x30])
    let result = try NativeBrokerABI.receiveOffer(
      socket: pair[1], storage: storage, admit: { true }
    ) {
      captured.append($0)  // Pure fixture metadata capture, no syscalls.
    }
    let received = try XCTUnwrap(captured.first)
    XCTAssertEqual(result, .descriptor(received))
    XCTAssertEqual(captured, storage.capturedDescriptors)
    XCTAssertNotEqual(received, original)
    var a = stat()
    var b = stat()
    XCTAssertEqual(fstat(original, &a), 0)
    XCTAssertEqual(fstat(received, &b), 0)
    XCTAssertEqual(a.st_dev, b.st_dev)
    XCTAssertEqual(a.st_ino, b.st_ino)
    XCTAssertEqual(a.st_mode, b.st_mode)
    var following = [UInt8](repeating: 0, count: 3)
    let readCount = following.withUnsafeMutableBytes {
      recv(pair[1], $0.baseAddress, $0.count, MSG_DONTWAIT)
    }
    XCTAssertEqual(readCount, 3)
    XCTAssertEqual(following, [0x10, 0x20, 0x30])
    XCTAssertThrowsError(
      try NativeBrokerABI.receiveOffer(socket: pair[1], storage: storage, admit: { true }) { _ in
        XCTFail("single-use storage must not receive again")
      })
    // Four real checked closes: transferred FD, original FD, two sockets.
  }

  func testMultipleRightsCapturedBeforeRejection() throws {
    let pair = try sockets()
    defer { checkedClose(pair) }
    let original = try nullDescriptor()
    defer { checkedClose([original]) }
    let storage = try NativeBrokerABI.ReceiveStorage()
    var captured: [Int32] = []
    defer { checkedClose(captured) }
    try sendRights([original, original, original], socket: pair[0])
    var returned = false
    XCTAssertThrowsError(
      try NativeBrokerABI.receiveOffer(socket: pair[1], storage: storage, admit: { true }) {
        XCTAssertFalse(returned)
        captured.append($0)
      })
    returned = true
    XCTAssertEqual(captured.count, 3)
    XCTAssertEqual(Set(captured).count, 3)
    XCTAssertEqual(storage.capturedDescriptors, captured)
    for fd in captured {
      var info = stat()
      XCTAssertEqual(fstat(fd, &info), 0, "rejection did not close delivered rights")
    }
  }

  func testWrongMarkerCapturesRightBeforeRejection() throws {
    let pair = try sockets()
    defer { checkedClose(pair) }
    let original = try nullDescriptor()
    defer { checkedClose([original]) }
    let storage = try NativeBrokerABI.ReceiveStorage()
    var captured: [Int32] = []
    defer { checkedClose(captured) }
    try sendRights([original], socket: pair[0], data: [0x41])
    XCTAssertThrowsError(
      try NativeBrokerABI.receiveOffer(socket: pair[1], storage: storage, admit: { true }) {
        captured.append($0)
      })
    XCTAssertEqual(captured.count, 1)
    XCTAssertEqual(storage.marker, 0x41)
    var info = stat()
    XCTAssertEqual(fstat(try XCTUnwrap(captured.first), &info), 0)
  }

  func testRealControlTruncationCapturesEveryDeliveredRight() throws {
    let pair = try sockets()
    defer { checkedClose(pair) }
    let original = try nullDescriptor()
    defer { checkedClose([original]) }
    let storage = try NativeBrokerABI.ReceiveStorage(
      controlCapacity: NativeBrokerABI.cmsgSpace(MemoryLayout<Int32>.size))
    var captured: [Int32] = []
    defer { checkedClose(captured) }
    try sendRights(Array(repeating: original, count: 8), socket: pair[0])
    XCTAssertThrowsError(
      try NativeBrokerABI.receiveOffer(socket: pair[1], storage: storage, admit: { true }) {
        captured.append($0)
      })
    XCTAssertNotEqual(storage.flags & MSG_CTRUNC, 0)
    XCTAssertFalse(captured.isEmpty)
    XCTAssertLessThan(captured.count, 8)
    XCTAssertEqual(storage.capturedDescriptors, captured)
    // Kernel-discarded, undelivered rights are not fabricated as delivered FDs.
    for fd in captured {
      var info = stat()
      XCTAssertEqual(fstat(fd, &info), 0)
    }
  }

  func testNonblockingWouldBlockAndEOFAreDistinct() throws {
    let pair = try sockets()
    defer { checkedClose([pair[1]]) }
    XCTAssertEqual(fcntl(pair[1], F_SETFL, O_NONBLOCK), 0)
    let empty = try NativeBrokerABI.ReceiveStorage()
    XCTAssertEqual(
      try NativeBrokerABI.receiveOffer(socket: pair[1], storage: empty, admit: { true }) { _ in
        XCTFail("no delivered rights")
      }, .wouldBlock)
    XCTAssertTrue(empty.capturedDescriptors.isEmpty)
    checkedClose([pair[0]])
    let eof = try NativeBrokerABI.ReceiveStorage()
    XCTAssertThrowsError(
      try NativeBrokerABI.receiveOffer(socket: pair[1], storage: eof, admit: { true }) { _ in
        XCTFail("EOF has no rights")
      })
    XCTAssertEqual(eof.syscallResult, 0)
  }

  func testAdmissionLossStillCapturesAllRightsBeforeThrowing() throws {
    let pair = try sockets()
    defer { checkedClose(pair) }
    let original = try nullDescriptor()
    defer { checkedClose([original]) }
    let storage = try NativeBrokerABI.ReceiveStorage()
    var captured: [Int32] = []
    defer { checkedClose(captured) }
    try sendRights([original, original], socket: pair[0], data: [0x41])
    // Explicit injected admission loss at the first capture. The second right
    // must still be captured; marker/shape rejection must not run before capture.
    XCTAssertThrowsError(
      try NativeBrokerABI.receiveOffer(
        socket: pair[1], storage: storage, admit: { captured.isEmpty },
        capture: { captured.append($0) }
      )
    ) { error in
      XCTAssertEqual(error as? NativeBrokerABI.Failure, .admission)
    }
    XCTAssertEqual(captured.count, 2)
    XCTAssertEqual(storage.syscallResult, 1)
    XCTAssertEqual(storage.capturedDescriptors, captured)
  }

  func testExplicitAdmissionGuardStopsBeforeEachNextKernelObservation() throws {
    let pair = try sockets()
    defer { checkedClose(pair) }
    // Injection controls admission only; kernel results themselves are genuine.
    // Thresholds cover local IDs, getpeereid, LOCAL_PEERPID and LOCAL_PEERTOKEN.
    for threshold in 1...6 {
      let storage = NativeBrokerABI.ObservationStorage()
      XCTAssertThrowsError(
        try NativeBrokerABI.observePeer(
          socket: pair[0], storage: storage,
          admit: { storage.records.count < threshold }
        )
      ) { error in
        XCTAssertEqual(error as? NativeBrokerABI.Failure, .admission)
      }
      XCTAssertEqual(
        storage.records.count, threshold, "late actual result recorded, no next syscall")
    }
    let denied = NativeBrokerABI.ObservationStorage()
    XCTAssertThrowsError(
      try NativeBrokerABI.observeProcess(
        pid: getpid(), storage: denied, admit: { false }))
    XCTAssertTrue(denied.records.isEmpty)
    let late = NativeBrokerABI.ObservationStorage()
    XCTAssertThrowsError(
      try NativeBrokerABI.observeProcess(
        pid: getpid(), storage: late, admit: { late.records.isEmpty }
      )
    ) { error in
      XCTAssertEqual(error as? NativeBrokerABI.Failure, .admission)
    }
    XCTAssertEqual(late.records.count, 1)
    let peerStorage = NativeBrokerABI.ObservationStorage()
    let peer = try NativeBrokerABI.observePeer(
      socket: pair[0], storage: peerStorage, admit: { true })
    let latePath = NativeBrokerABI.ObservationStorage()
    XCTAssertThrowsError(
      try NativeBrokerABI.tokenBoundPath(
        peer, storage: latePath, admit: { latePath.records.isEmpty }
      )
    ) { error in
      XCTAssertEqual(error as? NativeBrokerABI.Failure, .admission)
    }
    XCTAssertEqual(latePath.records.count, 1, "actual path bytes recorded before admission loss")
    let failed = NativeBrokerABI.ObservationStorage()
    XCTAssertThrowsError(
      try NativeBrokerABI.observePeer(socket: -1, storage: failed, admit: { true }))
    XCTAssertEqual(failed.records.count, 4, "actual invalid-FD failure stops before getsockopt")
    let receive = try NativeBrokerABI.ReceiveStorage()
    XCTAssertThrowsError(
      try NativeBrokerABI.receiveOffer(
        socket: pair[1], storage: receive, admit: { false }, capture: { _ in XCTFail("no receive") }
      ))
    XCTAssertNil(receive.syscallResult)
  }

  func testSelfSocketpairPublicPeerTokenPathAndBirthIsOnlySelfABI() throws {
    let pair = try sockets()
    defer { checkedClose(pair) }
    // An actual denied public kernel observation FAILS this fixture. It is not
    // replaced with injected success or presented as signed-product acceptance.
    let storage = NativeBrokerABI.ObservationStorage()
    let observation = try NativeBrokerABI.observeIdentity(
      socket: pair[0], storage: storage, admit: { true })
    let reverse = try NativeBrokerABI.observeIdentity(
      socket: pair[1], storage: storage, admit: { true })
    XCTAssertEqual(observation.peer.pid, getpid())
    XCTAssertEqual(observation.peer.uid, geteuid())
    XCTAssertEqual(observation.peer.gid, getegid())
    XCTAssertTrue(observation.peer.isSamePeer(as: reverse.peer))
    XCTAssertEqual(
      observation.process,
      try NativeBrokerABI.observeProcess(pid: getpid(), storage: storage, admit: { true }))
    XCTAssertEqual(
      observation.executablePath,
      try NativeBrokerABI.tokenBoundPath(reverse.peer, storage: storage, admit: { true }))
    XCTAssertFalse(observation.executablePath.isEmpty)
    // A socketpair identifies the creator, and MUST NOT pass as its own child.
    XCTAssertThrowsError(
      try NativeBrokerABI.checkBrokerChain(
        workerAtSpawn: observation.process, workerNow: observation.process,
        nativePID: getpid(),
        nativeCredentials: NativeBrokerABI.observeLocalCredentials(
          storage: storage, admit: { true }),
        broker: observation,
        canonicalInterpreterPath: observation.executablePath))
  }

  func testFreshSpawnDirectChildBirthObservations() throws {
    var child: pid_t = 0
    // Fixed system fixture, no executable or argument derived from user data.
    let strings: [UnsafeMutablePointer<CChar>?] = ["/bin/sleep", "30"].map {
      $0.withCString { strdup($0) }
    }
    defer { for string in strings { free(string) } }
    guard strings.allSatisfy({ $0 != nil }) else {
      throw NativeBrokerABI.Failure.observation("fixture argument allocation failed")
    }
    var arguments = strings + [nil]
    var environment: [UnsafeMutablePointer<CChar>?] = [nil]
    let result = arguments.withUnsafeMutableBufferPointer { args in
      environment.withUnsafeMutableBufferPointer { env in
        posix_spawn(&child, "/bin/sleep", nil, nil, args.baseAddress!, env.baseAddress!)
      }
    }
    XCTAssertEqual(result, 0)
    guard result == 0 else { return }
    defer {
      // Physical fixture teardown only, never production retirement proof.
      XCTAssertEqual(kill(child, SIGKILL), 0)
      var status: Int32 = 0
      var waited: pid_t
      repeat { waited = waitpid(child, &status, 0) } while waited == -1 && errno == EINTR
      XCTAssertEqual(waited, child)
    }
    let storage = NativeBrokerABI.ObservationStorage()
    let atSpawn = try NativeBrokerABI.observeProcess(pid: child, storage: storage, admit: { true })
    let repeated = try NativeBrokerABI.observeProcess(pid: child, storage: storage, admit: { true })
    XCTAssertEqual(atSpawn, repeated)
    XCTAssertEqual(atSpawn.parentPID, getpid())
    XCTAssertEqual(atSpawn.pid, child)
    XCTAssertEqual(atSpawn.uid, geteuid())
    XCTAssertThrowsError(
      try NativeBrokerABI.observeProcess(pid: -1, storage: storage, admit: { true }))
    // A real spawned-worker -> connected-broker chain is deliberately left to
    // same-Core integration; neither this child nor self credentials prove it.
  }
}
