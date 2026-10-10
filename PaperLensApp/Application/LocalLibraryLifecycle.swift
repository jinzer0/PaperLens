import CryptoKit
import Darwin
import Foundation
#if SWIFT_PACKAGE
import ProviderRequest
#endif
import UniformTypeIdentifiers

public struct AgentLibraryPurgeReceipt: Equatable, Sendable {
  public let paperID: UUID
  public let deletionID: UUID
  /// The Agent implementation may issue this only after its admitted producers have closed
  /// and its own namespace is absent. Main does not inspect or erase the Agent namespace.
  public init(paperID: UUID, deletionID: UUID) {
    self.paperID = paperID
    self.deletionID = deletionID
  }
}

public protocol AgentLibraryPurging: Sendable {
  func purgeLibraryPaper(paperID: UUID, deletionID: UUID) async throws -> AgentLibraryPurgeReceipt
}

public enum LocalLibraryError: Error, Equatable, Sendable {
  case invalidPDF, cancelled, agentPurgeUnavailable, invalidPurgeReceipt
  case deletionInProgress, cleanupFailed, producerClosureUnknown, importCapacity
}

final class ImportCancellation: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false
  private var callback: (@Sendable () -> Void)?
  func cancel() {
    let callback = lock.withLock { cancelled = true; return self.callback }
    callback?()
  }
  func bind(_ callback: @escaping @Sendable () -> Void) {
    let revoked = lock.withLock { self.callback = callback; return cancelled }
    if revoked { callback() }
  }
  func check() throws {
    if lock.withLock({ cancelled }) { throw LocalLibraryError.cancelled }
  }
}

enum ActualCopyEndpoint: Hashable, Sendable { case input, output }

struct ActualCopyEffects: Sendable {
  let beforeOpen: @Sendable (ActualCopyEndpoint, URL) throws -> Void
  let checkedClose: @Sendable (ActualCopyEndpoint, FileHandle) throws -> Void
  let startScope: @Sendable (URL) -> Bool
  let stopScope: @Sendable (URL) -> Void

  static let actual = ActualCopyEffects(beforeOpen: { _, _ in },
    checkedClose: { _, handle in try handle.close() },
    startScope: { $0.startAccessingSecurityScopedResource() },
    stopScope: { $0.stopAccessingSecurityScopedResource() })
}

/// A rooted operation owns physical obligations independently of the lifecycle facade.
/// Only the copying thread mutates it; registry readers see immutable terminal debts.
private final class ActualCopyOwner: @unchecked Sendable {
  let identity: ImportIdentity
  let source: URL
  let stage: URL
  let lease: RequestResourceLease
  let effects: ActualCopyEffects
  var scoped = false
  var input: FileHandle?
  var output: FileHandle?

  init(identity: ImportIdentity, source: URL, stage: URL, lease: RequestResourceLease,
    effects: ActualCopyEffects) {
    self.identity = identity
    self.source = source
    self.stage = stage
    self.lease = lease
    self.effects = effects
  }
}

struct ActualCopyDebt: Sendable {
  let identity: ImportIdentity
  let source: URL
  let stage: URL
  let lease: RequestResourceLease
  let scoped: Bool
  let input: FileHandle?
  let output: FileHandle?
  let inputClosed: Bool
  let outputClosed: Bool
}

private final class ActualCopyOwnership: @unchecked Sendable {
  static let shared = ActualCopyOwnership()
  private let lock = NSLock()
  private var owners: [UUID: ActualCopyOwner] = [:]
  private var debts: [UUID: ActualCopyDebt] = [:]

  func retain(_ owner: ActualCopyOwner) {
    lock.withLock { owners[owner.identity.attempt] = owner }
  }

  func retainUnknown(_ owner: ActualCopyOwner, inputClosed: Bool, outputClosed: Bool) {
    let debt = ActualCopyDebt(identity: owner.identity, source: owner.source, stage: owner.stage,
      lease: owner.lease, scoped: owner.scoped, input: owner.input, output: owner.output,
      inputClosed: inputClosed, outputClosed: outputClosed)
    lock.withLock { debts[owner.identity.attempt] = debt }
  }

