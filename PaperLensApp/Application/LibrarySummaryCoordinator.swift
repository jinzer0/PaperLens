import Combine
import Darwin
import Foundation
import GRDB
#if SWIFT_PACKAGE
import ProviderRequest
#endif

/// The ChatGPT adapter uses the app-owned isolated execution scope. A missing
/// connection remains unavailable and never falls back to a different provider.
@MainActor public final class NativeCodexSummaryProvider: LibrarySummaryProviding {
  private let connection: NativeCodexConnection?
  private let authority: ProviderRequest

  public init(connection: NativeCodexConnection?, authority: ProviderRequest) {
    self.connection = connection; self.authority = authority
  }

  public func execute(_ request: AuthorizedProviderRequest, identity: LibrarySummaryIdentity) async throws
    -> ValidatedProviderResult {
    guard let connection else { throw LibrarySummaryError.providerUnavailable }
    return try await connection.executeLibrarySummary(request, identity: identity, authority: authority)
  }
}

/// Select from the durable configuration at dispatch, and fence a result if any
/// selector field changed while the selected adapter was running.
@MainActor public final class SelectedLibrarySummaryProvider: LibrarySummaryProviding {
  private let database: ProductDatabase
  private let apiKey: any LibrarySummaryProviding
  private let chatGPT: any LibrarySummaryProviding

  public init(database: ProductDatabase, apiKey: any LibrarySummaryProviding,
    chatGPT: any LibrarySummaryProviding) {
    self.database = database; self.apiKey = apiKey; self.chatGPT = chatGPT
  }

  public func execute(_ request: AuthorizedProviderRequest, identity: LibrarySummaryIdentity) async throws
    -> ValidatedProviderResult {
    let selection = try database.providerConfiguration()
    guard selection.generation == identity.configurationGeneration,
      selection.slotID != nil, let model = selection.model, !model.isEmpty else {
      throw LibrarySummaryError.staleIdentity
    }
    let selected: any LibrarySummaryProviding
    switch selection.kind {
    case .openAIAPIKey: selected = apiKey
    case .codexChatGPT: selected = chatGPT
    case nil: throw LibrarySummaryError.providerUnavailable
    }
    let result = try await selected.execute(request, identity: identity)
    try Task.checkCancellation()
    guard try database.providerConfiguration() == selection else {
      throw LibrarySummaryError.staleIdentity
    }
    return result
  }
}

/// The selected Main-owned HTTP adapter. A return, including a thrown return, occurs
/// after the transport has drained its task, session and delegate consumer.
@MainActor public final class NativeAPIKeySummaryProvider: LibrarySummaryProviding {
  private let connection: NativeAPIKeyConnection
  private let transport: any NativeGenerationTransport
  private let authority: ProviderRequest

  public init(connection: NativeAPIKeyConnection, authority: ProviderRequest,
    transport: any NativeGenerationTransport = URLSessionOpenAIGenerationTransport()) {
    self.connection = connection; self.authority = authority; self.transport = transport
  }

  public func execute(_ request: AuthorizedProviderRequest, identity: LibrarySummaryIdentity) async throws
    -> ValidatedProviderResult {
    let lease = try connection.acquireLease()
    var retained = true
    do {
      guard lease.selection.configGeneration == identity.configurationGeneration else {
        throw LibrarySummaryError.staleIdentity
      }
      let result = try await transport.execute(key: connection.key(for: lease),
        configuration: connection.configuration, request: request, authority: authority)
      try Task.checkCancellation()
      guard try connection.mayPublish(lease) else { throw LibrarySummaryError.staleIdentity }
      retained = false
      try connection.releaseAfterTermination(lease)
      return result
    } catch {
      // execute has actually returned; cancellation acceptance alone never reaches here.
      if retained { try connection.releaseAfterTermination(lease) }
      throw error
    }
  }
}

/// One explicit request at a time under the retained application owner. Opening the
/// Library, restoring a result and refreshing facts never starts generation.
@MainActor public final class LibrarySummaryCoordinator: ObservableObject {
  @Published public private(set) var activePaperID: UUID?
  private let database: ProductDatabase
  private let epoch: UUID
  private let leases: any ReaderLeaseProvider
  private let authority: ProviderRequest
  private let provider: any LibrarySummaryProviding
  private var active: Task<LibrarySummaryRecord, any Error>?
  // Unknown physical staging closure keeps its exact owners alive and blocks replacement.
  private var cleanupDebt: [(SummaryStage, any ReaderReadLease)] = []
  private var producerCleanupDebt: [any ReaderReadLease] = []

