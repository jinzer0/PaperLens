import Foundation
#if SWIFT_PACKAGE
import ProviderRequest
#endif

public enum LibrarySummaryError: Error, Equatable {
  case providerUnavailable, geometryUnavailable, staleIdentity, invalidGrounding, invalidResult
  case requestInProgress, cleanupUnavailable
}

/// Decoder must validate canonical geometry and full quote extent, not merely decode a BLOB.
public protocol LibrarySummaryGeometryValidating: Sendable {
  func resolve(_ hit: ExtractionSearchHit, identity: PDFSentenceIdentity) throws -> PDFSentenceAnchor
}

/// Implement only with the existing certified provider enforcement (authorization, resource
/// accounting, exact request copy, typed validation and actual closure). No SDK calls here.
public protocol LibrarySummaryProviding: Sendable {
  func execute(_ request: AuthorizedProviderRequest, identity: LibrarySummaryIdentity) async throws
    -> ValidatedProviderResult
}

public struct LibrarySummaryIdentity: Codable, Equatable, Sendable {
  public let paperID: UUID
  public let generation: UUID
  /// Supplied by the trusted Paper identity owner; never inferred from the UUID or defaulted.
  public let requestPaperGeneration: Int
  public let pdfSHA256: String
  public let revision: UUID
  public let configurationGeneration: Int64
  public let job: UUID
  public let attempt: UUID
  public let fence: UUID
  public let correlation: UUID
  public let input: UUID
  public let epoch: UUID

  public init(paperID: UUID, generation: UUID, requestPaperGeneration: Int, pdfSHA256: String, revision: UUID,
    configurationGeneration: Int64, job: UUID, attempt: UUID, fence: UUID,
    correlation: UUID, input: UUID, epoch: UUID) {
    self.paperID = paperID; self.generation = generation; self.pdfSHA256 = pdfSHA256
    self.requestPaperGeneration = requestPaperGeneration
    self.revision = revision; self.configurationGeneration = configurationGeneration
    self.job = job; self.attempt = attempt; self.fence = fence
    self.correlation = correlation; self.input = input; self.epoch = epoch
  }

  func check(_ snapshot: JobRecoveryPolicy.Snapshot) throws {
    let line = snapshot.current.lineage
    guard snapshot.role == .librarySummary, snapshot.current.state == .running,
      !snapshot.revoked, line.job == job.uuidString,
      line.reservation == .init(attempt: attempt.uuidString, fence: fence.uuidString,
        correlation: correlation.uuidString),
      line.captured == snapshot.authority,
      line.captured.input == .librarySummary(version: input.uuidString),
      line.captured.config == .generation(String(configurationGeneration)),
      line.captured.paper == .init(id: paperID.uuidString, generation: generation.uuidString),
      line.captured.epoch == epoch.uuidString, line.captured.prerequisitesAvailable
    else { throw LibrarySummaryError.staleIdentity }
  }
}

public struct LibrarySummaryRecord: Sendable {
  public let id: UUID
  public let identity: LibrarySummaryIdentity
  public let result: ValidatedProviderResult
  public let evidence: RequestEvidenceBundle
  /// In the exact order of the claim's saved evidenceIndices; no reranking.
  public let claimAnchors: [PDFSentenceAnchor]
}

/// Parent serializes policy snapshots and performs actual permit/closure work. This boundary
/// never invents a successful closure, retries an ambiguous send, or regenerates on restore.
public struct LibrarySummaryService: Sendable {
  private let database: ProductDatabase
  private let provider: (any LibrarySummaryProviding)?
  private let geometry: (any LibrarySummaryGeometryValidating)?

  public init(database: ProductDatabase, provider: (any LibrarySummaryProviding)? = nil,
    geometry: (any LibrarySummaryGeometryValidating)? = nil) {
    self.database = database; self.provider = provider; self.geometry = geometry
  }

  /// Caller applies .dispatch first. Durable intent and frozen input precede the only send.
  @MainActor public func dispatch(_ request: AuthorizedProviderRequest, identity: LibrarySummaryIdentity,
    snapshot: JobRecoveryPolicy.Snapshot) async throws -> ValidatedProviderResult {
    guard let provider else { throw LibrarySummaryError.providerUnavailable }
    guard let geometry else { throw LibrarySummaryError.geometryUnavailable }
    try identity.check(snapshot)
    guard snapshot.current.dispatch == .intentRecorded else { throw LibrarySummaryError.staleIdentity }
    let frozen = try LibrarySummaryFrozen(request: request)
    try database.reserveLibrarySummary(identity, frozen: frozen, geometry: geometry)
    try Task.checkCancellation()
    // Any thrown/ambiguous return retains intent. Parent must terminate/drain, not auto-replay.
    let result = try await provider.execute(request, identity: identity)
    return try frozen.validate(result: ProviderRequest.canonicalBytes(result.value))
  }

