import AppKit
import CoreText
import GRDB
import PDFKit
import XCTest
@testable import PaperLensProduct

/// Deterministic synchronous PDFKit reentry without a window or a visible-frame trial.
@MainActor private final class AnnotationReentrantPDFView: PDFView {
  var onSelectionRead: (() -> Void)?
  var onNavigation: (() -> Void)?
  var navigationCalls = 0
  override var currentSelection: PDFSelection? {
    get {
      let selection = super.currentSelection
      let callback = onSelectionRead
      onSelectionRead = nil
      callback?()
      return selection
    }
    set { super.currentSelection = newValue }
  }
  override func go(to destination: PDFDestination) {
    navigationCalls += 1
    super.go(to: destination)
    let callback = onNavigation
    onNavigation = nil
    callback?()
  }
}

/// Public page-class delegate hook; ordinary PDFKit selections unless explicitly denied.
private final class AnnotationControlledPDFPage: PDFPage {
  var rejectRectangleSelection = false
  var rectangleSelectionCalls = 0
  var onRectangleSelection: (() -> Void)?

  override func selection(for rect: CGRect) -> PDFSelection? {
    rectangleSelectionCalls += 1
    let callback = onRectangleSelection
    onRectangleSelection = nil
    callback?()
    guard !rejectRectangleSelection else { return nil }
    return super.selection(for: rect)
  }
}

private final class AnnotationPageDelegate: NSObject, PDFDocumentDelegate {
  func classForPage() -> AnyClass { AnnotationControlledPDFPage.self }
}

/// Mirrors presentation ownership: context resets before document detach and lease close.
@MainActor private final class AnnotationBindingFixture {
  let session: ReaderSession
  let view = AnnotationReentrantPDFView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
  var context: ReaderAnnotationContext?
  var discards = 0
  private let pageDelegate = AnnotationPageDelegate()

  init(database: ProductDatabase, lifecycle: LocalLibraryLifecycle) {
    session = ReaderSession(database: database, leaseProvider: LibraryReadLeaseProvider(lifecycle: lifecycle))
  }

  func open(database: ProductDatabase, paperID: UUID) throws -> ReaderAnnotationContext {
    let identity = try database.annotationIdentity(paperID: paperID)
    try session.open(paperID: paperID, validateDocument: { url in
      let document = try XCTUnwrap(PDFDocument(url: url))
      document.delegate = self.pageDelegate
      self.view.document = document
      return document.pageCount
    }, discard: { [weak self] in self?.discard() })
    let admitted = try session.withReadAccess {
      try ReaderAnnotationContext(session: session, service: AnnotationService(database: database),
        identity: identity, view: view, document: XCTUnwrap(view.document))
    }
    context = admitted
    try session.withReadAccess {
      let document = try XCTUnwrap(view.document)
      let matches = document.findString("alpha", withOptions: [])
      XCTAssertEqual(matches.count, 2)
      view.currentSelection = try XCTUnwrap(matches.last)
    }
    return admitted
  }

  func discard() {
    discards += 1
    context?.invalidate()
    context = nil
    view.onSelectionRead = nil; view.onNavigation = nil
    view.clearSelection()
    view.highlightedSelections = nil
    view.document = nil
  }
}

@MainActor final class ReaderAnnotationBindingTests: XCTestCase {
  private func fixture() async throws
    -> (URL, ProductDatabase, LocalLibraryLifecycle, UUID, AnnotationBindingFixture) {
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    addTeardownBlock { try FileManager.default.removeItem(at: temporary) }
    let data = NSMutableData()
    let consumer = try XCTUnwrap(CGDataConsumer(data: data as CFMutableData))
    var box = CGRect(x: 0, y: 0, width: 400, height: 600)
    let pdf = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
    for _ in 0..<2 {
      pdf.beginPDFPage(nil)
      pdf.textPosition = CGPoint(x: 40, y: 500)
      let text = NSAttributedString(string: "alpha original owned text", attributes: [
        .font: NSFont.systemFont(ofSize: 14)])
      CTLineDraw(CTLineCreateWithAttributedString(text as CFAttributedString), pdf)
      pdf.endPDFPage()
    }
    pdf.closePDF()
    let source = temporary.appendingPathComponent("owned.pdf")
    try (data as Data).write(to: source)
    let database = try ProductDatabase.open(at: temporary.appendingPathComponent("library"))
    let lifecycle = try await LocalLibraryLifecycle.open(database: database)
    let id = try await lifecycle.importPDF(from: source)
    let binding = AnnotationBindingFixture(database: database, lifecycle: lifecycle)
    return (temporary, database, lifecycle, id, binding)
  }

