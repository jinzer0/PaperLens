import Foundation
import PDFKit

public struct ReaderMetadataIdentity: Equatable, Sendable {
  public let paperID: UUID
  public let generation: UUID
  public let pdfSHA256: String
  public let pdfReference: String
  public let revisionID: UUID
  public init(paperID: UUID, generation: UUID, pdfSHA256: String, pdfReference: String, revisionID: UUID) {
    self.paperID = paperID; self.generation = generation; self.pdfSHA256 = pdfSHA256
    self.pdfReference = pdfReference; self.revisionID = revisionID
  }
}

public enum ReaderMetadataError: Error, Equatable {
  case staleIdentity, invalidMetadata, invalidDestination, unavailableContents, staleConfirmation
  public var message: String {
    switch self {
    case .staleIdentity: return "현재 논문 정보가 변경되었습니다."
    case .invalidMetadata: return "출처 정보를 확인할 수 없습니다."
    case .invalidDestination: return "이 목차 위치로 이동할 수 없습니다. PDF는 계속 읽을 수 있습니다."
    case .unavailableContents: return "목차 미확인. PDF는 계속 읽을 수 있습니다."
    case .staleConfirmation: return "새로운 읽기 위치가 있어 이전 위치를 저장하지 않았습니다."
    }
  }
}

public struct ReaderMetadataValue: Codable, Equatable, Sendable {
  public enum Source: String, Codable, Sendable { case source, acceptedExtraction }
  public let text: String
  public let source: Source
  public let sourceID: String
  public init(text: String, source: Source, sourceID: String) {
    self.text = text; self.source = source; self.sourceID = sourceID
  }
}

/// Multiple distinct candidates remain an explicit conflict, never a guessed winner.
public struct ReaderMetadataField: Codable, Equatable, Sendable {
  public let candidates: [ReaderMetadataValue]
  public init(_ candidates: [ReaderMetadataValue] = []) { self.candidates = candidates }
  public var isConflict: Bool { Set(candidates.map(\.text)).count > 1 }
  public var display: String {
    if candidates.isEmpty { return "미확인" }
    return candidates.map { "\($0.text) [\($0.source.rawValue): \($0.sourceID)]" }
      .joined(separator: "\n")
  }
}

public struct ReaderMetadataSnapshot: Codable, Equatable, Sendable {
  public let title: ReaderMetadataField
  public let year: ReaderMetadataField
  public let abstract: ReaderMetadataField
  /// A candidate contains a source's actual topic list, not user tags.
  public let topics: ReaderMetadataField
  public init(title: ReaderMetadataField = .init(), year: ReaderMetadataField = .init(),
    abstract: ReaderMetadataField = .init(), topics: ReaderMetadataField = .init()) {
    self.title = title; self.year = year; self.abstract = abstract; self.topics = topics
  }
  func validate() throws {
    for field in [title, year, abstract, topics] {
      guard field.candidates.count <= 64 else { throw ReaderMetadataError.invalidMetadata }
      for value in field.candidates {
        guard !value.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          !value.sourceID.isEmpty, value.text.utf8.count <= 262_144,
          value.sourceID.utf8.count <= 4096 else { throw ReaderMetadataError.invalidMetadata }
      }
    }
  }
}

public struct ReaderConfirmedLocation: Codable, Equatable, Sendable {
  public let pageIndex: Int
  public let x: Double
  public let y: Double
  public init(pageIndex: Int, x: Double, y: Double) {
    self.pageIndex = pageIndex; self.x = x; self.y = y
  }
  public func isValid(pageCount: Int, bounds: CGRect) -> Bool {
    pageIndex >= 0 && pageIndex < pageCount && x.isFinite && y.isFinite
      && !bounds.isEmpty && bounds.contains(CGPoint(x: x, y: y))
  }
}

public struct ReaderMetadataContext: Codable, Equatable, Sendable {
  public let sessionID: UUID
  public let sequence: Int64
  public let location: ReaderConfirmedLocation?
  public let sectionID: String?
  public init(sessionID: UUID, sequence: Int64, location: ReaderConfirmedLocation?, sectionID: String?) {
    self.sessionID = sessionID; self.sequence = sequence
    self.location = location; self.sectionID = sectionID
  }
}

