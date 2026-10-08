import Darwin
import Foundation
import XCTest

@testable import PackagedDBProbe

private enum ProbeTestFailure: Error { case setup }

private final class ProbeBarrierOutcome: @unchecked Sendable {
  private let lock = NSLock()
  private var failure: PackagedDBFailure?
  private var snapshot: PackagedDBSnapshot?
  func recordSnapshot(_ value: PackagedDBSnapshot) { lock.withLock { snapshot = value } }
  func record(_ error: Error) {
    lock.withLock {
      failure = (error as? PackagedDBFailure) ?? PackagedDBFailure(.unexpectedFailure)
    }
  }
  var observedFailure: PackagedDBFailure? { lock.withLock { failure } }
  var observedSnapshot: PackagedDBSnapshot? { lock.withLock { snapshot } }
}

// Setup, not the probe, reserves CODE artifacts and records independent stat
// identities. No HOME/environment/argv substitution and no recursive cleanup.
private final class ProbeFixture {
  let context: TopologyDBOwnerContext

  init(runID: String = UUID().uuidString.lowercased()) throws {
    var worktree = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    while worktree.path != "/" {
      if FileManager.default.fileExists(
        atPath: worktree.path
          + "/bmad-docs/implementation-artifacts/spec-1-5-packaged-db-fts5-matrix.md")
      {
        break
      }
      worktree.deleteLastPathComponent()
    }
    guard worktree.path != "/", let root = TopologyFixtures.directory(worktree, create: false)
    else { throw ProbeTestFailure.setup }
    guard
      let topology = TopologyFixtures.directory(
        worktree.appendingPathComponent(".build/topology"), create: true)
    else {
      Darwin.close(root)
      throw ProbeTestFailure.setup
    }
    let entry = "local-grdb-probe-" + runID
    guard TopologyFixtures.validRunID(runID), mkdirat(topology, entry, 0o700) == 0 else {
      Darwin.close(root)
      Darwin.close(topology)
      throw ProbeTestFailure.setup
    }
    let namespace = openat(topology, entry, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard namespace >= 0 else {
      Darwin.close(root)
      Darwin.close(topology)
      throw ProbeTestFailure.setup
    }
    var rootInfo = stat()
    var parentInfo = stat()
    var runInfo = stat()
    var dbInfo = stat()
    let reservation = openat(
      namespace, "db.sqlite",
      O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard reservation >= 0 else {
      Darwin.close(namespace)
      Darwin.close(root)
      Darwin.close(topology)
      throw ProbeTestFailure.setup
    }
    let valid =
      fstat(root, &rootInfo) == 0 && fstat(topology, &parentInfo) == 0
      && TopologyFixtures.privateDirectory(namespace, info: &runInfo)
      && TopologyFixtures.privateFile(reservation, info: &dbInfo) && dbInfo.st_size == 0
      && TopologyFixtures.matches(directory: namespace, name: "db.sqlite", info: dbInfo)
    // There is no additional DB file descriptor when GRDB opens.
    let reservationClosed = Darwin.close(reservation) == 0
    guard valid, reservationClosed else {
      Darwin.close(namespace)
      Darwin.close(root)
      Darwin.close(topology)
      throw ProbeTestFailure.setup
    }
    context = TopologyDBOwnerContext(
      worktreePath: worktree.path, worktree: root,
      topology: topology, namespace: namespace, worktreeIdentity: rootInfo,
      topologyIdentity: parentInfo, namespaceIdentity: runInfo, databaseIdentity: dbInfo,
      uid: getuid(), ownerID: UUID().uuidString.lowercased(), runID: runID,
      attemptID: UUID().uuidString.lowercased())
    guard context.validate(), context.entries() == ["db.sqlite"] else {
      throw ProbeTestFailure.setup
    }
  }

  func altered(
    uid: uid_t? = nil, worktree: Int32? = nil, topology: Int32? = nil,
    namespace: Int32? = nil, runIdentity: stat? = nil, dbIdentity: stat? = nil,
    runID: String? = nil
  ) -> TopologyDBOwnerContext {
    TopologyDBOwnerContext(
      worktreePath: context.worktreePath,
      worktree: worktree ?? context.worktree, topology: topology ?? context.topology,
      namespace: namespace ?? context.namespace, worktreeIdentity: context.worktreeIdentity,
      topologyIdentity: context.topologyIdentity,
      namespaceIdentity: runIdentity ?? context.namespaceIdentity,
      databaseIdentity: dbIdentity ?? context.databaseIdentity, uid: uid ?? context.uid,
      ownerID: context.ownerID, runID: runID ?? context.runID, attemptID: context.attemptID)
  }

  func removeUnusedReservation() -> Bool {
    var info = stat()
    guard context.validate(), context.entries() == ["db.sqlite"],
      fstatat(context.namespace, "db.sqlite", &info, AT_SYMLINK_NOFOLLOW) == 0,
      info.st_size == 0,
      TopologyFixtures.removeOwned(
        directory: context.namespace, name: "db.sqlite",
        info: context.databaseIdentity), context.entries() == [],
      TopologyFixtures.matches(
        directory: context.topology, name: context.entry,
        info: context.namespaceIdentity)
    else { return false }
    return unlinkat(context.topology, context.entry, AT_REMOVEDIR) == 0
  }

  deinit {
    Darwin.close(context.namespace)
    Darwin.close(context.topology)
    Darwin.close(context.worktree)
  }
}

final class PackagedDBProbeTests: XCTestCase {
  // GRDB's one-active-queue gate is process-global, so tests must not overlap.
  private final class SerialGate: @unchecked Sendable { let lock = NSLock() }
  private static let serial = SerialGate()
  override func setUp() {
    super.setUp()
    Self.serial.lock.lock()
  }
  override func tearDown() {
    Self.serial.lock.unlock()
    super.tearDown()
  }

  private func withProbe(
    _ fault: PackagedDBFault = .none,
    body: (ProbeFixture, PackagedDBProbe) throws -> Void
  ) throws {
    let fixture = try ProbeFixture()
    let probe = try PackagedDBProbe(owner: fixture.context, fault: fault)
    defer {
      let closed = probe.closeAndDrain()
      XCTAssertTrue(closed, "close not observed; ownership retained")
      if closed { XCTAssertTrue(probe.cleanup(), "owned cleanup blocked") }
    }
    try body(fixture, probe)
  }

  func testOrderedMigrationsCorpusDeleteAndSameInodeReopen() throws {
    try withProbe { fixture, probe in
      let initial = try probe.snapshot()
      XCTAssertEqual(initial.version, 0)
      XCTAssertTrue(initial.migrations.isEmpty && initial.identifiers.isEmpty)
      XCTAssertTrue(initial.probeObjects.isEmpty)
      let base = try probe.migrateBase()
      XCTAssertEqual(base.version, 1)
      XCTAssertTrue(base.migrations == ["probe_base_v1"])
      XCTAssertEqual(base.registryRows, 1)
      XCTAssertTrue(base.baseSchemaValid)
      XCTAssertTrue(base.probeObjects == ["probe_base"])
      XCTAssertEqual(base.baselineRows, 0)
      let full = try probe.migrate()
      XCTAssertEqual(full.version, 2)
      XCTAssertTrue(full.migrations == ["probe_base_v1", "probe_fts_v2"])
      XCTAssertTrue(full.identifiers == Set(["probe_base_v1", "probe_fts_v2"]))
      XCTAssertEqual(full.registryRows, 2)
      XCTAssertTrue(full.baseSchemaValid && full.ftsSchemaValid)
      XCTAssertEqual(full.ftsRows, 4)
      XCTAssertEqual(full.ftsIDs, [1, 2, 3, 4])
      // Content is RAM-only, including on XCTest assertion failure.
      XCTAssertTrue(
        full.sentences == ["orbit alpha.", "beta gamma.", "orbit delta.", "epsilon zeta."])
      XCTAssertEqual(full.matches, [1, 3])
      XCTAssertTrue(probe.isReady)
      let empty = try probe.deleteCorpus()
      XCTAssertEqual(empty.ftsRows, 0)
      XCTAssertTrue(empty.matches.isEmpty && empty.sentences.isEmpty)
      XCTAssertTrue(probe.closeAndDrain())
      XCTAssertTrue(probe.hasObservedClose)
      XCTAssertTrue(fixture.context.validate())
      try probe.reopen()
      let reopened = try probe.migrate()
      XCTAssertTrue(reopened == empty)
      XCTAssertTrue(fixture.context.validate())
      XCTAssertEqual(reopened.registryRows, 2)
      XCTAssertTrue(reopened.ftsSchemaValid)
      XCTAssertTrue(probe.isReady)
      XCTAssertTrue(probe.failureHistory.isEmpty)
    }
  }

  func testFullFreshMigrationThenReopenDoesNotRepopulateDeletedCorpus() throws {
    try withProbe { _, probe in
      XCTAssertEqual(try probe.migrate().matches, [1, 3])
      let empty = try probe.deleteCorpus()
      XCTAssertTrue(probe.closeAndDrain())
      try probe.reopen()
      XCTAssertTrue(try probe.migrate() == empty)
      XCTAssertTrue(try probe.migrate() == empty)
    }
  }

  private func checkFault(_ fault: PackagedDBFault) throws {
    try withProbe(fault) { fixture, probe in
      for attempt in 0..<2 {
        XCTAssertThrowsError(try probe.migrate()) { error in
          let failure = error as? PackagedDBFailure
          XCTAssertEqual(failure?.reason, .migrationFailed)
          // Actual SQLite constraint / primary-key constraint codes.
          XCTAssertEqual(failure?.primaryCode, 19)
          XCTAssertEqual(failure?.extendedCode, 1555)
        }
        XCTAssertFalse(probe.isReady)
        let rollback = try probe.snapshot()
        XCTAssertEqual(rollback.version, fault == .m1 ? 0 : 1)
        XCTAssertTrue(rollback.migrations == (fault == .m1 ? [] : ["probe_base_v1"]))
        XCTAssertEqual(rollback.registryRows, fault == .m1 ? 0 : 1)
        XCTAssertTrue(rollback.probeObjects == (fault == .m1 ? [] : ["probe_base"]))
        XCTAssertEqual(rollback.baselineRows, 0)
        XCTAssertEqual(rollback.ftsRows, 0)
        XCTAssertFalse(rollback.ftsSchemaValid)
        XCTAssertTrue(rollback.matches.isEmpty)
        XCTAssertTrue(fixture.context.validate())
        XCTAssertEqual(probe.failureHistory.count, attempt + 1)
        if attempt == 0 {
          XCTAssertTrue(probe.closeAndDrain())
          try probe.reopen()
          XCTAssertTrue(try probe.snapshot() == rollback)
        }
      }
    }
  }
  func testM1ActualDuplicatePrimaryKeyRollbackAndUnchangedFailingReopen() throws {
    try checkFault(.m1)
  }
  func testM2ActualDuplicatePrimaryKeyPreservesM1AndUnchangedFailingReopen() throws {
    try checkFault(.m2)
  }

  func testRealQueueBarrierInterruptDoesNotDrainAndClosePrecedesCleanup() throws {
    try withProbe { fixture, probe in
      _ = try probe.migrate()
      let entered = DispatchSemaphore(value: 0)
      let release = DispatchSemaphore(value: 0)
      let completed = DispatchSemaphore(value: 0)
      let outcome = ProbeBarrierOutcome()
      // Never print a caught SQL error; numeric safe failure state is in probe.
      DispatchQueue.global().async {
        defer { completed.signal() }
        do { try probe.barrier(entered: entered, release: release) } catch { outcome.record(error) }
      }
      defer { release.signal() }
      XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
      XCTAssertEqual(completed.wait(timeout: .now()), .timedOut)
      probe.interrupt()
      XCTAssertFalse(probe.closeAndDrain())
      XCTAssertFalse(probe.hasObservedClose)
      XCTAssertFalse(probe.cleanup())
      XCTAssertTrue(fixture.context.validate())
      XCTAssertThrowsError(try probe.reopen())
      let other = try ProbeFixture()
      XCTAssertThrowsError(try PackagedDBProbe(owner: other.context, fault: .none))
      XCTAssertTrue(other.removeUnusedReservation())
      release.signal()
      XCTAssertEqual(completed.wait(timeout: .now() + 5), .success)
      if let failure = outcome.observedFailure {
        XCTAssertEqual(failure.primaryCode, 9)
        XCTAssertEqual(failure.reason, .unexpectedFailure)
      }
      XCTAssertTrue(probe.closeAndDrain())
      XCTAssertTrue(probe.hasObservedClose)
      XCTAssertTrue(probe.cleanup())
      var info = stat()
      XCTAssertEqual(
        fstatat(
          fixture.context.topology, fixture.context.entry, &info,
          AT_SYMLINK_NOFOLLOW), -1)
      XCTAssertEqual(errno, ENOENT)
    }
  }

  func testQueuedSnapshotWaitsForRealTransactionJournalAndRemainsAdmitted() throws {
    try withProbe { fixture, probe in
      let expected = try probe.migrate()
      let writeEntered = DispatchSemaphore(value: 0)
      let writeRelease = DispatchSemaphore(value: 0)
      let writeCompleted = DispatchSemaphore(value: 0)
      let snapshotAdmitted = DispatchSemaphore(value: 0)
      let snapshotPublication = DispatchSemaphore(value: 0)
      let snapshotRelease = DispatchSemaphore(value: 0)
      let snapshotCompleted = DispatchSemaphore(value: 0)
      let writeOutcome = ProbeBarrierOutcome()
      let snapshotOutcome = ProbeBarrierOutcome()
      defer {
        writeRelease.signal()
        snapshotRelease.signal()
      }
      DispatchQueue.global().async {
        defer { writeCompleted.signal() }
        do { try probe.transactionBarrier(entered: writeEntered, release: writeRelease) } catch {
          writeOutcome.record(error)
        }
      }
      XCTAssertEqual(writeEntered.wait(timeout: .now() + 5), .success)
      // Observe the actual dirty transaction's journal without opening it.
      XCTAssertTrue(fixture.context.entries()?.contains("db.sqlite-journal") == true)
      DispatchQueue.global().async {
        defer { snapshotCompleted.signal() }
        do {
          let snapshot = try probe.snapshot(
            admittedSignal: snapshotAdmitted,
            beforePublication: {
              snapshotPublication.signal()
              snapshotRelease.wait()
            })
          snapshotOutcome.recordSnapshot(snapshot)
        } catch { snapshotOutcome.record(error) }
      }
      XCTAssertEqual(snapshotAdmitted.wait(timeout: .now() + 5), .success)
      XCTAssertEqual(snapshotPublication.wait(timeout: .now()), .timedOut)
      XCTAssertEqual(snapshotCompleted.wait(timeout: .now()), .timedOut)
      XCTAssertTrue(probe.failureHistory.isEmpty)
      XCTAssertFalse(probe.closeAndDrain())
      XCTAssertFalse(probe.cleanup())
      writeRelease.signal()
      XCTAssertEqual(writeCompleted.wait(timeout: .now() + 5), .success)
      XCTAssertEqual(snapshotPublication.wait(timeout: .now() + 5), .success)
      XCTAssertTrue(writeOutcome.observedFailure == nil)
      // The first operation is finished; the second is still counted through
      // final publication, not merely through its serialized SQL closure.
      XCTAssertFalse(probe.closeAndDrain())
      XCTAssertFalse(probe.hasObservedClose)
      XCTAssertThrowsError(try probe.reopen())
      XCTAssertFalse(probe.cleanup())
      snapshotRelease.signal()
      XCTAssertEqual(snapshotCompleted.wait(timeout: .now() + 5), .success)
      XCTAssertTrue(snapshotOutcome.observedFailure == nil)
      XCTAssertTrue(snapshotOutcome.observedSnapshot == expected)
      XCTAssertTrue(probe.failureHistory.isEmpty)
      XCTAssertTrue(fixture.context.validate())
      XCTAssertTrue(probe.closeAndDrain())
    }
  }

  func testFinalMigrationPublicationBlocksCloseAndCannotReadyReplacementQueue() throws {
    try withProbe { fixture, probe in
      let publication = DispatchSemaphore(value: 0)
      let release = DispatchSemaphore(value: 0)
      let completed = DispatchSemaphore(value: 0)
      let outcome = ProbeBarrierOutcome()
      defer { release.signal() }
      DispatchQueue.global().async {
        defer { completed.signal() }
        do {
          let snapshot = try probe.migrate(beforePublication: {
            publication.signal()
            release.wait()
          })
          outcome.recordSnapshot(snapshot)
        } catch { outcome.record(error) }
      }
      // Actual full migration, schema/registry inspection and post-validation
      // have finished; only counted final publication remains paused.
      XCTAssertEqual(publication.wait(timeout: .now() + 5), .success)
      XCTAssertFalse(probe.isReady)
      XCTAssertEqual(completed.wait(timeout: .now()), .timedOut)
      XCTAssertFalse(probe.closeAndDrain())
      XCTAssertFalse(probe.hasObservedClose)
      XCTAssertThrowsError(try probe.reopen())
      XCTAssertFalse(probe.cleanup())
      XCTAssertTrue(fixture.context.validate())
      release.signal()
      XCTAssertEqual(completed.wait(timeout: .now() + 5), .success)
      XCTAssertTrue(outcome.observedFailure == nil)
      XCTAssertEqual(outcome.observedSnapshot?.version, 2)
      XCTAssertFalse(probe.isReady)
      XCTAssertTrue(probe.closeAndDrain())
      try probe.reopen()
      XCTAssertFalse(probe.isReady)
      XCTAssertTrue(try probe.snapshot() == outcome.observedSnapshot)
      XCTAssertFalse(probe.isReady)
      XCTAssertTrue(try probe.migrate() == outcome.observedSnapshot)
      XCTAssertTrue(probe.isReady)
      XCTAssertTrue(probe.failureHistory.isEmpty)
    }
  }

  func testIndependentDescriptorsUIDDeviceInodeRunAndUUIDReuse() throws {
    let first = try ProbeFixture()
    let second = try ProbeFixture()
    defer { XCTAssertTrue(second.removeUnusedReservation()) }
    let context = first.context
    var wrongInode = context.namespaceIdentity
    wrongInode.st_ino &+= 1
    var wrongDevice = context.databaseIdentity
    wrongDevice.st_dev &+= 1
    var wrongUID = context.databaseIdentity
    wrongUID.st_uid &+= 1
    let invalid = [
      first.altered(uid: getuid() &+ 1),
      first.altered(worktree: second.context.namespace),
      first.altered(topology: second.context.namespace),
      first.altered(namespace: second.context.namespace),
      first.altered(runIdentity: wrongInode), first.altered(dbIdentity: wrongDevice),
      first.altered(dbIdentity: wrongUID), first.altered(runID: second.context.runID),
      first.altered(runID: context.runID.uppercased()),
    ]
    for candidate in invalid {
      XCTAssertThrowsError(try PackagedDBProbe(owner: candidate, fault: .none))
      XCTAssertTrue(context.validate())
    }
    // Exclusive mkdir rejects a reused namespace without adoption.
    XCTAssertThrowsError(try ProbeFixture(runID: context.runID))
    let probe = try PackagedDBProbe(owner: context, fault: .none)
    XCTAssertTrue(probe.closeAndDrain())
    // Same identity, still reserved but already consumed UUID is not adopted.
    XCTAssertThrowsError(try PackagedDBProbe(owner: context, fault: .none))
    XCTAssertTrue(probe.cleanup())
    let reused = try ProbeFixture(runID: context.runID)
    XCTAssertThrowsError(try PackagedDBProbe(owner: reused.context, fault: .none))
    XCTAssertTrue(reused.removeUnusedReservation())
  }

  func testUnsafeFileAndNamespaceModesAreNotChangedOrAdopted() throws {
    let fixture = try ProbeFixture()
    let context = fixture.context
    let db = openat(context.namespace, "db.sqlite", O_RDWR | O_NOFOLLOW | O_CLOEXEC)
    guard db >= 0 else { throw ProbeTestFailure.setup }
    defer { Darwin.close(db) }
    XCTAssertEqual(fchmod(db, 0o640), 0)
    XCTAssertThrowsError(try PackagedDBProbe(owner: context, fault: .none))
    var info = stat()
    XCTAssertEqual(fstat(db, &info), 0)
    XCTAssertEqual(info.st_mode & 0o7777, 0o640)
    XCTAssertEqual(fchmod(db, 0o600), 0)
    XCTAssertEqual(fchmod(context.namespace, 0o750), 0)
    XCTAssertThrowsError(try PackagedDBProbe(owner: context, fault: .none))
    XCTAssertEqual(fstat(context.namespace, &info), 0)
    XCTAssertEqual(info.st_mode & 0o7777, 0o750)
    XCTAssertEqual(fchmod(context.namespace, 0o700), 0)
    XCTAssertTrue(fixture.removeUnusedReservation())
  }

  func testHardlinkAndSymlinkAreRejectedWithoutForeignUnlink() throws {
    let fixture = try ProbeFixture()
    let c = fixture.context
    XCTAssertEqual(linkat(c.namespace, "db.sqlite", c.namespace, "held", 0), 0)
    XCTAssertThrowsError(try PackagedDBProbe(owner: c, fault: .none))
    var linked = stat()
    XCTAssertEqual(fstatat(c.namespace, "held", &linked, AT_SYMLINK_NOFOLLOW), 0)
    XCTAssertEqual(linked.st_nlink, 2)
    XCTAssertEqual(unlinkat(c.namespace, "held", 0), 0)
    XCTAssertEqual(renameat(c.namespace, "db.sqlite", c.namespace, "held"), 0)
    XCTAssertEqual(symlinkat("held", c.namespace, "db.sqlite"), 0)
    XCTAssertThrowsError(try PackagedDBProbe(owner: c, fault: .none))
    var symlink = stat()
    XCTAssertEqual(fstatat(c.namespace, "db.sqlite", &symlink, AT_SYMLINK_NOFOLLOW), 0)
    XCTAssertEqual(symlink.st_mode & S_IFMT, S_IFLNK)
    XCTAssertTrue(
      TopologyFixtures.matches(directory: c.namespace, name: "held", info: c.databaseIdentity))
    XCTAssertEqual(unlinkat(c.namespace, "db.sqlite", 0), 0)
    XCTAssertEqual(renameat(c.namespace, "held", c.namespace, "db.sqlite"), 0)
    XCTAssertTrue(fixture.removeUnusedReservation())
  }

  func testNamespaceReplacementAndSymlinkDoNotAuthorizeCleanup() throws {
    try withProbe { fixture, probe in
      _ = try probe.migrate()
      XCTAssertTrue(probe.closeAndDrain())
      let c = fixture.context
      let held = c.entry + "-held"
      XCTAssertEqual(renameat(c.topology, c.entry, c.topology, held), 0)
      XCTAssertEqual(mkdirat(c.topology, c.entry, 0o700), 0)
      var replacement = stat()
      XCTAssertEqual(fstatat(c.topology, c.entry, &replacement, AT_SYMLINK_NOFOLLOW), 0)
      XCTAssertThrowsError(try probe.reopen())
      XCTAssertFalse(probe.cleanup())
      XCTAssertTrue(
        TopologyFixtures.matches(directory: c.topology, name: c.entry, info: replacement))
      XCTAssertTrue(
        TopologyFixtures.matches(
          directory: c.namespace, name: "db.sqlite", info: c.databaseIdentity))
      XCTAssertEqual(unlinkat(c.topology, c.entry, AT_REMOVEDIR), 0)
      XCTAssertEqual(symlinkat(held, c.topology, c.entry), 0)
      XCTAssertThrowsError(try probe.reopen())
      XCTAssertFalse(probe.cleanup())
      XCTAssertEqual(unlinkat(c.topology, c.entry, 0), 0)
      XCTAssertEqual(renameat(c.topology, held, c.topology, c.entry), 0)
    }
  }

  func testLivePhaseOwnershipRefusalAndCleanupPreserveOriginalSQLFailure() throws {
    try withProbe(.m2) { fixture, probe in
      XCTAssertThrowsError(try probe.migrate())
      XCTAssertEqual(probe.failureHistory.first?.reason, .migrationFailed)
      XCTAssertEqual(fchmod(fixture.context.namespace, 0o750), 0)
      XCTAssertThrowsError(try probe.snapshot()) { error in
        XCTAssertEqual((error as? PackagedDBFailure)?.reason, .bindingMismatch)
      }
      XCTAssertFalse(probe.isReady)
      // Invalid filesystem authority does not prevent closing our own handle.
      XCTAssertTrue(probe.closeAndDrain())
      XCTAssertFalse(probe.cleanup())
      XCTAssertEqual(probe.failureHistory.first?.reason, .migrationFailed)
      XCTAssertTrue(probe.failureHistory.contains { $0.reason == .cleanupFailed })
      XCTAssertTrue(
        TopologyFixtures.matches(
          directory: fixture.context.namespace,
          name: "db.sqlite", info: fixture.context.databaseIdentity))
      XCTAssertEqual(fchmod(fixture.context.namespace, 0o700), 0)
    }
  }

  func testClosedDatabaseHardlinkIsPreservedWithoutOwnedCleanup() throws {
    try withProbe { fixture, probe in
      _ = try probe.migrate()
      XCTAssertTrue(probe.closeAndDrain())
      let c = fixture.context
      XCTAssertEqual(linkat(c.namespace, "db.sqlite", c.namespace, "held", 0), 0)
      XCTAssertFalse(probe.cleanup())
      var info = stat()
      XCTAssertEqual(fstatat(c.namespace, "held", &info, AT_SYMLINK_NOFOLLOW), 0)
      XCTAssertEqual(info.st_nlink, 2)
      XCTAssertTrue(
        TopologyFixtures.matches(
          directory: c.namespace,
          name: "db.sqlite", info: c.databaseIdentity))
      XCTAssertEqual(unlinkat(c.namespace, "held", 0), 0)
    }
  }

  func testUnknownAndUnobservedFixedSidecarsArePreserved() throws {
    for name in ["foreign", "db.sqlite-wal", "db.sqlite-shm", "db.sqlite-journal"] {
      try withProbe { fixture, probe in
        _ = try probe.migrate()
        XCTAssertTrue(probe.closeAndDrain())
        let c = fixture.context
        let fd = openat(
          c.namespace, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ProbeTestFailure.setup }
        var foreign = stat()
        XCTAssertEqual(fstat(fd, &foreign), 0)
        XCTAssertEqual(Darwin.close(fd), 0)
        XCTAssertThrowsError(try probe.reopen())
        XCTAssertFalse(probe.cleanup())
        XCTAssertTrue(TopologyFixtures.matches(directory: c.namespace, name: name, info: foreign))
        XCTAssertTrue(
          TopologyFixtures.matches(
            directory: c.namespace, name: "db.sqlite", info: c.databaseIdentity))
        XCTAssertTrue(
          TopologyFixtures.removeOwned(directory: c.namespace, name: name, info: foreign))
      }
    }
  }

  func testReplacedDatabaseIsNotReopenedOrUnlinked() throws {
    try withProbe { fixture, probe in
      _ = try probe.migrate()
      XCTAssertTrue(probe.closeAndDrain())
      let c = fixture.context
      XCTAssertEqual(renameat(c.namespace, "db.sqlite", c.namespace, "held"), 0)
      let fd = openat(
        c.namespace, "db.sqlite", O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
      guard fd >= 0 else { throw ProbeTestFailure.setup }
      var replacement = stat()
      XCTAssertEqual(fstat(fd, &replacement), 0)
      Darwin.close(fd)
      XCTAssertThrowsError(try probe.reopen())
      XCTAssertFalse(probe.cleanup())
      XCTAssertTrue(
        TopologyFixtures.matches(directory: c.namespace, name: "db.sqlite", info: replacement))
      XCTAssertTrue(
        TopologyFixtures.removeOwned(directory: c.namespace, name: "db.sqlite", info: replacement))
      XCTAssertEqual(renameat(c.namespace, "held", c.namespace, "db.sqlite"), 0)
    }
  }

  private func installACL(_ fd: Int32) throws {
    var acl: acl_t? = acl_init(1)
    guard acl != nil else { throw ProbeTestFailure.setup }
    defer { if let acl { acl_free(UnsafeMutableRawPointer(acl)) } }
    var entry: acl_entry_t?
    guard acl_create_entry(&acl, &entry) == 0, let entry, let installedACL = acl else {
      throw ProbeTestFailure.setup
    }
    // membership.h is public but its declaration is not imported by Darwin.
    typealias UIDToUUID = @convention(c) (uid_t, UnsafeMutablePointer<UInt8>) -> Int32
    guard let library = dlopen(nil, RTLD_LAZY) else { throw ProbeTestFailure.setup }
    defer { dlclose(library) }
    guard let symbol = dlsym(library, "mbr_uid_to_uuid") else {
      throw ProbeTestFailure.setup
    }
    let uidToUUID = unsafeBitCast(symbol, to: UIDToUUID.self)
    var uuid = UUID().uuid
    let mapped = withUnsafeMutableBytes(of: &uuid) {
      uidToUUID(getuid(), $0.baseAddress!.assumingMemoryBound(to: UInt8.self))
    }
    guard mapped == 0, acl_set_tag_type(entry, ACL_EXTENDED_ALLOW) == 0 else {
      throw ProbeTestFailure.setup
    }
    let qualified = withUnsafePointer(to: &uuid) {
      acl_set_qualifier(entry, UnsafeRawPointer($0))
    }
    var permissions: acl_permset_t?
    guard qualified == 0,
      acl_get_permset(entry, &permissions) == 0, let permissions,
      acl_add_perm(permissions, ACL_READ_DATA) == 0,
      acl_set_fd_np(fd, installedACL, ACL_TYPE_EXTENDED) == 0
    else { throw ProbeTestFailure.setup }
  }

  private func clearACL(_ fd: Int32) throws {
    guard let acl = acl_init(0) else { throw ProbeTestFailure.setup }
    defer { acl_free(UnsafeMutableRawPointer(acl)) }
    guard acl_set_fd_np(fd, acl, ACL_TYPE_EXTENDED) == 0 else { throw ProbeTestFailure.setup }
  }

  func testNonemptyFileAndNamespaceACLsAreRejectedWithoutRepair() throws {
    let fixture = try ProbeFixture()
    let c = fixture.context
    let db = openat(c.namespace, "db.sqlite", O_RDWR | O_NOFOLLOW | O_CLOEXEC)
    guard db >= 0 else { throw ProbeTestFailure.setup }
    defer { Darwin.close(db) }
    try installACL(db)
    XCTAssertFalse(TopologyFixtures.emptyACL(db))
    XCTAssertThrowsError(try PackagedDBProbe(owner: c, fault: .none))
    XCTAssertFalse(TopologyFixtures.emptyACL(db))
    try clearACL(db)
    try installACL(c.namespace)
    XCTAssertFalse(TopologyFixtures.emptyACL(c.namespace))
    XCTAssertThrowsError(try PackagedDBProbe(owner: c, fault: .none))
    XCTAssertFalse(TopologyFixtures.emptyACL(c.namespace))
    try clearACL(c.namespace)
    XCTAssertTrue(fixture.removeUnusedReservation())
  }

  func testSameConnectionDiagnosticsAndIncrementalBounds() throws {
    try withProbe { _, probe in
      _ = try probe.migrate()
      let diagnostics = try probe.diagnostics()
      // Never assert/log the raw values, which may contain timestamps or paths.
      XCTAssertTrue(!diagnostics.version.isEmpty && !diagnostics.sourceID.isEmpty)
      XCTAssertTrue(!diagnostics.compileOptions.isEmpty)
      XCTAssertTrue(diagnostics.compileOptions.count <= 256)
      XCTAssertTrue(diagnostics.compileOptions.allSatisfy { $0.utf8.count <= 256 })
    }
    var count = 0
    let bounded = try PackagedDBProbe.collectBounded {
      guard count < 256 else { return nil }
      count += 1
      return String(repeating: "a", count: 256)
    }
    XCTAssertEqual(bounded.count, 256)
    count = 0
    XCTAssertThrowsError(
      try PackagedDBProbe.collectBounded {
        count += 1
        return "option"
      }
    ) { error in XCTAssertEqual((error as? PackagedDBFailure)?.reason, .provenanceOverflow) }
    XCTAssertEqual(count, 257)
    var pending = true
    XCTAssertThrowsError(
      try PackagedDBProbe.collectBounded {
        guard pending else { return nil }
        pending = false
        return String(repeating: "é", count: 129)
      }
    ) { error in XCTAssertEqual((error as? PackagedDBFailure)?.reason, .provenanceOverflow) }
  }
}
