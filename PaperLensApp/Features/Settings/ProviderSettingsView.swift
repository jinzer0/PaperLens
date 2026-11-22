import SwiftUI

@MainActor
func providerSettingsKeyBinding(
  _ entry: Binding<String>, service: ProviderSettingsService,
  isCurrent: @escaping @MainActor () -> Bool = { true }
) -> Binding<String> {
  Binding(
    get: { entry.wrappedValue },
    set: { value in
      guard isCurrent(), !service.candidatesBlocked else { return }
      if value != entry.wrappedValue {
        service.candidateEdited()
      }
      entry.wrappedValue = value
    }
  )
}

@MainActor
func submitProviderAPIKey(
  _ entry: Binding<String>, service: ProviderSettingsService,
  isCurrent: @escaping @MainActor () -> Bool = { true }
) {
  let submittedKey = entry.wrappedValue
  guard isCurrent(), !submittedKey.isEmpty, !service.isTesting, !service.candidatesBlocked else { return }
  service.reconnect(key: submittedKey) {
    guard isCurrent(), entry.wrappedValue == submittedKey else { return }
    entry.wrappedValue = ""
  }
}

@MainActor
public struct ProviderSettingsView: View {
  @ObservedObject private var service: ProviderSettingsService
  private let isCurrent: @MainActor () -> Bool
  @State private var key = ""
  @FocusState private var keyFocused: Bool

  public init(service: ProviderSettingsService) {
    self.init(service: service, isCurrent: { true })
  }

  init(service: ProviderSettingsService, isCurrent: @escaping @MainActor () -> Bool) {
    self.service = service
    self.isCurrent = isCurrent
  }

  public var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        Text("Provider 설정").font(.title2).accessibilityAddTraits(.isHeader)
        Text("현재 Provider: \(service.currentProviderLabel)")
        Text(service.availabilityMessage)
        if service.currentProviderLabel == "OpenAI API", service.eligibleForEntry,
          let selected = service.activeSelection {
          Text("연결 버전: \(selected.configGeneration)")
            .font(.caption).foregroundStyle(.secondary)
        }
        Divider()
        Text("OpenAI API 재연결").font(.headline)
        Text("모델: \(service.model)")
        Text("새 키로 실제 생성 요청을 보내 연결을 확인합니다. API 사용 요금이 발생할 수 있습니다.")
          .font(.callout)
        SecureField("새 API 키", text: providerSettingsKeyBinding($key, service: service, isCurrent: isCurrent))
          .textFieldStyle(.roundedBorder)
          .focused($keyFocused)
          .accessibilityLabel("재연결할 OpenAI API 키")
          .disabled(service.candidatesBlocked)
          .onSubmit { submit() }
        HStack {
          Button(actionTitle) { submit() }
            .disabled(key.isEmpty || service.isTesting || service.candidatesBlocked)
            .keyboardShortcut(.defaultAction)
          if service.isTesting {
            ProgressView().controlSize(.small).accessibilityLabel("새 연결 확인 중")
            Button("취소") {
              guard isCurrent() else { return }
              service.cancel()
              keyFocused = true
            }
            .keyboardShortcut(.cancelAction)
          }
        }
        candidateStatus
        if service.candidatesBlocked && !service.keyStorageBlocked {
          Text("진행 중인 ChatGPT 로그인이나 전용 저장소 정리가 끝나면 새 키를 확인할 수 있습니다.")
            .foregroundStyle(.secondary)
        }
        Divider()
        if let codex = service.codex {
          NativeCodexConnectionView(connection: codex, isCurrent: isCurrent)
        }
      }
      .padding(24)
      .frame(maxWidth: 640, alignment: .leading)
    }
    .frame(minWidth: 380, minHeight: 360)
    .task { if isCurrent() { service.restore() } }
    .onDisappear { key = "" }
  }

  private var actionTitle: String {
    if case .failed = service.phase { return "다시 시도" }
    return service.eligibleForEntry ? "새 키 확인 및 교체" : "연결 확인 및 저장"
  }

  private func submit() {
    submitProviderAPIKey($key, service: service, isCurrent: isCurrent)
  }

  @ViewBuilder private var candidateStatus: some View {
    switch service.phase {
    case .idle:
      Text("새 키를 입력한 뒤 연결 확인을 선택하세요.").foregroundStyle(.secondary)
    case .probing:
      Text("진행 중: 새 키의 인증된 생성 응답을 확인하고 있습니다.")
    case .connected:
      Text(
        service.currentProviderLabel == "OpenAI API" && service.eligibleForEntry
          ? "API 연결 확인과 저장이 완료되었습니다." : "현재 API 연결을 사용할 수 없습니다.")
    case .failed(let error):
      Label(error.koreanMessage, systemImage: "exclamationmark.triangle")
        .foregroundStyle(.red)
      if error == .persistenceFailure && service.keyStorageBlocked {
        Text("앱을 다시 열어 저장된 연결을 확인하세요.")
      } else if service.eligibleForEntry && !service.keyStorageBlocked {
        Text("새 연결은 적용하지 않았으며 기존 연결을 유지합니다.")
      }
    }
  }
}

