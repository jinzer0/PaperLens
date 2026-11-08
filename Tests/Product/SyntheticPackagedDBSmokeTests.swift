import Darwin
import Foundation
import XCTest
@testable import PaperLensProduct

final class SyntheticPackagedDBSmokeTests: XCTestCase {
  private func temporaryRoot() throws -> URL {
    // The existing DB owner requires a physical, standardized CODE-artifact path.
    // Foundation normalizes /private/var to /var, whose symlink the owner correctly refuses.
    let requested = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build")
      .appendingPathComponent("paperlens-synthetic-db-test-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: requested, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    let physical = try XCTUnwrap(realpath(requested.path, nil))
    defer { free(physical) }
    return URL(fileURLWithPath: String(cString: physical), isDirectory: true)
  }

  func testLaunchRequiresExclusiveExplicitModeAndCanonicalIdentifier() {
    let id = UUID().uuidString.lowercased()
    let args = ["PaperLens", SyntheticPackagedDBSmoke.flag, "--run-id", id]
    XCTAssertEqual(SyntheticPackagedDBSmoke.launch(args), .run(id))
    XCTAssertEqual(SyntheticPackagedDBSmoke.launch(["PaperLens"]), .absent)
    XCTAssertEqual(SyntheticPackagedDBSmoke.launch(Array(args.dropLast())), .invalid)
    for other in ["--topology-smoke", SyntheticWorkspaceSmoke.flag, "unexpected"] {
      XCTAssertEqual(SyntheticPackagedDBSmoke.launch(args + [other]), .invalid)
    }
    for invalid in [id.uppercased(), "../existing", "", "00000000"] {
      XCTAssertEqual(SyntheticPackagedDBSmoke.launch([
        "PaperLens", SyntheticPackagedDBSmoke.flag, "--run-id", invalid]), .invalid)
    }
    XCTAssertEqual(SyntheticPackagedDBSmoke.launch([
      "PaperLens", "--run-id", id, SyntheticPackagedDBSmoke.flag]), .invalid)
  }

  func testActualSQLMigrationsFTSDeletionConstraintRollbackReopenAndCleanup() throws {
    let root = try temporaryRoot()
    var safeToRemove = false
    defer { if safeToRemove { try? FileManager.default.removeItem(at: root) } }
    let parent = root.appendingPathComponent("runs", isDirectory: true)
    let id = UUID().uuidString.lowercased()
    let report = try SyntheticPackagedDBSmoke.run(parentURL: parent, runID: id)
    safeToRemove = report.cleanupConfirmed
    XCTAssertTrue(report.behaviorPassed)
    XCTAssertTrue(report.cleanupConfirmed)
    XCTAssertEqual(report.cases.map(\.kind), [.normal, .m1, .m2])
    XCTAssertTrue(report.cases.allSatisfy(\.passed))
    XCTAssertEqual(report.cases.map { $0.checks.count }, [9, 8, 8])
    for result in report.cases.dropFirst() {
      XCTAssertEqual(result.failures.count, 2)
      XCTAssertTrue(result.failures.allSatisfy { $0.primary == 19 && $0.extended == 1555 })
    }
    let run = parent.appendingPathComponent(id, isDirectory: true)
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:
      run.appendingPathComponent(".build/topology").path), [])
    let reportURL = run.appendingPathComponent("report.json")
    let bytes = try Data(contentsOf: reportURL)
    XCTAssertLessThanOrEqual(bytes.count, 16_384)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    XCTAssertEqual(object["schema"] as? String, "paperlens-synthetic-packaged-db-v1")
    XCTAssertEqual(object["scope"] as? String, "synthetic_sql_behavior_only")
    XCTAssertEqual(object["runID"] as? String, id)
    XCTAssertEqual(object["behaviorPassed"] as? Bool, true)
    XCTAssertEqual(object["cleanupConfirmed"] as? Bool, true)
    XCTAssertEqual(object["sqliteOrigin"] as? String, "sqlite_origin_unverified")
    XCTAssertEqual(object["storyDone"] as? Bool, false)
    XCTAssertEqual(object["p2Passed"] as? Bool, false)
    let text = try XCTUnwrap(String(data: bytes, encoding: .utf8))
    for excluded in PackagedDBProbe.corpus + [root.path, "SELECT", "CREATE", "sourceID", "db.sqlite"] {
      XCTAssertFalse(text.contains(excluded))
    }
    var info = stat()
    XCTAssertEqual(lstat(reportURL.path, &info), 0)
    XCTAssertEqual(info.st_mode & 0o7777, 0o600)
    XCTAssertEqual(info.st_nlink, 1)
    // A completed run is immutable: no SQL, file adoption, or report overwrite on a second invocation.
    XCTAssertThrowsError(try SyntheticPackagedDBSmoke.run(parentURL: parent, runID: id))
    XCTAssertEqual(try Data(contentsOf: reportURL), bytes)
  }

  func testExistingOrSymlinkRunAndSymlinkParentPreserveUnrelatedFiles() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let parent = root.appendingPathComponent("runs", isDirectory: true)
    let external = root.appendingPathComponent("external", isDirectory: true)
    for directory in [parent, external] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
    }
    let sentinel = external.appendingPathComponent("sentinel")
    let bytes = Data("preserve unrelated synthetic content".utf8)
    try bytes.write(to: sentinel)
    let id = UUID().uuidString.lowercased()
    XCTAssertEqual(symlink(external.path, parent.appendingPathComponent(id).path), 0)
    XCTAssertThrowsError(try SyntheticPackagedDBFiles(parentURL: parent, runID: id))
    let linkedParent = root.appendingPathComponent("linked-parent", isDirectory: true)
    XCTAssertEqual(symlink(external.path, linkedParent.path), 0)
    XCTAssertThrowsError(try SyntheticPackagedDBFiles(parentURL: linkedParent,
      runID: UUID().uuidString.lowercased()))
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: external.path), ["sentinel"])
    XCTAssertEqual(try Data(contentsOf: sentinel), bytes)
  }

  func testUnsafeParentPermissionsAreRefusedWithoutRepair() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let parent = root.appendingPathComponent("runs", isDirectory: true)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o755])
    XCTAssertThrowsError(try SyntheticPackagedDBFiles(parentURL: parent,
      runID: UUID().uuidString.lowercased()))
    var info = stat()
    XCTAssertEqual(lstat(parent.path, &info), 0)
    XCTAssertEqual(info.st_mode & 0o7777, 0o755)
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path), [])
  }

  func testReportReservationNeverOverwritesOrFollowsExistingSymlink() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let parent = root.appendingPathComponent("runs", isDirectory: true)
    let id = UUID().uuidString.lowercased()
    let files = try SyntheticPackagedDBFiles(parentURL: parent, runID: id)
    let sentinel = root.appendingPathComponent("sentinel")
    let bytes = Data("preserve existing report target".utf8)
    try bytes.write(to: sentinel)
    let output = files.root.appendingPathComponent("report.json")
    XCTAssertEqual(symlink(sentinel.path, output.path), 0)
    XCTAssertThrowsError(try files.write(.init(runID: id, cases: [])))
    XCTAssertEqual(try Data(contentsOf: sentinel), bytes)
    var info = stat()
    XCTAssertEqual(lstat(output.path, &info), 0)
    XCTAssertEqual(info.st_mode & S_IFMT, S_IFLNK)
  }

  func testReplacedRunDirectoryCannotRedirectReportPublication() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let parent = root.appendingPathComponent("runs", isDirectory: true)
    let id = UUID().uuidString.lowercased()
    let files = try SyntheticPackagedDBFiles(parentURL: parent, runID: id)
    let retained = parent.appendingPathComponent("retained", isDirectory: true)
    try FileManager.default.moveItem(at: files.root, to: retained)
    try FileManager.default.createDirectory(at: files.root, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    let sentinel = files.root.appendingPathComponent("report.json")
    let bytes = Data("preserve replacement directory".utf8)
    try bytes.write(to: sentinel)
    XCTAssertThrowsError(try files.write(.init(runID: id, cases: [])))
    XCTAssertEqual(try Data(contentsOf: sentinel), bytes)
    XCTAssertFalse(FileManager.default.fileExists(atPath: retained.appendingPathComponent("report.json").path))
  }
}
