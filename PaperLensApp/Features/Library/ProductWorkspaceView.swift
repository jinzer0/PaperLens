import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers
#if SWIFT_PACKAGE
import ProviderRequest
#endif

/// Retained by the app composition, not recreated when a sheet or Reader is presented.
@MainActor
public final class ProductWorkspace: ObservableObject {
  public enum Sheet: Identifiable {
    case confirmation(LocalImportConfirmation), folders, settings
    public var id: String {
      switch self {
      case .confirmation(let value): return value.id.uuidString
      case .folders: return "folders"
      case .settings: return "settings"
      }
    }
  }
  public struct OpenReader: Identifiable {
    public let id: UUID
    public let session: ReaderSession
    public let annotationIdentity: AnnotationPaperIdentity
    public let metadataIdentity: ReaderMetadataIdentity?
  }
  public let organization: LibraryOrganizationService
  public let imports: FolderImportService
  public let settings: ProviderSettingsService
  public let urls: URLImportService
  public let annotations: AnnotationService
  public let metadata: ReaderMetadataService
  fileprivate let database: ProductDatabase
  private let readLeases: LibraryReadLeaseProvider
  private var scopedSource: URL?
  private var pendingConfirmation: UUID?
  @Published public var sheet: Sheet?
  @Published public var libraryFilter = OrganizationFilter()
  @Published public private(set) var reader: OpenReader?
  @Published public private(set) var revision = 0
  @Published public private(set) var preparing = false
  @Published public private(set) var opening = false
  @Published public private(set) var failure: String?

  public init(database: ProductDatabase, lifecycle: LocalLibraryLifecycle,
    connection: NativeAPIKeyConnection) throws {
    self.database = database
    annotations = AnnotationService(database: database)
    metadata = ReaderMetadataService(database: database)
    organization = LibraryOrganizationService(database: database, lifecycle: lifecycle)
    imports = FolderImportService(database: database, lifecycle: lifecycle)
    settings = ProviderSettingsService(connection: connection)
    urls = URLImportService(authority: try ProviderRequest(), grantWriter: {
      try await lifecycle.grantURLImportWriter(for: $0)
    })
    readLeases = LibraryReadLeaseProvider(lifecycle: lifecycle)
  }

  public func sortFacts() async throws -> [OrganizationSortFacts] {
    let database = database
    return try await Task.detached { try database.librarySortFacts() }.value
  }

  public func prepareImport(source: URL) async throws {
    guard !preparing, !opening, sheet == nil, reader == nil else { throw ProductWorkspaceError.busy }
    preparing = true
    defer { preparing = false }
    let scoped = source.startAccessingSecurityScopedResource()
    do {
      let confirmation = try await imports.prepare(source: source)
      if scoped { scopedSource = source }
      pendingConfirmation = confirmation.id
      sheet = .confirmation(confirmation)
      failure = nil
    } catch {
      if scoped { source.stopAccessingSecurityScopedResource() }
      throw error
    }
  }

  public func pickPDF() {
    guard !preparing, !opening, sheet == nil, reader == nil else { return }
    let picker = NSOpenPanel()
    picker.allowedContentTypes = [.pdf]
    picker.canChooseDirectories = false
    picker.allowsMultipleSelection = false
    guard picker.runModal() == .OK, let source = picker.url else { return }
    Task {
      do { try await prepareImport(source: source) }
      catch { failure = "PDF 확인 실패. 원본과 저장소 상태를 확인하세요: \(error)" }
    }
  }

  public func dismissSheet() {
    if let pendingConfirmation {
      Task { await imports.cancel(pendingConfirmation) }
    }
    pendingConfirmation = nil
    scopedSource?.stopAccessingSecurityScopedResource()
    scopedSource = nil
    revision += 1
  }

  public func acceptDroppedPDF(_ source: URL) {
    Task {
      do { try await prepareImport(source: source) }
      catch { failure = "PDF 확인 실패: \(error)" }
    }
  }

  public func openImportedURL(_ paperID: UUID) {
    Task {
      do {
        let facts = try await sortFacts()
        let snapshot = try await organization.snapshot(filter: .init(), facts: facts)
        guard let paper = snapshot.papers.first(where: { $0.id == paperID }) else {
          throw OrganizationError.stalePaper
        }
        try await open(paper)
      } catch { failure = "가져온 PDF를 열지 못했습니다: \(error)" }
    }
  }

  public func imported(_ paperID: UUID) {
    revision += 1
    do {
      let record = try database.libraryRecords().first(where: { $0.id == paperID })
      guard record?.status == .ready else {
        failure = "PDF 가져오기가 완료되지 않았습니다. 라이브러리의 실패 상태를 확인하세요."
        return
      }
      failure = nil
    } catch { failure = "가져온 PDF의 저장 상태를 확인하지 못했습니다: \(error)" }
  }

