import Combine
import Foundation
import PDFKit

/// Presentation values contain no PDF destinations, pages, documents or views.
public struct ReaderMetadataOutlineRow: Identifiable {
  public let id: String
  public let title: String
  public let depth: Int
  public let location: ReaderConfirmedLocation?
}

public struct ReaderMetadataBindingState {
  public let presentation: ReaderMetadataPresentation
  public let sections: [ReaderMetadataOutlineRow]
  /// A validated restoration candidate, never proof that navigation occurred.
  public let restorationCandidate: ReaderConfirmedLocation?
  public let observedLocation: ReaderConfirmedLocation?
  public let activeSectionID: String?
}

/// Borrows the Reader's admitted PDF; neither acquires a lease nor owns PDF lifetime.
@MainActor public final class ReaderMetadataBinding: ObservableObject {
  public let identity: ReaderMetadataIdentity?
  private let documentIdentity: ReaderMetadataDocumentIdentity
  @Published public private(set) var state: ReaderMetadataBindingState?
  private let session: ReaderSession
  private let service: ReaderMetadataService
  private weak var view: PDFView?
  private weak var document: PDFDocument?
  private var context: ReaderMetadataContext?
  private var invalidated = false
  private var observing = false
  private var publishing = false
  private var restorationPending = true
  private var restoringPosition = false
  private var observationFreshness: UInt64 = 0

  public init(session: ReaderSession, service: ReaderMetadataService,
    admittedIdentity: AnnotationPaperIdentity, identity: ReaderMetadataIdentity?,
    view: PDFView, document: PDFDocument) throws {
    self.session = session; self.service = service; self.identity = identity
    self.view = view; self.document = document
    self.documentIdentity = try session.withReadAccess {
      guard let paper = session.currentPaper,
        paper.paperID == admittedIdentity.id, paper.generation == admittedIdentity.generation else {
        throw ReaderMetadataError.staleIdentity
      }
      // Current DB facts may reject the admitted document, never relabel its digest.
      return ReaderMetadataDocumentIdentity(paperID: admittedIdentity.id,
        generation: admittedIdentity.generation, pdfSHA256: admittedIdentity.pdfSHA256,
        pdfReference: paper.pdfReference)
    }
    let initial = try access { _, document, metadata in
      let context = try identity.map { try service.beginSession(for: $0) }
      let adapter = ReaderOutlineAdapter(document: document, identity: identity)
      return (context, try makeState(metadata: metadata, document: document,
        adapter: adapter, context: context, observed: nil))
    }
    context = initial.0
    try publish(initial.1)
  }

  /// Parent calls synchronously before PDF detach/lease release and on revision switch.
  public func invalidate() {
    guard !invalidated else { return }
    invalidated = true
    restorationPending = false
    view = nil; document = nil; context = nil
    state = nil
  }

  /// Reloads durable candidates and the actual outline without starting extraction.
  public func refresh() throws {
    guard !publishing else { throw ReaderMetadataError.staleConfirmation }
    let prepared: (ReaderMetadataBindingState, ReaderMetadataContext?, ReaderConfirmedLocation?, UInt64)? =
      try access { _, document, metadata in
      let expected = context
      let observed = state?.observedLocation
      let freshness = observationFreshness
      let adapter = ReaderOutlineAdapter(document: document, identity: identity)
      guard refreshIsCurrent(context: expected, observed: observed, freshness: freshness) else { return nil }
      let validatedObservation: ReaderConfirmedLocation?
      if let observed, let page = document.page(at: observed.pageIndex),
        page.document === document,
        observed.isValid(pageCount: document.pageCount, bounds: page.bounds(for: .cropBox)) {
        validatedObservation = observed
      } else {
        validatedObservation = nil
      }
      guard refreshIsCurrent(context: expected, observed: observed, freshness: freshness) else { return nil }
      let next = try makeState(metadata: metadata, document: document,
        adapter: adapter, context: expected, observed: validatedObservation)
      guard refreshIsCurrent(context: expected, observed: observed, freshness: freshness) else { return nil }
      return (next, expected, observed, freshness)
    }
    // Supersession must not skip the identity and actual lease postchecks above.
    guard let prepared else { throw ReaderMetadataError.staleConfirmation }
    try validateRefresh(context: prepared.1, observed: prepared.2, freshness: prepared.3)
    try publish(prepared.0)
  }

