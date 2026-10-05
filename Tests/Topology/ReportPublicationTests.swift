import Darwin
import Foundation

@main
private enum ReportPublicationTests {
  static func check(_ value: @autoclosure () -> Bool, _ code: String) {
    guard value() else {
      print(code)
      exit(1)
    }
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
    print(
      "report_publication_pass: payload, mode, file_collision, symlink_collision, invalid_descriptor, temporary_cleanup"
    )
  }
}
