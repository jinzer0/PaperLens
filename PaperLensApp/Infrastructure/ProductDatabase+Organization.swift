import CryptoKit
import Darwin
import Foundation
import GRDB

#if SWIFT_PACKAGE
  import ProviderRequest
#endif

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
      try writeOrganizationPreferences(value, in: db)
    }
  }

  func updateOrganizationPreference(_ change: OrganizationPreferenceChange) throws {
    try adapterWrite { db in
      var value = try organizationPreferences(in: db)
      switch change {
      case .presentation(let presentation): value.presentation = presentation
      case .sort(let sort): value.sort = sort
      }
      try writeOrganizationPreferences(value, in: db)
    }
  }

  private func writeOrganizationPreferences(_ value: OrganizationPreferences, in db: Database) throws {
    try db.execute(sql: "UPDATE organizationPreferences SET presentation = ?, sort = ? WHERE singleton = 1",
      arguments: [value.presentation.rawValue, value.sort.rawValue])
    guard db.changesCount == 1, try organizationPreferences(in: db) == value else {
      throw ProductDatabaseError.invalidRecord
    }
  }

  public func organizationSnapshot(filter: OrganizationFilter) throws -> OrganizationSnapshot {
    try adapterRead { try organizationSnapshot(filter: filter, in: $0) }
  }

  /// The Library rows, detail facts and sidebar describe the same committed state.
  func organizationObservation(filter: OrganizationFilter) throws -> OrganizationObservation {
    try adapterRead { try organizationObservation(filter: filter, in: $0) }
  }

  func readOrganizationObservation(filter: OrganizationFilter) async throws -> OrganizationObservation {
    try await adapterReadAsync { try self.organizationObservation(filter: filter, in: $0) }
  }

  private func organizationObservation(filter: OrganizationFilter, in db: Database) throws -> OrganizationObservation {
    let snapshot = try organizationSnapshot(filter: filter, in: db)
    try Task.checkCancellation()
    let ids = Set(snapshot.papers.filter { $0.status == .ready }.map(\.id))
    let facts = try librarySortFacts(for: ids, in: db)
    return OrganizationObservation(snapshot: snapshot, facts: facts,
      folders: try? folders(in: db), tags: try? organizationTags(in: db))
  }

  private func organizationPreferences(in db: Database) throws -> OrganizationPreferences {
    guard let preference = try Row.fetchOne(db, sql: "SELECT presentation, sort FROM organizationPreferences WHERE singleton = 1"),
      let presentation = LibraryPresentation(rawValue: preference["presentation"]),
      let sort = LibrarySort(rawValue: preference["sort"])
    else { throw ProductDatabaseError.invalidRecord }
    return OrganizationPreferences(presentation: presentation, sort: sort)
  }

  private func organizationSnapshot(filter: OrganizationFilter, in db: Database) throws -> OrganizationSnapshot {
    let preferences = try organizationPreferences(in: db)
    let totalCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM paper WHERE status != 'tombstone'")!
    let folderPredicate: String
    let folderArguments: StatementArguments
    switch filter.folder {
    case .all:
      folderPredicate = "1"
      folderArguments = []
    case .unfiled:
      folderPredicate = "NOT EXISTS (SELECT 1 FROM paperFolder pf WHERE pf.paperID = p.id)"
      folderArguments = []
    case .folder(let id):
      folderPredicate = "EXISTS (SELECT 1 FROM paperFolder pf WHERE pf.paperID = p.id AND pf.folderID = ?)"
      folderArguments = [id.uuidString]
    }
    let result = try organizationPapers(filter: filter, matching: folderPredicate,
      arguments: folderArguments, in: db)
    return OrganizationSnapshot(preferences: preferences, totalCount: totalCount,
      folderCount: result.unfilteredCount, papers: result.papers)
  }

  private func organizationPapers(filter: OrganizationFilter, matching predicate: String,
    arguments: StatementArguments, in db: Database, requireReadable: Bool = false)
    throws -> (papers: [OrganizedPaper], unfilteredCount: Int) {
    let rows = try Row.fetchAll(db, sql: """
      SELECT p.*, j.id AS importJobID, j.state AS importJobState,
        j.recoveryJournal IS NOT NULL AS hasImportHistory,
        CASE WHEN p.status IN ('deleting', 'deletionFailed') THEN p.deletionFailure
          ELSE j.failure END AS failure,
        COALESCE(j.bytesCopied, 0) AS bytesCopied,
        COALESCE(o.readingStatus, 'unread') AS readingStatus,
        COALESCE(o.favorite, 0) AS favorite, m.payload AS metadataPayload
      FROM paper p LEFT JOIN importJob j ON j.paperID = p.id
      LEFT JOIN paperOrganization o ON o.paperID = p.id AND o.generation = p.generation
      \(Self.currentLibraryMetadataJoins)
      WHERE p.status != 'tombstone' AND (\(predicate)) ORDER BY p.id
      """, arguments: arguments)
    let tagRows = try Row.fetchAll(db, sql: """
      SELECT t.paperID, t.label FROM paperUserTag t
      JOIN paperOrganization o ON o.paperID = t.paperID
      JOIN paper p ON p.id = o.paperID AND p.generation = o.generation
      WHERE p.status != 'tombstone' AND (\(predicate)) ORDER BY t.normalized, t.label
      """, arguments: arguments)
    var tags: [String: [String]] = [:]
    for row in tagRows { tags[row["paperID"], default: []].append(row["label"]) }
    let search = LibraryOrganizationService.normalized(filter.search.trimmingCharacters(in: .whitespacesAndNewlines))
    let tag = filter.tag.map(LibraryOrganizationService.normalized)
    let papers = try rows.compactMap { row -> OrganizedPaper? in
      try Task.checkCancellation()
      let idString: String = row["id"], generationString: String = row["generation"]
      guard let id = UUID(uuidString: idString), let generation = UUID(uuidString: generationString),
        let status = LibraryStatus(rawValue: row["status"]),
        let readingStatus = PaperReadingStatus(rawValue: row["readingStatus"])
      else { throw ProductDatabaseError.invalidRecord }
      let labels = tags[idString] ?? []
      let normalizedTags = labels.map(LibraryOrganizationService.normalized)
      let favorite: Bool = row["favorite"]
      guard tag.map(normalizedTags.contains) ?? true,
        filter.readingStatus.map({ $0 == readingStatus }) ?? true,
        !filter.favoritesOnly || favorite else { return nil }
      let title: String = row["title"]
      let metadata = try Self.libraryMetadataObservation(row.decode(Data?.self, forColumn: "metadataPayload"))
      let sourceTitle = metadata.snapshot?.title
      let resolvedTitle = sourceTitle.flatMap { $0.isConflict ? nil : $0.candidates.first?.text }
      guard search.isEmpty || LibraryOrganizationService.normalized(title).contains(search)
        || resolvedTitle.map({ LibraryOrganizationService.normalized($0).contains(search) }) == true
        || normalizedTags.contains(where: { $0.contains(search) }) else { return nil }
      let failure = try Self.libraryFailure(row, status: status, in: db)
      let canRetryImport = status == .importFailed && failure != "missingPDF"
        && String.fromDatabaseValue(row["importJobState"]) == "failed"
        && (row["hasImportHistory"] as Bool) && !(row["cleanupDebt"] as Bool)
      let readable: Bool
      do {
        try validateOrganizationPDF(row, verifyDigest: true)
        readable = true
      } catch {
        if requireReadable { throw error }
        readable = false
      }
      try Task.checkCancellation()
      return OrganizedPaper(id: id, generation: generation, title: title, sourceTitle: sourceTitle,
        sourceMetadataInvalid: metadata.invalid, status: status,
        deletionID: String.fromDatabaseValue(row["deletionID"]).flatMap(UUID.init(uuidString:)),
        failure: failure, bytesCopied: row["bytesCopied"], createdAt: Date(timeIntervalSince1970: row["createdAt"]),
        readable: readable, canRetryImport: canRetryImport,
        organization: PaperOrganization(readingStatus: readingStatus, favorite: favorite, tags: labels))
    }
    return (papers, rows.count)
  }

  func readOrganizationEditorPaper(paperID: UUID, generation: UUID) async throws -> OrganizedPaper {
    try await adapterReadAsync { db in
      let result = try self.organizationPapers(filter: .init(), matching: "p.id = ? AND p.generation = ?",
        arguments: [paperID.uuidString, generation.uuidString], in: db, requireReadable: true)
      guard let paper = result.papers.first else {
        throw OrganizationError.stalePaper
      }
      return paper
    }
  }

  public func organizationTags() throws -> [String] {
    try adapterRead { try organizationTags(in: $0) }
  }

  private func organizationTags(in db: Database) throws -> [String] {
    try String.fetchAll(db, sql: """
      SELECT MIN(t.label) FROM paperUserTag t
      JOIN paperOrganization o ON o.paperID = t.paperID
      JOIN paper p ON p.id = o.paperID AND p.generation = o.generation
      WHERE p.status != 'tombstone'
      GROUP BY t.normalized ORDER BY t.normalized, MIN(t.label)
      """)
  }

  public func updatePaperOrganization(paperID: UUID, generation: UUID,
    expected: PaperOrganization, value: PaperOrganization) throws {
    var normalized: Set<String> = []
    let labels = try value.tags.map { label -> (label: String, normalized: String) in
      let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
      let key = LibraryOrganizationService.normalized(label)
      guard !label.isEmpty, label.count <= 80, !label.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
        normalized.insert(key).inserted else { throw OrganizationError.invalidTags }
      return (label, key)
    }
    guard labels.count <= 100 else { throw OrganizationError.invalidTags }
    let expectedLabels = Dictionary(uniqueKeysWithValues: labels.map {
      (Data($0.normalized.utf8), Data($0.label.utf8))
    })
    try adapterWrite { db in
      let row = try currentOrganizationPaper(db, paperID: paperID, generation: generation)
      try validateOrganizationPDF(row, verifyDigest: true)
      let stored = try Row.fetchOne(db, sql: """
        SELECT readingStatus, favorite FROM paperOrganization WHERE paperID = ? AND generation = ?
        """, arguments: [paperID.uuidString, generation.uuidString])
      let current: PaperOrganization
      if let stored {
        guard let status = PaperReadingStatus(rawValue: stored["readingStatus"])
        else { throw ProductDatabaseError.invalidRecord }
        let tags = try String.fetchAll(db, sql: """
          SELECT label FROM paperUserTag WHERE paperID = ? ORDER BY normalized, label
          """, arguments: [paperID.uuidString])
        current = PaperOrganization(readingStatus: status, favorite: stored["favorite"], tags: tags)
      } else {
        current = PaperOrganization()
      }
      guard current == expected else { throw OrganizationError.staleOrganization }
      try db.execute(sql: """
        INSERT INTO paperOrganization(paperID, generation, readingStatus, favorite) VALUES (?, ?, ?, ?)
        ON CONFLICT(paperID) DO UPDATE SET generation = excluded.generation,
          readingStatus = excluded.readingStatus, favorite = excluded.favorite
        """, arguments: [paperID.uuidString, generation.uuidString, value.readingStatus.rawValue, value.favorite])
      guard db.changesCount == 1 else { throw ProductDatabaseError.invalidRecord }
      try db.execute(sql: "DELETE FROM paperUserTag WHERE paperID = ?", arguments: [paperID.uuidString])
      for (label, key) in labels {
        try db.execute(sql: "INSERT INTO paperUserTag(paperID, label, normalized) VALUES (?, ?, ?)",
          arguments: [paperID.uuidString, label, key])
        guard db.changesCount == 1 else { throw ProductDatabaseError.invalidRecord }
      }
      let saved = try Row.fetchOne(db, sql: """
        SELECT o.readingStatus, o.favorite FROM paperOrganization o
        JOIN paper p ON p.id = o.paperID AND p.generation = o.generation
        WHERE p.id = ? AND p.generation = ? AND p.status = 'ready' AND p.deletionID IS NULL
        """, arguments: [paperID.uuidString, generation.uuidString])
      guard let saved, String.fromDatabaseValue(saved["readingStatus"]) == value.readingStatus.rawValue,
        Int64.fromDatabaseValue(saved["favorite"]) == (value.favorite ? 1 : 0) else {
        throw ProductDatabaseError.invalidRecord
      }
      let savedTags = try Row.fetchAll(db, sql: "SELECT label, normalized FROM paperUserTag WHERE paperID = ?",
        arguments: [paperID.uuidString])
      guard savedTags.count == expectedLabels.count, savedTags.allSatisfy({ row in
        guard let key = String.fromDatabaseValue(row["normalized"]),
          let label = String.fromDatabaseValue(row["label"]) else { return false }
        return expectedLabels[Data(key.utf8)] == Data(label.utf8)
      }) else {
        throw ProductDatabaseError.invalidRecord
      }
    }
  }

  public func admitOrganizationOpen(paperID: UUID, generation: UUID) throws {
    try adapterRead { db in
      try validateOrganizationPDF(currentOrganizationPaper(db, paperID: paperID, generation: generation), verifyDigest: true)
    }
  }
  func readOrganizationOpenGeneration(paperID: UUID, expectedGeneration: UUID?) async throws -> UUID {
    try await adapterReadAsync { db in
      let row = try self.currentOrganizationPaper(db, paperID: paperID, generation: expectedGeneration)
      guard let generation = String.fromDatabaseValue(row["generation"]).flatMap(UUID.init(uuidString:)) else {
        throw ProductDatabaseError.invalidRecord
      }
      try self.validateOrganizationPDF(row, verifyDigest: true)
      return generation
    }
  }

  private func currentOrganizationPaper(_ db: Database, paperID: UUID, generation: UUID?) throws -> Row {
    guard let row = try Row.fetchOne(db,
      sql: "SELECT * FROM paper WHERE id = ? AND generation = COALESCE(?, generation)",
      arguments: [paperID.uuidString, generation?.uuidString]) else { throw OrganizationError.stalePaper }
    return row
  }
  private func validateOrganizationPDF(_ row: Row, verifyDigest: Bool = false) throws {
    let id: String = row["id"], status: String = row["status"]
    let deletionID: String? = row["deletionID"], reference: String? = row["pdfReference"], digest: String? = row["pdfSHA256"]
    guard status == "ready", deletionID == nil,
      let digest, digest.count == 64, digest.allSatisfy({ "0123456789abcdef".contains($0) })
    else { throw OrganizationError.unavailablePDF }
    let pdf = try validateOwnedLibraryPDFLocation(paperID: id, reference: reference)
    if verifyDigest {
      let input = try FileHandle(forReadingFrom: pdf)
      var hash = SHA256()
      do {
        while true {
          try Task.checkCancellation()
          guard let data = try input.read(upToCount: 64 * 1024), !data.isEmpty else { break }
          hash.update(data: data)
        }
        try input.close()
      } catch { try? input.close(); throw error }
      guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == digest
      else { throw OrganizationError.unavailablePDF }
    }
  }

  private static let ownedPDFByteLimit = Result { Int64(try ProviderRequest().limit("pdfBytes")) }

  /// Startup and Library admission must agree about the immutable PDF's location and shape.
  func validateOwnedLibraryPDFLocation(paperID: String, reference: String?) throws -> URL {
    guard UUID(uuidString: paperID)?.uuidString == paperID,
      reference == "papers/\(paperID)/document.pdf" else { throw OrganizationError.unavailablePDF }
    let papers = root.appendingPathComponent("papers", isDirectory: false)
    let namespace = papers.appendingPathComponent(paperID, isDirectory: false)
    for parent in [papers, namespace] {
      let info = try libraryPDFEntry(at: parent)
      guard info.st_mode & S_IFMT == S_IFDIR else { throw OrganizationError.unavailablePDF }
    }
    let url = namespace.appendingPathComponent("document.pdf", isDirectory: false)
    let info = try libraryPDFEntry(at: url)
    let maximumBytes = try Self.ownedPDFByteLimit.get()
    guard info.st_mode & S_IFMT == S_IFREG, info.st_size > 0, info.st_size <= maximumBytes,
      info.st_mode & 0o222 == 0
    else { throw OrganizationError.unavailablePDF }
    return url
  }

  private func libraryPDFEntry(at url: URL) throws -> stat {
    var info = stat()
    if Darwin.lstat(url.path, &info) != 0 {
      let failure = errno
      if failure == ENOENT || failure == ENOTDIR { throw OrganizationError.unavailablePDF }
      throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO)
    }
    return info
  }
}
