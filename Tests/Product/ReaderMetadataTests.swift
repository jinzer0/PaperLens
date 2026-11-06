import Foundation
import GRDB
import PDFKit
import XCTest
@testable import PaperLensProduct

final class ReaderMetadataTests: XCTestCase {
  private func identity() -> ReaderMetadataIdentity {
    let id = UUID()
    return .init(paperID: id, generation: UUID(), pdfSHA256: String(repeating: "a", count: 64),
      pdfReference: "papers/\(id.uuidString)/document.pdf", revisionID: UUID())
  }

  /// SQL fixtures model durable accepted visibility only, not PDFium output or runtime proof.
  private func seed(_ identity: ReaderMetadataIdentity, in database: ProductDatabase) throws {
    try database.adapterWrite { db in
      try db.execute(sql: """
        INSERT INTO paper(id, generation, title, status, pdfReference, pdfSHA256, createdAt)
        VALUES (?, ?, 'Fixture', 'ready', ?, ?, 0)
        """, arguments: [identity.paperID.uuidString, identity.generation.uuidString,
          identity.pdfReference, identity.pdfSHA256])
      try db.execute(sql: """
        INSERT INTO extractionRevision(id, paperID, generation, pdfSHA256, pdfReference)
        VALUES (?, ?, ?, ?, ?)
        """, arguments: [identity.revisionID.uuidString, identity.paperID.uuidString,
          identity.generation.uuidString, identity.pdfSHA256, identity.pdfReference])
      try db.execute(sql: "INSERT INTO extractionVisible(paperID, revision) VALUES (?, ?)",
        arguments: [identity.paperID.uuidString, identity.revisionID.uuidString])
    }
  }

  private func withDatabase(_ body: (ProductDatabase, URL) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    // The product owner must register extraction and metadata migrations before opening.
    try body(ProductDatabase.open(at: root), root)
  }

  func testProvenanceConflictMissingAndValidation() throws {
    let source = ReaderMetadataValue(text: "Actual title", source: .source, sourceID: "source-1")
    let extraction = ReaderMetadataValue(text: "Other title", source: .acceptedExtraction, sourceID: "revision-1")
    let snapshot = ReaderMetadataSnapshot(title: .init([source, extraction]))
    XCTAssertTrue(snapshot.title.isConflict)
    XCTAssertTrue(snapshot.title.display.contains("source-1"))
    XCTAssertTrue(snapshot.title.display.contains("revision-1"))
    XCTAssertEqual(snapshot.year.display, "미확인")
    XCTAssertEqual(snapshot.abstract.display, "미확인")
    XCTAssertEqual(snapshot.topics.display, "미확인")
    let invalid = ReaderMetadataSnapshot(title: .init([.init(text: " ", source: .source, sourceID: "s")]))
    XCTAssertThrowsError(try invalid.validate())
    XCTAssertEqual(try JSONDecoder().decode(ReaderMetadataSnapshot.self,
      from: JSONEncoder().encode(snapshot)), snapshot)
  }

  func testDurableRestartSessionCASAndPaperIsolation() throws {
    try withDatabase { database, root in
      let current = identity(), other = identity()
      try seed(current, in: database); try seed(other, in: database)
      let metadata = ReaderMetadataSnapshot(title: .init([.init(text: "Source title", source: .source, sourceID: "record")]))
      let service = ReaderMetadataService(database: database)
      try service.accept(metadata, for: current)
      XCTAssertEqual(try service.metadata(for: other), ReaderMetadataSnapshot())
      let session = try service.beginSession(for: current)
      let location = ReaderConfirmedLocation(pageIndex: 2, x: 20, y: 100)
      let saved = try service.saveConfirmed(location, sectionID: "/0", expected: session, for: current)
      XCTAssertThrowsError(try service.saveConfirmed(.init(pageIndex: 0, x: 0, y: 0),
        sectionID: nil, expected: session, for: current))
      let reopened = try ProductDatabase.open(at: root)
      let restarted = ReaderMetadataService(database: reopened)
      XCTAssertEqual(try restarted.metadata(for: current), metadata)
      let newSession = try restarted.beginSession(for: current)
      XCTAssertEqual(newSession.location, location)
      XCTAssertNotEqual(newSession.sessionID, saved.sessionID)
      XCTAssertThrowsError(try service.saveConfirmed(location, sectionID: nil, expected: saved, for: current))
    }
  }

