import AppKit
import SwiftUI
import UniformTypeIdentifiers

public typealias URLImportRetryAction = @MainActor (OrganizedPaper, @escaping @MainActor () -> Void) -> Void

/// Wrap the actual Library content; neither confirmation nor completion replaces it.
public struct URLImportView<LibraryContent: View>: View {
  @ObservedObject private var service: URLImportService
  private let folderService: FolderImportService
  private let possibleDuplicate: (String) -> Bool
  private let captureRetry: (@MainActor (OrganizedPaper) async throws -> ImportRecoveryRecord)?
  private let localPDFAvailable: Bool
  private let readerAvailable: Bool
  private let openReader: (UUID) -> Void
  private let chooseLocalPDF: (UUID) -> Void
  private let localPDFFocused: FocusState<Bool>.Binding
  @Binding private var localIntentInvalidation: UUID?
  private let confirmLocalPDF: (URL) -> Void
  private let library: (URLImportRetryAction?) -> LibraryContent
  @State private var input = ""
  @State private var inputSheet = false
  @StateObject private var drag = URLImportDragState()
  @State private var invalidInput = false
  @State private var retryUnavailable = false
  @State private var retryPreparation: UUID?
  @State private var folders: [LibraryFolder] = []
  @State private var destinationFolderID: UUID?
  @State private var folderLoadFailed = false
  @State private var folderRefreshID = UUID()
  @FocusState private var inputFocused: Bool
  @FocusState private var openerFocused: Opener?
  @State private var inputPresentation: InputPresentation?
  @State private var confirmationPresentation: ConfirmationPresentation?

  private enum Opener: Hashable { case add, paste, retry }
  private enum FocusReturn {
    case toolbar(Opener)
    case paper(@MainActor () -> Void)
  }

  private struct FolderObservationID: Equatable {
    let mount: UUID?
    let refresh: UUID
  }

  private struct RetryEntry {
    let paper: OrganizedPaper
    let restoreFocus: @MainActor () -> Void
  }

  private struct ConfirmationPresentation {
    let id: UUID
    let opener: FocusReturn?
    let mount: UUID?
    var interaction: UUID
    var stateAfterCancel: URLImportService.State = .idle
    var appeared = false
    var cancelled = false
    var invalidated = false
  }

  private struct InputPresentation {
    let id = UUID()
    let mount: UUID?
    let retry: RetryEntry?
    var interaction: UUID
    var submittedText: String?
    var appeared = false
  }

  public init(service: URLImportService, folderService: FolderImportService,
    possibleDuplicate: @escaping (String) -> Bool,
    openReader: @escaping (UUID) -> Void,
    localPDFFocused: FocusState<Bool>.Binding,
    localIntentInvalidation: Binding<UUID?>,
    chooseLocalPDF: @escaping (UUID) -> Void,
    confirmLocalPDF: @escaping (URL) -> Void,
    @ViewBuilder library: () -> LibraryContent) {
    let content = library()
    self.init(service: service, folderService: folderService, possibleDuplicate: possibleDuplicate,
      captureRetry: nil, openReader: openReader, localPDFFocused: localPDFFocused,
      localIntentInvalidation: localIntentInvalidation, chooseLocalPDF: chooseLocalPDF,
      confirmLocalPDF: confirmLocalPDF) { _ in content }
  }

  init(service: URLImportService, folderService: FolderImportService,
    possibleDuplicate: @escaping (String) -> Bool,
    captureRetry: (@MainActor (OrganizedPaper) async throws -> ImportRecoveryRecord)?,
    localPDFAvailable: Bool = true, readerAvailable: Bool = true,
    openReader: @escaping (UUID) -> Void,
    localPDFFocused: FocusState<Bool>.Binding,
    localIntentInvalidation: Binding<UUID?>,
    chooseLocalPDF: @escaping (UUID) -> Void,
    confirmLocalPDF: @escaping (URL) -> Void,
    @ViewBuilder library: @escaping (URLImportRetryAction?) -> LibraryContent) {
    self.service = service
    self.folderService = folderService
    self.possibleDuplicate = possibleDuplicate
    self.captureRetry = captureRetry
    self.localPDFAvailable = localPDFAvailable
    self.readerAvailable = readerAvailable
    self.openReader = openReader
    self.chooseLocalPDF = chooseLocalPDF
    self.localPDFFocused = localPDFFocused
    _localIntentInvalidation = localIntentInvalidation
    self.confirmLocalPDF = confirmLocalPDF
    self.library = library
  }

