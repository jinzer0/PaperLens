import SwiftUI

@MainActor
public struct LibraryBrowserView: View {
  private let service: LibraryOrganizationService
  private let folderService: FolderImportService
  private let sortFacts: @Sendable () async throws -> [OrganizationSortFacts]
  private let readReadingRecords: @Sendable (UUID, UUID) async throws -> LibraryReadingRecords
  private let openPaper: @MainActor (OrganizedPaper) async throws -> Void
  private let importPDF: @MainActor () -> Void
  private let retryImportPDF: @MainActor (UUID, UUID) -> Void
  private let manageFolders: @MainActor () -> Void
  private let refreshRevision: Int
  @State private var query = OrganizationQueryState()
  @State private var currentFacts: [UUID: OrganizationSortFacts] = [:]
  @State private var folders: [LibraryFolder] = []
  @State private var folderLoadFailed = false
  @State private var tags: [String] = []
  @State private var tagLoadFailed = false
  @Binding private var filter: OrganizationFilter
  @State private var operationFailed = false
  @State private var busy = false
  @State private var deleting: OrganizedPaper?
  @State private var rootMount: UUID?
  @State private var sheetPresentation: LibrarySheetPresentation?
  @State private var organizationFocusToRestore: (paperID: UUID, generation: UUID, control: OrganizationControlFocus)?
  @FocusState private var organizationFocus: OrganizationControlFocus?
  @FocusState private var focusedPaper: UUID?
  @FocusState private var focusedIdentification: UUID?
  @FocusState private var focusedMovement: UUID?
  private var snapshot: OrganizationSnapshot? { query.snapshot }
  private var loading: Bool { query.loading }
  private var loadFailed: Bool { query.failed }

  public init(service: LibraryOrganizationService, folderService: FolderImportService,
    filter: Binding<OrganizationFilter>, refreshRevision: Int,
    sortFacts: @escaping @Sendable () async throws -> [OrganizationSortFacts],
    readReadingRecords: @escaping @Sendable (UUID, UUID) async throws -> LibraryReadingRecords,
    openPaper: @escaping @MainActor (OrganizedPaper) async throws -> Void,
    importPDF: @escaping @MainActor () -> Void,
    retryImportPDF: @escaping @MainActor (UUID, UUID) -> Void,
    manageFolders: @escaping @MainActor () -> Void) {
    self.service = service; self.folderService = folderService; self.sortFacts = sortFacts
    self.readReadingRecords = readReadingRecords
    _filter = filter; self.refreshRevision = refreshRevision
    self.openPaper = openPaper; self.importPDF = importPDF
    self.retryImportPDF = retryImportPDF
    self.manageFolders = manageFolders
  }

  private var folderHeading: String {
    switch filter.folder {
    case .all: return "전체 논문"
    case .unfiled: return "미분류"
    case .folder(let id):
      return folders.first(where: { $0.id == id })?.name ?? "확인할 수 없는 폴더 · \(id.uuidString)"
    }
  }

  private var selectedFolderUnavailable: Bool {
    guard case .folder(let id) = filter.folder else { return false }
    return !folders.contains(where: { $0.id == id })
  }

  private var clearedConditions: OrganizationFilter {
    var value = OrganizationFilter()
    value.folder = filter.folder
    return value
  }

