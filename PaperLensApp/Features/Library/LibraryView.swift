import SwiftUI
import UniformTypeIdentifiers

/// Main presents this only after a real authenticated connection and explicit Continue.
/// This view neither establishes authentication nor creates an alternate admission owner.
@MainActor
public struct LibraryView: View {
  private let lifecycle: LocalLibraryLifecycle
  @State private var records: [LibraryRecord] = []
  @State private var selecting = false
  @State private var selectedSource: URL?
  @State private var confirmingImport = false
  @State private var deleting: LibraryRecord?
  @State private var operationFailure = false
  @State private var loadingFailure = false

  public init(lifecycle: LocalLibraryLifecycle) { self.lifecycle = lifecycle }

  public var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Text("Library").font(.largeTitle)
        Spacer()
        Button("PDF 추가") { selecting = true }
      }
      if loadingFailure {
        Text("라이브러리를 불러오지 못했습니다.").foregroundStyle(.red)
        Button("다시 불러오기") { Task { await refresh() } }
      } else if records.isEmpty {
        ContentUnavailableView("아직 논문이 없습니다", systemImage: "books.vertical",
          description: Text("로컬 PDF를 선택한 뒤 가져오기를 확인하세요."))
      } else {
        List(records) { record in
          HStack {
            VStack(alignment: .leading, spacing: 4) {
              Text(record.title).lineLimit(2)
              Text(statusLabel(record)).font(.caption).foregroundStyle(.secondary)
              if record.status == .importing {
                ProgressView()
                Text("\(record.bytesCopied.formatted()) bytes 복사됨").font(.caption)
              }
              if record.cleanupDebt && record.status == .importFailed {
                Text("남은 파일 정리가 필요합니다. 삭제로 정리하세요.").font(.caption)
              }
            }
            Spacer()
            if record.status == .deletionFailed {
              Button("Retry Deletion") { performDeletion(record, retry: true) }
            } else if record.status != .deleting {
              Button("삭제", role: .destructive) { deleting = record }
            }
          }
        }
      }
    }
    .padding(24)
    .fileImporter(isPresented: $selecting, allowedContentTypes: [.pdf], allowsMultipleSelection: false) { result in
      switch result {
      case .success(let urls):
        selectedSource = urls.first
        confirmingImport = selectedSource != nil
      case .failure:
        selectedSource = nil
        // Native picker cancellation is not a persisted failure or an import admission.
      }
    }
    .confirmationDialog("선택한 PDF의 개인 복사본을 가져오시겠습니까?",
      isPresented: $confirmingImport, titleVisibility: .visible) {
        Button("가져오기") {
          guard let source = selectedSource else { return }
          selectedSource = nil
          Task {
            do { _ = try await lifecycle.importPDF(from: source) }
            catch { operationFailure = true }
            await refresh()
          }
        }
        Button("취소", role: .cancel) { selectedSource = nil }
      }
    .confirmationDialog("논문과 앱이 소유한 데이터를 삭제하시겠습니까?",
      isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
      titleVisibility: .visible) {
        if let record = deleting {
          Button("삭제", role: .destructive) {
            deleting = nil
            performDeletion(record, retry: false)
          }
        }
        Button("취소", role: .cancel) { deleting = nil }
      }
    .alert("작업을 완료하지 못했습니다", isPresented: $operationFailure) {
      Button("확인", role: .cancel) {}
    } message: {
      Text("현재 저장된 상태를 확인하세요. 삭제 미완료 항목은 Retry Deletion으로 다시 시도할 수 있습니다.")
    }
    .task {
      while !Task.isCancelled {
        await refresh()
        do { try await Task.sleep(for: .milliseconds(300)) } catch { break }
      }
    }
  }

  private func refresh() async {
    do {
      records = try await lifecycle.list()
      loadingFailure = false
    } catch { loadingFailure = true }
  }

  private func performDeletion(_ record: LibraryRecord, retry: Bool) {
    Task {
      do {
        if retry { try await lifecycle.retryDeletion(paperID: record.id) }
        else { try await lifecycle.delete(paperID: record.id) }
      } catch { operationFailure = true }
      await refresh()
    }
  }

  private func statusLabel(_ record: LibraryRecord) -> String {
    switch record.status {
    case .importing: return "가져오는 중"
    case .ready: return "가져오기 완료"
    case .importFailed: return record.failure == "interrupted" ? "가져오기 중단됨" : "가져오기 실패"
    case .deleting: return "삭제 중"
    case .deletionFailed: return "삭제 미완료"
    case .tombstone: return "삭제됨"
    }
  }
}
