import Darwin
import Foundation
import CryptoKit

@_silgen_name("FPDF_InitLibrary") private func FPDF_InitLibrary()
@_silgen_name("FPDF_DestroyLibrary") private func FPDF_DestroyLibrary()

// Locked public headers: opaque document/page/text pointers, size_t/unsigned long
// are UInt on Darwin arm64; FPDF_BOOL/int are Int32. FS_RECTF and FS_MATRIX
// outputs below are contiguous Float storage, never Double storage.
@_silgen_name("FPDF_LoadMemDocument64") private func FPDF_LoadMemDocument64(_ data: UnsafeRawPointer, _ size: UInt, _ password: UnsafePointer<CChar>?) -> OpaquePointer?
@_silgen_name("FPDF_CloseDocument") private func FPDF_CloseDocument(_ document: OpaquePointer)
@_silgen_name("FPDF_GetLastError") private func FPDF_GetLastError() -> UInt
@_silgen_name("FPDF_GetPageCount") private func FPDF_GetPageCount(_ document: OpaquePointer) -> Int32
@_silgen_name("FPDF_LoadPage") private func FPDF_LoadPage(_ document: OpaquePointer, _ index: Int32) -> OpaquePointer?
@_silgen_name("FPDF_ClosePage") private func FPDF_ClosePage(_ page: OpaquePointer)
@_silgen_name("FPDF_GetPageBoundingBox") private func FPDF_GetPageBoundingBox(_ page: OpaquePointer, _ rect: UnsafeMutablePointer<Float>) -> Int32
@_silgen_name("FPDFPage_GetMediaBox") private func FPDFPage_GetMediaBox(_ page: OpaquePointer, _ left: UnsafeMutablePointer<Float>, _ bottom: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>, _ top: UnsafeMutablePointer<Float>) -> Int32
@_silgen_name("FPDFPage_GetCropBox") private func FPDFPage_GetCropBox(_ page: OpaquePointer, _ left: UnsafeMutablePointer<Float>, _ bottom: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>, _ top: UnsafeMutablePointer<Float>) -> Int32
@_silgen_name("FPDFPage_GetRotation") private func FPDFPage_GetRotation(_ page: OpaquePointer) -> Int32
@_silgen_name("FPDFText_LoadPage") private func FPDFText_LoadPage(_ page: OpaquePointer) -> OpaquePointer?
@_silgen_name("FPDFText_ClosePage") private func FPDFText_ClosePage(_ text: OpaquePointer)
@_silgen_name("FPDFText_CountChars") private func FPDFText_CountChars(_ text: OpaquePointer) -> Int32
@_silgen_name("FPDFText_GetUnicode") private func FPDFText_GetUnicode(_ text: OpaquePointer, _ index: Int32) -> UInt32
@_silgen_name("FPDFText_GetCharBox") private func FPDFText_GetCharBox(_ text: OpaquePointer, _ index: Int32, _ left: UnsafeMutablePointer<Double>, _ right: UnsafeMutablePointer<Double>, _ bottom: UnsafeMutablePointer<Double>, _ top: UnsafeMutablePointer<Double>) -> Int32
@_silgen_name("FPDFText_GetMatrix") private func FPDFText_GetMatrix(_ text: OpaquePointer, _ index: Int32, _ matrix: UnsafeMutablePointer<Float>) -> Int32
@_silgen_name("FPDFText_IsGenerated") private func FPDFText_IsGenerated(_ text: OpaquePointer, _ index: Int32) -> Int32

/// All native operations, including topology smoke, execute on one queue. The
/// reservation remains held BETWEEN pulls, through document/map/FD cleanup.
private enum NativeLibrary {
  static let queue = DispatchQueue(label: "PaperLens.PDFium.native")
  nonisolated(unsafe) static var reserved = false // queue confined
  nonisolated(unsafe) static var cleanupDebt: [NativeExtraction] = [] // actual unresolved handles, queue confined
  nonisolated(unsafe) static var rejectedDebt: [RejectedExtractionHandle] = [] // queue confined; never reclose
  static func reserve() -> Bool {
    guard !reserved else { return false }
    reserved = true
    return true
  }
}

/// A failed checked close is not evidence that the descriptor is still live.
/// Retain its actual owner and identity without retrying a possibly reused FD.
private final class RejectedExtractionHandle: @unchecked Sendable {
  let key: PDFiumExtractionKey
  let pdf: FileHandle
  init(key: PDFiumExtractionKey, pdf: FileHandle) { self.key = key; self.pdf = pdf }
}

private final class NativeReply<Value>: @unchecked Sendable {
  let body: (Value) -> Void
  init(_ body: @escaping (Value) -> Void) { self.body = body }
  func send(_ value: Value) { body(value) }
}

