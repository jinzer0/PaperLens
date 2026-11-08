import Darwin
import Foundation
import GRDB
import CryptoKit
import MachO
import SQLite3

// Verification-only. Explicit synthetic mode only; never normal product startup.
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

/// Contentless observations only. An image match does not waive source-identity validation.
struct PackagedDBProvenance: Encodable, Equatable, Sendable {
  let sameConnection: Bool
  let symbolsBoundToImage: Bool
  let sharedCacheImage: Bool
  let metadataMatches: Bool
  let osBuild: String?
  let imageIdentity: String?
  let sqliteVersion: String?
  let sqliteSourceId: String?
  let compileOptions: [String]
  let inspectedEntries: Int
  let maxEntryBytes: Int

  var verified: Bool {
    sameConnection && symbolsBoundToImage && sharedCacheImage && metadataMatches
      && osBuild != nil && imageIdentity != nil && sqliteVersion != nil && sqliteSourceId != nil
      && compileOptions.contains("ENABLE_FTS5")
  }
}

enum PackagedDBImageBinding {
  // The existing offline consumer's complete allowlist, in its canonical order.
  static let facts = ["ENABLE_FTS5", "THREADSAFE=1", "ENABLE_COLUMN_METADATA", "ENABLE_RTREE",
    "ENABLE_JSON1", "ENABLE_FTS3", "ENABLE_FTS4", "ENABLE_FTS3_PARENTHESIS",
    "ENABLE_UNLOCK_NOTIFY", "SECURE_DELETE", "DEFAULT_AUTOVACUUM", "ENABLE_DBSTAT_VTAB",
    "ENABLE_MATH_FUNCTIONS", "OMIT_LOAD_EXTENSION", "USE_URI", "ENABLE_SESSION"]

