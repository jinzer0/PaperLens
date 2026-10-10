import AppKit
import CoreText
import GRDB
import PDFKit
import XCTest
@testable import PaperLensProduct

final class AnnotationServiceTests: XCTestCase {
  private func database() throws -> ProductDatabase {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    addTeardownBlock { try FileManager.default.removeItem(at: root) }
    return try ProductDatabase.open(at: root)
  }

  private func admit(_ db: ProductDatabase) throws -> AnnotationPaperIdentity {
    let identity = AnnotationPaperIdentity(id: UUID(), generation: UUID(),
      pdfSHA256: String(repeating: "a", count: 64))
    try db.adapterWrite { sql in
      try sql.execute(sql: """
        INSERT INTO paper(id, generation, title, status, pdfReference, pdfSHA256, createdAt)
        VALUES (?, ?, 'Synthetic test PDF', 'ready', ?, ?, 0)
        """, arguments: [identity.id.uuidString, identity.generation.uuidString,
          "papers/\(identity.id.uuidString)/document.pdf", identity.pdfSHA256])
    }
    return identity
  }

  /// Synthetic native text PDF, never a user document or selection stand-in.
  @MainActor private func selection(_ identity: AnnotationPaperIdentity) throws -> PDFSelectionSnapshot {
    let data = NSMutableData()
    let consumer = try XCTUnwrap(CGDataConsumer(data: data as CFMutableData))
    var box = CGRect(x: 0, y: 0, width: 400, height: 600)
    let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
    for _ in 0..<2 {
      context.beginPDFPage(nil)
      context.textPosition = CGPoint(x: 40, y: 500)
      let string = NSAttributedString(string: "alpha original text", attributes: [
        .font: NSFont.systemFont(ofSize: 14)])
      CTLineDraw(CTLineCreateWithAttributedString(string as CFAttributedString), context)
      context.endPDFPage()
    }
    context.closePDF()
    let document = try XCTUnwrap(PDFDocument(data: data as Data))
    document.page(at: 1)?.rotation = 90
    let matches = document.findString("alpha", withOptions: [])
    XCTAssertEqual(matches.count, 2)
    let selected = PDFSelection(document: document)
    for match in matches { selected.add(match) }
    let view = PDFView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
    view.document = document; view.currentSelection = selected
    let snapshot = try PDFSelectionSnapshot.capture(from: view, identity: identity,
      admittedDocument: document)
    XCTAssertEqual(snapshot.locations.map(\.pageIndex), [0, 1])
    XCTAssertEqual(snapshot.locations[1].rotation, 90)
    XCTAssertEqual(snapshot.coordinateRepresentation, "pdfkit-page-native-v1")
    XCTAssertThrowsError(try PDFSelectionSnapshot.capture(from: view, identity: identity,
      admittedDocument: PDFDocument()))
    view.currentSelection = nil
    XCTAssertThrowsError(try PDFSelectionSnapshot.capture(from: view, identity: identity,
      admittedDocument: document))
    return snapshot
  }

