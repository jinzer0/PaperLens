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
    case confirmation(LocalImportConfirmation)
    case folders, settings
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
      ReaderMountIdentity(
        paperID: id, generation: annotationIdentity.generation,
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
  public let parsing: MainPDFiumParsingComposition?
  public let summaries: LibrarySummaryCoordinator
  public let deletionPeerAvailable: Bool
  public var parsingRecoveryCoordinator: ParsingRecoveryCoordinator? {
    parsing?.recoveryCoordinator
  }
  fileprivate let database: ProductDatabase
  private let readLeases: LibraryReadLeaseProvider
  private var scopedSource: URL?
  private var pendingConfirmation: UUID?
  private var confirmationCancellation: (id: UUID, task: Task<UUID, Never>)?
  private var importPreparation: UUID?
  internal var beforeImportConfirmationInstallForOwnedFixtures:
    (@MainActor (LocalImportConfirmation) -> Void)?
  private var metadataReadRequest: UUID?
  private var installingSheet = false
  private var cleaningSheet = false
  @Published private var activeSheet: Sheet?
  @Published public private(set) var sheetCleanupPending = false
  public var sheet: Sheet? {
    get { activeSheet }
    set {
      if let newValue {
        guard activeSheet == nil, !sheetCleanupPending, !installingSheet, !cleaningSheet else {
          return
        }
        switch newValue {
        case .confirmation(let confirmation):
          guard preparing, pendingConfirmation == confirmation.id else { return }
        case .folders, .settings:
          guard !preparing, !opening, reader == nil else { return }
        }
        installingSheet = true
        defer { installingSheet = false }
        confirmationCancellation = nil
        sheetCleanupPending = true
        activeSheet = newValue
      } else {
        activeSheet = nil
      }
    }
  }
  @Published public var libraryFilter = OrganizationFilter()
  @Published public private(set) var reader: OpenReader?
  @Published private(set) var latestLocalImport: UUID?
  @Published public private(set) var revision = 0
  @Published public private(set) var preparing = false
  @Published public private(set) var opening = false
  @Published public private(set) var failure: String?

  public init(
    database: ProductDatabase, lifecycle: LocalLibraryLifecycle,
    connection: NativeAPIKeyConnection, codex: NativeCodexConnection? = nil,
    parsing: MainPDFiumParsingComposition? = nil
  ) throws {
    self.database = database
    if let parsing {
      guard parsing.lifecycle === lifecycle,
        parsing.service.database === database else { throw ExtractionError.staleAttempt }
    }
    self.parsing = parsing
    annotations = AnnotationService(database: database)
    metadata = ReaderMetadataService(database: database)
    organization = LibraryOrganizationService(database: database, lifecycle: lifecycle)
    imports = FolderImportService(database: database, lifecycle: lifecycle)
    settings = ProviderSettingsService(connection: connection, codex: codex)
    urls = URLImportService(
      authority: try ProviderRequest(),
      grantWriter: {
        try await lifecycle.grantURLImportWriter(for: $0)
      })
    let readLeases = LibraryReadLeaseProvider(lifecycle: lifecycle)
    self.readLeases = readLeases
    deletionPeerAvailable = lifecycle.deletionPeerAvailable
    let summaryAuthority = try ProviderRequest()
    summaries = LibrarySummaryCoordinator(database: database, epoch: lifecycle.epoch,
      leases: readLeases, authority: summaryAuthority,
      provider: SelectedLibrarySummaryProvider(database: database,
        apiKey: NativeAPIKeySummaryProvider(connection: connection, authority: summaryAuthority),
        chatGPT: NativeCodexSummaryProvider(connection: codex, authority: summaryAuthority)))
  }

  public func generateSummary(for paper: OrganizedPaper, outputLanguage: String) async throws {
    _ = try await summaries.generate(paperID: paper.id, generation: paper.generation,
      outputLanguage: outputLanguage)
    revision += 1
  }

  public func sortFacts() async throws -> [OrganizationSortFacts] {
    let database = database
    return try await Task.detached { try database.librarySortFacts() }.value
  }

  @discardableResult public func prepareImport(source: URL) async throws -> UUID {
    guard !preparing, !opening, !sheetCleanupPending, sheet == nil, reader == nil else {
      throw ProductWorkspaceError.busy
    }
    confirmationCancellation = nil
    let destinationFolderID: UUID?
    switch libraryFilter.folder {
    case .folder(let id): destinationFolderID = id
    case .all, .unfiled: destinationFolderID = nil
    }
    let request = UUID()
    importPreparation = request
    preparing = true
    defer {
      if importPreparation == request {
        importPreparation = nil
        preparing = false
      }
    }
    let scoped = source.startAccessingSecurityScopedResource()
    var returnedConfirmation: UUID?
    do {
      let confirmation = try await imports.prepare(
        source: source,
        destinationFolderID: destinationFolderID)
      returnedConfirmation = confirmation.id
      beforeImportConfirmationInstallForOwnedFixtures?(confirmation)
      try Task.checkCancellation()
      guard importPreparation == request, !opening, !sheetCleanupPending, sheet == nil,
        reader == nil
      else { throw CancellationError() }
      if scoped { scopedSource = source }
      pendingConfirmation = confirmation.id
      sheet = .confirmation(confirmation)
      failure = nil
      return confirmation.id
    } catch {
      if scoped { source.stopAccessingSecurityScopedResource() }
      if let returnedConfirmation { await imports.cancel(returnedConfirmation) }
      throw error
    }
  }

  @discardableResult public func pickPDF() -> Task<UUID?, Never>? {
    guard !preparing, !opening, !sheetCleanupPending, sheet == nil, reader == nil else {
      return nil
    }
    confirmationCancellation = nil
    let picker = NSOpenPanel()
    picker.allowedContentTypes = [.pdf]
    picker.canChooseDirectories = false
    picker.allowsMultipleSelection = false
    guard picker.runModal() == .OK, let source = picker.url else { return nil }
    return Task {
      do { return try await prepareImport(source: source) } catch {
        failure = "PDF 가져오기를 준비하지 못했습니다. 원본 PDF를 다시 선택하세요."
        return nil
      }
    }
  }

  public func prepareRetry(source: URL, paperID: UUID, generation: UUID) async throws {
    guard !preparing, !opening, !sheetCleanupPending, sheet == nil, reader == nil else {
      throw ProductWorkspaceError.busy
    }
    confirmationCancellation = nil
    let request = UUID()
    importPreparation = request
    preparing = true
    defer {
      if importPreparation == request {
        importPreparation = nil
        preparing = false
      }
    }
    let scoped = source.startAccessingSecurityScopedResource()
    var returnedConfirmation: UUID?
    do {
      let confirmation = try await imports.prepareRetry(
        source: source,
        paperID: paperID, generation: generation)
      returnedConfirmation = confirmation.id
      beforeImportConfirmationInstallForOwnedFixtures?(confirmation)
      try Task.checkCancellation()
      guard importPreparation == request, !opening, !sheetCleanupPending, sheet == nil,
        reader == nil
      else { throw CancellationError() }
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
    confirmationCancellation = nil
    let picker = NSOpenPanel()
    picker.allowedContentTypes = [.pdf]
    picker.canChooseDirectories = false
    picker.allowsMultipleSelection = false
    guard picker.runModal() == .OK, let source = picker.url else { return }
    Task {
      do { try await prepareRetry(source: source, paperID: paperID, generation: generation) } catch
      { failure = "PDF 재시도를 준비하지 못했습니다. 작업 상태를 확인하고 PDF를 다시 선택하세요." }
    }
  }

  @discardableResult public func dismissSheet() -> Task<UUID, Never>? {
    if !installingSheet, !preparing, importPreparation == nil, activeSheet == nil,
      let confirmationCancellation
    {
      return confirmationCancellation.task
    }
    guard !cleaningSheet else { return nil }
    cleaningSheet = true
    sheetCleanupPending = true
    activeSheet = nil
    importPreparation = nil
    preparing = false
    let confirmationID = pendingConfirmation
    pendingConfirmation = nil
    scopedSource?.stopAccessingSecurityScopedResource()
    scopedSource = nil
    revision += 1
    if let confirmationID {
      // Cancellation acknowledges only this ephemeral intent, not a consumed producer.
      // Do not abandon owner cleanup when a caller cancels this retained task.
      let task = Task { @MainActor in
        await imports.cancel(confirmationID)
        if confirmationCancellation?.id == confirmationID {
          cleaningSheet = false
          // Last mutation: synchronous subscribers may now admit a new operation.
          sheetCleanupPending = false
        }
        return confirmationID
      }
      confirmationCancellation = (confirmationID, task)
      return task
    }
    sheetCleanupPending = false
    cleaningSheet = false
    return nil
  }

  @discardableResult public func presentationDidDismiss(confirmationID: UUID? = nil) -> Task<
    UUID, Never
  >? {
    guard activeSheet == nil, !installingSheet, !preparing, importPreparation == nil else {
      return nil
    }
    if let confirmationID {
      if let confirmationCancellation {
        guard confirmationCancellation.id == confirmationID else { return nil }
        return confirmationCancellation.task
      }
      guard pendingConfirmation == confirmationID else { return nil }
    } else {
      guard pendingConfirmation == nil, confirmationCancellation == nil else { return nil }
    }
    guard sheetCleanupPending, !cleaningSheet else { return nil }
    return dismissSheet()
  }

  public func acceptDroppedPDF(_ source: URL) {
    Task {
      do { _ = try await prepareImport(source: source) } catch {
        failure = "PDF 가져오기를 준비하지 못했습니다. 원본 PDF를 다시 선택하세요."
      }
    }
  }

  public func openImportedURL(_ paperID: UUID) {
    Task { await openImportedPDF(paperID) }
  }

  func openImportedPDF(_ paperID: UUID) async {
    guard canOpenReader else { return }
    do {
      try await openReader {
        let facts = try await sortFacts()
        let snapshot = try await organization.snapshot(filter: .init(), facts: facts)
        guard let paper = snapshot.papers.first(where: { $0.id == paperID }) else {
          throw OrganizationError.stalePaper
        }
        return paper
      }
    } catch { failure = "가져온 PDF를 열지 못했습니다. 라이브러리에서 현재 상태를 확인하세요." }
  }

  @discardableResult public func imported(
    _ paperID: UUID, localConfirmationID: UUID? = nil
  ) -> Task<Void, Never>? {
    revision += 1
    do {
      let record = try database.libraryRecords().first(where: { $0.id == paperID })
      guard record?.status == .ready else {
        failure = "PDF 가져오기가 완료되지 않았습니다. 라이브러리의 실패 상태를 확인하세요."
        return nil
      }
      failure = nil
      if let localConfirmationID, pendingConfirmation == localConfirmationID {
        latestLocalImport = paperID
      }
      if let parsing {
        return Task {
          // Parsing reports its own persisted outcome. Reader admission does not
          // depend on completion, nor does failure become an automatic retry.
          do { _ = try await parsing.parseImportedPaper(paperID) }
          catch { }
        }
      }
    } catch { failure = "PDF 가져오기 상태를 확인하지 못했습니다. 라이브러리에서 현재 상태를 다시 확인하세요." }
    return nil
  }

  public func open(_ paper: OrganizedPaper) async throws {
    try await openReader { paper }
  }

  private var canOpenReader: Bool {
    reader == nil && sheet == nil && !sheetCleanupPending && !preparing && !opening
  }

  private func openReader(resolvePaper: () async throws -> OrganizedPaper) async throws {
    guard canOpenReader else { throw ProductWorkspaceError.busy }
    confirmationCancellation = nil
    opening = true
    defer { opening = false }
    let paper = try await resolvePaper()
    try await organization.admitOpen(paper)
    // Bind the selected generation at lease acquisition too, not just at the list's check.
    let provider = SelectedPaperReadLeases(base: readLeases, paper: paper)
    let identity = try database.annotationIdentity(paperID: paper.id)
    guard identity.generation == paper.generation else { throw AnnotationError.stalePaper }
    let metadataIdentity = try database.publishedMetadataPaperIdentity(paperID: paper.id)
    if let metadataIdentity {
      guard metadataIdentity.generation == identity.generation,
        metadataIdentity.pdfSHA256 == identity.pdfSHA256
      else { throw ReaderMetadataError.staleIdentity }
    }
    metadataReadRequest = nil
    reader = OpenReader(
      id: paper.id, session: ReaderSession(database: database, leaseProvider: provider),
      annotationIdentity: identity, metadataIdentity: metadataIdentity)
    if latestLocalImport == paper.id { latestLocalImport = nil }
    failure = nil
  }

  public func returnToLibrary() {
    metadataReadRequest = nil
    reader?.session.close()  // Synchronously discards PDF/search/selection before closing the lease.
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
      do { return try applyPublishedMetadata(refresh) } catch {
        return applyPublishedMetadataFailure(
          .init(
            observed: observed, admission: refresh.admission,
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
    case success(PublishedMetadataRefresh)
    case failure(PublishedMetadataFailure)
  }

  func readPublishedMetadataOutcome(for observed: OpenReader) async -> PublishedMetadataOutcome {
    let admission = observed.session.admissionState
    let request = beginMetadataRead()
    do {
      return .success(
        try await readPublishedMetadata(for: observed, admission: admission, request: request))
    } catch {
      return .failure(
        .init(observed: observed, admission: admission, request: request, error: error))
    }
  }

  func applyPublishedMetadataFailure(_ failed: PublishedMetadataFailure) -> Bool {
    let observed = failed.observed
    guard isCurrentReader(observed), !Task.isCancelled else { return true }
    guard metadataReadRequest == failed.request else { return false }
    guard
      observed.session.admissionState == failed.admission
        || observed.session.admissionState == .closed
    else { return false }
    if observed.session.currentPaper == nil {
      observed.session.close()
      reader = nil
    } else {
      reader = OpenReader(
        id: observed.id, session: observed.session,
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

  private func readPublishedMetadata(
    for observed: OpenReader,
    admission: ReaderSessionAdmissionState, request: UUID
  ) async throws -> PublishedMetadataRefresh {
    let database = database
    let paperID = observed.id
    let identity = try await Task.detached {
      try database.publishedMetadataPaperIdentity(paperID: paperID)
    }.value
    return PublishedMetadataRefresh(
      observed: observed, admission: admission, request: request, identity: identity)
  }

  @discardableResult func applyPublishedMetadata(_ refresh: PublishedMetadataRefresh) throws -> Bool
  {
    let observed = refresh.observed
    guard !Task.isCancelled, isCurrentReader(observed) else { return true }
    guard metadataReadRequest == refresh.request else { return false }
    if observed.session.admissionState == .closed { throw ReaderError.notOpen }
    guard observed.session.admissionState == refresh.admission,
      refresh.admission != .pending
    else { return false }
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
          reader.metadataIdentity != identity
        else { return }
        self.reader = OpenReader(
          id: reader.id, session: reader.session,
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
    return reader.id == observed.id
      && reader.annotationIdentity.generation == observed.annotationIdentity.generation
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
  init(base: LibraryReadLeaseProvider, paper: OrganizedPaper) {
    self.base = base
    self.paper = paper
  }
  func acquireReadLease(
    for snapshot: ReaderPaperSnapshot,
    onRevoked: @escaping @MainActor () -> Void
  ) throws -> any ReaderReadLease {
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
  @FocusState private var settingsOpenerFocused: Bool
  @FocusState private var localPDFFocused: Bool
  @State private var mount: UUID?
  @State private var toolbarPresentation: ToolbarPresentation?
  @State private var nativeSlot: NativeSlot?
  @State private var directIntent: DirectIntent?

  private struct NativeSlot {
    let id = UUID()
    let mount: UUID
    let sheet: ProductWorkspace.Sheet
    let confirmationID: UUID?
    let directIntentID: UUID?
    let toolbarPresentationID: UUID?
    var appeared = false
    var cancelled: UUID?
    var continued: UUID?
  }

  private struct DirectIntent {
    let id: UUID
    let mount: UUID
    var invalidated = false
    var preparationFinished = false
    var preparedID: UUID?
    var slotID: UUID?
    var confirmationID: UUID?
    var appeared = false
    var dismissed = false
    var cancelled: UUID?
    var continued: UUID?
    var cancellationReturned: UUID?
  }

  private struct ToolbarPresentation {
    enum Kind {
      case folders, settings

      var sheet: ProductWorkspace.Sheet {
        switch self {
        case .folders: return .folders
        case .settings: return .settings
        }
      }

      func matches(_ sheet: ProductWorkspace.Sheet) -> Bool {
        switch (self, sheet) {
        case (.folders, .folders), (.settings, .settings): return true
        default: return false
        }
      }
    }

    let id = UUID()
    let mount: UUID
    let kind: Kind
    var appeared = false
  }

  public init(workspace: ProductWorkspace) {
    self.workspace = workspace
    urls = workspace.urls
  }
  public var body: some View {
    let slot = nativeSlot
    VStack(spacing: 0) {
      if let reader = workspace.reader {
        NativeReaderView(
          paperID: reader.id, session: reader.session,
          annotationIdentity: reader.annotationIdentity, annotationService: workspace.annotations,
          metadataService: workspace.metadata, metadataIdentity: reader.metadataIdentity,
          parsingStatus: ParsingStatusView(
            database: workspace.database, paperID: reader.id,
            coordinator: workspace.parsingRecoveryCoordinator,
            onUsableRevisionChange: { await workspace.refreshPublishedMetadata(for: reader) }),
          onReturn: { workspace.returnToLibrary() },
          onSaveFailure: { workspace.reportSaveFailure($0) }
        )
        .id(reader.mountIdentity)
      } else {
        HStack {
          Button("폴더 관리") { openToolbar(.folders) }.focused($folderOpenerFocused)
          Button("Settings") { openToolbar(.settings) }.focused($settingsOpenerFocused)
          if let paperID = workspace.latestLocalImport {
            Button("가져온 PDF 열기") { Task { await workspace.openImportedPDF(paperID) } }
          }
          if workspace.preparing { ProgressView("PDF 확인 중") }
          Spacer()
        }.padding().disabled(
          workspace.preparing || workspace.opening || workspace.sheetCleanupPending)
        URLImportView(
          service: urls, folderService: workspace.imports,
          possibleDuplicate: { _ in true },
          openReader: { workspace.openImportedURL($0) },
          localPDFFocused: $localPDFFocused,
          localIntentInvalidation: Binding(
            get: {
              directIntent?.invalidated == true ? directIntent?.id : nil
            },
            set: { id in
              guard let id, directIntent?.id == id else { return }
              directIntent?.invalidated = true
            }),
          chooseLocalPDF: { chooseLocalPDF($0) },
          confirmLocalPDF: {
            invalidateDirectIntent()
            workspace.acceptDroppedPDF($0)
          }
        ) {
          LibraryBrowserView(
            service: workspace.organization, folderService: workspace.imports,
            filter: $workspace.libraryFilter, refreshRevision: workspace.revision,
            sortFacts: { try await workspace.sortFacts() },
            readReadingRecords: { [annotations = workspace.annotations] paperID, generation in
              try await Task.detached {
                try annotations.libraryReadingRecords(paperID: paperID, generation: generation)
              }.value
            },
            openPaper: {
              invalidateDirectIntent()
              try await workspace.open($0)
            },
            importPDF: {
              invalidateDirectIntent()
              _ = workspace.pickPDF()
            },
            retryImportPDF: {
              invalidateDirectIntent()
              workspace.pickRetryPDF(paperID: $0, generation: $1)
            },
            manageFolders: {
              invalidateDirectIntent()
              workspace.sheet = .folders
            },
            generateSummary: { paper, language in
              try await workspace.generateSummary(for: paper, outputLanguage: language)
            })
        }
        .onChange(of: urls.state) {
          if case .ready(let paper) = urls.state { workspace.imported(paper) }
        }
      }
      if let failure = workspace.failure {
        Label(failure, systemImage: "exclamationmark.triangle")
          .foregroundStyle(.red).textSelection(.enabled)
      }
      if !workspace.deletionPeerAvailable {
        Text("Agent 삭제 연결이 없어 삭제는 미완료 상태로 남습니다.")
          .font(.caption).foregroundStyle(.secondary).padding(8)
      }
    }
    .onAppear {
      mount = UUID()
      latchNativeSlot()
    }
    .onDisappear {
      invalidateDirectIntent()
      mount = nil
      toolbarPresentation = nil
    }
    .onChange(of: workspace.reader?.mountIdentity) { _, reader in
      if reader != nil {
        invalidateDirectIntent()
        toolbarPresentation = nil
      }
    }
    .onChange(of: workspace.sheet?.id) { _, _ in latchNativeSlot() }
    .sheet(
      isPresented: Binding(
        get: {
          guard let slot else { return false }
          return nativeSlot?.id == slot.id && workspace.sheet?.id == slot.sheet.id
        },
        set: { visible in
          guard !visible, let slot, nativeSlot?.id == slot.id,
            workspace.sheet?.id == slot.sheet.id
          else { return }
          if interactiveCancelAllowed(slot) {
            recordAction(slot, confirmationID: slot.confirmationID, continued: false)
          }
          workspace.sheet = nil
        }),
      onDismiss: {
        if let slot { nativeDidDismiss(slot) }
      }
    ) {
      if let slot {
        sheetContent(slot)
          .onAppear { nativeDidAppear(slot) }
      }
    }
  }

  @ViewBuilder private func sheetContent(_ slot: NativeSlot) -> some View {
    switch slot.sheet {
    case .confirmation(let confirmation):
      ImportConfirmationView(
        confirmation: confirmation, service: workspace.imports,
        cancelledConfirmation: actionBinding(slot, continued: false),
        continuedConfirmation: actionBinding(slot, continued: true),
        allowsInteractiveCancel: interactiveCancelAllowed(slot),
        imported: { _ = workspace.imported($0, localConfirmationID: confirmation.id) })
    case .folders:
      VStack {
        FolderManagementView(service: workspace.imports)
        Button("닫기") { closeNativeSlot(slot) }
      }.padding().frame(minWidth: 420)
    case .settings:
      VStack {
        ProviderSettingsView(service: workspace.settings)
        Button("닫기") { closeNativeSlot(slot) }
      }.padding()
    }
  }

  private func invalidateDirectIntent() { directIntent?.invalidated = true }

  private func openToolbar(_ kind: ToolbarPresentation.Kind) {
    guard let mount, nativeSlot == nil, toolbarPresentation == nil, workspace.sheet == nil,
      !workspace.sheetCleanupPending, !workspace.preparing, !workspace.opening,
      workspace.reader == nil
    else { return }
    let presentation = ToolbarPresentation(mount: mount, kind: kind)
    toolbarPresentation = presentation
    invalidateDirectIntent()
    workspace.sheet = kind.sheet
    if workspace.sheet.map({ kind.matches($0) }) != true,
      toolbarPresentation?.id == presentation.id
    {
      toolbarPresentation = nil
    }
  }

  private func closeNativeSlot(_ slot: NativeSlot) {
    guard nativeSlot?.id == slot.id, workspace.sheet?.id == slot.sheet.id else { return }
    workspace.sheet = nil
  }

  private func chooseLocalPDF(_ id: UUID) {
    guard let mount, nativeSlot == nil, workspace.reader == nil,
      workspace.sheet == nil, !workspace.preparing, !workspace.opening,
      !workspace.sheetCleanupPending
    else { return }
    directIntent = DirectIntent(id: id, mount: mount)
    guard let preparation = workspace.pickPDF() else {
      if directIntent?.id == id { directIntent = nil }
      return
    }
    Task { @MainActor in
      let confirmationID = await preparation.value
      guard !Task.isCancelled, directIntent?.id == id else { return }
      directIntent?.preparationFinished = true
      directIntent?.preparedID = confirmationID
      if confirmationID == nil { directIntent?.invalidated = true }
      latchNativeSlot()
      reconcileDirectIntent(id)
    }
  }

  private func latchNativeSlot() {
    if let presentation = toolbarPresentation,
      let sheet = workspace.sheet,
      presentation.mount != mount || !presentation.kind.matches(sheet)
    {
      if toolbarPresentation?.id == presentation.id { toolbarPresentation = nil }
    }
    guard nativeSlot == nil, let mount, let sheet = workspace.sheet else { return }
    let confirmationID: UUID?
    if case .confirmation(let confirmation) = sheet {
      confirmationID = confirmation.id
    } else {
      confirmationID = nil
    }
    let origin =
      confirmationID != nil && directIntent?.mount == mount
        && directIntent?.invalidated == false && directIntent?.slotID == nil
      ? directIntent?.id : nil
    if origin == nil { invalidateDirectIntent() }
    let toolbarID =
      toolbarPresentation?.mount == mount
        && toolbarPresentation?.kind.matches(sheet) == true ? toolbarPresentation?.id : nil
    let slot = NativeSlot(
      mount: mount, sheet: sheet,
      confirmationID: confirmationID, directIntentID: origin,
      toolbarPresentationID: toolbarID)
    nativeSlot = slot
    if let origin, directIntent?.id == origin {
      directIntent?.slotID = slot.id
      directIntent?.confirmationID = confirmationID
    }
  }

  private func nativeDidAppear(_ slot: NativeSlot) {
    guard nativeSlot?.id == slot.id, mount == slot.mount,
      workspace.sheet?.id == slot.sheet.id
    else { return }
    nativeSlot?.appeared = true
    if let id = slot.toolbarPresentationID, toolbarPresentation?.id == id,
      toolbarPresentation?.mount == slot.mount,
      toolbarPresentation?.kind.matches(slot.sheet) == true
    {
      toolbarPresentation?.appeared = true
    }
    if let id = slot.directIntentID, directIntent?.id == id,
      directIntent?.slotID == slot.id
    {
      directIntent?.appeared = true
    }
  }

  private func interactiveCancelAllowed(_ slot: NativeSlot) -> Bool {
    guard nativeSlot?.id == slot.id, nativeSlot?.appeared == true,
      nativeSlot?.continued == nil, let id = slot.directIntentID,
      directIntent?.id == id, directIntent?.slotID == slot.id,
      directIntent?.invalidated == false, directIntent?.continued == nil,
      mount == slot.mount, workspace.sheet?.id == slot.sheet.id
    else { return false }
    return true
  }

  private func actionBinding(_ slot: NativeSlot, continued: Bool) -> Binding<UUID?> {
    Binding(
      get: {
        guard nativeSlot?.id == slot.id else { return nil }
        return continued ? nativeSlot?.continued : nativeSlot?.cancelled
      }, set: { id in recordAction(slot, confirmationID: id, continued: continued) })
  }

  private func recordAction(_ slot: NativeSlot, confirmationID: UUID?, continued: Bool) {
    guard nativeSlot?.id == slot.id, let confirmationID,
      slot.confirmationID == confirmationID, mount == slot.mount,
      workspace.sheet?.id == slot.sheet.id
    else { return }
    if continued {
      nativeSlot?.continued = confirmationID
    } else {
      nativeSlot?.cancelled = confirmationID
    }
    guard let id = slot.directIntentID, directIntent?.id == id,
      directIntent?.slotID == slot.id
    else { return }
    if continued {
      directIntent?.continued = confirmationID
    } else {
      directIntent?.cancelled = confirmationID
    }
  }

  private func nativeDidDismiss(_ slot: NativeSlot) {
    // Slot identity gates duplicate callbacks; owner cleanup precedes every focus guard.
    guard nativeSlot?.id == slot.id else { return }
    let cleanup = workspace.presentationDidDismiss(confirmationID: slot.confirmationID)
    let appeared = nativeSlot?.appeared == true
    nativeSlot = nil
    if let id = slot.directIntentID, directIntent?.id == id,
      directIntent?.slotID == slot.id
    {
      directIntent?.dismissed = true
      if let cleanup {
        Task { @MainActor in
          let cancelledID = await cleanup.value
          guard !Task.isCancelled, directIntent?.id == id,
            directIntent?.slotID == slot.id
          else { return }
          directIntent?.cancellationReturned = cancelledID
          reconcileDirectIntent(id)
        }
      }
      reconcileDirectIntent(id)
    }
    if let id = slot.toolbarPresentationID, let presentation = toolbarPresentation,
      presentation.id == id, presentation.mount == slot.mount,
      presentation.kind.matches(slot.sheet)
    {
      toolbarPresentation = nil
      if appeared, presentation.appeared, mount == slot.mount,
        workspace.reader == nil, workspace.sheet == nil, nativeSlot == nil,
        !workspace.sheetCleanupPending, !workspace.preparing, !workspace.opening
      {
        switch presentation.kind {
        case .folders: folderOpenerFocused = true
        case .settings: settingsOpenerFocused = true
        }
      }
    }
    latchNativeSlot()
  }

  private func reconcileDirectIntent(_ id: UUID) {
    guard let intent = directIntent, intent.id == id, !intent.invalidated,
      intent.preparationFinished, let confirmationID = intent.preparedID,
      intent.confirmationID == confirmationID, intent.slotID != nil,
      intent.appeared, intent.dismissed, intent.cancelled == confirmationID,
      intent.continued == nil, intent.cancellationReturned == confirmationID,
      mount == intent.mount, workspace.reader == nil, nativeSlot == nil,
      workspace.sheet == nil, !workspace.sheetCleanupPending,
      !workspace.preparing, !workspace.opening
    else { return }
    directIntent = nil
    localPDFFocused = true
  }
}