  public func open(_ paper: OrganizedPaper) async throws {
    guard reader == nil, sheet == nil, !preparing, !opening else { throw ProductWorkspaceError.busy }
    opening = true
    defer { opening = false }
    try await organization.admitOpen(paper)
    // Bind the selected generation at lease acquisition too, not just at the list's check.
    let provider = SelectedPaperReadLeases(base: readLeases, paper: paper)
    let identity = try database.annotationIdentity(paperID: paper.id)
    guard identity.generation == paper.generation else { throw AnnotationError.stalePaper }
    let metadataIdentity = try database.publishedMetadataPaperIdentity(paperID: paper.id)
    if let metadataIdentity {
      guard metadataIdentity.generation == identity.generation,
        metadataIdentity.pdfSHA256 == identity.pdfSHA256 else { throw ReaderMetadataError.staleIdentity }
    }
    reader = OpenReader(id: paper.id, session: ReaderSession(database: database, leaseProvider: provider),
      annotationIdentity: identity, metadataIdentity: metadataIdentity)
    failure = nil
  }

  public func returnToLibrary() {
    reader?.session.close() // Synchronously discards PDF/search/selection before closing the lease.
    reader = nil
    revision += 1
  }

  public func reportSaveFailure(_ error: Error) {
    failure = "읽기 위치를 저장하지 못했습니다: \(error)"
  }
}

public enum ProductWorkspaceError: Error { case busy }

@MainActor private final class SelectedPaperReadLeases: ReaderLeaseProvider {
  private let base: LibraryReadLeaseProvider
  private let paper: OrganizedPaper
  init(base: LibraryReadLeaseProvider, paper: OrganizedPaper) { self.base = base; self.paper = paper }
  func acquireReadLease(for snapshot: ReaderPaperSnapshot,
    onRevoked: @escaping @MainActor () -> Void) throws -> any ReaderReadLease {
    guard snapshot.paperID == paper.id, snapshot.generation == paper.generation else {
      throw ReaderError.revoked
    }
    return try base.acquireReadLease(for: snapshot, onRevoked: onRevoked)
  }
}

@MainActor
public struct ProductWorkspaceView: View {
  @ObservedObject private var workspace: ProductWorkspace
  @ObservedObject private var urls: URLImportService
  public init(workspace: ProductWorkspace) { self.workspace = workspace; urls = workspace.urls }
  public var body: some View {
    VStack(spacing: 0) {
      if let reader = workspace.reader {
        VStack(spacing: 0) {
          ParsingStatusView(database: workspace.database, paperID: reader.id)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
          Divider()
          NativeReaderView(paperID: reader.id, session: reader.session,
            annotationIdentity: reader.annotationIdentity, annotationService: workspace.annotations,
            metadataService: workspace.metadata, metadataIdentity: reader.metadataIdentity,
            onReturn: { workspace.returnToLibrary() },
            onSaveFailure: { workspace.reportSaveFailure($0) })
        }
        .id([reader.id, reader.annotationIdentity.generation])
      } else {
        HStack {
          Button("폴더 관리") { workspace.sheet = .folders }
          Button("Settings") { workspace.sheet = .settings }
          if workspace.preparing { ProgressView("PDF 확인 중") }
          Spacer()
        }.padding().disabled(workspace.preparing || workspace.opening)
        URLImportView(service: urls, folderService: workspace.imports,
          possibleDuplicate: { _ in true },
          openReader: { workspace.openImportedURL($0) },
          chooseLocalPDF: { workspace.pickPDF() },
          confirmLocalPDF: { workspace.acceptDroppedPDF($0) }) {
            LibraryBrowserView(service: workspace.organization,
              filter: $workspace.libraryFilter, refreshRevision: workspace.revision,
              sortFacts: { try await workspace.sortFacts() },
              openPaper: { try await workspace.open($0) }, importPDF: { workspace.pickPDF() })
          }
          .onChange(of: urls.state) {
            if case .ready(let paper) = urls.state { workspace.imported(paper) }
          }
      }
      if let failure = workspace.failure { Text(failure).foregroundStyle(.red).textSelection(.enabled) }
      Text("Codex 연결은 아직 연결되지 않았습니다. Agent 삭제 연결이 없어 삭제는 미완료 상태로 남습니다.")
        .font(.caption).foregroundStyle(.secondary).padding(8)
    }
    .sheet(item: $workspace.sheet, onDismiss: { workspace.dismissSheet() }) { sheet in
      switch sheet {
      case .confirmation(let confirmation):
        ImportConfirmationView(confirmation: confirmation, service: workspace.imports,
          imported: { workspace.imported($0) })
          .interactiveDismissDisabled()
      case .folders:
        VStack {
          FolderManagementView(service: workspace.imports)
          Button("닫기") { workspace.sheet = nil }
        }.padding().frame(minWidth: 420)
      case .settings:
        VStack {
          ProviderSettingsView(service: workspace.settings)
          Button("닫기") { workspace.sheet = nil }
        }.padding()
      }
    }
  }
}
