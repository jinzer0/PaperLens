import Darwin
import Foundation
import XCTest
#if SWIFT_PACKAGE
import ProviderRPC
#endif
@testable import PaperLensProduct

/// Actual local FIFO ownership only: no SDK, process launch or authenticated peer.
@MainActor
final class OwnedPipeAgentRPCChannelTests: XCTestCase {
  @MainActor
  private struct Fixture {
    let stdout = Pipe()
    let stdin = Pipe()
    func channel() throws -> OwnedPipeAgentRPCChannel {
      try OwnedPipeAgentRPCChannel(readStdout: stdout.fileHandleForReading,
        writeStdin: stdin.fileHandleForWriting)
    }
    func peer() throws -> OwnedPipeAgentRPCChannel {
      try OwnedPipeAgentRPCChannel(readStdout: stdin.fileHandleForReading,
        writeStdin: stdout.fileHandleForWriting)
    }
    func closePeers() throws {
      try stdout.fileHandleForWriting.close()
      try stdin.fileHandleForReading.close()
    }
  }

  private func closed(_ channel: OwnedPipeAgentRPCChannel) -> XCTestExpectation {
    let done = expectation(description: "checked duplex closure")
    channel.observeClosure { outcome in
      XCTAssertTrue(outcome.bothClosed)
      done.fulfill()
    }
    return done
  }

  func testPreflightRejectsPairedAliasSwappedModesAmbientAndInvalidWithoutFlagEffects() throws {
    let fixture = Fixture()
    let before = fcntl(fixture.stdout.fileHandleForReading.fileDescriptor, F_GETFL)
    XCTAssertThrowsError(try OwnedPipeAgentRPCChannel(
      readStdout: fixture.stdout.fileHandleForReading,
      writeStdin: fixture.stdout.fileHandleForWriting))
    XCTAssertThrowsError(try OwnedPipeAgentRPCChannel(
      readStdout: fixture.stdout.fileHandleForWriting,
      writeStdin: fixture.stdin.fileHandleForReading))
    XCTAssertThrowsError(try OwnedPipeAgentRPCChannel(
      readStdout: fixture.stdout.fileHandleForReading,
      writeStdin: fixture.stdout.fileHandleForReading))
    XCTAssertThrowsError(try OwnedPipeAgentRPCChannel(
      readStdout: FileHandle(fileDescriptor: STDIN_FILENO, closeOnDealloc: false),
      writeStdin: fixture.stdin.fileHandleForWriting))
    XCTAssertThrowsError(try OwnedPipeAgentRPCChannel(
      readStdout: FileHandle(fileDescriptor: -1, closeOnDealloc: false),
      writeStdin: fixture.stdin.fileHandleForWriting))
    XCTAssertEqual(fcntl(fixture.stdout.fileHandleForReading.fileDescriptor, F_GETFL), before)
    try fixture.stdout.fileHandleForReading.close()
    try fixture.stdin.fileHandleForWriting.close()
    try fixture.closePeers()
  }

