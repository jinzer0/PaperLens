import AppKit
import PDFKit
import SwiftUI

/// Data-only editor state; discarded synchronously with the capability, not on a later UI render.
@MainActor final class ReaderAnnotationEditor: ObservableObject {
  struct Note {
    enum Source {
      case selection(PDFSelectionSnapshot)
      case record(AnnotationRecord)
    }

    let id = UUID()
    let source: Source
    var text: String

    var selection: PDFSelectionSnapshot {
      switch source {
      case .selection(let selection): return selection
      case .record(let record): return record.selection
      }
    }
  }

  @Published var records: [AnnotationRecord] = []
  @Published fileprivate(set) var note: Note?
  @Published var feedback = ""
  @Published var noteFocusRequest: UUID?

  fileprivate func reset() { note = nil; records = []; feedback = ""; noteFocusRequest = nil }
}

/// The presentation owns admission. This capability neither retains a PDF nor acquires a lease.
@MainActor public final class ReaderAnnotationContext: ObservableObject {
  public let identity: AnnotationPaperIdentity
  private let session: ReaderSession
  private let service: AnnotationService
  private weak var view: PDFView?
  private weak var document: PDFDocument?
  private weak var revealedOverlay: PDFSelection?
  private var revealedRecordID: UUID?
  private var invalidated = false
  private var changingNote = false
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
    clearRevealedOverlay()
    view = nil; document = nil
    editor.reset()
    isActive = false
  }

  private func validate(requiring record: AnnotationRecord? = nil) throws {
    guard !invalidated, let paper = session.currentPaper,
      paper.paperID == identity.id, paper.generation == identity.generation,
      let view, let document, view.document === document else { throw AnnotationError.stalePaper }
    let current = try service.records(for: identity)
    if let record, !current.contains(record) { throw AnnotationError.staleRecord }
  }

  private func access<T>(requiring record: AnnotationRecord? = nil,
    _ operation: (PDFView, PDFDocument) throws -> T) throws -> T {
    do {
      return try session.withReadAccess {
        try validate(requiring: record)
        guard let view, let document else { throw AnnotationError.stalePaper }
        let result = try operation(view, document)
        // Navigation/selection notifications can synchronously close or replace the Reader.
        try validate(requiring: record)
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
      if revealedRecordID == record.id { clearRevealedOverlay() }
    }
  }

  private func clearRevealedOverlay() {
    let overlay = revealedOverlay
    revealedOverlay = nil
    revealedRecordID = nil
    guard let overlay, let view, let document, view.document === document,
      let visible = view.highlightedSelections else { return }
    let remaining = visible.filter { $0 !== overlay }
    guard remaining.count != visible.count else { return }
    view.highlightedSelections = remaining.isEmpty ? nil : remaining
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
    case .invalidNote: return "내용이 있는 노트를 UTF-8 기준 16,384바이트 이내로 입력하세요. 저장되지 않았습니다."
    case .invalidSelection: return "먼저 주석을 지원하는 원본 PDF 텍스트를 선택하세요."
    case .stalePaper: return "이 논문에는 더 이상 주석을 남길 수 없습니다."
    case .staleRecord: return "이 기록이 변경되었거나 삭제되었습니다. 새로고침 후 편집하세요."
    case .corruptRecord: return "주석 기록을 확인하지 못했습니다. PDF는 계속 읽을 수 있습니다."
    default: return "주석 작업을 완료하지 못했습니다. 새로고침으로 저장된 기록을 확인한 후 다시 시도하세요."
    }
  }

  func beginNote(editing record: AnnotationRecord? = nil) throws {
    try changeNote {
      if let record {
        guard record.kind == .note, try records().contains(record) else { throw AnnotationError.staleRecord }
      }
      if editor.note != nil {
        try publishEditor { editor.feedback = "새 노트를 시작하려면 작성 중인 노트를 저장하거나 취소하세요." }
      } else if let record {
        try publishEditor { editor.note = .init(source: .record(record), text: record.note ?? "") }
        try publishEditor { editor.feedback = "노트 편집 중" }
      } else {
        let selection = try capture()
        try publishEditor { editor.note = .init(source: .selection(selection), text: "") }
        try publishEditor { editor.feedback = "노트 작성 중" }
      }
      try publishEditor { editor.noteFocusRequest = UUID() }
    }
  }

  func updateNoteText(_ text: String, editorID: UUID) throws {
    try changeNote(editorID: editorID) { note in
      var updated = note
      updated.text = text
      try publishEditor { editor.note = updated }
    }
  }

  func saveNote(editorID: UUID) throws {
    try changeNote(editorID: editorID) { note in
      let saved: AnnotationRecord
      switch note.source {
      case .selection(let selection): saved = try createNote(selection, text: note.text)
      case .record(let record): saved = try updateNote(record, text: note.text)
      }
      let refreshed = try records()
      guard refreshed.contains(saved) else { throw AnnotationError.staleRecord }
      try clearNote()
      try publishEditor { editor.records = refreshed }
      try publishEditor { editor.feedback = "노트가 저장되었습니다." }
    }
  }

  func cancelNote(editorID: UUID) throws {
    try changeNote(editorID: editorID) { _ in
      try clearNote()
      try publishEditor {
        editor.feedback = "노트 작성 또는 편집을 취소했습니다. 저장된 기록은 유지됩니다."
      }
    }
  }

  func removeAnnotation(_ record: AnnotationRecord) throws {
    try changeNote {
      try delete(record)
      if case .record(let editing)? = editor.note?.source, editing.id == record.id {
        try clearNote()
      }
      let refreshed = try records()
      try publishEditor { editor.records = refreshed }
      try publishEditor { editor.feedback = "주석 기록이 삭제되었습니다." }
    }
  }

  private func clearNote() throws {
    try publishEditor { editor.note = nil }
    try publishEditor { editor.noteFocusRequest = nil }
  }

  private func changeNote(editorID: UUID, _ change: (ReaderAnnotationEditor.Note) throws -> Void) throws {
    guard let note = editor.note, note.id == editorID else { return }
    try changeNote { try change(note) }
  }

  private func changeNote(_ change: () throws -> Void) throws {
    // A Published subscriber can deliver another action before the current setter finishes.
    guard !invalidated, !changingNote else { return }
    changingNote = true
    defer { changingNote = false }
    try change()
  }

  @discardableResult func highlightSelection() throws -> AnnotationRecord {
    let saved = try createHighlight()
    let feedback: String
    do {
      try showAnnotation(saved, navigate: false)
      feedback = "하이라이트가 저장되었습니다."
    } catch AnnotationError.invalidSelection {
      feedback = "하이라이트를 저장했지만 PDF에 표시하지 못했습니다."
    }
    let records = try records()
    guard records.contains(saved) else { throw AnnotationError.staleRecord }
    try publishEditor { editor.records = records }
    try publishEditor { editor.feedback = feedback }
    return saved
  }

  func copyOriginalSelection() throws {
    try copySelection()
    try publishEditor { editor.feedback = "선택한 원본 텍스트가 복사되었습니다." }
  }

  public func reveal(_ record: AnnotationRecord) throws {
    try showAnnotation(record, navigate: true)
  }

  private func showAnnotation(_ record: AnnotationRecord, navigate: Bool) throws {
    var installedOverlay: PDFSelection?
    do {
      try access(requiring: record) { view, document in
        guard let location = record.selection.locations.first,
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
        try validate(requiring: record)
        installedOverlay = overlay
        revealedOverlay = overlay
        revealedRecordID = record.id
        view.highlightedSelections = [overlay]
        try validate(requiring: record)
        if navigate {
          view.go(to: PDFDestination(page: page, at: CGPoint(x: rect.x, y: rect.y + rect.height)))
        }
      }
    } catch {
      if let installedOverlay, revealedOverlay === installedOverlay { clearRevealedOverlay() }
      throw error
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

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("하이라이트·노트").font(.headline)
        Spacer()
        Button("닫기") { if context.isActive { onClose() } }
          .keyboardShortcut(editor.note == nil ? KeyboardShortcut(.escape, modifiers: []) : nil)
          .accessibilityLabel("하이라이트와 노트 닫기")
          .accessibilityHint("현재 PDF 읽기 위치로 돌아갑니다. 저장하지 않은 노트는 버립니다")
      }
      HStack {
        Button("하이라이트") {
          perform { _ = try context.highlightSelection() }
        }
        .accessibilityLabel("선택한 원본 PDF 텍스트에 하이라이트 추가")
        Button("노트 추가") {
          perform { try context.beginNote() }
        }
        .accessibilityLabel("선택한 원본 PDF 텍스트에 개인 노트 추가")
        Button("복사") {
          perform { try context.copyOriginalSelection() }
        }
        .accessibilityLabel("선택한 원본 PDF 텍스트 복사")
        .accessibilityHint("주석을 저장하지 않고 원본 텍스트만 복사합니다")
      }.accessibilityElement(children: .contain)
      if let note = editor.note {
        Text("선택한 원문").font(.caption)
        ScrollView {
          Text(note.selection.originalText).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }.frame(maxHeight: 100)
        TextEditor(text: Binding(get: {
          guard let current = editor.note, current.id == note.id else { return "" }
          return current.text
        }, set: { value in
          perform { try context.updateNoteText(value, editorID: note.id) }
        })).focused($noteFocused).id(note.id).frame(minHeight: 100)
          .accessibilityLabel("개인 노트 내용")
          .accessibilityHint("Command-Return으로 저장하고 Escape로 작성 또는 편집을 취소합니다")
        Text("\(note.text.utf8.count) / 16,384바이트 (UTF-8)").font(.caption)
        HStack {
          Button("노트 저장") {
            perform { try context.saveNote(editorID: note.id) }
          }
          .keyboardShortcut(.return, modifiers: [.command])
          .accessibilityHint("저장에 실패하면 작성 중인 내용이 유지됩니다")
          Button("취소") { perform { try context.cancelNote(editorID: note.id) } }
          .keyboardShortcut(.escape, modifiers: [])
          .accessibilityHint("작성 중인 내용만 버리고 주석 목록과 현재 PDF 읽기 위치는 유지합니다")
        }
      }
      if editor.records.isEmpty { Text("저장된 하이라이트나 노트가 없습니다").foregroundStyle(.secondary) }
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0) {
          ForEach(editor.records) { record in
            let kind = record.kind == .note ? "개인 노트" : "하이라이트"
            let pages = record.selection.locations.map { "\($0.pageIndex + 1)쪽" }.joined(separator: ", ")
            VStack(alignment: .leading) {
              Text(kind).font(.headline)
              Text(record.selection.originalText).lineLimit(3)
              if let note = record.note { Text(note).textSelection(.enabled) }
              Text(pages).font(.caption)
              HStack {
                Button("PDF에서 보기") { perform {
                  try context.reveal(record)
                  try context.publishEditor { editor.feedback = "저장된 주석의 원본 PDF 위치를 표시했습니다." }
                } }
                .accessibilityLabel("\(pages) \(kind) PDF에서 보기")
                .accessibilityHint("저장된 원문 위치로 이동합니다")
                if record.kind == .note {
                  Button("편집") { perform { try context.beginNote(editing: record) } }
                    .accessibilityLabel("\(pages) \(kind) 편집")
                }
                Button("삭제", role: .destructive) {
                  perform { try context.removeAnnotation(record) }
                }
                .accessibilityLabel("\(pages) \(kind) 삭제")
              }
            }
            .accessibilityElement(children: .contain)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
          }
        }
      }
      Text(editor.feedback).font(.caption).accessibilityLabel("주석 상태: \(editor.feedback)")
      Button("새로고침") { perform {
        let refreshed = try context.records()
        try context.publishEditor { editor.records = refreshed }
        try context.publishEditor { editor.feedback = "저장된 주석 목록을 새로고침했습니다." }
      } }
    }.padding().frame(minWidth: 280)
      .onAppear {
        perform {
          let refreshed = try context.records()
          try context.publishEditor { editor.records = refreshed }
        }
        noteFocused = context.isActive && editor.noteFocusRequest != nil
      }
      .onChange(of: editor.noteFocusRequest) {
        noteFocused = context.isActive && editor.noteFocusRequest != nil
      }
      .onDisappear { noteFocused = false }
  }

  private func perform(_ action: () throws -> Void) {
    context.performEditorAction(action)
    if !context.isActive { noteFocused = false }
  }
}
