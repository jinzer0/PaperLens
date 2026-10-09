import SwiftUI

@MainActor
public struct LibraryBrowserView: View {
  private let service: LibraryOrganizationService
  private let sortFacts: @Sendable () async throws -> [OrganizationSortFacts]
  private let openPaper: @MainActor (OrganizedPaper) async throws -> Void
  private let importPDF: @MainActor () -> Void
  @State private var snapshot: OrganizationSnapshot?
  @State private var currentFacts: [UUID: OrganizationSortFacts] = [:]
  @State private var filter = OrganizationFilter()
  @State private var loading = true
  @State private var loadFailed = false
  @State private var operationFailed = false
  @State private var busy = false
  @State private var revision = 0
  @State private var deleting: OrganizedPaper?
  @State private var editing: OrganizedPaper?
  @FocusState private var focusedPaper: UUID?

  public init(service: LibraryOrganizationService,
    sortFacts: @escaping @Sendable () async throws -> [OrganizationSortFacts],
    openPaper: @escaping @MainActor (OrganizedPaper) async throws -> Void,
    importPDF: @escaping @MainActor () -> Void) {
    self.service = service; self.sortFacts = sortFacts
    self.openPaper = openPaper; self.importPDF = importPDF
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Library").font(.largeTitle)
        Spacer()
        Button("PDF 추가", action: importPDF)
        Button("새로고침") { Task { await refresh() } }
      }
      TextField("제목 또는 사용자 태그 검색", text: $filter.search)
        .textFieldStyle(.roundedBorder)
      HStack {
        Toggle("즐겨찾기만", isOn: $filter.favoritesOnly)
        Picker("읽기 상태", selection: $filter.readingStatus) {
          Text("전체").tag(Optional<PaperReadingStatus>.none)
          ForEach(PaperReadingStatus.allCases, id: \.self) { status in
            Text(readingLabel(status)).tag(Optional(status))
          }
        }
        TextField("태그 필터 (정확한 이름)", text: Binding(
          get: { filter.tag ?? "" }, set: { filter.tag = $0.isEmpty ? nil : $0 }))
      }
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
        Button("다시 불러오기") { Task { await refresh() } }
      } else if loading {
        ProgressView("라이브러리 불러오는 중")
      } else if let snapshot {
        if snapshot.totalCount == 0 {
          ContentUnavailableView("아직 논문이 없습니다", systemImage: "books.vertical",
            description: Text("PDF 추가로 시작하세요."))
          Button("PDF 추가", action: importPDF)
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
    .padding()
    .task { await refresh() }
    .onChange(of: filter) { _, _ in Task { await refresh() } }
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
    .sheet(item: $editing, onDismiss: { Task { await refresh() } }) { paper in
      OrganizationEditor(paper: paper) { value in
        try await service.save(value, for: paper)
      }
      .onDisappear { focusedPaper = paper.id }
    }
  }

  @ViewBuilder private func paperContent(_ paper: OrganizedPaper) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(paper.title).font(.headline).textSelection(.enabled)
      Text(statusLabel(paper)).font(.caption)
      Text("\(readingLabel(paper.organization.readingStatus)) · \(paper.organization.favorite ? "즐겨찾기" : "즐겨찾기 아님")")
      if !paper.organization.tags.isEmpty { Text(paper.organization.tags.joined(separator: " · ")).font(.caption) }
      if let year = currentFacts[paper.id]?.publicationYear { Text("발행연도 \(String(year))").font(.caption) }
      else { Text("발행연도 정보 없음").font(.caption).foregroundStyle(.secondary) }
      if let date = currentFacts[paper.id]?.lastReadAt {
        Text("최근 읽음 \(date.formatted())").font(.caption)
      }
      if paper.status == .importing { ProgressView(); Text("\(paper.bytesCopied) bytes 복사됨") }
      HStack {
        Button("열기") { perform { try await service.admitOpen(paper); try await openPaper(paper) } }
          .disabled(!paper.readable || busy)
        Menu("더 보기") {
          Button("태그·읽기 상태·즐겨찾기 편집") { editing = paper }.disabled(!paper.readable)
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
  private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
    guard !busy else { return }
    busy = true
    Task {
      do { try await operation() } catch { operationFailed = true }
      await refresh(); busy = false
    }
  }
  private func refresh() async {
    revision += 1
    let request = revision, requestedFilter = filter
    loading = true
    do {
      let facts = try await sortFacts()
      let value = try await service.snapshot(filter: requestedFilter, facts: facts)
      guard request == revision else { return }
      let generations = Dictionary(uniqueKeysWithValues: value.papers.map { ($0.id, $0.generation) })
      currentFacts = Dictionary(uniqueKeysWithValues: facts.filter { generations[$0.paperID] == $0.generation }.map { ($0.paperID, $0) })
      snapshot = value; loadFailed = false; loading = false
    } catch {
      guard request == revision else { return }
      loadFailed = true; loading = false
    }
  }
  private func readingLabel(_ status: PaperReadingStatus) -> String {
    switch status { case .unread: return "읽지 않음"; case .reading: return "읽는 중"; case .read: return "읽음" }
  }
  private func statusLabel(_ paper: OrganizedPaper) -> String {
    switch paper.status {
    case .ready: return paper.readable ? "PDF 읽기 가능" : "PDF 사용 불가 · 새로고침 또는 삭제"
    case .importing: return "가져오는 중"
    case .importFailed: return "가져오기 실패 · 삭제로 정리"
    case .deleting: return "삭제 중 · 열기 불가"
    case .deletionFailed: return "삭제 미완료 · 삭제 다시 시도"
    case .tombstone: return "삭제됨"
    }
  }
}

@MainActor private struct OrganizationEditor: View {
  let paper: OrganizedPaper
  let save: @MainActor (PaperOrganization) async throws -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var value: PaperOrganization
  @State private var tags: String
  @State private var busy = false
  @State private var failed = false
  init(paper: OrganizedPaper, save: @escaping @MainActor (PaperOrganization) async throws -> Void) {
    self.paper = paper; self.save = save
    _value = State(initialValue: paper.organization)
    _tags = State(initialValue: paper.organization.tags.joined(separator: "\n"))
  }
  var body: some View {
    Form {
      Text(paper.title).font(.headline)
      Picker("읽기 상태", selection: $value.readingStatus) {
        Text("읽지 않음").tag(PaperReadingStatus.unread)
        Text("읽는 중").tag(PaperReadingStatus.reading)
        Text("읽음").tag(PaperReadingStatus.read)
      }
      Toggle("즐겨찾기", isOn: $value.favorite)
      Text("사용자 태그 · 한 줄에 하나 (최대 100개, 각 80자)")
      TextEditor(text: $tags).frame(minHeight: 120).accessibilityLabel("사용자 태그")
      if failed { Text("저장 실패 · 현재 Paper와 PDF 상태를 확인하세요.") }
      HStack {
        Button("취소", role: .cancel) { dismiss() }
        Button("저장") {
          busy = true
          var draft = value
          draft.tags = tags.split(separator: "\n").map(String.init)
          Task {
            do { try await save(draft); dismiss() }
            catch { failed = true; busy = false }
          }
        }
      }.disabled(busy)
    }.padding().frame(minWidth: 400).interactiveDismissDisabled(busy)
  }
}
