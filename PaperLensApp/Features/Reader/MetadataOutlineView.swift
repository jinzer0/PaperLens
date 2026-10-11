import SwiftUI

public struct ReaderMetadataPresentation {
  public let identity: ReaderMetadataIdentity
  public let metadata: ReaderMetadataSnapshot
  public init(identity: ReaderMetadataIdentity, metadata: ReaderMetadataSnapshot) {
    self.identity = identity; self.metadata = metadata
  }
}

/// Data-only presentation; the admitted binding exclusively authorizes PDF operations.
@MainActor
public struct MetadataOutlineView: View {
  @ObservedObject private var binding: ReaderMetadataBinding
  @State private var navigationError: String?

  public init(binding: ReaderMetadataBinding) { self.binding = binding }

  public var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        Text("논문 정보").font(.headline).accessibilityAddTraits(.isHeader)
        if let state = binding.state {
          field("제목", state.presentation.metadata.title)
          field("저자", .init())
          field("발행연도", state.presentation.metadata.year)
          Text("PDF 생성·수정 날짜는 발행연도가 아닙니다.")
            .font(.caption).foregroundStyle(.secondary)
          field("Abstract", state.presentation.metadata.abstract)
          field("Topic · 출처 정보", state.presentation.metadata.topics)
          Button("정보 새로고침") {
            do { try binding.refresh(); navigationError = nil }
            catch { report(error) }
          }
          Divider()
          Text("목차").font(.headline).accessibilityAddTraits(.isHeader)
          if !state.sections.isEmpty {
            ForEach(state.sections) { section in
              Button {
                do { try binding.navigate(sectionID: section.id); navigationError = nil }
                catch { report(error) }
              } label: {
                HStack(alignment: .top) {
                  if state.activeSectionID == section.id {
                    Image(systemName: "location.fill").accessibilityHidden(true)
                  }
                  Text(section.title).multilineTextAlignment(.leading)
                  if let location = section.location {
                    Text("\(location.pageIndex + 1)페이지").foregroundStyle(.secondary)
                  } else {
                    Text("위치 미확인").foregroundStyle(.secondary)
                  }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, CGFloat(section.depth) * 12)
              }
              .buttonStyle(.borderless)
              .disabled(section.location == nil)
              .accessibilityLabel(section.title)
              .accessibilityValue(contentsValue(section, active: state.activeSectionID == section.id))
              .accessibilityAddTraits(state.activeSectionID == section.id ? .isSelected : [])
              .accessibilityHint(section.location == nil ? "확인된 PDF 위치가 없어 이동할 수 없습니다." :
                "이 섹션의 PDF 위치로 이동을 요청합니다.")
            }
            if state.activeSectionID == nil { Text("현재 섹션 미확인").foregroundStyle(.secondary) }
          } else {
            Text("목차 미확인. PDF는 계속 읽을 수 있습니다.").foregroundStyle(.secondary)
          }
        } else {
          Text("현재 논문 정보를 사용할 수 없습니다. PDF는 계속 읽을 수 있습니다.")
            .foregroundStyle(.secondary)
        }
        if let navigationError {
          Label(navigationError, systemImage: "exclamationmark.triangle")
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .padding()
    }
    .background(.background)
    .onChange(of: binding.identity) { navigationError = nil }
  }

  private func report(_ error: Error) {
    navigationError = (error as? ReaderMetadataError)?.message
      ?? "현재 논문의 위치를 확인할 수 없습니다. PDF는 계속 읽을 수 있습니다."
  }

  private func contentsValue(_ section: ReaderMetadataOutlineRow, active: Bool) -> String {
    let location = section.location.map { "\($0.pageIndex + 1)페이지" } ?? "위치 미확인"
    return "\(section.depth + 1)단계, \(location)" + (active ? ", 현재 읽는 섹션" : "")
  }

  private func field(_ label: String, _ field: ReaderMetadataField) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(label).font(.subheadline.weight(.semibold))
      if field.isConflict {
        Label("출처 충돌 · 우선순위 미확인", systemImage: "exclamationmark.triangle")
      }
      Text(field.display).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
    }
    .accessibilityElement(children: .combine)
  }
}
