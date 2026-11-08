import CoreFoundation
import CryptoKit
import Darwin
import Foundation

// Independent CODE-artifact identities, supplied by setup before SQLite opens.
// Unlike canary fixtures, these descriptors never authorize automatic deletion.
struct TopologyDBOwnerContext: @unchecked Sendable {
  let worktreePath: String
  let worktree: Int32
  let topology: Int32
  let namespace: Int32
  let worktreeIdentity: stat
  let topologyIdentity: stat
  let namespaceIdentity: stat
  let databaseIdentity: stat
  let uid: uid_t
  let ownerID: String
  let runID: String
  let attemptID: String
  var entry: String { "local-grdb-probe-" + runID }
  var databasePath: String { worktreePath + "/.build/topology/" + entry + "/db.sqlite" }

  func validateDirectory() -> Bool {
    guard uid == getuid(), uid == geteuid(), TopologyFixtures.validRunID(runID),
      TopologyFixtures.validRunID(ownerID), TopologyFixtures.validRunID(attemptID),
      worktreePath.hasPrefix("/"),
      URL(fileURLWithPath: worktreePath).standardizedFileURL.path == worktreePath
    else { return false }
    func same(_ fd: Int32, _ expected: stat, privateMode: Bool) -> Bool {
      var current = stat()
      guard fstat(fd, &current) == 0, current.st_dev == expected.st_dev,
        current.st_ino == expected.st_ino, current.st_uid == uid,
        expected.st_uid == uid, current.st_mode & S_IFMT == S_IFDIR
      else { return false }
      return !privateMode || TopologyFixtures.privateDirectory(fd, info: &current)
    }
    guard same(worktree, worktreeIdentity, privateMode: false),
      same(topology, topologyIdentity, privateMode: false),
      same(namespace, namespaceIdentity, privateMode: true),
      TopologyFixtures.matches(directory: topology, name: entry, info: namespaceIdentity),
      let root = TopologyFixtures.directory(URL(fileURLWithPath: worktreePath), create: false)
    else { return false }
    defer { close(root) }
    guard same(root, worktreeIdentity, privateMode: false),
      let parent = TopologyFixtures.directory(
        URL(fileURLWithPath: worktreePath + "/.build/topology"), create: false)
    else { return false }
    defer { close(parent) }
    return same(parent, topologyIdentity, privateMode: false)
      && TopologyFixtures.matches(directory: parent, name: entry, info: namespaceIdentity)
  }

  func validate() -> Bool {
    validateDirectory() && validateFile("db.sqlite", identity: databaseIdentity)
      && validateDirectory()
  }

  func validateFile(_ name: String, identity: stat) -> Bool {
    var current = stat()
    return identity.st_uid == uid
      && TopologyFixtures.privateNamedFile(
        directory: namespace, name: name,
        path: worktreePath + "/.build/topology/" + entry + "/" + name, info: &current)
      && current.st_dev == identity.st_dev && current.st_ino == identity.st_ino
      && TopologyFixtures.matches(directory: namespace, name: name, info: identity)
  }

  func entries() -> Set<String>? {
    let fd = openat(namespace, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { return nil }
    guard let directory = fdopendir(fd) else {
      close(fd)
      return nil
    }
    defer { closedir(directory) }
    var result = Set<String>()
    errno = 0
    while let entry = readdir(directory) {
      let name = withUnsafePointer(to: &entry.pointee.d_name) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
          String(cString: $0)
        }
      }
      if name != "." && name != ".." { result.insert(name) }
      if result.count > 4 { return nil }
      errno = 0
    }
    return errno == 0 ? result : nil
  }
}

@objc public protocol PDFTopologyService {
  func identify(_ runID: String, withReply reply: @escaping (Data) -> Void)
  func inspect(_ runID: String, pdf: FileHandle, withReply reply: @escaping (Data) -> Void)
}

@objc(PaperLensPDFiumExtractionService) public protocol PDFiumExtractionService: PDFTopologyService
{
  func beginExtraction(
    _ request: PDFiumExtractionRequest, pdf: FileHandle,
    withReply reply: @escaping (PDFiumStartAck?, PDFiumFailure?) -> Void)
  func nextExtractionBatch(
    _ operationID: NSUUID, sequence: Int,
    withReply reply: @escaping (PDFiumBatch?, PDFiumEnd?, PDFiumFailure?) -> Void)
  func cancelExtractionAndDrain(
    _ operationID: NSUUID,
    withReply reply: @escaping (PDFiumEnd?, PDFiumFailure?) -> Void)
}

/// Shared reply-shape checks do not constitute same-operation drain proof.
enum PDFiumExtractionReplies {
  static func validateStart(_ ack: PDFiumStartAck?, failure: PDFiumFailure?) throws {
    guard (ack != nil) != (failure != nil) else {
      throw PDFiumFailure(code: .protocolViolation)
    }
  }
  static func validatePull(
    _ batch: PDFiumBatch?, end: PDFiumEnd?,
    failure: PDFiumFailure?
  ) throws {
    if failure != nil {
      guard batch == nil, end == nil || end?.disposition == .failed else {
        throw PDFiumFailure(code: .protocolViolation)
      }
    } else {
      guard let batch, batch.complete == (end != nil),
        end == nil || end?.disposition == .completed
      else {
        throw PDFiumFailure(code: .protocolViolation)
      }
    }
  }
}

// No keyed scalar may silently decode to zero. Objects are decoded by exact class;
// arrays are copied to Swift value storage and contain only final immutable DTOs.
private enum PDFiumCoding {
  static func integer(_ c: NSCoder, _ k: String) -> Int? {
    guard c.containsValue(forKey: k) else { return nil }
    return c.decodeInteger(forKey: k)
  }
  static func int64(_ c: NSCoder, _ k: String) -> Int64? {
    guard c.containsValue(forKey: k) else { return nil }
    return c.decodeInt64(forKey: k)
  }
  static func uint64(_ c: NSCoder, _ k: String) -> UInt64? {
    int64(c, k).map { UInt64(bitPattern: $0) }
  }
  static func number(_ c: NSCoder, _ k: String) -> Double? {
    guard c.containsValue(forKey: k) else { return nil }
    let v = c.decodeDouble(forKey: k)
    return v.isFinite ? v : nil
  }
  static func bool(_ c: NSCoder, _ k: String) -> Bool? {
    guard c.containsValue(forKey: k) else { return nil }
    return c.decodeBool(forKey: k)
  }
  static func string(_ c: NSCoder, _ k: String) -> String? {
    (c.decodeObject(of: NSString.self, forKey: k)).map { String($0) }
  }
  static func uuid(_ c: NSCoder, _ k: String) -> UUID? {
    (c.decodeObject(of: NSUUID.self, forKey: k)).map { $0 as UUID }
  }
  static func hash(_ s: String) -> Bool {
    s.utf8.count == 64 && s.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }
  static func uuidV4(_ value: UUID) -> Bool {
    let bytes = value.uuid
    return bytes.6 & 0xf0 == 0x40 && bytes.8 & 0xc0 == 0x80
  }
}

@objc(PaperLensPDFiumExtractionKey)
public final class PDFiumExtractionKey: NSObject, NSSecureCoding, @unchecked Sendable {
  public static var supportsSecureCoding: Bool { true }
  public let operationID: UUID
  public let paperID: UUID
  public let generation: UUID
  public let revision: UUID
  public let job: UUID
  public let attempt: UUID
  public let fence: UUID
  public let correlation: UUID
  public let input: UUID
  public let epoch: UUID
  public let pdfSHA256: String
  public let pdfReference: String
  public var payloadBytes: Int? {
    let strings = pdfSHA256.utf8.count.addingReportingOverflow(pdfReference.utf8.count)
    let total = strings.partialValue.addingReportingOverflow(10 * MemoryLayout<uuid_t>.size)
    return strings.overflow || total.overflow ? nil : total.partialValue
  }
  public init(
    operationID: UUID, paperID: UUID, generation: UUID, revision: UUID,
    job: UUID, attempt: UUID, fence: UUID, correlation: UUID, input: UUID, epoch: UUID,
    pdfSHA256: String, pdfReference: String
  ) throws {
    guard PDFiumCoding.hash(pdfSHA256), !pdfReference.isEmpty,
      [operationID, paperID, generation, revision, job, attempt, fence, correlation, input, epoch]
        .allSatisfy(PDFiumCoding.uuidV4)
    else {
      throw PDFiumFailure(code: .invalidRequest)
    }
    self.operationID = operationID
    self.paperID = paperID
    self.generation = generation
    self.revision = revision
    self.job = job
    self.attempt = attempt
    self.fence = fence
    self.correlation = correlation
    self.input = input
    self.epoch = epoch
    self.pdfSHA256 = pdfSHA256
    self.pdfReference = pdfReference
  }
  public required convenience init?(coder c: NSCoder) {
    guard let op = PDFiumCoding.uuid(c, "operationID"), let p = PDFiumCoding.uuid(c, "paperID"),
      let g = PDFiumCoding.uuid(c, "generation"), let r = PDFiumCoding.uuid(c, "revision"),
      let j = PDFiumCoding.uuid(c, "job"), let a = PDFiumCoding.uuid(c, "attempt"),
      let f = PDFiumCoding.uuid(c, "fence"), let co = PDFiumCoding.uuid(c, "correlation"),
      let i = PDFiumCoding.uuid(c, "input"), let e = PDFiumCoding.uuid(c, "epoch"),
      let h = PDFiumCoding.string(c, "pdfSHA256"), let ref = PDFiumCoding.string(c, "pdfReference")
    else { return nil }
    do {
      try self.init(
        operationID: op, paperID: p, generation: g, revision: r, job: j,
        attempt: a, fence: f, correlation: co, input: i, epoch: e, pdfSHA256: h, pdfReference: ref)
    } catch { return nil }
  }
  public func encode(with c: NSCoder) {
    c.encode(operationID as NSUUID, forKey: "operationID")
    c.encode(paperID as NSUUID, forKey: "paperID")
    c.encode(generation as NSUUID, forKey: "generation")
    c.encode(revision as NSUUID, forKey: "revision")
    c.encode(job as NSUUID, forKey: "job")
    c.encode(attempt as NSUUID, forKey: "attempt")
    c.encode(fence as NSUUID, forKey: "fence")
    c.encode(correlation as NSUUID, forKey: "correlation")
    c.encode(input as NSUUID, forKey: "input")
    c.encode(epoch as NSUUID, forKey: "epoch")
    c.encode(pdfSHA256 as NSString, forKey: "pdfSHA256")
    c.encode(pdfReference as NSString, forKey: "pdfReference")
  }
  public func matches(_ other: PDFiumExtractionKey) -> Bool {
    operationID == other.operationID && paperID == other.paperID && generation == other.generation
      && revision == other.revision && job == other.job && attempt == other.attempt
      && fence == other.fence && correlation == other.correlation && input == other.input
      && epoch == other.epoch && pdfSHA256 == other.pdfSHA256
      && pdfReference.utf8.elementsEqual(other.pdfReference.utf8)
  }
}

public enum PDFiumFailureCode: Int, Sendable {
  case invalidRequest, identityMismatch, busy, invalidPDF, unsupportedGeometry, unmappableText
  case resourceExceeded, cancelled, protocolViolation, cleanupIncomplete
}
@objc(PaperLensPDFiumFailure)
public final class PDFiumFailure: NSObject, NSSecureCoding, Error, @unchecked Sendable {
  public static var supportsSecureCoding: Bool { true }
  public let code: PDFiumFailureCode
  public let nativeError: UInt64?
  public let systemError: Int32?
  public init(code: PDFiumFailureCode, nativeError: UInt64? = nil, systemError: Int32? = nil) {
    self.code = code
    self.nativeError = nativeError
    self.systemError = systemError
  }
  public required convenience init?(coder c: NSCoder) {
    guard let n = PDFiumCoding.integer(c, "code"), let code = PDFiumFailureCode(rawValue: n),
      let hn = PDFiumCoding.bool(c, "hasNative"), let hs = PDFiumCoding.bool(c, "hasSystem")
    else { return nil }
    var native: UInt64?
    var system: Int32?
    if hn {
      guard let v = PDFiumCoding.uint64(c, "native") else { return nil }
      native = v
    }
    if hs {
      guard let v = PDFiumCoding.integer(c, "system"), let s = Int32(exactly: v) else { return nil }
      system = s
    }
    self.init(code: code, nativeError: native, systemError: system)
  }
  public func encode(with c: NSCoder) {
    c.encode(code.rawValue, forKey: "code")
    c.encode(nativeError != nil, forKey: "hasNative")
    c.encode(systemError != nil, forKey: "hasSystem")
    if let v = nativeError { c.encode(Int64(bitPattern: v), forKey: "native") }
    if let v = systemError { c.encode(Int(v), forKey: "system") }
  }
}