  private var libraryContent: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Library").font(.largeTitle)
        Spacer()
        Button("PDF 추가", action: requestImport)
          .focused($organizationFocus, equals: .importPDF)
        Button("새로고침", action: requestRefresh).disabled(busy)
          .focused($organizationFocus, equals: .refresh)
      }
      Text(folderHeading).font(.title2).textSelection(.enabled)
      TextField("제목 또는 사용자 태그 검색", text: $filter.search)
        .textFieldStyle(.roundedBorder)
        .accessibilityLabel("라이브러리 제목 또는 사용자 태그 검색")
        .focused($organizationFocus, equals: .search)
      if let snapshot {
        HStack {
          Picker("표시", selection: Binding(get: { snapshot.preferences.presentation }, set: { value in
            var preference = snapshot.preferences; preference.presentation = value
            savePreferences(preference)
          })) {
            Text("목록").tag(LibraryPresentation.list)
            Text("카드").tag(LibraryPresentation.grid)
          }.pickerStyle(.segmented)
            .focused($organizationFocus, equals: .presentation)
          Picker("정렬", selection: Binding(get: { snapshot.preferences.sort }, set: { value in
            var preference = snapshot.preferences; preference.sort = value
            savePreferences(preference)
          })) {
            Text("최근 읽음").tag(LibrarySort.recentlyRead)
            Text("이름").tag(LibrarySort.name)
            Text("최근 추가").tag(LibrarySort.recentlyAdded)
            Text("발행연도").tag(LibrarySort.publicationYear)
          }.focused($organizationFocus, equals: .sort)
        }.disabled(busy || loading)
      }
      if loadFailed {
        ContentUnavailableView("불러오기 실패", systemImage: "exclamationmark.triangle",
          description: Text("저장된 값을 확인할 수 없습니다. 다시 불러오세요."))
        Button("다시 불러오기", action: requestRefresh).disabled(busy)
          .focused($organizationFocus, equals: .retryLibrary)
      } else if loading {
        ProgressView("라이브러리 불러오는 중")
      } else if selectedFolderUnavailable {
        ContentUnavailableView("선택한 폴더를 확인할 수 없습니다", systemImage: "folder.badge.questionmark",
          description: Text(folderLoadFailed
            ? "폴더 목록을 불러오지 못했습니다. 선택은 유지됩니다. 다시 불러오세요."
            : "이 UUID의 폴더가 현재 목록에 없습니다. 다른 폴더를 직접 선택하거나 폴더 관리에서 확인하세요."))
        Button("폴더 관리", action: requestManageFolders).disabled(busy)
          .focused($organizationFocus, equals: .manageUnavailableFolder)
      } else if let snapshot {
        if snapshot.totalCount == 0 {
          ContentUnavailableView("아직 논문이 없습니다", systemImage: "books.vertical",
            description: Text("PDF 추가로 시작하세요."))
          Button("PDF 추가", action: requestImport)
            .focused($organizationFocus, equals: .importEmpty)
        } else if snapshot.papers.isEmpty {
          ContentUnavailableView("일치하는 논문 없음", systemImage: "line.3.horizontal.decrease.circle",
            description: Text("저장된 논문은 있습니다. 검색과 필터를 변경하세요."))
          Button("검색·조건 지우기") { filter = clearedConditions }
            .focused($organizationFocus, equals: .clearNoMatch)
        } else if snapshot.preferences.presentation == .list {
          List(snapshot.papers) { paper in paperContent(paper) }
        } else {
          ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), alignment: .top)]) {
              ForEach(snapshot.papers) { paper in
                paperContent(paper).padding().background(.background, in: RoundedRectangle(cornerRadius: 8))
                  .overlay(RoundedRectangle(cornerRadius: 8).stroke(.secondary.opacity(0.3)))
              }
            }
          }
        }
      }
    }
  }

  private var filterSidebar: some View {
    ScrollView {
    VStack(alignment: .leading, spacing: 16) {
      Text("폴더").font(.headline)
      folderControl("전체 논문", selection: .all)
      folderControl("미분류", selection: .unfiled)
      if loading {
        ProgressView("폴더 불러오는 중")
      } else if folderLoadFailed || loadFailed {
        Text("폴더 목록을 불러오지 못했습니다.").font(.caption)
        Button("폴더 다시 불러오기", action: requestRefresh).disabled(busy)
          .focused($organizationFocus, equals: .retryFolders)
      } else if folders.isEmpty {
        Text("저장된 폴더가 없습니다.").font(.caption).foregroundStyle(.secondary)
      } else {
        ForEach(folders) { folder in
          folderControl(folder.name, selection: .folder(folder.id))
        }
      }
      if selectedFolderUnavailable, case .folder(let id) = filter.folder {
        Text("선택 유지 · \(id.uuidString)").font(.caption).textSelection(.enabled)
      }
      Button("폴더 관리", action: requestManageFolders).disabled(busy)
        .focused($organizationFocus, equals: .manageFolders)
      Divider()
      Text("필터").font(.headline)
      Toggle("즐겨찾기만", isOn: $filter.favoritesOnly)
        .focused($organizationFocus, equals: .favoritesFilter)
      Picker("읽기 상태", selection: $filter.readingStatus) {
        Text("전체").tag(Optional<PaperReadingStatus>.none)
        ForEach(PaperReadingStatus.allCases, id: \.self) { status in
          Text(readingLabel(status)).tag(Optional(status))
        }
      }.pickerStyle(.radioGroup)
        .focused($organizationFocus, equals: .readingFilter)
      Divider()
      Text("사용자 태그").font(.headline)
      tagControl("전체 태그", selection: nil)
      if loading {
        ProgressView("저장된 태그 불러오는 중")
      } else if tagLoadFailed || loadFailed {
        Text("저장된 태그를 불러오지 못했습니다. 선택은 유지됩니다.").font(.caption)
        Button("태그 다시 불러오기", action: requestRefresh).disabled(busy)
          .focused($organizationFocus, equals: .retryTags)
      } else if tags.isEmpty {
        Text("저장된 사용자 태그가 없습니다.").font(.caption).foregroundStyle(.secondary)
      } else {
        ForEach(tags, id: \.self) { tag in
          tagControl(tag, selection: tag)
        }
      }
      if let selectedTag = filter.tag {
        Text("현재 태그 · \(selectedTag)").font(.caption).textSelection(.enabled)
        if !loading, !loadFailed, !tagLoadFailed,
          !tags.contains(where: { tagIsSelected($0) }) {
          Text("현재 저장된 태그 목록에 없는 선택입니다. 조건은 유지됩니다.")
            .font(.caption).foregroundStyle(.secondary)
        }
      }
      TextField("태그 필터 (정확한 이름)", text: Binding(
        get: { filter.tag ?? "" }, set: { filter.tag = $0.isEmpty ? nil : $0 }))
        .textFieldStyle(.roundedBorder)
        .accessibilityLabel("정확한 사용자 태그로 필터")
        .focused($organizationFocus, equals: .exactTag)
      Text("제목·태그 검색과 함께 적용됩니다. 출처 주제는 사용자 태그가 아닙니다.")
        .font(.caption).foregroundStyle(.secondary)
      Button("검색·조건 지우기") { filter = clearedConditions }
        .disabled(filter == clearedConditions)
        .focused($organizationFocus, equals: .clearConditions)
      Spacer()
    }
    .padding(12)
    }
    .frame(minWidth: 180, idealWidth: 220, maxWidth: 300, maxHeight: .infinity, alignment: .topLeading)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("라이브러리 필터 사이드바")
  }

  private func folderControl(_ title: String, selection: LibraryFolderSelection) -> some View {
    let focus: OrganizationControlFocus
    switch selection {
    case .all: focus = .allFolders
    case .unfiled: focus = .unfiled
    case .folder(let id): focus = .folder(id)
    }
    return Button { filter.folder = selection } label: {
      HStack {
        Text(title).multilineTextAlignment(.leading)
        Spacer()
        if filter.folder == selection { Image(systemName: "checkmark") }
      }.frame(maxWidth: .infinity, alignment: .leading)
    }
    .disabled(busy)
    .focused($organizationFocus, equals: focus)
    .accessibilityValue(filter.folder == selection ? "선택됨" : "선택되지 않음")
  }

  private func tagIsSelected(_ tag: String?) -> Bool {
    guard let tag, let selected = filter.tag else { return tag == nil && filter.tag == nil }
    return LibraryOrganizationService.normalized(tag) == LibraryOrganizationService.normalized(selected)
  }

  private func tagControl(_ title: String, selection: String?) -> some View {
    Button { filter.tag = selection } label: {
      HStack {
        Text(title).multilineTextAlignment(.leading)
        Spacer()
        if tagIsSelected(selection) { Image(systemName: "checkmark") }
      }.frame(maxWidth: .infinity, alignment: .leading)
    }
    .disabled(busy)
    .focused($organizationFocus, equals: .tag(selection))
    .accessibilityValue(tagIsSelected(selection) ? "선택됨" : "선택되지 않음")
  }

  public var body: some View {
    HSplitView {
      filterSidebar
      libraryContent.frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    .padding()
    .onAppear {
      rootMount = UUID()
      if sheetPresentation?.slot.content.isTagEditor == true { sheetPresentation = nil }
      refresh()
    }
    .onDisappear {
      rootMount = nil
      if sheetPresentation?.slot.content.isTagEditor == true { sheetPresentation = nil }
      invalidateObservation()
    }
    .onChange(of: refreshRevision) { _, _ in refresh() }
    .onChange(of: filter) { _, _ in refresh() }
    .onChange(of: organizationFocus) { _, value in
      if value != nil { interruptSheetReturn(newerWork: false) }
    }
    .onChange(of: focusedPaper) { _, value in
      if let value, sheetPresentation?.slot.content.isTagEditor != true
        || value != sheetPresentation?.slot.paper.id { interruptSheetReturn(newerWork: false) }
    }
    .onChange(of: focusedIdentification) { _, value in
      if let value, sheetPresentation?.slot.content.isIdentification != true
        || value != sheetPresentation?.slot.paper.id { interruptSheetReturn(newerWork: false) }
    }
    .onChange(of: focusedMovement) { _, value in
      if let value, sheetPresentation?.slot.content.isMovement != true
        || value != sheetPresentation?.slot.paper.id { interruptSheetReturn(newerWork: false) }
    }
    .onChange(of: operationFailed) { _, value in
      if value { interruptSheetReturn(newerWork: true) }
    }
    .onChange(of: loading) { _, value in
      if !value, let opener = organizationFocusToRestore {
        if organizationFocus == nil || organizationFocus == opener.control {
          organizationFocus = !loadFailed && snapshot?.papers.contains(where: {
            $0.id == opener.paperID && $0.generation == opener.generation
          }) == true ? opener.control : .search
        }
        organizationFocusToRestore = nil
      }
    }
    .alert("논문을 영구 삭제하시겠습니까?",
      isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { paper in
        Button("삭제", role: .destructive) { deleting = nil; perform { try await service.delete(paper, retry: false) } }
        Button("취소", role: .cancel) { deleting = nil; focusedPaper = paper.id }
      } message: { paper in
        Text("‘\(paper.title)’의 앱 소유 PDF와 읽기 위치·주석·조직 기록을 삭제합니다. 원본 파일은 유지되며 이 작업은 되돌릴 수 없습니다.")
      }
    .alert("저장 또는 작업 실패", isPresented: $operationFailed) {
      Button("확인", role: .cancel) {}
    } message: { Text("성공으로 저장되지 않았습니다. 새로 불러온 현재 상태를 확인하세요.") }
    .background {
      if let presentation = sheetPresentation {
        sheetPresenter(presentation.slot).id(presentation.slot.id)
      }
    }
  }

  @ViewBuilder private func paperContent(_ paper: OrganizedPaper) -> some View {
    let fact = currentFacts[paper.id].flatMap { $0.generation == paper.generation ? $0 : nil }
    VStack(alignment: .leading, spacing: 8) {
      Text(paper.title).font(.headline).textSelection(.enabled)
      Text("출처 제목 · \(LibraryMetadataPresentation.preview(fact?.metadata?.title, limit: 160))")
        .font(.caption).textSelection(.enabled)
      Text(statusLabel(paper)).font(.caption)
      Text("\(readingLabel(paper.organization.readingStatus)) · \(paper.organization.favorite ? "즐겨찾기" : "즐겨찾기 아님")")
      HStack {
        Toggle("즐겨찾기", isOn: Binding(get: { paper.organization.favorite }, set: { selected in
          var value = paper.organization
          value.favorite = selected
          saveOrganization(value, for: paper, origin: .favorite(paper.id))
        }))
        .toggleStyle(.button)
        .focused($organizationFocus, equals: .favorite(paper.id))
        .accessibilityLabel("\(paper.title) 즐겨찾기")
        .accessibilityValue(paper.organization.favorite ? "설정됨" : "설정되지 않음")
        Menu("읽기 상태 · \(readingLabel(paper.organization.readingStatus))") {
          ForEach(PaperReadingStatus.allCases, id: \.self) { status in
            Button {
              var value = paper.organization
              value.readingStatus = status
              saveOrganization(value, for: paper, origin: .reading(paper.id))
            } label: {
              if status == paper.organization.readingStatus {
                Label(readingLabel(status), systemImage: "checkmark")
              } else { Text(readingLabel(status)) }
            }
          }
        }
        .focused($organizationFocus, equals: .reading(paper.id))
        .accessibilityLabel("\(paper.title) 읽기 상태 변경")
        .accessibilityValue(readingLabel(paper.organization.readingStatus))
      }.disabled(!paper.readable || busy || loading || loadFailed)
      if !paper.organization.tags.isEmpty { Text(paper.organization.tags.joined(separator: " · ")).font(.caption) }
      if fact?.metadata?.year.isConflict == true {
        Text("발행연도 출처 간 충돌 · 상세에서 후보 확인").font(.caption)
      } else if let year = fact?.publicationYear { Text("발행연도 \(String(year))").font(.caption) }
      else if let year = fact?.metadata?.year, !year.candidates.isEmpty {
        Text("발행연도 미확인 · \(LibraryMetadataPresentation.preview(year, limit: 80))")
          .font(.caption)
      }
      else { Text("발행연도 정보 없음").font(.caption).foregroundStyle(.secondary) }
      if let date = fact?.lastReadAt {
        Text("최근 읽음 \(date.formatted())").font(.caption)
      }
      LibraryStoredSummary(paper: paper, observation: fact?.summary, showEvidence: false)
      Text("초록 · \(LibraryMetadataPresentation.preview(fact?.metadata?.abstract, limit: 220))")
        .font(.caption).textSelection(.enabled)
      Text("출처 주제 (사용자 태그 아님) · \(LibraryMetadataPresentation.preview(fact?.metadata?.topics, limit: 120))")
        .font(.caption).textSelection(.enabled)
      if paper.status == .importing { ProgressView(); Text("\(paper.bytesCopied) bytes 복사됨") }
      HStack {
        Button("열기") { perform { try await service.admitOpen(paper); try await openPaper(paper) } }
          .disabled(!paper.readable || busy)
          .focused($organizationFocus, equals: .open(paper.id))
          .accessibilityLabel("\(paper.title) 열기")
        Button("논문 정보·요약·읽기 기록 상세") {
          beginIdentification(paper)
        }.disabled(busy || loading || loadFailed)
          .focused($focusedIdentification, equals: paper.id)
          .accessibilityLabel("\(paper.title) 출처 제목·발행연도·요약·초록·출처 주제·저장된 읽기 기록 상세")
        Button("폴더 이동") {
          beginMovement(paper)
        }.disabled(!paper.readable || busy || loading || loadFailed)
          .focused($focusedMovement, equals: paper.id)
          .accessibilityLabel("\(paper.title) 폴더 이동")
        Menu("더 보기") {
          if paper.status == .importFailed {
            Button("새 PDF 선택 후 같은 작업 재시도") { requestRetry(paper) }
              .disabled(busy || loading || loadFailed)
          }
          Button("태그·읽기 상태·즐겨찾기 편집") {
            beginTagEdit(paper)
          }.disabled(!paper.readable)
          if paper.status == .deletionFailed {
            Button("삭제 다시 시도") { perform { try await service.delete(paper, retry: true) } }
          } else {
            Button("삭제", role: .destructive) {
              guard !nativeSheetPending, !busy else { return }
              interruptSheetReturn(newerWork: true)
              deleting = paper
            }.disabled(paper.status == .deleting)
          }
        }.disabled(busy).focused($focusedPaper, equals: paper.id)
          .accessibilityLabel("\(paper.title) 더 보기")
      }
    }.accessibilityElement(children: .contain)
  }
  private var nativeSheetPending: Bool {
    sheetPresentation.map { !$0.nativeDismissConsumed } ?? false
  }

  private func renderedPaperControls(for paper: OrganizedPaper) -> Bool {
    guard !busy, !loading, !loadFailed, !selectedFolderUnavailable, let snapshot else { return false }
    return snapshot.totalCount > 0
      && snapshot.papers.contains(where: { $0.id == paper.id && $0.generation == paper.generation })
  }

  private func beginTagEdit(_ paper: OrganizedPaper) {
    guard !nativeSheetPending, let mountID = rootMount, !busy, !loading, !loadFailed,
      paper.readable, renderedPaperControls(for: paper),
      deleting == nil, !operationFailed else { return }
    interruptSheetReturn(newerWork: true)
    guard sheetPresentation == nil else { return }
    let slot = LibrarySheetSlot(mountID: mountID, content: .tagEditor(paper),
      filter: filter, refreshRevision: refreshRevision)
    organizationFocusToRestore = nil
    sheetPresentation = LibrarySheetPresentation(slot: slot)
    invalidateObservation(preservingEditor: slot.id)
  }

  private func beginIdentification(_ paper: OrganizedPaper) {
    guard !nativeSheetPending, let mountID = rootMount, !busy, !loading, !loadFailed,
      renderedPaperControls(for: paper), deleting == nil, !operationFailed,
      let accepted = snapshot?.papers.first(where: {
        $0.id == paper.id && $0.generation == paper.generation
      }) else { return }
    interruptSheetReturn(newerWork: true)
    guard sheetPresentation == nil else { return }
    let fact = currentFacts[accepted.id].flatMap { $0.generation == accepted.generation ? $0 : nil }
    let captured = LibraryIdentification(paper: accepted, metadata: fact?.metadata, summary: fact?.summary)
    let slot = LibrarySheetSlot(mountID: mountID, content: .identification(captured),
      filter: filter, refreshRevision: refreshRevision)
    organizationFocusToRestore = nil
    sheetPresentation = LibrarySheetPresentation(slot: slot)
  }

  private func beginMovement(_ paper: OrganizedPaper) {
    guard !nativeSheetPending, let mountID = rootMount, !busy, !loading, !loadFailed,
      paper.readable, renderedPaperControls(for: paper), deleting == nil, !operationFailed,
      let accepted = snapshot?.papers.first(where: {
        $0.id == paper.id && $0.generation == paper.generation && $0.readable
      }) else { return }
    interruptSheetReturn(newerWork: true)
    guard sheetPresentation == nil else { return }
    let slot = LibrarySheetSlot(mountID: mountID, content: .movement(accepted),
      filter: filter, refreshRevision: refreshRevision)
    organizationFocusToRestore = nil
    clearObservation()
    sheetPresentation = LibrarySheetPresentation(slot: slot)
  }

  private func movementPayloadIsEligible(_ slot: LibrarySheetSlot) -> Bool {
    guard case .movement = slot.content, let presentation = sheetPresentation else { return false }
    return presentation.slot.id == slot.id && presentation.slot.mountID == slot.mountID
      && rootMount == slot.mountID && presentation.requestedVisibility && !presentation.closing
      && !presentation.nativeDismissConsumed && !presentation.newerWork
      && filter == slot.filter && refreshRevision == slot.refreshRevision
  }

  private func movementCommitted(_ slot: LibrarySheetSlot) {
    if sheetPresentation?.slot.id == slot.id, sheetPresentation?.slot.mountID == slot.mountID,
      sheetPresentation?.nativeDismissConsumed == false {
      sheetPresentation?.closing = true
      sheetPresentation?.requestedVisibility = false
    }
    guard rootMount != nil else { return }
    refresh(completedMovement: slot)
  }

  private func detailPayloadIsEligible(_ slot: LibrarySheetSlot) -> Bool {
    guard case .identification = slot.content, let presentation = sheetPresentation else { return false }
    return presentation.slot.id == slot.id && presentation.slot.mountID == slot.mountID
      && rootMount == slot.mountID && presentation.requestedVisibility && !presentation.closing
      && !presentation.nativeDismissConsumed && !presentation.newerWork
      && filter == slot.filter && refreshRevision == slot.refreshRevision
  }

  private func sheetPresenter(_ slot: LibrarySheetSlot) -> some View {
    Color.clear.frame(width: 0, height: 0)
      .sheet(isPresented: Binding(get: {
        sheetPresentation?.slot.id == slot.id && rootMount == slot.mountID
          && sheetPresentation?.requestedVisibility == true
      }, set: { visible in
        if !visible { requestSheetClose(slot) }
      }), onDismiss: { sheetDismissed(slot) }) {
        switch slot.content {
        case .tagEditor(let paper):
        OrganizationEditor(paper: paper, save: { value, observed in
          guard sheetPresentation?.slot.id == slot.id, rootMount == slot.mountID,
            sheetPresentation?.requestedVisibility == true, sheetPresentation?.closing == false,
            sheetPresentation?.lateMovementMutationVeto == false else {
            throw CancellationError()
          }
          busy = true; invalidateObservation(preservingEditor: slot.id)
          do {
            try await service.save(value, for: observed)
            busy = false
            if let mountID = rootMount {
              let preserved = sheetPresentation?.slot.id == slot.id && mountID == slot.mountID
                && sheetPresentation?.nativeDismissConsumed == false ? slot.id : nil
              refresh(preservingEditor: preserved)
            }
          } catch {
            busy = false
            if let mountID = rootMount {
              let preserved = sheetPresentation?.slot.id == slot.id && mountID == slot.mountID
                && sheetPresentation?.nativeDismissConsumed == false ? slot.id : nil
              refresh(preservingEditor: preserved)
            }
            throw error
          }
        }, revalidate: { observed in
          guard sheetPresentation?.slot.id == slot.id, rootMount == slot.mountID,
            sheetPresentation?.requestedVisibility == true, sheetPresentation?.closing == false,
            sheetPresentation?.lateMovementMutationVeto == false else { throw CancellationError() }
          return try await service.revalidate(observed)
        },
          close: { requestSheetClose(slot) })
        .onAppear { sheetAppeared(slot) }
        case .identification(let captured):
          LibraryIdentificationDetail(captured: captured, readReadingRecords: readReadingRecords,
            eligible: detailPayloadIsEligible(slot), isEligible: { detailPayloadIsEligible(slot) },
            close: { requestSheetClose(slot) })
            .id(slot.id)
            .onAppear { sheetAppeared(slot) }
        case .movement(let paper):
          PaperMovementSheet(paper: paper, service: folderService,
            eligible: movementPayloadIsEligible(slot), isEligible: { movementPayloadIsEligible(slot) },
            close: { requestSheetClose(slot) }, committed: { movementCommitted(slot) })
            .id(slot.id)
            .onAppear { sheetAppeared(slot) }
        }
      }
  }

  private func sheetAppeared(_ slot: LibrarySheetSlot) {
    guard sheetPresentation?.slot.id == slot.id, rootMount == slot.mountID,
      sheetPresentation?.requestedVisibility == true, sheetPresentation?.closing == false,
      sheetPresentation?.appeared == false else { return }
    sheetPresentation?.appeared = true
  }

  private func requestSheetClose(_ slot: LibrarySheetSlot) {
    guard sheetPresentation?.slot.id == slot.id, rootMount == slot.mountID,
      sheetPresentation?.requestedVisibility == true, sheetPresentation?.closing == false,
      sheetPresentation?.nativeDismissConsumed == false else { return }
    sheetPresentation?.closing = true
    sheetPresentation?.requestedVisibility = false
  }

  private func sheetDismissed(_ slot: LibrarySheetSlot) {
    guard let presentation = sheetPresentation, presentation.slot.id == slot.id,
      presentation.slot.mountID == slot.mountID, presentation.closing, !presentation.requestedVisibility,
      !presentation.nativeDismissConsumed else { return }
    guard rootMount == slot.mountID || !slot.content.isTagEditor else { return }
    sheetPresentation?.nativeDismissConsumed = true
    guard rootMount == slot.mountID, !presentation.newerWork, filter == slot.filter,
      refreshRevision == slot.refreshRevision, !busy,
      deleting == nil, !operationFailed else {
      sheetPresentation = nil
      return
    }
    refresh(returningSheet: slot)
  }

  private func interruptSheetReturn(newerWork: Bool) {
    guard let presentation = sheetPresentation else { return }
    if newerWork {
      if presentation.nativeDismissConsumed { sheetPresentation = nil }
      else {
        sheetPresentation?.newerWork = true
        if !presentation.slot.content.isTagEditor {
          sheetPresentation?.closing = true
          sheetPresentation?.requestedVisibility = false
        }
      }
    } else {
      sheetPresentation?.differentFocus = true
    }
  }

  private func consumeSheetReturn(_ request: OrganizationQueryState.Request) {
    guard let presentation = sheetPresentation, presentation.awaitingRequest == request,
      presentation.nativeDismissConsumed, !query.loading else { return }
    let slot = presentation.slot
    sheetPresentation = nil
    guard rootMount == slot.mountID, filter == slot.filter,
      refreshRevision == slot.refreshRevision, presentation.appeared,
      !presentation.newerWork, !presentation.differentFocus,
      !busy, deleting == nil, !operationFailed,
      organizationFocus == nil else { return }
    switch slot.content {
    case .tagEditor:
      guard focusedIdentification == nil, focusedMovement == nil,
        focusedPaper == nil || focusedPaper == slot.paper.id else { return }
      if renderedPaperControls(for: slot.paper) {
        focusedPaper = slot.paper.id
      } else {
        focusedPaper = nil
        organizationFocus = .search
      }
    case .identification:
      guard focusedPaper == nil, focusedMovement == nil,
        focusedIdentification == nil || focusedIdentification == slot.paper.id else { return }
      if renderedPaperControls(for: slot.paper) {
        focusedIdentification = slot.paper.id
      } else {
        focusedIdentification = nil
        organizationFocus = .search
      }
    case .movement:
      guard focusedPaper == nil, focusedIdentification == nil,
        focusedMovement == nil || focusedMovement == slot.paper.id else { return }
      if renderedPaperControls(for: slot.paper), snapshot?.papers.contains(where: {
        $0.id == slot.paper.id && $0.generation == slot.paper.generation && $0.readable
      }) == true {
        focusedMovement = slot.paper.id
      } else {
        focusedMovement = nil
        organizationFocus = .search
      }
    }
  }

  private func requestManageFolders() {
    guard !nativeSheetPending, !busy else { return }
    interruptSheetReturn(newerWork: true)
    manageFolders()
  }

  private func requestRefresh() {
    guard !nativeSheetPending, !busy else { return }
    refresh()
  }

  private func savePreferences(_ preference: OrganizationPreferences) {
    perform { try await service.savePreferences(preference) }
  }
  private func saveOrganization(_ value: PaperOrganization, for paper: OrganizedPaper,
    origin: OrganizationControlFocus) {
    guard !nativeSheetPending, paper.readable, !busy, !loading, !loadFailed,
      value != paper.organization else { return }
    organizationFocusToRestore = (paper.id, paper.generation, origin)
    perform { try await service.save(value, for: paper) }
  }
  private func requestImport() {
    guard !nativeSheetPending else { return }
    invalidateObservation()
    importPDF()
    refresh()
  }
  private func requestRetry(_ paper: OrganizedPaper) {
    guard !nativeSheetPending, paper.status == .importFailed, !busy, !loading, !loadFailed else { return }
    invalidateObservation()
    retryImportPDF(paper.id, paper.generation)
    refresh()
  }
  private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
    guard !nativeSheetPending, !busy else { return }
    busy = true; invalidateObservation()
    Task {
      do { try await operation() } catch { operationFailed = true }
      busy = false; refresh()
    }
  }
  private func refresh(preservingEditor slotID: UUID? = nil,
    returningSheet slot: LibrarySheetSlot? = nil,
    completedMovement movement: LibrarySheetSlot? = nil) {
    if let slot {
      guard let presentation = sheetPresentation, presentation.slot.id == slot.id,
        rootMount == slot.mountID, presentation.nativeDismissConsumed,
        presentation.awaitingRequest == nil, !presentation.newerWork,
        filter == slot.filter, refreshRevision == slot.refreshRevision else { return }
      clearObservation()
    } else if let movement {
      if let presentation = sheetPresentation {
        let preservesOriginalReturn = presentation.slot.id == movement.id
          && presentation.slot.mountID == movement.mountID && rootMount == movement.mountID
          && !presentation.nativeDismissConsumed && !presentation.newerWork
          && !presentation.differentFocus && filter == movement.filter
          && refreshRevision == movement.refreshRevision
        if !preservesOriginalReturn {
          if presentation.nativeDismissConsumed { sheetPresentation = nil }
          else {
            sheetPresentation?.newerWork = true
            if presentation.slot.content.isTagEditor {
              sheetPresentation?.lateMovementMutationVeto = true
            }
          }
        }
      }
      clearObservation()
    } else {
      invalidateObservation(preservingEditor: slotID)
    }
    guard rootMount != nil, !busy else { return }
    let request = query.begin(filter: filter)
    if let slot, sheetPresentation?.slot.id == slot.id { sheetPresentation?.awaitingRequest = request }
    Task { await load(request) }
  }
  private func invalidateObservation(preservingEditor slotID: UUID? = nil) {
    if let presentation = sheetPresentation,
      !presentation.slot.content.isTagEditor || presentation.slot.id != slotID
        || presentation.nativeDismissConsumed {
      interruptSheetReturn(newerWork: true)
    }
    clearObservation()
  }
  private func clearObservation() {
    currentFacts = [:]
    folders = []
    folderLoadFailed = false
    tags = []
    tagLoadFailed = false
    query.invalidate()
  }
  private func load(_ request: OrganizationQueryState.Request) async {
    let observedFolders: [LibraryFolder]
    let foldersFailed: Bool
    do {
      observedFolders = try await folderService.folders()
      foldersFailed = false
    } catch {
      observedFolders = []
      foldersFailed = true
    }
    let observedTags: [String]
    let tagsFailed: Bool
    do {
      observedTags = try await service.tags()
      tagsFailed = false
    } catch {
      observedTags = []
      tagsFailed = true
    }
    do {
      let facts = try await sortFacts()
      let value = try await service.snapshot(filter: request.filter, facts: facts)
      guard query.accept(value, request: request, currentFilter: filter) else { return }
      folders = observedFolders
      folderLoadFailed = foldersFailed
      tags = observedTags
      tagLoadFailed = tagsFailed
      let generations = Dictionary(uniqueKeysWithValues: value.papers.map { ($0.id, $0.generation) })
      currentFacts = Dictionary(uniqueKeysWithValues: facts.filter { generations[$0.paperID] == $0.generation }.map { ($0.paperID, $0) })
      consumeSheetReturn(request)
    } catch {
      query.reject(request: request, currentFilter: filter)
      consumeSheetReturn(request)
    }
  }
  private func readingLabel(_ status: PaperReadingStatus) -> String {
    switch status { case .unread: return "읽지 않음"; case .reading: return "읽는 중"; case .read: return "읽음" }
  }
  private func statusLabel(_ paper: OrganizedPaper) -> String {
    switch paper.status {
    case .ready: return paper.readable ? "PDF 읽기 가능" : "PDF 사용 불가 · 새로고침 또는 삭제"
    case .importing: return "가져오는 중"
    case .importFailed: return "가져오기 실패 · 새 PDF로 같은 작업 재시도 또는 삭제"
    case .deleting: return "삭제 중 · 열기 불가"
    case .deletionFailed: return "삭제 미완료 · 삭제 다시 시도"
    case .tombstone: return "삭제됨"
    }
  }
}

