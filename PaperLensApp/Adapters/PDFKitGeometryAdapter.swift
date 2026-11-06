import Foundation
import PDFKit

/// A quarter-turn map between two strictly bounded rectangles. Endpoints are
/// evaluated exactly only when the input equals the actual endpoint. No epsilon,
/// snapping, clamping, or retained PDFKit state. Internal for arithmetic tests.
struct PDFKitCropBoxTransform {
    private let geometry: PDFPageGeometry
    private let bounds: CGRect
    private let flipped: Bool

    init(geometry: PDFPageGeometry, displayBounds: CGRect, flipped: Bool) throws {
        guard [displayBounds.origin.x, displayBounds.origin.y,
               displayBounds.width, displayBounds.height, displayBounds.maxX, displayBounds.maxY]
                .allSatisfy(\.isFinite),
              displayBounds.size.width > 0, displayBounds.size.height > 0,
              displayBounds.maxX > displayBounds.minX, displayBounds.maxY > displayBounds.minY else {
            throw PDFGeometryError.malformedGeometry
        }
        self.geometry = geometry
        self.bounds = displayBounds
        self.flipped = flipped
    }

    private func validateDisplay(_ point: PDFPoint) throws {
        try point.validate()
        guard point.x >= Double(bounds.minX), point.x <= Double(bounds.maxX),
              point.y >= Double(bounds.minY), point.y <= Double(bounds.maxY) else {
            throw PDFGeometryError.outsidePage
        }
    }

    private func unit(_ value: Double, minimum: Double, maximum: Double, span: Double) -> Double {
        if value == minimum { return 0 }
        if value == maximum { return 1 }
        return (value - minimum) / span
    }

    private func coordinate(_ unit: Double, reversed: Bool,
                            minimum: Double, maximum: Double, span: Double) -> Double {
        if unit == 0 { return reversed ? maximum : minimum }
        if unit == 1 { return reversed ? minimum : maximum }
        // Evaluate a reversed axis from its upper endpoint, rather than forming
        // 1-unit and then subtracting the same large origin in the inverse.
        return reversed ? maximum.addingProduct(-unit, span) : minimum.addingProduct(unit, span)
    }

    func applying(_ point: PDFPoint) throws -> PDFPoint {
        try geometry.validate(point)
        let u = unit(point.x, minimum: geometry.cropOrigin.x,
                     maximum: geometry.cropOrigin.x + geometry.width, span: geometry.width)
        let v = unit(point.y, minimum: geometry.cropOrigin.y,
                     maximum: geometry.cropOrigin.y + geometry.height, span: geometry.height)
        let axes: (x: Double, reverseX: Bool, y: Double, reverseY: Bool)
        switch geometry.rotation {
        case 0: axes = (u, false, v, flipped)
        case 90: axes = (v, false, u, !flipped)
        case 180: axes = (u, true, v, !flipped)
        default: axes = (v, true, u, flipped)
        }
        let mapped = PDFPoint(
            x: coordinate(axes.x, reversed: axes.reverseX,
                          minimum: Double(bounds.minX), maximum: Double(bounds.maxX), span: Double(bounds.width)),
            y: coordinate(axes.y, reversed: axes.reverseY,
                          minimum: Double(bounds.minY), maximum: Double(bounds.maxY), span: Double(bounds.height)))
        try validateDisplay(mapped)
        return mapped
    }

    func inverse(_ point: PDFPoint) throws -> PDFPoint {
        // Reject nextUp/nextDown outside the actual converted rectangle BEFORE
        // normalization could lose the distinction through floating-point rounding.
        try validateDisplay(point)
        let x = unit(point.x, minimum: Double(bounds.minX), maximum: Double(bounds.maxX), span: Double(bounds.width))
        let y = unit(point.y, minimum: Double(bounds.minY), maximum: Double(bounds.maxY), span: Double(bounds.height))
        let axes: (x: Double, reverseX: Bool, y: Double, reverseY: Bool)
        switch geometry.rotation {
        case 0: axes = (x, false, y, flipped)
        case 90: axes = (y, !flipped, x, false)
        case 180: axes = (x, true, y, !flipped)
        default: axes = (y, flipped, x, true)
        }
        let canonical = PDFPoint(
            x: coordinate(axes.x, reversed: axes.reverseX, minimum: geometry.cropOrigin.x,
                          maximum: geometry.cropOrigin.x + geometry.width, span: geometry.width),
            y: coordinate(axes.y, reversed: axes.reverseY, minimum: geometry.cropOrigin.y,
                          maximum: geometry.cropOrigin.y + geometry.height, span: geometry.height))
        try geometry.validate(canonical)
        return canonical
    }