  func testRevisionSwitchDeleteAndLateCallbacksDoNotResurrect() throws {
    try withDatabase { database, _ in
      let current = identity(), other = identity()
      try seed(current, in: database); try seed(other, in: database)
      let service = ReaderMetadataService(database: database)
      let metadata = ReaderMetadataSnapshot(title: .init([.init(text: "Actual", source: .source, sourceID: "s")]))
      try service.accept(metadata, for: current); try service.accept(metadata, for: other)
      let session = try service.beginSession(for: current)
      try database.adapterWrite { db in
        try db.execute(sql: "DELETE FROM extractionVisible WHERE paperID = ?", arguments: [current.paperID.uuidString])
      }
      XCTAssertThrowsError(try service.metadata(for: current))
      XCTAssertThrowsError(try service.accept(metadata, for: current))
      try database.adapterWrite { db in
        try db.execute(sql: "INSERT INTO extractionVisible(paperID, revision) VALUES (?, ?)",
          arguments: [current.paperID.uuidString, current.revisionID.uuidString])
      }
      _ = try database.beginDeletion(current.paperID)
      XCTAssertThrowsError(try service.metadata(for: current))
      XCTAssertThrowsError(try service.accept(metadata, for: current))
      XCTAssertThrowsError(try service.saveConfirmed(.init(pageIndex: 0, x: 0, y: 0),
        sectionID: nil, expected: session, for: current))
      let remaining = try database.adapterRead { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM readerMetadata WHERE paperID = ?",
          arguments: [current.paperID.uuidString])
      }
      XCTAssertEqual(remaining, 0)
      XCTAssertEqual(try service.metadata(for: other), metadata)
    }
  }

  func testNewVisibleRevisionInvalidatesOldContextAndMetadata() throws {
    try withDatabase { database, _ in
      let old = identity()
      try seed(old, in: database)
      let service = ReaderMetadataService(database: database)
      try service.accept(.init(title: .init([.init(text: "Old", source: .acceptedExtraction,
        sourceID: old.revisionID.uuidString)])), for: old)
      let session = try service.beginSession(for: old)
      let new = ReaderMetadataIdentity(paperID: old.paperID, generation: old.generation,
        pdfSHA256: old.pdfSHA256, pdfReference: old.pdfReference, revisionID: UUID())
      try database.adapterWrite { db in
        try db.execute(sql: """
          INSERT INTO extractionRevision(id, paperID, generation, pdfSHA256, pdfReference)
          VALUES (?, ?, ?, ?, ?)
          """, arguments: [new.revisionID.uuidString, new.paperID.uuidString,
            new.generation.uuidString, new.pdfSHA256, new.pdfReference])
        try db.execute(sql: "UPDATE extractionVisible SET revision = ? WHERE paperID = ?",
          arguments: [new.revisionID.uuidString, new.paperID.uuidString])
      }
      XCTAssertThrowsError(try service.metadata(for: old))
      XCTAssertThrowsError(try service.saveConfirmed(.init(pageIndex: 0, x: 10, y: 20),
        sectionID: nil, expected: session, for: old))
      XCTAssertEqual(try service.metadata(for: new), ReaderMetadataSnapshot())
      XCTAssertNil(try service.beginSession(for: new).location)
    }
  }

  func testConfirmedDestinationValidationEdges() {
    let bounds = CGRect(x: 0, y: 0, width: 200, height: 300)
    XCTAssertTrue(ReaderConfirmedLocation(pageIndex: 0, x: 10, y: 20).isValid(pageCount: 1, bounds: bounds))
    for location in [ReaderConfirmedLocation(pageIndex: -1, x: 10, y: 20),
      .init(pageIndex: 1, x: 10, y: 20), .init(pageIndex: 0, x: .nan, y: 20),
      .init(pageIndex: 0, x: 10, y: .infinity), .init(pageIndex: 0, x: 201, y: 20)] {
      XCTAssertFalse(location.isValid(pageCount: 1, bounds: bounds))
    }
  }

  @MainActor
  func testRestorationDestinationUsesCurrentCropBoundsAndNativePage() throws {
    let document = PDFDocument(), page = PDFPage()
    page.setBounds(CGRect(x: 20, y: 30, width: 200, height: 300), for: .cropBox)
    document.insert(page, at: 0)
    let adapter = ReaderOutlineAdapter(document: document, identity: identity())
    func context(_ location: ReaderConfirmedLocation) -> ReaderMetadataContext {
      .init(sessionID: UUID(), sequence: 1, location: location, sectionID: "untrusted")
    }
    let valid = context(.init(pageIndex: 0, x: 40, y: 150))
    let destination = try XCTUnwrap(adapter.restorationDestination(valid))
    XCTAssertTrue(destination.page === page)
    XCTAssertEqual(destination.point, CGPoint(x: 40, y: 150))
    for location in [
      ReaderConfirmedLocation(pageIndex: -1, x: 40, y: 150),
      .init(pageIndex: 1, x: 40, y: 150),
      .init(pageIndex: 0, x: 19, y: 150),
      .init(pageIndex: 0, x: 40, y: 331),
      .init(pageIndex: 0, x: .nan, y: 150),
      .init(pageIndex: 0, x: 40, y: .infinity)
    ] {
      XCTAssertNil(adapter.restorationDestination(context(location)))
    }
    page.setBounds(CGRect(x: 100, y: 100, width: 100, height: 100), for: .cropBox)
    XCTAssertNil(adapter.restorationDestination(valid))
    document.removePage(at: 0)
    XCTAssertNil(adapter.restorationDestination(valid))
  }

  @MainActor
  func testActualOutlineMappingAndInvalidDestinationsWithoutRendererTrial() throws {
    let document = PDFDocument(), page = PDFPage(), foreignPage = PDFPage()
    page.setBounds(CGRect(x: 0, y: 0, width: 200, height: 300), for: .cropBox)
    document.insert(page, at: 0)
    let root = PDFOutline(), first = PDFOutline(), second = PDFOutline(), invalid = PDFOutline()
    first.label = "Introduction"; first.destination = PDFDestination(page: page, at: CGPoint(x: 10, y: 250))
    second.label = "Methods"; second.destination = PDFDestination(page: page, at: CGPoint(x: 10, y: 100))
    invalid.label = "Invalid"; invalid.destination = PDFDestination(page: foreignPage, at: .zero)
    root.insertChild(first, at: 0); root.insertChild(second, at: 1); root.insertChild(invalid, at: 2)
    document.outlineRoot = root
    let current = identity()
    let adapter = ReaderOutlineAdapter(document: document, identity: current)
    XCTAssertEqual(adapter.sections.count, 3)
    XCTAssertNil(adapter.sections[2].location)
    XCTAssertEqual(adapter.activeSection(at: .init(pageIndex: 0, x: 10, y: 200)), "/0")
    XCTAssertEqual(adapter.activeSection(at: .init(pageIndex: 0, x: 10, y: 80)), "/1")
    XCTAssertNil(adapter.activeSection(at: .init(pageIndex: 0, x: 10, y: 280)))
    let view = PDFView()
    XCTAssertThrowsError(try adapter.confirmedPosition(in: view, current: current))
    view.document = document
    XCTAssertThrowsError(try adapter.navigate(sectionID: "/2", in: view, current: current))
    XCTAssertThrowsError(try adapter.navigate(sectionID: "/0", in: view, current: identity()))
    XCTAssertNil(adapter.validatedRestoration(.init(sessionID: UUID(), sequence: 1,
      location: .init(pageIndex: 7, x: 0, y: 0), sectionID: "/0")))
    XCTAssertTrue(ReaderOutlineAdapter(document: PDFDocument(), identity: current).sections.isEmpty)
  }
}
