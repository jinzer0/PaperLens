import CryptoKit
import Darwin
import Foundation
#if SWIFT_PACKAGE
import ProviderRequest
#endif

struct ActualURLStageValidationEffects: Sendable {
  let acquired: @Sendable (Int32) -> Void
  let checkedClose: @Sendable (FileHandle) throws -> Void
  static let actual = ActualURLStageValidationEffects(acquired: { _ in },
    checkedClose: { try $0.close() })
}

private final class ActualURLStageValidationOwner: @unchecked Sendable {
  let id = UUID()
  let stage: ClosedHTTPSPDFStage
  let lease: RequestResourceLease
  var input: FileHandle?
  init(stage: ClosedHTTPSPDFStage, lease: RequestResourceLease) {
    self.stage = stage
    self.lease = lease
  }
}

private final class ActualURLStageValidationRoots: @unchecked Sendable {
  static let shared = ActualURLStageValidationRoots()
  private let lock = NSLock()
  private var owners: [UUID: ActualURLStageValidationOwner] = [:]
  func retain(_ owner: ActualURLStageValidationOwner) {
    lock.withLock { owners[owner.id] = owner }
  }
  func releaseKnown(_ owner: ActualURLStageValidationOwner) {
    owner.lease.close()
    let removed = lock.withLock { owners.removeValue(forKey: owner.id) }
    withExtendedLifetime(removed) {} // Destruction must occur outside arbitration.
  }
  var ids: Set<UUID> { lock.withLock { Set(owners.keys) } }
}

/// A capability for one already-reserved ImportJob, never a second importer.
final class LibraryURLImportWriter: URLImportWriter, @unchecked Sendable {
  static var rootedValidationIDs: Set<UUID> { ActualURLStageValidationRoots.shared.ids }
  let stagingDirectory: URL
  let identity: ImportIdentity
  let destinationFolderID: UUID?
  let cancellation: ImportCancellation
  private let lifecycle: LocalLibraryLifecycle
  private let lock = NSLock()
  private enum Phase { case admitted, publishing, failed, finished }
  private var phase = Phase.admitted
  private var publicationClosureUnknown = false
  private var producer: Task<ClosedHTTPSPDFStage, any Error>?
  private var ownsNamespace = false
  var namespaceOwned: Bool { lock.withLock { ownsNamespace } }
  func markNamespaceOwned() { lock.withLock { ownsNamespace = true } }

  init(lifecycle: LocalLibraryLifecycle, identity: ImportIdentity,
    directory: URL, destinationFolderID: UUID?, cancellation: ImportCancellation) {
    self.lifecycle = lifecycle
    self.identity = identity
    stagingDirectory = directory
    self.destinationFolderID = destinationFolderID
    self.cancellation = cancellation
  }

  func bindDownload(_ task: Task<ClosedHTTPSPDFStage, any Error>) throws {
    let bound = lock.withLock {
      guard phase == .admitted, producer == nil else { return false }
      producer = task
      return true
    }
    guard bound else { task.cancel(); throw URLImportError.writerUnavailable }
    cancellation.bind { task.cancel() }
  }

  func assertCurrent() throws {
    try cancellation.check()
    guard lock.withLock({ phase != .finished }) else { throw URLImportError.writerUnavailable }
  }

  func revoke() { cancellation.cancel() }

  func publish(_ stage: ClosedHTTPSPDFStage) async throws -> UUID {
    try assertCurrent()
    let consumed = lock.withLock {
      guard phase == .admitted else { return false }
      phase = .publishing
      return true
    }
    guard consumed else { throw URLImportError.writerUnavailable }
    // On error the caller must abort, only after this validation/publisher has closed.
    do {
      let result = try await lifecycle.publishURLImport(self, stage: stage)
      lock.withLock { phase = .finished }
      return result
    } catch {
      lock.withLock {
        if (error as? URLImportError) == .closureUnknown { publicationClosureUnknown = true }
        phase = .failed
      }
      throw error
    }
  }

  func abort(reason: URLImportError) async throws {
    // The service calls this only after adapter download (including invalidation/drain)
    // or publish has returned. Unknown closure is never promoted to closed by this call.
    let consumed: Bool? = lock.withLock {
      guard phase != .publishing else { return nil }
      guard phase != .finished else { return false }
      phase = .finished
      return true
    }
    guard let consumed else { throw URLImportError.writerUnavailable }
    guard consumed else { return }
    revoke()
    var closureReason: URLImportError = lock.withLock { publicationClosureUnknown }
      ? .closureUnknown : reason
    let producer = lock.withLock { self.producer }
    if let producer {
      do { _ = try await producer.value }
      catch { if (error as? URLImportError) == .closureUnknown { closureReason = .closureUnknown } }
    }
    try await lifecycle.abortURLImport(self, reason: closureReason)
  }