private enum OrganizationControlFocus: Hashable {
  case search, favorite(UUID), reading(UUID)
  case importPDF, refresh, presentation, sort, retryLibrary, manageUnavailableFolder
  case importEmpty, clearNoMatch, retryFolders, manageFolders, favoritesFilter, readingFilter
  case retryTags, exactTag, clearConditions, allFolders, unfiled, folder(UUID), tag(String?), open(UUID)
}

private enum LibrarySheetContent {
  case tagEditor(OrganizedPaper)
  case identification(LibraryIdentification)
  case movement(OrganizedPaper)

  var isTagEditor: Bool {
    if case .tagEditor = self { return true }
    return false
  }
  var isIdentification: Bool {
    if case .identification = self { return true }
    return false
  }
  var isMovement: Bool {
    if case .movement = self { return true }
    return false
  }
  var paper: OrganizedPaper {
    switch self {
    case .tagEditor(let paper): return paper
    case .identification(let captured): return captured.paper
    case .movement(let paper): return paper
    }
  }
}

private struct LibrarySheetSlot: Identifiable {
  let id = UUID()
  let mountID: UUID
  let content: LibrarySheetContent
  var paper: OrganizedPaper { content.paper }
  let filter: OrganizationFilter
  let refreshRevision: Int
}

private struct LibrarySheetPresentation {
  let slot: LibrarySheetSlot
  var requestedVisibility = true
  var appeared = false
  var closing = false
  var nativeDismissConsumed = false
  var awaitingRequest: OrganizationQueryState.Request?
  var newerWork = false
  var differentFocus = false
  var lateMovementMutationVeto = false
}