  public init(database: ProductDatabase, epoch: UUID, leases: any ReaderLeaseProvider,
    authority: ProviderRequest, provider: any LibrarySummaryProviding) {
    self.database = database; self.epoch = epoch; self.leases = leases
    self.authority = authority; self.provider = provider
  }

  public func cancel() { active?.cancel() }

  @discardableResult public func generate(paperID: UUID, generation: UUID,
    outputLanguage: String) async throws -> LibrarySummaryRecord {
    guard active == nil, cleanupDebt.isEmpty, producerCleanupDebt.isEmpty else {
      throw LibrarySummaryError.requestInProgress
    }
    activePaperID = paperID
    let task = Task { try await self.execute(paperID: paperID, generation: generation,
      outputLanguage: outputLanguage) }
    active = task
    defer { active = nil; activePaperID = nil }
    return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
  }

  private func execute(paperID: UUID, generation: UUID, outputLanguage: String) async throws
    -> LibrarySummaryRecord {
    try Task.checkCancellation()
    let ordinal = try database.summaryGenerationOrdinal(paperID: paperID, generation: generation)
    let input = try capture(paperID: paperID, generation: generation)
    let identity = LibrarySummaryIdentity(paperID: paperID, generation: generation,
      requestPaperGeneration: ordinal, pdfSHA256: input.hash, revision: input.revision,
      configurationGeneration: input.configuration, job: UUID(), attempt: UUID(),
      fence: UUID(), correlation: UUID(), input: UUID(), epoch: epoch)
    let keys = try Set(input.sentences.map {
      try PDFSentenceIdentity(paperID: paperID, pdfSHA256: input.hash,
        extractionRevision: input.revision.uuidString.lowercased(),
        pageIndex: $0.anchor.pageIndex, sentenceID: $0.anchor.sentenceID)
    })
    guard let geometry = try database.originalExtractionGeometryOwners(paperID: paperID,
      generation: generation, pdfSHA256: input.hash, revision: input.revision, sentences: keys)
    else { throw LibrarySummaryError.geometryUnavailable }
    let sources = RequestSources.librarySummary(outputLanguage: outputLanguage)
    let context = try TrustedRequestContext(authority: authority, sources: sources,
      identity: .init(paperID: paperID.uuidString.lowercased(), paperGeneration: ordinal,
        pdfSHA256: input.hash, extractionRevision: input.revision.uuidString.lowercased()),
      sentences: input.sentences, rankedCandidates: input.ranked)
    let request = try authority.buildRequest(sources: sources, context: context,
      requestID: identity.correlation.uuidString.lowercased())
    let paper = try database.readerSnapshot(paperID: paperID)
    guard paper.generation == generation else { throw LibrarySummaryError.staleIdentity }
    let lease = try leases.acquireReadLease(for: paper, onRevoked: { [weak self] in self?.cancel() })
    var stage: SummaryStage?
    var reserved = false
    var awaitingProducer = false
    let service = LibrarySummaryService(database: database, provider: provider, geometry: geometry)
    do {
      try lease.validate()
      let owner = JobRecoveryPolicy.Authority(input: .librarySummary(version: identity.input.uuidString),
        config: .generation(String(identity.configurationGeneration)),
        paper: .init(id: paperID.uuidString, generation: generation.uuidString),
        epoch: epoch.uuidString, prerequisitesAvailable: true)
      var policy = try JobRecoveryPolicy.create(job: identity.job.uuidString, role: .librarySummary,
        authority: owner, reservation: .init(attempt: identity.attempt.uuidString,
          fence: identity.fence.uuidString, correlation: identity.correlation.uuidString))
      let line = policy.current.lineage
      let writer = UUID().uuidString, publication = UUID().uuidString, resultID = UUID()
      func apply(_ event: JobRecoveryPolicy.Event) throws {
        let decision = JobRecoveryPolicy.apply(event, to: policy)
        if let rejection = decision.rejection { throw rejection }
        policy = decision.snapshot
      }
      try apply(.claim(line)); try apply(.acquireWriter(line, permit: writer)); try apply(.dispatch(line))
      // Reserve succeeds before provider execution; failure cleanup below targets exact identity only.
      reserved = true
      awaitingProducer = true
      let result = try await service.dispatch(request, identity: identity, snapshot: policy)
      awaitingProducer = false
      try Task.checkCancellation()
      try lease.validate()
      // Actual closed file + actual rename satisfy the publication policy; no closure
      // receipt is derived from cancellation or from a validated HTTP body alone.
      let staged = SummaryStage(root: database.root, paper: paper, job: identity.job)
      stage = staged
      try staged.prepare()
      try staged.write(ProviderRequest.canonicalBytes(result.value))
      let validated = JobRecoveryPolicy.Result(id: resultID.uuidString)
      try apply(.writerClosure(line, permit: writer, .closed(.validated(validated))))
      try apply(.acquirePublication(line, writer: writer, permit: publication))
      try apply(.rename(line, permit: publication))
      try staged.rename()
      try apply(.renameFinished(line, permit: publication, succeeded: true))
      try Task.checkCancellation(); try lease.validate()
      let record = try service.publish(result, request: request, identity: identity,
        snapshot: policy, permit: publication, resultID: resultID)
      try staged.remove()
      lease.close()
      return record
    } catch {
      let cause = error
      if reserved { try? database.failLibrarySummary(identity) }
      // An isolated producer may report unknown physical retirement. Keep the
      // paper lease held so deletion cannot remove a producer's remaining input.
      if awaitingProducer, cause as? LibrarySummaryError == .cleanupUnavailable {
        producerCleanupDebt.append(lease)
        throw cause
      }
      if let stage {
        do { try stage.remove() } catch {
          cleanupDebt.append((stage, lease))
          throw LibrarySummaryError.cleanupUnavailable
        }
      }
      lease.close()
      throw cause
    }
  }

