import Combine
import Darwin
import Foundation
#if SWIFT_PACKAGE
import ProviderRequest
#endif
import SwiftUI

public enum ProductEntryError: Error {
  case privateContainerUnavailable, connectionRequired, connectionInUse
}

/// Production composition has no provider-free entry path. Tests inject only their own
/// private root and transport; constructing this object does not read a credential.
@MainActor
public final class ProductAppComposition: ObservableObject {
  private static var productionInstance: ProductAppComposition?
  public enum Phase {
    case loading, modelRequired, connection(NativeAPIKeyConnection)
    case library(LocalLibraryLifecycle), failed
  }
  @Published public private(set) var phase: Phase = .loading
  @Published public private(set) var entryFailed = false
  @Published public private(set) var workspace: ProductWorkspace?
  private let root: URL
  private let transport: any NativeConnectionTestTransport
  private var database: ProductDatabase?
  private var slots: APIKeySlotStore?
  private var lifecycle: LocalLibraryLifecycle?
  private var authority: ProviderRequest?
  private var connection: NativeAPIKeyConnection?
  private var started = false

  public init(root: URL, transport: any NativeConnectionTestTransport) {
    self.root = root
    self.transport = transport
  }

  public static func production() throws -> ProductAppComposition {
    if let productionInstance { return productionInstance }
    let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
      .resolvingSymlinksInPath()
    guard Bundle.main.bundleIdentifier == "io.github.jinzer0.PaperLens",
      home.path.hasSuffix("/Library/Containers/io.github.jinzer0.PaperLens/Data")
    else { throw ProductEntryError.privateContainerUnavailable }
    let instance = ProductAppComposition(
      root: home.appendingPathComponent("Library/Application Support/PaperLensProduct", isDirectory: true),
      transport: URLSessionOpenAIConnectionTransport())
    productionInstance = instance
    return instance
  }

  public func start() async {
    guard !started else { return }
    started = true
    do {
      try Self.preparePrivateRoot(root)
      let database = try ProductDatabase.open(at: root.appendingPathComponent("database", isDirectory: true))
      let slots = try APIKeySlotStore(directory: root.appendingPathComponent("api-key-slots", isDirectory: true))
      let authority = try ProviderRequest()
      // No Agent receipt is invented. Deletion remains failed/debt until a real peer is bound.
      let lifecycle = try await LocalLibraryLifecycle.open(database: database, agentPurge: nil)
      self.database = database
      self.slots = slots
      self.authority = authority
      self.lifecycle = lifecycle
      let persisted = try database.providerConfiguration()
      if persisted.slotID != nil, let model = persisted.model {
        try configure(model: model)
      } else {
        phase = .modelRequired
      }
    } catch {
      phase = .failed
    }
  }

  /// A new adapter is an explicit attempt, never automatic ABA conflict recovery.
  public func configure(model: String) throws {
    guard workspace == nil else { throw ProductEntryError.connectionInUse }
    let configuration = try NativeOpenAIConfiguration(model: model)
    guard let database, let slots, let authority else {
      throw ProductEntryError.privateContainerUnavailable
    }
    guard connection?.canReplaceOwner != false else { throw ProductEntryError.connectionInUse }
    try connection?.retireAfterDrain()
    let persistence = DatabaseAPIKeySelector(database: database, configuration: configuration)
    let connection = NativeAPIKeyConnection(configuration: configuration, slots: slots,
      persistence: persistence, transport: transport, authority: authority)
    self.connection = connection
    connection.restore()
    entryFailed = false
    phase = .connection(connection)
  }

  public func changeModel() {
    guard workspace == nil else { entryFailed = true; return }
    connection?.cancel()
    guard connection?.canReplaceOwner != false else {
      entryFailed = true
      return
    }
    entryFailed = false
    phase = .modelRequired
  }

  /// Only the explicit Continue action calls this. Durable selector and slot safety are
  /// checked again, rather than relying on a previously rendered success label.
  public func continueToLibrary() throws {
    guard case .connection(let connection) = phase, let lifecycle,
      connection.eligibleForEntry, connection.phase != .probing else {
      throw ProductEntryError.connectionRequired
    }
    let lease = try connection.acquireLease()
    let current: Bool
    do { current = try connection.mayPublish(lease) }
    catch {
      try connection.releaseAfterTermination(lease)
      throw error
    }
    try connection.releaseAfterTermination(lease)
    guard current else { throw ProductEntryError.connectionRequired }
    guard let database else { throw ProductEntryError.privateContainerUnavailable }
    if workspace == nil {
      workspace = try ProductWorkspace(database: database, lifecycle: lifecycle, connection: connection)
    }
    phase = .library(lifecycle)
  }