private final class NativeExtraction: @unchecked Sendable {
  let request: PDFiumExtractionRequest
  let pdf: FileHandle
  private let cancellationLock = NSLock()
  private var cancelled = false
  var mapping: UnsafeMutableRawPointer?
  var mappingBytes = 0
  var document: OpaquePointer?
  var page: OpaquePointer?
  var textPage: OpaquePointer?
  var library = false
  var senderClosed = false
  var senderCloseUncertain = false
  var observedHash: String?
  var pageCount: Int?
  var processedPages = 0
  var sequence = 0
  var sentenceCount = 0
  var textBytes = 0
  var quadCount = 0
  var workspace: PageWorkspace?
  var pending: (PDFiumRawPage, PDFiumSentence)?
  var end: PDFiumEnd?
  var failure: PDFiumFailure?
  var drained = false

  struct PageWorkspace {
    let page: PDFiumRawPage
    let text: String
    let glyphs: [PDFiumGlyph]
    let ranges: [NSRange]
    var nextRange: Int
    var nextGlyph: Int
  }
  init(request: PDFiumExtractionRequest, pdf: FileHandle) {
    self.request = request; self.pdf = pdf
  }
  func requestCancellation() {
    cancellationLock.lock(); cancelled = true; cancellationLock.unlock()
  }
  func check() throws {
    cancellationLock.lock(); let stop = cancelled; cancellationLock.unlock()
    guard !stop else { throw PDFiumFailure(code: .cancelled) }
    guard DispatchTime.now().uptimeNanoseconds < request.deadlineUptimeNanoseconds else {
      throw PDFiumFailure(code: .resourceExceeded)
    }
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
      }
    }
    guard result == KERN_SUCCESS, UInt64(info.resident_size) <= request.limits.maximumResidentBytes else {
      throw PDFiumFailure(code: .resourceExceeded)
    }
  }
  func start() throws -> PDFiumStartAck {
    try check()
    let fd = pdf.fileDescriptor
    var info = stat()
    guard fd >= 0 else { throw PDFiumFailure(code: .invalidRequest) }
    guard fstat(fd, &info) == 0 else { throw PDFiumFailure(code: .invalidRequest, systemError: errno) }
    let flags = fcntl(fd, F_GETFL)
    guard flags >= 0 else { throw PDFiumFailure(code: .invalidRequest, systemError: errno) }
    guard info.st_mode & S_IFMT == S_IFREG, flags & O_ACCMODE == O_RDONLY,
      info.st_size > 0, info.st_size == request.pdfByteCount,
      info.st_size <= request.limits.maximumInputBytes, let size = Int(exactly: info.st_size)
    else { throw PDFiumFailure(code: .invalidRequest) }
    try check()
    let address = mmap(nil, size, PROT_READ, MAP_PRIVATE, fd, 0)
    guard address != MAP_FAILED, let address else {
      throw PDFiumFailure(code: .invalidPDF, systemError: errno)
    }
    mapping = address; mappingBytes = size
    try check()
    var digest = SHA256()
    // Hash directly from the bounded mapping without an input-size copy.
    let hashStride = Int(sysconf(_SC_PAGESIZE))
    guard hashStride > 0 else { throw PDFiumFailure(code: .resourceExceeded) }
    var offset = 0
    while offset < size {
      try check()
      let length = min(hashStride, size - offset)
      digest.update(bufferPointer: UnsafeRawBufferPointer(start: address.advanced(by: offset), count: length))
      offset += length
      try check()
    }
    let hash = digest.finalize().map { String(format: "%02x", $0) }.joined()
    observedHash = hash
    try check()
    guard hash == request.key.pdfSHA256 else { throw PDFiumFailure(code: .identityMismatch) }
    guard NativeLibrary.reserve() else { throw PDFiumFailure(code: .busy) }
    library = true
    FPDF_InitLibrary()
    try check()
    guard let loaded = FPDF_LoadMemDocument64(UnsafeRawPointer(address), UInt(size), nil) else {
      throw PDFiumFailure(code: .invalidPDF, nativeError: UInt64(FPDF_GetLastError()))
    }
    document = loaded
    try check()
    let count = Int(FPDF_GetPageCount(loaded))
    pageCount = count
    try check()
    guard count > 0 else { throw PDFiumFailure(code: .invalidPDF) }
    guard count <= request.limits.maximumPages else {
      throw PDFiumFailure(code: .resourceExceeded)
    }
    return try PDFiumStartAck(key: request.key, workerPID: getpid(), observedPDFSHA256: hash,
      observedPDFByteCount: Int64(size), documentPageCount: count)
  }
  private func rectangle(left: Double, bottom: Double, right: Double, top: Double) throws -> PDFiumRawQuad {
    guard [left, bottom, right, top].allSatisfy(\.isFinite), left < right, bottom < top else {
      throw PDFiumFailure(code: .unsupportedGeometry)
    }
    return try PDFiumRawQuad(topLeftX: left, topLeftY: top, topRightX: right, topRightY: top,
      bottomRightX: right, bottomRightY: bottom, bottomLeftX: left, bottomLeftY: bottom)
  }
  private func loadWorkspace() throws {
    try check()
    guard let document, let index = Int32(exactly: processedPages),
      let loaded = FPDF_LoadPage(document, index) else { throw PDFiumFailure(code: .invalidPDF) }
    page = loaded
    defer {
      if let textPage { FPDFText_ClosePage(textPage); self.textPage = nil }
      FPDF_ClosePage(loaded); page = nil
    }
    try check()
    var box = [Float](repeating: .nan, count: 4)
    let hasBounds = box.withUnsafeMutableBufferPointer { FPDF_GetPageBoundingBox(loaded, $0.baseAddress!) }
    try check()
    guard hasBounds != 0 else { throw PDFiumFailure(code: .unsupportedGeometry) }
    let bounds = try rectangle(left: Double(box[0]), bottom: Double(box[3]), right: Double(box[2]), top: Double(box[1]))
    var left = Float.nan, bottom = Float.nan, right = Float.nan, top = Float.nan
    let hasMedia = FPDFPage_GetMediaBox(loaded, &left, &bottom, &right, &top)
    try check()
    let media = hasMedia != 0 ? try rectangle(left: Double(left), bottom: Double(bottom), right: Double(right), top: Double(top)) : nil
    left = .nan; bottom = .nan; right = .nan; top = .nan
    let hasCrop = FPDFPage_GetCropBox(loaded, &left, &bottom, &right, &top)
    try check()
    let crop = hasCrop != 0 ? try rectangle(left: Double(left), bottom: Double(bottom), right: Double(right), top: Double(top)) : nil
    let rotation = Int(FPDFPage_GetRotation(loaded))
    try check()
    let rawPage = try PDFiumRawPage(pageIndex: processedPages, boundingBox: bounds,
      mediaBox: media, cropBox: crop, rotationQuarterTurns: rotation)
    guard let text = FPDFText_LoadPage(loaded) else { throw PDFiumFailure(code: .invalidPDF) }
    textPage = text
    try check()
    let count = Int(FPDFText_CountChars(text))
    try check()
    guard count >= 0 else { throw PDFiumFailure(code: .invalidPDF) }
    guard count <= request.limits.maximumTextBytes - textBytes else {
      throw PDFiumFailure(code: .resourceExceeded)
    }
    // Grow only after checking actual RSS. Do not pretend that a record-count
    // estimate certifies Foundation or native allocator resident memory.
    try check()
    var glyphs: [PDFiumGlyph] = []
    var source = String.UnicodeScalarView()
    var utf16Position = 0
    var pageBytes = 0
    for i in 0..<count {
      try check()
      let scalarValue = FPDFText_GetUnicode(text, Int32(i))
      try check()
      guard scalarValue != 0, let scalar = Unicode.Scalar(scalarValue) else {
        throw PDFiumFailure(code: .unmappableText)
      }
      let generated = FPDFText_IsGenerated(text, Int32(i))
      try check()
      guard generated == 0 || generated == 1 else { throw PDFiumFailure(code: .unmappableText) }
      var matrix = [Float](repeating: .nan, count: 6)
      let hasMatrix = matrix.withUnsafeMutableBufferPointer { FPDFText_GetMatrix(text, Int32(i), $0.baseAddress!) }
      try check()
      guard hasMatrix != 0, matrix.allSatisfy(\.isFinite) else {
        throw PDFiumFailure(code: .unsupportedGeometry)
      }
      var l = Double.nan, r = Double.nan, b = Double.nan, t = Double.nan
      let hasBox = FPDFText_GetCharBox(text, Int32(i), &l, &r, &b, &t)
      try check()
      guard hasBox != 0, [l, r, b, t].allSatisfy(\.isFinite), l <= r, b <= t else {
        throw PDFiumFailure(code: .unsupportedGeometry)
      }
      let collapsed = l == r || b == t
      let whitespace = CharacterSet.whitespacesAndNewlines.contains(scalar)
      guard !collapsed || whitespace else { throw PDFiumFailure(code: .unsupportedGeometry) }
      // A successful collapsed native character box verifies nondrawing extent;
      // only whitespace may omit a quad. All drawable chars require a real box.
      let quad = collapsed ? nil : try rectangle(left: l, bottom: b, right: r, top: t)
      if quad != nil {
        guard matrix[0] > 0, matrix[3] > 0, matrix[1] == 0, matrix[2] == 0 else {
          throw PDFiumFailure(code: .unsupportedGeometry)
        }
      }
      let scalarString = String(scalar)
      let scalarBytes = scalarString.utf8.count
      guard pageBytes <= request.limits.maximumTextBytes - textBytes - scalarBytes,
        utf16Position <= Int.max - scalarString.utf16.count else {
        throw PDFiumFailure(code: .resourceExceeded)
      }
      try check()
      let glyph = try PDFiumGlyph(nativeCharacterIndex: i, unicodeScalar: scalarValue,
        utf16Start: utf16Position, utf16Length: scalarString.utf16.count, generated: generated == 1,
        matrixA: Double(matrix[0]), matrixB: Double(matrix[1]), matrixC: Double(matrix[2]),
        matrixD: Double(matrix[3]), matrixE: Double(matrix[4]), matrixF: Double(matrix[5]), rawQuad: quad)
      glyphs.append(glyph); source.append(scalar)
      pageBytes += scalarBytes; utf16Position += scalarString.utf16.count
      try check()
    }
    let pageText = String(source)
    var ranges: [NSRange] = []
    var enumerationError: Error?
    var coveredUTF16 = 0
    pageText.enumerateSubstrings(in: pageText.startIndex..<pageText.endIndex,
      options: [.bySentences, .substringNotRequired]) { _, _, enclosing, stop in
      do {
        try self.check()
        let range = NSRange(enclosing, in: pageText)
        // Use enclosing ranges to retain spaces and separators without shortening.
        guard range.location == coveredUTF16, range.length > 0,
          ranges.count < self.request.limits.maximumSentences - self.sentenceCount else {
          throw PDFiumFailure(code: .unmappableText)
        }
        ranges.append(range); coveredUTF16 += range.length
        try self.check()
      } catch { enumerationError = error; stop = true }
    }
    if let enumerationError { throw enumerationError }
    if coveredUTF16 != utf16Position {
      // A whitespace-only page has no usable sentence but still advances real
      // completeness. No visible source scalar may be discarded by enumeration.
      guard ranges.isEmpty, pageText.unicodeScalars.allSatisfy({ CharacterSet.whitespacesAndNewlines.contains($0) }),
        glyphs.allSatisfy({ $0.rawQuad == nil }) else { throw PDFiumFailure(code: .unmappableText) }
    }
    try check()
    workspace = PageWorkspace(page: rawPage, text: pageText, glyphs: glyphs, ranges: ranges,
      nextRange: 0, nextGlyph: 0)
  }
  private func nextSentence() throws -> (PDFiumRawPage, PDFiumSentence)? {
    while true {
      try check()
      if workspace == nil {
        guard let pageCount else { throw PDFiumFailure(code: .protocolViolation) }
        guard processedPages < pageCount else { return nil }
        try loadWorkspace()
      }
      guard var current = workspace else { throw PDFiumFailure(code: .protocolViolation) }
      if current.nextRange == current.ranges.count {
        workspace = nil; processedPages += 1
        continue
      }
      let range = current.ranges[current.nextRange]
      let first = current.nextGlyph
      guard let swiftRange = Range(range, in: current.text),
        first < current.glyphs.count, current.glyphs[first].utf16Start == range.location else {
        throw PDFiumFailure(code: .unmappableText)
      }
      let finish = range.location.addingReportingOverflow(range.length)
      guard !finish.overflow else { throw PDFiumFailure(code: .unmappableText) }
      var last = first
      var quads = 0
      while last < current.glyphs.count && current.glyphs[last].utf16Start < finish.partialValue {
        try check()
        if current.glyphs[last].rawQuad != nil { quads += 1 }
        last += 1
      }
      guard last > first, current.glyphs[last - 1].utf16Start + current.glyphs[last - 1].utf16Length == finish.partialValue,
        quads > 0, quads <= request.limits.maximumQuadsPerSentence,
        quadCount <= request.limits.maximumQuads - quads,
        sentenceCount < request.limits.maximumSentences else { throw PDFiumFailure(code: .resourceExceeded) }
      let slice = current.text[swiftRange]
      let bytes = slice.utf8.count
      guard let envelope = PDFiumBatch.maximumEnvelopePayloadBytes(key: request.key),
        envelope <= request.limits.maximumBatchBytes,
        current.page.payloadBytes <= request.limits.maximumBatchBytes - envelope else {
        throw PDFiumFailure(code: .resourceExceeded)
      }
      var payload = 2 * MemoryLayout<uuid_t>.size + 6 * MemoryLayout<Int64>.size + request.key.pdfSHA256.utf8.count
      guard bytes <= request.limits.maximumBatchBytes - payload else { throw PDFiumFailure(code: .resourceExceeded) }
      payload += bytes
      for glyph in current.glyphs[first..<last] {
        try check()
        guard glyph.payloadBytes <= request.limits.maximumBatchBytes - payload else {
          throw PDFiumFailure(code: .resourceExceeded)
        }
        payload += glyph.payloadBytes
      }
      guard payload <= request.limits.maximumBatchBytes - envelope - current.page.payloadBytes,
        bytes <= request.limits.maximumSentenceBytes,
        textBytes <= request.limits.maximumTextBytes - bytes else { throw PDFiumFailure(code: .resourceExceeded) }
      try check()
      let sentence = try PDFiumSentence(paperID: request.key.paperID, revision: request.key.revision,
        pdfSHA256: request.key.pdfSHA256, pageIndex: current.page.pageIndex, sentenceID: sentenceCount,
        text: String(slice), nativeStartCharacter: first, nativeCharacterCount: last - first,
        sourceUTF16Start: range.location, sourceUTF16Length: range.length,
        glyphs: Array(current.glyphs[first..<last]))
      sentenceCount += 1; textBytes += bytes; quadCount += quads
      current.nextRange += 1; current.nextGlyph = last; workspace = current
      try check()
      return (current.page, sentence)
    }
  }
  func pull(_ requestedSequence: Int) throws -> (PDFiumBatch, PDFiumEnd?) {
    guard !drained, failure == nil, requestedSequence == sequence else {
      throw PDFiumFailure(code: .protocolViolation)
    }
    try check()
    var sentences: [PDFiumSentence] = []
    var pages: [PDFiumRawPage] = []
    guard let envelope = PDFiumBatch.maximumEnvelopePayloadBytes(key: request.key),
      envelope <= request.limits.maximumBatchBytes else { throw PDFiumFailure(code: .resourceExceeded) }
    var batchBytes = envelope
    var complete = false
    while true {
      try check()
      let item: (PDFiumRawPage, PDFiumSentence)?
      if let held = pending { item = held; pending = nil } else { item = try nextSentence() }
      guard let (rawPage, sentence) = item else { complete = true; break }
      guard let bytes = sentence.payloadBytes else { throw PDFiumFailure(code: .resourceExceeded) }
      let needsPage = !pages.contains(where: { $0.pageIndex == rawPage.pageIndex })
      let extra = bytes.addingReportingOverflow(needsPage ? rawPage.payloadBytes : 0)
      guard !extra.overflow, extra.partialValue <= request.limits.maximumBatchBytes else {
        throw PDFiumFailure(code: .resourceExceeded)
      }
      if sentences.count == request.limits.maximumBatchSentences
        || batchBytes > request.limits.maximumBatchBytes - extra.partialValue {
        pending = item; break
      }
      try check()
      if needsPage { pages.append(rawPage) }
      sentences.append(sentence); batchBytes += extra.partialValue
      try check()
    }
    guard !sentences.isEmpty else { throw PDFiumFailure(code: .unmappableText) }
    let batch = try PDFiumBatch(key: request.key, sequence: sequence, pages: pages,
      sentences: sentences, complete: complete, totalSentences: complete ? sentenceCount : nil)
    sequence += 1
    if complete {
      do { return (batch, try cleanup(.completed)) }
      catch { sequence -= 1; throw error }
    }
    return (batch, nil)
  }
  /// Native close APIs are void. munmap and FileHandle.close are checked. No
  /// end is constructed until all actual owned resources have been disposed.
  func cleanup(_ disposition: PDFiumEndDisposition) throws -> PDFiumEnd {
    if let end { return end }
    if let textPage { FPDFText_ClosePage(textPage); self.textPage = nil }
    if let page { FPDF_ClosePage(page); self.page = nil }
    workspace = nil; pending = nil
    if let document { FPDF_CloseDocument(document); self.document = nil }
    if let mapping {
      guard munmap(mapping, mappingBytes) == 0 else {
        throw PDFiumFailure(code: .cleanupIncomplete, systemError: errno)
      }
      self.mapping = nil
    }
    if !senderClosed {
      guard !senderCloseUncertain else { throw PDFiumFailure(code: .cleanupIncomplete) }
      do { try pdf.close(); senderClosed = true }
      catch { senderCloseUncertain = true; throw PDFiumFailure(code: .cleanupIncomplete) }
    }
    if library { FPDF_DestroyLibrary(); library = false; NativeLibrary.reserved = false }
    drained = true
    guard let observedHash, let pageCount, pageCount >= 0 else {
      // Failed admission may have no actual hash/page-count observation. Do not
      // manufacture required End fields merely because the local FD was closed.
      throw PDFiumFailure(code: .cleanupIncomplete)
    }
    let result = try PDFiumEnd(key: request.key, disposition: disposition,
      lastSequence: sequence - 1, totalSentences: sentenceCount, processedPageCount: processedPages,
      documentPageCount: pageCount, observedPDFSHA256: observedHash)
    end = result
    return result
  }
  func fail(_ error: Error) -> (PDFiumEnd?, PDFiumFailure) {
    let failure = (error as? PDFiumFailure) ?? PDFiumFailure(code: .protocolViolation)
    self.failure = failure
    do { return (try cleanup(.failed), failure) }
    catch { return (nil, (error as? PDFiumFailure) ?? PDFiumFailure(code: .cleanupIncomplete)) }
  }
}

