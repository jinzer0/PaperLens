import Foundation
import ProviderRequest

public enum ReadinessSource: String, CaseIterable, Hashable, Codable, Sendable {
  case arxivAbstract, arxivPDF, httpsPDF, localPDF
  public var hasSoftTarget: Bool { self == .arxivAbstract || self == .arxivPDF }
}
public enum ReadinessCPU: String, Hashable, Codable, Sendable { case arm64, intel }
public enum ReadinessOS: String, Hashable, Codable, Sendable { case minimum15, current27 }
public enum ReadinessCache: String, Hashable, Codable, Sendable { case cold, warm }
public enum ReadinessBacking: Int, CaseIterable, Hashable, Codable, Sendable {
  case one = 1
  case two = 2
}
public enum ReadinessToolchain: String, Hashable, Codable, Sendable { case xcode27A266aSwift64 }
public enum ReadinessProbeVersion: String, Hashable, Codable, Sendable { case zoomV1 = "zoom-v1" }
public enum ReadinessCodeVersion: String, Hashable, Codable, Sendable {
  case precursorV1 = "readiness-precursor-v1"
}
public enum ReadinessSemantics: String, Hashable, Codable, Sendable {
  case offscreenRasterOnly
}

/// Closed comparison identity. The geometry and semantics cannot vary inside zoom-v1.
public struct ReadinessProfile: Equatable, Hashable, Codable, Sendable {
  public let source: ReadinessSource
  public let cpu: ReadinessCPU
  public let os: ReadinessOS
  public let cache: ReadinessCache
  public let backing: ReadinessBacking
  public let toolchain: ReadinessToolchain
  public var probeVersion: ReadinessProbeVersion { .zoomV1 }
  public var codeVersion: ReadinessCodeVersion { .precursorV1 }
  public var semantics: ReadinessSemantics { .offscreenRasterOnly }
  private enum CodingKeys: String, CodingKey {
    case source, cpu, os, cache, backing, toolchain, probeVersion, codeVersion, semantics
  }
  public init(
    source: ReadinessSource, cpu: ReadinessCPU, os: ReadinessOS,
    cache: ReadinessCache, backing: ReadinessBacking,
    toolchain: ReadinessToolchain = .xcode27A266aSwift64
  ) {
    self.source = source
    self.cpu = cpu
    self.os = os
    self.cache = cache
    self.backing = backing
    self.toolchain = toolchain
  }
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    _ = try container.decode(ReadinessProbeVersion.self, forKey: .probeVersion)
    _ = try container.decode(ReadinessCodeVersion.self, forKey: .codeVersion)
    _ = try container.decode(ReadinessSemantics.self, forKey: .semantics)
    self.init(
      source: try container.decode(ReadinessSource.self, forKey: .source),
      cpu: try container.decode(ReadinessCPU.self, forKey: .cpu),
      os: try container.decode(ReadinessOS.self, forKey: .os),
      cache: try container.decode(ReadinessCache.self, forKey: .cache),
      backing: try container.decode(ReadinessBacking.self, forKey: .backing),
      toolchain: try container.decode(ReadinessToolchain.self, forKey: .toolchain))
  }
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(source, forKey: .source)
    try container.encode(cpu, forKey: .cpu)
    try container.encode(os, forKey: .os)
    try container.encode(cache, forKey: .cache)
    try container.encode(backing, forKey: .backing)
    try container.encode(toolchain, forKey: .toolchain)
    try container.encode(probeVersion, forKey: .probeVersion)
    try container.encode(codeVersion, forKey: .codeVersion)
    try container.encode(semantics, forKey: .semantics)
  }
}

