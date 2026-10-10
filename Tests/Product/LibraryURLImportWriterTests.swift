import Darwin
import Foundation
import GRDB
import ProviderRequest
import XCTest
@testable import PaperLensProduct

final class LibraryURLImportWriterTests: XCTestCase, @unchecked Sendable {
  private func database() throws -> ProductDatabase {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let database = try ProductDatabase.open(at: root)
    addTeardownBlock { try FileManager.default.removeItem(at: root) }
    return database
  }

  @MainActor
  private func continued(folder: UUID? = nil) async throws -> URLImportConfirmation {
    let box = URLConfirmationBox()
    let service = URLImportService(authority: try ProviderRequest(), grantWriter: { intent in
      box.store(intent)
      throw URLImportError.writerUnavailable
    })
    try service.prepare("https://writer.invalid/pdf", destination: "Not a UUID",
      possibleDuplicate: false, destinationFolderID: folder)
    service.continueImport(confirmationID: try XCTUnwrap(service.confirmation).id)
    while service.state == .downloading { await Task.yield() }
    return try XCTUnwrap(box.value)
  }

  private func stage(_ writer: any URLImportWriter, stall: Bool = false) async throws -> ClosedHTTPSPDFStage {
    let adapter = HTTPSPDFImportAdapter(authority: try ProviderRequest())
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [URLWriterFixture.self]
    return try await adapter.download(route: adapter.route("https://writer.invalid/" + (stall ? "stall" : "pdf")),
      stagingDirectory: writer.stagingDirectory, assertCurrent: { try writer.assertCurrent() },
      configuration: configuration, effects: .actual)
  }

  func testActualValidationClosesOnceReleasesQuotaAndCanPublishReopen() async throws {
    let db = try database()
    let lifecycle = try await LocalLibraryLifecycle.open(database: db)
    let writer = try await lifecycle.grantURLImportWriter(for: continued())
    let closed = try await stage(writer)
    let pool = try RequestResourcePool(authority: ProviderRequest(), kind: "import")
    let before = pool.active
    let roots = LibraryURLImportWriter.rootedValidationIDs
    let observation = URLValidationObservation(pool: pool)
    try LibraryURLImportWriter.validate(closed, directory: writer.stagingDirectory,
      cancellation: ImportCancellation(), effects: observation.effects())
    XCTAssertEqual(observation.snapshot.acquisitions, 1)
    XCTAssertEqual(observation.snapshot.closeAttempts, 1)
    XCTAssertEqual(observation.snapshot.activeAtOpen, before + 1)
    XCTAssertEqual(observation.snapshot.activeAtClose, before + 1)
    XCTAssertEqual(observation.snapshot.readMode, O_RDONLY)
    XCTAssertEqual(observation.snapshot.permissions, 0o400)
    XCTAssertEqual(pool.active, before)
    XCTAssertEqual(LibraryURLImportWriter.rootedValidationIDs, roots)
    // Never ask FileHandle for its descriptor after known close; publication
    // independently reopens and validates the same real sealed stage.
    _ = try await writer.publish(closed)
    XCTAssertEqual(try db.libraryRecords().map(\.status), [.ready])
    XCTAssertEqual(try Data(contentsOf: writer.stagingDirectory.appendingPathComponent("document.pdf")),
      URLWriterFixture.bytes)
  }