@MainActor private struct PaperMovementSheet: View {
  let paper: OrganizedPaper
  let service: FolderImportService
  let eligible: Bool
  let isEligible: @MainActor () -> Bool
  let close: @MainActor () -> Void
  let committed: @MainActor () -> Void
  @State private var observation = PaperPlacementLoadState()
  @State private var destination: UUID?
  @State private var loadTask: Task<Void, Never>?
  @State private var saveTask: Task<Void, Never>?
  @State private var saving = false
  @State private var saveFailed = false
  @State private var visible = false
  @State private var closed = false

  private var canObserve: Bool { eligible && !closed && isEligible() }

  var body: some View {
    Form {
      if canObserve { Text(paper.title).font(.headline) }
      Text("논문의 폴더 배치만 변경합니다. 앱 소유 PDF는 이동하거나 복사하지 않습니다.")
        .font(.caption)
      if canObserve {
      if observation.loading { ProgressView("현재 폴더 불러오는 중") }
      if saving { ProgressView("폴더 배치 저장 중").accessibilityLabel("폴더 배치 저장 중") }
      if let captured = observation.captured {
        Text("현재 폴더: \(captured.folder?.name ?? "미분류")")
        Picker("이동할 폴더", selection: $destination) {
          Text("미분류").tag(Optional<UUID>.none)
          ForEach(observation.folders) { folder in
            Text(folder.name).tag(Optional(folder.id))
          }
        }.disabled(saving)
      }
      if observation.failed || saveFailed {
        Text(saveFailed
          ? "이동 실패 · 현재 상태를 다시 불러온 뒤 목적지를 선택하고 새로 저장하세요. 자동으로 다시 이동하지 않습니다."
          : "현재 배치를 확인할 수 없습니다. 다시 불러오세요.")
        Button("현재 상태 다시 불러오기") { reload() }.disabled(saving || observation.loading)
      }
      }
      HStack {
        Button("취소", role: .cancel) { closed = true; cancelObservation(); close() }
          .keyboardShortcut(.cancelAction)
        Button("저장") { save() }
          .keyboardShortcut(.defaultAction)
          .disabled(!canObserve || saving || observation.loading || observation.captured == nil || saveFailed)
      }
    }
    .padding().frame(minWidth: 400)
    .task {
      guard canObserve, !Task.isCancelled else { return }
      visible = true; reload()
    }
    .onChange(of: eligible) { _, value in
      if !value { closed = true; cancelObservation() }
    }
    .onDisappear { visible = false; closed = true; cancelObservation() }
  }

