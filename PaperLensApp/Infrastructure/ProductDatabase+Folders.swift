import Foundation
import GRDB

public struct LibraryFolder: Identifiable, Equatable, Sendable {
  public let id: UUID
  public let name: String
}

/// An observed value, not PDF read authority or protection against placement ABA.
public struct CapturedPaperPlacement: Equatable, Sendable {
  public let paperID: UUID
  public let generation: UUID
  public let sha256: String
  public let pdfReference: String
  public let folder: LibraryFolder?
}

public enum FolderImportError: Error, Equatable, Sendable {
  case invalidName, missingFolder, paperNotReady, invalidSource, sourceChanged, consumedIntent
  case stalePlacement
}

extension ProductDatabase {
  public static func registerFolderMigrations(in migrator: inout DatabaseMigrator) {
    migrator.registerMigration("libraryFoldersV1") { db in
      try db.execute(sql: """
        CREATE TABLE libraryFolder (id TEXT PRIMARY KEY NOT NULL, name TEXT NOT NULL);
        CREATE TABLE paperFolder (
          paperID TEXT PRIMARY KEY NOT NULL REFERENCES paper(id) ON DELETE CASCADE,
          folderID TEXT NOT NULL REFERENCES libraryFolder(id) ON DELETE CASCADE
        );
        CREATE INDEX paperFolderDestination ON paperFolder(folderID);
        CREATE TRIGGER clearTombstoneFolder AFTER UPDATE OF status ON paper
        WHEN NEW.status = 'tombstone' BEGIN
          DELETE FROM paperFolder WHERE paperID = NEW.id;
        END;
        """)
    }
  }

  public func folders() throws -> [LibraryFolder] {
    try adapterRead { db in
      try Row.fetchAll(db, sql: "SELECT id, name FROM libraryFolder ORDER BY name COLLATE NOCASE, id")
        .map { row in
          let raw: String = row["id"]
          guard let id = UUID(uuidString: raw) else { throw ProductDatabaseError.invalidRecord }
          return LibraryFolder(id: id, name: row["name"])
        }
    }
  }

  public func createFolder(name: String) throws -> LibraryFolder {
    let name = try Self.validFolderName(name)
    let folder = LibraryFolder(id: UUID(), name: name)
    try adapterWrite { db in
      try db.execute(sql: "INSERT INTO libraryFolder(id, name) VALUES (?, ?)",
        arguments: [folder.id.uuidString, folder.name])
    }
    return folder
  }

  public func renameFolder(id: UUID, name: String) throws {
    let name = try Self.validFolderName(name)
    try adapterWrite { db in
      try db.execute(sql: "UPDATE libraryFolder SET name = ? WHERE id = ?",
        arguments: [name, id.uuidString])
      guard db.changesCount == 1 else { throw FolderImportError.missingFolder }
    }
  }

  /// Unfiles placements in the same transaction; never touches physical PDFs.
  public func deleteFolder(id: UUID) throws {
    try adapterWrite { db in
      try db.execute(sql: "DELETE FROM libraryFolder WHERE id = ?", arguments: [id.uuidString])
      guard db.changesCount == 1 else { throw FolderImportError.missingFolder }
    }
  }

  public func folderID(for paperID: UUID) throws -> UUID? {
    try adapterRead { db in
      let raw = try String.fetchOne(db, sql: """
        SELECT folderID FROM paperFolder JOIN paper ON paper.id = paperFolder.paperID
        WHERE paper.id = ? AND paper.status = 'ready' AND paper.deletionID IS NULL
        """, arguments: [paperID.uuidString])
      guard let raw else { return nil }
      guard let id = UUID(uuidString: raw) else { throw ProductDatabaseError.invalidRecord }
      return id
    }
  }

  public func capturePaperPlacement(paperID: UUID, generation: UUID) throws -> CapturedPaperPlacement {
    try adapterRead { db in
      try Self.capturePaperPlacement(paperID: paperID, generation: generation, in: db)
    }
  }

