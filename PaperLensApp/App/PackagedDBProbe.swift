import Darwin
import Foundation
import GRDB

// Verification-only. No Codable/raw logging surface and no product startup wiring.
enum PackagedDBFault: Equatable, Sendable { case none, m1, m2 }
enum PackagedDBReason: String, Sendable {
  case bindingMismatch = "binding_mismatch"
  case dbOpenFailed = "db_open_failed"
  case migrationFailed = "migration_failed"
  case provenanceOverflow = "provenance_overflow"
  case cleanupFailed = "cleanup_failed"
  case unexpectedFailure = "unexpected_failure"
}
struct PackagedDBFailure: Error, Sendable {
  let reason: PackagedDBReason
  let primaryCode: Int32?
  let extendedCode: Int32?
  init(_ reason: PackagedDBReason, error: Error? = nil) {
    self.reason = reason
    let databaseError = error as? DatabaseError
    primaryCode = databaseError?.resultCode.rawValue
    extendedCode = databaseError?.extendedResultCode.rawValue
  }
}
struct PackagedDBSnapshot: Equatable, Sendable {
  let version: Int
  let migrations: [String]
  let identifiers: Set<String>
  let registryRows: Int
  let probeObjects: [String]
  let baseSchemaValid: Bool
  let ftsSchemaValid: Bool
  let baselineRows: Int
  let ftsRows: Int
  let ftsIDs: [Int]
  let sentences: [String]
  let matches: [Int]
}
// These raw observations intentionally remain RAM-only. The parent owns the
// existing approved source-suffix/16-fact projector; this is NOT an exporter.
struct PackagedDBDiagnostics: Sendable {
  let version: String
  let sourceID: String
  let compileOptions: [String]
}

final class PackagedDBProbe: @unchecked Sendable {
  private final class Global: @unchecked Sendable {
    let lock = NSLock()
    var active = false
    var runs = Set<String>()
  }
  private static let global = Global()
  static let migrationNames = ["probe_base_v1", "probe_fts_v2"]
  static let corpus = ["orbit alpha.", "beta gamma.", "orbit delta.", "epsilon zeta."]
  let sqliteOrigin = "sqlite_origin_unverified"
  let storyDone = false
  let p2Passed = false
  let fault: PackagedDBFault
  private let owner: TopologyDBOwnerContext
  private let lock = NSLock()
  private let operationGate = NSLock()
  private var queue: DatabaseQueue?
  private var admitted = 0
  private var stopping = false
  private var closing = false
  private var closed = false
  private var cleaned = false
  private var ownershipRetained = false
  private var sidecars: [String: stat] = [:]
  private var ready = false
  private var failures: [PackagedDBFailure] = []
  private static let sidecarNames: Set<String> = [
    "db.sqlite-journal", "db.sqlite-wal", "db.sqlite-shm",
  ]

  var isReady: Bool { lock.withLock { ready } }
  var failureHistory: [PackagedDBFailure] { lock.withLock { failures } }
  var hasObservedClose: Bool { lock.withLock { closed } }

