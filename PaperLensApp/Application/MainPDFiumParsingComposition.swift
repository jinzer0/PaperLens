import Foundation
import GRDB
#if SWIFT_PACKAGE
import ProviderRequest
#endif

/// Main's actual parsing owners. Construction does not activate parsing or certify geometry.
@MainActor public final class MainPDFiumParsingComposition {
  public let lifecycle: LocalLibraryLifecycle
  public let authority: ProviderRequest
  public let inputAcquirer: LibraryPDFiumInputAcquirer
  public let producer: PDFiumExtractionProducer
  public let geometryValidator: PDFiumGeometryValidator
  public let service: ExtractionRevisionService
  public let recoveryCoordinator: ParsingRecoveryCoordinator
  private let cancellationRelay: CancellationRelay
  private var initialInvocations: Set<UUID> = []

  /// Failure is request failure/debt information, never proof of physical closure.
  public var cancellationRequestFailure: Error? { cancellationRelay.failure }

  @MainActor private final class CancellationRelay {
    weak var producer: PDFiumExtractionProducer?
    var failure: Error?

    func revoke(resources: PDFiumExtractionResourceOwner) {
      // Synchronous poisoning protects Main even before the actor receives the request.
      do { try resources.requestCancellation(operationID: resources.operationID) }
      catch { if failure == nil { failure = error } }
      guard let producer else {
        if failure == nil { failure = PDFiumFailure(code: .identityMismatch) }
        return
      }
      let operationID = resources.operationID
      Task {
        do { try await producer.requestCancellation(operationID: operationID) }
        catch { if failure == nil { failure = error } }
      }
    }
  }

  public init(lifecycle: LocalLibraryLifecycle, authority: ProviderRequest,
    geometryBinding: PDFiumGeometryBinding?) throws {
    guard let geometryBinding else { throw ExtractionError.geometryUnavailable }
    let acquirer = LibraryPDFiumInputAcquirer(lifecycle: lifecycle)
    let relay = CancellationRelay()
    let producer = PDFiumExtractionProducer { identity, operationID in
      try await Self.acquireOwnedInput(identity: identity, operationID: operationID,
        authority: authority, acquirer: acquirer, relay: relay)
    }
    relay.producer = producer
    let validator = PDFiumGeometryValidator(binding: geometryBinding)
    let service = ExtractionRevisionService(database: lifecycle.readLeaseDatabase,
      producer: producer, geometryValidator: validator)
    self.lifecycle = lifecycle
    self.authority = authority
    self.inputAcquirer = acquirer
    self.producer = producer
    self.geometryValidator = validator
    self.service = service
    self.recoveryCoordinator = ParsingRecoveryCoordinator(service: service, currentEpoch: lifecycle.epoch)
    self.cancellationRelay = relay
  }

  /// Committed-import notifications are not Retry commands. A durable previous
  /// invocation (including an interrupted or failed one) requires explicit recovery.
  @discardableResult
  public func parseImportedPaper(_ paperID: UUID) async throws -> ExtractionIdentity? {
    try Task.checkCancellation()
    guard let identity = try initialIdentity(paperID: paperID) else { return nil }
    try await service.parse(identity)
    return identity
  }

  internal func initialIdentity(paperID: UUID) throws -> ExtractionIdentity? {
    guard !initialInvocations.contains(paperID) else { return nil }
    let identity: ExtractionIdentity? = try service.database.adapterRead { db in
      guard try Int.fetchOne(db, sql: """
        SELECT COUNT(*) FROM extractionInvocation WHERE paperID = ?
        """, arguments: [paperID.uuidString]) == 0,
        let row = try Row.fetchOne(db, sql: """
          SELECT paper.generation, paper.pdfSHA256, paper.pdfReference,
            providerConfig.kind, providerConfig.slotID, providerConfig.model,
            providerConfig.generation AS configGeneration
          FROM paper CROSS JOIN providerConfig
          WHERE paper.id = ? AND paper.status = 'ready' AND paper.deletionID IS NULL
            AND providerConfig.singleton = 1
          """, arguments: [paperID.uuidString]) else { return nil }
      guard let generation = UUID(uuidString: row["generation"]),
        let sha: String = row["pdfSHA256"], let reference: String = row["pdfReference"]
      else { throw ProductDatabaseError.invalidRecord }
      let slot: String? = row["slotID"]
      let rawKind: String? = row["kind"]
      let kind = rawKind.flatMap(ProviderKind.init(rawValue:))
      guard (slot == nil) == (rawKind == nil), rawKind == nil || kind != nil else {
        throw ProductDatabaseError.invalidRecord
      }
      if let slot, UUID(uuidString: slot) == nil { throw ProductDatabaseError.invalidRecord }
      let configuration = ProviderConfiguration(kind: kind,
        slotID: slot.flatMap(UUID.init(uuidString:)),
        generation: row["configGeneration"], model: row["model"])
      return ExtractionIdentity(paperID: paperID, generation: generation,
        pdfSHA256: sha, pdfReference: reference, revision: UUID(), job: UUID(),
        attempt: UUID(), fence: UUID(), correlation: UUID(), input: UUID(),
        epoch: lifecycle.epoch, configuration: configuration)
    }
    guard let identity else { return nil }
    let authority = JobRecoveryPolicy.Authority(
      input: .parser(version: identity.input.uuidString), config: .inapplicable,
      paper: .init(id: paperID.uuidString, generation: identity.generation.uuidString),
      epoch: lifecycle.epoch.uuidString, prerequisitesAvailable: true)
    var admission = try JobRecoveryPolicy.create(job: identity.job.uuidString, role: .parsing,
      authority: authority, reservation: .init(attempt: identity.attempt.uuidString,
        fence: identity.fence.uuidString, correlation: identity.correlation.uuidString))
    let lineage = admission.current.lineage
    for event in [JobRecoveryPolicy.Event.claim(lineage), .dispatch(lineage)] {
      let decision = JobRecoveryPolicy.apply(event, to: admission)
      if let rejection = decision.rejection { throw rejection }
      admission = decision.snapshot
    }
    // Claim before the first suspension, including failures before DB reservation.
    initialInvocations.insert(paperID)
    return identity
  }

  /// The same owned acquisition used by the producer; no helper is started here.
  internal func acquireOwnedInput(identity: ExtractionIdentity, operationID: UUID) async throws
    -> PDFiumPinnedInput {
    try await Self.acquireOwnedInput(identity: identity, operationID: operationID,
      authority: authority, acquirer: inputAcquirer, relay: cancellationRelay)
  }

  nonisolated private static func acquireOwnedInput(identity: ExtractionIdentity, operationID: UUID,
    authority: ProviderRequest, acquirer: LibraryPDFiumInputAcquirer,
    relay: CancellationRelay) async throws -> PDFiumPinnedInput {
    let resources = try PDFiumExtractionResourceOwner(identity: identity,
      operationID: operationID, authority: authority)
    return try await acquirer.acquireInput(resources: resources,
      onRevoked: { relay.revoke(resources: resources) })
  }
}
