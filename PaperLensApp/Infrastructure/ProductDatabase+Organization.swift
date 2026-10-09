import CryptoKit
import Foundation
import GRDB

extension ProductDatabase {
  public static func registerOrganizationMigrations(in migrator: inout DatabaseMigrator) {
    migrator.registerMigration("paperOrganizationV1") { db in
      try db.execute(sql: """
        CREATE TABLE organizationPreferences (
          singleton INTEGER PRIMARY KEY CHECK(singleton = 1),
          presentation TEXT NOT NULL CHECK(presentation IN ('list','grid')),
          sort TEXT NOT NULL CHECK(sort IN ('recentlyRead','name','recentlyAdded','publicationYear'))
        );
        INSERT INTO organizationPreferences VALUES (1, 'list', 'recentlyRead');
        CREATE TABLE paperOrganization (
          paperID TEXT PRIMARY KEY REFERENCES paper(id) ON DELETE CASCADE,
          generation TEXT NOT NULL,
          readingStatus TEXT NOT NULL CHECK(readingStatus IN ('unread','reading','read')),
          favorite INTEGER NOT NULL CHECK(favorite IN (0,1))
        );
        CREATE TABLE paperUserTag (
          paperID TEXT NOT NULL REFERENCES paperOrganization(paperID) ON DELETE CASCADE,
          label TEXT NOT NULL, normalized TEXT NOT NULL,
          PRIMARY KEY(paperID, normalized)
        );
        CREATE TRIGGER organizationTombstone AFTER UPDATE OF status ON paper
        WHEN NEW.status = 'tombstone' BEGIN
          DELETE FROM paperOrganization WHERE paperID = NEW.id;
        END;
        CREATE TRIGGER organizationGeneration AFTER UPDATE OF generation ON paper
        WHEN OLD.generation != NEW.generation BEGIN
          DELETE FROM paperOrganization WHERE paperID = NEW.id;
        END;
        """)
    }
  }

  public func setOrganizationPreferences(_ value: OrganizationPreferences) throws {
    try adapterWrite { db in
      try db.execute(sql: "UPDATE organizationPreferences SET presentation = ?, sort = ? WHERE singleton = 1",
        arguments: [value.presentation.rawValue, value.sort.rawValue])
      guard db.changesCount == 1 else { throw ProductDatabaseError.invalidRecord }
    }
  }

  public func organizationSnapshot(filter: OrganizationFilter) throws -> OrganizationSnapshot {
    try adapterRead { db in
      guard let preference = try Row.fetchOne(db, sql: "SELECT presentation, sort FROM organizationPreferences WHERE singleton = 1"),
        let presentation = LibraryPresentation(rawValue: preference["presentation"]),
        let sort = LibrarySort(rawValue: preference["sort"])
      else { throw ProductDatabaseError.invalidRecord }
      let rows = try Row.fetchAll(db, sql: """
        SELECT p.*, j.failure, COALESCE(j.bytesCopied, 0) AS bytesCopied,
          COALESCE(o.readingStatus, 'unread') AS readingStatus,
          COALESCE(o.favorite, 0) AS favorite
        FROM paper p LEFT JOIN importJob j ON j.paperID = p.id
        LEFT JOIN paperOrganization o ON o.paperID = p.id AND o.generation = p.generation
        WHERE p.status != 'tombstone' ORDER BY p.id
        """)
      let tagRows = try Row.fetchAll(db, sql: """
        SELECT t.paperID, t.label FROM paperUserTag t
        JOIN paperOrganization o ON o.paperID = t.paperID
        JOIN paper p ON p.id = o.paperID AND p.generation = o.generation
        WHERE p.status != 'tombstone' ORDER BY t.normalized, t.label
        """)
      var tags: [String: [String]] = [:]
      for row in tagRows { tags[row["paperID"], default: []].append(row["label"]) }
      let search = LibraryOrganizationService.normalized(filter.search.trimmingCharacters(in: .whitespacesAndNewlines))
      let tag = filter.tag.map(LibraryOrganizationService.normalized)
      let papers = try rows.map { row -> OrganizedPaper in
        let idString: String = row["id"], generationString: String = row["generation"]
        guard let id = UUID(uuidString: idString), let generation = UUID(uuidString: generationString),
          let status = LibraryStatus(rawValue: row["status"]),
          let readingStatus = PaperReadingStatus(rawValue: row["readingStatus"])
        else { throw ProductDatabaseError.invalidRecord }
        return OrganizedPaper(id: id, generation: generation, title: row["title"], status: status,
          failure: row["failure"], bytesCopied: row["bytesCopied"], createdAt: Date(timeIntervalSince1970: row["createdAt"]),
          readable: (try? validateOrganizationPDF(row, verifyDigest: true)) != nil,
          organization: PaperOrganization(readingStatus: readingStatus, favorite: row["favorite"], tags: tags[idString] ?? []))
      }.filter { paper in
        let normalizedTags = paper.organization.tags.map(LibraryOrganizationService.normalized)
        return (search.isEmpty || LibraryOrganizationService.normalized(paper.title).contains(search) || normalizedTags.contains(where: { $0.contains(search) }))
          && (tag == nil || normalizedTags.contains(tag!))
          && (filter.readingStatus == nil || paper.organization.readingStatus == filter.readingStatus)
          && (!filter.favoritesOnly || paper.organization.favorite)
      }
      return OrganizationSnapshot(preferences: OrganizationPreferences(presentation: presentation, sort: sort), totalCount: rows.count, papers: papers)
    }
  }

