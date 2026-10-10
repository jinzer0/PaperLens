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