  private func cancelObservation() {
    loadTask?.cancel(); loadTask = nil
    saveTask?.cancel(); saveTask = nil
    observation.invalidate()
  }

  private func reload() {
    guard canObserve, visible, !saving else { return }
    loadTask?.cancel()
    let request = observation.begin(paperID: paper.id, generation: paper.generation)
    destination = nil
    loadTask = Task {
      guard canObserve, visible, !Task.isCancelled else { return }
      do {
        let captured = try await service.capturePaperPlacement(paperID: request.paperID,
          generation: request.generation)
        try Task.checkCancellation()
        guard canObserve, visible else { return }
        let folders = try await service.folders()
        try Task.checkCancellation()
        guard canObserve, visible else { return }
        if observation.accept(captured, folders: folders, request: request) {
          destination = captured.folder?.id; saveFailed = false
        } else { observation.reject(request) }
      } catch {
        guard !Task.isCancelled, canObserve, visible else { return }
        observation.reject(request)
      }
    }
  }

  private func save() {
    guard canObserve, visible, !saving, !saveFailed, !observation.loading,
      let captured = observation.captured else { return }
    let selectedDestination = destination
    saving = true
    saveTask = Task {
      guard canObserve, visible, !Task.isCancelled else { return }
      do {
        try await service.movePaper(captured, to: selectedDestination)
        // A committed transaction can win a late dismissal; refresh, never undo it.
        committed()
      } catch {
        guard canObserve, visible, !Task.isCancelled else { return }
        observation.invalidate(); saveFailed = true; saving = false
      }
    }
  }
}