  public func movePaper(_ captured: CapturedPaperPlacement, to folderID: UUID?) throws {
    try adapterWrite { db in
      let current = try Self.capturePaperPlacement(paperID: captured.paperID,
        generation: captured.generation, in: db)
      guard current == captured else { throw FolderImportError.stalePlacement }
      try Self.assignImportedPaper(captured.paperID, folderID: folderID, in: db)
    }
  }

  private static func capturePaperPlacement(paperID: UUID, generation: UUID,
    in db: Database) throws -> CapturedPaperPlacement {
    guard let row = try Row.fetchOne(db, sql: """
      SELECT p.id, p.generation, p.pdfSHA256, p.pdfReference,
        pf.folderID, f.name AS folderName
      FROM paper p LEFT JOIN paperFolder pf ON pf.paperID = p.id
      LEFT JOIN libraryFolder f ON f.id = pf.folderID
      WHERE p.id = ? AND p.generation = ? AND p.status = 'ready' AND p.deletionID IS NULL
      """, arguments: [paperID.uuidString, generation.uuidString])
    else { throw FolderImportError.paperNotReady }
    let id: String = row["id"], storedGeneration: String = row["generation"]
    let digest: String? = row["pdfSHA256"], reference: String? = row["pdfReference"]
    guard UUID(uuidString: id) == paperID, UUID(uuidString: storedGeneration) == generation,
      let digest, digest.count == 64, digest.allSatisfy({ "0123456789abcdef".contains($0) }),
      let reference, reference == "papers/\(id)/document.pdf"
    else { throw ProductDatabaseError.invalidRecord }
    let rawFolder: String? = row["folderID"], name: String? = row["folderName"]
    let folder: LibraryFolder?
    if let rawFolder {
      guard let folderID = UUID(uuidString: rawFolder), let name else {
        throw ProductDatabaseError.invalidRecord
      }
      folder = LibraryFolder(id: folderID, name: name)
    } else {
      guard name == nil else { throw ProductDatabaseError.invalidRecord }
      folder = nil
    }
    return CapturedPaperPlacement(paperID: paperID, generation: generation,
      sha256: digest, pdfReference: reference, folder: folder)
  }

  public func validateFolderDestination(_ folderID: UUID?) throws {
    try adapterRead { db in try Self.validateImportDestination(folderID, in: db) }
  }

  static func validateImportDestination(_ folderID: UUID?, in db: Database) throws {
    guard let folderID else { return }
    guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM libraryFolder WHERE id = ?",
      arguments: [folderID.uuidString]) == 1 else { throw FolderImportError.missingFolder }
  }

  /// Called by the existing publication owner AFTER ready publication, in its transaction.
  static func assignImportedPaper(_ paperID: UUID, folderID: UUID?, in db: Database) throws {
    try validateImportDestination(folderID, in: db)
    guard try Int.fetchOne(db, sql: """
      SELECT COUNT(*) FROM paper WHERE id = ? AND status = 'ready'
        AND deletionID IS NULL AND pdfReference IS NOT NULL AND pdfSHA256 IS NOT NULL
      """, arguments: [paperID.uuidString]) == 1 else { throw FolderImportError.paperNotReady }
    if let folderID {
      try db.execute(sql: """
        INSERT INTO paperFolder(paperID, folderID) VALUES (?, ?)
        ON CONFLICT(paperID) DO UPDATE SET folderID = excluded.folderID
        """, arguments: [paperID.uuidString, folderID.uuidString])
    } else {
      try db.execute(sql: "DELETE FROM paperFolder WHERE paperID = ?", arguments: [paperID.uuidString])
    }
  }

  public func contentHashMatches(_ sha256: String) throws -> [UUID] {
    try adapterRead { db in
      try String.fetchAll(db, sql: """
        SELECT id FROM paper WHERE pdfSHA256 = ? AND status = 'ready'
          AND deletionID IS NULL AND pdfReference IS NOT NULL ORDER BY id
        """, arguments: [sha256]).map {
          guard let id = UUID(uuidString: $0) else { throw ProductDatabaseError.invalidRecord }
          return id
        }
    }
  }

  private static func validFolderName(_ name: String) throws -> String {
    let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty, value.count <= 120,
      !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    else { throw FolderImportError.invalidName }
    return value
  }
}
