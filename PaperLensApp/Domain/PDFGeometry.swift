import Foundation

public enum PDFGeometryError: Error, Equatable {
    case malformedGeometry
    case outsidePage
    case unsupportedRotation
    case invalidPrecision
    case invalidIdentity
    case identityMismatch
    case staleRevision
    case unknownSentence
    case missingGeometry
    case missingPage
    case differentPage
    case roundtripExceeded
}

/// Explicit error budget, measured per axis in unrotated PDF points. No product default.
public struct PDFGeometryPrecision: Equatable, Sendable {
    public let maximumErrorPDFPoints: Double

    public init(maximumErrorPDFPoints: Double) throws {
        guard maximumErrorPDFPoints.isFinite, maximumErrorPDFPoints >= 0 else {
            throw PDFGeometryError.invalidPrecision
        }
        self.maximumErrorPDFPoints = maximumErrorPDFPoints
    }

    public func validate(expected: PDFPoint, actual: PDFPoint) throws {
        try expected.validate()
        try actual.validate()
        guard abs(expected.x - actual.x) <= maximumErrorPDFPoints,
              abs(expected.y - actual.y) <= maximumErrorPDFPoints else {
            throw PDFGeometryError.roundtripExceeded
        }
    }
}

public struct PDFPoint: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
    public func validate() throws {
        guard x.isFinite, y.isFinite else { throw PDFGeometryError.malformedGeometry }
    }
}

/// Absolute unrotated page coordinates; retains the actual CropBox origin.
public struct PDFPageGeometry: Equatable, Sendable {
    public let pageIndex: Int
    public let cropOrigin: PDFPoint
    public let width: Double
    public let height: Double
    public let rotation: Int

    public init(pageIndex: Int, cropOrigin: PDFPoint, width: Double, height: Double,
                rotation: Int) throws {
        try cropOrigin.validate()
        guard (0...1999).contains(pageIndex), width.isFinite, height.isFinite,
              width > 0, height > 0,
              (cropOrigin.x + width).isFinite, (cropOrigin.y + height).isFinite,
              cropOrigin.x + width > cropOrigin.x,
              cropOrigin.y + height > cropOrigin.y else {
            throw PDFGeometryError.malformedGeometry
        }
        guard [0, 90, 180, 270].contains(rotation) else {
            throw PDFGeometryError.unsupportedRotation
        }
        self.pageIndex = pageIndex
        self.cropOrigin = cropOrigin
        self.width = width
        self.height = height
        self.rotation = rotation
    }

    public func validate(_ point: PDFPoint) throws {
        try point.validate()
        guard point.x >= cropOrigin.x, point.x <= cropOrigin.x + width,
              point.y >= cropOrigin.y, point.y <= cropOrigin.y + height else {
            throw PDFGeometryError.outsidePage
        }
    }

    /// For an extraction backend explicitly supplying unrotated crop-local top-left points.
    /// Raw PDFium coordinates with another convention must not call this conversion.
    public func canonicalFromCropTopLeft(_ point: PDFPoint) throws -> PDFPoint {
        try point.validate()
        guard point.x >= 0, point.x <= width, point.y >= 0, point.y <= height else {
            throw PDFGeometryError.outsidePage
        }
        let canonical = PDFPoint(x: cropOrigin.x + point.x,
                                 y: cropOrigin.y + height - point.y)
        try validate(canonical)
        return canonical
    }

    public func rotatedTopLeft(fromCanonical point: PDFPoint) throws -> PDFPoint {
        try validate(point)
        let x = point.x - cropOrigin.x
        let y = point.y - cropOrigin.y
        switch rotation {
        case 0: return PDFPoint(x: x, y: height - y)
        case 90: return PDFPoint(x: y, y: x)
        case 180: return PDFPoint(x: width - x, y: y)
        default: return PDFPoint(x: height - y, y: width - x)
        }
    }

    public func canonical(fromRotatedTopLeft point: PDFPoint) throws -> PDFPoint {
        try point.validate()
        let rotatedWidth = rotation == 90 || rotation == 270 ? height : width
        let rotatedHeight = rotation == 90 || rotation == 270 ? width : height
        guard point.x >= 0, point.x <= rotatedWidth,
              point.y >= 0, point.y <= rotatedHeight else {
            throw PDFGeometryError.outsidePage
        }
        let local: PDFPoint
        switch rotation {
        case 0: local = PDFPoint(x: point.x, y: height - point.y)
        case 90: local = PDFPoint(x: point.y, y: point.x)
        case 180: local = PDFPoint(x: width - point.x, y: point.y)
        default: local = PDFPoint(x: width - point.y, y: height - point.x)
        }
        let result = PDFPoint(x: local.x + cropOrigin.x, y: local.y + cropOrigin.y)
        try validate(result)
        return result
    }
}

