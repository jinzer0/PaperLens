import SwiftUI

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
        Text("현재 Provider: \(service.activeSelection == nil ? "없음" : "OpenAI API")")
        Text(service.availabilityMessage)
        if let selected = service.activeSelection {
          Text("연결 버전: \(selected.configGeneration)")
            .font(.caption).foregroundStyle(.secondary)
        }
        Divider()
        Text("OpenAI API 재연결").font(.headline)
        Text("모델: \(service.model)")
        Text("새 키로 실제 생성 요청을 보내 연결을 확인합니다. API 사용 요금이 발생할 수 있습니다.")
          .font(.callout)
        SecureField("새 API 키", text: $key)
          .textFieldStyle(.roundedBorder)
          .focused($keyFocused)
          .accessibilityLabel("재연결할 OpenAI API 키")
          .onSubmit { submit() }
          .onChange(of: key) { _, _ in service.candidateEdited() }
        HStack {
          Button(actionTitle) { submit() }
            .disabled(key.isEmpty || service.isTesting)
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
        Divider()
        Text("ChatGPT 연결").font(.headline)
        Text("이 Settings에서는 공식 ChatGPT 재로그인과 device-code 연결을 아직 제공하지 않습니다.")
          .foregroundStyle(.secondary)
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
    guard !key.isEmpty, !service.isTesting else { return }
    service.reconnect(key: key)
  }

  @ViewBuilder private var candidateStatus: some View {
    switch service.phase {
    case .idle:
      Text("새 키를 입력한 뒤 연결 확인을 선택하세요.").foregroundStyle(.secondary)
    case .probing:
      Text("진행 중: 새 키의 인증된 생성 응답을 확인하고 있습니다.")
    case .connected:
      Text(service.eligibleForEntry ? "연결 확인과 저장이 완료되었습니다." : "연결을 사용할 수 없습니다.")
    case .failed(let error):
      Label(error.koreanMessage, systemImage: "exclamationmark.triangle")
        .foregroundStyle(.red)
      if service.eligibleForEntry {
        Text("새 연결은 적용하지 않았으며 기존 연결을 유지합니다.")
      }
    }
  }
}
