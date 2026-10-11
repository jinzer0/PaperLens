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
    public var mountIdentity: ReaderMountIdentity {
      ReaderMountIdentity(paperID: id, generation: annotationIdentity.generation,
        session: ObjectIdentifier(session))
    }
  }
  public struct ReaderMountIdentity: Hashable {
    let paperID: UUID
    let generation: UUID
    let session: ObjectIdentifier
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
  private var importPreparation: UUID?
  internal var beforeImportConfirmationInstallForOwnedFixtures: (@MainActor (LocalImportConfirmation) -> Void)?
  private var metadataReadRequest: UUID?
  private var installingSheet = false
  private var cleaningSheet = false
  @Published private var activeSheet: Sheet?
  @Published public private(set) var sheetCleanupPending = false
  public var sheet: Sheet? {
    get { activeSheet }
    set {
      if let newValue {
        guard activeSheet == nil, !sheetCleanupPending, !installingSheet, !cleaningSheet else { return }
        switch newValue {
        case .confirmation(let confirmation):
          guard preparing, pendingConfirmation == confirmation.id else { return }
        case .folders, .settings:
          guard !preparing else { return }
        }
        installingSheet = true
        defer { installingSheet = false }
        sheetCleanupPending = true
        activeSheet = newValue
      } else {
        activeSheet = nil
      }
    }
  }
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
    guard !preparing, !opening, !sheetCleanupPending, sheet == nil, reader == nil else { throw ProductWorkspaceError.busy }
    let destinationFolderID: UUID?
    switch libraryFilter.folder {
    case .folder(let id): destinationFolderID = id
    case .all, .unfiled: destinationFolderID = nil
    }
    let request = UUID()
    importPreparation = request
    preparing = true
    defer { if importPreparation == request { importPreparation = nil; preparing = false } }
    let scoped = source.startAccessingSecurityScopedResource()
    var returnedConfirmation: UUID?
    do {
      let confirmation = try await imports.prepare(source: source,
        destinationFolderID: destinationFolderID)
      returnedConfirmation = confirmation.id
      beforeImportConfirmationInstallForOwnedFixtures?(confirmation)
      try Task.checkCancellation()
      guard importPreparation == request, !opening, !sheetCleanupPending, sheet == nil, reader == nil else { throw CancellationError() }
      if scoped { scopedSource = source }
      pendingConfirmation = confirmation.id
      sheet = .confirmation(confirmation)
      failure = nil
    } catch {
      if scoped { source.stopAccessingSecurityScopedResource() }
      if let returnedConfirmation { await imports.cancel(returnedConfirmation) }
      throw error
    }
  }

  public func pickPDF() {
    guard !preparing, !opening, !sheetCleanupPending, sheet == nil, reader == nil else { return }
    let picker = NSOpenPanel()
    picker.allowedContentTypes = [.pdf]
    picker.canChooseDirectories = false
    picker.allowsMultipleSelection = false
    guard picker.runModal() == .OK, let source = picker.url else { return }
    Task {
      do { try await prepareImport(source: source) }
      catch { failure = "PDF 가져오기를 준비하지 못했습니다. 원본 PDF를 다시 선택하세요." }
    }
  }

  public func prepareRetry(source: URL, paperID: UUID, generation: UUID) async throws {
    guard !preparing, !opening, !sheetCleanupPending, sheet == nil, reader == nil else { throw ProductWorkspaceError.busy }
    let request = UUID()
    importPreparation = request
    preparing = true
    defer { if importPreparation == request { importPreparation = nil; preparing = false } }
    let scoped = source.startAccessingSecurityScopedResource()
    var returnedConfirmation: UUID?
    do {
      let confirmation = try await imports.prepareRetry(source: source,
        paperID: paperID, generation: generation)
      returnedConfirmation = confirmation.id
      beforeImportConfirmationInstallForOwnedFixtures?(confirmation)
      try Task.checkCancellation()
      guard importPreparation == request, !opening, !sheetCleanupPending, sheet == nil, reader == nil else { throw CancellationError() }
      if scoped { scopedSource = source }
      pendingConfirmation = confirmation.id
      sheet = .confirmation(confirmation)
      failure = nil
    } catch {
      if scoped { source.stopAccessingSecurityScopedResource() }
      if let returnedConfirmation { await imports.cancel(returnedConfirmation) }
      throw error
    }
  }

  public func pickRetryPDF(paperID: UUID, generation: UUID) {
    guard !preparing, !opening, !sheetCleanupPending, sheet == nil, reader == nil else { return }
    let picker = NSOpenPanel()
    picker.allowedContentTypes = [.pdf]
    picker.canChooseDirectories = false
    picker.allowsMultipleSelection = false
    guard picker.runModal() == .OK, let source = picker.url else { return }
    Task {
      do { try await prepareRetry(source: source, paperID: paperID, generation: generation) }
      catch { failure = "PDF 재시도를 준비하지 못했습니다. 작업 상태를 확인하고 PDF를 다시 선택하세요." }
    }
  }

  public func dismissSheet() {
    guard !cleaningSheet else { return }
    cleaningSheet = true
    defer { cleaningSheet = false }
    sheetCleanupPending = true
    activeSheet = nil
    importPreparation = nil
    preparing = false
    if let pendingConfirmation {
      Task { await imports.cancel(pendingConfirmation) }
    }
    pendingConfirmation = nil
    scopedSource?.stopAccessingSecurityScopedResource()
    scopedSource = nil
    revision += 1
    sheetCleanupPending = false
  }

  public func presentationDidDismiss() {
    guard sheetCleanupPending, activeSheet == nil, !installingSheet, !cleaningSheet else { return }
    dismissSheet()
  }

  public func acceptDroppedPDF(_ source: URL) {
    Task {
      do { try await prepareImport(source: source) }
      catch { failure = "PDF 가져오기를 준비하지 못했습니다. 원본 PDF를 다시 선택하세요." }
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
      } catch { failure = "가져온 PDF를 열지 못했습니다. 라이브러리에서 현재 상태를 확인하세요." }
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
    } catch { failure = "PDF 가져오기 상태를 확인하지 못했습니다. 라이브러리에서 현재 상태를 다시 확인하세요." }
  }

  public func open(_ paper: OrganizedPaper) async throws {
    guard reader == nil, sheet == nil, !sheetCleanupPending, !preparing, !opening else { throw ProductWorkspaceError.busy }
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
    metadataReadRequest = nil
    reader = OpenReader(id: paper.id, session: ReaderSession(database: database, leaseProvider: provider),
      annotationIdentity: identity, metadataIdentity: metadataIdentity)
    failure = nil
  }

  public func returnToLibrary() {
    metadataReadRequest = nil
    reader?.session.close() // Synchronously discards PDF/search/selection before closing the lease.
    reader = nil
    revision += 1
  }

  /// Intent from the mounted status view, never an authoritative revision supplied by it.
  /// False means pending admission: retain the intent for the existing poll to retry.
  /// True means reconciled or dismissed, not proof that metadata was published.
  @discardableResult public func refreshPublishedMetadata(for observed: OpenReader) async -> Bool {
    guard isCurrentReader(observed), !Task.isCancelled else { return true }
    let admission = observed.session.admissionState
    guard admission != .pending else { return false }
    let outcome = await readPublishedMetadataOutcome(for: observed)
    switch outcome {
    case .failure(let failed): return applyPublishedMetadataFailure(failed)
    case .success(let refresh):
      do { return try applyPublishedMetadata(refresh) }
      catch {
        return applyPublishedMetadataFailure(.init(observed: observed, admission: refresh.admission,
          request: refresh.request, error: error))
      }
    }
  }

  // Split only to exercise real GRDB reads that complete after close/reopen in tests.
  struct PublishedMetadataRefresh {
    let observed: OpenReader
    let admission: ReaderSessionAdmissionState
    let request: UUID
    let identity: ReaderMetadataIdentity?
  }

  struct PublishedMetadataFailure {
    let observed: OpenReader
    let admission: ReaderSessionAdmissionState
    let request: UUID
    let error: Error
  }

  enum PublishedMetadataOutcome {
    case success(PublishedMetadataRefresh), failure(PublishedMetadataFailure)
  }

  func readPublishedMetadataOutcome(for observed: OpenReader) async -> PublishedMetadataOutcome {
    let admission = observed.session.admissionState
    let request = beginMetadataRead()
    do { return .success(try await readPublishedMetadata(for: observed, admission: admission, request: request)) }
    catch { return .failure(.init(observed: observed, admission: admission, request: request, error: error)) }
  }

  func applyPublishedMetadataFailure(_ failed: PublishedMetadataFailure) -> Bool {
    let observed = failed.observed
    guard isCurrentReader(observed), !Task.isCancelled else { return true }
    guard metadataReadRequest == failed.request else { return false }
    guard observed.session.admissionState == failed.admission || observed.session.admissionState == .closed
    else { return false }
    if observed.session.currentPaper == nil {
      observed.session.close()
      reader = nil
    } else {
      reader = OpenReader(id: observed.id, session: observed.session,
        annotationIdentity: observed.annotationIdentity, metadataIdentity: nil)
    }
    failure = "논문 정보를 확인하지 못했습니다. 라이브러리에서 논문을 다시 열어 확인하세요."
    return true
  }

  func readPublishedMetadata(for observed: OpenReader) async throws -> PublishedMetadataRefresh {
    let admission = observed.session.admissionState
    let request = beginMetadataRead()
    return try await readPublishedMetadata(for: observed, admission: admission, request: request)
  }

  private func beginMetadataRead() -> UUID {
    let request = UUID()
    metadataReadRequest = request
    return request
  }

  private func readPublishedMetadata(for observed: OpenReader,
    admission: ReaderSessionAdmissionState, request: UUID) async throws -> PublishedMetadataRefresh {
    let database = database
    let paperID = observed.id
    let identity = try await Task.detached {
      try database.publishedMetadataPaperIdentity(paperID: paperID)
    }.value
    return PublishedMetadataRefresh(observed: observed, admission: admission, request: request, identity: identity)
  }

  @discardableResult func applyPublishedMetadata(_ refresh: PublishedMetadataRefresh) throws -> Bool {
    let observed = refresh.observed
    guard !Task.isCancelled, isCurrentReader(observed) else { return true }
    guard metadataReadRequest == refresh.request else { return false }
    if observed.session.admissionState == .closed { throw ReaderError.notOpen }
    guard observed.session.admissionState == refresh.admission,
      refresh.admission != .pending else { return false }
    do {
      try observed.session.withReadAccess {
        guard let paper = observed.session.currentPaper,
          paper.paperID == observed.id, paper.generation == observed.annotationIdentity.generation,
          try database.annotationIdentity(paperID: observed.id) == observed.annotationIdentity
        else { throw ReaderMetadataError.staleIdentity }
        // The detached read can race publication/removal. Only the sole DB's current
        // pointer may be advertised, and this recheck stays under actual Reader access.
        let current = try database.publishedMetadataPaperIdentity(paperID: observed.id)
        let identity = current == refresh.identity ? refresh.identity : current
        if let identity {
          guard identity.paperID == paper.paperID, identity.generation == paper.generation,
            identity.pdfSHA256 == observed.annotationIdentity.pdfSHA256,
            identity.pdfReference == paper.pdfReference
          else { throw ReaderMetadataError.staleIdentity }
        }
        guard isCurrentReader(observed), !Task.isCancelled, let reader,
          metadataReadRequest == refresh.request,
          observed.session.admissionState == refresh.admission,
          reader.metadataIdentity != identity else { return }
        self.reader = OpenReader(id: reader.id, session: reader.session,
          annotationIdentity: reader.annotationIdentity, metadataIdentity: identity)
      }
    } catch {
      guard isCurrentReader(observed), !Task.isCancelled else { return true }
      guard metadataReadRequest == refresh.request else { return false }
      // Ownership/hash denial cannot keep a document admitted under obsolete facts.
      if error as? ReaderMetadataError == .staleIdentity { observed.session.close() }
      throw error
    }
    return metadataReadRequest == refresh.request
  }

  private func isCurrentReader(_ observed: OpenReader) -> Bool {
    guard let reader else { return false }
    return reader.id == observed.id && reader.annotationIdentity.generation == observed.annotationIdentity.generation
      && reader.session === observed.session
  }

  public func reportSaveFailure(_ error: Error) {
    failure = "읽기 위치를 저장하지 못했습니다. 논문을 다시 열 때 위치를 확인하세요."
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
  @FocusState private var folderOpenerFocused: Bool
  @State private var mount: UUID?
  @State private var folderPresentation: FolderPresentation?

  private struct FolderPresentation {
    let id = UUID()
    let mount: UUID
    var appeared = false
  }

  public init(workspace: ProductWorkspace) { self.workspace = workspace; urls = workspace.urls }
  public var body: some View {
    let viewMount = mount
    let folderPresentationID = folderPresentation?.id
    VStack(spacing: 0) {
      if let reader = workspace.reader {
        NativeReaderView(paperID: reader.id, session: reader.session,
          annotationIdentity: reader.annotationIdentity, annotationService: workspace.annotations,
          metadataService: workspace.metadata, metadataIdentity: reader.metadataIdentity,
          parsingStatus: ParsingStatusView(database: workspace.database, paperID: reader.id,
            onUsableRevisionChange: { await workspace.refreshPublishedMetadata(for: reader) }),
          onReturn: { workspace.returnToLibrary() },
          onSaveFailure: { workspace.reportSaveFailure($0) })
        .id(reader.mountIdentity)
      } else {
        HStack {
          Button("폴더 관리") {
            guard let mount, folderPresentation == nil, workspace.sheet == nil,
              !workspace.sheetCleanupPending, !workspace.preparing, !workspace.opening,
              workspace.reader == nil else { return }
            folderPresentation = FolderPresentation(mount: mount)
            workspace.sheet = .folders
            if workspace.sheet?.id != "folders" { folderPresentation = nil }
          }.focused($folderOpenerFocused)
          Button("Settings") { workspace.sheet = .settings }
          if workspace.preparing { ProgressView("PDF 확인 중") }
          Spacer()
        }.padding().disabled(workspace.preparing || workspace.opening || workspace.sheetCleanupPending)
        URLImportView(service: urls, folderService: workspace.imports,
          possibleDuplicate: { _ in true },
          openReader: { workspace.openImportedURL($0) },
          chooseLocalPDF: { workspace.pickPDF() },
          confirmLocalPDF: { workspace.acceptDroppedPDF($0) }) {
            LibraryBrowserView(service: workspace.organization, folderService: workspace.imports,
              filter: $workspace.libraryFilter, refreshRevision: workspace.revision,
              sortFacts: { try await workspace.sortFacts() },
              readReadingRecords: { [annotations = workspace.annotations] paperID, generation in
                try await Task.detached {
                  try annotations.libraryReadingRecords(paperID: paperID, generation: generation)
                }.value
              },
              openPaper: { try await workspace.open($0) }, importPDF: { workspace.pickPDF() },
              retryImportPDF: { workspace.pickRetryPDF(paperID: $0, generation: $1) },
              manageFolders: { workspace.sheet = .folders })
          }
          .onChange(of: urls.state) {
            if case .ready(let paper) = urls.state { workspace.imported(paper) }
          }
      }
      if let failure = workspace.failure {
        Label(failure, systemImage: "exclamationmark.triangle")
          .foregroundStyle(.red).textSelection(.enabled)
      }
      Text("Codex 연결은 아직 연결되지 않았습니다. Agent 삭제 연결이 없어 삭제는 미완료 상태로 남습니다.")
        .font(.caption).foregroundStyle(.secondary).padding(8)
    }
    .onAppear { mount = UUID() }
    .onDisappear { mount = nil; folderPresentation = nil }
    .onChange(of: workspace.reader?.mountIdentity) { _, reader in
      if reader != nil { folderPresentation = nil }
    }
    .sheet(item: $workspace.sheet, onDismiss: {
      let presentation = folderPresentation
      workspace.presentationDidDismiss()
      guard let presentation, presentation.id == folderPresentationID,
        presentation.mount == viewMount, folderPresentation?.id == presentation.id else { return }
      folderPresentation = nil
      guard presentation.appeared, mount == presentation.mount,
        workspace.reader == nil, workspace.sheet == nil,
        !workspace.sheetCleanupPending, !workspace.preparing, !workspace.opening else { return }
      // Folder management has no pending import input/security scope to drain.
      // Local import confirmation deliberately has no focus receipt here.
      folderOpenerFocused = true
    }) { sheet in
      switch sheet {
      case .confirmation(let confirmation):
        ImportConfirmationView(confirmation: confirmation, service: workspace.imports,
          imported: { workspace.imported($0) })
          .interactiveDismissDisabled()
      case .folders:
        let presentationID = folderPresentation?.id
        VStack {
          FolderManagementView(service: workspace.imports)
          Button("닫기") { workspace.sheet = nil }
        }.padding().frame(minWidth: 420)
          .onAppear {
            guard let presentationID, folderPresentation?.id == presentationID,
              workspace.sheet?.id == "folders",
              folderPresentation?.mount == mount else { return }
            folderPresentation?.appeared = true
          }
      case .settings:
        VStack {
          ProviderSettingsView(service: workspace.settings)
          Button("닫기") { workspace.sheet = nil }
        }.padding()
      }
    }
  }
}