  /// Only dispatches intent. Position notifications, not this call, confirm movement.
  public func navigate(sectionID: String) throws {
    guard !publishing else { throw ReaderMetadataError.staleConfirmation }
    restorationPending = false
    try access { view, document, _ in
      let adapter = ReaderOutlineAdapter(document: document, identity: identity)
      try adapter.navigate(sectionID: sectionID, in: view, current: identity)
    }
  }

  /// Requests a saved within-page destination once. It does not observe or save arrival.
  /// A context on a different page must not override the existing Reader page restoration.
  @discardableResult
  public func restoreSavedPosition(onPage pageIndex: Int) throws -> Bool {
    guard !publishing, !observing, !restoringPosition else {
      throw ReaderMetadataError.staleConfirmation
    }
    guard restorationPending else { return false }
    restoringPosition = true
    defer { restoringPosition = false; restorationPending = false }
    return try access { view, document, _ in
      guard let identity, let expected = context,
        state?.observedLocation == nil else { return false }
      try service.validateContext(expected, for: identity)
      let adapter = ReaderOutlineAdapter(document: document, identity: identity)
      guard expected.location?.pageIndex == pageIndex,
        let destination = adapter.restorationDestination(expected) else { return false }
      let zoom = view.scaleFactor
      guard zoom.isFinite, zoom > 0 else { throw ReaderMetadataError.invalidDestination }
      destination.zoom = zoom
      _ = try validate()
      try service.validateContext(expected, for: identity)
      guard restorationPending, context == expected, state?.observedLocation == nil else {
        throw ReaderMetadataError.staleConfirmation
      }
      restorationPending = false
      view.go(to: destination)
      return true
    }
  }

  /// Called by the actual PDF position observer. No asynchronous PDF access escapes the lease.
  public func observePosition() throws {
    guard !observing, !publishing else { throw ReaderMetadataError.staleConfirmation }
    // Identical coordinates and failed observations both supersede an older refresh.
    guard observationFreshness < UInt64.max else {
      invalidate()
      throw ReaderMetadataError.staleConfirmation
    }
    observationFreshness += 1
    restorationPending = false
    observing = true
    defer { observing = false }
    do {
      let result = try access { view, document, metadata in
        let expected = context
        let adapter = ReaderOutlineAdapter(document: document, identity: identity)
        // currentDestination can synchronously notify/revoke/replace the Reader.
        let destination = view.currentDestination
        _ = try validate()
        guard let destination, let page = destination.page, page.document === document else {
          throw ReaderMetadataError.invalidDestination
        }
        let location = ReaderConfirmedLocation(pageIndex: document.index(for: page),
          x: Double(destination.point.x), y: Double(destination.point.y))
        guard location.isValid(pageCount: document.pageCount, bounds: page.bounds(for: .cropBox)) else {
          throw ReaderMetadataError.invalidDestination
        }
        let sectionID = adapter.activeSection(at: location)
        let nextState = try makeState(metadata: metadata, document: document,
          adapter: adapter, context: expected, observed: location)
        _ = try validate()
        let saved: ReaderMetadataContext?
        if let identity {
          guard let expected else { throw ReaderMetadataError.staleIdentity }
          saved = try service.saveConfirmed(location, sectionID: sectionID,
            expected: expected, for: identity)
        } else {
          // Native Contents uses the existing Reader position owner, not a fake revision.
          try session.save(ReaderPosition(pageIndex: location.pageIndex,
            zoom: Double(view.scaleFactor)))
          saved = nil
        }
        return (saved, nextState)
      }
      context = result.0
      try publish(result.1)
    } catch {
      // Never leave a previous observation looking like the current position after failure.
      if let old = state {
        do {
          try publish(ReaderMetadataBindingState(presentation: old.presentation, sections: old.sections,
            restorationCandidate: old.restorationCandidate, observedLocation: nil, activeSectionID: nil))
        } catch {
          state = nil
        }
      }
      throw error
    }
  }

