import AppKit
import CryptoKit
import Darwin
import Foundation
import PDFKit
#if SWIFT_PACKAGE
import ProviderRequest
#endif

/// Diagnostic-only profile. Never supplied to ProductAppComposition or production parsing.
enum SyntheticPDFGeometryCalibration {
  static let flag = "--synthetic-geometry-calibration"
  static let scales: [Double] = [0.1, 1, 10]
  static let coordinateLimit = 100_000.0

  // Pinned PDFium fpdf_text.cpp widens CFX_FloatRect members to Double; the
  // preceding cpdf_textpage.cpp glyph scale/translation/TransformRect uses Float.
  // Our Type3 path (cpdf_type3char.cpp) has two integer bbox roundings. Charge
  // a full final glyph unit for EACH, conservatively including the earlier
  // text-unit rounding: 2 * 20/1000 PDF points. All source operands are <= 1024,
  // except the initial *1000 glyph-unit conversion (<=900000, exact for these
  // integers). 128 binary32 operations conservatively cover font-matrix bbox,
  // text advance, font size division, four-corner transform and min/max; the
  // post-conversion absolute-term envelope is 1024. No residual sets this bound.
  static let extractionBound: Double = {
    let u = Double(Float.ulpOfOne) / 2
    return (2 * 20.0 / 1000 + (128 * u / (1 - 128 * u)) * 1024).nextUp
  }()
  // Conditional, independently tested PDFKit numerical model, NOT a claim about
  // undocumented internals: <=128 binary64 affine operations, terms bounded by
  // 100000 view points, normalized by minimum admitted zoom 0.1. Every sampled
  // view coordinate is checked against that envelope. A violation FAILS the
  // diagnostic; it never widens the model or grants a production profile.
  static let roundtripBound: Double = {
    let u = Double.ulpOfOne / 2
    return ((128 * u / (1 - 128 * u)) * 16 * coordinateLimit / 0.1).nextUp
  }()
  static let correspondenceBound = (extractionBound + roundtripBound).nextUp

  struct Page: Sendable {
    let index: Int
    let profile: Int
    let rotation: Int
    var x: Double { profile == 0 ? 0 : 17.25 }
    var y: Double { profile == 0 ? 0 : -23.5 }
    var corners: [PDFPoint] {
      [.init(x: x, y: y), .init(x: x + 200, y: y),
       .init(x: x, y: y + 300), .init(x: x + 200, y: y + 300),
       .init(x: x + 37.5, y: y + 112.25)]
    }
    // Independent PDF-program oracle: font size20, FontMatrix1/1000,
    // A bbox[0,0,600,700], advance600; B bbox[0,0,500,900].
    var glyphVertices: [[PDFPoint]] {
      [vertices(left: x + 40, right: x + 52, bottom: y + 80, top: y + 94),
       vertices(left: x + 52, right: x + 62, bottom: y + 80, top: y + 98)]
    }
    private func vertices(left: Double, right: Double, bottom: Double, top: Double) -> [PDFPoint] {
      [.init(x: left, y: top), .init(x: right, y: top),
       .init(x: right, y: bottom), .init(x: left, y: bottom)]
    }
    func geometry() throws -> PDFPageGeometry {
      try PDFPageGeometry(pageIndex: index, cropOrigin: .init(x: x, y: y),
        width: 200, height: 300, rotation: rotation)
    }
    // Oracle deliberately does not call Domain's rotation or adapter conversion.
    func topLeft(_ p: PDFPoint) -> PDFPoint {
      let a = p.x - x, b = p.y - y
      switch rotation {
      case 0: return .init(x: a, y: 300 - b)
      case 90: return .init(x: b, y: a)
      case 180: return .init(x: 200 - a, y: b)
      default: return .init(x: 300 - b, y: 200 - a)
      }
    }
  }
  static var pages: [Page] {
    (0..<8).map { Page(index: $0, profile: $0 / 4, rotation: ($0 % 4) * 90) }
  }

