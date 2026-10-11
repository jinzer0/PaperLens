import Foundation
import GRDB

extension ProductDatabase {
  /// One historical observation on the sole queue; does not admit or claim a Reader.
  public func libraryReadingRecords(paperID: UUID, generation: UUID) throws -> LibraryReadingRecords {
    try adapterRead { db in
      guard let row = try Row.fetchOne(db, sql: """
        SELECT pdfSHA256, lastReadPage, lastReadZoom FROM paper
        WHERE id = ? AND generation = ? AND status = 'ready'
          AND deletionID IS NULL AND pdfReference = ?
        """, arguments: [paperID.uuidString, generation.uuidString,
          "papers/\(paperID.uuidString)/document.pdf"]),
        let hash = String.fromDatabaseValue(row["pdfSHA256"]), hash.count == 64,
        hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
      else { throw AnnotationError.stalePaper }
      let identity = AnnotationPaperIdentity(id: paperID, generation: generation, pdfSHA256: hash)
      let pageValue: DatabaseValue = row["lastReadPage"]
      let zoomValue: DatabaseValue = row["lastReadZoom"]
      let position: ReaderPosition?
      if pageValue.isNull && zoomValue.isNull {
        position = nil
      } else {
        guard case .int64(let storedPage) = pageValue.storage,
          let page = Int(exactly: storedPage), page >= 0, page < Int.max
        else { throw ReaderError.invalidStoredPosition }
        let zoom: Double
        switch zoomValue.storage {
        case .double(let value): zoom = value
        case .int64(let value): zoom = Double(value)
        default: throw ReaderError.invalidStoredPosition
        }
        guard zoom.isFinite, (0.1...10).contains(zoom)
        else { throw ReaderError.invalidStoredPosition }
        position = ReaderPosition(pageIndex: page, zoom: zoom)
      }
      let annotations = try Row.fetchAll(db, sql: """
        SELECT * FROM personalAnnotation WHERE paperID = ? AND generation = ? ORDER BY createdAt, id
        """, arguments: [paperID.uuidString, generation.uuidString]).map { row in
          let noteValue: DatabaseValue = row["note"]
          guard String.fromDatabaseValue(row["id"]) != nil,
            String.fromDatabaseValue(row["kind"]) != nil,
            Data.fromDatabaseValue(row["selection"]) != nil,
            Int64.fromDatabaseValue(row["revision"]) != nil,
            noteValue.isNull || String.fromDatabaseValue(noteValue) != nil
          else { throw AnnotationError.corruptRecord }
          let record = try decodeAnnotation(row, identity: identity)
          guard record.selection.locations.allSatisfy({ $0.pageIndex < Int.max })
          else { throw AnnotationError.corruptRecord }
          return record
        }
      return LibraryReadingRecords(identity: identity, position: position, annotations: annotations)
    }
  }

  /// Durable identity only; file admission and lifetime remain ReaderSession's responsibility.
  public func annotationIdentity(paperID: UUID) throws -> AnnotationPaperIdentity {
    try adapterRead { db in
      guard let row = try Row.fetchOne(db, sql: """
        SELECT generation, pdfSHA256 FROM paper WHERE id = ? AND status = 'ready'
          AND deletionID IS NULL AND pdfReference = ?
        """, arguments: [paperID.uuidString, "papers/\(paperID.uuidString)/document.pdf"]),
        let generation = UUID(uuidString: row["generation"] as String),
        let hash: String = row["pdfSHA256"], hash.count == 64,
        hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
      else { throw AnnotationError.stalePaper }
      return AnnotationPaperIdentity(id: paperID, generation: generation, pdfSHA256: hash)
    }
  }

  /// Register with the existing ProductDatabase migrator before opening its sole queue.
  public static func registerAnnotationMigrations(in migrator: inout DatabaseMigrator) {
    migrator.registerMigration("personalAnnotationsV1") { db in
      try db.execute(sql: """
        CREATE TABLE personalAnnotation (
          id TEXT PRIMARY KEY NOT NULL,
          paperID TEXT NOT NULL REFERENCES paper(id) ON DELETE CASCADE,
          generation TEXT NOT NULL,
          kind TEXT NOT NULL CHECK(kind IN ('highlight', 'note')),
          selection BLOB NOT NULL,
          note TEXT,
          revision INTEGER NOT NULL CHECK(revision >= 0),
          createdAt REAL NOT NULL,
          CHECK((kind = 'highlight' AND note IS NULL) OR (kind = 'note' AND note IS NOT NULL))
        );
        CREATE INDEX personalAnnotationPaper ON personalAnnotation(paperID, createdAt, id);
        CREATE TRIGGER personalAnnotationTombstone AFTER UPDATE OF status, generation ON paper
        WHEN NEW.status = 'tombstone' OR NEW.generation != OLD.generation
        BEGIN DELETE FROM personalAnnotation WHERE paperID = NEW.id; END;
        """)
    }
  }

