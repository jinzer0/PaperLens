import Foundation
import GRDB
import XCTest
import CryptoKit
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

  private let stageData = Data("owned closed import fixture\n".utf8)

  private var stageHash: String {
    SHA256.hash(data: stageData).map { String(format: "%02x", $0) }.joined()
  }

  private func ownedStage(root: URL, id: ImportIdentity, name: String = "checked-closed.pdf") throws
    -> ClosedImportStage {
    let namespace = root.resolvingSymlinksInPath().appendingPathComponent("papers")
      .appendingPathComponent(id.paperID.uuidString)
    try FileManager.default.createDirectory(at: namespace, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let file = namespace.appendingPathComponent(name)
    XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: nil))
    let handle = try FileHandle(forWritingTo: file)
    do {
      try handle.write(contentsOf: stageData)
      try handle.synchronize()
      try handle.close()
    } catch {
      try? handle.close()
      throw error
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: file.path)
    return ClosedImportStage(file: file, sha256: stageHash, bytes: Int64(stageData.count))
  }

  private func append(_ event: JobRecoveryPolicy.Event, to record: ImportRecoveryRecord,
    db: ProductDatabase) throws -> ImportRecoveryRecord {
    try db.appendJournaledImport(expected: record, replacement: record.journal.recording(event))
  }

  // Real fixture files, but these owner observations are synthetic, not production authority.
  private func renameIntent(_ reserved: ImportRecoveryRecord, db: ProductDatabase,
    resultID: String? = nil) throws -> ImportRecoveryRecord {
    let id = try reserved.journal.currentCapture().identity
    let lineage = try reserved.journal.snapshot().current.lineage
    var record = reserved
    for event in [JobRecoveryPolicy.Event.writerClosure(lineage, permit: id.writer.uuidString, .open),
      .writerClosure(lineage, permit: id.writer.uuidString,
        .closed(.validated(.init(id: resultID ?? id.attempt.uuidString)))),
      .acquirePublication(lineage, writer: id.writer.uuidString, permit: id.publication.uuidString),
      .rename(lineage, permit: id.publication.uuidString)] {
      record = try append(event, to: record, db: db)
    }
    return record
  }

  private func publicationFixture(confirmedHash: Bool = false, folder: Bool = false,
    resultID: String? = nil, includeIntent: Bool = true) throws
    -> (URL, ProductDatabase, ImportIdentity, ImportRecoveryRecord, ClosedImportStage) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let db = try ProductDatabase.open(at: root)
    let id = identity()
    let folderID = folder ? try db.createFolder(name: "Captured destination").id : nil
    let confirmed = ImportRecoveryJournal.ConfirmedInput(
      expectedSHA256: confirmedHash ? stageHash : nil, destinationFolderID: folderID)
    let reserved = try db.reserveJournaledImport(id, title: "Actual transaction fixture", confirmedInput: confirmed)
    let stage = try ownedStage(root: root, id: id)
    let record = includeIntent ? try renameIntent(reserved, db: db, resultID: resultID) : reserved
    return (root, db, id, record, stage)
  }

  private func finalURL(_ stage: ClosedImportStage) -> URL {
    stage.file.deletingLastPathComponent().appendingPathComponent("document.pdf")
  }

  private func assertNoMove(_ record: ImportRecoveryRecord, stage: ClosedImportStage,
    db: ProductDatabase, file: StaticString = #filePath, line: UInt = #line) throws {
    XCTAssertTrue(FileManager.default.fileExists(atPath: stage.file.path), file: file, line: line)
    XCTAssertFalse(FileManager.default.fileExists(atPath: finalURL(stage).path), file: file, line: line)
    let id = try record.journal.currentCapture().identity
    XCTAssertEqual(try read(id, db: db).encoded, record.encoded, file: file, line: line)
  }

  func testJournaledReservationCapturesExactIdentityFactsWriterAndReopens() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let db = try ProductDatabase.open(at: root)
    let id = identity()
    let folder = try db.createFolder(name: "Reservation destination")
    let confirmed = ImportRecoveryJournal.ConfirmedInput(expectedSHA256: stageHash, destinationFolderID: folder.id)
    let record = try db.reserveJournaledImport(id, title: "Exact reservation", confirmedInput: confirmed)
    let capture = try record.journal.currentCapture()
    XCTAssertEqual(ids(capture.identity), ids(id))
    XCTAssertEqual(capture.confirmedInput, confirmed)
    let snapshot = try record.journal.snapshot()
    XCTAssertEqual(snapshot.current.state, .running)
    XCTAssertEqual(snapshot.permits.count, 1)
    XCTAssertEqual(snapshot.permits.first?.kind, .writer)
    XCTAssertEqual(snapshot.permits.first?.id, id.writer.uuidString)
    XCTAssertEqual(snapshot.permits.first?.owner, snapshot.current.lineage)
    XCTAssertEqual(snapshot.permits.first?.closure, .unknown)
    XCTAssertEqual(try read(id, db: ProductDatabase.open(at: root)).encoded, record.encoded)
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("papers").path))
  }

  func testJournaledReservationInvalidFolderDuplicateAndIgnoredInitializationRollBack() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let db = try ProductDatabase.open(at: root)
    let invalid = identity()
    XCTAssertThrowsError(try db.reserveJournaledImport(invalid, title: "Denied",
      confirmedInput: .init(expectedSHA256: nil, destinationFolderID: UUID())))
    XCTAssertTrue(try db.libraryRecords().isEmpty)
    let id = identity()
    let record = try db.reserveJournaledImport(id, title: "Original", confirmedInput: facts)
    let duplicateJob = ImportIdentity(paperID: UUID(), generation: UUID(), jobID: id.jobID,
      attempt: UUID(), fence: UUID(), correlation: UUID(), input: UUID(), epoch: UUID(),
      writer: UUID(), publication: UUID())
    XCTAssertThrowsError(try db.reserveJournaledImport(duplicateJob, title: "Must roll back", confirmedInput: facts))
    XCTAssertThrowsError(try db.reserveJournaledImport(id, title: "Duplicate", confirmedInput: facts))
    XCTAssertEqual(try db.libraryRecords().map(\.title), ["Original"])
    XCTAssertEqual(try read(id, db: db).encoded, record.encoded)
    try installTrigger(corrupt: false, db: db)
    XCTAssertThrowsError(try db.reserveJournaledImport(identity(), title: "Ignored initialization", confirmedInput: facts))
    XCTAssertEqual(try db.libraryRecords().map(\.title), ["Original"])
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("papers").path))
  }

  func testJournaledPublicationMovesActualClosedStageAndPublishesCompleteFactsOnReopen() throws {
    for confirmedHash in [false, true] {
      let (root, db, id, expected, stage) = try publicationFixture(confirmedHash: confirmedHash, folder: true)
      defer { try? FileManager.default.removeItem(at: root) }
      try db.recordProgress(id, bytes: stage.bytes)
      let completed = try db.publishJournaledImport(expected: expected, closedStage: stage)
      XCTAssertFalse(FileManager.default.fileExists(atPath: stage.file.path))
      XCTAssertEqual(try Data(contentsOf: finalURL(stage)), stageData)
      let snapshot = try completed.journal.snapshot()
      XCTAssertEqual(snapshot.current.state, .succeeded)
      XCTAssertTrue(snapshot.permits.isEmpty)
      XCTAssertEqual(snapshot.usableResult?.result.id, id.attempt.uuidString)
      let confirmed = try completed.journal.currentCapture().confirmedInput
      XCTAssertEqual(confirmed, try expected.journal.currentCapture().confirmedInput)
      XCTAssertEqual(confirmed.expectedSHA256, confirmedHash ? stageHash : nil)
      let reopened = try ProductDatabase.open(at: root)
      XCTAssertEqual(try read(id, db: reopened).encoded, completed.encoded)
      XCTAssertEqual(try read(id, db: reopened).journal.snapshot(), snapshot)
      XCTAssertEqual(try reopened.folderID(for: id.paperID), confirmed.destinationFolderID)
      let placement = try reopened.capturePaperPlacement(paperID: id.paperID, generation: id.generation)
      XCTAssertEqual(placement.sha256, stageHash)
      XCTAssertEqual(placement.pdfReference, "papers/\(id.paperID.uuidString)/document.pdf")
      let library = try XCTUnwrap(reopened.libraryRecords().first)
      XCTAssertEqual(library.status, .ready)
      XCTAssertEqual(library.bytesCopied, stage.bytes)
      XCTAssertNil(library.failure)
    }
  }

  func testJournaledAppendRejectsTypedBytesFactsPrefixAndStaleMismatch() throws {
    let (root, db, id, expected, stage) = try publicationFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let snapshot = try expected.journal.snapshot()
    let replacement = try expected.journal.recording(.authorityChanged(snapshot.authority))
    let inconsistent = ImportRecoveryRecord(journal: replacement, encoded: expected.encoded)
    assertError(.invalidHistory) { _ = try db.appendJournaledImport(expected: inconsistent, replacement: replacement) }
    assertError(.invalidHistory) { _ = try db.appendJournaledImport(expected: expected, replacement: expected.journal) }
    let differentFacts = try ImportRecoveryJournal(identity: id,
      confirmedInput: .init(expectedSHA256: stageHash, destinationFolderID: nil))
    XCTAssertThrowsError(try db.appendJournaledImport(expected: expected, replacement: differentFacts))
    let updated = try db.appendJournaledImport(expected: expected, replacement: replacement)
    assertError(.staleHistory) { _ = try db.appendJournaledImport(expected: expected, replacement: replacement) }
    assertError(.staleHistory) { _ = try db.publishJournaledImport(expected: expected, closedStage: stage) }
    try assertNoMove(updated, stage: stage, db: db)
  }

  func testJournaledPublicationRejectsHashFolderProgressAndUnacknowledgedIntentBeforeMove() throws {
    for denial in ["hash", "folder", "progress", "result", "intent", "canonical", "bytes", "upperHash"] {
      let (root, db, id, expected, stage) = try publicationFixture(confirmedHash: true, folder: true,
        resultID: denial == "result" ? UUID().uuidString : nil, includeIntent: denial != "intent")
      defer { try? FileManager.default.removeItem(at: root) }
      var observation = stage
      var supplied = expected
      switch denial {
      case "hash": observation = ClosedImportStage(file: stage.file, sha256: String(repeating: "a", count: 64), bytes: stage.bytes)
      case "folder": try db.deleteFolder(id: XCTUnwrap(expected.journal.currentCapture().confirmedInput.destinationFolderID))
      case "progress": try db.recordProgress(id, bytes: stage.bytes + 1)
      case "canonical": supplied = ImportRecoveryRecord(journal: expected.journal, encoded: expected.encoded + Data([0]))
      case "bytes": observation = ClosedImportStage(file: stage.file, sha256: stage.sha256, bytes: 0)
      case "upperHash": observation = ClosedImportStage(file: stage.file, sha256: stage.sha256.uppercased(), bytes: stage.bytes)
      default: break
      }
      XCTAssertThrowsError(try db.publishJournaledImport(expected: supplied, closedStage: observation), denial)
      try assertNoMove(expected, stage: stage, db: db)
    }
  }

  func testJournaledPublicationAndAppendRejectEveryUUIDDriftAndDeletionBeforeMove() throws {
    let names = ["paperID", "generation", "id", "attempt", "fence", "correlation", "input", "epoch", "writer", "publication"]
    for column in 0..<10 {
      let (root, db, id, expected, stage) = try publicationFixture()
      defer { try? FileManager.default.removeItem(at: root) }
      try db.adapterWrite { sql in
        if column == 0 {
          // Preserve FK integrity while drifting actual job/paper association.
          let other = identity()
          try ProductDatabase.insertImport(other, title: "Foreign association", createdAt: 1, in: sql)
          try sql.execute(sql: "DELETE FROM importJob WHERE id = ?", arguments: [other.jobID.uuidString])
          try sql.execute(sql: "UPDATE importJob SET paperID = ? WHERE id = ?", arguments: [other.paperID.uuidString, id.jobID.uuidString])
        } else {
          let table = column == 1 ? "paper" : "importJob"
          try sql.execute(sql: "UPDATE \(table) SET \(names[column]) = ?", arguments: [UUID().uuidString])
        }
      }
      let replacement = try expected.journal.recording(.authorityChanged(expected.journal.snapshot().authority))
      XCTAssertThrowsError(try db.appendJournaledImport(expected: expected, replacement: replacement))
      XCTAssertThrowsError(try db.publishJournaledImport(expected: expected, closedStage: stage))
      XCTAssertTrue(FileManager.default.fileExists(atPath: stage.file.path))
      XCTAssertFalse(FileManager.default.fileExists(atPath: finalURL(stage).path))
    }
    let (root, db, id, expected, stage) = try publicationFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try db.beginDeletion(id.paperID)
    XCTAssertThrowsError(try db.appendJournaledImport(expected: expected,
      replacement: expected.journal.recording(.revoke)))
    XCTAssertThrowsError(try db.publishJournaledImport(expected: expected, closedStage: stage))
    XCTAssertTrue(FileManager.default.fileExists(atPath: stage.file.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: finalURL(stage).path))
  }

  func testJournaledPublicationRejectsUnsafeOwnedFileShapesAndFinalOverwrite() throws {
    for denial in ["foreign", "siblingPrefix", "symlink", "directory", "hardlink", "writable", "size", "finalAlias", "overwrite", "nul", "namespaceSymlink"] {
      let (root, db, id, expected, stage) = try publicationFixture()
      defer { try? FileManager.default.removeItem(at: root) }
      let fm = FileManager.default
      var file = stage.file
      let final = finalURL(stage)
      switch denial {
      case "foreign", "siblingPrefix":
        let foreign = denial == "foreign" ? identity() : ImportIdentity(paperID: id.paperID,
          generation: id.generation, jobID: id.jobID, attempt: id.attempt, fence: id.fence,
          correlation: id.correlation, input: id.input, epoch: id.epoch, writer: id.writer, publication: id.publication)
        if denial == "foreign" { file = try ownedStage(root: root, id: foreign).file }
        else {
          let sibling = stage.file.deletingLastPathComponent().appendingPathExtension("foreign")
          try fm.createDirectory(at: sibling, withIntermediateDirectories: true)
          file = sibling.appendingPathComponent("closed.pdf")
          try fm.copyItem(at: stage.file, to: file)
        }
      case "symlink":
        file = stage.file.deletingLastPathComponent().appendingPathComponent("link.pdf")
        try fm.createSymbolicLink(at: file, withDestinationURL: stage.file)
      case "directory": file = stage.file.deletingLastPathComponent()
      case "hardlink":
        try fm.linkItem(at: stage.file, to: stage.file.deletingLastPathComponent().appendingPathComponent("hardlink.pdf"))
      case "writable": try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
      case "size": break
      case "finalAlias": file = final
      case "overwrite": try stageData.write(to: final)
      case "nul": file = try XCTUnwrap(URL(string: stage.file.absoluteString + "%00"))
      default:
        let namespace = stage.file.deletingLastPathComponent()
        let relocated = namespace.appendingPathExtension("relocated")
        try fm.moveItem(at: namespace, to: relocated)
        try fm.createSymbolicLink(at: namespace, withDestinationURL: relocated)
      }
      let observation = ClosedImportStage(file: file, sha256: stage.sha256,
        bytes: denial == "size" ? stage.bytes + 1 : stage.bytes)
      XCTAssertThrowsError(try db.publishJournaledImport(expected: expected, closedStage: observation), denial)
      XCTAssertEqual(try read(id, db: db).encoded, expected.encoded)
      XCTAssertTrue(fm.fileExists(atPath: stage.file.path))
      if denial == "overwrite" { XCTAssertEqual(try Data(contentsOf: final), stageData) }
      else { XCTAssertFalse(fm.fileExists(atPath: final.path)) }
    }
  }

  func testJournaledPublicationPreflightsRealMetadataQuotaBeforeFilesystemEffects() throws {
    let (root, db, id, initial, stage) = try publicationFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let maximum = ProductJobRecovery.maximumImportRecoveryJournalBytes
    var journal = initial.journal
    let snapshot = try journal.snapshot()
    let lineage = snapshot.current.lineage
    while true {
      let suffix = try journal.recording(.renameFinished(lineage, permit: id.publication.uuidString, succeeded: true))
        .recording(.publish(lineage, permit: id.publication.uuidString, .init(id: id.attempt.uuidString)))
        .recording(.release(lineage, permit: id.publication.uuidString))
      if (try? suffix.encoded(maximumBytes: maximum)) == nil { break }
      journal = try journal.recording(.authorityChanged(snapshot.authority))
      _ = try journal.encoded(maximumBytes: maximum)
    }
    let expected = try db.appendJournaledImport(expected: initial, replacement: journal)
    XCTAssertLessThanOrEqual(expected.encoded.count, maximum)
    XCTAssertThrowsError(try db.publishJournaledImport(expected: expected, closedStage: stage))
    try assertNoMove(expected, stage: stage, db: db)
  }

  func testJournaledPublicationSQLFailuresPreserveMovedBytesAndRollBackEveryStoredFact() throws {
    for trigger in ["ignoreJournal", "corruptJournal", "ignorePaper", "corruptPaper", "ignoreJob", "corruptJob", "immutablePaper", "immutableJob", "ignoreFolder", "corruptFolder", "corruptAfterSuccess"] {
      let (root, db, id, expected, stage) = try publicationFixture(folder: true)
      defer { try? FileManager.default.removeItem(at: root) }
      let before = try db.adapterRead { sql in
        (try XCTUnwrap(Row.fetchOne(sql, sql: "SELECT * FROM paper")),
          try XCTUnwrap(Row.fetchOne(sql, sql: "SELECT * FROM importJob")))
      }
      try db.adapterWrite { sql in
        let statement: String
        switch trigger {
        case "ignoreJournal": statement = "BEFORE UPDATE OF recoveryJournal ON importJob BEGIN SELECT RAISE(IGNORE); END"
        case "corruptJournal": statement = "AFTER UPDATE OF recoveryJournal ON importJob BEGIN UPDATE importJob SET recoveryJournal = X'00' WHERE id = NEW.id; END"
        case "ignorePaper": statement = "BEFORE UPDATE OF status ON paper BEGIN SELECT RAISE(IGNORE); END"
        case "corruptPaper": statement = "AFTER UPDATE OF status ON paper BEGIN UPDATE paper SET pdfSHA256 = 'wrong' WHERE id = NEW.id; END"
        case "ignoreJob": statement = "BEFORE UPDATE OF state ON importJob BEGIN SELECT RAISE(IGNORE); END"
        case "corruptJob": statement = "AFTER UPDATE OF state ON importJob BEGIN UPDATE importJob SET state = 'failed' WHERE id = NEW.id; END"
        case "immutablePaper": statement = "AFTER UPDATE OF status ON paper BEGIN UPDATE paper SET title = 'mutated' WHERE id = NEW.id; END"
        case "immutableJob": statement = "AFTER UPDATE OF state ON importJob BEGIN UPDATE importJob SET bytesCopied = 999 WHERE id = NEW.id; END"
        case "ignoreFolder": statement = "BEFORE INSERT ON paperFolder BEGIN SELECT RAISE(IGNORE); END"
        case "corruptFolder": statement = "AFTER INSERT ON paperFolder BEGIN DELETE FROM paperFolder WHERE paperID = NEW.paperID; END"
        default: statement = "AFTER UPDATE OF state ON importJob BEGIN UPDATE importJob SET recoveryJournal = X'00' WHERE id = NEW.id; END"
        }
        try sql.execute(sql: "CREATE TRIGGER denyPublication \(statement)")
      }
      XCTAssertThrowsError(try db.publishJournaledImport(expected: expected, closedStage: stage), trigger)
      XCTAssertFalse(FileManager.default.fileExists(atPath: stage.file.path))
      XCTAssertEqual(try Data(contentsOf: finalURL(stage)), stageData)
      XCTAssertEqual(try read(id, db: db).encoded, expected.encoded)
      XCTAssertEqual(try read(id, db: ProductDatabase.open(at: root)).encoded, expected.encoded)
      let after = try db.adapterRead { sql in
        (try XCTUnwrap(Row.fetchOne(sql, sql: "SELECT * FROM paper")),
          try XCTUnwrap(Row.fetchOne(sql, sql: "SELECT * FROM importJob")))
      }
      for (old, new) in [(before.0, after.0), (before.1, after.1)] {
        for column in old.columnNames {
          let a: DatabaseValue = old[column]
          let b: DatabaseValue = new[column]
          XCTAssertEqual(a, b, "\(trigger): \(column)")
        }
      }
      XCTAssertNil(try db.folderID(for: id.paperID))
    }
  }

  func testJournaledAppendRejectsIgnoredCorruptAndImmutableMutationWithWholeSQLRollback() throws {
    for trigger in ["ignored", "corrupt", "immutable"] {
      let (root, db, id, expected, stage) = try publicationFixture()
      defer { try? FileManager.default.removeItem(at: root) }
      if trigger == "immutable" {
        try db.adapterWrite { sql in
          try sql.execute(sql: """
            CREATE TRIGGER mutateAppend AFTER UPDATE OF recoveryJournal ON importJob
            BEGIN UPDATE paper SET title = 'mutated'; END
            """)
        }
      } else { try installTrigger(corrupt: trigger == "corrupt", db: db) }
      let replacement = try expected.journal.recording(.authorityChanged(expected.journal.snapshot().authority))
      XCTAssertThrowsError(try db.appendJournaledImport(expected: expected, replacement: replacement))
      XCTAssertEqual(try db.libraryRecords().first?.title, "Actual transaction fixture")
      XCTAssertEqual(try read(id, db: db).encoded, expected.encoded)
      try assertNoMove(expected, stage: stage, db: db)
    }
  }

  func testJournaledAppendAndPublicationRejectMissingCorruptOversizeAndRevokedHistory() throws {
    for denial in ["null", "corrupt", "oversize", "missingJob", "revoked"] {
      let (root, db, id, initial, stage) = try publicationFixture()
      defer { try? FileManager.default.removeItem(at: root) }
      var expected = initial
      if denial == "revoked" {
        expected = try append(.revoke, to: initial, db: db)
      } else {
        try db.adapterWrite { sql in
          switch denial {
          case "null": try sql.execute(sql: "UPDATE importJob SET recoveryJournal = NULL")
          case "corrupt": try sql.execute(sql: "UPDATE importJob SET recoveryJournal = X'00'")
          case "oversize": try sql.execute(sql: "UPDATE importJob SET recoveryJournal = ?",
            arguments: [Data(repeating: 0, count: ProductJobRecovery.maximumImportRecoveryJournalBytes + 1)])
          default: try sql.execute(sql: "DELETE FROM importJob WHERE id = ?", arguments: [id.jobID.uuidString])
          }
        }
      }
      let observation = try expected.journal.recording(.authorityChanged(expected.journal.snapshot().authority))
      if denial != "revoked" {
        XCTAssertThrowsError(try db.appendJournaledImport(expected: expected, replacement: observation))
      }
      XCTAssertThrowsError(try db.publishJournaledImport(expected: expected, closedStage: stage))
      XCTAssertTrue(FileManager.default.fileExists(atPath: stage.file.path))
      XCTAssertFalse(FileManager.default.fileExists(atPath: finalURL(stage).path))
    }
  }

  // Terminal observations and SQL state below are synthetic fixture attestations,
  // not file closure ACKs, production owner events, or physical publication.
  private func deletingFixture(cause: String = "paperDeleting",
    policyFailure: JobRecoveryPolicy.Failure = .failed) throws
    -> (URL, ProductDatabase, ImportIdentity, UUID, ImportRecoveryRecord, ImportRecoveryJournal) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let db = try ProductDatabase.open(at: root)
    let id = identity()
    let saga = UUID()
    var record = try db.reserveJournaledImport(id, title: "Synthetic deleting history", confirmedInput: facts)
    let lineage = try record.journal.snapshot().current.lineage
    if cause == "succeeded" {
      let result = JobRecoveryPolicy.Result(id: "synthetic-published-result")
      for event in [JobRecoveryPolicy.Event.writerClosure(lineage, permit: id.writer.uuidString,
        .closed(.validated(result))),
        .acquirePublication(lineage, writer: id.writer.uuidString, permit: id.publication.uuidString),
        .rename(lineage, permit: id.publication.uuidString),
        .renameFinished(lineage, permit: id.publication.uuidString, succeeded: true),
        .publish(lineage, permit: id.publication.uuidString, result)] {
        record = try append(event, to: record, db: db)
      }
    } else if cause == "interrupted" {
      record = try append(.startup(currentEpoch: UUID().uuidString), to: record, db: db)
    } else if cause != "paperDeleting" {
      record = try append(.terminate(lineage, policyFailure), to: record, db: db)
    }
    let unrevoked = record.journal
    let revoked = try unrevoked.recording(.revoke)
    record = try db.adapterWrite { sql in
      if cause != "paperDeleting" {
        // Seed the prior terminal owner observation before deletion revocation.
        // No filesystem publication/closure is performed or acknowledged here.
        try sql.execute(sql: "UPDATE importJob SET state = ?, failure = ?, bytesCopied = 17",
          arguments: [cause == "succeeded" ? "succeeded" : "failed", cause == "succeeded" ? nil : cause])
        try sql.execute(sql: "UPDATE paper SET status = ?, pdfReference = ?",
          arguments: [cause == "succeeded" ? "ready" : "importFailed",
            cause == "succeeded" ? "papers/\(id.paperID.uuidString)/document.pdf" : nil])
      }
      // Genuine replayed revocation is persisted before the actual saga is marked.
      let stored = try ProductDatabase.compareAndSwapImportRecovery(expected: record.encoded,
        replacement: revoked, maximumBytes: bound, in: sql)
      if cause == "paperDeleting" {
        try sql.execute(sql: "UPDATE importJob SET state = 'failed', failure = 'paperDeleting', bytesCopied = 17")
      }
      try sql.execute(sql: """
        UPDATE paper SET status = 'deleting', deletionID = ?, cleanupDebt = 1,
          pdfReference = NULL, pdfSHA256 = ?, deletionFailure = 'deletionIncomplete'
        """, arguments: [saga.uuidString, String(repeating: "a", count: 64)])
      try sql.execute(sql: "UPDATE providerConfig SET generation = 7, model = 'caller-baseline'")
      return stored
    }
    return (root, db, id, saga, record, unrevoked)
  }

  private func readDeleting(_ id: ImportIdentity, saga: UUID, db: ProductDatabase,
    maximumBytes: Int? = nil) throws -> ImportRecoveryRecord {
    try db.adapterRead { try ProductDatabase.readImportRecoveryForDeletion(id, saga: saga,
      maximumBytes: maximumBytes ?? bound, in: $0) }
  }

  private func casDeleting(_ expected: Data, _ replacement: ImportRecoveryJournal,
    saga: UUID, db: ProductDatabase, maximumBytes: Int? = nil) throws -> ImportRecoveryRecord {
    try db.adapterWrite { try ProductDatabase.compareAndSwapImportRecoveryForDeletion(expected: expected,
      replacement: replacement, saga: saga, maximumBytes: maximumBytes ?? bound, in: $0) }
  }

  private func actualRows(_ db: ProductDatabase) throws -> (Row, Row, Row) {
    try db.adapterRead { sql in
      (try XCTUnwrap(Row.fetchOne(sql, sql: "SELECT * FROM paper")),
        try XCTUnwrap(Row.fetchOne(sql, sql: "SELECT * FROM importJob")),
        try XCTUnwrap(Row.fetchOne(sql, sql: "SELECT * FROM providerConfig")))
    }
  }

  private func assertRows(_ before: (Row, Row, Row), equal after: (Row, Row, Row),
    exceptJournal: Bool = false, file: StaticString = #filePath, line: UInt = #line) {
    for (index, pair) in [(before.0, after.0), (before.1, after.1), (before.2, after.2)].enumerated() {
      XCTAssertEqual(Array(pair.0.columnNames), Array(pair.1.columnNames), file: file, line: line)
      for column in pair.0.columnNames where !(exceptJournal && index == 1 && column == "recoveryJournal") {
        let old: DatabaseValue = pair.0[column]
        let new: DatabaseValue = pair.1[column]
        XCTAssertEqual(old, new, column, file: file, line: line)
      }
    }
  }

  func testDeletingHistoryRetainsExactTerminalCauseResultAndCleanupAcrossReopen() throws {
    for cause in ["succeeded", "importFailed", "urlImportFailed", "sourceChanged",
      "publicationRejected", "cancelled", "interrupted", "paperDeleting"] {
      let (root, db, id, saga, initial, _) = try deletingFixture(cause: cause)
      defer { try? FileManager.default.removeItem(at: root) }
      let before = try actualRows(db)
      let original = try initial.journal.snapshot()
      XCTAssertTrue(original.revoked)
      if cause == "succeeded" {
        XCTAssertEqual(original.current.state, .succeeded)
        XCTAssertEqual(original.current.result?.id, "synthetic-published-result")
        XCTAssertEqual(original.usableResult?.result, original.current.result)
      } else {
        XCTAssertEqual(original.current.state, .failed(cause == "interrupted" ? .interrupted :
          cause == "paperDeleting" ? .paperDeleting : .failed))
      }
      XCTAssertEqual(try readDeleting(id, saga: saga, db: db).encoded, initial.encoded)
      assertError(.invalidHistory) { _ = try read(id, db: db) }
      let observation = try initial.journal.recording(.authorityChanged(original.authority))
      assertError(.invalidHistory) { _ = try cas(initial.encoded, observation, db: db) }
      var record = initial
      let permit = try XCTUnwrap(original.permits.first)
      if permit.closure == .unknown {
        let replacement = try record.journal.recording(.writerClosure(permit.owner, permit: permit.id,
          .closed(.unvalidated)))
        record = try casDeleting(record.encoded, replacement, saga: saga, db: db)
      }
      // Retain both a failed cleanup invocation and its distinct fresh retry ID.
      // Committed publication bytes instead belong to the retained result: release
      // the committed permit, never manufacture failed-stage cleanup for success.
      for succeeded in (cause == "succeeded" ? [] : [false, true]) {
        let operation = UUID().uuidString
        let requested = try record.journal.recording(.requestCleanup(permit.owner, permit: permit.id,
          operation: operation))
        record = try casDeleting(record.encoded, requested, saga: saga, db: db)
        let pending = try XCTUnwrap(record.journal.snapshot().permits.first?.cleanupOperation)
        XCTAssertEqual(pending.id, operation)
        XCTAssertEqual(try readDeleting(id, saga: saga, db: ProductDatabase.open(at: root)).encoded, record.encoded)
        let finished = try record.journal.recording(.cleanupFinished(permit.owner, permit: permit.id,
          operation: pending, succeeded: succeeded))
        record = try casDeleting(record.encoded, finished, saga: saga, db: db)
      }
      record = try casDeleting(record.encoded,
        record.journal.recording(.release(permit.owner, permit: permit.id)), saga: saga, db: db)
      record = try casDeleting(record.encoded,
        record.journal.recording(.removeNamespace(operation: UUID().uuidString)), saga: saga, db: db)
      let removal = try XCTUnwrap(record.journal.snapshot().pendingRemoval)
      record = try casDeleting(record.encoded,
        record.journal.recording(.namespaceRemovalFinished(operation: removal, succeeded: true)), saga: saga, db: db)
      let reopened = try ProductDatabase.open(at: root)
      let restored = try readDeleting(id, saga: saga, db: reopened)
      XCTAssertEqual(restored.encoded, record.encoded)
      let final = try restored.journal.snapshot()
      XCTAssertEqual(final, try record.journal.snapshot())
      XCTAssertEqual(final.executions, original.executions)
      XCTAssertEqual(final.usableResult, original.usableResult)
      XCTAssertEqual(final.usedPermitIDs, original.usedPermitIDs)
      XCTAssertEqual(final.usedOperationIDs.count, cause == "succeeded" ? 1 : 3)
      XCTAssertTrue(final.permits.isEmpty)
      XCTAssertTrue(final.namespaceRemoved)
      assertRows(before, equal: try actualRows(reopened), exceptJournal: true)
      assertError(.invalidHistory) { _ = try read(id, db: reopened) }
    }
  }

  func testDeletingReadRejectsWrongSagaAndEveryCapturedIdentityDrift() throws {
    let (root, db, id, saga, record, _) = try deletingFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    assertError(.invalidHistory) { _ = try readDeleting(id, saga: UUID(), db: db) }
    for column in 0..<10 {
      XCTAssertThrowsError(try readDeleting(changing(id, column: column), saga: saga, db: db))
    }
    for value in [saga.uuidString.lowercased(), "malformed", UUID().uuidString] {
      try db.adapterWrite { try $0.execute(sql: "UPDATE paper SET deletionID = ?", arguments: [value]) }
      assertError(.invalidHistory) { _ = try readDeleting(id, saga: saga, db: db) }
    }
    try db.adapterWrite { try $0.execute(sql: "UPDATE paper SET deletionID = ?", arguments: [saga.uuidString]) }
    try db.adapterWrite { sql in
      try sql.execute(sql: "UPDATE importJob SET id = ?", arguments: [UUID().uuidString])
      assertError(.missingHistory) { _ = try ProductDatabase.readImportRecoveryForDeletion(id,
        saga: saga, maximumBytes: bound, in: sql) }
      try sql.execute(sql: "UPDATE importJob SET id = ?", arguments: [id.jobID.uuidString])
      let other = UUID().uuidString
      try sql.execute(sql: """
        INSERT INTO paper (id, generation, title, status, createdAt, deletionID)
        VALUES (?, ?, 'Other synthetic owner', 'deleting', 0, ?)
        """, arguments: [other, id.generation.uuidString, saga.uuidString])
      try sql.execute(sql: "UPDATE importJob SET paperID = ?", arguments: [other])
      assertError(.staleHistory) { _ = try ProductDatabase.readImportRecoveryForDeletion(id,
        saga: saga, maximumBytes: bound, in: sql) }
      try sql.execute(sql: "UPDATE importJob SET paperID = ?", arguments: [id.paperID.uuidString])
      try sql.execute(sql: "DELETE FROM paper WHERE id = ?", arguments: [other])
    }
    for (table, column, value) in [("paper", "generation", id.generation.uuidString),
      ("importJob", "attempt", id.attempt.uuidString), ("importJob", "fence", id.fence.uuidString),
      ("importJob", "correlation", id.correlation.uuidString), ("importJob", "input", id.input.uuidString),
      ("importJob", "epoch", id.epoch.uuidString), ("importJob", "writer", id.writer.uuidString),
      ("importJob", "publication", id.publication.uuidString)] {
      for drift in [UUID().uuidString, "malformed", value.lowercased()] {
        try db.adapterWrite { try $0.execute(sql: "UPDATE \(table) SET \(column) = ?", arguments: [drift]) }
        XCTAssertThrowsError(try readDeleting(id, saga: saga, db: db), column)
      }
      try db.adapterWrite { try $0.execute(sql: "UPDATE \(table) SET \(column) = ?", arguments: [value]) }
    }
    XCTAssertEqual(try readDeleting(id, saga: saga, db: db).encoded, record.encoded)
  }

  func testDeletingReadRejectsStatesCausesAndIneligiblePayloadWithoutFallback() throws {
    for cause in ["succeeded", "importFailed", "interrupted", "paperDeleting"] {
      let (root, db, id, saga, record, unrevoked) = try deletingFixture(cause: cause)
      defer { try? FileManager.default.removeItem(at: root) }
      let observation = try record.journal.recording(.authorityChanged(record.journal.snapshot().authority))
      for status in ["importing", "ready", "importFailed", "deletionFailed", "tombstone", "unknown"] {
        try db.adapterWrite { try $0.execute(sql: "UPDATE paper SET status = ?", arguments: [status]) }
        assertError(.invalidHistory) { _ = try readDeleting(id, saga: saga, db: db) }
        assertError(.invalidHistory) { _ = try casDeleting(record.encoded, observation, saga: saga, db: db) }
      }
      try db.adapterWrite { try $0.execute(sql: "UPDATE paper SET status = 'deleting', deletionID = NULL") }
      assertError(.invalidHistory) { _ = try readDeleting(id, saga: saga, db: db) }
      try db.adapterWrite { try $0.execute(sql: "UPDATE paper SET deletionID = ?", arguments: [saga.uuidString]) }
      for state in ["pending", "running", "unknown", cause == "succeeded" ? "failed" : "succeeded"] {
        try db.adapterWrite { try $0.execute(sql: "UPDATE importJob SET state = ?", arguments: [state]) }
        assertError(.invalidHistory) { _ = try readDeleting(id, saga: saga, db: db) }
        assertError(.invalidHistory) { _ = try casDeleting(record.encoded, observation, saga: saga, db: db) }
      }
      try db.adapterWrite { try $0.execute(sql: "UPDATE importJob SET state = ?",
        arguments: [cause == "succeeded" ? "succeeded" : "failed"]) }
      for failure in ["unknown", "failed", "timeout", "deletionIncomplete",
        cause == "paperDeleting" ? "importFailed" : "paperDeleting"] {
        try db.adapterWrite { try $0.execute(sql: "UPDATE importJob SET failure = ?", arguments: [failure]) }
        assertError(.invalidHistory) { _ = try readDeleting(id, saga: saga, db: db) }
        assertError(.invalidHistory) { _ = try casDeleting(record.encoded, observation, saga: saga, db: db) }
      }
      if cause != "succeeded" {
        try db.adapterWrite { try $0.execute(sql: "UPDATE importJob SET failure = NULL") }
        assertError(.invalidHistory) { _ = try readDeleting(id, saga: saga, db: db) }
      }
      try db.adapterWrite { try $0.execute(sql: "UPDATE importJob SET failure = ?",
        arguments: [cause == "succeeded" ? nil : cause]) }
      for payload in [Data(), Data([0]), Data(record.encoded.dropLast()), Data([0x20]) + record.encoded,
        Data(repeating: 0, count: bound + 1), try unrevoked.encoded(maximumBytes: bound)] {
        try db.adapterWrite { try $0.execute(sql: "UPDATE importJob SET recoveryJournal = ?", arguments: [payload]) }
        assertError(.invalidHistory) { _ = try readDeleting(id, saga: saga, db: db) }
        assertError(.invalidHistory) { _ = try casDeleting(record.encoded, observation, saga: saga, db: db) }
      }
      for payload in ["'text-not-BLOB'", "42", "NULL"] {
        try db.adapterWrite { try $0.execute(sql: "UPDATE importJob SET recoveryJournal = \(payload)") }
        assertError(payload == "NULL" ? .missingHistory : .invalidHistory) {
          _ = try readDeleting(id, saga: saga, db: db)
        }
        assertError(payload == "NULL" ? .missingHistory : .invalidHistory) {
          _ = try casDeleting(record.encoded, observation, saga: saga, db: db)
        }
      }
      try db.adapterWrite { try $0.execute(sql: "UPDATE importJob SET recoveryJournal = ?", arguments: [record.encoded]) }
      assertError(.invalidHistory) { _ = try readDeleting(id, saga: saga, db: db, maximumBytes: record.encoded.count - 1) }
      XCTAssertEqual(try readDeleting(id, saga: saga, db: db, maximumBytes: record.encoded.count).encoded, record.encoded)
    }
    // Existing actual cancellation code maps to policy .failed, not its similarly
    // named enum case. No existing fixed actual timeout code is synthesized.
    for (code, policy) in [("cancelled", JobRecoveryPolicy.Failure.cancelled), ("timeout", .timeout)] {
      let (root, db, id, saga, record, _) = try deletingFixture(cause: code, policyFailure: policy)
      defer { try? FileManager.default.removeItem(at: root) }
      let observation = try record.journal.recording(.authorityChanged(record.journal.snapshot().authority))
      assertError(.invalidHistory) { _ = try readDeleting(id, saga: saga, db: db) }
      assertError(.invalidHistory) { _ = try casDeleting(record.encoded, observation, saga: saga, db: db) }
    }
  }

  func testDeletingBoundsAreValidatedBeforeAnySQLAndCASRejectsNonExtensionsAndRetry() throws {
    let (root, db, id, saga, record, unrevoked) = try deletingFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let observation = try record.journal.recording(.authorityChanged(record.journal.snapshot().authority))
    try db.adapterWrite { sql in
      try sql.execute(sql: "ALTER TABLE importJob RENAME TO hiddenImportJob")
      for maximum in [0, -1] {
        assertError(.invalidHistory) { _ = try ProductDatabase.readImportRecoveryForDeletion(id,
          saga: saga, maximumBytes: maximum, in: sql) }
        assertError(.invalidHistory) { _ = try ProductDatabase.compareAndSwapImportRecoveryForDeletion(
          expected: record.encoded, replacement: observation, saga: saga, maximumBytes: maximum, in: sql) }
      }
      assertError(.invalidHistory) { _ = try ProductDatabase.compareAndSwapImportRecoveryForDeletion(
        expected: record.encoded, replacement: observation, saga: saga, maximumBytes: 1, in: sql) }
      try sql.execute(sql: "ALTER TABLE hiddenImportJob RENAME TO importJob")
    }
    for replacement in [record.journal, unrevoked,
      try unrevoked.recording(.authorityChanged(unrevoked.snapshot().authority)).recording(.revoke),
      try ImportRecoveryJournal(identity: id, confirmedInput: .init(expectedSHA256: String(repeating: "b", count: 64),
        destinationFolderID: nil)).recording(.revoke),
      try ImportRecoveryJournal(identity: changing(id, column: 7), confirmedInput: facts).recording(.revoke)] {
      assertError(.invalidHistory) { _ = try casDeleting(record.encoded, replacement, saga: saga, db: db) }
    }
    for expected in [Data(), Data(record.encoded.dropLast()), Data([0x20]) + record.encoded,
      Data(repeating: 0, count: bound + 1)] {
      assertError(.invalidHistory) { _ = try casDeleting(expected, observation, saga: saga, db: db) }
    }
    assertError(.invalidHistory) { _ = try casDeleting(record.encoded, observation, saga: saga,
      db: db, maximumBytes: record.encoded.count) }
    assertError(.invalidHistory) { _ = try casDeleting(record.encoded, observation, saga: UUID(), db: db) }
    let initial = try ImportRecoveryJournal(identity: id, confirmedInput: facts)
    let failed = try initial.recording(.claim(initial.snapshot().current.lineage))
      .recording(.terminate(initial.snapshot().current.lineage, .failed))
    let next = ImportIdentity(paperID: id.paperID, generation: id.generation, jobID: id.jobID,
      attempt: UUID(), fence: UUID(), correlation: UUID(), input: UUID(), epoch: id.epoch,
      writer: UUID(), publication: UUID())
    let retry = try failed.retrying(identity: next, confirmedInput: facts).recording(.revoke)
    assertError(.invalidHistory) { _ = try casDeleting(record.encoded, retry, saga: saga, db: db) }
    XCTAssertThrowsError(try record.journal.retrying(identity: next, confirmedInput: facts))
    let exactBound = try observation.encoded(maximumBytes: bound).count
    let updated = try casDeleting(record.encoded, observation, saga: saga, db: db, maximumBytes: exactBound)
    assertError(.staleHistory) { _ = try casDeleting(record.encoded, observation, saga: saga, db: db) }
    XCTAssertEqual(try readDeleting(id, saga: saga, db: ProductDatabase.open(at: root)).encoded, updated.encoded)
  }

  func testDeletingCASIgnoredCorruptAndEveryUnrelatedColumnTriggerRollsBackCallerAndReopens() throws {
    let mutations = ["ignore", "corrupt", "oversize", "text",
      "paper:title = 'mutated'", "paper:createdAt = 999", "paper:cleanupDebt = 0",
      "paper:pdfReference = 'mutated'", "paper:pdfSHA256 = 'mutated'",
      "paper:deletionFailure = 'mutated'", "paper:deletionID = 'mutated'",
      "paper:status = 'deletionFailed'", "paper:generation = 'mutated'",
      "importJob:bytesCopied = 999", "importJob:failure = 'mutated'", "importJob:state = 'running'",
      "importJob:id = 'mutated'",
      "importJob:attempt = 'mutated'", "importJob:fence = 'mutated'", "importJob:correlation = 'mutated'",
      "importJob:input = 'mutated'", "importJob:epoch = 'mutated'", "importJob:writer = 'mutated'",
      "importJob:publication = 'mutated'"]
    for mutation in mutations {
      let (root, db, id, saga, record, _) = try deletingFixture()
      defer { try? FileManager.default.removeItem(at: root) }
      let before = try actualRows(db)
      let replacement = try record.journal.recording(.authorityChanged(record.journal.snapshot().authority))
      try db.adapterWrite { sql in
        let action: String
        switch mutation {
        case "ignore": action = "SELECT RAISE(IGNORE);"
        case "corrupt": action = "UPDATE importJob SET recoveryJournal = X'00';"
        case "oversize": action = "UPDATE importJob SET recoveryJournal = zeroblob(\(bound + 1));"
        case "text": action = "UPDATE importJob SET recoveryJournal = 'text';"
        default:
          let parts = mutation.split(separator: ":", maxSplits: 1)
          action = "UPDATE \(parts[0]) SET \(parts[1]);"
        }
        try sql.execute(sql: "CREATE TRIGGER denyDeleting \(mutation == "ignore" ? "BEFORE" : "AFTER") UPDATE OF recoveryJournal ON importJob BEGIN \(action) END")
      }
      XCTAssertThrowsError(try db.adapterWrite { sql in
        try sql.execute(sql: "UPDATE providerConfig SET generation = generation + 1, model = 'caller-mutated'")
        _ = try ProductDatabase.compareAndSwapImportRecoveryForDeletion(expected: record.encoded,
          replacement: replacement, saga: saga, maximumBytes: bound, in: sql)
      }, mutation)
      let reopened = try ProductDatabase.open(at: root)
      assertRows(before, equal: try actualRows(reopened))
      XCTAssertEqual(try readDeleting(id, saga: saga, db: reopened).encoded, record.encoded)
    }
  }

  // Actual command fixtures use synthetic terminal observations, never closure ACKs.
  private func deletionCommandFixture(cause: String = "running") throws
    -> (URL, ProductDatabase, ImportIdentity, ImportRecoveryRecord) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let db = try ProductDatabase.open(at: root)
    let id = identity()
    var record = try db.reserveJournaledImport(id, title: "Actual deletion command", confirmedInput: facts)
    if cause == "paperDeleting" {
      let saga = try XCTUnwrap(db.beginDeletion(id.paperID))
      return (root, db, id, try readDeleting(id, saga: saga, db: db))
    }
    let lineage = try record.journal.snapshot().current.lineage
    if cause == "succeeded" {
      let result = JobRecoveryPolicy.Result(id: "synthetic-command-result")
      for event in [JobRecoveryPolicy.Event.writerClosure(lineage, permit: id.writer.uuidString,
        .closed(.validated(result))),
        .acquirePublication(lineage, writer: id.writer.uuidString, permit: id.publication.uuidString),
        .rename(lineage, permit: id.publication.uuidString),
        .renameFinished(lineage, permit: id.publication.uuidString, succeeded: true),
        .publish(lineage, permit: id.publication.uuidString, result)] {
        record = try append(event, to: record, db: db)
      }
    } else if cause == "interrupted" {
      record = try append(.startup(currentEpoch: UUID().uuidString), to: record, db: db)
    } else if cause != "running" {
      record = try append(.terminate(lineage, .failed), to: record, db: db)
    }
    if cause != "running" {
      try db.adapterWrite { sql in
        try sql.execute(sql: "UPDATE importJob SET state = ?, failure = ?, bytesCopied = 17",
          arguments: [cause == "succeeded" ? "succeeded" : "failed", cause == "succeeded" ? nil : cause])
        try sql.execute(sql: "UPDATE paper SET status = ?, pdfReference = ?",
          arguments: [cause == "succeeded" ? "ready" : "importFailed",
            cause == "succeeded" ? "papers/\(id.paperID.uuidString)/document.pdf" : nil])
      }
    }
    return (root, db, id, record)
  }

  func testActualBeginDeletionRevokesRunningAndPreservesEveryTerminalCauseAcrossRetries() throws {
    for cause in ["running", "succeeded", "importFailed", "urlImportFailed", "sourceChanged",
      "publicationRejected", "cancelled", "interrupted", "paperDeleting"] {
      let (root, db, id, original) = try deletionCommandFixture(cause: cause)
      defer { try? FileManager.default.removeItem(at: root) }
      let before = try actualRows(db)
      let expected = try original.journal.recording(.revoke)
      let saga = try XCTUnwrap(db.beginDeletion(id.paperID))
      var record = try readDeleting(id, saga: saga, db: db)
      XCTAssertEqual(record.encoded, try expected.encoded(maximumBytes: bound))
      XCTAssertTrue(try record.journal.extends(original.journal, maximumBytes: bound))
      let after = try actualRows(db)
      XCTAssertEqual(String.fromDatabaseValue(after.0["status"]), "deleting")
      XCTAssertEqual(String.fromDatabaseValue(after.0["deletionID"]), saga.uuidString)
      XCTAssertTrue((after.0["pdfReference"] as DatabaseValue).isNull)
      XCTAssertTrue((after.0["deletionFailure"] as DatabaseValue).isNull)
      for column in before.0.columnNames where !["status", "deletionID", "pdfReference", "deletionFailure"].contains(column) {
        let old: DatabaseValue = before.0[column]
        let new: DatabaseValue = after.0[column]
        XCTAssertEqual(old, new, column)
      }
      XCTAssertEqual(String.fromDatabaseValue(after.1["state"]), cause == "running" ? "failed" :
        cause == "succeeded" ? "succeeded" : "failed")
      XCTAssertEqual(String.fromDatabaseValue(after.1["failure"]), cause == "running" ? "paperDeleting" :
        cause == "succeeded" ? nil : cause)
      for column in before.1.columnNames where !["state", "failure", "recoveryJournal"].contains(column) {
        let old: DatabaseValue = before.1[column]
        let new: DatabaseValue = after.1[column]
        XCTAssertEqual(old, new, column)
      }
      if cause != "running" {
        XCTAssertEqual(try record.journal.snapshot().executions, try original.journal.snapshot().executions)
        XCTAssertEqual(try record.journal.snapshot().usableResult, try original.journal.snapshot().usableResult)
      }
      for failed in [false, true] {
        if failed { try db.deletionFailed(id.paperID, saga: saga, reason: "deletionIncomplete") }
        let prior = record
        XCTAssertEqual(try db.beginDeletion(id.paperID), saga)
        record = try readDeleting(id, saga: saga, db: ProductDatabase.open(at: root))
        XCTAssertEqual(record.encoded, try prior.journal.recording(.revoke).encoded(maximumBytes: bound))
        XCTAssertTrue(try record.journal.extends(prior.journal, maximumBytes: bound))
        XCTAssertEqual(try record.journal.snapshot(), try prior.journal.snapshot())
        XCTAssertNotEqual(record.encoded, prior.encoded)
      }
      try db.finalizeDeletion(id.paperID, saga: saga)
      let reopened = try ProductDatabase.open(at: root)
      XCTAssertEqual(try reopened.adapterRead { try Int.fetchOne($0, sql: "SELECT count(*) FROM importJob") }, 0)
      let tombstone = try reopened.adapterRead { try XCTUnwrap(Row.fetchOne($0, sql: "SELECT * FROM paper")) }
      XCTAssertEqual(String.fromDatabaseValue(tombstone["status"]), "tombstone")
      XCTAssertEqual(String.fromDatabaseValue(tombstone["title"]), "")
      XCTAssertTrue((tombstone["pdfReference"] as DatabaseValue).isNull)
      XCTAssertTrue((tombstone["pdfSHA256"] as DatabaseValue).isNull)
      XCTAssertTrue((tombstone["deletionFailure"] as DatabaseValue).isNull)
    }
  }

  func testActualBeginDeletionLegacyNullRemainsIneligibleAcrossRetryAndReopen() throws {
    let (root, db, id, _) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let saga = try XCTUnwrap(db.beginDeletion(id.paperID))
    try db.deletionFailed(id.paperID, saga: saga, reason: "agentClosureUnproved")
    XCTAssertEqual(try db.beginDeletion(id.paperID), saga)
    let reopened = try ProductDatabase.open(at: root)
    XCTAssertTrue((try actualRows(reopened).1["recoveryJournal"] as DatabaseValue).isNull)
    assertError(.missingHistory) { _ = try readDeleting(id, saga: saga, db: reopened) }
  }

  func testActualBeginDeletionRejectsAllTenCapturedIdentityDriftsWithoutEffects() throws {
    let (root, db, id, original) = try deletionCommandFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    for column in 0..<10 {
      let wrong = changing(id, column: column)
      let initial = try ImportRecoveryJournal(identity: wrong, confirmedInput: facts)
      let bytes = try initial.recording(.claim(initial.snapshot().current.lineage)).encoded(maximumBytes: bound)
      try db.adapterWrite { try $0.execute(sql: "UPDATE importJob SET recoveryJournal = ?", arguments: [bytes]) }
      let before = try actualRows(db)
      XCTAssertThrowsError(try db.beginDeletion(id.paperID))
      assertRows(before, equal: try actualRows(ProductDatabase.open(at: root)))
    }
    try db.adapterWrite { try $0.execute(sql: "UPDATE importJob SET recoveryJournal = ?", arguments: [original.encoded]) }
    XCTAssertNotNil(try db.beginDeletion(id.paperID))
  }

  func testActualBeginDeletionInvalidPayloadStateCauseAndPriorSagaRollBack() throws {
    let mutations = ["recoveryJournal = X'00'", "recoveryJournal = 'text'",
      "recoveryJournal = zeroblob(262145)", "recoveryJournal = X''",
      "state = 'pending'", "state = 'succeeded'", "state = 'failed', failure = 'timeout'",
      "failure = 'unexpected'"]
    for mutation in mutations {
      let (root, db, id, _) = try deletionCommandFixture()
      defer { try? FileManager.default.removeItem(at: root) }
      try db.adapterWrite { try $0.execute(sql: "UPDATE importJob SET \(mutation)") }
      let before = try actualRows(db)
      XCTAssertThrowsError(try db.beginDeletion(id.paperID), mutation)
      assertRows(before, equal: try actualRows(ProductDatabase.open(at: root)))
    }
    for status in ["deleting", "deletionFailed"] {
      let (root, db, id, _) = try deletionCommandFixture(cause: "importFailed")
      defer { try? FileManager.default.removeItem(at: root) }
      try db.adapterWrite { try $0.execute(sql: "UPDATE paper SET status = ?, deletionID = ?",
        arguments: [status, UUID().uuidString]) }
      let before = try actualRows(db)
      XCTAssertThrowsError(try db.beginDeletion(id.paperID))
      assertRows(before, equal: try actualRows(ProductDatabase.open(at: root)))
    }
    for cause in ["timeout", "unknown", "cancelled"] {
      let (root, db, id, _) = try deletionCommandFixture(cause: cause)
      defer { try? FileManager.default.removeItem(at: root) }
      if cause == "cancelled" {
        let initial = try ImportRecoveryJournal(identity: id, confirmedInput: facts)
        let wrong = try initial.recording(.claim(initial.snapshot().current.lineage))
          .recording(.terminate(initial.snapshot().current.lineage, .cancelled))
        try db.adapterWrite { try $0.execute(sql: "UPDATE importJob SET recoveryJournal = ?",
          arguments: [try wrong.encoded(maximumBytes: bound)]) }
      }
      let before = try actualRows(db)
      XCTAssertThrowsError(try db.beginDeletion(id.paperID))
      assertRows(before, equal: try actualRows(ProductDatabase.open(at: root)))
    }
  }

  func testActualBeginDeletionCanonicalPendingAndRevocationQuotaRejectWithoutEffects() throws {
    let (root, db, id, _) = try deletionCommandFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let pending = try ImportRecoveryJournal(identity: id, confirmedInput: facts)
    try db.adapterWrite { sql in
      try sql.execute(sql: "UPDATE importJob SET state = 'pending', recoveryJournal = ?",
        arguments: [try pending.encoded(maximumBytes: bound)])
    }
    let before = try actualRows(db)
    XCTAssertThrowsError(try db.beginDeletion(id.paperID))
    assertRows(before, equal: try actualRows(ProductDatabase.open(at: root)))

    let (quotaRoot, quotaDB, quotaID, _) = try deletionCommandFixture()
    defer { try? FileManager.default.removeItem(at: quotaRoot) }
    let saga = try XCTUnwrap(quotaDB.beginDeletion(quotaID.paperID))
    let record = try readDeleting(quotaID, saga: saga, db: quotaDB)
    let next = try record.journal.recording(.revoke).encoded(maximumBytes: bound)
    let increment = next.count - record.encoded.count
    XCTAssertGreaterThan(increment, 0)
    // Efficiently construct only genuine repeated revoke events, then demand
    // canonical decoding/replay before installing this metadata quota fixture.
    var document = try XCTUnwrap(JSONSerialization.jsonObject(with: record.encoded) as? [String: Any])
    var events = try XCTUnwrap(document["events"] as? [Any])
    let revoke = try XCTUnwrap(events.last)
    events += Array(repeating: revoke, count: (bound - record.encoded.count) / increment)
    document["events"] = events
    let bytes = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
    let full = try ImportRecoveryJournal.decode(bytes, maximumBytes: bound)
    XCTAssertEqual(try full.encoded(maximumBytes: bound), bytes)
    XCTAssertLessThanOrEqual(bytes.count, bound)
    XCTAssertGreaterThan(bytes.count + increment, bound)
    XCTAssertThrowsError(try full.recording(.revoke).encoded(maximumBytes: bound))
    try quotaDB.adapterWrite { try $0.execute(sql: "UPDATE importJob SET recoveryJournal = ?", arguments: [bytes]) }
    let quotaBefore = try actualRows(quotaDB)
    XCTAssertThrowsError(try quotaDB.beginDeletion(quotaID.paperID))
    assertRows(quotaBefore, equal: try actualRows(ProductDatabase.open(at: quotaRoot)))
    XCTAssertEqual(try readDeleting(quotaID, saga: saga, db: quotaDB).encoded, bytes)
  }

  func testActualBeginDeletionJournalAndOperationalTriggersRollBackWholeCommand() throws {
    let mutations = ["ignore", "corrupt", "oversize", "text",
      "paper:title = 'mutated'", "paper:createdAt = 999", "paper:cleanupDebt = 1",
      "paper:pdfReference = 'mutated'", "paper:pdfSHA256 = 'mutated'",
      "paper:deletionFailure = 'mutated'", "paper:deletionID = 'mutated'",
      "paper:status = 'deletionFailed'", "paper:generation = 'mutated'",
      "importJob:bytesCopied = 999", "importJob:failure = 'mutated'", "importJob:state = 'running'",
      "importJob:id = 'mutated'", "importJob:paperID = 'mutated'",
      "importJob:attempt = 'mutated'", "importJob:fence = 'mutated'", "importJob:correlation = 'mutated'",
      "importJob:input = 'mutated'", "importJob:epoch = 'mutated'", "importJob:writer = 'mutated'",
      "importJob:publication = 'mutated'"]
    for mutation in mutations + ["ignorePaper", "ignoreJob", "operationalCorrupt"] {
      let (root, db, id, _) = try deletionCommandFixture()
      defer { try? FileManager.default.removeItem(at: root) }
      let before = try actualRows(db)
      try db.adapterWrite { sql in
        var table = "importJob"
        var column = "recoveryJournal"
        var timing = mutation == "ignore" ? "BEFORE" : "AFTER"
        let action: String
        switch mutation {
        case "ignore", "ignorePaper", "ignoreJob":
          action = "SELECT RAISE(IGNORE);"
          timing = "BEFORE"
          if mutation == "ignorePaper" { table = "paper"; column = "status" }
          if mutation == "ignoreJob" { column = "state" }
        case "corrupt": action = "UPDATE importJob SET recoveryJournal = X'00';"
        case "oversize": action = "UPDATE importJob SET recoveryJournal = zeroblob(262145);"
        case "text": action = "UPDATE importJob SET recoveryJournal = 'text';"
        case "operationalCorrupt":
          column = "state"
          action = "UPDATE importJob SET recoveryJournal = X'00';"
        default:
          let parts = mutation.split(separator: ":", maxSplits: 1)
          action = "UPDATE \(parts[0]) SET \(parts[1]);"
        }
        try sql.execute(sql: "CREATE TRIGGER denyCommand \(timing) UPDATE OF \(column) ON \(table) BEGIN \(action) END")
      }
      XCTAssertThrowsError(try db.beginDeletion(id.paperID), mutation)
      assertRows(before, equal: try actualRows(ProductDatabase.open(at: root)))
    }
  }

  private func ordinaryFailureFixture() throws -> (URL, ProductDatabase, ImportIdentity, ImportRecoveryRecord) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let db = try ProductDatabase.open(at: root)
    let id = identity()
    let record = try db.reserveJournaledImport(id, title: "SYNTHETIC ordinary failure", confirmedInput: facts)
    try db.adapterWrite { sql in
      try sql.execute(sql: "UPDATE importJob SET bytesCopied = 37")
      try sql.execute(sql: "UPDATE providerConfig SET generation = 7, model = 'baseline'")
    }
    return (root, db, id, record)
  }

  // SYNTHETIC observations only. This neither opens/closes a writer nor purges bytes.
  private func syntheticCleanFailure(_ record: ImportRecoveryRecord) throws -> ImportRecoveryJournal {
    let l = try record.journal.snapshot().current.lineage
    let writer = try record.journal.currentCapture().identity.writer.uuidString
    var journal = try record.journal.recording(.writerClosure(l, permit: writer, .closed(.unvalidated)))
      .recording(.terminate(l, .failed))
    let permit = try XCTUnwrap(journal.snapshot().permits.first)
    journal = try journal.recording(.requestCleanup(l, permit: permit.id, operation: UUID().uuidString))
    let operation = try XCTUnwrap(journal.snapshot().permits.first?.cleanupOperation)
    return try journal.recording(.cleanupFinished(l, permit: permit.id, operation: operation, succeeded: true))
      .recording(.release(l, permit: permit.id))
  }

  func testOrdinaryJournaledFailureFiveFixedCausesRetainUnknownPermitAndReopenExactRows() throws {
    for cause in [ImportAbortFailure.cancelled, .sourceChanged, .importFailed, .urlImportFailed, .publicationRejected] {
      let (root, db, id, original) = try ordinaryFailureFixture()
      defer { try? FileManager.default.removeItem(at: root) }
      let folder = UUID().uuidString
      try db.adapterWrite { sql in
        try sql.execute(sql: "INSERT INTO libraryFolder(id, name) VALUES (?, 'SYNTHETIC retained folder')", arguments: [folder])
        try sql.execute(sql: "INSERT INTO paperFolder(paperID, folderID) VALUES (?, ?)", arguments: [id.paperID.uuidString, folder])
      }
      let before = try actualRows(db)
      let l = try original.journal.snapshot().current.lineage
      let replacement = try original.journal.recording(.terminate(l, .failed))
      XCTAssertThrowsError(try db.recordJournaledImportFailure(expected: original,
        replacement: replacement, failure: cause, cleanupDebt: false))
      assertRows(before, equal: try actualRows(db))
      let stored = try db.recordJournaledImportFailure(expected: original,
        replacement: replacement, failure: cause, cleanupDebt: true)
      let reopened = try ProductDatabase.open(at: root)
      let readback = try read(id, db: reopened)
      XCTAssertEqual(stored.encoded, try replacement.encoded(maximumBytes: bound))
      XCTAssertEqual(readback.encoded, stored.encoded)
      XCTAssertEqual(try readback.journal.snapshot(), try replacement.snapshot())
      XCTAssertEqual(try readback.journal.snapshot().current.state, .failed(.failed))
      XCTAssertEqual(try readback.journal.snapshot().permits.first?.closure, .unknown)
      XCTAssertEqual(try readback.journal.snapshot().usedPermitIDs, try original.journal.snapshot().usedPermitIDs)
      let after = try actualRows(reopened)
      for column in before.0.columnNames where !["status", "pdfReference", "cleanupDebt"].contains(column) {
        XCTAssertEqual(before.0[column] as DatabaseValue, after.0[column] as DatabaseValue, column)
      }
      for column in before.1.columnNames where !["state", "failure", "recoveryJournal"].contains(column) {
        XCTAssertEqual(before.1[column] as DatabaseValue, after.1[column] as DatabaseValue, column)
      }
      XCTAssertEqual(String.fromDatabaseValue(after.0["status"]), "importFailed")
      XCTAssertEqual(Int64.fromDatabaseValue(after.0["cleanupDebt"]), 1)
      XCTAssertEqual(String.fromDatabaseValue(after.1["failure"]), cause.rawValue)
      XCTAssertEqual(String.fromDatabaseValue(after.1["state"]), "failed")
      XCTAssertEqual(Int64.fromDatabaseValue(after.1["bytesCopied"]), 37)
      XCTAssertEqual(try reopened.adapterRead { try String.fetchOne($0, sql: "SELECT folderID FROM paperFolder WHERE paperID = ?", arguments: [id.paperID.uuidString]) }, folder)
    }
  }

  func testOrdinaryJournaledFailureSyntheticCleanAllowsFalseButPreservesExistingDebt() throws {
    for existingDebt in [0, 1] {
      for requestedDebt in [false, true] {
        let (root, db, id, record) = try ordinaryFailureFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try db.adapterWrite { try $0.execute(sql: "UPDATE paper SET cleanupDebt = ?", arguments: [existingDebt]) }
        let replacement = try syntheticCleanFailure(record)
        let stored = try db.recordJournaledImportFailure(expected: record, replacement: replacement,
          failure: .cancelled, cleanupDebt: requestedDebt)
        let reopened = try ProductDatabase.open(at: root)
        XCTAssertEqual(try read(id, db: reopened).encoded, stored.encoded)
        XCTAssertEqual(try read(id, db: reopened).journal.snapshot(), try replacement.snapshot())
        XCTAssertTrue(try replacement.snapshot().permits.isEmpty)
        XCTAssertEqual(Int64.fromDatabaseValue(try actualRows(reopened).0["cleanupDebt"]),
          existingDebt == 1 || requestedDebt ? 1 : 0)
      }
    }
  }

  func testOrdinaryJournaledFailureRejectsExpectedBytesPrefixCapturePolicyPermitRetryAndQuotaBeforeEffects() throws {
    let (root, db, id, record) = try ordinaryFailureFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let before = try actualRows(db)
    let l = try record.journal.snapshot().current.lineage
    let failed = try record.journal.recording(.terminate(l, .failed))
    for bytes in [Data(), Data(record.encoded.dropLast()), Data([0x20]) + record.encoded,
      Data(repeating: 0, count: bound + 1)] {
      assertError(.invalidHistory) {
        _ = try db.recordJournaledImportFailure(expected: .init(journal: record.journal, encoded: bytes),
          replacement: failed, failure: .importFailed, cleanupDebt: true)
      }
    }
    let initial = try ImportRecoveryJournal(identity: id, confirmedInput: facts)
    let claimed = try initial.recording(.claim(l))
    let divergent = try claimed.recording(.authorityChanged(claimed.snapshot().authority))
      .recording(.acquireWriter(l, permit: id.writer.uuidString)).recording(.terminate(l, .failed))
    let added = try record.journal.recording(.writerClosure(l, permit: id.writer.uuidString,
      .closed(.validated(.init(id: "SYNTHETIC added-permit observation")))))
      .recording(.acquirePublication(l, writer: id.writer.uuidString, permit: id.publication.uuidString))
      .recording(.terminate(l, .failed))
    let clean = try syntheticCleanFailure(record)
    let retryID = ImportIdentity(paperID: id.paperID, generation: id.generation, jobID: id.jobID,
      attempt: UUID(), fence: UUID(), correlation: UUID(), input: UUID(), epoch: id.epoch,
      writer: UUID(), publication: UUID())
    let retried = try clean.retrying(identity: retryID, confirmedInput: facts)
    let nextLineage = try retried.snapshot().current.lineage
    let retryFailure = try retried.recording(.claim(nextLineage)).recording(.terminate(nextLineage, .failed))
    var replacements = [record.journal, claimed, divergent, added, retryFailure,
      try record.journal.recording(.authorityChanged(record.journal.snapshot().authority)),
      try record.journal.recording(.dispatch(l)).recording(.terminate(l, .failed)),
      try record.journal.recording(.terminate(l, .cancelled)),
      try record.journal.recording(.terminate(l, .timeout)),
      try record.journal.recording(.startup(currentEpoch: UUID().uuidString)),
      try record.journal.recording(.revoke),
      try clean.recording(.revoke).recording(.removeNamespace(operation: UUID().uuidString))]
    for column in 0..<10 {
      let other = try ImportRecoveryJournal(identity: changing(id, column: column), confirmedInput: facts)
      let otherL = try other.snapshot().current.lineage
      replacements.append(try other.recording(.claim(otherL)).recording(.terminate(otherL, .failed)))
    }
    for changedFacts in [ImportRecoveryJournal.ConfirmedInput(expectedSHA256: String(repeating: "a", count: 64), destinationFolderID: nil),
      .init(expectedSHA256: nil, destinationFolderID: UUID())] {
      replacements.append(try ImportRecoveryJournal(identity: id, confirmedInput: changedFacts)
        .recording(.claim(l)).recording(.terminate(l, .failed)))
    }
    let result = JobRecoveryPolicy.Result(id: "SYNTHETIC forbidden publication")
    let publishing = try record.journal.recording(.writerClosure(l, permit: id.writer.uuidString, .closed(.validated(result))))
      .recording(.acquirePublication(l, writer: id.writer.uuidString, permit: id.publication.uuidString))
      .recording(.rename(l, permit: id.publication.uuidString))
      .recording(.renameFinished(l, permit: id.publication.uuidString, succeeded: true))
      .recording(.publish(l, permit: id.publication.uuidString, result))
    replacements.append(publishing)
    var oversized = record.journal
    while try oversized.encoded(maximumBytes: Int.max).count <= bound {
      oversized = try oversized.recording(.authorityChanged(oversized.snapshot().authority))
    }
    replacements.append(try oversized.recording(.terminate(l, .failed)))
    for replacement in replacements {
      XCTAssertThrowsError(try db.recordJournaledImportFailure(expected: record,
        replacement: replacement, failure: .importFailed, cleanupDebt: true))
      assertRows(before, equal: try actualRows(db))
    }
    let advanced = try db.appendJournaledImport(expected: record,
      replacement: record.journal.recording(.authorityChanged(record.journal.snapshot().authority)))
    let advancedRows = try actualRows(db)
    assertError(.staleHistory) { _ = try db.recordJournaledImportFailure(expected: record,
      replacement: failed, failure: .importFailed, cleanupDebt: true) }
    assertRows(advancedRows, equal: try actualRows(ProductDatabase.open(at: root)))
    XCTAssertEqual(try read(id, db: db).encoded, advanced.encoded)
  }

  func testOrdinaryJournaledFailureRejectsLegacyNullStoredPayloadAndOperationalCaptureDrift() throws {
    let (legacyRoot, legacyDB, _, legacyClaimed) = try fixture()
    defer { try? FileManager.default.removeItem(at: legacyRoot) }
    let legacyExpected = ImportRecoveryRecord(journal: legacyClaimed,
      encoded: try legacyClaimed.encoded(maximumBytes: bound))
    let legacyBefore = try actualRows(legacyDB)
    assertError(.missingHistory) {
      _ = try legacyDB.recordJournaledImportFailure(expected: legacyExpected,
        replacement: legacyClaimed.recording(.terminate(legacyClaimed.snapshot().current.lineage, .failed)),
        failure: .importFailed, cleanupDebt: true)
    }
    assertRows(legacyBefore, equal: try actualRows(ProductDatabase.open(at: legacyRoot)))
    let mutations = ["paper:status = 'deleting'", "paper:status = 'ready'", "paper:deletionID = 'invalid'",
      "importJob:state = 'pending'", "importJob:state = 'failed'", "importJob:failure = 'cancelled'",
      "importJob:recoveryJournal = NULL", "importJob:recoveryJournal = X'00'",
      "importJob:recoveryJournal = 'text'", "importJob:recoveryJournal = zeroblob(262145)"]
      + ["paper:generation = 'invalid'"]
      + ["attempt", "fence", "correlation", "input", "epoch", "writer", "publication"].map { "importJob:\($0) = 'invalid'" }
    for mutation in mutations {
      let (root, db, _, record) = try ordinaryFailureFixture()
      defer { try? FileManager.default.removeItem(at: root) }
      let parts = mutation.split(separator: ":", maxSplits: 1)
      try db.adapterWrite { try $0.execute(sql: "UPDATE \(parts[0]) SET \(parts[1])") }
      let before = try actualRows(db)
      let replacement = try record.journal.recording(.terminate(record.journal.snapshot().current.lineage, .failed))
      if mutation.hasSuffix("NULL") {
        assertError(.missingHistory) { _ = try db.recordJournaledImportFailure(expected: record,
          replacement: replacement, failure: .importFailed, cleanupDebt: true) }
      } else {
        XCTAssertThrowsError(try db.recordJournaledImportFailure(expected: record,
          replacement: replacement, failure: .importFailed, cleanupDebt: true), mutation)
      }
      assertRows(before, equal: try actualRows(ProductDatabase.open(at: root)))
    }
  }

  func testOrdinaryJournaledFailureTriggerMutationsRollBackActualWriterAndProviderMarker() throws {
    for mutation in ["ignoreJournal", "ignorePaper", "ignoreJob", "corrupt", "text", "oversize",
      "state", "failure", "operationalCorrupt", "title", "counter", "folder", "provider", "otherRow"] {
      let (root, db, id, record) = try ordinaryFailureFixture()
      defer { try? FileManager.default.removeItem(at: root) }
      let other = UUID().uuidString
      let folder = UUID().uuidString
      try db.adapterWrite { sql in
        try sql.execute(sql: "INSERT INTO paper(id, generation, title, status, createdAt) VALUES (?, ?, 'other', 'importFailed', 0)", arguments: [other, UUID().uuidString])
        try sql.execute(sql: "INSERT INTO libraryFolder(id, name) VALUES (?, 'SYNTHETIC folder')", arguments: [folder])
      }
      let before = try actualRows(db)
      let otherBefore = try db.adapterRead { try Row.fetchOne($0, sql: "SELECT * FROM paper WHERE id = ?", arguments: [other]) }
      try db.adapterWrite { sql in
        var table = "importJob"
        var column = "recoveryJournal"
        var timing = "AFTER"
        let action: String
        switch mutation {
        case "ignoreJournal", "ignorePaper", "ignoreJob":
          timing = "BEFORE"
          if mutation == "ignorePaper" { table = "paper"; column = "status" }
          if mutation == "ignoreJob" { column = "state" }
          action = "SELECT RAISE(IGNORE);"
        case "corrupt": action = "UPDATE importJob SET recoveryJournal = X'00';"
        case "text": action = "UPDATE importJob SET recoveryJournal = 'text';"
        case "oversize": action = "UPDATE importJob SET recoveryJournal = zeroblob(262145);"
        case "state": action = "UPDATE importJob SET state = 'running';"; column = "state"
        case "failure": action = "UPDATE importJob SET failure = 'cancelled';"; column = "state"
        case "operationalCorrupt": action = "UPDATE importJob SET recoveryJournal = X'00';"; column = "state"
        case "title": action = "UPDATE paper SET title = 'drift';"
        case "counter": action = "UPDATE importJob SET bytesCopied = 99;"
        case "folder": action = "INSERT INTO paperFolder(paperID, folderID) VALUES ('\(id.paperID.uuidString)', '\(folder)');"
        case "provider": action = "SELECT 1;"
        default: action = "UPDATE paper SET title = 'foreign drift' WHERE id = '\(other)';"
        }
        // Executed INSIDE the actual method transaction, never a nested adapterWrite.
        try sql.execute(sql: "CREATE TRIGGER abortMutation \(timing) UPDATE OF \(column) ON \(table) BEGIN UPDATE providerConfig SET generation = generation + 1, model = 'transaction-marker'; \(action) END")
      }
      XCTAssertThrowsError(try db.recordJournaledImportFailure(expected: record,
        replacement: record.journal.recording(.terminate(record.journal.snapshot().current.lineage, .failed)),
        failure: .importFailed, cleanupDebt: true), mutation)
      let reopened = try ProductDatabase.open(at: root)
      assertRows(before, equal: try actualRows(reopened))
      let otherAfter = try reopened.adapterRead { try Row.fetchOne($0, sql: "SELECT * FROM paper WHERE id = ?", arguments: [other]) }
      XCTAssertEqual(otherBefore, otherAfter)
      XCTAssertEqual(try read(id, db: reopened).encoded, record.encoded)
      XCTAssertEqual(try reopened.adapterRead { try Int.fetchOne($0, sql: "SELECT count(*) FROM paperFolder") }, 0)
    }
  }

  func testOrdinaryJournaledFailureUnrelatedRowMutationWithoutMarkerIsRejected() throws {
    let (root, db, _, record) = try ordinaryFailureFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let other = UUID().uuidString
    try db.adapterWrite { sql in
      try sql.execute(sql: "INSERT INTO paper(id, generation, title, status, createdAt) VALUES (?, ?, 'other', 'importFailed', 0)", arguments: [other, UUID().uuidString])
      try sql.execute(sql: "CREATE TRIGGER unrelatedMutation AFTER UPDATE OF state ON importJob BEGIN UPDATE paper SET title = 'foreign drift' WHERE id = '\(other)'; END")
    }
    let before = try db.adapterRead { try Row.fetchAll($0, sql: "SELECT * FROM paper ORDER BY id") }
    let rowsBefore = try actualRows(db)
    XCTAssertThrowsError(try db.recordJournaledImportFailure(expected: record,
      replacement: record.journal.recording(.terminate(record.journal.snapshot().current.lineage, .failed)),
      failure: .importFailed, cleanupDebt: true))
    let reopened = try ProductDatabase.open(at: root)
    XCTAssertEqual(before, try reopened.adapterRead { try Row.fetchAll($0, sql: "SELECT * FROM paper ORDER BY id") })
    assertRows(rowsBefore, equal: try actualRows(reopened))
  }

  func testOrdinaryJournaledFailureCompensatingReaderTriggerCannotSubstituteForeignWrites() throws {
    // SYNTHETIC SQL-only attack: one foreign write substitutes the ignored reader
    // UPDATE, leaving total_changes == 4 and both target rows otherwise unchanged.
    for mutation in ["otherPaper", "providerConfig", "delete", "insert", "truncate"] {
      let (root, db, id, record) = try ordinaryFailureFixture()
      defer { try? FileManager.default.removeItem(at: root) }
      let other = UUID().uuidString
      let inserted = UUID().uuidString
      try db.adapterWrite { sql in
        try sql.execute(sql: "INSERT INTO paper(id, generation, title, status, createdAt) VALUES (?, ?, 'SYNTHETIC other', 'importFailed', 0)", arguments: [other, UUID().uuidString])
        try sql.execute(sql: "INSERT INTO libraryFolder(id, name) VALUES (?, 'SYNTHETIC truncate target')", arguments: [other])
        let action: String
        switch mutation {
        case "otherPaper": action = "UPDATE paper SET title = 'foreign drift' WHERE id = '\(other)';"
        case "providerConfig": action = "UPDATE providerConfig SET model = 'foreign drift';"
        case "delete": action = "DELETE FROM paper WHERE id = '\(other)';"
        case "insert": action = "INSERT INTO paper(id, generation, title, status, createdAt) VALUES ('\(inserted)', '\(UUID().uuidString)', 'foreign insertion', 'importFailed', 0);"
        default: action = "DELETE FROM libraryFolder;"
        }
        // No extra provider marker: precisely one write replaces the mandatory
        // inner reader UPDATE before RAISE(IGNORE), defeating count-only guards.
        try sql.execute(sql: "CREATE TRIGGER compensatingReader BEFORE UPDATE OF readerSequence ON paper WHEN NEW.id = '\(id.paperID.uuidString)' BEGIN \(action) SELECT RAISE(IGNORE); END")
      }
      let before = try actualRows(db)
      let papersBefore = try db.adapterRead { try Row.fetchAll($0, sql: "SELECT * FROM paper ORDER BY id") }
      let foldersBefore = try db.adapterRead { try Row.fetchAll($0, sql: "SELECT * FROM libraryFolder ORDER BY id") }
      XCTAssertThrowsError(try db.recordJournaledImportFailure(expected: record,
        replacement: record.journal.recording(.terminate(record.journal.snapshot().current.lineage, .failed)),
        failure: .importFailed, cleanupDebt: true), mutation)
      let reopened = try ProductDatabase.open(at: root)
      assertRows(before, equal: try actualRows(reopened))
      XCTAssertEqual(papersBefore, try reopened.adapterRead { try Row.fetchAll($0, sql: "SELECT * FROM paper ORDER BY id") }, mutation)
      XCTAssertEqual(foldersBefore, try reopened.adapterRead { try Row.fetchAll($0, sql: "SELECT * FROM libraryFolder ORDER BY id") }, mutation)
      XCTAssertEqual(try read(id, db: reopened).encoded, record.encoded)
    }
  }

  func testOrdinaryJournaledFailureWithoutRowIDSchemaDeniesCompensatingAndUntriggeredWrites() throws {
    for compensatingTrigger in [false, true] {
      let (root, db, id, record) = try ordinaryFailureFixture()
      defer { try? FileManager.default.removeItem(at: root) }
      try db.adapterWrite { sql in
        try sql.execute(sql: "CREATE TABLE syntheticWR(key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID")
        try sql.execute(sql: "INSERT INTO syntheticWR(key, value) VALUES ('owned', 'unchanged')")
        if compensatingTrigger {
          // Exactly one invisible WR write replaces the ignored reader UPDATE;
          // there is no provider marker or additional fifth write.
          try sql.execute(sql: "CREATE TRIGGER compensatingWR BEFORE UPDATE OF readerSequence ON paper WHEN NEW.id = '\(id.paperID.uuidString)' BEGIN UPDATE syntheticWR SET value = 'foreign drift'; SELECT RAISE(IGNORE); END")
        }
      }
      let before = try actualRows(db)
      assertError(.invalidHistory) {
        _ = try db.recordJournaledImportFailure(expected: record,
          replacement: record.journal.recording(.terminate(record.journal.snapshot().current.lineage, .failed)),
          failure: .importFailed, cleanupDebt: true)
      }
      let reopened = try ProductDatabase.open(at: root)
      assertRows(before, equal: try actualRows(reopened))
      XCTAssertEqual(try read(id, db: reopened).encoded, record.encoded)
      XCTAssertEqual(try reopened.adapterRead { try String.fetchOne($0, sql: "SELECT value FROM syntheticWR WHERE key = 'owned'") }, "unchanged")
    }
  }

  func testOrdinaryJournaledFailureShadowTriggerDefinitionDeniedAndCanonicalSchemaAdmitted() throws {
    let (root, db, id, record) = try ordinaryFailureFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let before = try actualRows(db)
    let valueBefore = try db.adapterRead {
      try Int64.fetchOne($0, sql: "SELECT v FROM extractionFTS_config WHERE k = 'version'")
    }
    XCTAssertNotNil(valueBefore)
    XCTAssertThrowsError(try db.adapterWrite { sql in
      try sql.execute(sql: "CREATE TRIGGER compensatingShadow BEFORE UPDATE OF readerSequence ON paper WHEN NEW.id = '\(id.paperID.uuidString)' BEGIN UPDATE extractionFTS_config SET v = v + 1 WHERE k = 'version'; SELECT RAISE(IGNORE); END")
    }) { error in
      guard let databaseError = error as? DatabaseError else {
        XCTFail("Expected typed SQLite trigger-definition denial, got \(error)")
        return
      }
      XCTAssertEqual(databaseError.resultCode, .SQLITE_ERROR)
      XCTAssertTrue(databaseError.message?.contains("may not write to shadow table \"extractionFTS_config\"") == true)
    }
    let reopened = try ProductDatabase.open(at: root)
    assertRows(before, equal: try actualRows(reopened))
    XCTAssertEqual(try read(id, db: reopened).encoded, record.encoded)
    XCTAssertEqual(valueBefore, try reopened.adapterRead {
      try Int64.fetchOne($0, sql: "SELECT v FROM extractionFTS_config WHERE k = 'version'")
    })
    XCTAssertEqual(try reopened.adapterRead {
      try Int.fetchOne($0, sql: "SELECT count(*) FROM sqlite_schema WHERE type = 'trigger' AND name = 'compensatingShadow'")
    }, 0)
    // Actual SQLite definition denial is not evidence of an observer callback.
    // Canonical shadow schema must still admit an ordinary failure afterwards.
    let replacement = try record.journal.recording(.terminate(record.journal.snapshot().current.lineage, .failed))
    let stored = try reopened.recordJournaledImportFailure(expected: record,
      replacement: replacement, failure: .importFailed, cleanupDebt: true)
    let final = try ProductDatabase.open(at: root)
    XCTAssertEqual(try read(id, db: final).encoded, stored.encoded)
    XCTAssertEqual(try read(id, db: final).journal.snapshot(), try replacement.snapshot())
    XCTAssertEqual(String.fromDatabaseValue(try actualRows(final).0["status"]), "importFailed")
    XCTAssertEqual(String.fromDatabaseValue(try actualRows(final).1["failure"]), "importFailed")
    XCTAssertEqual(valueBefore, try final.adapterRead {
      try Int64.fetchOne($0, sql: "SELECT v FROM extractionFTS_config WHERE k = 'version'")
    })
    let finalProvider = try actualRows(final).2
    for column in before.2.columnNames {
      XCTAssertEqual(before.2[column] as DatabaseValue, finalProvider[column] as DatabaseValue, column)
    }
  }

  func testJournaledReservationIgnoredInsertsCannotBackfillLegacyHistory() throws {
    for table in ["paper", "importJob"] {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }
      let db = try ProductDatabase.open(at: root)
      let id = identity()
      try db.adapterWrite { sql in
        try sql.execute(sql: "CREATE TRIGGER ignoreInsert BEFORE INSERT ON \(table) BEGIN SELECT RAISE(IGNORE); END")
      }
      XCTAssertThrowsError(try db.reserveJournaledImport(id, title: "Ignored insert", confirmedInput: facts))
      XCTAssertTrue(try db.libraryRecords().isEmpty)
      assertError(.missingHistory) { _ = try read(id, db: db) }
    }
    let (root, db, id, _) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    try db.adapterWrite { sql in
      try sql.execute(sql: "CREATE TRIGGER ignorePaperInsert BEFORE INSERT ON paper BEGIN SELECT RAISE(IGNORE); END")
      try sql.execute(sql: "CREATE TRIGGER ignoreJobInsert BEFORE INSERT ON importJob BEGIN SELECT RAISE(IGNORE); END")
    }
    XCTAssertThrowsError(try db.reserveJournaledImport(id, title: "Forbidden legacy backfill", confirmedInput: facts))
    assertError(.missingHistory) { _ = try read(id, db: db) }
  }
}
