import AppKit
import Foundation
import PDFKit
import ProviderRequest
import XCTest

@testable import PDFReadiness

@MainActor
final class PDFReadinessTests: XCTestCase {
  func testBitmapGraphicsContextPreflightRejectsUnsupportedStraightAlphaAtBothBackings() {
    for backing in ReadinessBacking.allCases {
      autoreleasepool {
        let width = 300 * backing.rawValue
        let height = 240 * backing.rawValue
        let representation = NSBitmapImageRep(
          bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
          bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
          colorSpaceName: .deviceRGB, bitmapFormat: [.alphaNonpremultiplied],
          bytesPerRow: width * 4, bitsPerPixel: 32)
        XCTAssertTrue(representation != nil, "Bitmap representation unavailable")
        guard let bitmap = representation else { return }
        bitmap.size = CGSize(width: 300, height: 240)
        let assertRequestedRepresentation = {
          XCTAssertTrue(
            bitmap.pixelsWide == width && bitmap.pixelsHigh == height
              && bitmap.bytesPerRow == width * 4 && bitmap.bitsPerSample == 8
              && bitmap.samplesPerPixel == 4 && bitmap.bitsPerPixel == 32
              && bitmap.hasAlpha && !bitmap.isPlanar
              && bitmap.colorSpaceName == .deviceRGB
              && bitmap.bitmapFormat == [.alphaNonpremultiplied]
              && bitmap.size == CGSize(width: 300, height: 240)
              && bitmap.bitmapData != nil,
            "Requested bitmap representation metadata changed")
        }
        assertRequestedRepresentation()
        rejects(.unsupportedCapture) {
          try PDFKitReadinessProbe.requireBitmapGraphicsContext(for: bitmap)
        }
        assertRequestedRepresentation()
      }
    }
  }

  func testAllocateCaptureBitmapAcceptsProductionTupleAtBothBackings() throws {
    for backing in ReadinessBacking.allCases {
      try autoreleasepool {
        let bitmap = try PDFKitReadinessProbe.allocateCaptureBitmap(backing: backing)
        let width = 300 * backing.rawValue
        let height = 240 * backing.rawValue
        XCTAssertTrue(
          bitmap.pixelsWide == width && bitmap.pixelsHigh == height
            && bitmap.bytesPerRow == width * 4 && bitmap.bitsPerSample == 8
            && bitmap.samplesPerPixel == 4 && bitmap.bitsPerPixel == 32
            && bitmap.hasAlpha && !bitmap.isPlanar
            && bitmap.colorSpaceName == .deviceRGB && bitmap.bitmapFormat == []
            && bitmap.size == CGSize(width: 300, height: 240)
            && bitmap.bitmapData != nil,
          "Production bitmap representation metadata changed")
      }
    }
  }

  private struct Fixture {
    let id = UUID()
    let start = ContinuousClock().now
    let profile: ReadinessProfile
    init(source: ReadinessSource = .arxivAbstract, backing: ReadinessBacking = .one) {
      profile = ReadinessProfile(
        source: source, cpu: .arm64, os: .current27,
        cache: .cold, backing: backing)
    }
    func stamp(
      _ milliseconds: Int, generation: UInt64 = 1,
      profile replacement: ReadinessProfile? = nil, attempt: UUID? = nil
    ) -> ReadinessStamp {
      ReadinessStamp(
        attempt: attempt ?? id, generation: generation,
        profile: replacement ?? profile, instant: start.advanced(by: .milliseconds(milliseconds)))
    }
    func state() -> ReadinessAttempt {
      ReadinessAttempt(
        attempt: id, generation: 1, profile: profile,
        deadline: start.advanced(by: .seconds(120)))
    }
    func resolution() throws -> ReadinessResolution {
      try ReadinessResolution(
        owner: .measurement, cause: .completionUnproven,
        affectedCells: [profile], action: .establishWitness, retest: .fullVisibleMatrix)
    }
  }
  private func rejects(
    _ expected: ReadinessFailure, _ action: () throws -> Void,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertThrowsError(try action(), file: file, line: line) { error in
      XCTAssertTrue(
        (error as? ReadinessFailure) == expected,
        "Typed failure mismatch", file: file, line: line)
    }
  }
  private func prepared(_ f: Fixture) throws -> ReadinessAttempt {
    var state = f.state()
    try state.queueAutomaticOpen(f.stamp(0))
    try state.acceptImport(f.stamp(1))
    try state.present(f.stamp(2))
    return state
  }
  private func sample(_ profile: ReadinessProfile, _ duration: Duration) -> ReadinessTimingSample {
    ReadinessTimingSample(attempt: UUID(), profile: profile, duration: duration)
  }

