import CryptoKit
import Darwin
import Foundation
import UniformTypeIdentifiers
#if SWIFT_PACKAGE
import ProviderRequest
#endif

public struct LocalImportConfirmation: Identifiable, Equatable, Sendable {
  public let id: UUID
  public let filename: String
  public let sha256: String
  public let matchingPaperIDs: [UUID]
  public let destinationFolderID: UUID?
  /// Display only; the retained pending intent owns the exact failed Job capture.
  public let retryPaperID: UUID?
}

/// Quiescent sheet observation state. Invalidated requests cannot publish late results.
struct PaperPlacementLoadState {
  struct Request: Equatable, Sendable {
    let id: UUID
    let paperID: UUID
    let generation: UUID
  }
  private var request: Request?
  private(set) var captured: CapturedPaperPlacement?
  private(set) var folders: [LibraryFolder] = []
  private(set) var loading = false
  private(set) var failed = false

  mutating func begin(paperID: UUID, generation: UUID) -> Request {
    invalidate()
    let value = Request(id: UUID(), paperID: paperID, generation: generation)
    request = value; loading = true
    return value
  }

  mutating func invalidate() {
    request = nil; captured = nil; folders = []; loading = false; failed = false
  }

  @discardableResult
  mutating func accept(_ value: CapturedPaperPlacement, folders: [LibraryFolder],
    request: Request) -> Bool {
    guard self.request == request, value.paperID == request.paperID,
      value.generation == request.generation,
      value.folder.map({ folders.contains($0) }) ?? true else { return false }
    self.request = nil; captured = value; self.folders = folders
    loading = false; failed = false
    return true
  }

  mutating func reject(_ request: Request) {
    guard self.request == request else { return }
    self.request = nil; loading = false; failed = true
  }
}

/// Immutable physical ownership. Only the detached hashing operation performs runtime I/O.
final class SelectedSourceReadOwner: Sendable {
  let id = UUID()
  let handle: FileHandle
  let lease: RequestResourceLease
  let source: URL
  let securityScoped: Bool

  init(handle: FileHandle, lease: RequestResourceLease, source: URL, securityScoped: Bool) {
    self.handle = handle
    self.lease = lease
    self.source = source
    self.securityScoped = securityScoped
  }
}

/// All mutable root state is protected by lock; effects never execute under this lock.
private final class SelectedSourceReadRoots: @unchecked Sendable {
  static let shared = SelectedSourceReadRoots()
  private let lock = NSLock()
  private var owners: [UUID: SelectedSourceReadOwner] = [:]
  private var unknown: Set<UUID> = []

  func retain(_ owner: SelectedSourceReadOwner) {
    lock.lock()
    defer { lock.unlock() }
    owners[owner.id] = owner
  }

  func markUnknown(_ id: UUID) {
    lock.lock()
    defer { lock.unlock() }
    unknown.insert(id)
  }

  func removeKnownClosed(_ id: UUID) {
    lock.lock()
    defer { lock.unlock() }
    owners.removeValue(forKey: id)
  }

  func unknownOwners() -> [SelectedSourceReadOwner] {
    lock.lock()
    defer { lock.unlock() }
    return unknown.compactMap { owners[$0] }
  }
}