public enum ReadinessFailure: Error, Equatable, Sendable {
  case invalidMeasurement, changedProbe, noncomparable, cancelled, deadline
  case staleGeneration, wrongUpdate, unsupportedCapture, blankCapture, resourceLimit
  case invalidPDF, missingCompletion
}
public enum ReadinessOutcome: String, Codable, Sendable {
  case rasterVerified, qualifiedVisibleUpdate, missingCompletion, wrongUpdate
  case cancelled, invalidMeasurement, changedProbe, noncomparable
}
public enum DurationBand: String, Codable, Sendable {
  case withinSoftTarget, overSoftTarget, notObserved
}
public enum GeometryBand: String, Codable, Sendable {
  case withinTolerance, outsideTolerance, notObserved
}
public enum ReadinessDisposition: String, Codable, Sendable {
  case baseline, withinTarget, review, repeated, severe
  public var requiresResolution: Bool { self == .repeated || self == .severe }
  /// A single soft exceedance is review, never a release failure.
  public var isHardReleaseFailure: Bool { self == .severe }
}
public enum ReadinessOwner: String, Codable, Sendable { case renderer, importPipeline, measurement }
public enum ReadinessCause: String, Codable, Sendable {
  case completionUnproven, geometry, resource, deadline, latency, invalidEvents
}
public enum ReadinessAction: String, Codable, Sendable {
  case establishWitness, repairProbe, investigateLatency
}
public enum ReadinessRetest: String, Codable, Sendable { case sameCells, fullVisibleMatrix }
public enum ReadinessRisk: String, Codable, Sendable { case measuredLatencyOnly }

public struct ReadinessResolution: Equatable, Encodable, Sendable {
  public let owner: ReadinessOwner
  public let cause: ReadinessCause
  public let affectedCells: Set<ReadinessProfile>
  public let action: ReadinessAction
  public let retest: ReadinessRetest
  public let measuredRisk: ReadinessRisk?
  public init(
    owner: ReadinessOwner, cause: ReadinessCause,
    affectedCells: Set<ReadinessProfile>, action: ReadinessAction,
    retest: ReadinessRetest, measuredRisk: ReadinessRisk? = nil
  ) throws {
    guard !affectedCells.isEmpty,
      measuredRisk == nil || cause == .latency
    else { throw ReadinessFailure.invalidMeasurement }
    self.owner = owner
    self.cause = cause
    self.affectedCells = affectedCells
    self.action = action
    self.retest = retest
    self.measuredRisk = measuredRisk
  }
}

/// Only this closed projection is serializable. It contains no raw input or timing values.
public struct ReadinessProjection: Equatable, Encodable, Sendable {
  public let profile: ReadinessProfile
  public let outcome: ReadinessOutcome
  public let completion: ReadinessOutcome
  public let durationBand: DurationBand
  public let geometryBand: GeometryBand
  public let disposition: ReadinessDisposition
  public let resolution: ReadinessResolution?
  public let storyBlocked: Bool
  public let p6Blocked: Bool
  public let downstreamBlocked: Bool
}

/// Scripted metadata only: no transport, filesystem, security-scope or fixture proof.
public enum ReadinessSourceFixtures {
  public static func classify(_ source: ReadinessSource, authority: ProviderRequest) throws {
    let budget = try RequestResourceBudget(authority: authority, kind: "import")
    let prefix = Data("%PDF-1.7\n".utf8)
    if source == .localPDF {
      try authority.validatePDFSignature(prefix: prefix, mime: nil, sourceKind: source.rawValue)
    } else {
      let url: ValidatedRequestURL
      switch source {
      case .arxivAbstract:
        url = try authority.resolveArxivAbstractURL("https://arxiv.org/abs/2401.00001")
      case .arxivPDF:
        url = try authority.validateImportURL(
          "https://arxiv.org/pdf/2401.00001", sourceKind: source.rawValue)
      case .httpsPDF:
        url = try authority.validateImportURL(
          "https://example.org/synthetic.pdf", sourceKind: source.rawValue)
      case .localPDF: throw ReadinessFailure.invalidMeasurement
      }
      guard
        case .pdf = try authority.validateHTTPResponse(
          current: url, status: 200,
          headers: [RequestHTTPHeader("Content-Type", "application/pdf")], prefix: prefix,
          budget: budget)
      else { throw ReadinessFailure.invalidMeasurement }
    }
    try budget.add("bodyBytes", delta: prefix.count)
  }
}