  private var canPresentInput: Bool {
    drag.mount != nil && inputPresentation == nil && confirmationPresentation == nil
      && service.confirmation == nil && service.state != .confirming && service.state != .downloading
      && retryPreparation == nil && !invalidInput && !retryUnavailable
  }

  private var mountedConfirmationID: UUID? {
    guard let mount = drag.mount, let presentation = confirmationPresentation,
      presentation.mount == mount else { return nil }
    return presentation.id
  }

  public var body: some View {
    let mount = drag.mount
    let interaction = drag.interaction
    let confirmationID = mountedConfirmationID
    let inputPresentationID = inputPresentation?.id
    let confirmationPresentationID = confirmationPresentation?.id
    let folderObservation = FolderObservationID(mount: mount, refresh: folderRefreshID)
    VStack {
      HStack {
        Button("URL 추가") { openURLInput(mount: mount, interaction: interaction) }
          .focusable(canPresentInput, interactions: .edit)
          .focused($openerFocused, equals: .add)
          .onKeyPress(.space, phases: .down) { press in
            guard press.modifiers.isEmpty else { return .ignored }
            openURLInput(mount: mount, interaction: interaction)
            return .handled
          }
          .disabled(!canPresentInput)
        Button("URL 붙여넣기") {
          guard drag.isCurrent(mount, interaction), canPresentInput else { return }
          drag.interrupt()
          if let text = NSPasteboard.general.string(forType: .string) { prepare(text, opener: .toolbar(.paste)) }
          else { invalidInput = true }
        }.focused($openerFocused, equals: .paste)
          .disabled(!canPresentInput)
        Button("PDF 선택") { openPDFPicker(mount: mount, interaction: interaction) }
          .focusable(localPDFAvailable, interactions: .edit)
          .focused(localPDFFocused)
          .onKeyPress(.space, phases: .down) { press in
            guard press.modifiers.isEmpty else { return .ignored }
            openPDFPicker(mount: mount, interaction: interaction)
            return .handled
          }
          .disabled(!localPDFAvailable)
        Spacer()
      }
      HStack {
        Picker("URL 저장 폴더", selection: Binding(get: { destinationFolderID }, set: { value in
          guard drag.isCurrent(mount, interaction),
            service.state != .confirming, service.state != .downloading else { return }
          drag.interrupt()
          destinationFolderID = value
        })) {
          Text("미분류 (기본값)").tag(Optional<UUID>.none)
          ForEach(folders) { folder in Text(folder.name).tag(Optional(folder.id)) }
        }
        .disabled(service.state == .confirming || service.state == .downloading)
        Button("폴더 새로고침") {
          guard drag.isCurrent(mount, interaction) else { return }
          drag.interrupt()
          folderRefreshID = UUID()
        }
        if folderLoadFailed {
          Label("폴더를 불러오지 못했습니다.", systemImage: "exclamationmark.triangle")
            .foregroundStyle(.red)
        }
      }
      library(canPresentInput && captureRetry != nil ? beginRetry : nil)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
          if drag.targeted {
            ZStack {
              Color.accentColor.opacity(0.15)
              Label("PDF 또는 HTTPS URL을 Library에 추가", systemImage: "plus.circle.fill")
                .padding().background(.regularMaterial)
            }
            .allowsHitTesting(false)
          }
        }
        .onDrop(of: URLImportDropDelegate.contentTypes,
          delegate: URLImportDropDelegate(state: drag,
            supportsURL: { service.supports($0) },
            localPDFAvailable: localPDFAvailable,
            canAccept: { canPresentInput },
            accept: { url in
              if url.isFileURL { confirmLocalPDF(url) } else { prepare(url.absoluteString) }
            }))
      status
      if retryPreparation != nil { ProgressView("재시도할 가져오기 확인 중") }
    }
    .sheet(isPresented: Binding(get: { inputSheet }, set: { value in
      guard drag.isCurrent(mount, interaction), let inputPresentationID,
        let presentation = inputPresentation, presentation.id == inputPresentationID,
        drag.isCurrent(presentation.mount, presentation.interaction) else { return }
      drag.interrupt()
      inputSheet = value
      if !value { inputPresentation?.interaction = drag.interaction }
    }), onDismiss: { inputDidDismiss(inputPresentationID, mount: mount) }) {
      let presentationID = inputPresentation?.id
      VStack(alignment: .leading, spacing: 16) {
        if let retry = inputPresentation?.retry {
          Text("‘\(retry.paper.title)’의 가져오기 다시 시도").font(.headline)
          Text("같은 가져오기 작업을 재시도할 HTTPS PDF 또는 arXiv URL을 입력하세요.")
        } else {
          Text("HTTPS PDF 또는 arXiv URL").font(.headline)
        }
        TextField("URL", text: Binding(get: { input }, set: { value in
          guard drag.isCurrent(mount, interaction), inputSheet else { return }
          input = value
        })).accessibilityLabel("가져올 HTTPS URL")
          .focused($inputFocused)
          .onSubmit {
            closeInput(presentationID, mount: mount, interaction: interaction, submit: true)
          }
        HStack {
          Button("취소") {
            closeInput(presentationID, mount: mount, interaction: interaction, submit: false)
          }.keyboardShortcut(.cancelAction)
          Button("확인") {
            closeInput(presentationID, mount: mount, interaction: interaction, submit: true)
          }.keyboardShortcut(.defaultAction)
        }
      }.padding().frame(minWidth: 420)
        .onAppear {
          guard let presentationID, inputPresentation?.id == presentationID else { return }
          inputPresentation?.appeared = true
          inputFocused = true
        }
    }
    .sheet(item: Binding(get: { service.confirmation(for: mountedConfirmationID) }, set: { value in
      guard value == nil, drag.isCurrent(mount, interaction),
        let confirmationID, service.confirmation?.id == confirmationID else { return }
      cancelConfirmation(confirmationID)
    }), onDismiss: { confirmationDidDismiss(confirmationPresentationID, mount: mount) }) { intent in
      VStack(alignment: .leading, spacing: 16) {
        if case .retry = intent.purpose {
          Text("URL 가져오기 다시 시도 확인").font(.headline)
          Text("확인한 URL과 저장 폴더로 같은 논문의 실패한 가져오기 작업을 다시 시도합니다. 별도 논문을 추가하지 않습니다.")
        } else {
          Text("Library에 논문 추가").font(.headline)
        }
        Label(intent.destination, systemImage: "folder")
        switch intent.inputKind {
        case .arxivAbstract:
          Text("arXiv 초록 링크에서 PDF 가져오기")
        case .arxivPDF:
          Text("arXiv PDF 링크에서 가져오기")
        case .httpsPDF:
          Text("HTTPS PDF 링크에서 가져오기")
        }
        if intent.possibleDuplicate {
          if case .retry = intent.purpose {
            Label("중복 가능성이 있습니다. 계속하면 선택한 논문의 실패한 작업만 다시 시도하며, 같은 내용의 기존 논문은 교체하지 않습니다.", systemImage: "exclamationmark.triangle")
          } else {
            Label("중복 가능성이 있습니다. 계속하면 독립 복사본으로 추가됩니다.", systemImage: "exclamationmark.triangle")
          }
        }
        Text("다운로드 후 Library에 머무릅니다.")
        HStack {
          Button("취소") {
            guard drag.isCurrent(mount, interaction), mountedConfirmationID == intent.id else { return }
            cancelConfirmation(intent.id)
          }.keyboardShortcut(.cancelAction)
          Button("계속") {
            guard drag.isCurrent(mount, interaction), mountedConfirmationID == intent.id,
              service.confirmation(for: intent.id) != nil else { return }
            drag.interrupt()
            service.continueImport(confirmationID: intent.id)
          }
            .keyboardShortcut(.defaultAction)
        }
      }.padding().frame(minWidth: 420)
        .onAppear {
          guard confirmationPresentation?.id == intent.id else { return }
          confirmationPresentation?.appeared = true
        }
    }
    .alert("지원하지 않는 URL", isPresented: $invalidInput) {
      Button("확인", role: .cancel) {}
    } message: { Text("인증 정보가 없는 HTTPS PDF 또는 올바른 arXiv URL을 입력하세요.") }
    .alert("가져오기를 다시 시도할 수 없습니다", isPresented: $retryUnavailable) {
      Button("확인", role: .cancel) {}
    } message: { Text("논문의 현재 상태와 저장 폴더를 확인한 뒤 다시 시도하세요.") }
    .onAppear {
      drag.localIntentInvalidation = $localIntentInvalidation
      drag.appear()
    }
    .task(id: folderObservation) { await observeFolders(folderObservation) }
    .onDisappear {
      let ownedConfirmationID = mountedConfirmationID
      inputPresentation = nil
      confirmationPresentation = nil
      retryPreparation = nil
      drag.disappear()
      if let ownedConfirmationID { service.cancelConfirmation(confirmationID: ownedConfirmationID) }
    }
    .onChange(of: service.confirmation?.id) { _ in serviceInterrupted() }
    .onChange(of: service.state) { _ in serviceInterrupted() }
  }

  private func openURLInput(mount: UUID?, interaction: UUID) {
    guard drag.isCurrent(mount, interaction), canPresentInput else { return }
    drag.interrupt()
    inputPresentation = InputPresentation(mount: drag.mount, retry: nil, interaction: drag.interaction)
    inputSheet = true
  }

  private func openPDFPicker(mount: UUID?, interaction: UUID) {
    guard drag.isCurrent(mount, interaction), localPDFAvailable else { return }
    drag.interrupt()
    let intent = UUID()
    drag.localIntent = intent
    chooseLocalPDF(intent)
  }

  private func beginRetry(_ paper: OrganizedPaper, restoreFocus: @escaping @MainActor () -> Void) {
    guard canPresentInput, paper.status == .importFailed else { return }
    drag.interrupt()
    input = ""
    inputPresentation = InputPresentation(mount: drag.mount,
      retry: RetryEntry(paper: paper, restoreFocus: restoreFocus), interaction: drag.interaction)
    inputSheet = true
  }

  private func closeInput(_ id: UUID?, mount: UUID?, interaction: UUID, submit: Bool) {
    guard let id, let presentation = inputPresentation, presentation.id == id, inputSheet,
      drag.isCurrent(presentation.mount, presentation.interaction),
      drag.isCurrent(mount, interaction) else { return }
    drag.interrupt()
    inputPresentation?.interaction = drag.interaction
    inputPresentation?.submittedText = submit ? input : nil
    inputSheet = false
  }

  private func inputDidDismiss(_ id: UUID?, mount: UUID?) {
    guard let id, let presentation = inputPresentation,
      presentation.id == id, presentation.mount == mount else { return }
    inputPresentation = nil
    guard presentation.appeared, !inputSheet,
      drag.isCurrent(presentation.mount, presentation.interaction),
      service.confirmation == nil, !invalidInput else { return }
    // Entry owns no import resources. Prepare only after its actual dismissal;
    // a resulting confirmation or alert must not receive the opener's focus.
    if let retry = presentation.retry {
      input = ""
      if let text = presentation.submittedText { prepareRetry(text, entry: retry) }
      else { retry.restoreFocus() }
      return
    }
    if let text = presentation.submittedText { prepare(text, opener: .toolbar(.add)) }
    guard service.confirmation == nil, !invalidInput else { return }
    openerFocused = .add
  }

  private func cancelConfirmation(_ id: UUID) {
    guard service.confirmation?.id == id else { return }
    let wasCurrent = confirmationPresentation.map {
      !$0.invalidated && $0.id == id && drag.isCurrent($0.mount, $0.interaction)
    } ?? false
    drag.interrupt()
    if wasCurrent {
      confirmationPresentation?.cancelled = true
      confirmationPresentation?.interaction = drag.interaction
    } else {
      confirmationPresentation?.invalidated = true
    }
    service.cancelConfirmation(confirmationID: id)
  }

  private func serviceInterrupted() {
    let wasCurrent = confirmationPresentation.map {
      !$0.invalidated && drag.isCurrent($0.mount, $0.interaction)
    } ?? false
    drag.interrupt()
    guard let presentation = confirmationPresentation else { return }
    if wasCurrent && (service.confirmation?.id == presentation.id
      || (presentation.cancelled && service.confirmation == nil && service.state == presentation.stateAfterCancel)) {
      confirmationPresentation?.interaction = drag.interaction
    } else {
      confirmationPresentation?.invalidated = true
    }
  }

  private func confirmationDidDismiss(_ id: UUID?, mount: UUID?) {
    guard let id, let presentation = confirmationPresentation,
      presentation.id == id, presentation.mount == mount else { return }
    confirmationPresentation = nil
    guard presentation.appeared, presentation.cancelled, !presentation.invalidated,
      drag.isCurrent(presentation.mount, presentation.interaction),
      service.confirmation == nil, service.state == presentation.stateAfterCancel,
      !inputSheet, inputPresentation == nil, !invalidInput, !retryUnavailable else { return }
    // Cancelled URL recognition has no grant, writer, stage or network cleanup.
    // Continue is deliberately excluded: service state is not a closure receipt.
    switch presentation.opener {
    case .toolbar(let opener): openerFocused = opener
    case .paper(let restore): restore()
    case nil: break
    }
  }

  @ViewBuilder private var status: some View {
    let mount = drag.mount
    let interaction = drag.interaction
    switch service.state {
    case .idle, .confirming: EmptyView()
    case .downloading:
      let downloadID = service.downloadConfirmationID
      HStack {
        ProgressView().accessibilityLabel("PDF 다운로드 중")
        Text("PDF 다운로드 중")
        Button("취소") {
          guard drag.isCurrent(mount, interaction), let downloadID,
            service.downloadConfirmationID == downloadID else { return }
          drag.interrupt()
          service.cancelDownload(confirmationID: downloadID)
        }
      }
    case .ready(let paper):
      HStack {
        Label("Library에 추가됨", systemImage: "checkmark.circle")
        Button("Reader 열기") {
          guard readerAvailable, drag.isCurrent(mount, interaction), service.state == .ready(paper) else { return }
          drag.interrupt()
          openReader(paper)
        }.disabled(!readerAvailable)
      }
    case .failed(let reason):
      HStack {
        Label(safeMessage(reason), systemImage: "exclamationmark.triangle")
        if service.canRetry {
          Button("다시 시도") {
            guard drag.isCurrent(mount, interaction), service.state == .failed(reason),
              service.canRetry, canPresentInput else { return }
            drag.interrupt()
            let folder = folders.first { $0.id == destinationFolderID }
            guard destinationFolderID == nil || folder != nil else { retryUnavailable = true; return }
            do {
              try service.retry(destination: folder?.name ?? "미분류", destinationFolderID: folder?.id)
              if let confirmation = service.confirmation {
                confirmationPresentation = ConfirmationPresentation(id: confirmation.id,
                  opener: .toolbar(.retry), mount: mount, interaction: drag.interaction,
                  stateAfterCancel: .failed(reason))
              }
            } catch { retryUnavailable = true }
          }
          .focused($openerFocused, equals: .retry)
          .disabled(!canPresentInput)
        }
      }
    }
  }

  private func prepare(_ text: String, opener: FocusReturn? = nil) {
    do {
      guard drag.mount != nil, service.confirmation == nil,
        service.state != .confirming, service.state != .downloading else { throw URLImportError.rejected }
      let folder = folders.first { $0.id == destinationFolderID }
      guard destinationFolderID == nil || folder != nil else { throw URLImportError.rejected }
      try service.prepare(text, destination: folder?.name ?? "미분류",
        possibleDuplicate: possibleDuplicate(text), destinationFolderID: destinationFolderID)
      if let confirmation = service.confirmation {
        confirmationPresentation = ConfirmationPresentation(id: confirmation.id,
          opener: opener, mount: drag.mount, interaction: drag.interaction)
      }
    }
    catch { invalidInput = true }
  }

  private func prepareRetry(_ text: String, entry: RetryEntry) {
    guard canPresentInput, let captureRetry else { return }
    guard service.supports(text) else { invalidInput = true; return }
    let folderID = destinationFolderID
    guard folderID == nil || folders.contains(where: { $0.id == folderID }) else {
      retryUnavailable = true; return
    }
    let id = UUID()
    let mount = drag.mount, interaction = drag.interaction
    retryPreparation = id
    Task {
      defer { if retryPreparation == id { retryPreparation = nil } }
      do {
        let expected = try await captureRetry(entry.paper)
        guard retryPreparation == id, drag.isCurrent(mount, interaction),
          service.confirmation == nil else { return }
        guard destinationFolderID == folderID else { retryUnavailable = true; return }
        let folder = folders.first { $0.id == folderID }
        guard folderID == nil || folder != nil else { retryUnavailable = true; return }
        try service.prepareRetry(text, destination: folder?.name ?? "미분류",
          possibleDuplicate: possibleDuplicate(text), destinationFolderID: folderID, expected: expected)
        if let confirmation = service.confirmation {
          confirmationPresentation = ConfirmationPresentation(id: confirmation.id,
            opener: .paper(entry.restoreFocus), mount: mount, interaction: interaction)
        }
      } catch {
        if retryPreparation == id, drag.isCurrent(mount, interaction) { retryUnavailable = true }
      }
    }
  }

  private func observeFolders(_ observation: FolderObservationID) async {
    func isCurrent() -> Bool {
      observation.mount != nil && observation.mount == drag.mount
        && observation.refresh == folderRefreshID && !Task.isCancelled
    }
    guard isCurrent() else { return }
    do {
      for try await loaded in folderService.folderSnapshots() {
        guard isCurrent() else { return }
        folders = loaded
        if let id = destinationFolderID, !loaded.contains(where: { $0.id == id }) {
          destinationFolderID = nil
        }
        folderLoadFailed = false
      }
    } catch {
      guard isCurrent() else { return }
      folderLoadFailed = true
    }
  }

  private func safeMessage(_ reason: URLImportError) -> String {
    switch reason {
    case .cancelled: return "다운로드가 취소되었습니다."
    case .capacity: return "다른 가져오기가 진행 중입니다."
    case .writerUnavailable: return "현재 Library에서 가져오기를 시작할 수 없습니다."
    case .destinationMissing: return "저장 폴더가 없어졌습니다. 다른 폴더를 선택한 뒤 다시 시도하세요."
    case .closureUnknown, .cleanupFailed: return "정리가 완료되지 않았습니다. Library 상태를 확인하세요."
    case .connectionFailed: return "다운로드 연결에 실패했습니다. 네트워크나 서버 상태를 확인한 뒤 다시 시도하세요."
    case .rejected: return "PDF 응답 또는 가져오기 제한을 확인할 수 없습니다."
    }
  }
}