private struct LibraryIdentification {
  let paper: OrganizedPaper
  let metadata: ReaderMetadataSnapshot?
  let summary: LibrarySummaryObservation?
}

@MainActor private struct LibraryStoredSummary: View {
  let paper: OrganizedPaper
  let observation: LibrarySummaryObservation?
  let showEvidence: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(showEvidence ? "저장된 요약" : "저장된 요약 · 한 줄 미리보기").font(.headline)
      if let observation {
        if let attempt = observation.recentAttempt,
          attempt.identity.paperID == paper.id, attempt.identity.generation == paper.generation {
          switch attempt.activity {
          case .running: Text("최근 요약 시도 · 준비 중")
          case .failed: Text("최근 요약 시도 · 실패")
          case .succeeded: Text("최근 요약 시도 · 완료 (저장 요약의 사용 가능 여부와 별개)")
          }
        }
        switch observation.availability {
        case .available: EmptyView()
        case .unavailable:
          Text("요약 사용 불가 · 검증된 저장 요약 또는 원문 근거 검증 소유자를 사용할 수 없습니다.")
        case .verificationFailed:
          Text("요약 검증 실패 · 저장된 요약 또는 최근 시도 정보를 안전하게 확인할 수 없습니다.")
        }
        if let record = observation.record,
          record.identity.paperID == paper.id, record.identity.generation == paper.generation,
          case .librarySummary(let summary, _) = record.result.result {
          if showEvidence {
            Text(summary.text).textSelection(.enabled)
          } else {
            Text(summary.text).lineLimit(1).truncationMode(.tail)
          }
          if record.claimAnchors.isEmpty {
            Text("근거 부족 · 근거 위치 없음")
          } else if showEvidence {
            Text("저장된 요약의 원문 근거").font(.headline)
            ForEach(record.claimAnchors.indices, id: \.self) { index in
              let anchor = record.claimAnchors[index]
              VStack(alignment: .leading, spacing: 4) {
                Text("PDF \(anchor.identity.pageIndex + 1)쪽").font(.caption)
                Text(anchor.fullSourceQuote).textSelection(.enabled)
              }
            }
          }
        } else if observation.record != nil {
          Text("요약 검증 실패 · 현재 논문의 저장된 요약을 확인할 수 없습니다.")
        }
      } else {
        Text("미확인 · 확인된 저장 요약 정보가 없습니다.")
      }
    }
  }
}

