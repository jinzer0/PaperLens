import Foundation
import XCTest
import GRDB
@testable import PaperLensProduct

@MainActor final class ReaderSessionTests: XCTestCase {
  // Tests require parent registration of registerReaderMigrations on the existing
  // ProductDatabase owner. They never create a second production queue or schema.
  private func fixture() throws -> (ProductDatabase, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let db = try ProductDatabase.open(at: root)
    addTeardownBlock { try FileManager.default.removeItem(at: root) }
    return (db, root)
  }

  private func insert(_ db: ProductDatabase, id: UUID = UUID()) throws -> UUID {
    try db.adapterWrite { database in
      try database.execute(sql: """
        INSERT INTO paper(id, generation, title, status, pdfReference, pdfSHA256, createdAt)
        VALUES (?, ?, 'Synthetic Paper', 'ready', ?, 'identical-synthetic-digest', 0)
        """, arguments: [id.uuidString, UUID().uuidString, "papers/\(id.uuidString)/document.pdf"])
    }
    return id
  }

  func testMissingLeaseBindingBlocksBeforeDocumentRead() throws {
    let (db, _) = try fixture()
    let id = try insert(db)
    let session = ReaderSession(database: db)
    XCTAssertThrowsError(try session.open(paperID: id, validateDocument: { _ in
      XCTFail("Must not read without lifecycle binding")
      return 3
    }, discard: {})) { XCTAssertEqual($0 as? ReaderError, .leaseUnavailable) }
  }

  func testDurableRestoreAfterDatabaseReopenAndIndependentSameDigestPapers() throws {
    let (db, root) = try fixture()
    let first = try insert(db)
    let second = try insert(db)
    let provider = TestLeaseProvider()
    let session = ReaderSession(database: db, leaseProvider: provider)
    XCTAssertEqual(try session.open(paperID: first, validateDocument: { _ in 4 }, discard: {}),
      ReaderPosition(pageIndex: 0, zoom: 1))
    try session.leave(at: ReaderPosition(pageIndex: 2, zoom: 1.5))
    let reopened = try ProductDatabase.open(at: root)
    let restored = ReaderSession(database: reopened, leaseProvider: provider)
    XCTAssertEqual(try restored.open(paperID: first, validateDocument: { _ in 4 }, discard: {}),
      ReaderPosition(pageIndex: 2, zoom: 1.5))
    restored.close()
    XCTAssertEqual(try restored.open(paperID: second, validateDocument: { _ in 4 }, discard: {}),
      ReaderPosition(pageIndex: 0, zoom: 1))
    restored.close()
  }

  func testReversedSequenceAndReplacedOwnerCannotOverwriteCommittedPosition() throws {
    let (db, _) = try fixture()
    let id = try insert(db)
    let snapshot = try db.readerSnapshot(paperID: id)
    let owner = UUID()
    _ = try db.claimReader(snapshot, sessionID: owner)
    try db.saveReaderPosition(.init(pageIndex: 3, zoom: 2), snapshot: snapshot,
      sessionID: owner, sequence: 2)
    XCTAssertThrowsError(try db.saveReaderPosition(.init(pageIndex: 1, zoom: 1),
      snapshot: snapshot, sessionID: owner, sequence: 1))
    let replacement = UUID()
    XCTAssertEqual(try db.claimReader(snapshot, sessionID: replacement),
      ReaderPosition(pageIndex: 3, zoom: 2))
    XCTAssertThrowsError(try db.saveReaderPosition(.init(pageIndex: 0, zoom: 1),
      snapshot: snapshot, sessionID: owner, sequence: 3))
    try db.releaseReader(snapshot, sessionID: owner)
    try db.validateReaderOwner(snapshot, sessionID: replacement)
  }

