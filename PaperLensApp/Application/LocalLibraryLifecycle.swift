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

/// Production currently admits paper generation only through Main-owned native
/// transports. SDK paper RPCs remain refused. An unexpected Agent-paper namespace
/// is debt, never evidence that this version may erase or adopt it.
public actor NativeOnlyAgentLibraryPurge: AgentLibraryPurging {
  private let unsupportedPaperRoot: URL
  public init(unsupportedPaperRoot: URL) { self.unsupportedPaperRoot = unsupportedPaperRoot }

  public func purgeLibraryPaper(paperID: UUID, deletionID: UUID) async throws -> AgentLibraryPurgeReceipt {
    guard unsupportedPaperRoot.isFileURL else { throw LocalLibraryError.cleanupFailed }
    var info = stat()
    guard lstat(unsupportedPaperRoot.path, &info) != 0, errno == ENOENT else {
      throw LocalLibraryError.producerClosureUnknown
    }
    return AgentLibraryPurgeReceipt(paperID: paperID, deletionID: deletionID)
  }
}

/// Summary workers are Main-owned and retire before their read lease closes. The
/// peer also fences legacy Agent data and unowned scopes left by an earlier run.
@MainActor
public final class IsolatedAgentLibraryPurge: AgentLibraryPurging {
  private let legacy: NativeOnlyAgentLibraryPurge
  private let summaryRoot: URL
  private var connection: NativeCodexConnection?

  public init(unsupportedPaperRoot: URL, summaryRoot: URL) {
    legacy = NativeOnlyAgentLibraryPurge(unsupportedPaperRoot: unsupportedPaperRoot)
    self.summaryRoot = summaryRoot
  }

  public func bind(_ connection: NativeCodexConnection) { self.connection = connection }

  public func purgeLibraryPaper(paperID: UUID, deletionID: UUID) async throws -> AgentLibraryPurgeReceipt {
    _ = try await legacy.purgeLibraryPaper(paperID: paperID, deletionID: deletionID)
    if let connection {
      return try await connection.purgeSummaryPaper(paperID: paperID, deletionID: deletionID)
    }
    // Startup recovery has no live owner to vouch for remnants. Do not adopt/delete them.
    try Self.requireEmptySummaryRoot(summaryRoot)
    return AgentLibraryPurgeReceipt(paperID: paperID, deletionID: deletionID)
  }

  internal static func requireEmptySummaryRoot(_ root: URL) throws {
    guard root.isFileURL else { throw LocalLibraryError.cleanupFailed }
    var info = stat()
    if lstat(root.path, &info) != 0 {
      guard errno == ENOENT else { throw LocalLibraryError.producerClosureUnknown }
      return
    }
    guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(),
      info.st_mode & 0o077 == 0,
      try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty
    else { throw LocalLibraryError.producerClosureUnknown }
  }
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

/// Fixture observation only; this value cannot attest closure to the lifecycle.
struct ActualCopyCompletionObservation: Sendable {
  enum Status: Equatable, Sendable { case neverStarted, closedUnvalidated, closedValidated, unknown }
  let identity: ImportIdentity
  let status: Status
  let error: (any Error)?
  let sha256: String?
  let bytes: Int64?
}

private struct ActualClosedImportStage: Sendable {
  let file: URL
  let sha256: String
  let bytes: Int64
}

private struct ActualCopyCompletion: Sendable {
  enum Outcome: Sendable {
    case neverStarted(any Error)
    case closedUnvalidated(any Error)
    case closedValidated(ActualClosedImportStage)
    case unknown(ActualCopyOwner)
  }
  let identity: ImportIdentity
  let outcome: Outcome
  let namespaceOwned: Bool

  func matches(_ other: ImportIdentity) -> Bool {
    identity.paperID == other.paperID && identity.generation == other.generation &&
      identity.jobID == other.jobID && identity.attempt == other.attempt &&
      identity.fence == other.fence && identity.correlation == other.correlation &&
      identity.input == other.input && identity.epoch == other.epoch &&
      identity.writer == other.writer && identity.publication == other.publication
  }

  var closureKnown: Bool {
    switch outcome {
    case .neverStarted, .closedUnvalidated, .closedValidated: return true
    case .unknown: return false
    }
  }
}

struct ActualCopyEffects: Sendable {
  let beforeOpen: @Sendable (ActualCopyEndpoint, URL) throws -> Void
  let checkedClose: @Sendable (ActualCopyEndpoint, FileHandle) throws -> Void
  let startScope: @Sendable (URL) -> Bool
  let stopScope: @Sendable (URL) -> Void
  let completed: @Sendable (ActualCopyCompletionObservation) -> Void

  static let actual = ActualCopyEffects(beforeOpen: { _, _ in },
    checkedClose: { _, handle in try handle.close() },
    startScope: { $0.startAccessingSecurityScopedResource() },
    stopScope: { $0.stopAccessingSecurityScopedResource() }, completed: { _ in })
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
  var namespaceOwned = false

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

private final class ActualNamespaceRemoval: @unchecked Sendable {
  let namespace: URL
  private let lock = NSLock()
  private var outcome: Result<Void, any Error>?
  init(namespace: URL) { self.namespace = namespace }
  var result: Result<Void, any Error>? { lock.withLock { outcome } }
  func perform(_ effect: () throws -> Void) {
    let result = Result { try effect() }
    lock.withLock { outcome = result }
  }
}

private final class ActualCopyOwnership: @unchecked Sendable {
  static let shared = ActualCopyOwnership()
  private let lock = NSLock()
  private var owners: [UUID: ActualCopyOwner] = [:]
  private var debts: [UUID: ActualCopyDebt] = [:]
  private var completions: [UUID: ActualCopyCompletion] = [:]
  private var publications: [UUID: ImportPublicationReceipt] = [:]
  private var removals: [String: ActualNamespaceRemoval] = [:]

  func removal(_ id: String) -> ActualNamespaceRemoval? { lock.withLock { removals[id] } }
  func retainRemoval(_ receipt: ActualNamespaceRemoval, id: String) {
    lock.withLock { removals[id] = receipt }
  }
  func acknowledgeRemoval(_ id: String) {
    let removed = lock.withLock { removals.removeValue(forKey: id) }
    withExtendedLifetime(removed) {}
  }