private final class PDFService: NSObject, PDFiumExtractionService, @unchecked Sendable {
  private static let queue = NativeLibrary.queue
  private let lock = NSLock()
  private var accepted = false
  private var identified = false
  private var identifiedRun: String?
  private var extraction: NativeExtraction?
  private var pulling = false

  func beginExtraction(_ request: PDFiumExtractionRequest, pdf: FileHandle,
    withReply reply: @escaping (PDFiumStartAck?, PDFiumFailure?) -> Void) {
    let completion = NativeReply<(PDFiumStartAck?, PDFiumFailure?)> { reply($0.0, $0.1) }
    lock.lock()
    guard !accepted, !identified, extraction == nil else {
      lock.unlock()
      let debt = RejectedExtractionHandle(key: request.key, pdf: pdf)
      do { try pdf.close(); reply(nil, PDFiumFailure(code: .busy)) }
      catch {
        Self.queue.async { NativeLibrary.rejectedDebt.append(debt) }
        reply(nil, PDFiumFailure(code: .cleanupIncomplete))
      }
      return
    }
    accepted = true
    let operation = NativeExtraction(request: request, pdf: pdf)
    extraction = operation
    lock.unlock()
    Self.queue.async {
      do { completion.send((try operation.start(), nil)) }
      catch { let (_, failure) = operation.fail(error); completion.send((nil, failure)) }
    }
  }

