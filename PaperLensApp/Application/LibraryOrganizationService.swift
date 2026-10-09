import Foundation

public enum LibraryPresentation: String, CaseIterable, Sendable { case list, grid }
public enum LibrarySort: String, CaseIterable, Sendable {
  case recentlyRead, name, recentlyAdded, publicationYear
}
public enum PaperReadingStatus: String, CaseIterable, Sendable { case unread, reading, read }
public struct OrganizationPreferences: Equatable, Sendable {
  public var presentation: LibraryPresentation
  public var sort: LibrarySort
  public init(presentation: LibraryPresentation = .list, sort: LibrarySort = .recentlyRead) {
    self.presentation = presentation; self.sort = sort
  }
}
public struct PaperOrganization: Equatable, Sendable {
  public var readingStatus: PaperReadingStatus
  public var favorite: Bool
  public var tags: [String]
  public init(readingStatus: PaperReadingStatus = .unread, favorite: Bool = false, tags: [String] = []) {
    self.readingStatus = readingStatus; self.favorite = favorite; self.tags = tags
  }
}
public struct OrganizationFilter: Equatable, Sendable {
  public var search = ""
  public var tag: String?
  public var readingStatus: PaperReadingStatus?
  public var favoritesOnly = false
  public init() {}
}
/// Parent supplies only accepted Reader/metadata values, bound to this exact Paper generation.
public struct OrganizationSortFacts: Sendable {
  public let paperID: UUID
  public let generation: UUID
  public let lastReadAt: Date?
  public let publicationYear: Int?
  public init(paperID: UUID, generation: UUID, lastReadAt: Date?, publicationYear: Int?) {
    self.paperID = paperID; self.generation = generation
    self.lastReadAt = lastReadAt; self.publicationYear = publicationYear
  }
}
public struct OrganizedPaper: Identifiable, Equatable, Sendable {
  public let id: UUID
  public let generation: UUID
  public let title: String
  public let status: LibraryStatus
  public let failure: String?
  public let bytesCopied: Int64
  public let createdAt: Date
  public let readable: Bool
  public let organization: PaperOrganization
}
public struct OrganizationSnapshot: Sendable {
  public let preferences: OrganizationPreferences
  public let totalCount: Int
  public let papers: [OrganizedPaper]
}
public enum OrganizationError: Error, Equatable, Sendable {
  case stalePaper, unavailablePDF, invalidTags, invalidSortFacts
}

/// SQL and filesystem checks live exclusively in the Infrastructure adapter.
public actor LibraryOrganizationService {
  private let database: ProductDatabase
  private let lifecycle: LocalLibraryLifecycle
  public init(database: ProductDatabase, lifecycle: LocalLibraryLifecycle) {
    self.database = database; self.lifecycle = lifecycle
  }

  public func snapshot(filter: OrganizationFilter, facts: [OrganizationSortFacts]) async throws -> OrganizationSnapshot {
    let database = database
    let result = try await Task.detached { try database.organizationSnapshot(filter: filter) }.value
    var byID: [UUID: OrganizationSortFacts] = [:]
    for fact in facts {
      guard byID.updateValue(fact, forKey: fact.paperID) == nil,
        fact.lastReadAt?.timeIntervalSince1970.isFinite != false,
        fact.publicationYear.map({ (1...9999).contains($0) }) != false
      else { throw OrganizationError.invalidSortFacts }
    }
    func currentFacts(_ paper: OrganizedPaper) -> OrganizationSortFacts? {
      guard let fact = byID[paper.id], fact.generation == paper.generation else { return nil }
      return fact
    }
    let papers = result.papers.sorted { lhs, rhs in
      switch result.preferences.sort {
      case .name:
        let a = Self.normalized(lhs.title), b = Self.normalized(rhs.title)
        if a != b { return a < b }
      case .recentlyAdded:
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
      case .recentlyRead:
        let a = currentFacts(lhs)?.lastReadAt, b = currentFacts(rhs)?.lastReadAt
        if a != b { return Self.descending(a, b) }
      case .publicationYear:
        let a = currentFacts(lhs)?.publicationYear, b = currentFacts(rhs)?.publicationYear
        if a != b { return Self.descending(a, b) }
      }
      return lhs.id.uuidString < rhs.id.uuidString
    }
    return OrganizationSnapshot(preferences: result.preferences, totalCount: result.totalCount, papers: papers)
  }

  public func savePreferences(_ preferences: OrganizationPreferences) async throws {
    let database = database
    try await Task.detached { try database.setOrganizationPreferences(preferences) }.value
  }
  public func save(_ organization: PaperOrganization, for paper: OrganizedPaper) async throws {
    let database = database
    try await Task.detached {
      try database.updatePaperOrganization(paperID: paper.id, generation: paper.generation, value: organization)
    }.value
  }
  public func admitOpen(_ paper: OrganizedPaper) async throws {
    let database = database
    try await Task.detached { try database.admitOrganizationOpen(paperID: paper.id, generation: paper.generation) }.value
  }
  /// Lifecycle owns revocation, draining and same-saga retry. Parent read-lease integration
  /// must keep this generation check and lifecycle admission in the same arbitration domain.
  public func delete(_ paper: OrganizedPaper, retry: Bool) async throws {
    let database = database
    try await Task.detached { try database.validateOrganizationDeletion(paperID: paper.id, generation: paper.generation) }.value
    if retry { try await lifecycle.retryDeletion(paperID: paper.id) }
    else { try await lifecycle.delete(paperID: paper.id) }
  }
  nonisolated static func normalized(_ value: String) -> String {
    value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
  }
  private nonisolated static func descending<T: Comparable>(_ lhs: T?, _ rhs: T?) -> Bool {
    switch (lhs, rhs) {
    case (.some(let a), .some(let b)): return a > b
    case (.some, .none): return true
    default: return false
    }
  }
}
