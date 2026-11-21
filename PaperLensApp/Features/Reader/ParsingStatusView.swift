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

/// The Reader receives safe display text from its single parsing status panel.
enum ParsingFailureNotice: PreferenceKey {
  static var defaultValue: String? { nil }

  static func reduce(value: inout String?, nextValue: () -> String?) {
    if let message = nextValue() { value = message }
  }

  static func message(status: ExtractionStatus?, unavailable: Bool) -> String? {
    guard !unavailable, let status, status.state == "failed" else { return nil }
    return ParsingFailureMessage.korean(status.failure)
  }
}

struct ParsingRetryFailure {
  private let context: ParsingRecoveryContext
  let message: String

  init?(error: any Error, context: ParsingRecoveryContext) {
    guard !(error is ParsingRecoveryError) else { return nil }
    self.context = context
    if let failure = error as? ExtractionError {
      message = ParsingFailureMessage.korean(failure.rawValue)
    } else {
      message = "파싱을 다시 시도하지 못했습니다. 현재 상태를 확인하세요."
    }
  }

  func matching(_ presentation: ParsingRecoveryCoordinator.Presentation?) -> Self? {
    guard presentation?.retry == context else { return nil }
    return self
  }
}

/// Reads persisted attempt/visibility state. Dispatching a task is never shown as success.
public struct ParsingStatusView: View {
  private struct ObservationTaskKey: Hashable {
    let paperID: UUID
    let restart: UUID
  }

  public let database: ProductDatabase
  public let paperID: UUID
  public let coordinator: ParsingRecoveryCoordinator?
  private let initialStartFailed: Bool
  private let startUnreservedParsing: (@MainActor () async -> Void)?
  private let onUsableRevisionChange: @MainActor () async -> Bool
  @State private var reconciliation = ParsingMetadataReconciliation()
  @State private var presentation: ParsingRecoveryCoordinator.Presentation?
  @State private var retrying = false
  @State private var retryFailure: ParsingRetryFailure?
  @State private var unavailable = false
  @State private var restartToken = UUID()
  @State private var trackingKey: ObservationTaskKey?
  @State private var trackingEnded = false
  @State private var presentationPaperID: UUID?

  private var status: ExtractionStatus? { presentation?.status }

  public init(database: ProductDatabase, paperID: UUID,
    coordinator: ParsingRecoveryCoordinator? = nil,
    initialStartFailed: Bool = false,
    startUnreservedParsing: (@MainActor () async -> Void)? = nil,
    onUsableRevisionChange: @escaping @MainActor () async -> Bool) {
    self.database = database
    self.paperID = paperID
    self.coordinator = coordinator
    self.initialStartFailed = initialStartFailed
    self.startUnreservedParsing = startUnreservedParsing
    self.onUsableRevisionChange = onUsableRevisionChange
  }

  public var body: some View {
    let key = ObservationTaskKey(paperID: paperID, restart: restartToken)
    VStack(alignment: .leading, spacing: 8) {
      Text("파싱 상태와 복구").font(.headline).accessibilityAddTraits(.isHeader)
      Label(title, systemImage: icon)
        .accessibilityLabel(title)
      if status?.usableRevision != nil {
        Text("이전에 완성된 원문을 계속 사용할 수 있습니다.")
          .font(.caption)
      }
      Text("AI 기능 가용성").font(.subheadline).accessibilityAddTraits(.isHeader)
      Text(aiPreparationReason).font(.caption)
      Text("Translation·Paper Chat·Brief 생성은 아직 구현되지 않았습니다.")
        .font(.caption).foregroundStyle(.secondary)
      if let message = retryFailure?.message {
        Label(message, systemImage: "exclamationmark.triangle")
          .accessibilityLabel(message)
      }
      if canStartParsing {
        Button(initialStartFailed ? "파싱 다시 시도" : "파싱 시작") {
          Task { await startParsing(key: key) }
        }
        .disabled(retrying)
        .accessibilityValue(retrying ? "요청 처리 중" : "")
      }
      if status?.state == "failed" {
        let displayedRetry = presentation?.retry
        Button(retrying ? "파싱 재시도 요청 중…" : "파싱 다시 시도") {
          guard let displayedRetry else { return }
          Task { await retryParsing(displayedRetry, key: key) }
        }
          .disabled(retrying || displayedRetry == nil || coordinator == nil || unavailable)
          .accessibilityValue(retrying ? "재시도 요청 처리 중" : "")
          .accessibilityHint("현재 논문의 파싱 재시도를 명시적으로 요청합니다. 완료를 의미하지 않습니다.")
        if coordinator == nil {
          Text("PDF 파싱 서비스가 연결되지 않았습니다.")
            .font(.caption)
        }
      }
      Button("상태 새로 고침") { Task { _ = await recoverTracking(key: key) } }
    }
    .textSelection(.enabled)
    .preference(key: ParsingFailureNotice.self, value: failureNotice)
    .task(id: key) {
      guard isCurrent(key), !Task.isCancelled else { return }
      if presentationPaperID != key.paperID {
        updatePresentation(nil)
        retrying = false
        unavailable = false
        reconciliation = ParsingMetadataReconciliation()
        presentationPaperID = key.paperID
      }
      trackingKey = key
      trackingEnded = false
      do {
        // A Retry-context change also invalidates presentation. Read back the latest
        // snapshot because a buffered value could precede an explicit refresh.
        for try await _ in database.parsingPresentations(paperID: key.paperID, includesRetry: coordinator != nil) {
          guard isCurrent(key), !Task.isCancelled else { return }
          await refresh(key: key)
        }
        guard isCurrent(key), !Task.isCancelled else { return }
        trackingEnded = true
      } catch {
        guard isCurrent(key), !Task.isCancelled else { return }
        trackingEnded = true
        let request = reconciliation.beginRequest()
        updatePresentation(nil)
        unavailable = true
        await reconcile(.unavailable, request: request)
      }
    }
  }

