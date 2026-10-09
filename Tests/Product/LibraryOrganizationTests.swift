import CryptoKit
import Foundation
import GRDB
import XCTest
@testable import PaperLensProduct

/// ProductDatabase.open must register the feature migration in its sole startup migrator.
final class LibraryOrganizationTests: XCTestCase {
  private func root() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    addTeardownBlock { try FileManager.default.removeItem(at: root) }
    return root
  }
  private func seed(_ database: ProductDatabase, title: String, createdAt: Double = 1) throws -> (UUID, UUID) {
    let id = UUID(), generation = UUID()
    let namespace = database.root.appendingPathComponent("papers/\(id.uuidString)")
    try FileManager.default.createDirectory(at: namespace, withIntermediateDirectories: true)
    let bytes = Data("%PDF-1.7\norganization synthetic fixture\n%%EOF\n".utf8)
    let pdf = namespace.appendingPathComponent("document.pdf")
    try bytes.write(to: pdf)
    try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: pdf.path)
    let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    try database.adapterWrite { db in
      try db.execute(sql: """
        INSERT INTO paper(id, generation, title, status, pdfReference, pdfSHA256, createdAt)
        VALUES (?, ?, ?, 'ready', ?, ?, ?)
        """, arguments: [id.uuidString, generation.uuidString, title,
          "papers/\(id.uuidString)/document.pdf", digest, createdAt])
    }
    return (id, generation)
  }

  func testRestartPreferencesAndOrganizationWithIdenticalBytesSeparateIdentities() throws {
    let location = try root()
    let database = try ProductDatabase.open(at: location)
    let a = try seed(database, title: "Alpha"), b = try seed(database, title: "Alpha")
    try database.setOrganizationPreferences(.init(presentation: .grid, sort: .name))
    try database.updatePaperOrganization(paperID: a.0, generation: a.1,
      value: .init(readingStatus: .reading, favorite: true, tags: ["Résumé", "Methods"]))
    let reopened = try ProductDatabase.open(at: location)
    var filter = OrganizationFilter(); filter.search = "resume"; filter.favoritesOnly = true
    filter.readingStatus = .reading; filter.tag = "methods"
    let snapshot = try reopened.organizationSnapshot(filter: filter)
    XCTAssertEqual(snapshot.totalCount, 2)
    XCTAssertEqual(snapshot.papers.map(\.id), [a.0])
    XCTAssertEqual(snapshot.preferences, .init(presentation: .grid, sort: .name))
    XCTAssertEqual(try reopened.organizationSnapshot(filter: .init()).papers.first(where: { $0.id == b.0 })?.organization,
      .init())
    filter.search = "absent"
    XCTAssertEqual(try reopened.organizationSnapshot(filter: filter).papers.count, 0)
    XCTAssertEqual(try reopened.organizationSnapshot(filter: filter).totalCount, 2)
  }

  func testGuardFailuresLeavePreviousRecordsAndTombstoneCascades() throws {
    let database = try ProductDatabase.open(at: root())
    let a = try seed(database, title: "A"), b = try seed(database, title: "B")
    let value = PaperOrganization(readingStatus: .read, favorite: true, tags: ["Keep"])
    try database.updatePaperOrganization(paperID: a.0, generation: a.1, value: value)
    try database.updatePaperOrganization(paperID: b.0, generation: b.1, value: value)
    XCTAssertThrowsError(try database.updatePaperOrganization(paperID: a.0, generation: UUID(), value: .init()))
    XCTAssertThrowsError(try database.updatePaperOrganization(paperID: a.0, generation: a.1,
      value: .init(tags: ["Résumé", "resume"])))
    XCTAssertEqual(try database.organizationSnapshot(filter: .init()).papers.first(where: { $0.id == a.0 })?.organization, value)
    let saga = try XCTUnwrap(database.beginDeletion(a.0))
    XCTAssertThrowsError(try database.updatePaperOrganization(paperID: a.0, generation: a.1, value: .init()))
    XCTAssertThrowsError(try database.admitOrganizationOpen(paperID: a.0, generation: a.1))
    try database.deletionFailed(a.0, saga: saga, reason: "fixtureFailure")
    let failed = try XCTUnwrap(database.organizationSnapshot(filter: .init()).papers.first(where: { $0.id == a.0 }))
    XCTAssertEqual(failed.status, .deletionFailed); XCTAssertFalse(failed.readable)
    let restarted = try ProductDatabase.open(at: database.root)
    XCTAssertEqual(try restarted.organizationSnapshot(filter: .init()).papers.first(where: { $0.id == a.0 })?.status, .deletionFailed)
    XCTAssertEqual(try database.beginDeletion(a.0), saga)
    try database.finalizeDeletion(a.0, saga: saga)
    try database.adapterRead { db in
      XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM paperOrganization WHERE paperID = ?", arguments: [a.0.uuidString]), 0)
      XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM paperUserTag WHERE paperID = ?", arguments: [a.0.uuidString]), 0)
    }
    XCTAssertEqual(try database.organizationSnapshot(filter: .init()).papers.map(\.id), [b.0])
  }

  func testMissingWritableAndTamperedPDFRejectMutation() throws {
    let database = try ProductDatabase.open(at: root())
    let a = try seed(database, title: "A")
    let pdf = database.root.appendingPathComponent("papers/\(a.0.uuidString)/document.pdf")
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pdf.path)
    XCTAssertThrowsError(try database.updatePaperOrganization(paperID: a.0, generation: a.1, value: .init(favorite: true)))
    try Data("%PDF-tampered".utf8).write(to: pdf)
    try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: pdf.path)
    XCTAssertThrowsError(try database.updatePaperOrganization(paperID: a.0, generation: a.1, value: .init(favorite: true)))
    try FileManager.default.removeItem(at: pdf)
    XCTAssertFalse(try XCTUnwrap(database.organizationSnapshot(filter: .init()).papers.first).readable)
    XCTAssertThrowsError(try database.admitOrganizationOpen(paperID: a.0, generation: a.1))
  }

  func testSQLSaveFailuresRollbackAndGenerationChangeErasesTags() throws {
    let database = try ProductDatabase.open(at: root())
    let a = try seed(database, title: "A")
    let original = PaperOrganization(readingStatus: .reading, favorite: true, tags: ["Original"])
    try database.updatePaperOrganization(paperID: a.0, generation: a.1, value: original)
    try database.adapterWrite { db in
      try db.execute(sql: """
        CREATE TRIGGER rejectPreference BEFORE UPDATE ON organizationPreferences
        BEGIN SELECT RAISE(ABORT, 'fixture save failure'); END;
        CREATE TRIGGER rejectTag BEFORE INSERT ON paperUserTag
        WHEN NEW.label = 'Reject' BEGIN SELECT RAISE(ABORT, 'fixture tag failure'); END;
        """)
    }
    XCTAssertThrowsError(try database.setOrganizationPreferences(.init(presentation: .grid, sort: .name)))
    XCTAssertThrowsError(try database.updatePaperOrganization(paperID: a.0, generation: a.1,
      value: .init(readingStatus: .read, tags: ["Reject"])))
    let snapshot = try database.organizationSnapshot(filter: .init())
    XCTAssertEqual(snapshot.preferences, .init())
    XCTAssertEqual(snapshot.papers.first?.organization, original)
    try database.adapterWrite { db in
      try db.execute(sql: "UPDATE paper SET generation = ? WHERE id = ?", arguments: [UUID().uuidString, a.0.uuidString])
    }
    XCTAssertEqual(try database.organizationSnapshot(filter: .init()).papers.first?.organization, .init())
    try database.adapterRead { db in
      XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM paperUserTag WHERE paperID = ?", arguments: [a.0.uuidString]), 0)
    }
  }

  func testFourComparatorsNullPlacementTiesAndStaleFacts() async throws {
    let database = try ProductDatabase.open(at: root())
    let a = try seed(database, title: "Zulu", createdAt: 10), b = try seed(database, title: "alpha", createdAt: 20)
    let c = try seed(database, title: "Alpha", createdAt: 20)
    let lifecycle = try await LocalLibraryLifecycle.open(database: database)
    let service = LibraryOrganizationService(database: database, lifecycle: lifecycle)
    let facts = [OrganizationSortFacts(paperID: a.0, generation: a.1, lastReadAt: Date(timeIntervalSince1970: 30), publicationYear: 2025),
      OrganizationSortFacts(paperID: b.0, generation: b.1, lastReadAt: Date(timeIntervalSince1970: 10), publicationYear: 2020),
      OrganizationSortFacts(paperID: c.0, generation: UUID(), lastReadAt: Date(timeIntervalSince1970: 100), publicationYear: 9999)]
    let ties = [b.0, c.0].sorted { $0.uuidString < $1.uuidString }
    for (sort, expected) in [(LibrarySort.name, ties + [a.0]), (.recentlyAdded, ties + [a.0]),
      (.recentlyRead, [a.0, b.0, c.0]), (.publicationYear, [a.0, b.0, c.0])] {
      try await service.savePreferences(.init(sort: sort))
      let snapshot = try await service.snapshot(filter: .init(), facts: facts)
      XCTAssertEqual(snapshot.papers.map(\.id), expected)
    }
    do {
      _ = try await service.snapshot(filter: .init(), facts: [facts[0], facts[0]])
      XCTFail("Duplicate facts must not pick arbitrary owner values")
    } catch { XCTAssertEqual(error as? OrganizationError, .invalidSortFacts) }
  }
}