@objc(PaperLensPDFiumExtractionLimits)
public final class PDFiumExtractionLimits: NSObject, NSSecureCoding, @unchecked Sendable {
  public static var supportsSecureCoding: Bool { true }
  public let maximumInputBytes: Int64
  public let maximumPages: Int
  public let maximumSentences: Int
  public let maximumSentenceBytes: Int
  public let maximumTextBytes: Int
  public let maximumQuadsPerSentence: Int
  public let maximumQuads: Int
  public let maximumBatchSentences: Int
  public let maximumBatchBytes: Int
  public let maximumResidentBytes: UInt64
  public init(
    maximumInputBytes: Int64, maximumPages: Int, maximumSentences: Int,
    maximumSentenceBytes: Int, maximumTextBytes: Int, maximumQuadsPerSentence: Int,
    maximumQuads: Int, maximumBatchSentences: Int, maximumBatchBytes: Int,
    maximumResidentBytes: UInt64
  ) throws {
    guard maximumInputBytes > 0, maximumResidentBytes > 0,
      [
        maximumPages, maximumSentences, maximumSentenceBytes, maximumTextBytes,
        maximumQuadsPerSentence, maximumQuads, maximumBatchSentences, maximumBatchBytes,
      ]
      .allSatisfy({ $0 > 0 }), maximumSentenceBytes <= maximumTextBytes,
      maximumQuadsPerSentence <= maximumQuads, maximumBatchSentences <= maximumSentences
    else { throw PDFiumFailure(code: .invalidRequest) }
    self.maximumInputBytes = maximumInputBytes
    self.maximumPages = maximumPages
    self.maximumSentences = maximumSentences
    self.maximumSentenceBytes = maximumSentenceBytes
    self.maximumTextBytes = maximumTextBytes
    self.maximumQuadsPerSentence = maximumQuadsPerSentence
    self.maximumQuads = maximumQuads
    self.maximumBatchSentences = maximumBatchSentences
    self.maximumBatchBytes = maximumBatchBytes
    self.maximumResidentBytes = maximumResidentBytes
  }
  public required convenience init?(coder c: NSCoder) {
    guard let i = PDFiumCoding.int64(c, "input"), let p = PDFiumCoding.integer(c, "pages"),
      let s = PDFiumCoding.integer(c, "sentences"),
      let sb = PDFiumCoding.integer(c, "sentenceBytes"),
      let t = PDFiumCoding.integer(c, "textBytes"),
      let qs = PDFiumCoding.integer(c, "quadsPerSentence"),
      let q = PDFiumCoding.integer(c, "quads"), let bs = PDFiumCoding.integer(c, "batchSentences"),
      let bb = PDFiumCoding.integer(c, "batchBytes"), let r = PDFiumCoding.uint64(c, "resident")
    else { return nil }
    do {
      try self.init(
        maximumInputBytes: i, maximumPages: p, maximumSentences: s,
        maximumSentenceBytes: sb, maximumTextBytes: t, maximumQuadsPerSentence: qs,
        maximumQuads: q, maximumBatchSentences: bs, maximumBatchBytes: bb, maximumResidentBytes: r)
    } catch { return nil }
  }
  public func encode(with c: NSCoder) {
    c.encode(maximumInputBytes, forKey: "input")
    c.encode(maximumPages, forKey: "pages")
    c.encode(maximumSentences, forKey: "sentences")
    c.encode(maximumSentenceBytes, forKey: "sentenceBytes")
    c.encode(maximumTextBytes, forKey: "textBytes")
    c.encode(maximumQuadsPerSentence, forKey: "quadsPerSentence")
    c.encode(maximumQuads, forKey: "quads")
    c.encode(maximumBatchSentences, forKey: "batchSentences")
    c.encode(maximumBatchBytes, forKey: "batchBytes")
    c.encode(Int64(bitPattern: maximumResidentBytes), forKey: "resident")
  }
}

@objc(PaperLensPDFiumExtractionRequest)
public final class PDFiumExtractionRequest: NSObject, NSSecureCoding, @unchecked Sendable {
  public static var supportsSecureCoding: Bool { true }
  public let key: PDFiumExtractionKey
  public let pdfByteCount: Int64
  public let limits: PDFiumExtractionLimits
  public let deadlineUptimeNanoseconds: UInt64
  public init(
    key: PDFiumExtractionKey, pdfByteCount: Int64, limits: PDFiumExtractionLimits,
    deadlineUptimeNanoseconds: UInt64
  ) throws {
    guard pdfByteCount > 0, pdfByteCount <= limits.maximumInputBytes,
      deadlineUptimeNanoseconds > 0, let keyBytes = key.payloadBytes,
      keyBytes <= limits.maximumBatchBytes
    else { throw PDFiumFailure(code: .invalidRequest) }
    self.key = key
    self.pdfByteCount = pdfByteCount
    self.limits = limits
    self.deadlineUptimeNanoseconds = deadlineUptimeNanoseconds
  }
  public required convenience init?(coder c: NSCoder) {
    guard let k = c.decodeObject(of: PDFiumExtractionKey.self, forKey: "key"),
      let b = PDFiumCoding.int64(c, "bytes"),
      let l = c.decodeObject(of: PDFiumExtractionLimits.self, forKey: "limits"),
      let d = PDFiumCoding.uint64(c, "deadline")
    else { return nil }
    do { try self.init(key: k, pdfByteCount: b, limits: l, deadlineUptimeNanoseconds: d) } catch {
      return nil
    }
  }
  public func encode(with c: NSCoder) {
    c.encode(key, forKey: "key")
    c.encode(pdfByteCount, forKey: "bytes")
    c.encode(limits, forKey: "limits")
    c.encode(Int64(bitPattern: deadlineUptimeNanoseconds), forKey: "deadline")
  }
}

@objc(PaperLensPDFiumStartAck)
public final class PDFiumStartAck: NSObject, NSSecureCoding, @unchecked Sendable {
  public static var supportsSecureCoding: Bool { true }
  public let key: PDFiumExtractionKey
  public let workerPID: Int32
  public let observedPDFSHA256: String
  public let observedPDFByteCount: Int64
  public let documentPageCount: Int
  public init(
    key: PDFiumExtractionKey, workerPID: Int32, observedPDFSHA256: String,
    observedPDFByteCount: Int64, documentPageCount: Int
  ) throws {
    guard workerPID > 0, PDFiumCoding.hash(observedPDFSHA256), observedPDFByteCount > 0,
      documentPageCount > 0
    else { throw PDFiumFailure(code: .invalidRequest) }
    self.key = key
    self.workerPID = workerPID
    self.observedPDFSHA256 = observedPDFSHA256
    self.observedPDFByteCount = observedPDFByteCount
    self.documentPageCount = documentPageCount
  }
  public required convenience init?(coder c: NSCoder) {
    guard let k = c.decodeObject(of: PDFiumExtractionKey.self, forKey: "key"),
      let p = PDFiumCoding.integer(c, "pid"), let pid = Int32(exactly: p),
      let h = PDFiumCoding.string(c, "hash"), let b = PDFiumCoding.int64(c, "bytes"),
      let pages = PDFiumCoding.integer(c, "pages")
    else { return nil }
    do {
      try self.init(
        key: k, workerPID: pid, observedPDFSHA256: h,
        observedPDFByteCount: b, documentPageCount: pages)
    } catch { return nil }
  }
  public func encode(with c: NSCoder) {
    c.encode(key, forKey: "key")
    c.encode(Int(workerPID), forKey: "pid")
    c.encode(observedPDFSHA256 as NSString, forKey: "hash")
    c.encode(observedPDFByteCount, forKey: "bytes")
    c.encode(documentPageCount, forKey: "pages")
  }
}

/// Native-space observations. Presence records are explicit; absent boxes are not guessed.
@objc(PaperLensPDFiumRawQuad)
public final class PDFiumRawQuad: NSObject, NSSecureCoding, @unchecked Sendable {
  public static var supportsSecureCoding: Bool { true }
  public let topLeftX: Double
  public let topLeftY: Double
  public let topRightX: Double
  public let topRightY: Double
  public let bottomRightX: Double
  public let bottomRightY: Double
  public let bottomLeftX: Double
  public let bottomLeftY: Double
  public var coordinates: [Double] {
    [
      topLeftX, topLeftY, topRightX, topRightY, bottomRightX, bottomRightY, bottomLeftX,
      bottomLeftY,
    ]
  }
  public init(
    topLeftX: Double, topLeftY: Double, topRightX: Double, topRightY: Double,
    bottomRightX: Double, bottomRightY: Double, bottomLeftX: Double, bottomLeftY: Double
  ) throws {
    guard
      [
        topLeftX, topLeftY, topRightX, topRightY, bottomRightX, bottomRightY, bottomLeftX,
        bottomLeftY,
      ]
      .allSatisfy(\.isFinite)
    else { throw PDFiumFailure(code: .unsupportedGeometry) }
    let points = [
      (topLeftX, topLeftY), (topRightX, topRightY),
      (bottomRightX, bottomRightY), (bottomLeftX, bottomLeftY),
    ]
    for index in 0..<points.count {
      let a = points[index]
      let b = points[(index + 1) % points.count]
      let c = points[(index + 2) % points.count]
      let cross = (b.0 - a.0) * (c.1 - b.1) - (b.1 - a.1) * (c.0 - b.0)
      guard cross.isFinite, cross < 0 else { throw PDFiumFailure(code: .unsupportedGeometry) }
    }
    self.topLeftX = topLeftX
    self.topLeftY = topLeftY
    self.topRightX = topRightX
    self.topRightY = topRightY
    self.bottomRightX = bottomRightX
    self.bottomRightY = bottomRightY
    self.bottomLeftX = bottomLeftX
    self.bottomLeftY = bottomLeftY
  }
  public required convenience init?(coder c: NSCoder) {
    guard let a = PDFiumCoding.number(c, "x0"), let b = PDFiumCoding.number(c, "y0"),
      let d = PDFiumCoding.number(c, "x1"), let e = PDFiumCoding.number(c, "y1"),
      let f = PDFiumCoding.number(c, "x2"), let g = PDFiumCoding.number(c, "y2"),
      let h = PDFiumCoding.number(c, "x3"), let i = PDFiumCoding.number(c, "y3")
    else { return nil }
    do {
      try self.init(
        topLeftX: a, topLeftY: b, topRightX: d, topRightY: e,
        bottomRightX: f, bottomRightY: g, bottomLeftX: h, bottomLeftY: i)
    } catch { return nil }
  }
  public func encode(with c: NSCoder) {
    c.encode(topLeftX, forKey: "x0")
    c.encode(topLeftY, forKey: "y0")
    c.encode(topRightX, forKey: "x1")
    c.encode(topRightY, forKey: "y1")
    c.encode(bottomRightX, forKey: "x2")
    c.encode(bottomRightY, forKey: "y2")
    c.encode(bottomLeftX, forKey: "x3")
    c.encode(bottomLeftY, forKey: "y3")
  }
}

