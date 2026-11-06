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

    private func nativeQuad(_ quad: PDFQuad) throws -> PDFiumRawQuad {
        try PDFiumRawQuad(topLeftX: quad.topLeft.x - 10, topLeftY: quad.topLeft.y - 20,
                          topRightX: quad.topRight.x - 10, topRightY: quad.topRight.y - 20,
                          bottomRightX: quad.bottomRight.x - 10, bottomRightY: quad.bottomRight.y - 20,
                          bottomLeftX: quad.bottomLeft.x - 10, bottomLeftY: quad.bottomLeft.y - 20)
    }

    private func glyph(_ scalar: UInt32, native: Int, start: Int, length: Int,
                       quad: PDFiumRawQuad?, matrixB: Double = 0) throws -> PDFiumGlyph {
        try PDFiumGlyph(nativeCharacterIndex: native, unicodeScalar: scalar,
                        utf16Start: start, utf16Length: length, generated: false,
                        matrixA: 1, matrixB: matrixB, matrixC: 0, matrixD: 1,
                        matrixE: 0, matrixF: 0, rawQuad: quad)
    }

    private func nativeFixture() throws -> (PDFSentenceAnchor, PDFiumGeometryInput, PDFiumPageMapping) {
        // Explicit owned synthetic coordinates, not a PDFium calibration or production profile.
        let owner = try anchor(quote: "A 😀")
        let bounds = try PDFiumRawQuad(topLeftX: 0, topLeftY: 200, topRightX: 100, topRightY: 200,
                                      bottomRightX: 100, bottomRightY: 0, bottomLeftX: 0, bottomLeftY: 0)
        let rawPage = try PDFiumRawPage(pageIndex: 0, boundingBox: bounds, mediaBox: bounds,
                                       cropBox: bounds, rotationQuarterTurns: 0)
        let glyphs = try [glyph(65, native: 4, start: 8, length: 1, quad: nativeQuad(owner.quads[0])),
                         glyph(32, native: 5, start: 9, length: 1, quad: nil),
                         glyph(0x1F600, native: 6, start: 10, length: 2, quad: nativeQuad(owner.quads[1]))]
        let input = PDFiumGeometryInput(identity: identity(), sourceText: owner.fullSourceQuote,
                                       nativeStartCharacter: 4, nativeCharacterCount: 3,
                                       rawPage: rawPage, glyphs: glyphs)
        let mapping = try PDFiumPageMapping(
            page: owner.page, rawToCanonical: PDFGeometryAffine(a: 1, b: 0, c: 0, d: 1, tx: 10, ty: 20),
            canonicalToReader: PDFGeometryAffine(a: 2, b: 0, c: 0, d: -2, tx: 0, ty: 440))
        return (owner, input, mapping)
    }

    private func nativeValidator(_ mapping: PDFiumPageMapping, tolerance: Double = 0) throws -> PDFiumGeometryValidator {
        try PDFiumGeometryValidator(binding: PDFiumGeometryBinding(
            precision: PDFGeometryPrecision(maximumErrorPDFPoints: tolerance), mapPage: { _ in mapping }))
    }

    private func replacing(_ input: PDFiumGeometryInput, text: String? = nil, page: PDFiumRawPage? = nil,
                           glyphs: [PDFiumGlyph]? = nil) -> PDFiumGeometryInput {
        PDFiumGeometryInput(identity: input.identity, sourceText: text ?? input.sourceText,
                            nativeStartCharacter: input.nativeStartCharacter,
                            nativeCharacterCount: input.nativeCharacterCount,
                            rawPage: page ?? input.rawPage, glyphs: glyphs ?? input.glyphs)
    }

    func testSummaryResolverPreservesIndependentFullExtentAndEveryHitIdentity() throws {
        for rotation in [0, 90, 180, 270] {
            let owner = try anchor(rotation: rotation)
            let codec = try validator([owner])
            let bytes = try encode(owner, with: codec).canonicalBytes
            let hit = ExtractionSearchHit(revision: revision, page: 0, sentenceID: 7,
                                          text: quote, canonicalGeometry: bytes)
            let resolver: any LibrarySummaryGeometryValidating = codec
            XCTAssertEqual(try resolver.resolve(hit, identity: owner.identity), owner)
            let wrongHits = [
                ExtractionSearchHit(revision: UUID(), page: 0, sentenceID: 7, text: quote, canonicalGeometry: bytes),
                ExtractionSearchHit(revision: revision, page: 1, sentenceID: 7, text: quote, canonicalGeometry: bytes),
                ExtractionSearchHit(revision: revision, page: 0, sentenceID: 8, text: quote, canonicalGeometry: bytes)
            ]
            for wrong in wrongHits {
                assertError(LibrarySummaryError.invalidGrounding) {
                    try resolver.resolve(wrong, identity: owner.identity)
                }
            }
            assertError(PDFGeometryError.unknownSentence) {
                try validator([]).resolve(hit, identity: owner.identity)
            }
        }
    }

    func testSummaryResolverRejectsTruncatedOrForgedCanonicalExtentAndHitText() throws {
        let owner = try anchor()
        let codec = try validator([owner])
        let bytes = try encode(owner, with: codec).canonicalBytes
        let truncatedQuote = try mutate(bytes) { $0["fullSourceQuote"] = "Original full sentence" }
        let droppedQuad = try mutate(bytes) { object in
            object["quads"] = Array((object["quads"] as! [[String: Any]]).prefix(1))
        }
        for changed in [truncatedQuote, droppedQuad] {
            assertError(CanonicalExtractionGeometryError.semanticExtentMismatch) {
                try codec.resolve(.init(revision: revision, page: 0, sentenceID: 7,
                                        text: quote, canonicalGeometry: changed), identity: owner.identity)
            }
        }
        let wrongPage = try mutate(bytes) { $0["width"] = 101 }
        assertError(CanonicalExtractionGeometryError.pageGeometryMismatch) {
            try codec.resolve(.init(revision: revision, page: 0, sentenceID: 7,
                                    text: quote, canonicalGeometry: wrongPage), identity: owner.identity)
        }
        let stale = try mutate(bytes) { $0["extractionRevision"] = UUID().uuidString.lowercased() }
        assertError(PDFGeometryError.staleRevision) {
            try codec.resolve(.init(revision: revision, page: 0, sentenceID: 7,
                                    text: quote, canonicalGeometry: stale), identity: owner.identity)
        }
        let composed = try anchor(quote: "é")
        let composedCodec = try validator([composed])
        let composedBytes = try encode(composed, with: composedCodec).canonicalBytes
        assertError(CanonicalExtractionGeometryError.semanticExtentMismatch) {
            try composedCodec.resolve(.init(revision: revision, page: 0, sentenceID: 7,
                                            text: "é", canonicalGeometry: composedBytes), identity: composed.identity)
        }
    }

    func testSummaryResolverUsesExplicitOwnerPrecisionRatherThanDecodedCoordinates() throws {
        let owner = try anchor()
        let boundary = try anchor(shift: 1)
        let over = try anchor(shift: Double(16).nextUp - 15)
        let codec = try validator([owner], tolerance: 1)
        for candidate in [boundary, over] {
            // Separate synthetic encoding owner; resolving authority stays the original owner.
            let bytes = try encode(candidate, with: validator([candidate])).canonicalBytes
            let hit = ExtractionSearchHit(revision: revision, page: 0, sentenceID: 7,
                                          text: quote, canonicalGeometry: bytes)
            if candidate == boundary {
                XCTAssertEqual(try codec.resolve(hit, identity: owner.identity), boundary)
                assertError(PDFGeometryError.roundtripExceeded) {
                    try validator([owner]).resolve(hit, identity: owner.identity)
                }
            } else {
                assertError(PDFGeometryError.roundtripExceeded) {
                    try codec.resolve(hit, identity: owner.identity)
                }
            }
        }
    }

    func testNativeGeometryUsesOwningCanonicalCodecBytesAndDecoder() throws {
        let (owner, input, mapping) = try nativeFixture()
        let native = try nativeValidator(mapping).validateAndEncode(input, identity: identity(),
                                                                   expectedText: owner.fullSourceQuote)
        let codec = try validator([owner])
        let decoded = try codec.decodeAndValidate(native.canonicalBytes, identity: identity())
        XCTAssertEqual(decoded.identity, owner.identity)
        XCTAssertTrue(decoded.fullSourceQuote.utf8.elementsEqual(owner.fullSourceQuote.utf8))
        XCTAssertEqual(decoded.page, owner.page)
        XCTAssertEqual(decoded.quads, owner.quads)
        XCTAssertEqual(native.quadCount, owner.quads.count)
        XCTAssertEqual(try XCTUnwrap(native.originalOwner).anchor, owner)
        XCTAssertEqual(native.originalOwner?.precision.maximumErrorPDFPoints, 0)
        XCTAssertEqual(native.canonicalBytes, try encode(owner, with: codec).canonicalBytes)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: native.canonicalBytes) as? [String: Any])
        XCTAssertEqual(object["version"] as? Int, 1)
        assertError(PDFGeometryError.unknownSentence) {
            try validator([]).decodeAndValidate(native.canonicalBytes, identity: identity())
        }
    }

    func testNativeOriginalOwnerRetainsExplicitPrecisionAndCannotComeFromCandidateCodec() throws {
        let (expected, input, mapping) = try nativeFixture()
        let native = try nativeValidator(mapping, tolerance: 0.25)
            .validateAndEncode(input, identity: identity(), expectedText: expected.fullSourceQuote)
        let original = try XCTUnwrap(native.originalOwner)
        XCTAssertEqual(original.anchor, expected)
        XCTAssertEqual(original.precision.maximumErrorPDFPoints, 0.25)
        let archive = try original.archive(for: identity(), text: expected.fullSourceQuote,
                                           candidate: native.canonicalBytes)
        XCTAssertEqual(archive.maximumErrorPDFPoints, 0.25)
        XCTAssertEqual(archive.anchors.count, 1)
        XCTAssertEqual(try CanonicalExtractionGeometryValidator.decodeCanonicalAnchor(
            XCTUnwrap(archive.anchors.first).bytes), expected)
        let candidateOnly = try encode(expected, with: validator([expected], tolerance: 0.25))
        XCTAssertEqual(candidateOnly.canonicalBytes, native.canonicalBytes)
        XCTAssertNil(candidateOnly.originalOwner)
        XCTAssertNil(ExtractionGeometryEncoding(canonicalBytes: native.canonicalBytes,
                                                 quadCount: native.quadCount).originalOwner)
        assertError(PDFGeometryError.identityMismatch) {
            try original.archive(for: identity(paper: UUID()), text: expected.fullSourceQuote,
                                 candidate: native.canonicalBytes)
        }
        assertError(ExtractionError.invalidBatch) {
            try original.archive(for: identity(), text: "shortened", candidate: native.canonicalBytes)
        }
    }

    func testNativeCodecRejectsIdentityRawPageAndByteDifferentText() throws {
        let (owner, input, mapping) = try nativeFixture()
        let native = try nativeValidator(mapping)
        let keys = [identity(paper: UUID(uuidString: "00000000-0000-4000-8000-000000000003")!),
                    identity(hash: String(repeating: "b", count: 64)),
                    identity(revision: UUID(uuidString: "00000000-0000-4000-8000-000000000004")!),
                    identity(page: 1), identity(sentence: 8)]
        for key in keys {
            assertError(ExtractionError.invalidBatch) {
                try native.validateAndEncode(input, identity: key, expectedText: owner.fullSourceQuote)
            }
        }
        let wrongPage = try PDFiumRawPage(pageIndex: 1, boundingBox: input.rawPage.boundingBox,
                                         mediaBox: nil, cropBox: nil, rotationQuarterTurns: 0)
        assertError(ExtractionError.invalidBatch) {
            try native.validateAndEncode(replacing(input, page: wrongPage), identity: identity(),
                                         expectedText: owner.fullSourceQuote)
        }
        let composedGlyph = try glyph(0xE9, native: 4, start: 8, length: 1, quad: input.glyphs[0].rawQuad)
        let composed = PDFiumGeometryInput(identity: identity(), sourceText: "é", nativeStartCharacter: 4,
                                          nativeCharacterCount: 1, rawPage: input.rawPage, glyphs: [composedGlyph])
        XCTAssertEqual("é", "é")
        assertError(ExtractionError.invalidBatch) {
            try native.validateAndEncode(composed, identity: identity(), expectedText: "é")
        }
        assertError(PDFGeometryError.malformedGeometry) {
            try native.validateAndEncode(replacing(composed, text: "é"), identity: identity(), expectedText: "é")
        }
    }

    func testNativeCodecRejectsGlyphGapsUTF16UnsupportedMatrixAndMissingQuad() throws {
        let (owner, input, mapping) = try nativeFixture()
        let native = try nativeValidator(mapping)
        for (nativeIndex, start) in [(7, 10), (6, 11)] {
            let changed = try glyph(0x1F600, native: nativeIndex, start: start, length: 2,
                                    quad: input.glyphs[2].rawQuad)
            assertError(PDFGeometryError.malformedGeometry) {
                try native.validateAndEncode(replacing(input, glyphs: [input.glyphs[0], input.glyphs[1], changed]),
                                             identity: identity(), expectedText: owner.fullSourceQuote)
            }
        }
        let skewed = try glyph(65, native: 4, start: 8, length: 1, quad: input.glyphs[0].rawQuad, matrixB: 1)
        assertError(PDFGeometryError.unsupportedRotation) {
            try native.validateAndEncode(replacing(input, glyphs: [skewed, input.glyphs[1], input.glyphs[2]]),
                                         identity: identity(), expectedText: owner.fullSourceQuote)
        }
        // DTO admission rejects these before a malformed glyph can reach the codec.
        XCTAssertThrowsError(try glyph(0x1F600, native: 6, start: 10, length: 1,
                                       quad: input.glyphs[2].rawQuad)) {
            XCTAssertEqual(($0 as? PDFiumFailure)?.code, .unmappableText)
        }
        XCTAssertThrowsError(try glyph(65, native: 4, start: 8, length: 1, quad: nil)) {
            XCTAssertEqual(($0 as? PDFiumFailure)?.code, .unmappableText)
        }
    }

    func testNativeCodecRejectsMappingPageRotationBoundsAndRoundtripLoss() throws {
        let (owner, input, mapping) = try nativeFixture()
        for page in [try anchor(identity: identity(page: 1)).page, try anchor(rotation: 90).page] {
            let wrong = PDFiumPageMapping(page: page, rawToCanonical: mapping.rawToCanonical,
                                          canonicalToReader: mapping.canonicalToReader)
            assertError(PDFGeometryError.identityMismatch) {
                try nativeValidator(wrong).validateAndEncode(input, identity: identity(),
                                                             expectedText: owner.fullSourceQuote)
            }
        }
        let rotatedRaw = try PDFiumRawPage(pageIndex: 0, boundingBox: input.rawPage.boundingBox,
                                          mediaBox: nil, cropBox: nil, rotationQuarterTurns: 1)
        assertError(PDFGeometryError.identityMismatch) {
            try nativeValidator(mapping).validateAndEncode(replacing(input, page: rotatedRaw),
                                                           identity: identity(), expectedText: owner.fullSourceQuote)
        }
        let outside = try PDFiumPageMapping(page: owner.page,
            rawToCanonical: PDFGeometryAffine(a: 1, b: 0, c: 0, d: 1, tx: 1000, ty: 20),
            canonicalToReader: mapping.canonicalToReader)
        assertError(PDFGeometryError.outsidePage) {
            try nativeValidator(outside).validateAndEncode(input, identity: identity(), expectedText: owner.fullSourceQuote)
        }
        let lossy = try PDFiumPageMapping(page: owner.page, rawToCanonical: mapping.rawToCanonical,
            canonicalToReader: PDFGeometryAffine(a: 1, b: 0, c: 0, d: 1, tx: 1e20, ty: 1e20))
        assertError(PDFGeometryError.roundtripExceeded) {
            try nativeValidator(lossy).validateAndEncode(input, identity: identity(), expectedText: owner.fullSourceQuote)
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
