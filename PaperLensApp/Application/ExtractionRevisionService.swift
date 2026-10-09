import Foundation
import Darwin
#if SWIFT_PACKAGE
import ProviderRequest
#endif

public enum ExtractionError: String, Error, Sendable {
  case producerUnavailable, geometryUnavailable, invalidBatch, staleAttempt, interrupted, storageFailure
}

public struct ExtractionIdentity: Equatable, Sendable {
  public let paperID: UUID
  public let generation: UUID
  public let pdfSHA256: String
  public let pdfReference: String
  public let revision: UUID
  public let job: UUID
  public let attempt: UUID
  public let fence: UUID
  public let correlation: UUID
  public let input: UUID
  public let epoch: UUID
  public let configuration: ProviderConfiguration
}

public struct ExtractionSentenceIdentity: Equatable, Sendable {
  public let paperID: UUID
  public let pdfSHA256: String
  public let revision: UUID
  public let page: Int
  public let sentenceID: Int
}

/// Implemented only by the actual PDFium typed boundary; never an untyped JSON envelope.
public protocol ExtractionGeometryInput: Sendable {}
public struct ExtractionGeometryEncoding: Sendable {
  public let canonicalBytes: Data
  public let quadCount: Int
}
public protocol ExtractionGeometryValidating: Sendable {
  /// Must verify actual membership, canonical geometry, full semantic extent and exact text using 1.19.
  func validateAndEncode(_ input: any ExtractionGeometryInput,
    identity: ExtractionSentenceIdentity, expectedText: String) throws -> ExtractionGeometryEncoding
}
public struct ExtractionSentenceInput: Sendable {
  public let identity: ExtractionSentenceIdentity
  public let text: String
  public let geometry: any ExtractionGeometryInput
}
public struct ExtractionBatch: Sendable {
  public let identity: ExtractionIdentity
  public let sequence: Int
  public let sentences: [ExtractionSentenceInput]
  public let complete: Bool
  public let totalSentences: Int?
}
public protocol ExtractionBatchProducing: Sendable {
  /// Retains actual resource ownership through validation, transaction and disposal.
  func withBatches(_ identity: ExtractionIdentity,
    consume: @escaping @Sendable ([ExtractionBatch], ExtractionConsumptionScope) async throws -> Void) async throws
}
/// Main-only authority over the original captured allowance; never encoded on XPC.
public struct ExtractionConsumptionScope: Sendable {
  private let checkBudgetBody: @Sendable () throws -> Void
  public init(checkBudget: @escaping @Sendable () throws -> Void) {
    self.checkBudgetBody = checkBudget
  }
  public func checkBudget() throws {
    try Task.checkCancellation()
    try checkBudgetBody()
  }
}
struct ValidatedExtractionSentence: Sendable {
  let page: Int
  let sentenceID: Int
  let text: String
  let geometry: Data
}
public struct ExtractionStatus: Sendable {
  public let state: String
  public let failure: String?
  public let usableRevision: UUID?
}
public struct ExtractionSearchHit: Sendable {
  public let revision: UUID
  public let page: Int
  public let sentenceID: Int
  public let text: String
  public let canonicalGeometry: Data
}

/// Exclusive transfer of the checked sender handle. The callbacks capture the
/// existing Main child-pin and operation/resource owner; they must validate the
/// original identity/current configuration and observe actual RSS/elapsed time.
/// No timeout, XPC invalidation or deinit is a read-pin release proof.
public final class PDFiumPinnedInput: @unchecked Sendable {
  public let operationID: UUID
  public let identity: ExtractionIdentity
  fileprivate let senderPDF: FileHandle
  public let limits: PDFiumExtractionLimits
  public let deadlineUptimeNanoseconds: UInt64
  public let pdfByteCount: Int64
  private let checkBudgetBody: @Sendable () throws -> Void
  private let releaseReadPinBody: @Sendable (UUID) async throws -> Void
  private let finishOperationBody: @Sendable (UUID) async throws -> Void
  private let stateLock = NSLock()
  private enum CapturedState: Equatable { case held, running, released, uncertain }
  private var senderState = CapturedState.held
  private var pinState = CapturedState.held
  private var resourceState = CapturedState.held
  private var consumerDisposed = false
  private var cancelled = false
  private let device: dev_t
  private let inode: ino_t

