import Darwin
import Foundation
import ProviderRequest
import XCTest
@testable import PaperLensProduct

/// Synthetic local ownership/budget fixtures only. No PDFium, helper launch,
/// renderer, vendor library, product DB, or production resource callback is used.
final class PDFiumExtractionProducerTests: XCTestCase {
  private final class FixtureState: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []
    private var stopped = false
    private var clock: UInt64 = 1
    let deadline: UInt64 = 10
    func record(_ event: String) { lock.lock(); events.append(event); lock.unlock() }
    func snapshot() -> [String] { lock.lock(); defer { lock.unlock() }; return events }
    func cancel() { lock.lock(); stopped = true; lock.unlock() }
    func expire() { lock.lock(); clock = deadline; lock.unlock() }
    func check() throws {
      lock.lock(); defer { lock.unlock() }
      if stopped { throw PDFiumFailure(code: .cancelled) }
      if clock >= deadline { throw PDFiumFailure(code: .resourceExceeded) }
    }
  }
  private actor ReleaseGate {
    private var started = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    func hold() async {
      await withCheckedContinuation { continuation in
        releaseWaiter = continuation
        started = true
        startWaiter?.resume(); startWaiter = nil
      }
    }
    func waitForStart() async {
      if started { return }
      await withCheckedContinuation { startWaiter = $0 }
    }
    func open() { releaseWaiter?.resume(); releaseWaiter = nil }
  }
  private struct FixtureGeometry: ExtractionGeometryInput {}
  private struct FixtureValidator: ExtractionGeometryValidating {
    let state: FixtureState
    let expire: Bool
    func validateAndEncode(_ input: any ExtractionGeometryInput,
      identity: ExtractionSentenceIdentity, expectedText: String) throws -> ExtractionGeometryEncoding {
      state.record("canonical")
      if expire { state.expire() } else { state.cancel() }
      return .init(canonicalBytes: Data([1]), quadCount: 1)
    }
  }
  private func identity(reference: String = "synthetic.pdf",
    copying original: ExtractionIdentity? = nil) -> ExtractionIdentity {
    .init(paperID: original?.paperID ?? UUID(), generation: original?.generation ?? UUID(),
      pdfSHA256: original?.pdfSHA256 ?? String(repeating: "a", count: 64),
      pdfReference: reference, revision: original?.revision ?? UUID(), job: original?.job ?? UUID(),
      attempt: original?.attempt ?? UUID(), fence: original?.fence ?? UUID(),
      correlation: original?.correlation ?? UUID(), input: original?.input ?? UUID(),
      epoch: original?.epoch ?? UUID(), configuration: original?.configuration
        ?? ProviderConfiguration(slotID: nil, generation: 0, model: nil))
  }
  private func limits() throws -> PDFiumExtractionLimits {
    let a = try ProviderRequest()
    return try .init(maximumInputBytes: Int64(a.limit("pdfBytes")), maximumPages: a.limit("pages"),
      maximumSentences: a.limit("sentences"), maximumSentenceBytes: a.limit("sentenceBytes"),
      maximumTextBytes: a.limit("textBytes"), maximumQuadsPerSentence: a.limit("quadsPerSentence"),
      maximumQuads: a.limit("quads"), maximumBatchSentences: a.limit("batchSentences"),
      maximumBatchBytes: a.limit("batchBytes"), maximumResidentBytes: UInt64(a.limit("rssBytes")))
  }
  private func input(_ id: ExtractionIdentity, operationID: UUID = UUID(),
    state: FixtureState, gate: ReleaseGate? = nil) throws -> (PDFiumPinnedInput, URL) {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data([1]).write(to: url)
    let handle = try FileHandle(forReadingFrom: url)
    do {
      return (try PDFiumPinnedInput(operationID: operationID, identity: id, senderPDF: handle,
        limits: limits(), deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 1_000_000_000,
        checkBudget: { try state.check() }, releaseReadPin: { _ in
          state.record("pin")
          if let gate { await gate.hold() }
        }, finishOperation: { _ in state.record("accounting") }), url)
    } catch { try handle.close(); try FileManager.default.removeItem(at: url); throw error }
  }
  private func key(_ id: ExtractionIdentity) throws -> PDFiumExtractionKey {
    try .init(operationID: UUID(), paperID: id.paperID, generation: id.generation,
      revision: id.revision, job: id.job, attempt: id.attempt, fence: id.fence,
      correlation: id.correlation, input: id.input, epoch: id.epoch,
      pdfSHA256: id.pdfSHA256, pdfReference: id.pdfReference)
  }

  func testSenderDrainDoesNotReleasePinAndDisposalPrecedesAccounting() async throws {
    let state = FixtureState()
    let (owner, url) = try input(identity(), state: state)
    defer { try? FileManager.default.removeItem(at: url) }
    try owner.closeSender()
    do { try await owner.releasePinAfterConfirmedDrain(); XCTFail("released during consumption") }
    catch { XCTAssertEqual((error as? PDFiumFailure)?.code, .cleanupIncomplete) }
    XCTAssertEqual(state.snapshot(), [])
    state.record("raw+canonical disposed")
    owner.recordConsumerDisposal()
    try await owner.releasePinAfterConfirmedDrain()
    try await owner.finishAfterDisposal()
    try await owner.releasePinAfterConfirmedDrain()
    try await owner.finishAfterDisposal()
    XCTAssertEqual(state.snapshot(), ["raw+canonical disposed", "pin", "accounting"])
  }

  func testReentrantReleaseCannotFinishAccountingDuringPinCallback() async throws {
    let state = FixtureState(), gate = ReleaseGate()
    let (owner, url) = try input(identity(), state: state, gate: gate)
    defer { try? FileManager.default.removeItem(at: url) }
    try owner.closeSender(); owner.recordConsumerDisposal()
    let release = Task { try await owner.releasePinAfterConfirmedDrain() }
    await gate.waitForStart()
    do { try await owner.releasePinAfterConfirmedDrain(); XCTFail("reentrant release") }
    catch { XCTAssertEqual((error as? PDFiumFailure)?.code, .cleanupIncomplete) }
    do { try await owner.finishAfterDisposal(); XCTFail("premature accounting") }
    catch { XCTAssertEqual((error as? PDFiumFailure)?.code, .cleanupIncomplete) }
    await gate.open(); try await release.value
    try await owner.finishAfterDisposal()
    XCTAssertEqual(state.snapshot(), ["pin", "accounting"])
  }

  func testCancellationAndOriginalAllowanceSurviveDetachedConsumption() async throws {
    for cancel in [true, false] {
      let state = FixtureState()
      let (owner, url) = try input(identity(), state: state)
      defer { try? FileManager.default.removeItem(at: url) }
      try owner.closeSender()
      let scope = ExtractionConsumptionScope(checkBudget: { try owner.checkBudget() })
      try scope.checkBudget()
      if cancel { owner.requestCancellation() } else { state.expire() }
      do { try await Task.detached { try scope.checkBudget() }.value; XCTFail("budget renewed") }
      catch { XCTAssertEqual((error as? PDFiumFailure)?.code, cancel ? .cancelled : .resourceExceeded) }
      XCTAssertEqual(state.snapshot(), [])
      owner.recordConsumerDisposal()
      try await owner.releasePinAfterConfirmedDrain(); try await owner.finishAfterDisposal()
      XCTAssertEqual(state.snapshot(), ["pin", "accounting"])
    }
  }

  func testGuardRunsAfterCanonicalUnitBeforeNextUnitForCancellationAndDeadline() throws {
    for expire in [true, false] {
      let id = identity(), state = FixtureState()
      let sentences = (0..<2).map { index in
        ExtractionSentenceInput(identity: .init(paperID: id.paperID, pdfSHA256: id.pdfSHA256,
          revision: id.revision, page: 0, sentenceID: index), text: "synthetic",
          geometry: FixtureGeometry())
      }
      let batch = ExtractionBatch(identity: id, sequence: 0, sentences: sentences,
        complete: true, totalSentences: 2)
      XCTAssertThrowsError(try ExtractionRevisionService.validate([batch], identity: id,
        validator: FixtureValidator(state: state, expire: expire),
        scope: ExtractionConsumptionScope(checkBudget: { try state.check() }))) { error in
        XCTAssertEqual((error as? PDFiumFailure)?.code, expire ? .resourceExceeded : .cancelled)
      }
      XCTAssertEqual(state.snapshot(), ["canonical"])
    }
  }

  func testAcquisitionRejectsCanonicallyEquivalentButByteDifferentReferenceWithoutStartingHelper() async throws {
    let requested = identity(reference: "é")
    let returned = identity(reference: "é", copying: requested)
    XCTAssertEqual(requested, returned) // Swift semantic equality is the regression counterexample.
    XCTAssertFalse(requested.pdfReference.utf8.elementsEqual(returned.pdfReference.utf8))
    let state = FixtureState()
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data([1]).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let limits = try limits()
    let producer = PDFiumExtractionProducer { _, operationID in
      try PDFiumPinnedInput(operationID: operationID, identity: returned,
        senderPDF: FileHandle(forReadingFrom: url), limits: limits,
        deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 1_000_000_000,
        checkBudget: { try state.check() }, releaseReadPin: { _ in state.record("pin") },
        finishOperation: { _ in state.record("accounting") })
    }
    do {
      try await producer.withBatches(requested) { _, _ in XCTFail("mismatch consumed") }
      XCTFail("substituted reference accepted")
    } catch { XCTAssertEqual((error as? PDFiumFailure)?.code, .identityMismatch) }
    XCTAssertEqual(state.snapshot(), ["pin", "accounting"])
  }

  func testImmutableSecureRequestRoundTripAndByteExactKey() throws {
    let id = identity(reference: "é"), original = try key(id)
    let request = try PDFiumExtractionRequest(key: original, pdfByteCount: 1, limits: limits(),
      deadlineUptimeNanoseconds: 123)
    let data = try NSKeyedArchiver.archivedData(withRootObject: request, requiringSecureCoding: true)
    let decoded = try XCTUnwrap(NSKeyedUnarchiver.unarchivedObject(ofClass: PDFiumExtractionRequest.self,
      from: data))
    XCTAssertTrue(decoded.key.matches(original))
    XCTAssertEqual(decoded.deadlineUptimeNanoseconds, 123)
    XCTAssertEqual(decoded.pdfByteCount, 1)
    let substituted = try PDFiumExtractionKey(operationID: original.operationID, paperID: id.paperID,
      generation: id.generation, revision: id.revision, job: id.job, attempt: id.attempt,
      fence: id.fence, correlation: id.correlation, input: id.input, epoch: id.epoch,
      pdfSHA256: id.pdfSHA256, pdfReference: "é")
    XCTAssertFalse(original.matches(substituted))
    XCTAssertThrowsError(try PDFiumExtractionRequest(key: original, pdfByteCount: 0,
      limits: limits(), deadlineUptimeNanoseconds: 123))
  }

  func testSecureBatchRoundTripRetainsNestedGlyphPageAndTerminalFacts() throws {
    let id = identity(), wireKey = try key(id)
    let quad = try PDFiumRawQuad(topLeftX: 0, topLeftY: 10, topRightX: 10, topRightY: 10,
      bottomRightX: 10, bottomRightY: 0, bottomLeftX: 0, bottomLeftY: 0)
    let page = try PDFiumRawPage(pageIndex: 0, boundingBox: quad, mediaBox: quad,
      cropBox: nil, rotationQuarterTurns: 0)
    let glyph = try PDFiumGlyph(nativeCharacterIndex: 0, unicodeScalar: 65,
      utf16Start: 0, utf16Length: 1, generated: false,
      matrixA: 1, matrixB: 0, matrixC: 0, matrixD: 1, matrixE: 0, matrixF: 0, rawQuad: quad)
    let sentence = try PDFiumSentence(paperID: id.paperID, revision: id.revision,
      pdfSHA256: id.pdfSHA256, pageIndex: 0, sentenceID: 0, text: "A",
      nativeStartCharacter: 0, nativeCharacterCount: 1, sourceUTF16Start: 0,
      sourceUTF16Length: 1, glyphs: [glyph])
    let batch = try PDFiumBatch(key: wireKey, sequence: 0, pages: [page],
      sentences: [sentence], complete: true, totalSentences: 1)
    let data = try NSKeyedArchiver.archivedData(withRootObject: batch, requiringSecureCoding: true)
    let decoded = try XCTUnwrap(NSKeyedUnarchiver.unarchivedObject(ofClass: PDFiumBatch.self,
      from: data))
    XCTAssertTrue(decoded.key.matches(wireKey))
    XCTAssertEqual(decoded.sentences.first?.text, "A")
    XCTAssertEqual(decoded.sentences.first?.glyphs.first?.unicodeScalar, 65)
    XCTAssertEqual(decoded.pages.first?.mediaBox?.topLeftY, 10)
    XCTAssertNil(decoded.pages.first?.cropBox)
    let end = try PDFiumEnd(key: wireKey, disposition: .completed, lastSequence: 0,
      totalSentences: 1, processedPageCount: 1, documentPageCount: 1,
      observedPDFSHA256: id.pdfSHA256)
    let endData = try NSKeyedArchiver.archivedData(withRootObject: end, requiringSecureCoding: true)
    let decodedEnd = try XCTUnwrap(NSKeyedUnarchiver.unarchivedObject(ofClass: PDFiumEnd.self,
      from: endData))
    XCTAssertNoThrow(try PDFiumExtractionReplies.validatePull(decoded, end: decodedEnd, failure: nil))
    XCTAssertEqual(decodedEnd.observedPDFSHA256, id.pdfSHA256)
    XCTAssertEqual(decodedEnd.totalSentences, 1)
  }

  func testInvalidReplyShapesAreRejectedWithoutXPC() throws {
    let id = identity()
    let ack = try PDFiumStartAck(key: key(id), workerPID: 1,
      observedPDFSHA256: id.pdfSHA256, observedPDFByteCount: 1, documentPageCount: 1)
    let failure = PDFiumFailure(code: .invalidRequest)
    let completed = try PDFiumEnd(key: ack.key, disposition: .completed, lastSequence: 0,
      totalSentences: 1, processedPageCount: 1, documentPageCount: 1,
      observedPDFSHA256: id.pdfSHA256)
    let failed = try PDFiumEnd(key: ack.key, disposition: .failed, lastSequence: -1,
      totalSentences: 0, processedPageCount: 0, documentPageCount: 1,
      observedPDFSHA256: id.pdfSHA256)
    XCTAssertThrowsError(try PDFiumExtractionReplies.validateStart(nil, failure: nil))
    XCTAssertThrowsError(try PDFiumExtractionReplies.validateStart(ack, failure: failure))
    XCTAssertNoThrow(try PDFiumExtractionReplies.validateStart(ack, failure: nil))
    XCTAssertThrowsError(try PDFiumExtractionReplies.validatePull(nil, end: nil, failure: nil))
    XCTAssertThrowsError(try PDFiumExtractionReplies.validatePull(nil, end: completed, failure: nil))
    XCTAssertThrowsError(try PDFiumExtractionReplies.validatePull(nil, end: completed, failure: failure))
    XCTAssertNoThrow(try PDFiumExtractionReplies.validatePull(nil, end: failed, failure: failure))
    XCTAssertNoThrow(try PDFiumExtractionReplies.validatePull(nil, end: nil, failure: failure))
  }
}
