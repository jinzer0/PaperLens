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
public enum LibraryFolderSelection: Equatable, Sendable { case all, unfiled, folder(UUID) }
public struct OrganizationFilter: Equatable, Sendable {
  public var folder: LibraryFolderSelection = .all
  public var search = ""
  public var tag: String?
  public var readingStatus: PaperReadingStatus?
  public var favoritesOnly = false
  public init() {}
}
public enum LibrarySummaryAvailability: Sendable {
  case available, unavailable, verificationFailed
}
public enum LibrarySummaryAttemptActivity: Sendable {
  case running, failed, succeeded
}
/// Allowlisted local reasons only; provider messages and document text are never stored here.
public enum LibrarySummaryFailure: String, CaseIterable, Sendable {
  case cancelled, interrupted, providerUnavailable, authentication, rateLimited, network, timedOut
  case invalidResponse, invalidGrounding, geometryUnavailable, staleIdentity, cleanupUnavailable
  case persistenceFailure, paperUnavailable, requestInProgress, terminated

  public var koreanMessage: String {
    switch self {
    case .cancelled: return "요약 생성을 취소했습니다. 원할 때 요약 생성을 다시 선택하세요."
    case .interrupted: return "앱 종료로 요약 생성이 중단되었습니다. 현재 연결과 파싱 상태를 확인한 뒤 다시 생성하세요."
    case .providerUnavailable: return "선택한 Provider를 사용할 수 없습니다. 설정에서 연결 상태를 확인한 뒤 다시 생성하세요."
    case .authentication: return "Provider 인증에 실패했습니다. 설정에서 다시 연결한 뒤 생성하세요."
    case .rateLimited: return "Provider 요청 한도에 도달했습니다. 잠시 후 다시 생성하세요."
    case .network: return "네트워크 요청을 완료하지 못했습니다. 연결 상태를 확인한 뒤 다시 생성하세요."
    case .timedOut: return "요약 요청 시간이 초과되었습니다. 잠시 후 다시 생성하세요."
    case .invalidResponse: return "Provider 응답 형식이 올바르지 않아 요약을 저장하지 않았습니다. 다시 생성할 수 있습니다."
    case .invalidGrounding: return "응답의 원문 근거를 확인하지 못해 요약을 저장하지 않았습니다. 파싱 상태를 확인하세요."
    case .geometryUnavailable: return "요약에 필요한 원문 위치 정보가 없습니다. 파싱 상태를 확인하세요. PDF는 계속 읽을 수 있습니다."
    case .staleIdentity: return "논문 또는 Provider 설정이 변경되어 이전 요청을 저장하지 않았습니다. 현재 상태에서 다시 생성하세요."
    case .cleanupUnavailable: return "요약 실행의 안전한 종료를 확인하지 못했습니다. 원문 보호를 위해 새 요청과 삭제를 보류합니다."
    case .persistenceFailure: return "요약을 안전하게 저장하지 못했습니다. 현재 저장 상태를 새로 확인하세요."
    case .paperUnavailable: return "현재 논문을 사용할 수 없어 요약을 중단했습니다. 라이브러리 상태를 확인하세요."
    case .requestInProgress: return "다른 요약이 실행 중이거나 이전 실행의 정리가 필요합니다. 현재 작업 상태를 확인하세요."
    case .terminated: return "요약 작업을 완료하지 못했습니다. 현재 연결과 파싱 상태를 확인한 뒤 다시 생성하세요."
    }
  }
}
public struct LibrarySummaryRecentAttempt: Sendable {
  public let identity: LibrarySummaryIdentity
  public let activity: LibrarySummaryAttemptActivity
  public let failure: LibrarySummaryFailure?
  public init(identity: LibrarySummaryIdentity, activity: LibrarySummaryAttemptActivity,
    failure: LibrarySummaryFailure? = nil) {
    self.identity = identity; self.activity = activity; self.failure = failure
  }
}
/// Passive facts from one database read, never dispatch or publication authority.
public struct LibrarySummaryObservation: Sendable {
  public let record: LibrarySummaryRecord?
  /// Most recently inserted attempt for the exact Paper/generation/PDF, not current input/configuration.
  public let recentAttempt: LibrarySummaryRecentAttempt?
  public let availability: LibrarySummaryAvailability
}