@objc(PaperLensPDFiumRawPage)
public final class PDFiumRawPage: NSObject, NSSecureCoding, @unchecked Sendable {
  public static var supportsSecureCoding: Bool { true }
  public let pageIndex: Int
  public let boundingBox: PDFiumRawQuad
  public let mediaBox: PDFiumRawQuad?
  public let cropBox: PDFiumRawQuad?
  public let rotationQuarterTurns: Int
  /// Typed field payload, excluding Foundation/XPC implementation overhead.
  public var payloadBytes: Int {
    2 * MemoryLayout<Int64>.size + 2 * MemoryLayout<Bool>.size
      + (1 + (mediaBox == nil ? 0 : 1) + (cropBox == nil ? 0 : 1)) * 8 * MemoryLayout<Double>.size
  }
  // Provenance is fixed by this DTO, not a sender-defined label.
  public static let boundingBoxAPI = "FPDF_GetPageBoundingBox"
  public static let mediaBoxAPI = "FPDFPage_GetMediaBox"
  public static let cropBoxAPI = "FPDFPage_GetCropBox"
  public init(
    pageIndex: Int, boundingBox: PDFiumRawQuad, mediaBox: PDFiumRawQuad?,
    cropBox: PDFiumRawQuad?, rotationQuarterTurns: Int
  ) throws {
    guard pageIndex >= 0, (0...3).contains(rotationQuarterTurns) else {
      throw PDFiumFailure(code: .unsupportedGeometry)
    }
    self.pageIndex = pageIndex
    self.boundingBox = boundingBox
    self.mediaBox = mediaBox
    self.cropBox = cropBox
    self.rotationQuarterTurns = rotationQuarterTurns
  }
  public required convenience init?(coder c: NSCoder) {
    guard let p = PDFiumCoding.integer(c, "page"), let r = PDFiumCoding.integer(c, "rotation"),
      let b = c.decodeObject(of: PDFiumRawQuad.self, forKey: "bounding"),
      let hm = PDFiumCoding.bool(c, "hasMedia"), let hc = PDFiumCoding.bool(c, "hasCrop")
    else { return nil }
    let m = c.decodeObject(of: PDFiumRawQuad.self, forKey: "media")
    let crop = c.decodeObject(of: PDFiumRawQuad.self, forKey: "crop")
    guard hm == (m != nil), hc == (crop != nil) else { return nil }
    do {
      try self.init(
        pageIndex: p, boundingBox: b, mediaBox: m, cropBox: crop, rotationQuarterTurns: r)
    } catch { return nil }
  }
  public func encode(with c: NSCoder) {
    c.encode(pageIndex, forKey: "page")
    c.encode(rotationQuarterTurns, forKey: "rotation")
    c.encode(boundingBox, forKey: "bounding")
    c.encode(mediaBox != nil, forKey: "hasMedia")
    c.encode(cropBox != nil, forKey: "hasCrop")
    if let m = mediaBox { c.encode(m, forKey: "media") }
    if let crop = cropBox { c.encode(crop, forKey: "crop") }
  }
}

@objc(PaperLensPDFiumGlyph)
public final class PDFiumGlyph: NSObject, NSSecureCoding, @unchecked Sendable {
  public static var supportsSecureCoding: Bool { true }
  public let nativeCharacterIndex: Int
  public let unicodeScalar: UInt32
  public let utf16Start: Int
  public let utf16Length: Int
  public let generated: Bool
  public let matrixA: Double
  public let matrixB: Double
  public let matrixC: Double
  public let matrixD: Double
  public let matrixE: Double
  public let matrixF: Double
  public let rawQuad: PDFiumRawQuad?
  public var payloadBytes: Int {
    3 * MemoryLayout<Int64>.size + MemoryLayout<UInt32>.size + 2 * MemoryLayout<Bool>.size
      + 6 * MemoryLayout<Double>.size + (rawQuad == nil ? 0 : 8 * MemoryLayout<Double>.size)
  }
  public init(
    nativeCharacterIndex: Int, unicodeScalar: UInt32, utf16Start: Int, utf16Length: Int,
    generated: Bool, matrixA: Double, matrixB: Double, matrixC: Double, matrixD: Double,
    matrixE: Double, matrixF: Double, rawQuad: PDFiumRawQuad?
  ) throws {
    guard let scalar = Unicode.Scalar(unicodeScalar), unicodeScalar != 0,
      nativeCharacterIndex >= 0, utf16Start >= 0,
      utf16Length == String(scalar).utf16.count,
      [matrixA, matrixB, matrixC, matrixD, matrixE, matrixF].allSatisfy(\.isFinite),
      rawQuad != nil || CharacterSet.whitespacesAndNewlines.contains(scalar)
    else {
      throw PDFiumFailure(code: .unmappableText)
    }
    self.nativeCharacterIndex = nativeCharacterIndex
    self.unicodeScalar = unicodeScalar
    self.utf16Start = utf16Start
    self.utf16Length = utf16Length
    self.generated = generated
    self.matrixA = matrixA
    self.matrixB = matrixB
    self.matrixC = matrixC
    self.matrixD = matrixD
    self.matrixE = matrixE
    self.matrixF = matrixF
    self.rawQuad = rawQuad
  }
  public required convenience init?(coder c: NSCoder) {
    guard let n = PDFiumCoding.integer(c, "native"), let u = PDFiumCoding.int64(c, "unicode"),
      let scalar = UInt32(exactly: u), let s = PDFiumCoding.integer(c, "start"),
      let l = PDFiumCoding.integer(c, "length"), let g = PDFiumCoding.bool(c, "generated"),
      let a = PDFiumCoding.number(c, "a"), let b = PDFiumCoding.number(c, "b"),
      let cc = PDFiumCoding.number(c, "c"), let d = PDFiumCoding.number(c, "d"),
      let e = PDFiumCoding.number(c, "e"), let f = PDFiumCoding.number(c, "f"),
      let hq = PDFiumCoding.bool(c, "hasQuad")
    else { return nil }
    let q = c.decodeObject(of: PDFiumRawQuad.self, forKey: "quad")
    guard hq == (q != nil) else { return nil }
    do {
      try self.init(
        nativeCharacterIndex: n, unicodeScalar: scalar, utf16Start: s, utf16Length: l,
        generated: g, matrixA: a, matrixB: b, matrixC: cc, matrixD: d, matrixE: e, matrixF: f,
        rawQuad: q)
    } catch { return nil }
  }
  public func encode(with c: NSCoder) {
    c.encode(nativeCharacterIndex, forKey: "native")
    c.encode(Int64(unicodeScalar), forKey: "unicode")
    c.encode(utf16Start, forKey: "start")
    c.encode(utf16Length, forKey: "length")
    c.encode(generated, forKey: "generated")
    c.encode(matrixA, forKey: "a")
    c.encode(matrixB, forKey: "b")
    c.encode(matrixC, forKey: "c")
    c.encode(matrixD, forKey: "d")
    c.encode(matrixE, forKey: "e")
    c.encode(matrixF, forKey: "f")
    c.encode(rawQuad != nil, forKey: "hasQuad")
    if let q = rawQuad { c.encode(q, forKey: "quad") }
  }
}

@objc(PaperLensPDFiumSentence)
public final class PDFiumSentence: NSObject, NSSecureCoding, @unchecked Sendable {
  public static var supportsSecureCoding: Bool { true }
  public let paperID: UUID
  public let revision: UUID
  public let pdfSHA256: String
  public let pageIndex: Int
  public let sentenceID: Int
  public let text: String
  public let nativeStartCharacter: Int
  public let nativeCharacterCount: Int
  public let sourceUTF16Start: Int
  public let sourceUTF16Length: Int
  public let glyphs: [PDFiumGlyph]
  public init(
    paperID: UUID, revision: UUID, pdfSHA256: String, pageIndex: Int, sentenceID: Int,
    text: String, nativeStartCharacter: Int, nativeCharacterCount: Int,
    sourceUTF16Start: Int, sourceUTF16Length: Int, glyphs: [PDFiumGlyph]
  ) throws {
    guard PDFiumCoding.hash(pdfSHA256), PDFiumCoding.uuidV4(paperID), PDFiumCoding.uuidV4(revision),
      pageIndex >= 0, sentenceID >= 0, !text.isEmpty,
      nativeStartCharacter >= 0, nativeCharacterCount > 0, sourceUTF16Start >= 0,
      nativeStartCharacter <= Int.max - nativeCharacterCount,
      sourceUTF16Length == text.utf16.count, glyphs.count == nativeCharacterCount
    else {
      throw PDFiumFailure(code: .unmappableText)
    }
    var position = sourceUTF16Start
    var reconstructed = String.UnicodeScalarView()
    for (i, glyph) in glyphs.enumerated() {
      guard glyph.nativeCharacterIndex == nativeStartCharacter + i,
        glyph.utf16Start == position, let scalar = Unicode.Scalar(glyph.unicodeScalar),
        position <= Int.max - glyph.utf16Length
      else { throw PDFiumFailure(code: .unmappableText) }
      position += glyph.utf16Length
      reconstructed.append(scalar)
    }
    guard position - sourceUTF16Start == sourceUTF16Length,
      String(reconstructed).utf8.elementsEqual(text.utf8)
    else { throw PDFiumFailure(code: .unmappableText) }
    self.paperID = paperID
    self.revision = revision
    self.pdfSHA256 = pdfSHA256
    self.pageIndex = pageIndex
    self.sentenceID = sentenceID
    self.text = text
    self.nativeStartCharacter = nativeStartCharacter
    self.nativeCharacterCount = nativeCharacterCount
    self.sourceUTF16Start = sourceUTF16Start
    self.sourceUTF16Length = sourceUTF16Length
    self.glyphs = glyphs
  }
  public required convenience init?(coder c: NSCoder) {
    guard let p = PDFiumCoding.uuid(c, "paper"), let r = PDFiumCoding.uuid(c, "revision"),
      let h = PDFiumCoding.string(c, "hash"), let pg = PDFiumCoding.integer(c, "page"),
      let id = PDFiumCoding.integer(c, "sentence"), let t = PDFiumCoding.string(c, "text"),
      let n = PDFiumCoding.integer(c, "nativeStart"),
      let nc = PDFiumCoding.integer(c, "nativeCount"),
      let s = PDFiumCoding.integer(c, "sourceStart"),
      let l = PDFiumCoding.integer(c, "sourceLength"),
      let glyphs = c.decodeObject(
        of: [NSArray.self, PDFiumGlyph.self, PDFiumRawQuad.self], forKey: "glyphs")
        as? [PDFiumGlyph]
    else { return nil }
    do {
      try self.init(
        paperID: p, revision: r, pdfSHA256: h, pageIndex: pg, sentenceID: id, text: t,
        nativeStartCharacter: n, nativeCharacterCount: nc, sourceUTF16Start: s,
        sourceUTF16Length: l, glyphs: glyphs)
    } catch { return nil }
  }
  public func encode(with c: NSCoder) {
    c.encode(paperID as NSUUID, forKey: "paper")
    c.encode(revision as NSUUID, forKey: "revision")
    c.encode(pdfSHA256 as NSString, forKey: "hash")
    c.encode(pageIndex, forKey: "page")
    c.encode(sentenceID, forKey: "sentence")
    c.encode(text as NSString, forKey: "text")
    c.encode(nativeStartCharacter, forKey: "nativeStart")
    c.encode(nativeCharacterCount, forKey: "nativeCount")
    c.encode(sourceUTF16Start, forKey: "sourceStart")
    c.encode(sourceUTF16Length, forKey: "sourceLength")
    c.encode(glyphs as NSArray, forKey: "glyphs")
  }
  /// Checked exact field payload accounting. Foundation/XPC allocation and
  /// serialization overhead are NOT certified by this logical byte count.
  public var payloadBytes: Int? {
    var size = 2 * MemoryLayout<uuid_t>.size + 6 * MemoryLayout<Int64>.size + pdfSHA256.utf8.count
    let textSize = size.addingReportingOverflow(text.utf8.count)
    guard !textSize.overflow else { return nil }
    size = textSize.partialValue
    for glyph in glyphs {
      let next = size.addingReportingOverflow(glyph.payloadBytes)
      guard !next.overflow else { return nil }
      size = next.partialValue
    }
    return size
  }
}

