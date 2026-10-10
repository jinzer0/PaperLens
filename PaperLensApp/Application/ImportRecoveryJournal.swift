import Foundation

/// Serialization of independently admitted owner attestations, never execution or closure proof.
struct ImportRecoveryJournal: Sendable {
  struct ConfirmedInput: Codable, Equatable, Sendable {
    let expectedSHA256: String?
    let destinationFolderID: UUID?

    init(expectedSHA256: String?, destinationFolderID: UUID?) {
      self.expectedSHA256 = expectedSHA256
      self.destinationFolderID = destinationFolderID
    }

    private enum CodingKeys: String, CodingKey { case expectedSHA256, destinationFolderID }

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      guard container.contains(.expectedSHA256), container.contains(.destinationFolderID) else {
        throw JournalError.invalidData
      }
      expectedSHA256 = try container.decodeIfPresent(String.self, forKey: .expectedSHA256)
      destinationFolderID = try container.decodeIfPresent(UUID.self, forKey: .destinationFolderID)
    }

    func encode(to encoder: Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(expectedSHA256, forKey: .expectedSHA256)
      try container.encode(destinationFolderID, forKey: .destinationFolderID)
    }
  }

  enum JournalError: Error, Equatable {
    case invalidData, invalidMaximumBytes, byteLimitExceeded, retryRequiresCapture
  }

  private struct Capture: Codable, Sendable {
    let paperID: String
    let generation: String
    let jobID: String
    let attempt: String
    let fence: String
    let correlation: String
    let input: String
    let epoch: String
    let writer: String
    let publication: String
    let confirmedInput: ConfirmedInput

    init(_ identity: ImportIdentity, _ inputFacts: ConfirmedInput) {
      paperID = identity.paperID.uuidString
      generation = identity.generation.uuidString
      jobID = identity.jobID.uuidString
      attempt = identity.attempt.uuidString
      fence = identity.fence.uuidString
      correlation = identity.correlation.uuidString
      input = identity.input.uuidString
      epoch = identity.epoch.uuidString
      writer = identity.writer.uuidString
      publication = identity.publication.uuidString
      confirmedInput = inputFacts
    }

    var ids: [String] {
      [paperID, generation, jobID, attempt, fence, correlation, input, epoch, writer, publication]
    }
    var freshIDs: [String] { [attempt, fence, correlation, input, writer, publication] }
    var authority: JobRecoveryPolicy.Authority {
      JobRecoveryPolicy.Authority(input: .source(version: input), config: .inapplicable,
        paper: .init(id: paperID, generation: generation), epoch: epoch,
        prerequisitesAvailable: true)
    }
    var reservation: JobRecoveryPolicy.Reservation {
      .init(attempt: attempt, fence: fence, correlation: correlation)
    }
    var lineage: JobRecoveryPolicy.Lineage {
      .init(job: jobID, reservation: reservation, captured: authority)
    }
    func validate() throws {
      guard ids.allSatisfy(ImportRecoveryJournal.canonicalUUID), Set(ids).count == ids.count else {
        throw JournalError.invalidData
      }
      if let hash = confirmedInput.expectedSHA256 {
        guard hash.utf8.count == 64,
          hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
          throw JournalError.invalidData
        }
      }
    }
  }

  private struct PaperDTO: Codable, Sendable {
    let id: String
    let generation: String
    init(_ value: JobRecoveryPolicy.Paper) { id = value.id; generation = value.generation }
    var value: JobRecoveryPolicy.Paper { .init(id: id, generation: generation) }
  }
  private struct AuthorityDTO: Codable, Sendable {
    let sourceVersion: String
    let paper: PaperDTO
    let epoch: String
    let prerequisitesAvailable: Bool
    init(_ value: JobRecoveryPolicy.Authority) throws {
      guard case .source(let source) = value.input, value.config == .inapplicable else {
        throw JournalError.invalidData
      }
      sourceVersion = source
      paper = PaperDTO(value.paper)
      epoch = value.epoch
      prerequisitesAvailable = value.prerequisitesAvailable
    }
    var value: JobRecoveryPolicy.Authority {
      .init(input: .source(version: sourceVersion), config: .inapplicable, paper: paper.value,
        epoch: epoch, prerequisitesAvailable: prerequisitesAvailable)
    }
  }
  private struct LineageDTO: Codable, Sendable {
    let job: String
    let attempt: String
    let fence: String
    let correlation: String
    let captured: AuthorityDTO
    init(_ value: JobRecoveryPolicy.Lineage) throws {
      job = value.job
      attempt = value.reservation.attempt
      fence = value.reservation.fence
      correlation = value.reservation.correlation
      captured = try AuthorityDTO(value.captured)
    }
    var value: JobRecoveryPolicy.Lineage {
      .init(job: job, reservation: .init(attempt: attempt, fence: fence, correlation: correlation),
        captured: captured.value)
    }
  }
  private struct OperationDTO: Codable, Sendable {
    let id: String
    let paper: PaperDTO
    init(_ value: JobRecoveryPolicy.Operation) { id = value.id; paper = PaperDTO(value.paper) }
    var value: JobRecoveryPolicy.Operation { .init(id: id, paper: paper.value) }
  }
  private enum FailureDTO: String, Codable, Sendable {
    case failed, cancelled, timeout, interrupted, paperDeleting
    init(_ value: JobRecoveryPolicy.Failure) {
      switch value {
      case .failed: self = .failed
      case .cancelled: self = .cancelled
      case .timeout: self = .timeout
      case .interrupted: self = .interrupted
      case .paperDeleting: self = .paperDeleting
      }
    }
    var value: JobRecoveryPolicy.Failure {
      switch self {
      case .failed: return .failed
      case .cancelled: return .cancelled
      case .timeout: return .timeout
      case .interrupted: return .interrupted
      case .paperDeleting: return .paperDeleting
      }
    }
  }
  private enum ClosureDTO: Codable, Sendable {
    case unknown, open, closedUnvalidated, closedValidated(result: String)
    init(_ value: JobRecoveryPolicy.Closure) {
      switch value {
      case .unknown: self = .unknown
      case .open: self = .open
      case .closed(.unvalidated): self = .closedUnvalidated
      case .closed(.validated(let result)): self = .closedValidated(result: result.id)
      }
    }
    var value: JobRecoveryPolicy.Closure {
      switch self {
      case .unknown: return .unknown
      case .open: return .open
      case .closedUnvalidated: return .closed(.unvalidated)
      case .closedValidated(let result): return .closed(.validated(.init(id: result)))
      }
    }
  }
  private enum EventDTO: Codable, Sendable {
    case authorityChanged(AuthorityDTO)
    case claim(LineageDTO)
    case startup(currentEpoch: String)
    case dispatch(LineageDTO)
    case sendMayHaveHappened(LineageDTO)
    case terminate(LineageDTO, FailureDTO)
    case retryCapture(Capture)
    case acquireWriter(LineageDTO, permit: String)
    case writerClosure(LineageDTO, permit: String, ClosureDTO)
    case acquirePublication(LineageDTO, writer: String, permit: String)
    case rename(LineageDTO, permit: String)
    case renameFinished(LineageDTO, permit: String, succeeded: Bool)
    case publish(LineageDTO, permit: String, result: String)
    case revoke
    case requestCleanup(LineageDTO, permit: String, operation: String)
    case cleanupFinished(LineageDTO, permit: String, operation: OperationDTO, succeeded: Bool)
    case release(LineageDTO, permit: String)
    case removeNamespace(operation: String)
    case namespaceRemovalFinished(operation: OperationDTO, succeeded: Bool)

    init(_ event: JobRecoveryPolicy.Event) throws {
      switch event {
      case .authorityChanged(let a): self = .authorityChanged(try AuthorityDTO(a))
      case .claim(let l): self = .claim(try LineageDTO(l))
      case .startup(let e): self = .startup(currentEpoch: e)
      case .dispatch(let l): self = .dispatch(try LineageDTO(l))
      case .sendMayHaveHappened(let l): self = .sendMayHaveHappened(try LineageDTO(l))
      case .terminate(let l, let f): self = .terminate(try LineageDTO(l), FailureDTO(f))
      case .retry: throw JournalError.retryRequiresCapture
      case .acquireWriter(let l, let p): self = .acquireWriter(try LineageDTO(l), permit: p)
      case .writerClosure(let l, let p, let c):
        self = .writerClosure(try LineageDTO(l), permit: p, ClosureDTO(c))
      case .acquirePublication(let l, let w, let p):
        self = .acquirePublication(try LineageDTO(l), writer: w, permit: p)
      case .rename(let l, let p): self = .rename(try LineageDTO(l), permit: p)
      case .renameFinished(let l, let p, let s):
        self = .renameFinished(try LineageDTO(l), permit: p, succeeded: s)
      case .publish(let l, let p, let r): self = .publish(try LineageDTO(l), permit: p, result: r.id)
      case .revoke: self = .revoke
      case .requestCleanup(let l, let p, let o):
        self = .requestCleanup(try LineageDTO(l), permit: p, operation: o)
      case .cleanupFinished(let l, let p, let o, let s):
        self = .cleanupFinished(try LineageDTO(l), permit: p, operation: OperationDTO(o), succeeded: s)
      case .release(let l, let p): self = .release(try LineageDTO(l), permit: p)
      case .removeNamespace(let o): self = .removeNamespace(operation: o)
      case .namespaceRemovalFinished(let o, let s):
        self = .namespaceRemovalFinished(operation: OperationDTO(o), succeeded: s)
      }
    }
    var value: JobRecoveryPolicy.Event {
      switch self {
      case .authorityChanged(let a): return .authorityChanged(a.value)
      case .claim(let l): return .claim(l.value)
      case .startup(let e): return .startup(currentEpoch: e)
      case .dispatch(let l): return .dispatch(l.value)
      case .sendMayHaveHappened(let l): return .sendMayHaveHappened(l.value)
      case .terminate(let l, let f): return .terminate(l.value, f.value)
      case .retryCapture(let c): return .retry(c.reservation, c.authority)
      case .acquireWriter(let l, let p): return .acquireWriter(l.value, permit: p)
      case .writerClosure(let l, let p, let c): return .writerClosure(l.value, permit: p, c.value)
      case .acquirePublication(let l, let w, let p):
        return .acquirePublication(l.value, writer: w, permit: p)
      case .rename(let l, let p): return .rename(l.value, permit: p)
      case .renameFinished(let l, let p, let s): return .renameFinished(l.value, permit: p, succeeded: s)
      case .publish(let l, let p, let r): return .publish(l.value, permit: p, .init(id: r))
      case .revoke: return .revoke
      case .requestCleanup(let l, let p, let o): return .requestCleanup(l.value, permit: p, operation: o)
      case .cleanupFinished(let l, let p, let o, let s):
        return .cleanupFinished(l.value, permit: p, operation: o.value, succeeded: s)
      case .release(let l, let p): return .release(l.value, permit: p)
      case .removeNamespace(let o): return .removeNamespace(operation: o)
      case .namespaceRemovalFinished(let o, let s):
        return .namespaceRemovalFinished(operation: o.value, succeeded: s)
      }
    }
  }
  private struct Document: Codable, Sendable {
    let version: Int
    let initial: Capture
    let events: [EventDTO]
  }
  private let document: Document

  init(identity: ImportIdentity, confirmedInput: ConfirmedInput) throws {
    document = Document(version: 1, initial: Capture(identity, confirmedInput), events: [])
    _ = try snapshot()
  }
  private init(document: Document) { self.document = document }

  private static func canonicalUUID(_ text: String) -> Bool {
    UUID(uuidString: text)?.uuidString == text
  }

  func snapshot() throws -> JobRecoveryPolicy.Snapshot {
    guard document.version == 1 else { throw JournalError.invalidData }
    try document.initial.validate()
    let first = document.initial
    var captures = [first]
    var state = try JobRecoveryPolicy.create(job: first.jobID, role: .import,
      authority: first.authority, reservation: first.reservation)
    for dto in document.events {
      let event = dto.value
      let decision = JobRecoveryPolicy.apply(event, to: state)
      if let rejection = decision.rejection { throw rejection }
      if case .retryCapture(let capture) = dto {
        try capture.validate()
        let reserved = Set(captures.flatMap(\.ids) + state.usedPermitIDs + state.usedOperationIDs)
        guard capture.paperID == first.paperID, capture.generation == first.generation,
          capture.jobID == first.jobID, capture.freshIDs.allSatisfy({ !reserved.contains($0) }) else {
          throw JournalError.invalidData
        }
        captures.append(capture)
      }
      try Self.validate(event, captures: captures)
      state = decision.snapshot
    }
    return state
  }

  private static func validate(_ event: JobRecoveryPolicy.Event, captures: [Capture]) throws {
    func lineage(_ l: JobRecoveryPolicy.Lineage) throws -> Capture {
      guard let c = captures.first(where: { $0.lineage == l }) else { throw JournalError.invalidData }
      return c
    }
    func permit(_ l: JobRecoveryPolicy.Lineage, _ p: String) throws {
      let c = try lineage(l)
      guard p == c.writer || p == c.publication else { throw JournalError.invalidData }
    }
    func operation(_ id: String) throws {
      guard canonicalUUID(id), !captures.flatMap(\.ids).contains(id) else { throw JournalError.invalidData }
    }
    func target(_ o: JobRecoveryPolicy.Operation) throws {
      try operation(o.id)
      guard captures.contains(where: { $0.authority.paper == o.paper }) else { throw JournalError.invalidData }
    }
    switch event {
    case .authorityChanged(let a):
      guard canonicalUUID(a.epoch), captures.contains(where: {
        $0.authority.input == a.input && $0.authority.config == a.config && $0.authority.paper == a.paper
      }) else { throw JournalError.invalidData }
    case .startup(let e): guard canonicalUUID(e) else { throw JournalError.invalidData }
    case .claim(let l), .dispatch(let l), .sendMayHaveHappened(let l), .terminate(let l, _):
      _ = try lineage(l)
    case .acquireWriter(let l, let p):
      guard try lineage(l).writer == p else { throw JournalError.invalidData }
    case .acquirePublication(let l, let w, let p):
      let c = try lineage(l)
      guard c.writer == w, c.publication == p else { throw JournalError.invalidData }
    case .writerClosure(let l, let p, let closure):
      guard try lineage(l).writer == p else { throw JournalError.invalidData }
      if case .closed(.validated(let r)) = closure, r.id.isEmpty { throw JournalError.invalidData }
    case .rename(let l, let p), .renameFinished(let l, let p, _), .publish(let l, let p, _):
      guard try lineage(l).publication == p else { throw JournalError.invalidData }
    case .requestCleanup(let l, let p, let o): try permit(l, p); try operation(o)
    case .cleanupFinished(let l, let p, let o, _): try permit(l, p); try target(o)
    case .release(let l, let p): try permit(l, p)
    case .removeNamespace(let o): try operation(o)
    case .namespaceRemovalFinished(let o, _): try target(o)
    case .retry, .revoke: break
    }
  }

  func recording(_ event: JobRecoveryPolicy.Event) throws -> ImportRecoveryJournal {
    let dto = try EventDTO(event)
    let journal = Self(document: Document(version: 1, initial: document.initial,
      events: document.events + [dto]))
    _ = try journal.snapshot()
    return journal
  }

  func retrying(identity: ImportIdentity, confirmedInput: ConfirmedInput) throws -> ImportRecoveryJournal {
    let journal = Self(document: Document(version: 1, initial: document.initial,
      events: document.events + [.retryCapture(Capture(identity, confirmedInput))]))
    _ = try journal.snapshot()
    return journal
  }

  func encoded(maximumBytes: Int) throws -> Data {
    guard maximumBytes > 0 else { throw JournalError.invalidMaximumBytes }
    _ = try snapshot()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(document)
    guard data.count <= maximumBytes else { throw JournalError.byteLimitExceeded }
    return data
  }

  static func decode(_ data: Data, maximumBytes: Int) throws -> ImportRecoveryJournal {
    guard maximumBytes > 0 else { throw JournalError.invalidMaximumBytes }
    guard data.count <= maximumBytes else { throw JournalError.byteLimitExceeded }
    do {
      let document = try JSONDecoder().decode(Document.self, from: data)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      let normalized = try encoder.encode(document)
      // Only our canonical encoding is admitted. Lossy keyed decoding cannot hide
      // duplicate members, unknown keys or alternate spellings in the original bytes.
      guard data == normalized else { throw JournalError.invalidData }
      let journal = Self(document: document)
      _ = try journal.snapshot()
      return journal
    } catch let error as JobRecoveryPolicy.Rejection {
      throw error
    } catch {
      throw JournalError.invalidData
    }
  }
}
