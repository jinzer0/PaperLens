import Foundation
import GRDB

extension ProductDatabase {
  public static func registerReaderMetadataMigrations(in migrator: inout DatabaseMigrator) {
    migrator.registerMigration("readerMetadataV1") { db in
      try db.execute(sql: """
        CREATE TABLE readerMetadata (
          paperID TEXT PRIMARY KEY NOT NULL REFERENCES paper(id) ON DELETE CASCADE,
          revisionID TEXT NOT NULL, payload BLOB NOT NULL
        );
        CREATE TABLE readerMetadataContext (
          paperID TEXT PRIMARY KEY NOT NULL REFERENCES paper(id) ON DELETE CASCADE,
          revisionID TEXT NOT NULL, sessionID TEXT NOT NULL,
          sequence INTEGER NOT NULL CHECK(sequence >= 0), payload BLOB NOT NULL
        );
        CREATE TRIGGER readerMetadataInvalidation AFTER UPDATE OF status, generation, pdfSHA256, pdfReference, deletionID ON paper
        WHEN NEW.status != 'ready' OR NEW.deletionID IS NOT NULL
          OR NEW.generation != OLD.generation OR NEW.pdfSHA256 IS NOT OLD.pdfSHA256
          OR NEW.pdfReference IS NOT OLD.pdfReference
        BEGIN
          DELETE FROM readerMetadata WHERE paperID = NEW.id;
          DELETE FROM readerMetadataContext WHERE paperID = NEW.id;
        END;
        CREATE TRIGGER readerMetadataRevisionChange AFTER UPDATE OF revision ON extractionVisible
        WHEN NEW.revision != OLD.revision BEGIN
          DELETE FROM readerMetadata WHERE paperID = NEW.paperID;
          DELETE FROM readerMetadataContext WHERE paperID = NEW.paperID;
        END;
        CREATE TRIGGER readerMetadataRevisionRemoval AFTER DELETE ON extractionVisible BEGIN
          DELETE FROM readerMetadata WHERE paperID = OLD.paperID;
          DELETE FROM readerMetadataContext WHERE paperID = OLD.paperID;
        END;
        """)
    }
  }

  private static func guardReaderMetadata(_ identity: ReaderMetadataIdentity, in db: Database) throws {
    let count = try Int.fetchOne(db, sql: """
      SELECT COUNT(*) FROM paper p
      JOIN extractionVisible v ON v.paperID = p.id
      JOIN extractionRevision r ON r.id = v.revision AND r.paperID = p.id
      WHERE p.id = ? AND p.generation = ? AND p.pdfSHA256 = ? AND p.pdfReference = ?
        AND p.status = 'ready' AND p.deletionID IS NULL AND r.id = ?
        AND r.generation = p.generation AND r.pdfSHA256 = p.pdfSHA256
        AND r.pdfReference = p.pdfReference
      """, arguments: [identity.paperID.uuidString, identity.generation.uuidString,
        identity.pdfSHA256, identity.pdfReference, identity.revisionID.uuidString])
    guard count == 1 else { throw ReaderMetadataError.staleIdentity }
  }

  public func readerMetadata(for identity: ReaderMetadataIdentity) throws -> ReaderMetadataSnapshot? {
    try adapterRead { db in
      try Self.guardReaderMetadata(identity, in: db)
      guard let data = try Data.fetchOne(db, sql: "SELECT payload FROM readerMetadata WHERE paperID = ? AND revisionID = ?",
        arguments: [identity.paperID.uuidString, identity.revisionID.uuidString]) else { return nil }
      let snapshot = try JSONDecoder().decode(ReaderMetadataSnapshot.self, from: data)
      try snapshot.validate()
      return snapshot
    }
  }

  public func saveReaderMetadata(_ snapshot: ReaderMetadataSnapshot, for identity: ReaderMetadataIdentity) throws {
    try snapshot.validate()
    let data = try JSONEncoder().encode(snapshot)
    try adapterWrite { db in
      try Self.guardReaderMetadata(identity, in: db)
      try db.execute(sql: """
        INSERT INTO readerMetadata(paperID, revisionID, payload) VALUES (?, ?, ?)
        ON CONFLICT(paperID) DO UPDATE SET revisionID = excluded.revisionID, payload = excluded.payload
        """, arguments: [identity.paperID.uuidString, identity.revisionID.uuidString, data])
    }
  }

  /// Atomically fences previous Reader sessions while retaining only current-revision candidates.
  public func beginReaderMetadataSession(for identity: ReaderMetadataIdentity) throws -> ReaderMetadataContext {
    try adapterWrite { db in
      try Self.guardReaderMetadata(identity, in: db)
      var previous: ReaderMetadataContext?
      if let data = try Data.fetchOne(db, sql: "SELECT payload FROM readerMetadataContext WHERE paperID = ? AND revisionID = ?",
        arguments: [identity.paperID.uuidString, identity.revisionID.uuidString]) {
        previous = try JSONDecoder().decode(ReaderMetadataContext.self, from: data)
      }
      let context = ReaderMetadataContext(sessionID: UUID(), sequence: previous?.sequence ?? 0,
        location: previous?.location, sectionID: previous?.sectionID)
      let data = try JSONEncoder().encode(context)
      try db.execute(sql: """
        INSERT INTO readerMetadataContext(paperID, revisionID, sessionID, sequence, payload) VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(paperID) DO UPDATE SET revisionID = excluded.revisionID,
          sessionID = excluded.sessionID, sequence = excluded.sequence, payload = excluded.payload
        """, arguments: [identity.paperID.uuidString, identity.revisionID.uuidString,
          context.sessionID.uuidString, context.sequence, data])
      return context
    }
  }

  /// The caller supplies an observed PDFKit location, never a dispatched destination.
  func saveReaderMetadataContext(_ location: ReaderConfirmedLocation, sectionID: String?,
    expected: ReaderMetadataContext, for identity: ReaderMetadataIdentity) throws -> ReaderMetadataContext {
    guard location.pageIndex >= 0, location.x.isFinite, location.y.isFinite,
      expected.sequence >= 0, expected.sequence < Int64.max,
      sectionID == nil || (sectionID!.utf8.count <= 4096 && !sectionID!.isEmpty) else {
      throw ReaderMetadataError.invalidDestination
    }
    let next = ReaderMetadataContext(sessionID: expected.sessionID, sequence: expected.sequence + 1,
      location: location, sectionID: sectionID)
    let data = try JSONEncoder().encode(next)
    return try adapterWrite { db in
      try Self.guardReaderMetadata(identity, in: db)
      try db.execute(sql: """
        UPDATE readerMetadataContext SET sequence = ?, payload = ?
        WHERE paperID = ? AND revisionID = ? AND sessionID = ? AND sequence = ?
        """, arguments: [next.sequence, data, identity.paperID.uuidString, identity.revisionID.uuidString,
          expected.sessionID.uuidString, expected.sequence])
      guard db.changesCount == 1 else { throw ReaderMetadataError.staleConfirmation }
      return next
    }
  }
}
