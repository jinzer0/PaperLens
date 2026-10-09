import AppKit
import GRDB
import PDFKit
import XCTest
@testable import PaperLensProduct

/// Controlled position observations/reentry, not visible-frame or renderer evidence.
@MainActor private final class MetadataObservedPDFView: PDFView {
  var observedDestination: PDFDestination?
  var onObservation: (() -> Void)?
  var onNavigation: (() -> Void)?
  override var currentDestination: PDFDestination? {
    let result = observedDestination
    let callback = onObservation
    onObservation = nil
    callback?()
    return result
  }
  override func go(to destination: PDFDestination) {
    super.go(to: destination)
    let callback = onNavigation
    onNavigation = nil
    callback?()
  }
}

@MainActor private final class MetadataBindingOwner {
  let session: ReaderSession
  let view = MetadataObservedPDFView()
  var binding: ReaderMetadataBinding?
  var onDiscard: (() -> Void)?

  init(database: ProductDatabase, lifecycle: LocalLibraryLifecycle) {
    session = ReaderSession(database: database,
      leaseProvider: LibraryReadLeaseProvider(lifecycle: lifecycle))
  }
  func open(paperID: UUID) throws {
    try session.open(paperID: paperID, validateDocument: { url in
      let document = try XCTUnwrap(PDFDocument(url: url))
      self.view.document = document
      return document.pageCount
    }, discard: { [weak self] in
      guard let self else { return }
      // Drain PDFKit's autoreleased detach work before ReaderSession closes its real lease.
      autoreleasepool {
        self.binding?.invalidate()
        let callback = self.onDiscard
        self.onDiscard = nil
        callback?()
        self.binding = nil
        self.view.observedDestination = nil
        self.view.document = nil
      }
    })
  }
}

@MainActor final class ReaderMetadataBindingTests: XCTestCase {
  private func fixture() async throws
    -> (ProductDatabase, LocalLibraryLifecycle, ReaderMetadataIdentity, MetadataBindingOwner) {
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    addTeardownBlock { try FileManager.default.removeItem(at: temporary) }
    let bytes = NSMutableData()
    let consumer = try XCTUnwrap(CGDataConsumer(data: bytes as CFMutableData))
    var box = CGRect(x: 0, y: 0, width: 400, height: 600)
    let pdf = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
    for _ in 0..<2 { pdf.beginPDFPage(nil); pdf.endPDFPage() }
    pdf.closePDF()
    let source = temporary.appendingPathComponent("synthetic.pdf")
    try (bytes as Data).write(to: source)
    let database = try ProductDatabase.open(at: temporary.appendingPathComponent("library"))
    let lifecycle = try await LocalLibraryLifecycle.open(database: database)
    let paperID = try await lifecycle.importPDF(from: source)
    let paper = try database.readerSnapshot(paperID: paperID)
    let annotation = try database.annotationIdentity(paperID: paperID)
    let identity = ReaderMetadataIdentity(paperID: paperID, generation: paper.generation,
      pdfSHA256: annotation.pdfSHA256, pdfReference: paper.pdfReference, revisionID: UUID())
    // SQL models already-published visibility; it is not extraction producer proof.
    try database.adapterWrite { db in
      try db.execute(sql: """
        INSERT INTO extractionRevision(id, paperID, generation, pdfSHA256, pdfReference)
        VALUES (?, ?, ?, ?, ?)
        """, arguments: [identity.revisionID.uuidString, paperID.uuidString,
          identity.generation.uuidString, identity.pdfSHA256, identity.pdfReference])
      try db.execute(sql: "INSERT INTO extractionVisible(paperID, revision) VALUES (?, ?)",
        arguments: [paperID.uuidString, identity.revisionID.uuidString])
    }
    let owner = MetadataBindingOwner(database: database, lifecycle: lifecycle)
    try owner.open(paperID: paperID)
    return (database, lifecycle, identity, owner)
  }

  private func mount(_ database: ProductDatabase, _ identity: ReaderMetadataIdentity,
    _ owner: MetadataBindingOwner) throws -> ReaderMetadataBinding {
    let binding = try ReaderMetadataBinding(session: owner.session,
      service: ReaderMetadataService(database: database), identity: identity,
      view: owner.view, document: XCTUnwrap(owner.view.document))
    owner.binding = binding
    return binding
  }