@objc(PaperLensPDFiumBatch)
public final class PDFiumBatch: NSObject, NSSecureCoding, @unchecked Sendable {
  public static var supportsSecureCoding: Bool { true }
  public let key: PDFiumExtractionKey
  public let sequence: Int
  public let pages: [PDFiumRawPage]
  public let sentences: [PDFiumSentence]
  public let complete: Bool
  public let totalSentences: Int?
  public static func maximumEnvelopePayloadBytes(key: PDFiumExtractionKey) -> Int? {
    guard let bytes = key.payloadBytes else { return nil }
    let total = bytes.addingReportingOverflow(
      4 * MemoryLayout<Int64>.size + 2 * MemoryLayout<Bool>.size)
    return total.overflow ? nil : total.partialValue
  }
  public init(
    key: PDFiumExtractionKey, sequence: Int, pages: [PDFiumRawPage],
    sentences: [PDFiumSentence], complete: Bool, totalSentences: Int?
  ) throws {
    guard sequence >= 0, !sentences.isEmpty, complete == (totalSentences != nil),
      totalSentences.map({ $0 >= sentences.count }) ?? true,
      Set(pages.map(\.pageIndex)).count == pages.count
    else { throw PDFiumFailure(code: .protocolViolation) }
    self.key = key
    self.sequence = sequence
    self.pages = pages
    self.sentences = sentences
    self.complete = complete
    self.totalSentences = totalSentences
  }
  public required convenience init?(coder c: NSCoder) {
    guard let k = c.decodeObject(of: PDFiumExtractionKey.self, forKey: "key"),
      let s = PDFiumCoding.integer(c, "sequence"), let done = PDFiumCoding.bool(c, "complete"),
      let p = c.decodeObject(
        of: [NSArray.self, PDFiumRawPage.self, PDFiumRawQuad.self], forKey: "pages")
        as? [PDFiumRawPage],
      let sentences = c.decodeObject(
        of: [
          NSArray.self, PDFiumSentence.self, PDFiumGlyph.self, PDFiumRawQuad.self,
          NSUUID.self, NSString.self,
        ], forKey: "sentences") as? [PDFiumSentence]
    else { return nil }
    let total = done ? PDFiumCoding.integer(c, "total") : nil
    guard done || !c.containsValue(forKey: "total") else { return nil }
    do {
      try self.init(
        key: k, sequence: s, pages: p, sentences: sentences, complete: done, totalSentences: total)
    } catch { return nil }
  }
  public func encode(with c: NSCoder) {
    c.encode(key, forKey: "key")
    c.encode(sequence, forKey: "sequence")
    c.encode(pages as NSArray, forKey: "pages")
    c.encode(sentences as NSArray, forKey: "sentences")
    c.encode(complete, forKey: "complete")
    if let t = totalSentences { c.encode(t, forKey: "total") }
  }
}

public enum PDFiumEndDisposition: Int, Sendable { case completed, cancelled, failed }
@objc(PaperLensPDFiumEnd)
public final class PDFiumEnd: NSObject, NSSecureCoding, @unchecked Sendable {
  public static var supportsSecureCoding: Bool { true }
  public let key: PDFiumExtractionKey
  public let disposition: PDFiumEndDisposition
  public let lastSequence: Int
  public let totalSentences: Int
  public let processedPageCount: Int
  public let documentPageCount: Int
  public let observedPDFSHA256: String
  public init(
    key: PDFiumExtractionKey, disposition: PDFiumEndDisposition, lastSequence: Int,
    totalSentences: Int, processedPageCount: Int, documentPageCount: Int, observedPDFSHA256: String
  ) throws {
    guard lastSequence >= -1, totalSentences >= 0, processedPageCount >= 0,
      documentPageCount >= processedPageCount, PDFiumCoding.hash(observedPDFSHA256),
      disposition != .completed
        || (totalSentences > 0 && processedPageCount == documentPageCount && lastSequence >= 0)
    else { throw PDFiumFailure(code: .protocolViolation) }
    self.key = key
    self.disposition = disposition
    self.lastSequence = lastSequence
    self.totalSentences = totalSentences
    self.processedPageCount = processedPageCount
    self.documentPageCount = documentPageCount
    self.observedPDFSHA256 = observedPDFSHA256
  }
  public required convenience init?(coder c: NSCoder) {
    guard let k = c.decodeObject(of: PDFiumExtractionKey.self, forKey: "key"),
      let d = PDFiumCoding.integer(c, "disposition"),
      let disposition = PDFiumEndDisposition(rawValue: d),
      let s = PDFiumCoding.integer(c, "sequence"), let t = PDFiumCoding.integer(c, "total"),
      let p = PDFiumCoding.integer(c, "processed"), let pc = PDFiumCoding.integer(c, "pages"),
      let h = PDFiumCoding.string(c, "hash")
    else { return nil }
    do {
      try self.init(
        key: k, disposition: disposition, lastSequence: s, totalSentences: t,
        processedPageCount: p, documentPageCount: pc, observedPDFSHA256: h)
    } catch { return nil }
  }
  public func encode(with c: NSCoder) {
    c.encode(key, forKey: "key")
    c.encode(disposition.rawValue, forKey: "disposition")
    c.encode(lastSequence, forKey: "sequence")
    c.encode(totalSentences, forKey: "total")
    c.encode(processedPageCount, forKey: "processed")
    c.encode(documentPageCount, forKey: "pages")
    c.encode(observedPDFSHA256 as NSString, forKey: "hash")
  }
}

public enum PDFiumExtractionInterface {
  public static func make() -> NSXPCInterface {
    let interface = NSXPCInterface(with: PDFiumExtractionService.self)
    let classes = NSSet(array: [
      PDFiumExtractionRequest.self, PDFiumExtractionKey.self,
      PDFiumExtractionLimits.self, PDFiumStartAck.self, PDFiumBatch.self, PDFiumEnd.self,
      PDFiumFailure.self, PDFiumRawPage.self, PDFiumSentence.self, PDFiumGlyph.self,
      PDFiumRawQuad.self, NSArray.self, NSString.self, NSUUID.self, NSNumber.self,
    ])
    let begin = #selector(PDFiumExtractionService.beginExtraction(_:pdf:withReply:))
    let next = #selector(PDFiumExtractionService.nextExtractionBatch(_:sequence:withReply:))
    let cancel = #selector(PDFiumExtractionService.cancelExtractionAndDrain(_:withReply:))
    interface.setClasses(classes as! Set<AnyHashable>, for: begin, argumentIndex: 0, ofReply: false)
    interface.setClasses(
      NSSet(array: [FileHandle.self]) as! Set<AnyHashable>, for: begin, argumentIndex: 1,
      ofReply: false)
    for (selector, count) in [(begin, 2), (next, 3), (cancel, 2)] {
      for index in 0..<count {
        interface.setClasses(
          classes as! Set<AnyHashable>, for: selector, argumentIndex: index, ofReply: true)
      }
    }
    for selector in [next, cancel] {
      interface.setClasses(
        NSSet(array: [NSUUID.self]) as! Set<AnyHashable>, for: selector, argumentIndex: 0,
        ofReply: false)
    }
    return interface
  }
}

enum TopologyIdentity {
  static let main = "io.github.jinzer0.PaperLens"
  static let worker = main + ".PDFiumXPC"
  static let agent = main + ".ProviderAgent"
  static let groupOwner = main + ".TopologyFixtureOwner"
  static let group = "397452Z366." + main + ".TopologyFixture"

  static func requirement(_ identifier: String) -> String {
    "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"397452Z366\" and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
  }

  // Only OS account metadata selects the profile; sandbox HOME is not the
  // account home. Invalid metadata must not produce a fallback fixture path.
  static func accountHome() -> URL? {
    let uid = getuid()
    guard uid >= 500, geteuid() == uid,
      let entry = getpwuid(uid), entry.pointee.pw_uid == uid,
      let directory = entry.pointee.pw_dir,
      let path = String(validatingCString: directory), path.hasPrefix("/"), path != "/"
    else { return nil }
    let home = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    var info = stat()
    guard home.path == path, home.resolvingSymlinksInPath() == home,
      lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == uid
    else { return nil }
    return home
  }

  // Check the bundle identity and actual sandbox container against the same
  // OS-derived account home, never using sandbox HOME to select the profile.
  static func container(_ identifier: String) -> URL? {
    guard Bundle.main.bundleIdentifier == identifier, let home = accountHome()
    else { return nil }
    let expected =
      home
      .appendingPathComponent("Library/Containers/\(identifier)/Data", isDirectory: true)
    let actual = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).standardizedFileURL
    var info = stat()
    guard actual == expected.standardizedFileURL,
      actual.resolvingSymlinksInPath() == actual,
      lstat(actual.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR
    else { return nil }
    return actual
  }
}