@MainActor
final class URLImportDragState: ObservableObject {
  @Published var targeted = false
  @Published private(set) var mount: UUID?
  @Published private(set) var interaction = UUID()
  private(set) var pendingDrop: UUID?
  var localIntent: UUID?
  var localIntentInvalidation: Binding<UUID?>?

  // UI interruption fences only; writer/input admission remains with the existing owners.
  func isCurrent(_ mount: UUID?, _ interaction: UUID) -> Bool {
    mount != nil && self.mount == mount && self.interaction == interaction
  }

  func interrupt() {
    if let localIntent {
      localIntentInvalidation?.wrappedValue = localIntent
      self.localIntent = nil
    }
    interaction = UUID()
    pendingDrop = nil
    targeted = false
  }

  func appear() {
    interrupt()
    mount = UUID()
  }

  func disappear() {
    interrupt()
    mount = nil
  }

  func beginDrop() -> UUID {
    interrupt()
    let token = UUID()
    pendingDrop = token
    return token
  }

  func consumeDrop(_ token: UUID, mount: UUID?, interaction: UUID) -> Bool {
    guard isCurrent(mount, interaction), pendingDrop == token else { return false }
    pendingDrop = nil
    return true
  }
}

@MainActor
struct URLImportDropDelegate: DropDelegate {
  static let contentTypes: [UTType] = [.url, .fileURL]
  let state: URLImportDragState
  let supportsURL: (String) -> Bool
  let localPDFAvailable: Bool
  let canAccept: () -> Bool
  let accept: (URL) -> Void

