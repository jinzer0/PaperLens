import AppKit
import PDFKit
import SwiftUI

/// Data-only editor state; discarded synchronously with the capability, not on a later UI render.
@MainActor final class ReaderAnnotationEditor: ObservableObject {
  @Published var records: [AnnotationRecord] = []
  @Published var draft: PDFSelectionSnapshot?
  @Published var editing: AnnotationRecord?
  @Published var text = ""
  @Published var feedback = ""
  @Published var noteFocusRequest: UUID?

  func cancel() { draft = nil; editing = nil; text = "" }
  func reset() { cancel(); records = []; feedback = ""; noteFocusRequest = nil }
}

/// The presentation owns admission. This capability neither retains a PDF nor acquires a lease.
@MainActor public final class ReaderAnnotationContext: ObservableObject {
  public let identity: AnnotationPaperIdentity
  private let session: ReaderSession
  private let service: AnnotationService
  private weak var view: PDFView?
  private weak var document: PDFDocument?
  private var invalidated = false
  let editor = ReaderAnnotationEditor()
  @Published public private(set) var isActive = true

  init(session: ReaderSession, service: AnnotationService, identity: AnnotationPaperIdentity,
    view: PDFView, document: PDFDocument) throws {
    self.session = session; self.service = service; self.identity = identity
    self.view = view; self.document = document
    try access { _, _ in () }
  }

  /// Called synchronously before the presentation detaches PDF state or releases its lease.
  public func invalidate() {
    guard !invalidated else { return }
    invalidated = true
    view = nil; document = nil
    editor.reset()
    isActive = false
  }

  private func validate() throws {
    guard !invalidated, let paper = session.currentPaper,
      paper.paperID == identity.id, paper.generation == identity.generation,
      let view, let document, view.document === document else { throw AnnotationError.stalePaper }
    _ = try service.records(for: identity)
  }

  private func access<T>(_ operation: (PDFView, PDFDocument) throws -> T) throws -> T {
    do {
      return try session.withReadAccess {
        try validate()
        guard let view, let document else { throw AnnotationError.stalePaper }
        let result = try operation(view, document)
        // Navigation/selection notifications can synchronously close or replace the Reader.
        try validate()
        return result
      }
    } catch {
      if error is ReaderError || (error as? AnnotationError) == .stalePaper { invalidate() }
      throw error
    }
  }

  public func records() throws -> [AnnotationRecord] {
    try access { _, _ in try service.records(for: identity) }
  }

  public func capture() throws -> PDFSelectionSnapshot {
    try access { view, document in
      try PDFSelectionSnapshot.capture(from: view, identity: identity, admittedDocument: document)
    }
  }

  public func createHighlight() throws -> AnnotationRecord {
    try access { view, document in
      let snapshot = try PDFSelectionSnapshot.capture(from: view, identity: identity,
        admittedDocument: document)
      try validate()
      return try service.createHighlight(snapshot)
    }
  }

  public func createNote(_ draft: PDFSelectionSnapshot, text: String) throws -> AnnotationRecord {
    try access { _, _ in
      guard draft.paper == identity else { throw AnnotationError.stalePaper }
      return try service.createNote(draft, text: text)
    }
  }

  public func updateNote(_ record: AnnotationRecord, text: String) throws -> AnnotationRecord {
    try access { _, _ in
      guard record.selection.paper == identity else { throw AnnotationError.stalePaper }
      return try service.updateNote(record, text: text)
    }
  }

  public func delete(_ record: AnnotationRecord) throws {
    try access { _, _ in
      guard record.selection.paper == identity else { throw AnnotationError.stalePaper }
      try service.delete(record)
    }
  }

  public func copySelection() throws {
    try access { view, document in
      let snapshot = try PDFSelectionSnapshot.capture(from: view, identity: identity,
        admittedDocument: document)
      try validate()
      NSPasteboard.general.clearContents()
      try validate()
      guard NSPasteboard.general.setString(snapshot.originalText, forType: .string)
      else { throw AnnotationError.invalidSelection }
    }
  }

  // Each publication is a reentrancy boundary: subscribers may close the Reader.
  func publishEditor(_ change: () -> Void) throws {
    do { try access { _, _ in change() } }
    catch { if !isActive { editor.reset() }; throw error }
  }