  init(owner input: TopologyDBOwnerContext, fault: PackagedDBFault) throws {
    guard input.validate(), input.entries() == ["db.sqlite"],
      input.databaseIdentity.st_size == 0
    else { throw PackagedDBFailure(.bindingMismatch) }
    var current = stat()
    guard fstatat(input.namespace, "db.sqlite", &current, AT_SYMLINK_NOFOLLOW) == 0,
      current.st_size == 0
    else { throw PackagedDBFailure(.bindingMismatch) }
    let root = fcntl(input.worktree, F_DUPFD_CLOEXEC, 0)
    let topology = fcntl(input.topology, F_DUPFD_CLOEXEC, 0)
    let namespace = fcntl(input.namespace, F_DUPFD_CLOEXEC, 0)
    guard root >= 0, topology >= 0, namespace >= 0 else {
      if root >= 0 { Darwin.close(root) }
      if topology >= 0 { Darwin.close(topology) }
      if namespace >= 0 { Darwin.close(namespace) }
      throw PackagedDBFailure(.bindingMismatch)
    }
    owner = TopologyDBOwnerContext(
      worktreePath: input.worktreePath, worktree: root, topology: topology,
      namespace: namespace, worktreeIdentity: input.worktreeIdentity,
      topologyIdentity: input.topologyIdentity, namespaceIdentity: input.namespaceIdentity,
      databaseIdentity: input.databaseIdentity, uid: input.uid, ownerID: input.ownerID,
      runID: input.runID, attemptID: input.attemptID)
    self.fault = fault
    let claimed = Self.global.lock.withLock {
      guard !Self.global.active, !Self.global.runs.contains(input.runID) else { return false }
      Self.global.runs.insert(input.runID)
      Self.global.active = true
      return true
    }
    guard claimed else { throw PackagedDBFailure(.bindingMismatch) }
    do {
      guard owner.validate() else { throw PackagedDBFailure(.bindingMismatch) }
      queue = try DatabaseQueue(path: owner.databasePath)
      try validateNamespace(observeNew: true)
    } catch {
      // If open succeeded, retain the global lease until throwing close is observed.
      let failure = (error as? PackagedDBFailure) ?? PackagedDBFailure(.dbOpenFailed, error: error)
      failures.append(failure)
      // A throwing initializer cannot return ownership of a successfully opened
      // queue. Close here, never unlink; a close failure must retain the queue.
      if let queue {
        do {
          try queue.close()
          Self.global.lock.withLock { Self.global.active = false }
        } catch {
          Self.retainUnclosed(queue, owner: owner)
          ownershipRetained = true
        }
        self.queue = nil
      } else {
        // Constructor failure does not expose a handle whose close we can
        // observe. Conservatively retain ownership and block replacement.
        Self.retainUnclosed(nil, owner: owner)
        ownershipRetained = true
      }
      throw failure
    }
  }

  // An unclosed queue must outlive a failed initializer/deinit. Keeping it and
  // the global lease blocks replacement; it does not assert drain or cleanup.
  private final class Retained: @unchecked Sendable {
    let lock = NSLock()
    var sessions: [(DatabaseQueue?, TopologyDBOwnerContext)] = []
  }
  private static let retained = Retained()
  private static func retainUnclosed(_ queue: DatabaseQueue?, owner: TopologyDBOwnerContext) {
    retained.lock.withLock { retained.sessions.append((queue, owner)) }
  }

  private func migrator() -> DatabaseMigrator {
    let fault = fault
    var migrator = DatabaseMigrator()
    migrator.eraseDatabaseOnSchemaChange = false
    migrator.registerMigration(Self.migrationNames[0]) { db in
      try db.execute(sql: "CREATE TABLE probe_base(id INTEGER PRIMARY KEY)")
      if fault == .m1 {
        try db.execute(sql: "INSERT INTO probe_base(id) VALUES (1)")
        try db.execute(sql: "INSERT INTO probe_base(id) VALUES (1)")
      }
      try db.execute(sql: "PRAGMA user_version = 1")
    }
    migrator.registerMigration(Self.migrationNames[1]) { db in
      try db.execute(sql: "CREATE VIRTUAL TABLE probe_fts USING fts5(sentence)")
      for (index, sentence) in Self.corpus.enumerated() {
        try db.execute(
          sql: "INSERT INTO probe_fts(rowid, sentence) VALUES (?, ?)",
          arguments: StatementArguments([index + 1, sentence] as [(any DatabaseValueConvertible)?]))
        if fault == .m2 && index == 0 {
          try db.execute(sql: "INSERT INTO probe_base(id) VALUES (1)")
          try db.execute(sql: "INSERT INTO probe_base(id) VALUES (1)")
        }
      }
      try db.execute(sql: "PRAGMA user_version = 2")
    }
    return migrator
  }

