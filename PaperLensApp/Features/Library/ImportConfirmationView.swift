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
  @Environment(\.dismiss) private var dismiss
  @State private var folders: [LibraryFolder] = []
  @State private var destination: UUID?
  @State private var working = false
  @State private var destinationsLoaded = false
  @State private var action = ImportConfirmationActionState()
  @State private var errorMessage: String?

  public init(confirmation: LocalImportConfirmation, service: FolderImportService,
    imported: @escaping (UUID) -> Void) {
    self.confirmation = confirmation
    self.service = service
    self.imported = imported
    _destination = State(initialValue: confirmation.destinationFolderID)
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(confirmation.retryPaperID == nil
        ? "Confirm local PDF import" : "Confirm failed local PDF Retry").font(.headline)
      if let paperID = confirmation.retryPaperID {
        Text("Retry the same failed Paper and import Job using this freshly selected PDF and the confirmed destination. No separate Paper is created.")
        LabeledContent("Failed Paper", value: paperID.uuidString)
      }
      LabeledContent("Selected filename", value: confirmation.filename)
      Text("Title, author and identifiers: not extracted").foregroundStyle(.secondary)
      if destinationsLoaded {
        Picker("Destination", selection: $destination) {
          Text("Unfiled (default)").tag(nil as UUID?)
          ForEach(folders) { folder in Text(folder.name).tag(Optional(folder.id)) }
        }
      } else {
        Text("Loading selected destination…")
      }
      if confirmation.matchingPaperIDs.isEmpty {
        Text("Content hash checked: no matching ready PDF. Other duplicate signals are unavailable.")
      } else {
        Text(confirmation.retryPaperID == nil
          ? "Possible duplicate: \(confirmation.matchingPaperIDs.count) ready PDF(s) have the same content hash. Continue creates a separate Paper and PDF copy."
          : "Possible duplicate: \(confirmation.matchingPaperIDs.count) ready PDF(s) have the same content hash. Continue retries only the captured failed Paper and Job; matching Papers are not replaced.")
      }
      if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
      HStack {
        Button("Cancel") {
          guard action.beginCancel(working: working) else { return }
          working = true
          Task { await service.cancel(confirmation.id); dismiss() }
        }.disabled(working)
        Spacer()
        Button(confirmation.retryPaperID != nil ? "Continue Retry"
          : (confirmation.matchingPaperIDs.isEmpty ? "Import" : "Continue importing")) {
          guard action.beginContinue(destinationsLoaded: destinationsLoaded, working: working) else { return }
          working = true
          Task {
            do {
              let id = try await service.continueImport(confirmation.id,
                destinationFolderID: destination)
              imported(id)
              dismiss()
            } catch {
              errorMessage = "Import was not confirmed successfully. Select the PDF again to retry."
            }
            working = false
          }
        }.disabled(!destinationsLoaded || working || action.consumed)
      }
    }
    .padding(24)
    .frame(minWidth: 440)
    .disabled(working)
    .task {
      do {
        folders = try await service.folders()
        if let destination, !folders.contains(where: { $0.id == destination }) {
          errorMessage = "The selected destination no longer exists. Select the PDF again."
          action.invalidate()
        } else {
          destinationsLoaded = true
        }
      }
      catch { errorMessage = "Unable to load destinations."; action.invalidate() }
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