/// Character prefixes preserve extended grapheme clusters, including emoji and combining marks.
enum LibraryMetadataPresentation {
  static func excerpt(_ text: String, limit: Int) -> String {
    let prefix = text.prefix(limit)
    return String(prefix) + (prefix.endIndex == text.endIndex ? "" : "…")
  }
  static func preview(_ field: ReaderMetadataField?, limit: Int) -> String {
    guard let field, !field.candidates.isEmpty else { return "미확인" }
    guard !field.isConflict else { return "출처 간 충돌 · 상세에서 후보 확인" }
    return excerpt(field.candidates[0].text, limit: limit)
  }
}

@MainActor private struct LibraryIdentificationDetail: View {
  let captured: LibraryIdentification
  let readReadingRecords: @Sendable (UUID, UUID) async throws -> LibraryReadingRecords
  let eligible: Bool
  let isEligible: @MainActor () -> Bool
  let close: @MainActor () -> Void
  private enum ReadingRecordsObservation {
    case loading, unavailable, failed
    case loaded(LibraryReadingRecords)
  }
  private struct ReadingRecordsRequest: Hashable {
    let paperID: UUID
    let generation: UUID
    let retry: UUID
    let eligible: Bool
  }
  @State private var readingRecords: ReadingRecordsObservation = .loading
  @State private var retry = UUID()
  @State private var activeRequest: UUID?
  @State private var closed = false
  private var request: ReadingRecordsRequest {
    ReadingRecordsRequest(paperID: captured.paper.id, generation: captured.paper.generation,
      retry: retry, eligible: eligible)
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if eligible, !closed, isEligible() {
        Text(captured.paper.title).font(.headline).textSelection(.enabled)
      }
      Text("불러온 시점의 저장된 출처 정보입니다. 현재 발행 상태나 PDF 열기 권한을 보장하지 않습니다.")
        .font(.caption)
      if eligible, !closed, isEligible() {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          field("출처 제목", captured.metadata?.title)
          field("발행연도", captured.metadata?.year)
          LibraryStoredSummary(paper: captured.paper, observation: captured.summary, showEvidence: true)
          storedReadingRecords
          field("초록", captured.metadata?.abstract)
          field("출처 주제 · 사용자 태그 아님", captured.metadata?.topics)
        }.frame(maxWidth: .infinity, alignment: .leading)
      }
      }
      Button("닫기", role: .cancel) {
        invalidateReadingRecords()
        close()
      }.keyboardShortcut(.cancelAction)
    }.padding().frame(minWidth: 420, idealWidth: 560, minHeight: 280, idealHeight: 480)
      .task(id: request) { await loadReadingRecords(request) }
      .onDisappear { invalidateReadingRecords() }
  }

  private func invalidateReadingRecords() {
    closed = true
    activeRequest = nil
    readingRecords = .unavailable
  }

  private func loadReadingRecords(_ capturedRequest: ReadingRecordsRequest) async {
    guard capturedRequest.eligible, isEligible() else { invalidateReadingRecords(); return }
    guard !closed, !Task.isCancelled, request == capturedRequest else { return }
    let token = UUID()
    activeRequest = token
    readingRecords = .loading
    guard captured.paper.readable else {
      readingRecords = .unavailable
      return
    }
    do {
      let result = try await readReadingRecords(capturedRequest.paperID, capturedRequest.generation)
      guard isEligible() else { invalidateReadingRecords(); return }
      guard !closed, !Task.isCancelled, activeRequest == token, request == capturedRequest else { return }
      guard result.identity.id == capturedRequest.paperID,
        result.identity.generation == capturedRequest.generation,
        result.annotations.allSatisfy({ $0.selection.paper == result.identity }) else {
        readingRecords = .unavailable
        return
      }
      readingRecords = .loaded(result)
    } catch {
      guard isEligible() else { invalidateReadingRecords(); return }
      guard !closed, !Task.isCancelled, activeRequest == token, request == capturedRequest else { return }
      if let error = error as? AnnotationError, error == .stalePaper {
        readingRecords = .unavailable
      } else {
        readingRecords = .failed
      }
    }
  }

  @ViewBuilder private var storedReadingRecords: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("저장된 읽기 기록").font(.headline)
      Text("개인 기록의 수동 조회입니다. PDF 열기·페이지 이동·선택 캡처·파일 공개·복사·주석 변경 권한을 부여하지 않습니다. 저장된 페이지가 현재 PDF에 존재하는지는 확인하지 않았습니다. 실제 읽기는 Library의 열기에서 다시 승인받아야 합니다.")
        .font(.caption)
      switch readingRecords {
      case .loading:
        ProgressView("저장된 읽기 기록 불러오는 중")
      case .unavailable:
        Text("읽기 기록 조회 불가 · 현재 읽을 수 있는 동일 세대 논문을 확인할 수 없습니다. 기록이 없다는 뜻은 아닙니다.")
      case .failed:
        Text("읽기 기록 불러오기 실패 · 저장된 위치와 주석의 유무를 확인하지 못했습니다.")
        Button("읽기 기록 다시 불러오기") {
          guard eligible, isEligible() else { invalidateReadingRecords(); return }
          guard !closed else { return }
          activeRequest = nil
          readingRecords = .loading
          retry = UUID()
        }
      case .loaded(let records):
        if let position = records.position {
          Text("저장 당시 위치").font(.headline)
          Text(savedPageLabel(position.pageIndex))
          if position.zoom.isFinite, (0.1...10).contains(position.zoom) {
            Text("저장 당시 확대 배율: \(position.zoom.formatted())배")
          } else {
            Text("저장 당시 확대 배율 확인 불가")
          }
        } else {
          Text("저장된 마지막 읽기 위치 없음")
        }
        if records.annotations.isEmpty {
          Text("저장된 Highlight/Note 없음")
        } else {
          Text("저장된 Highlight/Note").font(.headline)
          ForEach(records.annotations) { record in
            VStack(alignment: .leading, spacing: 6) {
              Text(record.kind == .highlight ? "Highlight" : "Note").font(.headline)
              if record.selection.locations.isEmpty {
                Text("저장된 페이지 위치 확인 불가").font(.caption)
              } else {
                ForEach(record.selection.locations.indices, id: \.self) { index in
                  Text(savedPageLabel(record.selection.locations[index].pageIndex)).font(.caption)
                }
              }
              Text(verbatim: record.selection.originalText)
              if let note = record.note {
                Text("개인 노트").font(.caption)
                Text(verbatim: note)
              } else if record.kind == .note {
                Text("개인 노트 본문 확인 불가")
              }
            }
            Divider()
          }
        }
      }
    }
  }

  private func savedPageLabel(_ pageIndex: Int) -> String {
    guard pageIndex >= 0 else { return "저장된 페이지 위치 확인 불가" }
    let (page, overflow) = pageIndex.addingReportingOverflow(1)
    guard !overflow else { return "저장된 페이지 위치 확인 불가" }
    return "저장 당시 PDF \(page)쪽"
  }
  @ViewBuilder private func field(_ title: String, _ value: ReaderMetadataField?) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title).font(.headline)
      if let value, !value.candidates.isEmpty {
        Text(value.isConflict ? "출처 간 충돌 · 어느 후보도 확정하지 않았습니다." : "저장된 출처 후보")
        Text("후보별 텍스트 최대 1,200자, 출처 식별자 최대 256자 발췌").font(.caption)
        ForEach(value.candidates.indices, id: \.self) { index in
          let candidate = value.candidates[index]
          VStack(alignment: .leading, spacing: 4) {
            Text(LibraryMetadataPresentation.excerpt(candidate.text, limit: 1200))
            Text("출처 종류: \(candidate.source.rawValue)").font(.caption)
            Text("출처 ID: \(LibraryMetadataPresentation.excerpt(candidate.sourceID, limit: 256))").font(.caption)
          }.textSelection(.enabled)
        }
      } else {
        Text("미확인 · 저장된 출처 후보가 없습니다.")
      }
    }
  }
}

