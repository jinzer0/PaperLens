import AppKit
import PDFKit
import SwiftUI

/// Mount only while Reader's document read lease is admitted; remove on revocation.
/// Identity-keyed content prevents a prior Paper's draft/results leaking into another Reader.
@MainActor public struct AnnotationInspector: View {
  private let service: AnnotationService
  private let identity: AnnotationPaperIdentity
  private let pdfView: PDFView
  private let admittedDocument: PDFDocument
  private let onClose: () -> Void
  public init(service: AnnotationService, identity: AnnotationPaperIdentity, pdfView: PDFView,
    admittedDocument: PDFDocument, onClose: @escaping () -> Void) {
    self.service = service; self.identity = identity; self.pdfView = pdfView
    self.admittedDocument = admittedDocument; self.onClose = onClose
  }
  public var body: some View {
    AnnotationInspectorContent(service: service, identity: identity, pdfView: pdfView,
      admittedDocument: admittedDocument, onClose: onClose).id(identity)
  }
}

@MainActor private struct AnnotationInspectorContent: View {
  let service: AnnotationService
  let identity: AnnotationPaperIdentity
  let pdfView: PDFView
  let admittedDocument: PDFDocument
  let onClose: () -> Void
  @State private var records: [AnnotationRecord] = []
  @State private var draft: PDFSelectionSnapshot?
  @State private var editing: AnnotationRecord?
  @State private var text = ""
  @State private var feedback = ""
  @FocusState private var noteFocused: Bool

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
            let saved = try service.createHighlight(capture())
            records = try service.records(for: identity)
            feedback = "Highlight saved"
            try reveal(saved)
          }
        }
        Button("Add Note") {
          perform {
            draft = try capture(); editing = nil; text = ""
            noteFocused = true; feedback = ""
          }
        }
        Button("Copy") {
          perform {
            let snapshot = try capture()
            NSPasteboard.general.clearContents()
            guard NSPasteboard.general.setString(snapshot.originalText, forType: .string)
            else { throw AnnotationError.invalidSelection }
            feedback = "Original selected text copied"
          }
        }
      }.accessibilityElement(children: .contain)
      if let selected = editing?.selection ?? draft {
        Text("Selected original text").font(.caption)
        ScrollView { Text(selected.originalText).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
          .frame(maxHeight: 100)
        TextEditor(text: $text).focused($noteFocused).frame(minHeight: 100)
          .accessibilityLabel("Personal note")
        Text("\(text.utf8.count) / 16384 UTF-8 bytes").font(.caption)
        HStack {
          Button("Save Note") {
            perform {
              if let editing { _ = try service.updateNote(editing, text: text) }
              else { _ = try service.createNote(selected, text: text) }
              draft = nil; editing = nil; text = ""
              feedback = "Note saved"
              records = try service.records(for: identity)
            }
          }
          Button("Cancel") { draft = nil; editing = nil; text = ""; feedback = "Draft discarded" }
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
            Button("Show in PDF") { perform { try reveal(record) } }
            if record.kind == .note {
              Button("Edit") {
                editing = record; draft = nil; text = record.note ?? ""; noteFocused = true
              }
            }
            Button("Delete", role: .destructive) {
              perform {
                try service.delete(record)
                if editing?.id == record.id { editing = nil; text = "" }
                records = try service.records(for: identity); feedback = "Record deleted"
              }
            }
          }
        }.padding(.vertical, 4)
      }
      Text(feedback).font(.caption).accessibilityLabel("Annotation status: \(feedback)")
      Button("Refresh") { perform { records = try service.records(for: identity); feedback = "" } }
    }.padding().frame(minWidth: 280)
      .onAppear { perform { records = try service.records(for: identity) } }
  }

  private func capture() throws -> PDFSelectionSnapshot {
    // Fail before selection access if deletion/replacement revoked durable identity.
    _ = try service.records(for: identity)
    return try PDFSelectionSnapshot.capture(from: pdfView, identity: identity,
      admittedDocument: admittedDocument)
  }

  private func reveal(_ record: AnnotationRecord) throws {
    let current = try service.records(for: identity)
    guard current.contains(record), pdfView.document === admittedDocument,
      let location = record.selection.locations.first,
      let page = admittedDocument.page(at: location.pageIndex), let rect = location.rectangles.first
    else { throw AnnotationError.staleRecord }
    // PDFView overlay only: never PDFAnnotation/addAnnotation or document.write.
    let overlay = PDFSelection(document: admittedDocument)
    for location in record.selection.locations {
      guard let page = admittedDocument.page(at: location.pageIndex) else {
        throw AnnotationError.invalidSelection
      }
      for rectangle in location.rectangles {
        guard let part = page.selection(for: rectangle.cgRect) else { continue }
        overlay.add(part)
      }
    }
    overlay.color = NSColor.systemYellow.withAlphaComponent(0.35)
    pdfView.highlightedSelections = [overlay]
    pdfView.go(to: PDFDestination(page: page, at: CGPoint(x: rect.x, y: rect.y + rect.height)))
  }

  private func perform(_ action: () throws -> Void) {
    do { try action() }
    catch {
      switch error as? AnnotationError {
      case .invalidNote: feedback = "Enter a nonempty note of at most 16384 UTF-8 bytes. Nothing was saved."
      case .invalidSelection: feedback = "Select supported original PDF text before this action."
      case .stalePaper:
        records = []; feedback = "This Paper is no longer available for annotation."
      case .staleRecord: feedback = "This record changed or was removed. Refresh before editing."
      default: feedback = "Annotation action failed. Refresh to check saved records before retrying."
      }
    }
  }
}