enum TopologyFixtures {
  static var home: String? { TopologyIdentity.accountHome()?.path }
  static var groupRoot: String? {
    guard let home else { return nil }
    return home + "/Library/Group Containers/" + TopologyIdentity.group
  }
  static let aliases = ["M", "A", "C", "E", "G", "PDF"]
  static let nonce = Data("PaperLensTopology\n".utf8)
  private static let syntheticPDF: Data = {
    var bytes = Data("%PDF-1.4\n".utf8)
    let objects = [
      "<< /Type /Catalog /Pages 2 0 R >>",
      "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
      "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 72 72] /Resources << >> >>",
    ]
    var offsets: [Int] = []
    for (index, object) in objects.enumerated() {
      offsets.append(bytes.count)
      bytes.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8))
    }
    let xref = bytes.count
    bytes.append(Data("xref\n0 4\n0000000000 65535 f \n".utf8))
    for offset in offsets {
      bytes.append(Data(String(format: "%010ld 00000 n \n", offset).utf8))
    }
    bytes.append(Data("trailer\n<< /Size 4 /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
    return bytes
  }()

  static func validRunID(_ value: String) -> Bool {
    guard let uuid = UUID(uuidString: value), uuid.uuidString.lowercased() == value else {
      return false
    }
    let chars = Array(value)
    return chars[14] == "4" && "89ab".contains(chars[19])
  }

  static func profileMatches(_ identifier: String) -> Bool {
    guard groupMapMatches(), let home, let root = TopologyIdentity.container(identifier)
    else { return false }
    return root.path == home + "/Library/Containers/\(identifier)/Data"
  }

  static func groupMapMatches() -> Bool {
    guard let url = Bundle.main.url(forResource: "fixture-map", withExtension: "json"),
      let bytes = try? Data(contentsOf: url), bytes.count <= 4096,
      let map = try? JSONSerialization.jsonObject(with: bytes) as? [String: String]
    else { return false }
    return map == ["profile": "current-user", "groupID": TopologyIdentity.group]
  }

  static func path(_ alias: String, runID: String) -> String? {
    guard validRunID(runID), groupMapMatches(), let home else { return nil }
    let main = home + "/Library/Containers/" + TopologyIdentity.main + "/Data"
    let agent = home + "/Library/Containers/" + TopologyIdentity.agent + "/Data"
    switch alias {
    case "M": return main + "/Library/Application Support/PaperLensTopology/\(runID)/db.canary"
    case "PDF": return main + "/Library/Application Support/PaperLensTopology/\(runID)/input.pdf"
    case "A": return agent + "/Library/Application Support/PaperLensTopology/\(runID)/secret.canary"
    case "C": return agent + "/Library/Caches/PaperLensTopology/\(runID)/cache.canary"
    case "E":
      return home
        + "/Library/Application Support/PaperLensTopologyFixtureHost/\(runID)/external.canary"
    case "G":
      guard let groupRoot else { return nil }
      return groupRoot + "/PaperLensTopology/\(runID)/group.canary"
    default: return nil
    }
  }

  static func marker(_ alias: String, runID: String) -> Data {
    alias == "PDF" ? syntheticPDF : Data("PaperLens topology canary\n".utf8)
  }

  static func publishReport(_ report: Data, directory: Int32) -> Bool {
    let temporary = UUID().uuidString.lowercased() + ".report"
    let fd = openat(
      directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { return false }
    var owned = stat()
    guard privateFile(fd, info: &owned) else {
      removeOwned(directory: directory, name: temporary, info: owned)
      close(fd)
      return false
    }
    defer {
      close(fd)
      removeOwned(directory: directory, name: temporary, info: owned)
    }
    guard writeAll(report, descriptor: fd), sync(fd),
      matches(directory: directory, name: temporary, info: owned),
      privateFile(fd, info: &owned)
    else { return false }
    // Publication cannot replace a prior report, even if it races the verifier.
    return renameatx_np(directory, temporary, directory, "report.json", UInt32(RENAME_EXCL)) == 0
  }

  static func writeAll(_ data: Data, descriptor: Int32) -> Bool {
    data.withUnsafeBytes { bytes -> Bool in
      var offset = 0
      while offset < bytes.count {
        let count = Darwin.write(
          descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else { return false }
        offset += count
      }
      return true
    }
  }

  static func sync(_ descriptor: Int32) -> Bool {
    while fsync(descriptor) != 0 {
      if errno != EINTR { return false }
    }
    return true
  }

  static func emptyACL(_ descriptor: Int32) -> Bool {
    guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
      return errno == ENOENT
    }
    return emptyACLValue(acl)
  }

  private static func emptyACLValue(_ acl: acl_t) -> Bool {
    defer { acl_free(UnsafeMutableRawPointer(acl)) }
    var entry: acl_entry_t?
    errno = 0
    let result = acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry)
    return result == -1 && errno == EINVAL
  }

  static func privateDirectory(_ descriptor: Int32, info: inout stat) -> Bool {
    fstat(descriptor, &info) == 0 && info.st_uid == getuid()
      && info.st_mode & S_IFMT == S_IFDIR && info.st_mode & 0o7777 == 0o700
      && info.st_nlink >= 2 && emptyACL(descriptor)
  }

  static func privateFile(_ descriptor: Int32, info: inout stat) -> Bool {
    fstat(descriptor, &info) == 0 && privateFileIdentity(info) && emptyACL(descriptor)
  }

  private static func privateFileIdentity(_ info: stat) -> Bool {
    info.st_uid == getuid() && info.st_mode & S_IFMT == S_IFREG
      && info.st_mode & 0o7777 == 0o600 && info.st_nlink == 1
  }

  // Do not open/close an auxiliary DB or SHM descriptor while SQLite is live:
  // closing another descriptor can release process-owned POSIX file locks.
  // ACL lookup is the public no-follow named metadata API. The caller must
  // validate its retained namespace/path before and after these checks.
  static func privateNamedFile(
    directory: Int32, name: String, path: String,
    info: inout stat
  ) -> Bool {
    guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
      privateFileIdentity(info)
    else { return false }
    guard let acl = acl_get_link_np(path, ACL_TYPE_EXTENDED) else { return errno == ENOENT }
    return emptyACLValue(acl)
  }

  static func matches(directory: Int32, name: String, info: stat) -> Bool {
    var current = stat()
    return fstatat(directory, name, &current, AT_SYMLINK_NOFOLLOW) == 0
      && current.st_dev == info.st_dev && current.st_ino == info.st_ino
      && current.st_mode & S_IFMT == info.st_mode & S_IFMT
  }

  @discardableResult static func removeOwned(directory: Int32, name: String, info: stat) -> Bool {
    guard matches(directory: directory, name: name, info: info) else { return false }
    return unlinkat(directory, name, 0) == 0
  }

  // Walk with directory descriptors: neither a pre-existing symlink nor a
  // concurrently replaced ancestor may redirect creation into user files.
  static func directory(_ url: URL, create: Bool) -> Int32? {
    guard url.isFileURL, url.path.hasPrefix("/") else { return nil }
    var fd = open("/", O_SEARCH | O_CLOEXEC | O_NOFOLLOW)
    guard fd >= 0 else { return nil }
    for part in url.pathComponents.dropFirst() {
      // Ancestors need search, not directory listing or write permission.
      // Try existing metadata first; create only a genuinely missing segment.
      var next = openat(fd, part, O_SEARCH | O_CLOEXEC | O_NOFOLLOW)
      if next < 0 && errno == ENOENT && create {
        if mkdirat(fd, part, 0o700) != 0 && errno != EEXIST {
          let failure = errno
          close(fd)
          errno = failure
          return nil
        }
        next = openat(fd, part, O_SEARCH | O_CLOEXEC | O_NOFOLLOW)
      }
      let failure = next < 0 ? errno : 0
      close(fd)
      guard next >= 0 else {
        errno = failure
        return nil
      }
      fd = next
    }
    return fd
  }

  static func observation(
    runID: String, actor: String, alias: String, operation: String,
    result: Int, error: Int32 = 0, matched: Bool = true,
    observed: Bool = false, beganAtNs: Int64 = 0, endedAtNs: Int64 = 0
  ) -> [String: Any] {
    let verdict: String
    if !observed || !matched || error == ENOENT {
      verdict = "blocked"
    } else if result >= 0 {
      verdict = "failed"
    }  // A forbidden operation succeeded.
    else {
      verdict = "inconclusive"
    }  // An errno is NOT OS sandbox attribution.
    return [
      "runID": runID, "caseID": actor + "." + alias + "." + operation,
      "fixtureID": alias, "actorInstanceRef": actor, "operation": operation,
      "ownerPre": "unverified", "ownerPost": "unverified",
      "sameUIDControl": "unverified", "expectedRootMatched": matched,
      "posixACLControl": "unverified", "syscallResult": observed ? result : 0,
      "errno": observed ? Int(error) : 0,
      "sandboxDenialRef": NSNull(), "promptObserved": "unverified", "verdict": verdict,
      "syscallObserved": observed, "beganAtNs": observed ? beganAtNs : Int64(0),
      "endedAtNs": observed ? endedAtNs : Int64(0),
      "intervalRef": actor + "." + alias + "." + operation,
    ]
  }

  static func probe(
    runID: String, actor: String, alias: String, operation: String,
    symlinkDirectory: Int32? = nil
  ) -> [String: Any] {
    guard ["read", "write", "symlinkRead"].contains(operation),
      let target = path(alias, runID: runID)
    else {
      return observation(
        runID: runID, actor: actor, alias: alias, operation: operation,
        result: -1, matched: false)
    }
    var fd: Int32 = -1
    var openError: Int32 = 0
    var verification: Int32 = -1
    var began: Int64 = 0
    var ended: Int64 = 0
    defer { if verification >= 0 { close(verification) } }
    if operation == "symlinkRead" {
      guard let directory = symlinkDirectory else {
        return observation(
          runID: runID, actor: actor, alias: alias, operation: operation,
          result: -1, matched: false)
      }
      let name = alias + ".link"
      var linkInfo = stat()
      var linkBytes = [UInt8](repeating: 0, count: 4096)
      let length = readlinkat(directory, name, &linkBytes, linkBytes.count)
      guard fstatat(directory, name, &linkInfo, AT_SYMLINK_NOFOLLOW) == 0,
        linkInfo.st_mode & S_IFMT == S_IFLNK, linkInfo.st_uid == getuid(),
        linkInfo.st_nlink == 1, length > 0,
        String(bytes: linkBytes.prefix(length), encoding: .utf8) == target
      else {
        return observation(
          runID: runID, actor: actor, alias: alias, operation: operation,
          result: -1, matched: false)
      }
      began = Int64(DispatchTime.now().uptimeNanoseconds)
      fd = openat(directory, name, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
      openError = fd < 0 ? errno : 0
      ended = Int64(DispatchTime.now().uptimeNanoseconds)
    } else {
      // Never create or truncate a target. All fixed-path ancestors are
      // opened without following symlinks; only our explicit link is followed.
      let url = URL(fileURLWithPath: target)
      guard let directory = directory(url.deletingLastPathComponent(), create: false) else {
        return observation(
          runID: runID, actor: actor, alias: alias, operation: operation,
          result: -1, error: errno)
      }
      defer { close(directory) }
      began = Int64(DispatchTime.now().uptimeNanoseconds)
      fd = openat(
        directory, url.lastPathComponent,
        (operation == "write" ? O_WRONLY : O_RDONLY) | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
      openError = fd < 0 ? errno : 0
      ended = Int64(DispatchTime.now().uptimeNanoseconds)
      if fd >= 0 && operation == "write" {
        verification = openat(
          directory, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
      }
    }
    guard fd >= 0 else {
      return observation(
        runID: runID, actor: actor, alias: alias, operation: operation,
        result: -1, error: openError, observed: true, beganAtNs: began, endedAtNs: ended)
    }
    defer { close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
      info.st_nlink == 1, info.st_size > 0, info.st_size <= 4096
    else {
      return observation(
        runID: runID, actor: actor, alias: alias, operation: operation,
        result: -1, matched: false)
    }
    if operation == "write" {
      let expected = marker(alias, runID: runID)
      var bytes = [UInt8](repeating: 0, count: expected.count)
      var verificationInfo = stat()
      // Probe write permission independently. If it unexpectedly succeeds,
      // verify the public marker through a second descriptor before writing
      // its first byte unchanged. Never mutate an unverified/replaced file.
      guard verification >= 0, fstat(verification, &verificationInfo) == 0,
        verificationInfo.st_ino == info.st_ino, verificationInfo.st_dev == info.st_dev,
        info.st_size == expected.count, pread(verification, &bytes, bytes.count, 0) == bytes.count,
        Data(bytes) == expected
      else {
        return observation(
          runID: runID, actor: actor, alias: alias, operation: operation,
          result: -1, matched: false)
      }
    }
    var byte = marker(alias, runID: runID).first!
    began = Int64(DispatchTime.now().uptimeNanoseconds)
    let result = operation == "write" ? pwrite(fd, &byte, 1, 0) : pread(fd, &byte, 1, 0)
    let code = result < 0 ? errno : 0
    ended = Int64(DispatchTime.now().uptimeNanoseconds)
    return observation(
      runID: runID, actor: actor, alias: alias, operation: operation,
      result: result, error: code, observed: true, beganAtNs: began, endedAtNs: ended)
  }

  static func network(runID: String, actor: String, expectAllowed: Bool) -> [String: Any] {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    var row = observation(
      runID: runID, actor: actor, alias: "network", operation: "connect",
      result: -1, error: fd < 0 ? errno : 0)
    guard fd >= 0 else { return row }
    defer { close(fd) }
    var noSignal: Int32 = 1
    guard
      setsockopt(
        fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal)))
        == 0,
      fcntl(fd, F_SETFL, O_NONBLOCK) >= 0
    else {
      return row
    }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = UInt16(18765).bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let start = DispatchTime.now().uptimeNanoseconds
    func wait(_ events: Int16) -> Bool {
      let elapsed = (DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
      guard elapsed < 2000 else { return false }
      var descriptor = pollfd(fd: fd, events: events, revents: 0)
      return poll(&descriptor, 1, Int32(2000 - elapsed)) > 0
    }
    let began = Int64(DispatchTime.now().uptimeNanoseconds)
    let result = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    let code: Int32 = result < 0 ? errno : 0
    let ended = Int64(DispatchTime.now().uptimeNanoseconds)
    var connected = result == 0
    if result < 0 && code == EINPROGRESS {
      if wait(Int16(POLLOUT)) {
        var size = socklen_t(MemoryLayout<Int32>.size)
        var socketError: Int32 = 0
        connected =
          getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &size) == 0
          && socketError == 0
      }
    }
    row = observation(
      runID: runID, actor: actor, alias: "network", operation: "connect",
      result: Int(result), error: code, observed: true, beganAtNs: began, endedAtNs: ended)
    if !expectAllowed && connected {
      // Preserve the original connect tuple, including EINPROGRESS, while
      // separately recording a completed forbidden connection as failure.
      row["verdict"] = "failed"
    }
    if expectAllowed && connected {
      var sent = 0
      while sent < nonce.count && wait(Int16(POLLOUT)) {
        let count = nonce.withUnsafeBytes {
          send(fd, $0.baseAddress!.advanced(by: sent), nonce.count - sent, 0)
        }
        guard count > 0 else { break }
        sent += count
      }
      var response = Data()
      while response.count < nonce.count && wait(Int16(POLLIN)) {
        var bytes = [UInt8](repeating: 0, count: nonce.count - response.count)
        let count = recv(fd, &bytes, bytes.count, 0)
        guard count > 0 else { break }
        response.append(contentsOf: bytes.prefix(count))
      }
      let echoed = sent == nonce.count && response == nonce
      row["echoMatched"] = echoed
      row["verdict"] = echoed ? "pass" : "inconclusive"
    }
    return row
  }

  static func json(_ value: [String: Any]) -> Data {
    // All callers construct closed, finite, path-free dictionaries.
    (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]))
      ?? Data("{\"status\":\"failed\"}".utf8)
  }
}

// A reservation never adopts or removes a prior namespace, including on failure.
final class TopologyReportReservation: @unchecked Sendable {
  let descriptor: Int32
  let directoryURL: URL
  private let root: Int32
  private let parent: Int32
  private let runID: String
  private let identity: stat
  private let parentIdentity: stat

