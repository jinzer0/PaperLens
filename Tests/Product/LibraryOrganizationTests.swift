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
      expected: .init(), value: .init(readingStatus: .reading, favorite: true, tags: ["Résumé", "Methods"]))
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
    try database.updatePaperOrganization(paperID: a.0, generation: a.1, expected: .init(), value: value)
    try database.updatePaperOrganization(paperID: b.0, generation: b.1, expected: .init(), value: value)
    XCTAssertThrowsError(try database.updatePaperOrganization(paperID: a.0, generation: UUID(), expected: value, value: .init()))
    XCTAssertThrowsError(try database.updatePaperOrganization(paperID: a.0, generation: a.1,
      expected: value, value: .init(tags: ["Résumé", "resume"])))
    XCTAssertEqual(try database.organizationSnapshot(filter: .init()).papers.first(where: { $0.id == a.0 })?.organization, value)
    let saga = try XCTUnwrap(database.beginDeletion(a.0))
    XCTAssertThrowsError(try database.updatePaperOrganization(paperID: a.0, generation: a.1, expected: value, value: .init()))
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
    XCTAssertThrowsError(try database.updatePaperOrganization(paperID: a.0, generation: a.1, expected: .init(), value: .init(favorite: true)))
    try Data("%PDF-tampered".utf8).write(to: pdf)
    try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: pdf.path)
    XCTAssertThrowsError(try database.updatePaperOrganization(paperID: a.0, generation: a.1, expected: .init(), value: .init(favorite: true)))
    try FileManager.default.removeItem(at: pdf)
    XCTAssertFalse(try XCTUnwrap(database.organizationSnapshot(filter: .init()).papers.first).readable)
    XCTAssertThrowsError(try database.admitOrganizationOpen(paperID: a.0, generation: a.1))
  }

  func testSQLSaveFailuresRollbackAndGenerationChangeErasesTags() throws {
    let database = try ProductDatabase.open(at: root())
    let a = try seed(database, title: "A")
    let original = PaperOrganization(readingStatus: .reading, favorite: true, tags: ["Original"])
    try database.updatePaperOrganization(paperID: a.0, generation: a.1, expected: .init(), value: original)
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
      expected: original, value: .init(readingStatus: .read, tags: ["Reject"])))
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
    let facts = [OrganizationSortFacts(paperID: a.0, generation: a.1, lastReadAt: Date(timeIntervalSince1970: 30), publicationYear: 2025, metadata: nil),
      OrganizationSortFacts(paperID: b.0, generation: b.1, lastReadAt: Date(timeIntervalSince1970: 10), publicationYear: 2020, metadata: nil),
      OrganizationSortFacts(paperID: c.0, generation: UUID(), lastReadAt: Date(timeIntervalSince1970: 100), publicationYear: 9999, metadata: nil)]
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

  func testMetadataExcerptsPreserveGraphemesAndPreviewNeverChoosesConflictingCandidate() {
    let cluster = "é한한"
    XCTAssertEqual(LibraryMetadataPresentation.excerpt(cluster, limit: 1), "é…")
    XCTAssertEqual(LibraryMetadataPresentation.excerpt(cluster, limit: 2), "é한…")
    XCTAssertEqual(LibraryMetadataPresentation.excerpt(cluster, limit: 3), cluster)
    XCTAssertEqual(LibraryMetadataPresentation.preview(nil, limit: 220), "미확인")
    XCTAssertEqual(LibraryMetadataPresentation.preview(.init(), limit: 120), "미확인")
    let source = ReaderMetadataValue(text: cluster, source: .source, sourceID: "actual-source")
    let same = ReaderMetadataValue(text: cluster, source: .acceptedExtraction, sourceID: "actual-revision")
    XCTAssertEqual(LibraryMetadataPresentation.preview(.init([source, same]), limit: 1), "é…")
    let other = ReaderMetadataValue(text: "different candidate", source: .acceptedExtraction, sourceID: "other-revision")
    for candidates in [[source, other], [other, source]] {
      XCTAssertEqual(LibraryMetadataPresentation.preview(.init(candidates), limit: 220),
        "출처 간 충돌 · 상세에서 후보 확인")
    }
  }

  func testSameGenerationEditorsDuplicateAndReopenedServiceCannotOverwriteNewerFields() async throws {
    let location = try root()
    let database = try ProductDatabase.open(at: location)
    _ = try seed(database, title: "Editors")
    let lifecycle = try await LocalLibraryLifecycle.open(database: database)
    let first = LibraryOrganizationService(database: database, lifecycle: lifecycle)
    let second = LibraryOrganizationService(database: database, lifecycle: lifecycle)
    let observed = try XCTUnwrap(database.organizationSnapshot(filter: .init()).papers.first)
    let committed = PaperOrganization(readingStatus: .read, favorite: true, tags: ["Résumé", "한글"])
    try await first.save(committed, for: observed)
    // The same request is not an idempotent overwrite of intervening committed values.
    for draft in [committed, .init(readingStatus: .reading), .init(favorite: false), .init(tags: ["Other"])] {
      do { try await second.save(draft, for: observed); XCTFail("Expected stale editor rejection") }
      catch { XCTAssertEqual(error as? OrganizationError, .staleOrganization) }
    }
    let reopened = try ProductDatabase.open(at: location)
    let reopenedService = LibraryOrganizationService(database: reopened, lifecycle: lifecycle)
    do { try await reopenedService.save(.init(), for: observed); XCTFail("Restart must not reset expected values") }
    catch { XCTAssertEqual(error as? OrganizationError, .staleOrganization) }
    let current = try await reopenedService.revalidate(observed)
    XCTAssertEqual(current.organization, committed)
    try await reopenedService.save(.init(), for: current)
    XCTAssertEqual(try database.organizationSnapshot(filter: .init()).papers.first?.organization, .init())
    do { try await first.save(committed, for: current); XCTFail("Revalidated editors also become stale") }
    catch { XCTAssertEqual(error as? OrganizationError, .staleOrganization) }
  }

  func testConcurrentServicesHaveExactlyOneWholeRecordWinner() async throws {
    let database = try ProductDatabase.open(at: root())
    _ = try seed(database, title: "Concurrent")
    let lifecycle = try await LocalLibraryLifecycle.open(database: database)
    let first = LibraryOrganizationService(database: database, lifecycle: lifecycle)
    let second = LibraryOrganizationService(database: database, lifecycle: lifecycle)
    let observed = try XCTUnwrap(database.organizationSnapshot(filter: .init()).papers.first)
    let a = PaperOrganization(readingStatus: .reading, favorite: true, tags: ["First"])
    let b = PaperOrganization(readingStatus: .read, favorite: false, tags: ["Second"])
    let outcomes = await withTaskGroup(of: String.self, returning: [String].self) { group in
      for (service, value) in [(first, a), (second, b)] {
        group.addTask {
          do { try await service.save(value, for: observed); return "saved" }
          catch OrganizationError.staleOrganization { return "stale" }
          catch { return "unexpected: \(error)" }
        }
      }
      var results: [String] = []
      for await result in group { results.append(result) }
      return results.sorted()
    }
    XCTAssertEqual(outcomes, ["saved", "stale"])
    let stored = try XCTUnwrap(database.organizationSnapshot(filter: .init()).papers.first).organization
    XCTAssertTrue(stored == a || stored == b, "No mixed or lost fields")
  }

  func testStoredUnicodeSubstringANDSemanticsClearingAndPresentationOrder() async throws {
    let database = try ProductDatabase.open(at: root())
    let a = try seed(database, title: "CAFÉ 논문", createdAt: 20)
    let b = try seed(database, title: "Other", createdAt: 10)
    try database.updatePaperOrganization(paperID: a.0, generation: a.1, expected: .init(),
      value: .init(readingStatus: .reading, favorite: true, tags: ["  Résumé  ", "방법", "Two Words"]))
    try database.updatePaperOrganization(paperID: b.0, generation: b.1, expected: .init(),
      value: .init(readingStatus: .read, tags: ["Resume"]))
    var filter = OrganizationFilter()
    filter.search = "  SuMÉ\n"; filter.tag = "RÉSUMÉ"; filter.readingStatus = .reading; filter.favoritesOnly = true
    XCTAssertEqual(try database.organizationSnapshot(filter: filter).papers.map(\.id), [a.0])
    for search in ["cafe", "논문", "방법", "two words"] {
      filter.search = search
      XCTAssertEqual(try database.organizationSnapshot(filter: filter).papers.map(\.id), [a.0])
    }
    for search in ["cafe resume", "words two", "absent"] {
      filter.search = search
      XCTAssertTrue(try database.organizationSnapshot(filter: filter).papers.isEmpty)
    }
    filter.search = " \n\t"; filter.tag = "resume "
    XCTAssertTrue(try database.organizationSnapshot(filter: filter).papers.isEmpty, "Exact tag filter is not trimmed")
    filter.tag = "resume"; filter.readingStatus = .read
    XCTAssertTrue(try database.organizationSnapshot(filter: filter).papers.isEmpty, "Favorite and status combine with AND")
    filter.favoritesOnly = false
    XCTAssertEqual(try database.organizationSnapshot(filter: filter).papers.map(\.id), [b.0])
    let lifecycle = try await LocalLibraryLifecycle.open(database: database)
    let service = LibraryOrganizationService(database: database, lifecycle: lifecycle)
    filter = OrganizationFilter(); filter.search = "resume"
    try await service.savePreferences(.init(presentation: .list, sort: .recentlyAdded))
    let list = try await service.snapshot(filter: filter, facts: [])
    try await service.savePreferences(.init(presentation: .grid, sort: .recentlyAdded))
    let grid = try await service.snapshot(filter: filter, facts: [])
    XCTAssertEqual(list.papers, grid.papers)
    XCTAssertEqual(grid.papers.map(\.id), [a.0, b.0])
    let current = try XCTUnwrap(grid.papers.first)
    XCTAssertEqual(current.organization.tags, ["Résumé", "Two Words", "방법"])
    try await service.save(.init(), for: current)
    let reopened = try ProductDatabase.open(at: database.root)
    XCTAssertEqual(try reopened.organizationSnapshot(filter: filter).papers.map(\.id), [b.0])
    XCTAssertEqual(try reopened.organizationSnapshot(filter: .init()).papers.first(where: { $0.id == a.0 })?.organization, .init())
  }

  func testTagValidationAndFailedSaveKeepPriorCommittedValuesAfterRestart() async throws {
    let database = try ProductDatabase.open(at: root())
    let id = try seed(database, title: "Validation")
    let original = PaperOrganization(readingStatus: .read, favorite: true, tags: ["Keep"])
    try database.updatePaperOrganization(paperID: id.0, generation: id.1, expected: .init(), value: original)
    for tags in [[" "], ["a\tb"], [String(repeating: "é", count: 81)], ["Résumé", "résumé"],
      (0...100).map { "Tag\($0)" }] {
      XCTAssertThrowsError(try database.updatePaperOrganization(paperID: id.0, generation: id.1,
        expected: original, value: .init(tags: tags))) { error in
          XCTAssertEqual(error as? OrganizationError, .invalidTags)
        }
    }
    let lifecycle = try await LocalLibraryLifecycle.open(database: database)
    let service = LibraryOrganizationService(database: database, lifecycle: lifecycle)
    let observed = try XCTUnwrap(database.organizationSnapshot(filter: .init()).papers.first)
    // An editor's unsubmitted draft is not a persistence command; cancellation discards it.
    var draft = observed.organization; draft.favorite = false; draft.tags = ["Unsubmitted"]
    XCTAssertNotEqual(draft, original)
    try database.adapterWrite { db in
      try db.execute(sql: """
        CREATE TRIGGER rejectOrganization BEFORE UPDATE ON paperOrganization
        BEGIN SELECT RAISE(ABORT, 'fixture organization failure'); END;
        """)
    }
    do { try await service.save(draft, for: observed); XCTFail("SQL failure must not report save success") }
    catch { XCTAssertNil(error as? OrganizationError) }
    let current = try await service.revalidate(observed)
    XCTAssertEqual(current.organization, original)
    let reopened = try ProductDatabase.open(at: database.root)
    XCTAssertEqual(try reopened.organizationSnapshot(filter: .init()).papers.first?.organization, original)
    try database.adapterWrite { db in try db.execute(sql: "DROP TRIGGER rejectOrganization") }
    try await service.save(.init(readingStatus: .reading, favorite: true, tags: ["Keep"]), for: current)
    XCTAssertEqual(try reopened.organizationSnapshot(filter: .init()).papers.first?.organization.readingStatus, .reading)
  }

  func testEveryStoredFieldCombinationAndIndividualClearUsesCapturedCommittedValues() async throws {
    let database = try ProductDatabase.open(at: root())
    _ = try seed(database, title: "Combinations")
    let lifecycle = try await LocalLibraryLifecycle.open(database: database)
    let service = LibraryOrganizationService(database: database, lifecycle: lifecycle)
    for status in PaperReadingStatus.allCases {
      for favorite in [false, true] {
        for tags in [[String](), ["é", "한글"]] {
          let observed = try XCTUnwrap(database.organizationSnapshot(filter: .init()).papers.first)
          let value = PaperOrganization(readingStatus: status, favorite: favorite, tags: tags)
          try await service.save(value, for: observed)
          let reopened = try ProductDatabase.open(at: database.root)
          XCTAssertEqual(try reopened.organizationSnapshot(filter: .init()).papers.first?.organization, value)
          var filter = OrganizationFilter(); filter.readingStatus = status; filter.favoritesOnly = favorite
          filter.tag = tags.isEmpty ? nil : "e"
          XCTAssertEqual(try reopened.organizationSnapshot(filter: filter).papers.count, 1)
        }
      }
    }
    var current = try XCTUnwrap(database.organizationSnapshot(filter: .init()).papers.first)
    var value = current.organization; value.tags = []
    try await service.save(value, for: current)
    current = try await service.revalidate(current)
    XCTAssertEqual(current.organization, .init(readingStatus: .read, favorite: true))
    value = current.organization; value.favorite = false
    try await service.save(value, for: current)
    current = try await service.revalidate(current)
    XCTAssertEqual(current.organization, .init(readingStatus: .read))
    try await service.save(.init(), for: current)
    XCTAssertEqual(try database.organizationSnapshot(filter: .init()).papers.first?.organization, .init())
  }

  func testReverseActualQueriesAndFailuresOnlyPublishCurrentRevision() async throws {
    let database = try ProductDatabase.open(at: root())
    _ = try seed(database, title: "Alpha")
    _ = try seed(database, title: "Beta")
    let lifecycle = try await LocalLibraryLifecycle.open(database: database)
    let service = LibraryOrganizationService(database: database, lifecycle: lifecycle)
    let barrier = OrganizationCompletionBarrier()
    var query = OrganizationQueryState()
    let alpha: OrganizationFilter = { var value = OrganizationFilter(); value.search = "Alpha"; return value }()
    let beta: OrganizationFilter = { var value = OrganizationFilter(); value.search = "Beta"; return value }()
    let oldRequest = query.begin(filter: alpha)
    let oldTask = Task {
      let value = try await service.snapshot(filter: alpha, facts: [])
      await barrier.suspend()
      return value
    }
    await barrier.waitUntilSuspended()
    let currentRequest = query.begin(filter: beta)
    let current = try await service.snapshot(filter: beta, facts: [])
    XCTAssertTrue(query.accept(current, request: currentRequest, currentFilter: beta))
    await barrier.release()
    let old = try await oldTask.value
    XCTAssertFalse(query.accept(old, request: oldRequest, currentFilter: beta))
    query.reject(request: oldRequest, currentFilter: beta)
    XCTAssertFalse(query.failed)
    XCTAssertEqual(query.snapshot?.papers.map(\.title), ["Beta"])
    // Filter changes reject even before the next refresh task is scheduled.
    XCTAssertFalse(query.accept(old, request: currentRequest, currentFilter: alpha))
    let failureRequest = query.begin(filter: beta)
    try database.adapterWrite { db in try db.execute(sql: "DROP TABLE organizationPreferences") }
    do { _ = try await service.snapshot(filter: beta, facts: []); XCTFail("Actual query failure is not empty") }
    catch { query.reject(request: failureRequest, currentFilter: beta) }
    XCTAssertTrue(query.failed); XCTAssertFalse(query.loading)
    XCTAssertEqual(query.snapshot?.papers.map(\.title), ["Beta"], "Last committed projection survives but is not displayed as current")
  }

  func testQueryInvalidationAndSaveVersusDeletionBothOrdersNeverRestorePaper() async throws {
    let database = try ProductDatabase.open(at: root())
    let a = try seed(database, title: "Delete first"), b = try seed(database, title: "Save first")
    let lifecycle = try await LocalLibraryLifecycle.open(database: database)
    let service = LibraryOrganizationService(database: database, lifecycle: lifecycle)
    var query = OrganizationQueryState()
    let oldRequest = query.begin(filter: .init())
    let old = try await service.snapshot(filter: .init(), facts: [])
    let first = try XCTUnwrap(old.papers.first(where: { $0.id == a.0 }))
    let second = try XCTUnwrap(old.papers.first(where: { $0.id == b.0 }))
    query.invalidate() // Existing owner invalidates synchronously before deletion admission.
    let saga = try XCTUnwrap(database.beginDeletion(a.0))
    do { try await service.save(.init(favorite: true), for: first); XCTFail("Deleting Paper must reject late save") }
    catch { XCTAssertEqual(error as? OrganizationError, .unavailablePDF) }
    try database.finalizeDeletion(a.0, saga: saga)
    do { _ = try await service.revalidate(first); XCTFail("Retry must not reconstruct tombstone") }
    catch { XCTAssertEqual(error as? OrganizationError, .stalePaper) }
    XCTAssertFalse(query.accept(old, request: oldRequest, currentFilter: .init()))
    try await service.save(.init(readingStatus: .read, favorite: true, tags: ["Saved"]), for: second)
    let secondSaga = try XCTUnwrap(database.beginDeletion(b.0))
    try database.finalizeDeletion(b.0, saga: secondSaga)
    let currentRequest = query.begin(filter: .init())
    let current = try await service.snapshot(filter: .init(), facts: [])
    XCTAssertTrue(query.accept(current, request: currentRequest, currentFilter: .init()))
    XCTAssertEqual(query.snapshot?.totalCount, 0)
    XCTAssertTrue(query.snapshot?.papers.isEmpty == true)
    XCTAssertFalse(query.accept(old, request: oldRequest, currentFilter: .init()))
    let reopened = try ProductDatabase.open(at: database.root)
    XCTAssertEqual(try reopened.organizationSnapshot(filter: .init()).totalCount, 0)
    XCTAssertThrowsError(try reopened.updatePaperOrganization(paperID: b.0, generation: b.1,
      expected: second.organization, value: .init()))
  }
}

/// Holds an actual service query result to force reverse completion without timing sleeps.
private actor OrganizationCompletionBarrier {
  private var held: CheckedContinuation<Void, Never>?
  private var waiting: CheckedContinuation<Void, Never>?
  func suspend() async {
    await withCheckedContinuation { continuation in
      held = continuation
      waiting?.resume(); waiting = nil
    }
  }
  func waitUntilSuspended() async {
    if held != nil { return }
    await withCheckedContinuation { waiting = $0 }
  }
  func release() {
    held?.resume(); held = nil
  }
}