  func validateDrop(info: DropInfo) -> Bool {
    canAccept() && info.hasItemsConforming(to: Self.contentTypes)
  }

  func dropEntered(info: DropInfo) {
    state.interrupt()
    state.targeted = state.mount != nil && validateDrop(info: info)
  }

  func dropExited(info: DropInfo) {
    state.targeted = false
  }

  func dropUpdated(info: DropInfo) -> DropProposal? {
    DropProposal(operation: state.targeted && canAccept() ? .copy : .cancel)
  }

  func performDrop(info: DropInfo) -> Bool {
    // SwiftUI only makes the item providers available during this callback.
    guard let item = info.itemProviders(for: Self.contentTypes).first else { return false }
    return performDrop(item)
  }

  func performDrop(_ item: NSItemProvider) -> Bool {
    guard state.mount != nil, state.targeted, canAccept(),
      item.canLoadObject(ofClass: NSURL.self) else { return false }
    let token = state.beginDrop()
    let mount = state.mount
    let interaction = state.interaction
    item.loadObject(ofClass: NSURL.self) { value, _ in
      let url = value as? URL
      Task { @MainActor in
        guard state.consumeDrop(token, mount: mount, interaction: interaction),
          canAccept(), let url, supported(url) else { return }
        accept(url)
      }
    }
    return true
  }

  private func supported(_ url: URL) -> Bool {
    url.isFileURL ? localPDFAvailable && url.pathExtension.lowercased() == "pdf" : supportsURL(url.absoluteString)
  }
}