  private func validateRefresh(context expected: ReaderMetadataContext?,
    observed: ReaderConfirmedLocation?, freshness: UInt64) throws {
    guard !invalidated else { throw ReaderMetadataError.staleIdentity }
    guard refreshIsCurrent(context: expected, observed: observed, freshness: freshness) else {
      throw ReaderMetadataError.staleConfirmation
    }
  }

  private func refreshIsCurrent(context expected: ReaderMetadataContext?,
    observed: ReaderConfirmedLocation?, freshness: UInt64) -> Bool {
    !invalidated && context == expected && state?.observedLocation == observed
      && observationFreshness == freshness
  }

  private func publish(_ next: ReaderMetadataBindingState) throws {
    guard !publishing else { throw ReaderMetadataError.staleConfirmation }
    publishing = true
    defer { publishing = false }
    do {
      try access { _, _, _ in state = next }
    } catch {
      // A willSet callback can invalidate before the outer setter installs next.
      state = nil
      throw error
    }
  }

  private func validate() throws -> ReaderMetadataSnapshot {
    guard !invalidated, let paper = session.currentPaper,
      paper.paperID == documentIdentity.paperID, paper.generation == documentIdentity.generation,
      paper.pdfReference == documentIdentity.pdfReference, let view, let document,
      view.document === document else { throw ReaderMetadataError.staleIdentity }
    guard try service.documentIdentity(paperID: paper.paperID) == documentIdentity else {
      throw ReaderMetadataError.staleIdentity
    }
    guard let identity else { return ReaderMetadataSnapshot() }
    guard identity.paperID == documentIdentity.paperID,
      identity.generation == documentIdentity.generation,
      identity.pdfSHA256 == documentIdentity.pdfSHA256,
      identity.pdfReference == documentIdentity.pdfReference else {
      throw ReaderMetadataError.staleIdentity
    }
    // The shared DB atomically checks ready generation/SHA/reference AND published revision.
    return try service.metadata(for: identity)
  }

  private func access<T>(_ operation: (PDFView, PDFDocument, ReaderMetadataSnapshot) throws -> T) throws -> T {
    do {
      return try session.withReadAccess {
        let metadata = try validate()
        guard let view, let document else { throw ReaderMetadataError.staleIdentity }
        let result = try operation(view, document, metadata)
        _ = try validate()
        return result
      }
    } catch {
      if error is ReaderError || (error as? ReaderMetadataError) == .staleIdentity { invalidate() }
      throw error
    }
  }

  private func makeState(metadata: ReaderMetadataSnapshot, document: PDFDocument,
    adapter: ReaderOutlineAdapter, context: ReaderMetadataContext?,
    observed: ReaderConfirmedLocation?) throws -> ReaderMetadataBindingState {
    var titles = metadata.title.candidates
    let attributes = document.documentAttributes
    _ = try validate()
    if let title = attributes?[PDFDocumentAttribute.titleAttribute] as? String,
      !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      let candidate = ReaderMetadataValue(text: title, source: .source,
        sourceID: "pdf:\(documentIdentity.pdfSHA256)")
      if !titles.contains(candidate) { titles.append(candidate) }
    }
    // PDF creation/modification dates, subject and keywords have different semantics.
    let combined = ReaderMetadataSnapshot(title: .init(titles), year: metadata.year,
      abstract: metadata.abstract, topics: metadata.topics)
    try combined.validate()
    return ReaderMetadataBindingState(presentation: .init(identity: identity, metadata: combined),
      sections: adapter.sections.map {
        ReaderMetadataOutlineRow(id: $0.id, title: $0.title, depth: $0.depth, location: $0.location)
      }, restorationCandidate: context.flatMap { adapter.validatedRestoration($0) }, observedLocation: observed,
      activeSectionID: observed.flatMap { adapter.activeSection(at: $0) })
  }
}