/// No source access or metadata generation. Parent supplies a current, read-leased identity.
public struct ReaderMetadataService: Sendable {
  private let database: ProductDatabase
  public init(database: ProductDatabase) { self.database = database }
  public func metadata(for identity: ReaderMetadataIdentity) throws -> ReaderMetadataSnapshot {
    try database.readerMetadata(for: identity) ?? ReaderMetadataSnapshot()
  }
  public func accept(_ snapshot: ReaderMetadataSnapshot, for identity: ReaderMetadataIdentity) throws {
    try snapshot.validate()
    try database.saveReaderMetadata(snapshot, for: identity)
  }
  public func beginSession(for identity: ReaderMetadataIdentity) throws -> ReaderMetadataContext {
    try database.beginReaderMetadataSession(for: identity)
  }
  @MainActor
  public func saveObservedPosition(in view: PDFView, using adapter: ReaderOutlineAdapter,
    expected: ReaderMetadataContext, for current: ReaderMetadataIdentity) async throws -> ReaderMetadataContext {
    let (location, sectionID) = try adapter.confirmedPosition(in: view, current: current)
    let database = database
    return try await Task.detached {
      try database.saveReaderMetadataContext(location, sectionID: sectionID, expected: expected, for: current)
    }.value
  }

  func saveConfirmed(_ location: ReaderConfirmedLocation, sectionID: String?,
    expected: ReaderMetadataContext, for identity: ReaderMetadataIdentity) throws -> ReaderMetadataContext {
    try database.saveReaderMetadataContext(location, sectionID: sectionID, expected: expected, for: identity)
  }
}

@MainActor
public final class ReaderOutlineAdapter {
  public struct Section: Identifiable {
    public let id: String
    public let title: String
    public let depth: Int
    public let location: ReaderConfirmedLocation?
    fileprivate let destination: PDFDestination?
  }
  public let document: PDFDocument
  public let identity: ReaderMetadataIdentity
  public private(set) var sections: [Section] = []
  public init(document: PDFDocument, identity: ReaderMetadataIdentity) {
    self.document = document; self.identity = identity
    if let root = document.outlineRoot { collect(root, path: "", depth: -1) }
  }
  private func collect(_ outline: PDFOutline, path: String, depth: Int) {
    guard depth < 64, sections.count < 4096 else { return }
    if depth >= 0 {
      let destination = outline.destination ?? (outline.action as? PDFActionGoTo)?.destination
      let location = destination.flatMap { try? validated($0) }
      sections.append(Section(id: path, title: outline.label ?? "미확인", depth: depth,
        location: location, destination: location == nil ? nil : destination))
    }
    for index in 0..<outline.numberOfChildren {
      guard sections.count < 4096 else { break }
      if let child = outline.child(at: index) { collect(child, path: "\(path)/\(index)", depth: depth + 1) }
    }
  }
  private func validated(_ destination: PDFDestination) throws -> ReaderConfirmedLocation {
    guard let page = destination.page, page.document === document else {
      throw ReaderMetadataError.invalidDestination
    }
    let location = ReaderConfirmedLocation(pageIndex: document.index(for: page),
      x: Double(destination.point.x), y: Double(destination.point.y))
    guard location.isValid(pageCount: document.pageCount, bounds: page.bounds(for: .cropBox)) else {
      throw ReaderMetadataError.invalidDestination
    }
    return location
  }
  /// Dispatch is only intent. This method does not report success or persist a position.
  public func navigate(sectionID: String, in view: PDFView, current: ReaderMetadataIdentity) throws {
    guard current == identity, view.document === document else { throw ReaderMetadataError.staleIdentity }
    guard let section = sections.first(where: { $0.id == sectionID }),
      let destination = section.destination else { throw ReaderMetadataError.invalidDestination }
    _ = try validated(destination)
    view.go(to: destination)
  }
  /// Call from the actual Reader position observer under its current read lease, not row selection.
  public func confirmedPosition(in view: PDFView, current: ReaderMetadataIdentity) throws
    -> (ReaderConfirmedLocation, String?) {
    guard current == identity, view.document === document else { throw ReaderMetadataError.staleIdentity }
    guard let destination = view.currentDestination else { throw ReaderMetadataError.invalidDestination }
    let location = try validated(destination)
    return (location, activeSection(at: location))
  }
  public func activeSection(at location: ReaderConfirmedLocation) -> String? {
    guard let page = document.page(at: location.pageIndex),
      location.isValid(pageCount: document.pageCount, bounds: page.bounds(for: .cropBox)) else { return nil }
    return sections.filter { section in
      guard let start = section.location else { return false }
      return start.pageIndex < location.pageIndex
        || (start.pageIndex == location.pageIndex && start.y >= location.y)
    }.max { lhs, rhs in
      guard let l = lhs.location, let r = rhs.location else { return false }
      return l.pageIndex == r.pageIndex ? l.y > r.y : l.pageIndex < r.pageIndex
    }?.id
  }
  /// Restored data is only a candidate until checked against the actual current document.
  public func validatedRestoration(_ context: ReaderMetadataContext) -> ReaderConfirmedLocation? {
    guard let location = context.location, let page = document.page(at: location.pageIndex),
      location.isValid(pageCount: document.pageCount, bounds: page.bounds(for: .cropBox)) else { return nil }
    return location
  }
}
