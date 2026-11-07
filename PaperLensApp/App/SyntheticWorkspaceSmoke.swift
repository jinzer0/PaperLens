import Darwin
import Foundation
import SwiftUI
#if SWIFT_PACKAGE
import ProviderRequest
#endif

/// Explicit local UI diagnostic. This never constructs the production entry
/// composition, stores a provider selection, or represents authentication success.
enum SyntheticWorkspaceSmoke {
  static let flag = "--synthetic-workspace-smoke"
  enum Launch: Equatable { case absent, invalid, run(String) }
  static func launch(_ arguments: [String]) -> Launch {
    guard arguments.dropFirst().contains(flag) else { return .absent }
    let args = Array(arguments.dropFirst())
    guard args.count == 3, args[0] == flag, args[1] == "--run-id",
      let id = UUID(uuidString: args[2]), id.uuidString.lowercased() == args[2]
    else { return .invalid }
    return .run(args[2])
  }
}

@MainActor private final class RefusingWorkspaceProbe: NativeConnectionTestTransport {
  func probe(key: String, configuration: NativeOpenAIConfiguration,
    request: AuthorizedProviderRequest, authority: ProviderRequest) async throws -> NativeProbeResponse {
    throw LibrarySummaryError.providerUnavailable
  }
}

final class SyntheticWorkspaceFiles {
  let root: URL
  private(set) var source: URL?
  private let parentURL: URL
  private let id: String
  // Retained for diagnostic lifetime, including partial failures. No purge is claimed.
  private var retainedDescriptors: [Int32] = []
  init(parentURL: URL, runID: String) throws {
    guard let uuid = UUID(uuidString: runID), uuid.uuidString.lowercased() == runID,
      parentURL.isFileURL else { throw ProductEntryError.privateContainerUnavailable }
    self.parentURL = parentURL; id = runID
    root = parentURL.appendingPathComponent(runID, isDirectory: true)
  }
  func create() throws {
    guard let parent = TopologyFixtures.directory(parentURL, create: true) else {
      throw ProductEntryError.privateContainerUnavailable
    }
    retainedDescriptors.append(parent)
    var parentInfo = stat()
    guard TopologyFixtures.privateDirectory(parent, info: &parentInfo) else {
      throw ProductEntryError.privateContainerUnavailable
    }
    // Existing runs, symlinks and directories are never adopted or overwritten.
    guard mkdirat(parent, id, 0o700) == 0 else {
      throw ProductEntryError.privateContainerUnavailable
    }
    let directory = openat(parent, id, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard directory >= 0 else { throw ProductEntryError.privateContainerUnavailable }
    retainedDescriptors.append(directory)
    var info = stat()
    guard TopologyFixtures.privateDirectory(directory, info: &info),
      TopologyFixtures.matches(directory: parent, name: id, info: info) else {
      throw ProductEntryError.privateContainerUnavailable
    }
    let filename = "Synthetic Reader 8 pages.pdf"
    let fd = openat(directory, filename, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw ProductEntryError.privateContainerUnavailable }
    retainedDescriptors.append(fd)
    let bytes = SyntheticPDFGeometryCalibration.fixturePDF()
    try bytes.withUnsafeBytes { data in
      var offset = 0
      while offset < data.count {
        let count = write(fd, data.baseAddress!.advanced(by: offset), data.count - offset)
        guard count > 0 else { throw ProductEntryError.privateContainerUnavailable }
        offset += count
      }
    }
    guard close(fd) == 0 else { throw ProductEntryError.privateContainerUnavailable }
    retainedDescriptors.removeAll { $0 == fd }
    source = root.appendingPathComponent(filename)
  }
}

@MainActor private final class SyntheticWorkspaceModel: ObservableObject {
  @Published var workspace: ProductWorkspace?
  @Published var failed = false
  @Published var preparing = false
  private var started = false
  private var source: URL?
  private var retainedFiles: SyntheticWorkspaceFiles?

  func start(arguments: [String]) async {
    guard !started else { return }
    started = true
    do {
      guard case .run(let id) = SyntheticWorkspaceSmoke.launch(arguments),
        Bundle.main.bundleIdentifier == TopologyIdentity.main,
        let container = TopologyIdentity.container(TopologyIdentity.main)
      else { throw ProductEntryError.privateContainerUnavailable }
      let parentURL = container.appendingPathComponent(
        "Library/Application Support/PaperLensSyntheticWorkspace", isDirectory: true)
      let files = try SyntheticWorkspaceFiles(parentURL: parentURL, runID: id)
      retainedFiles = files
      try files.create()
      source = files.source
      let root = files.root
      let database = try ProductDatabase.open(at: root.appendingPathComponent("database"))
      let authority = try ProviderRequest()
      let lifecycle = try await LocalLibraryLifecycle.open(database: database,
        agentPurge: NativeOnlyAgentLibraryPurge(unsupportedPaperRoot: root.appendingPathComponent("agent-paper-data")))
      let slots = try APIKeySlotStore(directory: root.appendingPathComponent("unused-slots"))
      let connection = NativeAPIKeyConnection(configuration: try NativeOpenAIConfiguration(model: "synthetic-unconnected"),
        slots: slots, persistence: nil, transport: RefusingWorkspaceProbe(), authority: authority)
      let parsing = try MainPDFiumParsingComposition(lifecycle: lifecycle, authority: authority)
      workspace = try ProductWorkspace(database: database, lifecycle: lifecycle, connection: connection,
        parsing: parsing, diagnosticSource: source)
    } catch { failed = true }
  }

  func prepareSyntheticImport() async {
    guard let workspace, let source, !preparing else { return }
    preparing = true
    defer { preparing = false }
    do { _ = try await workspace.prepareImport(source: source) }
    catch { failed = true }
  }
}

@MainActor struct SyntheticWorkspaceSmokeView: View {
  @StateObject private var model = SyntheticWorkspaceModel()
  var body: some View {
    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 6) {
        Text("합성 Workspace UI 진단 · 인증 없음").font(.headline)
        Text("전용 합성 PDF의 가져오기 확인과 Reader만 검사합니다. 제품의 Provider 진입 검증이 아닙니다.")
          .font(.caption)
        Button("합성 PDF 가져오기") { Task { await model.prepareSyntheticImport() } }
          .disabled(model.workspace == nil || model.preparing)
      }.padding().frame(maxWidth: .infinity, alignment: .leading).background(.yellow.opacity(0.15))
      if let workspace = model.workspace {
        ProductWorkspaceView(workspace: workspace)
      } else if model.failed {
        Text("합성 진단 저장소를 만들지 못했습니다. 새 run ID와 전용 앱 실행을 확인하세요.").padding()
      } else { ProgressView("합성 진단 준비 중").padding() }
      if model.failed, model.workspace != nil { Text("합성 가져오기를 준비하지 못했습니다.").foregroundStyle(.red) }
    }
    .frame(minWidth: 900, minHeight: 680)
    .task { await model.start(arguments: CommandLine.arguments) }
  }
}