  func testRealSelectionHighlightNoteRevealAndReopenNeverRewriteOriginal() async throws {
    let (_, db, _, id, binding) = try await fixture()
    defer { binding.session.close() }
    let context = try binding.open(database: db, paperID: id)
    let reference = try db.readerSnapshot(paperID: id).pdfReference
    let original = try Data(contentsOf: db.root.appendingPathComponent(reference))
    let snapshot = try context.capture()
    XCTAssertEqual(snapshot.originalText, "alpha")
    XCTAssertEqual(snapshot.locations.map(\.pageIndex), [1])
    XCTAssertEqual(snapshot.coordinateRepresentation, "pdfkit-page-native-v1")
    let highlight = try context.createHighlight()
    try binding.session.withReadAccess {
      binding.view.currentSelection = try XCTUnwrap(binding.view.document?.findString("alpha", withOptions: []).first)
    }
    let note = try context.createNote(snapshot, text: "owned personal observation")
    XCTAssertEqual(note.selection, snapshot) // A changed live selection cannot retarget the frozen draft.
    try context.reveal(highlight)
    try binding.session.withReadAccess {
      XCTAssertFalse(binding.view.highlightedSelections?.isEmpty ?? true)
      let document = try XCTUnwrap(binding.view.document)
      XCTAssertEqual(document.index(for: try XCTUnwrap(binding.view.currentPage)), 1)
    }
    let edited = try context.updateNote(note, text: "edited observation")
    XCTAssertThrowsError(try context.updateNote(note, text: "stale edit"))
    XCTAssertThrowsError(try context.delete(note))
    XCTAssertThrowsError(try context.updateNote(edited, text: " "))
    XCTAssertEqual(Set(try context.records().map(\.id)), Set([highlight.id, note.id]))
    binding.session.close()
    let reopened = try ProductDatabase.open(at: db.root)
    let service = AnnotationService(database: reopened)
    let records = try service.records(for: reopened.annotationIdentity(paperID: id))
    XCTAssertTrue(records.contains(highlight))
    XCTAssertTrue(records.contains(edited))
    XCTAssertEqual(try Data(contentsOf: db.root.appendingPathComponent(reference)), original)
    let fresh = try binding.open(database: db, paperID: id)
    try fresh.reveal(edited)
    try fresh.delete(edited)
    XCTAssertEqual(try fresh.records(), [highlight])
  }

  private func presentation(database: ProductDatabase, lifecycle: LocalLibraryLifecycle,
    paperID: UUID) throws -> ReaderPresentation {
    let session = ReaderSession(database: database,
      leaseProvider: LibraryReadLeaseProvider(lifecycle: lifecycle))
    let reader = ReaderPresentation(session: session,
      annotationIdentity: try database.annotationIdentity(paperID: paperID),
      annotationService: AnnotationService(database: database),
      metadataService: ReaderMetadataService(database: database), metadataIdentity: nil)
    reader.open(paperID: paperID)
    XCTAssertTrue(reader.opened)
    return reader
  }

  private func settleSearch(_ reader: ReaderPresentation) async {
    for _ in 0..<1000 {
      if reader.searchState != .searching { return }
      await Task.yield()
    }
    XCTFail("Owned native search did not settle within the bounded scheduler pass")
  }