  func retainCompletion(_ completion: ActualCopyCompletion) {
    lock.withLock { completions[completion.identity.attempt] = completion }
  }

  func completion(_ identity: ImportIdentity) -> ActualCopyCompletion? {
    lock.withLock { completions[identity.attempt] }
  }

  func retainPublication(_ receipt: ImportPublicationReceipt, identity: ImportIdentity) {
    lock.withLock { publications[identity.attempt] = receipt }
  }

  func publication(_ identity: ImportIdentity) -> ImportPublicationReceipt? {
    lock.withLock { publications[identity.attempt] }
  }

  func acknowledge(_ identity: ImportIdentity) {
    let removed = lock.withLock { () -> (ActualCopyOwner?, ActualCopyCompletion?, ImportPublicationReceipt?) in
      guard debts[identity.attempt] == nil else { return (nil, nil, nil) }
      return (owners.removeValue(forKey: identity.attempt),
        completions.removeValue(forKey: identity.attempt), publications.removeValue(forKey: identity.attempt))
    }
    withExtendedLifetime(removed) {}
  }

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
    // Keep the actual completion/owner rooted until its exact durable acknowledgment.
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
  public nonisolated let deletionPeerAvailable: Bool
  private let copyEffects: ActualCopyEffects
  private let validationEffects: ActualURLStageValidationEffects
  nonisolated let epoch = UUID()
  private var records: [UUID: ImportRecoveryRecord] = [:]
  private var deletionSagas: [UUID: UUID] = [:]
  private var transitionOwners: Set<UUID> = []
  private var transitionWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]
  private var cancellations: [UUID: ImportCancellation] = [:]
  private var drains: [UUID: [CheckedContinuation<Void, Never>]] = [:]
  private var deletionInFlight: Set<UUID> = []

  public static func open(
    database: ProductDatabase, agentPurge: (any AgentLibraryPurging)? = nil
  ) async throws -> LocalLibraryLifecycle {
    try await open(database: database, agentPurge: agentPurge, copyEffects: .actual,
      validationEffects: .actual)
  }

  static func openForOwnedCopyFixtures(database: ProductDatabase, effects: ActualCopyEffects)
    async throws -> LocalLibraryLifecycle {
    try await open(database: database, agentPurge: nil, copyEffects: effects,
      validationEffects: .actual)
  }

  static func openForOwnedURLValidationFixtures(database: ProductDatabase,
    effects: ActualURLStageValidationEffects) async throws -> LocalLibraryLifecycle {
    try await open(database: database, agentPurge: nil, copyEffects: .actual,
      validationEffects: effects)
  }

  nonisolated static var actualCopyDebts: [ActualCopyDebt] {
    ActualCopyOwnership.shared.snapshots()
  }

  private static func open(database: ProductDatabase, agentPurge: (any AgentLibraryPurging)?,
    copyEffects: ActualCopyEffects, validationEffects: ActualURLStageValidationEffects)
    async throws -> LocalLibraryLifecycle {
    try Task.checkCancellation()
    // Allocate Main's lifetime epoch once, before recovery, and expose no owner until
    // all registered job kinds and library validation have completed successfully.
    let lifecycle = LocalLibraryLifecycle(database: database, agentPurge: agentPurge,
      copyEffects: copyEffects, validationEffects: validationEffects)
    let epoch = lifecycle.epoch
    let worker = Task.detached {
      try Task.checkCancellation()
      let recovery = ProductJobRecovery(database: database)
      _ = try recovery.recoverStartup(currentEpoch: epoch)
      try Task.checkCancellation()
      try recovery.reconcileLibraryStartup()
      try Task.checkCancellation()
    }
    try await withTaskCancellationHandler {
      try await worker.value
    } onCancel: {
      worker.cancel()
    }
    try Task.checkCancellation()
    return lifecycle
  }