  private func validateNamespace(observeNew: Bool) throws {
    guard owner.validate(), let entries = owner.entries(), entries.contains("db.sqlite"),
      entries.subtracting(["db.sqlite"]).isSubset(of: Self.sidecarNames)
    else { throw PackagedDBFailure(.bindingMismatch) }
    for name in Array(sidecars.keys) where !entries.contains(name) {
      sidecars.removeValue(forKey: name)
    }
    for name in entries.subtracting(["db.sqlite"]) {
      if let identity = sidecars[name] {
        guard owner.validateFile(name, identity: identity) else {
          throw PackagedDBFailure(.bindingMismatch)
        }
      } else {
        guard observeNew else { throw PackagedDBFailure(.bindingMismatch) }
        var identity = stat()
        let valid =
          TopologyFixtures.privateNamedFile(
            directory: owner.namespace, name: name,
            path: owner.worktreePath + "/.build/topology/" + owner.entry + "/" + name,
            info: &identity)
          && TopologyFixtures.matches(directory: owner.namespace, name: name, info: identity)
        guard valid, owner.validate() else { throw PackagedDBFailure(.bindingMismatch) }
        sidecars[name] = identity
      }
    }
    guard owner.validate() else { throw PackagedDBFailure(.bindingMismatch) }
  }

  // Count admission before waiting for the separate operation gate. The entire
  // namespace/SQL/publication interval is serialized, including thrown paths.
  // The short state lock is never held while waiting for this gate or SQL work.
  private func operation<T>(
    admittedSignal: DispatchSemaphore? = nil,
    publish: (T) throws -> Void = { _ in },
    _ body: (DatabaseQueue) throws -> T
  ) throws -> T {
    let queue: DatabaseQueue
    do {
      queue = try lock.withLock {
        guard !stopping, !closed, !cleaned, let queue = self.queue else {
          throw PackagedDBFailure(.unexpectedFailure)
        }
        admitted += 1
        return queue
      }
    } catch {
      let failure = (error as? PackagedDBFailure) ?? PackagedDBFailure(.unexpectedFailure)
      lock.withLock {
        ready = false
        if failures.count < 32 { failures.append(failure) }
      }
      throw failure
    }
    defer { lock.withLock { admitted -= 1 } }
    admittedSignal?.signal()
    operationGate.lock()
    defer { operationGate.unlock() }
    var sqlStarted = false
    do {
      try validateNamespace(observeNew: false)
      sqlStarted = true
      let value = try body(queue)
      try validateNamespace(observeNew: true)
      try publish(value)
      return value
    } catch {
      let failure =
        (error as? PackagedDBFailure)
        ?? PackagedDBFailure(.unexpectedFailure, error: error)
      var namespaceFailure = false
      do { try validateNamespace(observeNew: sqlStarted) } catch { namespaceFailure = true }
      lock.withLock {
        ready = false
        if failures.count < 32 { failures.append(failure) }
        if namespaceFailure {
          if failures.count < 32 { failures.append(PackagedDBFailure(.bindingMismatch)) }
        }
      }
      throw failure
    }
  }

  func migrateBase() throws -> PackagedDBSnapshot {
    try operation { queue in
      let before = try inspect(queue)
      guard before.version == 0, before.identifiers.isEmpty, before.probeObjects.isEmpty else {
        throw PackagedDBFailure(.unexpectedFailure)
      }
      do { try migrator().migrate(queue, upTo: Self.migrationNames[0]) } catch {
        throw PackagedDBFailure(.migrationFailed, error: error)
      }
      return try inspect(queue)
    }
  }