  func testActualPresentationSearchMatchesNoResultsEmptyQueryAndLatestRequest() async throws {
    let (_, db, lifecycle, id, _) = try await fixture()
    let reader = try presentation(database: db, lifecycle: lifecycle, paperID: id)
    defer { reader.session.close() }
    let reference = try db.readerSnapshot(paperID: id).pdfReference
    let original = try Data(contentsOf: db.root.appendingPathComponent(reference))
    reader.query = "ALPHA"
    reader.search()
    XCTAssertEqual(reader.searchState, .searching)
    await settleSearch(reader)
    XCTAssertEqual(reader.searchState, .matches(2))
    XCTAssertEqual(reader.pdfView.currentSelection?.string, "alpha")
    reader.showMatch(delta: 1)
    XCTAssertEqual(reader.pdfView.currentSelection?.string, "alpha")
    reader.query = "not present in this owned PDF"
    reader.search()
    await settleSearch(reader)
    XCTAssertEqual(reader.searchState, .noResults)
    XCTAssertNil(reader.pdfView.currentSelection)
    reader.query = "alpha"
    reader.search()
    reader.query = "absent latest query"
    reader.search()
    await settleSearch(reader)
    XCTAssertEqual(reader.searchState, .noResults)
    XCTAssertNil(reader.pdfView.currentSelection)
    reader.query = ""
    reader.search()
    XCTAssertEqual(reader.searchState, .idle)
    XCTAssertTrue(reader.opened)
    XCTAssertEqual(try Data(contentsOf: db.root.appendingPathComponent(reference)), original)
  }

  func testNativeSelectionClearingReentryPreservesDiscardInsteadOfSearchingForever() async throws {
    let (_, db, lifecycle, id, _) = try await fixture()
    let reader = try presentation(database: db, lifecycle: lifecycle, paperID: id)
    defer { reader.session.close() }
    reader.query = "alpha"
    reader.search()
    await settleSearch(reader)
    XCTAssertEqual(reader.searchState, .matches(2))
    XCTAssertNotNil(reader.pdfView.currentSelection)
    var observations = 0
    let token = NotificationCenter.default.addObserver(forName: .PDFViewSelectionChanged,
      object: reader.pdfView, queue: .main) { _ in
      MainActor.assumeIsolated {
        observations += 1
        if observations == 1 { reader.session.close() }
      }
    }
    defer { NotificationCenter.default.removeObserver(token) }
    reader.search()
    XCTAssertGreaterThan(observations, 0)
    XCTAssertFalse(reader.opened)
    XCTAssertNil(reader.pdfView.document)
    XCTAssertEqual(reader.searchState, .idle)
    let discardFailure = reader.failure
    XCTAssertNotNil(discardFailure)
    for _ in 0..<20 { await Task.yield() }
    XCTAssertEqual(reader.searchState, .idle)
    XCTAssertEqual(reader.failure, discardFailure)
    XCTAssertNil(reader.pdfView.currentSelection)
  }

  func testActualPresentationDiscardBeforeScheduledSearchCannotPublishMatches() async throws {
    let (_, db, lifecycle, id, _) = try await fixture()
    let reader = try presentation(database: db, lifecycle: lifecycle, paperID: id)
    defer { reader.session.close() }
    reader.query = "alpha"
    reader.search()
    XCTAssertEqual(reader.searchState, .searching)
    reader.session.close()
    let discardFailure = reader.failure
    for _ in 0..<20 { await Task.yield() }
    XCTAssertFalse(reader.opened)
    XCTAssertNil(reader.pdfView.document)
    XCTAssertEqual(reader.searchState, .idle)
    XCTAssertEqual(reader.failure, discardFailure)
    XCTAssertNil(reader.pdfView.currentSelection)
  }

  func testNextNativeMatchCannotNavigateAfterSelectionCallbackStartsNewQuery() async throws {
    let (_, db, lifecycle, id, _) = try await fixture()
    let reader = try presentation(database: db, lifecycle: lifecycle, paperID: id)
    defer { reader.session.close() }
    reader.query = "alpha"
    reader.search()
    await settleSearch(reader)
    XCTAssertEqual(reader.searchState, .matches(2))
    let document = try XCTUnwrap(reader.pdfView.document)
    let priorPage = try XCTUnwrap(reader.pdfView.currentPage)
    XCTAssertEqual(document.index(for: priorPage), 0)
    var observations = 0
    let token = NotificationCenter.default.addObserver(forName: .PDFViewSelectionChanged,
      object: reader.pdfView, queue: .main) { _ in
      MainActor.assumeIsolated {
        observations += 1
        if observations == 1 {
          reader.query = "missing newer native query"
          reader.search()
        }
      }
    }
    defer { NotificationCenter.default.removeObserver(token) }
    reader.showMatch(delta: 1)
    XCTAssertGreaterThan(observations, 0)
    XCTAssertTrue(reader.pdfView.currentPage === priorPage)
    XCTAssertNil(reader.pdfView.currentSelection)
    await settleSearch(reader)
    XCTAssertEqual(reader.searchState, .noResults)
    XCTAssertTrue(reader.pdfView.currentPage === priorPage)
    XCTAssertTrue(reader.pdfView.document === document)
    XCTAssertTrue(reader.opened)
    XCTAssertNil(reader.failure)
  }