  func testActualValidationKnownClosePreservesTamperAndSignatureErrors() async throws {
    let db = try database()
    let lifecycle = try await LocalLibraryLifecycle.open(database: db)
    let pool = try RequestResourcePool(authority: ProviderRequest(), kind: "import")
    for mutation in ["hash", "magic", "mode", "directory", "missing"] {
      let writer = try await lifecycle.grantURLImportWriter(for: continued())
      let closed = try await stage(writer)
      if mutation == "directory" || mutation == "missing" {
        try FileManager.default.removeItem(at: closed.file)
        if mutation == "directory" {
          try FileManager.default.createDirectory(at: closed.file, withIntermediateDirectories: false)
        }
      } else {
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: closed.file.path)
        if mutation != "mode" {
          var bytes = URLWriterFixture.bytes
          bytes[mutation == "magic" ? 0 : bytes.count - 1] = 88
          try bytes.write(to: closed.file)
          try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: closed.file.path)
        }
      }
      let before = pool.active
      let roots = LibraryURLImportWriter.rootedValidationIDs
      let observation = URLValidationObservation(pool: pool)
      XCTAssertThrowsError(try LibraryURLImportWriter.validate(closed, directory: writer.stagingDirectory,
        cancellation: ImportCancellation(), effects: observation.effects())) { error in
        if mutation == "magic" {
          XCTAssertTrue(error is RequestContractError, "signature work error must not become closureUnknown")
        } else { XCTAssertEqual(error as? URLImportError, .rejected) }
      }
      XCTAssertEqual(observation.snapshot.closeAttempts, mutation == "missing" ? 0 : 1)
      XCTAssertEqual(observation.snapshot.acquisitions, mutation == "missing" ? 0 : 1)
      XCTAssertEqual(pool.active, before)
      XCTAssertEqual(LibraryURLImportWriter.rootedValidationIDs, roots)
      try await writer.abort(reason: .rejected)
    }
  }

  func testActualValidationCancellationAfterOpenClosesOnceAndReleasesLease() async throws {
    let db = try database()
    let lifecycle = try await LocalLibraryLifecycle.open(database: db)
    let writer = try await lifecycle.grantURLImportWriter(for: continued())
    let closed = try await stage(writer)
    let cancellation = ImportCancellation()
    let pool = try RequestResourcePool(authority: ProviderRequest(), kind: "import")
    let before = pool.active
    let roots = LibraryURLImportWriter.rootedValidationIDs
    let observation = URLValidationObservation(pool: pool)
    XCTAssertThrowsError(try LibraryURLImportWriter.validate(closed, directory: writer.stagingDirectory,
      cancellation: cancellation, effects: observation.effects(cancelOnOpen: cancellation))) {
      XCTAssertEqual($0 as? LocalLibraryError, .cancelled)
    }
    XCTAssertEqual(observation.snapshot.acquisitions, 1)
    XCTAssertEqual(observation.snapshot.closeAttempts, 1)
    XCTAssertEqual(pool.active, before)
    XCTAssertEqual(LibraryURLImportWriter.rootedValidationIDs, roots)
    try await writer.abort(reason: .cancelled)
  }

  func testActualValidationInvalidPathsCancellationAndCapacityHaveNoFDEffects() async throws {
    let db = try database()
    let lifecycle = try await LocalLibraryLifecycle.open(database: db)
    let writer = try await lifecycle.grantURLImportWriter(for: continued())
    let closed = try await stage(writer)
    let pool = try RequestResourcePool(authority: ProviderRequest(), kind: "import")
    let before = pool.active
    let roots = LibraryURLImportWriter.rootedValidationIDs
    let observation = URLValidationObservation(pool: pool)
    for directory in [URL(string: "https://writer.invalid/foreign")!,
      writer.stagingDirectory.appendingPathComponent("foreign"),
      writer.stagingDirectory.appendingPathComponent("decoded\0NUL"), closed.file] {
      XCTAssertThrowsError(try LibraryURLImportWriter.validate(closed, directory: directory,
        cancellation: ImportCancellation(), effects: observation.effects())) {
        XCTAssertEqual($0 as? URLImportError, .rejected)
      }
    }
    let cancelled = ImportCancellation()
    cancelled.cancel()
    XCTAssertThrowsError(try LibraryURLImportWriter.validate(closed, directory: writer.stagingDirectory,
      cancellation: cancelled, effects: observation.effects())) {
      XCTAssertEqual($0 as? LocalLibraryError, .cancelled)
    }
    let authority = try ProviderRequest()
    let capacity = authority.limit(authority.contract["pools"]["import"]["limit"].string)
    var leases: [RequestResourceLease] = []
    defer { for lease in leases { lease.close() } }
    for _ in 0..<(capacity - before) { leases.append(try XCTUnwrap(pool.acquire())) }
    XCTAssertThrowsError(try LibraryURLImportWriter.validate(closed, directory: writer.stagingDirectory,
      cancellation: ImportCancellation(), effects: observation.effects())) {
      XCTAssertEqual($0 as? URLImportError, .capacity)
    }
    XCTAssertEqual(pool.active, capacity)
    XCTAssertEqual(observation.snapshot.acquisitions, 0)
    XCTAssertEqual(observation.snapshot.closeAttempts, 0)
    XCTAssertEqual(LibraryURLImportWriter.rootedValidationIDs, roots)
    for lease in leases { lease.close() }
    XCTAssertEqual(pool.active, before)
    try await writer.abort(reason: .rejected)
  }

  // Permanent logical debt: run ONLY in a dedicated process, separate from the
  // adapter's irreversible unknown-close test and all ordinary tests.
  func testUnknownValidationCloseRetainsActualReadFDStageAndQuotaAfterFacadeLoss() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let db = try ProductDatabase.open(at: root)
    // No namespace teardown: uncertainty does not permit erasing an owned stage.
    var lifecycle: LocalLibraryLifecycle? = try await LocalLibraryLifecycle.open(database: db)
    let intent = try await continued()
    var writer: (any URLImportWriter)? = try await XCTUnwrap(lifecycle).grantURLImportWriter(for: intent)
    let closed = try await stage(XCTUnwrap(writer))
    let directory = try XCTUnwrap(writer).stagingDirectory
    let authority = try ProviderRequest()
    let pool = try RequestResourcePool(authority: authority, kind: "import")
    let before = pool.active
    let roots = LibraryURLImportWriter.rootedValidationIDs
    let observation = URLValidationObservation(pool: pool)
    let cancellation = ImportCancellation()
    var validation: Task<Void, any Error>? = Task {
      // Cancel after real open to prove close uncertainty outranks work failure.
      try LibraryURLImportWriter.validate(closed, directory: directory, cancellation: cancellation,
        effects: observation.effects(failClose: true, cancelOnOpen: cancellation))
    }
    do { try await validation?.value; XCTFail("unknown validation returned success") }
    catch { XCTAssertEqual(error as? URLImportError, .closureUnknown) }
    let fd = try XCTUnwrap(observation.snapshot.descriptor)
    defer {
      // Manual OS fixture cleanup is NOT logical ACK: root and quota remain.
      XCTAssertEqual(Darwin.close(fd), 0)
      XCTAssertEqual(pool.active, before + 1)
      XCTAssertEqual(LibraryURLImportWriter.rootedValidationIDs.subtracting(roots).count, 1)
      XCTAssertEqual(observation.snapshot.closeAttempts, 1)
    }
    validation = nil
    writer = nil
    lifecycle = nil
    for _ in 0..<20 { await Task.yield() }
    XCTAssertNotEqual(Darwin.fcntl(fd, F_GETFD), -1)
    XCTAssertEqual(observation.snapshot.readMode, O_RDONLY)
    XCTAssertEqual(observation.snapshot.permissions, 0o400)
    XCTAssertEqual(observation.snapshot.closeAttempts, 1)
    XCTAssertEqual(pool.active, before + 1)
    XCTAssertEqual(LibraryURLImportWriter.rootedValidationIDs.subtracting(roots).count, 1)
    XCTAssertEqual(try Data(contentsOf: closed.file), URLWriterFixture.bytes)
    let capacity = authority.limit(authority.contract["pools"]["import"]["limit"].string)
    var leases: [RequestResourceLease] = []
    defer { for lease in leases { lease.close() } }
    for _ in 0..<(capacity - before - 1) { leases.append(try XCTUnwrap(pool.acquire())) }
    XCTAssertEqual(pool.active, capacity)
    XCTAssertNil(pool.acquire())
    XCTAssertThrowsError(try LibraryURLImportWriter.validate(closed, directory: directory,
      cancellation: ImportCancellation(), effects: .actual)) {
      XCTAssertEqual($0 as? URLImportError, .capacity)
    }
    XCTAssertEqual(observation.snapshot.closeAttempts, 1)
    // Direct actual validator evidence only: this does not inject the lifecycle's
    // publishing call or prove its uncertainty/no-ready transition.
  }

  @MainActor
  func testPrepareCancelAndUnconsumedFactoryCannotReserve() async throws {
    let db = try database()
    let lifecycle = try await LocalLibraryLifecycle.open(database: db)
    let service = URLImportService(authority: try ProviderRequest())
    try service.prepare("https://writer.invalid/pdf", destination: "Library", possibleDuplicate: false)
    let intent = try XCTUnwrap(service.confirmation)
    do { _ = try await lifecycle.grantURLImportWriter(for: intent); XCTFail("prepared intent granted") }
    catch { XCTAssertEqual(error as? URLImportError, .writerUnavailable) }
    service.cancelConfirmation()
    do { _ = try await lifecycle.grantURLImportWriter(for: intent); XCTFail("cancelled intent granted") }
    catch { XCTAssertEqual(error as? URLImportError, .writerUnavailable) }
    XCTAssertTrue(try db.libraryRecords().isEmpty)
  }

  func testActualLifecycleUnknownValidationCannotPublishOrEraseItsNamespace() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let db = try ProductDatabase.open(at: root)
    let pool = try RequestResourcePool(authority: ProviderRequest(), kind: "import")
    let before = pool.active
    let roots = LibraryURLImportWriter.rootedValidationIDs
    let observation = URLValidationObservation(pool: pool)
    var lifecycle: LocalLibraryLifecycle? = try await LocalLibraryLifecycle.openForOwnedURLValidationFixtures(
      database: db, effects: observation.effects(failClose: true))
    var writer: (any URLImportWriter)? = try await XCTUnwrap(lifecycle).grantURLImportWriter(for: continued())
    let closed = try await stage(XCTUnwrap(writer))
    let directory = try XCTUnwrap(writer).stagingDirectory
    do { _ = try await XCTUnwrap(writer).publish(closed); XCTFail("uncertain validation published") }
    catch { XCTAssertEqual(error as? URLImportError, .closureUnknown) }
    let fd = try XCTUnwrap(observation.snapshot.descriptor)
    defer {
      // Physical fixture cleanup is not a logical receipt or quota acknowledgment.
      XCTAssertEqual(Darwin.close(fd), 0)
      XCTAssertEqual(pool.active, before + 1)
      XCTAssertEqual(LibraryURLImportWriter.rootedValidationIDs.subtracting(roots).count, 1)
    }
    // A later cancellation must not downgrade the actual validator's unknown close.
    try await XCTUnwrap(writer).abort(reason: .cancelled)
    let record = try XCTUnwrap(db.libraryRecords().first)
    XCTAssertEqual(record.status, .importFailed)
    XCTAssertTrue(record.cleanupDebt)
    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("document.pdf").path))
    XCTAssertEqual(try Data(contentsOf: closed.file), URLWriterFixture.bytes)
    do { try await XCTUnwrap(lifecycle).delete(paperID: record.id); XCTFail("uncertain namespace erased") }
    catch { XCTAssertEqual(error as? LocalLibraryError, .agentPurgeUnavailable) }
    XCTAssertEqual(try db.libraryRecords().map(\.status), [.deletionFailed])
    XCTAssertEqual(try Data(contentsOf: closed.file), URLWriterFixture.bytes)
    writer = nil
    lifecycle = nil
    for _ in 0..<20 { await Task.yield() }
    XCTAssertNotEqual(Darwin.fcntl(fd, F_GETFD), -1)
    XCTAssertEqual(observation.snapshot.closeAttempts, 1)
    XCTAssertEqual(pool.active, before + 1)
    XCTAssertEqual(LibraryURLImportWriter.rootedValidationIDs.subtracting(roots).count, 1)
    XCTAssertTrue(try XCTUnwrap(ProductDatabase.open(at: root).libraryRecords().first).cleanupDebt)
  }

  func testOneReservedIdentityPublishesRealClosedStageIntoConfirmedFolder() async throws {
    let db = try database()
    let folder = try db.createFolder(name: "Confirmed")
    let lifecycle = try await LocalLibraryLifecycle.open(database: db)
    let intent = try await continued(folder: folder.id)
    let writer = try await lifecycle.grantURLImportWriter(for: intent)
    let reserved = try XCTUnwrap(db.libraryRecords().first)
    let job = try db.adapterRead { try Row.fetchOne($0, sql: "SELECT * FROM importJob") }
    XCTAssertEqual(try db.adapterRead { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM importJob") }, 1)
    do { _ = try await lifecycle.grantURLImportWriter(for: intent); XCTFail("intent granted twice") }
    catch { XCTAssertEqual(error as? URLImportError, .writerUnavailable) }
    let closed = try await stage(writer)
    let id = try await writer.publish(closed)
    XCTAssertEqual(id, reserved.id)
    XCTAssertEqual(try db.folderID(for: id), folder.id)
    XCTAssertEqual(try db.libraryRecords().map(\.status), [.ready])
    XCTAssertEqual(try db.adapterRead {
      try String.fetchOne($0, sql: "SELECT pdfSHA256 FROM paper WHERE id = ?",
        arguments: [id.uuidString])
    }, closed.sha256)
    XCTAssertEqual(try db.libraryRecords().first?.title, "HTTPS PDF")
    let published = try db.adapterRead { try Row.fetchOne($0, sql: "SELECT * FROM importJob") }
    for key in ["id", "paperID", "attempt", "fence", "correlation", "input", "epoch", "writer", "publication"] {
      let before: String? = job?[key], after: String? = published?[key]
      XCTAssertEqual(before, after, key)
    }
    let final = writer.stagingDirectory.appendingPathComponent("document.pdf")
    XCTAssertEqual(try Data(contentsOf: final), URLWriterFixture.bytes)
    let attributes = try FileManager.default.attributesOfItem(atPath: final.path)
    XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o400)
    XCTAssertFalse(FileManager.default.fileExists(atPath: closed.file.path))
    do { _ = try await writer.publish(closed); XCTFail("stage published twice") }
    catch { XCTAssertEqual(error as? URLImportError, .writerUnavailable) }
    writer.revoke()
    try await writer.abort(reason: .cancelled)
    XCTAssertEqual(try Data(contentsOf: final), URLWriterFixture.bytes)
  }

  func testChangedOwnedBytesRejectedAndClosedCleanupDoesNotCreateSecondJob() async throws {
    let db = try database()
    let lifecycle = try await LocalLibraryLifecycle.open(database: db)
    let writer = try await lifecycle.grantURLImportWriter(for: continued())
    let closed = try await stage(writer)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: closed.file.path)
    try Data("%PDF-1.7\nchanged".utf8).write(to: closed.file)
    try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: closed.file.path)
    do { _ = try await writer.publish(closed); XCTFail("changed immutable bytes accepted") }
    catch { XCTAssertEqual(error as? URLImportError, .rejected) }
    writer.revoke()
    try await writer.abort(reason: .rejected)
    try await writer.abort(reason: .rejected)
    XCTAssertEqual(try db.libraryRecords().map(\.status), [.importFailed])
    XCTAssertEqual(try db.adapterRead { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM importJob") }, 1)
    XCTAssertFalse(FileManager.default.fileExists(atPath: writer.stagingDirectory.path))
  }

  func testForeignClosedStageCannotPublishIntoAnotherReservedNamespace() async throws {
    let db = try database()
    let lifecycle = try await LocalLibraryLifecycle.open(database: db)
    let first = try await lifecycle.grantURLImportWriter(for: continued())
    let second = try await lifecycle.grantURLImportWriter(for: continued())
    let closed = try await stage(first)
    do { _ = try await second.publish(closed); XCTFail("foreign stage accepted") }
    catch { XCTAssertEqual(error as? URLImportError, .rejected) }
    try await second.abort(reason: .rejected)
    XCTAssertTrue(FileManager.default.fileExists(atPath: closed.file.path))
    _ = try await first.publish(closed)
    XCTAssertEqual(try db.libraryRecords().filter { $0.status == .ready }.count, 1)
  }

  func testRemovedConfirmedFolderRejectsPublicationAndCleansClosedStage() async throws {
    let db = try database()
    let folder = try db.createFolder(name: "Removed")
    let lifecycle = try await LocalLibraryLifecycle.open(database: db)
    let writer = try await lifecycle.grantURLImportWriter(for: continued(folder: folder.id))
    let closed = try await stage(writer)
    try db.deleteFolder(id: folder.id)
    do { _ = try await writer.publish(closed); XCTFail("removed folder accepted") } catch {}
    try await writer.abort(reason: .rejected)
    XCTAssertEqual(try db.libraryRecords().map(\.status), [.importFailed])
    XCTAssertFalse(FileManager.default.fileExists(atPath: writer.stagingDirectory.path))
  }

  func testUnknownClosureRetainsDebtAndRetryDeletionUsesSameSaga() async throws {
    let db = try database()
    let agent = URLWriterAgent(root: db.root.appendingPathComponent("agent"))
    let lifecycle = try await LocalLibraryLifecycle.open(database: db, agentPurge: agent)
    let writer = try await lifecycle.grantURLImportWriter(for: continued())
    let closed = try await stage(writer)
    let id = try XCTUnwrap(db.libraryRecords().first).id
    // A conservative typed unknown report must not be upgraded merely because a
    // terminal failure was received. No synthetic successful stage is constructed.
    try await writer.abort(reason: .closureUnknown)
    XCTAssertTrue(try XCTUnwrap(db.libraryRecords().first).cleanupDebt)
    for _ in 0..<2 {
      do { try await lifecycle.delete(paperID: id); XCTFail("unknown closure purged") } catch {}
      XCTAssertTrue(FileManager.default.fileExists(atPath: closed.file.path))
    }
    let sagas = await agent.sagas()
    XCTAssertEqual(sagas.count, 2)
    XCTAssertEqual(sagas.first, sagas.last)
    XCTAssertEqual(try db.libraryRecords().map(\.status), [.deletionFailed])
  }

  @MainActor
  func testDeletionCancelsActualTransportButWaitsForAbortAfterDrain() async throws {
    let db = try database()
    let lifecycle = try await LocalLibraryLifecycle.open(database: db)
    let writer = try await lifecycle.grantURLImportWriter(for: continued())
    let actual = try XCTUnwrap(writer as? LibraryURLImportWriter)
    let download = Task { try await stage(writer, stall: true) }
    try actual.bindDownload(download)
    for _ in 0..<300 {
      if URLWriterFixture.state.started { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertTrue(URLWriterFixture.state.started)
    let id = actual.identity.paperID
    let deletion = Task { try await lifecycle.delete(paperID: id) }
    do { _ = try await download.value; XCTFail("revoked network completed") } catch {}
    XCTAssertTrue(URLWriterFixture.state.stopped)
    // Namespace still exists: transport cancellation/drain alone cannot release census.
    XCTAssertTrue(FileManager.default.fileExists(atPath: writer.stagingDirectory.path))
    let saga = try db.adapterRead { sql in
      try XCTUnwrap(String.fetchOne(sql, sql: "SELECT deletionID FROM paper WHERE id = ?",
        arguments: [id.uuidString]))
    }
    try await writer.abort(reason: .cancelled)
    do { try await deletion.value; XCTFail("missing Agent reported success") }
    catch { XCTAssertEqual(error as? LocalLibraryError, .agentPurgeUnavailable) }
    XCTAssertEqual(try db.libraryRecords().map(\.status), [.deletionFailed])
    try db.adapterRead { sql in
      XCTAssertEqual(try String.fetchOne(sql, sql: "SELECT deletionID FROM paper WHERE id = ?",
        arguments: [id.uuidString]), saga)
      XCTAssertEqual(try String.fetchOne(sql, sql: "SELECT state FROM importJob WHERE id = ?",
        arguments: [actual.identity.jobID.uuidString]), "failed")
      XCTAssertEqual(try String.fetchOne(sql, sql: "SELECT attempt FROM importJob WHERE id = ?",
        arguments: [actual.identity.jobID.uuidString]), actual.identity.attempt.uuidString)
    }
    do { try writer.assertCurrent(); XCTFail("revoked capability current") } catch {}
  }

  func testPriorRevocationCancelsNewlyBoundRealTask() async throws {
    let db = try database()
    let lifecycle = try await LocalLibraryLifecycle.open(database: db)
    let writer = try await lifecycle.grantURLImportWriter(for: continued())
    let actual = try XCTUnwrap(writer as? LibraryURLImportWriter)
    writer.revoke()
    let download = Task { try await stage(writer) }
    try actual.bindDownload(download)
    do { _ = try await download.value; XCTFail("prior revocation ignored") } catch {}
    try await writer.abort(reason: .cancelled)
    XCTAssertFalse(FileManager.default.fileExists(atPath: writer.stagingDirectory.path))
  }
}

private final class URLValidationObservation: @unchecked Sendable {
  struct Snapshot {
    var descriptor: Int32?
    var acquisitions = 0
    var closeAttempts = 0
    var activeAtOpen = 0
    var activeAtClose = 0
    var readMode: Int32 = -1
    var permissions: mode_t = 0
  }
  private let lock = NSLock()
  private let pool: RequestResourcePool
  private var value = Snapshot()
  init(pool: RequestResourcePool) { self.pool = pool }
  var snapshot: Snapshot { lock.withLock { value } }
  func effects(failClose: Bool = false, cancelOnOpen: ImportCancellation? = nil)
    -> ActualURLStageValidationEffects {
    ActualURLStageValidationEffects(acquired: { fd in
      let active = self.pool.active
      let flags = Darwin.fcntl(fd, F_GETFL)
      var info = stat()
      XCTAssertEqual(Darwin.fstat(fd, &info), 0)
      XCTAssertNotEqual(flags, -1)
      XCTAssertNotEqual(flags & O_NONBLOCK, 0)
      XCTAssertNotEqual(Darwin.fcntl(fd, F_GETFD) & FD_CLOEXEC, 0)
      self.lock.withLock {
        self.value.descriptor = fd
        self.value.acquisitions += 1
        self.value.activeAtOpen = active
        self.value.readMode = flags & O_ACCMODE
        self.value.permissions = info.st_mode & 0o7777
      }
      cancelOnOpen?.cancel()
    }, checkedClose: { handle in
      let active = self.pool.active
      // Read the descriptor only while it is valid, before actual checked close.
      XCTAssertEqual(handle.fileDescriptor, self.snapshot.descriptor)
      self.lock.withLock {
        self.value.closeAttempts += 1
        self.value.activeAtClose = active
      }
      if failClose { throw URLImportError.cleanupFailed }
      try handle.close()
    })
  }
}

private final class URLConfirmationBox: @unchecked Sendable {
  private let lock = NSLock()
  private var intent: URLImportConfirmation?
  var value: URLImportConfirmation? { lock.withLock { intent } }
  func store(_ intent: URLImportConfirmation) { lock.withLock { self.intent = intent } }
}

private actor URLWriterAgent: AgentLibraryPurging {
  let root: URL
  private var invocations: [UUID] = []
  init(root: URL) { self.root = root }
  func sagas() -> [UUID] { invocations }
  func purgeLibraryPaper(paperID: UUID, deletionID: UUID) async throws -> AgentLibraryPurgeReceipt {
    invocations.append(deletionID)
    let owned = root.appendingPathComponent(paperID.uuidString)
    if FileManager.default.fileExists(atPath: owned.path) { try FileManager.default.removeItem(at: owned) }
    guard !FileManager.default.fileExists(atPath: owned.path) else { throw URLImportError.cleanupFailed }
    return AgentLibraryPurgeReceipt(paperID: paperID, deletionID: deletionID)
  }
}

private final class URLWriterFixture: URLProtocol, @unchecked Sendable {
  static let bytes = Data("%PDF-1.7\nfixture".utf8)
  final class State: @unchecked Sendable {
    private let lock = NSLock()
    private var didStart = false
    private var didStop = false
    var started: Bool { lock.withLock { didStart } }
    var stopped: Bool { lock.withLock { didStop } }
    func start() { lock.withLock { didStart = true; didStop = false } }
    func stop() { lock.withLock { didStop = true } }
  }
  static let state = State()
  override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "writer.invalid" }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    guard let url = request.url else { return }
    if url.path == "/stall" { Self.state.start(); return }
    let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
      headerFields: ["Content-Type": "application/pdf"])!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Self.bytes)
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() { if request.url?.path == "/stall" { Self.state.stop() } }
}
