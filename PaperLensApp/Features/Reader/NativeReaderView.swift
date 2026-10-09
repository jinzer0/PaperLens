import AppKit
import PDFKit
import SwiftUI

@MainActor final class ReaderPresentation: NSObject, ObservableObject {
  enum SearchState: Equatable { case idle, searching, matches(Int), noResults }
  let session: ReaderSession
  let pdfView = PDFView()
  @Published var pageIndex = 0
  @Published var pageCount = 0
  @Published var zoom: Double = 1
  @Published var query = ""
  @Published var searchState: SearchState = .idle
  @Published var failure: String?
  @Published var title = "Reader"
  @Published var opened = false
  @Published private(set) var annotationContext: ReaderAnnotationContext?
  @Published private(set) var metadataBinding: ReaderMetadataBinding?
  @Published private(set) var metadataFailure: String?
  private var metadataIdentity: ReaderMetadataIdentity?
  private let metadataService: ReaderMetadataService
  private let annotationIdentity: AnnotationPaperIdentity
  private let annotationService: AnnotationService
  private var matches: [PDFSelection] = []
  private var matchIndex = 0
  private var searchTask: Task<Void, Never>?
  private var searchGeneration = UUID()
  private var restoring = false

  init(session: ReaderSession, annotationIdentity: AnnotationPaperIdentity,
    annotationService: AnnotationService, metadataService: ReaderMetadataService,
    metadataIdentity: ReaderMetadataIdentity?) {
    self.session = session
    self.annotationIdentity = annotationIdentity
    self.annotationService = annotationService
    self.metadataService = metadataService
    self.metadataIdentity = metadataIdentity
    super.init()
    pdfView.displayMode = .singlePageContinuous
    pdfView.displayDirection = .vertical
    pdfView.minScaleFactor = 0.1
    pdfView.maxScaleFactor = 10
    pdfView.autoScales = false
    pdfView.setAccessibilityLabel("Original PDF. Select text using the pointer or keyboard.")
    NotificationCenter.default.addObserver(self, selector: #selector(positionChanged),
      name: .PDFViewPageChanged, object: pdfView)
    NotificationCenter.default.addObserver(self, selector: #selector(positionChanged),
      name: .PDFViewScaleChanged, object: pdfView)
    NotificationCenter.default.addObserver(self, selector: #selector(positionChanged),
      name: .PDFViewVisiblePagesChanged, object: pdfView)
  }