  func testRejectsOrdinaryFileDirectorySocketAndReadWriteFIFO() throws {
    let fixture = Fixture()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("file")
    try Data([1]).write(to: file)
    let ordinary = try FileHandle(forReadingFrom: file)
    defer { try? ordinary.close() }
    XCTAssertThrowsError(try OwnedPipeAgentRPCChannel(readStdout: ordinary,
      writeStdin: fixture.stdin.fileHandleForWriting))
    let directoryFD = open(directory.path, O_RDONLY)
    XCTAssertGreaterThan(directoryFD, 2)
    let directoryHandle = FileHandle(fileDescriptor: directoryFD, closeOnDealloc: false)
    defer { try? directoryHandle.close() }
    XCTAssertThrowsError(try OwnedPipeAgentRPCChannel(readStdout: directoryHandle,
      writeStdin: fixture.stdin.fileHandleForWriting))
    var sockets: [Int32] = [-1, -1]
    XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets), 0)
    let socket = FileHandle(fileDescriptor: sockets[0], closeOnDealloc: false)
    defer { try? socket.close(); _ = Darwin.close(sockets[1]) }
    XCTAssertThrowsError(try OwnedPipeAgentRPCChannel(readStdout: socket,
      writeStdin: fixture.stdin.fileHandleForWriting))
    let fifo = directory.appendingPathComponent("fifo")
    XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
    let readWriteFD = open(fifo.path, O_RDWR | O_NONBLOCK)
    XCTAssertGreaterThan(readWriteFD, 2)
    let readWrite = FileHandle(fileDescriptor: readWriteFD, closeOnDealloc: false)
    defer { try? readWrite.close() }
    XCTAssertThrowsError(try OwnedPipeAgentRPCChannel(readStdout: readWrite,
      writeStdin: fixture.stdin.fileHandleForWriting))
    try fixture.stdout.fileHandleForReading.close()
    try fixture.stdin.fileHandleForWriting.close()
    try fixture.closePeers()
  }

  func testFlagsBoundsPartialReadsAndBothPhysicalCloses() async throws {
    let fixture = Fixture()
    let readFD = fixture.stdout.fileHandleForReading.fileDescriptor
    let writeFD = fixture.stdin.fileHandleForWriting.fileDescriptor
    let rf = fcntl(readFD, F_GETFL)
    let wf = fcntl(writeFD, F_GETFL)
    let channel = try fixture.channel()
    XCTAssertEqual(fcntl(readFD, F_GETFL), rf | O_NONBLOCK)
    XCTAssertEqual(fcntl(writeFD, F_GETFL), wf | O_NONBLOCK)
    XCTAssertEqual(fcntl(writeFD, 74), 1)
    do {
      try await channel.write(Data(repeating: 0, count: ProviderRPC.maxFrameBytes + 1))
      XCTFail("Oversized write accepted")
    } catch { XCTAssertEqual(error as? OwnedPipeAgentRPCChannel.Failure, .frameTooLarge) }
    try fixture.stdout.fileHandleForWriting.write(contentsOf: Data([1, 2, 3]))
    let partial = try await channel.read()
    XCTAssertEqual(partial, Data([1, 2, 3]))
    let done = closed(channel)
    channel.requestClose()
    await fulfillment(of: [done], timeout: 3)
    XCTAssertEqual(fcntl(readFD, F_GETFL), -1)
    XCTAssertEqual(errno, EBADF)
    XCTAssertEqual(fcntl(writeFD, F_GETFL), -1)
    XCTAssertEqual(errno, EBADF)
    try fixture.closePeers()
  }

  func testBackpressureOrderedShortWritesBusyAndCloseUnblocksBothDirections() async throws {
    let fixture = Fixture()
    let channel = try fixture.channel()
    let peer = try fixture.peer()
    // Fill the genuine pipe until native EAGAIN, with no assumed capacity.
    let fd = fixture.stdin.fileHandleForWriting.fileDescriptor
    let fill = [UInt8](repeating: 0x55, count: 4096)
    var filled = 0
    while true {
      let count = fill.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
      if count > 0 { filled += count; continue }
      XCTAssertEqual(errno, EAGAIN)
      break
    }
    let frame = Data((0..<ProviderRPC.maxFrameBytes).map { UInt8($0 % 251) })
    let entered = expectation(description: "blocked writer entered")
    let sent = expectation(description: "ordered write finished")
    let write = Task { @MainActor in
      entered.fulfill()
      do { try await channel.write(frame) } catch { XCTFail("\(error)") }
      sent.fulfill()
    }
    await fulfillment(of: [entered], timeout: 3)
    do { try await channel.write(Data([9])); XCTFail("Overlap accepted") }
    catch { XCTAssertEqual(error as? OwnedPipeAgentRPCChannel.Failure, .busy) }
    let received = expectation(description: "backpressure released and bytes read")
    var output = Data()
    let read = Task { @MainActor in
      do {
        while output.count < filled + frame.count {
          guard let chunk = try await peer.read() else { XCTFail("Early EOF"); break }
          XCTAssertLessThanOrEqual(chunk.count, ProviderRPC.maxFrameBytes)
          output.append(chunk)
        }
      } catch { XCTFail("\(error)") }
      received.fulfill()
    }
    await fulfillment(of: [sent, received], timeout: 3)
    // Always revoke before joining after a bounded expectation failure.
    let a = closed(channel)
    let b = closed(peer)
    channel.requestClose()
    peer.requestClose()
    await fulfillment(of: [a, b], timeout: 3)
    await write.value
    await read.value
    XCTAssertEqual(output.prefix(filled), Data(repeating: 0x55, count: filled))
    XCTAssertEqual(output.dropFirst(filled), frame)
  }

  func testCloseAndCancellationUnblockPendingReadAndWrite() async throws {
    for cancel in [false, true] {
      let fixture = Fixture()
      let channel = try fixture.channel()
      let fd = fixture.stdin.fileHandleForWriting.fileDescriptor
      let fill = [UInt8](repeating: 0, count: 4096)
      while fill.withUnsafeBytes({ Darwin.write(fd, $0.baseAddress, $0.count) }) > 0 {}
      XCTAssertEqual(errno, EAGAIN)
      let enteredRead = expectation(description: "read suspended")
      let enteredWrite = expectation(description: "write suspended")
      let returnedRead = expectation(description: "read revoked")
      let returnedWrite = expectation(description: "write revoked")
      let read = Task { @MainActor in
        enteredRead.fulfill()
        do { _ = try await channel.read(); XCTFail("Revoked read succeeded") } catch {}
        returnedRead.fulfill()
      }
      let write = Task { @MainActor in
        enteredWrite.fulfill()
        do { try await channel.write(Data([1])); XCTFail("Revoked write succeeded") } catch {}
        returnedWrite.fulfill()
      }
      await fulfillment(of: [enteredRead, enteredWrite], timeout: 3)
      do { _ = try await channel.read(); XCTFail("Overlap accepted") }
      catch { XCTAssertEqual(error as? OwnedPipeAgentRPCChannel.Failure, .busy) }
      let done = closed(channel)
      if cancel { read.cancel() } else { channel.requestClose() }
      await fulfillment(of: [returnedRead, returnedWrite, done], timeout: 3)
      channel.requestClose()
      await read.value
      await write.value
      try fixture.closePeers()
    }
  }

  func testEOFJoinsReadinessCancellationBeforeNilAndCallback() async throws {
    let fixture = Fixture()
    let channel = try fixture.channel()
    let entered = expectation(description: "read waiting on readiness")
    let returned = expectation(description: "EOF after physical closes")
    let done = closed(channel)
    let read = Task { @MainActor in
      entered.fulfill()
      do {
        let bytes = try await channel.read()
        XCTAssertNil(bytes)
        XCTAssertTrue(channel.closureOutcome.bothClosed)
      } catch { XCTFail("\(error)") }
      returned.fulfill()
    }
    await fulfillment(of: [entered], timeout: 3)
    XCTAssertFalse(channel.closureOutcome.bothClosed)
    try fixture.stdout.fileHandleForWriting.close()
    XCTAssertFalse(channel.closureOutcome.bothClosed)
    await fulfillment(of: [returned, done], timeout: 3)
    channel.requestClose()
    await read.value
    try fixture.stdin.fileHandleForReading.close()
  }

  func testRealEPIPEWithVerifiedNoSIGPIPEDoesNotKillHost() async throws {
    let fixture = Fixture()
    let channel = try fixture.channel()
    XCTAssertEqual(fcntl(fixture.stdin.fileHandleForWriting.fileDescriptor, 74), 1)
    try fixture.stdin.fileHandleForReading.close()
    let done = closed(channel)
    do { try await channel.write(Data([1])); XCTFail("Broken pipe write succeeded") }
    catch { XCTAssertEqual(error as? OwnedPipeAgentRPCChannel.Failure, .io(EPIPE)) }
    await fulfillment(of: [done], timeout: 3)
    try fixture.stdout.fileHandleForWriting.close()
  }

  func testUnknownCloseRetainsActualHandleAfterFacadeDropAndNeverRetries() async throws {
    var fixture: Fixture? = Fixture()
    weak var debtHandle = fixture?.stdout.fileHandleForReading
    var attempts: [Int32] = []
    let debtFD = try XCTUnwrap(debtHandle).fileDescriptor
    var channel: OwnedPipeAgentRPCChannel? = try OwnedPipeAgentRPCChannel(
      readStdout: try XCTUnwrap(fixture).stdout.fileHandleForReading,
      writeStdin: try XCTUnwrap(fixture).stdin.fileHandleForWriting,
      close: { handle in
        attempts.append(handle.fileDescriptor)
        if handle.fileDescriptor == debtFD { throw OwnedPipeAgentRPCChannel.Failure.closureDebt }
        try handle.close()
      })
    let done = expectation(description: "separate checked closure debt")
    channel?.observeClosure { outcome in
      XCTAssertEqual(outcome.read, .unknown)
      XCTAssertEqual(outcome.write, .closed)
      XCTAssertFalse(outcome.bothClosed)
      done.fulfill()
    }
    channel?.requestClose()
    channel?.requestClose()
    await fulfillment(of: [done], timeout: 3)
    XCTAssertEqual(attempts.count, 2)
    try fixture?.closePeers()
    fixture = nil
    channel = nil
    XCTAssertNotNil(debtHandle)
    XCTAssertGreaterThanOrEqual(fcntl(debtFD, F_GETFL), 0)
    // Explicit fixture debt teardown is NOT a runtime close acknowledgement.
    try debtHandle?.close()
    XCTAssertEqual(attempts.count, 2)
  }

  func testEOFCloseFailureThrowsInsteadOfNilAndChecksEachEndpointOnce() async throws {
    let fixture = Fixture()
    var calls = 0
    let channel = try OwnedPipeAgentRPCChannel(
      readStdout: fixture.stdout.fileHandleForReading, writeStdin: fixture.stdin.fileHandleForWriting,
      close: { _ in calls += 1; throw OwnedPipeAgentRPCChannel.Failure.closureDebt })
    try fixture.stdout.fileHandleForWriting.close()
    let returned = expectation(description: "EOF debt throws rather than closure ACK")
    let read = Task { @MainActor in
      do { _ = try await channel.read(); XCTFail("Unknown close reported nil") }
      catch { XCTAssertEqual(error as? OwnedPipeAgentRPCChannel.Failure, .closureDebt) }
      returned.fulfill()
    }
    await fulfillment(of: [returned], timeout: 3)
    channel.requestClose()
    await read.value
    XCTAssertEqual(calls, 2)
    XCTAssertFalse(channel.closureOutcome.bothClosed)
    // Explicit manual owned-debt teardown; root remains unknown, never runtime ACK.
    try fixture.stdout.fileHandleForReading.close()
    try fixture.stdin.fileHandleForWriting.close()
    try fixture.stdin.fileHandleForReading.close()
  }

  func testLifecycleExplicitHandshakeAndEOFDecoderClosureIncludingTruncation() async throws {
    for truncated in [false, true] {
      let fixture = Fixture()
      let lifecycle = try AgentConnectionLifecycle.ownedPipe(
        readStdout: fixture.stdout.fileHandleForReading,
        writeStdin: fixture.stdin.fileHandleForWriting)
      let peer = try fixture.peer()
      XCTAssertEqual(lifecycle.connection.state, .handshaking)
      XCTAssertFalse(lifecycle.connection.transportClosureObserved)
      try lifecycle.start()
      let helloDone = expectation(description: "actual local hello supplied-frame exchange")
      let peerClosed = closed(peer)
      let peerTask = Task { @MainActor in
        do {
          let decoder = ProviderFrameDecoder()
          var hello: [String: Any]?
          while hello == nil {
            guard let bytes = try await peer.read() else { XCTFail("Early EOF"); break }
            if let frame = try decoder.feed(bytes).first { hello = try ProviderRPC.decode(frame) }
          }
          let id = try XCTUnwrap(hello?["id"] as? String)
          let reply = try ProviderRPC.encode(["kind": "result", "id": id,
            "result": ["major": 1, "minor": 1, "capabilities": ["topology-v1"]]])
          try await peer.write(truncated ? Data(reply.prefix(3)) : reply)
          peer.requestClose()
        } catch { XCTFail("\(error)") }
        helloDone.fulfill()
      }
      await fulfillment(of: [helloDone, peerClosed], timeout: 3)
      let joined = expectation(description: "decoder finish plus reader/writer joins")
      let joinTask = Task { @MainActor in
        // Only observes lifecycle state, not native IO. The XCTest deadline below
        // bounds this test waiter; cancellation joins it even on a failed expectation.
        while !Task.isCancelled {
          if lifecycle.connection.transportClosureObserved { joined.fulfill(); return }
          await Task.yield()
        }
      }
      await fulfillment(of: [joined], timeout: 3)
      lifecycle.close()
      peer.requestClose()
      joinTask.cancel()
      await peerTask.value
      await joinTask.value
      XCTAssertTrue(lifecycle.connection.transportClosureObserved)
      XCTAssertEqual(lifecycle.connection.state, truncated ? .poisoned : .closed)
    }
  }
}