  /// The parent's permit must already attest real validated-stage closure and publication.
  /// The database checks all current durable identities again in the commit transaction.
  public func publish(_ result: ValidatedProviderResult, request: AuthorizedProviderRequest,
    identity: LibrarySummaryIdentity, snapshot: JobRecoveryPolicy.Snapshot,
    permit: String, resultID: UUID) throws -> LibrarySummaryRecord {
    guard provider != nil else { throw LibrarySummaryError.providerUnavailable }
    guard let geometry else { throw LibrarySummaryError.geometryUnavailable }
    try identity.check(snapshot)
    guard snapshot.current.dispatch != .none else { throw LibrarySummaryError.staleIdentity }
    let decision = JobRecoveryPolicy.apply(.publish(snapshot.current.lineage, permit: permit,
      .init(id: resultID.uuidString)), to: snapshot)
    if let rejection = decision.rejection { throw rejection }
    let frozen = try LibrarySummaryFrozen(request: request)
    let bytes = try ProviderRequest.canonicalBytes(result.value)
    let validated = try frozen.validate(result: bytes)
    return try database.publishLibrarySummary(identity, frozen: frozen, result: validated,
      bytes: bytes, permit: permit, resultID: resultID, geometry: geometry)
  }

  public func restore(paperID: UUID) throws -> LibrarySummaryRecord? {
    return try database.restoreLibrarySummary(paperID: paperID, geometry: geometry)
  }
}

/// Persist full trusted context so restore uses the same ranked-prefix and budget authority.
/// These are local storage fields, never additional ProviderRequest wire fields.
struct LibrarySummaryFrozen: Codable, Equatable {
  struct Sentence: Codable, Equatable {
    let page: Int
    let id: Int
    let quote: String
  }
  let request: Data
  let language: String
  let paper: String
  let paperGeneration: Int
  let hash: String
  let revision: String
  let sentences: [Sentence]
  let ranked: [Int]

  init(request authorized: AuthorizedProviderRequest) throws {
    guard case .librarySummary(let language, let bundle) = authorized.wire.typedInput,
      authorized.context.operation == .librarySummary,
      authorized.context.identity == bundle.identity else { throw LibrarySummaryError.invalidResult }
    self.request = try ProviderRequest.canonicalBytes(authorized.wire.value)
    self.language = language; paper = bundle.identity.paperID
    paperGeneration = bundle.identity.paperGeneration; hash = bundle.identity.pdfSHA256
    revision = bundle.identity.extractionRevision
    sentences = authorized.context.sentences.map {
      Sentence(page: $0.anchor.pageIndex, id: $0.anchor.sentenceID, quote: $0.quote)
    }
    ranked = authorized.context.rankedCandidates
    // The original authority is private to ProviderRequest. Rebind the full trusted
    // context and verify the exact wire projection under one local authority.
    _ = try self.authorized()
  }

  func authorized() throws -> AuthorizedProviderRequest {
    try authorized(using: ProviderRequest())
  }

  func authorized(using authority: ProviderRequest) throws -> AuthorizedProviderRequest {
    let context = try TrustedRequestContext(authority: authority,
      sources: .librarySummary(outputLanguage: language),
      identity: .init(paperID: paper, paperGeneration: paperGeneration,
        pdfSHA256: hash, extractionRevision: revision),
      sentences: sentences.map { .init(anchor: .init(pageIndex: $0.page, sentenceID: $0.id), quote: $0.quote) },
      rankedCandidates: ranked)
    let built = try authority.buildRequest(sources: context.sources, context: context,
      requestID: authority.parseRequest(request).requestID)
    _ = try authority.verifyAdapterCopy(built, raw: request)
    return built
  }

  func validate(result: Data) throws -> ValidatedProviderResult {
    let authority = try ProviderRequest()
    let validated = try authority.validateResult(result, request: authorized(using: authority))
    guard case .librarySummary(let summary, _) = validated.result,
      !summary.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { throw LibrarySummaryError.invalidResult }
    return validated
  }
}
