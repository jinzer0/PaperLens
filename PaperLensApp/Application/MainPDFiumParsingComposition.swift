import Foundation
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
