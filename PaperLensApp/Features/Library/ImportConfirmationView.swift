import SwiftUI

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
  @State private var consumed = false
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
      Text("Confirm local PDF import").font(.headline)
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
      Text(confirmation.matchingPaperIDs.isEmpty
        ? "Content hash checked: no matching ready PDF. Other duplicate signals are unavailable."
        : "Possible duplicate: \(confirmation.matchingPaperIDs.count) ready PDF(s) have the same content hash. Continue creates a separate Paper and PDF copy.")
      if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
      HStack {
        Button("Cancel") {
          Task { await service.cancel(confirmation.id); dismiss() }
        }.disabled(working)
        Spacer()
        Button(confirmation.matchingPaperIDs.isEmpty ? "Import" : "Continue importing") {
          working = true
          consumed = true
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
        }.disabled(!destinationsLoaded || working || consumed)
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
          consumed = true
        } else {
          destinationsLoaded = true
        }
      }
      catch { errorMessage = "Unable to load destinations."; consumed = true }
    }
    .onDisappear { Task { await service.cancel(confirmation.id) } }
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
      Picker("Folder", selection: $selected) {
        Text("New folder").tag(nil as UUID?)
        ForEach(folders) { Text($0.name).tag(Optional($0.id)) }
      }
      .onChange(of: selected) { _, value in
        name = folders.first(where: { $0.id == value })?.name ?? ""
      }
      TextField("Folder name", text: $name)
      HStack {
        Button(selected == nil ? "Create folder" : "Rename folder") {
          perform {
            if let selected { try await service.renameFolder(id: selected, name: name) }
            else { _ = try await service.createFolder(name: name) }
          }
        }
        Button("Delete folder (keep Papers)") {
          guard let selected else { return }
          perform { try await service.deleteFolder(id: selected); self.selected = nil }
        }.disabled(selected == nil)
      }
      if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
    }
    .disabled(working)
    .task {
      do { folders = try await service.folders() }
      catch { errorMessage = "Unable to load folders." }
    }
  }

  private func perform(_ action: @escaping @MainActor () async throws -> Void) {
    working = true
    Task {
      do {
        try await action()
        folders = try await service.folders()
        errorMessage = nil
      } catch { errorMessage = "Folder change failed; prior placement was preserved." }
      working = false
    }
  }
}