  func releaseKnown(_ owner: ActualCopyOwner) {
    // Physical releases are outside arbitration, after every endpoint is known closed.
    if owner.scoped { owner.effects.stopScope(owner.source) }
    owner.lease.close()
    _ = lock.withLock { owners.removeValue(forKey: owner.identity.attempt) }
  }

  func snapshots() -> [ActualCopyDebt] { lock.withLock { Array(debts.values) } }
}

/// Application arbitration contains policy and accounting only. Every database/file effect
/// runs off this actor; deletion waits for actual producer closure, never terminal status.
public actor LocalLibraryLifecycle {
  private let database: ProductDatabase
  nonisolated let readLeaseRegistry = LibraryReadLeaseRegistry()
  nonisolated var readLeaseDatabase: ProductDatabase { database }
  private let agentPurge: (any AgentLibraryPurging)?
  private let copyEffects: ActualCopyEffects
  nonisolated let epoch = UUID()
  private var snapshots: [UUID: JobRecoveryPolicy.Snapshot] = [:]
  private var cancellations: [UUID: ImportCancellation] = [:]
  private var drains: [UUID: [CheckedContinuation<Void, Never>]] = [:]
  private var deletionInFlight: Set<UUID> = []

  public static func open(
    database: ProductDatabase, agentPurge: (any AgentLibraryPurging)? = nil
  ) async throws -> LocalLibraryLifecycle {
    try await open(database: database, agentPurge: agentPurge, copyEffects: .actual)
  }

  static func openForOwnedCopyFixtures(database: ProductDatabase, effects: ActualCopyEffects)
    async throws -> LocalLibraryLifecycle {
    try await open(database: database, agentPurge: nil, copyEffects: effects)
  }

  nonisolated static var actualCopyDebts: [ActualCopyDebt] {
    ActualCopyOwnership.shared.snapshots()
  }

  private static func open(database: ProductDatabase, agentPurge: (any AgentLibraryPurging)?,
    copyEffects: ActualCopyEffects) async throws -> LocalLibraryLifecycle {
    // Allocate Main's lifetime epoch once, before recovery, and expose no owner until
    // all registered job kinds and library validation have completed successfully.
    let lifecycle = LocalLibraryLifecycle(database: database, agentPurge: agentPurge,
      copyEffects: copyEffects)
    let epoch = lifecycle.epoch
    try await Task.detached {
      let recovery = ProductJobRecovery(database: database)
      _ = try recovery.recoverStartup(currentEpoch: epoch)
      try recovery.reconcileLibraryStartup()
    }.value
    return lifecycle
  }

  private init(database: ProductDatabase, agentPurge: (any AgentLibraryPurging)?,
    copyEffects: ActualCopyEffects) {
    self.database = database
    self.agentPurge = agentPurge
    self.copyEffects = copyEffects
  }

  public func list() async throws -> [LibraryRecord] {
    let database = database
    return try await Task.detached { try database.libraryRecords() }.value
  }

  /// The service invokes this only after consuming Continue. The confirmed folder UUID,
  /// never its presentation label, is used at both reservation and publication.
  public func grantURLImportWriter(for confirmation: URLImportConfirmation) async throws
    -> any URLImportWriter {
    guard confirmation.consumeWriterGrant() else {
      throw URLImportError.writerUnavailable
    }
    let identity = ImportIdentity(paperID: UUID(), generation: UUID(), jobID: UUID(),
      attempt: UUID(), fence: UUID(), correlation: UUID(), input: UUID(), epoch: epoch,
      writer: UUID(), publication: UUID())
    let authority = JobRecoveryPolicy.Authority(input: .source(version: identity.input.uuidString),
      config: .inapplicable,
      paper: .init(id: identity.paperID.uuidString, generation: identity.generation.uuidString),
      epoch: epoch.uuidString, prerequisitesAvailable: true)
    snapshots[identity.paperID] = try JobRecoveryPolicy.create(job: identity.jobID.uuidString,
      role: .import, authority: authority,
      reservation: .init(attempt: identity.attempt.uuidString, fence: identity.fence.uuidString,
        correlation: identity.correlation.uuidString))
    let lineage = snapshots[identity.paperID]!.current.lineage
    try apply(.claim(lineage), paperID: identity.paperID)
    try apply(.acquireWriter(lineage, permit: identity.writer.uuidString), paperID: identity.paperID)
    let cancellation = ImportCancellation()
    cancellations[identity.paperID] = cancellation
    let database = database
    let namespace = Self.namespace(database.root, identity.paperID)
    let writer = LibraryURLImportWriter(lifecycle: self, identity: identity, directory: namespace,
      destinationFolderID: confirmation.destinationFolderID, cancellation: cancellation)
    var reserved = false
    do {
      // Only bounded, fixed provenance; never URL spelling, path, query or credentials.
      let title = confirmation.sourceKind == "arxivPDF" ? "arXiv PDF" : "HTTPS PDF"
      try await Task.detached {
        try database.reserveImport(identity, title: title,
          destinationFolderID: confirmation.destinationFolderID)
      }.value
      reserved = true
      try apply(.writerClosure(lineage, permit: identity.writer.uuidString, .open),
        paperID: identity.paperID)
      try await Task.detached {
        let fm = FileManager.default
        try fm.createDirectory(at: namespace.deletingLastPathComponent(),
          withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let created = namespace.withUnsafeFileSystemRepresentation {
          Darwin.mkdir($0!, mode_t(0o700)) == 0
        }
        guard created else { throw URLImportError.writerUnavailable }
        writer.markNamespaceOwned()
      }.value
      try writer.assertCurrent()
      return writer
    } catch {
      if reserved { try await writer.abort(reason: .rejected) }
      else {
        snapshots.removeValue(forKey: identity.paperID)
        finishProducer(identity.paperID)
      }
      throw error
    }
  }

  func publishURLImport(_ writer: LibraryURLImportWriter, stage: ClosedHTTPSPDFStage) async throws -> UUID {
    let identity = writer.identity
    guard let snapshot = snapshots[identity.paperID] else { throw URLImportError.writerUnavailable }
    let lineage = snapshot.current.lineage
    try writer.assertCurrent()
    try await Task.detached {
      try LibraryURLImportWriter.validate(stage, directory: writer.stagingDirectory,
        cancellation: writer.cancellation)
    }.value
    try writer.assertCurrent()
    let result = JobRecoveryPolicy.Result(id: identity.attempt.uuidString)
    try apply(.writerClosure(lineage, permit: identity.writer.uuidString,
      .closed(.validated(result))), paperID: identity.paperID)
    try apply(.acquirePublication(lineage, writer: identity.writer.uuidString,
      permit: identity.publication.uuidString), paperID: identity.paperID)
    try apply(.rename(lineage, permit: identity.publication.uuidString), paperID: identity.paperID)
    let database = database
    do {
      try await Task.detached {
        try writer.assertCurrent()
        try database.recordProgress(identity, bytes: Int64(stage.byteCount))
        try database.publish(identity, stage: stage.file,
          final: writer.stagingDirectory.appendingPathComponent("document.pdf"),
          sha256: stage.sha256, destinationFolderID: writer.destinationFolderID)
      }.value
    } catch {
      try apply(.renameFinished(lineage, permit: identity.publication.uuidString, succeeded: false),
        paperID: identity.paperID)
      throw error
    }
    try apply(.renameFinished(lineage, permit: identity.publication.uuidString, succeeded: true),
      paperID: identity.paperID)
    try apply(.publish(lineage, permit: identity.publication.uuidString, result), paperID: identity.paperID)
    try apply(.release(lineage, permit: identity.publication.uuidString), paperID: identity.paperID)
    finishProducer(identity.paperID)
    return identity.paperID
  }

  func abortURLImport(_ writer: LibraryURLImportWriter, reason: URLImportError) async throws {
    let identity = writer.identity
    guard let snapshot = snapshots[identity.paperID] else { throw URLImportError.writerUnavailable }
    defer { finishProducer(identity.paperID) }
    let lineage = snapshot.current.lineage
    let closureKnown = reason != .closureUnknown
    var cleanupError: (any Error)?
    do {
      if closureKnown, let permit = snapshot.permits.first, permit.kind == .writer {
        if case .closed = permit.closure {} else {
          try apply(.writerClosure(lineage, permit: permit.id, .closed(.unvalidated)), paperID: identity.paperID)
        }
      }
    } catch { cleanupError = error }
    try? apply(.terminate(lineage, .failed), paperID: identity.paperID)
    var clean = false
    do {
      if closureKnown, cleanupError == nil, let permit = snapshots[identity.paperID]?.permits.first {
        let operation = UUID().uuidString
        try apply(.requestCleanup(permit.owner, permit: permit.id, operation: operation),
          paperID: identity.paperID)
        guard let pending = snapshots[identity.paperID]?.permits.first?.cleanupOperation else {
          throw URLImportError.cleanupFailed
        }
        clean = await Task.detached {
          guard writer.namespaceOwned else { return true }
          do { try Self.removeNamespace(writer.stagingDirectory); return true } catch { return false }
        }.value
        try apply(.cleanupFinished(permit.owner, permit: permit.id, operation: pending, succeeded: clean),
          paperID: identity.paperID)
        if clean { try apply(.release(permit.owner, permit: permit.id), paperID: identity.paperID) }
      }
    } catch { cleanupError = error; clean = false }
    let database = database
    let cleanupDebt = !clean
    try await Task.detached {
      try database.recordImportAbort(identity, failure: reason == .cancelled ? "cancelled" : "urlImportFailed",
        cleanupDebt: cleanupDebt)
    }.value
    if let cleanupError { throw cleanupError }
    if closureKnown && !clean { throw URLImportError.cleanupFailed }
  }

  /// Call only after explicit user confirmation. Selecting/cancelling creates nothing.
  /// Returns the durable Paper identity, including when an admitted import ends in failure.
  public func importPDF(
    from source: URL, expectedSHA256: String? = nil, destinationFolderID: UUID? = nil
  ) async throws -> UUID {
    let identity = ImportIdentity(paperID: UUID(), generation: UUID(), jobID: UUID(),
      attempt: UUID(), fence: UUID(), correlation: UUID(), input: UUID(), epoch: epoch,
      writer: UUID(), publication: UUID())
    let authority = JobRecoveryPolicy.Authority(input: .source(version: identity.input.uuidString),
      config: .inapplicable,
      paper: .init(id: identity.paperID.uuidString, generation: identity.generation.uuidString),
      epoch: identity.epoch.uuidString, prerequisitesAvailable: true)
    let reservation = JobRecoveryPolicy.Reservation(attempt: identity.attempt.uuidString,
      fence: identity.fence.uuidString, correlation: identity.correlation.uuidString)
    snapshots[identity.paperID] = try JobRecoveryPolicy.create(job: identity.jobID.uuidString,
      role: .import, authority: authority, reservation: reservation)
    let lineage = snapshots[identity.paperID]!.current.lineage
    try apply(.claim(lineage), paperID: identity.paperID)
    try apply(.acquireWriter(lineage, permit: identity.writer.uuidString), paperID: identity.paperID)
    let cancellation = ImportCancellation()
    cancellations[identity.paperID] = cancellation
    let database = database
    let namespace = Self.namespace(database.root, identity.paperID)
    let stage = namespace.appendingPathComponent("\(identity.attempt.uuidString).stage")
    let final = namespace.appendingPathComponent("document.pdf")
    let copyEffects = copyEffects
    var reserved = false
    var renamed = false
    do {
      // Source title metadata is not accessed here; only the picker-supplied URL spelling.
      let title = String(source.deletingPathExtension().lastPathComponent.prefix(240))
      try await Task.detached {
        try database.reserveImport(identity, title: title, destinationFolderID: destinationFolderID)
      }.value
      reserved = true
      try apply(.writerClosure(lineage, permit: identity.writer.uuidString, .open),
        paperID: identity.paperID)
      let digest = try await withTaskCancellationHandler {
        try await Task.detached {
          try Self.copyValidatedPDF(source: source, stage: stage, identity: identity,
            database: database, cancellation: cancellation, effects: copyEffects)
        }.value
      } onCancel: { cancellation.cancel() }
      let result = JobRecoveryPolicy.Result(id: identity.attempt.uuidString)
      try apply(.writerClosure(lineage, permit: identity.writer.uuidString,
        .closed(.validated(result))), paperID: identity.paperID)
      if let expectedSHA256, digest != expectedSHA256 { throw FolderImportError.sourceChanged }
      try cancellation.check()
      try apply(.acquirePublication(lineage, writer: identity.writer.uuidString,
        permit: identity.publication.uuidString), paperID: identity.paperID)
      try apply(.rename(lineage, permit: identity.publication.uuidString), paperID: identity.paperID)
      do {
        try await Task.detached {
          try database.publish(identity, stage: stage, final: final, sha256: digest,
            destinationFolderID: destinationFolderID)
        }.value
        renamed = true
      } catch {
        try apply(.renameFinished(lineage, permit: identity.publication.uuidString, succeeded: false),
          paperID: identity.paperID)
        throw error
      }
      try apply(.renameFinished(lineage, permit: identity.publication.uuidString, succeeded: true),
        paperID: identity.paperID)
      try apply(.publish(lineage, permit: identity.publication.uuidString, result),
        paperID: identity.paperID)
      try apply(.release(lineage, permit: identity.publication.uuidString), paperID: identity.paperID)
      finishProducer(identity.paperID)
      return identity.paperID
    } catch {
      // Actual closure precedes cleanup/release. A failed guard after rename removes bytes
      // while its publication permit still prevents namespace deletion.
      let closureKnown = (error as? LocalLibraryError) != .producerClosureUnknown
      if closureKnown, let snapshot = snapshots[identity.paperID],
        let permit = snapshot.permits.first, case .unknown = permit.closure {
        try? apply(.writerClosure(lineage, permit: permit.id, .closed(.unvalidated)),
          paperID: identity.paperID)
      } else if closureKnown, let snapshot = snapshots[identity.paperID],
        let permit = snapshot.permits.first, case .open = permit.closure {
        try? apply(.writerClosure(lineage, permit: permit.id, .closed(.unvalidated)),
          paperID: identity.paperID)
      }
      try? apply(.terminate(lineage, .failed), paperID: identity.paperID)
      let clean: Bool = await Task.detached {
        guard closureKnown else { return false }
        do { try Self.removeNamespace(namespace); return true } catch { return false }
      }.value
      if let permit = snapshots[identity.paperID]?.permits.first {
        let operationID = UUID().uuidString
        try? apply(.requestCleanup(lineage, permit: permit.id, operation: operationID),
          paperID: identity.paperID)
        if let operation = snapshots[identity.paperID]?.permits.first?.cleanupOperation {
          try? apply(.cleanupFinished(lineage, permit: permit.id, operation: operation, succeeded: clean),
            paperID: identity.paperID)
        }
        if clean { try? apply(.release(lineage, permit: permit.id), paperID: identity.paperID) }
      }
      if reserved {
        let failure: String
        if (error as? FolderImportError) == .sourceChanged { failure = "sourceChanged" }
        else if (error as? LocalLibraryError) == .cancelled { failure = "cancelled" }
        else { failure = renamed ? "publicationRejected" : "importFailed" }
        do {
          try await Task.detached {
            try database.recordImportAbort(identity, failure: failure, cleanupDebt: !clean)
          }.value
        } catch {
          finishProducer(identity.paperID)
          throw error // Do not conceal inability to record the failure.
        }
      }
      finishProducer(identity.paperID)
      if !reserved { throw error }
      return identity.paperID
    }
  }

  public func delete(paperID: UUID) async throws {
    guard deletionInFlight.insert(paperID).inserted else { throw LocalLibraryError.deletionInProgress }
    defer { deletionInFlight.remove(paperID) }
    let database = database
    // Shared admission closes before durable visibility changes; callbacks never run under lock.
    let callbacks = readLeaseRegistry.revoke(paperID)
    await MainActor.run { for callback in callbacks { callback() } }
    guard let saga = try await Task.detached(operation: { try database.beginDeletion(paperID) }).value
    else { return } // Already finalized contentless tombstone: idempotent, not reactivated.
    if snapshots[paperID] != nil { try apply(.revoke, paperID: paperID) }
    cancellations[paperID]?.cancel()
    if cancellations[paperID] != nil {
      await withCheckedContinuation { drains[paperID, default: []].append($0) }
    }
    do {
      readLeaseRegistry.retryClosures(paperID)
      try await readLeaseRegistry.drain(paperID)
      guard let agentPurge else { throw LocalLibraryError.agentPurgeUnavailable }
      let receipt = try await agentPurge.purgeLibraryPaper(paperID: paperID, deletionID: saga)
      guard receipt.paperID == paperID, receipt.deletionID == saga else {
        throw LocalLibraryError.invalidPurgeReceipt
      }
      // A failed producer cleanup remains a permit debt. Retrying the same deletion repairs
      // its physically closed permits before the policy admits namespace removal.
      if let snapshot = snapshots[paperID] {
        for permit in snapshot.permits {
          let operation = UUID().uuidString
          try apply(.requestCleanup(permit.owner, permit: permit.id, operation: operation), paperID: paperID)
          let namespace = Self.namespace(database.root, paperID)
          guard let pending = snapshots[paperID]?.permits.first(where: { $0.id == permit.id })?.cleanupOperation
          else { throw LocalLibraryError.cleanupFailed }
          do {
            try await Task.detached { try Self.removeNamespace(namespace) }.value
          } catch {
            try? apply(.cleanupFinished(permit.owner, permit: permit.id, operation: pending, succeeded: false),
              paperID: paperID)
            throw error
          }
          try apply(.cleanupFinished(permit.owner, permit: permit.id, operation: pending, succeeded: true),
            paperID: paperID)
          try apply(.release(permit.owner, permit: permit.id), paperID: paperID)
        }
        if !snapshot.namespaceRemoved {
          try apply(.removeNamespace(operation: UUID().uuidString), paperID: paperID)
        }
      }
      let namespace = Self.namespace(database.root, paperID)
      do {
        try await Task.detached { try Self.removeNamespace(namespace) }.value
      } catch {
        if let pending = snapshots[paperID]?.pendingRemoval {
          try? apply(.namespaceRemovalFinished(operation: pending, succeeded: false), paperID: paperID)
        }
        throw error
      }
      if let pending = snapshots[paperID]?.pendingRemoval {
        try apply(.namespaceRemovalFinished(operation: pending, succeeded: true), paperID: paperID)
      }
      try await Task.detached { try database.finalizeDeletion(paperID, saga: saga) }.value
      snapshots.removeValue(forKey: paperID)
    } catch {
      let reason: String
      switch error {
      case LocalLibraryError.agentPurgeUnavailable: reason = "agentPurgeUnavailable"
      case LocalLibraryError.invalidPurgeReceipt: reason = "agentClosureUnproved"
      default: reason = "deletionIncomplete"
      }
      try await Task.detached { try database.deletionFailed(paperID, saga: saga, reason: reason) }.value
      throw error
    }
  }

  public func retryDeletion(paperID: UUID) async throws { try await delete(paperID: paperID) }

  private func apply(_ event: JobRecoveryPolicy.Event, paperID: UUID) throws {
    guard let snapshot = snapshots[paperID] else { throw ProductDatabaseError.invalidRecord }
    let decision = JobRecoveryPolicy.apply(event, to: snapshot)
    snapshots[paperID] = decision.snapshot
    if let rejection = decision.rejection { throw rejection }
  }

  private func finishProducer(_ paperID: UUID) {
    cancellations.removeValue(forKey: paperID)
    for continuation in drains.removeValue(forKey: paperID) ?? [] { continuation.resume() }
  }

  private nonisolated static func namespace(_ root: URL, _ paperID: UUID) -> URL {
    root.appendingPathComponent("papers", isDirectory: true)
      .appendingPathComponent(paperID.uuidString, isDirectory: true)
  }

  private nonisolated static func removeNamespace(_ url: URL) throws {
    let fm = FileManager.default
    if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
    guard !fm.fileExists(atPath: url.path) else { throw LocalLibraryError.cleanupFailed }
  }

  private nonisolated static func copyValidatedPDF(
    source: URL, stage: URL, identity: ImportIdentity, database: ProductDatabase,
    cancellation: ImportCancellation, effects: ActualCopyEffects
  ) throws -> String {
    try cancellation.check()
    guard source.isFileURL, !source.path(percentEncoded: false).utf8.contains(0) else {
      throw LocalLibraryError.invalidPDF
    }
    let authority = try ProviderRequest()
    let pool = try RequestResourcePool(authority: authority, kind: "import")
    guard let lease = pool.acquire() else { throw LocalLibraryError.importCapacity }
    let owner = ActualCopyOwner(identity: identity, source: source, stage: stage, lease: lease,
      effects: effects)
    ActualCopyOwnership.shared.retain(owner)
    owner.scoped = effects.startScope(source)
    let fm = FileManager.default
    var hash = SHA256()
    var workError: (any Error)?
    do {
      var selected = stat()
      guard source.withUnsafeFileSystemRepresentation({ path in
        guard let path else { return Int32(-1) }
        return Darwin.lstat(path, &selected)
      }) == 0,
        selected.st_mode & S_IFMT == S_IFREG, selected.st_size > 0,
        selected.st_size <= Int64(authority.limit("pdfBytes")) else {
        throw LocalLibraryError.invalidPDF
      }
      let values = try source.resourceValues(forKeys: [.contentTypeKey])
      guard values.contentType?.conforms(to: .pdf) == true else { throw LocalLibraryError.invalidPDF }
      let budget = try RequestResourceBudget(authority: authority, kind: "import")
      try effects.beforeOpen(.input, source)
      let inputFD = source.withUnsafeFileSystemRepresentation { path in
        guard let path else { return Int32(-1) }
        return Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
      }
      guard inputFD >= 0 else { throw LocalLibraryError.invalidPDF }
      let input = FileHandle(fileDescriptor: inputFD, closeOnDealloc: false)
      owner.input = input
      var actual = stat()
      guard Darwin.fstat(inputFD, &actual) == 0, actual.st_mode & S_IFMT == S_IFREG,
        actual.st_dev == selected.st_dev, actual.st_ino == selected.st_ino,
        actual.st_size > 0, actual.st_size <= Int64(authority.limit("pdfBytes")) else {
        throw LocalLibraryError.invalidPDF
      }
      try fm.createDirectory(at: stage.deletingLastPathComponent(), withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      try effects.beforeOpen(.output, stage)
      let outputFD = stage.withUnsafeFileSystemRepresentation { path in
        guard let path else { return Int32(-1) }
        return Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK,
          mode_t(0o600))
      }
      guard outputFD >= 0 else { throw LocalLibraryError.invalidPDF }
      let output = FileHandle(fileDescriptor: outputFD, closeOnDealloc: false)
      owner.output = output
      var created = stat()
      guard Darwin.fstat(outputFD, &created) == 0, created.st_mode & S_IFMT == S_IFREG,
        created.st_uid == Darwin.getuid(), created.st_mode & 0o7777 == 0o600,
        created.st_nlink == 1, created.st_size == 0 else { throw LocalLibraryError.invalidPDF }
      var first = true
      var copied: Int64 = 0
      let clock = ContinuousClock()
      let started = clock.now
      while true {
        try cancellation.check()
        let elapsed = started.duration(to: clock.now).components
        let milliseconds = Int(elapsed.seconds) * 1000 + Int(elapsed.attoseconds / 1_000_000_000_000_000)
        try budget.observe("elapsedMs", value: milliseconds)
        guard let chunk = try input.read(upToCount: authority.limit("readBufferBytes")), !chunk.isEmpty
        else { break }
        try budget.observe("readBufferBytes", value: chunk.count)
        if first {
          try authority.validatePDFSignature(prefix: chunk, mime: nil, sourceKind: "localPDF")
          first = false
        }
        try budget.add("bodyBytes", delta: chunk.count)
        try output.write(contentsOf: chunk)
        hash.update(data: chunk)
        copied += Int64(chunk.count)
        try database.recordProgress(identity, bytes: copied)
      }
      guard !first, copied == actual.st_size else { throw LocalLibraryError.invalidPDF }
      try output.synchronize()
      guard Darwin.fchmod(outputFD, mode_t(0o400)) == 0 else { throw LocalLibraryError.invalidPDF }
    } catch { workError = error }
    var inputClosed = owner.input == nil
    var outputClosed = owner.output == nil
    var closureUnknown = false
    if let output = owner.output {
      do { try effects.checkedClose(.output, output); outputClosed = true }
      catch { closureUnknown = true }
    }
    if let input = owner.input {
      do { try effects.checkedClose(.input, input); inputClosed = true }
      catch { closureUnknown = true }
    }
    guard !closureUnknown && inputClosed && outputClosed else {
      ActualCopyOwnership.shared.retainUnknown(owner, inputClosed: inputClosed, outputClosed: outputClosed)
      throw LocalLibraryError.producerClosureUnknown
    }
    ActualCopyOwnership.shared.releaseKnown(owner)
    if let workError { throw workError }
    try cancellation.check()
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
  }
}
