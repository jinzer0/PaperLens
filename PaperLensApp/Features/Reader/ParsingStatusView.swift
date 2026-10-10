import SwiftUI

/// Tracks scheduling intent, not publication authority. The first nil/error matters too.
struct ParsingMetadataReconciliation {
  enum Outcome: Equatable { case revision(UUID?), unavailable }
  private var latest: Outcome?
  private var pending = true
  private var request: UUID?
  mutating func beginRequest() -> UUID {
    let value = UUID()
    request = value
    return value
  }
  func isCurrent(_ value: UUID) -> Bool { request == value }
  mutating func observe(_ outcome: Outcome, request: UUID) -> Bool {
    guard isCurrent(request) else { return false }
    return observe(outcome)
  }
  mutating func resolve(_ outcome: Outcome, completed: Bool, request: UUID) {
    guard isCurrent(request) else { return }
    resolve(outcome, completed: completed)
  }
  mutating func observe(_ outcome: Outcome) -> Bool {
    if latest != outcome { pending = true }
    latest = outcome
    return pending
  }
  mutating func resolve(_ outcome: Outcome, completed: Bool) {
    guard latest == outcome else { return }
    pending = !completed
  }
}

/// Presentation only: unavailable reads cannot leave an old failure presented as current.
enum ParsingFailureNotice {
  static func message(status: ExtractionStatus?, unavailable: Bool) -> String? {
    guard !unavailable, let status, status.state == "failed" else { return nil }
    return ParsingFailureMessage.korean(status.failure)
  }
}

/// Reads persisted attempt/visibility state. Dispatching a task is never shown as success.
public struct ParsingStatusView: View {
  public let database: ProductDatabase
  public let paperID: UUID
  public let coordinator: ParsingRecoveryCoordinator?
  private let onUsableRevisionChange: @MainActor () async -> Bool
  @State private var reconciliation = ParsingMetadataReconciliation()
  @State private var status: ExtractionStatus?
  @State private var recoveryContext: ParsingRecoveryContext?
  @State private var retrying = false
  @State private var retryFailure: String?
  @State private var unavailable = false

  public init(database: ProductDatabase, paperID: UUID,
    coordinator: ParsingRecoveryCoordinator? = nil,
    onUsableRevisionChange: @escaping @MainActor () async -> Bool) {
    self.database = database
    self.paperID = paperID
    self.coordinator = coordinator
    self.onUsableRevisionChange = onUsableRevisionChange
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("파싱 상태와 복구").font(.headline)
      Label(title, systemImage: icon)
        .accessibilityLabel(title)
      if status?.usableRevision != nil {
        Text("이전에 완성된 원문을 계속 사용할 수 있습니다.")
          .font(.caption)
      }
      Text("AI 기능 가용성").font(.subheadline)
      Text(aiPreparationReason).font(.caption)
      Text("Translation·Paper Chat·Brief 생성은 아직 구현되지 않았습니다.")
        .font(.caption).foregroundStyle(.secondary)
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
    .overlay(alignment: .bottomTrailing) {
      if let message = ParsingFailureNotice.message(status: status, unavailable: unavailable) {
        Label(message, systemImage: "exclamationmark.triangle")
          .font(.callout)
          .padding(12)
          .frame(maxWidth: 360, alignment: .leading)
          .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
          .overlay(RoundedRectangle(cornerRadius: 10).stroke(.secondary.opacity(0.4)))
          .shadow(radius: 3)
          .fixedSize(horizontal: false, vertical: true)
          // Float below the status block, not over its existing refresh/Retry controls.
          .alignmentGuide(.bottom) { $0[.top] - 8 }
          .allowsHitTesting(false)
          .accessibilityElement(children: .ignore)
          .accessibilityLabel("파싱 실패 알림. \(message)")
      }
    }
    .zIndex(1)
    .task(id: paperID) {
      status = nil
      recoveryContext = nil
      retryFailure = nil
      reconciliation = ParsingMetadataReconciliation()
      // Persisted polling continues while this view is mounted, including after restart.
      repeat {
        await refresh()
        do { try await Task.sleep(for: .seconds(1)) } catch { return }
      } while !Task.isCancelled
    }
  }

  private var aiPreparationReason: String {
    guard !unavailable, let status else {
      return "파싱 상태를 확인하기 전에는 AI용 원문의 준비 여부를 판단할 수 없습니다."
    }
    guard status.usableRevision != nil else {
      return "사용 가능한 추출 원문이 없어 번역·논문 대화·Brief 생성을 위한 원문이 준비되지 않았습니다."
    }
    return "사용 가능한 추출 원문이 있습니다. 원문 준비가 AI 기능의 실행 또는 완료를 의미하지는 않습니다."
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
    let request = reconciliation.beginRequest()
    do {
      let latest = try await Task.detached { try database.extractionStatus(paperID: id) }.value
      guard reconciliation.isCurrent(request), id == paperID, !Task.isCancelled else { return }
      let context = try await coordinator?.context(paperID: id)
      guard reconciliation.isCurrent(request), id == paperID, !Task.isCancelled else { return }
      status = latest
      recoveryContext = context
      unavailable = false
      await reconcile(.revision(latest.usableRevision), request: request)
    } catch {
      guard reconciliation.isCurrent(request), id == paperID, !Task.isCancelled else { return }
      unavailable = true
      status = nil
      recoveryContext = nil
      await reconcile(.unavailable, request: request)
    }
  }

  @MainActor private func reconcile(_ outcome: ParsingMetadataReconciliation.Outcome, request: UUID) async {
    guard reconciliation.observe(outcome, request: request) else { return }
    let completed = await onUsableRevisionChange()
    guard !Task.isCancelled, reconciliation.isCurrent(request) else { return }
    reconciliation.resolve(outcome, completed: completed, request: request)
  }
}