  // Preserve SQLite's documented alt markers and Apple's public sqlite3.h "aapl" marker.
  // https://www.sqlite.org/releaselog/3_21_0.html . Neither marker proves image origin.
  static func sourceSuffix(_ source: String) -> String? {
    guard source.utf8.count <= 256 else { return nil }
    let parts = source.split(separator: " ", omittingEmptySubsequences: false)
    guard parts.count == 3, parts[0].range(of: #"\A[0-9]{4}-[0-9]{2}-[0-9]{2}\z"#,
      options: .regularExpression) != nil,
      parts[1].range(of: #"\A[0-9]{2}:[0-9]{2}:[0-9]{2}\z"#,
      options: .regularExpression) != nil else { return nil }
    let suffix = String(parts[2])
    func hex(_ bytes: some Sequence<UInt8>) -> Bool {
      bytes.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    let canonical = [40, 64].contains(suffix.utf8.count) && hex(suffix.utf8)
    let modified = suffix.utf8.count == 64 && hex(suffix.utf8.prefix(60))
      && ["alt1", "alt2", "aapl"].contains(String(suffix.suffix(4)))
    guard canonical || modified else { return nil }
    return suffix
  }

  private static func osBuild() -> String? {
    var size = 0
    guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, (2...64).contains(size)
    else { return nil }
    var bytes = [CChar](repeating: 0, count: size)
    guard sysctlbyname("kern.osversion", &bytes, &size, nil, 0) == 0,
      (2...bytes.count).contains(size), bytes[size - 1] == 0 else { return nil }
    let value = String(decoding: bytes.prefix(size - 1).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    return value.range(of: #"\A[0-9]{1,3}[A-Z][0-9]{1,6}[a-z]?\z"#,
      options: .regularExpression) != nil ? value : nil
  }

  private static func imageUUID(_ base: UnsafeMutableRawPointer) -> Data? {
    let header = base.load(as: mach_header_64.self)
    guard header.magic == MH_MAGIC_64, header.filetype == MH_DYLIB,
      header.flags & UInt32(MH_DYLIB_IN_CACHE) != 0,
      (1...4096).contains(header.ncmds), header.sizeofcmds <= 1_048_576 else { return nil }
    let start = MemoryLayout<mach_header_64>.size
    let end = start + Int(header.sizeofcmds)
    var offset = start
    var uuid: Data?
    for _ in 0..<header.ncmds {
      guard offset <= end - MemoryLayout<load_command>.size else { return nil }
      let command = base.load(fromByteOffset: offset, as: load_command.self)
      guard command.cmdsize >= MemoryLayout<load_command>.size,
        Int(command.cmdsize) <= end - offset else { return nil }
      if command.cmd == LC_UUID {
        guard uuid == nil, command.cmdsize == MemoryLayout<uuid_command>.size else { return nil }
        uuid = Data(bytes: base.advanced(by: offset + MemoryLayout<load_command>.size), count: 16)
      }
      offset += Int(command.cmdsize)
    }
    return offset == end ? uuid : nil
  }

  private final class Witness {
    let connection: OpaquePointer
    let image: UnsafeMutableRawPointer?
    var calls = 0
    var sameConnection = false
    var executingImage = false
    init(connection: OpaquePointer, image: UnsafeMutableRawPointer?) {
      self.connection = connection; self.image = image
    }
    func observe(_ context: OpaquePointer) {
      calls += 1
      sameConnection = sqlite3_context_db_handle(context) == connection
      // Return PCs prove execution through this image, rather than merely its presence.
      // Raw stack addresses and dladdr paths never leave this synchronous callback.
      let addresses = Thread.callStackReturnAddresses
      guard let image, addresses.count < 128 else { return }
      executingImage = addresses.contains { address in
        guard let pointer = UnsafeRawPointer(bitPattern: address.uintValue) else { return false }
        var info = Dl_info()
        return dladdr(pointer, &info) != 0 && info.dli_fbase == image
      }
    }
  }

  static func observe(_ db: Database, diagnostics: PackagedDBDiagnostics) throws -> PackagedDBProvenance {
    guard let connection = db.sqliteConnection else { throw PackagedDBFailure(.unexpectedFailure) }
    let step: @convention(c) (OpaquePointer?) -> Int32 = sqlite3_step
    let prepare: @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, Int32, UInt32,
      UnsafeMutablePointer<OpaquePointer?>?, UnsafeMutablePointer<UnsafePointer<CChar>?>?) -> Int32
      = sqlite3_prepare_v3
    let version: @convention(c) () -> UnsafePointer<CChar>? = sqlite3_libversion
    let source: @convention(c) () -> UnsafePointer<CChar>? = sqlite3_sourceid
    let compile: @convention(c) (Int32) -> UnsafePointer<CChar>? = sqlite3_compileoption_get
    let addresses = [unsafeBitCast(step, to: UnsafeRawPointer.self),
      unsafeBitCast(prepare, to: UnsafeRawPointer.self), unsafeBitCast(version, to: UnsafeRawPointer.self),
      unsafeBitCast(source, to: UnsafeRawPointer.self), unsafeBitCast(compile, to: UnsafeRawPointer.self)]
    var first = Dl_info()
    let found = dladdr(addresses[0], &first) != 0
    var sharedCache = false
    var identity: String?
    let build = osBuild()
    var bound = false
    if found, let base = first.dli_fbase, let path = first.dli_fname,
      ["/usr/lib/libsqlite3.dylib", "/usr/lib/libsqlite3.0.dylib"].contains(String(cString: path)),
      _dyld_shared_cache_contains_path(path),
      let handle = dlopen(path, RTLD_NOW | RTLD_NOLOAD | RTLD_FIRST) {
      defer { dlclose(handle) }
      if let header = _dyld_get_dlopen_image_header(handle), UnsafeRawPointer(header) == UnsafeRawPointer(base),
        let uuid = imageUUID(base) {
        sharedCache = true
        bound = addresses.allSatisfy { address in
          var info = Dl_info()
          return dladdr(address, &info) != 0 && info.dli_fbase == base
        }
        if let build {
          identity = SHA256.hash(data: Data("apple-system-sqlite-image-v1\n\(build)\n".utf8) + uuid)
            .map { String(format: "%02x", $0) }.joined()
        }
      }
    }
    let witness = Witness(connection: connection, image: bound ? first.dli_fbase : nil)
    let retained = Unmanaged.passRetained(witness).toOpaque()
    let name = "paperlens_sqlite_provenance_v1"
    let registered = sqlite3_create_function_v2(connection, name, 0, SQLITE_UTF8 | SQLITE_DIRECTONLY,
      retained, { context, _, _ in
        guard let context, let user = sqlite3_user_data(context) else { return }
        Unmanaged<Witness>.fromOpaque(user).takeUnretainedValue().observe(context)
        sqlite3_result_int(context, 1)
      }, nil, nil, { user in
        if let user { Unmanaged<Witness>.fromOpaque(user).release() }
      })
    // SQLite invokes the destructor even when registration fails.
    guard registered == SQLITE_OK else { throw PackagedDBFailure(.unexpectedFailure) }
    var queryFailure: Error?
    do {
      guard try Int.fetchOne(db, sql: "SELECT paperlens_sqlite_provenance_v1()") == 1
      else { throw PackagedDBFailure(.unexpectedFailure) }
    } catch { queryFailure = error }
    let removed = sqlite3_create_function_v2(connection, name, 0, SQLITE_UTF8 | SQLITE_DIRECTONLY,
      nil, nil, nil, nil, nil)
    guard removed == SQLITE_OK else { throw PackagedDBFailure(.unexpectedFailure) }
    if let queryFailure { throw queryFailure }
    let options = diagnostics.compileOptions
    var directOptions: [String] = []
    for index in 0...256 {
      guard let value = compile(Int32(index)) else { break }
      guard index < 256, strnlen(value, 257) <= 256 else {
        throw PackagedDBFailure(.provenanceOverflow)
      }
      directOptions.append(String(cString: value))
    }
    let metadataMatches = version().map { String(cString: $0) } == diagnostics.version
      && source().map { String(cString: $0) } == diagnostics.sourceID
      && directOptions == options
    let validVersion = diagnostics.version.range(of: #"\A[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\z"#,
      options: .regularExpression) != nil
    return PackagedDBProvenance(sameConnection: witness.calls == 1 && witness.sameConnection,
      symbolsBoundToImage: bound && witness.executingImage, sharedCacheImage: sharedCache,
      metadataMatches: metadataMatches, osBuild: build, imageIdentity: identity,
      sqliteVersion: validVersion ? diagnostics.version : nil,
      sqliteSourceId: sourceSuffix(diagnostics.sourceID), compileOptions: facts.filter(options.contains),
      inspectedEntries: options.count, maxEntryBytes: options.map { $0.utf8.count }.max() ?? 0)
  }
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
      try queue.read { db in try Self.diagnostics(db) }
    }
  }

  private static func diagnostics(_ db: Database) throws -> PackagedDBDiagnostics {
    guard let version = try String.fetchOne(db, sql: "SELECT sqlite_version()"),
      let sourceID = try String.fetchOne(db, sql: "SELECT sqlite_source_id()"),
      version.utf8.count <= 256, sourceID.utf8.count <= 256
    else { throw PackagedDBFailure(.provenanceOverflow) }
    let options = try boundedStrings(db, sql: "PRAGMA compile_options", limit: 256)
    return PackagedDBDiagnostics(version: version, sourceID: sourceID, compileOptions: options)
  }

  func provenance() throws -> PackagedDBProvenance {
    try operation { queue in
      try queue.read { db in
        try PackagedDBImageBinding.observe(db, diagnostics: Self.diagnostics(db))
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