  func open(paperID: UUID) {
    guard !opened else { return }
    restoring = true
    defer { restoring = false }
    do {
      let position = try session.open(paperID: paperID, validateDocument: { url in
        for directory in [url.deletingLastPathComponent(),
          url.deletingLastPathComponent().deletingLastPathComponent()] {
          let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
          guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw ReaderError.invalidReference
          }
        }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
          let document = PDFDocument(url: url), !document.isLocked,
          document.pageCount > 0 else { throw ReaderError.invalidDocument }
        pdfView.document = document
        return document.pageCount
      }, discard: { [weak self] in self?.discard() })
      try session.withReadAccess {
        guard session.currentPaper?.paperID == annotationIdentity.id,
          session.currentPaper?.generation == annotationIdentity.generation,
          paperID == annotationIdentity.id else { throw AnnotationError.stalePaper }
        _ = try annotationService.records(for: annotationIdentity)
        guard let document = pdfView.document,
          let page = document.page(at: position.pageIndex) else { throw ReaderError.invalidDocument }
        pdfView.scaleFactor = CGFloat(position.zoom)
        pdfView.go(to: page)
        pageCount = document.pageCount
        pageIndex = position.pageIndex
        zoom = position.zoom
      }
      title = session.currentPaper?.title ?? "Reader"
      opened = true
      failure = nil
      mountMetadata()
    } catch {
      session.close()
      failure = "Unable to open Reader: \(error)"
    }
  }

  func discard() {
    // Detaching a PDF synchronously emits page notifications; block saves first.
    opened = false
    searchGeneration = UUID()
    searchTask?.cancel()
    searchTask = nil
    // Drain autoreleased PDFKit detach work before the real read lease is released.
    autoreleasepool {
      closeMetadata()
      closeAnnotations()
      pdfView.document?.cancelFindString()
      pdfView.clearSelection()
      pdfView.highlightedSelections = nil
      matches.removeAll()
      pdfView.document = nil
    }
    searchState = .idle
    pageCount = 0
    failure = "Reader access ended. The Paper may have been deleted or replaced."
  }

  func replaceMetadataIdentity(_ identity: ReaderMetadataIdentity?) {
    guard identity != metadataIdentity else { return }
    closeMetadata()
    closeAnnotations()
    metadataIdentity = identity
    if opened { mountMetadata() }
  }

  private func closeMetadata() {
    metadataBinding?.invalidate()
    metadataBinding = nil
    metadataFailure = nil
  }

  private func mountMetadata() {
    guard opened, let identity = metadataIdentity else {
      metadataFailure = "발행된 추출 정보가 없어 논문 정보와 목차를 사용할 수 없습니다. PDF는 계속 읽을 수 있습니다."
      return
    }
    do {
      let binding = try session.withReadAccess {
        guard let document = pdfView.document else { throw ReaderError.notOpen }
        return try ReaderMetadataBinding(session: session, service: metadataService,
          identity: identity, view: pdfView, document: document)
      }
      guard opened, binding.state != nil else { binding.invalidate(); return }
      metadataBinding = binding
      metadataFailure = nil
    } catch {
      metadataFailure = "논문 정보를 사용할 수 없습니다: \(error)"
    }
  }

  func toggleAnnotations() {
    if annotationContext != nil { closeAnnotations(); return }
    guard opened else { return }
    do {
      let context = try session.withReadAccess {
        guard let document = pdfView.document else { throw ReaderError.notOpen }
        return try ReaderAnnotationContext(session: session, service: annotationService,
          identity: annotationIdentity, view: pdfView, document: document)
      }
      guard opened, context.isActive else { context.invalidate(); return }
      annotationContext = context
    } catch { failure = "Annotations unavailable: \(error)" }
  }

  func closeAnnotations() {
    annotationContext?.invalidate()
    annotationContext = nil
  }

  @objc private func positionChanged(_ notification: Notification) {
    guard opened, !restoring else { return }
    do {
      try session.withReadAccess {
        guard let document = pdfView.document, let page = pdfView.currentPage else {
          throw ReaderError.invalidDocument
        }
        pageIndex = document.index(for: page)
        zoom = Double(pdfView.scaleFactor)
      }
      try session.save(ReaderPosition(pageIndex: pageIndex, zoom: zoom))
      failure = nil
    } catch { failure = "Reading position was not saved: \(error)" }
    // Only actual PDFKit position notifications confirm metadata navigation.
    guard opened, let binding = metadataBinding else { return }
    do { try binding.observePosition(); metadataFailure = nil }
    catch { metadataFailure = (error as? ReaderMetadataError)?.message ?? "읽기 위치 미확인" }
  }

  func navigate(delta: Int) {
    guard let target = ReaderNavigation.page(after: pageIndex, delta: delta, count: pageCount)
    else { return }
    perform {
      guard let page = pdfView.document?.page(at: target) else { throw ReaderError.invalidDocument }
      pdfView.go(to: page)
    }
  }

  func changeZoom(factor: Double) {
    perform { pdfView.scaleFactor = min(10, max(0.1, pdfView.scaleFactor * CGFloat(factor))) }
  }

  func search() {
    guard opened else { return }
    searchTask?.cancel()
    let generation = UUID()
    searchGeneration = generation
    matches.removeAll()
    matchIndex = 0
    do { try session.withReadAccess { pdfView.clearSelection() } }
    catch { failure = "Search unavailable: \(error)"; searchState = .idle; return }
    guard !query.isEmpty else { searchState = .idle; return }
    searchState = .searching
    let text = query
    searchTask = Task { @MainActor [weak self] in
      await Task.yield()
      guard let self, !Task.isCancelled, self.searchGeneration == generation else { return }
      do {
        let found = try self.session.withReadAccess {
          guard let document = self.pdfView.document else { throw ReaderError.notOpen }
          return document.findString(text, withOptions: [.caseInsensitive])
        }
        guard !Task.isCancelled, self.searchGeneration == generation else { return }
        self.matches = found
        self.searchState = found.isEmpty ? .noResults : .matches(found.count)
        if !found.isEmpty { self.showMatch(delta: 0) }
      } catch { self.failure = "Search unavailable: \(error)"; self.searchState = .idle }
    }
  }

  func showMatch(delta: Int) {
    guard !matches.isEmpty else { return }
    perform {
      matchIndex = (matchIndex + delta + matches.count) % matches.count
      let selection = matches[matchIndex]
      pdfView.setCurrentSelection(selection, animate: false)
      pdfView.go(to: selection)
    }
  }

  func leave(onReturn: () -> Void) {
    guard opened else { session.close(); onReturn(); return }
    do {
      try session.leave(at: ReaderPosition(pageIndex: pageIndex, zoom: zoom))
      onReturn()
    } catch { failure = "Cannot leave without saving: \(error). Retry or explicitly discard." }
  }

  func disappear(reportFailure: (Error) -> Void) {
    if opened {
      do { try session.save(ReaderPosition(pageIndex: pageIndex, zoom: zoom)) }
      catch { reportFailure(error) }
    }
    session.close()
  }

  private func perform(_ action: () throws -> Void) {
    do { try session.withReadAccess(action) }
    catch { failure = "Reader operation rejected: \(error)" }
  }
}