  func testFixedProfileAndFourClassificationOnlyFixtures() throws {
    let authority = try ProviderRequest()
    for source in ReadinessSource.allCases {
      try ReadinessSourceFixtures.classify(source, authority: authority)
      for backing in ReadinessBacking.allCases {
        let profile = Fixture(source: source, backing: backing).profile
        XCTAssertEqual(profile.probeVersion, .zoomV1)
        XCTAssertEqual(profile.codeVersion, .precursorV1)
        XCTAssertTrue(profile.source == source && profile.backing == backing)
      }
    }
    XCTAssertEqual(ReadinessSource.allCases.count, 4)
    XCTAssertThrowsError(try authority.validateImportURL("http://example.org/file.pdf"))
    XCTAssertThrowsError(try authority.validateImportURL("https://user@example.org/file.pdf"))
    XCTAssertThrowsError(
      try authority.resolveArxivAbstractURL("https://example.org/abs/2401.00001"))
    let budget = try RequestResourceBudget(authority: authority, kind: "import")
    XCTAssertThrowsError(try budget.add("bodyBytes", delta: authority.limit("pdfBytes") + 1))
  }

  func testRasterAndVisibleCompletionRemainSeparate() throws {
    let f = Fixture()
    var state = try prepared(f)
    // Module-internal fixture tests event plumbing, not an authenticated renderer/witness.
    try state.recordRaster(RasterObservation(stamp: f.stamp(10)))
    XCTAssertTrue(state.rasterVerifiedAt != nil)
    XCTAssertNil(state.firstInteractivePageAt)
    XCTAssertTrue(state.rasterDuration == .milliseconds(9))
    XCTAssertTrue(state.timingSample?.duration == .milliseconds(9))
    XCTAssertEqual(state.outcome, .rasterVerified)
    try state.finish(f.stamp(11))
    XCTAssertTrue(state.failure == .missingCompletion)
    rejects(.invalidMeasurement) { _ = try state.projection() }
    let projection = try state.projection(resolution: f.resolution())
    XCTAssertEqual(projection.outcome, .rasterVerified)
    XCTAssertEqual(projection.completion, .missingCompletion)
    XCTAssertEqual(projection.geometryBand, .withinTolerance)
    XCTAssertEqual(projection.disposition, .severe)
    XCTAssertTrue(projection.storyBlocked && projection.p6Blocked && projection.downstreamBlocked)
  }

  func testEventAssertionsCannotAuthenticateVisibleWitness() throws {
    let f = Fixture()
    var state = try prepared(f)
    try state.recordRaster(RasterObservation(stamp: f.stamp(3)))
    rejects(.wrongUpdate) { try state.assertQualifiedVisibleUpdate(f.stamp(4)) }
    XCTAssertNil(state.firstInteractivePageAt)
    XCTAssertNil(state.rasterDuration)
    XCTAssertTrue(state.outcome == .wrongUpdate)
  }

  func testMissingAndManualOpenAreNotComparable() throws {
    let f = Fixture()
    var noQueue = f.state()
    rejects(.noncomparable) { try noQueue.acceptImport(f.stamp(0)) }
    var manual = try prepared(f)
    rejects(.noncomparable) { try manual.present(f.stamp(3), automatic: false) }
    XCTAssertNil(manual.rasterDuration)
    var missing = try prepared(f)
    try missing.finish(f.stamp(3))
    let projection = try missing.projection(resolution: f.resolution())
    XCTAssertEqual(projection.outcome, .missingCompletion)
    XCTAssertEqual(projection.durationBand, .notObserved)
    XCTAssertEqual(projection.geometryBand, .notObserved)
    var beforeAcceptance = f.state()
    rejects(.invalidMeasurement) { try beforeAcceptance.present(f.stamp(0)) }
    var beforePresentation = f.state()
    try beforePresentation.queueAutomaticOpen(f.stamp(0))
    try beforePresentation.acceptImport(f.stamp(1))
    rejects(.invalidMeasurement) {
      try beforePresentation.recordRaster(RasterObservation(stamp: f.stamp(2)))
    }
  }