  private var canStartParsing: Bool {
    !unavailable && status?.state == "notStarted" && status?.usableRevision == nil
      && startUnreservedParsing != nil
  }

  private var failureNotice: String? {
    if canStartParsing && initialStartFailed {
      return "파싱을 시작하지 못했습니다. 다시 시도하세요."
    }
    return ParsingFailureNotice.message(status: status, unavailable: unavailable)
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
    default: return failureNotice ?? "검색용 원문이 아직 준비되지 않았습니다."
    }
  }

  private var icon: String {
    if unavailable || (canStartParsing && initialStartFailed) { return "exclamationmark.triangle" }
    switch status?.state {
    case "succeeded": return "checkmark.circle"
    case "running": return "hourglass"
    case "failed", "unavailable": return "exclamationmark.triangle"
    default: return "doc.text.magnifyingglass"
    }
  }

  private func isCurrent(_ key: ObservationTaskKey) -> Bool {
    key.paperID == paperID && key.restart == restartToken
  }

  @MainActor private func startParsing(key: ObservationTaskKey) async {
    guard isCurrent(key), !Task.isCancelled, canStartParsing, !retrying,
      let startUnreservedParsing else { return }
    retrying = true
    defer { if key.paperID == paperID { retrying = false } }
    await startUnreservedParsing()
    _ = await recoverTracking(key: key)
  }

  @MainActor private func retryParsing(_ context: ParsingRecoveryContext, key: ObservationTaskKey) async {
    guard isCurrent(key), !Task.isCancelled,
      !retrying, !unavailable, presentation?.retry == context, let coordinator else { return }
    let id = key.paperID
    retrying = true
    retryFailure = nil
    defer {
      if id == paperID { retrying = false }
    }
    let failure: ParsingRetryFailure?
    do {
      try await coordinator.retry(context)
      failure = nil
    } catch {
      failure = ParsingRetryFailure(error: error, context: context)
    }
    guard let recoveredKey = await recoverTracking(key: key),
      isCurrent(recoveredKey), !Task.isCancelled else { return }
    retryFailure = failure?.matching(presentation)
  }

  @MainActor private func recoverTracking(key: ObservationTaskKey) async -> ObservationTaskKey? {
    guard isCurrent(key), !Task.isCancelled else { return nil }
    await refresh(key: key)
    guard isCurrent(key), !Task.isCancelled else { return nil }
    guard trackingKey == key, trackingEnded else { return key }
    // Advancing the task key invalidates pending readback/reconciliation, not publication.
    _ = reconciliation.beginRequest()
    let restart = UUID()
    restartToken = restart
    trackingEnded = false
    return ObservationTaskKey(paperID: key.paperID, restart: restart)
  }

  @MainActor private func refresh(key: ObservationTaskKey) async {
    guard isCurrent(key), !Task.isCancelled else { return }
    let database = database
    let id = key.paperID
    let request = reconciliation.beginRequest()
    do {
      let latest: ParsingRecoveryCoordinator.Presentation
      if let coordinator {
        latest = try await coordinator.presentation(paperID: id)
      } else {
        let status = try await Task.detached { try database.extractionStatus(paperID: id) }.value
        latest = .init(status: status, retry: nil)
      }
      guard reconciliation.isCurrent(request), isCurrent(key), !Task.isCancelled else { return }
      updatePresentation(latest)
      unavailable = false
      await reconcile(.revision(latest.status.usableRevision), request: request)
    } catch {
      guard reconciliation.isCurrent(request), isCurrent(key), !Task.isCancelled else { return }
      unavailable = true
      updatePresentation(nil)
      await reconcile(.unavailable, request: request)
    }
  }

  @MainActor private func updatePresentation(_ latest: ParsingRecoveryCoordinator.Presentation?) {
    presentation = latest
    retryFailure = retryFailure?.matching(latest)
  }

  @MainActor private func reconcile(_ outcome: ParsingMetadataReconciliation.Outcome, request: UUID) async {
    guard reconciliation.observe(outcome, request: request) else { return }
    let completed = await onUsableRevisionChange()
    guard !Task.isCancelled, reconciliation.isCurrent(request) else { return }
    reconciliation.resolve(outcome, completed: completed, request: request)
  }
}