  private func outline(_ owner: MetadataBindingOwner) throws {
    let document = try XCTUnwrap(owner.view.document)
    let page = try XCTUnwrap(document.page(at: 0))
    let root = PDFOutline(), first = PDFOutline(), second = PDFOutline(), invalid = PDFOutline()
    first.label = "Introduction"
    first.destination = PDFDestination(page: page, at: CGPoint(x: 20, y: 500))
    second.label = "Methods"
    second.destination = PDFDestination(page: page, at: CGPoint(x: 20, y: 200))
    invalid.label = "Foreign"
    invalid.destination = PDFDestination(page: PDFPage(), at: .zero)
    root.insertChild(first, at: 0); root.insertChild(second, at: 1); root.insertChild(invalid, at: 2)
    document.outlineRoot = root
  }

  func testRealTitleAttributeConflictAndDatesNeverBecomePublicationYear() async throws {
    let (db, _, identity, owner) = try await fixture()
    defer { owner.session.close() }
    let service = ReaderMetadataService(database: db)
    let accepted = ReaderMetadataSnapshot(title: .init([.init(text: "Accepted title",
      source: .acceptedExtraction, sourceID: identity.revisionID.uuidString)]))
    try service.accept(accepted, for: identity)
    owner.view.document?.documentAttributes = [
      PDFDocumentAttribute.titleAttribute: "Actual PDF title",
      PDFDocumentAttribute.authorAttribute: "Actual author",
      PDFDocumentAttribute.creationDateAttribute: Date(timeIntervalSince1970: 0),
      PDFDocumentAttribute.subjectAttribute: "Not an abstract",
      PDFDocumentAttribute.keywordsAttribute: ["Not an admitted topic"]]
    let binding = try mount(db, identity, owner)
    let metadata = try XCTUnwrap(binding.state).presentation.metadata
    XCTAssertTrue(metadata.title.isConflict)
    XCTAssertEqual(metadata.title.candidates.map(\.text), ["Accepted title", "Actual PDF title"])
    XCTAssertEqual(metadata.title.candidates.last?.sourceID, "pdf:\(identity.pdfSHA256)")
    XCTAssertTrue(metadata.year.candidates.isEmpty)
    XCTAssertTrue(metadata.abstract.candidates.isEmpty)
    XCTAssertTrue(metadata.topics.candidates.isEmpty)
    XCTAssertEqual(try service.metadata(for: identity), accepted)
    try binding.refresh()
    XCTAssertEqual(binding.state?.presentation.metadata.title.candidates.count, 2)
  }

  func testBlankOrWrongTypedAttributesPreserveAdmittedFieldsWithoutDefaults() async throws {
    let (db, _, identity, owner) = try await fixture()
    defer { owner.session.close() }
    let accepted = ReaderMetadataSnapshot(year: .init([.init(text: "2024",
      source: .acceptedExtraction, sourceID: identity.revisionID.uuidString)]))
    try ReaderMetadataService(database: db).accept(accepted, for: identity)
    owner.view.document?.documentAttributes = [PDFDocumentAttribute.titleAttribute: " \n"]
    let binding = try mount(db, identity, owner)
    XCTAssertEqual(binding.state?.presentation.metadata, accepted)
    owner.view.document?.documentAttributes = [PDFDocumentAttribute.titleAttribute: 42]
    try binding.refresh()
    XCTAssertEqual(binding.state?.presentation.metadata, accepted)
    XCTAssertTrue(binding.state?.sections.isEmpty == true)
  }

  func testActualOutlineIntentDoesNotConfirmButObservationPersists() async throws {
    let (db, _, identity, owner) = try await fixture()
    defer { owner.session.close() }
    try outline(owner)
    let binding = try mount(db, identity, owner)
    XCTAssertEqual(binding.state?.sections.map(\.title), ["Introduction", "Methods", "Foreign"])
    XCTAssertNil(binding.state?.sections.last?.location)
    try binding.navigate(sectionID: "/0")
    XCTAssertNil(binding.state?.observedLocation)
    XCTAssertThrowsError(try binding.navigate(sectionID: "/2"))
    let page = try XCTUnwrap(owner.view.document?.page(at: 0))
    owner.view.observedDestination = PDFDestination(page: page, at: CGPoint(x: 20, y: 150))
    try binding.observePosition()
    XCTAssertEqual(binding.state?.activeSectionID, "/1")
    let persisted = try ReaderMetadataService(database: db).beginSession(for: identity)
    XCTAssertEqual(persisted.location, .init(pageIndex: 0, x: 20, y: 150))
    XCTAssertEqual(persisted.sectionID, "/1")
  }