  func nextExtractionBatch(_ operationID: NSUUID, sequence: Int,
    withReply reply: @escaping (PDFiumBatch?, PDFiumEnd?, PDFiumFailure?) -> Void) {
    let completion = NativeReply<(PDFiumBatch?, PDFiumEnd?, PDFiumFailure?)> { reply($0.0, $0.1, $0.2) }
    lock.lock()
    guard let operation = extraction, operation.request.key.operationID == operationID as UUID,
      !pulling else { lock.unlock(); reply(nil, nil, PDFiumFailure(code: .protocolViolation)); return }
    pulling = true
    lock.unlock()
    Self.queue.async {
      guard !operation.drained else {
        self.lock.lock(); self.pulling = false; self.lock.unlock()
        completion.send((nil, nil, PDFiumFailure(code: .protocolViolation)))
        return
      }
      do {
        let (batch, end) = try operation.pull(sequence)
        self.lock.lock(); self.pulling = false; self.lock.unlock()
        completion.send((batch, end, nil))
      } catch {
        let (end, failure) = operation.fail(error)
        self.lock.lock(); self.pulling = false; self.lock.unlock()
        completion.send((nil, end, failure))
      }
    }
  }

  func cancelExtractionAndDrain(_ operationID: NSUUID,
    withReply reply: @escaping (PDFiumEnd?, PDFiumFailure?) -> Void) {
    let completion = NativeReply<(PDFiumEnd?, PDFiumFailure?)> { reply($0.0, $0.1) }
    lock.lock()
    guard let operation = extraction, operation.request.key.operationID == operationID as UUID else {
      lock.unlock(); reply(nil, PDFiumFailure(code: .identityMismatch)); return
    }
    operation.requestCancellation()
    lock.unlock()
    Self.queue.async {
      do { completion.send((try operation.cleanup(operation.failure == nil ? .cancelled : .failed), nil)) }
      catch { completion.send((nil, (error as? PDFiumFailure) ?? PDFiumFailure(code: .cleanupIncomplete))) }
    }
  }