  func testNextNativeMatchSelectionCallbackClosesActualSessionBeforeNavigation() async throws {
    let (_, db, lifecycle, id, _) = try await fixture()
    let reader = try presentation(database: db, lifecycle: lifecycle, paperID: id)
    defer { reader.session.close() }
    reader.query = "alpha"
    reader.search()
    await settleSearch(reader)
    XCTAssertEqual(reader.searchState, .matches(2))
    var observations = 0
    let token = NotificationCenter.default.addObserver(forName: .PDFViewSelectionChanged,
      object: reader.pdfView, queue: .main) { _ in
      MainActor.assumeIsolated {
        observations += 1
        if observations == 1 { reader.session.close() }
      }
    }
    defer { NotificationCenter.default.removeObserver(token) }
    reader.showMatch(delta: 1)
    XCTAssertGreaterThan(observations, 0)
    XCTAssertFalse(reader.opened)
    XCTAssertNil(reader.pdfView.document)
    XCTAssertNil(reader.pdfView.currentSelection)
    XCTAssertEqual(reader.searchState, .idle)
    let discardFailure = reader.failure
    XCTAssertNotNil(discardFailure)
    for _ in 0..<20 { await Task.yield() }
    XCTAssertEqual(reader.failure, discardFailure)
    XCTAssertEqual(reader.searchState, .idle)
    XCTAssertNil(reader.pdfView.document)
    XCTAssertNil(reader.pdfView.currentSelection)
  }

  func testIncompleteMultipageRevealHasNoPartialOverlayNavigationOrRecordLoss() async throws {
    let (_, db, _, id, binding) = try await fixture()
    defer { binding.session.close() }
    let context = try binding.open(database: db, paperID: id)
    let document = try XCTUnwrap(binding.view.document)
    let reference = try db.readerSnapshot(paperID: id).pdfReference
    let original = try Data(contentsOf: db.root.appendingPathComponent(reference))
    let matches = document.findString("alpha", withOptions: [])
    XCTAssertEqual(matches.count, 2)
    let complete = PDFSelection(document: document)
    complete.add(matches[0]); complete.add(matches[1])
    binding.view.currentSelection = complete
    let highlight = try context.createHighlight()
    XCTAssertEqual(highlight.selection.locations.map(\.pageIndex), [0, 1])
    try context.reveal(highlight)
    let priorOverlay = try XCTUnwrap(binding.view.highlightedSelections?.first)
    let priorPage = binding.view.currentPage
    let priorNavigation = binding.view.navigationCalls
    let laterPage = try XCTUnwrap(document.page(at: 1) as? AnnotationControlledPDFPage)
    let priorCalls = laterPage.rectangleSelectionCalls
    laterPage.rejectRectangleSelection = true
    XCTAssertThrowsError(try context.reveal(highlight)) {
      XCTAssertEqual($0 as? AnnotationError, .invalidSelection)
    }
    XCTAssertGreaterThan(laterPage.rectangleSelectionCalls, priorCalls)
    XCTAssertTrue(binding.view.highlightedSelections?.first === priorOverlay)
    XCTAssertTrue(binding.view.currentPage === priorPage)
    XCTAssertEqual(binding.view.navigationCalls, priorNavigation)
    XCTAssertEqual(try context.records(), [highlight])
    XCTAssertTrue(context.isActive)
    XCTAssertEqual(try Data(contentsOf: db.root.appendingPathComponent(reference)), original)
    laterPage.rejectRectangleSelection = false
    try context.reveal(highlight)
    XCTAssertEqual(binding.view.highlightedSelections?.first?.pages.count, 2)
    XCTAssertEqual(binding.view.navigationCalls, priorNavigation + 1)
  }