  func testReversedDuplicateAndCrossAttemptEventsHaveNoDuration() throws {
    let f = Fixture()
    var reversed = try prepared(f)
    rejects(.invalidMeasurement) {
      try reversed.recordRaster(RasterObservation(stamp: f.stamp(1)))
    }
    XCTAssertNil(reversed.rasterDuration)
    var duplicate = try prepared(f)
    rejects(.invalidMeasurement) { try duplicate.acceptImport(f.stamp(3)) }
    var duplicateQueue = f.state()
    try duplicateQueue.queueAutomaticOpen(f.stamp(0))
    rejects(.invalidMeasurement) { try duplicateQueue.queueAutomaticOpen(f.stamp(1)) }
    var duplicateRaster = try prepared(f)
    try duplicateRaster.recordRaster(RasterObservation(stamp: f.stamp(3)))
    rejects(.invalidMeasurement) {
      try duplicateRaster.recordRaster(RasterObservation(stamp: f.stamp(4)))
    }
    XCTAssertNil(duplicateRaster.rasterDuration)
    var otherAttempt = try prepared(f)
    rejects(.staleGeneration) {
      try otherAttempt.recordRaster(RasterObservation(stamp: f.stamp(3, attempt: UUID())))
    }
    var stale = try prepared(f)
    rejects(.staleGeneration) {
      try stale.recordRaster(RasterObservation(stamp: f.stamp(3, generation: 2)))
    }
    XCTAssertNil(stale.rasterDuration)
  }

  func testEveryChangedProfileStartsAnotherComparisonSet() throws {
    let f = Fixture()
    let alternatives = [
      ReadinessProfile(source: .arxivPDF, cpu: .arm64, os: .current27, cache: .cold, backing: .one),
      ReadinessProfile(
        source: .arxivAbstract, cpu: .intel, os: .current27, cache: .cold, backing: .one),
      ReadinessProfile(
        source: .arxivAbstract, cpu: .arm64, os: .minimum15, cache: .cold, backing: .one),
      ReadinessProfile(
        source: .arxivAbstract, cpu: .arm64, os: .current27, cache: .warm, backing: .one),
      ReadinessProfile(
        source: .arxivAbstract, cpu: .arm64, os: .current27, cache: .cold, backing: .two),
    ]
    for profile in alternatives {
      var state = try prepared(f)
      rejects(.changedProbe) {
        try state.recordRaster(RasterObservation(stamp: f.stamp(3, profile: profile)))
      }
      XCTAssertNil(state.rasterDuration)
      rejects(.invalidMeasurement) {
        _ = try ReadinessAssessment.disposition(
          profile: f.profile, samples: [sample(profile, .seconds(1))])
      }
    }
  }

  func testCancellationDeadlineAndRendererFailuresAreTerminal() throws {
    let f = Fixture()
    var cancelled = try prepared(f)
    rejects(.cancelled) { try cancelled.cancel(f.stamp(3)) }
    rejects(.cancelled) {
      try cancelled.recordRaster(RasterObservation(stamp: f.stamp(4)))
    }
    XCTAssertNil(cancelled.rasterDuration)
    for ms in [120_000, 120_001] {
      var expired = try prepared(f)
      rejects(.deadline) { try expired.recordRaster(RasterObservation(stamp: f.stamp(ms))) }
      XCTAssertNil(expired.rasterDuration)
    }
    for failure in [
      ReadinessFailure.resourceLimit, .blankCapture, .unsupportedCapture, .wrongUpdate,
    ] {
      var failed = try prepared(f)
      rejects(failure) { try failed.failProbe(f.stamp(3), reason: failure) }
      XCTAssertNil(failed.rasterDuration)
      let projection = try failed.projection(resolution: f.resolution())
      XCTAssertTrue(projection.disposition == .severe)
      XCTAssertTrue(
        projection.geometryBand == (failure == .wrongUpdate ? .outsideTolerance : .notObserved))
    }
    var finished = try prepared(f)
    try finished.finish(f.stamp(3))
    rejects(.missingCompletion) {
      try finished.recordRaster(RasterObservation(stamp: f.stamp(4)))
    }
  }