  public func confirmEntry() {
    do { try continueToLibrary() }
    catch { entryFailed = true }
  }

  private static func preparePrivateRoot(_ root: URL) throws {
    guard root.isFileURL,
      !root.pathComponents.contains("."), !root.pathComponents.contains("..") else {
      throw ProductEntryError.privateContainerUnavailable
    }
    var ancestor = root.deletingLastPathComponent()
    while ancestor.path != "/" {
      var existing = stat()
      if lstat(ancestor.path, &existing) == 0 {
        guard existing.st_mode & S_IFMT == S_IFDIR else {
          throw ProductEntryError.privateContainerUnavailable
        }
      } else if errno != ENOENT {
        throw ProductEntryError.privateContainerUnavailable
      }
      ancestor.deleteLastPathComponent()
    }
    let parent = root.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    var info = stat()
    if lstat(root.path, &info) != 0 {
      guard errno == ENOENT, mkdir(root.path, 0o700) == 0 else {
        throw ProductEntryError.privateContainerUnavailable
      }
    }
    guard lstat(root.path, &info) == 0, info.st_uid == geteuid(),
      info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o7777 == 0o700 else {
      throw ProductEntryError.privateContainerUnavailable
    }
  }
}

@MainActor
struct ProductRootView: View {
  @State private var composition: ProductAppComposition?
  @State private var startupFailed = false

  var body: some View {
    Group {
      if let composition {
        ProductCompositionView(composition: composition)
      } else if startupFailed {
        ContentUnavailableView("앱을 시작하지 못했습니다", systemImage: "exclamationmark.triangle",
          description: Text("전용 앱 컨테이너에서 PaperLens를 실행하세요."))
      } else {
        ProgressView("PaperLens 시작 중")
      }
    }
    .frame(minWidth: 760, minHeight: 540)
    .task {
      guard composition == nil, !startupFailed else { return }
      do {
        let created = try ProductAppComposition.production()
        composition = created
        await created.start()
      } catch { startupFailed = true }
    }
  }
}

@MainActor
private struct ProductCompositionView: View {
  @ObservedObject var composition: ProductAppComposition
  @State private var model = ""
  @State private var configurationFailed = false

  var body: some View {
    switch composition.phase {
    case .loading:
      ProgressView("라이브러리 준비 중")
    case .modelRequired:
      VStack(alignment: .leading, spacing: 16) {
        Text("OpenAI 연결 설정").font(.largeTitle)
        Text("사용할 모델 ID를 명시적으로 입력하세요. 모델 제한 인증을 의미하지 않습니다.")
        TextField("모델 ID", text: $model).textFieldStyle(.roundedBorder)
        Button("API 키 입력으로 계속") {
          do { try composition.configure(model: model); configurationFailed = false }
          catch { configurationFailed = true }
        }.disabled(model.isEmpty)
        if configurationFailed { Text("모델 설정을 확인하세요.").foregroundStyle(.red) }
      }.padding(24).frame(maxWidth: 640)
    case .connection(let connection):
      NativeEntryView(composition: composition, connection: connection)
    case .library:
      if let workspace = composition.workspace {
        ProductWorkspaceView(workspace: workspace)
      } else {
        ContentUnavailableView("Workspace unavailable", systemImage: "exclamationmark.triangle")
      }
    case .failed:
      ContentUnavailableView("저장소를 열지 못했습니다", systemImage: "exclamationmark.triangle",
        description: Text("앱 전용 저장소의 권한 또는 저장된 상태를 확인하세요. 안전하지 않은 저장소는 사용하지 않습니다."))
    }
  }
}

@MainActor
private struct NativeEntryView: View {
  @ObservedObject var composition: ProductAppComposition
  @ObservedObject var connection: NativeAPIKeyConnection

  var body: some View {
    VStack(alignment: .leading) {
      APIKeyConnectionView(connection: connection)
      HStack {
        Button("모델 변경 / 명시적 재시도") { composition.changeModel() }
        Spacer()
        Button("Continue") { composition.confirmEntry() }
          .disabled(!connection.eligibleForEntry || connection.phase == .probing)
      }.padding(.horizontal, 24)
      if composition.entryFailed {
        Text("저장된 연결을 다시 확인하세요. 라이브러리에 진입하지 않았습니다.")
          .foregroundStyle(.red).padding(.horizontal, 24)
      }
      Text("현재 Native API 키 경로만 제공됩니다. Codex 연결과 실제 모델 제한 검증은 완료되지 않았습니다. Agent 삭제 연결이 없어 삭제는 미완료 상태로 남습니다.")
        .font(.caption).foregroundStyle(.secondary).padding(24)
    }
  }
}
