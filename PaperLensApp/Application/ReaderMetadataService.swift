import Foundation
import GRDB
import PDFKit
#if SWIFT_PACKAGE
import ProviderRequest
#endif

/// Immutable native document identity, independent of extraction publication.
struct ReaderMetadataDocumentIdentity: Equatable {
  let paperID: UUID
  let generation: UUID
  let pdfSHA256: String
  let pdfReference: String
}

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
  case staleIdentity, invalidMetadata, invalidDestination, unavailableContents, staleConfirmation, sourceSaveFailed
  public var message: String {
    switch self {
    case .staleIdentity: return "현재 논문 정보가 변경되었습니다."
    case .invalidMetadata: return "출처 정보를 확인할 수 없습니다."
    case .invalidDestination: return "이 목차 위치로 이동할 수 없습니다. PDF는 계속 읽을 수 있습니다."
    case .unavailableContents: return "목차 미확인. PDF는 계속 읽을 수 있습니다."
    case .staleConfirmation: return "새로운 읽기 위치가 있어 이전 위치를 저장하지 않았습니다."
    case .sourceSaveFailed: return "PDF에서 읽은 출처 정보를 저장하지 못했습니다."
    }
  }
}

public struct ReaderMetadataValue: Codable, Equatable, Sendable {
  static let maximumUTF8Bytes = 262_144
  public enum Source: String, Codable, Sendable { case source, acceptedExtraction }
  public let text: String
  public let source: Source
  public let sourceID: String
  public init(text: String, source: Source, sourceID: String) {
    self.text = text; self.source = source; self.sourceID = sourceID
  }

  var isValid: Bool {
    text.utf8.count <= Self.maximumUTF8Bytes && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !sourceID.isEmpty && sourceID.utf8.count <= 4096
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
  private static let maximumCandidates = 64
  public let title: ReaderMetadataField
  public let year: ReaderMetadataField
  public let abstract: ReaderMetadataField
  /// A candidate contains a source's actual topic list, not user tags.
  public let topics: ReaderMetadataField
  public init(title: ReaderMetadataField = .init(), year: ReaderMetadataField = .init(),
    abstract: ReaderMetadataField = .init(), topics: ReaderMetadataField = .init()) {
    self.title = title; self.year = year; self.abstract = abstract; self.topics = topics
  }
  var isEmpty: Bool { [title, year, abstract, topics].allSatisfy { $0.candidates.isEmpty } }

  func validate() throws {
    for field in [title, year, abstract, topics] {
      guard field.candidates.count <= Self.maximumCandidates, field.candidates.allSatisfy(\.isValid) else {
        throw ReaderMetadataError.invalidMetadata
      }
    }
  }

  func mergingPDFSource(_ source: Self) -> Self {
    func merge(_ field: ReaderMetadataField, _ incoming: ReaderMetadataField) -> ReaderMetadataField {
      var candidates = field.candidates
      for candidate in incoming.candidates where candidates.count < Self.maximumCandidates {
        if candidate.source == .source && candidate.isValid && !candidates.contains(candidate) {
          candidates.append(candidate)
        }
      }
      return .init(candidates)
    }
    return Self(title: merge(title, source.title), year: merge(year, source.year),
      abstract: merge(abstract, source.abstract), topics: merge(topics, source.topics))
  }
}

/// Reads explicit, document-level source metadata from the already admitted PDF.
@MainActor enum PDFSourceMetadata {
  private static let rdf = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
  private static let dc = "http://purl.org/dc/elements/1.1/"
  private static let terms = "http://purl.org/dc/terms/"
  private static let prism = ["http://prismstandard.org/namespaces/basic/2.0/",
    "http://prismstandard.org/namespaces/basic/3.0/"]
  // Core Graphics returns the entire decoded stream. Even at the DEFLATE format's
  // theoretical 1032:1 expansion, that copy must fit the existing PDF byte limit.
  private static let maximumFlateBytes = ((try? ProviderRequest().limit("pdfBytes")) ?? 0) / 1032

