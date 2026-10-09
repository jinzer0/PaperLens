import SwiftUI

/// Reads persisted attempt/visibility state. Dispatching a task is never shown as success.
public struct ParsingStatusView: View {
  public let database: ProductDatabase
  public let paperID: UUID
  public let retry: (() async -> Void)?
  @State private var status: ExtractionStatus?
  @State private var unavailable = false

  public var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label(title, systemImage: icon)
        .accessibilityLabel(title)
      if status?.usableRevision != nil {
        Text("이전에 완성된 원문을 계속 사용할 수 있습니다.")
          .font(.caption)
      }
      if status?.state == "failed", let retry {
        Button("파싱 다시 시도") { Task { await retry(); await refresh() } }
      }
      Button("상태 새로 고침") { Task { await refresh() } }
    }
    .textSelection(.enabled)
    .task(id: paperID) {
      // Persisted polling continues while this view is mounted, including after restart.
      repeat {
        await refresh()
        do { try await Task.sleep(for: .seconds(1)) } catch { return }
      } while !Task.isCancelled
    }
  }

  private var title: String {
    if unavailable { return "파싱 상태를 불러올 수 없습니다." }
    switch status?.state {
    case "running": return "원문을 파싱하고 있습니다."
    case "succeeded": return "검색용 원문 준비가 완료되었습니다."
    case "failed":
      switch status?.failure {
      case "producerUnavailable": return "PDF 파싱 서비스가 연결되지 않았습니다."
      case "geometryUnavailable": return "검증된 문장 위치 계약이 연결되지 않았습니다."
      case "interrupted": return "파싱이 중단되었습니다. 다시 시도하세요."
      default: return "원문 파싱에 실패했습니다. 다시 시도하세요."
      }
    case "unavailable": return "현재 논문의 원문을 사용할 수 없습니다."
    default: return "검색용 원문이 아직 준비되지 않았습니다."
    }
  }

  private var icon: String {
    switch status?.state {
    case "succeeded": return "checkmark.circle"
    case "running": return "hourglass"
    case "failed", "unavailable": return "exclamationmark.triangle"
    default: return "doc.text.magnifyingglass"
    }
  }

  @MainActor private func refresh() async {
    let database = database
    let id = paperID
    do {
      status = try await Task.detached { try database.extractionStatus(paperID: id) }.value
      unavailable = false
    } catch { unavailable = true; status = nil }
  }
}
