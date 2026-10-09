import Foundation

public struct ReaderPaperSnapshot: Equatable, Sendable {
  public let paperID: UUID
  public let generation: UUID
  public let pdfReference: String
  public let title: String
  // Only Infrastructure constructs admitted identities from ready rows.
  init(paperID: UUID, generation: UUID, pdfReference: String, title: String) {
    self.paperID = paperID
    self.generation = generation
    self.pdfReference = pdfReference
    self.title = title
  }
}

public struct ReaderPosition: Equatable, Sendable {
  public let pageIndex: Int
  public let zoom: Double
  public init(pageIndex: Int, zoom: Double) {
    self.pageIndex = pageIndex
    self.zoom = zoom
  }
  public func validate(pageCount: Int) throws {
    guard pageCount > 0, pageIndex >= 0, pageIndex < pageCount,
      zoom.isFinite, (0.1...10).contains(zoom) else { throw ReaderError.invalidPosition }
  }
}

public enum ReaderError: Error, Equatable, Sendable {
  case leaseUnavailable, notReady, invalidReference, revoked, replacedSession
  case invalidDocument, invalidPosition, invalidStoredPosition, sequenceExhausted, notOpen
}

/// Scheduling information only. Actual operations still require withReadAccess.
public enum ReaderSessionAdmissionState: Equatable, Sendable {
  case pending, admitted(UUID), closed
}

/// Implemented by the shared lifecycle, not a Reader-local ownership surrogate.
/// Acquisition pins the exact identity against physical deletion until close.
/// Revocation synchronously invokes onRevoked on MainActor before deletion drains.
@MainActor public protocol ReaderLeaseProvider: AnyObject {
  func acquireReadLease(
    for snapshot: ReaderPaperSnapshot, onRevoked: @escaping @MainActor () -> Void
  ) throws -> any ReaderReadLease
}

@MainActor public protocol ReaderReadLease: AnyObject {
  /// Throws once revoked. Work must not escape as an untracked asynchronous read.
  func validate() throws
  /// The lifetime pin remains held, but short state arbitration must not span operation.
  func withReadAccess<T>(_ operation: () throws -> T) throws -> T
  /// Idempotent release, only after PDF documents/search/selection are discarded.
  func close()
}

public enum ReaderNavigation {
  public static func page(after current: Int, delta: Int, count: Int) -> Int? {
    guard count > 0, current >= 0, current < count else { return nil }
    let (candidate, overflow) = current.addingReportingOverflow(delta)
    guard !overflow, candidate >= 0, candidate < count else { return nil }
    return candidate
  }
}

/// All entry, persistence and lifetime decisions go through Application. No PDFKit
/// types or arbitrary URL admission are exposed by this service.
@MainActor public final class ReaderSession {
  private let database: ProductDatabase
  private let leaseProvider: (any ReaderLeaseProvider)?
  private var lease: (any ReaderReadLease)?
  private var snapshot: ReaderPaperSnapshot?
  private var sessionID: UUID?
  private var sequence: Int64 = 0
  private var pageCount = 0
  private var discardContent: (@MainActor () -> Void)?
  public private(set) var restoredPosition: ReaderPosition?
  public private(set) var currentPaper: ReaderPaperSnapshot?
  public private(set) var admissionState: ReaderSessionAdmissionState = .pending

  public init(database: ProductDatabase, leaseProvider: (any ReaderLeaseProvider)? = nil) {
    self.database = database
    self.leaseProvider = leaseProvider
  }

  /// Validator loads the original document under a pinned lease and returns its
  /// actual page count. discard must synchronously detach it on failure/revocation.
  @discardableResult public func open(
    paperID: UUID, validateDocument: (URL) throws -> Int,
    discard: @escaping @MainActor () -> Void
  ) throws -> ReaderPosition {
    guard lease == nil else { throw ReaderError.replacedSession }
    admissionState = .pending
    let admitted: ReaderPaperSnapshot
    do {
      guard leaseProvider != nil else { throw ReaderError.leaseUnavailable }
      admitted = try database.readerSnapshot(paperID: paperID)
    } catch {
      admissionState = .closed
      throw error
    }
    guard let leaseProvider else { admissionState = .closed; throw ReaderError.leaseUnavailable }
    discardContent = discard
    do {
      lease = try leaseProvider.acquireReadLease(for: admitted) { [weak self] in
        self?.revoke()
      }
      guard let lease else { throw ReaderError.leaseUnavailable }
      try lease.validate()
      let count = try lease.withReadAccess {
        try validateDocument(database.root.appendingPathComponent(admitted.pdfReference))
      }
      guard count > 0 else { throw ReaderError.invalidDocument }
      try lease.validate()
      try database.validateReaderSnapshot(admitted)
      let owner = UUID()
      let saved = try database.claimReader(admitted, sessionID: owner)
      sessionID = owner
      snapshot = admitted
      let position = saved ?? ReaderPosition(pageIndex: 0, zoom: 1)
      do { try position.validate(pageCount: count) }
      catch { throw ReaderError.invalidStoredPosition }
      try lease.validate()
      try database.validateReaderOwner(admitted, sessionID: owner)
      pageCount = count
      sequence = 0
      restoredPosition = position
      currentPaper = admitted
      admissionState = .admitted(owner)
      return position
    } catch {
      // A validator may complete after reentrant revocation; discard its late candidate too.
      discard()
      revoke()
      throw error
    }
  }

  public func withReadAccess<T>(_ operation: () throws -> T) throws -> T {
    guard let lease, let snapshot, let sessionID else { throw ReaderError.notOpen }
    do {
      try lease.validate()
      try database.validateReaderOwner(snapshot, sessionID: sessionID)
    } catch {
      revoke()
      throw error
    }
    return try lease.withReadAccess(operation)
  }

  public func save(_ position: ReaderPosition) throws {
    guard let lease, let snapshot, let sessionID else { throw ReaderError.notOpen }
    try position.validate(pageCount: pageCount)
    guard sequence < Int64.max else { throw ReaderError.sequenceExhausted }
    let next = sequence + 1
    do {
      try lease.validate()
      try database.saveReaderPosition(position, snapshot: snapshot, sessionID: sessionID,
        sequence: next)
    } catch {
      if let reason = error as? ReaderError,
        [.revoked, .notReady, .replacedSession, .invalidReference].contains(reason) { revoke() }
      throw error
    }
    sequence = next
    restoredPosition = position
  }

  /// Storage failure permits retry; revoked/replaced identity closes access instead.
  public func leave(at position: ReaderPosition) throws {
    try save(position)
    close()
  }

  public func close() { revoke() }

  private func revoke() {
    admissionState = .closed
    let discard = discardContent
    discardContent = nil
    discard?()
    if let snapshot, let sessionID {
      // Release cannot recreate anything. Persistence failure does not retain PDF access.
      try? database.releaseReader(snapshot, sessionID: sessionID)
    }
    lease?.close()
    lease = nil
    snapshot = nil
    sessionID = nil
    currentPaper = nil
    restoredPosition = nil
    pageCount = 0
  }
}
