import AppKit
import CoreGraphics
import CoreText
import Foundation
import PDFKit
import ProviderRequest

private final class BoundedPDFBuffer {
  var bytes = Data()
  var exceeded = false
}

/// Offscreen PDFKit rendering only. No window, compositor or interaction witness is created.
@MainActor
public enum PDFKitReadinessProbe {
  nonisolated public static let maximumPDFBytes = 65_536
  private static let observationLimit = 16

  public static func generatedPDF() throws -> Data {
    let buffer = BoundedPDFBuffer()
    var callbacks = CGDataConsumerCallbacks(
      putBytes: { info, bytes, count in
        guard let info else { return 0 }
        let buffer = Unmanaged<BoundedPDFBuffer>.fromOpaque(info).takeUnretainedValue()
        guard count <= PDFKitReadinessProbe.maximumPDFBytes - buffer.bytes.count else {
          buffer.exceeded = true
          return 0
        }
        buffer.bytes.append(bytes.assumingMemoryBound(to: UInt8.self), count: count)
        return count
      }, releaseConsumer: nil)
    guard
      let consumer = CGDataConsumer(
        info: Unmanaged.passUnretained(buffer).toOpaque(),
        cbks: &callbacks)
    else { throw ReadinessFailure.invalidPDF }
    var box = CGRect(x: 0, y: 0, width: 320, height: 240)
    guard let context = CGContext(consumer: consumer, mediaBox: &box, nil) else {
      throw ReadinessFailure.invalidPDF
    }
    let crop = NSData(bytes: &box, length: MemoryLayout<CGRect>.size)
    context.beginPDFPage([kCGPDFContextCropBox as String: crop] as CFDictionary)
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(box)
    context.setFillColorSpace(CGColorSpaceCreateDeviceRGB())
    let colors: [[CGFloat]] = [[1, 0, 0, 1], [0, 1, 0, 1], [0, 0, 1, 1]]
    for (index, x) in [80, 150, 220].enumerated() {
      context.setFillColor(colors[index])
      context.fill(CGRect(x: CGFloat(x), y: 100, width: 8, height: 8))
    }
    let text = NSAttributedString(
      string: "PaperLens synthetic readiness zoom-v1",
      attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(
          "Helvetica" as CFString, 12, nil),
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(
          gray: 0, alpha: 1),
      ])
    context.textMatrix = .identity
    context.textPosition = CGPoint(x: 24, y: 200)
    CTLineDraw(CTLineCreateWithAttributedString(text as CFAttributedString), context)
    context.endPDFPage()
    context.closePDF()
    guard !buffer.exceeded, !buffer.bytes.isEmpty, buffer.bytes.count <= maximumPDFBytes else {
      throw ReadinessFailure.resourceLimit
    }
    return buffer.bytes
  }

  /// A task cancellation, generation change or expired deadline can never return success.
  /// The predicate is read on the main actor before and after each synchronous capture.
  public static func run(
    attempt: UUID, generation: UInt64, profile: ReadinessProfile,
    deadline: ContinuousClock.Instant, currentGeneration: @MainActor () -> UInt64,
    authority: ProviderRequest
  ) async throws -> RasterObservation {
    let clock = ContinuousClock()
    @MainActor func check() throws {
      guard !Task.isCancelled else { throw ReadinessFailure.cancelled }
      guard currentGeneration() == generation else { throw ReadinessFailure.staleGeneration }
      guard clock.now < deadline else { throw ReadinessFailure.deadline }
    }
    try check()
    // Initialize AppKit for a command-line test host without launching or creating a window.
    _ = NSApplication.shared
    try ReadinessSourceFixtures.classify(profile.source, authority: authority)
    let data = try generatedPDF()
    let budget = try RequestResourceBudget(authority: authority, kind: "import")
    try budget.add("bodyBytes", delta: data.count)
    try budget.observe("readBufferBytes", value: data.count)
    guard let document = PDFDocument(data: data), !document.isEncrypted,
      document.pageCount == 1, let page = document.page(at: 0), page.rotation == 0,
      page.bounds(for: .cropBox) == CGRect(x: 0, y: 0, width: 320, height: 240),
      !(page.string ?? "").isEmpty
    else { throw ReadinessFailure.invalidPDF }
    let view = PDFView(frame: CGRect(x: 0, y: 0, width: 300, height: 240))
    view.displayMode = .singlePage
    view.displayBox = .cropBox
    view.displaysPageBreaks = false
    view.autoScales = false
    view.backgroundColor = .white
    view.document = document
    view.go(to: page)
    // PDFKit's inner page layout is separate from NSView's constraint layout.
    view.layoutDocumentView()
    view.layoutSubtreeIfNeeded()
    let fit = view.scaleFactorForSizeToFit
    guard fit.isFinite, fit > 0 else { throw ReadinessFailure.unsupportedCapture }
    view.scaleFactor = fit
    view.layoutDocumentView()
    let baseline = try await observe(
      view: view, page: page, scale: fit,
      backing: profile.backing, check: check)
    try check()
    view.scaleFactor = fit * 1.25
    view.layoutDocumentView()
    let zoomed = try await observe(
      view: view, page: page, scale: fit * 1.25,
      backing: profile.backing, check: check)
    try ReadinessPixels.verifyZoom(baseline: baseline, zoomed: zoomed)
    try check()
    return RasterObservation(
      stamp: ReadinessStamp(
        attempt: attempt, generation: generation,
        profile: profile, instant: clock.now))
  }

  private static func observe(
    view: PDFView, page: PDFPage, scale: Double,
    backing: ReadinessBacking, check: @MainActor () throws -> Void
  ) async throws -> [PixelFiducial] {
    var lastFailure: ReadinessFailure = .unsupportedCapture
    for index in 0..<observationLimit {
      try check()
      view.layoutSubtreeIfNeeded()
      // documentView is PDFKit's public displayed-pages view. Do not traverse private
      // page/tile subviews, capture this view separately, or replace PDFView rendering.
      guard let documentView = view.documentView else {
        throw ReadinessFailure.unsupportedCapture
      }
      documentView.layoutSubtreeIfNeeded()
      documentView.needsDisplay = true
      documentView.displayIfNeeded()
      view.needsDisplay = true
      view.displayIfNeeded()
      do {
        let result = try capture(view: view, page: page, scale: scale, backing: backing)
        try check()
        return result
      } catch let failure as ReadinessFailure {
        switch failure {
        case .blankCapture, .wrongUpdate: lastFailure = failure
        default: throw failure
        }
      }
      if index + 1 < observationLimit {
        do { try await Task.sleep(for: .milliseconds(10)) } catch {
          throw ReadinessFailure.cancelled
        }
      }
    }
    try check()
    throw lastFailure
  }

  private static func capture(
    view: PDFView, page: PDFPage, scale: Double,
    backing: ReadinessBacking
  ) throws -> [PixelFiducial] {
    let b = backing.rawValue
    let width = 300 * b
    let height = 240 * b
    let bytes = width * height * 4
    guard bytes <= ReadinessPixels.maximumBytes,
      view.bounds.size == CGSize(width: 300, height: 240),
      let natural = view.bitmapImageRepForCachingDisplay(in: view.bounds),
      natural.bytesPerRow > 0, natural.pixelsHigh > 0,
      natural.bytesPerRow <= (ReadinessPixels.maximumBytes - 2 * bytes) / natural.pixelsHigh,
      let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width,
        pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB,
        bitmapFormat: [.alphaNonpremultiplied], bytesPerRow: width * 4, bitsPerPixel: 32),
      let pixels = bitmap.bitmapData
    else { throw ReadinessFailure.unsupportedCapture }
    // Explicit public backing-specific cache target, not an alternate renderer/fallback.
    bitmap.size = view.bounds.size
    pixels.initialize(repeating: 0, count: bytes)
    view.cacheDisplay(in: view.bounds, to: bitmap)
    guard bitmap.pixelsWide == width, bitmap.pixelsHigh == height,
      bitmap.bitsPerSample == 8, bitmap.samplesPerPixel == 4,
      bitmap.bytesPerRow == width * 4, bitmap.bitsPerPixel == 32, !bitmap.isPlanar
    else { throw ReadinessFailure.unsupportedCapture }
    var centers: [(Double, Double)] = []
    for x in [84.0, 154.0, 224.0] {
      let point = view.convert(CGPoint(x: x, y: 104), from: page)
      let pixelX = (point.x - view.bounds.minX) * Double(b) - 0.5
      let pointY = view.isFlipped ? point.y - view.bounds.minY : view.bounds.maxY - point.y
      centers.append((pixelX, pointY * Double(b) - 0.5))
    }
    // Only the bytes written by PDFView.cacheDisplay are scanned as evidence.
    return try ReadinessPixels.scan(
      rgba: Array(UnsafeBufferPointer(start: pixels, count: bytes)),
      width: width, height: height, backing: backing, scale: scale, expectedCenters: centers)
  }
}