  public init(operationID: UUID, identity: ExtractionIdentity, senderPDF: FileHandle,
    limits: PDFiumExtractionLimits, deadlineUptimeNanoseconds: UInt64,
    checkBudget: @escaping @Sendable () throws -> Void,
    releaseReadPin: @escaping @Sendable (UUID) async throws -> Void,
    finishOperation: @escaping @Sendable (UUID) async throws -> Void) throws {
    let authority = try ProviderRequest()
    let now = DispatchTime.now().uptimeNanoseconds
    let maximumElapsed = UInt64(authority.limit("parserElapsedMs")).multipliedReportingOverflow(by: 1_000_000)
    guard !maximumElapsed.overflow, deadlineUptimeNanoseconds > now,
      deadlineUptimeNanoseconds - now <= maximumElapsed.partialValue,
      limits.maximumInputBytes == Int64(authority.limit("pdfBytes")),
      limits.maximumPages == authority.limit("pages"),
      limits.maximumSentences == authority.limit("sentences"),
      limits.maximumSentenceBytes == authority.limit("sentenceBytes"),
      limits.maximumTextBytes == authority.limit("textBytes"),
      limits.maximumQuadsPerSentence == authority.limit("quadsPerSentence"),
      limits.maximumQuads == authority.limit("quads"),
      limits.maximumBatchSentences == authority.limit("batchSentences"),
      limits.maximumBatchBytes == authority.limit("batchBytes"),
      limits.maximumResidentBytes <= UInt64(authority.limit("rssBytes")) else {
      throw PDFiumFailure(code: .invalidRequest)
    }
    _ = try PDFiumExtractionKey(operationID: operationID, paperID: identity.paperID,
      generation: identity.generation, revision: identity.revision, job: identity.job,
      attempt: identity.attempt, fence: identity.fence, correlation: identity.correlation,
      input: identity.input, epoch: identity.epoch, pdfSHA256: identity.pdfSHA256,
      pdfReference: identity.pdfReference)
    // Also reject a revision that the required 1.19 identity contract cannot encode.
    _ = try PDFSentenceIdentity(paperID: identity.paperID, pdfSHA256: identity.pdfSHA256,
      extractionRevision: identity.revision.uuidString.lowercased(), pageIndex: 0, sentenceID: 0)
    try checkBudget()
    let fd = senderPDF.fileDescriptor
    guard fd >= 0 else { throw PDFiumFailure(code: .invalidRequest) }
    var info = stat()
    guard fstat(fd, &info) == 0 else { throw PDFiumFailure(code: .invalidRequest, systemError: errno) }
    let flags = fcntl(fd, F_GETFL)
    guard flags >= 0 else { throw PDFiumFailure(code: .invalidRequest, systemError: errno) }
    guard flags & O_ACCMODE == O_RDONLY, info.st_mode & S_IFMT == S_IFREG,
      info.st_size > 0, info.st_size <= limits.maximumInputBytes else {
      throw PDFiumFailure(code: .invalidRequest)
    }
    self.operationID = operationID; self.identity = identity; self.senderPDF = senderPDF
    self.limits = limits; self.deadlineUptimeNanoseconds = deadlineUptimeNanoseconds
    self.pdfByteCount = Int64(info.st_size); self.device = info.st_dev; self.inode = info.st_ino
    self.checkBudgetBody = checkBudget; self.releaseReadPinBody = releaseReadPin
    self.finishOperationBody = finishOperation
  }
  func checkBudget() throws {
    stateLock.lock(); let stop = cancelled; stateLock.unlock()
    guard !stop else { throw PDFiumFailure(code: .cancelled) }
    guard DispatchTime.now().uptimeNanoseconds < deadlineUptimeNanoseconds else {
      throw PDFiumFailure(code: .resourceExceeded)
    }
    try checkBudgetBody()
  }
  func requestCancellation() {
    stateLock.lock(); cancelled = true; stateLock.unlock()
  }
  func recordConsumerDisposal() {
    stateLock.lock(); consumerDisposed = true; stateLock.unlock()
  }
  fileprivate func checkSender() throws {
    stateLock.lock(); defer { stateLock.unlock() }
    guard senderState == .held else { throw PDFiumFailure(code: .cleanupIncomplete) }
    var info = stat()
    let fd = senderPDF.fileDescriptor
    let flags = fcntl(fd, F_GETFL)
    guard fd >= 0, flags >= 0, flags & O_ACCMODE == O_RDONLY,
      fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
      info.st_dev == device, info.st_ino == inode, info.st_size == pdfByteCount else {
      throw PDFiumFailure(code: .identityMismatch)
    }
  }
  func closeSender() throws {
    stateLock.lock(); defer { stateLock.unlock() }
    if senderState == .released { return }
    guard senderState == .held else { throw PDFiumFailure(code: .cleanupIncomplete) }
    senderState = .running
    do { try senderPDF.close(); senderState = .released }
    catch { senderState = .uncertain; throw PDFiumFailure(code: .cleanupIncomplete) }
  }
  private func claimPinRelease() throws -> Bool {
    stateLock.lock(); defer { stateLock.unlock() }
    if pinState == .released { return false }
    guard senderState == .released, consumerDisposed, pinState == .held else {
      throw PDFiumFailure(code: .cleanupIncomplete)
    }
    pinState = .running; return true
  }
  private func recordPinRelease(_ success: Bool) {
    stateLock.lock(); pinState = success ? .released : .uncertain; stateLock.unlock()
  }
  func releasePinAfterConfirmedDrain() async throws {
    guard try claimPinRelease() else { return }
    do { try await releaseReadPinBody(operationID); recordPinRelease(true) }
    catch { recordPinRelease(false); throw error }
  }
  private func claimResourceRelease() throws -> Bool {
    stateLock.lock(); defer { stateLock.unlock() }
    if resourceState == .released { return false }
    guard pinState == .released, resourceState == .held else {
      throw PDFiumFailure(code: .cleanupIncomplete)
    }
    resourceState = .running; return true
  }
  private func recordResourceRelease(_ success: Bool) {
    stateLock.lock(); resourceState = success ? .released : .uncertain; stateLock.unlock()
  }
  func finishAfterDisposal() async throws {
    guard try claimResourceRelease() else { return }
    do { try await finishOperationBody(operationID); recordResourceRelease(true) }
    catch { recordResourceRelease(false); throw error }
  }
}

