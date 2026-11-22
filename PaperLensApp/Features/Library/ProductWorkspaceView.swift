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
    fileprivate let presentationMount: UUID?
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
  private let diagnosticSource: URL?
  private let readLeases: LibraryReadLeaseProvider
  private var urlImportObservation: AnyCancellable?
  private var libraryContentObservation: AnyCancellable?
  private var scopedSource: URL?
  private var pendingConfirmation: UUID?
  private var continuedLocalConfirmation: UUID?
  private var confirmationCancellation: (id: UUID, task: Task<UUID, Never>)?
  private var importPreparation: (id: UUID, mount: UUID?, task: Task<LocalImportConfirmation, any Error>)?
  internal var beforeImportConfirmationInstallForOwnedFixtures:
    (@MainActor (LocalImportConfirmation) -> Void)?
  private var metadataReadRequest: UUID?
  private static let metadataLookupFailure = "논문 정보를 확인하지 못했습니다. 상태 새로 고침으로 다시 확인하세요."
  private var publishingReader = false
  private var closingReader = false
  private var installingSheet = false
  private var clearingSheet = false
  private var cleaningSheet = false
  private var presentationMounts: Set<UUID> = []
  private var activeSheetMount: UUID?
  @Published private var activeSheet: Sheet?
  @Published public private(set) var sheetCleanupPending = false
  public var sheet: Sheet? {
    get { activeSheet }
    set {
      if let newValue {
        installSheet(newValue, for: nil)
      } else {
        clearActiveSheet()
      }
    }
  }

  func attachPresentation() -> UUID {
    let mount = UUID()
    presentationMounts.insert(mount)
    return mount
  }

  func detachPresentation(_ mount: UUID) {
    guard presentationMounts.remove(mount) != nil else { return }
    if let reader, reader.presentationMount == mount { closeReader(reader, savingPosition: true) }
    if !installingSheet, !clearingSheet,
      importPreparation?.mount == mount || activeSheetMount == mount
    {
      dismissSheet()
    }
  }

  func reader(for mount: UUID?) -> OpenReader? {
    guard let mount, presentationMounts.contains(mount), reader?.presentationMount == mount else { return nil }
    return reader
  }

  func sheet(for mount: UUID?) -> Sheet? {
    guard let mount, activeSheetMount == mount, presentationMounts.contains(mount) else { return nil }
    return activeSheet
  }

  func closeSheet(id: String, for mount: UUID) {
    guard sheet(for: mount)?.id == id else { return }
    clearActiveSheet()
  }

  func installSheet(_ sheet: Sheet, for mount: UUID?) {
    guard activeSheet == nil, !sheetCleanupPending, !installingSheet, !cleaningSheet,
      mount.map(presentationMounts.contains) ?? true else { return }
    switch sheet {
    case .confirmation(let confirmation):
      guard preparing, pendingConfirmation == confirmation.id, importPreparation?.mount == mount else { return }
    case .folders, .settings:
      guard !preparing, !opening, reader == nil else { return }
    }
    installingSheet = true
    defer {
      installingSheet = false
      if let mount, !presentationMounts.contains(mount) { dismissSheet() }
    }
    confirmationCancellation = nil
    activeSheetMount = mount
    sheetCleanupPending = true
    activeSheet = sheet
  }

  fileprivate var settingsActionsAllowed: Bool {
    if case .settings = activeSheet { return !clearingSheet && !cleaningSheet }
    return false
  }

  private func clearActiveSheet() {
    guard !clearingSheet, let activeSheet else { return }
    let mount = activeSheetMount
    clearingSheet = true
    defer {
      clearingSheet = false
      if !cleaningSheet, let mount, !presentationMounts.contains(mount) { dismissSheet() }
    }
    if case .settings = activeSheet { settings.cancelUncommittedConnections() }
    self.activeSheet = nil
  }
  @Published public var libraryFilter = OrganizationFilter()
  @Published public private(set) var reader: OpenReader?
  @Published private(set) var latestLocalImport: UUID?
  @Published private(set) var localImportID: UUID?
  @Published private(set) var deletingPaperIDs: Set<UUID> = []
  @Published private(set) var finishedDeletionIDs: Set<UUID> = []
  @Published private(set) var deletionRevision = 0
  @Published private(set) var failedInitialParsing: Set<UUID> = []
  @Published public private(set) var revision = 0
  @Published private(set) var libraryContentRevision = UUID()
  @Published public private(set) var preparing = false
  @Published public private(set) var opening = false
  @Published public private(set) var failure: String?

  public convenience init(
    database: ProductDatabase, lifecycle: LocalLibraryLifecycle,
    connection: NativeAPIKeyConnection, codex: NativeCodexConnection? = nil,
    parsing: MainPDFiumParsingComposition? = nil
  ) throws {
    try self.init(database: database, lifecycle: lifecycle, connection: connection,
      codex: codex, parsing: parsing, diagnosticSource: nil)
  }

  internal init(
    database: ProductDatabase, lifecycle: LocalLibraryLifecycle,
    connection: NativeAPIKeyConnection, codex: NativeCodexConnection? = nil,
    parsing: MainPDFiumParsingComposition? = nil, diagnosticSource: URL?,
    urlSessionConfiguration: URLSessionConfiguration? = nil
  ) throws {
    self.database = database
    self.diagnosticSource = diagnosticSource
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
      authority: try ProviderRequest(), sessionConfiguration: urlSessionConfiguration,
      grantWriter: {
        guard diagnosticSource == nil else { throw URLImportError.writerUnavailable }
        return try await lifecycle.grantURLImportWriter(for: $0)
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
    // Receive each terminal state after the service has settled its import,
    // independently of SwiftUI mounting or coalescing view updates.
    urlImportObservation = urls.$state
      .receive(on: DispatchQueue.main)
      .sink { [weak self] state in
        switch state {
        case .ready(let paper): self?.imported(paper)
        case .failed: self?.revision += 1
        default: break
        }
      }
    libraryContentObservation = database.libraryContentChanges()
      .receive(on: DispatchQueue.main)
      .sink(receiveCompletion: { _ in }, receiveValue: { [weak self] in
        self?.libraryContentRevision = UUID()
      })
  }

  public func sortFacts() async throws -> [OrganizationSortFacts] {
    let database = database
    return try await Task.detached { try database.librarySortFacts() }.value
  }

  @discardableResult func requestDeletion(_ paper: OrganizedPaper, retry: Bool,
    presentationMount: UUID? = nil) -> Task<Void, Never>? {
    let libraryIsCurrent = presentationMount.map {
      presentationMounts.contains($0) && reader?.presentationMount != $0
    } ?? (reader == nil)
    guard libraryIsCurrent, libraryPresentationIdle, paper.status != .deleting, paper.status != .tombstone,
      retry == (paper.status == .deletionFailed), !finishedDeletionIDs.contains(paper.id),
      deletingPaperIDs.insert(paper.id).inserted
    else { return nil }
    if latestLocalImport == paper.id { latestLocalImport = nil }
    failedInitialParsing.remove(paper.id)
    urls.dismissStatus(for: paper.id)
    let message = "‘\(paper.title)’ 삭제를 완료하지 못했습니다."
    if failure == message { failure = nil }
    return Task {
      defer {
        // Keep the old row unavailable until Library reloads its durable status.
        deletionRevision += 1
        finishedDeletionIDs.insert(paper.id)
        deletingPaperIDs.remove(paper.id)
      }
      do { try await organization.delete(paper, retry: retry) }
      catch { failure = message }
    }
  }

  func acknowledgeDeletionRefresh(_ paperIDs: Set<UUID>, revision: Int) {
    guard deletionRevision == revision else { return }
    finishedDeletionIDs.subtract(paperIDs)
  }

  func captureURLImportRetry(_ paper: OrganizedPaper) async throws -> ImportRecoveryRecord {
    guard diagnosticSource == nil, canOpenReader, paper.status == .importFailed,
      !deletingPaperIDs.contains(paper.id), !finishedDeletionIDs.contains(paper.id)
    else { throw URLImportError.writerUnavailable }
    let database = database
    let captured = try await Task.detached {
      try database.captureRetryableImport(paperID: paper.id, generation: paper.generation)
    }.value
    try Task.checkCancellation()
    guard canOpenReader, !deletingPaperIDs.contains(paper.id), !finishedDeletionIDs.contains(paper.id)
    else { throw URLImportError.writerUnavailable }
    return captured
  }

  @discardableResult public func prepareImport(source: URL, presentationMount: UUID? = nil) async throws -> UUID {
    let destinationFolderID: UUID?
    switch libraryFilter.folder {
    case .folder(let id): destinationFolderID = id
    case .all, .unfiled: destinationFolderID = nil
    }
    return try await prepareLocalImport(source: source, destinationFolderID: destinationFolderID,
      presentationMount: presentationMount)
  }

  public func prepareRetry(source: URL, paperID: UUID, generation: UUID, presentationMount: UUID? = nil) async throws {
    _ = try await prepareLocalImport(source: source, retry: (paperID, generation), presentationMount: presentationMount)
  }

  private func prepareLocalImport(
    source: URL, destinationFolderID: UUID? = nil,
    retry: (paperID: UUID, generation: UUID)? = nil, presentationMount: UUID?
  ) async throws -> UUID {
    try admitDiagnosticSource(source)
    guard canPrepareLocalImport else {
      throw ProductWorkspaceError.busy
    }
    guard presentationMount.map(presentationMounts.contains) ?? true else { throw CancellationError() }
    try Task.checkCancellation()
    confirmationCancellation = nil
    let scoped = source.startAccessingSecurityScopedResource()
    let request = UUID()
    let task = Task { [imports] in
      if let retry {
        return try await imports.prepareRetry(
          source: source, paperID: retry.paperID, generation: retry.generation)
      }
      return try await imports.prepare(source: source, destinationFolderID: destinationFolderID)
    }
    importPreparation = (request, presentationMount, task)
    preparing = true
    // A synchronous observer may have dismissed the request during publication.
    if importPreparation == nil { preparing = false }
    defer {
      if importPreparation?.id == request {
        importPreparation = nil
        preparing = false
      }
    }
    var returnedConfirmation: UUID?
    var handedOffConfirmation = false
    do {
      let confirmation = try await withTaskCancellationHandler {
        try await task.value
      } onCancel: {
        task.cancel()
      }
      returnedConfirmation = confirmation.id
      beforeImportConfirmationInstallForOwnedFixtures?(confirmation)
      try Task.checkCancellation()
      guard importPreparation?.id == request, !opening, !sheetCleanupPending, sheet == nil,
        reader == nil, presentationMount.map(presentationMounts.contains) ?? true
      else { throw CancellationError() }
      if scoped { scopedSource = source }
      pendingConfirmation = confirmation.id
      installSheet(.confirmation(confirmation), for: presentationMount)
      handedOffConfirmation = true
      guard pendingConfirmation == confirmation.id else { throw CancellationError() }
      failure = nil
      return confirmation.id
    } catch {
      if !handedOffConfirmation {
        if scoped { source.stopAccessingSecurityScopedResource() }
        if let returnedConfirmation { await imports.cancel(returnedConfirmation) }
      }
      throw error
    }
  }

  @discardableResult public func pickPDF(presentationMount: UUID? = nil) -> Task<UUID?, Never>? {
    guard canPrepareLocalImport else {
      return nil
    }
    confirmationCancellation = nil
    let picker = NSOpenPanel()
    picker.allowedContentTypes = [.pdf]
    picker.canChooseDirectories = false
    picker.allowsMultipleSelection = false
    if let diagnosticSource { picker.directoryURL = diagnosticSource.deletingLastPathComponent() }
    guard picker.runModal() == .OK, let source = picker.url else { return nil }
    return Task {
      do { return try await prepareImport(source: source, presentationMount: presentationMount) }
      catch is CancellationError { return nil }
      catch {
        failure = (error as? FolderImportError)?.reselectionMessage
          ?? "PDF 가져오기를 준비하지 못했습니다. 원본 PDF를 다시 선택하세요."
        return nil
      }
    }
  }

  public func pickRetryPDF(paperID: UUID, generation: UUID, presentationMount: UUID? = nil) {
    guard canPrepareLocalImport else { return }
    confirmationCancellation = nil
    let picker = NSOpenPanel()
    picker.allowedContentTypes = [.pdf]
    picker.canChooseDirectories = false
    picker.allowsMultipleSelection = false
    if let diagnosticSource { picker.directoryURL = diagnosticSource.deletingLastPathComponent() }
    guard picker.runModal() == .OK, let source = picker.url else { return }
    Task {
      do { try await prepareRetry(source: source, paperID: paperID, generation: generation,
        presentationMount: presentationMount) }
      catch is CancellationError { return }
      catch {
        failure = (error as? FolderImportError)?.reselectionMessage
          ?? "PDF 재시도를 준비하지 못했습니다. 작업 상태를 확인하고 PDF를 다시 선택하세요."
      }
    }
  }

  @discardableResult func startLocalImport(_ id: UUID, destinationFolderID: UUID?,
    presentationMount: UUID? = nil) -> Task<UUID?, Never>? {
    guard case .confirmation(let confirmation) = activeSheet, confirmation.id == id,
      pendingConfirmation == id, continuedLocalConfirmation == nil, localImportID == nil,
      activeSheetMount == presentationMount, !installingSheet, !clearingSheet, !cleaningSheet,
      presentationMount.map(presentationMounts.contains) ?? true else { return nil }
    // Continue transfers the picker scope to the import before the sheet can dismiss.
    // The producer still owns its own scope and writer until physical cleanup.
    continuedLocalConfirmation = id
    let scope = scopedSource
    scopedSource = nil
    localImportID = id
    return Task {
      defer {
        scope?.stopAccessingSecurityScopedResource()
        localImportID = nil
      }
      do {
        let paperID = try await imports.continueImport(id, destinationFolderID: destinationFolderID)
        imported(paperID, localConfirmationID: id)
        return paperID
      } catch {
        failure = (error as? FolderImportError)?.reselectionMessage
          ?? "PDF 가져오기를 완료하지 못했습니다. Library에서 현재 상태를 확인하세요."
        revision += 1
        return nil
      }
    }
  }

  func isPreparingImport(for mount: UUID?) -> Bool {
    guard let mount, presentationMounts.contains(mount) else { return false }
    return preparing && importPreparation?.mount == mount
  }

  func cancelLocalImportPreparation(for mount: UUID) {
    guard isPreparingImport(for: mount), activeSheet == nil, !installingSheet else { return }
    dismissSheet()
  }

  @discardableResult public func dismissSheet() -> Task<UUID, Never>? {
    if !installingSheet, !preparing, importPreparation == nil, activeSheet == nil,
      let confirmationCancellation
    {
      return confirmationCancellation.task
    }
    guard !cleaningSheet, !clearingSheet else { return nil }
    cleaningSheet = true
    sheetCleanupPending = true
    clearActiveSheet()
    activeSheetMount = nil
    importPreparation?.task.cancel()
    importPreparation = nil
    preparing = false
    let confirmationID = pendingConfirmation
    let continued = confirmationID != nil && continuedLocalConfirmation == confirmationID
    pendingConfirmation = nil
    continuedLocalConfirmation = nil
    scopedSource?.stopAccessingSecurityScopedResource()
    scopedSource = nil
    revision += 1
    if let confirmationID, !continued {
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

  @discardableResult public func presentationDidDismiss(confirmationID: UUID? = nil,
    presentationMount: UUID? = nil) -> Task<
    UUID, Never
  >? {
    guard activeSheetMount == presentationMount, activeSheet == nil,
      !installingSheet, !preparing, importPreparation == nil else {
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

  public func acceptDroppedPDF(_ source: URL, presentationMount: UUID? = nil) {
    Task {
      do { _ = try await prepareImport(source: source, presentationMount: presentationMount) }
      catch is CancellationError { return }
      catch {
        failure = (error as? FolderImportError)?.reselectionMessage
          ?? "PDF 가져오기를 준비하지 못했습니다. 원본 PDF를 다시 선택하세요."
      }
    }
  }

  private func admitDiagnosticSource(_ source: URL) throws {
    guard diagnosticSource == nil || source.standardizedFileURL == diagnosticSource?.standardizedFileURL
    else { throw ProductWorkspaceError.diagnosticSourceRequired }
  }

  public func openImportedURL(_ paperID: UUID, presentationMount: UUID? = nil) {
    Task { await openImportedPDF(paperID, presentationMount: presentationMount) }
  }

  func openImportedPDF(_ paperID: UUID, presentationMount: UUID? = nil) async {
    guard canOpenReader else { return }
    do {
      try await openReader(paperID: paperID, expectedGeneration: nil, presentationMount: presentationMount)
    } catch is CancellationError {
      return
    } catch {
      guard presentationMount.map(presentationMounts.contains) ?? true else { return }
      failure = "가져온 PDF를 열지 못했습니다. 라이브러리에서 현재 상태를 확인하세요."
    }
  }

  @discardableResult public func imported(
    _ paperID: UUID, localConfirmationID: UUID? = nil
  ) -> Task<Void, Never>? {
    guard !deletingPaperIDs.contains(paperID), !finishedDeletionIDs.contains(paperID) else { return nil }
    revision += 1
    do {
      guard try database.libraryStatus(paperID: paperID) == .ready else {
        failure = "PDF 가져오기가 완료되지 않았습니다. 라이브러리의 실패 상태를 확인하세요."
        return nil
      }
      failure = nil
      if let localConfirmationID, pendingConfirmation == localConfirmationID || localImportID == localConfirmationID {
        latestLocalImport = paperID
      }
      if let parsing {
        return Task {
          do { _ = try await parsing.parseImportedPaper(paperID) }
          catch {
            guard !Task.isCancelled, !deletingPaperIDs.contains(paperID),
              !finishedDeletionIDs.contains(paperID) else { return }
            failedInitialParsing.insert(paperID)
          }
        }
      }
    } catch { failure = "PDF 가져오기 상태를 확인하지 못했습니다. 라이브러리에서 현재 상태를 다시 확인하세요." }
    return nil
  }

  public func open(_ paper: OrganizedPaper, presentationMount: UUID? = nil) async throws {
    try await openReader(paperID: paper.id, expectedGeneration: paper.generation,
      presentationMount: presentationMount)
  }

  func startUnreservedParsing(for observed: OpenReader) async {
    guard let parsing, isCurrentReader(observed), !Task.isCancelled else { return }
    failedInitialParsing.remove(observed.id)
    do {
      try observed.session.withReadAccess { }
      try await parsing.startUnreservedParsing(paperID: observed.id,
        generation: observed.annotationIdentity.generation)
    } catch {
      guard isCurrentReader(observed), !Task.isCancelled else { return }
      failedInitialParsing.insert(observed.id)
    }
  }

  private var libraryPresentationIdle: Bool {
    sheet == nil && !sheetCleanupPending && !preparing && !opening && !publishingReader && !closingReader
  }

  fileprivate var canOpenReader: Bool { libraryPresentationIdle && reader == nil }

  fileprivate var canPrepareLocalImport: Bool { canOpenReader && localImportID == nil }

  private func openReader(paperID: UUID, expectedGeneration: UUID?, presentationMount: UUID?) async throws {
    try checkReaderPresentation(presentationMount)
    guard canOpenReader else { throw ProductWorkspaceError.busy }
    confirmationCancellation = nil
    opening = true
    defer { opening = false }
    guard !deletingPaperIDs.contains(paperID), !finishedDeletionIDs.contains(paperID)
    else { throw OrganizationError.stalePaper }
    let generation = try await database.readOrganizationOpenGeneration(
      paperID: paperID, expectedGeneration: expectedGeneration)
    try checkReaderPresentation(presentationMount)
    guard !deletingPaperIDs.contains(paperID), !finishedDeletionIDs.contains(paperID)
    else { throw OrganizationError.stalePaper }
    // Bind the selected generation at lease acquisition too, not just at the list's check.
    let provider = SelectedPaperReadLeases(base: readLeases, paperID: paperID, generation: generation)
    let identity = try database.annotationIdentity(paperID: paperID)
    guard identity.generation == generation else { throw AnnotationError.stalePaper }
    let metadataIdentity: ReaderMetadataIdentity?
    let metadataLookupFailed: Bool
    do {
      let published = try database.publishedMetadataPaperIdentity(paperID: paperID)
      if let published {
        guard published.generation == identity.generation, published.pdfSHA256 == identity.pdfSHA256
        else { throw ReaderMetadataError.staleIdentity }
      }
      metadataIdentity = published
      metadataLookupFailed = false
    } catch {
      metadataIdentity = nil
      metadataLookupFailed = true
    }
    metadataReadRequest = nil
    publishReader(OpenReader(
      id: paperID, session: ReaderSession(database: database, leaseProvider: provider),
      annotationIdentity: identity, metadataIdentity: metadataIdentity, presentationMount: presentationMount))
    guard presentationMount.map(presentationMounts.contains) ?? true else { throw CancellationError() }
    if latestLocalImport == paperID { latestLocalImport = nil }
    failure = metadataLookupFailed ? Self.metadataLookupFailure : nil
  }

  private func checkReaderPresentation(_ mount: UUID?) throws {
    try Task.checkCancellation()
    guard mount.map(presentationMounts.contains) ?? true else { throw CancellationError() }
  }

  private func publishReader(_ value: OpenReader) {
    publishingReader = true
    reader = value
    publishingReader = false
    // Published subscribers can detach the owner before the assignment completes.
    if let mount = value.presentationMount, !presentationMounts.contains(mount) {
      closeReader(value, savingPosition: true)
    }
  }

  public func returnToLibrary() {
    if let reader, reader.presentationMount == nil { closeReader(reader) }
  }

  func returnToLibrary(from observed: OpenReader, presentationMount: UUID) {
    guard reader(for: presentationMount)?.session === observed.session else { return }
    closeReader(observed)
  }

  private func closeReader(_ observed: OpenReader, savingPosition: Bool = false) {
    guard !publishingReader, !closingReader, isCurrentReader(observed) else { return }
    closingReader = true
    defer { closingReader = false }
    metadataReadRequest = nil
    if savingPosition {
      do { try observed.session.saveMountedPositionIfAvailable() }
      catch { reportSaveFailure(error) }
    }
    observed.session.close()
    reader = nil
    if failure == Self.metadataLookupFailure { failure = nil }
    revision += 1
  }

  /// Intent from the mounted status view, never an authoritative revision supplied by it.
  /// False retains the refresh intent after pending admission or a failed metadata read.
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
    let documentIsCurrent = (try? withCurrentMetadataDocument(observed) { _ in true }) == true
    guard documentIsCurrent else {
      closeReader(observed)
      failure = "논문을 계속 읽을 수 없습니다. 라이브러리에서 현재 상태를 확인하세요."
      return true
    }
    if reader?.metadataIdentity != nil {
      publishReader(OpenReader(
        id: observed.id, session: observed.session,
        annotationIdentity: observed.annotationIdentity, metadataIdentity: nil,
        presentationMount: observed.presentationMount))
    }
    if isCurrentReader(observed), failure != Self.metadataLookupFailure {
      failure = Self.metadataLookupFailure
    }
    return false
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
      let updated: OpenReader? = try withCurrentMetadataDocument(observed) { paper in
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
        else { return nil }
        return OpenReader(
          id: reader.id, session: reader.session,
          annotationIdentity: reader.annotationIdentity, metadataIdentity: identity,
          presentationMount: reader.presentationMount)
      }
      if let updated { publishReader(updated) }
    } catch {
      guard isCurrentReader(observed), !Task.isCancelled else { return true }
      guard metadataReadRequest == refresh.request else { return false }
      throw error
    }
    guard metadataReadRequest == refresh.request else { return false }
    if failure == Self.metadataLookupFailure { failure = nil }
    return true
  }

  private func withCurrentMetadataDocument<T>(_ observed: OpenReader,
    _ read: (ReaderPaperSnapshot) throws -> T) throws -> T {
    do {
      return try observed.session.withReadAccess {
        guard let paper = observed.session.currentPaper,
          paper.paperID == observed.id, paper.generation == observed.annotationIdentity.generation,
          try database.annotationIdentity(paperID: observed.id) == observed.annotationIdentity
        else { throw AnnotationError.stalePaper }
        return try read(paper)
      }
    } catch AnnotationError.stalePaper {
      observed.session.close()
      throw AnnotationError.stalePaper
    }
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

public enum ProductWorkspaceError: Error { case busy, diagnosticSourceRequired }

@MainActor private final class SelectedPaperReadLeases: ReaderLeaseProvider {
  private let base: LibraryReadLeaseProvider
  private let paperID: UUID
  private let generation: UUID
  init(base: LibraryReadLeaseProvider, paperID: UUID, generation: UUID) {
    self.base = base
    self.paperID = paperID
    self.generation = generation
  }
  func acquireReadLease(
    for snapshot: ReaderPaperSnapshot,
    onRevoked: @escaping @MainActor () -> Void
  ) throws -> any ReaderReadLease {
    guard snapshot.paperID == paperID, snapshot.generation == generation else {
      throw ReaderError.revoked
    }
    return try base.acquireReadLease(for: snapshot, onRevoked: onRevoked)
  }
}

@MainActor
public struct ProductWorkspaceView: View {
  @ObservedObject private var workspace: ProductWorkspace
  @ObservedObject private var urls: URLImportService
  private let diagnosticPresentationChange: ((UUID?) -> Void)?
  @FocusState private var folderOpenerFocused: Bool
  @FocusState private var settingsOpenerFocused: Bool
  @FocusState private var localPDFFocused: Bool
  @State private var mount: UUID?
  @State private var toolbarPresentation: ToolbarPresentation?
  @State private var nativeSlot: NativeSlot?
  @State private var directIntent: DirectIntent?
  @State private var activeImportProgress: [UUID: Int64] = [:]

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
    self.init(workspace: workspace, diagnosticPresentationChange: nil)
  }

  init(workspace: ProductWorkspace, diagnosticPresentationChange: ((UUID?) -> Void)?) {
    self.workspace = workspace
    urls = workspace.urls
    self.diagnosticPresentationChange = diagnosticPresentationChange
  }
  public var body: some View {
    let slot = nativeSlot
    VStack(spacing: 0) {
      if let mount, let reader = workspace.reader(for: mount) {
        NativeReaderView(
          paperID: reader.id, session: reader.session,
          annotationIdentity: reader.annotationIdentity, annotationService: workspace.annotations,
          metadataService: workspace.metadata, metadataIdentity: reader.metadataIdentity,
          parsingStatus: ParsingStatusView(
            database: workspace.database, paperID: reader.id,
            coordinator: workspace.parsingRecoveryCoordinator,
            initialStartFailed: workspace.failedInitialParsing.contains(reader.id),
            startUnreservedParsing: workspace.parsing == nil ? nil : {
              await workspace.startUnreservedParsing(for: reader)
            },
            onUsableRevisionChange: { await workspace.refreshPublishedMetadata(for: reader) }),
          onReturn: { workspace.returnToLibrary(from: reader, presentationMount: mount) },
          onSaveFailure: {
            if workspace.reader(for: mount)?.session === reader.session { workspace.reportSaveFailure($0) }
          }
        )
        .id(reader.mountIdentity)
      } else {
        HStack {
          Group {
            Button("폴더 관리") { openToolbar(.folders) }.focused($folderOpenerFocused)
            Button("Settings") { openToolbar(.settings) }.focused($settingsOpenerFocused)
            if let mount, let paperID = workspace.latestLocalImport {
              Button("가져온 PDF 열기") {
                Task { await workspace.openImportedPDF(paperID, presentationMount: mount) }
              }
            }
          }.disabled(!workspace.canOpenReader)
          if let mount, workspace.isPreparingImport(for: mount) {
            ProgressView("PDF 확인 중")
            Button("취소") { workspace.cancelLocalImportPreparation(for: mount) }
              .accessibilityLabel("PDF 확인 취소")
          }
          Spacer()
        }.padding()
        URLImportView(
          service: urls, folderService: workspace.imports,
          possibleDuplicate: { _ in true },
          captureRetry: { try await workspace.captureURLImportRetry($0) },
          localPDFAvailable: workspace.canPrepareLocalImport, readerAvailable: workspace.canOpenReader,
          openReader: { paperID in
            guard let mount else { return }
            workspace.openImportedURL(paperID, presentationMount: mount)
          },
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
            guard let mount else { return }
            invalidateDirectIntent()
            workspace.acceptDroppedPDF($0, presentationMount: mount)
          }
        ) { retryImportURL in
          LibraryBrowserView(
            service: workspace.organization, folderService: workspace.imports,
            filter: $workspace.libraryFilter, refreshRevision: workspace.revision,
            deletingPaperIDs: workspace.deletingPaperIDs, finishedDeletionIDs: workspace.finishedDeletionIDs,
            deletionRevision: workspace.deletionRevision,
            contentRevision: workspace.libraryContentRevision,
            activeImportProgress: activeImportProgress, localPDFAvailable: workspace.canPrepareLocalImport,
            libraryPresentationAvailable: workspace.canOpenReader,
            readReadingRecords: { [annotations = workspace.annotations] paperID, generation in
              try await Task.detached {
                try annotations.libraryReadingRecords(paperID: paperID, generation: generation)
              }.value
            },
            openPaper: {
              guard let mount else { throw CancellationError() }
              invalidateDirectIntent()
              try await workspace.open($0, presentationMount: mount)
            },
            deletePaper: {
              guard let mount else { return }
              workspace.requestDeletion($0, retry: $1, presentationMount: mount)
            },
            acknowledgeDeletionRefresh: { workspace.acknowledgeDeletionRefresh($0, revision: $1) },
            importPDF: {
              guard let mount else { return }
              invalidateDirectIntent()
              _ = workspace.pickPDF(presentationMount: mount)
            },
            retryImportPDF: {
              guard let mount else { return }
              invalidateDirectIntent()
              workspace.pickRetryPDF(paperID: $0, generation: $1, presentationMount: mount)
            },
            retryImportURL: retryImportURL,
            manageFolders: {
              guard let mount else { return }
              invalidateDirectIntent()
              workspace.installSheet(.folders, for: mount)
            },
            summaries: workspace.summaries, providerSettings: workspace.settings)
        }
      }
      if workspace.localImportID != nil, activeImportProgress.isEmpty {
        ProgressView("PDF 가져오기 처리 중")
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
      guard mount == nil else { return }
      mount = workspace.attachPresentation()
      diagnosticPresentationChange?(mount)
      latchNativeSlot()
    }
    .onDisappear {
      invalidateDirectIntent()
      let oldMount = mount
      mount = nil
      toolbarPresentation = nil
      nativeSlot = nil
      if let oldMount { workspace.detachPresentation(oldMount) }
      diagnosticPresentationChange?(nil)
    }
    .onChange(of: workspace.reader(for: mount)?.mountIdentity) { _, reader in
      if reader != nil {
        invalidateDirectIntent()
        toolbarPresentation = nil
      }
    }
    .onChange(of: workspace.sheet(for: mount)?.id) { _, _ in latchNativeSlot() }
    .task {
      do {
        for try await progress in workspace.database.activeImportProgress() {
          guard !Task.isCancelled else { return }
          if activeImportProgress != progress { activeImportProgress = progress }
        }
      } catch {
        if !Task.isCancelled { activeImportProgress = [:] }
      }
    }
    .sheet(
      isPresented: Binding(
        get: {
          guard let slot else { return false }
          return nativeSlot?.id == slot.id && workspace.sheet(for: slot.mount)?.id == slot.sheet.id
        },
        set: { visible in
          guard !visible, let slot, nativeSlot?.id == slot.id,
            workspace.sheet(for: slot.mount)?.id == slot.sheet.id
          else { return }
          if interactiveCancelAllowed(slot) {
            recordAction(slot, confirmationID: slot.confirmationID, continued: false)
          }
          workspace.closeSheet(id: slot.sheet.id, for: slot.mount)
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
        startInWorkspace: { workspace.startLocalImport(confirmation.id, destinationFolderID: $0,
          presentationMount: slot.mount) != nil },
        imported: { _ in })
    case .folders:
      VStack {
        FolderManagementView(service: workspace.imports)
        Button("닫기") { closeNativeSlot(slot) }
      }.padding().frame(minWidth: 420)
    case .settings:
      VStack {
        ProviderSettingsView(service: workspace.settings, isCurrent: {
          nativeSlot?.id == slot.id && mount == slot.mount && workspace.settingsActionsAllowed
            && workspace.sheet(for: slot.mount)?.id == slot.sheet.id
        })
        .onDisappear { closeNativeSlot(slot) }
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
    workspace.installSheet(kind.sheet, for: mount)
    if workspace.sheet(for: mount).map({ kind.matches($0) }) != true,
      toolbarPresentation?.id == presentation.id
    {
      toolbarPresentation = nil
    }
  }

  private func closeNativeSlot(_ slot: NativeSlot) {
    guard nativeSlot?.id == slot.id else { return }
    workspace.closeSheet(id: slot.sheet.id, for: slot.mount)
  }

  private func chooseLocalPDF(_ id: UUID) {
    guard let mount, nativeSlot == nil, workspace.reader == nil,
      workspace.sheet == nil, !workspace.preparing, !workspace.opening,
      !workspace.sheetCleanupPending, workspace.localImportID == nil
    else { return }
    directIntent = DirectIntent(id: id, mount: mount)
    guard let preparation = workspace.pickPDF(presentationMount: mount) else {
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
      let sheet = workspace.sheet(for: mount),
      presentation.mount != mount || !presentation.kind.matches(sheet)
    {
      if toolbarPresentation?.id == presentation.id { toolbarPresentation = nil }
    }
    guard nativeSlot == nil, let mount, let sheet = workspace.sheet(for: mount) else { return }
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
      workspace.sheet(for: slot.mount)?.id == slot.sheet.id
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
      mount == slot.mount, workspace.sheet(for: slot.mount)?.id == slot.sheet.id
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
      workspace.sheet(for: slot.mount)?.id == slot.sheet.id
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
    if case .settings = slot.sheet { closeNativeSlot(slot) }
    let cleanup = workspace.presentationDidDismiss(confirmationID: slot.confirmationID,
      presentationMount: slot.mount)
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