  func invalidated() {
    lock.lock(); let operation = extraction; operation?.requestCancellation(); lock.unlock()
    guard let operation else { return }
    Self.queue.async {
      let (end, _) = operation.fail(PDFiumFailure(code: .cancelled))
      if end == nil && !operation.drained,
        !NativeLibrary.cleanupDebt.contains(where: { $0 === operation }) {
        NativeLibrary.cleanupDebt.append(operation)
      }
    }
  }

  func identify(_ runID: String, withReply reply: @escaping (Data) -> Void) {
    lock.lock()
    let permitted =
      !identified && !accepted && TopologyFixtures.validRunID(runID)
      && TopologyFixtures.profileMatches(TopologyIdentity.worker)
    identified = true
    identifiedRun = permitted ? runID : nil
    lock.unlock()
    guard permitted else {
      reply(TopologyFixtures.json(["status": "blocked"]))
      return
    }
    // This method activates/binds the live peer, but never initializes
    // PDFium, accepts a descriptor, or performs a file/network probe.
    reply(TopologyFixtures.json(["runID": runID, "pid": Int(getpid())]))
  }

  func inspect(_ runID: String, pdf: FileHandle, withReply reply: @escaping (Data) -> Void) {
    // Only one bounded inspection per connection; never queue unbounded FDs.
    lock.lock()
    let permitted = !accepted && identifiedRun == runID && TopologyFixtures.validRunID(runID)
    accepted = true
    lock.unlock()
    guard permitted else {
      try? pdf.close()
      reply(TopologyFixtures.json(["status": "failed"]))
      return
    }
    let work = Inspection(runID: runID, pdf: pdf, reply: reply)
    Self.queue.async { self.inspect(work) }
  }