  private struct Input {
    let revision: UUID
    let hash: String
    let configuration: Int64
    let sentences: [RequestSentence]
    let ranked: [Int]
  }

  private func capture(paperID: UUID, generation: UUID) throws -> Input {
    try database.adapterRead { db in
      guard let row = try Row.fetchOne(db, sql: """
        SELECT r.id AS revision, p.pdfSHA256 AS hash, c.generation AS configuration
        FROM paper p JOIN extractionVisible v ON v.paperID = p.id
        JOIN extractionRevision r ON r.id = v.revision CROSS JOIN providerConfig c
        WHERE p.id = ? AND p.generation = ? AND p.status = 'ready' AND p.deletionID IS NULL
          AND r.paperID = p.id AND r.generation = p.generation AND r.pdfSHA256 = p.pdfSHA256
          AND r.pdfReference = p.pdfReference AND c.singleton = 1
          AND c.kind IN ('openAIAPIKey', 'codexChatGPT')
          AND c.slotID IS NOT NULL AND c.model IS NOT NULL
        """, arguments: [paperID.uuidString, generation.uuidString]),
        let revision = UUID(uuidString: row["revision"]) else { throw LibrarySummaryError.providerUnavailable }
      // Bound materialization using original owner storage, before reading any anchor BLOB.
      guard let quota = try Row.fetchOne(db, sql: """
        SELECT COUNT(*) AS n, COALESCE(SUM(length(originalAnchor)), 0) AS bytes
        FROM extractionGeometryOwner WHERE revision = ?
        """, arguments: [revision.uuidString]),
        (quota["n"] as Int) > 0, (quota["n"] as Int) <= authority.limit("sentences"),
        (quota["bytes"] as Int) <= SummaryOwnerArchive.maximumBytes else {
        throw LibrarySummaryError.geometryUnavailable
      }
      let rows = try Row.fetchAll(db, sql: """
        SELECT page, sentenceID, text FROM extractionSentence WHERE revision = ? ORDER BY sentenceID
        """, arguments: [revision.uuidString])
      guard rows.count == (quota["n"] as Int) else { throw LibrarySummaryError.invalidGrounding }
      let sentences: [RequestSentence] = try rows.enumerated().map { index, row in
        guard (row["sentenceID"] as Int) == index else { throw LibrarySummaryError.invalidGrounding }
        return .init(anchor: .init(pageIndex: row["page"], sentenceID: index), quote: row["text"])
      }
      let ranked = try Int.fetchAll(db, sql: """
        SELECT sentenceID FROM extractionFTS JOIN extractionSentence s ON s.id = extractionFTS.rowid
        WHERE extractionFTS MATCH ? AND revision = ? ORDER BY rank, sentenceID
        """, arguments: [authority.contract["policies"]["summaryQuery"].string, revision.uuidString])
      return Input(revision: revision, hash: row["hash"], configuration: row["configuration"],
        sentences: sentences, ranked: ranked)
    }
  }
}

/// Only exact files created by this invocation are removed. Directory descriptors
/// reject symlink substitution; unknown closure remains owned by the coordinator.
@MainActor final class SummaryStage {
  private let name: String
  private let parentPath: String
  private var parent: Int32 = -1
  private var directory: Int32 = -1
  private var parentCloseAttempted = false
  private var directoryCloseAttempted = false
  private var closeUnknown = false
  private var handle: FileHandle?
  private var fileCloseAttempted = false
  private var file = "result.tmp"
  private var fileCreated = false
  private var directoryCreated = false
  private var namespaceRemoved = false
  private var directoryIdentity: (dev_t, ino_t)?
  private var fileIdentity: (dev_t, ino_t)?
  private var removed = false

