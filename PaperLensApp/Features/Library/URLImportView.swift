import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Wrap the actual Library content; neither confirmation nor completion replaces it.
public struct URLImportView<LibraryContent: View>: View {
  @ObservedObject private var service: URLImportService
  private let folderService: FolderImportService
  private let possibleDuplicate: (String) -> Bool
  private let openReader: (UUID) -> Void
  private let chooseLocalPDF: () -> Void
  private let confirmLocalPDF: (URL) -> Void
  private let library: LibraryContent
  @State private var input = ""
  @State private var inputSheet = false
  @StateObject private var drag = URLImportDragState()
  @State private var invalidInput = false
  @State private var folders: [LibraryFolder] = []
  @State private var destinationFolderID: UUID?
  @State private var folderLoadFailed = false
  @FocusState private var inputFocused: Bool

  public init(service: URLImportService, folderService: FolderImportService,
    possibleDuplicate: @escaping (String) -> Bool,
    openReader: @escaping (UUID) -> Void,
    chooseLocalPDF: @escaping () -> Void,
    confirmLocalPDF: @escaping (URL) -> Void,
    @ViewBuilder library: () -> LibraryContent) {
    self.service = service
    self.folderService = folderService
    self.possibleDuplicate = possibleDuplicate
    self.openReader = openReader
    self.chooseLocalPDF = chooseLocalPDF
    self.confirmLocalPDF = confirmLocalPDF
    self.library = library()
  }