  private func guardAnnotationPaper(_ identity: AnnotationPaperIdentity, db: Database) throws {
    let count = try Int.fetchOne(db, sql: """
      SELECT COUNT(*) FROM paper WHERE id = ? AND generation = ? AND status = 'ready'
      AND deletionID IS NULL AND pdfSHA256 = ? AND pdfReference = ?
      """, arguments: [identity.id.uuidString, identity.generation.uuidString,
        identity.pdfSHA256, "papers/\(identity.id.uuidString)/document.pdf"])
    guard count == 1 else { throw AnnotationError.stalePaper }
  }

  func annotationRecords(for identity: AnnotationPaperIdentity) throws -> [AnnotationRecord] {
    try adapterRead { db in
      try guardAnnotationPaper(identity, db: db)
      return try Row.fetchAll(db, sql: """
        SELECT * FROM personalAnnotation WHERE paperID = ? AND generation = ? ORDER BY createdAt, id
        """, arguments: [identity.id.uuidString, identity.generation.uuidString]).map {
          try decodeAnnotation($0, identity: identity)
        }
    }
  }

  func insertAnnotation(kind: AnnotationKind, selection: PDFSelectionSnapshot, note: String?) throws
    -> AnnotationRecord {
    try selection.validate()
    if kind == .note {
      guard let note else { throw AnnotationError.invalidNote }
      try AnnotationService.validateNote(note)
    } else if note != nil { throw AnnotationError.invalidNote }
    let encoded = try JSONEncoder().encode(selection)
    let record = AnnotationRecord(id: UUID(), kind: kind, selection: selection, note: note, revision: 0)
    return try adapterWrite { db in
      try guardAnnotationPaper(selection.paper, db: db)
      try db.execute(sql: """
        INSERT INTO personalAnnotation(id, paperID, generation, kind, selection, note, revision, createdAt)
        VALUES (?, ?, ?, ?, ?, ?, 0, ?)
        """, arguments: [record.id.uuidString, selection.paper.id.uuidString,
          selection.paper.generation.uuidString, kind.rawValue, encoded, note,
          Date().timeIntervalSince1970])
      return record
    }
  }

  func updateAnnotationNote(_ record: AnnotationRecord, text: String) throws -> AnnotationRecord {
    try AnnotationService.validateNote(text)
    guard record.kind == .note, record.revision < Int64.max else { throw AnnotationError.staleRecord }
    return try adapterWrite { db in
      try guardAnnotationPaper(record.selection.paper, db: db)
      try db.execute(sql: """
        UPDATE personalAnnotation SET note = ?, revision = revision + 1
        WHERE id = ? AND paperID = ? AND generation = ? AND kind = 'note' AND revision = ?
        """, arguments: [text, record.id.uuidString, record.selection.paper.id.uuidString,
          record.selection.paper.generation.uuidString, record.revision])
      guard db.changesCount == 1 else { throw AnnotationError.staleRecord }
      guard let row = try Row.fetchOne(db, sql: "SELECT * FROM personalAnnotation WHERE id = ?",
        arguments: [record.id.uuidString]) else { throw AnnotationError.corruptRecord }
      return try decodeAnnotation(row, identity: record.selection.paper)
    }
  }

  func deleteAnnotation(_ record: AnnotationRecord) throws {
    try adapterWrite { db in
      try guardAnnotationPaper(record.selection.paper, db: db)
      try db.execute(sql: """
        DELETE FROM personalAnnotation WHERE id = ? AND paperID = ? AND generation = ? AND revision = ?
        """, arguments: [record.id.uuidString, record.selection.paper.id.uuidString,
          record.selection.paper.generation.uuidString, record.revision])
      guard db.changesCount == 1 else { throw AnnotationError.staleRecord }
    }
  }

  private func decodeAnnotation(_ row: Row, identity: AnnotationPaperIdentity) throws -> AnnotationRecord {
    let id: String = row["id"]
    let kind: String = row["kind"]
    let data: Data = row["selection"]
    let note: String? = row["note"]
    let revision: Int64 = row["revision"]
    guard let uuid = UUID(uuidString: id), let type = AnnotationKind(rawValue: kind), revision >= 0,
      let snapshot = try? JSONDecoder().decode(PDFSelectionSnapshot.self, from: data),
      snapshot.paper == identity else { throw AnnotationError.corruptRecord }
    try snapshot.validate()
    if type == .note {
      guard let note else { throw AnnotationError.corruptRecord }
      try AnnotationService.validateNote(note)
    } else if note != nil { throw AnnotationError.corruptRecord }
    return AnnotationRecord(id: uuid, kind: type, selection: snapshot, note: note, revision: revision)
  }
}