  private final class Inspection: @unchecked Sendable {
    let runID: String
    let pdf: FileHandle
    let reply: (Data) -> Void
    let deadline = DispatchTime.now().uptimeNanoseconds + 10_000_000_000
    var own: TopologyOwnedFixtures?
    var cases: [[String: Any]] = []
    var initialized = false
    var finished = false
    init(runID: String, pdf: FileHandle, reply: @escaping (Data) -> Void) {
      self.runID = runID
      self.pdf = pdf
      self.reply = reply
    }
  }

  private func inspect(_ work: Inspection) {
    let matched = TopologyFixtures.profileMatches(TopologyIdentity.worker)
    guard matched, DispatchTime.now().uptimeNanoseconds < work.deadline else {
      finish(work, status: "blocked", matched: false)
      return
    }
    let root = URL(fileURLWithPath: NSHomeDirectory())
      .appendingPathComponent("Library/Application Support/PaperLensTopology")
    guard let own = TopologyOwnedFixtures(root: root, runID: work.runID),
      own.prepareLinks(["M", "A", "C", "E", "G"]), own.checkLinks()
    else {
      finish(work, status: "blocked", matched: true)
      return
    }
    work.own = own
    Self.queue.asyncAfter(deadline: DispatchTime(uptimeNanoseconds: work.deadline)) {
      self.finish(work, status: "blocked", matched: true)
    }
    fence(work, phase: "pre")
  }

