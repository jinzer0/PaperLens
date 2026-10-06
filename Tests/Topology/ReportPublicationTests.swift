import Darwin
import Foundation

@main
private enum ReportPublicationTests {
  final class Result: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Bool] = []
    let signal = DispatchSemaphore(value: 0)

    func finish(_ value: Bool) {
      lock.lock()
      values.append(value)
      lock.unlock()
      signal.signal()
    }

    func snapshot() -> [Bool] {
      lock.lock()
      defer { lock.unlock() }
      return values
    }
  }

  static func check(_ value: @autoclosure () -> Bool, _ code: String) {
    guard value() else {
      print(code)
      exit(1)
    }
  }

  static func privateRoot(_ root: URL, _ name: String) -> URL {
    let result = root.appendingPathComponent(name, isDirectory: true)
    check(mkdir(result.path, 0o700) == 0, "private_root_failed")
    return result
  }

  static func write(_ bytes: Data, directory: Int32, name: String) {
    let temporary = UUID().uuidString.lowercased() + ".test-write"
    let fd = openat(
      directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    check(fd >= 0, "test_write_open_failed")
    defer { close(fd) }
    check(TopologyFixtures.writeAll(bytes, descriptor: fd), "test_write_failed")
    check(TopologyFixtures.sync(fd), "test_sync_failed")
    check(
      renameatx_np(directory, temporary, directory, name, UInt32(RENAME_EXCL)) == 0,
      "test_write_publication_failed")
  }

  static func namespaces(_ root: URL) throws {
    let container = privateRoot(root, "container")
    let runID = UUID().uuidString.lowercased()
    guard let reservation = TopologyReportReservation(container: container, runID: runID) else {
      check(false, "reservation_failed")
      return
    }
    let reports = reservation.directoryURL.deletingLastPathComponent()
    let legacy = reports.deletingLastPathComponent().appendingPathComponent("report.json")
    let historic = Data("historic".utf8)
    try historic.write(to: legacy)
    let payload = Data(repeating: 0x43, count: 1024 * 1024)
    check(reservation.publish(payload), "reserved_publication_failed")
    let report = reservation.directoryURL.appendingPathComponent("report.json")
    check(try! Data(contentsOf: report) == payload, "reserved_payload_changed")
    check(try! Data(contentsOf: legacy) == historic, "legacy_changed")
    check(!reservation.publish(historic), "reserved_report_replaced")
    check(TopologyReportReservation(container: container, runID: runID) == nil, "run_adopted")
    let second = TopologyReportReservation(
      container: container, runID: UUID().uuidString.lowercased())
    check(second != nil && second!.publish(historic), "historic_run_blocked_new_run")
    check(try! Data(contentsOf: report) == payload, "historic_run_changed")
    check(TopologyReportReservation(container: container, runID: "../escape") == nil, "run_escape")
    for symlink in [false, true] {
      let collided = UUID().uuidString.lowercased()
      let url = reports.appendingPathComponent(collided)
      if symlink {
        try FileManager.default.createSymbolicLink(
          at: url, withDestinationURL: reservation.directoryURL)
      } else {
        try historic.write(to: url)
      }
      var before = stat()
      check(lstat(url.path, &before) == 0, "collision_stat_failed")
      check(
        TopologyReportReservation(container: container, runID: collided) == nil, "collision_adopted"
      )
      var after = stat()
      check(
        lstat(url.path, &after) == 0 && after.st_dev == before.st_dev
          && after.st_ino == before.st_ino,
        "collision_replaced")
    }
    let replacedID = UUID().uuidString.lowercased()
    let replaced = TopologyReportReservation(container: container, runID: replacedID)!
    let moved = reports.appendingPathComponent("moved-owned-run")
    check(rename(replaced.directoryURL.path, moved.path) == 0, "reservation_move_failed")
    check(mkdir(replaced.directoryURL.path, 0o700) == 0, "replacement_directory_failed")
    check(!replaced.publish(payload), "replaced_namespace_published")
    check(FileManager.default.fileExists(atPath: moved.path), "owned_namespace_deleted")
    check(chmod(reports.path, 0o755) == 0, "unsafe_reports_setup_failed")
    check(
      TopologyReportReservation(container: container, runID: UUID().uuidString.lowercased()) == nil,
      "unsafe_reports_adopted")
    check(chmod(reports.path, 0o700) == 0, "reports_restore_failed")
    let redirected = privateRoot(root, "redirected")
    try FileManager.default.createSymbolicLink(
      at: redirected.appendingPathComponent("Library"),
      withDestinationURL: container.appendingPathComponent("Library"))
    check(
      TopologyReportReservation(container: redirected, runID: UUID().uuidString.lowercased())
        == nil,
      "ancestor_symlink_followed")
    let parentMoved = TopologyReportReservation(
      container: container, runID: UUID().uuidString.lowercased())!
    let preservedReports = reports.deletingLastPathComponent().appendingPathComponent(
      "Reports-preserved")
    check(rename(reports.path, preservedReports.path) == 0, "reports_move_failed")
    check(mkdir(reports.path, 0o700) == 0, "reports_replacement_failed")
    check(!parentMoved.publish(payload), "replaced_reports_parent_published")
    check(
      try! Data(
        contentsOf: preservedReports.appendingPathComponent(runID).appendingPathComponent(
          "report.json"))
        == payload, "moved_historic_report_changed")
  }

  static func ownedLinks(_ root: URL) throws {
    let fixturesRoot = privateRoot(root, "links")
    let runID = UUID().uuidString.lowercased()
    let owner = TopologyOwnedFixtures(root: fixturesRoot, runID: runID)!
    check(!owner.prepareLinks(["../escape"]), "link_alias_escape")
    check(!owner.prepareLinks(["A", "A"]), "duplicate_link_alias")
    check(owner.prepareLinks(["A", "C"]), "prepare_links_failed")
    check(
      owner.links == [["alias": "A", "name": "A.link"], ["alias": "C", "name": "C.link"]],
      "link_metadata_changed")
    check(owner.checkLinks() && owner.checkLinks(), "links_not_retained")
    let observation = TopologyFixtures.probe(
      runID: runID, actor: "Main", alias: "A", operation: "symlinkRead",
      symlinkDirectory: owner.descriptor)
    check(observation["intervalRef"] as? String == "Main.A.symlinkRead", "interval_ref_failed")
    check(owner.checkLinks(), "probe_removed_owned_link")
    check(unlinkat(owner.descriptor, "A.link", 0) == 0, "replace_link_unlink_failed")
    write(Data("replacement".utf8), directory: owner.descriptor, name: "A.link")
    var replacement = stat()
    check(
      fstatat(owner.descriptor, "A.link", &replacement, AT_SYMLINK_NOFOLLOW) == 0,
      "replacement_link_stat_failed")
    check(!owner.checkLinks(), "replacement_link_accepted")
    check(!owner.cleanup(), "replacement_link_cleanup_succeeded")
    var preserved = stat()
    check(
      fstatat(owner.descriptor, "A.link", &preserved, AT_SYMLINK_NOFOLLOW) == 0
        && replacement.st_ino == preserved.st_ino && replacement.st_dev == preserved.st_dev,
      "replacement_link_deleted")
    let clean = TopologyOwnedFixtures(root: fixturesRoot, runID: UUID().uuidString.lowercased())!
    check(
      clean.prepareLinks(["M", "A", "C", "E", "G"]) && clean.checkLinks(), "worker_links_failed")
    check(clean.cleanup(), "owned_links_cleanup_failed")
    let unobserved = TopologyFixtures.observation(
      runID: runID, actor: "Main", alias: "A", operation: "write", result: -1, error: EACCES)
    check(
      unobserved["syscallObserved"] as? Bool == false
        && unobserved["syscallResult"] as? Int == 0 && unobserved["errno"] as? Int == 0
        && unobserved["beganAtNs"] as? Int64 == 0 && unobserved["endedAtNs"] as? Int64 == 0
        && unobserved["verdict"] as? String == "blocked", "unobserved_fabricated_evidence")
  }

  static func startFence(
    _ descriptor: Int32, _ runID: String, _ phase: String,
    _ result: Result, timeout: Int = 1000
  ) {
    TopologyReadiness.fence(
      directory: descriptor, runID: runID, phase: phase,
      actors: [["role": "Main", "pid": Int(getpid())]], links: [], intervals: [],
      ownerControl: true, timeoutMs: timeout, completion: { result.finish($0) })
  }

  static func waitForFile(_ directory: Int32, _ name: String) -> Bool {
    let deadline = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
    while DispatchTime.now().uptimeNanoseconds < deadline {
      var info = stat()
      if fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 { return true }
      usleep(1000)
    }
    return false
  }

  static func fences(_ root: URL) throws {
    check(TopologyReadiness.contractHash != nil, "test_bundled_contract_missing")
    let directoryURL = privateRoot(root, "fences")
    let directory = TopologyFixtures.directory(directoryURL, create: false)!
    defer { close(directory) }
    let runID = UUID().uuidString.lowercased()
    for phase in ["pre", "post"] {
      let result = Result()
      let readyName = phase == "pre" ? "ready.json" : "post-ready.json"
      let ackName = phase == "pre" ? "continue.json" : "post-continue.json"
      startFence(directory, runID, phase, result)
      check(waitForFile(directory, readyName), "ready_not_published")
      let bytes = try Data(contentsOf: directoryURL.appendingPathComponent(readyName))
      let ready = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
      check(
        Set(ready.keys)
          == Set([
            "schemaRevision", "runID", "phase", "contractHash", "clock",
            "actors", "links", "intervals", "ownerControl",
          ]), "ready_schema_failed")
      let ack = TopologyFixtures.json([
        "schemaRevision": "topology-readiness-v1", "runID": runID, "phase": phase,
        "readyHash": TopologyReadiness.hash(bytes),
        "artifactHash": String(repeating: "a", count: 64),
      ])
      write(ack, directory: directory, name: ackName)
      let withdrawalDeadline = DispatchTime.now().uptimeNanoseconds + 500_000_000
      var readyInfo = stat()
      while fstatat(directory, readyName, &readyInfo, AT_SYMLINK_NOFOLLOW) == 0
        && DispatchTime.now().uptimeNanoseconds < withdrawalDeadline
      { usleep(1000) }
      check(
        fstatat(directory, readyName, &readyInfo, AT_SYMLINK_NOFOLLOW) == -1 && errno == ENOENT,
        "ready_not_withdrawn")
      check(result.snapshot().isEmpty, "fence_completed_before_ack_withdrawal")
      var ackInfo = stat()
      check(fstatat(directory, ackName, &ackInfo, AT_SYMLINK_NOFOLLOW) == 0, "native_deleted_ack")
      check(
        TopologyFixtures.removeOwned(directory: directory, name: ackName, info: ackInfo),
        "verifier_ack_withdrawal_failed")
      check(
        result.signal.wait(timeout: .now() + .seconds(1)) == .success
          && result.snapshot() == [true], "valid_fence_failed")
    }
    let timeout = Result()
    startFence(directory, runID, "pre", timeout, timeout: 80)
    check(
      timeout.signal.wait(timeout: .now() + .seconds(1)) == .success
        && timeout.snapshot() == [false],
      "fence_timeout_failed")
    var info = stat()
    check(
      fstatat(directory, "ready.json", &info, AT_SYMLINK_NOFOLLOW) == -1 && errno == ENOENT,
      "timed_out_ready_leaked")
    let invalidActor = Result()
    TopologyReadiness.fence(
      directory: directory, runID: runID, phase: "pre",
      actors: [["role": "Main", "pid": true]], links: [], intervals: [],
      ownerControl: true, timeoutMs: 1000, completion: { invalidActor.finish($0) })
    check(invalidActor.snapshot() == [false], "boolean_pid_accepted")
    write(Data("prior-ready".utf8), directory: directory, name: "ready.json")
    let readyCollision = Result()
    startFence(directory, runID, "pre", readyCollision)
    check(readyCollision.snapshot() == [false], "existing_ready_adopted")
    check(
      try! Data(contentsOf: directoryURL.appendingPathComponent("ready.json"))
        == Data("prior-ready".utf8),
      "existing_ready_changed")
    check(unlinkat(directory, "ready.json", 0) == 0, "test_prior_ready_cleanup_failed")
    write(Data("prior-ack".utf8), directory: directory, name: "continue.json")
    let prior = Result()
    startFence(directory, runID, "pre", prior)
    check(
      prior.signal.wait(timeout: .now() + .seconds(1)) == .success && prior.snapshot() == [false],
      "preexisting_ack_adopted")
    check(
      try! Data(contentsOf: directoryURL.appendingPathComponent("continue.json"))
        == Data("prior-ack".utf8),
      "preexisting_ack_changed")
    check(unlinkat(directory, "continue.json", 0) == 0, "test_prior_ack_cleanup_failed")
    let invalid = Result()
    startFence(directory, runID, "pre", invalid)
    check(waitForFile(directory, "ready.json"), "invalid_ack_ready_missing")
    write(
      TopologyFixtures.json([
        "schemaRevision": "topology-readiness-v1", "runID": runID,
        "phase": "post", "readyHash": String(repeating: "b", count: 64),
        "artifactHash": String(repeating: "a", count: 64),
      ]), directory: directory, name: "continue.json")
    check(
      invalid.signal.wait(timeout: .now() + .seconds(1)) == .success
        && invalid.snapshot() == [false],
      "invalid_ack_accepted")
    check(
      fstatat(directory, "continue.json", &info, AT_SYMLINK_NOFOLLOW) == 0,
      "invalid_ack_deleted")
    check(unlinkat(directory, "continue.json", 0) == 0, "test_invalid_ack_cleanup_failed")
    let oversized = Result()
    startFence(directory, runID, "pre", oversized)
    write(Data(repeating: 0x20, count: 64 * 1024 + 1), directory: directory, name: "continue.json")
    check(
      oversized.signal.wait(timeout: .now() + .seconds(1)) == .success
        && oversized.snapshot() == [false], "oversized_ack_accepted")
    check(
      fstatat(directory, "continue.json", &info, AT_SYMLINK_NOFOLLOW) == 0,
      "oversized_ack_deleted")
    check(unlinkat(directory, "continue.json", 0) == 0, "test_oversized_ack_cleanup_failed")
    let duplicate = Result()
    startFence(directory, runID, "pre", duplicate)
    let duplicateReady = try Data(contentsOf: directoryURL.appendingPathComponent("ready.json"))
    let duplicateBytes = Data(
      ("{\"schemaRevision\":\"topology-readiness-v1\",\"runID\":\""
        + runID + "\",\"phase\":\"pre\",\"phase\":\"pre\",\"readyHash\":\""
        + TopologyReadiness.hash(duplicateReady) + "\",\"artifactHash\":\""
        + String(repeating: "a", count: 64) + "\"}").utf8)
    write(duplicateBytes, directory: directory, name: "continue.json")
    check(
      duplicate.signal.wait(timeout: .now() + .seconds(1)) == .success
        && duplicate.snapshot() == [false], "duplicate_ack_keys_accepted")
    check(unlinkat(directory, "continue.json", 0) == 0, "test_duplicate_ack_cleanup_failed")
    let symlinkAck = Result()
    startFence(directory, runID, "pre", symlinkAck)
    write(Data("preserved-ack-target".utf8), directory: directory, name: "ack-target")
    check(symlinkat("ack-target", directory, "continue.json") == 0, "symlink_ack_setup_failed")
    check(
      symlinkAck.signal.wait(timeout: .now() + .seconds(1)) == .success
        && symlinkAck.snapshot() == [false], "symlink_ack_followed")
    check(
      fstatat(directory, "continue.json", &info, AT_SYMLINK_NOFOLLOW) == 0
        && info.st_mode & S_IFMT == S_IFLNK, "symlink_ack_deleted")
    check(
      try! Data(contentsOf: directoryURL.appendingPathComponent("ack-target"))
        == Data("preserved-ack-target".utf8),
      "symlink_ack_target_changed")
    check(unlinkat(directory, "continue.json", 0) == 0, "test_symlink_ack_cleanup_failed")
    let retainedAck = Result()
    startFence(directory, runID, "post", retainedAck, timeout: 160)
    let postBytes = try Data(contentsOf: directoryURL.appendingPathComponent("post-ready.json"))
    write(
      TopologyFixtures.json([
        "schemaRevision": "topology-readiness-v1", "runID": runID,
        "phase": "post", "readyHash": TopologyReadiness.hash(postBytes),
        "artifactHash": String(repeating: "a", count: 64),
      ]), directory: directory, name: "post-continue.json")
    check(
      retainedAck.signal.wait(timeout: .now() + .seconds(1)) == .success
        && retainedAck.snapshot() == [false], "ack_withdrawal_timeout_failed")
    check(
      fstatat(directory, "post-continue.json", &info, AT_SYMLINK_NOFOLLOW) == 0,
      "timed_out_ack_deleted")
    check(unlinkat(directory, "post-continue.json", 0) == 0, "test_retained_ack_cleanup_failed")
    let replaced = Result()
    startFence(directory, runID, "pre", replaced)
    check(waitForFile(directory, "ready.json"), "replacement_ready_missing")
    check(
      renameat(directory, "ready.json", directory, "moved-ready.json") == 0, "ready_move_failed")
    write(Data("replacement".utf8), directory: directory, name: "ready.json")
    check(
      replaced.signal.wait(timeout: .now() + .seconds(1)) == .success
        && replaced.snapshot() == [false],
      "replaced_ready_accepted")
    check(
      try! Data(contentsOf: directoryURL.appendingPathComponent("ready.json"))
        == Data("replacement".utf8),
      "replacement_ready_deleted")
    check(timeout.snapshot() == [false], "timeout_completed_again")
  }

  static func completedForbiddenConnection() {
    let server = socket(AF_INET, SOCK_STREAM, 0)
    check(server >= 0, "network_control_socket_failed")
    defer { close(server) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = UInt16(18765).bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(server, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    check(bound == 0 && listen(server, 1) == 0, "network_control_port_unavailable")
    let row = TopologyFixtures.network(
      runID: UUID().uuidString.lowercased(), actor: "PDFiumXPC", expectAllowed: false)
    check(
      row["syscallObserved"] as? Bool == true && row["verdict"] as? String == "failed",
      "completed_forbidden_connection_not_failed")
    let result = row["syscallResult"] as? Int
    let code = row["errno"] as? Int
    check(
      (result == 0 && code == 0) || (result == -1 && code == Int(EINPROGRESS)),
      "original_connect_tuple_replaced")
  }

  static func main() throws {
    let created = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: created, withIntermediateDirectories: false)
    guard let canonical = realpath(created.path, nil) else {
      try FileManager.default.removeItem(at: created)
      throw POSIXError(.ENOENT)
    }
    let root = URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
    free(canonical)
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = TopologyFixtures.directory(root, create: false)
    check(directory != nil, "search_directory_failed")
    let descriptor = directory!
    defer { close(descriptor) }
    let report = root.appendingPathComponent("report.json")
    let payload = Data(repeating: 0x41, count: 1024 * 1024)
    check(TopologyFixtures.publishReport(payload, directory: descriptor), "publication_failed")
    check(try! Data(contentsOf: report) == payload, "payload_mismatch")
    var before = stat()
    check(lstat(report.path, &before) == 0, "report_metadata_failed")
    check(before.st_mode & 0o777 == 0o600, "report_mode_failed")
    check(
      !TopologyFixtures.publishReport(Data("replacement".utf8), directory: descriptor),
      "existing_report_replaced")
    var after = stat()
    check(
      lstat(report.path, &after) == 0 && before.st_ino == after.st_ino
        && before.st_dev == after.st_dev, "existing_identity_changed")
    check(try! Data(contentsOf: report) == payload, "existing_bytes_changed")
    try FileManager.default.removeItem(at: report)
    let target = root.appendingPathComponent("owned-target")
    let marker = Data("preserved".utf8)
    try marker.write(to: target)
    try FileManager.default.createSymbolicLink(at: report, withDestinationURL: target)
    check(lstat(report.path, &before) == 0, "symlink_metadata_failed")
    check(
      !TopologyFixtures.publishReport(payload, directory: descriptor), "symlink_report_replaced")
    check(
      lstat(report.path, &after) == 0 && after.st_mode & S_IFMT == S_IFLNK
        && after.st_ino == before.st_ino, "symlink_identity_changed")
    check(try! Data(contentsOf: target) == marker, "symlink_target_changed")
    check(!TopologyFixtures.publishReport(payload, directory: -1), "invalid_descriptor_accepted")
    let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
    check(Set(names) == Set(["report.json", "owned-target"]), "owned_temporary_leaked")
    try namespaces(root)
    try ownedLinks(root)
    try fences(root)
    completedForbiddenConnection()
    print(
      "report_publication_pass: payload, mode, file_collision, symlink_collision, invalid_descriptor, temporary_cleanup, namespaces, owned_links, readiness_fences"
    )
  }
}
