import Foundation
import XCTest
@testable import PaperLensProduct

final class CanonicalExtractionGeometryTests: XCTestCase {
    private let paper = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    private let revision = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
    private let pdfSHA256 = String(repeating: "a", count: 64)
    private let quote = "Original full sentence\nincluding its continuation."
    private struct UnknownGeometry: ExtractionGeometryInput {}

    private func identity(paper: UUID? = nil, hash: String? = nil, revision: UUID? = nil,
                          page: Int = 0, sentence: Int = 7) -> ExtractionSentenceIdentity {
        ExtractionSentenceIdentity(paperID: paper ?? self.paper, pdfSHA256: hash ?? self.pdfSHA256,
                                   revision: revision ?? self.revision, page: page, sentenceID: sentence)
    }

    private func anchor(identity key: ExtractionSentenceIdentity? = nil, rotation: Int = 0,
                        quote: String? = nil, shift: Double = 0, dropContinuation: Bool = false,
                        width: Double = 100) throws -> PDFSentenceAnchor {
        let key = key ?? identity()
        let page = try PDFPageGeometry(pageIndex: key.page, cropOrigin: PDFPoint(x: 10, y: 20),
                                       width: width, height: 200, rotation: rotation)
        let first = try PDFQuad(topLeft: PDFPoint(x: 15 + shift, y: 200),
                                topRight: PDFPoint(x: 90 + shift, y: 200),
                                bottomRight: PDFPoint(x: 90 + shift, y: 180),
                                bottomLeft: PDFPoint(x: 15 + shift, y: 180), page: page)
        let second = try PDFQuad(topLeft: PDFPoint(x: 15, y: 170),
                                 topRight: PDFPoint(x: 70, y: 170),
                                 bottomRight: PDFPoint(x: 70, y: 150),
                                 bottomLeft: PDFPoint(x: 15, y: 150), page: page)
        let canonicalID = try PDFSentenceIdentity(
            paperID: key.paperID, pdfSHA256: key.pdfSHA256,
            extractionRevision: key.revision.uuidString.lowercased(),
            pageIndex: key.page, sentenceID: key.sentenceID)
        return try PDFSentenceAnchor(identity: canonicalID, fullSourceQuote: quote ?? self.quote,
                                     page: page, quads: dropContinuation ? [first] : [first, second])
    }

    private func validator(_ anchors: [PDFSentenceAnchor], tolerance: Double = 0) throws
        -> CanonicalExtractionGeometryValidator {
        // Synthetic test input only, never a product precision/profile selection.
        try CanonicalExtractionGeometryValidator(
            owningAnchors: anchors, precision: PDFGeometryPrecision(maximumErrorPDFPoints: tolerance))
    }

    private func encode(_ anchor: PDFSentenceAnchor, with validator: CanonicalExtractionGeometryValidator,
                        identity: ExtractionSentenceIdentity? = nil) throws -> ExtractionGeometryEncoding {
        try validator.validateAndEncode(CanonicalExtractionGeometryInput(anchor: anchor),
                                        identity: identity ?? self.identity(),
                                        expectedText: anchor.fullSourceQuote)
    }