  func testReconstructionReentryCannotInstallOverlayOrNavigateAfterSessionClose() async throws {
    let (_, db, _, id, binding) = try await fixture()
    defer { binding.session.close() }
    let context = try binding.open(database: db, paperID: id)
    let saved = try context.createHighlight()
    let page = try XCTUnwrap(binding.view.document?.page(at: 1) as? AnnotationControlledPDFPage)
    let navigation = binding.view.navigationCalls
    page.onRectangleSelection = { binding.session.close() }
    XCTAssertThrowsError(try context.reveal(saved))
    XCTAssertFalse(context.isActive)
    XCTAssertNil(binding.view.document)
    XCTAssertNil(binding.view.highlightedSelections)
    XCTAssertEqual(binding.view.navigationCalls, navigation)
    XCTAssertEqual(try AnnotationService(database: db).records(for: context.identity), [saved])
  }

  func testCancelDataOnlyDraftDoesNotWriteAndCloseResetsAllEditorState() async throws {
    let (_, db, _, id, binding) = try await fixture()
    defer { binding.session.close() }
    let context = try binding.open(database: db, paperID: id)
    context.editor.draft = try context.capture()
    context.editor.text = "unsaved observation"
    context.editor.cancel()
    XCTAssertNil(context.editor.draft)
    XCTAssertEqual(context.editor.text, "")
    XCTAssertTrue(try context.records().isEmpty)
    let note = try context.createNote(context.capture(), text: "saved")
    context.editor.draft = try context.capture()
    context.editor.editing = note
    context.editor.records = [note]
    context.editor.text = "pending edit"
    binding.session.close()
    XCTAssertFalse(context.isActive)
    XCTAssertNil(context.editor.draft)
    XCTAssertNil(context.editor.editing)
    XCTAssertTrue(context.editor.records.isEmpty)
    XCTAssertEqual(context.editor.text, "")
    XCTAssertThrowsError(try context.createNote(note.selection, text: "late"))
    XCTAssertEqual(try AnnotationService(database: db).records(for: context.identity), [note])
  }

  func testInvalidSelectionAndStorageFailureDoNotSaveOrLosePendingDraft() async throws {
    let (_, db, _, id, binding) = try await fixture()
    defer { binding.session.close() }
    let context = try binding.open(database: db, paperID: id)
    let draft = try context.capture()
    try binding.session.withReadAccess { binding.view.clearSelection() }
    XCTAssertThrowsError(try context.capture())
    XCTAssertThrowsError(try context.createHighlight())
    XCTAssertThrowsError(try context.createNote(draft, text: ""))
    context.editor.draft = draft
    context.editor.text = "retryable unsaved observation"
    try db.adapterWrite { sql in
      try sql.execute(sql: """
        CREATE TRIGGER rejectBoundAnnotation BEFORE INSERT ON personalAnnotation
        BEGIN SELECT RAISE(ABORT, 'owned annotation storage failure'); END;
        """)
    }
    XCTAssertThrowsError(try context.createNote(draft, text: context.editor.text))
    XCTAssertTrue(context.isActive)
    XCTAssertEqual(context.editor.draft, draft)
    XCTAssertEqual(context.editor.text, "retryable unsaved observation")
    XCTAssertTrue(try context.records().isEmpty)
  }

  func testStaleHashRejectsCaptureRevealWritesAndResetsDraft() async throws {
    let (_, db, _, id, binding) = try await fixture()
    defer { binding.session.close() }
    let context = try binding.open(database: db, paperID: id)
    let draft = try context.capture()
    let note = try context.createNote(draft, text: "saved before mismatch")
    context.editor.draft = draft
    try db.adapterWrite { sql in
      try sql.execute(sql: "UPDATE paper SET pdfSHA256 = ? WHERE id = ?",
        arguments: [String(repeating: "b", count: 64), id.uuidString])
    }
    XCTAssertThrowsError(try context.capture())
    XCTAssertFalse(context.isActive)
    XCTAssertNil(context.editor.draft)
    XCTAssertThrowsError(try context.reveal(note))
    XCTAssertThrowsError(try context.createNote(draft, text: "late"))
    XCTAssertThrowsError(try context.updateNote(note, text: "late"))
    XCTAssertThrowsError(try context.delete(note))
    XCTAssertThrowsError(try AnnotationService(database: db).updateNote(note, text: "direct stale"))
    XCTAssertThrowsError(try AnnotationService(database: db).delete(note))
  }

