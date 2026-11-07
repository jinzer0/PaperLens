import Darwin
import Foundation
import PDFKit
import XCTest
#if SWIFT_PACKAGE
import ProviderRequest
#endif
@testable import PaperLensProduct

@MainActor private final class SmokeRefusingProbe: NativeConnectionTestTransport {
  func probe(key: String, configuration: NativeOpenAIConfiguration,
    request: AuthorizedProviderRequest, authority: ProviderRequest) async throws -> NativeProbeResponse {
    XCTFail("Synthetic workspace must never request provider authentication")
    throw LibrarySummaryError.providerUnavailable
  }
}

@MainActor final class SyntheticWorkspaceSmokeTests: XCTestCase {
  func testLaunchRequiresExactExplicitModeAndFreshCanonicalRunIdentifier() {
    let id = UUID().uuidString.lowercased()
    let args = ["PaperLens", SyntheticWorkspaceSmoke.flag, "--run-id", id]
    XCTAssertEqual(SyntheticWorkspaceSmoke.launch(args), .run(id))
    XCTAssertEqual(SyntheticWorkspaceSmoke.launch(["PaperLens"]), .absent)
    XCTAssertEqual(SyntheticWorkspaceSmoke.launch(Array(args.dropLast())), .invalid)
    XCTAssertEqual(SyntheticWorkspaceSmoke.launch(args + ["--topology-smoke"]), .invalid)
    XCTAssertEqual(SyntheticWorkspaceSmoke.launch(["PaperLens", SyntheticWorkspaceSmoke.flag,
      "--run-id", id.uppercased()]), .invalid)
    XCTAssertEqual(SyntheticWorkspaceSmoke.launch(["PaperLens", SyntheticWorkspaceSmoke.flag,
      "--run-id", "../existing"]), .invalid)
  }

  func testSyntheticSourceIsEightPagesAndExistingRunOrSymlinkIsNeverAdopted() throws {
    let requested = FileManager.default.temporaryDirectory
      .appendingPathComponent("paperlens-synthetic-workspace-test-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: requested, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    let physical = try XCTUnwrap(realpath(requested.path, nil))
    defer { free(physical) }
    let root = URL(fileURLWithPath: String(cString: physical), isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let parent = root.appendingPathComponent("runs")
    let id = UUID().uuidString.lowercased()
    let owner = try SyntheticWorkspaceFiles(parentURL: parent, runID: id)
    try owner.create()
    let source = try XCTUnwrap(owner.source)
    let bytes = try Data(contentsOf: source)
    XCTAssertEqual(bytes, SyntheticPDFGeometryCalibration.fixturePDF())
    XCTAssertEqual(try XCTUnwrap(PDFDocument(url: source)).pageCount, 8)
    let duplicate = try SyntheticWorkspaceFiles(parentURL: parent, runID: id)
    XCTAssertThrowsError(try duplicate.create())
    XCTAssertEqual(try Data(contentsOf: source), bytes)

    let external = root.appendingPathComponent("unrelated")
    try FileManager.default.createDirectory(at: external, withIntermediateDirectories: false)
    let sentinel = external.appendingPathComponent("sentinel")
    let unrelatedBytes = Data("preserve-synthetic-unrelated-content".utf8)
    try unrelatedBytes.write(to: sentinel)
    let linkedID = UUID().uuidString.lowercased()
    XCTAssertEqual(symlink(external.path, parent.appendingPathComponent(linkedID).path), 0)
    let linked = try SyntheticWorkspaceFiles(parentURL: parent, runID: linkedID)
    XCTAssertThrowsError(try linked.create())
    XCTAssertEqual(try Data(contentsOf: sentinel), unrelatedBytes)
    XCTAssertFalse(FileManager.default.fileExists(atPath:
      external.appendingPathComponent("Synthetic Reader 8 pages.pdf").path))
  }

  func testDiagnosticWorkspaceAdmitsOnlyGeneratedSourceAndRefusesURLWriterBeforeNetwork() async throws {
    let requested = FileManager.default.temporaryDirectory
      .appendingPathComponent("paperlens-synthetic-source-guard-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: requested, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    let physical = try XCTUnwrap(realpath(requested.path, nil))
    defer { free(physical); try? FileManager.default.removeItem(at: requested) }
    let parent = URL(fileURLWithPath: String(cString: physical), isDirectory: true)
    let files = try SyntheticWorkspaceFiles(parentURL: parent, runID: UUID().uuidString.lowercased())
    try files.create()
    let source = try XCTUnwrap(files.source)
    let database = try ProductDatabase.open(at: files.root.appendingPathComponent("database"))
    let lifecycle = try await LocalLibraryLifecycle.open(database: database)
    let authority = try ProviderRequest()
    let connection = NativeAPIKeyConnection(configuration: try NativeOpenAIConfiguration(model: "synthetic-unconnected"),
      slots: try APIKeySlotStore(directory: files.root.appendingPathComponent("slots")),
      persistence: nil, transport: SmokeRefusingProbe(), authority: authority)
    let workspace = try ProductWorkspace(database: database, lifecycle: lifecycle, connection: connection,
      diagnosticSource: source)
    let unrelated = parent.appendingPathComponent("never-open-this.pdf")
    do {
      _ = try await workspace.prepareImport(source: unrelated)
      XCTFail("Unrelated source was admitted")
    } catch ProductWorkspaceError.diagnosticSourceRequired { }
    do {
      try await workspace.prepareRetry(source: unrelated, paperID: UUID(), generation: UUID())
      XCTFail("Unrelated retry source was admitted")
    } catch ProductWorkspaceError.diagnosticSourceRequired { }
    _ = try await workspace.prepareImport(source: source)
    _ = await workspace.dismissSheet()?.value
    try workspace.urls.prepare("https://synthetic.invalid/never-request.pdf", destination: "Synthetic",
      possibleDuplicate: false)
    let confirmation = try XCTUnwrap(workspace.urls.confirmation)
    workspace.urls.continueImport(confirmationID: confirmation.id)
    for _ in 0..<200 {
      if workspace.urls.state == .failed(.writerUnavailable) { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTAssertEqual(workspace.urls.state, .failed(.writerUnavailable))
    XCTAssertFalse(connection.eligibleForEntry)
    XCTAssertNil(try database.providerConfiguration().kind)
    XCTAssertEqual(try Data(contentsOf: source), SyntheticPDFGeometryCalibration.fixturePDF())
  }
}