@MainActor private struct NativePDFSurface: NSViewRepresentable {
  let pdfView: PDFView
  func makeNSView(context: Context) -> PDFView { pdfView }
  func updateNSView(_ nsView: PDFView, context: Context) {}
  // ReaderPresentation exclusively discards PDF state, before session lease release.
}

/// Parent supplies the Application session bound to the real shared lifecycle.
@MainActor public struct NativeReaderView: View {
  @StateObject private var presentation: ReaderPresentation
  private let paperID: UUID
  private let metadataIdentity: ReaderMetadataIdentity?
  private let onReturn: () -> Void
  private let onSaveFailure: (Error) -> Void
  public init(paperID: UUID, session: ReaderSession,
    annotationIdentity: AnnotationPaperIdentity, annotationService: AnnotationService,
    metadataService: ReaderMetadataService, metadataIdentity: ReaderMetadataIdentity?,
    onReturn: @escaping () -> Void,
    onSaveFailure: @escaping (Error) -> Void) {
    self.paperID = paperID
    self.metadataIdentity = metadataIdentity
    self.onReturn = onReturn
    self.onSaveFailure = onSaveFailure
    _presentation = StateObject(wrappedValue: ReaderPresentation(session: session,
      annotationIdentity: annotationIdentity, annotationService: annotationService,
      metadataService: metadataService, metadataIdentity: metadataIdentity))
  }

  public var body: some View {
    VStack(spacing: 8) {
      HStack {
        Button("Library") { presentation.leave(onReturn: onReturn) }
          .accessibilityLabel("Save reading position and return to Library")
        Text(presentation.title).font(.headline)
        if presentation.opened {
          Button(presentation.annotationContext == nil ? "Highlights & Notes" : "Close annotations") {
            presentation.toggleAnnotations()
          }
        }
        Spacer()
        Button("Previous page") { presentation.navigate(delta: -1) }
          .disabled(!presentation.opened || presentation.pageIndex == 0)
          .keyboardShortcut(.leftArrow, modifiers: [.command])
        Text(presentation.pageCount == 0 ? "No page" :
          "Page \(presentation.pageIndex + 1) of \(presentation.pageCount)")
          .accessibilityLabel("Current PDF page")
        Button("Next page") { presentation.navigate(delta: 1) }
          .disabled(!presentation.opened || presentation.pageIndex + 1 >= presentation.pageCount)
          .keyboardShortcut(.rightArrow, modifiers: [.command])
        Button("Zoom out") { presentation.changeZoom(factor: 1 / 1.2) }
          .disabled(!presentation.opened || presentation.zoom <= 0.1)
          .keyboardShortcut("-", modifiers: [.command])
        Text("\(Int(presentation.zoom * 100))%")
        Button("Zoom in") { presentation.changeZoom(factor: 1.2) }
          .disabled(!presentation.opened || presentation.zoom >= 10)
          .keyboardShortcut("+", modifiers: [.command])
      }
      HStack {
        TextField("Search original PDF text", text: $presentation.query)
          .onSubmit { presentation.search() }
          .accessibilityLabel("Search PDF text")
        Button("Search") { presentation.search() }.disabled(!presentation.opened)
        switch presentation.searchState {
        case .idle: EmptyView()
        case .searching: ProgressView("Searching")
        case .noResults: Text("No results").accessibilityLabel("No PDF text search results")
        case .matches(let count):
          Text("\(count) matches")
          Button("Previous match") { presentation.showMatch(delta: -1) }
          Button("Next match") { presentation.showMatch(delta: 1) }
        }
      }.disabled(!presentation.opened)
      if let failure = presentation.failure {
        HStack {
          Text(failure).foregroundStyle(.red).textSelection(.enabled)
          Button("Discard and return") { presentation.session.close(); onReturn() }
        }
      }
      HStack(spacing: 0) {
        NativePDFSurface(pdfView: presentation.pdfView)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        Divider()
        VStack(alignment: .leading) {
          if let binding = presentation.metadataBinding {
            MetadataOutlineView(binding: binding)
          }
          if let failure = presentation.metadataFailure {
            Text(failure).foregroundStyle(.secondary).padding().textSelection(.enabled)
          }
        }.frame(width: 300)
        if let context = presentation.annotationContext {
          Divider()
          AnnotationInspector(context: context, onClose: { presentation.closeAnnotations() })
            .frame(width: 340)
        }
      }
    }
    .padding()
    .onAppear { presentation.open(paperID: paperID) }
    .onChange(of: metadataIdentity) { presentation.replaceMetadataIdentity(metadataIdentity) }
    .onDisappear { presentation.disappear(reportFailure: onSaveFailure) }
  }
}