    private func mutate(_ bytes: Data, _ change: (inout [String: Any]) -> Void) throws -> Data {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        change(&object)
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func assertError<T, E: Error & Equatable>(_ expected: E,
                                                    file: StaticString = #filePath, line: UInt = #line,
                                                    _ body: () throws -> T) {
        XCTAssertThrowsError(try body(), file: file, line: line) {
            XCTAssertEqual($0 as? E, expected, file: file, line: line)
        }
    }

    func testCanonicalCodecPreservesFullExtentCropOriginRotationAndOrderedVertices() throws {
        for rotation in [0, 90, 180, 270] {
            let original = try anchor(rotation: rotation)
            let codec = try validator([original])
            let encoding = try encode(original, with: codec)
            XCTAssertEqual(encoding.quadCount, 2)
            let decoded = try codec.decodeAndValidate(encoding.canonicalBytes, identity: identity())
            XCTAssertEqual(decoded, original)
            XCTAssertTrue(decoded.fullSourceQuote.utf8.elementsEqual(quote.utf8))
            XCTAssertEqual(decoded.page.cropOrigin, PDFPoint(x: 10, y: 20))
            XCTAssertEqual(decoded.page.rotation, rotation)
            XCTAssertEqual(decoded.quads[0].points, [PDFPoint(x: 15, y: 200), PDFPoint(x: 90, y: 200),
                                                     PDFPoint(x: 90, y: 180), PDFPoint(x: 15, y: 180)])
            XCTAssertEqual(try encode(decoded, with: codec).canonicalBytes, encoding.canonicalBytes)
        }
    }

    func testEveryIdentityComponentMustMatchAndMembershipCannotComeFromInput() throws {
        let original = try anchor()
        let codec = try validator([original])
        let cases: [(ExtractionSentenceIdentity, PDFGeometryError)] = [
            (identity(paper: UUID(uuidString: "00000000-0000-4000-8000-000000000003")!), .identityMismatch),
            (identity(hash: String(repeating: "b", count: 64)), .identityMismatch),
            (identity(revision: UUID(uuidString: "00000000-0000-4000-8000-000000000004")!), .staleRevision),
            (identity(page: 1), .identityMismatch),
            (identity(sentence: 8), .identityMismatch),
        ]
        for (key, error) in cases {
            assertError(error) { try encode(original, with: codec, identity: key) }
            let unowned = try anchor(identity: key)
            assertError(PDFGeometryError.unknownSentence) { try encode(unowned, with: codec, identity: key) }
        }
        let emptyOwner = try validator([])
        assertError(PDFGeometryError.unknownSentence) { try encode(original, with: emptyOwner) }
        let bytes = try encode(original, with: codec).canonicalBytes
        assertError(PDFGeometryError.unknownSentence) { try emptyOwner.decodeAndValidate(bytes, identity: identity()) }
    }

    func testUnknownGeometryDuplicateOwnershipAndInvalidExpectedIdentityFail() throws {
        let original = try anchor()
        let codec = try validator([original])
        assertError(CanonicalExtractionGeometryError.unsupportedInput) {
            try codec.validateAndEncode(UnknownGeometry(), identity: identity(), expectedText: quote)
        }
        assertError(CanonicalExtractionGeometryError.duplicateSentence) { try validator([original, original]) }
        for key in [identity(page: -1), identity(page: 2000), identity(sentence: -1),
                    identity(sentence: 200000), identity(hash: pdfSHA256.uppercased()),
                    identity(revision: UUID(uuidString: "00000000-0000-1000-8000-000000000002")!)] {
            assertError(PDFGeometryError.invalidIdentity) { try encode(original, with: codec, identity: key) }
        }
        let lastKey = identity(page: 1999, sentence: 199999)
        let last = try anchor(identity: lastKey)
        let lastCodec = try validator([last])
        let bytes = try encode(last, with: lastCodec, identity: lastKey).canonicalBytes
        XCTAssertEqual(try lastCodec.decodeAndValidate(bytes, identity: lastKey), last)
    }

    func testTruncatedQuoteDroppedContinuationAndDifferentPageMetadataFail() throws {
        let original = try anchor()
        let codec = try validator([original])
        for candidate in [try anchor(quote: "Original full sentence"), try anchor(dropContinuation: true)] {
            assertError(CanonicalExtractionGeometryError.semanticExtentMismatch) { try encode(candidate, with: codec) }
        }
        for candidate in [try anchor(rotation: 90), try anchor(width: 101)] {
            assertError(CanonicalExtractionGeometryError.pageGeometryMismatch) { try encode(candidate, with: codec) }
        }
        let composed = try anchor(quote: "é")
        let decomposed = try anchor(quote: "é")
        assertError(CanonicalExtractionGeometryError.semanticExtentMismatch) {
            try encode(decomposed, with: validator([composed]))
        }
    }

    func testExpectedTextMustMatchAdmittedFullSourceQuoteByteForByte() throws {
        let original = try anchor()
        let codec = try validator([original])
        let input = CanonicalExtractionGeometryInput(anchor: original)
        let exact = try codec.validateAndEncode(input, identity: identity(), expectedText: quote)
        XCTAssertEqual(try codec.decodeAndValidate(exact.canonicalBytes, identity: identity()), original)
        for text in ["Different sentence.", "Original full sentence",
                     "Original full sentence including its continuation.",
                     "Original full sentence\nincluding a different continuation."] {
            assertError(CanonicalExtractionGeometryError.semanticExtentMismatch) {
                try codec.validateAndEncode(input, identity: identity(), expectedText: text)
            }
        }
        let composed = try anchor(quote: "é")
        let composedCodec = try validator([composed])
        let composedInput = CanonicalExtractionGeometryInput(anchor: composed)
        let composedBytes = try composedCodec.validateAndEncode(composedInput, identity: identity(),
                                                                 expectedText: "é").canonicalBytes
        XCTAssertTrue(try composedCodec.decodeAndValidate(composedBytes, identity: identity())
            .fullSourceQuote.utf8.elementsEqual("é".utf8))
        XCTAssertEqual("é", "é") // Swift equality alone would admit the normalization mismatch.
        assertError(CanonicalExtractionGeometryError.semanticExtentMismatch) {
            try composedCodec.validateAndEncode(composedInput, identity: identity(), expectedText: "é")
        }
    }

    func testExplicitPrecisionBoundaryAndJustOverRejectWithoutQuantizing() throws {
        let original = try anchor()
        let codec = try validator([original], tolerance: 1)
        let boundary = try anchor(shift: 1)
        let bytes = try encode(boundary, with: codec).canonicalBytes
        XCTAssertEqual(try codec.decodeAndValidate(bytes, identity: identity()), boundary)
        let over = try anchor(shift: Double(16).nextUp - 15)
        assertError(PDFGeometryError.roundtripExceeded) { try encode(over, with: codec) }
        let exact = try validator([original])
        assertError(PDFGeometryError.roundtripExceeded) { try encode(boundary, with: exact) }
    }

    func testDecodedBytesCannotRebindOrNarrowOwningSemanticExtent() throws {
        let original = try anchor()
        let codec = try validator([original])
        let bytes = try encode(original, with: codec).canonicalBytes
        let truncated = try mutate(bytes) { $0["fullSourceQuote"] = "Original full sentence" }
        let dropped = try mutate(bytes) { object in
            object["quads"] = Array((object["quads"] as! [[String: Any]]).prefix(1))
        }
        for changed in [truncated, dropped] {
            assertError(CanonicalExtractionGeometryError.semanticExtentMismatch) {
                try codec.decodeAndValidate(changed, identity: identity())
            }
        }
        let stale = try mutate(bytes) { $0["extractionRevision"] = "00000000-0000-4000-8000-000000000004" }
        assertError(PDFGeometryError.staleRevision) { try codec.decodeAndValidate(stale, identity: identity()) }
        let anotherPaper = try mutate(bytes) { $0["paperID"] = "00000000-0000-4000-8000-000000000003" }
        assertError(PDFGeometryError.identityMismatch) {
            try codec.decodeAndValidate(anotherPaper, identity: identity())
        }
        let differentCrop = try mutate(bytes) { $0["cropOrigin"] = ["x": 11, "y": 20] }
        assertError(CanonicalExtractionGeometryError.pageGeometryMismatch) {
            try codec.decodeAndValidate(differentCrop, identity: identity())
        }
        let reordered = try mutate(bytes) { object in
            object["quads"] = Array((object["quads"] as! [[String: Any]]).reversed())
        }
        assertError(PDFGeometryError.roundtripExceeded) {
            try codec.decodeAndValidate(reordered, identity: identity())
        }
    }

    func testDecoderRejectsUnknownVersionMalformedIdentityEmptyAndInvalidQuads() throws {
        let original = try anchor()
        let codec = try validator([original])
        let bytes = try encode(original, with: codec).canonicalBytes
        assertError(CanonicalExtractionGeometryError.invalidEncoding) {
            try codec.decodeAndValidate(Data("not JSON".utf8), identity: identity())
        }
        let unknownVersion = try mutate(bytes) { $0["version"] = 2 }
        assertError(CanonicalExtractionGeometryError.unsupportedEncodingVersion) {
            try codec.decodeAndValidate(unknownVersion, identity: identity())
        }
        let badHash = try mutate(bytes) { $0["pdfSHA256"] = self.pdfSHA256.uppercased() }
        assertError(PDFGeometryError.invalidIdentity) { try codec.decodeAndValidate(badHash, identity: identity()) }
        let noQuads = try mutate(bytes) { $0["quads"] = [] as [Any] }
        assertError(PDFGeometryError.missingGeometry) { try codec.decodeAndValidate(noQuads, identity: identity()) }
        let noQuote = try mutate(bytes) { $0["fullSourceQuote"] = "" }
        assertError(PDFGeometryError.missingGeometry) { try codec.decodeAndValidate(noQuote, identity: identity()) }
        let unsupportedRotation = try mutate(bytes) { $0["rotation"] = 45 }
        assertError(PDFGeometryError.unsupportedRotation) {
            try codec.decodeAndValidate(unsupportedRotation, identity: identity())
        }
        let outside = try mutate(bytes) { object in
            var quads = object["quads"] as! [[String: Any]]
            quads[0]["topLeft"] = ["x": 9, "y": 200]
            object["quads"] = quads
        }
        assertError(PDFGeometryError.outsidePage) { try codec.decodeAndValidate(outside, identity: identity()) }
        let mirrored = try mutate(bytes) { object in
            var quads = object["quads"] as! [[String: Any]]
            let first = quads[0]
            quads[0] = ["topLeft": first["topRight"]!, "topRight": first["topLeft"]!,
                        "bottomRight": first["bottomLeft"]!, "bottomLeft": first["bottomRight"]!]
            object["quads"] = quads
        }
        assertError(PDFGeometryError.malformedGeometry) { try codec.decodeAndValidate(mirrored, identity: identity()) }
        let wrongType = try mutate(bytes) { $0["width"] = "NaN" }
        assertError(CanonicalExtractionGeometryError.invalidEncoding) {
            try codec.decodeAndValidate(wrongType, identity: identity())
        }
    }
}