  func testDeletionAndGenerationReplacementBlockOpenAndSaveAndClearPosition() throws {
    let (db, _) = try fixture()
    let id = try insert(db)
    let snapshot = try db.readerSnapshot(paperID: id)
    let owner = UUID()
    _ = try db.claimReader(snapshot, sessionID: owner)
    try db.saveReaderPosition(.init(pageIndex: 1, zoom: 1), snapshot: snapshot,
      sessionID: owner, sequence: 1)
    try db.adapterWrite { database in
      try database.execute(sql: "UPDATE paper SET generation = ? WHERE id = ?",
        arguments: [UUID().uuidString, id.uuidString])
    }
    XCTAssertThrowsError(try db.validateReaderSnapshot(snapshot))
    XCTAssertThrowsError(try db.saveReaderPosition(.init(pageIndex: 2, zoom: 1),
      snapshot: snapshot, sessionID: owner, sequence: 2))
    let fresh = try db.readerSnapshot(paperID: id)
    XCTAssertNil(try db.claimReader(fresh, sessionID: UUID()))
    try db.adapterWrite { database in
      try database.execute(sql: "UPDATE paper SET status = 'deleting', deletionID = ? WHERE id = ?",
        arguments: [UUID().uuidString, id.uuidString])
    }
    XCTAssertThrowsError(try db.readerSnapshot(paperID: id))
    XCTAssertThrowsError(try db.claimReader(fresh, sessionID: UUID()))
    XCTAssertEqual(try db.adapterRead { database in
      try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM paper WHERE id = ?",
        arguments: [id.uuidString])
    }, 1)
  }

  func testRevocationDuringLoadDiscardsCandidateAndFailsClosed() throws {
    let (db, _) = try fixture()
    let id = try insert(db)
    let provider = TestLeaseProvider()
    let session = ReaderSession(database: db, leaseProvider: provider)
    var discarded = false
    XCTAssertThrowsError(try session.open(paperID: id, validateDocument: { _ in
      provider.revoke()
      return 4
    }, discard: { discarded = true }))
    XCTAssertTrue(discarded)
    XCTAssertNil(session.currentPaper)
    XCTAssertThrowsError(try session.save(.init(pageIndex: 1, zoom: 1)))
    XCTAssertTrue(provider.lastLease?.closed == true)
  }

  func testDatabaseRevocationDuringLoadWithoutNotificationStillFailsAdmission() throws {
    let (db, _) = try fixture()
    let id = try insert(db)
    let session = ReaderSession(database: db, leaseProvider: TestLeaseProvider())
    XCTAssertThrowsError(try session.open(paperID: id, validateDocument: { _ in
      try db.adapterWrite { database in
        try database.execute(sql: "UPDATE paper SET status = 'deletionFailed' WHERE id = ?",
          arguments: [id.uuidString])
      }
      return 2
    }, discard: {}))
    XCTAssertNil(session.currentPaper)
  }

  func testInvalidRestoreIsNotClampedAndInvalidSavePreservesCommittedPosition() throws {
    let (db, _) = try fixture()
    let id = try insert(db)
    let provider = TestLeaseProvider()
    let session = ReaderSession(database: db, leaseProvider: provider)
    _ = try session.open(paperID: id, validateDocument: { _ in 4 }, discard: {})
    try session.save(.init(pageIndex: 3, zoom: 1.25))
    XCTAssertThrowsError(try session.save(.init(pageIndex: 4, zoom: 1)))
    XCTAssertThrowsError(try session.save(.init(pageIndex: 1, zoom: .nan)))
    session.close()
    XCTAssertThrowsError(try session.open(paperID: id, validateDocument: { _ in 2 }, discard: {})) {
      XCTAssertEqual($0 as? ReaderError, .invalidStoredPosition)
    }
    XCTAssertEqual(try session.open(paperID: id, validateDocument: { _ in 4 }, discard: {}),
      ReaderPosition(pageIndex: 3, zoom: 1.25))
    session.close()
  }

  func testArbitraryReferenceAndUnknownPaperAreNeverAdmitted() throws {
    let (db, _) = try fixture()
    XCTAssertThrowsError(try db.readerSnapshot(paperID: UUID()))
    let id = try insert(db)
    try db.adapterWrite { database in
      try database.execute(sql: "UPDATE paper SET pdfReference = '/tmp/arbitrary.pdf' WHERE id = ?",
        arguments: [id.uuidString])
    }
    XCTAssertThrowsError(try db.readerSnapshot(paperID: id)) {
      XCTAssertEqual($0 as? ReaderError, .invalidReference)
    }
  }

  func testStorageFailureDoesNotPretendLeaveOrOverwriteCommittedPosition() throws {
    let (db, _) = try fixture()
    let id = try insert(db)
    let provider = TestLeaseProvider()
    let session = ReaderSession(database: db, leaseProvider: provider)
    _ = try session.open(paperID: id, validateDocument: { _ in 4 }, discard: {})
    try session.save(.init(pageIndex: 1, zoom: 1.5))
    try db.adapterWrite { database in
      try database.execute(sql: """
        CREATE TRIGGER syntheticSaveFailure BEFORE UPDATE OF lastReadPage ON paper
        BEGIN SELECT RAISE(ABORT, 'synthetic storage failure'); END;
        """)
    }
    XCTAssertThrowsError(try session.leave(at: .init(pageIndex: 2, zoom: 2)))
    XCTAssertNotNil(session.currentPaper)
    XCTAssertEqual(session.restoredPosition, ReaderPosition(pageIndex: 1, zoom: 1.5))
    XCTAssertFalse(provider.lastLease?.closed ?? true)
    try db.adapterWrite { database in
      try database.execute(sql: "DROP TRIGGER syntheticSaveFailure")
    }
    try session.leave(at: .init(pageIndex: 2, zoom: 2))
    XCTAssertNil(session.currentPaper)
    XCTAssertEqual(try session.open(paperID: id, validateDocument: { _ in 4 }, discard: {}),
      ReaderPosition(pageIndex: 2, zoom: 2))
    session.close()
  }

  func testInvalidDocumentClosesLeaseWithoutClaimingPaper() throws {
    let (db, _) = try fixture()
    let id = try insert(db)
    let provider = TestLeaseProvider()
    let session = ReaderSession(database: db, leaseProvider: provider)
    var discarded = false
    XCTAssertThrowsError(try session.open(paperID: id, validateDocument: { _ in 0 },
      discard: { discarded = true })) {
      XCTAssertEqual($0 as? ReaderError, .invalidDocument)
    }
    XCTAssertTrue(discarded)
    XCTAssertTrue(provider.lastLease?.closed == true)
    XCTAssertNil(session.currentPaper)
    XCTAssertNil(try db.adapterRead { database in
      try String.fetchOne(database, sql: "SELECT readerSession FROM paper WHERE id = ?",
        arguments: [id.uuidString])
    })
  }

  func testNavigationBoundsAndOverflow() {
    XCTAssertNil(ReaderNavigation.page(after: 0, delta: -1, count: 3))
    XCTAssertNil(ReaderNavigation.page(after: 2, delta: 1, count: 3))
    XCTAssertEqual(ReaderNavigation.page(after: 1, delta: 1, count: 3), 2)
    XCTAssertEqual(ReaderNavigation.page(after: 1, delta: -1, count: 3), 0)
    XCTAssertNil(ReaderNavigation.page(after: 1, delta: Int.max, count: 3))
    XCTAssertNil(ReaderNavigation.page(after: 0, delta: 0, count: 0))
  }
}

/// Test-only deterministic lease, not a production fallback or lifecycle proof.
@MainActor private final class TestLeaseProvider: ReaderLeaseProvider {
  var lastLease: TestReadLease?
  private var callback: (@MainActor () -> Void)?
  func acquireReadLease(for snapshot: ReaderPaperSnapshot,
    onRevoked: @escaping @MainActor () -> Void) throws -> any ReaderReadLease {
    let lease = TestReadLease()
    lastLease = lease
    callback = onRevoked
    return lease
  }
  func revoke() { lastLease?.revoked = true; callback?() }
}

@MainActor private final class TestReadLease: ReaderReadLease {
  var revoked = false
  var closed = false
  func validate() throws {
    if revoked || closed { throw ReaderError.revoked }
  }
  func withReadAccess<T>(_ operation: () throws -> T) throws -> T {
    try validate()
    return try operation()
  }
  func close() { closed = true }
}