/// Parent supplies only accepted Reader/metadata values, bound to this exact Paper generation.
public struct OrganizationSortFacts: Sendable {
  public let paperID: UUID
  public let generation: UUID
  public let lastReadAt: Date?
  public let publicationYear: Int?
  /// Validated stored observation at query time, not publication or read authority.
  public let metadata: ReaderMetadataSnapshot?
  /// Nil means no delivered Summary fact, not known absence or successful generation.
  public let summary: LibrarySummaryObservation?
  public init(paperID: UUID, generation: UUID, lastReadAt: Date?, publicationYear: Int?,
    metadata: ReaderMetadataSnapshot?, summary: LibrarySummaryObservation? = nil) {
    self.paperID = paperID; self.generation = generation
    self.lastReadAt = lastReadAt; self.publicationYear = publicationYear
    self.metadata = metadata
    self.summary = summary
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
  case stalePaper, staleOrganization, unavailablePDF, invalidTags, invalidSortFacts
}

/// The UI invalidates synchronously before starting asynchronous queries or mutations.
/// Only the current revision and captured conditions may publish success or failure.
public struct OrganizationQueryState {
  public struct Request: Equatable, Sendable {
    fileprivate let revision: Int
    public let filter: OrganizationFilter
  }
  public private(set) var snapshot: OrganizationSnapshot?
  public private(set) var loading = true
  public private(set) var failed = false
  private var revision = 0
  public init() {}
  public mutating func invalidate() {
    revision += 1
    loading = true
    failed = false
  }
  public mutating func begin(filter: OrganizationFilter) -> Request {
    invalidate()
    return Request(revision: revision, filter: filter)
  }
  @discardableResult
  public mutating func accept(_ value: OrganizationSnapshot, request: Request,
    currentFilter: OrganizationFilter) -> Bool {
    guard request.revision == revision, request.filter == currentFilter else { return false }
    snapshot = value; loading = false; failed = false
    return true
  }
  public mutating func reject(request: Request, currentFilter: OrganizationFilter) {
    guard request.revision == revision, request.filter == currentFilter else { return }
    loading = false; failed = true
  }
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
      if let record = fact.summary?.record {
        guard record.identity.paperID == fact.paperID, record.identity.generation == fact.generation
        else { throw OrganizationError.invalidSortFacts }
      }
      if let attempt = fact.summary?.recentAttempt {
        guard attempt.identity.paperID == fact.paperID, attempt.identity.generation == fact.generation
        else { throw OrganizationError.invalidSortFacts }
      }
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

  public func tags() async throws -> [String] {
    let database = database
    return try await Task.detached { try database.organizationTags() }.value
  }

  public func savePreferences(_ preferences: OrganizationPreferences) async throws {
    let database = database
    try await Task.detached { try database.setOrganizationPreferences(preferences) }.value
  }
  public func save(_ organization: PaperOrganization, for paper: OrganizedPaper) async throws {
    let database = database
    try await Task.detached {
      try database.updatePaperOrganization(paperID: paper.id, generation: paper.generation,
        expected: paper.organization, value: organization)
    }.value
  }
  /// Retry does not silently rebase the failed whole-record draft onto newer values.
  public func revalidate(_ paper: OrganizedPaper) async throws -> OrganizedPaper {
    let database = database
    return try await Task.detached {
      let snapshot = try database.organizationSnapshot(filter: .init())
      guard let current = snapshot.papers.first(where: { $0.id == paper.id && $0.generation == paper.generation })
      else { throw OrganizationError.stalePaper }
      try database.admitOrganizationOpen(paperID: current.id, generation: current.generation)
      return current
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