  enum Launch: Equatable { case absent, invalid, run(String) }
  static func launch(_ arguments: [String]) -> Launch {
    guard arguments.dropFirst().contains(flag) else { return .absent }
    let args = Array(arguments.dropFirst())
    guard args.count == 3, args[0] == flag, args[1] == "--run-id",
      let id = UUID(uuidString: args[2]), id.uuidString.lowercased() == args[2] else { return .invalid }
    return .run(args[2])
  }

  /// Raw deterministic PDF with embedded Type3 glyph programs and ToUnicode.
  /// No system fonts, CoreText substitution, external files, or raster operations.
  static func fixturePDF() -> Data {
    var objects = ["<< /Type /Catalog /Pages 2 0 R >>", ""]
    func stream(_ content: String) -> String {
      "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream"
    }
    objects.append(stream("600 0 0 0 600 700 d1\n0 0 600 700 re f"))
    objects.append(stream("500 0 0 0 500 900 d1\n0 0 500 900 re f"))
    objects.append(stream("""
      /CIDInit /ProcSet findresource begin
      12 dict begin begincmap
      /CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def
      /CMapName /SyntheticUnicode def /CMapType 2 def
      1 begincodespacerange <00> <FF> endcodespacerange
      2 beginbfchar <41> <0041> <42> <0042> endbfchar
      endcmap CMapName currentdict /CMap defineresource pop end end
      """))
    objects.append("""
      << /Type /Font /Subtype /Type3 /Name /F1 /FontBBox [0 0 600 900]
      /FontMatrix [0.001 0 0 0.001 0 0] /CharProcs << /A 3 0 R /B 4 0 R >>
      /Encoding << /Type /Encoding /Differences [65 /A /B] >>
      /FirstChar 65 /LastChar 66 /Widths [600 500] /Resources << >> /ToUnicode 5 0 R
      /FontDescriptor 7 0 R >>
      """)
    // CoreGraphics text extraction requires named vertical metrics for this Type3
    // font. These are the union of the embedded glyph boxes, in glyph units:
    // highest glyph B reaches900; neither glyph extends below the baseline.
    // Glyph programs, widths, Unicode mapping and the independent oracle are unchanged.
    objects.append("""
      << /Type /FontDescriptor /FontName /PaperLensSyntheticAB /Flags 32
      /FontBBox [0 0 600 900] /ItalicAngle 0 /Ascent 900 /Descent 0
      /CapHeight 900 /StemV 500 >>
      """)
    var children: [String] = []
    for page in pages {
      let pageID = objects.count + 1
      children.append("\(pageID) 0 R")
      objects.append("""
        << /Type /Page /Parent 2 0 R /MediaBox [-40 -60 260 360]
        /CropBox [\(page.x) \(page.y) \(page.x + 200) \(page.y + 300)] /Rotate \(page.rotation)
        /Resources << /Font << /F1 6 0 R >> >> /Contents \(pageID + 1) 0 R >>
        """)
      objects.append(stream("BT /F1 20 Tf 1 0 0 1 \(page.x + 40) \(page.y + 80) Tm (AB) Tj ET"))
    }
    objects[1] = "<< /Type /Pages /Count 8 /Kids [\(children.joined(separator: " "))] >>"
    var output = Data("%PDF-1.7\n".utf8)
    var offsets = [0]
    for (index, object) in objects.enumerated() {
      offsets.append(output.count)
      output.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8))
    }
    let xref = output.count
    output.append(Data("xref\n0 \(offsets.count)\n0000000000 65535 f \n".utf8))
    for offset in offsets.dropFirst() {
      output.append(Data(String(format: "%010d 00000 n \n", offset).utf8))
    }
    output.append(Data("trailer\n<< /Size \(offsets.count) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
    return output
  }

  struct Cell: Encodable, Sendable {
    let profile: Int
    let rotation: Int
    let zoom: Double
    var extraction: Double?
    var display: Double?
    var roundtrip: Double?
    var errors: [String] = []
    var passed: Bool {
      guard let extraction, let display, let roundtrip else { return false }
      return errors.isEmpty && extraction <= SyntheticPDFGeometryCalibration.extractionBound
        && display <= SyntheticPDFGeometryCalibration.correspondenceBound
        && roundtrip <= SyntheticPDFGeometryCalibration.roundtripBound
    }
    private enum CodingKeys: String, CodingKey {
      case profile, rotation, zoom, extraction, display, roundtrip, errors, passed
    }
    func encode(to encoder: Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(profile, forKey: .profile)
      try container.encode(rotation, forKey: .rotation)
      try container.encode(zoom, forKey: .zoom)
      try container.encodeIfPresent(extraction, forKey: .extraction)
      try container.encodeIfPresent(display, forKey: .display)
      try container.encodeIfPresent(roundtrip, forKey: .roundtrip)
      try container.encode(errors, forKey: .errors)
      try container.encode(passed, forKey: .passed)
    }
  }
  struct Report: Encodable, Sendable {
    let runID: String
    let version = 1
    let scope = "synthetic-eight-page-24-cell-diagnostic-not-production-or-P6"
    let completionContract = "requires report.json AND matching final terminal receipt; absent receipt is incomplete"
    let cleanupScope = "helper drain, sender, input pin, resource allowance, owned fixture"
    let extractionLimit = SyntheticPDFGeometryCalibration.extractionBound
    let displayLimit = SyntheticPDFGeometryCalibration.correspondenceBound
    let roundtripLimit = SyntheticPDFGeometryCalibration.roundtripBound
    var producerInvocations = 0
    var extractionCompleted = false
    var cleanup = "not_started"
    var errors: [String] = []
    var cells: [Cell] = SyntheticPDFGeometryCalibration.pages.flatMap { page in
      SyntheticPDFGeometryCalibration.scales.map { Cell(profile: page.profile, rotation: page.rotation, zoom: $0) }
    }
    var passed = false
  }
  enum Failure: Error { case invalidInput, envelope, ownership, cleanup, output, geometry }
  static func errorCode(_ error: Error) -> String {
    if let failure = error as? PDFiumFailure { return "pdfium_\(failure.code.rawValue)" }
    if let failure = error as? PDFGeometryError { return "geometry_\(failure)" }
    if let failure = error as? CanonicalExtractionGeometryError { return "codec_\(failure)" }
    if error is CancellationError { return "cancelled" }
    if let failure = error as? Failure { return "calibration_\(failure)" }
    return "operation_failed"
  }
  static func residual(_ actual: [PDFPoint], _ expected: [PDFPoint]) throws -> Double {
    guard actual.count == expected.count, !actual.isEmpty else { throw Failure.geometry }
    var result = 0.0
    for (a, e) in zip(actual, expected) {
      try a.validate(); try e.validate()
      result = max(result, max(abs(a.x - e.x), abs(a.y - e.y)))
    }
    guard result.isFinite else { throw Failure.geometry }
    return result
  }
  static func rawPoints(_ quad: PDFiumRawQuad) -> [PDFPoint] {
    [.init(x: quad.topLeftX, y: quad.topLeftY), .init(x: quad.topRightX, y: quad.topRightY),
     .init(x: quad.bottomRightX, y: quad.bottomRightY), .init(x: quad.bottomLeftX, y: quad.bottomLeftY)]
  }

  @MainActor static func measure(_ batches: [ExtractionBatch], scope: ExtractionConsumptionScope,
    pdf: Data, report: inout Report) throws {
    guard let document = PDFDocument(data: pdf), document.pageCount == 8 else { throw Failure.invalidInput }
    let sentences = batches.flatMap(\.sentences)
    guard sentences.count == 8 else { throw Failure.invalidInput }
    let view = PDFView(frame: CGRect(x: 0, y: 0, width: 600, height: 800))
    view.displayMode = .singlePageContinuous
    view.displayDirection = .vertical
    view.minScaleFactor = 0.1; view.maxScaleFactor = 10; view.autoScales = false
    view.document = document
    defer { view.document = nil }
    for (cellIndex, original) in report.cells.enumerated() {
      try scope.checkBudget()
      var cell = original
      let source = pages[cell.profile * 4 + cell.rotation / 90]
      let matching = sentences.filter { $0.identity.page == source.index }
      guard matching.count == 1, let sentence = matching.first,
        let input = sentence.geometry as? PDFiumGeometryInput,
        let page = document.page(at: source.index) else {
        cell.errors.append("extraction_missing_page"); report.cells[cellIndex] = cell; continue
      }
      var anchor: PDFSentenceAnchor?
      var stage = "extraction"
      do {
        let geometry = try source.geometry()
        let expected = source.glyphVertices.flatMap { $0 }
        let actual = input.glyphs.compactMap(\.rawQuad).flatMap(rawPoints)
        cell.extraction = try residual(actual, expected)
        guard sentence.identity.sentenceID == source.index,
          sentence.text.utf8.elementsEqual("AB".utf8), input.glyphs.map(\.unicodeScalar) == [65, 66],
          input.glyphs.map(\.nativeCharacterIndex) == [0, 1],
          input.glyphs.allSatisfy({ !$0.generated }),
          input.rawPage.rotationQuarterTurns * 90 == source.rotation,
          let crop = input.rawPage.cropBox, let media = input.rawPage.mediaBox,
          try residual(rawPoints(crop), [PDFPoint(x: source.x, y: source.y + 300),
            .init(x: source.x + 200, y: source.y + 300), .init(x: source.x + 200, y: source.y),
            .init(x: source.x, y: source.y)]) == 0,
          try residual(rawPoints(media), [.init(x: -40, y: 360), .init(x: 260, y: 360),
            .init(x: 260, y: -60), .init(x: -40, y: -60)]) == 0 else { throw Failure.geometry }
        if cell.extraction! > extractionBound { cell.errors.append("extraction_bound") }
        stage = "display_setup"
        view.scaleFactor = cell.zoom
        view.go(to: page)
        view.layoutDocumentView()
        guard Double(view.scaleFactor) == cell.zoom,
          try PDFKitGeometryAdapter.pageGeometry(page: page, in: view, pageIndex: source.index) == geometry
        else { throw Failure.geometry }
        let identity = try PDFSentenceIdentity(paperID: sentence.identity.paperID,
          pdfSHA256: sentence.identity.pdfSHA256,
          extractionRevision: sentence.identity.revision.uuidString.lowercased(),
          pageIndex: source.index, sentenceID: sentence.identity.sentenceID)
        let owner = try PDFSentenceAnchor(identity: identity, fullSourceQuote: "AB", page: geometry,
          quads: source.glyphVertices.map {
            try PDFQuad(topLeft: $0[0], topRight: $0[1], bottomRight: $0[2], bottomLeft: $0[3], page: geometry)
          })
        let precision = try PDFGeometryPrecision(maximumErrorPDFPoints: correspondenceBound)
        let mapping = try independentMapping(source, page: page, view: view, zoom: cell.zoom)
        stage = "canonical"
        let validator = PDFiumGeometryValidator(binding: PDFiumGeometryBinding(precision: precision,
          mapPage: { raw in
            guard raw.pageIndex == source.index else { throw Failure.geometry }
            return mapping
          }))
        let encoded = try validator.validateAndEncode(input, identity: sentence.identity, expectedText: "AB")
        anchor = try CanonicalExtractionGeometryValidator(owningAnchors: [owner], precision: precision)
          .decodeAndValidate(encoded.canonicalBytes, identity: sentence.identity)
      } catch { cell.errors.append(stage + "_" + errorCode(error)) }
      if let anchor {
        do {
          let precision = try PDFGeometryPrecision(maximumErrorPDFPoints: correspondenceBound)
          let mapping = try independentMapping(source, page: page, view: view, zoom: cell.zoom)
          var error = 0.0
          // Independent corner/interior correspondences catch origin/axis/rotation errors
          // even if the backend and adapter happen to share an invertible wrong mapping.
          for point in source.corners {
            let direct = view.convert(CGPoint(x: point.x, y: point.y), from: page)
            let actual = PDFPoint(x: Double(direct.x), y: Double(direct.y))
            let expected = try mapping.canonicalToReader.applying(point)
            try envelope([actual, expected])
            error = max(error, try residual([actual], [expected]) / cell.zoom)
            cell.display = error
          }
          let display = try PDFKitGeometryAdapter.displayQuads(anchor: anchor, expected: anchor.identity,
            publishedMembership: [anchor.identity], page: page, in: view, precision: precision).flatMap { $0 }
          let expected = try source.glyphVertices.flatMap { $0 }.map { try mapping.canonicalToReader.applying($0) }
          try envelope(display + expected)
          error = max(error, try residual(display, expected) / cell.zoom)
          cell.display = error
          if error > correspondenceBound { cell.errors.append("display_bound") }
        } catch { cell.errors.append("display_" + errorCode(error)) }
        do {
          let precision = try PDFGeometryPrecision(maximumErrorPDFPoints: roundtripBound)
          var error = 0.0
          for point in anchor.quads.flatMap(\.points) + source.corners {
            let direct = view.convert(CGPoint(x: point.x, y: point.y), from: page)
            let directBack = view.convert(direct, to: page)
            try envelope([.init(x: Double(direct.x), y: Double(direct.y))])
            error = max(error, try residual(
              [.init(x: Double(directBack.x), y: Double(directBack.y))], [point]))
            cell.roundtrip = error
            let display = try PDFKitGeometryAdapter.displayPoint(point, page: page, in: view,
              geometry: anchor.page, precision: precision)
            try envelope([display])
            let back = try PDFKitGeometryAdapter.canonicalPoint(display, page: page, in: view,
              geometry: anchor.page, precision: precision)
            error = max(error, try residual([back], [point]))
            cell.roundtrip = error
          }
          cell.roundtrip = error
          if error > roundtripBound { cell.errors.append("roundtrip_bound") }
        } catch { cell.errors.append("roundtrip_" + errorCode(error)) }
      } else {
        cell.errors.append("display_no_validated_anchor")
        cell.errors.append("roundtrip_no_validated_anchor")
      }
      report.cells[cellIndex] = cell
      try scope.checkBudget()
    }
  }

  static func envelope(_ points: [PDFPoint]) throws {
    for point in points {
      try point.validate()
      guard abs(point.x) <= coordinateLimit, abs(point.y) <= coordinateLimit else { throw Failure.envelope }
    }
  }
  @MainActor static func independentMapping(_ source: Page, page: PDFPage, view: PDFView,
    zoom: Double) throws -> PDFiumPageMapping {
    let origin = PDFPoint(x: source.x, y: source.y)
    let offset = view.convert(CGPoint(x: origin.x, y: origin.y), from: page)
    let base = PDFPoint(x: Double(offset.x), y: Double(offset.y))
    try envelope([base])
    let start = source.topLeft(origin)
    let dx = source.topLeft(.init(x: origin.x + 1, y: origin.y))
    let dy = source.topLeft(.init(x: origin.x, y: origin.y + 1))
    let sign = view.isFlipped ? 1.0 : -1.0
    let a = (dx.x - start.x) * zoom, b = (dx.y - start.y) * zoom * sign
    let c = (dy.x - start.x) * zoom, d = (dy.y - start.y) * zoom * sign
    return try PDFiumPageMapping(page: source.geometry(),
      rawToCanonical: PDFGeometryAffine(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0),
      canonicalToReader: PDFGeometryAffine(a: a, b: b, c: c, d: d,
        tx: base.x - a * origin.x - c * origin.y, ty: base.y - b * origin.x - d * origin.y))
  }

  @MainActor private static var started = false
  // Keep uncertain ownership alive. No timeout or UI completion releases these owners.
  @MainActor private static var retainedFiles: CalibrationFiles?
  @MainActor private static var retainedProducer: PDFiumExtractionProducer?
  @MainActor static func run(arguments: [String]) async {
    guard !started else { return }
    started = true
    guard case .run(let runID) = launch(arguments) else {
      print("synthetic_geometry_calibration: invalid_arguments; no extraction")
      return
    }
    var report = Report(runID: runID)
    do {
      let bytes = fixturePDF()
      let files = try CalibrationFiles(runID: runID)
      retainedFiles = files
      try files.createFixture(bytes)
      let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
      try files.output("started.json", data: encoder.encode(report))
      let paperID = UUID()
      let identity = ExtractionIdentity(paperID: paperID, generation: UUID(),
        pdfSHA256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
        pdfReference: "papers/\(paperID.uuidString)/document.pdf", revision: UUID(),
        job: UUID(), attempt: UUID(), fence: UUID(), correlation: UUID(), input: UUID(), epoch: UUID(),
        configuration: ProviderConfiguration(kind: nil, slotID: nil, generation: 0, model: nil))
      let authority = try ProviderRequest()
      let producer = PDFiumExtractionProducer { identity, operationID in
        try files.acquire(identity: identity, operationID: operationID, authority: authority)
      }
      retainedProducer = producer
      let result = CalibrationResult(report)
      report.producerInvocations = 1
      result.report.producerInvocations = 1
      do {
        try await producer.withBatches(identity) { batches, scope in
          try await result.consume(batches, scope: scope, pdf: bytes)
        }
      } catch { result.report.errors.append(errorCode(error)) }
      report = result.report
      do {
        try files.cleanupFixture()
        report.cleanup = "confirmed"
      } catch {
        report.cleanup = "uncertain_retained"
        report.errors.append(errorCode(error))
      }
      for index in report.cells.indices where report.cells[index].extraction == nil {
        report.cells[index].errors.append("extraction_unavailable")
      }
      report.passed = report.extractionCompleted && report.cleanup == "confirmed"
        && report.errors.isEmpty && report.cells.count == 24 && report.cells.allSatisfy(\.passed)
      try files.output("report.json", data: encoder.encode(report))
      if report.cleanup == "confirmed" {
        try files.closeDirectory()
        retainedProducer = nil; retainedFiles = nil
      }
      print("synthetic_geometry_calibration: \(runID) \(report.passed ? "passed_bounded_diagnostic" : "failed")")
    } catch {
      // started.json without report.json is incomplete/failed, NEVER a passing run.
      print("synthetic_geometry_calibration: \(runID) \(errorCode(error)); missing report is failure")
    }
  }
}