/// Raw monotonic values are RAM-only, deliberately not Codable or printable evidence.
public struct ReadinessStamp: Equatable, Sendable {
  public let attempt: UUID
  public let generation: UInt64
  public let profile: ReadinessProfile
  public let instant: ContinuousClock.Instant
  public init(
    attempt: UUID, generation: UInt64, profile: ReadinessProfile,
    instant: ContinuousClock.Instant
  ) {
    self.attempt = attempt
    self.generation = generation
    self.profile = profile
    self.instant = instant
  }
}

/// Construction is module-internal and occurs only after actual PDFView pixel verification.
public struct RasterObservation: Sendable {
  public let stamp: ReadinessStamp
  public let geometry: GeometryBand
  internal init(stamp: ReadinessStamp) {
    self.stamp = stamp
    geometry = .withinTolerance
  }
}

/// No API can authenticate a visible witness in this precursor.
public struct ReadinessAttempt: Sendable {
  public let attempt: UUID
  public let generation: UInt64
  public let profile: ReadinessProfile
  private let deadline: ContinuousClock.Instant
  private var queued: ContinuousClock.Instant?
  public private(set) var importAcceptedAt: ContinuousClock.Instant?
  public private(set) var presentationAt: ContinuousClock.Instant?
  public private(set) var rasterVerifiedAt: ContinuousClock.Instant?
  public var firstInteractivePageAt: ContinuousClock.Instant? { nil }
  public private(set) var outcome: ReadinessOutcome = .missingCompletion
  public private(set) var failure: ReadinessFailure?
  private var last: ContinuousClock.Instant?
  private var terminal = false
  private var geometry: GeometryBand = .notObserved