  // The optional boundary only pauses real final publication for deterministic
  // lifecycle tests; it supplies no SQL result, close state or ready value.
  func migrate(beforePublication: (() -> Void)? = nil) throws -> PackagedDBSnapshot {
    try operation(publish: { (snapshot: PackagedDBSnapshot) in
      guard snapshot.version == 2, snapshot.migrations == Self.migrationNames,
        snapshot.identifiers == Set(Self.migrationNames), snapshot.registryRows == 2,
        snapshot.baseSchemaValid, snapshot.ftsSchemaValid, snapshot.baselineRows == 0,
        (snapshot.ftsRows == 0 && snapshot.matches.isEmpty)
          || (snapshot.ftsIDs == [1, 2, 3, 4] && snapshot.sentences == Self.corpus
            && snapshot.matches == [1, 3])
      else { throw PackagedDBFailure(.unexpectedFailure) }
      beforePublication?()
      try self.validateNamespace(observeNew: false)
      self.lock.withLock {
        self.ready =
          self.fault == .none && self.failures.isEmpty
          && !self.stopping && !self.closed && !self.closing && !self.cleaned
      }
    }) { queue in
      do { try migrator().migrate(queue) } catch {
        throw PackagedDBFailure(.migrationFailed, error: error)
      }
      return try inspect(queue)
    }
  }

  func snapshot(
    admittedSignal: DispatchSemaphore? = nil,
    beforePublication: (() -> Void)? = nil
  ) throws -> PackagedDBSnapshot {
    try operation(admittedSignal: admittedSignal, publish: { _ in beforePublication?() }) {
      try inspect($0)
    }
  }

  private func inspect(_ queue: DatabaseQueue) throws -> PackagedDBSnapshot {
    let migrator = migrator()
    return try queue.read { db in
      let objects = try Self.boundedStrings(
        db,
        sql:
          "SELECT name FROM sqlite_schema WHERE name GLOB 'probe_*' ORDER BY name", limit: 8)
      let registryExists =
        try Int.fetchOne(
          db,
          sql:
            "SELECT count(*) FROM sqlite_schema WHERE name = 'grdb_migrations'") == 1
      if registryExists {
        _ = try Self.boundedStrings(db, sql: "SELECT identifier FROM grdb_migrations", limit: 2)
      }
      let identifiers = try migrator.appliedIdentifiers(db)
      let migrations = try migrator.appliedMigrations(db)
      guard identifiers.count <= 2, migrations.count <= 2 else {
        throw PackagedDBFailure(.unexpectedFailure)
      }
      let registryRows =
        registryExists
        ? (try Int.fetchOne(db, sql: "SELECT count(*) FROM grdb_migrations") ?? -1) : 0
      let base =
        objects.contains("probe_base")
        ? (try Int.fetchOne(db, sql: "SELECT count(*) FROM probe_base") ?? -1) : 0
      let fts = objects.contains("probe_fts")
      let rows = fts ? (try Int.fetchOne(db, sql: "SELECT count(*) FROM probe_fts") ?? -1) : 0
      let baseColumn = try Int.fetchOne(
        db,
        sql:
          "SELECT count(*) FROM pragma_table_info('probe_base') WHERE name = 'id' AND type = 'INTEGER' AND pk = 1"
      )
      let baseColumns = try Int.fetchOne(
        db,
        sql:
          "SELECT count(*) FROM pragma_table_info('probe_base')")
      let baseSchemaValid = baseColumn == 1 && baseColumns == 1
      let ftsSchemaValid =
        try String.fetchOne(
          db,
          sql:
            "SELECT sql FROM sqlite_schema WHERE name = 'probe_fts'")
        == "CREATE VIRTUAL TABLE probe_fts USING fts5(sentence)"
      let sentences =
        fts
        ? try Self.boundedStrings(
          db,
          sql:
            "SELECT sentence FROM probe_fts ORDER BY rowid", limit: 4) : []
      var ftsIDs: [Int] = []
      if fts {
        let cursor = try Int.fetchCursor(db, sql: "SELECT rowid FROM probe_fts ORDER BY rowid")
        while let id = try cursor.next() {
          guard ftsIDs.count < 4 else { throw PackagedDBFailure(.unexpectedFailure) }
          ftsIDs.append(id)
        }
      }
      var matches: [Int] = []
      if fts {
        let cursor = try Int.fetchCursor(
          db,
          sql:
            "SELECT rowid FROM probe_fts WHERE probe_fts MATCH ? ORDER BY rowid",
          arguments: StatementArguments(["orbit"]))
        while let id = try cursor.next() {
          guard matches.count < 4 else { throw PackagedDBFailure(.unexpectedFailure) }
          matches.append(id)
        }
      }
      guard base >= 0, base <= 4, rows >= 0, rows <= 4, registryRows == identifiers.count else {
        throw PackagedDBFailure(.unexpectedFailure)
      }
      return PackagedDBSnapshot(
        version: try Int.fetchOne(db, sql: "PRAGMA user_version") ?? -1,
        migrations: migrations, identifiers: identifiers, registryRows: registryRows,
        probeObjects: objects, baseSchemaValid: baseSchemaValid, ftsSchemaValid: ftsSchemaValid,
        baselineRows: base, ftsRows: rows, ftsIDs: ftsIDs, sentences: sentences, matches: matches)
    }
  }

