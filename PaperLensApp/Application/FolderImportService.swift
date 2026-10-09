import CryptoKit
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
}

/// Only pending user intent is ephemeral. Folder and Paper visibility lives in ProductDatabase.
public actor FolderImportService {
  private struct Pending {
    let source: URL
    let digest: String
  }
  private let database: ProductDatabase
  private let lifecycle: LocalLibraryLifecycle
  private var pending: [UUID: Pending] = [:]

  public init(database: ProductDatabase, lifecycle: LocalLibraryLifecycle) {
    self.database = database
    self.lifecycle = lifecycle
  }

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

  public func assignPaper(_ paperID: UUID, to folderID: UUID?) async throws {
    let database = database
    try await Task.detached { try database.assignPaper(paperID, to: folderID) }.value
  }

  /// The URL is picker-selected. No bookmark, owned copy, Job or Paper is created here.
  public func prepare(source: URL, destinationFolderID: UUID? = nil) async throws -> LocalImportConfirmation {
    let database = database
    let facts = try await Task.detached {
      try database.validateFolderDestination(destinationFolderID)
      let digest = try Self.hashSelectedSource(source)
      return (digest, try database.contentHashMatches(digest))
    }.value
    try Task.checkCancellation()
    let id = UUID()
    pending[id] = Pending(source: source, digest: facts.0)
    return LocalImportConfirmation(id: id, filename: source.lastPathComponent,
      sha256: facts.0, matchingPaperIDs: facts.1, destinationFolderID: destinationFolderID)
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
    try await Task.detached {
      try database.validateFolderDestination(destinationFolderID)
      guard try Self.hashSelectedSource(intent.source) == intent.digest else {
        throw FolderImportError.sourceChanged
      }
    }.value
    try Task.checkCancellation()
    // Existing owner must compare the digest of its actual copied bytes again before publish.
    return try await lifecycle.importPDF(from: intent.source, expectedSHA256: intent.digest,
      destinationFolderID: destinationFolderID)
  }

  private nonisolated static func hashSelectedSource(_ source: URL) throws -> String {
    guard source.isFileURL else { throw FolderImportError.invalidSource }
    let authority = try ProviderRequest()
    let pool = try RequestResourcePool(authority: authority, kind: "import")
    guard let lease = pool.acquire() else { throw LocalLibraryError.importCapacity }
    defer { lease.close() }
    let scoped = source.startAccessingSecurityScopedResource()
    defer { if scoped { source.stopAccessingSecurityScopedResource() } }
    let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey,
      .contentTypeKey, .fileSizeKey])
    guard values.isRegularFile == true, values.isSymbolicLink != true,
      values.contentType?.conforms(to: .pdf) == true, let size = values.fileSize,
      size > 0, size <= authority.limit("pdfBytes") else { throw FolderImportError.invalidSource }
    let budget = try RequestResourceBudget(authority: authority, kind: "import")
    let input = try FileHandle(forReadingFrom: source)
    var hash = SHA256()
    var bytes = 0
    var first = true
    let clock = ContinuousClock()
    let start = clock.now
    var failure: (any Error)?
    do {
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
    do { try input.close() } catch { throw LocalLibraryError.producerClosureUnknown }
    if let failure { throw failure }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
  }
}