  private init(database: ProductDatabase, agentPurge: (any AgentLibraryPurging)?,
    copyEffects: ActualCopyEffects, validationEffects: ActualURLStageValidationEffects) {
    self.database = database
    self.agentPurge = agentPurge
    self.deletionPeerAvailable = agentPurge != nil
    self.copyEffects = copyEffects
    self.validationEffects = validationEffects
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
    let identity: ImportIdentity
    switch confirmation.purpose {
    case .newPaper:
      identity = ImportIdentity(paperID: UUID(), generation: UUID(), jobID: UUID(),
        attempt: UUID(), fence: UUID(), correlation: UUID(), input: UUID(), epoch: epoch,
        writer: UUID(), publication: UUID())
    case .retry(let expected):
      let previous = try expected.journal.currentCapture().identity
      identity = ImportIdentity(paperID: previous.paperID, generation: previous.generation,
        jobID: previous.jobID, attempt: UUID(), fence: UUID(), correlation: UUID(), input: UUID(),
        epoch: epoch, writer: UUID(), publication: UUID())
    }
    let cancellation = ImportCancellation()
    let database = database
    let namespace = Self.namespace(database.root, identity.paperID)
    let writer = LibraryURLImportWriter(lifecycle: self, identity: identity, directory: namespace,
      destinationFolderID: confirmation.destinationFolderID, cancellation: cancellation)
    var reserved = false
    do {
      try await reserveURLImport(identity, confirmation: confirmation, cancellation: cancellation)
      reserved = true
      try confirmation.bindFailedQuery { try await self.captureFailedURLImport(identity) }
      LibraryURLImportWriter.retain(writer)
      try await writerOpened(identity)
      try await Task.detached {
        try cancellation.check()
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
      throw error
    }
  }

  /// The FIFO covers only reservation acknowledgment and owner installation. The
  /// existing writer then owns opening, producer drain, publication and abort.
  private func reserveURLImport(_ identity: ImportIdentity, confirmation: URLImportConfirmation,
    cancellation: ImportCancellation) async throws {
    await enterTransition(identity.paperID)
    defer { leaveTransition(identity.paperID) }
    guard cancellations[identity.paperID] == nil, !deletionInFlight.contains(identity.paperID),
      deletionSagas[identity.paperID] == nil else { throw LocalLibraryError.deletionInProgress }
    let database = database
    if case .retry = confirmation.purpose {
      let namespace = Self.namespace(database.root, identity.paperID)
      guard try await Task.detached(operation: { try Self.checkedNamespace(namespace) == nil }).value else {
        throw LocalLibraryError.cleanupFailed
      }
      guard !deletionInFlight.contains(identity.paperID), deletionSagas[identity.paperID] == nil else {
        throw LocalLibraryError.deletionInProgress
      }
    }
    cancellations[identity.paperID] = cancellation
    let actualEpoch = epoch
    do {
      let acknowledged = try await Task.detached {
        switch confirmation.purpose {
        case .newPaper:
          // Only fixed provenance, never URL spelling, query or credentials.
          let title = confirmation.sourceKind == "arxivPDF" ? "arXiv PDF" : "HTTPS PDF"
          return try database.reserveJournaledImport(identity, title: title,
            confirmedInput: .init(expectedSHA256: nil,
              destinationFolderID: confirmation.destinationFolderID))
        case .retry(let expected):
          return try database.reserveJournaledURLImportRetry(expected: expected, identity: identity,
            confirmation: confirmation, currentEpoch: actualEpoch)
        }
      }.value
      records[identity.paperID] = acknowledged
    } catch {
      finishProducer(identity.paperID)
      throw error
    }
  }

  /// Read-only capture for the exact execution Main actually acknowledged. This
  /// query cannot settle any producer, erase a namespace, or repair cleanup debt.
  private func captureFailedURLImport(_ identity: ImportIdentity) async throws -> ImportRecoveryRecord {
    await enterTransition(identity.paperID)
    defer { leaveTransition(identity.paperID) }
    guard cancellations[identity.paperID] == nil, !deletionInFlight.contains(identity.paperID),
      deletionSagas[identity.paperID] == nil else { throw LocalLibraryError.deletionInProgress }
    let database = database
    let namespace = Self.namespace(database.root, identity.paperID)
    let captured = try await Task.detached {
      let captured = try database.captureRetryableImport(paperID: identity.paperID,
        generation: identity.generation)
      guard try Self.checkedNamespace(namespace) == nil else { throw LocalLibraryError.cleanupFailed }
      return captured
    }.value
    let actual = try captured.journal.currentCapture().identity
    guard actual.paperID == identity.paperID, actual.generation == identity.generation,
      actual.jobID == identity.jobID, actual.attempt == identity.attempt,
      actual.fence == identity.fence, actual.correlation == identity.correlation,
      actual.input == identity.input, actual.epoch == identity.epoch,
      actual.writer == identity.writer, actual.publication == identity.publication,
      !deletionInFlight.contains(identity.paperID), deletionSagas[identity.paperID] == nil,
      cancellations[identity.paperID] == nil else { throw ImportRecoveryPersistenceError.staleHistory }
    return captured
  }

  func publishURLImport(_ writer: LibraryURLImportWriter, stage: ClosedHTTPSPDFStage) async throws -> UUID {
    let identity = writer.identity
    try writer.assertCurrent()
    try writer.assertProducedStage(stage)
    let validationEffects = validationEffects
    let validation = try await Task.detached {
      try LibraryURLImportWriter.validate(stage, directory: writer.stagingDirectory,
        cancellation: writer.cancellation, effects: validationEffects)
    }.value
    writer.retainValidation(validation)
    let closed = ClosedImportStage(file: stage.file, sha256: stage.sha256, bytes: Int64(stage.byteCount))
    try await publishClosed(identity, stage: closed, cancellation: writer.cancellation)
    writer.acknowledgePhysicalCompletion()
    LibraryURLImportWriter.release(writer)
    finishProducer(identity.paperID)
    return identity.paperID
  }

  private func publishClosed(_ identity: ImportIdentity, stage: ClosedImportStage,
    cancellation: ImportCancellation) async throws {
    await enterTransition(identity.paperID)
    defer { leaveTransition(identity.paperID) }
    var record = try currentRecord(identity.paperID)
    let lineage = try record.journal.snapshot().current.lineage
    let result = JobRecoveryPolicy.Result(id: identity.attempt.uuidString)
    try cancellation.check()
    let database = database
    try await Task.detached { try database.recordProgress(identity, bytes: stage.bytes) }.value
    var journal = try record.journal.recording(.writerClosure(lineage,
      permit: identity.writer.uuidString, .closed(.validated(result))))
    journal = try journal.recording(.acquirePublication(lineage, writer: identity.writer.uuidString,
      permit: identity.publication.uuidString))
    journal = try journal.recording(.rename(lineage, permit: identity.publication.uuidString))
    try Self.preflight(journal)
    record = try await store(record, replacement: journal, paperID: identity.paperID)
    let receipt = ImportPublicationReceipt(stage: stage)
    ActualCopyOwnership.shared.retainPublication(receipt, identity: identity)
    do {
      try cancellation.check()
      let admitted = record
      let committed = try await Task.detached {
        try database.publishJournaledImport(expected: admitted, closedStage: stage, receipt: receipt)
      }.value
      records[identity.paperID] = committed
    } catch {
      let admitted = record
      // Reconcile even when move did not occur: a failure is not an acknowledgment.
      if let committed = try await Task.detached(operation: {
        try database.reconcileJournaledPublication(expected: admitted, closedStage: stage)
      }).value {
        records[identity.paperID] = committed
        ActualCopyOwnership.shared.acknowledge(identity)
        return
      }
      let failed = try record.journal.recording(.renameFinished(lineage,
        permit: identity.publication.uuidString, succeeded: receipt.moved))
      _ = try await store(record, replacement: failed, paperID: identity.paperID)
      throw error
    }
    ActualCopyOwnership.shared.acknowledge(identity)
  }

  func abortURLImport(_ writer: LibraryURLImportWriter, reason: URLImportError) async throws {
    let identity = writer.identity
    defer { finishProducer(identity.paperID) }
    try await abortClosed(identity, closureKnown: writer.actualClosureKnown,
      failure: reason == .cancelled ? .cancelled : .urlImportFailed)
    if writer.actualClosureKnown {
      writer.acknowledgePhysicalCompletion()
      LibraryURLImportWriter.release(writer)
    }
  }

  /// Call only after explicit user confirmation. Selecting/cancelling creates nothing.
  /// Returns the durable Paper identity, including when an admitted import ends in failure.
  public func importPDF(
    from source: URL, expectedSHA256: String? = nil, destinationFolderID: UUID? = nil
  ) async throws -> UUID {
    let identity = ImportIdentity(paperID: UUID(), generation: UUID(), jobID: UUID(),
      attempt: UUID(), fence: UUID(), correlation: UUID(), input: UUID(), epoch: epoch,
      writer: UUID(), publication: UUID())
    let cancellation = ImportCancellation()
    cancellations[identity.paperID] = cancellation
    do {
      // Source title metadata is not accessed here; only the picker-supplied URL spelling.
      let title = String(source.deletingPathExtension().lastPathComponent.prefix(240))
      try await reserve(identity, title: title,
        facts: .init(expectedSHA256: expectedSHA256, destinationFolderID: destinationFolderID))
    } catch {
      finishProducer(identity.paperID)
      throw error
    }
    return try await runLocalImport(identity, source: source, expectedSHA256: expectedSHA256,
      cancellation: cancellation)
  }

  /// Only a consumed fresh local confirmation may call this; old facts are never replayed.
  func retryImportPDF(expected: ImportRecoveryRecord, from source: URL,
    expectedSHA256: String, destinationFolderID: UUID?) async throws -> UUID {
    let previous = try expected.journal.currentCapture().identity
    let identity = ImportIdentity(paperID: previous.paperID, generation: previous.generation,
      jobID: previous.jobID, attempt: UUID(), fence: UUID(), correlation: UUID(), input: UUID(),
      epoch: epoch, writer: UUID(), publication: UUID())
    let cancellation = ImportCancellation()
    await enterTransition(identity.paperID)
    do {
      guard cancellations[identity.paperID] == nil, !deletionInFlight.contains(identity.paperID),
        deletionSagas[identity.paperID] == nil else { throw LocalLibraryError.deletionInProgress }
      let database = database
      let namespace = Self.namespace(database.root, identity.paperID)
      guard try await Task.detached(operation: { try Self.checkedNamespace(namespace) == nil }).value else {
        throw LocalLibraryError.cleanupFailed
      }
      guard !deletionInFlight.contains(identity.paperID) else { throw LocalLibraryError.deletionInProgress }
      cancellations[identity.paperID] = cancellation
      let actualEpoch = epoch
      let acknowledged: ImportRecoveryRecord
      do {
        acknowledged = try await Task.detached {
          try database.reserveJournaledImportRetry(expected: expected, identity: identity,
            confirmedInput: .init(expectedSHA256: expectedSHA256, destinationFolderID: destinationFolderID),
            currentEpoch: actualEpoch)
        }.value
      } catch {
        finishProducer(identity.paperID)
        throw error
      }
      records[identity.paperID] = acknowledged
      leaveTransition(identity.paperID)
    } catch {
      leaveTransition(identity.paperID)
      throw error
    }
    return try await runLocalImport(identity, source: source, expectedSHA256: expectedSHA256,
      cancellation: cancellation)
  }

  /// Ordinary import and same-Job Retry share the actual producer and every terminal path.
  private func runLocalImport(_ identity: ImportIdentity, source: URL, expectedSHA256: String?,
    cancellation: ImportCancellation) async throws -> UUID {
    let database = database
    let namespace = Self.namespace(database.root, identity.paperID)
    let stage = namespace.appendingPathComponent("\(identity.attempt.uuidString).stage")
    let copyEffects = copyEffects
    var producerStarted = false
    var completion: ActualCopyCompletion?
    do {
      try await writerOpened(identity)
      producerStarted = true
      let actualCompletion = await withTaskCancellationHandler {
        let producerTask = Task.detached {
          Self.copyValidatedPDF(source: source, stage: stage, identity: identity,
            database: database, cancellation: cancellation, effects: copyEffects,
            expectedSHA256: expectedSHA256)
        }
        return await producerTask.value
      } onCancel: { cancellation.cancel() }
      guard actualCompletion.matches(identity) else { throw LocalLibraryError.producerClosureUnknown }
      completion = actualCompletion
      let closedStage: ActualClosedImportStage
      switch actualCompletion.outcome {
      case .neverStarted(let error), .closedUnvalidated(let error): throw error
      case .unknown: throw LocalLibraryError.producerClosureUnknown
      case .closedValidated(let stage): closedStage = stage
      }
      try await publishClosed(identity,
        stage: .init(file: closedStage.file, sha256: closedStage.sha256, bytes: closedStage.bytes),
        cancellation: cancellation)
      finishProducer(identity.paperID)
      return identity.paperID
    } catch {
      let closureKnown = !producerStarted || (completion?.matches(identity) == true &&
        completion?.closureKnown == true)
      defer { finishProducer(identity.paperID) }
      let failure: ImportAbortFailure
      if (error as? FolderImportError) == .sourceChanged { failure = .sourceChanged }
      else if (error as? LocalLibraryError) == .cancelled { failure = .cancelled }
      else { failure = ActualCopyOwnership.shared.publication(identity) != nil ? .publicationRejected : .importFailed }
      try await abortClosed(identity, closureKnown: closureKnown, failure: failure)
      return identity.paperID
    }
  }

  public func delete(paperID: UUID) async throws {
    guard deletionInFlight.insert(paperID).inserted else { throw LocalLibraryError.deletionInProgress }
    defer { deletionInFlight.remove(paperID) }
    let database = database
    // Shared admission closes before durable visibility changes; callbacks never run under lock.
    let callbacks = readLeaseRegistry.revoke(paperID)
    cancellations[paperID]?.cancel()
    await MainActor.run { for callback in callbacks { callback() } }
    await enterTransition(paperID)
    let capture: ImportDeletionCapture
    do {
      guard let acknowledged = try await Task.detached(operation: {
        try database.beginDeletion(paperID)
      }).value else { leaveTransition(paperID); return }
      capture = acknowledged
      deletionSagas[paperID] = capture.saga
      if let record = capture.histories.first { records[paperID] = record }
      leaveTransition(paperID)
    } catch { leaveTransition(paperID); throw error }
    let saga = capture.saga
    if cancellations[paperID] != nil {
      await withCheckedContinuation { drains[paperID, default: []].append($0) }
    }
    do {
      readLeaseRegistry.retryClosures(paperID)
      try await readLeaseRegistry.drain(paperID)
      var histories = capture.histories
      await enterTransition(paperID)
      do {
        for index in histories.indices {
          let identity = try histories[index].journal.currentCapture().identity
          if let installed = records[paperID],
            try installed.journal.currentCapture().identity.jobID == identity.jobID {
            histories[index] = installed
          }
          histories[index] = try await closeRetainedPhysical(histories[index], identity: identity, paperID: paperID)
          try Self.preflight(histories[index].journal)
        }
        leaveTransition(paperID)
      } catch { leaveTransition(paperID); throw error }
      guard let agentPurge else { throw LocalLibraryError.agentPurgeUnavailable }
      let receipt = try await agentPurge.purgeLibraryPaper(paperID: paperID, deletionID: saga)
      guard receipt.paperID == paperID, receipt.deletionID == saga else {
        throw LocalLibraryError.invalidPurgeReceipt
      }
      await enterTransition(paperID)
      do {
        // No history is reconstructed for explicit NULL legacy jobs. Genuine
        // histories come from beginDeletion's acknowledged full capture.
        var finalRecords: [ImportRecoveryRecord] = []
        for history in histories {
          let identity = try history.journal.currentCapture().identity
          var record = history
          if let installed = records[paperID],
            try installed.journal.currentCapture().identity.jobID == identity.jobID { record = installed }
          record = try await closeRetainedPhysical(record, identity: identity, paperID: paperID)
          record = try await cleanupPermits(record, paperID: paperID, strictLateAbort: false)
          if let pending = try record.journal.snapshot().pendingRemoval {
            guard ActualCopyOwnership.shared.removal(pending.id)?.result != nil else {
              throw LocalLibraryError.cleanupFailed
            }
          } else {
            let journal = try record.journal.recording(.removeNamespace(operation: UUID().uuidString))
            try Self.preflight(journal)
            record = try await store(record, replacement: journal, paperID: paperID)
          }
          finalRecords.append(record)
        }
        let namespace = Self.namespace(database.root, paperID)
        let admitted = finalRecords
        let operationIDs = try admitted.map { record -> String in
          guard let operation = try record.journal.snapshot().pendingRemoval else {
            throw ImportRecoveryPersistenceError.invalidHistory
          }
          return operation.id
        }
        let receiptIDs = operationIDs.isEmpty ? [saga.uuidString] : operationIDs
        let retained = receiptIDs.compactMap { ActualCopyOwnership.shared.removal($0) }
        let removal: ActualNamespaceRemoval
        if let existing = retained.first {
          guard retained.allSatisfy({ $0.namespace == namespace && $0.result != nil }) else {
            throw LocalLibraryError.cleanupFailed
          }
          removal = existing
        } else { removal = ActualNamespaceRemoval(namespace: namespace) }
        for id in receiptIDs where ActualCopyOwnership.shared.removal(id) == nil {
          ActualCopyOwnership.shared.retainRemoval(removal, id: id)
        }
        if removal.result == nil {
          await Task.detached { removal.perform { try Self.removeNamespace(namespace) } }.value
        }
        guard let outcome = removal.result else { throw LocalLibraryError.cleanupFailed }
        if case .failure(let error) = outcome {
          for record in admitted {
            guard let pending = try record.journal.snapshot().pendingRemoval else {
              throw ImportRecoveryPersistenceError.invalidHistory
            }
            _ = try await store(record, replacement: record.journal.recording(
              .namespaceRemovalFinished(operation: pending, succeeded: false)), paperID: paperID)
          }
          for id in receiptIDs { ActualCopyOwnership.shared.acknowledgeRemoval(id) }
          throw error
        }
        try await Task.detached {
          try database.finalizeJournaledDeletion(paperID, saga: saga, expected: admitted)
        }.value
        for id in receiptIDs { ActualCopyOwnership.shared.acknowledgeRemoval(id) }
        for record in admitted {
          let identity = try record.journal.currentCapture().identity
          ActualCopyOwnership.shared.acknowledge(identity)
          LibraryURLImportWriter.acknowledge(identity)
        }
        records.removeValue(forKey: paperID)
        deletionSagas.removeValue(forKey: paperID)
        leaveTransition(paperID)
      } catch { leaveTransition(paperID); throw error }
    } catch {
      let reason: String
      switch error {
      case LocalLibraryError.agentPurgeUnavailable: reason = "agentPurgeUnavailable"
      case LocalLibraryError.invalidPurgeReceipt: reason = "agentClosureUnproved"
      default: reason = "deletionIncomplete"
      }
      await enterTransition(paperID)
      do {
        try await Task.detached { try database.deletionFailed(paperID, saga: saga, reason: reason) }.value
        leaveTransition(paperID)
      } catch { leaveTransition(paperID); throw error }
      throw error
    }
  }

  public func retryDeletion(paperID: UUID) async throws { try await delete(paperID: paperID) }

  private func enterTransition(_ paperID: UUID) async {
    if transitionOwners.insert(paperID).inserted { return }
    await withCheckedContinuation { transitionWaiters[paperID, default: []].append($0) }
  }

  private func leaveTransition(_ paperID: UUID) {
    if var waiting = transitionWaiters[paperID], !waiting.isEmpty {
      let next = waiting.removeFirst()
      transitionWaiters[paperID] = waiting
      next.resume() // Ownership transfers directly; newcomers cannot overtake.
    } else {
      transitionWaiters.removeValue(forKey: paperID)
      transitionOwners.remove(paperID)
    }
  }

  private func currentRecord(_ paperID: UUID) throws -> ImportRecoveryRecord {
    guard let record = records[paperID] else { throw ImportRecoveryPersistenceError.missingHistory }
    return record
  }

  /// Caller owns the FIFO gate across database await and installation.
  private func store(_ expected: ImportRecoveryRecord, replacement: ImportRecoveryJournal,
    paperID: UUID) async throws -> ImportRecoveryRecord {
    let database = database
    let saga = deletionSagas[paperID]
    let acknowledged = try await Task.detached {
      if let saga {
        return try database.appendDeletingImport(expected: expected, replacement: replacement, saga: saga)
      }
      return try database.appendJournaledImport(expected: expected, replacement: replacement)
    }.value
    records[paperID] = acknowledged
    return acknowledged
  }

  private func reserve(_ identity: ImportIdentity, title: String,
    facts: ImportRecoveryJournal.ConfirmedInput) async throws {
    await enterTransition(identity.paperID)
    defer { leaveTransition(identity.paperID) }
    let database = database
    let acknowledged = try await Task.detached {
      try database.reserveJournaledImport(identity, title: title, confirmedInput: facts)
    }.value
    records[identity.paperID] = acknowledged
  }

  private func writerOpened(_ identity: ImportIdentity) async throws {
    await enterTransition(identity.paperID)
    defer { leaveTransition(identity.paperID) }
    let record = try currentRecord(identity.paperID)
    let lineage = try record.journal.snapshot().current.lineage
    guard !(try record.journal.snapshot().revoked) else { throw LocalLibraryError.cancelled }
    let opened = try record.journal.recording(.writerClosure(lineage, permit: identity.writer.uuidString, .open))
    try Self.preflight(opened)
    _ = try await store(record, replacement: opened, paperID: identity.paperID)
  }

  private func closeRetainedPhysical(_ record: ImportRecoveryRecord, identity: ImportIdentity,
    paperID: UUID) async throws -> ImportRecoveryRecord {
    let snapshot = try record.journal.snapshot()
    guard let permit = snapshot.permits.first else { return record }
    if permit.kind == .publication, permit.phase == .renaming {
      guard let receipt = ActualCopyOwnership.shared.publication(identity) else {
        throw LocalLibraryError.producerClosureUnknown
      }
      // Under Delete, the acknowledged revoke fences publication. Only the actual
      // mover can settle its closure; retain prior execution state unchanged.
      return try await store(record, replacement: record.journal.recording(
        .renameFinished(permit.owner, permit: permit.id, succeeded: receipt.moved)), paperID: paperID)
    }
    let local = ActualCopyOwnership.shared.completion(identity)
    let url = LibraryURLImportWriter.retained(identity)
    let known = local?.matches(identity) == true && local?.closureKnown == true || url?.actualClosureKnown == true
    guard known else { throw LocalLibraryError.producerClosureUnknown }
    if permit.kind == .writer {
      if case .closed = permit.closure { return record }
      return try await store(record, replacement: record.journal.recording(
        .writerClosure(permit.owner, permit: permit.id, .closed(.unvalidated))), paperID: paperID)
    }
    guard ActualCopyOwnership.shared.publication(identity) != nil else {
      throw LocalLibraryError.producerClosureUnknown
    }
    return record
  }

  private func abortClosed(_ identity: ImportIdentity, closureKnown: Bool,
    failure: ImportAbortFailure) async throws {
    await enterTransition(identity.paperID)
    defer { leaveTransition(identity.paperID) }
    var record = try currentRecord(identity.paperID)
    var snapshot = try record.journal.snapshot()
    if snapshot.current.state == .succeeded { return } // Late cancel cannot undo success.
    if let permit = snapshot.permits.first, permit.kind == .publication, permit.phase == .renaming {
      guard let receipt = ActualCopyOwnership.shared.publication(identity) else {
        throw LocalLibraryError.producerClosureUnknown
      }
      if deletionSagas[identity.paperID] == nil {
        let database = database
        let admitted = record
        if let committed = try await Task.detached(operation: {
          try database.reconcileJournaledPublication(expected: admitted, closedStage: receipt.stage)
        }).value {
          records[identity.paperID] = committed
          ActualCopyOwnership.shared.acknowledge(identity)
          return
        }
      }
      record = try await store(record, replacement: record.journal.recording(
        .renameFinished(permit.owner, permit: permit.id, succeeded: receipt.moved)), paperID: identity.paperID)
      snapshot = try record.journal.snapshot()
    }
    var journal = record.journal
    if closureKnown, let permit = snapshot.permits.first, permit.kind == .writer {
      if case .closed = permit.closure {} else {
        journal = try journal.recording(.writerClosure(permit.owner, permit: permit.id, .closed(.unvalidated)))
      }
    }
    let database = database
    if snapshot.current.state == .running {
      journal = try journal.recording(.terminate(snapshot.current.lineage, .failed))
      let admitted = record
      let replacement = journal
      record = try await Task.detached {
        try database.recordJournaledImportFailure(expected: admitted, replacement: replacement,
          failure: failure, cleanupDebt: true)
      }.value
      records[identity.paperID] = record
    } else if try journal.encoded(maximumBytes: ProductJobRecovery.maximumImportRecoveryJournalBytes) != record.encoded {
      if snapshot.current.state == .failed(.paperDeleting), let saga = deletionSagas[identity.paperID] {
        let admitted = record
        let replacement = journal
        record = try await Task.detached {
          try database.recordJournaledDeletingImportAbort(expected: admitted,
            replacement: replacement, saga: saga, cleanupDebt: true)
        }.value
        records[identity.paperID] = record
      } else {
        record = try await store(record, replacement: journal, paperID: identity.paperID)
      }
    }
    guard closureKnown else { return } // Unknown roots are never repaired by cancellation.
    record = try await cleanupPermits(record, paperID: identity.paperID,
      strictLateAbort: snapshot.current.state == .failed(.paperDeleting))
    if deletionSagas[identity.paperID] == nil {
      let acknowledged = record
      try await Task.detached { try database.completeFailedImportCleanup(expected: acknowledged) }.value
    }
    ActualCopyOwnership.shared.acknowledge(identity)
  }

  private func cleanupPermits(_ initial: ImportRecoveryRecord, paperID: UUID,
    strictLateAbort: Bool) async throws -> ImportRecoveryRecord {
    var record = initial
    for original in try initial.journal.snapshot().permits {
      guard case .closed = original.closure else { throw LocalLibraryError.producerClosureUnknown }
      var permit = original
      if permit.cleanup != .requested && permit.cleanup != .cleaned {
        let requested = try record.journal.recording(.requestCleanup(permit.owner,
          permit: permit.id, operation: UUID().uuidString))
        try Self.preflight(requested)
        record = try await store(record, replacement: requested, paperID: paperID)
        guard let admitted = try record.journal.snapshot().permits.first(where: { $0.id == permit.id }) else {
          throw ImportRecoveryPersistenceError.invalidHistory
        }
        permit = admitted
      }
      if permit.cleanup == .cleaned {
        let released = try record.journal.recording(.release(permit.owner, permit: permit.id))
        if strictLateAbort, let saga = deletionSagas[paperID] {
          let database = database
          let admitted = record
          record = try await Task.detached {
            try database.recordJournaledDeletingImportAbort(expected: admitted,
              replacement: released, saga: saga, cleanupDebt: false)
          }.value
          records[paperID] = record
        } else {
          record = try await store(record, replacement: released, paperID: paperID)
        }
        continue
      }
      guard let operation = permit.cleanupOperation else { throw LocalLibraryError.cleanupFailed }
      let namespace = Self.namespace(database.root, paperID)
      let identity = try record.journal.currentCapture().identity
      let namespaceOwned = ActualCopyOwnership.shared.completion(identity)?.namespaceOwned == true ||
        LibraryURLImportWriter.retained(identity)?.namespaceOwned == true
      let receipt: ActualNamespaceRemoval
      if let retained = ActualCopyOwnership.shared.removal(operation.id) {
        guard retained.namespace == namespace, retained.result != nil else { throw LocalLibraryError.cleanupFailed }
        receipt = retained
      } else {
        // This owner just admitted the operation. Replayed requested operations
        // without independently rooted physical authority may not start effects.
        guard original.cleanup != .requested else { throw LocalLibraryError.cleanupFailed }
        receipt = ActualNamespaceRemoval(namespace: namespace)
        ActualCopyOwnership.shared.retainRemoval(receipt, id: operation.id)
        await Task.detached {
          receipt.perform {
            if namespaceOwned { try Self.removeNamespace(namespace) }
            else if try Self.checkedNamespace(namespace) != nil { throw LocalLibraryError.cleanupFailed }
          }
        }.value
      }
      guard let outcome = receipt.result else { throw LocalLibraryError.cleanupFailed }
      let succeeded: Bool
      switch outcome { case .success: succeeded = true; case .failure: succeeded = false }
      var completed = try record.journal.recording(.cleanupFinished(permit.owner,
        permit: permit.id, operation: operation, succeeded: succeeded))
      if succeeded { completed = try completed.recording(.release(permit.owner, permit: permit.id)) }
      if strictLateAbort, let saga = deletionSagas[paperID] {
        let database = database
        let admitted = record
        let replacement = completed
        record = try await Task.detached {
          try database.recordJournaledDeletingImportAbort(expected: admitted,
            replacement: replacement, saga: saga, cleanupDebt: !succeeded)
        }.value
        records[paperID] = record
      } else {
        record = try await store(record, replacement: completed, paperID: paperID)
      }
      ActualCopyOwnership.shared.acknowledgeRemoval(operation.id)
      try outcome.get()
    }
    return record
  }

  /// Preview only: never installed and never treated as physical closure proof.
  nonisolated static func preflight(_ journal: ImportRecoveryJournal) throws {
    let maximum = ProductJobRecovery.maximumImportRecoveryJournalBytes
    let capture = try journal.currentCapture()
    let snapshot = try journal.snapshot()
    var closed = journal
    if let permit = snapshot.permits.first {
      if permit.kind == .writer {
        if permit.closure == .open {
          closed = try closed.recording(.writerClosure(permit.owner, permit: permit.id,
            .closed(.validated(.init(id: capture.identity.attempt.uuidString)))))
        }
      } else if permit.phase == .renaming {
        closed = try closed.recording(.renameFinished(permit.owner, permit: permit.id, succeeded: true))
      }
    }
    var branches = [journal, closed]
    if snapshot.current.state == .running && !snapshot.revoked {
      branches.append(try closed.recording(.terminate(snapshot.current.lineage, .failed)))
      var success = closed
      if let writer = try success.snapshot().permits.first, writer.kind == .writer {
        success = try success.recording(.acquirePublication(writer.owner, writer: writer.id,
          permit: capture.identity.publication.uuidString))
        success = try success.recording(.rename(writer.owner, permit: capture.identity.publication.uuidString))
        success = try success.recording(.renameFinished(writer.owner,
          permit: capture.identity.publication.uuidString, succeeded: true))
      }
      if let publication = try success.snapshot().permits.first, publication.kind == .publication {
        success = try success.recording(.publish(publication.owner, permit: publication.id,
          .init(id: capture.identity.attempt.uuidString)))
        success = try success.recording(.release(publication.owner, permit: publication.id))
        branches.append(success)
      }
    }
    for branch in branches {
      var terminal = try branch.recording(.revoke)
      for permit in try terminal.snapshot().permits {
        guard case .closed = permit.closure else { continue }
        if permit.kind == .publication && permit.phase == .committed {
          terminal = try terminal.recording(.release(permit.owner, permit: permit.id))
          continue
        }
        var current = permit
        if current.cleanup != .requested && current.cleanup != .cleaned {
          terminal = try terminal.recording(.requestCleanup(current.owner,
            permit: current.id, operation: UUID().uuidString))
          guard let admitted = try terminal.snapshot().permits.first(where: { $0.id == current.id }) else {
            throw ImportRecoveryPersistenceError.invalidHistory
          }
          current = admitted
        }
        if let operation = current.cleanupOperation, current.cleanup == .requested {
          terminal = try terminal.recording(.cleanupFinished(current.owner,
            permit: current.id, operation: operation, succeeded: true))
        }
        terminal = try terminal.recording(.release(current.owner, permit: current.id))
      }
      if try terminal.snapshot().permits.isEmpty {
        if try terminal.snapshot().pendingRemoval == nil {
          terminal = try terminal.recording(.removeNamespace(operation: UUID().uuidString))
        }
        if let operation = try terminal.snapshot().pendingRemoval {
          terminal = try terminal.recording(.namespaceRemovalFinished(operation: operation, succeeded: true))
        }
      }
      let bytes = try terminal.encoded(maximumBytes: maximum)
      // Preserve bounded headroom for failed completions and one fresh repair
      // admission. No pruning or quota enlargement is permitted.
      guard bytes.count <= maximum - 8192 else { throw ImportRecoveryJournal.JournalError.byteLimitExceeded }
    }
  }

  private func finishProducer(_ paperID: UUID) {
    cancellations.removeValue(forKey: paperID)
    for continuation in drains.removeValue(forKey: paperID) ?? [] { continuation.resume() }
  }

  private nonisolated static func namespace(_ root: URL, _ paperID: UUID) -> URL {
    root.standardizedFileURL.resolvingSymlinksInPath()
      .appendingPathComponent("papers", isDirectory: true)
      .appendingPathComponent(paperID.uuidString, isDirectory: true)
  }

  private nonisolated static func removeNamespace(_ url: URL) throws {
    guard let present = try checkedNamespace(url) else { return }
    guard present.st_mode & S_IFMT == S_IFDIR, present.st_uid == Darwin.getuid(),
      present.st_mode & 0o7777 == 0o700 else { throw LocalLibraryError.cleanupFailed }
    try FileManager.default.removeItem(at: url)
    guard try checkedNamespace(url) == nil else { throw LocalLibraryError.cleanupFailed }
  }

  /// Only ENOENT proves this private pathname absent; this is not race/ABA isolation.
  private nonisolated static func checkedNamespace(_ url: URL) throws -> stat? {
    var path = url.path(percentEncoded: false)
    guard url.isFileURL, path.hasPrefix("/"), !path.utf8.contains(0) else {
      throw LocalLibraryError.cleanupFailed
    }
    // A trailing directory separator would make lstat follow the final symlink.
    while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
    let checkedURL = URL(fileURLWithPath: path, isDirectory: false)
    return try checkedURL.withUnsafeFileSystemRepresentation { representation in
      guard let representation else { throw LocalLibraryError.cleanupFailed }
      var info = stat()
      let result = Darwin.lstat(representation, &info)
      let failure = errno
      if result == 0 { return info }
      if result == -1 && failure == ENOENT { return nil }
      throw LocalLibraryError.cleanupFailed
    }
  }

  private nonisolated static func copyValidatedPDF(
    source: URL, stage: URL, identity: ImportIdentity, database: ProductDatabase,
    cancellation: ImportCancellation, effects: ActualCopyEffects, expectedSHA256: String?
  ) -> ActualCopyCompletion {
    // The only completion factory runs on the actual producer, after physical facts
    // and retained obligations are settled. Observers never supply authority.
    var actualOwner: ActualCopyOwner?
    func completed(_ outcome: ActualCopyCompletion.Outcome) -> ActualCopyCompletion {
      let observation: ActualCopyCompletionObservation
      switch outcome {
      case .neverStarted(let error):
        observation = .init(identity: identity, status: .neverStarted, error: error, sha256: nil, bytes: nil)
      case .closedUnvalidated(let error):
        observation = .init(identity: identity, status: .closedUnvalidated, error: error, sha256: nil, bytes: nil)
      case .closedValidated(let stage):
        observation = .init(identity: identity, status: .closedValidated, error: nil,
          sha256: stage.sha256, bytes: stage.bytes)
      case .unknown:
        observation = .init(identity: identity, status: .unknown,
          error: LocalLibraryError.producerClosureUnknown, sha256: nil, bytes: nil)
      }
      effects.completed(observation)
      let completion = ActualCopyCompletion(identity: identity, outcome: outcome,
        namespaceOwned: actualOwner?.namespaceOwned ?? false)
      ActualCopyOwnership.shared.retainCompletion(completion)
      return completion
    }
    let authority: ProviderRequest
    let lease: RequestResourceLease
    do {
      try cancellation.check()
      guard source.isFileURL, !source.path(percentEncoded: false).utf8.contains(0) else {
        throw LocalLibraryError.invalidPDF
      }
      authority = try ProviderRequest()
      let pool = try RequestResourcePool(authority: authority, kind: "import")
      guard let acquired = pool.acquire() else { throw LocalLibraryError.importCapacity }
      lease = acquired
    } catch { return completed(.neverStarted(error)) }
    let owner = ActualCopyOwner(identity: identity, source: source, stage: stage, lease: lease,
      effects: effects)
    actualOwner = owner
    ActualCopyOwnership.shared.retain(owner)
    owner.scoped = effects.startScope(source)
    let fm = FileManager.default
    var hash = SHA256()
    var copied: Int64 = 0
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
      let namespace = stage.deletingLastPathComponent()
      try fm.createDirectory(at: namespace.deletingLastPathComponent(), withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      guard namespace.withUnsafeFileSystemRepresentation({ path in
        guard let path else { return false }
        return Darwin.mkdir(path, mode_t(0o700)) == 0
      }) else { throw LocalLibraryError.cleanupFailed }
      owner.namespaceOwned = true
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
      return completed(.unknown(owner))
    }
    ActualCopyOwnership.shared.releaseKnown(owner)
    if let workError { return completed(.closedUnvalidated(workError)) }
    do {
      try cancellation.check()
      let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
      if let expectedSHA256, digest != expectedSHA256 { throw FolderImportError.sourceChanged }
      guard copied > 0 else { throw LocalLibraryError.invalidPDF }
      return completed(.closedValidated(.init(file: stage, sha256: digest, bytes: copied)))
    } catch { return completed(.closedUnvalidated(error)) }
  }
}
