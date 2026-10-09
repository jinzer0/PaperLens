import Foundation

/// Only finalized canonical PDF-point geometry belongs at this boundary.
/// Backend coordinate conversion and ownership of the full sentence precede this input.
public struct CanonicalExtractionGeometryInput: ExtractionGeometryInput {
    public let anchor: PDFSentenceAnchor

    public init(anchor: PDFSentenceAnchor) {
        self.anchor = anchor
    }
}

public enum CanonicalExtractionGeometryError: Error, Equatable {
    case unsupportedInput
    case invalidEncoding
    case unsupportedEncodingVersion
    case duplicateSentence
    case pageGeometryMismatch
    case semanticExtentMismatch
}

/// The caller supplies actual revision membership/full extent and its explicit precision.
/// Neither an input anchor nor persisted bytes can establish their own membership.
public struct CanonicalExtractionGeometryValidator: ExtractionGeometryValidating {
    private let owningAnchors: [PDFSentenceIdentity: PDFSentenceAnchor]
    private let membership: Set<PDFSentenceIdentity>
    private let precision: PDFGeometryPrecision

    public init(owningAnchors: [PDFSentenceAnchor], precision: PDFGeometryPrecision) throws {
        var indexed: [PDFSentenceIdentity: PDFSentenceAnchor] = [:]
        for anchor in owningAnchors {
            guard indexed.updateValue(anchor, forKey: anchor.identity) == nil else {
                throw CanonicalExtractionGeometryError.duplicateSentence
            }
        }
        self.owningAnchors = indexed
        self.membership = Set(indexed.keys)
        self.precision = precision
    }

    public func validateAndEncode(_ input: any ExtractionGeometryInput,
                                  identity: ExtractionSentenceIdentity,
                                  expectedText: String) throws -> ExtractionGeometryEncoding {
        guard let canonical = input as? CanonicalExtractionGeometryInput else {
            throw CanonicalExtractionGeometryError.unsupportedInput
        }
        try validate(canonical.anchor, identity: identity)
        // The text persisted by the caller must be the admitted quote's original UTF-8.
        guard canonical.anchor.fullSourceQuote.utf8.elementsEqual(expectedText.utf8) else {
            throw CanonicalExtractionGeometryError.semanticExtentMismatch
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(EncodedAnchor(canonical.anchor))
        return ExtractionGeometryEncoding(canonicalBytes: bytes, quadCount: canonical.anchor.quads.count)
    }

    /// Decode is also an ownership check, not merely syntactic JSON acceptance.
    public func decodeAndValidate(_ bytes: Data,
                                  identity: ExtractionSentenceIdentity) throws -> PDFSentenceAnchor {
        let encoded: EncodedAnchor
        do {
            encoded = try JSONDecoder().decode(EncodedAnchor.self, from: bytes)
        } catch is DecodingError {
            throw CanonicalExtractionGeometryError.invalidEncoding
        }
        guard encoded.version == 1 else {
            throw CanonicalExtractionGeometryError.unsupportedEncodingVersion
        }
        let anchor = try encoded.anchor()
        try validate(anchor, identity: identity)
        return anchor
    }

    private func validate(_ anchor: PDFSentenceAnchor,
                          identity: ExtractionSentenceIdentity) throws {
        let expected = try PDFSentenceIdentity(
            paperID: identity.paperID, pdfSHA256: identity.pdfSHA256,
            extractionRevision: identity.revision.uuidString.lowercased(),
            pageIndex: identity.page, sentenceID: identity.sentenceID)
        // Domain remains the identity and membership authority.
        try anchor.validateResolution(expected: expected, publishedMembership: membership)
        guard let owner = owningAnchors[expected] else { throw PDFGeometryError.unknownSentence }
        guard anchor.page == owner.page else {
            throw CanonicalExtractionGeometryError.pageGeometryMismatch
        }
        // Compare original UTF-8, not Swift's canonically equivalent String equality.
        guard anchor.fullSourceQuote.utf8.elementsEqual(owner.fullSourceQuote.utf8),
              anchor.quads.count == owner.quads.count else {
            throw CanonicalExtractionGeometryError.semanticExtentMismatch
        }
        for (actualQuad, expectedQuad) in zip(anchor.quads, owner.quads) {
            for (actual, expected) in zip(actualQuad.points, expectedQuad.points) {
                try owner.page.validate(actual)
                try precision.validate(expected: expected, actual: actual)
            }
        }
    }
}

// Wire representation only: all decoded geometry is reconstructed by Domain initializers.
private struct EncodedAnchor: Codable {
    let version: Int
    let paperID: UUID
    let pdfSHA256: String
    let extractionRevision: String
    let pageIndex: Int
    let sentenceID: Int
    let fullSourceQuote: String
    let cropOrigin: EncodedPoint
    let width: Double
    let height: Double
    let rotation: Int
    let quads: [EncodedQuad]

    init(_ anchor: PDFSentenceAnchor) {
        version = 1
        paperID = anchor.identity.paperID
        pdfSHA256 = anchor.identity.pdfSHA256
        extractionRevision = anchor.identity.extractionRevision
        pageIndex = anchor.identity.pageIndex
        sentenceID = anchor.identity.sentenceID
        fullSourceQuote = anchor.fullSourceQuote
        cropOrigin = EncodedPoint(anchor.page.cropOrigin)
        width = anchor.page.width
        height = anchor.page.height
        rotation = anchor.page.rotation
        quads = anchor.quads.map(EncodedQuad.init)
    }

    func anchor() throws -> PDFSentenceAnchor {
        let identity = try PDFSentenceIdentity(
            paperID: paperID, pdfSHA256: pdfSHA256, extractionRevision: extractionRevision,
            pageIndex: pageIndex, sentenceID: sentenceID)
        let page = try PDFPageGeometry(pageIndex: pageIndex, cropOrigin: cropOrigin.point,
                                       width: width, height: height, rotation: rotation)
        return try PDFSentenceAnchor(identity: identity, fullSourceQuote: fullSourceQuote,
                                     page: page, quads: quads.map { try $0.quad(on: page) })
    }
}

private struct EncodedPoint: Codable {
    let x: Double
    let y: Double

    init(_ point: PDFPoint) {
        x = point.x
        y = point.y
    }

    var point: PDFPoint { PDFPoint(x: x, y: y) }
}

private struct EncodedQuad: Codable {
    let topLeft: EncodedPoint
    let topRight: EncodedPoint
    let bottomRight: EncodedPoint
    let bottomLeft: EncodedPoint

    init(_ quad: PDFQuad) {
        topLeft = EncodedPoint(quad.topLeft)
        topRight = EncodedPoint(quad.topRight)
        bottomRight = EncodedPoint(quad.bottomRight)
        bottomLeft = EncodedPoint(quad.bottomLeft)
    }

    func quad(on page: PDFPageGeometry) throws -> PDFQuad {
        try PDFQuad(topLeft: topLeft.point, topRight: topRight.point,
                    bottomRight: bottomRight.point, bottomLeft: bottomLeft.point, page: page)
    }
}