  static func validate(_ stage: ClosedHTTPSPDFStage, directory: URL,
    cancellation: ImportCancellation, effects: ActualURLStageValidationEffects) throws {
    try cancellation.check()
    guard stage.file.isFileURL, directory.isFileURL,
      !stage.file.path(percentEncoded: false).utf8.contains(0),
      !directory.path(percentEncoded: false).utf8.contains(0),
      stage.file.withUnsafeFileSystemRepresentation({ $0 != nil }),
      directory.withUnsafeFileSystemRepresentation({ $0 != nil }),
      stage.file.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL,
      directory.resolvingSymlinksInPath() == directory.standardizedFileURL,
      stage.file.resolvingSymlinksInPath() == stage.file.standardizedFileURL else {
      throw URLImportError.rejected
    }
    let authority = try ProviderRequest()
    guard stage.byteCount > 0, stage.byteCount <= authority.limit("pdfBytes") else {
      throw URLImportError.rejected
    }
    let budget = try RequestResourceBudget(authority: authority, kind: "import")
    let pool = try RequestResourcePool(authority: authority, kind: "import")
    guard let lease = pool.acquire() else { throw URLImportError.capacity }
    let owner = ActualURLStageValidationOwner(stage: stage, lease: lease)
    ActualURLStageValidationRoots.shared.retain(owner)
    let fd = stage.file.withUnsafeFileSystemRepresentation { path in
      guard let path else { return Int32(-1) }
      return Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    }
    guard fd >= 0 else {
      ActualURLStageValidationRoots.shared.releaseKnown(owner)
      throw URLImportError.rejected
    }
    let input = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
    owner.input = input
    effects.acquired(fd)
    var workError: (any Error)?
    do {
      try cancellation.check()
      var info = stat()
      guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
        info.st_mode & 0o7777 == 0o400, info.st_nlink == 1,
        info.st_uid == Darwin.getuid(),
        info.st_size == Int64(stage.byteCount) else { throw URLImportError.rejected }
      var hash = SHA256()
      var count = 0
      var first = true
      let clock = ContinuousClock()
      let started = clock.now
      while true {
        try cancellation.check()
        let elapsed = started.duration(to: clock.now).components
        try budget.observe("elapsedMs", value: Int(elapsed.seconds) * 1000
          + Int(elapsed.attoseconds / 1_000_000_000_000_000))
        let next = try input.read(upToCount: authority.limit("readBufferBytes"))
        try cancellation.check()
        let afterRead = started.duration(to: clock.now).components
        try budget.observe("elapsedMs", value: Int(afterRead.seconds) * 1000
          + Int(afterRead.attoseconds / 1_000_000_000_000_000))
        guard let chunk = next, !chunk.isEmpty else { break }
        try budget.observe("readBufferBytes", value: chunk.count)
        try budget.add("bodyBytes", delta: chunk.count)
        if first {
          // ClosedHTTPSPDFStage can only be issued after the adapter validates
          // the response's fixed PDF MIME policy and actual stream closure.
          try authority.validatePDFSignature(prefix: chunk,
            mime: authority.contract["policies"]["pdfMIME"].string, sourceKind: "httpsPDF")
          first = false
        }
        count += chunk.count
        hash.update(data: chunk)
      }
      guard !first, count == stage.byteCount,
        hash.finalize().map({ String(format: "%02x", $0) }).joined() == stage.sha256 else {
        throw URLImportError.rejected
      }
      var pathInfo = stat()
      var finalInfo = stat()
      guard fstat(fd, &finalInfo) == 0,
        finalInfo.st_ino == info.st_ino, finalInfo.st_dev == info.st_dev,
        finalInfo.st_size == info.st_size, finalInfo.st_mode == info.st_mode,
        finalInfo.st_nlink == 1, finalInfo.st_uid == info.st_uid,
        stage.file.withUnsafeFileSystemRepresentation({ path in
          guard let path else { return Int32(-1) }
          return Darwin.lstat(path, &pathInfo)
        }) == 0,
        pathInfo.st_ino == info.st_ino, pathInfo.st_dev == info.st_dev,
        pathInfo.st_size == info.st_size, pathInfo.st_mode == info.st_mode,
        pathInfo.st_nlink == 1, pathInfo.st_uid == info.st_uid else {
        throw URLImportError.rejected
      }
      try cancellation.check()
    } catch { workError = error }
    // A throwing checked close is uncertainty, not an acknowledgment. Leave the
    // exact handle, original lease and immutable stage rooted; never retry/probe it.
    do { try effects.checkedClose(input) } catch { throw URLImportError.closureUnknown }
    ActualURLStageValidationRoots.shared.releaseKnown(owner)
    if let workError { throw workError }
    try cancellation.check()
  }
}
