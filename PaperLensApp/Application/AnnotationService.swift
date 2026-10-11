import Foundation
import PDFKit

public struct AnnotationPaperIdentity: Codable, Hashable, Sendable {
  public let id: UUID
  public let generation: UUID
  public let pdfSHA256: String
  public init(id: UUID, generation: UUID, pdfSHA256: String) {
    self.id = id; self.generation = generation; self.pdfSHA256 = pdfSHA256
  }
}

public enum AnnotationError: Error, Equatable {
  case invalidSelection, invalidNote, stalePaper, staleRecord, corruptRecord
}

/// PDFKit page-native coordinates, not view coordinates or canonical AI geometry.
public struct AnnotationRectangle: Codable, Equatable, Sendable {
  public let x: Double
  public let y: Double
  public let width: Double
  public let height: Double
  init(_ rect: CGRect) {
    x = Double(rect.origin.x); y = Double(rect.origin.y)
    width = Double(rect.width); height = Double(rect.height)
  }
  public var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
  var valid: Bool {
    [x, y, width, height].allSatisfy(\.isFinite) && width > 0 && height > 0
  }
}

public struct AnnotationLocation: Codable, Equatable, Sendable {
  public let pageIndex: Int
  public let rotation: Int
  public let mediaBox: AnnotationRectangle
  public let cropBox: AnnotationRectangle
  public let rectangles: [AnnotationRectangle]
}

public struct PDFSelectionSnapshot: Codable, Equatable, Sendable {
  public let paper: AnnotationPaperIdentity
  public let originalText: String
  public let locations: [AnnotationLocation]
  public let coordinateRepresentation: String

  /// Reader must hold its admitted read lease throughout this synchronous capture.
  @MainActor public static func capture(
    from view: PDFView, identity: AnnotationPaperIdentity, admittedDocument: PDFDocument
  ) throws -> PDFSelectionSnapshot {
    guard view.document === admittedDocument, let selection = view.currentSelection,
      let text = selection.string, text.utf8.count <= 65_536,
      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { throw AnnotationError.invalidSelection }
    var locations: [AnnotationLocation] = []
    let lines = selection.selectionsByLine()
    guard !lines.isEmpty, lines.count <= 4_096, selection.pages.count <= 4_096
    else { throw AnnotationError.invalidSelection }
    let pages = selection.pages.sorted {
      admittedDocument.index(for: $0) < admittedDocument.index(for: $1)
    }
    for page in pages {
      let index = admittedDocument.index(for: page)
      guard index != NSNotFound, index >= 0, index < admittedDocument.pageCount,
        admittedDocument.page(at: index) === page else { throw AnnotationError.invalidSelection }
      let rectangles = lines.filter { line in
        line.pages.contains { $0 === page }
      }.map { AnnotationRectangle($0.bounds(for: page)) }
      guard !rectangles.isEmpty, rectangles.allSatisfy(\.valid)
      else { throw AnnotationError.invalidSelection }
      locations.append(AnnotationLocation(pageIndex: index, rotation: page.rotation,
        mediaBox: AnnotationRectangle(page.bounds(for: .mediaBox)),
        cropBox: AnnotationRectangle(page.bounds(for: .cropBox)), rectangles: rectangles))
    }
    let snapshot = PDFSelectionSnapshot(paper: identity, originalText: text,
      locations: locations, coordinateRepresentation: "pdfkit-page-native-v1")
    try snapshot.validate()
    return snapshot
  }

  func validate() throws {
    guard coordinateRepresentation == "pdfkit-page-native-v1",
      !originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      originalText.utf8.count <= 65_536, !locations.isEmpty,
      locations.reduce(0, { $0 + $1.rectangles.count }) <= 4_096
    else { throw AnnotationError.invalidSelection }
    var last = -1
    for location in locations {
      guard location.pageIndex > last, location.mediaBox.valid, location.cropBox.valid,
        !location.rectangles.isEmpty, location.rectangles.allSatisfy(\.valid)
      else { throw AnnotationError.invalidSelection }
      last = location.pageIndex
    }
  }
}

public enum AnnotationKind: String, Codable, Sendable { case highlight, note }

public struct AnnotationRecord: Identifiable, Equatable, Sendable {
  public let id: UUID
  public let kind: AnnotationKind
  public let selection: PDFSelectionSnapshot
  public let note: String?
  public let revision: Int64
}

/// Historical records only; no PDF admission, Reader ownership, or page-count authority.
public struct LibraryReadingRecords: Sendable {
  public let identity: AnnotationPaperIdentity
  public let position: ReaderPosition?
  public let annotations: [AnnotationRecord]
}

/// Local personal records only. No Provider dependency, AI context, or PDF writes.
public struct AnnotationService: Sendable {
  private let database: ProductDatabase
  public init(database: ProductDatabase) { self.database = database }
  public func libraryReadingRecords(paperID: UUID, generation: UUID) throws -> LibraryReadingRecords {
    try database.libraryReadingRecords(paperID: paperID, generation: generation)
  }
  public func records(for paper: AnnotationPaperIdentity) throws -> [AnnotationRecord] {
    try database.annotationRecords(for: paper)
  }
  public func createHighlight(_ selection: PDFSelectionSnapshot) throws -> AnnotationRecord {
    try selection.validate()
    return try database.insertAnnotation(kind: .highlight, selection: selection, note: nil)
  }
  public func createNote(_ selection: PDFSelectionSnapshot, text: String) throws -> AnnotationRecord {
    try selection.validate(); try Self.validateNote(text)
    return try database.insertAnnotation(kind: .note, selection: selection, note: text)
  }
  public func updateNote(_ record: AnnotationRecord, text: String) throws -> AnnotationRecord {
    guard record.kind == .note else { throw AnnotationError.invalidNote }
    try Self.validateNote(text)
    return try database.updateAnnotationNote(record, text: text)
  }
  public func delete(_ record: AnnotationRecord) throws { try database.deleteAnnotation(record) }
  static func validateNote(_ text: String) throws {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      text.utf8.count <= 16_384 else { throw AnnotationError.invalidNote }
  }
}
