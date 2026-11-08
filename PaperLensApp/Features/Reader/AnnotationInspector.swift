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
    case .invalidNote: return "내용이 있는 노트를 UTF-8 기준 16,384바이트 이내로 입력하세요. 저장되지 않았습니다."
    case .invalidSelection: return "먼저 주석을 지원하는 원본 PDF 텍스트를 선택하세요."
    case .stalePaper: return "이 논문에는 더 이상 주석을 남길 수 없습니다."
    case .staleRecord: return "이 기록이 변경되었거나 삭제되었습니다. 새로고침 후 편집하세요."
    default: return "주석 작업을 완료하지 못했습니다. 새로고침으로 저장된 기록을 확인한 후 다시 시도하세요."
    }
  }

  func beginNote() throws {
    if editor.draft == nil && editor.editing == nil {
      let selection = try capture()
      try publishEditor { editor.text = "" }
      try publishEditor { editor.editing = nil }
      try publishEditor { editor.draft = selection }
      try publishEditor { editor.feedback = "노트 작성 중" }
    } else {
      try publishEditor { editor.feedback = "새 노트를 시작하려면 작성 중인 노트를 저장하거나 취소하세요." }
    }
    try publishEditor { editor.noteFocusRequest = UUID() }
  }

  @discardableResult func highlightSelection() throws -> AnnotationRecord {
    let saved = try createHighlight()
    let records = try records()
    guard records.contains(saved) else { throw AnnotationError.staleRecord }
    try publishEditor { editor.records = records }
    try publishEditor { editor.feedback = "하이라이트가 저장되었습니다." }
    return saved
  }

  func copyOriginalSelection() throws {
    try copySelection()
    try publishEditor { editor.feedback = "선택한 원본 텍스트가 복사되었습니다." }
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
        Text("하이라이트·노트").font(.headline)
        Spacer()
        Button("닫기") { onClose() }
          .keyboardShortcut(draft == nil && editing == nil ? KeyboardShortcut(.escape, modifiers: []) : nil)
          .accessibilityLabel("하이라이트와 노트 닫기")
          .accessibilityHint("현재 PDF 읽기 위치로 돌아갑니다. 저장하지 않은 노트는 버립니다")
      }
      HStack {
        Button("하이라이트") {
          perform {
            let saved = try context.highlightSelection()
            try context.reveal(saved)
          }
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
      if let selected = editing?.selection ?? draft {
        Text("선택한 원문").font(.caption)
        ScrollView { Text(selected.originalText).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
          .frame(maxHeight: 100)
        TextEditor(text: Binding(get: { text }, set: { value in
          perform { try context.publishEditor { text = value } }
        })).focused($noteFocused).frame(minHeight: 100)
          .accessibilityLabel("개인 노트 내용")
          .accessibilityHint("Command-Return으로 저장하고 Escape로 작성 또는 편집을 취소합니다")
        Text("\(text.utf8.count) / 16,384바이트 (UTF-8)").font(.caption)
        HStack {
          Button("노트 저장") {
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
              try context.publishEditor { feedback = "노트가 저장되었습니다." }
            }
          }
          .keyboardShortcut(.return, modifiers: [.command])
          .accessibilityHint("저장에 실패하면 작성 중인 내용이 유지됩니다")
          Button("취소") { perform {
            try resetEditor()
            try context.publishEditor { feedback = "노트 작성 또는 편집을 취소했습니다. 저장된 기록은 유지됩니다." }
          } }
          .keyboardShortcut(.escape, modifiers: [])
          .accessibilityHint("작성 중인 내용만 버리고 주석 목록과 현재 PDF 읽기 위치는 유지합니다")
        }
      }
      if records.isEmpty { Text("저장된 하이라이트나 노트가 없습니다").foregroundStyle(.secondary) }
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0) {
          ForEach(records) { record in
            VStack(alignment: .leading) {
              Text(record.kind == .note ? "개인 노트" : "하이라이트").font(.headline)
              Text(record.selection.originalText).lineLimit(3)
              if let note = record.note { Text(note).textSelection(.enabled) }
              Text(record.selection.locations.map { "\($0.pageIndex + 1)쪽" }.joined(separator: ", "))
                .font(.caption)
              HStack {
                Button("PDF에서 보기") { perform {
                  try context.reveal(record)
                  try context.publishEditor { feedback = "저장된 주석의 원본 PDF 위치를 표시했습니다." }
                } }
                .accessibilityHint("저장된 원문 위치로 이동합니다")
                if record.kind == .note {
                  Button("편집") {
                    perform {
                      guard try context.records().contains(record) else { throw AnnotationError.staleRecord }
                      guard draft == nil && editing == nil else {
                        try context.beginNote(); return
                      }
                      try context.publishEditor { text = record.note ?? "" }
                      try context.publishEditor { editing = record }
                      try context.publishEditor { feedback = "노트 편집 중" }
                      try context.publishEditor { editor.noteFocusRequest = UUID() }
                    }
                  }
                }
                Button("삭제", role: .destructive) {
                  perform {
                    try context.delete(record)
                    if editing?.id == record.id { try resetEditor() }
                    let refreshed = try context.records()
                    try context.publishEditor { records = refreshed }
                    try context.publishEditor { feedback = "주석 기록이 삭제되었습니다." }
                  }
                }
              }
            }
            .accessibilityElement(children: .contain)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
          }
        }
      }
      Text(feedback).font(.caption).accessibilityLabel("주석 상태: \(feedback)")
      Button("새로고침") { perform {
        let refreshed = try context.records()
        try context.publishEditor { records = refreshed }
        try context.publishEditor { feedback = "저장된 주석 목록을 새로고침했습니다." }
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

  private func resetEditor() throws {
    try context.publishEditor { editor.cancel() }
    noteFocused = false
  }

  private func reset() {
    editor.reset(); noteFocused = false
  }

  private func perform(_ action: () throws -> Void) {
    context.performEditorAction(action)
    if !context.isActive { reset() }
  }
}