  @MainActor func testCRUDReopenAndFailureAtomicity() throws {
    var db: ProductDatabase? = try database()
    let root = try XCTUnwrap(db).root
    let paper = try admit(XCTUnwrap(db))
    let snapshot = try selection(paper)
    var service: AnnotationService? = AnnotationService(database: try XCTUnwrap(db))
    let highlight = try XCTUnwrap(service).createHighlight(snapshot)
    let note = try XCTUnwrap(service).createNote(snapshot, text: "personal observation")
    XCTAssertThrowsError(try XCTUnwrap(service).updateNote(note, text: ""))
    XCTAssertThrowsError(try XCTUnwrap(service).updateNote(note, text: " \n\t"))
    XCTAssertThrowsError(try XCTUnwrap(service).updateNote(note, text: String(repeating: "가", count: 5_462)))
    XCTAssertEqual(try XCTUnwrap(service).records(for: paper).count, 2)
    let maximum = try XCTUnwrap(service).createNote(snapshot, text: String(repeating: "x", count: 16_384))
    XCTAssertEqual(maximum.note?.utf8.count, 16_384)
    try XCTUnwrap(service).delete(maximum)
    let edited = try XCTUnwrap(service).updateNote(note, text: "edited actual text")
    XCTAssertThrowsError(try XCTUnwrap(service).updateNote(note, text: "stale overwrite"))
    XCTAssertThrowsError(try XCTUnwrap(service).delete(note))
    service = nil; db = nil
    let reopened = try ProductDatabase.open(at: root)
    let fresh = AnnotationService(database: reopened)
    let records = try fresh.records(for: paper)
    XCTAssertTrue(records.contains(highlight))
    XCTAssertTrue(records.contains(edited))
    try fresh.delete(edited)
    XCTAssertEqual(try fresh.records(for: paper), [highlight])
    try fresh.delete(highlight)
    XCTAssertTrue(try fresh.records(for: paper).isEmpty)
  }

  @MainActor func testDeletionBothOrdersNoResurrectionAndUnrelatedPaperSurvives() throws {
    let db = try database()
    let paper = try admit(db)
    let other = try admit(db)
    let service = AnnotationService(database: db)
    let selected = try selection(paper)
    let old = try service.createNote(selected, text: "before deletion")
    _ = try service.createHighlight(selected)
    let unrelated = try service.createNote(selection(other), text: "unrelated")
    let saga = try XCTUnwrap(db.beginDeletion(paper.id)).saga
    XCTAssertThrowsError(try service.createHighlight(selected))
    XCTAssertThrowsError(try service.createNote(selected, text: "late note"))
    XCTAssertThrowsError(try service.updateNote(old, text: "late edit"))
    XCTAssertThrowsError(try service.records(for: paper))
    try db.finalizeDeletion(paper.id, saga: saga)
    XCTAssertEqual(try db.adapterRead { sql in
      try Int.fetchOne(sql, sql: "SELECT COUNT(*) FROM personalAnnotation WHERE paperID = ?",
        arguments: [paper.id.uuidString])
    }, 0)
    let reopened = try ProductDatabase.open(at: db.root)
    let fresh = AnnotationService(database: reopened)
    XCTAssertThrowsError(try fresh.createNote(selected, text: "restart stale"))
    XCTAssertEqual(try fresh.records(for: other), [unrelated])
  }

  @MainActor func testGenerationAndTransactionFailureRollback() throws {
    let db = try database()
    let paper = try admit(db)
    let service = AnnotationService(database: db)
    let selected = try selection(paper)
    let note = try service.createNote(selected, text: "retained on failure")
    try db.adapterWrite { sql in
      try sql.execute(sql: """
        CREATE TRIGGER rejectAnnotationInsert BEFORE INSERT ON personalAnnotation
        BEGIN SELECT RAISE(ABORT, 'injected real SQL insert failure'); END;
        CREATE TRIGGER rejectAnnotationEdit BEFORE UPDATE ON personalAnnotation
        BEGIN SELECT RAISE(ABORT, 'injected real SQL failure'); END;
        """)
    }
    XCTAssertThrowsError(try service.createHighlight(selected))
    XCTAssertThrowsError(try service.createNote(selected, text: "must not insert"))
    XCTAssertThrowsError(try service.updateNote(note, text: "must rollback"))
    XCTAssertEqual(try service.records(for: paper), [note])
    try db.adapterWrite { sql in
      try sql.execute(sql: "UPDATE paper SET generation = ? WHERE id = ?",
        arguments: [UUID().uuidString, paper.id.uuidString])
    }
    XCTAssertThrowsError(try service.createHighlight(selected))
    XCTAssertEqual(try db.adapterRead { sql in
      try Int.fetchOne(sql, sql: "SELECT COUNT(*) FROM personalAnnotation WHERE paperID = ?",
        arguments: [paper.id.uuidString])
    }, 0)
  }
}
