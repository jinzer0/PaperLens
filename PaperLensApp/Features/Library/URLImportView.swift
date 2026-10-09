import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Wrap the actual Library content; neither confirmation nor completion replaces it.
public struct URLImportView<LibraryContent: View>: View {
  @ObservedObject private var service: URLImportService
  private let destination: String
  private let possibleDuplicate: (String) -> Bool
  private let openReader: (UUID) -> Void
  private let chooseLocalPDF: () -> Void
  private let confirmLocalPDF: (URL) -> Void
  private let library: LibraryContent
  @State private var input = ""
  @State private var inputSheet = false
  @StateObject private var drag = URLImportDragState()
  @State private var invalidInput = false

  public init(service: URLImportService, destination: String,
    possibleDuplicate: @escaping (String) -> Bool,
    openReader: @escaping (UUID) -> Void,
    chooseLocalPDF: @escaping () -> Void,
    confirmLocalPDF: @escaping (URL) -> Void,
    @ViewBuilder library: () -> LibraryContent) {
    self.service = service
    self.destination = destination
    self.possibleDuplicate = possibleDuplicate
    self.openReader = openReader
    self.chooseLocalPDF = chooseLocalPDF
    self.confirmLocalPDF = confirmLocalPDF
    self.library = library()
  }

  public var body: some View {
    VStack {
      HStack {
        Button("URL 추가") { inputSheet = true }
        Button("URL 붙여넣기") {
          if let text = NSPasteboard.general.string(forType: .string) { prepare(text) }
          else { invalidInput = true }
        }
        Button("PDF 선택", action: chooseLocalPDF)
        Spacer()
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
            accept: { url in
              if url.isFileURL { confirmLocalPDF(url) } else { prepare(url.absoluteString) }
            }))
      status
    }
    .sheet(isPresented: $inputSheet) {
      VStack(alignment: .leading, spacing: 16) {
        Text("HTTPS PDF 또는 arXiv URL").font(.headline)
        TextField("URL", text: $input).accessibilityLabel("가져올 HTTPS URL")
          .onSubmit { inputSheet = false; prepare(input) }
        HStack {
          Button("취소") { inputSheet = false }.keyboardShortcut(.cancelAction)
          Button("확인") { inputSheet = false; prepare(input) }.keyboardShortcut(.defaultAction)
        }
      }.padding().frame(minWidth: 420)
    }
    .sheet(item: Binding(get: { service.confirmation }, set: { value in
      if value == nil { service.cancelConfirmation() }
    })) { intent in
      VStack(alignment: .leading, spacing: 16) {
        Text("Library에 논문 추가").font(.headline)
        Label(intent.destination, systemImage: "folder")
        Text("입력 경로: \(intent.sourceKind)")
        if intent.possibleDuplicate {
          Label("중복 가능성이 있습니다. 계속하면 독립 복사본으로 추가됩니다.", systemImage: "exclamationmark.triangle")
        }
        Text("다운로드 후 Library에 머무릅니다.")
        HStack {
          Button("취소") { service.cancelConfirmation() }.keyboardShortcut(.cancelAction)
          Button("계속") { service.continueImport(confirmationID: intent.id) }
            .keyboardShortcut(.defaultAction)
        }
      }.padding().frame(minWidth: 420)
    }
    .alert("지원하지 않는 URL", isPresented: $invalidInput) {
      Button("확인", role: .cancel) {}
    } message: { Text("인증 정보가 없는 HTTPS PDF 또는 올바른 arXiv URL을 입력하세요.") }
  }

  @ViewBuilder private var status: some View {
    switch service.state {
    case .idle, .confirming: EmptyView()
    case .downloading:
      HStack {
        ProgressView().accessibilityLabel("PDF 다운로드 중")
        Text("PDF 다운로드 중")
        Button("취소") { service.cancelDownload() }
      }
    case .ready(let paper):
      HStack {
        Label("Library에 추가됨", systemImage: "checkmark.circle")
        Button("Reader 열기") { openReader(paper) }
      }
    case .failed(let reason):
      HStack {
        Label(safeMessage(reason), systemImage: "exclamationmark.triangle")
        Button("다시 시도") {
          do { try service.retry() } catch { invalidInput = true }
        }
      }
    }
  }

  private func prepare(_ text: String) {
    do { try service.prepare(text, destination: destination, possibleDuplicate: possibleDuplicate(text)) }
    catch { invalidInput = true }
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
  var hover: UUID?
}

@MainActor
private struct URLImportDropDelegate: DropDelegate {
  let state: URLImportDragState
  let supportsURL: (String) -> Bool
  let accept: (URL) -> Void

  func validateDrop(info: DropInfo) -> Bool {
    info.hasItemsConforming(to: [UTType.url.identifier, UTType.fileURL.identifier])
  }

  func dropEntered(info: DropInfo) {
    let hover = UUID()
    state.hover = hover
    state.supported = false
    load(info) { url in
      guard state.hover == hover else { return }
      state.supported = supported(url)
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
    guard state.supported else { return false }
    state.hover = nil
    state.supported = false
    load(info) { url in if supported(url) { accept(url) } }
    return true
  }

  private func supported(_ url: URL) -> Bool {
    url.isFileURL ? url.pathExtension.lowercased() == "pdf" : supportsURL(url.absoluteString)
  }

  private func load(_ info: DropInfo, completion: @escaping @MainActor (URL) -> Void) {
    guard let item = info.itemProviders(for: [UTType.url.identifier, UTType.fileURL.identifier]).first else { return }
    item.loadObject(ofClass: NSURL.self) { value, _ in
      guard let url = value as? URL else { return }
      Task { @MainActor in completion(url) }
    }
  }
}