  public func updatePaperOrganization(paperID: UUID, generation: UUID, value: PaperOrganization) throws {
    var normalized: Set<String> = []
    let labels = try value.tags.map { label -> (String, String) in
      let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
      let key = LibraryOrganizationService.normalized(label)
      guard !label.isEmpty, label.count <= 80, !label.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
        normalized.insert(key).inserted else { throw OrganizationError.invalidTags }
      return (label, key)
    }
    guard labels.count <= 100 else { throw OrganizationError.invalidTags }
    try adapterWrite { db in
      let row = try currentOrganizationPaper(db, paperID: paperID, generation: generation)
      try validateOrganizationPDF(row, verifyDigest: true)
      try db.execute(sql: """
        INSERT INTO paperOrganization(paperID, generation, readingStatus, favorite) VALUES (?, ?, ?, ?)
        ON CONFLICT(paperID) DO UPDATE SET generation = excluded.generation,
          readingStatus = excluded.readingStatus, favorite = excluded.favorite
        """, arguments: [paperID.uuidString, generation.uuidString, value.readingStatus.rawValue, value.favorite])
      try db.execute(sql: "DELETE FROM paperUserTag WHERE paperID = ?", arguments: [paperID.uuidString])
      for (label, key) in labels {
        try db.execute(sql: "INSERT INTO paperUserTag(paperID, label, normalized) VALUES (?, ?, ?)",
          arguments: [paperID.uuidString, label, key])
      }
    }
  }

  public func admitOrganizationOpen(paperID: UUID, generation: UUID) throws {
    try adapterRead { db in
      try validateOrganizationPDF(currentOrganizationPaper(db, paperID: paperID, generation: generation), verifyDigest: true)
    }
  }
  public func validateOrganizationDeletion(paperID: UUID, generation: UUID) throws {
    try adapterRead { db in
      let row = try currentOrganizationPaper(db, paperID: paperID, generation: generation)
      let status: String = row["status"]
      guard status != "tombstone" else { throw OrganizationError.stalePaper }
    }
  }
  private func currentOrganizationPaper(_ db: Database, paperID: UUID, generation: UUID) throws -> Row {
    guard let row = try Row.fetchOne(db, sql: "SELECT * FROM paper WHERE id = ? AND generation = ?",
      arguments: [paperID.uuidString, generation.uuidString]) else { throw OrganizationError.stalePaper }
    return row
  }
  private func validateOrganizationPDF(_ row: Row, verifyDigest: Bool = false) throws {
    let id: String = row["id"], status: String = row["status"]
    let deletionID: String? = row["deletionID"], reference: String? = row["pdfReference"], digest: String? = row["pdfSHA256"]
    guard status == "ready", deletionID == nil, reference == "papers/\(id)/document.pdf",
      let digest, digest.count == 64, digest.allSatisfy({ "0123456789abcdef".contains($0) })
    else { throw OrganizationError.unavailablePDF }
    let url = root.appendingPathComponent("papers/\(id)/document.pdf")
    for parent in [root.appendingPathComponent("papers"), url.deletingLastPathComponent()] {
      let values = try parent.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      guard values.isDirectory == true, values.isSymbolicLink != true else { throw OrganizationError.unavailablePDF }
    }
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
    guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? 0) > 0,
      let permissions, permissions & 0o222 == 0 else { throw OrganizationError.unavailablePDF }
    if verifyDigest {
      let input = try FileHandle(forReadingFrom: url)
      var hash = SHA256()
      do {
        while let data = try input.read(upToCount: 64 * 1024), !data.isEmpty { hash.update(data: data) }
        try input.close()
      } catch { try? input.close(); throw error }
      guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == digest
      else { throw OrganizationError.unavailablePDF }
    }
  }
}
