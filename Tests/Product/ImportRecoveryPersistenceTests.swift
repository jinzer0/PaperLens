import Foundation
import GRDB
import XCTest
@testable import PaperLensProduct

final class ImportRecoveryPersistenceTests: XCTestCase {
  // Explicit synthetic codec budget, not a shipped product budget or physical attestation.
  private let bound = 262_144
  private let facts = ImportRecoveryJournal.ConfirmedInput(expectedSHA256: nil, destinationFolderID: nil)

  private func identity() -> ImportIdentity {
    ImportIdentity(paperID: UUID(), generation: UUID(), jobID: UUID(), attempt: UUID(),
      fence: UUID(), correlation: UUID(), input: UUID(), epoch: UUID(), writer: UUID(), publication: UUID())
  }

  private func ids(_ id: ImportIdentity) -> [UUID] {
    [id.paperID, id.generation, id.jobID, id.attempt, id.fence, id.correlation,
      id.input, id.epoch, id.writer, id.publication]
  }

  private func changing(_ id: ImportIdentity, column: Int) -> ImportIdentity {
    var values = ids(id)
    values[column] = UUID()
    return ImportIdentity(paperID: values[0], generation: values[1], jobID: values[2],
      attempt: values[3], fence: values[4], correlation: values[5], input: values[6],
      epoch: values[7], writer: values[8], publication: values[9])
  }