/// Only pending user intent is ephemeral. Folder and Paper visibility lives in ProductDatabase.
public actor FolderImportService {
  private enum Purpose: Sendable {
    case newPaper
    case retry(ImportRecoveryRecord)
  }
  private struct Pending {
    let source: URL
    let digest: String
    let purpose: Purpose
  }
  private let database: ProductDatabase
  private let lifecycle: LocalLibraryLifecycle
  private let closeSelectedSource: @Sendable (FileHandle) throws -> Void
  private let beforeOpen: (@Sendable (URL) throws -> Void)?
  private var pending: [UUID: Pending] = [:]

  public init(database: ProductDatabase, lifecycle: LocalLibraryLifecycle) {
    self.database = database
    self.lifecycle = lifecycle
    self.closeSelectedSource = { try $0.close() }
    self.beforeOpen = nil
  }

  internal init(database: ProductDatabase, lifecycle: LocalLibraryLifecycle,
    closeSelectedSource: @escaping @Sendable (FileHandle) throws -> Void,
    beforeOpen: (@Sendable (URL) throws -> Void)? = nil) {
    self.database = database
    self.lifecycle = lifecycle
    self.closeSelectedSource = closeSelectedSource
    self.beforeOpen = beforeOpen
  }

  internal nonisolated static func unknownSelectedSourceReads() -> [SelectedSourceReadOwner] {
    SelectedSourceReadRoots.shared.unknownOwners()
  }

  internal var pendingConfirmationCount: Int { pending.count }

  public func folders() async throws -> [LibraryFolder] {
    let database = database
    return try await Task.detached { try database.folders() }.value
  }

  public func createFolder(name: String) async throws -> LibraryFolder {
    let database = database
    return try await Task.detached { try database.createFolder(name: name) }.value
  }

  public func renameFolder(id: UUID, name: String) async throws {
    let database = database
    try await Task.detached { try database.renameFolder(id: id, name: name) }.value
  }

  public func deleteFolder(id: UUID) async throws {
    let database = database
    try await Task.detached { try database.deleteFolder(id: id) }.value
  }

  public func capturePaperPlacement(paperID: UUID, generation: UUID) async throws -> CapturedPaperPlacement {
    let database = database
    return try await Task.detached {
      try database.capturePaperPlacement(paperID: paperID, generation: generation)
    }.value
  }

  public func movePaper(_ captured: CapturedPaperPlacement, to folderID: UUID?) async throws {
    try Task.checkCancellation()
    let database = database
    try await Task.detached { try database.movePaper(captured, to: folderID) }.value
  }

  /// The URL is picker-selected. No bookmark, owned copy, Job or Paper is created here.
  public func prepare(source: URL, destinationFolderID: UUID? = nil) async throws -> LocalImportConfirmation {
    try await prepareConfirmation(source: source, destinationFolderID: destinationFolderID,
      purpose: .newPaper, retryPaperID: nil)
  }

  public func prepareRetry(source: URL, paperID: UUID, generation: UUID,
    destinationFolderID: UUID? = nil) async throws -> LocalImportConfirmation {
    let database = database
    let captured = try await Task.detached {
      try database.captureRetryableImport(paperID: paperID, generation: generation)
    }.value
    try Task.checkCancellation()
    return try await prepareConfirmation(source: source, destinationFolderID: destinationFolderID,
      purpose: .retry(captured), retryPaperID: paperID)
  }

  private func prepareConfirmation(source: URL, destinationFolderID: UUID?,
    purpose: Purpose, retryPaperID: UUID?) async throws -> LocalImportConfirmation {
    let database = database
    let closeSelectedSource = closeSelectedSource
    let beforeOpen = beforeOpen
    let facts = try await Task.detached {
      try database.validateFolderDestination(destinationFolderID)
      let digest = try Self.hashSelectedSource(source, close: closeSelectedSource, beforeOpen: beforeOpen)
      return (digest, try database.contentHashMatches(digest))
    }.value
    try Task.checkCancellation()
    let id = UUID()
    pending[id] = Pending(source: source, digest: facts.0, purpose: purpose)
    return LocalImportConfirmation(id: id, filename: source.lastPathComponent,
      sha256: facts.0, matchingPaperIDs: facts.1, destinationFolderID: destinationFolderID,
      retryPaperID: retryPaperID)
  }

  public func cancel(_ confirmationID: UUID) {
    pending.removeValue(forKey: confirmationID)
  }

  /// A consumed command cannot replay, even when validation or import fails.
  public func continueImport(_ confirmationID: UUID, destinationFolderID: UUID?) async throws -> UUID {
    guard let intent = pending.removeValue(forKey: confirmationID) else {
      throw FolderImportError.consumedIntent
    }
    let database = database
    let closeSelectedSource = closeSelectedSource
    let beforeOpen = beforeOpen
    let digest = try await Task.detached {
      try database.validateFolderDestination(destinationFolderID)
      let digest = try Self.hashSelectedSource(intent.source, close: closeSelectedSource,
        beforeOpen: beforeOpen)
      guard digest == intent.digest else {
        throw FolderImportError.sourceChanged
      }
      return digest
    }.value
    try Task.checkCancellation()
    // Existing owner must compare the digest of its actual copied bytes again before publish.
    switch intent.purpose {
    case .newPaper:
      return try await lifecycle.importPDF(from: intent.source, expectedSHA256: digest,
        destinationFolderID: destinationFolderID)
    case .retry(let captured):
      return try await lifecycle.retryImportPDF(expected: captured, from: intent.source,
        expectedSHA256: digest, destinationFolderID: destinationFolderID)
    }
  }

  private nonisolated static func hashSelectedSource(_ source: URL,
    close: @Sendable (FileHandle) throws -> Void,
    beforeOpen: (@Sendable (URL) throws -> Void)?) throws -> String {
    guard source.isFileURL else { throw FolderImportError.invalidSource }
    let authority = try ProviderRequest()
    let pool = try RequestResourcePool(authority: authority, kind: "import")
    guard let lease = pool.acquire() else { throw LocalLibraryError.importCapacity }
    let scoped = source.startAccessingSecurityScopedResource()
    let owner: SelectedSourceReadOwner
    let observed: stat
    let budget: RequestResourceBudget
    do {
      budget = try RequestResourceBudget(authority: authority, kind: "import")
      var facts = stat()
      guard source.withUnsafeFileSystemRepresentation({ path in
        path.map { Darwin.lstat($0, &facts) } ?? -1
      }) == 0, facts.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
        throw FolderImportError.invalidSource
      }
      let values = try source.resourceValues(forKeys: [.contentTypeKey])
      guard values.contentType?.conforms(to: .pdf) == true else {
        throw FolderImportError.invalidSource
      }
      observed = facts
      try beforeOpen?(source)
      let descriptor = source.withUnsafeFileSystemRepresentation { path in
        path.map { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK) } ?? -1
      }
      guard descriptor >= 0 else { throw FolderImportError.invalidSource }
      // Nonthrowing construction immediately captures the actual descriptor. No ARC close.
      owner = SelectedSourceReadOwner(handle: FileHandle(fileDescriptor: descriptor,
        closeOnDealloc: false), lease: lease, source: source, securityScoped: scoped)
      SelectedSourceReadRoots.shared.retain(owner)
    } catch {
      // No physical descriptor exists on these paths; only this acquisition is released.
      lease.close()
      if scoped { source.stopAccessingSecurityScopedResource() }
      throw error
    }
    let input = owner.handle
    var hash = SHA256()
    var bytes = 0
    var first = true
    let clock = ContinuousClock()
    let start = clock.now
    var failure: (any Error)?
    do {
      var pinned = stat()
      guard Darwin.fstat(input.fileDescriptor, &pinned) == 0,
        pinned.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
        pinned.st_dev == observed.st_dev, pinned.st_ino == observed.st_ino,
        pinned.st_size > 0, pinned.st_size <= Int64(authority.limit("pdfBytes")) else {
        throw FolderImportError.invalidSource
      }
      let size = Int(pinned.st_size)
      while true {
        try Task.checkCancellation()
        let elapsed = start.duration(to: clock.now).components
        try budget.observe("elapsedMs", value: Int(elapsed.seconds) * 1000
          + Int(elapsed.attoseconds / 1_000_000_000_000_000))
        guard let chunk = try input.read(upToCount: authority.limit("readBufferBytes")),
          !chunk.isEmpty else { break }
        try budget.observe("readBufferBytes", value: chunk.count)
        try budget.add("bodyBytes", delta: chunk.count)
        if first {
          try authority.validatePDFSignature(prefix: chunk, mime: nil, sourceKind: "localPDF")
          first = false
        }
        bytes += chunk.count
        hash.update(data: chunk)
      }
      guard !first, bytes == size else { throw FolderImportError.sourceChanged }
    } catch { failure = error }
    do { try close(input) } catch {
      SelectedSourceReadRoots.shared.markUnknown(owner.id)
      throw LocalLibraryError.producerClosureUnknown
    }
    lease.close()
    if scoped { source.stopAccessingSecurityScopedResource() }
    SelectedSourceReadRoots.shared.removeKnownClosed(owner.id)
    if let failure { throw failure }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
  }
}
