import Foundation
import GRDB

/// A UI action captures this snapshot; it cannot silently retry a newer failure or PDF.
public struct ParsingRecoveryContext: Equatable, Sendable {
  public let failedAttempt: ExtractionIdentity
  public let usableRevision: UUID?
  public let currentConfiguration: ProviderConfiguration
}

public enum ParsingRecoveryError: Error, Equatable, Sendable {
  case staleContext, alreadyRunning
}

/// Main injects its existing process epoch and real extraction dependencies.
/// Durable state remains exclusively in ProductDatabase's extraction tables.
public actor ParsingRecoveryCoordinator {
  private let service: ExtractionRevisionService
  private let currentEpoch: UUID
  private var inFlight: Set<UUID> = []

  public init(service: ExtractionRevisionService, currentEpoch: UUID) {
    self.service = service
    self.currentEpoch = currentEpoch
  }

  public func context(paperID: UUID) throws -> ParsingRecoveryContext? {
    try service.database.adapterRead { try Self.context(in: $0, paperID: paperID) }
  }

  /// Rejects unavailable production boundaries before any persisted reservation or dispatch.
  /// A rejected/stale click leaves the latest failure and usable revision unchanged.
  @discardableResult
  public func retry(_ expected: ParsingRecoveryContext) async throws -> ExtractionIdentity {
    let paperID = expected.failedAttempt.paperID
    guard !inFlight.contains(paperID) else { throw ParsingRecoveryError.alreadyRunning }
    guard let producer = service.producer else { throw ExtractionError.producerUnavailable }
    guard let validator = service.geometryValidator else { throw ExtractionError.geometryUnavailable }
    try Task.checkCancellation()
    let old = expected.failedAttempt
    let identity = ExtractionIdentity(paperID: paperID, generation: old.generation,
      pdfSHA256: old.pdfSHA256, pdfReference: old.pdfReference, revision: UUID(), job: old.job,
      attempt: UUID(), fence: UUID(), correlation: UUID(), input: UUID(), epoch: currentEpoch,
      configuration: expected.currentConfiguration)
    // The transaction is the arbiter, including across coordinator instances. Policy
    // validates fresh parser admission; it is not another durable state/result mirror.
    try service.database.adapterWrite { db in
      guard try Self.context(in: db, paperID: paperID) == expected else {
        throw ParsingRecoveryError.staleContext
      }
      let authority = JobRecoveryPolicy.Authority(input: .parser(version: identity.input.uuidString),
        config: .inapplicable,
        paper: .init(id: paperID.uuidString, generation: identity.generation.uuidString),
        epoch: currentEpoch.uuidString, prerequisitesAvailable: true)
      var admission = try JobRecoveryPolicy.create(job: identity.job.uuidString, role: .parsing,
        authority: authority, reservation: .init(attempt: identity.attempt.uuidString,
          fence: identity.fence.uuidString, correlation: identity.correlation.uuidString))
      let lineage = admission.current.lineage
      for event in [JobRecoveryPolicy.Event.claim(lineage), .dispatch(lineage)] {
        let decision = JobRecoveryPolicy.apply(event, to: admission)
        if let rejection = decision.rejection { throw rejection }
        admission = decision.snapshot
      }
      guard try Int.fetchOne(db, sql: """
        SELECT COUNT(*) FROM extractionInvocation
        WHERE attempt = ? OR fence = ? OR revision = ?
        """, arguments: [identity.attempt.uuidString, identity.fence.uuidString,
          identity.revision.uuidString]) == 0,
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM extractionRevision WHERE id = ?",
          arguments: [identity.revision.uuidString]) == 0 else {
        throw ExtractionError.staleAttempt
      }
      try db.execute(sql: """
        INSERT INTO extractionInvocation(attempt, fence, revision, paperID) VALUES (?, ?, ?, ?)
        """, arguments: [identity.attempt.uuidString, identity.fence.uuidString,
          identity.revision.uuidString, paperID.uuidString])
      // Replace only the admitted failure; do not touch old revision/sentence/FTS rows.
      try db.execute(sql: """
        UPDATE extractionAttempt SET revision = ?, attempt = ?, fence = ?, correlation = ?,
          input = ?, epoch = ?, configSlot = ?, configGeneration = ?, state = 'running', failure = NULL
        WHERE paperID = ? AND state = 'failed' AND attempt = ? AND revision = ?
        """, arguments: [identity.revision.uuidString, identity.attempt.uuidString,
          identity.fence.uuidString, identity.correlation.uuidString, identity.input.uuidString,
          identity.epoch.uuidString, identity.configuration.slotID?.uuidString,
          identity.configuration.generation, paperID.uuidString, old.attempt.uuidString,
          old.revision.uuidString])
      guard db.changesCount == 1 else { throw ParsingRecoveryError.staleContext }
    }
    inFlight.insert(paperID)
    defer { inFlight.remove(paperID) }
    try await service.consumeReserved(identity, producer: producer, validator: validator)
    return identity
  }

  private static func context(in db: Database, paperID: UUID) throws -> ParsingRecoveryContext? {
    guard let row = try Row.fetchOne(db, sql: """
      SELECT extractionAttempt.*, providerConfig.slotID AS currentSlot,
        providerConfig.generation AS currentConfigGeneration, providerConfig.model AS currentModel
      FROM extractionAttempt JOIN paper ON paper.id = extractionAttempt.paperID
      CROSS JOIN providerConfig
      WHERE paper.id = ? AND paper.status = 'ready' AND paper.deletionID IS NULL
        AND extractionAttempt.state = 'failed' AND paper.generation = extractionAttempt.generation
        AND paper.pdfSHA256 = extractionAttempt.pdfSHA256
        AND paper.pdfReference = extractionAttempt.pdfReference AND providerConfig.singleton = 1
      """, arguments: [paperID.uuidString]) else { return nil }
    func uuid(_ column: String) throws -> UUID {
      let value: String = row[column]
      guard let id = UUID(uuidString: value) else { throw ProductDatabaseError.invalidRecord }
      return id
    }
    func optionalUUID(_ column: String) throws -> UUID? {
      let value: String? = row[column]
      guard let value else { return nil }
      guard let id = UUID(uuidString: value) else { throw ProductDatabaseError.invalidRecord }
      return id
    }
    let revision = try String.fetchOne(db, sql: """
      SELECT extractionRevision.id FROM extractionVisible
      JOIN extractionRevision ON extractionRevision.id = extractionVisible.revision
      JOIN paper ON paper.id = extractionVisible.paperID
      WHERE paper.id = ? AND extractionRevision.paperID = paper.id
        AND extractionRevision.generation = paper.generation
        AND extractionRevision.pdfSHA256 = paper.pdfSHA256
        AND extractionRevision.pdfReference = paper.pdfReference
      """, arguments: [paperID.uuidString])
    let usableRevision = revision.flatMap(UUID.init(uuidString:))
    if revision != nil && usableRevision == nil { throw ProductDatabaseError.invalidRecord }
    return ParsingRecoveryContext(failedAttempt: ExtractionIdentity(paperID: paperID,
      generation: try uuid("generation"), pdfSHA256: row["pdfSHA256"],
      pdfReference: row["pdfReference"], revision: try uuid("revision"), job: try uuid("job"),
      attempt: try uuid("attempt"), fence: try uuid("fence"), correlation: try uuid("correlation"),
      input: try uuid("input"), epoch: try uuid("epoch"),
      configuration: .init(slotID: try optionalUUID("configSlot"),
        generation: row["configGeneration"], model: nil)),
      usableRevision: usableRevision,
      currentConfiguration: .init(slotID: try optionalUUID("currentSlot"),
        generation: row["currentConfigGeneration"], model: row["currentModel"]))
  }
}

/// Only fixed, localizable reasons reach notifications/panels; never worker diagnostics.
public enum ParsingFailureMessage {
  public static func korean(_ failure: String?) -> String {
    switch failure {
    case "producerUnavailable": return "PDF 파싱 서비스가 연결되지 않았습니다."
    case "geometryUnavailable": return "검증된 문장 위치 계약이 연결되지 않았습니다."
    case "interrupted": return "파싱이 중단되었습니다. 다시 시도하세요."
    case "invalidBatch": return "원문 파싱 결과를 검증하지 못했습니다. 다시 시도하세요."
    case "resourceExceeded": return "파싱이 허용된 자원 한도를 초과했습니다. 다시 시도하세요."
    case "parsingFailure": return "원문 파싱에 실패했습니다. 다시 시도하세요."
    case "staleAttempt": return "논문 또는 설정이 변경되어 파싱을 완료하지 못했습니다."
    case "storageFailure": return "원문 파싱 결과를 저장하지 못했습니다. 다시 시도하세요."
    default: return "원문 파싱에 실패했습니다. 다시 시도하세요."
    }
  }
}
