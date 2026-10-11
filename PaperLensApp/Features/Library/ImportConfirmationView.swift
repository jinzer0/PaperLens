import SwiftUI

struct ImportConfirmationActionState {
  private(set) var consumed = false

  mutating func beginContinue(destinationsLoaded: Bool, working: Bool) -> Bool {
    guard destinationsLoaded, !working, !consumed else { return false }
    consumed = true
    return true
  }

  mutating func beginCancel(working: Bool) -> Bool {
    guard !working else { return false }
    consumed = true
    return true
  }

  mutating func invalidate() { consumed = true }
}

@MainActor
public struct ImportConfirmationView: View {
  private let confirmation: LocalImportConfirmation
  private let service: FolderImportService
  private let imported: (UUID) -> Void
  @Binding private var cancelledConfirmation: UUID?
  @Binding private var continuedConfirmation: UUID?
  private let allowsInteractiveCancel: Bool
  @Environment(\.dismiss) private var dismiss
  @State private var folders: [LibraryFolder] = []
  @State private var destination: UUID?
  @State private var working = false
  @State private var destinationsLoaded = false
  @State private var action = ImportConfirmationActionState()
  @State private var errorMessage: String?

  public init(confirmation: LocalImportConfirmation, service: FolderImportService,
    cancelledConfirmation: Binding<UUID?>, continuedConfirmation: Binding<UUID?>,
    allowsInteractiveCancel: Bool,
    imported: @escaping (UUID) -> Void) {
    self.confirmation = confirmation
    self.service = service
    self.imported = imported
    _cancelledConfirmation = cancelledConfirmation
    _continuedConfirmation = continuedConfirmation
    self.allowsInteractiveCancel = allowsInteractiveCancel
    _destination = State(initialValue: confirmation.destinationFolderID)
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(confirmation.retryPaperID == nil
        ? "PDF 가져오기 확인" : "PDF 가져오기 다시 시도 확인").font(.headline)
      if let paperID = confirmation.retryPaperID {
        Text("새로 선택한 PDF와 확인한 저장 폴더로 같은 논문의 실패한 가져오기 작업을 다시 시도합니다. 별도 논문을 추가하지 않습니다.")
        LabeledContent("재시도할 논문", value: paperID.uuidString)
      }
      LabeledContent("선택한 파일 이름", value: confirmation.filename)
      Text("논문 제목·저자·식별자: 아직 추출하지 않음").foregroundStyle(.secondary)
      if destinationsLoaded {
        Picker("저장 폴더", selection: $destination) {
          Text("미분류 (기본값)").tag(nil as UUID?)
          ForEach(folders) { folder in Text(folder.name).tag(Optional(folder.id)) }
        }
      } else if errorMessage == nil {
        ProgressView("저장 폴더를 불러오는 중…")
      }
      if confirmation.matchingPaperIDs.isEmpty {
        Text("내용 해시 확인 결과, 같은 내용의 준비된 PDF가 없습니다. 다른 중복 단서는 확인하지 못했습니다.")
      } else {
        Text(confirmation.retryPaperID == nil
          ? "중복 가능성: 준비된 PDF \(confirmation.matchingPaperIDs.count)개와 내용 해시가 같습니다. 계속하면 별도 논문과 독립 PDF 복사본을 추가합니다."
          : "중복 가능성: 준비된 PDF \(confirmation.matchingPaperIDs.count)개와 내용 해시가 같습니다. 계속하면 선택한 논문의 실패한 작업만 다시 시도하며, 같은 내용의 기존 논문은 교체하지 않습니다.")
      }
      if working { ProgressView("선택한 PDF 요청을 처리하는 중…") }
      if let errorMessage {
        Label(errorMessage, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
      }
      HStack {
        Button("취소") {
          guard action.beginCancel(working: working) else { return }
          cancelledConfirmation = confirmation.id
          working = true
          Task { await service.cancel(confirmation.id); dismiss() }
        }.keyboardShortcut(.cancelAction).disabled(working)
        Spacer()
        Button(confirmation.retryPaperID != nil ? "다시 시도"
          : (confirmation.matchingPaperIDs.isEmpty ? "가져오기" : "계속 가져오기")) {
          guard action.beginContinue(destinationsLoaded: destinationsLoaded, working: working) else { return }
          continuedConfirmation = confirmation.id
          working = true
          Task {
            do {
              let id = try await service.continueImport(confirmation.id,
                destinationFolderID: destination)
              imported(id)
              dismiss()
            } catch {
              errorMessage = "가져오기를 완료하지 못했습니다. 다시 시도하려면 PDF를 새로 선택하고 확인하세요."
            }
            working = false
          }
        }.keyboardShortcut(.defaultAction)
          .disabled(!destinationsLoaded || working || action.consumed)
      }
    }
    .padding(24)
    .frame(minWidth: 440)
    .disabled(working)
    .interactiveDismissDisabled(!allowsInteractiveCancel || working)
    .task {
      do {
        folders = try await service.folders()
        if let destination, !folders.contains(where: { $0.id == destination }) {
          errorMessage = "선택한 저장 폴더가 더 이상 없습니다. PDF를 새로 선택하고 저장 폴더를 다시 확인하세요."
          action.invalidate()
        } else {
          destinationsLoaded = true
        }
      }
      catch { errorMessage = "저장 폴더를 불러오지 못했습니다."; action.invalidate() }
    }
    .onDisappear {
      action.invalidate()
      Task { await service.cancel(confirmation.id) }
    }
  }
}

/// Library embeds this for folder maintenance; deleting a folder never deletes its Papers.
@MainActor
public struct FolderManagementView: View {
  private let service: FolderImportService
  @State private var folders: [LibraryFolder] = []
  @State private var name = ""
  @State private var selected: UUID?
  @State private var errorMessage: String?
  @State private var working = false

  public init(service: FolderImportService) { self.service = service }

  public var body: some View {
    VStack(alignment: .leading) {
      Picker("폴더", selection: $selected) {
        Text("새 폴더").tag(nil as UUID?)
        ForEach(folders) { Text($0.name).tag(Optional($0.id)) }
      }
      .onChange(of: selected) { _, value in
        name = folders.first(where: { $0.id == value })?.name ?? ""
      }
      TextField("폴더 이름", text: $name)
      HStack {
        Button(selected == nil ? "폴더 만들기" : "폴더 이름 변경") {
          perform {
            if let selected { try await service.renameFolder(id: selected, name: name) }
            else { _ = try await service.createFolder(name: name) }
          }
        }
        Button("폴더 삭제 · 논문 유지") {
          guard let selected else { return }
          perform { try await service.deleteFolder(id: selected); self.selected = nil }
        }.disabled(selected == nil)
      }
      if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
    }
    .disabled(working)
    .task {
      do { folders = try await service.folders() }
      catch { errorMessage = "폴더를 불러오지 못했습니다." }
    }
  }

  private func perform(_ action: @escaping @MainActor () async throws -> Void) {
    working = true
    Task {
      do {
        try await action()
        folders = try await service.folders()
        errorMessage = nil
      } catch { errorMessage = "폴더 변경에 실패했습니다. 현재 저장된 배치를 다시 확인하세요." }
      working = false
    }
  }
}