  init(root: URL, paper: ReaderPaperSnapshot, job: UUID) {
    name = ".summary-" + job.uuidString
    parentPath = root.appendingPathComponent(paper.pdfReference).deletingLastPathComponent().path
  }

  func prepare() throws {
    parent = Darwin.open(parentPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard parent >= 0 else { throw LibrarySummaryError.cleanupUnavailable }
    guard mkdirat(parent, name, 0o700) == 0 else { throw LibrarySummaryError.cleanupUnavailable }
    directoryCreated = true
    var created = stat()
    guard fstatat(parent, name, &created, AT_SYMLINK_NOFOLLOW) == 0,
      created.st_mode & S_IFMT == S_IFDIR else { throw LibrarySummaryError.cleanupUnavailable }
    directoryIdentity = (created.st_dev, created.st_ino)
    directory = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard directory >= 0 else { throw LibrarySummaryError.cleanupUnavailable }
    var opened = stat()
    guard fstat(directory, &opened) == 0, opened.st_dev == created.st_dev,
      opened.st_ino == created.st_ino else { throw LibrarySummaryError.cleanupUnavailable }
  }

  func write(_ bytes: Data) throws {
    guard handle == nil, file == "result.tmp", !removed else { throw LibrarySummaryError.cleanupUnavailable }
    let fd = openat(directory, file, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw LibrarySummaryError.cleanupUnavailable }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
    fileCreated = true
    self.handle = handle
    var created = stat()
    guard fstat(fd, &created) == 0 else { throw LibrarySummaryError.cleanupUnavailable }
    fileIdentity = (created.st_dev, created.st_ino)
    try handle.write(contentsOf: bytes)
    try handle.synchronize()
    try closeFile()
  }

  private func closeFile() throws {
    guard let handle else { return }
    guard !fileCloseAttempted else { throw LibrarySummaryError.cleanupUnavailable }
    fileCloseAttempted = true
    do { try handle.close(); self.handle = nil }
    catch { closeUnknown = true; throw error }
  }

  private func requireFileIdentity() throws {
    var current = stat()
    guard let expected = fileIdentity,
      fstatat(directory, file, &current, AT_SYMLINK_NOFOLLOW) == 0,
      current.st_mode & S_IFMT == S_IFREG, current.st_nlink == 1,
      current.st_dev == expected.0, current.st_ino == expected.1 else {
      throw LibrarySummaryError.cleanupUnavailable
    }
  }

  func rename() throws {
    guard handle == nil, !closeUnknown, file == "result.tmp", !removed else {
      throw LibrarySummaryError.cleanupUnavailable
    }
    try requireFileIdentity()
    // The private invocation directory was created exclusively and has no other writer.
    guard renameatx_np(directory, file, directory, "result.json", UInt32(RENAME_EXCL)) == 0 else {
      throw LibrarySummaryError.cleanupUnavailable
    }
    file = "result.json"
  }

  func remove() throws {
    guard !removed else { return }
    guard !closeUnknown else { throw LibrarySummaryError.cleanupUnavailable }
    try closeFile()
    if fileCreated {
      try requireFileIdentity()
      guard unlinkat(directory, file, 0) == 0 else { throw LibrarySummaryError.cleanupUnavailable }
      fileCreated = false
    }
    if directoryCreated, !namespaceRemoved {
      var current = stat()
      guard let expected = directoryIdentity,
        fstatat(parent, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
        current.st_dev == expected.0, current.st_ino == expected.1,
        unlinkat(parent, name, AT_REMOVEDIR) == 0 else { throw LibrarySummaryError.cleanupUnavailable }
      namespaceRemoved = true
    }
    // Attempt both closes independently, exactly once. An EINTR/error never turns
    // into a retry against a potentially reused descriptor number.
    if directory >= 0, !directoryCloseAttempted {
      directoryCloseAttempted = true
      if Darwin.close(directory) == 0 { directory = -1 } else { closeUnknown = true }
    }
    if parent >= 0, !parentCloseAttempted {
      parentCloseAttempted = true
      if Darwin.close(parent) == 0 { parent = -1 } else { closeUnknown = true }
    }
    guard !closeUnknown else { throw LibrarySummaryError.cleanupUnavailable }
    removed = true
  }
}