    /// Independent public forward correspondence, normalized to unrotated PDF
    /// points. Observation residuals are not input coordinates or membership grants.
    func validateCorrespondence(canonical: PDFPoint, publicDisplay: PDFPoint,
                                precision: PDFGeometryPrecision) throws {
        let expected = try applying(canonical)
        try publicDisplay.validate()
        let dx = abs(publicDisplay.x - expected.x) / Double(bounds.width)
        let dy = abs(publicDisplay.y - expected.y) / Double(bounds.height)
        let error: PDFPoint
        if geometry.rotation == 90 || geometry.rotation == 270 {
            error = PDFPoint(x: dy * geometry.width, y: dx * geometry.height)
        } else {
            error = PDFPoint(x: dx * geometry.width, y: dy * geometry.height)
        }
        try precision.validate(expected: PDFPoint(x: 0, y: 0), actual: error)
    }
}

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
        guard member === page else { throw PDFGeometryError.differentPage }
        let crop = page.bounds(for: .cropBox)
        let rotation = ((page.rotation % 360) + 360) % 360
        return try PDFPageGeometry(pageIndex: pageIndex,
                                   cropOrigin: PDFPoint(x: Double(crop.minX), y: Double(crop.minY)),
                                   width: Double(crop.width), height: Double(crop.height), rotation: rotation)
    }

    public static func displayPoint(_ point: PDFPoint, page: PDFPage, in view: PDFView,
                                    geometry: PDFPageGeometry,
                                    precision: PDFGeometryPrecision) throws -> PDFPoint {
        try validatePage(page, view: view, geometry: geometry)
        try geometry.validate(point)
        let transform = try capture(page: page, view: view, geometry: geometry)
        let mapped = try transform.applying(point)
        try validateLandmarks(transform, page: page, view: view, geometry: geometry, precision: precision)
        try validateConversions(point, mapped: mapped, transform: transform, page: page, view: view,
                                precision: precision)
        return mapped
    }

    public static func canonicalPoint(_ point: PDFPoint, page: PDFPage, in view: PDFView,
                                      geometry: PDFPageGeometry,
                                      precision: PDFGeometryPrecision) throws -> PDFPoint {
        try point.validate()
        try validatePage(page, view: view, geometry: geometry)
        let transform = try capture(page: page, view: view, geometry: geometry)
        let canonical = try transform.inverse(point)
        try geometry.validate(canonical)
        try validateLandmarks(transform, page: page, view: view, geometry: geometry, precision: precision)
        // Strict containment belongs to the actual input rectangle and returned
        // canonical geometry. Public inverse is an independent precision witness,
        // never returned geometry and never a source of boundary clamping.
        let direct = pdfPoint(view.convert(cgPoint(point), to: page))
        try precision.validate(expected: canonical, actual: direct)
        let mapped = try transform.applying(canonical)
        try validateConversions(canonical, mapped: mapped, transform: transform, page: page, view: view,
                                precision: precision)
        return canonical
    }

    /// Returns all source quads, preserving semantic range and TL/TR/BR/BL order.
    public static func displayQuads(anchor: PDFSentenceAnchor, expected: PDFSentenceIdentity,
                                    publishedMembership: Set<PDFSentenceIdentity>,
                                    page: PDFPage, in view: PDFView,
                                    precision: PDFGeometryPrecision) throws -> [[PDFPoint]] {
        try anchor.validateResolution(expected: expected, publishedMembership: publishedMembership)
        try validatePage(page, view: view, geometry: anchor.page)
        let transform = try capture(page: page, view: view, geometry: anchor.page)
        try validateLandmarks(transform, page: page, view: view, geometry: anchor.page, precision: precision)
        return try anchor.quads.map { quad in
            try quad.points.map { point in
                try anchor.page.validate(point)
                let mapped = try transform.applying(point)
                try validateConversions(point, mapped: mapped, transform: transform, page: page, view: view,
                                        precision: precision)
                return mapped
            }
        }
    }

    private static func validatePage(_ page: PDFPage, view: PDFView,
                                     geometry: PDFPageGeometry) throws {
        let actual = try pageGeometry(page: page, in: view, pageIndex: geometry.pageIndex)
        guard actual == geometry else { throw PDFGeometryError.malformedGeometry }
        guard view.scaleFactor.isFinite, view.scaleFactor > 0 else { throw PDFGeometryError.malformedGeometry }
    }

    private static func capture(page: PDFPage, view: PDFView,
                                geometry: PDFPageGeometry) throws -> PDFKitCropBoxTransform {
        let crop = CGRect(x: geometry.cropOrigin.x, y: geometry.cropOrigin.y,
                          width: geometry.width, height: geometry.height)
        // Public rectangle conversion defines the EXACT admitted view boundary.
        return try PDFKitCropBoxTransform(geometry: geometry,
                                          displayBounds: view.convert(crop, from: page), flipped: view.isFlipped)
    }

    private static func validateLandmarks(_ transform: PDFKitCropBoxTransform,
                                         page: PDFPage, view: PDFView, geometry: PDFPageGeometry,
                                         precision: PDFGeometryPrecision) throws {
        let origin = geometry.cropOrigin
        let right = PDFPoint(x: origin.x + geometry.width, y: origin.y)
        let top = PDFPoint(x: origin.x, y: origin.y + geometry.height)
        let opposite = PDFPoint(x: right.x, y: top.y)
        for landmark in [origin, right, top, opposite] {
            let mapped = try transform.applying(landmark)
            try validateConversions(landmark, mapped: mapped, transform: transform,
                                    page: page, view: view, precision: precision)
        }
    }

    private static func validateConversions(_ canonical: PDFPoint, mapped: PDFPoint,
                                           transform: PDFKitCropBoxTransform, page: PDFPage, view: PDFView,
                                           precision: PDFGeometryPrecision) throws {
        let direct = view.convert(cgPoint(canonical), from: page)
        try transform.validateCorrespondence(canonical: canonical, publicDisplay: pdfPoint(direct), precision: precision)
        try precision.validate(expected: canonical, actual: pdfPoint(view.convert(direct, to: page)))
        try precision.validate(expected: canonical, actual: pdfPoint(view.convert(cgPoint(mapped), to: page)))
    }

    private static func cgPoint(_ point: PDFPoint) -> CGPoint { CGPoint(x: point.x, y: point.y) }
    private static func pdfPoint(_ point: CGPoint) -> PDFPoint { PDFPoint(x: Double(point.x), y: Double(point.y)) }
}