/// Exactly-once local waiting. A timer only fails the waiter; it never supplies
/// cleanup proof or changes session ownership when a late reply arrives.
private final class PDFiumReply<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Value, Error>?
  init(_ continuation: CheckedContinuation<Value, Error>, deadline: UInt64) {
    self.continuation = continuation
    DispatchQueue.global().asyncAfter(deadline: DispatchTime(uptimeNanoseconds: deadline)) {
      self.resolve(.failure(PDFiumFailure(code: .resourceExceeded)))
    }
  }
  func resolve(_ result: Result<Value, Error>) {
    lock.lock(); let current = continuation; continuation = nil; lock.unlock()
    current?.resume(with: result)
  }
}

public actor PDFiumExtractionProducer: ExtractionBatchProducing {
  private final class Session: @unchecked Sendable {
    let input: PDFiumPinnedInput
    let key: PDFiumExtractionKey
    let connection: NSXPCConnection
    var ack: PDFiumStartAck?
    var end: PDFiumEnd?
    var drainTask: Task<Void, Error>?
    var pinReleaseTask: Task<Void, Error>?
    var resourceReleaseTask: Task<Void, Error>?
    var began = false
    var cancelRequested = false
    var scopeReturned = false
    var cancellationFailure: Error?
    init(input: PDFiumPinnedInput, key: PDFiumExtractionKey, connection: NSXPCConnection) {
      self.input = input; self.key = key; self.connection = connection
    }
  }
  private let acquireInput: @Sendable (ExtractionIdentity, UUID) async throws -> PDFiumPinnedInput
  // Entries with uncertain cleanup remain strongly retained. No invalidation
  // handler empties this table or releases the captured Main ownership.
  private var sessions: [UUID: Session] = [:]
  private var running = false
  public init(acquireInput: @escaping @Sendable (ExtractionIdentity, UUID) async throws -> PDFiumPinnedInput) {
    self.acquireInput = acquireInput
  }

  public func withBatches(_ identity: ExtractionIdentity,
    consume: @escaping @Sendable ([ExtractionBatch], ExtractionConsumptionScope) async throws -> Void) async throws {
    guard !running, sessions.isEmpty else { throw PDFiumFailure(code: .busy) }
    running = true
    defer { running = false }
    try Task.checkCancellation()
    let operationID = UUID()
    let input = try await acquireInput(identity, operationID)
    // Never substitute the requested ID for the returned captured owner's ID.
    let key = try PDFiumExtractionKey(operationID: input.operationID, paperID: input.identity.paperID,
      generation: input.identity.generation, revision: input.identity.revision, job: input.identity.job,
      attempt: input.identity.attempt, fence: input.identity.fence, correlation: input.identity.correlation,
      input: input.identity.input, epoch: input.identity.epoch, pdfSHA256: input.identity.pdfSHA256,
      pdfReference: input.identity.pdfReference)
    let connection = NSXPCConnection(serviceName: TopologyIdentity.worker)
    connection.setCodeSigningRequirement(TopologyIdentity.requirement(TopologyIdentity.worker))
    connection.remoteObjectInterface = PDFiumExtractionInterface.make()
    let session = Session(input: input, key: key, connection: connection)
    sessions[operationID] = session
    try await withTaskCancellationHandler {
      try await run(session, operationID: operationID, identity: identity, consume: consume)
    } onCancel: {
      input.requestCancellation()
      Task { await self.signalCancellation(operationID: operationID) }
    }
  }
  private func run(_ session: Session, operationID: UUID, identity: ExtractionIdentity,
    consume: @escaping @Sendable ([ExtractionBatch], ExtractionConsumptionScope) async throws -> Void) async throws {
    let input = session.input
    let key = session.key
    let connection = session.connection
    defer { session.scopeReturned = true }
    var batches: [ExtractionBatch] = []
    do {
      guard input.operationID == operationID, input.identity == identity,
        input.identity.pdfReference.utf8.elementsEqual(identity.pdfReference.utf8) else {
        throw PDFiumFailure(code: .identityMismatch)
      }
      try input.checkBudget(); try input.checkSender(); try Task.checkCancellation()
      let request = try PDFiumExtractionRequest(key: key, pdfByteCount: input.pdfByteCount,
        limits: input.limits, deadlineUptimeNanoseconds: input.deadlineUptimeNanoseconds)
      connection.resume()
      session.began = true
      let (ack, failure) = try await start(session, request: request)
      try PDFiumExtractionReplies.validateStart(ack, failure: failure)
      if let failure { throw failure }
      guard let ack, ack.key.matches(key),
        ack.workerPID == connection.processIdentifier, ack.workerPID > 0,
        ack.observedPDFSHA256 == identity.pdfSHA256, ack.observedPDFByteCount == input.pdfByteCount,
        ack.documentPageCount <= input.limits.maximumPages else {
        throw PDFiumFailure(code: .protocolViolation)
      }
      session.ack = ack
      batches = try await collect(session, identity: identity)
      // Helper drain and sender closure do not release the consumer's read pin.
      try input.closeSender()
      try input.checkBudget(); try Task.checkCancellation()
      guard !session.cancelRequested else { throw PDFiumFailure(code: .cancelled) }
      let scope = ExtractionConsumptionScope(checkBudget: { try input.checkBudget() })
      try scope.checkBudget()
      try await consume(batches, scope)
      batches.removeAll(keepingCapacity: false)
      input.recordConsumerDisposal()
      try await releasePin(session)
      try await finishResources(session)
      connection.invalidate(); sessions.removeValue(forKey: operationID)
    } catch {
      batches.removeAll(keepingCapacity: false)
      input.recordConsumerDisposal()
      let original = error
      do {
        if session.began {
          try await cancelAndDrain(operationID: operationID)
          try await releasePin(session)
        } else {
          // No message or FD was sent: dispose the returned captured operation
          // using its own actual ID, including a mismatched acquisition.
          try await releasePin(session)
        }
        try await finishResources(session)
        connection.invalidate(); sessions.removeValue(forKey: operationID)
      } catch { throw PDFiumFailure(code: .cleanupIncomplete) }
      throw original
    }
  }

  private func signalCancellation(operationID: UUID) async {
    guard let session = sessions[operationID], session.began else { return }
    do { try await cancelAndDrain(operationID: operationID) }
    catch { session.cancellationFailure = error }
  }

  public func cancelAndDrain(operationID: UUID) async throws {
    guard let session = sessions[operationID], session.key.operationID == operationID, session.began else {
      throw PDFiumFailure(code: .identityMismatch)
    }
    session.cancelRequested = true
    session.input.requestCancellation()
    if let task = session.drainTask { try await task.value }
    else {
      let task = Task { try await self.drain(session) }
      session.drainTask = task
      do { try await task.value }
      catch { session.drainTask = nil; throw error }
    }
    if session.scopeReturned {
      try await releasePin(session)
      try await finishResources(session)
      session.connection.invalidate(); sessions.removeValue(forKey: operationID)
    }
  }

  private func drain(_ session: Session) async throws {
    if session.end == nil {
      let (end, failure) = try await cancel(session)
      guard let end, failure == nil || end.disposition == .failed else {
        throw failure ?? PDFiumFailure(code: .cleanupIncomplete)
      }
      try validateEnd(end, session: session)
      session.end = end
    }
    try session.input.closeSender()
  }
  private func releasePin(_ session: Session) async throws {
    if let task = session.pinReleaseTask { try await task.value; return }
    try session.input.closeSender()
    let input = session.input
    let task = Task { try await input.releasePinAfterConfirmedDrain() }
    session.pinReleaseTask = task
    try await task.value
  }
  private func finishResources(_ session: Session) async throws {
    if let task = session.resourceReleaseTask { try await task.value; return }
    let input = session.input
    let task = Task { try await input.finishAfterDisposal() }
    session.resourceReleaseTask = task
    try await task.value
  }
  private func validateEnd(_ end: PDFiumEnd, session: Session) throws {
    if let previous = session.end {
      guard previous.key.matches(end.key), previous.disposition == end.disposition,
        previous.lastSequence == end.lastSequence, previous.totalSentences == end.totalSentences,
        previous.processedPageCount == end.processedPageCount,
        previous.documentPageCount == end.documentPageCount,
        previous.observedPDFSHA256 == end.observedPDFSHA256 else {
        throw PDFiumFailure(code: .protocolViolation)
      }
    }
    guard end.key.matches(session.key), end.observedPDFSHA256 == session.key.pdfSHA256,
      end.totalSentences <= session.input.limits.maximumSentences,
      end.documentPageCount <= Int(Int32.max),
      end.disposition != .completed || end.documentPageCount <= session.input.limits.maximumPages,
      end.lastSequence < session.input.limits.maximumSentences,
      session.ack.map({ $0.documentPageCount == end.documentPageCount }) ?? true else {
      throw PDFiumFailure(code: .protocolViolation)
    }
  }
  private func observeDrain(_ end: PDFiumEnd?, failure: PDFiumFailure?, session: Session) {
    guard sessions[session.key.operationID] === session, let end,
      failure == nil || end.disposition == .failed else { return }
    do { try validateEnd(end, session: session); session.end = end }
    catch { session.cancellationFailure = error }
    // Recording same-operation proof is not publication or resource release.
  }
  private func start(_ session: Session, request: PDFiumExtractionRequest) async throws
    -> (PDFiumStartAck?, PDFiumFailure?) {
    try await withCheckedThrowingContinuation { continuation in
      let box = PDFiumReply(continuation, deadline: session.input.deadlineUptimeNanoseconds)
      guard let proxy = session.connection.remoteObjectProxyWithErrorHandler({ error in
        box.resolve(.failure(error))
      }) as? PDFiumExtractionService else { box.resolve(.failure(PDFiumFailure(code: .protocolViolation))); return }
      proxy.beginExtraction(request, pdf: session.input.senderPDF) { ack, failure in
        box.resolve(.success((ack, failure)))
      }
    }
  }
  private func pull(_ session: Session, sequence: Int) async throws
    -> (PDFiumBatch?, PDFiumEnd?, PDFiumFailure?) {
    try await withCheckedThrowingContinuation { continuation in
      let box = PDFiumReply(continuation, deadline: session.input.deadlineUptimeNanoseconds)
      guard let proxy = session.connection.remoteObjectProxyWithErrorHandler({ error in
        box.resolve(.failure(error))
      }) as? PDFiumExtractionService else { box.resolve(.failure(PDFiumFailure(code: .protocolViolation))); return }
      proxy.nextExtractionBatch(session.key.operationID as NSUUID, sequence: sequence) { batch, end, failure in
        box.resolve(.success((batch, end, failure)))
      }
    }
  }
  private func cancel(_ session: Session) async throws -> (PDFiumEnd?, PDFiumFailure?) {
    // An expired original deadline is NOT extended for another trial. Still send
    // the serial cancellation request; a late drain requires explicit owner proof.
    try await withCheckedThrowingContinuation { continuation in
      let box = PDFiumReply(continuation, deadline: session.input.deadlineUptimeNanoseconds)
      guard let proxy = session.connection.remoteObjectProxyWithErrorHandler({ error in
        box.resolve(.failure(error))
      }) as? PDFiumExtractionService else { box.resolve(.failure(PDFiumFailure(code: .protocolViolation))); return }
      proxy.cancelExtractionAndDrain(session.key.operationID as NSUUID) { end, failure in
        Task { await self.observeDrain(end, failure: failure, session: session) }
        box.resolve(.success((end, failure)))
      }
    }
  }
  private func samePage(_ lhs: PDFiumRawPage, _ rhs: PDFiumRawPage) -> Bool {
    lhs.pageIndex == rhs.pageIndex && lhs.rotationQuarterTurns == rhs.rotationQuarterTurns
      && lhs.boundingBox.coordinates == rhs.boundingBox.coordinates
      && lhs.mediaBox?.coordinates == rhs.mediaBox?.coordinates
      && lhs.cropBox?.coordinates == rhs.cropBox?.coordinates
  }
  private func collect(_ session: Session, identity: ExtractionIdentity) async throws -> [ExtractionBatch] {
    guard let ack = session.ack else { throw PDFiumFailure(code: .protocolViolation) }
    let limits = session.input.limits
    var output: [ExtractionBatch] = []
    var pages: [Int: PDFiumRawPage] = [:]
    var sentenceCount = 0; var textBytes = 0; var quadCount = 0
    var lastPage = -1; var pageUTF16End = 0; var pageNativeEnd = 0
    while true {
      try Task.checkCancellation(); try session.input.checkBudget()
      guard output.count < limits.maximumSentences else { throw PDFiumFailure(code: .resourceExceeded) }
      let (batch, end, failure) = try await pull(session, sequence: output.count)
      try PDFiumExtractionReplies.validatePull(batch, end: end, failure: failure)
      if let failure {
        if let end { try validateEnd(end, session: session); session.end = end }
        throw failure
      }
      guard let batch, batch.key.matches(session.key), batch.sequence == output.count,
        batch.sentences.count <= limits.maximumBatchSentences,
        batch.complete == (end != nil), batch.complete == (batch.totalSentences != nil) else {
        throw PDFiumFailure(code: .protocolViolation)
      }
      guard let envelope = PDFiumBatch.maximumEnvelopePayloadBytes(key: session.key),
        envelope <= limits.maximumBatchBytes else { throw PDFiumFailure(code: .resourceExceeded) }
      var batchBytes = envelope
      for page in batch.pages {
        guard page.pageIndex < ack.documentPageCount else { throw PDFiumFailure(code: .protocolViolation) }
        if let previous = pages[page.pageIndex], !samePage(previous, page) {
          throw PDFiumFailure(code: .protocolViolation)
        }
        guard page.payloadBytes <= limits.maximumBatchBytes,
          batchBytes <= limits.maximumBatchBytes - page.payloadBytes else { throw PDFiumFailure(code: .resourceExceeded) }
        batchBytes += page.payloadBytes; pages[page.pageIndex] = page
      }
      var sentences: [ExtractionSentenceInput] = []
      for sentence in batch.sentences {
        try Task.checkCancellation(); try session.input.checkBudget()
        let bytes = sentence.text.utf8.count
        let quads = sentence.glyphs.reduce(0) { $0 + ($1.rawQuad == nil ? 0 : 1) }
        guard sentence.paperID == identity.paperID, sentence.revision == identity.revision,
          sentence.pdfSHA256 == identity.pdfSHA256, sentence.sentenceID == sentenceCount,
          sentence.pageIndex >= lastPage, sentence.pageIndex < ack.documentPageCount,
          let rawPage = pages[sentence.pageIndex],
          batch.pages.contains(where: { $0.pageIndex == sentence.pageIndex }),
          bytes <= limits.maximumSentenceBytes, textBytes <= limits.maximumTextBytes - bytes,
          quads > 0, quads <= limits.maximumQuadsPerSentence,
          quadCount <= limits.maximumQuads - quads, sentenceCount < limits.maximumSentences,
          let payload = sentence.payloadBytes, payload <= limits.maximumBatchBytes,
          batchBytes <= limits.maximumBatchBytes - payload else {
          throw PDFiumFailure(code: .protocolViolation)
        }
        if sentence.pageIndex != lastPage {
          pageUTF16End = 0; pageNativeEnd = 0; lastPage = sentence.pageIndex
        }
        guard sentence.sourceUTF16Start == pageUTF16End, sentence.nativeStartCharacter == pageNativeEnd,
          sentence.sourceUTF16Start <= Int.max - sentence.sourceUTF16Length,
          sentence.nativeStartCharacter <= Int.max - sentence.nativeCharacterCount else {
          throw PDFiumFailure(code: .unmappableText)
        }
        pageUTF16End += sentence.sourceUTF16Length; pageNativeEnd += sentence.nativeCharacterCount
        let sentenceIdentity = ExtractionSentenceIdentity(paperID: identity.paperID,
          pdfSHA256: identity.pdfSHA256, revision: identity.revision, page: sentence.pageIndex,
          sentenceID: sentence.sentenceID)
        let geometry = PDFiumGeometryInput(identity: sentenceIdentity, sourceText: sentence.text,
          nativeStartCharacter: sentence.nativeStartCharacter, nativeCharacterCount: sentence.nativeCharacterCount,
          rawPage: rawPage, glyphs: sentence.glyphs)
        sentences.append(ExtractionSentenceInput(identity: sentenceIdentity, text: sentence.text, geometry: geometry))
        sentenceCount += 1; textBytes += bytes; quadCount += quads; batchBytes += payload
        try session.input.checkBudget()
      }
      if let end {
        try validateEnd(end, session: session)
        guard end.disposition == .completed, end.lastSequence == batch.sequence,
          end.totalSentences == sentenceCount, batch.totalSentences == sentenceCount,
          end.processedPageCount == ack.documentPageCount else { throw PDFiumFailure(code: .protocolViolation) }
        session.end = end
      }
      try session.input.checkBudget()
      output.append(ExtractionBatch(identity: identity, sequence: batch.sequence, sentences: sentences,
        complete: batch.complete, totalSentences: batch.totalSentences))
      if batch.complete { return output }
    }
  }
}

