import Darwin
import Foundation

/// One registry per lifecycle. Only accounting is performed under this lock.
final class LibraryReadLeaseRegistry: @unchecked Sendable {
  private struct Entry {
    let snapshot: ReaderPaperSnapshot
    let revoke: @MainActor () -> Void
    var handle: FileHandle?
    var opening = true
    var revoked = false
    var closeRequested = false
    var closing = false
    var closureUnknown = false
    var reads = 0
    var senderTaken = false
    var cleanupDebt: [FileHandle] = []
    let receipt = LibraryPinClosureObservation()
  }
  private let lock = NSLock()
  private var closed: Set<UUID> = []
  private var entries: [UUID: Entry] = [:]
  private var waiters: [UUID: [CheckedContinuation<Void, any Error>]] = [:]
  private let closeHandle: @Sendable (FileHandle) throws -> Void
  private let duplicateHandle: @Sendable (FileHandle) throws -> FileHandle

  init(
    closeHandle: @escaping @Sendable (FileHandle) throws -> Void = { try $0.close() },
    duplicateHandle: @escaping @Sendable (FileHandle) throws -> FileHandle = { handle in
      let descriptor = fcntl(handle.fileDescriptor, F_DUPFD_CLOEXEC, 0)
      guard descriptor >= 0 else { throw LibraryExtractionPinError.duplicateFailed(errno) }
      return FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
    }
  ) {
    self.closeHandle = closeHandle
    self.duplicateHandle = duplicateHandle
  }

  func reserve(_ snapshot: ReaderPaperSnapshot, revoke: @escaping @MainActor () -> Void) throws -> UUID {
    try lock.withLock {
      guard !closed.contains(snapshot.paperID) else { throw ReaderError.revoked }
      let token = UUID()
      entries[token] = Entry(snapshot: snapshot, revoke: revoke)
      return token
    }
  }

  func install(_ handle: FileHandle?, token: UUID) throws {
    let revoked = lock.withLock {
      entries[token]!.handle = handle
      entries[token]!.opening = false
      if handle == nil { entries[token]!.closeRequested = true }
      return entries[token]!.revoked
    }
    if revoked { close(token) }
    else { finishClose(token) }
    if revoked { throw ReaderError.revoked }
  }

  func validate(_ token: UUID) throws {
    try lock.withLock {
      guard let entry = entries[token], !entry.revoked, !entry.closeRequested,
        !entry.opening, entry.handle != nil else { throw ReaderError.revoked }
    }
  }

  func beginRead(_ token: UUID) throws {
    try lock.withLock {
      guard let entry = entries[token], !entry.revoked, !entry.closeRequested,
        !entry.opening, entry.handle != nil else { throw ReaderError.revoked }
      entries[token]!.reads += 1
    }
  }

  func endRead(_ token: UUID) {
    lock.withLock { entries[token]!.reads -= 1 }
    finishClose(token)
  }

  func closureObservation(_ token: UUID) -> LibraryPinClosureObservation {
    lock.withLock { entries[token]!.receipt }
  }

  func cleanupFailedAcquisition(_ handle: FileHandle?, token: UUID,
    observation: LibraryPinClosureObservation) throws {
    let opening = lock.withLock { entries[token]?.opening == true }
    if opening { try? install(handle, token: token) }
    close(token)
    try observation.requireConfirmedClosure()
  }

  /// Linearize admission and transfer, but perform duplication/cleanup outside arbitration.
  func takeSenderPDF(_ token: UUID) throws -> FileHandle {
    let original: FileHandle = try lock.withLock {
      guard let entry = entries[token], !entry.revoked, !entry.closeRequested,
        !entry.closureUnknown, !entry.opening, let handle = entry.handle else {
        throw ReaderError.revoked
      }
      guard !entry.senderTaken else { throw LibraryExtractionPinError.senderAlreadyTaken }
      entries[token]!.senderTaken = true
      entries[token]!.reads += 1
      return handle
    }
    defer { endRead(token) }
    let sender = try duplicateHandle(original)
    let admitted = lock.withLock {
      let entry = entries[token]!
      return !entry.revoked && !entry.closeRequested && !entry.closureUnknown
    }
    guard admitted else {
      do { try closeHandle(sender) }
      catch {
        recordUnknownClosure(token, retaining: sender)
        throw LocalLibraryError.producerClosureUnknown
      }
      throw ReaderError.revoked
    }
    return sender
  }

  func retainSenderCleanupUnknown(_ sender: FileHandle, token: UUID) {
    recordUnknownClosure(token, retaining: sender)
  }

  private func recordUnknownClosure(_ token: UUID, retaining sender: FileHandle? = nil) {
    let result = lock.withLock {
      if let sender { entries[token]!.cleanupDebt.append(sender) }
      entries[token]!.closing = false
      entries[token]!.closureUnknown = true
      return (entries[token]!.receipt,
        waiters.removeValue(forKey: entries[token]!.snapshot.paperID) ?? [])
    }
    result.0.finish(.failure(LocalLibraryError.producerClosureUnknown))
    for waiter in result.1 { waiter.resume(throwing: LocalLibraryError.producerClosureUnknown) }
  }

