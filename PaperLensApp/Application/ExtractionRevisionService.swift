import Foundation
#if SWIFT_PACKAGE
import ProviderRequest
#endif

public enum ExtractionError: String, Error, Sendable {
  case producerUnavailable, geometryUnavailable, invalidBatch, staleAttempt, interrupted, storageFailure
}

public struct ExtractionIdentity: Equatable, Sendable {
  public let paperID: UUID
  public let generation: UUID
  public let pdfSHA256: String
  public let pdfReference: String
  public let revision: UUID
  public let job: UUID
  public let attempt: UUID
  public let fence: UUID
  public let correlation: UUID
  public let input: UUID
  public let epoch: UUID
  public let configuration: ProviderConfiguration
}

public struct ExtractionSentenceIdentity: Equatable, Sendable {
  public let paperID: UUID
  public let pdfSHA256: String
  public let revision: UUID
  public let page: Int
  public let sentenceID: Int
}

/// Implemented only by the actual PDFium typed boundary; never an untyped JSON envelope.
public protocol ExtractionGeometryInput: Sendable {}
public struct ExtractionGeometryEncoding: Sendable {
  public let canonicalBytes: Data
  public let quadCount: Int
}
public protocol ExtractionGeometryValidating: Sendable {
  /// Must verify actual membership, canonical geometry, full semantic extent and exact text using 1.19.
  func validateAndEncode(_ input: any ExtractionGeometryInput,
    identity: ExtractionSentenceIdentity, expectedText: String) throws -> ExtractionGeometryEncoding
}
public struct ExtractionSentenceInput: Sendable {
  public let identity: ExtractionSentenceIdentity
  public let text: String
  public let geometry: any ExtractionGeometryInput
}
public struct ExtractionBatch: Sendable {
  public let identity: ExtractionIdentity
  public let sequence: Int
  public let sentences: [ExtractionSentenceInput]
  public let complete: Bool
  public let totalSentences: Int?
}
public protocol ExtractionBatchProducing: Sendable {
  /// Parent owns bounded read-only PDF access, PDFium transport and cumulative RSS/elapsed budget.
  /// Producer must close its input before returning; transport terminal alone is not completion.
  func extract(_ identity: ExtractionIdentity) async throws -> [ExtractionBatch]
}
struct ValidatedExtractionSentence: Sendable {
  let page: Int
  let sentenceID: Int
  let text: String
  let geometry: Data
}
public struct ExtractionStatus: Sendable {
  public let state: String
  public let failure: String?
  public let usableRevision: UUID?
}
public struct ExtractionSearchHit: Sendable {
  public let revision: UUID
  public let page: Int
  public let sentenceID: Int
  public let text: String
  public let canonicalGeometry: Data
}

public struct ExtractionRevisionService: Sendable {
  public let database: ProductDatabase
  public let producer: (any ExtractionBatchProducing)?
  public let geometryValidator: (any ExtractionGeometryValidating)?

  public func parse(_ identity: ExtractionIdentity) async throws {
    let database = database
    try await Task.detached { try database.reserveExtraction(identity) }.value
    do {
      guard let producer else { throw ExtractionError.producerUnavailable }
      guard let geometryValidator else { throw ExtractionError.geometryUnavailable }
      let batches = try await producer.extract(identity)
      try Task.checkCancellation()
      let sentences = try Self.validate(batches, identity: identity, validator: geometryValidator)
      try await Task.detached { try database.publishExtraction(identity, sentences: sentences) }.value
    } catch {
      let failure = (error as? ExtractionError) ?? .storageFailure
      try await Task.detached { try database.failExtraction(identity, failure: failure) }.value
      throw error
    }
  }

  static func validate(_ batches: [ExtractionBatch], identity: ExtractionIdentity,
    validator: any ExtractionGeometryValidating) throws -> [ValidatedExtractionSentence] {
    let authority = try ProviderRequest()
    guard !batches.isEmpty, batches.count <= authority.limit("sentences") else {
      throw ExtractionError.invalidBatch
    }
    var output: [ValidatedExtractionSentence] = []
    var ids = Set<Int>()
    var textBytes = 0
    var quads = 0
    for (index, batch) in batches.enumerated() {
      guard batch.identity == identity, batch.sequence == index,
        batch.complete == (index == batches.count - 1), !batch.sentences.isEmpty,
        batch.sentences.count <= authority.limit("batchSentences"),
        batch.complete || batch.totalSentences == nil else { throw ExtractionError.invalidBatch }
      var batchBytes = 0
      for sentence in batch.sentences {
        let key = sentence.identity
        guard key.paperID == identity.paperID, key.pdfSHA256 == identity.pdfSHA256,
          key.revision == identity.revision, key.page >= 0, key.page < authority.limit("pages"),
          key.sentenceID >= 0, key.sentenceID < authority.limit("sentences"),
          ids.insert(key.sentenceID).inserted, !sentence.text.isEmpty,
          sentence.text.utf8.count <= authority.limit("sentenceBytes") else {
          throw ExtractionError.invalidBatch
        }
        let geometry = try validator.validateAndEncode(sentence.geometry, identity: key,
          expectedText: sentence.text)
        guard !geometry.canonicalBytes.isEmpty, geometry.quadCount > 0,
          geometry.quadCount <= authority.limit("quadsPerSentence"),
          geometry.canonicalBytes.count <= authority.limit("batchBytes") else {
          throw ExtractionError.invalidBatch
        }
        batchBytes += sentence.text.utf8.count + geometry.canonicalBytes.count
        textBytes += sentence.text.utf8.count
        quads += geometry.quadCount
        guard batchBytes <= authority.limit("batchBytes"), textBytes <= authority.limit("textBytes"),
          quads <= authority.limit("quads"), output.count < authority.limit("sentences") else {
          throw ExtractionError.invalidBatch
        }
        output.append(.init(page: key.page, sentenceID: key.sentenceID,
          text: sentence.text, geometry: geometry.canonicalBytes))
      }
    }
    guard batches.last?.totalSentences == output.count else { throw ExtractionError.invalidBatch }
    return output
  }
}