  func testValidatedRestorationIsNotObservedAndSavedSectionIsNotTrusted() async throws {
    let (db, _, identity, owner) = try await fixture()
    defer { owner.session.close() }
    try outline(owner)
    let service = ReaderMetadataService(database: db)
    let previous = try service.beginSession(for: identity)
    _ = try service.saveConfirmed(.init(pageIndex: 0, x: 20, y: 150),
      sectionID: "obsolete", expected: previous, for: identity)
    let binding = try mount(db, identity, owner)
    XCTAssertEqual(binding.state?.restorationCandidate, .init(pageIndex: 0, x: 20, y: 150))
    XCTAssertNil(binding.state?.observedLocation)
    XCTAssertNil(binding.state?.activeSectionID)
    binding.invalidate()
    let context = try service.beginSession(for: identity)
    _ = try service.saveConfirmed(.init(pageIndex: 99, x: 20, y: 150),
      sectionID: "/0", expected: context, for: identity)
    let next = try mount(db, identity, owner)
    XCTAssertNil(next.state?.restorationCandidate)
  }

  func testObservationReentryClosesBeforeSaveAndNavigationReentryFailsClosed() async throws {
    let (db, _, identity, owner) = try await fixture()
    try outline(owner)
    let binding = try mount(db, identity, owner)
    let page = try XCTUnwrap(owner.view.document?.page(at: 0))
    owner.view.observedDestination = PDFDestination(page: page, at: CGPoint(x: 20, y: 150))
    owner.view.onObservation = { owner.session.close() }
    XCTAssertThrowsError(try binding.observePosition())
    XCTAssertNil(binding.state)
    XCTAssertNil(try ReaderMetadataService(database: db).beginSession(for: identity).location)
    try owner.open(paperID: identity.paperID)
    defer { owner.session.close() }
    try outline(owner)
    let next = try mount(db, identity, owner)
    owner.view.onNavigation = { owner.session.close() }
    XCTAssertThrowsError(try next.navigate(sectionID: "/0"))
    XCTAssertNil(next.state)
  }

  func testRevisionRemovalAndDocumentReplacementDiscardPresentation() async throws {
    let (db, _, identity, owner) = try await fixture()
    defer { owner.session.close() }
    let binding = try mount(db, identity, owner)
    try db.adapterWrite { sql in
      try sql.execute(sql: "DELETE FROM extractionVisible WHERE paperID = ?",
        arguments: [identity.paperID.uuidString])
    }
    XCTAssertThrowsError(try binding.refresh())
    XCTAssertNil(binding.state)
    try db.adapterWrite { sql in
      try sql.execute(sql: "INSERT INTO extractionVisible(paperID, revision) VALUES (?, ?)",
        arguments: [identity.paperID.uuidString, identity.revisionID.uuidString])
    }
    let next = try mount(db, identity, owner)
    owner.view.document = PDFDocument()
    XCTAssertThrowsError(try next.refresh())
    XCTAssertNil(next.state)
  }

  func testCASReplacementAndStorageFailureNeverPublishSavedPosition() async throws {
    let (db, _, identity, owner) = try await fixture()
    defer { owner.session.close() }
    let binding = try mount(db, identity, owner)
    let page = try XCTUnwrap(owner.view.document?.page(at: 0))
    owner.view.observedDestination = PDFDestination(page: page, at: CGPoint(x: 20, y: 150))
    try db.adapterWrite { sql in
      try sql.execute(sql: """
        CREATE TRIGGER rejectBoundPosition BEFORE UPDATE ON readerMetadataContext
        BEGIN SELECT RAISE(ABORT, 'controlled storage failure'); END;
        """)
    }
    XCTAssertThrowsError(try binding.observePosition())
    XCTAssertNotNil(binding.state)
    XCTAssertNil(binding.state?.observedLocation)
    try db.adapterWrite { try $0.execute(sql: "DROP TRIGGER rejectBoundPosition") }
    try binding.observePosition()
    XCTAssertNotNil(binding.state?.observedLocation)
    let replacement = try ReaderMetadataService(database: db).beginSession(for: identity)
    XCTAssertThrowsError(try binding.observePosition()) { error in
      XCTAssertEqual(error as? ReaderMetadataError, .staleConfirmation)
    }
    XCTAssertNil(binding.state?.observedLocation)
    XCTAssertEqual(try ReaderMetadataService(database: db).beginSession(for: identity).sequence,
      replacement.sequence)
  }