  private func fence(_ work: Inspection, phase: String) {
    guard !work.finished, let own = work.own,
      DispatchTime.now().uptimeNanoseconds < work.deadline
    else {
      finish(work, status: "blocked", matched: true)
      return
    }
    let intervals: [[String: Any]] =
      phase == "post"
      ? work.cases.compactMap { row in
        guard row["syscallObserved"] as? Bool == true,
          let id = row["caseID"] as? String,
          let began = row["beganAtNs"] as? Int64, let ended = row["endedAtNs"] as? Int64
        else { return nil }
        return ["caseID": id, "beganAtNs": began, "endedAtNs": ended]
      } : []
    let now = DispatchTime.now().uptimeNanoseconds
    let remaining = work.deadline > now ? Int((work.deadline - now) / 1_000_000) : 0
    guard remaining > 0 else {
      finish(work, status: "blocked", matched: true)
      return
    }
    TopologyReadiness.fence(
      directory: own.descriptor, runID: work.runID, phase: phase,
      actors: [["role": "PDFiumXPC", "pid": Int(getpid())]],
      links: own.links, intervals: intervals, ownerControl: own.checkLinks(),
      timeoutMs: min(2000, remaining)
    ) { accepted in
      Self.queue.async {
        guard !work.finished else { return }
        guard accepted, DispatchTime.now().uptimeNanoseconds < work.deadline else {
          self.finish(work, status: "blocked", matched: true)
          return
        }
        if phase == "pre" {
          self.probes(work)
        } else {
          self.finish(work, status: "inconclusive", matched: true)
        }
      }
    }
  }