  func close(_ token: UUID) {
    lock.withLock { if entries[token] != nil { entries[token]!.closeRequested = true } }
    finishClose(token)
  }

  private func finishClose(_ token: UUID) {
    let candidate: (Bool, FileHandle?) = lock.withLock {
      guard let entry = entries[token], entry.closeRequested, !entry.opening,
        !entry.closing, !entry.closureUnknown, entry.reads == 0 else { return (false, nil) }
      entries[token]!.closing = true
      return (true, entry.handle)
    }
    guard candidate.0 else { return }
    do { if let handle = candidate.1 { try closeHandle(handle) } }
    catch {
      // Unknown physical closure is retained as debt, never an early release.
      recordUnknownClosure(token)
      return
    }
    let result: (LibraryPinClosureObservation, [CheckedContinuation<Void, any Error>]) = lock.withLock {
      let entry = entries.removeValue(forKey: token)!
      let paperID = entry.snapshot.paperID
      let resumes = entries.values.contains(where: { $0.snapshot.paperID == paperID })
        ? [] : waiters.removeValue(forKey: paperID) ?? []
      return (entry.receipt, resumes)
    }
    result.0.finish(.success(()))
    for waiter in result.1 { waiter.resume(returning: ()) }
  }

  /// Closes admission before the caller changes durable visibility.
  func revoke(_ paperID: UUID) -> [@MainActor () -> Void] {
    lock.withLock {
      closed.insert(paperID)
      let tokens = entries.filter { $0.value.snapshot.paperID == paperID }.map(\.key)
      return tokens.map {
        entries[$0]!.revoked = true
        return entries[$0]!.revoke
      }
    }
  }

  func retryClosures(_ paperID: UUID) {
    let tokens = lock.withLock {
      entries.filter { $0.value.snapshot.paperID == paperID && $0.value.closeRequested }.map(\.key)
    }
    for token in tokens { finishClose(token) }
  }

  func drain(_ paperID: UUID) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
      let outcome: Int = lock.withLock {
        let held = entries.values.filter { $0.snapshot.paperID == paperID }
        if held.contains(where: { $0.closureUnknown }) { return -1 }
        if held.isEmpty { return 1 }
        waiters[paperID, default: []].append(continuation)
        return 0
      }
      if outcome == 1 { continuation.resume(returning: ()) }
      if outcome == -1 { continuation.resume(throwing: LocalLibraryError.producerClosureUnknown) }
    }
  }
}

/// Construct from the same lifecycle that owns import/delete; no independent DB binding.
@MainActor public final class LibraryReadLeaseProvider: ReaderLeaseProvider {
  private let lifecycle: LocalLibraryLifecycle
  public init(lifecycle: LocalLibraryLifecycle) { self.lifecycle = lifecycle }

  public func acquireReadLease(
    for snapshot: ReaderPaperSnapshot, onRevoked: @escaping @MainActor () -> Void
  ) throws -> any ReaderReadLease {
    let token = try acquireToken(for: snapshot, onRevoked: onRevoked)
    return LibraryReadLease(registry: lifecycle.readLeaseRegistry, token: token)
  }

  public func acquireExtractionReadPin(
    for snapshot: ReaderPaperSnapshot, operationID: UUID,
    onRevoked: @escaping @MainActor () -> Void
  ) throws -> LibraryExtractionReadPin {
    let token = try acquireToken(for: snapshot, onRevoked: onRevoked)
    return LibraryExtractionReadPin(operationID: operationID,
      registry: lifecycle.readLeaseRegistry, token: token)
  }

  private func acquireToken(
    for snapshot: ReaderPaperSnapshot, onRevoked: @escaping @MainActor () -> Void
  ) throws -> UUID {
    let registry = lifecycle.readLeaseRegistry
    let token = try registry.reserve(snapshot, revoke: onRevoked)
    let observation = registry.closureObservation(token)
    var handle: FileHandle?
    do {
      let database = lifecycle.readLeaseDatabase
      try database.validateReaderSnapshot(snapshot)
      let url = database.root.appendingPathComponent(snapshot.pdfReference)
      let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      guard values.isRegularFile == true, values.isSymbolicLink != true else {
        throw ReaderError.invalidReference
      }
      let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
      guard descriptor >= 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
      }
      // Only registry checked-close owns disposal, including uncertain-close debt.
      handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
      try database.validateReaderSnapshot(snapshot)
      try registry.install(handle, token: token)
      return token
    } catch {
      try registry.cleanupFailedAcquisition(handle, token: token, observation: observation)
      throw error
    }
  }
}

@MainActor private final class LibraryReadLease: ReaderReadLease {
  private let registry: LibraryReadLeaseRegistry
  private let token: UUID
  init(registry: LibraryReadLeaseRegistry, token: UUID) {
    self.registry = registry
    self.token = token
  }
  func validate() throws { try registry.validate(token) }
  func withReadAccess<T>(_ operation: () throws -> T) throws -> T {
    try registry.beginRead(token)
    defer { registry.endRead(token) }
    let result = try operation()
    try registry.validate(token)
    return result
  }
  func close() { registry.close(token) }
}