  @discardableResult func performEditorAction(_ action: () throws -> Void) -> Bool {
    do { try action(); return true }
    catch {
      guard isActive else { editor.reset(); return false }
      try? publishEditor { editor.feedback = Self.message(for: error) }
      return false
    }
  }

  static func message(for error: Error) -> String {
    switch error as? AnnotationError {
    case .invalidNote: return "Enter a nonempty note of at most 16384 UTF-8 bytes. Nothing was saved."
    case .invalidSelection: return "Select supported original PDF text before this action."
    case .stalePaper: return "This Paper is no longer available for annotation."
    case .staleRecord: return "This record changed or was removed. Refresh before editing."
    default: return "Annotation action failed. Refresh to check saved records before retrying."
    }
  }

  func beginNote() throws {
    if editor.draft == nil && editor.editing == nil {
      let selection = try capture()
      try publishEditor { editor.text = "" }
      try publishEditor { editor.editing = nil }
      try publishEditor { editor.draft = selection }
      try publishEditor { editor.feedback = "" }
    } else {
      try publishEditor { editor.feedback = "Continue or cancel the current note before starting another." }
    }
    try publishEditor { editor.noteFocusRequest = UUID() }
  }

  @discardableResult func highlightSelection() throws -> AnnotationRecord {
    let saved = try createHighlight()
    let records = try records()
    guard records.contains(saved) else { throw AnnotationError.staleRecord }
    try publishEditor { editor.records = records }
    try publishEditor { editor.feedback = "Highlight saved" }
    return saved
  }

  func copyOriginalSelection() throws {
    try copySelection()
    try publishEditor { editor.feedback = "Original selected text copied" }
  }

  public func reveal(_ record: AnnotationRecord) throws {
    try access { view, document in
      guard try service.records(for: identity).contains(record),
        let location = record.selection.locations.first,
        let page = document.page(at: location.pageIndex), let rect = location.rectangles.first
      else { throw AnnotationError.staleRecord }
      // Selection overlay only: never annotate or rewrite the original PDF.
      let overlay = PDFSelection(document: document)
      for location in record.selection.locations {
        try validate()
        guard let page = document.page(at: location.pageIndex),
          page.rotation == location.rotation,
          AnnotationRectangle(page.bounds(for: .mediaBox)) == location.mediaBox,
          AnnotationRectangle(page.bounds(for: .cropBox)) == location.cropBox
        else { throw AnnotationError.invalidSelection }
        for rectangle in location.rectangles {
          guard let part = page.selection(for: rectangle.cgRect)
          else { throw AnnotationError.invalidSelection }
          overlay.add(part)
        }
      }
      overlay.color = NSColor.systemYellow.withAlphaComponent(0.35)
      try validate()
      view.highlightedSelections = [overlay]
      try validate()
      view.go(to: PDFDestination(page: page, at: CGPoint(x: rect.x, y: rect.y + rect.height)))
    }
  }
}

/// Only data snapshots are held by the editor, never live PDF objects.
@MainActor public struct AnnotationInspector: View {
  @ObservedObject private var context: ReaderAnnotationContext
  private let onClose: () -> Void
  public init(context: ReaderAnnotationContext, onClose: @escaping () -> Void) {
    self.context = context; self.onClose = onClose
  }
  public var body: some View {
    if context.isActive {
      AnnotationInspectorContent(context: context, onClose: onClose).id(ObjectIdentifier(context))
    }
  }
}

@MainActor private struct AnnotationInspectorContent: View {
  @ObservedObject var context: ReaderAnnotationContext
  @ObservedObject private var editor: ReaderAnnotationEditor
  let onClose: () -> Void
  @FocusState private var noteFocused: Bool

  init(context: ReaderAnnotationContext, onClose: @escaping () -> Void) {
    self.context = context; self.editor = context.editor; self.onClose = onClose
  }