  func testInvalidAndReentrantObservationsCannotSaveForeignPositions() async throws {
    let (db, _, identity, owner) = try await fixture()
    defer { owner.session.close() }
    let binding = try mount(db, identity, owner)
    owner.view.observedDestination = PDFDestination(page: PDFPage(), at: .zero)
    XCTAssertThrowsError(try binding.observePosition())
    let page = try XCTUnwrap(owner.view.document?.page(at: 0))
    owner.view.observedDestination = PDFDestination(page: page, at: CGPoint(x: CGFloat.nan, y: 150))
    XCTAssertThrowsError(try binding.observePosition())
    owner.view.observedDestination = PDFDestination(page: page, at: CGPoint(x: 20, y: 150))
    owner.view.onObservation = {
      do {
        try binding.observePosition()
        XCTFail("Reentrant observation must reject without saving")
      } catch {
        XCTAssertEqual(error as? ReaderMetadataError, .staleConfirmation)
      }
    }
    try binding.observePosition()
    XCTAssertEqual(try ReaderMetadataService(database: db).beginSession(for: identity).sequence, 1)
  }

  func testBindingDoesNotRetainDocumentAfterParentDetaches() async throws {
    let (db, _, identity, owner) = try await fixture()
    defer { owner.session.close() }
    try outline(owner)
    let binding = try mount(db, identity, owner)
    weak var document = owner.view.document
    binding.invalidate()
    owner.view.document = nil
    XCTAssertNil(document)
    XCTAssertNil(binding.state)
    XCTAssertThrowsError(try binding.refresh())
    XCTAssertThrowsError(try binding.navigate(sectionID: "/0"))
  }

  func testUnpublishedIdentityAndRevisionSwitchDuringObservationNeverSave() async throws {
    let (db, _, identity, owner) = try await fixture()
    defer { owner.session.close() }
    let unpublished = ReaderMetadataIdentity(paperID: identity.paperID,
      generation: identity.generation, pdfSHA256: identity.pdfSHA256,
      pdfReference: identity.pdfReference, revisionID: UUID())
    XCTAssertThrowsError(try mount(db, unpublished, owner))
    let binding = try mount(db, identity, owner)
    let page = try XCTUnwrap(owner.view.document?.page(at: 0))
    owner.view.observedDestination = PDFDestination(page: page, at: CGPoint(x: 20, y: 150))
    owner.view.onObservation = {
      do {
        try db.adapterWrite { sql in
          try sql.execute(sql: """
            INSERT INTO extractionRevision(id, paperID, generation, pdfSHA256, pdfReference)
            VALUES (?, ?, ?, ?, ?)
            """, arguments: [unpublished.revisionID.uuidString, identity.paperID.uuidString,
              identity.generation.uuidString, identity.pdfSHA256, identity.pdfReference])
          try sql.execute(sql: "UPDATE extractionVisible SET revision = ? WHERE paperID = ?",
            arguments: [unpublished.revisionID.uuidString, identity.paperID.uuidString])
        }
      } catch { XCTFail("Revision fixture failed: \(error)") }
    }
    XCTAssertThrowsError(try binding.observePosition())
    XCTAssertNil(binding.state)
    XCTAssertNil(try ReaderMetadataService(database: db).beginSession(for: unpublished).location)
  }

  func testActualLifecycleDeletionSynchronouslyDiscardsBindingAndPDF() async throws {
    let (db, lifecycle, identity, owner) = try await fixture()
    defer { owner.session.close() }
    let binding = try mount(db, identity, owner)
    weak var document = owner.view.document
    let original = db.root.appendingPathComponent(identity.pdfReference)
    var discardedBeforeDetach = false
    owner.onDiscard = {
      XCTAssertNil(binding.state)
      XCTAssertNotNil(document)
      XCTAssertTrue(owner.view.document === document)
      XCTAssertNotNil(owner.session.currentPaper)
      discardedBeforeDetach = true
    }
    XCTAssertNotNil(binding.state)
    // No Agent owner is bound by this fixture. Revocation must still finish, but
    // absence of its purge receipt must retain bytes and durable deletion debt.
    do {
      try await lifecycle.delete(paperID: identity.paperID)
      XCTFail("Missing Agent must not certify deletion")
    } catch {
      XCTAssertEqual(error as? LocalLibraryError, .agentPurgeUnavailable)
    }
    // This throws for unknown physical FileHandle closure; PDF detach alone is not proof.
    try await lifecycle.readLeaseRegistry.drain(identity.paperID)
    XCTAssertTrue(discardedBeforeDetach)
    XCTAssertNil(binding.state)
    XCTAssertNil(owner.view.document)
    XCTAssertNil(document)
    XCTAssertNil(owner.session.currentPaper)
    let record = try XCTUnwrap(db.libraryRecords().first { $0.id == identity.paperID })
    XCTAssertEqual(record.status, .deletionFailed)
    XCTAssertTrue(record.cleanupDebt)
    XCTAssertEqual(record.failure, "agentPurgeUnavailable")
    XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
    XCTAssertThrowsError(try binding.refresh())
    XCTAssertThrowsError(try ReaderMetadataService(database: db).metadata(for: identity))
  }

