import SwiftUI

@MainActor
public struct LibraryBrowserView: View {
  private let service: LibraryOrganizationService
  private let folderService: FolderImportService
  private let sortFacts: @Sendable () async throws -> [OrganizationSortFacts]
  private let openPaper: @MainActor (OrganizedPaper) async throws -> Void
  private let importPDF: @MainActor () -> Void
  private let retryImportPDF: @MainActor (UUID, UUID) -> Void
  private let refreshRevision: Int
  @State private var query = OrganizationQueryState()
  @State private var currentFacts: [UUID: OrganizationSortFacts] = [:]
  @Binding private var filter: OrganizationFilter
  @State private var operationFailed = false
  @State private var busy = false
  @State private var deleting: OrganizedPaper?
  @State private var editing: OrganizedPaper?
  @State private var moving: LibraryMovement?
  @State private var movementFocusToRestore: OrganizedPaper?
  @State private var identification: LibraryIdentification?
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
    openPaper: @escaping @MainActor (OrganizedPaper) async throws -> Void,
    importPDF: @escaping @MainActor () -> Void,
    retryImportPDF: @escaping @MainActor (UUID, UUID) -> Void) {
    self.service = service; self.folderService = folderService; self.sortFacts = sortFacts
    _filter = filter; self.refreshRevision = refreshRevision
    self.openPaper = openPaper; self.importPDF = importPDF
    self.retryImportPDF = retryImportPDF
  }

  private var libraryContent: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Library").font(.largeTitle)
        Spacer()
        Button("PDF 추가", action: requestImport)
        Button("새로고침") { refresh() }.disabled(busy)
      }
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
          Picker("정렬", selection: Binding(get: { snapshot.preferences.sort }, set: { value in
            var preference = snapshot.preferences; preference.sort = value
            savePreferences(preference)
          })) {
            Text("최근 읽음").tag(LibrarySort.recentlyRead)
            Text("이름").tag(LibrarySort.name)
            Text("최근 추가").tag(LibrarySort.recentlyAdded)
            Text("발행연도").tag(LibrarySort.publicationYear)
          }
        }.disabled(busy || loading)
      }
      if loadFailed {
        ContentUnavailableView("불러오기 실패", systemImage: "exclamationmark.triangle",
          description: Text("저장된 값을 확인할 수 없습니다. 다시 불러오세요."))
        Button("다시 불러오기") { refresh() }.disabled(busy)
      } else if loading {
        ProgressView("라이브러리 불러오는 중")
      } else if let snapshot {
        if snapshot.totalCount == 0 {
          ContentUnavailableView("아직 논문이 없습니다", systemImage: "books.vertical",
            description: Text("PDF 추가로 시작하세요."))
          Button("PDF 추가", action: requestImport)
        } else if snapshot.papers.isEmpty {
          ContentUnavailableView("일치하는 논문 없음", systemImage: "line.3.horizontal.decrease.circle",
            description: Text("저장된 논문은 있습니다. 검색과 필터를 변경하세요."))
          Button("필터 지우기") { filter = OrganizationFilter() }
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
    VStack(alignment: .leading, spacing: 16) {
      Text("필터").font(.headline)
      Toggle("즐겨찾기만", isOn: $filter.favoritesOnly)
      Picker("읽기 상태", selection: $filter.readingStatus) {
        Text("전체").tag(Optional<PaperReadingStatus>.none)
        ForEach(PaperReadingStatus.allCases, id: \.self) { status in
          Text(readingLabel(status)).tag(Optional(status))
        }
      }.pickerStyle(.radioGroup)
      TextField("태그 필터 (정확한 이름)", text: Binding(
        get: { filter.tag ?? "" }, set: { filter.tag = $0.isEmpty ? nil : $0 }))
        .textFieldStyle(.roundedBorder)
        .accessibilityLabel("정확한 사용자 태그로 필터")
      Text("제목·태그 검색과 함께 적용됩니다. 출처 주제는 사용자 태그가 아닙니다.")
        .font(.caption).foregroundStyle(.secondary)
      Button("검색·필터 모두 지우기") { filter = OrganizationFilter() }
        .disabled(filter == OrganizationFilter())
      Spacer()
    }
    .padding(12)
    .frame(minWidth: 180, idealWidth: 220, maxWidth: 300, maxHeight: .infinity, alignment: .topLeading)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("라이브러리 필터 사이드바")
  }

  public var body: some View {
    HSplitView {
      filterSidebar
      libraryContent.frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    .padding()
    .task(id: refreshRevision) { refresh() }
    .onDisappear { invalidateObservation() }
    .onChange(of: filter) { _, _ in refresh() }
    .onChange(of: loading) { _, value in
      if !value, let opener = movementFocusToRestore {
        if snapshot?.papers.contains(where: { $0.id == opener.id && $0.generation == opener.generation }) == true {
          focusedMovement = opener.id
        }
        movementFocusToRestore = nil
      }
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
    .sheet(item: $editing, onDismiss: { refresh() }) { paper in
      OrganizationEditor(paper: paper, save: { value, observed in
        busy = true; invalidateObservation()
        do {
          try await service.save(value, for: observed)
          busy = false; refresh()
        } catch {
          busy = false; refresh()
          throw error
        }
      }, revalidate: { observed in try await service.revalidate(observed) })
      .onDisappear { focusedPaper = paper.id }
    }
    .sheet(item: $identification) { captured in
      LibraryIdentificationDetail(captured: captured)
        .onDisappear { focusedIdentification = captured.paper.id }
    }
    .sheet(item: $moving, onDismiss: { refresh() }) { captured in
      PaperMovementSheet(paper: captured.paper, service: folderService, committed: {
        if moving?.id == captured.id { moving = nil }
        refresh()
      })
      .id(captured.id)
      .onDisappear { movementFocusToRestore = captured.paper }
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
        Button("논문 정보·요약 상세") {
          guard !busy, !loading, !loadFailed else { return }
          identification = LibraryIdentification(paper: paper, metadata: fact?.metadata, summary: fact?.summary)
        }.disabled(busy || loading || loadFailed)
          .focused($focusedIdentification, equals: paper.id)
          .accessibilityLabel("\(paper.title) 출처 제목·발행연도·요약·초록·출처 주제 상세")
        Button("폴더 이동") {
          guard paper.readable, !busy, !loading, !loadFailed else { return }
          invalidateObservation(); moving = LibraryMovement(paper: paper)
        }.disabled(!paper.readable || busy || loading || loadFailed)
          .focused($focusedMovement, equals: paper.id)
          .accessibilityLabel("\(paper.title) 폴더 이동")
        Menu("더 보기") {
          if paper.status == .importFailed {
            Button("새 PDF 선택 후 같은 작업 재시도") { requestRetry(paper) }
              .disabled(busy || loading || loadFailed)
          }
          Button("태그·읽기 상태·즐겨찾기 편집") {
            invalidateObservation(); editing = paper
          }.disabled(!paper.readable)
          if paper.status == .deletionFailed {
            Button("삭제 다시 시도") { perform { try await service.delete(paper, retry: true) } }
          } else {
            Button("삭제", role: .destructive) { deleting = paper }.disabled(paper.status == .deleting)
          }
        }.disabled(busy).focused($focusedPaper, equals: paper.id)
      }
    }.accessibilityElement(children: .contain)
  }
  private func savePreferences(_ preference: OrganizationPreferences) {
    perform { try await service.savePreferences(preference) }
  }
  private func saveOrganization(_ value: PaperOrganization, for paper: OrganizedPaper,
    origin: OrganizationControlFocus) {
    guard paper.readable, !busy, !loading, !loadFailed, value != paper.organization else { return }
    organizationFocusToRestore = (paper.id, paper.generation, origin)
    perform { try await service.save(value, for: paper) }
  }
  private func requestImport() {
    invalidateObservation()
    importPDF()
    refresh()
  }
  private func requestRetry(_ paper: OrganizedPaper) {
    guard paper.status == .importFailed, !busy, !loading, !loadFailed else { return }
    invalidateObservation()
    retryImportPDF(paper.id, paper.generation)
    refresh()
  }
  private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
    guard !busy else { return }
    busy = true; invalidateObservation()
    Task {
      do { try await operation() } catch { operationFailed = true }
      busy = false; refresh()
    }
  }
  private func refresh() {
    invalidateObservation()
    guard !busy else { return }
    let request = query.begin(filter: filter)
    Task { await load(request) }
  }
  private func invalidateObservation() {
    if let identification { focusedIdentification = identification.paper.id }
    identification = nil
    currentFacts = [:]
    query.invalidate()
  }
  private func load(_ request: OrganizationQueryState.Request) async {
    do {
      let facts = try await sortFacts()
      let value = try await service.snapshot(filter: request.filter, facts: facts)
      guard query.accept(value, request: request, currentFilter: filter) else { return }
      let generations = Dictionary(uniqueKeysWithValues: value.papers.map { ($0.id, $0.generation) })
      currentFacts = Dictionary(uniqueKeysWithValues: facts.filter { generations[$0.paperID] == $0.generation }.map { ($0.paperID, $0) })
    } catch {
      query.reject(request: request, currentFilter: filter)
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
}

private struct LibraryMovement: Identifiable {
  let id = UUID()
  let paper: OrganizedPaper
}

@MainActor private struct PaperMovementSheet: View {
  let paper: OrganizedPaper
  let service: FolderImportService
  let committed: @MainActor () -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var observation = PaperPlacementLoadState()
  @State private var destination: UUID?
  @State private var loadTask: Task<Void, Never>?
  @State private var saveTask: Task<Void, Never>?
  @State private var saving = false
  @State private var saveFailed = false
  @State private var visible = false

  var body: some View {
    Form {
      Text(paper.title).font(.headline)
      Text("논문의 폴더 배치만 변경합니다. 앱 소유 PDF는 이동하거나 복사하지 않습니다.")
        .font(.caption)
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
      HStack {
        Button("취소", role: .cancel) { cancelObservation(); dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("저장") { save() }
          .keyboardShortcut(.defaultAction)
          .disabled(saving || observation.loading || observation.captured == nil || saveFailed)
      }
    }
    .padding().frame(minWidth: 400)
    .task { visible = true; reload() }
    .onDisappear { visible = false; cancelObservation() }
  }

  private func cancelObservation() {
    loadTask?.cancel(); loadTask = nil
    saveTask?.cancel(); saveTask = nil
    observation.invalidate()
  }

  private func reload() {
    loadTask?.cancel()
    let request = observation.begin(paperID: paper.id, generation: paper.generation)
    destination = nil
    loadTask = Task {
      do {
        let captured = try await service.capturePaperPlacement(paperID: request.paperID,
          generation: request.generation)
        try Task.checkCancellation()
        let folders = try await service.folders()
        try Task.checkCancellation()
        guard visible else { return }
        if observation.accept(captured, folders: folders, request: request) {
          destination = captured.folder?.id; saveFailed = false
        } else { observation.reject(request) }
      } catch {
        guard !Task.isCancelled, visible else { return }
        observation.reject(request)
      }
    }
  }

  private func save() {
    guard !saving, !saveFailed, !observation.loading,
      let captured = observation.captured else { return }
    let selectedDestination = destination
    saving = true
    saveTask = Task {
      do {
        try await service.movePaper(captured, to: selectedDestination)
        // A committed transaction can win a late dismissal; refresh, never undo it.
        committed()
      } catch {
        guard visible, !Task.isCancelled else { return }
        observation.invalidate(); saveFailed = true; saving = false
      }
    }
  }
}

private struct LibraryIdentification: Identifiable {
  var id: UUID { paper.id }
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
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(captured.paper.title).font(.headline).textSelection(.enabled)
      Text("불러온 시점의 저장된 출처 정보입니다. 현재 발행 상태나 PDF 열기 권한을 보장하지 않습니다.")
        .font(.caption)
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          field("출처 제목", captured.metadata?.title)
          field("발행연도", captured.metadata?.year)
          LibraryStoredSummary(paper: captured.paper, observation: captured.summary, showEvidence: true)
          field("초록", captured.metadata?.abstract)
          field("출처 주제 · 사용자 태그 아님", captured.metadata?.topics)
        }.frame(maxWidth: .infinity, alignment: .leading)
      }
      Button("닫기", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
    }.padding().frame(minWidth: 420, idealWidth: 560, minHeight: 280, idealHeight: 480)
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
  @Environment(\.dismiss) private var dismiss
  @State private var observed: OrganizedPaper
  @State private var value: PaperOrganization
  @State private var tags: String
  @State private var interaction = OrganizationEditorInteraction()
  init(paper: OrganizedPaper,
    save: @escaping @MainActor (PaperOrganization, OrganizedPaper) async throws -> Void,
    revalidate: @escaping @MainActor (OrganizedPaper) async throws -> OrganizedPaper) {
    self.save = save; self.revalidate = revalidate
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
          dismiss()
        }
        Button("저장") {
          guard interaction.beginSave() else { return }
          var draft = value
          draft.tags = tags.split(separator: "\n").map(String.init)
          Task {
            do {
              try await save(draft, observed)
              guard interaction.finishSave(succeeded: true) else { return }
              dismiss()
            } catch { _ = interaction.finishSave(succeeded: false) }
          }
        }.disabled(interaction.failed)
      }.disabled(interaction.blocksInteraction)
    }.padding().frame(minWidth: 400).interactiveDismissDisabled(interaction.blocksInteraction)
      .onDisappear { interaction.invalidate() }
  }
}