  private func probes(_ work: Inspection) {
    guard !work.finished, DispatchTime.now().uptimeNanoseconds < work.deadline else { return }
    guard NativeLibrary.reserve() else {
      finish(work, status: "blocked", matched: true)
      return
    }
    FPDF_InitLibrary()
    defer { FPDF_DestroyLibrary(); NativeLibrary.reserved = false }
    work.initialized = true
    guard DispatchTime.now().uptimeNanoseconds < work.deadline else {
      finish(work, status: "blocked", matched: true)
      return
    }
    var cases: [[String: Any]] = []
    let fd = work.pdf.fileDescriptor
    var info = stat()
    var bytes = [UInt8](repeating: 0, count: 4096)
    let validFile =
      fstat(fd, &info) == 0 && info.st_mode & S_IFMT == S_IFREG && info.st_size <= 4096
    guard DispatchTime.now().uptimeNanoseconds < work.deadline else {
      finish(work, status: "blocked", matched: true)
      return
    }
    let readStart = Int64(DispatchTime.now().uptimeNanoseconds)
    let count = validFile ? pread(fd, &bytes, bytes.count, 0) : 0
    let readError = validFile && count < 0 ? errno : 0
    let readEnd = Int64(DispatchTime.now().uptimeNanoseconds)
    let expected = TopologyFixtures.marker("PDF", runID: work.runID)
    var readCase = TopologyFixtures.observation(
      runID: work.runID, actor: "PDFiumXPC", alias: "PDF",
      operation: "descriptorRead", result: count, error: readError, matched: validFile,
      observed: validFile, beganAtNs: validFile ? readStart : 0,
      endedAtNs: validFile ? readEnd : 0)
    readCase["verdict"] =
      count == expected.count && Data(bytes.prefix(max(0, count))) == expected ? "pass" : "failed"
    cases.append(readCase)
    guard DispatchTime.now().uptimeNanoseconds < work.deadline else {
      work.cases = cases
      finish(work, status: "blocked", matched: true)
      return
    }
    var byte = expected.first!
    let writeStart = Int64(DispatchTime.now().uptimeNanoseconds)
    let written = validFile ? pwrite(fd, &byte, 1, 0) : 0
    let writeError = written < 0 ? errno : 0
    let writeEnd = Int64(DispatchTime.now().uptimeNanoseconds)
    var writeCase = TopologyFixtures.observation(
      runID: work.runID, actor: "PDFiumXPC", alias: "PDF",
      operation: "descriptorWrite", result: written, error: writeError, matched: validFile,
      observed: validFile, beganAtNs: validFile ? writeStart : 0,
      endedAtNs: validFile ? writeEnd : 0)
    // EBADF establishes only the read-only descriptor capability, not sandbox denial.
    writeCase["verdict"] = written < 0 && writeError == EBADF ? "pass" : "failed"
    cases.append(writeCase)
    guard DispatchTime.now().uptimeNanoseconds < work.deadline else {
      work.cases = cases
      finish(work, status: "blocked", matched: true)
      return
    }
    cases.append(
      TopologyFixtures.probe(
        runID: work.runID, actor: "PDFiumXPC", alias: "PDF", operation: "write"))
    for alias in ["M", "A", "C", "E", "G"] {
      for operation in ["read", "write", "symlinkRead"] {
        guard DispatchTime.now().uptimeNanoseconds < work.deadline else {
          work.cases = cases
          finish(work, status: "blocked", matched: true)
          return
        }
        cases.append(
          TopologyFixtures.probe(
            runID: work.runID, actor: "PDFiumXPC", alias: alias,
            operation: operation, symlinkDirectory: work.own?.descriptor))
      }
    }
    if work.deadline - min(work.deadline, DispatchTime.now().uptimeNanoseconds) >= 2_000_000_000 {
      cases.append(
        TopologyFixtures.network(runID: work.runID, actor: "PDFiumXPC", expectAllowed: false))
    } else {
      cases.append(
        TopologyFixtures.observation(
          runID: work.runID, actor: "PDFiumXPC", alias: "network", operation: "connect",
          result: 0, matched: false))
    }
    work.cases = cases
    fence(work, phase: "post")
  }

  private func finish(_ work: Inspection, status: String, matched: Bool) {
    guard !work.finished else { return }
    work.finished = true
    let cleaned = work.own?.cleanup() ?? true
    work.own = nil
    try? work.pdf.close()
    work.reply(
      TopologyFixtures.json([
        "status": cleaned ? status : "failed", "pdfiumInitialized": work.initialized,
        "expectedRootMatched": matched, "cases": work.cases,
      ]))
  }
}

private final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
  func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection)
    -> Bool
  {
    connection.setCodeSigningRequirement(TopologyIdentity.requirement(TopologyIdentity.main))
    connection.exportedInterface = PDFiumExtractionInterface.make()
    let service = PDFService()
    connection.exportedObject = service
    connection.invalidationHandler = { service.invalidated() }
    connection.interruptionHandler = { service.invalidated() }
    connection.resume()
    return true
  }
}

@main
private enum PDFiumServiceMain {
  static func main() {
    let delegate = ListenerDelegate()
    let listener = NSXPCListener.service()
    listener.delegate = delegate
    withExtendedLifetime(delegate) {
      listener.resume()
    }
  }
}
