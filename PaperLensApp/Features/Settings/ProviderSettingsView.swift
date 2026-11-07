import SwiftUI

@MainActor
func providerSettingsKeyBinding(
  _ entry: Binding<String>, service: ProviderSettingsService
) -> Binding<String> {
  Binding(
    get: { entry.wrappedValue },
    set: { value in
      guard !service.candidatesBlocked else { return }
      if value != entry.wrappedValue {
        service.candidateEdited()
      }
      entry.wrappedValue = value
    }
  )
}

@MainActor
public struct ProviderSettingsView: View {
  @ObservedObject private var service: ProviderSettingsService
  @State private var key = ""
  @FocusState private var keyFocused: Bool

  public init(service: ProviderSettingsService) {
    self.service = service
  }

  public var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        Text("Provider 설정").font(.title2).accessibilityAddTraits(.isHeader)
        Text("현재 Provider: \(service.currentProviderLabel)")
        Text(service.availabilityMessage)
        if service.currentProviderLabel == "OpenAI API", let selected = service.activeSelection {
          Text("연결 버전: \(selected.configGeneration)")
            .font(.caption).foregroundStyle(.secondary)
        }
        Divider()
        Text("OpenAI API 재연결").font(.headline)
        Text("모델: \(service.model)")
        Text("새 키로 실제 생성 요청을 보내 연결을 확인합니다. API 사용 요금이 발생할 수 있습니다.")
          .font(.callout)
        SecureField("새 API 키", text: providerSettingsKeyBinding($key, service: service))
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
              service.cancel()
              keyFocused = true
            }
            .keyboardShortcut(.cancelAction)
          }
        }
        candidateStatus
        if service.candidatesBlocked {
          Text("ChatGPT SDK 범위의 실제 정리가 입증되지 않아 새 API 키와 Provider 교체가 차단됩니다. 기존 유효한 선택은 유지됩니다.")
            .foregroundStyle(.secondary)
        }
        Divider()
        if let codex = service.codex {
          NativeCodexConnectionView(connection: codex)
        }
      }
      .padding(24)
      .frame(maxWidth: 640, alignment: .leading)
    }
    .frame(minWidth: 380, minHeight: 360)
    .task { service.restore() }
    .onDisappear {
      if service.isTesting { service.cancel() }
      key = ""
    }
  }

  private var actionTitle: String {
    if case .failed = service.phase { return "다시 시도" }
    return service.activeSelection == nil ? "연결 확인 및 저장" : "새 키 확인 및 교체"
  }

  private func submit() {
    guard !key.isEmpty, !service.isTesting, !service.candidatesBlocked else { return }
    service.reconnect(key: key)
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
      if service.eligibleForEntry {
        Text("새 연결은 적용하지 않았으며 기존 연결을 유지합니다.")
      }
    }
  }
}

/// Shared by entry and Settings; the retained coordinator owns every login effect.
@MainActor
public struct NativeCodexConnectionView: View {
  @ObservedObject private var connection: NativeCodexConnection

  public init(connection: NativeCodexConnection) {
    self.connection = connection
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("ChatGPT 연결").font(.headline)
      Text("공식 로그인 후 실제 생성 응답을 검사합니다. 사용량이 발생할 수 있습니다. 논문 요약은 OpenAI API 연결에서 사용할 수 있습니다.")
        .font(.callout)
      HStack {
        Button("브라우저로 로그인") { connection.connect(mode: "browser") }
        Button("기기 코드로 로그인") { connection.connect(mode: "device") }
      }
      .disabled(!connection.canStart)
      if let instructions = connection.instructions,
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
        }
        Button("로그인 완료 확인") { connection.checkLogin() }
          .disabled(connection.phase != .signingIn)
        Text("직접 선택할 때만 완료를 확인합니다. 확인 중에는 다시 요청하지 않으며 공통 세션 한도와 요청 제한 시간이 적용됩니다.")
          .font(.caption).foregroundStyle(.secondary)
      }
      if busy {
        HStack {
          ProgressView().controlSize(.small).accessibilityLabel("ChatGPT 연결 진행 중")
          Button("ChatGPT 연결 취소") { connection.cancel() }
        }
      } else if connection.phase == .retiring {
        ProgressView("실제 종료 및 정리 확인 중")
      } else if connection.phase == .connected {
        Button("ChatGPT 연결 해제") { connection.cancel() }
      }
      if connection.phase == .blocked {
        Label(connection.message, systemImage: "exclamationmark.triangle")
          .foregroundStyle(.red)
      } else {
        Text(connection.message)
      }
      if connection.blocksReplacement {
        Text(
          "프로세스 종료와 전용 저장소 정리가 끝난 뒤 재연결하거나 Provider를 교체할 수 있습니다. 로그인 취소만으로 정리가 완료되지는 않습니다."
        )
        .font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  private var busy: Bool {
    switch connection.phase {
    case .starting, .signingIn, .observing, .probing: return true
    case .idle, .connected, .retiring, .blocked: return false
    }
  }
}