  init?(container: URL, runID: String) {
    guard TopologyFixtures.validRunID(runID),
      let root = TopologyFixtures.directory(
        container.appendingPathComponent("Library/Application Support/PaperLensTopology"),
        create: true)
    else { return nil }
    if mkdirat(root, "Reports", 0o700) != 0 && errno != EEXIST {
      close(root)
      return nil
    }
    let parent = openat(root, "Reports", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard parent >= 0 else {
      close(root)
      return nil
    }
    var parentInfo = stat()
    guard TopologyFixtures.privateDirectory(parent, info: &parentInfo),
      TopologyFixtures.matches(directory: root, name: "Reports", info: parentInfo),
      mkdirat(parent, runID, 0o700) == 0
    else {
      close(parent)
      close(root)
      return nil
    }
    let descriptor = openat(parent, runID, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    var info = stat()
    guard descriptor >= 0, TopologyFixtures.privateDirectory(descriptor, info: &info),
      TopologyFixtures.matches(directory: parent, name: runID, info: info)
    else {
      if descriptor >= 0 { close(descriptor) }
      close(parent)
      close(root)
      return nil
    }
    self.descriptor = descriptor
    self.root = root
    self.parent = parent
    self.runID = runID
    identity = info
    parentIdentity = parentInfo
    directoryURL = container.appendingPathComponent(
      "Library/Application Support/PaperLensTopology/Reports/" + runID, isDirectory: true)
  }

  func publish(_ data: Data) -> Bool {
    var current = stat()
    var currentParent = stat()
    guard TopologyFixtures.privateDirectory(descriptor, info: &current),
      current.st_dev == identity.st_dev, current.st_ino == identity.st_ino,
      TopologyFixtures.privateDirectory(parent, info: &currentParent),
      currentParent.st_dev == parentIdentity.st_dev,
      currentParent.st_ino == parentIdentity.st_ino,
      TopologyFixtures.matches(directory: root, name: "Reports", info: parentIdentity),
      TopologyFixtures.matches(directory: parent, name: runID, info: identity)
    else { return false }
    return TopologyFixtures.publishReport(data, directory: descriptor)
  }

  deinit {
    close(descriptor)
    close(parent)
    close(root)
  }
}

enum TopologyReadiness {
  static var contractHash: String? {
    guard let url = Bundle.main.url(forResource: "contract", withExtension: "json"),
      let data = try? Data(contentsOf: url)
    else { return nil }
    return hash(data)
  }

  static func hash(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func integer(_ value: Any?) -> Int64? {
    guard let number = value as? NSNumber,
      CFGetTypeID(number) != CFBooleanGetTypeID(),
      ["c", "s", "i", "l", "q", "C", "S", "I", "L", "Q"].contains(
        String(cString: number.objCType)),
      number.decimalValue >= 0, number.decimalValue <= Decimal(Int64.max)
    else { return nil }
    return number.int64Value
  }

  private static func ack(_ bytes: Data) -> [String: String]? {
    guard String(data: bytes, encoding: .utf8) != nil,
      let value = try? JSONSerialization.jsonObject(with: bytes) as? [String: String],
      Set(value.keys) == Set(["schemaRevision", "runID", "phase", "readyHash", "artifactHash"])
    else { return nil }
    // Foundation collapses duplicate JSON keys. Every value in this closed
    // object is a string, so five unquoted separators also reject duplicates.
    var quoted = false
    var escaped = false
    var separators = 0
    for byte in bytes {
      if quoted {
        if escaped {
          escaped = false
        } else if byte == 92 {
          escaped = true
        } else if byte == 34 {
          quoted = false
        }
      } else if byte == 34 {
        quoted = true
      } else if byte == 58 {
        separators += 1
      }
    }
    return separators == 5 ? value : nil
  }

  private static let providerCaseIDs: Set<String> = {
    guard let url = Bundle.main.url(forResource: "contract", withExtension: "json"),
      let bytes = try? Data(contentsOf: url),
      let value = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
      let definitions = value["definitions"] as? [String: Any],
      let schema = definitions["caseID"] as? [String: Any],
      let cases = schema["enum"] as? [String]
    else { return [] }
    return Set(cases)
  }()

  private static func validCaseID(_ value: String) -> Bool {
    if providerCaseIDs.contains(value) { return true }
    if ["Main.pre.network.connect", "Main.post.network.connect"].contains(value) { return true }
    let parts = value.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3, ["Main", "PDFiumXPC"].contains(String(parts[0])),
      (TopologyFixtures.aliases + ["network"]).contains(String(parts[1]))
    else { return false }
    if ["descriptorRead", "descriptorWrite"].contains(String(parts[2])) {
      return parts[0] == "PDFiumXPC" && parts[1] == "PDF"
    }
    return ["read", "write", "symlinkRead", "connect"].contains(String(parts[2]))
  }

  static func fence(
    directory: Int32, runID: String, phase: String, actors: [[String: Any]],
    links: [[String: String]], intervals: [[String: Any]], ownerControl: Bool,
    timeoutMs: Int, completion: @escaping @Sendable (Bool) -> Void
  ) {
    let roles = Set(["Main", "ProviderAgent", "Python", "PDFiumXPC"])
    guard TopologyFixtures.validRunID(runID), ["pre", "post"].contains(phase),
      timeoutMs > 0, timeoutMs <= 10_000, let contractHash,
      !actors.isEmpty, actors.count <= roles.count,
      Set(actors.compactMap { $0["role"] as? String }).count == actors.count,
      actors.allSatisfy({ actor in
        guard Set(actor.keys) == Set(["role", "pid"]), let role = actor["role"] as? String,
          roles.contains(role), let pid = integer(actor["pid"])
        else { return false }
        return pid > 0 && pid <= Int64(Int32.max)
      }),
      Set(links.compactMap { $0["alias"] }).count == links.count,
      links.allSatisfy({ link in
        guard Set(link.keys) == Set(["alias", "name"]), let alias = link["alias"] else {
          return false
        }
        return TopologyFixtures.aliases.contains(alias) && link["name"] == alias + ".link"
      }),
      Set(intervals.compactMap { $0["caseID"] as? String }).count == intervals.count,
      intervals.allSatisfy({ interval in
        guard Set(interval.keys) == Set(["caseID", "beganAtNs", "endedAtNs"]),
          let caseID = interval["caseID"] as? String,
          let began = integer(interval["beganAtNs"]),
          let ended = integer(interval["endedAtNs"])
        else { return false }
        return validCaseID(caseID)
          && began <= ended && ((began == 0) == (ended == 0))
      })
    else {
      completion(false)
      return
    }
    let bytes = TopologyFixtures.json([
      "schemaRevision": "topology-readiness-v1", "runID": runID, "phase": phase,
      "contractHash": contractHash, "clock": "darwin-uptime-ns", "actors": actors,
      "links": links, "intervals": intervals, "ownerControl": ownerControl,
    ])
    guard bytes.count <= 64 * 1024,
      let fence = Fence(
        directory: directory, runID: runID, phase: phase,
        bytes: bytes, timeoutMs: timeoutMs, completion: completion)
    else {
      completion(false)
      return
    }
    fence.start()
  }

  private final class Fence: @unchecked Sendable {
    private let directory: Int32
    private let directoryInfo: stat
    private let readyInfo: stat
    private let readyName: String
    private let ackName: String
    private let readyHash: String
    private let runID: String
    private let phase: String
    private let deadline: UInt64
    private let completion: @Sendable (Bool) -> Void
    private let timer: DispatchSourceTimer
    private var finished = false
    private var acknowledged: stat?
    private var acknowledgedHash: String?
    private var readyRemoved = false

    init?(
      directory: Int32, runID: String, phase: String, bytes: Data,
      timeoutMs: Int, completion: @escaping @Sendable (Bool) -> Void
    ) {
      let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeoutMs) * 1_000_000
      let directory = fcntl(directory, F_DUPFD_CLOEXEC, 0)
      guard directory >= 0 else { return nil }
      var directoryInfo = stat()
      let readyName = phase == "pre" ? "ready.json" : "post-ready.json"
      let ackName = phase == "pre" ? "continue.json" : "post-continue.json"
      var existing = stat()
      guard TopologyFixtures.privateDirectory(directory, info: &directoryInfo),
        fstatat(directory, ackName, &existing, AT_SYMLINK_NOFOLLOW) == -1, errno == ENOENT
      else {
        close(directory)
        return nil
      }
      let temporary = UUID().uuidString.lowercased() + ".ready"
      let fd = openat(
        directory, temporary,
        O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
      guard fd >= 0 else {
        close(directory)
        return nil
      }
      var readyInfo = stat()
      let safe =
        TopologyFixtures.privateFile(fd, info: &readyInfo)
        && TopologyFixtures.writeAll(bytes, descriptor: fd) && TopologyFixtures.sync(fd)
        && TopologyFixtures.matches(directory: directory, name: temporary, info: readyInfo)
        && renameatx_np(directory, temporary, directory, readyName, UInt32(RENAME_EXCL)) == 0
        && TopologyFixtures.matches(directory: directory, name: readyName, info: readyInfo)
      close(fd)
      guard safe else {
        TopologyFixtures.removeOwned(directory: directory, name: temporary, info: readyInfo)
        TopologyFixtures.removeOwned(directory: directory, name: readyName, info: readyInfo)
        close(directory)
        return nil
      }
      self.directory = directory
      self.directoryInfo = directoryInfo
      self.readyInfo = readyInfo
      self.readyName = readyName
      self.ackName = ackName
      readyHash = TopologyReadiness.hash(bytes)
      self.runID = runID
      self.phase = phase
      self.deadline = deadline
      self.completion = completion
      timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "topology.readiness"))
    }

    func start() {
      timer.setEventHandler { [self] in poll() }
      timer.schedule(deadline: .now(), repeating: .milliseconds(20))
      timer.resume()
    }

    private func read(_ name: String, expected: stat? = nil) -> Data? {
      let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
      guard fd >= 0 else { return nil }
      defer { close(fd) }
      var before = stat()
      guard TopologyFixtures.privateFile(fd, info: &before), before.st_size > 0,
        before.st_size <= 64 * 1024,
        expected == nil || (before.st_dev == expected!.st_dev && before.st_ino == expected!.st_ino),
        TopologyFixtures.matches(directory: directory, name: name, info: before)
      else { return nil }
      var bytes = [UInt8](repeating: 0, count: Int(before.st_size))
      let complete = bytes.withUnsafeMutableBytes { buffer -> Bool in
        var offset = 0
        while offset < buffer.count {
          let count = pread(
            fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, off_t(offset))
          if count < 0 && errno == EINTR { continue }
          guard count > 0 else { return false }
          offset += count
        }
        return true
      }
      var after = stat()
      guard complete, TopologyFixtures.privateFile(fd, info: &after),
        before.st_ino == after.st_ino, before.st_dev == after.st_dev,
        before.st_size == after.st_size, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
        before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
        TopologyFixtures.matches(directory: directory, name: name, info: after)
      else { return nil }
      return Data(bytes)
    }

    private func poll() {
      guard !finished else { return }
      var current = stat()
      guard DispatchTime.now().uptimeNanoseconds < deadline,
        TopologyFixtures.privateDirectory(directory, info: &current),
        current.st_dev == directoryInfo.st_dev, current.st_ino == directoryInfo.st_ino
      else {
        finish(false)
        return
      }
      if let acknowledged {
        var unexpectedReady = stat()
        guard fstatat(directory, readyName, &unexpectedReady, AT_SYMLINK_NOFOLLOW) == -1,
          errno == ENOENT
        else {
          finish(false)
          return
        }
        var currentAck = stat()
        if fstatat(directory, ackName, &currentAck, AT_SYMLINK_NOFOLLOW) != 0 {
          finish(errno == ENOENT)
          return
        }
        guard let bytes = read(ackName, expected: acknowledged),
          TopologyReadiness.hash(bytes) == acknowledgedHash
        else {
          finish(false)
          return
        }
        return
      }
      guard let ready = read(readyName, expected: readyInfo),
        TopologyReadiness.hash(ready) == readyHash
      else {
        finish(false)
        return
      }
      var info = stat()
      if fstatat(directory, ackName, &info, AT_SYMLINK_NOFOLLOW) != 0 {
        if errno != ENOENT { finish(false) }
        return
      }
      guard let bytes = read(ackName, expected: info),
        let ack = TopologyReadiness.ack(bytes),
        ack["schemaRevision"] == "topology-readiness-v1", ack["runID"] == runID,
        ack["phase"] == phase, ack["readyHash"] == readyHash,
        let artifact = ack["artifactHash"], artifact.utf8.count == 64,
        artifact.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
      else {
        finish(false)
        return
      }
      guard TopologyFixtures.removeOwned(directory: directory, name: readyName, info: readyInfo)
      else {
        finish(false)
        return
      }
      readyRemoved = true
      acknowledged = info
      acknowledgedHash = TopologyReadiness.hash(bytes)
    }

    private func finish(_ success: Bool) {
      guard !finished else { return }
      finished = true
      timer.setEventHandler {}
      timer.cancel()
      let removed =
        readyRemoved
        || TopologyFixtures.removeOwned(directory: directory, name: readyName, info: readyInfo)
      close(directory)
      completion(success && removed)
    }
  }
}

// An instance owns only an exclusively created run directory. Cleanup never
// traverses or removes a pre-existing run, and never recursively removes trees.
final class TopologyOwnedFixtures: @unchecked Sendable {
  struct Hooks {
    var captureReference: (URL) -> CFURL? = {
      CFURLCreateFileReferenceURL(nil, $0 as CFURL, nil)?.takeRetainedValue()
    }
  }

