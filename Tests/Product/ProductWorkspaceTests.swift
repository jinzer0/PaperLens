import Darwin
import Combine
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

  private func openOwnedReader(_ f: Fixture, id: UUID,
    discard: @escaping @MainActor () -> Void = {}) async throws -> ProductWorkspace.OpenReader {
    try await f.workspace.open(paper(f, id: id))
    let reader = try XCTUnwrap(f.workspace.reader)
    _ = try reader.session.open(paperID: id, validateDocument: { url in
      XCTAssertEqual(try Data(contentsOf: url), try Data(contentsOf: f.source))
      return 4
    }, discard: discard)
    return reader
  }

  private func readToken(_ f: Fixture, id: UUID) throws -> String {
    try XCTUnwrap(f.database.adapterRead {
      try String.fetchOne($0, sql: "SELECT readerSession FROM paper WHERE id = ?",
        arguments: [id.uuidString])
    })
  }

  private func publishMetadataRevision(_ f: Fixture, id: UUID) throws -> ReaderMetadataIdentity {
    let paper = try f.database.annotationIdentity(paperID: id)
    let reference = try f.database.readerSnapshot(paperID: id).pdfReference
    let extraction = ExtractionIdentity(paperID: id, generation: paper.generation,
      pdfSHA256: paper.pdfSHA256, pdfReference: reference, revision: UUID(), job: UUID(),
      attempt: UUID(), fence: UUID(), correlation: UUID(), input: UUID(), epoch: f.lifecycle.epoch,
      configuration: try f.database.providerConfiguration())
    // Canonical synthetic contract fixture only, not native geometry calibration.
    let text = "Published workspace fixture sentence."
    let key = ExtractionSentenceIdentity(paperID: id, pdfSHA256: paper.pdfSHA256,
      revision: extraction.revision, page: 0, sentenceID: 0)
    let page = try PDFPageGeometry(pageIndex: 0, cropOrigin: PDFPoint(x: 0, y: 0),
      width: 100, height: 100, rotation: 0)
    let quad = try PDFQuad(topLeft: PDFPoint(x: 10, y: 90), topRight: PDFPoint(x: 90, y: 90),
      bottomRight: PDFPoint(x: 90, y: 80), bottomLeft: PDFPoint(x: 10, y: 80), page: page)
    let anchor = try PDFSentenceAnchor(identity: PDFSentenceIdentity(paperID: id,
      pdfSHA256: paper.pdfSHA256, extractionRevision: extraction.revision.uuidString.lowercased(),
      pageIndex: 0, sentenceID: 0), fullSourceQuote: text, page: page, quads: [quad])
    let validator = try CanonicalExtractionGeometryValidator(owningAnchors: [anchor],
      precision: PDFGeometryPrecision(maximumErrorPDFPoints: 0))
    let batch = ExtractionBatch(identity: extraction, sequence: 0, sentences: [
      .init(identity: key, text: text, geometry: CanonicalExtractionGeometryInput(anchor: anchor)),
    ], complete: true, totalSentences: 1)
    try f.database.reserveExtraction(extraction)
    let scope = fixtureExtractionScope()
    let rows = try ExtractionRevisionService.validate([batch], identity: extraction,
      validator: validator, scope: scope)
    try f.database.publishExtraction(extraction, sentences: rows, checkBudget: { try scope.checkBudget() })
    return try XCTUnwrap(f.database.publishedMetadataPaperIdentity(paperID: id))
  }

  func testFirstNilAndErrorOutcomesReconcileOpenTimeMetadata() async throws {
    for queryFailure in [false, true] {
      let f = try await fixture()
      let id = try await importSelected(f)
      let published = try publishMetadataRevision(f, id: id)
      let observed = try await openOwnedReader(f, id: id)
      XCTAssertEqual(observed.metadataIdentity, published)
      let token = try readToken(f, id: id)
      try f.database.adapterWrite {
        if queryFailure { try $0.execute(sql: "DROP TABLE extractionVisible") }
        else {
          try $0.execute(sql: "DELETE FROM extractionVisible WHERE paperID = ?", arguments: [id.uuidString])
        }
      }
      var reconciliation = ParsingMetadataReconciliation()
      let outcome: ParsingMetadataReconciliation.Outcome = queryFailure ? .unavailable : .revision(nil)
      XCTAssertTrue(reconciliation.observe(outcome), "First nil/error must reconcile open-time identity")
      let completed = await f.workspace.refreshPublishedMetadata(for: observed)
      reconciliation.resolve(outcome, completed: completed)
      XCTAssertTrue(completed)
      XCTAssertFalse(reconciliation.observe(outcome), "Resolved identical outcome is change-based")
      XCTAssertNil(f.workspace.reader?.metadataIdentity)
      XCTAssertEqual(f.workspace.failure != nil, queryFailure)
      XCTAssertTrue(f.workspace.reader?.session === observed.session)
      XCTAssertEqual(try readToken(f, id: id), token)
      XCTAssertNoThrow(try observed.session.withReadAccess {})
      f.workspace.returnToLibrary()
    }
  }

  func testOldActualQueryFailureCannotClearNewerHealthyRequestOnSameAdmission() async throws {
    let f = try await fixture()
    let id = try await importSelected(f)
    let observed = try await openOwnedReader(f, id: id)
    let published = try publishMetadataRevision(f, id: id)
    let token = try readToken(f, id: id)
    // Reversible owned-schema fault preserves actual publication rows and triggers.
    try f.database.adapterWrite {
      try $0.execute(sql: "ALTER TABLE extractionVisible RENAME TO suspendedExtractionVisible")
    }
    let oldOutcome = await f.workspace.readPublishedMetadataOutcome(for: observed)
    guard case .failure(let failed) = oldOutcome else { return XCTFail("Actual query must fail") }
    try f.database.adapterWrite {
      try $0.execute(sql: "ALTER TABLE suspendedExtractionVisible RENAME TO extractionVisible")
    }
    let healthy = try await f.workspace.readPublishedMetadata(for: observed)
    XCTAssertNotEqual(failed.request, healthy.request)
    XCTAssertTrue(try f.workspace.applyPublishedMetadata(healthy))
    XCTAssertEqual(f.workspace.reader?.metadataIdentity, published)
    XCTAssertFalse(f.workspace.applyPublishedMetadataFailure(failed))
    XCTAssertEqual(f.workspace.reader?.metadataIdentity, published)
    XCTAssertNil(f.workspace.failure)
    XCTAssertTrue(f.workspace.reader?.session === observed.session)
    XCTAssertEqual(try readToken(f, id: id), token)
    XCTAssertNoThrow(try observed.session.withReadAccess {})
    f.workspace.returnToLibrary()
  }

  func testOldSuccessCannotReconcilePointerOrCloseReaderAfterNewerRequest() async throws {
    let f = try await fixture()
    let id = try await importSelected(f)
    let observed = try await openOwnedReader(f, id: id)
    let first = try publishMetadataRevision(f, id: id)
    let old = try await f.workspace.readPublishedMetadata(for: observed)
    let latest = try await f.workspace.readPublishedMetadata(for: observed)
    XCTAssertTrue(try f.workspace.applyPublishedMetadata(latest))
    let next = try publishMetadataRevision(f, id: id)
    XCTAssertFalse(try f.workspace.applyPublishedMetadata(old))
    XCTAssertEqual(f.workspace.reader?.metadataIdentity, first)
    XCTAssertNil(f.workspace.failure)
    XCTAssertNoThrow(try observed.session.withReadAccess {})
    XCTAssertTrue(try f.workspace.applyPublishedMetadata(latest))
    XCTAssertEqual(f.workspace.reader?.metadataIdentity, next)
    try f.database.adapterWrite {
      try $0.execute(sql: "UPDATE paper SET generation = ? WHERE id = ?", arguments: [UUID().uuidString, id.uuidString])
    }
    XCTAssertFalse(try f.workspace.applyPublishedMetadata(old))
    XCTAssertNotNil(observed.session.currentPaper, "Stale request cannot invoke ownership cleanup")
    await f.workspace.refreshPublishedMetadata(for: observed)
    XCTAssertNil(f.workspace.reader)
    XCTAssertNil(observed.session.currentPaper)
  }

  func testOldActualQueryFailureDefersSameObjectReplacementAdmission() async throws {
    let f = try await fixture()
    let id = try await importSelected(f)
    let observed = try await openOwnedReader(f, id: id)
    let published = try publishMetadataRevision(f, id: id)
    await f.workspace.refreshPublishedMetadata(for: observed)
    let oldToken = try readToken(f, id: id)
    try f.database.adapterWrite { try $0.execute(sql: "DROP TABLE extractionVisible") }
    let outcome = await f.workspace.readPublishedMetadataOutcome(for: observed)
    guard case .failure(let failed) = outcome else { return XCTFail("Real GRDB query must fail") }
    observed.session.close()
    _ = try observed.session.open(paperID: id, validateDocument: { url in
      XCTAssertEqual(try Data(contentsOf: url), try Data(contentsOf: f.source))
      return 4
    }, discard: {})
    let newToken = try readToken(f, id: id)
    XCTAssertNotEqual(oldToken, newToken)
    var reconciliation = ParsingMetadataReconciliation()
    XCTAssertTrue(reconciliation.observe(.unavailable))
    let completed = f.workspace.applyPublishedMetadataFailure(failed)
    reconciliation.resolve(.unavailable, completed: completed)
    XCTAssertFalse(completed)
    XCTAssertTrue(reconciliation.observe(.unavailable))
    XCTAssertEqual(f.workspace.reader?.metadataIdentity, published)
    XCTAssertNil(f.workspace.failure)
    XCTAssertEqual(try readToken(f, id: id), newToken)
    let next = await f.workspace.refreshPublishedMetadata(for: observed)
    XCTAssertTrue(next)
    XCTAssertNil(f.workspace.reader?.metadataIdentity)
    XCTAssertNotNil(f.workspace.failure)
    XCTAssertNoThrow(try observed.session.withReadAccess {})
    f.workspace.returnToLibrary()
  }

  func testActualSessionMountKeyStableForMetadataAndDifferentForReopen() async throws {
    let f = try await fixture()
    let id = try await importSelected(f)
    let original = try await openOwnedReader(f, id: id)
    let mount = original.mountIdentity
    _ = try publishMetadataRevision(f, id: id)
    await f.workspace.refreshPublishedMetadata(for: original)
    XCTAssertEqual(f.workspace.reader?.mountIdentity, mount)
    _ = try publishMetadataRevision(f, id: id)
    await f.workspace.refreshPublishedMetadata(for: original)
    XCTAssertEqual(f.workspace.reader?.mountIdentity, mount)
    f.workspace.returnToLibrary()
    let reopened = try await openOwnedReader(f, id: id)
    XCTAssertEqual(reopened.annotationIdentity, original.annotationIdentity)
    XCTAssertNotEqual(reopened.mountIdentity, mount)
    XCTAssertNoThrow(try reopened.session.withReadAccess {})
    f.workspace.returnToLibrary()
  }

  func testOverlappingActualPollReadsCannotResolveNewerPendingIntent() async throws {
    let f = try await fixture()
    let id = try await importSelected(f)
    try await f.workspace.open(paper(f, id: id))
    let observed = try XCTUnwrap(f.workspace.reader)
    var reconciliation = ParsingMetadataReconciliation()
    let oldRequest = reconciliation.beginRequest()
    let database = f.database
    let oldStatus = try await Task.detached { try database.extractionStatus(paperID: id) }.value
    let oldOutcome = ParsingMetadataReconciliation.Outcome.revision(oldStatus.usableRevision)
    XCTAssertTrue(reconciliation.observe(oldOutcome, request: oldRequest))
    let newRequest = reconciliation.beginRequest()
    let newStatus = try await Task.detached { try database.extractionStatus(paperID: id) }.value
    let newOutcome = ParsingMetadataReconciliation.Outcome.revision(newStatus.usableRevision)
    XCTAssertFalse(reconciliation.isCurrent(oldRequest), "Old post-read/context result cannot publish")
    XCTAssertFalse(reconciliation.observe(oldOutcome, request: oldRequest))
    XCTAssertTrue(reconciliation.observe(newOutcome, request: newRequest))
    let deferred = await f.workspace.refreshPublishedMetadata(for: observed)
    XCTAssertFalse(deferred)
    reconciliation.resolve(newOutcome, completed: deferred, request: newRequest)
    // Real old callback is dismissed after its mount closes, but cannot clear new intent.
    f.workspace.returnToLibrary()
    let dismissed = await f.workspace.refreshPublishedMetadata(for: observed)
    XCTAssertTrue(dismissed)
    reconciliation.resolve(oldOutcome, completed: dismissed, request: oldRequest)
    XCTAssertTrue(reconciliation.observe(newOutcome, request: newRequest))
  }

  func testPendingAdmissionRetainsPollIntentUntilRealOpen() async throws {
    let f = try await fixture()
    let id = try await importSelected(f)
    try await f.workspace.open(paper(f, id: id))
    let observed = try XCTUnwrap(f.workspace.reader)
    let published = try publishMetadataRevision(f, id: id)
    var reconciliation = ParsingMetadataReconciliation()
    let outcome = ParsingMetadataReconciliation.Outcome.revision(published.revisionID)
    XCTAssertTrue(reconciliation.observe(outcome))
    let deferred = await f.workspace.refreshPublishedMetadata(for: observed)
    reconciliation.resolve(outcome, completed: deferred)
    XCTAssertFalse(deferred)
    XCTAssertTrue(f.workspace.reader?.session === observed.session)
    XCTAssertNil(f.workspace.failure)
    XCTAssertNil(try f.database.adapterRead {
      try String.fetchOne($0, sql: "SELECT readerSession FROM paper WHERE id = ?", arguments: [id.uuidString])
    })
    var opens = 0
    _ = try observed.session.open(paperID: id, validateDocument: { url in
      opens += 1
      XCTAssertEqual(try Data(contentsOf: url), try Data(contentsOf: f.source))
      return 4
    }, discard: {})
    let token = try readToken(f, id: id)
    XCTAssertEqual(observed.session.admissionState, .admitted(try XCTUnwrap(UUID(uuidString: token))))
    XCTAssertTrue(reconciliation.observe(outcome), "Unchanged deferred outcome must retry")
    let completed = await f.workspace.refreshPublishedMetadata(for: observed)
    reconciliation.resolve(outcome, completed: completed)
    XCTAssertTrue(completed)
    XCTAssertFalse(reconciliation.observe(outcome))
    XCTAssertEqual(f.workspace.reader?.metadataIdentity, published)
    XCTAssertEqual(opens, 1)
    XCTAssertEqual(try readToken(f, id: id), token)
    XCTAssertNoThrow(try observed.session.withReadAccess {})
    f.workspace.returnToLibrary()
  }

  func testPreLeaseAdmissionFailureIsClosedRatherThanDeferredForever() async throws {
    let f = try await fixture()
    let id = try await importSelected(f)
    let unbound = ReaderSession(database: f.database)
    XCTAssertThrowsError(try unbound.open(paperID: id,
      validateDocument: { _ in XCTFail("Missing lease provider must not read"); return 4 }, discard: {}))
    XCTAssertEqual(unbound.admissionState, .closed)
    try await f.workspace.open(paper(f, id: id))
    let observed = try XCTUnwrap(f.workspace.reader)
    try f.database.adapterWrite {
      try $0.execute(sql: "UPDATE paper SET status = 'deleting' WHERE id = ?", arguments: [id.uuidString])
    }
    XCTAssertThrowsError(try observed.session.open(paperID: id,
      validateDocument: { _ in XCTFail("Rejected ready snapshot must not read"); return 4 }, discard: {}))
    XCTAssertEqual(observed.session.admissionState, .closed)
    let completed = await f.workspace.refreshPublishedMetadata(for: observed)
    XCTAssertTrue(completed)
    XCTAssertNil(f.workspace.reader)
    XCTAssertNotNil(f.workspace.failure)
  }

  func testSameSessionObjectReopenFencesActualAdmissionID() async throws {
    let f = try await fixture()
    let id = try await importSelected(f)
    let observed = try await openOwnedReader(f, id: id)
    let published = try publishMetadataRevision(f, id: id)
    let pending = try await f.workspace.readPublishedMetadata(for: observed)
    XCTAssertEqual(pending.identity, published)
    let oldToken = try readToken(f, id: id)
    observed.session.close()
    XCTAssertEqual(observed.session.admissionState, .closed)
    _ = try observed.session.open(paperID: id, validateDocument: { url in
      XCTAssertEqual(try Data(contentsOf: url), try Data(contentsOf: f.source))
      return 4
    }, discard: {})
    let newToken = try readToken(f, id: id)
    XCTAssertNotEqual(oldToken, newToken)
    try f.workspace.applyPublishedMetadata(pending)
    XCTAssertNil(f.workspace.reader?.metadataIdentity, "Same object cannot accept an old admission result")
    XCTAssertTrue(f.workspace.reader?.session === observed.session)
    XCTAssertEqual(try readToken(f, id: id), newToken)
    await f.workspace.refreshPublishedMetadata(for: observed)
    XCTAssertEqual(f.workspace.reader?.metadataIdentity, published)
    XCTAssertNoThrow(try observed.session.withReadAccess {})
    f.workspace.returnToLibrary()
  }

  func testLivePublicationReplacementAndRemovalKeepOriginalReaderOwnership() async throws {
    let f = try await fixture()
    let id = try await importSelected(f)
    var discards = 0
    let original = try await openOwnedReader(f, id: id, discard: { discards += 1 })
    XCTAssertNil(original.metadataIdentity)
    let token = try readToken(f, id: id)
    try original.session.save(.init(pageIndex: 2, zoom: 1.5))
    let first = try publishMetadataRevision(f, id: id)
    await f.workspace.refreshPublishedMetadata(for: original)
    XCTAssertEqual(f.workspace.reader?.metadataIdentity, first)
    let second = try publishMetadataRevision(f, id: id)
    XCTAssertNotEqual(first.revisionID, second.revisionID)
    await f.workspace.refreshPublishedMetadata(for: original)
    XCTAssertEqual(f.workspace.reader?.metadataIdentity, second)
    XCTAssertTrue(f.workspace.reader?.session === original.session)
    XCTAssertEqual(f.workspace.reader?.annotationIdentity, original.annotationIdentity)
    XCTAssertEqual(try readToken(f, id: id), token)
    XCTAssertEqual(original.session.restoredPosition, .init(pageIndex: 2, zoom: 1.5))
    XCTAssertEqual(try original.session.withReadAccess { try Data(contentsOf:
      f.database.root.appendingPathComponent(try XCTUnwrap(original.session.currentPaper).pdfReference)) },
      try Data(contentsOf: f.source))
    XCTAssertEqual(discards, 0)
    var changes = 0
    let observation = f.workspace.objectWillChange.sink { changes += 1 }
    await f.workspace.refreshPublishedMetadata(for: original)
    XCTAssertEqual(changes, 0, "Identical publication must not replace OpenReader")
    withExtendedLifetime(observation) {}
    try f.database.adapterWrite {
      try $0.execute(sql: "DELETE FROM extractionVisible WHERE paperID = ?", arguments: [id.uuidString])
    }
    await f.workspace.refreshPublishedMetadata(for: original)
    XCTAssertNil(f.workspace.reader?.metadataIdentity)
    XCTAssertTrue(f.workspace.reader?.session === original.session)
    XCTAssertEqual(try readToken(f, id: id), token)
    XCTAssertEqual(discards, 0)
    XCTAssertNoThrow(try original.session.withReadAccess {})
    f.workspace.returnToLibrary()
    XCTAssertEqual(discards, 1)
  }

  func testActualReadCompletionAndOldCallbackCannotRetargetSamePaperReopen() async throws {
    let f = try await fixture()
    let id = try await importSelected(f)
    let old = try await openOwnedReader(f, id: id)
    let published = try publishMetadataRevision(f, id: id)
    let pending = try await f.workspace.readPublishedMetadata(for: old)
    XCTAssertEqual(pending.identity, published)
    let oldToken = try readToken(f, id: id)
    f.workspace.returnToLibrary()
    let reopened = try await openOwnedReader(f, id: id)
    let newToken = try readToken(f, id: id)
    XCTAssertNotEqual(oldToken, newToken)
    XCTAssertEqual(old.annotationIdentity, reopened.annotationIdentity)
    let next = try publishMetadataRevision(f, id: id)
    try f.workspace.applyPublishedMetadata(pending)
    await f.workspace.refreshPublishedMetadata(for: old)
    XCTAssertEqual(f.workspace.reader?.metadataIdentity, published)
    XCTAssertTrue(f.workspace.reader?.session === reopened.session)
    XCTAssertEqual(try readToken(f, id: id), newToken)
    XCTAssertThrowsError(try old.session.withReadAccess { XCTFail("Old Reader is closed") })
    await f.workspace.refreshPublishedMetadata(for: reopened)
    XCTAssertEqual(f.workspace.reader?.metadataIdentity, next)
    XCTAssertNoThrow(try reopened.session.withReadAccess {})
    f.workspace.returnToLibrary()
  }

  func testCapturedReadRechecksPublicationAndCancellationBeforeAdvertising() async throws {
    let f = try await fixture()
    let id = try await importSelected(f)
    let observed = try await openOwnedReader(f, id: id)
    let first = try publishMetadataRevision(f, id: id)
    let pending = try await f.workspace.readPublishedMetadata(for: observed)
    XCTAssertEqual(pending.identity, first)
    let next = try publishMetadataRevision(f, id: id)
    let cancelled = Task { @MainActor in
      withUnsafeCurrentTask { $0?.cancel() }
      try f.workspace.applyPublishedMetadata(pending)
      await f.workspace.refreshPublishedMetadata(for: observed)
    }
    try await cancelled.value
    XCTAssertNil(f.workspace.reader?.metadataIdentity)
    try f.workspace.applyPublishedMetadata(pending)
    XCTAssertEqual(f.workspace.reader?.metadataIdentity, next,
      "A delayed real read cannot advertise a superseded pointer")
    let removed = try await f.workspace.readPublishedMetadata(for: observed)
    try f.database.adapterWrite {
      try $0.execute(sql: "DELETE FROM extractionVisible WHERE paperID = ?", arguments: [id.uuidString])
    }
    try f.workspace.applyPublishedMetadata(removed)
    XCTAssertNil(f.workspace.reader?.metadataIdentity)
    XCTAssertTrue(f.workspace.reader?.session === observed.session)
    XCTAssertNoThrow(try observed.session.withReadAccess {})
    f.workspace.returnToLibrary()
  }

  func testActualGRDBQueryFailureClearsAdvertisementWithoutInventingRevision() async throws {
    let f = try await fixture()
    let id = try await importSelected(f)
    let observed = try await openOwnedReader(f, id: id)
    let published = try publishMetadataRevision(f, id: id)
    await f.workspace.refreshPublishedMetadata(for: observed)
    XCTAssertEqual(f.workspace.reader?.metadataIdentity, published)
    let token = try readToken(f, id: id)
    // Owned temporary database fault, not a fake successful identity/fetch callback.
    try f.database.adapterWrite { try $0.execute(sql: "DROP TABLE extractionVisible") }
    await f.workspace.refreshPublishedMetadata(for: observed)
    XCTAssertNil(f.workspace.reader?.metadataIdentity)
    XCTAssertNotNil(f.workspace.failure)
    XCTAssertTrue(f.workspace.reader?.session === observed.session)
    XCTAssertEqual(try readToken(f, id: id), token)
    XCTAssertNoThrow(try observed.session.withReadAccess {})
    f.workspace.returnToLibrary()
  }

  func testClosedAndLifecycleRevokedReadersCannotAdvertisePublication() async throws {
    for delete in [false, true] {
      let f = try await fixture()
      let id = try await importSelected(f)
      let observed = try await openOwnedReader(f, id: id)
      _ = try publishMetadataRevision(f, id: id)
      if delete {
        do {
          try await f.lifecycle.delete(paperID: id)
          XCTFail("Unbound Agent deletion must remain incomplete")
        } catch { XCTAssertEqual(error as? LocalLibraryError, .agentPurgeUnavailable) }
      } else { observed.session.close() }
      await f.workspace.refreshPublishedMetadata(for: observed)
      XCTAssertNil(f.workspace.reader)
      XCTAssertNotNil(f.workspace.failure)
      XCTAssertNil(observed.session.currentPaper)
      XCTAssertThrowsError(try observed.session.withReadAccess { XCTFail("Lost ownership cannot read") })
    }
  }

  func testChangedHashOrGenerationCannotAdvertiseNewMetadata() async throws {
    for column in ["pdfSHA256", "generation"] {
      let f = try await fixture()
      let id = try await importSelected(f)
      let observed = try await openOwnedReader(f, id: id)
      let original = try publishMetadataRevision(f, id: id)
      await f.workspace.refreshPublishedMetadata(for: observed)
      XCTAssertEqual(f.workspace.reader?.metadataIdentity, original)
      try f.database.adapterWrite {
        try $0.execute(sql: "UPDATE paper SET \(column) = ? WHERE id = ?",
          arguments: [column == "generation" ? UUID().uuidString : String(repeating: "b", count: 64), id.uuidString])
      }
      let replacement = try publishMetadataRevision(f, id: id)
      XCTAssertNotEqual(replacement, original)
      await f.workspace.refreshPublishedMetadata(for: observed)
      XCTAssertNil(f.workspace.reader)
      XCTAssertNotNil(f.workspace.failure)
      XCTAssertNil(observed.session.currentPaper)
      XCTAssertThrowsError(try observed.session.withReadAccess { XCTFail("Changed facts cannot read") })
    }
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