  func testGenerationReplacementCannotReuseContextOrDraft() async throws {
    let (_, db, _, id, binding) = try await fixture()
    defer { binding.session.close() }
    let old = try binding.open(database: db, paperID: id)
    let draft = try old.capture()
    let note = try old.createNote(draft, text: "old generation")
    try db.adapterWrite { sql in
      try sql.execute(sql: "UPDATE paper SET generation = ? WHERE id = ?",
        arguments: [UUID().uuidString, id.uuidString])
    }
    XCTAssertThrowsError(try old.capture())
    XCTAssertNil(binding.view.document)
    XCTAssertNil(binding.session.currentPaper)
    XCTAssertThrowsError(try old.reveal(note))
    XCTAssertThrowsError(try old.updateNote(note, text: "late"))
    XCTAssertThrowsError(try old.delete(note))
    XCTAssertThrowsError(try old.createNote(draft, text: "late"))
    // A lifecycle identity replacement requires a newly admitted lifecycle, not registry reuse.
    let freshLifecycle = try await LocalLibraryLifecycle.open(database: db)
    let freshBinding = AnnotationBindingFixture(database: db, lifecycle: freshLifecycle)
    defer { freshBinding.session.close() }
    let fresh = try freshBinding.open(database: db, paperID: id)
    XCTAssertTrue(try fresh.records().isEmpty)
    XCTAssertThrowsError(try fresh.createNote(draft, text: "foreign generation draft"))
  }

  func testRevocationRejectsRetainedViewDocumentAndReadmission() async throws {
    let (_, db, lifecycle, id, binding) = try await fixture()
    let context = try binding.open(database: db, paperID: id)
    let retained = try XCTUnwrap(binding.view.document)
    let draft = try context.capture()
    let note = try context.createNote(draft, text: "before revoke")
    for callback in lifecycle.readLeaseRegistry.revoke(id) { callback() }
    XCTAssertNil(binding.view.document)
    XCTAssertFalse(context.isActive)
    // Even deliberate reattachment by a retaining caller cannot revive the capability.
    binding.view.document = retained
    XCTAssertThrowsError(try context.capture())
    XCTAssertThrowsError(try context.reveal(note))
    XCTAssertThrowsError(try context.createNote(draft, text: "late"))
    XCTAssertThrowsError(try context.updateNote(note, text: "late"))
    XCTAssertThrowsError(try context.delete(note))
    binding.view.document = nil
    try await lifecycle.readLeaseRegistry.drain(id)
    XCTAssertThrowsError(try binding.open(database: db, paperID: id))
    binding.session.close()
  }

  func testReentrantSelectionRevocationCannotPublishSnapshotOrInsertHighlight() async throws {
    let (_, db, lifecycle, id, binding) = try await fixture()
    let context = try binding.open(database: db, paperID: id)
    let completed = DispatchSemaphore(value: 0)
    var drain: Task<Void, any Error>?
    binding.view.onSelectionRead = {
      for callback in lifecycle.readLeaseRegistry.revoke(id) { callback() }
      drain = Task.detached {
        try await lifecycle.readLeaseRegistry.drain(id)
        completed.signal()
      }
      // Physical lifetime is pinned until the active synchronous capture unwinds.
      XCTAssertEqual(completed.wait(timeout: .now() + 0.05), .timedOut)
    }
    XCTAssertThrowsError(try context.createHighlight())
    XCTAssertFalse(context.isActive)
    XCTAssertNil(binding.view.document)
    XCTAssertTrue(try AnnotationService(database: db).records(for: context.identity).isEmpty)
    try await drain?.value
    binding.session.close()
  }

  func testReentrantNavigationCloseRejectsResultAndResetsEditorImmediately() async throws {
    let (_, db, _, id, binding) = try await fixture()
    defer { binding.session.close() }
    let context = try binding.open(database: db, paperID: id)
    let record = try context.createHighlight()
    context.editor.draft = try context.capture()
    context.editor.records = [record]
    binding.view.onNavigation = { binding.session.close() }
    XCTAssertThrowsError(try context.reveal(record))
    XCTAssertFalse(context.isActive)
    XCTAssertNil(context.editor.draft)
    XCTAssertTrue(context.editor.records.isEmpty)
    XCTAssertNil(binding.view.document)
    let fresh = try binding.open(database: db, paperID: id)
    XCTAssertThrowsError(try context.capture())
    XCTAssertEqual(try fresh.records(), [record])
  }

