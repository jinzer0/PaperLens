import Foundation
import PDFKit

/// Uses only public PDFKit page/view conversions. Never opens a document or stores a view transform.
@MainActor
public enum PDFKitGeometryAdapter {
    public static func pageGeometry(page: PDFPage, in view: PDFView,
                                    pageIndex: Int) throws -> PDFPageGeometry {
        guard let document = view.document, pageIndex >= 0,
              pageIndex < document.pageCount,
              let member = document.page(at: pageIndex) else {
            throw PDFGeometryError.missingPage
        }
        guard member === page else {
            throw PDFGeometryError.differentPage
        }
        let crop = page.bounds(for: .cropBox)
        let rotation = ((page.rotation % 360) + 360) % 360
        return try PDFPageGeometry(pageIndex: pageIndex,
                                   cropOrigin: PDFPoint(x: Double(crop.minX), y: Double(crop.minY)),
                                   width: Double(crop.width), height: Double(crop.height),
                                   rotation: rotation)
    }

    public static func displayPoint(_ point: PDFPoint, page: PDFPage, in view: PDFView,
                                    geometry: PDFPageGeometry,
                                    precision: PDFGeometryPrecision) throws -> PDFPoint {
        try validatePage(page, view: view, geometry: geometry)
        try geometry.validate(point)
        let transform = try captureAffine(page: page, view: view, geometry: geometry,
                                          precision: precision)
        let mapped = try transform.applying(point)
        let direct = view.convert(cgPoint(point), from: page)
        let directPoint = pdfPoint(direct)
        try directPoint.validate()
        // Compare in PDF points, not screen pixels or an invented zoom-dependent tolerance.
        let affineBack = pdfPoint(view.convert(cgPoint(mapped), to: page))
        let directBack = pdfPoint(view.convert(direct, to: page))
        try precision.validate(expected: point, actual: affineBack)
        try precision.validate(expected: point, actual: directBack)
        return mapped
    }

    public static func canonicalPoint(_ point: PDFPoint, page: PDFPage, in view: PDFView,
                                      geometry: PDFPageGeometry,
                                      precision: PDFGeometryPrecision) throws -> PDFPoint {
        try point.validate()
        try validatePage(page, view: view, geometry: geometry)
        let transform = try captureAffine(page: page, view: view, geometry: geometry,
                                          precision: precision)
        let canonical = try transform.inverse(point)
        try geometry.validate(canonical)
        let direct = pdfPoint(view.convert(cgPoint(point), to: page))
        try geometry.validate(direct)
        try precision.validate(expected: canonical, actual: direct)
        let back = view.convert(cgPoint(canonical), from: page)
        let roundtrip = pdfPoint(view.convert(back, to: page))
        try precision.validate(expected: canonical, actual: roundtrip)
        return canonical
    }

    /// Returns all source quads, preserving semantic range and TL/TR/BR/BL order.
    public static func displayQuads(anchor: PDFSentenceAnchor, expected: PDFSentenceIdentity,
                                    publishedMembership: Set<PDFSentenceIdentity>,
                                    page: PDFPage, in view: PDFView,
                                    precision: PDFGeometryPrecision) throws -> [[PDFPoint]] {
        try anchor.validateResolution(expected: expected, publishedMembership: publishedMembership)
        try validatePage(page, view: view, geometry: anchor.page)
        let transform = try captureAffine(page: page, view: view, geometry: anchor.page,
                                          precision: precision)
        return try anchor.quads.map { quad in
            try quad.points.map { point in
                try anchor.page.validate(point)
                let mapped = try transform.applying(point)
                let back = pdfPoint(view.convert(cgPoint(mapped), to: page))
                try precision.validate(expected: point, actual: back)
                return mapped
            }
        }
    }

    private static func validatePage(_ page: PDFPage, view: PDFView,
                                     geometry: PDFPageGeometry) throws {
        let actual = try pageGeometry(page: page, in: view, pageIndex: geometry.pageIndex)
        guard actual == geometry else { throw PDFGeometryError.malformedGeometry }
        guard view.scaleFactor.isFinite, view.scaleFactor > 0 else {
            throw PDFGeometryError.malformedGeometry
        }
    }

    /// Three independent page-space basis landmarks determine the affine coefficients.
    /// The fourth corner and all basis landmarks are checked through public inverse conversion.
    private static func captureAffine(page: PDFPage, view: PDFView,
                                      geometry: PDFPageGeometry,
                                      precision: PDFGeometryPrecision) throws -> PDFGeometryAffine {
        let origin = geometry.cropOrigin
        let right = PDFPoint(x: origin.x + geometry.width, y: origin.y)
        let top = PDFPoint(x: origin.x, y: origin.y + geometry.height)
        let opposite = PDFPoint(x: right.x, y: top.y)
        let o = pdfPoint(view.convert(cgPoint(origin), from: page))
        let r = pdfPoint(view.convert(cgPoint(right), from: page))
        let t = pdfPoint(view.convert(cgPoint(top), from: page))
        try o.validate(); try r.validate(); try t.validate()
        let a = (r.x - o.x) / geometry.width
        let b = (r.y - o.y) / geometry.width
        let c = (t.x - o.x) / geometry.height
        let d = (t.y - o.y) / geometry.height
        let transform = try PDFGeometryAffine(a: a, b: b, c: c, d: d,
                                               tx: o.x - a * origin.x - c * origin.y,
                                               ty: o.y - b * origin.x - d * origin.y)
        for landmark in [origin, right, top, opposite] {
            let mapped = try transform.applying(landmark)
            let direct = view.convert(cgPoint(landmark), from: page)
            try precision.validate(expected: landmark,
                                   actual: pdfPoint(view.convert(direct, to: page)))
            try precision.validate(expected: landmark,
                                   actual: pdfPoint(view.convert(cgPoint(mapped), to: page)))
        }
        return transform
    }

    private static func cgPoint(_ point: PDFPoint) -> CGPoint {
        CGPoint(x: point.x, y: point.y)
    }

    private static func pdfPoint(_ point: CGPoint) -> PDFPoint {
        PDFPoint(x: Double(point.x), y: Double(point.y))
    }
}
