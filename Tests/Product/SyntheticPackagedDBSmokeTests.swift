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
    for result in report.cases {
      let initial = try XCTUnwrap(result.initialProvenance)
      let reopened = try XCTUnwrap(result.reopenedProvenance)
      XCTAssertEqual(initial, reopened)
      XCTAssertTrue(initial.sameConnection)
      XCTAssertTrue(initial.symbolsBoundToImage)
      XCTAssertTrue(initial.sharedCacheImage)
      XCTAssertTrue(initial.metadataMatches)
      XCTAssertTrue(initial.verified)
      XCTAssertNotNil(initial.osBuild)
      XCTAssertEqual(initial.imageIdentity?.count, 64)
      XCTAssertNotNil(initial.sqliteVersion)
      XCTAssertLessThanOrEqual(initial.inspectedEntries, 256)
      XCTAssertLessThanOrEqual(initial.maxEntryBytes, 256)
      XCTAssertLessThanOrEqual(initial.compileOptions.count, 16)
      XCTAssertTrue(initial.compileOptions.contains("ENABLE_FTS5"))
    }
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
    XCTAssertEqual(object["schema"] as? String, "paperlens-synthetic-packaged-db-v2")
    XCTAssertEqual(object["scope"] as? String, "synthetic_sql_behavior_and_loaded_image")
    XCTAssertEqual(object["runID"] as? String, id)
    XCTAssertEqual(object["behaviorPassed"] as? Bool, true)
    XCTAssertEqual(object["cleanupConfirmed"] as? Bool, true)
    XCTAssertEqual(object["sqliteOrigin"] as? String, "apple-system")
    XCTAssertEqual(object["storyDone"] as? Bool, false)
    XCTAssertEqual(object["p2Passed"] as? Bool, false)
    let text = try XCTUnwrap(String(data: bytes, encoding: .utf8))
    for excluded in PackagedDBProbe.corpus + [root.path, "SELECT", "CREATE", "sourceID", "db.sqlite",
      "/usr/lib/", "dli_fbase", "callStackReturnAddresses"] {
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

  func testSourceIdentityProjectionPreservesTimestampFreeHashAndOfficialMarkers() {
    let sha1 = String(repeating: "a", count: 40)
    let sha3 = String(repeating: "b", count: 64)
    for suffix in [sha1, sha3, String(repeating: "a", count: 60) + "alt1",
      String(repeating: "b", count: 60) + "alt2", String(repeating: "c", count: 60) + "aapl"] {
      XCTAssertEqual(PackagedDBImageBinding.sourceSuffix("2026-01-01 12:34:56 " + suffix), suffix)
    }
    for source in [sha3, "2026-01-01 12:34:56 " + sha3.uppercased(),
      "2026-01-01 12:34:56 " + String(repeating: "a", count: 60) + "alt0",
      "2026-01-01 12:34:56 " + String(repeating: "a", count: 60) + "alt3",
      "2026-01-01 12:34:56 " + String(repeating: "a", count: 36) + "alt2",
      "2026-01-01 12:34:56 " + String(repeating: "a", count: 60) + "ALT2",
      "2026-01-01 12:34:56 " + String(repeating: "a", count: 60) + "AAPL",
      "2026-01-01 12:34:56 " + String(repeating: "a", count: 60) + "aap1",
      "2026-01-01 12:34:56 " + sha3 + "\n", "2026-01-01 12:34:56  " + sha3,
      "2026-01-01 12:34:56 " + String(repeating: "a", count: 257)] {
      XCTAssertNil(PackagedDBImageBinding.sourceSuffix(source))
    }
  }

  func testUnknownSourceDoesNotBecomeVerifiedFromSuccessfulImageBinding() {
    let observations = PackagedDBProvenance(sameConnection: true, symbolsBoundToImage: true,
      sharedCacheImage: true, metadataMatches: true, osBuild: "25G241",
      imageIdentity: String(repeating: "a", count: 64), sqliteVersion: "3.50.4",
      sqliteSourceId: nil, compileOptions: ["ENABLE_FTS5"], inspectedEntries: 1, maxEntryBytes: 11)
    XCTAssertFalse(observations.verified)
    var cases = SyntheticPackagedDBSmoke.Kind.allCases.map { kind in
      SyntheticPackagedDBSmoke.CaseResult(kind: kind, initialProvenance: observations,
        reopenedProvenance: observations)
    }
    XCTAssertEqual(SyntheticPackagedDBSmoke.Report(runID: UUID().uuidString.lowercased(), cases: cases)
      .sqliteOrigin, "sqlite_origin_unverified")
    cases[0].initialProvenance = nil
    XCTAssertEqual(SyntheticPackagedDBSmoke.Report(runID: UUID().uuidString.lowercased(), cases: cases)
      .sqliteOrigin, "sqlite_origin_unverified")
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