  func testPublishedIdentityCaptureRejectsUnpublishedAndMismatchedRevision() async throws {
    let (db, _, identity, owner) = try await fixture()
    defer { owner.session.close() }
    XCTAssertEqual(try db.publishedMetadataPaperIdentity(paperID: identity.paperID), identity)
    try db.adapterWrite {
      try $0.execute(sql: "UPDATE extractionRevision SET pdfSHA256 = ? WHERE id = ?",
        arguments: [String(repeating: "0", count: 64), identity.revisionID.uuidString])
    }
    XCTAssertNil(try db.publishedMetadataPaperIdentity(paperID: identity.paperID))
    try db.adapterWrite {
      try $0.execute(sql: "UPDATE extractionRevision SET pdfSHA256 = ? WHERE id = ?",
        arguments: [identity.pdfSHA256, identity.revisionID.uuidString])
      try $0.execute(sql: "DELETE FROM extractionVisible WHERE paperID = ?",
        arguments: [identity.paperID.uuidString])
    }
    XCTAssertNil(try db.publishedMetadataPaperIdentity(paperID: identity.paperID))
  }

  func testActualReaderMountMissingContextAndIdentityReplacement() async throws {
    let (db, lifecycle, identity, owner) = try await fixture()
    owner.session.close()
    let session = ReaderSession(database: db,
      leaseProvider: LibraryReadLeaseProvider(lifecycle: lifecycle))
    let presentation = ReaderPresentation(session: session,
      annotationIdentity: try db.annotationIdentity(paperID: identity.paperID),
      annotationService: AnnotationService(database: db),
      metadataService: ReaderMetadataService(database: db), metadataIdentity: nil)
    defer { session.close() }
    presentation.open(paperID: identity.paperID)
    XCTAssertTrue(presentation.opened)
    XCTAssertNotNil(presentation.pdfView.document)
    XCTAssertNil(presentation.metadataBinding)
    XCTAssertNotNil(presentation.metadataFailure)
    presentation.replaceMetadataIdentity(try db.publishedMetadataPaperIdentity(paperID: identity.paperID))
    let binding = try XCTUnwrap(presentation.metadataBinding)
    XCTAssertEqual(binding.identity, identity)
    XCTAssertNotNil(binding.state)
    XCTAssertNil(binding.state?.observedLocation)
    presentation.toggleAnnotations()
    let annotations = try XCTUnwrap(presentation.annotationContext)
    weak var document = presentation.pdfView.document
    presentation.replaceMetadataIdentity(nil)
    XCTAssertNil(binding.state)
    XCTAssertThrowsError(try binding.navigate(sectionID: "/0"))
    XCTAssertFalse(annotations.isActive)
    XCTAssertNil(presentation.annotationContext)
    XCTAssertNotNil(document)
    session.close()
    XCTAssertNil(presentation.pdfView.document)
    XCTAssertNil(document)
  }

  func testActualReaderPositionNotificationRejectsRemovedRevision() async throws {
    let (db, lifecycle, identity, owner) = try await fixture()
    owner.session.close()
    let session = ReaderSession(database: db,
      leaseProvider: LibraryReadLeaseProvider(lifecycle: lifecycle))
    let presentation = ReaderPresentation(session: session,
      annotationIdentity: try db.annotationIdentity(paperID: identity.paperID),
      annotationService: AnnotationService(database: db),
      metadataService: ReaderMetadataService(database: db), metadataIdentity: identity)
    defer { session.close() }
    presentation.open(paperID: identity.paperID)
    let binding = try XCTUnwrap(presentation.metadataBinding)
    try db.adapterWrite {
      try $0.execute(sql: "DELETE FROM extractionVisible WHERE paperID = ?",
        arguments: [identity.paperID.uuidString])
    }
    NotificationCenter.default.post(name: .PDFViewPageChanged, object: presentation.pdfView)
    XCTAssertNil(binding.state)
    XCTAssertNotNil(presentation.metadataFailure)
    XCTAssertNotNil(presentation.pdfView.document)
    XCTAssertThrowsError(try binding.navigate(sectionID: "/0"))
  }
}