  private func fixture() throws -> (URL, ProductDatabase, ImportIdentity, ImportRecoveryJournal) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let db = try ProductDatabase.open(at: root)
    let id = identity()
    try db.reserveImport(id, title: "Synthetic history fixture")
    let pending = try ImportRecoveryJournal(identity: id, confirmedInput: facts)
    let claimed = try pending.recording(.claim(pending.snapshot().current.lineage))
    return (root, db, id, claimed)
  }

  private func initialize(_ journal: ImportRecoveryJournal, db: ProductDatabase) throws {
    try db.adapterWrite { try ProductDatabase.initializeImportRecovery(journal, maximumBytes: bound, in: $0) }
  }

  private func read(_ id: ImportIdentity, db: ProductDatabase, maximumBytes: Int? = nil) throws
    -> ImportRecoveryRecord {
    try db.adapterRead { try ProductDatabase.readImportRecovery(id,
      maximumBytes: maximumBytes ?? bound, in: $0) }
  }

  private func cas(_ bytes: Data, _ replacement: ImportRecoveryJournal, db: ProductDatabase) throws
    -> ImportRecoveryRecord {
    try db.adapterWrite { try ProductDatabase.compareAndSwapImportRecovery(expected: bytes,
      replacement: replacement, maximumBytes: bound, in: $0) }
  }

  private func assertError(_ expected: ImportRecoveryPersistenceError,
    _ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertThrowsError(try body(), file: file, line: line) {
      XCTAssertEqual($0 as? ImportRecoveryPersistenceError, expected, file: file, line: line)
    }
  }

  func testLegacyNullMissingAndRepeatedInitializationAreNotSuccessfulHistory() throws {
    let (root, db, id, claimed) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    assertError(.missingHistory) { _ = try read(id, db: db) }
    assertError(.missingHistory) { _ = try read(identity(), db: db) }
    try initialize(claimed, db: db)
    let bytes = try claimed.encoded(maximumBytes: bound)
    XCTAssertEqual(try read(id, db: db).encoded, bytes)
    assertError(.staleHistory) { try initialize(claimed, db: db) }
    XCTAssertEqual(try read(id, db: db).encoded, bytes)
  }

  func testInitializationRequiresExactPendingOrClaimedNewReservationJournal() throws {
    let (root, db, id, claimed) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let pending = try ImportRecoveryJournal(identity: id, confirmedInput: facts)
    assertError(.invalidHistory) { try initialize(pending, db: db) }
    assertError(.invalidHistory) {
      try db.adapterWrite { try ProductDatabase.initializeImportRecovery(claimed, maximumBytes: 1, in: $0) }
    }
    let l = try claimed.snapshot().current.lineage
    let writer = try claimed.recording(.acquireWriter(l, permit: id.writer.uuidString))
    assertError(.invalidHistory) { try initialize(writer, db: db) }
    try db.adapterWrite { try $0.execute(sql: "UPDATE importJob SET state = 'pending'") }
    assertError(.invalidHistory) { try initialize(claimed, db: db) }
    try initialize(pending, db: db)
    let stored = try read(id, db: db)
    XCTAssertEqual(try stored.journal.snapshot().current.state, .pending)
    let claimRecord = try cas(stored.encoded, claimed, db: db)
    XCTAssertEqual(try claimRecord.journal.snapshot(), try claimed.snapshot())
  }

  func testOrdinaryAppendsPersistExactImmutableBytesAndReopenSnapshot() throws {
    let (root, db, id, claimed) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    try initialize(claimed, db: db)
    let original = try read(id, db: db)
    let l = try claimed.snapshot().current.lineage
    let result = JobRecoveryPolicy.Result(id: "synthetic-result-not-physical-proof")
    var journal = claimed
    var record = original
    for event in [JobRecoveryPolicy.Event.acquireWriter(l, permit: id.writer.uuidString),
      .writerClosure(l, permit: id.writer.uuidString, .open),
      .writerClosure(l, permit: id.writer.uuidString, .closed(.validated(result))),
      .acquirePublication(l, writer: id.writer.uuidString, permit: id.publication.uuidString),
      .rename(l, permit: id.publication.uuidString),
      .renameFinished(l, permit: id.publication.uuidString, succeeded: true),
      .publish(l, permit: id.publication.uuidString, result),
      .release(l, permit: id.publication.uuidString)] {
      journal = try journal.recording(event)
      record = try cas(record.encoded, journal, db: db)
      XCTAssertEqual(record.encoded, try journal.encoded(maximumBytes: bound))
      XCTAssertEqual(try record.journal.snapshot(), try journal.snapshot())
    }
    XCTAssertEqual(original.encoded, try claimed.encoded(maximumBytes: bound))
    XCTAssertEqual(try original.journal.snapshot(), try claimed.snapshot())
    let reopened = try ProductDatabase.open(at: root)
    let restored = try read(id, db: reopened)
    XCTAssertEqual(restored.encoded, record.encoded)
    XCTAssertEqual(try restored.journal.snapshot(), try journal.snapshot())
    // No paper publication or execution-column transition was performed by persistence.
    XCTAssertEqual(try reopened.libraryRecords().first?.status, .importing)
    XCTAssertEqual(try reopened.adapterRead { try String.fetchOne($0, sql: "SELECT state FROM importJob") }, "running")
  }

  func testAllTenCallerAndJournalCaptureIdentityMismatchesReject() throws {
    let (root, db, id, claimed) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    for column in 0..<10 {
      let wrong = changing(id, column: column)
      let pending = try ImportRecoveryJournal(identity: wrong, confirmedInput: facts)
      let wrongClaim = try pending.recording(.claim(pending.snapshot().current.lineage))
      XCTAssertThrowsError(try initialize(wrongClaim, db: db))
    }
    try initialize(claimed, db: db)
    let bytes = try read(id, db: db).encoded
    for column in 0..<10 {
      XCTAssertThrowsError(try read(changing(id, column: column), db: db))
    }
    // Each stored canonical capture must also match the actual joined row.
    for column in 0..<10 {
      let wrong = changing(id, column: column)
      let pending = try ImportRecoveryJournal(identity: wrong, confirmedInput: facts)
      let wrongBytes = try pending.encoded(maximumBytes: bound)
      try db.adapterWrite { try $0.execute(sql: "UPDATE importJob SET recoveryJournal = ?", arguments: [wrongBytes]) }
      assertError(.invalidHistory) { _ = try read(id, db: db) }
    }
    try db.adapterWrite { try $0.execute(sql: "UPDATE importJob SET recoveryJournal = ?", arguments: [bytes]) }
    XCTAssertEqual(try read(id, db: db).encoded, bytes)
  }

  func testActualRowIdentityAndOwnerGenerationDeletionFences() throws {
    let (root, db, id, claimed) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    try initialize(claimed, db: db)
    let bytes = try read(id, db: db).encoded
    let replacement = try claimed.recording(.terminate(claimed.snapshot().current.lineage, .failed))
    for (table, column, original) in [
      ("paper", "generation", id.generation), ("importJob", "attempt", id.attempt),
      ("importJob", "fence", id.fence), ("importJob", "correlation", id.correlation),
      ("importJob", "input", id.input), ("importJob", "epoch", id.epoch),
      ("importJob", "writer", id.writer), ("importJob", "publication", id.publication)] {
      try db.adapterWrite { try $0.execute(sql: "UPDATE \(table) SET \(column) = ?", arguments: [UUID().uuidString]) }
      assertError(.staleHistory) { _ = try read(id, db: db) }
      assertError(.staleHistory) { _ = try cas(bytes, replacement, db: db) }
      try db.adapterWrite { try $0.execute(sql: "UPDATE \(table) SET \(column) = ?", arguments: [original.uuidString]) }
    }
    for status in ["deleting", "deletionFailed", "tombstone", "unknown"] {
      try db.adapterWrite { try $0.execute(sql: "UPDATE paper SET status = ?", arguments: [status]) }
      assertError(.invalidHistory) { _ = try read(id, db: db) }
      assertError(.invalidHistory) { _ = try cas(bytes, replacement, db: db) }
    }
    try db.adapterWrite { try $0.execute(sql: "UPDATE paper SET status = 'importing', deletionID = ?", arguments: [UUID().uuidString]) }
    assertError(.invalidHistory) { _ = try read(id, db: db) }
    assertError(.invalidHistory) { _ = try cas(bytes, replacement, db: db) }
  }

  func testInvalidRowTypesUnknownStatesCorruptAndOversizePayloads() throws {
    let (root, db, id, claimed) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    try initialize(claimed, db: db)
    let bytes = try read(id, db: db).encoded
    for payload in [Data(), Data("not-json".utf8), Data(bytes.dropLast()),
      Data([0x20]) + bytes, Data(repeating: 0, count: bound + 1)] {
      try db.adapterWrite { try $0.execute(sql: "UPDATE importJob SET recoveryJournal = ?", arguments: [payload]) }
      assertError(.invalidHistory) { _ = try read(id, db: db) }
    }
    try db.adapterWrite { try $0.execute(sql: "UPDATE importJob SET recoveryJournal = 'text-not-blob'") }
    assertError(.invalidHistory) { _ = try read(id, db: db) }
    try db.adapterWrite { try $0.execute(sql: "UPDATE importJob SET recoveryJournal = ?", arguments: [bytes]) }
    assertError(.invalidHistory) { _ = try read(id, db: db, maximumBytes: bytes.count - 1) }
    XCTAssertEqual(try read(id, db: db, maximumBytes: bytes.count).encoded, bytes)
    try db.adapterWrite { try $0.execute(sql: "UPDATE importJob SET attempt = ?", arguments: [Data([1, 2])]) }
    assertError(.invalidHistory) { _ = try read(id, db: db) }
    try db.adapterWrite { try $0.execute(sql: "UPDATE importJob SET attempt = ?", arguments: [Data(id.attempt.uuidString.utf8)]) }
    assertError(.invalidHistory) { _ = try read(id, db: db) }
    try db.adapterWrite { try $0.execute(sql: "UPDATE importJob SET attempt = ?, state = 'unknown'", arguments: [id.attempt.uuidString]) }
    assertError(.invalidHistory) { _ = try read(id, db: db) }
  }

  func testNonpositiveBoundsRejectBeforeTouchingMissingSchema() throws {
    let (root, db, id, claimed) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let bytes = try claimed.encoded(maximumBytes: bound)
    // A missing table distinguishes bound validation from any SQL access.
    try db.adapterWrite { sql in
      try sql.execute(sql: "ALTER TABLE importJob RENAME TO hiddenImportJob")
      for maximum in [0, -1] {
        assertError(.invalidHistory) { try ProductDatabase.initializeImportRecovery(claimed, maximumBytes: maximum, in: sql) }
        assertError(.invalidHistory) { _ = try ProductDatabase.readImportRecovery(id, maximumBytes: maximum, in: sql) }
        assertError(.invalidHistory) { _ = try ProductDatabase.compareAndSwapImportRecovery(expected: bytes,
          replacement: claimed, maximumBytes: maximum, in: sql) }
      }
      try sql.execute(sql: "ALTER TABLE hiddenImportJob RENAME TO importJob")
    }
  }

  func testStaleCASIdenticalTruncatedAndDivergentPrefixesAndRetryReject() throws {
    let (root, db, id, claimed) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    try initialize(claimed, db: db)
    let bytes = try read(id, db: db).encoded
    let l = try claimed.snapshot().current.lineage
    assertError(.invalidHistory) { _ = try cas(bytes, claimed, db: db) }
    let pending = try ImportRecoveryJournal(identity: id, confirmedInput: facts)
    assertError(.invalidHistory) { _ = try cas(bytes, pending, db: db) }
    let alternate = try pending.recording(.revoke)
    assertError(.invalidHistory) { _ = try cas(bytes, alternate, db: db) }
    let longerAlternate = try alternate.recording(.removeNamespace(operation: UUID().uuidString))
    assertError(.invalidHistory) { _ = try cas(bytes, longerAlternate, db: db) }
    let failed = try claimed.recording(.terminate(l, .failed))
    assertError(.invalidHistory) {
      try db.adapterWrite { _ = try ProductDatabase.compareAndSwapImportRecovery(expected: bytes,
        replacement: failed, maximumBytes: bytes.count, in: $0) }
    }
    let record = try cas(bytes, failed, db: db)
    let timedOut = try claimed.recording(.terminate(l, .timeout))
    assertError(.invalidHistory) { _ = try cas(record.encoded, timedOut, db: db) }
    let longerFork = try timedOut.recording(.startup(currentEpoch: UUID().uuidString))
    assertError(.invalidHistory) { _ = try cas(record.encoded, longerFork, db: db) }
    assertError(.staleHistory) { _ = try cas(bytes, failed, db: db) }
    let next = ImportIdentity(paperID: id.paperID, generation: id.generation, jobID: id.jobID,
      attempt: UUID(), fence: UUID(), correlation: UUID(), input: UUID(), epoch: id.epoch,
      writer: UUID(), publication: UUID())
    let retried = try failed.retrying(identity: next, confirmedInput: facts)
    assertError(.invalidHistory) { _ = try cas(record.encoded, retried, db: db) }
    assertError(.invalidHistory) { _ = try cas(Data("corrupt".utf8), failed, db: db) }
    XCTAssertEqual(try read(id, db: db).encoded, record.encoded)
  }

  func testStartupAuthorityEpochDoesNotRewriteCapturedRowEpoch() throws {
    let (root, db, id, claimed) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    try initialize(claimed, db: db)
    let bytes = try read(id, db: db).encoded
    let epoch = UUID()
    let startup = try claimed.recording(.startup(currentEpoch: epoch.uuidString))
    let record = try cas(bytes, startup, db: db)
    XCTAssertEqual(try record.journal.snapshot().authority.epoch, epoch.uuidString)
    XCTAssertEqual(try record.journal.currentCapture().identity.epoch, id.epoch)
    XCTAssertEqual(try read(id, db: db).encoded, record.encoded)
  }

  func testIgnoredAndCorruptedInitializationRollBackEntireCallerTransaction() throws {
    for corrupt in [false, true] {
      let (root, db, id, claimed) = try fixture()
      defer { try? FileManager.default.removeItem(at: root) }
      try installTrigger(corrupt: corrupt, db: db)
      assertError(corrupt ? .invalidHistory : .staleHistory) {
        try db.adapterWrite { sql in
          try sql.execute(sql: "UPDATE providerConfig SET generation = generation + 1")
          try ProductDatabase.initializeImportRecovery(claimed, maximumBytes: bound, in: sql)
        }
      }
      XCTAssertEqual(try db.providerConfiguration().generation, 0)
      assertError(.missingHistory) { _ = try read(id, db: db) }
    }
  }

  func testIgnoredAndCorruptedCASRollBackEntireCallerTransaction() throws {
    for corrupt in [false, true] {
      let (root, db, id, claimed) = try fixture()
      defer { try? FileManager.default.removeItem(at: root) }
      try initialize(claimed, db: db)
      let bytes = try read(id, db: db).encoded
      let replacement = try claimed.recording(.terminate(claimed.snapshot().current.lineage, .failed))
      try installTrigger(corrupt: corrupt, db: db)
      assertError(corrupt ? .invalidHistory : .staleHistory) {
        try db.adapterWrite { sql in
          try sql.execute(sql: "UPDATE providerConfig SET generation = generation + 1")
          _ = try ProductDatabase.compareAndSwapImportRecovery(expected: bytes,
            replacement: replacement, maximumBytes: bound, in: sql)
        }
      }
      XCTAssertEqual(try db.providerConfiguration().generation, 0)
      XCTAssertEqual(try read(id, db: db).encoded, bytes)
    }
  }

  private func installTrigger(corrupt: Bool, db: ProductDatabase) throws {
    try db.adapterWrite { sql in
      if corrupt {
        try sql.execute(sql: """
          CREATE TRIGGER corruptRecovery AFTER UPDATE OF recoveryJournal ON importJob
          BEGIN UPDATE importJob SET recoveryJournal = X'00' WHERE id = NEW.id; END
          """)
      } else {
        try sql.execute(sql: """
          CREATE TRIGGER ignoreRecovery BEFORE UPDATE OF recoveryJournal ON importJob
          BEGIN SELECT RAISE(IGNORE); END
          """)
      }
    }
  }
}