/// Shared by entry and Settings; the retained coordinator owns every login effect.
@MainActor
public struct NativeCodexConnectionView: View {
  @ObservedObject private var connection: NativeCodexConnection
  @Environment(\.openURL) private var openURL
  private let isCurrent: @MainActor () -> Bool

  public init(connection: NativeCodexConnection) {
    self.init(connection: connection, isCurrent: { true })
  }

  init(connection: NativeCodexConnection, isCurrent: @escaping @MainActor () -> Bool) {
    self.connection = connection
    self.isCurrent = isCurrent
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("ChatGPT 연결").font(.headline)
      Text("공식 로그인 후 실제 생성 응답을 검사합니다. 사용량이 발생할 수 있습니다. 연결한 ChatGPT 계정으로 API 키 없이 논문 요약을 생성할 수 있습니다.")
        .font(.callout)
      HStack {
        Button(browserTitle) {
          if isCurrent() { connection.connect(mode: "browser") }
        }
        Button(deviceTitle) {
          if isCurrent() { connection.connect(mode: "device") }
        }
      }
      .disabled(!connection.canStart)
      if let instructions = connection.instructions, let intentID = connection.intentID,
        connection.phase == .signingIn || connection.phase == .observing
      {
        if let code = instructions.userCode {
          Text("기기 코드: \(code)")
            .font(.title3.monospaced()).textSelection(.enabled)
        }
        if instructions.url.scheme == "https", instructions.url.host != nil {
          Text(instructions.url.absoluteString)
            .font(.caption).textSelection(.enabled)
          Link("로그인 페이지 열기", destination: instructions.url)
            .environment(\.openURL, OpenURLAction { url in
              guard isCurrent(), connection.loginPageURL(intentID: intentID) == url else {
                return .discarded
              }
              openURL(url)
              return .handled
            })
        }
        Button("로그인 완료 확인") {
          if isCurrent() { connection.checkLogin(intentID: intentID) }
        }
          .disabled(connection.phase != .signingIn)
        Text("직접 선택할 때만 완료를 확인합니다. 확인 중에는 다시 요청하지 않으며 공통 세션 한도와 요청 제한 시간이 적용됩니다.")
          .font(.caption).foregroundStyle(.secondary)
      }
      if connection.hasPendingLogin, let intentID = connection.intentID {
        HStack {
          ProgressView().controlSize(.small).accessibilityLabel("ChatGPT 연결 진행 중")
          Button("ChatGPT 로그인 취소") {
            if isCurrent(), connection.intentID == intentID { connection.cancelUncommittedLogin() }
          }
        }
      } else if connection.phase == .retiring {
        ProgressView("실제 종료 및 정리 확인 중")
      } else if connection.canDisconnect {
        Button("ChatGPT 연결 해제") { if isCurrent() { connection.disconnect() } }
      }
      if connection.showsFailure {
        Label(connection.statusMessage, systemImage: "exclamationmark.triangle")
          .foregroundStyle(.red)
      } else {
        Text(connection.statusMessage)
      }
      if connection.canStart && connection.eligibleForEntry {
        Text("새 로그인이 확인될 때까지 현재 ChatGPT 연결을 유지합니다.")
          .font(.caption).foregroundStyle(.secondary)
      } else if !connection.loginStorageBlocked && connection.blocksReplacement {
        Text(
          "프로세스 종료와 전용 저장소 정리가 끝난 뒤 재연결하거나 Provider를 교체할 수 있습니다. 로그인 취소만으로 정리가 완료되지는 않습니다."
        )
        .font(.caption).foregroundStyle(.secondary)
      } else if !connection.loginStorageBlocked && !connection.canStart {
        Text("OpenAI API 작업 종료와 키 저장소 정리가 확인되면 ChatGPT에 연결할 수 있습니다.")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  private var browserTitle: String {
    if connection.offersRetry { return "브라우저 로그인 다시 시도" }
    return connection.eligibleForEntry ? "브라우저로 다시 로그인" : "브라우저로 로그인"
  }

  private var deviceTitle: String {
    if connection.offersRetry { return "기기 코드 로그인 다시 시도" }
    return connection.eligibleForEntry ? "기기 코드로 다시 로그인" : "기기 코드로 로그인"
  }
}