public struct PDFiumPageMapping: Sendable {
  public let page: PDFPageGeometry
  public let rawToCanonical: PDFGeometryAffine
  public let canonicalToReader: PDFGeometryAffine
  public init(page: PDFPageGeometry, rawToCanonical: PDFGeometryAffine,
    canonicalToReader: PDFGeometryAffine) {
    self.page = page; self.rawToCanonical = rawToCanonical; self.canonicalToReader = canonicalToReader
  }
}
public struct PDFiumGeometryBinding: Sendable {
  public let precision: PDFGeometryPrecision
  public let mapPage: @Sendable (PDFiumRawPage) throws -> PDFiumPageMapping
  public let encodeCanonicalAnchor: @Sendable (PDFSentenceAnchor) throws -> Data
  public init(precision: PDFGeometryPrecision,
    mapPage: @escaping @Sendable (PDFiumRawPage) throws -> PDFiumPageMapping,
    encodeCanonicalAnchor: @escaping @Sendable (PDFSentenceAnchor) throws -> Data) {
    self.precision = precision; self.mapPage = mapPage; self.encodeCanonicalAnchor = encodeCanonicalAnchor
  }
}
public struct PDFiumGeometryInput: ExtractionGeometryInput {
  public let identity: ExtractionSentenceIdentity
  public let sourceText: String
  public let nativeStartCharacter: Int
  public let nativeCharacterCount: Int
  public let rawPage: PDFiumRawPage
  public let glyphs: [PDFiumGlyph]
  public init(identity: ExtractionSentenceIdentity, sourceText: String, nativeStartCharacter: Int,
    nativeCharacterCount: Int, rawPage: PDFiumRawPage, glyphs: [PDFiumGlyph]) {
    self.identity = identity; self.sourceText = sourceText; self.nativeStartCharacter = nativeStartCharacter
    self.nativeCharacterCount = nativeCharacterCount; self.rawPage = rawPage; self.glyphs = glyphs
  }
}
public struct PDFiumGeometryValidator: ExtractionGeometryValidating {
  private let binding: PDFiumGeometryBinding
  public init(binding: PDFiumGeometryBinding) { self.binding = binding }
  public func validateAndEncode(_ input: any ExtractionGeometryInput,
    identity: ExtractionSentenceIdentity, expectedText: String) throws -> ExtractionGeometryEncoding {
    guard let input = input as? PDFiumGeometryInput, input.identity == identity,
      input.rawPage.pageIndex == identity.page, input.sourceText.utf8.elementsEqual(expectedText.utf8),
      !expectedText.isEmpty, input.nativeStartCharacter >= 0, input.nativeCharacterCount > 0,
      input.glyphs.count == input.nativeCharacterCount, let first = input.glyphs.first else {
      throw ExtractionError.invalidBatch
    }
    let anchorIdentity = try PDFSentenceIdentity(paperID: identity.paperID,
      pdfSHA256: identity.pdfSHA256, extractionRevision: identity.revision.uuidString.lowercased(),
      pageIndex: identity.page, sentenceID: identity.sentenceID)
    let mapping = try binding.mapPage(input.rawPage)
    guard mapping.page.pageIndex == identity.page,
      mapping.page.rotation == input.rawPage.rotationQuarterTurns * 90 else {
      throw PDFGeometryError.identityMismatch
    }
    var text = String.UnicodeScalarView()
    var position = first.utf16Start
    var quads: [PDFQuad] = []
    for (index, glyph) in input.glyphs.enumerated() {
      let native = input.nativeStartCharacter.addingReportingOverflow(index)
      guard !native.overflow, glyph.nativeCharacterIndex == native.partialValue,
        glyph.utf16Start == position, let scalar = Unicode.Scalar(glyph.unicodeScalar),
        glyph.unicodeScalar != 0, glyph.utf16Length == String(scalar).utf16.count,
        position <= Int.max - glyph.utf16Length else { throw PDFGeometryError.malformedGeometry }
      position += glyph.utf16Length; text.append(scalar)
      guard let raw = glyph.rawQuad else {
        guard CharacterSet.whitespacesAndNewlines.contains(scalar) else {
          throw PDFGeometryError.missingGeometry
        }
        continue
      }
      guard glyph.matrixA > 0, glyph.matrixD > 0, glyph.matrixB == 0, glyph.matrixC == 0,
        [glyph.matrixA, glyph.matrixB, glyph.matrixC, glyph.matrixD, glyph.matrixE, glyph.matrixF]
          .allSatisfy(\.isFinite) else { throw PDFGeometryError.unsupportedRotation }
      let rawPoints = [PDFPoint(x: raw.topLeftX, y: raw.topLeftY),
        PDFPoint(x: raw.topRightX, y: raw.topRightY),
        PDFPoint(x: raw.bottomRightX, y: raw.bottomRightY),
        PDFPoint(x: raw.bottomLeftX, y: raw.bottomLeftY)]
      var canonical: [PDFPoint] = []
      for point in rawPoints {
        let converted = try mapping.rawToCanonical.applying(point)
        try mapping.page.validate(converted)
        let rawRoundtrip = try mapping.rawToCanonical.inverse(converted)
        try binding.precision.validate(expected: converted,
          actual: mapping.rawToCanonical.applying(rawRoundtrip))
        let reader = try mapping.canonicalToReader.applying(converted)
        try binding.precision.validate(expected: converted,
          actual: mapping.canonicalToReader.inverse(reader))
        canonical.append(converted)
      }
      quads.append(try PDFQuad(topLeft: canonical[0], topRight: canonical[1],
        bottomRight: canonical[2], bottomLeft: canonical[3], page: mapping.page))
    }
    guard String(text).utf8.elementsEqual(expectedText.utf8),
      position - first.utf16Start == expectedText.utf16.count, !quads.isEmpty else {
      throw PDFGeometryError.malformedGeometry
    }
    // This is delivered-revision membership, NOT invented published membership.
    // Publication and subsequent resolution remain with the existing DB/1.19 owners.
    let anchor = try PDFSentenceAnchor(identity: anchorIdentity, fullSourceQuote: expectedText,
      page: mapping.page, quads: quads)
    let bytes = try binding.encodeCanonicalAnchor(anchor)
    guard !bytes.isEmpty else { throw PDFGeometryError.missingGeometry }
    return ExtractionGeometryEncoding(canonicalBytes: bytes, quadCount: quads.count)
  }
}