  public var body: some View {
    let mount = drag.mount
    let interaction = drag.interaction
    let confirmationID = service.confirmation?.id
    VStack {
      HStack {
        Button("URL 추가") {
          guard drag.isCurrent(mount, interaction) else { return }
          drag.interrupt()
          inputSheet = true
        }
        Button("URL 붙여넣기") {
          guard drag.isCurrent(mount, interaction) else { return }
          drag.interrupt()
          if let text = NSPasteboard.general.string(forType: .string) { prepare(text) }
          else { invalidInput = true }
        }
        Button("PDF 선택") {
          guard drag.isCurrent(mount, interaction) else { return }
          drag.interrupt()
          chooseLocalPDF()
        }
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
          let loadMount = drag.mount
          let loadInteraction = drag.interaction
          Task { await reloadFolders(mount: loadMount, interaction: loadInteraction) }
        }
        if folderLoadFailed {
          Label("폴더를 불러오지 못했습니다.", systemImage: "exclamationmark.triangle")
            .foregroundStyle(.red)
        }
      }
      library
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
          if drag.supported {
            ZStack {
              Color.accentColor.opacity(0.15)
              Label("PDF 또는 HTTPS URL을 Library에 추가", systemImage: "plus.circle.fill")
                .padding().background(.regularMaterial)
            }
            .allowsHitTesting(false)
          }
        }
        .onDrop(of: [UTType.url.identifier, UTType.fileURL.identifier],
          delegate: URLImportDropDelegate(state: drag,
            supportsURL: { service.supports($0) },
            canAccept: {
              !inputSheet && !invalidInput && service.confirmation == nil
                && service.state != .confirming && service.state != .downloading
            },
            accept: { url in
              if url.isFileURL { confirmLocalPDF(url) } else { prepare(url.absoluteString) }
            }))
      status
    }
    .sheet(isPresented: Binding(get: { inputSheet }, set: { value in
      guard drag.isCurrent(mount, interaction) else { return }
      drag.interrupt()
      inputSheet = value
    })) {
      VStack(alignment: .leading, spacing: 16) {
        Text("HTTPS PDF 또는 arXiv URL").font(.headline)
        TextField("URL", text: Binding(get: { input }, set: { value in
          guard drag.isCurrent(mount, interaction), inputSheet else { return }
          input = value
        })).accessibilityLabel("가져올 HTTPS URL")
          .focused($inputFocused)
          .onSubmit {
            guard drag.isCurrent(mount, interaction) else { return }
            drag.interrupt()
            inputSheet = false
            prepare(input)
          }
        HStack {
          Button("취소") {
            guard drag.isCurrent(mount, interaction) else { return }
            drag.interrupt()
            inputSheet = false
          }.keyboardShortcut(.cancelAction)
          Button("확인") {
            guard drag.isCurrent(mount, interaction) else { return }
            drag.interrupt()
            inputSheet = false
            prepare(input)
          }.keyboardShortcut(.defaultAction)
        }
      }.padding().frame(minWidth: 420)
        .onAppear { inputFocused = true }
    }
    .sheet(item: Binding(get: { service.confirmation }, set: { value in
      guard value == nil, drag.isCurrent(mount, interaction),
        let confirmationID, service.confirmation?.id == confirmationID else { return }
      drag.interrupt()
      service.cancelConfirmation()
    })) { intent in
      VStack(alignment: .leading, spacing: 16) {
        if case .retry = intent.purpose {
          Text("URL 가져오기 다시 시도 확인").font(.headline)
          Text("확인한 URL과 저장 폴더로 같은 논문의 실패한 가져오기 작업을 다시 시도합니다. 별도 논문을 추가하지 않습니다.")
        } else {
          Text("Library에 논문 추가").font(.headline)
        }
        Label(intent.destination, systemImage: "folder")
        Text("입력 경로: \(intent.sourceKind)")
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
            guard drag.isCurrent(mount, interaction), service.confirmation?.id == intent.id else { return }
            drag.interrupt()
            service.cancelConfirmation()
          }.keyboardShortcut(.cancelAction)
          Button("계속") {
            guard drag.isCurrent(mount, interaction), service.confirmation?.id == intent.id else { return }
            drag.interrupt()
            service.continueImport(confirmationID: intent.id)
          }
            .keyboardShortcut(.defaultAction)
        }
      }.padding().frame(minWidth: 420)
    }
    .alert("지원하지 않는 URL", isPresented: $invalidInput) {
      Button("확인", role: .cancel) {}
    } message: { Text("인증 정보가 없는 HTTPS PDF 또는 올바른 arXiv URL을 입력하세요.") }
    .onAppear {
      drag.appear()
      let loadMount = drag.mount
      let loadInteraction = drag.interaction
      Task { await reloadFolders(mount: loadMount, interaction: loadInteraction) }
    }
    .onDisappear { drag.disappear() }
    .onChange(of: service.confirmation?.id) { _ in drag.interrupt() }
    .onChange(of: service.state) { _ in drag.interrupt() }
  }

  @ViewBuilder private var status: some View {
    let mount = drag.mount
    let interaction = drag.interaction
    switch service.state {
    case .idle, .confirming: EmptyView()
    case .downloading:
      HStack {
        ProgressView().accessibilityLabel("PDF 다운로드 중")
        Text("PDF 다운로드 중")
        Button("취소") {
          guard drag.isCurrent(mount, interaction), service.state == .downloading else { return }
          drag.interrupt()
          service.cancelDownload()
        }
      }
    case .ready(let paper):
      HStack {
        Label("Library에 추가됨", systemImage: "checkmark.circle")
        Button("Reader 열기") {
          guard drag.isCurrent(mount, interaction), service.state == .ready(paper) else { return }
          drag.interrupt()
          openReader(paper)
        }
      }
    case .failed(let reason):
      HStack {
        Label(safeMessage(reason), systemImage: "exclamationmark.triangle")
        Button("다시 시도") {
          guard drag.isCurrent(mount, interaction), service.state == .failed(reason) else { return }
          drag.interrupt()
          do { try service.retry() } catch { invalidInput = true }
        }
      }
    }
  }

  private func prepare(_ text: String) {
    do {
      guard drag.mount != nil, service.confirmation == nil,
        service.state != .confirming, service.state != .downloading else { throw URLImportError.rejected }
      let folder = folders.first { $0.id == destinationFolderID }
      guard destinationFolderID == nil || folder != nil else { throw URLImportError.rejected }
      try service.prepare(text, destination: folder?.name ?? "Unfiled",
        possibleDuplicate: possibleDuplicate(text), destinationFolderID: destinationFolderID)
    }
    catch { invalidInput = true }
  }

  private func reloadFolders(mount: UUID?, interaction: UUID) async {
    guard drag.isCurrent(mount, interaction) else { return }
    do {
      let loaded = try await folderService.folders()
      guard drag.isCurrent(mount, interaction) else { return }
      folders = loaded
      if let id = destinationFolderID, !folders.contains(where: { $0.id == id }) {
        destinationFolderID = nil
      }
      folderLoadFailed = false
    } catch {
      guard drag.isCurrent(mount, interaction) else { return }
      folderLoadFailed = true
    }
  }

  private func safeMessage(_ reason: URLImportError) -> String {
    switch reason {
    case .cancelled: return "다운로드가 취소되었습니다."
    case .capacity: return "다른 가져오기가 진행 중입니다."
    case .writerUnavailable: return "현재 Library에서 가져오기를 시작할 수 없습니다."
    case .closureUnknown, .cleanupFailed: return "정리가 완료되지 않았습니다. Library 상태를 확인하세요."
    case .rejected: return "PDF 응답 또는 가져오기 제한을 확인할 수 없습니다."
    }
  }
}