  func testContextAndDraftDoNotRetainAdmittedDocumentAfterDiscard() async throws {
    let (_, db, _, id, binding) = try await fixture()
    var retainedContext: ReaderAnnotationContext?
    var retainedDraft: PDFSelectionSnapshot?
    weak var admitted: PDFDocument?
    try autoreleasepool {
      let context = try binding.open(database: db, paperID: id)
      retainedContext = context
      retainedDraft = try context.capture()
      admitted = binding.view.document
      binding.session.close()
    }
    let context = try XCTUnwrap(retainedContext)
    let draft = try XCTUnwrap(retainedDraft)
    XCTAssertNil(admitted)
    XCTAssertEqual(draft.paper.id, id)
    XCTAssertThrowsError(try context.capture())
    XCTAssertThrowsError(try context.createNote(draft, text: "closed draft"))
  }

  func testReentrantCaptureAndCopyRejectBeforePublishingOrPasteboardWrite() async throws {
    let (_, db, _, id, binding) = try await fixture()
    let context = try binding.open(database: db, paperID: id)
    binding.view.onSelectionRead = { binding.session.close() }
    XCTAssertThrowsError(try context.capture())
    XCTAssertFalse(context.isActive)
    let fresh = try binding.open(database: db, paperID: id)
    binding.view.onSelectionRead = { binding.session.close() }
    // The reentry barrier is before any pasteboard access, so no user clipboard is read or changed.
    XCTAssertThrowsError(try fresh.copySelection())
    XCTAssertFalse(fresh.isActive)
    XCTAssertTrue(try AnnotationService(database: db).records(for: fresh.identity).isEmpty)
  }

  func testForeignDocumentAndIdentityCannotBind() async throws {
    let (_, db, _, id, binding) = try await fixture()
    defer { binding.session.close() }
    let context = try binding.open(database: db, paperID: id)
    let document = try XCTUnwrap(binding.view.document)
    let service = AnnotationService(database: db)
    XCTAssertThrowsError(try ReaderAnnotationContext(session: binding.session, service: service,
      identity: context.identity, view: binding.view, document: PDFDocument()))
    let foreign = AnnotationPaperIdentity(id: id, generation: UUID(), pdfSHA256: context.identity.pdfSHA256)
    XCTAssertThrowsError(try ReaderAnnotationContext(session: binding.session, service: service,
      identity: foreign, view: binding.view, document: document))
    binding.view.document = PDFDocument()
    XCTAssertThrowsError(try context.capture())
    XCTAssertFalse(context.isActive)
  }

  func testInfrastructureIdentityRejectsNoncanonicalNotReadyAndMissingHash() async throws {
    let (_, db, _, id, binding) = try await fixture()
    defer { binding.session.close() }
    let identity = try db.annotationIdentity(paperID: id)
    XCTAssertEqual(identity.id, id)
    XCTAssertEqual(identity.generation, try db.readerSnapshot(paperID: id).generation)
    try db.adapterWrite { sql in
      try sql.execute(sql: "UPDATE paper SET pdfReference = '../owned.pdf' WHERE id = ?", arguments: [id.uuidString])
    }
    XCTAssertThrowsError(try db.annotationIdentity(paperID: id))
    try db.adapterWrite { sql in
      try sql.execute(sql: "UPDATE paper SET pdfReference = ?, pdfSHA256 = NULL WHERE id = ?",
        arguments: ["papers/\(id.uuidString)/document.pdf", id.uuidString])
    }
    XCTAssertThrowsError(try db.annotationIdentity(paperID: id))
    try db.adapterWrite { sql in
      try sql.execute(sql: "UPDATE paper SET pdfSHA256 = ?, status = 'importFailed' WHERE id = ?",
        arguments: [identity.pdfSHA256, id.uuidString])
    }
    XCTAssertThrowsError(try db.annotationIdentity(paperID: id))
    XCTAssertThrowsError(try db.annotationIdentity(paperID: UUID()))
  }
}