  public init(
    attempt: UUID, generation: UInt64, profile: ReadinessProfile,
    deadline: ContinuousClock.Instant
  ) {
    self.attempt = attempt
    self.generation = generation
    self.profile = profile
    self.deadline = deadline
  }
  private mutating func reject(
    _ reason: ReadinessFailure,
    geometry band: GeometryBand = .notObserved
  ) throws {
    failure = reason
    terminal = true
    rasterVerifiedAt = nil
    geometry = band
    switch reason {
    case .cancelled: outcome = .cancelled
    case .changedProbe: outcome = .changedProbe
    case .noncomparable: outcome = .noncomparable
    case .wrongUpdate: outcome = .wrongUpdate
    case .missingCompletion, .deadline: outcome = .missingCompletion
    default: outcome = .invalidMeasurement
    }
    throw reason
  }
  private mutating func validate(_ stamp: ReadinessStamp) throws {
    guard !terminal else { throw failure ?? ReadinessFailure.invalidMeasurement }
    guard stamp.attempt == attempt, stamp.generation == generation else {
      try reject(.staleGeneration)
      return
    }
    guard stamp.profile == profile else {
      try reject(.changedProbe)
      return
    }
    guard stamp.instant < deadline else {
      try reject(.deadline)
      return
    }
    if let last, stamp.instant < last {
      try reject(.invalidMeasurement)
      return
    }
    last = stamp.instant
  }
  public mutating func queueAutomaticOpen(_ stamp: ReadinessStamp) throws {
    try validate(stamp)
    guard queued == nil, importAcceptedAt == nil else {
      try reject(.invalidMeasurement)
      return
    }
    queued = stamp.instant
  }
  public mutating func acceptImport(_ stamp: ReadinessStamp) throws {
    try validate(stamp)
    guard importAcceptedAt == nil else {
      try reject(.invalidMeasurement)
      return
    }
    guard queued != nil else {
      try reject(.noncomparable)
      return
    }
    importAcceptedAt = stamp.instant
  }
  public mutating func present(_ stamp: ReadinessStamp, automatic: Bool = true) throws {
    try validate(stamp)
    guard automatic else {
      try reject(.noncomparable)
      return
    }
    guard importAcceptedAt != nil, presentationAt == nil else {
      try reject(.invalidMeasurement)
      return
    }
    presentationAt = stamp.instant
  }
  public mutating func recordRaster(_ observation: RasterObservation) throws {
    try validate(observation.stamp)
    guard presentationAt != nil, rasterVerifiedAt == nil else {
      try reject(.invalidMeasurement)
      return
    }
    rasterVerifiedAt = observation.stamp.instant
    outcome = .rasterVerified
    geometry = observation.geometry
  }
  /// Event assertions, callbacks and scale notifications are not visible witnesses.
  public mutating func assertQualifiedVisibleUpdate(_ stamp: ReadinessStamp) throws {
    try validate(stamp)
    try reject(.wrongUpdate)
  }
  public mutating func cancel(_ stamp: ReadinessStamp) throws {
    try validate(stamp)
    try reject(.cancelled)
  }
  public mutating func failProbe(_ stamp: ReadinessStamp, reason: ReadinessFailure) throws {
    try validate(stamp)
    try reject(reason, geometry: reason == .wrongUpdate ? .outsideTolerance : .notObserved)
  }
  public mutating func finish(_ stamp: ReadinessStamp) throws {
    try validate(stamp)
    terminal = true
    if rasterVerifiedAt == nil { outcome = .missingCompletion }
    failure = .missingCompletion
  }
  public var rasterDuration: Duration? {
    guard failure == nil || failure == .missingCompletion,
      let start = importAcceptedAt, let end = rasterVerifiedAt, end >= start
    else { return nil }
    return start.duration(to: end)
  }
  public var timingSample: ReadinessTimingSample? {
    guard let duration = rasterDuration else { return nil }
    return ReadinessTimingSample(attempt: attempt, profile: profile, duration: duration)
  }
  public func projection(resolution: ReadinessResolution? = nil) throws -> ReadinessProjection {
    guard let resolution, resolution.affectedCells.contains(profile),
      resolution.measuredRisk == nil
    else {
      throw ReadinessFailure.invalidMeasurement
    }
    let band = ReadinessAssessment.durationBand(rasterDuration, source: profile.source)
    return ReadinessProjection(
      profile: profile, outcome: outcome, completion: .missingCompletion,
      durationBand: band, geometryBand: geometry,
      disposition: .severe, resolution: resolution,
      storyBlocked: true, p6Blocked: true, downstreamBlocked: true)
  }
}

/// RAM-only raster timing. Public callers obtain this from an accepted attempt, not raw assertions.
public struct ReadinessTimingSample: Sendable {
  public let attempt: UUID
  public let profile: ReadinessProfile
  public let duration: Duration
  internal init(attempt: UUID, profile: ReadinessProfile, duration: Duration) {
    self.attempt = attempt
    self.profile = profile
    self.duration = duration
  }
}

/// Timing review is separate from completion qualification. Never a release/P6 gate.
public enum ReadinessAssessment {
  public static func durationBand(_ duration: Duration?, source: ReadinessSource) -> DurationBand {
    guard source.hasSoftTarget, let duration, duration >= .zero else { return .notObserved }
    return duration <= .milliseconds(30_000) ? .withinSoftTarget : .overSoftTarget
  }
  public static func disposition(
    profile: ReadinessProfile,
    samples: [ReadinessTimingSample], severe: Bool = false
  ) throws -> ReadinessDisposition {
    guard samples.allSatisfy({ $0.profile == profile && $0.duration >= .zero }),
      Set(samples.map(\.attempt)).count == samples.count
    else {
      throw ReadinessFailure.invalidMeasurement
    }
    if severe { return .severe }
    guard !samples.isEmpty else { return .severe }
    guard profile.source.hasSoftTarget else { return .baseline }
    let overs = samples.filter { $0.duration > .milliseconds(30_000) }.count
    if overs >= 2 { return .repeated }
    return overs == 1 ? .review : .withinTarget
  }
}