  let runID: String
  let descriptor: Int32
  let directoryURL: URL
  private let parent: Int32
  private let directoryInode: ino_t
  private let directoryDevice: dev_t
  private let directoryReference: CFURL?
  private let backupAdmission = NSLock()
  private var backupAttempted = false
  private var backupPrepared = false
  private var metadataLease: UUID?
  private struct OwnedDirectory {
    let name: String
    var descriptor: Int32 = -1
    var identity: stat?
  }
  private var ownedDirectories: [OwnedDirectory] = []
  private var directoryACLs: [acl_t] = []
  var metadataParentDescriptor: Int32 { parent }

  var permitsNamespaceMutation: Bool { backupAdmission.withLock { metadataLease == nil } }

  func beginMetadataMutation(owner: UUID) -> Bool {
    backupAdmission.withLock {
      guard metadataLease == nil, !cleaned else { return false }
      metadataLease = owner
      return true
    }
  }

  func endMetadataMutation(owner: UUID) {
    backupAdmission.withLock {
      if metadataLease == owner { metadataLease = nil }
    }
  }
  private var files: [(String, Data, ino_t, dev_t)] = []
  private var ownedLinks: [(alias: String, target: String, info: stat)] = []
  var links: [[String: String]] {
    ownedLinks.map { ["alias": $0.alias, "name": $0.alias + ".link"] }
  }
  private var cleaned = false
  private var runtimeCleanupDescriptors: Set<Int32> = []
  private let runtimeAdmission = NSRecursiveLock()

  init?(root: URL, runID: String, hooks: Hooks = Hooks()) {
    guard TopologyFixtures.validRunID(runID),
      let parent = TopologyFixtures.directory(root, create: true)
    else { return nil }
    guard mkdirat(parent, runID, 0o700) == 0 else {
      close(parent)
      return nil
    }
    let fd = openat(parent, runID, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else {
      close(parent)
      return nil
    }
    var info = stat()
    guard TopologyFixtures.privateDirectory(fd, info: &info),
      TopologyFixtures.matches(directory: parent, name: runID, info: info)
    else {
      close(fd)
      close(parent)
      return nil
    }
    self.parent = parent
    directoryInode = info.st_ino
    directoryDevice = info.st_dev
    descriptor = fd
    self.runID = runID
    directoryURL = root.appendingPathComponent(runID, isDirectory: true)
    directoryReference = hooks.captureReference(
      root.appendingPathComponent(runID, isDirectory: true))
  }

  // Caller serializes namespace mutation/cleanup. Only the admission flag is
  // locked; Foundation/filesystem operations never run while holding that lock.
  func prepareBackupExclusion() -> Bool {
    guard Bundle.main.bundleIdentifier == TopologyIdentity.agent else { return false }
    return prepareBackupExclusion(providerBundle: Bundle.main.bundleURL)
  }

  // Main supplies the genuine embedded bundle explicitly; no host interpreter fallback.
  func prepareBackupExclusion(providerBundle: URL) -> Bool {
    prepareBackupExclusion { reference in
      guard
        let (interpreter, script) =
          OwnedChildRetirement.WorkerLaunch.validatedProviderBundle(providerBundle)
      else { return nil }
      return OwnedChildRetirement.BackupLaunch(
        namespace: self, interpreter: interpreter, script: script, reference: reference)
    }
  }

  func prepareBundledWorker(mainBundle: URL) -> OwnedChildRetirement.WorkerLaunch? {
    guard
      let launch = OwnedChildRetirement.WorkerLaunch.bundled(
        namespace: self, mainBundle: mainBundle),
      prepareBackupExclusion(
        providerBundle: mainBundle.appendingPathComponent("Contents/XPCServices/ProviderAgent.xpc"))
    else { return nil }
    return launch
  }

  // Same tracked operation is used by the existing metadata caller and the leased worker Core.
  func prepareRuntimeDirectories() -> Bool {
    guard permitsNamespaceMutation else { return false }
    return prepareDirectories(permit: { self.permitsNamespaceMutation })
  }

  /// Copy only our current file-backed login credential into a newly owned request
  /// namespace. Neither caller receives its contents. SDK configuration and history
  /// are deliberately excluded; unknown files, links and changed snapshots fail closed.
  func copyLoginAuthentication(to destination: TopologyOwnedFixtures) -> Bool {
    let first = directoryURL.path < destination.directoryURL.path ? self : destination
    let second = first === self ? destination : self
    first.runtimeAdmission.lock(); second.runtimeAdmission.lock()
    defer { second.runtimeAdmission.unlock(); first.runtimeAdmission.unlock() }
    guard self !== destination, !cleaned, !destination.cleaned,
      destination.permitsNamespaceMutation,
      matchesOwnedNamespace(), destination.matchesOwnedNamespace(),
      let source = ownedDirectories.first(where: { $0.name == "codex" }),
      let target = destination.ownedDirectories.first(where: { $0.name == "codex" }),
      let sourceIdentity = source.identity, let targetIdentity = target.identity,
      TopologyFixtures.matches(directory: descriptor, name: "codex", info: sourceIdentity),
      TopologyFixtures.matches(directory: destination.descriptor, name: "codex", info: targetIdentity)
    else { return false }
    let input = openat(source.descriptor, "auth.json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
    guard input >= 0 else { return false }
    runtimeCleanupDescriptors.insert(input)
    var before = stat()
    guard fstat(input, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
      before.st_uid == getuid(), before.st_nlink == 1, before.st_size > 0,
      before.st_size <= 65_536, before.st_mode & 0o077 == 0,
      TopologyFixtures.matches(directory: source.descriptor, name: "auth.json", info: before)
    else { return closeRuntimeDescriptor(input) && false }
    let output = openat(target.descriptor, "auth.json",
      O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard output >= 0 else { return closeRuntimeDescriptor(input) && false }
    destination.runtimeCleanupDescriptors.insert(output)
    var buffer = [UInt8](repeating: 0, count: 4096)
    var total = 0
    var succeeded = true
    while total < before.st_size {
      let count = read(input, &buffer, min(buffer.count, Int(before.st_size) - total))
      if count <= 0 { succeeded = false; break }
      var offset = 0
      while offset < count {
        let written = buffer.withUnsafeBytes {
          write(output, $0.baseAddress!.advanced(by: offset), count - offset)
        }
        if written <= 0 { succeeded = false; break }
        offset += written
      }
      total += count
      if !succeeded { break }
    }
    _ = buffer.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) }
    var after = stat()
    succeeded = succeeded && fstat(input, &after) == 0
      && before.st_ino == after.st_ino && before.st_dev == after.st_dev
      && before.st_size == after.st_size
      && before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec
      && before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec
      && before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec
      && before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
      && TopologyFixtures.matches(directory: source.descriptor, name: "auth.json", info: before)
    let outputClosed = destination.closeRuntimeDescriptor(output)
    let inputClosed = closeRuntimeDescriptor(input)
    return succeeded && outputClosed && inputClosed
  }

  private func closeRuntimeDescriptor(_ fd: Int32) -> Bool {
    guard close(fd) == 0 else { return false }
    runtimeCleanupDescriptors.remove(fd)
    return true
  }

  /// Used only before a worker launch has been constructed/admitted.
  func cleanupUnlaunchedWorkerNamespace() -> Bool {
    let owner = UUID()
    guard beginMetadataMutation(owner: owner) else { return false }
    return cleanupWorkerNamespace(owner: owner)
  }

  func prepareWorkerDirectories(owner: UUID, permit: () -> Bool) -> Bool {
    guard backupAdmission.withLock({ metadataLease == owner }) else { return false }
    return prepareDirectories(permit: permit)
  }

  private func prepareDirectories(permit: () -> Bool) -> Bool {
    guard permit(), hasBackupExclusion(permit: permit), matchesOwnedNamespace(permit: permit)
    else { return false }
    for name in ["codex", "tmp", "work"] {
      if let record = ownedDirectories.first(where: { $0.name == name }) {
        guard permit(), let expected = record.identity else { return false }
        var current = stat()
        guard privateOwnedDirectory(record.descriptor, info: &current, permit: permit),
          current.st_dev == expected.st_dev, current.st_ino == expected.st_ino,
          permit(),
          TopologyFixtures.matches(directory: descriptor, name: name, info: expected)
        else { return false }
        continue
      }
      guard permit() else { return false }
      let made = mkdirat(descriptor, name, 0o700)
      // Record the actual acquired entry even when the independent timer won during mkdir.
      if made == 0 { ownedDirectories.append(OwnedDirectory(name: name)) }
      guard permit(), made == 0 else { return false }
      let fd = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      if fd >= 0 { ownedDirectories[ownedDirectories.count - 1].descriptor = fd }
      guard permit(), fd >= 0 else { return false }
      var info = stat()
      guard privateOwnedDirectory(fd, info: &info, permit: permit), permit(),
        TopologyFixtures.matches(directory: descriptor, name: name, info: info)
      else { return false }
      ownedDirectories[ownedDirectories.count - 1].identity = info
    }
    return permit() && matchesOwnedNamespace(permit: permit)
  }

  private func privateOwnedDirectory(
    _ fd: Int32, info: inout stat, permit: () -> Bool
  ) -> Bool {
    guard permit(), fstat(fd, &info) == 0, info.st_uid == getuid(),
      info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o7777 == 0o700,
      info.st_nlink >= 2, permit()
    else { return false }
    let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED)
    let code = errno
    if let acl { directoryACLs.append(acl) }
    guard permit() else { return false }
    guard let acl else { return code == ENOENT }
    var entry: acl_entry_t?
    errno = 0
    let result = acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry)
    let entryCode = errno
    guard permit() else { return false }
    let freed = acl_free(UnsafeMutableRawPointer(acl))
    if freed == 0 { directoryACLs.removeLast() }
    return permit() && freed == 0 && result == -1 && entryCode == EINVAL
  }

  // Explicit controlled metadata fixture, never a production host-Python fallback.
  func prepareBackupExclusionFixture(
    agentScript: URL, interpreter: URL = URL(fileURLWithPath: "/usr/bin/python3")
  ) -> Bool {
    prepareBackupExclusion(onFailure: { terminal in
      print("Synthetic backup metadata preparation failed: \(String(describing: terminal))")
    }) { reference in
      OwnedChildRetirement.BackupLaunch(
        namespace: self, interpreter: interpreter,
        script: agentScript, reference: reference)
    }
  }

  private func prepareBackupExclusion(
    onFailure: ((OwnedChildRetirement.Terminal?) -> Void)? = nil,
    launch: (String) -> OwnedChildRetirement.BackupLaunch?
  ) -> Bool {
    guard
      backupAdmission.withLock({
        guard !backupAttempted, metadataLease == nil else { return false }
        backupAttempted = true
        return true
      }), files.isEmpty, ownedLinks.isEmpty, matchesOwnedNamespace(),
      referenceMatchesDescriptor(), matchesOwnedNamespace(),
      let reference = directoryReference
    else { onFailure?(nil); return false }
    let uri = CFURLGetString(reference) as String
    guard uri.utf8.count <= 256, let plan = launch(uri) else { return false }
    let deadline = DispatchTime.now().uptimeNanoseconds + 300_000_000
    let owner = OwnedChildRetirement(backup: plan, deadlineUptimeNanoseconds: deadline)
    let terminal = DispatchSemaphore(value: 0)
    owner.observeTerminal { _ in terminal.signal() }
    owner.retire()
    guard terminal.wait(timeout: DispatchTime(uptimeNanoseconds: deadline)) == .success,
      case .clean(let proof) = owner.terminal,
      proof.childReaped, proof.childExitStatus == 0, proof.checkedDescriptorCloses == 8
    else { onFailure?(owner.terminal); return false }
    guard matchesOwnedNamespace(), referenceMatchesDescriptor(), referenceHasBackupExclusion(),
      matchesOwnedNamespace()
    else {
      return false
    }
    backupAdmission.withLock { backupPrepared = true }
    return true
  }

