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
  public let identity: ReaderMetadataIdentity
  @Published public private(set) var state: ReaderMetadataBindingState?
  private let session: ReaderSession
  private let service: ReaderMetadataService
  private weak var view: PDFView?
  private weak var document: PDFDocument?
  private var context: ReaderMetadataContext?
  private var invalidated = false
  private var observing = false
  private var publishing = false

  public init(session: ReaderSession, service: ReaderMetadataService,
    identity: ReaderMetadataIdentity, view: PDFView, document: PDFDocument) throws {
    self.session = session; self.service = service; self.identity = identity
    self.view = view; self.document = document
    let initial = try access { _, document, metadata in
      let context = try service.beginSession(for: identity)
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
    view = nil; document = nil; context = nil
    state = nil
  }

  /// Reloads durable candidates and the actual outline without starting extraction.
  public func refresh() throws {
    guard !publishing else { throw ReaderMetadataError.staleConfirmation }
    let prepared: (ReaderMetadataBindingState, ReaderMetadataContext, ReaderConfirmedLocation?)? =
      try access { _, document, metadata in
      guard let expected = context else { throw ReaderMetadataError.staleIdentity }
      let observed = state?.observedLocation
      let adapter = ReaderOutlineAdapter(document: document, identity: identity)
      guard refreshIsCurrent(context: expected, observed: observed) else { return nil }
      let validatedObservation: ReaderConfirmedLocation?
      if let observed, let page = document.page(at: observed.pageIndex),
        page.document === document,
        observed.isValid(pageCount: document.pageCount, bounds: page.bounds(for: .cropBox)) {
        validatedObservation = observed
      } else {
        validatedObservation = nil
      }
      guard refreshIsCurrent(context: expected, observed: observed) else { return nil }
      let next = try makeState(metadata: metadata, document: document,
        adapter: adapter, context: expected, observed: validatedObservation)
      guard refreshIsCurrent(context: expected, observed: observed) else { return nil }
      return (next, expected, observed)
    }
    // Supersession must not skip the identity and actual lease postchecks above.
    guard let prepared else { throw ReaderMetadataError.staleConfirmation }
    try validateRefresh(context: prepared.1, observed: prepared.2)
    try publish(prepared.0)
  }

  /// Only dispatches intent. Position notifications, not this call, confirm movement.
  public func navigate(sectionID: String) throws {
    guard !publishing else { throw ReaderMetadataError.staleConfirmation }
    try access { view, document, _ in
      let adapter = ReaderOutlineAdapter(document: document, identity: identity)
      try adapter.navigate(sectionID: sectionID, in: view, current: identity)
    }
  }

  /// Called by the actual PDF position observer. No asynchronous PDF access escapes the lease.
  public func observePosition() throws {
    guard !observing, !publishing else { throw ReaderMetadataError.staleConfirmation }
    observing = true
    defer { observing = false }
    do {
      let result = try access { view, document, metadata in
        guard let expected = context else { throw ReaderMetadataError.staleIdentity }
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
        let saved = try service.saveConfirmed(location, sectionID: sectionID,
          expected: expected, for: identity)
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

  private func validateRefresh(context expected: ReaderMetadataContext,
    observed: ReaderConfirmedLocation?) throws {
    guard !invalidated else { throw ReaderMetadataError.staleIdentity }
    guard refreshIsCurrent(context: expected, observed: observed) else {
      throw ReaderMetadataError.staleConfirmation
    }
  }

  private func refreshIsCurrent(context expected: ReaderMetadataContext,
    observed: ReaderConfirmedLocation?) -> Bool {
    !invalidated && context == expected && state?.observedLocation == observed
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
      paper.paperID == identity.paperID, paper.generation == identity.generation,
      paper.pdfReference == identity.pdfReference, let view, let document,
      view.document === document else { throw ReaderMetadataError.staleIdentity }
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
    adapter: ReaderOutlineAdapter, context: ReaderMetadataContext,
    observed: ReaderConfirmedLocation?) throws -> ReaderMetadataBindingState {
    var titles = metadata.title.candidates
    let attributes = document.documentAttributes
    _ = try validate()
    if let title = attributes?[PDFDocumentAttribute.titleAttribute] as? String,
      !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      let candidate = ReaderMetadataValue(text: title, source: .source,
        sourceID: "pdf:\(identity.pdfSHA256)")
      if !titles.contains(candidate) { titles.append(candidate) }
    }
    // PDF creation/modification dates, subject and keywords have different semantics.
    let combined = ReaderMetadataSnapshot(title: .init(titles), year: metadata.year,
      abstract: metadata.abstract, topics: metadata.topics)
    try combined.validate()
    return ReaderMetadataBindingState(presentation: .init(identity: identity, metadata: combined),
      sections: adapter.sections.map {
        ReaderMetadataOutlineRow(id: $0.id, title: $0.title, depth: $0.depth, location: $0.location)
      }, restorationCandidate: adapter.validatedRestoration(context), observedLocation: observed,
      activeSectionID: observed.flatMap { adapter.activeSection(at: $0) })
  }
}
