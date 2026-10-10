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
  @Published private(set) var annotationFeedback = ""
  private var annotationGeneration = UUID()
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
    pdfView.setAccessibilityLabel("원본 PDF. 포인터 또는 키보드로 텍스트를 선택할 수 있습니다.")
    NotificationCenter.default.addObserver(self, selector: #selector(positionChanged),
      name: .PDFViewPageChanged, object: pdfView)
    NotificationCenter.default.addObserver(self, selector: #selector(positionChanged),
      name: .PDFViewScaleChanged, object: pdfView)
    NotificationCenter.default.addObserver(self, selector: #selector(positionChanged),
      name: .PDFViewVisiblePagesChanged, object: pdfView)
  }

  func open(paperID: UUID) {
    guard !opened, !restoring else { return }
    restoring = true
    defer { restoring = false }
    enum RestorationInterrupted: Error { case admissionChanged }
    weak var admittedDocument: PDFDocument?
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
        admittedDocument = document
        pdfView.document = document
        return document.pageCount
      }, discard: { [weak self] in self?.discard() })
      guard case .admitted(let admittedUUID) = session.admissionState else {
        throw ReaderError.notOpen
      }
      // Admission identity is an interruption fence, never a substitute for the pin.
      func checkpoint() throws {
        guard session.admissionState == .admitted(admittedUUID) else {
          throw RestorationInterrupted.admissionChanged
        }
      }
      func step(_ effect: (PDFDocument) throws -> Void) throws {
        try checkpoint()
        try session.withReadAccess {
          try checkpoint()
          guard let document = pdfView.document, document === admittedDocument else {
            throw ReaderError.invalidDocument
          }
          try effect(document)
          try checkpoint()
        }
        try checkpoint()
      }
      try step { _ in
        guard session.currentPaper?.paperID == annotationIdentity.id,
          session.currentPaper?.generation == annotationIdentity.generation,
          paperID == annotationIdentity.id else { throw AnnotationError.stalePaper }
        _ = try annotationService.records(for: annotationIdentity)
      }
      try step { _ in pdfView.scaleFactor = CGFloat(position.zoom) }
      try step { document in
        guard let page = document.page(at: position.pageIndex) else {
          throw ReaderError.invalidDocument
        }
        try checkpoint()
        pdfView.go(to: page)
      }
      try step { document in pageCount = document.pageCount }
      try step { _ in pageIndex = position.pageIndex }
      try step { _ in zoom = position.zoom }
      try step { _ in title = session.currentPaper?.title ?? "Reader" }
      try step { _ in opened = true }
      try step { _ in failure = nil }
      try step { _ in mountMetadata() }
    } catch is RestorationInterrupted {
      // Published setters finish after their callbacks; repair any late stale write.
      discard()
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
      metadataFailure = "논문 정보와 목차를 사용할 수 없습니다. PDF는 계속 읽을 수 있습니다."
    }
  }

  func toggleAnnotations() {
    if annotationContext != nil { closeAnnotations(); return }
    annotationAction { _ in () }
  }

  func highlightSelection() {
    annotationAction { _ = try $0.highlightSelection() }
  }

  func addNote() {
    annotationAction { try $0.beginNote() }
  }

  func copySelection() {
    annotationAction(mountDrawer: false) { try $0.copyOriginalSelection() }
  }

  // Construct lazily from the actual admitted PDF, never from selection heuristics.
  private func actualAnnotationContext() throws -> ReaderAnnotationContext {
    try session.withReadAccess {
      guard opened else { throw ReaderError.notOpen }
      if let context = annotationContext {
        _ = try context.records()
        guard opened, context.isActive else { throw AnnotationError.stalePaper }
        return context
      }
      guard let document = pdfView.document else { throw ReaderError.notOpen }
      let context = try ReaderAnnotationContext(session: session, service: annotationService,
        identity: annotationIdentity, view: pdfView, document: document)
      guard opened, context.isActive else {
        context.invalidate(); throw AnnotationError.stalePaper
      }
      return context
    }
  }

  private func annotationAction(mountDrawer: Bool = true,
    _ action: (ReaderAnnotationContext) throws -> Void) {
    guard opened else { return }
    let generation = annotationGeneration
    var candidate: ReaderAnnotationContext?
    defer {
      if let candidate, annotationContext !== candidate { candidate.invalidate() }
    }
    do {
      let context = try actualAnnotationContext()
      candidate = context
      guard opened, annotationGeneration == generation, context.isActive else { return }
      let succeeded = context.performEditorAction { try action(context) }
      guard opened, annotationGeneration == generation, context.isActive else { return }
      if mountDrawer && succeeded && annotationContext == nil {
        annotationContext = context
        // A Published subscriber can close the drawer before the setter completes.
        guard opened, annotationGeneration == generation, context.isActive else {
          context.invalidate()
          if annotationContext === context { annotationContext = nil }
          return
        }
      }
      annotationFeedback = context.editor.feedback
      if !opened || annotationGeneration != generation || !context.isActive {
        annotationFeedback = ""
      }
    } catch {
      guard opened, annotationGeneration == generation else { return }
      annotationFeedback = ReaderAnnotationContext.message(for: error)
      if !opened || annotationGeneration != generation { annotationFeedback = "" }
    }
  }

  func closeAnnotations() {
    annotationGeneration = UUID()
    annotationContext?.invalidate()
    annotationContext = nil
    annotationFeedback = ""
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
    catch {
      guard opened, searchGeneration == generation else { return }
      failure = "Search unavailable: \(error)"; searchState = .idle; return
    }
    guard opened, searchGeneration == generation else { return }
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
        guard !Task.isCancelled, self.opened, self.searchGeneration == generation else { return }
        self.matches = found
        self.searchState = found.isEmpty ? .noResults : .matches(found.count)
        if !found.isEmpty { self.showMatch(delta: 0) }
      } catch {
        guard !Task.isCancelled, self.opened, self.searchGeneration == generation else { return }
        self.failure = "Search unavailable: \(error)"; self.searchState = .idle
      }
    }
  }

  func showMatch(delta: Int) {
    guard !matches.isEmpty else { return }
    let generation = searchGeneration
    do {
      try session.withReadAccess {
        guard opened, searchGeneration == generation, !matches.isEmpty else { return }
        guard let document = pdfView.document else { throw ReaderError.notOpen }
        matchIndex = (matchIndex + delta + matches.count) % matches.count
        let selection = matches[matchIndex]
        pdfView.setCurrentSelection(selection, animate: false)
        // Selection notifications can synchronously discard or replace this search.
        guard opened, searchGeneration == generation, pdfView.document === document else { return }
        try session.withReadAccess {
          guard opened, searchGeneration == generation, pdfView.document === document else { return }
          pdfView.go(to: selection)
        }
      }
    } catch {
      guard opened, searchGeneration == generation else { return }
      failure = "Reader operation rejected: \(error)"
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
  private enum AnnotationOpener: Hashable { case browse, highlight, note, copy }
  @FocusState private var annotationFocus: AnnotationOpener?
  @State private var annotationOrigin: AnnotationOpener = .browse
  private let paperID: UUID
  private let metadataIdentity: ReaderMetadataIdentity?
  private let parsingStatus: ParsingStatusView
  private let onReturn: () -> Void
  private let onSaveFailure: (Error) -> Void
  public init(paperID: UUID, session: ReaderSession,
    annotationIdentity: AnnotationPaperIdentity, annotationService: AnnotationService,
    metadataService: ReaderMetadataService, metadataIdentity: ReaderMetadataIdentity?,
    parsingStatus: ParsingStatusView,
    onReturn: @escaping () -> Void,
    onSaveFailure: @escaping (Error) -> Void) {
    self.paperID = paperID
    self.metadataIdentity = metadataIdentity
    self.parsingStatus = parsingStatus
    self.onReturn = onReturn
    self.onSaveFailure = onSaveFailure
    _presentation = StateObject(wrappedValue: ReaderPresentation(session: session,
      annotationIdentity: annotationIdentity, annotationService: annotationService,
      metadataService: metadataService, metadataIdentity: metadataIdentity))
  }

  public var body: some View {
    VStack(spacing: 8) {
      HStack {
        Button("Library로 돌아가기") { presentation.leave(onReturn: onReturn) }
          .accessibilityLabel("읽기 위치를 저장하고 Library로 돌아가기")
        Text(presentation.title).font(.headline).lineLimit(1).help(presentation.title)
        if presentation.opened {
          Button(presentation.annotationContext == nil ? "하이라이트·노트" : "주석 닫기") {
            if presentation.annotationContext == nil { annotationOrigin = .browse }
            presentation.toggleAnnotations()
          }
          .focused($annotationFocus, equals: .browse)
          .accessibilityLabel(presentation.annotationContext == nil ?
            "저장된 하이라이트와 노트 보기" : "하이라이트와 노트 닫기")
          .accessibilityHint("현재 PDF 읽기 위치를 유지합니다")
        }
        Spacer()
      }
      ViewThatFits(in: .horizontal) {
        HStack { pageNavigation; Spacer(); zoomControls }
        VStack(alignment: .leading, spacing: 8) { pageNavigation; zoomControls }
      }
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          TextField("원본 PDF 텍스트 검색", text: $presentation.query)
            .onSubmit { presentation.search() }
            .accessibilityLabel("원본 PDF 텍스트 검색")
          Button("검색") { presentation.search() }.disabled(!presentation.opened)
        }
        HStack {
          switch presentation.searchState {
          case .idle: EmptyView()
          case .searching: ProgressView("PDF 검색 중")
          case .noResults: Text("검색 결과 없음").accessibilityLabel("원본 PDF 텍스트 검색 결과 없음")
          case .matches(let count):
            Text("검색 결과 \(count)개")
            Button("이전 결과") { presentation.showMatch(delta: -1) }
            Button("다음 결과") { presentation.showMatch(delta: 1) }
          }
        }
      }.disabled(!presentation.opened)
      if presentation.opened {
        HStack {
          Button("하이라이트") {
            annotationOrigin = .highlight
            presentation.highlightSelection()
          }
          .focused($annotationFocus, equals: .highlight)
          .accessibilityLabel("선택한 원본 PDF 텍스트에 하이라이트 추가")
          .accessibilityHint("하이라이트를 저장하고 저장된 주석을 표시합니다")
          Button("노트 추가") {
            annotationOrigin = .note
            presentation.addNote()
          }
          .focused($annotationFocus, equals: .note)
          .accessibilityLabel("선택한 원본 PDF 텍스트에 개인 노트 추가")
          .accessibilityHint("원본 선택으로 노트 편집기를 열고 작성 중인 노트를 유지합니다")
          Button("복사") {
            if presentation.annotationContext != nil { annotationOrigin = .copy }
            presentation.copySelection()
          }
          .focused($annotationFocus, equals: .copy)
          .accessibilityLabel("선택한 원본 PDF 텍스트 복사")
          .accessibilityHint("주석을 저장하거나 노트를 열지 않고 원본 텍스트만 복사합니다")
          Text(presentation.annotationFeedback).font(.caption)
            .accessibilityLabel("주석 상태: \(presentation.annotationFeedback)")
          Spacer()
        }.accessibilityElement(children: .contain)
      }
      if presentation.failure != nil {
        HStack {
          Label("작업을 완료하지 못했습니다. 돌아가기를 시도하거나 저장하지 않고 돌아가세요.", systemImage: "exclamationmark.triangle")
            .foregroundStyle(.red).textSelection(.enabled)
          Button("저장하지 않고 돌아가기") { presentation.session.close(); onReturn() }
        }
      }
      HSplitView {
        NativePDFSurface(pdfView: presentation.pdfView)
          .frame(minWidth: 240, maxWidth: .infinity, maxHeight: .infinity)
        VStack(alignment: .leading) {
          parsingStatus.padding(12)
          if presentation.metadataBinding != nil || presentation.metadataFailure != nil {
            Divider()
          }
          if let binding = presentation.metadataBinding {
            MetadataOutlineView(binding: binding)
          }
          if let failure = presentation.metadataFailure {
            Label(failure, systemImage: "exclamationmark.triangle")
              .foregroundStyle(.secondary).padding().textSelection(.enabled)
          }
        }
        .frame(minWidth: 240, idealWidth: 320, maxWidth: 480, maxHeight: .infinity, alignment: .topLeading)
        if let context = presentation.annotationContext {
          AnnotationInspector(context: context, onClose: { presentation.closeAnnotations() })
            .frame(minWidth: 240, idealWidth: 340, maxWidth: 480, maxHeight: .infinity)
        }
      }
    }
    .padding()
    .onAppear { presentation.open(paperID: paperID) }
    .onChange(of: metadataIdentity) { presentation.replaceMetadataIdentity(metadataIdentity) }
    .onChange(of: presentation.annotationContext != nil) {
      if presentation.annotationContext == nil && presentation.opened {
        annotationFocus = annotationOrigin
      }
    }
    .onDisappear { presentation.disappear(reportFailure: onSaveFailure) }
  }

  private var pageNavigation: some View {
    HStack {
      Button("이전 페이지") { presentation.navigate(delta: -1) }
        .disabled(!presentation.opened || presentation.pageIndex == 0)
        .keyboardShortcut(.leftArrow, modifiers: [.command])
      Text(presentation.pageCount == 0 ? "페이지 없음" :
        "\(presentation.pageIndex + 1) / \(presentation.pageCount)쪽")
        .accessibilityLabel("현재 PDF 페이지")
      Button("다음 페이지") { presentation.navigate(delta: 1) }
        .disabled(!presentation.opened || presentation.pageIndex + 1 >= presentation.pageCount)
        .keyboardShortcut(.rightArrow, modifiers: [.command])
    }
  }

  private var zoomControls: some View {
    HStack {
      Button("축소") { presentation.changeZoom(factor: 1 / 1.2) }
        .disabled(!presentation.opened || presentation.zoom <= 0.1)
        .keyboardShortcut("-", modifiers: [.command])
      Text("\(Int(presentation.zoom * 100))%")
        .accessibilityLabel("PDF 확대 비율")
      Button("확대") { presentation.changeZoom(factor: 1.2) }
        .disabled(!presentation.opened || presentation.zoom >= 10)
        .keyboardShortcut("+", modifiers: [.command])
    }
  }
}
