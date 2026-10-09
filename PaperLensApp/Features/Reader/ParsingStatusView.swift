import SwiftUI

/// Reads persisted attempt/visibility state. Dispatching a task is never shown as success.
public struct ParsingStatusView: View {
  public let database: ProductDatabase
  public let paperID: UUID
  public let coordinator: ParsingRecoveryCoordinator?
  @State private var status: ExtractionStatus?
  @State private var recoveryContext: ParsingRecoveryContext?
  @State private var retrying = false
  @State private var retryFailure: String?
  @State private var unavailable = false

  public init(database: ProductDatabase, paperID: UUID,
    coordinator: ParsingRecoveryCoordinator? = nil) {
    self.database = database
    self.paperID = paperID
    self.coordinator = coordinator
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label(title, systemImage: icon)
        .accessibilityLabel(title)
      if status?.usableRevision != nil {
        Text("이전에 완성된 원문을 계속 사용할 수 있습니다.")
          .font(.caption)
      }
      if let retryFailure {
        Text(retryFailure)
          .accessibilityLabel(retryFailure)
      }
      if status?.state == "failed" {
        Button("파싱 다시 시도") { Task { await retryParsing() } }
          .disabled(retrying || recoveryContext == nil || coordinator == nil || unavailable)
        if coordinator == nil {
          Text("PDF 파싱 서비스가 연결되지 않았습니다.")
            .font(.caption)
        }
      }
      Button("상태 새로 고침") { Task { await refresh() } }
    }
    .textSelection(.enabled)
    .task(id: paperID) {
      status = nil
      recoveryContext = nil
      retryFailure = nil
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
      return ParsingFailureMessage.korean(status?.failure)
    case "unavailable": return "현재 논문의 원문을 사용할 수 없습니다."
    default: return "검색용 원문이 아직 준비되지 않았습니다."
    }
  }

  private var icon: String {
    if unavailable { return "exclamationmark.triangle" }
    switch status?.state {
    case "succeeded": return "checkmark.circle"
    case "running": return "hourglass"
    case "failed", "unavailable": return "exclamationmark.triangle"
    default: return "doc.text.magnifyingglass"
    }
  }

  @MainActor private func retryParsing() async {
    guard !retrying, let coordinator, let context = recoveryContext else { return }
    let id = paperID
    retrying = true
    retryFailure = nil
    defer { retrying = false }
    do { try await coordinator.retry(context) }
    catch {
      guard id == paperID else { return }
      if let failure = error as? ExtractionError {
        retryFailure = ParsingFailureMessage.korean(failure.rawValue)
      } else if error is ParsingRecoveryError {
        // A stale/duplicate action cannot replace the current attempt's notice.
        retryFailure = nil
      } else {
        retryFailure = "파싱을 다시 시도하지 못했습니다. 현재 상태를 확인하세요."
      }
    }
    guard id == paperID else { return }
    await refresh()
    if recoveryContext?.failedAttempt.attempt != context.failedAttempt.attempt {
      retryFailure = nil
    }
  }

  @MainActor private func refresh() async {
    let database = database
    let id = paperID
    do {
      let latest = try await Task.detached { try database.extractionStatus(paperID: id) }.value
      let context = try await coordinator?.context(paperID: id)
      guard id == paperID, !Task.isCancelled else { return }
      status = latest
      recoveryContext = context
      unavailable = false
    } catch {
      guard id == paperID, !Task.isCancelled else { return }
      unavailable = true
      status = nil
      recoveryContext = nil
    }
  }
}