  static func read(from document: PDFDocument, sha256: String) -> ReaderMetadataSnapshot {
    let source = "pdf:\(sha256)"
    let title = (document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)
      .map { ReaderMetadataValue(text: $0, source: .source, sourceID: source) }
    let original = ReaderMetadataSnapshot(title: .init([title].compactMap { $0 }.filter(\.isValid)))
    guard let packet = packet(from: document), let root = packet.rootElement() else { return original }
    let graph: XMLElement
    if root.localName == "RDF", root.uri == rdf {
      graph = root
    } else {
      guard root.localName == "xmpmeta", root.uri == "adobe:ns:meta/" else { return original }
      let graphs = root.elements(forLocalName: "RDF", uri: rdf)
      guard graphs.count == 1, let embedded = graphs.first else { return original }
      graph = embedded
    }

    var metadata = original
    let xmpSource = source + "#xmp"
    let descriptions = graph.elements(forLocalName: "Description", uri: rdf)
    let subjects = Set(descriptions.map { subjectURI(of: $0) })
    // A conforming XMP packet has one subject. In a mixed graph use only the
    // document subject, identified by the empty URI.
    guard let subject = subjects.contains("") ? "" : (subjects.count == 1 ? subjects.first : nil)
    else { return original }
    for element in descriptions where subjectURI(of: element) == subject {
      func field(_ values: [String]) -> ReaderMetadataField {
        .init(values.map { .init(text: $0, source: .source, sourceID: xmpSource) })
      }
      let dates = literals("issued", in: terms, of: element)
        + prism.flatMap { literals("publicationDate", in: $0, of: element) }
      metadata = metadata.mergingPDFSource(.init(
        title: field(literals("title", in: dc, of: element, container: "Alt")),
        year: field(dates.compactMap(publicationYear)),
        abstract: field(literals("abstract", in: terms, of: element, container: "Alt")),
        topics: field(topicList(in: element))))
    }
    return metadata
  }

  private static func subjectURI(of description: XMLElement) -> String {
    description.attribute(forLocalName: "about", uri: rdf)?.stringValue ?? ""
  }

  private static func packet(from document: PDFDocument) -> XMLDocument? {
    guard let source = document.documentRef, let catalog = source.catalog else { return nil }
    defer { withExtendedLifetime(source) {} }
    var stream: CGPDFStreamRef?
    guard CGPDFDictionaryGetStream(catalog, "Metadata", &stream), let stream,
      let dictionary = CGPDFStreamGetDictionary(stream) else { return nil }
    var length: CGPDFInteger = 0
    var subtype: UnsafePointer<CChar>?
    guard CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype,
      String(cString: subtype) == "XML",
      CGPDFDictionaryGetInteger(dictionary, "Length", &length), length > 0 else { return nil }
    let compressed = CGPDFDictionaryGetObject(dictionary, "Filter", nil)
    if compressed {
      guard hasSingleFlateFilter(dictionary),
        !CGPDFDictionaryGetObject(dictionary, "DecodeParms", nil),
        length <= maximumFlateBytes else { return nil }
    } else {
      guard length <= ReaderMetadataValue.maximumUTF8Bytes else { return nil }
    }
    var format = CGPDFDataFormat.raw
    guard let bytes = CGPDFStreamCopyData(stream, &format), format == .raw else { return nil }
    let count = CFDataGetLength(bytes)
    guard (1...ReaderMetadataValue.maximumUTF8Bytes).contains(count),
      compressed || count == length,
      let text = String(data: bytes as Data, encoding: .utf8), !text.contains("<!DOCTYPE")
    else { return nil }
    return try? XMLDocument(xmlString: text, options: [.nodeLoadExternalEntitiesNever])
  }

  private static func hasSingleFlateFilter(_ dictionary: CGPDFDictionaryRef) -> Bool {
    var name: UnsafePointer<CChar>?
    if !CGPDFDictionaryGetName(dictionary, "Filter", &name) {
      var filters: CGPDFArrayRef?
      guard CGPDFDictionaryGetArray(dictionary, "Filter", &filters), let filters,
        CGPDFArrayGetCount(filters) == 1, CGPDFArrayGetName(filters, 0, &name) else { return false }
    }
    return name.map { String(cString: $0) } == "FlateDecode"
  }