  private var records: [AnnotationRecord] {
    get { editor.records }
    nonmutating set { editor.records = newValue }
  }
  private var draft: PDFSelectionSnapshot? {
    get { editor.draft }
    nonmutating set { editor.draft = newValue }
  }
  private var editing: AnnotationRecord? {
    get { editor.editing }
    nonmutating set { editor.editing = newValue }
  }
  private var text: String {
    get { editor.text }
    nonmutating set { editor.text = newValue }
  }
  private var feedback: String {
    get { editor.feedback }
    nonmutating set { editor.feedback = newValue }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Highlights & Notes").font(.headline)
        Spacer()
        Button("Close") { onClose() }.accessibilityHint("Return to the same PDF reading context")
      }
      HStack {
        Button("Highlight") {
          perform {
            let saved = try context.highlightSelection()
            try context.reveal(saved)
          }
        }
        Button("Add Note") {
          perform { try context.beginNote() }
        }
        Button("Copy") {
          perform { try context.copyOriginalSelection() }
        }
      }.accessibilityElement(children: .contain)
      if let selected = editing?.selection ?? draft {
        Text("Selected original text").font(.caption)
        ScrollView { Text(selected.originalText).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
          .frame(maxHeight: 100)
        TextEditor(text: Binding(get: { text }, set: { value in
          perform { try context.publishEditor { text = value } }
        })).focused($noteFocused).frame(minHeight: 100)
          .accessibilityLabel("Personal note")
        Text("\(text.utf8.count) / 16384 UTF-8 bytes").font(.caption)
        HStack {
          Button("Save Note") {
            perform {
              let saved: AnnotationRecord
              if let editing { saved = try context.updateNote(editing, text: text) }
              else { saved = try context.createNote(selected, text: text) }
              let refreshed = try context.records()
              guard refreshed.contains(saved) else { throw AnnotationError.staleRecord }
              try context.publishEditor { draft = nil }
              try context.publishEditor { editing = nil }
              try context.publishEditor { text = "" }
              try context.publishEditor { records = refreshed }
              try context.publishEditor { feedback = "Note saved" }
            }
          }
          Button("Cancel") { perform {
            resetEditor()
            try context.publishEditor { feedback = "Draft discarded" }
          } }
        }
      }
      if records.isEmpty { Text("No saved highlights or notes").foregroundStyle(.secondary) }
      List(records) { record in
        VStack(alignment: .leading) {
          Text(record.kind == .note ? "Personal Note" : "Highlight").font(.headline)
          Text(record.selection.originalText).lineLimit(3)
          if let note = record.note { Text(note).textSelection(.enabled) }
          Text(record.selection.locations.map { "Page \($0.pageIndex + 1)" }.joined(separator: ", "))
            .font(.caption)
          HStack {
            Button("Show in PDF") { perform { try context.reveal(record) } }
            if record.kind == .note {
              Button("Edit") {
                perform {
                  guard try context.records().contains(record) else { throw AnnotationError.staleRecord }
                  guard draft == nil && editing == nil else {
                    try context.beginNote(); return
                  }
                  try context.publishEditor { text = record.note ?? "" }
                  try context.publishEditor { editing = record }
                  try context.publishEditor { editor.noteFocusRequest = UUID() }
                }
              }
            }
            Button("Delete", role: .destructive) {
              perform {
                try context.delete(record)
                if editing?.id == record.id { resetEditor() }
                let refreshed = try context.records()
                try context.publishEditor { records = refreshed }
                try context.publishEditor { feedback = "Record deleted" }
              }
            }
          }
        }.padding(.vertical, 4)
      }
      Text(feedback).font(.caption).accessibilityLabel("Annotation status: \(feedback)")
      Button("Refresh") { perform {
        let refreshed = try context.records()
        try context.publishEditor { records = refreshed }
        try context.publishEditor { feedback = "" }
      } }
    }.padding().frame(minWidth: 280)
      .onAppear {
        perform {
          let refreshed = try context.records()
          try context.publishEditor { records = refreshed }
        }
        noteFocused = context.isActive && editor.noteFocusRequest != nil
      }
      .onChange(of: editor.noteFocusRequest) {
        noteFocused = context.isActive && editor.noteFocusRequest != nil
      }
      .onDisappear { reset() }
      .onChange(of: context.isActive) { if !context.isActive { reset() } }
  }

  private func resetEditor() {
    editor.cancel(); noteFocused = false
  }

  private func reset() {
    editor.reset(); noteFocused = false
  }

  private func perform(_ action: () throws -> Void) {
    context.performEditorAction(action)
    if !context.isActive { reset() }
  }
}