@MainActor
private final class URLImportDragState: ObservableObject {
  @Published var supported = false
  @Published private(set) var mount: UUID?
  @Published private(set) var interaction = UUID()
  var hover: UUID?
  private(set) var pendingDrop: UUID?

  // UI interruption fences only; writer/input admission remains with the existing owners.
  func isCurrent(_ mount: UUID?, _ interaction: UUID) -> Bool {
    mount != nil && self.mount == mount && self.interaction == interaction
  }

  func interrupt() {
    interaction = UUID()
    hover = nil
    pendingDrop = nil
    supported = false
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
private struct URLImportDropDelegate: DropDelegate {
  let state: URLImportDragState
  let supportsURL: (String) -> Bool
  let canAccept: () -> Bool
  let accept: (URL) -> Void

  func validateDrop(info: DropInfo) -> Bool {
    info.hasItemsConforming(to: [UTType.url.identifier, UTType.fileURL.identifier])
  }

  func dropEntered(info: DropInfo) {
    state.interrupt()
    guard state.mount != nil, canAccept(), let item = item(info) else { return }
    let mount = state.mount
    let interaction = state.interaction
    let hover = UUID()
    state.hover = hover
    state.supported = false
    load(item) { url in
      guard state.isCurrent(mount, interaction), state.hover == hover, canAccept() else { return }
      state.supported = url.map { supported($0) } ?? false
    }
  }

  func dropExited(info: DropInfo) {
    state.hover = nil
    state.supported = false
  }

  func dropUpdated(info: DropInfo) -> DropProposal? {
    DropProposal(operation: state.supported ? .copy : .cancel)
  }

  func performDrop(info: DropInfo) -> Bool {
    guard state.mount != nil, state.supported, state.hover != nil,
      canAccept(), let item = item(info) else { return false }
    let token = state.beginDrop()
    let mount = state.mount
    let interaction = state.interaction
    load(item) { url in
      guard state.consumeDrop(token, mount: mount, interaction: interaction),
        canAccept(), let url, supported(url) else { return }
      accept(url)
    }
    return true
  }

  private func supported(_ url: URL) -> Bool {
    url.isFileURL ? url.pathExtension.lowercased() == "pdf" : supportsURL(url.absoluteString)
  }

  private func item(_ info: DropInfo) -> NSItemProvider? {
    info.itemProviders(for: [UTType.url.identifier, UTType.fileURL.identifier]).first
  }

  private func load(_ item: NSItemProvider, completion: @escaping @MainActor (URL?) -> Void) {
    item.loadObject(ofClass: NSURL.self) { value, _ in
      let url = value as? URL
      Task { @MainActor in completion(url) }
    }
  }
}