private final class ExtractionPublicationObservation: @unchecked Sendable {
  private let lock = NSLock()
  private var published = false
  func recordPublication() { lock.lock(); published = true; lock.unlock() }
  var didPublish: Bool { lock.lock(); defer { lock.unlock() }; return published }
}

public struct ExtractionRevisionService: Sendable {
  public let database: ProductDatabase
  public let producer: (any ExtractionBatchProducing)?
  public let geometryValidator: (any ExtractionGeometryValidating)?

  public func parse(_ identity: ExtractionIdentity) async throws {
    guard let producer else { throw ExtractionError.producerUnavailable }
    guard let geometryValidator else { throw ExtractionError.geometryUnavailable }
    try await Task.detached { try database.reserveExtraction(identity) }.value
    try await consumeReserved(identity, producer: producer, validator: geometryValidator)
  }

  func consumeReserved(_ identity: ExtractionIdentity, producer: any ExtractionBatchProducing,
    validator: any ExtractionGeometryValidating) async throws {
    let database = database
    let observation = ExtractionPublicationObservation()
    do {
      try await producer.withBatches(identity) { batches, scope in
        try scope.checkBudget()
        let sentences = try Self.validate(batches, identity: identity, validator: validator,
          scope: scope)
        try scope.checkBudget()
        try await Task.detached {
          try database.publishExtraction(identity, sentences: sentences,
            checkBudget: { try scope.checkBudget() })
        }.value
        observation.recordPublication()
      }
    } catch {
      // A post-commit resource-owner cleanup failure is still an error/debt, but
      // cannot truthfully turn an already committed revision into a failed Job.
      // Pin/accounting cleanup can fail after publication; keep that debt distinct.
      guard !observation.didPublish else { throw error }
      let failure = (error as? ExtractionError) ?? .storageFailure
      try await Task.detached { try database.failExtraction(identity, failure: failure) }.value
      throw error
    }
  }