  private static func literals(_ name: String, in namespace: String, of description: XMLElement,
    container: String? = nil) -> [String] {
    var values = [description.attribute(forLocalName: name, uri: namespace)?.stringValue].compactMap { $0 }
    for element in description.elements(forLocalName: name, uri: namespace) {
      if let value = literal(element) {
        values.append(value)
      } else if let container, let array = element.elements(forLocalName: container, uri: rdf).first {
        let items = array.elements(forLocalName: "li", uri: rdf)
        let defaults = container == "Alt" ? items.filter {
          $0.attribute(forLocalName: "lang", uri: "http://www.w3.org/XML/1998/namespace")?.stringValue
            == "x-default"
        } : []
        values.append(contentsOf: (defaults.isEmpty ? items : defaults).compactMap(literal))
      }
    }
    return values
  }

  private static func literal(_ element: XMLElement) -> String? {
    guard element.children?.allSatisfy({ $0.kind == .text || $0.kind == .comment }) == true else { return nil }
    return element.stringValue
  }

  private static func topicList(in description: XMLElement) -> [String] {
    let values = literals("subject", in: dc, of: description, container: "Bag")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    return values.isEmpty ? [] : [values.joined(separator: ", ")]
  }

  private static func publicationYear(_ rawDate: String) -> String? {
    let date = rawDate.trimmingCharacters(in: .whitespacesAndNewlines)
    let timestamp = date.split(separator: "T", omittingEmptySubsequences: false)
    guard timestamp.count <= 2, let datePart = timestamp.first else { return nil }
    let parts = datePart.split(separator: "-", omittingEmptySubsequences: false)
    func digits(_ text: Substring, count: Int) -> Int? {
      guard text.utf8.count == count, text.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
      return Int(text)
    }
    guard let yearPart = parts.first, let year = digits(yearPart, count: 4), year > 0
    else { return nil }
    if parts.count == 1 { return timestamp.count == 1 ? String(yearPart) : nil }
    guard let month = digits(parts[1], count: 2), (1...12).contains(month) else { return nil }
    if parts.count == 2 { return timestamp.count == 1 ? String(yearPart) : nil }
    guard parts.count == 3, let day = digits(parts[2], count: 2),
      DateComponents(year: year, month: month, day: day).isValidDate(in: Calendar(identifier: .gregorian))
    else { return nil }
    if timestamp.count == 2 {
      let time = #"^(?:[01][0-9]|2[0-3]):[0-5][0-9](?::[0-5][0-9](?:\.[0-9]+)?)?(?:Z|[+-](?:[01][0-9]|2[0-3]):[0-5][0-9])?$"#
      guard timestamp[1].range(of: time, options: .regularExpression) != nil else { return nil }
    }
    return String(yearPart)
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
    let left = Double(bounds.minX), right = Double(bounds.maxX)
    let bottom = Double(bounds.minY), top = Double(bounds.maxY)
    // A PDF destination can lie exactly on any CropBox edge, including the top of a page.
    return pageIndex >= 0 && pageIndex < pageCount && !bounds.isInfinite
      && [x, y, left, right, bottom, top].allSatisfy(\.isFinite)
      && left < right && bottom < top && left <= x && x <= right && bottom <= y && y <= top
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
  func documentIdentity(paperID: UUID) throws -> ReaderMetadataDocumentIdentity {
    let paper = try database.readerSnapshot(paperID: paperID)
    let identity: AnnotationPaperIdentity
    do { identity = try database.annotationIdentity(paperID: paperID) }
    catch AnnotationError.stalePaper { throw ReaderMetadataError.staleIdentity }
    guard paper.paperID == identity.id, paper.generation == identity.generation else {
      throw ReaderMetadataError.staleIdentity
    }
    return ReaderMetadataDocumentIdentity(paperID: paperID, generation: paper.generation,
      pdfSHA256: identity.pdfSHA256, pdfReference: paper.pdfReference)
  }

  public func metadata(for identity: ReaderMetadataIdentity) throws -> ReaderMetadataSnapshot {
    try database.readerMetadata(for: identity) ?? ReaderMetadataSnapshot()
  }
  public func accept(_ snapshot: ReaderMetadataSnapshot, for identity: ReaderMetadataIdentity) throws {
    try snapshot.validate()
    try database.saveReaderMetadata(snapshot, for: identity)
  }
  /// Called while the binding borrows the actual admitted PDF under its read lease.
  func recordPDFSource(_ source: ReaderMetadataSnapshot,
    for identity: ReaderMetadataIdentity) throws -> ReaderMetadataSnapshot {
    do {
      return try database.adapterWrite { try ProductDatabase.mergeReaderPDFSource(source, for: identity, in: $0) }
    } catch is DatabaseError {
      throw ReaderMetadataError.sourceSaveFailed
    }
  }
  public func beginSession(for identity: ReaderMetadataIdentity) throws -> ReaderMetadataContext {
    try database.beginReaderMetadataSession(for: identity)
  }
  /// Read-only CAS check before restoration; a navigation request must not renew a stale session.
  func validateContext(_ expected: ReaderMetadataContext, for identity: ReaderMetadataIdentity) throws {
    try database.adapterRead { db in
      guard let data = try Data.fetchOne(db, sql: """
        SELECT payload FROM readerMetadataContext
        WHERE paperID = ? AND revisionID = ? AND sessionID = ? AND sequence = ?
        """, arguments: [identity.paperID.uuidString, identity.revisionID.uuidString,
          expected.sessionID.uuidString, expected.sequence]),
        try JSONDecoder().decode(ReaderMetadataContext.self, from: data) == expected else {
        throw ReaderMetadataError.staleConfirmation
      }
    }
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
    /// Missing coordinates anchor section ordering at the displayed start of the page.
    public let location: ReaderConfirmedLocation?
    fileprivate let destination: PDFDestination?
    fileprivate let displayedY: CGFloat?
  }
  public let document: PDFDocument
  public let identity: ReaderMetadataIdentity?
  public private(set) var sections: [Section] = []
  public init(document: PDFDocument, identity: ReaderMetadataIdentity?) {
    self.document = document; self.identity = identity
    if let root = document.outlineRoot { collect(root, path: "", depth: -1) }
  }
  private func collect(_ outline: PDFOutline, path: String, depth: Int) {
    guard depth < 64, sections.count < 4096 else { return }
    if depth >= 0 {
      let destination = outline.destination ?? (outline.action as? PDFActionGoTo)?.destination
      let location = destination.flatMap { try? validatedOutlineLocation($0) }
      let y = location.flatMap { location in
        destination?.page.flatMap { displayedY(at: location, on: $0) }
      }
      sections.append(Section(id: path, title: outline.label ?? "미확인", depth: depth,
        location: location, destination: location == nil ? nil : destination, displayedY: y))
    }
    for index in 0..<outline.numberOfChildren {
      guard sections.count < 4096 else { break }
      if let child = outline.child(at: index) { collect(child, path: "\(path)/\(index)", depth: depth + 1) }
    }
  }
  private func validatedOutlineLocation(_ destination: PDFDestination) throws -> ReaderConfirmedLocation {
    guard let page = destination.page, page.document === document else {
      throw ReaderMetadataError.invalidDestination
    }
    let bounds = page.bounds(for: .cropBox)
    var point = destination.point
    if point.x == kPDFDestinationUnspecifiedValue || point.y == kPDFDestinationUnspecifiedValue {
      // PDFKit leaves axes unset for page-fit and partial XYZ destinations.
      // Only the outline anchor needs coordinates; navigation keeps the original destination.
      let transform = page.transform(for: .cropBox)
      if point.x == kPDFDestinationUnspecifiedValue {
        point.x = transform.b > 0 ? bounds.maxX : bounds.minX
      }
      if point.y == kPDFDestinationUnspecifiedValue {
        point.y = transform.d < 0 ? bounds.minY : bounds.maxY
      }
    }
    let location = ReaderConfirmedLocation(pageIndex: document.index(for: page),
      x: Double(point.x), y: Double(point.y))
    guard location.isValid(pageCount: document.pageCount, bounds: bounds) else {
      throw ReaderMetadataError.invalidDestination
    }
    return location
  }
  /// Dispatch is only intent. This method does not report success or persist a position.
  public func navigate(sectionID: String, in view: PDFView, current: ReaderMetadataIdentity?) throws {
    guard current == identity, view.document === document else { throw ReaderMetadataError.staleIdentity }
    guard let section = sections.first(where: { $0.id == sectionID }),
      let destination = section.destination else { throw ReaderMetadataError.invalidDestination }
    _ = try validatedOutlineLocation(destination)
    view.go(to: destination)
  }
  /// Call from the actual Reader position observer under its current read lease, not row selection.
  public func confirmedPosition(in view: PDFView, current: ReaderMetadataIdentity) throws
    -> (ReaderConfirmedLocation, String?) {
    guard current == identity, view.document === document else { throw ReaderMetadataError.staleIdentity }
    let location = try Self.observedLocation(from: view.currentDestination, in: view, document: document)
    return (location, activeSection(at: location))
  }

  static func observedLocation(from destination: PDFDestination?, in view: PDFView,
    document: PDFDocument) throws -> ReaderConfirmedLocation {
    guard view.document === document else { throw ReaderMetadataError.staleIdentity }
    guard let destination, let page = destination.page,
      page.document === document else { throw ReaderMetadataError.invalidDestination }
    let point = destination.point
    let pageIndex = document.index(for: page)
    let crop = page.bounds(for: .cropBox)
    func validatedLocation(at point: CGPoint) -> ReaderConfirmedLocation? {
      let location = ReaderConfirmedLocation(pageIndex: pageIndex, x: Double(point.x), y: Double(point.y))
      return location.isValid(pageCount: document.pageCount, bounds: crop) ? location : nil
    }
    if let location = validatedLocation(at: point) { return location }

    // PDFKit can report the viewport origin in the margin beside a centered page.
    // Derive the reading point from the actual visible part of that same page.
    guard point.x.isFinite, point.y.isFinite,
      point.x != kPDFDestinationUnspecifiedValue, point.y != kPDFDestinationUnspecifiedValue,
      let window = view.window, !view.isHiddenOrHasHiddenAncestor, view.currentPage === page,
      let clip = view.documentView?.enclosingScrollView?.contentView, clip.window === window,
      clip.isDescendant(of: view) else { throw ReaderMetadataError.invalidDestination }
    let viewport = view.convert(clip.bounds, from: clip).intersection(view.bounds)
    let visiblePage = view.convert(crop, from: page).intersection(viewport)
    guard !visiblePage.isEmpty, !visiblePage.isInfinite else { throw ReaderMetadataError.invalidDestination }
    let top = view.isFlipped ? visiblePage.minY : visiblePage.maxY
    guard let location = validatedLocation(at: view.convert(CGPoint(x: visiblePage.minX, y: top), to: page)) else {
      throw ReaderMetadataError.invalidDestination
    }
    return location
  }
  public func activeSection(at location: ReaderConfirmedLocation) -> String? {
    guard let page = document.page(at: location.pageIndex),
      location.isValid(pageCount: document.pageCount, bounds: page.bounds(for: .cropBox)),
      let currentY = displayedY(at: location, on: page) else { return nil }
    return sections.lazy.compactMap { section -> (id: String, pageIndex: Int, y: CGFloat)? in
      guard let start = section.location, let y = section.displayedY,
        start.pageIndex < location.pageIndex
          || (start.pageIndex == location.pageIndex && y >= currentY) else { return nil }
      return (section.id, start.pageIndex, y)
    }.max { lhs, rhs in
      lhs.pageIndex == rhs.pageIndex ? lhs.y > rhs.y : lhs.pageIndex < rhs.pageIndex
    }?.id
  }

  // Reader scrolls vertically. Compare the rotated crop-box heights, while
  // keeping destinations and saved positions in their original page space.
  private func displayedY(at location: ReaderConfirmedLocation, on page: PDFPage) -> CGFloat? {
    let point = CGPoint(x: location.x, y: location.y).applying(page.transform(for: .cropBox))
    return point.y.isFinite ? point.y : nil
  }

  /// Restored data is only a candidate until checked against the actual current document.
  public func validatedRestoration(_ context: ReaderMetadataContext) -> ReaderConfirmedLocation? {
    guard let location = context.location,
      location.pageIndex >= 0, location.pageIndex < document.pageCount,
      let page = document.page(at: location.pageIndex),
      page.document === document,
      location.isValid(pageCount: document.pageCount, bounds: page.bounds(for: .cropBox)) else { return nil }
    return location
  }

  /// A freshly validated destination, borrowed only inside the caller's Reader access.
  func restorationDestination(_ context: ReaderMetadataContext) -> PDFDestination? {
    guard let location = validatedRestoration(context),
      let page = document.page(at: location.pageIndex), page.document === document,
      location.isValid(pageCount: document.pageCount, bounds: page.bounds(for: .cropBox)) else { return nil }
    return PDFDestination(page: page, at: CGPoint(x: location.x, y: location.y))
  }
}