public struct PixelFiducial: Equatable, Sendable {
  public let minX: Int
  public let minY: Int
  public let maxX: Int
  public let maxY: Int
  public var width: Double { Double(maxX - minX + 1) }
  public var height: Double { Double(maxY - minY + 1) }
  public var centerX: Double { Double(minX + maxX) / 2 }
  public var centerY: Double { Double(minY + maxY) / 2 }
}

/// Scans actual canonical RGBA bytes. Conversion coordinates are not rendering evidence.
public enum ReadinessPixels {
  public static let maximumBytes = 4_194_304
  public static let tolerance = 2.0
  public static func scan(
    rgba: [UInt8], width: Int, height: Int,
    backing: ReadinessBacking, scale: Double, expectedCenters: [(Double, Double)]
  ) throws -> [PixelFiducial] {
    let b = backing.rawValue
    guard width == 300 * b, height == 240 * b,
      rgba.count == width * height * 4, rgba.count <= maximumBytes,
      scale.isFinite, scale > 0, expectedCenters.count == 3,
      expectedCenters.allSatisfy({ $0.0.isFinite && $0.1.isFinite })
    else { throw ReadinessFailure.unsupportedCapture }
    var bounds = Array(repeating: (width, height, -1, -1, 0), count: 3)
    for y in 0..<height {
      for x in 0..<width {
        let i = (y * width + x) * 4
        guard rgba[i + 3] >= 250 else { continue }
        for c in 0..<3
        where rgba[i + c] >= 220
          && rgba[i + (c + 1) % 3] <= 35 && rgba[i + (c + 2) % 3] <= 35
        {
          bounds[c].0 = min(bounds[c].0, x)
          bounds[c].1 = min(bounds[c].1, y)
          bounds[c].2 = max(bounds[c].2, x)
          bounds[c].3 = max(bounds[c].3, y)
          bounds[c].4 += 1
        }
      }
    }
    guard bounds.allSatisfy({ $0.4 > 0 }) else { throw ReadinessFailure.blankCapture }
    let fids = bounds.map { PixelFiducial(minX: $0.0, minY: $0.1, maxX: $0.2, maxY: $0.3) }
    let expectedWidth = 8 * scale * Double(b)
    for c in 0..<3 {
      let fid = fids[c]
      guard fid.minX > 0, fid.minY > 0, fid.maxX < width - 1, fid.maxY < height - 1,
        abs(fid.width - expectedWidth) <= tolerance,
        abs(fid.height - expectedWidth) <= tolerance,
        abs(fid.centerX - expectedCenters[c].0) <= tolerance,
        abs(fid.centerY - expectedCenters[c].1) <= tolerance,
        Double(bounds[c].4) >= fid.width * fid.height * 0.8
      else { throw ReadinessFailure.wrongUpdate }
    }
    for pair in [(0, 1), (1, 2), (0, 2)] {
      let expected = Double(pair.1 - pair.0) * 70 * scale * Double(b)
      guard abs(fids[pair.1].centerX - fids[pair.0].centerX - expected) <= tolerance else {
        throw ReadinessFailure.wrongUpdate
      }
    }
    return fids
  }
  public static func verifyZoom(baseline: [PixelFiducial], zoomed: [PixelFiducial]) throws {
    guard baseline.count == 3, zoomed.count == 3 else { throw ReadinessFailure.wrongUpdate }
    for i in 0..<3 {
      guard abs(zoomed[i].width - baseline[i].width * 1.25) <= tolerance,
        abs(zoomed[i].height - baseline[i].height * 1.25) <= tolerance
      else {
        throw ReadinessFailure.wrongUpdate
      }
    }
    for pair in [(0, 1), (1, 2), (0, 2)] {
      let before = baseline[pair.1].centerX - baseline[pair.0].centerX
      let after = zoomed[pair.1].centerX - zoomed[pair.0].centerX
      guard abs(after - before * 1.25) <= tolerance else { throw ReadinessFailure.wrongUpdate }
    }
  }
}
