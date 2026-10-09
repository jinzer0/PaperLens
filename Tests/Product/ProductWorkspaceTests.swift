import Darwin
import Foundation
import GRDB
import XCTest
#if SWIFT_PACKAGE
import ProviderRequest
#endif
@testable import PaperLensProduct

@MainActor private final class WorkspaceNoNetworkTransport: NativeConnectionTestTransport {
  func probe(key: String, configuration: NativeOpenAIConfiguration,
    request: AuthorizedProviderRequest, authority: ProviderRequest) async throws -> NativeProbeResponse {
    XCTFail("Workspace regressions must never send a provider request")
    throw APIKeyConnectionError.authentication
  }
}

@MainActor final class ProductWorkspaceTests: XCTestCase {
  private struct Fixture {
    let root: URL
    let source: URL
    let database: ProductDatabase
    let lifecycle: LocalLibraryLifecycle
    let connection: NativeAPIKeyConnection
    let workspace: ProductWorkspace
  }

  private func fixture() async throws -> Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    guard let physicalPath = realpath(root.path, nil) else {
      throw APIKeyConnectionError.unsafeStorage
    }
    defer { free(physicalPath) }
    let physical = URL(fileURLWithPath: String(cString: physicalPath), isDirectory: true)
    addTeardownBlock { try FileManager.default.removeItem(at: physical) }
    let source = physical.appendingPathComponent("selected-1999.pdf")
    try Data("%PDF-1.4\nsynthetic workspace fixture\n%%EOF\n".utf8).write(to: source)
    let database = try ProductDatabase.open(at: physical.appendingPathComponent("database"))
    let lifecycle = try await LocalLibraryLifecycle.open(database: database)
    let slots = try APIKeySlotStore(directory: physical.appendingPathComponent("api-key-slots"))
    let configuration = try NativeOpenAIConfiguration(model: "fixture-model")
    _ = try database.compareAndSwapProviderConfiguration(expected: database.providerConfiguration(),
      replacementSlotID: slots.create(key: "fixture-secret"), replacementModel: configuration.model)
    let connection = NativeAPIKeyConnection(configuration: configuration, slots: slots,
      persistence: DatabaseAPIKeySelector(database: database, configuration: configuration),
      transport: WorkspaceNoNetworkTransport(), authority: try ProviderRequest())
    connection.restore()
    let workspace = try ProductWorkspace(database: database, lifecycle: lifecycle, connection: connection)
    return Fixture(root: physical, source: source, database: database,
      lifecycle: lifecycle, connection: connection, workspace: workspace)
  }

  private func confirmation(_ workspace: ProductWorkspace) throws -> LocalImportConfirmation {
    guard case .confirmation(let confirmation) = workspace.sheet else {
      throw ProductWorkspaceError.busy
    }
    return confirmation
  }

  private func importSelected(_ fixture: Fixture) async throws -> UUID {
    try await fixture.workspace.prepareImport(source: fixture.source)
    let pending = try confirmation(fixture.workspace)
    let id = try await fixture.workspace.imports.continueImport(pending.id, destinationFolderID: nil)
    fixture.workspace.imported(id)
    fixture.workspace.sheet = nil
    fixture.workspace.dismissSheet()
    return id
  }

  private func paper(_ fixture: Fixture, id: UUID) async throws -> OrganizedPaper {
    let facts = try await fixture.workspace.sortFacts()
    let snapshot = try await fixture.workspace.organization.snapshot(filter: .init(), facts: facts)
    return try XCTUnwrap(snapshot.papers.first(where: { $0.id == id }))
  }

  func testStoredFilterProjectionSurvivesReaderReturnAndImportRefresh() async throws {
    let f = try await fixture()
    let selectedID = try await importSelected(f)
    let observed = try await paper(f, id: selectedID)
    try await f.workspace.organization.save(
      .init(readingStatus: .reading, favorite: true, tags: ["유지"]), for: observed)
    f.workspace.libraryFilter.favoritesOnly = true
    f.workspace.libraryFilter.readingStatus = .reading
    f.workspace.libraryFilter.tag = "유지"
    let before = try await f.workspace.organization.snapshot(
      filter: f.workspace.libraryFilter, facts: f.workspace.sortFacts())
    XCTAssertEqual(before.papers.map(\.id), [selectedID])
    try await f.workspace.open(try XCTUnwrap(before.papers.first))
    let reader = try XCTUnwrap(f.workspace.reader?.session)
    _ = try reader.open(paperID: selectedID, validateDocument: { _ in 1 }, discard: {})
    f.workspace.returnToLibrary()
    let unrelatedID = try await importSelected(f)
    XCTAssertNotEqual(unrelatedID, selectedID)
    let after = try await f.workspace.organization.snapshot(
      filter: f.workspace.libraryFilter, facts: f.workspace.sortFacts())
    XCTAssertEqual(after.totalCount, 2)
    XCTAssertEqual(after.papers.map(\.id), [selectedID])
  }

  func testActualWorkspaceImportDuplicateAndPersistedOrganizationBinding() async throws {
    let f = try await fixture()
    let folder = try await f.workspace.imports.createFolder(name: "Destination")
    let first = try await importSelected(f)
    try await f.workspace.prepareImport(source: f.source)
    let duplicate = try confirmation(f.workspace)
    XCTAssertEqual(duplicate.matchingPaperIDs, [first])
    let second = try await f.workspace.imports.continueImport(duplicate.id, destinationFolderID: folder.id)
    f.workspace.imported(second)
    f.workspace.sheet = nil; f.workspace.dismissSheet()
    XCTAssertNil(f.workspace.failure)
    XCTAssertNotEqual(first, second)
    XCTAssertEqual(try f.database.folderID(for: second), folder.id)
    do {
      _ = try await f.workspace.imports.continueImport(duplicate.id, destinationFolderID: nil)
      XCTFail("Continue must be single-use")
    } catch { XCTAssertEqual(error as? FolderImportError, .consumedIntent) }
    let selected = try await paper(f, id: second)
    try await f.workspace.organization.save(.init(readingStatus: .reading, favorite: true, tags: ["Methods"]), for: selected)
    try await f.workspace.organization.savePreferences(.init(presentation: .grid, sort: .name))
    let reopened = try ProductDatabase.open(at: f.database.root)
    var filter = OrganizationFilter(); filter.favoritesOnly = true; filter.tag = "methods"
    let snapshot = try reopened.organizationSnapshot(filter: filter)
    XCTAssertEqual(snapshot.papers.map(\.id), [second])
    XCTAssertEqual(snapshot.preferences, .init(presentation: .grid, sort: .name))
    XCTAssertEqual(snapshot.papers.first?.organization.readingStatus, .reading)
  }

  func testCancelAndChangedSourceNeverReservePaperOrJob() async throws {
    let f = try await fixture()
    try await f.workspace.prepareImport(source: f.source)
    let cancelled = try confirmation(f.workspace)
    do {
      try await f.workspace.prepareImport(source: f.source)
      XCTFail("An outstanding confirmation must not be replaced")
    } catch { XCTAssertTrue(error is ProductWorkspaceError) }
    await f.workspace.imports.cancel(cancelled.id)
    f.workspace.sheet = nil; f.workspace.dismissSheet()
    do {
      _ = try await f.workspace.imports.continueImport(cancelled.id, destinationFolderID: nil)
      XCTFail("Cancelled confirmation must not import")
    } catch { XCTAssertEqual(error as? FolderImportError, .consumedIntent) }
    try await f.workspace.prepareImport(source: f.source)
    let changed = try confirmation(f.workspace)
    try Data("%PDF-1.4\nchanged after confirmation\n%%EOF\n".utf8).write(to: f.source)
    do {
      _ = try await f.workspace.imports.continueImport(changed.id, destinationFolderID: nil)
      XCTFail("Changed source must require another confirmation")
    } catch { XCTAssertEqual(error as? FolderImportError, .sourceChanged) }
    f.workspace.sheet = nil; f.workspace.dismissSheet()
    XCTAssertTrue(try f.database.libraryRecords().isEmpty)
    XCTAssertEqual(try f.database.adapterRead { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM importJob") }, 0)
    XCTAssertFalse(FileManager.default.fileExists(atPath: f.database.root.appendingPathComponent("papers").path))
    try Data("not a PDF".utf8).write(to: f.source)
    do {
      try await f.workspace.prepareImport(source: f.source)
      XCTFail("Invalid input must not mount a confirmation")
    } catch {}
    XCTAssertNil(f.workspace.sheet)
    XCTAssertFalse(f.workspace.preparing)
    XCTAssertTrue(try f.database.libraryRecords().isEmpty)
  }

  func testReaderReturnDiscardsLeaseAndRestoresGuardedPositionFromSameDatabase() async throws {
    let f = try await fixture()
    let id = try await importSelected(f)
    let selected = try await paper(f, id: id)
    try await f.workspace.open(selected)
    let session = try XCTUnwrap(f.workspace.reader?.session)
    var discarded = false
    _ = try session.open(paperID: id, validateDocument: { url in
      XCTAssertEqual(try Data(contentsOf: url), try Data(contentsOf: f.source))
      return 4
    }, discard: { discarded = true })
    try session.leave(at: .init(pageIndex: 2, zoom: 1.5))
    f.workspace.returnToLibrary()
    XCTAssertTrue(discarded)
    XCTAssertNil(session.currentPaper)
    XCTAssertNil(f.workspace.reader)
    XCTAssertThrowsError(try session.withReadAccess { XCTFail("No background Reader access after return") })
    let fact = try XCTUnwrap(f.database.librarySortFacts().first(where: { $0.paperID == id }))
    XCTAssertNotNil(fact.lastReadAt)
    XCTAssertNil(fact.publicationYear) // A filename is not metadata.
    try await f.workspace.open(selected)
    let restored = try XCTUnwrap(f.workspace.reader?.session)
    XCTAssertEqual(try restored.open(paperID: id, validateDocument: { _ in 4 }, discard: {}),
      .init(pageIndex: 2, zoom: 1.5))
    f.workspace.returnToLibrary()
  }

  func testSelectedGenerationCannotChangeBetweenListAdmissionAndReaderAcquisition() async throws {
    let f = try await fixture()
    let id = try await importSelected(f)
    let selected = try await paper(f, id: id)
    try await f.workspace.open(selected)
    let session = try XCTUnwrap(f.workspace.reader?.session)
    try f.database.adapterWrite { db in
      try db.execute(sql: "UPDATE paper SET generation = ? WHERE id = ?", arguments: [UUID().uuidString, id.uuidString])
    }
    XCTAssertThrowsError(try session.open(paperID: id, validateDocument: { _ in
      XCTFail("The replacement must not be read under the old selection")
      return 4
    }, discard: {})) { XCTAssertEqual($0 as? ReaderError, .revoked) }
    XCTAssertNil(session.currentPaper)
    f.workspace.returnToLibrary()
  }

  func testRealLifecycleRevocationDiscardsBeforeMissingAgentDeletionFailure() async throws {
    let f = try await fixture()
    let id = try await importSelected(f)
    let selected = try await paper(f, id: id)
    try await f.workspace.open(selected)
    let session = try XCTUnwrap(f.workspace.reader?.session)
    var discarded = false
    _ = try session.open(paperID: id, validateDocument: { _ in 4 }, discard: { discarded = true })
    do {
      try await f.lifecycle.delete(paperID: id)
      XCTFail("No Agent producer has been bound")
    } catch { XCTAssertEqual(error as? LocalLibraryError, .agentPurgeUnavailable) }
    XCTAssertTrue(discarded)
    XCTAssertNil(session.currentPaper)
    XCTAssertThrowsError(try session.save(.init(pageIndex: 1, zoom: 1)))
    XCTAssertThrowsError(try session.withReadAccess { XCTFail("Revoked content must not be used") })
    XCTAssertEqual(try f.database.libraryRecords().first?.status, .deletionFailed)
    f.workspace.returnToLibrary()
  }

  func testGuardedSaveFailureIsVisibleAndDoesNotAcceptLastReadTimestamp() async throws {
    let f = try await fixture()
    let id = try await importSelected(f)
    let selected = try await paper(f, id: id)
    try await f.workspace.open(selected)
    let session = try XCTUnwrap(f.workspace.reader?.session)
    _ = try session.open(paperID: id, validateDocument: { _ in 4 }, discard: {})
    try f.database.adapterWrite { db in
      try db.execute(sql: """
        CREATE TRIGGER rejectWorkspaceSave BEFORE UPDATE OF lastReadPage ON paper
        WHEN NEW.lastReadPage IS NOT NULL BEGIN SELECT RAISE(ABORT, 'synthetic storage failure'); END;
        """)
    }
    do {
      try session.leave(at: .init(pageIndex: 1, zoom: 1))
      XCTFail("Failed save must not return as success")
    } catch { f.workspace.reportSaveFailure(error) }
    XCTAssertNotNil(f.workspace.failure)
    XCTAssertNotNil(f.workspace.reader)
    XCTAssertNotNil(session.currentPaper)
    XCTAssertNil(try f.database.librarySortFacts().first?.lastReadAt)
    f.workspace.returnToLibrary()
    XCTAssertNil(session.currentPaper)
  }

  func testSettingsUsesSameNativeOwnerAndRejectsRetirementWhileLeased() async throws {
    let f = try await fixture()
    f.workspace.settings.restore()
    XCTAssertEqual(f.workspace.settings.activeSelection, f.connection.activeSelection)
    let lease = try f.workspace.settings.acquireLease()
    XCTAssertFalse(f.connection.canReplaceOwner)
    XCTAssertThrowsError(try f.connection.retireAfterDrain())
    XCTAssertTrue(try f.connection.mayPublish(lease))
    try f.workspace.settings.releaseAfterTermination(lease)
    XCTAssertTrue(f.connection.canReplaceOwner)
    f.workspace.sheet = .settings
    f.workspace.sheet = nil; f.workspace.dismissSheet()
    XCTAssertEqual(f.workspace.settings.activeSelection, f.connection.activeSelection)
  }

  func testRootOwnsWorkspaceOnlyAfterExplicitContinueAndCannotAbandonItsNativeOwner() async throws {
    let f = try await fixture()
    let composition = ProductAppComposition(root: f.root, transport: WorkspaceNoNetworkTransport())
    await composition.start()
    guard case .connection(let connection) = composition.phase else {
      return XCTFail("Local restore must still require explicit Continue")
    }
    XCTAssertNil(composition.workspace)
    try composition.continueToLibrary()
    let retained = try XCTUnwrap(composition.workspace)
    XCTAssertEqual(retained.settings.activeSelection, connection.activeSelection)
    let lease = try retained.settings.acquireLease()
    composition.changeModel()
    XCTAssertThrowsError(try composition.configure(model: "other-fixture-model"))
    guard case .library = composition.phase else {
      return XCTFail("Settings and Reader owners must not be abandoned by root state changes")
    }
    XCTAssertTrue(composition.workspace === retained)
    XCTAssertTrue(try connection.mayPublish(lease))
    try retained.settings.releaseAfterTermination(lease)
    XCTAssertThrowsError(try composition.configure(model: "other-fixture-model"))
    XCTAssertTrue(composition.workspace === retained)
  }

  func testYearFactsOnlyUseCurrentRevisionWithNoConflictPrecedence() async throws {
    let f = try await fixture()
    let id = try await importSelected(f)
    let selected = try await paper(f, id: id)
    let digest = try XCTUnwrap(f.database.adapterRead { db in
      try String.fetchOne(db, sql: "SELECT pdfSHA256 FROM paper WHERE id = ?", arguments: [id.uuidString])
    })
    let identity = ReaderMetadataIdentity(paperID: id, generation: selected.generation,
      pdfSHA256: digest, pdfReference: "papers/\(id.uuidString)/document.pdf", revisionID: UUID())
    try f.database.adapterWrite { db in
      try db.execute(sql: """
        INSERT INTO extractionRevision(id, paperID, generation, pdfSHA256, pdfReference) VALUES (?, ?, ?, ?, ?)
        """, arguments: [identity.revisionID.uuidString, id.uuidString, identity.generation.uuidString,
          digest, identity.pdfReference])
      try db.execute(sql: "INSERT INTO extractionVisible(paperID, revision) VALUES (?, ?)",
        arguments: [id.uuidString, identity.revisionID.uuidString])
    }
    let source = ReaderMetadataValue(text: "2024", source: .source, sourceID: "actual-source")
    let accepted = ReaderMetadataValue(text: "2024", source: .acceptedExtraction, sourceID: identity.revisionID.uuidString)
    try f.database.saveReaderMetadata(.init(year: .init([source, accepted])), for: identity)
    XCTAssertEqual(try f.database.librarySortFacts().first?.publicationYear, 2024)
    let conflict = ReaderMetadataValue(text: "2023", source: .acceptedExtraction, sourceID: identity.revisionID.uuidString)
    try f.database.saveReaderMetadata(.init(year: .init([source, conflict])), for: identity)
    XCTAssertNil(try f.database.librarySortFacts().first?.publicationYear)
    try f.database.saveReaderMetadata(.init(year: .init([accepted])), for: identity)
    let reopened = try ProductDatabase.open(at: f.database.root)
    XCTAssertEqual(try reopened.librarySortFacts().first?.generation, selected.generation)
    XCTAssertEqual(try reopened.librarySortFacts().first?.publicationYear, 2024)
    try f.database.adapterWrite { db in
      try db.execute(sql: "DELETE FROM extractionVisible WHERE paperID = ?", arguments: [id.uuidString])
    }
    XCTAssertNil(try reopened.librarySortFacts().first?.publicationYear)
    try f.database.adapterWrite { db in
      try db.execute(sql: "UPDATE paper SET generation = ? WHERE id = ?", arguments: [UUID().uuidString, id.uuidString])
    }
    let replaced = try XCTUnwrap(reopened.librarySortFacts().first)
    XCTAssertNotEqual(replaced.generation, selected.generation)
    XCTAssertNil(replaced.publicationYear)
    XCTAssertNil(replaced.lastReadAt)
  }
}