  func testSoftTargetBoundariesAndDispositionDoNotBecomeReleaseGates() throws {
    for source in [ReadinessSource.arxivAbstract, .arxivPDF] {
      let f = Fixture(source: source)
      XCTAssertEqual(
        ReadinessAssessment.durationBand(.milliseconds(30_000), source: source), .withinSoftTarget)
      XCTAssertEqual(
        ReadinessAssessment.durationBand(.milliseconds(30_001), source: source), .overSoftTarget)
      XCTAssertEqual(ReadinessAssessment.durationBand(nil, source: source), .notObserved)
      XCTAssertEqual(
        ReadinessAssessment.durationBand(.milliseconds(-1), source: source), .notObserved)
      let one = try ReadinessAssessment.disposition(
        profile: f.profile,
        samples: [sample(f.profile, .milliseconds(30_001))])
      XCTAssertEqual(one, .review)
      XCTAssertFalse(one.isHardReleaseFailure)
      XCTAssertFalse(one.requiresResolution)
      let repeated = try ReadinessAssessment.disposition(
        profile: f.profile,
        samples: [
          sample(f.profile, .milliseconds(30_001)), sample(f.profile, .milliseconds(30_002)),
        ])
      XCTAssertEqual(repeated, .repeated)
      XCTAssertTrue(repeated.requiresResolution)
      XCTAssertFalse(repeated.isHardReleaseFailure)
      XCTAssertEqual(
        try ReadinessAssessment.disposition(
          profile: f.profile,
          samples: [sample(f.profile, .milliseconds(30_000))]), .withinTarget)
      XCTAssertEqual(
        try ReadinessAssessment.disposition(
          profile: f.profile,
          samples: [], severe: true), .severe)
      XCTAssertEqual(try ReadinessAssessment.disposition(profile: f.profile, samples: []), .severe)
      rejects(.invalidMeasurement) {
        _ = try ReadinessAssessment.disposition(
          profile: f.profile, samples: [sample(f.profile, .seconds(-1))])
      }
      let duplicate = sample(f.profile, .milliseconds(30_001))
      rejects(.invalidMeasurement) {
        _ = try ReadinessAssessment.disposition(
          profile: f.profile, samples: [duplicate, duplicate])
      }
      // 30s is not the observation deadline.
      var state = try prepared(f)
      try state.recordRaster(RasterObservation(stamp: f.stamp(30_002)))
      XCTAssertTrue(state.rasterVerifiedAt != nil)
      XCTAssertNil(state.firstInteractivePageAt)
    }
    for source in [ReadinessSource.httpsPDF, .localPDF] {
      let f = Fixture(source: source)
      XCTAssertEqual(ReadinessAssessment.durationBand(.seconds(100), source: source), .notObserved)
      XCTAssertEqual(
        try ReadinessAssessment.disposition(
          profile: f.profile,
          samples: [sample(f.profile, .seconds(100))]), .baseline)
    }
  }