@MainActor private final class CalibrationResult {
  var report: SyntheticPDFGeometryCalibration.Report
  init(_ report: SyntheticPDFGeometryCalibration.Report) { self.report = report }
  func consume(_ batches: [ExtractionBatch], scope: ExtractionConsumptionScope, pdf: Data) throws {
    report.extractionCompleted = true
    try SyntheticPDFGeometryCalibration.measure(batches, scope: scope, pdf: pdf, report: &report)
  }
}

/// One run-owned namespace and an actual second read-only descriptor as the input pin.
/// No product Paper, DB, Provider, arbitrary path or fabricated release callback.
private final class CalibrationFiles: @unchecked Sendable {
  private let lock = NSLock()
  private let directory: Int32
  private var directoryCloseAttempted = false
  private var pin: FileHandle?
  private var resource: PDFiumExtractionResourceOwner?
  private var claimed = false
  private var pinCloseAttempted = false
  private var finished = false
  private var uncertain = false
  private var uncertainHandles: [FileHandle] = []
  private var fixtureRemoved = false
  private var device: dev_t = 0
  private var inode: ino_t = 0

  init(runID: String) throws {
    let fm = FileManager.default
    guard let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
      throw SyntheticPDFGeometryCalibration.Failure.output
    }
    let base = support.appendingPathComponent("PaperLensSyntheticGeometryCalibration", isDirectory: true)
    try fm.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let values = try base.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard values.isDirectory == true, values.isSymbolicLink != true else {
      throw SyntheticPDFGeometryCalibration.Failure.ownership
    }
    let root = base.appendingPathComponent(runID, isDirectory: true)
    guard mkdir(root.path, 0o700) == 0 else { throw SyntheticPDFGeometryCalibration.Failure.ownership }
    directory = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard directory >= 0 else { throw SyntheticPDFGeometryCalibration.Failure.ownership }
  }
  func createFixture(_ pdf: Data) throws {
    try output("fixture.pdf", data: pdf)
    var info = stat()
    guard fstatat(directory, "fixture.pdf", &info, AT_SYMLINK_NOFOLLOW) == 0,
      info.st_mode & S_IFMT == S_IFREG else { throw SyntheticPDFGeometryCalibration.Failure.ownership }
    device = info.st_dev; inode = info.st_ino
  }
  func output(_ name: String, data: Data) throws {
    guard ["fixture.pdf", "started.json", "report.json"].contains(name), !directoryCloseAttempted else {
      throw SyntheticPDFGeometryCalibration.Failure.output
    }
    let fd = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw SyntheticPDFGeometryCalibration.Failure.output }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
    do { try handle.write(contentsOf: data) }
    catch {
      do { try handle.close() } catch { uncertain = true; uncertainHandles.append(handle) }
      throw SyntheticPDFGeometryCalibration.Failure.output
    }
    do { try handle.close() }
    catch {
      uncertain = true; uncertainHandles.append(handle)
      throw SyntheticPDFGeometryCalibration.Failure.cleanup
    }
  }
  func acquire(identity: ExtractionIdentity, operationID: UUID,
    authority: ProviderRequest) throws -> PDFiumPinnedInput {
    try lock.withLock {
      guard !claimed, !uncertain else { throw SyntheticPDFGeometryCalibration.Failure.ownership }
      claimed = true
      let resource = try PDFiumExtractionResourceOwner(identity: identity, operationID: operationID, authority: authority)
      self.resource = resource
      try resource.claimInputAcquisition()
      func openOwned() throws -> FileHandle {
        let fd = openat(directory, "fixture.pdf", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw SyntheticPDFGeometryCalibration.Failure.ownership }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_dev == device, info.st_ino == inode,
          info.st_mode & S_IFMT == S_IFREG else {
          do { try handle.close() } catch { uncertain = true; uncertainHandles.append(handle) }
          throw SyntheticPDFGeometryCalibration.Failure.ownership
        }
        return handle
      }
      var sender: FileHandle?
      do {
        pin = try openOwned()
        sender = try openOwned()
        return try PDFiumPinnedInput(operationID: operationID, identity: identity, senderPDF: sender!,
          limits: resource.limits, deadlineUptimeNanoseconds: resource.deadlineUptimeNanoseconds,
          checkBudget: { try resource.checkBudget() },
          releaseReadPin: { [self] id in try releasePin(id) },
          finishOperation: { [self] id in try finish(id) })
      } catch {
        // No input was returned to the producer, so no helper can hold these descriptors.
        if let sender {
          do { try sender.close() } catch { uncertain = true; uncertainHandles.append(sender) }
        }
        if let pin {
          pinCloseAttempted = true
          do { try pin.close(); self.pin = nil } catch { uncertain = true }
        }
        if !uncertain { try resource.finishOperation(operationID); finished = true }
        throw error
      }
    }
  }
  private func releasePin(_ id: UUID) throws {
    try lock.withLock {
      guard resource?.operationID == id, !pinCloseAttempted, !uncertain, let pin else {
        throw SyntheticPDFGeometryCalibration.Failure.cleanup
      }
      pinCloseAttempted = true
      do { try pin.close(); self.pin = nil }
      catch { uncertain = true; throw SyntheticPDFGeometryCalibration.Failure.cleanup }
    }
  }
  private func finish(_ id: UUID) throws {
    try lock.withLock {
      guard !uncertain, pinCloseAttempted, pin == nil, let resource, resource.operationID == id else {
        throw SyntheticPDFGeometryCalibration.Failure.cleanup
      }
      try resource.finishOperation(id)
      finished = true
    }
  }
  func cleanupFixture() throws {
    try lock.withLock {
      guard !uncertain, (!claimed || finished), !fixtureRemoved else {
        throw SyntheticPDFGeometryCalibration.Failure.cleanup
      }
      var info = stat()
      guard fstatat(directory, "fixture.pdf", &info, AT_SYMLINK_NOFOLLOW) == 0,
        info.st_dev == device, info.st_ino == inode, info.st_mode & S_IFMT == S_IFREG,
        unlinkat(directory, "fixture.pdf", 0) == 0 else {
        uncertain = true; throw SyntheticPDFGeometryCalibration.Failure.cleanup
      }
      fixtureRemoved = true
    }
  }
  func closeDirectory() throws {
    guard !directoryCloseAttempted else { throw SyntheticPDFGeometryCalibration.Failure.cleanup }
    directoryCloseAttempted = true
    guard Darwin.close(directory) == 0 else { throw SyntheticPDFGeometryCalibration.Failure.cleanup }
  }
}