  func deleteCorpus() throws -> PackagedDBSnapshot {
    try operation { queue in
      try queue.write { db in try db.execute(sql: "DELETE FROM probe_fts") }
      return try inspect(queue)
    }
  }

  private static func boundedStrings(_ db: Database, sql: String, limit: Int) throws -> [String] {
    let cursor = try String.fetchCursor(db, sql: sql)
    return try collectBounded(limit: limit) { try cursor.next() }
  }

  // Incremental collection refuses the first overflow, never prefix proof.
  static func collectBounded(limit: Int = 256, next: () throws -> String?) throws -> [String] {
    guard limit > 0, limit <= 256 else { throw PackagedDBFailure(.provenanceOverflow) }
    var values: [String] = []
    while let value = try next() {
      guard values.count < limit, value.utf8.count <= 256 else {
        throw PackagedDBFailure(.provenanceOverflow)
      }
      values.append(value)
    }
    return values
  }

  func diagnostics() throws -> PackagedDBDiagnostics {
    try operation { queue in
      try queue.read { db in
        guard let version = try String.fetchOne(db, sql: "SELECT sqlite_version()"),
          let sourceID = try String.fetchOne(db, sql: "SELECT sqlite_source_id()"),
          version.utf8.count <= 256, sourceID.utf8.count <= 256
        else { throw PackagedDBFailure(.provenanceOverflow) }
        let options = try Self.boundedStrings(db, sql: "PRAGMA compile_options", limit: 256)
        return PackagedDBDiagnostics(version: version, sourceID: sourceID, compileOptions: options)
      }
    }
  }

  // A test barrier inside actual serialized GRDB work, not a fake completion.
  func barrier(entered: DispatchSemaphore, release: DispatchSemaphore) throws {
    try operation { queue in
      try queue.writeWithoutTransaction { db in
        _ = try Int.fetchOne(db, sql: "SELECT 1")
        entered.signal()
        release.wait()
        _ = try Int.fetchOne(db, sql: "SELECT 1")
      }
    }
  }

  // Hold a real write transaction after a dirty page has created its journal.
  // The baseline remains empty after commit, so normal invariants still apply.
  func transactionBarrier(entered: DispatchSemaphore, release: DispatchSemaphore) throws {
    try operation { queue in
      try queue.write { db in
        try db.execute(sql: "INSERT INTO probe_base(id) VALUES (1)")
        entered.signal()
        release.wait()
        try db.execute(sql: "DELETE FROM probe_base WHERE id = 1")
      }
    }
  }

  func interrupt() {
    let candidate: DatabaseQueue? = lock.withLock {
      guard !closed, !closing, let queue else { return nil }
      admitted += 1
      return queue
    }
    guard let candidate else { return }
    defer { lock.withLock { admitted -= 1 } }
    candidate.interrupt()
  }