  func testResolutionAndClosedProjectionCannotWaiveMissingEvidence() throws {
    let f = Fixture()
    rejects(.invalidMeasurement) {
      _ = try ReadinessResolution(
        owner: .measurement, cause: .completionUnproven,
        affectedCells: [], action: .establishWitness, retest: .fullVisibleMatrix)
    }
    rejects(.invalidMeasurement) {
      _ = try ReadinessResolution(
        owner: .measurement, cause: .completionUnproven,
        affectedCells: [f.profile], action: .establishWitness, retest: .fullVisibleMatrix,
        measuredRisk: .measuredLatencyOnly)
    }
    let risk = try ReadinessResolution(
      owner: .importPipeline, cause: .latency,
      affectedCells: [f.profile], action: .investigateLatency, retest: .sameCells,
      measuredRisk: .measuredLatencyOnly)
    let state = try prepared(f)
    rejects(.invalidMeasurement) { _ = try state.projection(resolution: risk) }
    let other = try Fixture(source: .localPDF).resolution()
    rejects(.invalidMeasurement) { _ = try state.projection(resolution: other) }
    let safe = try state.projection(resolution: f.resolution())
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(safe)) as? [String: Any])
    XCTAssertTrue(
      Set(object.keys) == [
        "profile", "outcome", "completion", "durationBand", "geometryBand",
        "disposition", "resolution", "storyBlocked", "p6Blocked", "downstreamBlocked",
      ])
    let profile = try XCTUnwrap(object["profile"] as? [String: Any])
    XCTAssertTrue(
      Set(profile.keys) == [
        "source", "cpu", "os", "cache", "backing", "toolchain",
        "probeVersion", "codeVersion", "semantics",
      ])
    let json = String(decoding: try JSONEncoder().encode(safe), as: UTF8.self)
    for forbidden in [
      "https:", "%PDF", "instant", "durationMs", "attempt", "generation", "pixels", "path", "hash",
    ] {
      XCTAssertFalse(json.contains(forbidden), "Projection leaked a forbidden category")
    }
  }

  private func image(scale: Double, backing: ReadinessBacking) -> (
    pixels: [UInt8], centers: [(Double, Double)]
  ) {
    let b = backing.rawValue
    let width = 300 * b
    let height = 240 * b
    var pixels = Array(repeating: UInt8(255), count: width * height * 4)
    var centers: [(Double, Double)] = []
    for (color, x) in [80.0, 150.0, 220.0].enumerated() {
      let left = Int((x * scale * Double(b)).rounded())
      let top = Int((100 * scale * Double(b)).rounded())
      let size = Int((8 * scale * Double(b)).rounded())
      for y in top..<(top + size) {
        for px in left..<(left + size) {
          let i = (y * width + px) * 4
          pixels[i] = 0
          pixels[i + 1] = 0
          pixels[i + 2] = 0
          pixels[i + color] = 255
        }
      }
      centers.append(((x + 4) * scale * Double(b) - 0.5, 104 * scale * Double(b) - 0.5))
    }
    return (pixels, centers)
  }
  private func scan(
    _ image: (pixels: [UInt8], centers: [(Double, Double)]), scale: Double,
    backing: ReadinessBacking
  ) throws -> [PixelFiducial] {
    try ReadinessPixels.scan(
      rgba: image.pixels, width: 300 * backing.rawValue,
      height: 240 * backing.rawValue, backing: backing, scale: scale, expectedCenters: image.centers
    )
  }

  func testIndependentPixelOracleAtBothBackingScalesAndZoom() throws {
    for backing in ReadinessBacking.allCases {
      let before = try scan(image(scale: 1, backing: backing), scale: 1, backing: backing)
      let after = try scan(image(scale: 1.25, backing: backing), scale: 1.25, backing: backing)
      try ReadinessPixels.verifyZoom(baseline: before, zoomed: after)
      rejects(.wrongUpdate) { try ReadinessPixels.verifyZoom(baseline: before, zoomed: before) }
      rejects(.wrongUpdate) {
        _ = try scan(image(scale: 1, backing: backing), scale: 1.25, backing: backing)
      }
    }
  }

  func testCanonicalScannerAlphaBoundariesAndMalformedBuffers() throws {
    for alpha in UInt8(250)...UInt8(254) {
      let rgba: [UInt8] = [220, 35, 35, 255, 220, 35, 35, alpha]
      let original = rgba
      rejects(.unsupportedCapture) {
        try PDFKitReadinessProbe.requireCanonicalScannerAlpha(rgba)
      }
      XCTAssertEqual(rgba, original)
    }
    for alpha in [UInt8(0), 249, 255] {
      let rgba: [UInt8] = [220, 35, 35, alpha]
      let original = rgba
      try PDFKitReadinessProbe.requireCanonicalScannerAlpha(rgba)
      XCTAssertEqual(rgba, original)
    }
    let malformed: [[UInt8]] = [
      [], [220, 35, 35], [220, 35, 35, 255, 0],
      Array(repeating: UInt8(255), count: ReadinessPixels.maximumBytes + 4),
    ]
    for rgba in malformed {
      rejects(.unsupportedCapture) {
        try PDFKitReadinessProbe.requireCanonicalScannerAlpha(rgba)
      }
    }
  }

  func testCanonicalScannerAlphaPreservesOpaqueGeometryAndIgnoredBlankCapture() throws {
    for backing in ReadinessBacking.allCases {
      let baseline = image(scale: 1, backing: backing)
      let zoomed = image(scale: 1.25, backing: backing)
      let originalBaseline = baseline.pixels
      let originalZoomed = zoomed.pixels
      try PDFKitReadinessProbe.requireCanonicalScannerAlpha(baseline.pixels)
      try PDFKitReadinessProbe.requireCanonicalScannerAlpha(zoomed.pixels)
      XCTAssertEqual(baseline.pixels, originalBaseline)
      XCTAssertEqual(zoomed.pixels, originalZoomed)
      let before = try scan(baseline, scale: 1, backing: backing)
      let after = try scan(zoomed, scale: 1.25, backing: backing)
      try ReadinessPixels.verifyZoom(baseline: before, zoomed: after)
      rejects(.wrongUpdate) { try ReadinessPixels.verifyZoom(baseline: before, zoomed: before) }
      for alpha in [UInt8(0), 249] {
        var ignored = baseline
        for index in stride(from: 3, to: ignored.pixels.count, by: 4) {
          ignored.pixels[index] = alpha
        }
        let original = ignored.pixels
        try PDFKitReadinessProbe.requireCanonicalScannerAlpha(ignored.pixels)
        XCTAssertEqual(ignored.pixels, original)
        rejects(.blankCapture) { _ = try scan(ignored, scale: 1, backing: backing) }
      }
    }
  }

  func testBlankWrongSizeColorPositionAndSparsePixelsFail() throws {
    let good = image(scale: 1, backing: .one)
    var blank = good
    blank.pixels = Array(repeating: 255, count: good.pixels.count)
    rejects(.blankCapture) { _ = try scan(blank, scale: 1, backing: .one) }
    rejects(.unsupportedCapture) {
      _ = try ReadinessPixels.scan(
        rgba: good.pixels, width: 301, height: 240,
        backing: .one, scale: 1, expectedCenters: good.centers)
    }
    rejects(.unsupportedCapture) {
      _ = try ReadinessPixels.scan(
        rgba: [], width: 300, height: 240,
        backing: .one, scale: 1, expectedCenters: good.centers)
    }
    rejects(.unsupportedCapture) { _ = try scan(good, scale: .nan, backing: .one) }
    var wrongPosition = good
    wrongPosition.centers[0].0 += 3
    rejects(.wrongUpdate) { _ = try scan(wrongPosition, scale: 1, backing: .one) }
    var boundary = good
    boundary.centers[0].0 += 2
    _ = try scan(boundary, scale: 1, backing: .one)
    var swapped = good
    for i in stride(from: 0, to: swapped.pixels.count, by: 4) {
      swapped.pixels.swapAt(i, i + 2)
    }
    rejects(.wrongUpdate) { _ = try scan(swapped, scale: 1, backing: .one) }
    var transparent = good
    for i in stride(from: 3, to: transparent.pixels.count, by: 4) { transparent.pixels[i] = 0 }
    rejects(.blankCapture) { _ = try scan(transparent, scale: 1, backing: .one) }
    var sparse = good
    for y in 100..<108 {
      for x in 80..<88 where !(x == 80 || x == 87) || !(y == 100 || y == 107) {
        let i = (y * 300 + x) * 4
        sparse.pixels[i] = 255
        sparse.pixels[i + 1] = 255
        sparse.pixels[i + 2] = 255
      }
    }
    rejects(.wrongUpdate) { _ = try scan(sparse, scale: 1, backing: .one) }
    var displaced = good
    for y in 100..<108 {
      for x in 150..<158 {
        let i = (y * 300 + x) * 4
        displaced.pixels[i] = 255
        displaced.pixels[i + 1] = 255
        displaced.pixels[i + 2] = 255
      }
      for x in 153..<161 {
        let i = (y * 300 + x) * 4
        displaced.pixels[i] = 0
        displaced.pixels[i + 1] = 255
        displaced.pixels[i + 2] = 0
      }
    }
    displaced.centers[1].0 += 3
    // Even a matching conversion expectation cannot waive measured pair distances.
    rejects(.wrongUpdate) { _ = try scan(displaced, scale: 1, backing: .one) }
    rejects(.wrongUpdate) { try ReadinessPixels.verifyZoom(baseline: [], zoomed: []) }
  }

  func testUnknownProfileVersionsAndBackingAreNotComparable() throws {
    let f = Fixture()
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(f.profile)) as? [String: Any])
    for (key, value) in [
      ("probeVersion", "zoom-v2"), ("codeVersion", "other"), ("semantics", "visible"),
    ] {
      var changed = object
      changed[key] = value
      XCTAssertThrowsError(
        try JSONDecoder().decode(
          ReadinessProfile.self,
          from: JSONSerialization.data(withJSONObject: changed)))
    }
    object["backing"] = 3
    XCTAssertThrowsError(
      try JSONDecoder().decode(
        ReadinessProfile.self,
        from: JSONSerialization.data(withJSONObject: object)))
  }

  /// This test MUST fail when public offscreen PDFKit cannot render. Failure is not a PASS substitute.
  func testRealGeneratedPDFKitZoomCacheDisplayPixels() async throws {
    let authority = try ProviderRequest()
    let f = Fixture(source: .localPDF)
    var state = try prepared(f)
    let pdf = try PDFKitReadinessProbe.generatedPDF()
    XCTAssertTrue(!pdf.isEmpty && pdf.count <= PDFKitReadinessProbe.maximumPDFBytes)
    let document = try XCTUnwrap(PDFDocument(data: pdf))
    XCTAssertTrue(document.pageCount == 1 && !document.isEncrypted)
    let page = try XCTUnwrap(document.page(at: 0))
    XCTAssertTrue(page.rotation == 0)
    XCTAssertTrue(
      page.bounds(for: .cropBox).width == 320 && page.bounds(for: .cropBox).height == 240)
    XCTAssertTrue((page.string ?? "").contains("synthetic readiness"))
    let result = try await PDFKitReadinessProbe.run(
      attempt: f.id, generation: 1,
      profile: f.profile, deadline: f.start.advanced(by: .seconds(5)),
      currentGeneration: { 1 }, authority: authority)
    XCTAssertEqual(result.geometry, .withinTolerance)
    try state.recordRaster(result)
    XCTAssertTrue(state.rasterVerifiedAt != nil)
    XCTAssertNil(state.firstInteractivePageAt)
    let safe = try state.projection(resolution: f.resolution())
    XCTAssertTrue(safe.storyBlocked && safe.p6Blocked && safe.downstreamBlocked)
    XCTAssertEqual(safe.completion, .missingCompletion)
  }

  func testRealProbeRejectsExpiredAndStaleBeforeRendering() async throws {
    let f = Fixture(source: .localPDF)
    let authority = try ProviderRequest()
    do {
      _ = try await PDFKitReadinessProbe.run(
        attempt: f.id, generation: 1, profile: f.profile,
        deadline: f.start, currentGeneration: { 1 }, authority: authority)
      XCTFail("Expired probe accepted")
    } catch { XCTAssertTrue((error as? ReadinessFailure) == .deadline) }
    do {
      _ = try await PDFKitReadinessProbe.run(
        attempt: f.id, generation: 1, profile: f.profile,
        deadline: f.start.advanced(by: .seconds(5)), currentGeneration: { 2 }, authority: authority)
      XCTFail("Stale probe accepted")
    } catch { XCTAssertTrue((error as? ReadinessFailure) == .staleGeneration) }
    let task = Task { @MainActor in
      try await PDFKitReadinessProbe.run(
        attempt: f.id, generation: 1, profile: f.profile,
        deadline: f.start.advanced(by: .seconds(5)), currentGeneration: { 1 }, authority: authority)
    }
    task.cancel()
    do {
      _ = try await task.value
      XCTFail("Cancelled probe accepted")
    } catch { XCTAssertTrue((error as? ReadinessFailure) == .cancelled) }
  }
}