func organizationEditorActivityLabel(busy: Bool, failed: Bool) -> String? {
  guard busy else { return nil }
  return failed ? "현재 저장값 확인 중" : "저장 중"
}

struct OrganizationEditorInteraction {
  enum Phase {
    case editing, saving, failed, revalidating, closing
  }

  private(set) var phase: Phase = .editing
  var busy: Bool { phase == .saving || phase == .revalidating }
  var failed: Bool { phase == .failed || phase == .revalidating }
  var blocksInteraction: Bool { busy || phase == .closing }

  mutating func beginSave() -> Bool {
    guard phase == .editing else { return false }
    phase = .saving
    return true
  }

  mutating func beginRevalidate() -> Bool {
    guard phase == .failed else { return false }
    phase = .revalidating
    return true
  }

  mutating func beginCancel() -> Bool {
    guard phase == .editing || phase == .failed else { return false }
    phase = .closing
    return true
  }

  mutating func finishSave(succeeded: Bool) -> Bool {
    guard phase == .saving else { return false }
    phase = succeeded ? .closing : .failed
    return true
  }

  mutating func finishRevalidation(succeeded: Bool) -> Bool {
    guard phase == .revalidating else { return false }
    phase = succeeded ? .editing : .failed
    return true
  }

  mutating func invalidate() {
    phase = .closing
  }
}

@MainActor private struct OrganizationEditor: View {
  let save: @MainActor (PaperOrganization, OrganizedPaper) async throws -> Void
  let revalidate: @MainActor (OrganizedPaper) async throws -> OrganizedPaper
  let close: @MainActor () -> Void
  @State private var observed: OrganizedPaper
  @State private var value: PaperOrganization
  @State private var tags: String
  @State private var interaction = OrganizationEditorInteraction()
  init(paper: OrganizedPaper,
    save: @escaping @MainActor (PaperOrganization, OrganizedPaper) async throws -> Void,
    revalidate: @escaping @MainActor (OrganizedPaper) async throws -> OrganizedPaper,
    close: @escaping @MainActor () -> Void) {
    self.save = save; self.revalidate = revalidate; self.close = close
    _observed = State(initialValue: paper)
    _value = State(initialValue: paper.organization)
    _tags = State(initialValue: paper.organization.tags.joined(separator: "\n"))
  }
  var body: some View {
    Form {
      Text(observed.title).font(.headline)
      Picker("읽기 상태", selection: $value.readingStatus) {
        Text("읽지 않음").tag(PaperReadingStatus.unread)
        Text("읽는 중").tag(PaperReadingStatus.reading)
        Text("읽음").tag(PaperReadingStatus.read)
      }.disabled(interaction.blocksInteraction)
      Toggle("즐겨찾기", isOn: $value.favorite).disabled(interaction.blocksInteraction)
      Text("사용자 태그 · 한 줄에 하나 (최대 100개, 각 80자)")
      TextEditor(text: $tags).frame(minHeight: 120).accessibilityLabel("사용자 태그").disabled(interaction.blocksInteraction)
      if let activity = organizationEditorActivityLabel(busy: interaction.busy, failed: interaction.failed) {
        ProgressView(activity).accessibilityLabel(activity)
      }
      if interaction.failed {
        Text("저장 실패 · 이전 값은 덮어쓰지 않았습니다. 현재 저장값을 다시 확인한 뒤 편집하세요.")
        Button("현재 저장값 확인 후 다시 시도") {
          guard interaction.beginRevalidate() else { return }
          Task {
            do {
              let current = try await revalidate(observed)
              guard interaction.phase == .revalidating else { return }
              observed = current; value = current.organization
              tags = current.organization.tags.joined(separator: "\n")
              _ = interaction.finishRevalidation(succeeded: true)
            } catch { _ = interaction.finishRevalidation(succeeded: false) }
          }
        }.disabled(interaction.blocksInteraction)
      }
      HStack {
        Button("취소", role: .cancel) {
          guard interaction.beginCancel() else { return }
          close()
        }.keyboardShortcut(.cancelAction)
        Button("저장") {
          guard interaction.beginSave() else { return }
          var draft = value
          draft.tags = tags.split(separator: "\n").map(String.init)
          Task {
            do {
              try await save(draft, observed)
              guard interaction.finishSave(succeeded: true) else { return }
              close()
            } catch { _ = interaction.finishSave(succeeded: false) }
          }
        }.keyboardShortcut(.defaultAction).disabled(interaction.failed)
      }.disabled(interaction.blocksInteraction)
    }.padding().frame(minWidth: 400).interactiveDismissDisabled(interaction.blocksInteraction)
      .onDisappear { interaction.invalidate() }
  }
}