  func hasBackupExclusion(permit: () -> Bool = { true }) -> Bool {
    backupAdmission.withLock { backupPrepared }
      && matchesOwnedNamespace(permit: permit) && referenceMatchesDescriptor(permit: permit)
      && referenceHasBackupExclusion(permit: permit) && matchesOwnedNamespace(permit: permit)
  }

  private func matchesOwnedNamespace(permit: () -> Bool = { true }) -> Bool {
    var info = stat()
    var named = stat()
    return !cleaned && privateOwnedDirectory(descriptor, info: &info, permit: permit)
      && info.st_ino == directoryInode && info.st_dev == directoryDevice
      && permit()
      && TopologyFixtures.matches(directory: parent, name: runID, info: info)
      && permit()
      && lstat(directoryURL.path, &named) == 0 && named.st_mode & S_IFMT == S_IFDIR
      && named.st_ino == directoryInode && named.st_dev == directoryDevice
      && permit()
  }

  private func referenceMatchesDescriptor(permit: () -> Bool = { true }) -> Bool {
    guard let reference = directoryReference, CFURLIsFileReferenceURL(reference) else {
      return false
    }
    let descriptorURL = URL(fileURLWithPath: "/dev/fd/\(descriptor)", isDirectory: true) as CFURL
    guard
      (resourceProperty(reference, kCFURLIsDirectoryKey, permit: permit) as? NSNumber)?.boolValue
        == true,
      (resourceProperty(descriptorURL, kCFURLIsDirectoryKey, permit: permit) as? NSNumber)?
        .boolValue == true,
      let observedFile = resourceProperty(
        reference, kCFURLFileResourceIdentifierKey, permit: permit),
      let ownedFile = resourceProperty(
        descriptorURL, kCFURLFileResourceIdentifierKey, permit: permit),
      let observedVolume = resourceProperty(reference, kCFURLVolumeIdentifierKey, permit: permit),
      let ownedVolume = resourceProperty(descriptorURL, kCFURLVolumeIdentifierKey, permit: permit)
    else { return false }
    // Public opaque equality only: never decode or guess identifier layouts.
    // /dev/fd is used for identity reads, not the unsupported metadata setter.
    return CFEqual(observedFile, ownedFile) && CFEqual(observedVolume, ownedVolume)
  }

  private func referenceHasBackupExclusion(permit: () -> Bool = { true }) -> Bool {
    guard let reference = directoryReference else { return false }
    return
      (resourceProperty(reference, kCFURLIsExcludedFromBackupKey, permit: permit) as? NSNumber)?
      .boolValue
      == true
  }

  private func resourceProperty(
    _ url: CFURL, _ key: CFString, permit: () -> Bool = { true }
  ) -> AnyObject? {
    guard permit() else { return nil }
    guard let fresh = CFURLCreateWithString(nil, CFURLGetString(url), nil) else { return nil }
    guard CFURLIsFileReferenceURL(fresh) == CFURLIsFileReferenceURL(url) else { return nil }
    CFURLClearResourcePropertyCache(fresh)
    var value: Unmanaged<AnyObject>?
    guard permit() else { return nil }
    let copied = CFURLCopyResourcePropertyForKey(fresh, key, &value, nil)
    let owned = value?.takeRetainedValue()
    return permit() && copied ? owned : nil
  }

  func prepareLinks(_ aliases: [String]) -> Bool {
    guard permitsNamespaceMutation, !cleaned, ownedLinks.isEmpty, !aliases.isEmpty,
      Set(aliases).count == aliases.count,
      aliases.allSatisfy({ TopologyFixtures.aliases.contains($0) })
    else { return false }
    for alias in aliases {
      guard let target = TopologyFixtures.path(alias, runID: runID),
        symlinkat(target, descriptor, alias + ".link") == 0
      else { return false }
      var info = stat()
      guard fstatat(descriptor, alias + ".link", &info, AT_SYMLINK_NOFOLLOW) == 0,
        info.st_mode & S_IFMT == S_IFLNK, info.st_uid == getuid(), info.st_nlink == 1
      else { return false }
      ownedLinks.append((alias, target, info))
    }
    return checkLinks()
  }

  func checkLinks() -> Bool {
    var info = stat()
    guard !cleaned, !ownedLinks.isEmpty,
      TopologyFixtures.privateDirectory(descriptor, info: &info),
      info.st_ino == directoryInode, info.st_dev == directoryDevice
    else { return false }
    return ownedLinks.allSatisfy { link in
      var current = stat()
      var bytes = [UInt8](repeating: 0, count: 4096)
      let name = link.alias + ".link"
      guard fstatat(descriptor, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
        current.st_dev == link.info.st_dev, current.st_ino == link.info.st_ino,
        current.st_mode & S_IFMT == S_IFLNK, current.st_uid == getuid(), current.st_nlink == 1
      else { return false }
      let count = readlinkat(descriptor, name, &bytes, bytes.count)
      return count > 0 && String(bytes: bytes.prefix(count), encoding: .utf8) == link.target
        && TopologyFixtures.matches(directory: descriptor, name: name, info: link.info)
    }
  }

  func create(_ alias: String) -> Bool {
    let names = ["M": "db.canary", "PDF": "input.pdf", "G": "group.canary"]
    guard permitsNamespaceMutation, !cleaned, let name = names[alias] else { return false }
    let bytes = TopologyFixtures.marker(alias, runID: runID)
    let fd = openat(descriptor, name, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    var info = stat()
    guard TopologyFixtures.privateFile(fd, info: &info) else {
      TopologyFixtures.removeOwned(directory: descriptor, name: name, info: info)
      return false
    }
    files.append((name, bytes, info.st_ino, info.st_dev))
    return TopologyFixtures.writeAll(bytes, descriptor: fd)
  }

  func readOnlyPDF() -> FileHandle? {
    guard let item = files.first(where: { $0.0 == "input.pdf" }) else { return nil }
    let fd = openat(descriptor, "input.pdf", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { return nil }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_ino == item.2, info.st_dev == item.3,
      info.st_mode & S_IFMT == S_IFREG,
      info.st_nlink == 1, info.st_uid == getuid(), info.st_size == item.1.count
    else {
      close(fd)
      return nil
    }
    return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
  }

  func check() -> Bool {
    guard permitsNamespaceMutation, !cleaned, !files.isEmpty else { return false }
    return files.allSatisfy { name, expected, inode, device in
      let fd = openat(descriptor, name, O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
      guard fd >= 0 else { return false }
      defer { close(fd) }
      var info = stat()
      guard fstat(fd, &info) == 0, info.st_ino == inode, info.st_dev == device,
        info.st_uid == getuid(),
        info.st_mode & 0o777 == 0o600, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
        info.st_size == expected.count, TopologyFixtures.emptyACL(fd)
      else { return false }
      var bytes = [UInt8](repeating: 0, count: expected.count)
      guard pread(fd, &bytes, bytes.count, 0) == bytes.count, Data(bytes) == expected else {
        return false
      }
      // Verify existing-file write permission only after checking integrity.
      var byte = bytes[0]
      return pwrite(fd, &byte, 1, 0) == 1
    }
  }

  /// Only called by the retained native worker owner after CLI, broker and worker
  /// waits and checked pipe closure. No pre-existing run is ever adopted.
  func cleanupWorkerNamespace(owner: UUID) -> Bool {
    runtimeAdmission.lock()
    defer { runtimeAdmission.unlock() }
    guard runtimeCleanupDescriptors.isEmpty,
      backupAdmission.withLock({ metadataLease == owner }), matchesOwnedNamespace() else {
      return false
    }
    for record in ownedDirectories {
      guard let expected = record.identity,
        TopologyFixtures.matches(directory: descriptor, name: record.name, info: expected),
        emptyOwnedRuntimeDirectory(record.descriptor, device: directoryDevice)
      else { return false }
    }
    endMetadataMutation(owner: owner)
    return cleanup()
  }

  private func emptyOwnedRuntimeDirectory(_ directory: Int32, device: dev_t) -> Bool {
    let copy = fcntl(directory, F_DUPFD_CLOEXEC, 64)
    guard copy >= 0 else { return false }
    runtimeCleanupDescriptors.insert(copy)
    guard let stream = fdopendir(copy) else {
      if close(copy) == 0 { runtimeCleanupDescriptors.remove(copy) }
      return false
    }
    func finish(_ success: Bool) -> Bool {
      let closed = closedir(stream) == 0
      if closed { runtimeCleanupDescriptors.remove(copy) }
      return success && closed
    }
    while true {
      errno = 0
      guard let entry = readdir(stream) else { return finish(errno == 0) }
      let capacity = Int(entry.pointee.d_namlen) + 1
      let name = withUnsafePointer(to: &entry.pointee.d_name) {
        $0.withMemoryRebound(to: CChar.self, capacity: capacity) {
          String(cString: $0)
        }
      }
      if name == "." || name == ".." { continue }
      var info = stat()
      guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
        info.st_uid == getuid(), info.st_dev == device else { return finish(false) }
      if info.st_mode & S_IFMT == S_IFDIR {
        let child = openat(directory, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard child >= 0 else { return finish(false) }
        runtimeCleanupDescriptors.insert(child)
        var opened = stat()
        let valid = fstat(child, &opened) == 0 && opened.st_dev == info.st_dev
          && opened.st_ino == info.st_ino && emptyOwnedRuntimeDirectory(child, device: device)
        let closed = close(child) == 0
        if closed { runtimeCleanupDescriptors.remove(child) }
        guard valid, closed,
          TopologyFixtures.matches(directory: directory, name: name, info: info),
          unlinkat(directory, name, AT_REMOVEDIR) == 0 else { return finish(false) }
      } else {
        // A local symlink is unlinked without following its target. Hard-linked
        // regular files are retained because their external ownership is unknown.
        guard info.st_mode & S_IFMT != S_IFREG || info.st_nlink == 1,
          TopologyFixtures.matches(directory: directory, name: name, info: info),
          unlinkat(directory, name, 0) == 0 else { return finish(false) }
      }
    }
  }

  @discardableResult func cleanup() -> Bool {
    runtimeAdmission.lock()
    defer { runtimeAdmission.unlock() }
    guard runtimeCleanupDescriptors.isEmpty else { return false }
    guard permitsNamespaceMutation else { return false }
    guard !cleaned else { return true }
    var success = true
    for record in ownedDirectories {
      guard let expected = record.identity,
        TopologyFixtures.matches(directory: descriptor, name: record.name, info: expected)
      else {
        success = false
        continue
      }
      if unlinkat(descriptor, record.name, AT_REMOVEDIR) != 0 { success = false }
    }
    for link in ownedLinks {
      var info = stat()
      let name = link.alias + ".link"
      if fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 {
        if !TopologyFixtures.removeOwned(directory: descriptor, name: name, info: link.info) {
          success = false
        }
      } else if errno != ENOENT {
        success = false
      }
    }
    for (name, _, inode, device) in files {
      var info = stat()
      if fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 {
        if info.st_ino != inode || info.st_dev != device || info.st_mode & S_IFMT != S_IFREG {
          success = false
          continue
        }
        if unlinkat(descriptor, name, 0) != 0 { success = false }
      } else if errno != ENOENT {
        success = false
      }
    }
    var info = stat()
    if fstatat(parent, runID, &info, AT_SYMLINK_NOFOLLOW) != 0 || info.st_ino != directoryInode
      || info.st_dev != directoryDevice || info.st_mode & S_IFMT != S_IFDIR
    {
      success = false
    } else if unlinkat(parent, runID, AT_REMOVEDIR) != 0 {
      success = false
    }
    cleaned = true
    return success
  }

  deinit {
    cleanup()
    for acl in directoryACLs { acl_free(UnsafeMutableRawPointer(acl)) }
    for record in ownedDirectories where record.descriptor >= 0 { close(record.descriptor) }
    close(descriptor)
    close(parent)
  }
}