public struct PDFQuad: Equatable, Sendable {
    public let topLeft: PDFPoint
    public let topRight: PDFPoint
    public let bottomRight: PDFPoint
    public let bottomLeft: PDFPoint
    public var points: [PDFPoint] { [topLeft, topRight, bottomRight, bottomLeft] }

    public init(topLeft: PDFPoint, topRight: PDFPoint, bottomRight: PDFPoint,
                bottomLeft: PDFPoint, page: PDFPageGeometry) throws {
        let vertices = [topLeft, topRight, bottomRight, bottomLeft]
        for point in vertices { try page.validate(point) }
        // Canonical TL/TR/BR/BL is clockwise. Reject collapsed, mirrored and crossed quads.
        for index in 0..<4 {
            let a = vertices[index]
            let b = vertices[(index + 1) % 4]
            let c = vertices[(index + 2) % 4]
            let cross = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
            guard cross.isFinite, cross < 0 else { throw PDFGeometryError.malformedGeometry }
        }
        self.topLeft = topLeft
        self.topRight = topRight
        self.bottomRight = bottomRight
        self.bottomLeft = bottomLeft
    }
}

/// No normalization or alternate ID equivalence: exact five-component equality only.
public struct PDFSentenceIdentity: Hashable, Sendable {
    public let paperID: UUID
    public let pdfSHA256: String
    public let extractionRevision: String
    public let pageIndex: Int
    public let sentenceID: Int

    public init(paperID: UUID, pdfSHA256: String, extractionRevision: String,
                pageIndex: Int, sentenceID: Int) throws {
        guard pdfSHA256.utf8.count == 64,
              pdfSHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              extractionRevision.utf8.count == 36,
              extractionRevision.range(
                of: "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$",
                options: .regularExpression) != nil,
              (0...1999).contains(pageIndex),
              (0...199999).contains(sentenceID) else { throw PDFGeometryError.invalidIdentity }
        self.paperID = paperID
        self.pdfSHA256 = pdfSHA256
        self.extractionRevision = extractionRevision
        self.pageIndex = pageIndex
        self.sentenceID = sentenceID
    }
}

public struct PDFSentenceAnchor: Equatable, Sendable {
    public let identity: PDFSentenceIdentity
    public let fullSourceQuote: String
    public let page: PDFPageGeometry
    public let quads: [PDFQuad]

    public init(identity: PDFSentenceIdentity, fullSourceQuote: String,
                page: PDFPageGeometry, quads: [PDFQuad]) throws {
        guard identity.pageIndex == page.pageIndex else { throw PDFGeometryError.differentPage }
        guard !fullSourceQuote.isEmpty, !quads.isEmpty else { throw PDFGeometryError.missingGeometry }
        for quad in quads { for point in quad.points { try page.validate(point) } }
        self.identity = identity
        self.fullSourceQuote = fullSourceQuote
        self.page = page
        self.quads = quads
    }

    /// Membership must come from the owning published revision, not guessed nearest geometry.
    public func validateResolution(expected: PDFSentenceIdentity,
                                   publishedMembership: Set<PDFSentenceIdentity>) throws {
        guard identity.paperID == expected.paperID, identity.pdfSHA256 == expected.pdfSHA256 else {
            throw PDFGeometryError.identityMismatch
        }
        guard identity.extractionRevision == expected.extractionRevision else {
            throw PDFGeometryError.staleRevision
        }
        guard identity == expected else { throw PDFGeometryError.identityMismatch }
        guard publishedMembership.contains(identity) else { throw PDFGeometryError.unknownSentence }
    }
}

/// x' = a*x + c*y + tx, y' = b*x + d*y + ty. Stateless, finite and invertible.
public struct PDFGeometryAffine: Equatable, Sendable {
    public let a: Double
    public let b: Double
    public let c: Double
    public let d: Double
    public let tx: Double
    public let ty: Double

    public init(a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double) throws {
        let determinant = a * d - b * c
        guard [a, b, c, d, tx, ty, determinant].allSatisfy(\.isFinite), determinant != 0 else {
            throw PDFGeometryError.malformedGeometry
        }
        self.a = a; self.b = b; self.c = c; self.d = d; self.tx = tx; self.ty = ty
    }

    public func applying(_ point: PDFPoint) throws -> PDFPoint {
        try point.validate()
        let result = PDFPoint(x: a * point.x + c * point.y + tx,
                              y: b * point.x + d * point.y + ty)
        try result.validate()
        return result
    }

    public func inverse(_ point: PDFPoint) throws -> PDFPoint {
        try point.validate()
        let determinant = a * d - b * c
        let x = point.x - tx
        let y = point.y - ty
        let result = PDFPoint(x: (d * x - c * y) / determinant,
                              y: (-b * x + a * y) / determinant)
        try result.validate()
        return result
    }
}
