import SwiftUI

/// Native key entry only. The parent composes the genuine Codex browser/device flow
/// separately and routes entry from the verified selector, never a local UI flag.
@MainActor
public struct APIKeyConnectionView: View {
  @ObservedObject private var connection: NativeAPIKeyConnection
  @ObservedObject private var provider: ProviderSettingsService
  @State private var key = ""

  public init(connection: NativeAPIKeyConnection, codex: NativeCodexConnection? = nil) {
    self.connection = connection
    self.provider = ProviderSettingsService(connection: connection, codex: codex)
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("OpenAI API 키 연결").font(.title2)
      Text("엔드포인트: https://api.openai.com/v1/chat/completions")
        .font(.caption).textSelection(.enabled)
      Text("모델: \(connection.configuration.model)")
      Text("실제 생성 요청으로 연결을 확인합니다. API 사용 요금이 발생할 수 있습니다.")
        .font(.callout)
      SecureField("API 키", text: keyBinding)
        .textFieldStyle(.roundedBorder)
        .onSubmit { submit() }
        .accessibilityLabel("OpenAI API 키")
        .disabled(provider.candidatesBlocked)
      HStack {
        Button(buttonTitle) { submit() }
          .disabled(key.isEmpty || connection.phase == .probing || provider.candidatesBlocked)
          .keyboardShortcut(.defaultAction)
        if connection.phase == .probing {
          ProgressView().controlSize(.small)
          Button("취소") { connection.cancel() }
        }
      }
      status
      if provider.candidatesBlocked {
        Text("ChatGPT SDK 정리가 입증되지 않아 새 키 입력과 Provider 교체가 차단됩니다. 기존 유효한 연결 선택은 유지됩니다.")
          .foregroundStyle(.secondary)
      }
      if connection.activeSelection != nil && !connection.eligibleForEntry {
        Text("저장된 연결이 있지만 현재 안전한 사용 조건을 확인할 수 없습니다.")
          .foregroundStyle(.red)
      }
      Text("연결 확인은 모델 제한 인증을 의미하지 않습니다. 실제 모델 제한 적용은 아직 미검증입니다.")
        .font(.caption).foregroundStyle(.secondary)
    }
    .padding(24)
    .frame(minWidth: 460, maxWidth: 640, alignment: .leading)
    .task { connection.restore() }
    .onDisappear {
      key = ""
      connection.invalidateCandidate()
    }
  }

  private var keyBinding: Binding<String> {
    Binding(
      get: { key },
      set: { value in
        guard !provider.candidatesBlocked else { return }
        guard value != key else { return }
        connection.invalidateCandidate()
        key = value
      })
  }

  private var buttonTitle: String {
    if case .failed = connection.phase { return "다시 시도" }
    return connection.activeSelection == nil ? "연결 확인 및 저장" : "새 키 확인 및 교체"
  }
  private func submit() {
    guard !key.isEmpty, connection.phase != .probing, !provider.candidatesBlocked else { return }
    connection.connect(key: key)
  }
  @ViewBuilder private var status: some View {
    switch connection.phase {
    case .idle:
      Text("API 키를 입력해 연결을 확인하세요.").foregroundStyle(.secondary)
    case .probing:
      Text("새 키로 인증된 생성 응답을 확인하는 중입니다.")
    case .connected:
      if connection.eligibleForEntry {
        Text("연결 확인과 선택 저장을 완료했습니다.").foregroundStyle(.green)
      } else {
        Text("연결을 안전하게 사용할 수 없습니다.").foregroundStyle(.red)
      }
    case .failed(let error):
      Text(error.koreanMessage).foregroundStyle(.red)
      if connection.eligibleForEntry {
        Text("기존에 확인된 연결은 유지됩니다.").foregroundStyle(.secondary)
      }
    }
  }
}
