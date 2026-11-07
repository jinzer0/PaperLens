import Foundation
import CryptoKit
import PDFKit
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
  public let geometryValidator: any ExtractionGeometryValidating
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

  /// Production uses the admitted PDF itself for PDFKit page correspondence.
  public convenience init(lifecycle: LocalLibraryLifecycle, authority: ProviderRequest) throws {
    try self.init(lifecycle: lifecycle, authority: authority, geometryBinding: nil,
      observingOriginalPDF: true)
  }

  public convenience init(lifecycle: LocalLibraryLifecycle, authority: ProviderRequest,
    geometryBinding: PDFiumGeometryBinding?) throws {
    guard let geometryBinding else { throw ExtractionError.geometryUnavailable }
    try self.init(lifecycle: lifecycle, authority: authority, geometryBinding: geometryBinding,
      observingOriginalPDF: false)
  }

  private init(lifecycle: LocalLibraryLifecycle, authority: ProviderRequest,
    geometryBinding: PDFiumGeometryBinding?, observingOriginalPDF: Bool) throws {
    let acquirer = LibraryPDFiumInputAcquirer(lifecycle: lifecycle)
    let relay = CancellationRelay()
    let producer = PDFiumExtractionProducer { identity, operationID in
      try await Self.acquireOwnedInput(identity: identity, operationID: operationID,
        authority: authority, acquirer: acquirer, relay: relay)
    }
    relay.producer = producer
    let validator: any ExtractionGeometryValidating
    let serviceProducer: any ExtractionBatchProducing
    if observingOriginalPDF {
      let observed = OriginalPDFKitGeometryValidator()
      validator = observed
      serviceProducer = OriginalPDFKitGeometryProducer(base: producer, lifecycle: lifecycle,
        authority: authority, validator: observed)
    } else {
      guard let geometryBinding else { throw ExtractionError.geometryUnavailable }
      validator = PDFiumGeometryValidator(binding: geometryBinding)
      serviceProducer = producer
    }
    let service = ExtractionRevisionService(database: lifecycle.readLeaseDatabase,
      producer: serviceProducer, geometryValidator: validator)
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

/// Bindings contain only values observed while the original admitted PDF is leased.
/// They exist solely during the consumer scope; no document/view escapes the lease.
private final class OriginalPDFKitGeometryValidator: ExtractionGeometryValidating, @unchecked Sendable {
  private struct Witness {
    let identity: ExtractionIdentity
    let binding: PDFiumGeometryBinding
  }
  private let lock = NSLock()
  private var witnesses: [UUID: Witness] = [:]

  func install(_ binding: PDFiumGeometryBinding, identity: ExtractionIdentity) throws {
    try lock.withLock {
      guard witnesses[identity.revision] == nil else { throw ExtractionError.staleAttempt }
      witnesses[identity.revision] = Witness(identity: identity, binding: binding)
    }
  }
  func remove(_ identity: ExtractionIdentity) {
    _ = lock.withLock { witnesses.removeValue(forKey: identity.revision) }
  }
  func validateAndEncode(_ input: any ExtractionGeometryInput,
    identity: ExtractionSentenceIdentity, expectedText: String) throws -> ExtractionGeometryEncoding {
    let witness = try lock.withLock {
      guard let witness = witnesses[identity.revision],
        witness.identity.paperID == identity.paperID,
        witness.identity.pdfSHA256 == identity.pdfSHA256 else { throw ExtractionError.staleAttempt }
      return witness
    }
    return try PDFiumGeometryValidator(binding: witness.binding)
      .validateAndEncode(input, identity: identity, expectedText: expectedText)
  }
}

private struct OriginalPDFKitGeometryProducer: ExtractionBatchProducing {
  let base: PDFiumExtractionProducer
  let lifecycle: LocalLibraryLifecycle
  let authority: ProviderRequest
  let validator: OriginalPDFKitGeometryValidator

  func withBatches(_ identity: ExtractionIdentity,
    consume: @escaping @Sendable ([ExtractionBatch], ExtractionConsumptionScope) async throws -> Void) async throws {
    try await base.withBatches(identity) { batches, scope in
      try scope.checkBudget()
      let rawPages = try Self.pages(in: batches, identity: identity)
      let binding = try await MainActor.run {
        try OriginalPDFKitPageWitness.capture(identity: identity, rawPages: rawPages,
          lifecycle: lifecycle, authority: authority, checkBudget: { try scope.checkBudget() })
      }
      try validator.install(binding, identity: identity)
      defer { validator.remove(identity) }
      try scope.checkBudget()
      try await consume(batches, scope)
    }
  }

  private static func pages(in batches: [ExtractionBatch], identity: ExtractionIdentity) throws
    -> [Int: PDFiumRawPage] {
    var pages: [Int: PDFiumRawPage] = [:]
    for batch in batches {
      guard batch.identity == identity else { throw ExtractionError.staleAttempt }
      for sentence in batch.sentences {
        guard let input = sentence.geometry as? PDFiumGeometryInput,
          input.identity == sentence.identity else { throw ExtractionError.invalidBatch }
        let page = input.rawPage
        if let previous = pages[page.pageIndex] {
          guard OriginalPDFKitPageWitness.sameRawPage(previous, page) else {
            throw PDFGeometryError.malformedGeometry
          }
        } else { pages[page.pageIndex] = page }
      }
    }
    return pages
  }
}

/// The public conversion metric is in unrotated PDF points. This envelope is
/// declared before measuring: gamma(128) charges 128 binary64 affine operations,
/// sixteen absolute terms <=100000, and the Reader's minimum zoom 0.1. Opaque
/// PDFKit conversions must independently satisfy it on every captured page.
/// It never grants CropBox membership or modifies producer vertices.
enum OriginalPDFKitPageWitness {
  static let coordinateLimit = 100_000.0
  static let maximumErrorPDFPoints: Double = {
    let u = Double.ulpOfOne / 2
    return ((128 * u / (1 - 128 * u)) * 16 * coordinateLimit / 0.1).nextUp
  }()

  @MainActor static func capture(identity: ExtractionIdentity, rawPages: [Int: PDFiumRawPage],
    lifecycle: LocalLibraryLifecycle, authority: ProviderRequest,
    checkBudget: () throws -> Void) throws -> PDFiumGeometryBinding {
    try checkBudget()
    let database = lifecycle.readLeaseDatabase
    let snapshot = try database.extractionReadSnapshot(identity)
    let lease = try LibraryReadLeaseProvider(lifecycle: lifecycle)
      .acquireReadLease(for: snapshot, onRevoked: {})
    defer { lease.close() }
    let mappings: [Int: PDFiumPageMapping] = try lease.withReadAccess {
      try autoreleasepool {
        let url = database.root.appendingPathComponent(snapshot.pdfReference)
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values.fileSize, size > 0, size <= authority.limit("pdfBytes") else {
          throw ExtractionError.resourceExceeded
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        try checkBudget()
        guard data.count == size,
          SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == identity.pdfSHA256,
          let document = PDFDocument(data: data), document.pageCount > 0,
          document.pageCount <= authority.limit("pages") else { throw ExtractionError.invalidBatch }
        let view = PDFView(frame: CGRect(x: 0, y: 0, width: 800, height: 1000))
        view.displayMode = .singlePage
        view.displayBox = .cropBox
        view.autoScales = false
        view.document = document
        defer { view.document = nil }
        var mappings: [Int: PDFiumPageMapping] = [:]
        for index in rawPages.keys.sorted() {
          try checkBudget()
          guard index < document.pageCount, let raw = rawPages[index],
            let page = document.page(at: index) else { throw PDFGeometryError.missingPage }
          view.go(to: page)
          view.scaleFactor = 1
          view.layoutDocumentView()
          mappings[index] = try mapping(raw: raw, page: page, view: view)
        }
        try checkBudget()
        return mappings
      }
    }
    try lease.validate()
    try database.validateReaderSnapshot(snapshot)
    let precision = try PDFGeometryPrecision(maximumErrorPDFPoints: maximumErrorPDFPoints)
    return PDFiumGeometryBinding(precision: precision, mapPage: { raw in
      guard let original = rawPages[raw.pageIndex], sameRawPage(original, raw),
        let mapping = mappings[raw.pageIndex] else { throw PDFGeometryError.identityMismatch }
      return mapping
    })
  }

  static func sameRawPage(_ lhs: PDFiumRawPage, _ rhs: PDFiumRawPage) -> Bool {
    lhs.pageIndex == rhs.pageIndex && lhs.rotationQuarterTurns == rhs.rotationQuarterTurns
      && lhs.boundingBox.coordinates == rhs.boundingBox.coordinates
      && lhs.cropBox?.coordinates == rhs.cropBox?.coordinates
      && lhs.mediaBox?.coordinates == rhs.mediaBox?.coordinates
  }

  @MainActor static func mapping(raw: PDFiumRawPage, page: PDFPage, view: PDFView) throws
    -> PDFiumPageMapping {
    let geometry = try PDFKitGeometryAdapter.pageGeometry(page: page, in: view, pageIndex: raw.pageIndex)
    guard geometry.rotation == raw.rotationQuarterTurns * 90 else {
      throw PDFGeometryError.malformedGeometry
    }
    // PDFium's page-box ABI stores binary32, independently of Double glyph boxes.
    // Compare the exact ABI projection, not a measured/tuned tolerance.
    let x = geometry.cropOrigin.x, y = geometry.cropOrigin.y
    let right = x + geometry.width, top = y + geometry.height
    let projected = [x, top, right, top, right, y, x, y].map { Double(Float($0)) }
    // A missing direct /CropBox is common (including inherited boxes). In that
    // case PDFKit supplies the effective CropBox and PDFium's effective page
    // bounding-box API must independently agree; MediaBox is never substituted.
    let actualBox = raw.cropBox ?? raw.boundingBox
    guard actualBox.coordinates == projected else { throw PDFGeometryError.malformedGeometry }
    let precision = try PDFGeometryPrecision(maximumErrorPDFPoints: maximumErrorPDFPoints)
    let origin = PDFPoint(x: x, y: y)
    let horizontal = PDFPoint(x: right, y: y)
    let vertical = PDFPoint(x: x, y: top)
    func observed(_ p: PDFPoint) throws -> PDFPoint {
      let v = view.convert(CGPoint(x: p.x, y: p.y), from: page)
      let result = PDFPoint(x: Double(v.x), y: Double(v.y))
      try envelope([p, result])
      return result
    }
    let base = try observed(origin), h = try observed(horizontal), v = try observed(vertical)
    let a = (h.x - base.x) / geometry.width, b = (h.y - base.y) / geometry.width
    let c = (v.x - base.x) / geometry.height, d = (v.y - base.y) / geometry.height
    let transform = try PDFGeometryAffine(a: a, b: b, c: c, d: d,
      tx: base.x - a * x - c * y, ty: base.y - b * x - d * y)
    let witnesses = [origin, horizontal, vertical, PDFPoint(x: right, y: top),
      PDFPoint(x: x + geometry.width / 4, y: y + geometry.height / 3)]
    for point in witnesses {
      let direct = try observed(point)
      try precision.validate(expected: direct, actual: transform.applying(point))
      try precision.validate(expected: point, actual: transform.inverse(direct))
      _ = try PDFKitGeometryAdapter.displayPoint(point, page: page, in: view,
        geometry: geometry, precision: precision)
    }
    return try PDFiumPageMapping(page: geometry,
      rawToCanonical: PDFGeometryAffine(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0),
      canonicalToReader: transform)
  }

  private static func envelope(_ points: [PDFPoint]) throws {
    for point in points {
      try point.validate()
      guard abs(point.x) <= coordinateLimit, abs(point.y) <= coordinateLimit else {
        throw PDFGeometryError.malformedGeometry
      }
    }
  }
}
