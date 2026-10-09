import Foundation
import GRDB

extension ProductDatabase {
  /// Parent registers this on the sole existing migrator, before opening features.
  public static func registerReaderMigrations(in migrator: inout DatabaseMigrator) {
    migrator.registerMigration("readerLastReadV1") { db in
      try db.execute(sql: """
        ALTER TABLE paper ADD COLUMN lastReadPage INTEGER;
        ALTER TABLE paper ADD COLUMN lastReadZoom REAL;
        ALTER TABLE paper ADD COLUMN lastReadAt REAL;
        ALTER TABLE paper ADD COLUMN readerSession TEXT;
        ALTER TABLE paper ADD COLUMN readerSequence INTEGER NOT NULL DEFAULT 0;
        CREATE TRIGGER revokeReaderPosition AFTER UPDATE OF status, generation, pdfReference, deletionID ON paper
        WHEN NEW.status != 'ready' OR NEW.deletionID IS NOT NULL OR NEW.generation != OLD.generation
          OR NEW.pdfReference IS NOT OLD.pdfReference
        BEGIN
          UPDATE paper SET lastReadPage = NULL, lastReadZoom = NULL, lastReadAt = NULL,
            readerSession = NULL, readerSequence = 0 WHERE id = NEW.id;
        END;
        """)
    }
  }

  public func readerSnapshot(paperID: UUID) throws -> ReaderPaperSnapshot {
    try adapterRead { db in try Self.readyReaderSnapshot(db, paperID: paperID) }
  }

  public func validateReaderSnapshot(_ snapshot: ReaderPaperSnapshot) throws {
    try adapterRead { db in try Self.checkReaderSnapshot(db, snapshot: snapshot) }
  }

  func claimReader(_ snapshot: ReaderPaperSnapshot, sessionID: UUID) throws -> ReaderPosition? {
    try adapterWrite { db in
      try Self.checkReaderSnapshot(db, snapshot: snapshot)
      guard let row = try Row.fetchOne(db,
        sql: "SELECT lastReadPage, lastReadZoom FROM paper WHERE id = ?",
        arguments: [snapshot.paperID.uuidString]) else { throw ReaderError.notReady }
      let page: Int? = row["lastReadPage"]
      let zoom: Double? = row["lastReadZoom"]
      guard (page == nil) == (zoom == nil) else { throw ReaderError.invalidStoredPosition }
      if let page, let zoom {
        guard page >= 0, zoom.isFinite, (0.1...10).contains(zoom) else {
          throw ReaderError.invalidStoredPosition
        }
      }
      try db.execute(sql: """
        UPDATE paper SET readerSession = ?, readerSequence = 0
        WHERE id = ? AND generation = ? AND pdfReference = ? AND status = 'ready' AND deletionID IS NULL
        """, arguments: [sessionID.uuidString, snapshot.paperID.uuidString,
          snapshot.generation.uuidString, snapshot.pdfReference])
      guard db.changesCount == 1 else { throw ReaderError.revoked }
      if let page, let zoom { return ReaderPosition(pageIndex: page, zoom: zoom) }
      return nil
    }
  }

  func validateReaderOwner(_ snapshot: ReaderPaperSnapshot, sessionID: UUID) throws {
    try adapterRead { db in
      try Self.checkReaderSnapshot(db, snapshot: snapshot)
      let owner = try String.fetchOne(db, sql: "SELECT readerSession FROM paper WHERE id = ?",
        arguments: [snapshot.paperID.uuidString])
      guard owner == sessionID.uuidString else { throw ReaderError.replacedSession }
    }
  }

  func saveReaderPosition(
    _ position: ReaderPosition, snapshot: ReaderPaperSnapshot, sessionID: UUID, sequence: Int64
  ) throws {
    guard position.pageIndex >= 0, position.zoom.isFinite, (0.1...10).contains(position.zoom),
      sequence > 0 else { throw ReaderError.invalidPosition }
    try adapterWrite { db in
      try Self.checkReaderSnapshot(db, snapshot: snapshot)
      try db.execute(sql: """
        UPDATE paper SET lastReadPage = ?, lastReadZoom = ?, readerSequence = ?, lastReadAt = ?
        WHERE id = ? AND generation = ? AND pdfReference = ? AND status = 'ready'
          AND deletionID IS NULL AND readerSession = ? AND readerSequence < ?
        """, arguments: [position.pageIndex, position.zoom, sequence, Date().timeIntervalSince1970,
          snapshot.paperID.uuidString,
          snapshot.generation.uuidString, snapshot.pdfReference, sessionID.uuidString, sequence])
      guard db.changesCount == 1 else { throw ReaderError.replacedSession }
    }
  }

  func releaseReader(_ snapshot: ReaderPaperSnapshot, sessionID: UUID) throws {
    try adapterWrite { db in
      try db.execute(sql: """
        UPDATE paper SET readerSession = NULL WHERE id = ? AND generation = ?
          AND pdfReference = ? AND readerSession = ?
        """, arguments: [snapshot.paperID.uuidString, snapshot.generation.uuidString,
          snapshot.pdfReference, sessionID.uuidString])
    }
  }

  private static func readyReaderSnapshot(_ db: Database, paperID: UUID) throws -> ReaderPaperSnapshot {
    guard let row = try Row.fetchOne(db, sql: """
      SELECT generation, pdfReference, title FROM paper
      WHERE id = ? AND status = 'ready' AND deletionID IS NULL
      """, arguments: [paperID.uuidString]) else { throw ReaderError.notReady }
    let generation: String = row["generation"]
    let reference: String? = row["pdfReference"]
    guard let generationID = UUID(uuidString: generation),
      let reference, reference == "papers/\(paperID.uuidString)/document.pdf" else {
      throw ReaderError.invalidReference
    }
    return ReaderPaperSnapshot(paperID: paperID, generation: generationID,
      pdfReference: reference, title: row["title"])
  }

  private static func checkReaderSnapshot(_ db: Database, snapshot: ReaderPaperSnapshot) throws {
    let current = try readyReaderSnapshot(db, paperID: snapshot.paperID)
    guard current.generation == snapshot.generation,
      current.pdfReference == snapshot.pdfReference else { throw ReaderError.revoked }
  }
}
