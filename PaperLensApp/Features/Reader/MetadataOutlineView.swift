import PDFKit
import SwiftUI

public struct ReaderMetadataPresentation {
  public let identity: ReaderMetadataIdentity
  public let metadata: ReaderMetadataSnapshot
  public init(identity: ReaderMetadataIdentity, metadata: ReaderMetadataSnapshot) {
    self.identity = identity; self.metadata = metadata
  }
}

/// Parent owns live Paper/revision/read-lease revocation and the actual position observer.
/// Nothing in this view mutates durable state or starts extraction/recovery.
@MainActor
public struct MetadataOutlineView: View {
  public let currentIdentity: ReaderMetadataIdentity?
  public let presentation: ReaderMetadataPresentation?
  public let outline: ReaderOutlineAdapter?
  public let pdfView: PDFView
  public let observedLocation: ReaderConfirmedLocation?
  public let observedIdentity: ReaderMetadataIdentity?
  private let authorizeCurrent: () throws -> ReaderMetadataIdentity
  @State private var navigationError: String?

  public init(currentIdentity: ReaderMetadataIdentity?, presentation: ReaderMetadataPresentation?,
    outline: ReaderOutlineAdapter?, pdfView: PDFView, observedLocation: ReaderConfirmedLocation?,
    observedIdentity: ReaderMetadataIdentity?,
    authorizeCurrent: @escaping () throws -> ReaderMetadataIdentity) {
    self.currentIdentity = currentIdentity; self.presentation = presentation
    self.outline = outline; self.pdfView = pdfView
    self.observedLocation = observedLocation; self.observedIdentity = observedIdentity
    self.authorizeCurrent = authorizeCurrent
  }

  private var currentMetadata: ReaderMetadataSnapshot {
    guard let presentation, presentation.identity == currentIdentity else { return .init() }
    return presentation.metadata
  }
  private var currentOutline: ReaderOutlineAdapter? {
    guard let outline, outline.identity == currentIdentity, pdfView.document === outline.document else { return nil }
    return outline
  }
  private var activeSectionID: String? {
    guard observedIdentity == currentIdentity, let observedLocation else { return nil }
    return currentOutline?.activeSection(at: observedLocation)
  }

  public var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        Text("논문 정보").font(.headline).accessibilityAddTraits(.isHeader)
        field("제목", currentMetadata.title)
        field("발행연도", currentMetadata.year)
        field("Abstract", currentMetadata.abstract)
        field("Topic · 출처 정보", currentMetadata.topics)
        Divider()
        Text("목차").font(.headline).accessibilityAddTraits(.isHeader)
        if let outline = currentOutline, !outline.sections.isEmpty {
          ForEach(outline.sections) { section in
            Button {
              do {
                let current = try authorizeCurrent()
                try outline.navigate(sectionID: section.id, in: pdfView, current: current)
                navigationError = nil
              } catch let error as ReaderMetadataError { navigationError = error.message }
              catch { navigationError = "현재 논문의 위치를 확인할 수 없습니다. PDF는 계속 읽을 수 있습니다." }
            } label: {
              HStack(alignment: .top) {
                if activeSectionID == section.id { Image(systemName: "location.fill") }
                Text(section.title).multilineTextAlignment(.leading)
                if section.location == nil { Text("위치 미확인").foregroundStyle(.secondary) }
              }
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.leading, CGFloat(section.depth) * 12)
            }
            .buttonStyle(.borderless)
            .disabled(section.location == nil)
            .accessibilityLabel(section.title)
            .accessibilityValue(activeSectionID == section.id ? "현재 읽는 섹션" :
              (section.location == nil ? "위치 미확인" : "PDF 위치로 이동"))
          }
          if activeSectionID == nil { Text("현재 섹션 미확인").foregroundStyle(.secondary) }
        } else {
          Text("목차 미확인. PDF는 계속 읽을 수 있습니다.").foregroundStyle(.secondary)
        }
        if let navigationError {
          Label(navigationError, systemImage: "exclamationmark.triangle")
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .padding()
    }
    .background(.background)
    .onChange(of: currentIdentity) { navigationError = nil }
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