  static func validate(_ batches: [ExtractionBatch], identity: ExtractionIdentity,
    validator: any ExtractionGeometryValidating,
    scope: ExtractionConsumptionScope) throws -> [ValidatedExtractionSentence] {
    try scope.checkBudget()
    let authority = try ProviderRequest()
    guard !batches.isEmpty, batches.count <= authority.limit("sentences") else {
      throw ExtractionError.invalidBatch
    }
    var output: [ValidatedExtractionSentence] = []
    var textBytes = 0
    var quads = 0
    for (index, batch) in batches.enumerated() {
      try scope.checkBudget()
      guard batch.identity == identity, batch.sequence == index,
        batch.complete == (index == batches.count - 1), !batch.sentences.isEmpty,
        batch.sentences.count <= authority.limit("batchSentences"),
        batch.complete || batch.totalSentences == nil else { throw ExtractionError.invalidBatch }
      var batchBytes = 0
      for sentence in batch.sentences {
        try scope.checkBudget()
        let key = sentence.identity
        guard key.paperID == identity.paperID, key.pdfSHA256 == identity.pdfSHA256,
          key.revision == identity.revision, key.page >= 0, key.page < authority.limit("pages"),
          key.sentenceID >= 0, key.sentenceID < authority.limit("sentences"),
          key.sentenceID == output.count, output.last.map({ $0.page <= key.page }) ?? true,
          !sentence.text.isEmpty,
          sentence.text.utf8.count <= authority.limit("sentenceBytes") else {
          throw ExtractionError.invalidBatch
        }
        let geometry = try validator.validateAndEncode(sentence.geometry, identity: key,
          expectedText: sentence.text)
        try scope.checkBudget()
        guard !geometry.canonicalBytes.isEmpty, geometry.quadCount > 0,
          geometry.quadCount <= authority.limit("quadsPerSentence"),
          geometry.canonicalBytes.count <= authority.limit("batchBytes") else {
          throw ExtractionError.invalidBatch
        }
        batchBytes += sentence.text.utf8.count + geometry.canonicalBytes.count
        textBytes += sentence.text.utf8.count
        quads += geometry.quadCount
        guard batchBytes <= authority.limit("batchBytes"), textBytes <= authority.limit("textBytes"),
          quads <= authority.limit("quads"), output.count < authority.limit("sentences") else {
          throw ExtractionError.invalidBatch
        }
        output.append(.init(page: key.page, sentenceID: key.sentenceID,
          text: sentence.text, geometry: geometry.canonicalBytes))
      }
    }
    guard batches.last?.totalSentences == output.count else { throw ExtractionError.invalidBatch }
    try scope.checkBudget()
    return output
  }
}