  // Nonblocking drain attempt. A caller must retry after real operation
  // completion; interrupt alone never changes admitted or closed state.
  @discardableResult func closeAndDrain() -> Bool {
    let candidate: DatabaseQueue? = lock.withLock {
      stopping = true
      ready = false
      guard !closed, !closing, admitted == 0 else { return nil }
      closing = true
      return queue
    }
    guard let candidate else { return lock.withLock { closed } }
    do {
      try candidate.close()
      lock.withLock {
        closed = true
        closing = false
        queue = nil
        do { try validateNamespace(observeNew: false) } catch {
          if failures.count < 32 { failures.append(PackagedDBFailure(.bindingMismatch)) }
        }
      }
      Self.global.lock.withLock { Self.global.active = false }
      return true
    } catch {
      lock.withLock {
        closing = false
        if failures.count < 32 { failures.append(PackagedDBFailure(.cleanupFailed, error: error)) }
      }
      return false
    }
  }

  func reopen() throws {
    try lock.withLock {
      guard closed, !cleaned, !closing, admitted == 0 else {
        throw PackagedDBFailure(.unexpectedFailure)
      }
      try validateNamespace(observeNew: false)
      let claimed = Self.global.lock.withLock {
        guard !Self.global.active else { return false }
        Self.global.active = true
        return true
      }
      guard claimed else { throw PackagedDBFailure(.bindingMismatch) }
      do {
        queue = try DatabaseQueue(path: owner.databasePath)
        closed = false
        stopping = false
        try validateNamespace(observeNew: true)
      } catch {
        closed = false
        stopping = true
        let failure =
          (error as? PackagedDBFailure) ?? PackagedDBFailure(.dbOpenFailed, error: error)
        if failures.count < 32 { failures.append(failure) }
        if queue == nil {
          Self.retainUnclosed(nil, owner: owner)
          ownershipRetained = true
        }
        throw failure
      }
    }
  }

  @discardableResult func cleanup() -> Bool {
    lock.withLock {
      guard closed, !closing, admitted == 0, !cleaned else { return cleaned }
      do {
        try validateNamespace(observeNew: false)
        guard let entries = owner.entries(),
          entries.isSubset(of: Set(sidecars.keys).union(["db.sqlite"]))
        else { throw PackagedDBFailure(.cleanupFailed) }
        // Validate all entries before the first unlink; never remove a foreign
        // entry, even when another independently owned file is removable.
        for name in entries {
          let identity = name == "db.sqlite" ? owner.databaseIdentity : sidecars[name]!
          guard owner.validateFile(name, identity: identity) else {
            throw PackagedDBFailure(.cleanupFailed)
          }
        }
        for name in entries.subtracting(["db.sqlite"]).sorted() {
          guard owner.validate(), let identity = sidecars[name],
            owner.validateFile(name, identity: identity),
            TopologyFixtures.removeOwned(directory: owner.namespace, name: name, info: identity)
          else { throw PackagedDBFailure(.cleanupFailed) }
        }
        guard owner.validate(),
          TopologyFixtures.removeOwned(
            directory: owner.namespace, name: "db.sqlite", info: owner.databaseIdentity),
          owner.entries() == [],
          owner.validateDirectory(),
          TopologyFixtures.matches(
            directory: owner.topology, name: owner.entry,
            info: owner.namespaceIdentity),
          unlinkat(owner.topology, owner.entry, AT_REMOVEDIR) == 0
        else { throw PackagedDBFailure(.cleanupFailed) }
        cleaned = true
        return true
      } catch {
        if failures.count < 32 { failures.append(PackagedDBFailure(.cleanupFailed)) }
        return false
      }
    }
  }

  deinit {
    // No automatic file cleanup and no implicit close/drain certification.
    if ownershipRetained { return }
    if let queue {
      Self.retainUnclosed(queue, owner: owner)
      return
    }
    Darwin.close(owner.namespace)
    Darwin.close(owner.topology)
    Darwin.close(owner.worktree)
  }
}
