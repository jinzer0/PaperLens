import CryptoKit
import Darwin
import Foundation
import GRDB
import ProviderRequest
import XCTest
@testable import PaperLensProduct

final class FolderImportTests: XCTestCase {
  // The only mutable hook state is protected by this lock, never held over close/read.
  private final class CloseCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    func record() {
      lock.lock()
      defer { lock.unlock() }
      calls += 1
    }
    var count: Int {
      lock.lock()
      defer { lock.unlock() }
      return calls
    }
  }

  private struct TestNamespacePurge: AgentLibraryPurging {
    func purgeLibraryPaper(paperID: UUID, deletionID: UUID) async throws -> AgentLibraryPurgeReceipt {
      // These fixtures never create an Agent namespace or start a producer.
      AgentLibraryPurgeReceipt(paperID: paperID, deletionID: deletionID)
    }
  }

  private func fixture() throws -> (URL, URL, ProductDatabase) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let source = root.appendingPathComponent("selected.pdf")
    try Data("%PDF-1.4\n1 0 obj << /Type /Catalog >> endobj\n%%EOF\n".utf8).write(to: source)
    let database = try ProductDatabase.open(at: root.appendingPathComponent("owned"))
    return (root, source, database)
  }

  func testCancelCreatesNoPaperJobOrOwnedCopyAndConsumesIntent() async throws {
    let (root, source, db) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let lifecycle = try await LocalLibraryLifecycle.open(database: db)
    let service = FolderImportService(database: db, lifecycle: lifecycle)
    let confirmation = try await service.prepare(source: source)
    XCTAssertEqual(confirmation.filename, "selected.pdf")
    XCTAssertTrue(confirmation.matchingPaperIDs.isEmpty)
    XCTAssertTrue(try db.libraryRecords().isEmpty)
    await service.cancel(confirmation.id)
    do {
      _ = try await service.continueImport(confirmation.id, destinationFolderID: nil)
      XCTFail("Cancelled intent must not import")
    } catch { XCTAssertEqual(error as? FolderImportError, .consumedIntent) }
    XCTAssertEqual(try db.adapterRead { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM importJob") }, 0)
    XCTAssertFalse(FileManager.default.fileExists(atPath: db.root.appendingPathComponent("papers").path))
  }

  func testChangedSourceRejectsBeforeReservation() async throws {
    let (root, source, db) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let lifecycle = try await LocalLibraryLifecycle.open(database: db)
    let service = FolderImportService(database: db, lifecycle: lifecycle)
    let confirmation = try await service.prepare(source: source)
    try Data("%PDF-1.4\nchanged content\n%%EOF\n".utf8).write(to: source)
    do {
      _ = try await service.continueImport(confirmation.id, destinationFolderID: nil)
      XCTFail("Changed source must require new confirmation")
    } catch { XCTAssertEqual(error as? FolderImportError, .sourceChanged) }
    XCTAssertTrue(try db.libraryRecords().isEmpty)
    XCTAssertEqual(try db.adapterRead { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM importJob") }, 0)
  }

  func testFoldersPersistRenameMoveDeleteAndInvalidDestinationPreservesPlacement() async throws {
    let (root, source, db) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let lifecycle = try await LocalLibraryLifecycle.open(database: db)
    let service = FolderImportService(database: db, lifecycle: lifecycle)
    let first = try await service.createFolder(name: " First ")
    let second = try await service.createFolder(name: "Second")
    let confirmation = try await service.prepare(source: source, destinationFolderID: first.id)
    let paper = try await service.continueImport(confirmation.id, destinationFolderID: first.id)
    XCTAssertEqual(try db.folderID(for: paper), first.id)
    try await service.renameFolder(id: first.id, name: "Renamed")
    let reopened = try ProductDatabase.open(at: db.root)
    XCTAssertEqual(try reopened.folders().first(where: { $0.id == first.id })?.name, "Renamed")
    XCTAssertEqual(try reopened.folderID(for: paper), first.id)
    let captured = try capture(reopened, paper)
    XCTAssertThrowsError(try reopened.movePaper(captured, to: UUID()))
    XCTAssertEqual(try reopened.folderID(for: paper), first.id)
    XCTAssertThrowsError(try reopened.renameFolder(id: first.id, name: " \n "))
    XCTAssertEqual(try reopened.folders().first(where: { $0.id == first.id })?.name, "Renamed")
    try await service.movePaper(captured, to: second.id)
    XCTAssertEqual(try reopened.folderID(for: paper), second.id)
    try await service.deleteFolder(id: second.id)
    XCTAssertNil(try reopened.folderID(for: paper))
    XCTAssertEqual(try reopened.libraryRecords().first?.status, .ready)
    XCTAssertTrue(FileManager.default.fileExists(atPath: pdf(db, paper).path))
  }

  func testDeletedDestinationDoesNotSilentlySubstituteDefault() async throws {
    let (root, source, db) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let lifecycle = try await LocalLibraryLifecycle.open(database: db)
    let service = FolderImportService(database: db, lifecycle: lifecycle)
    let folder = try await service.createFolder(name: "Chosen")
    let confirmation = try await service.prepare(source: source, destinationFolderID: folder.id)
    try await service.deleteFolder(id: folder.id)
    do {
      _ = try await service.continueImport(confirmation.id, destinationFolderID: folder.id)
      XCTFail("Deleted destination must fail")
    } catch { XCTAssertEqual(error as? FolderImportError, .missingFolder) }
    XCTAssertTrue(try db.libraryRecords().isEmpty)
  }

  func testDuplicateWarningFreshPhysicalOwnershipSingleUseAndSurvivorAfterDelete() async throws {
    let (root, source, db) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let lifecycle = try await LocalLibraryLifecycle.open(database: db, agentPurge: TestNamespacePurge())
    let service = FolderImportService(database: db, lifecycle: lifecycle)
    let initial = try await service.prepare(source: source)
    let first = try await service.continueImport(initial.id, destinationFolderID: nil)
    let duplicate = try await service.prepare(source: source)
    XCTAssertEqual(duplicate.matchingPaperIDs, [first])
    let second = try await service.continueImport(duplicate.id, destinationFolderID: nil)
    XCTAssertNotEqual(first, second)
    do {
      _ = try await service.continueImport(duplicate.id, destinationFolderID: nil)
      XCTFail("Accepted intent must not replay")
    } catch { XCTAssertEqual(error as? FolderImportError, .consumedIntent) }
    let firstPDF = pdf(db, first)
    let secondPDF = pdf(db, second)
    XCTAssertEqual(try Data(contentsOf: firstPDF), try Data(contentsOf: secondPDF))
    let firstAttributes = try FileManager.default.attributesOfItem(atPath: firstPDF.path)
    let secondAttributes = try FileManager.default.attributesOfItem(atPath: secondPDF.path)
    XCTAssertNotEqual(firstAttributes[.systemFileNumber] as? NSNumber,
      secondAttributes[.systemFileNumber] as? NSNumber)
    let capturedFirst = try capture(db, first)
    try await lifecycle.delete(paperID: first)
    let reopened = try ProductDatabase.open(at: db.root)
    XCTAssertEqual(try reopened.libraryRecords().map(\.id), [second])
    XCTAssertEqual(try Data(contentsOf: secondPDF), try Data(contentsOf: source))
    XCTAssertFalse(FileManager.default.fileExists(atPath: firstPDF.path))
    XCTAssertThrowsError(try reopened.movePaper(capturedFirst, to: nil))
  }

  func testCopiedBytesDigestMismatchCannotPublish() async throws {
    let (root, source, db) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let lifecycle = try await LocalLibraryLifecycle.open(database: db)
    // Direct owner regression for the revalidation-to-copy race boundary.
    _ = try await lifecycle.importPDF(from: source, expectedSHA256: String(repeating: "0", count: 64),
      destinationFolderID: nil)
    let records = try db.libraryRecords()
    XCTAssertFalse(records.contains(where: { $0.status == .ready }))
    XCTAssertTrue(try db.contentHashMatches(String(repeating: "0", count: 64)).isEmpty)
    for record in records { XCTAssertFalse(FileManager.default.fileExists(atPath: pdf(db, record.id).path)) }
  }

  func testConcurrentIndependentConfirmationsCreateSeparatePapers() async throws {
    let (root, source, db) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let lifecycle = try await LocalLibraryLifecycle.open(database: db)
    let service = FolderImportService(database: db, lifecycle: lifecycle)
    let firstIntent = try await service.prepare(source: source)
    let secondIntent = try await service.prepare(source: source)
    let firstResult = Task { () -> Result<UUID, Error> in
      do { return .success(try await service.continueImport(firstIntent.id, destinationFolderID: nil)) }
      catch { return .failure(error) }
    }
    let secondResult = Task { () -> Result<UUID, Error> in
      do { return .success(try await service.continueImport(secondIntent.id, destinationFolderID: nil)) }
      catch { return .failure(error) }
    }
    let outcomes = await [firstResult.value, secondResult.value]
    var admitted: [UUID] = []
    var denied = 0
    for outcome in outcomes {
      switch outcome {
      case .success(let id): admitted.append(id)
      case .failure(let error):
        guard error as? LocalLibraryError == .importCapacity else { throw error }
        denied += 1
      }
    }
    XCTAssertEqual(try db.libraryRecords().count, admitted.count)
    XCTAssertEqual(try db.adapterRead { try Int.fetchOne($0,
      sql: "SELECT COUNT(*) FROM importJob") }, admitted.count)
    for intent in [firstIntent, secondIntent] {
      do { _ = try await service.continueImport(intent.id, destinationFolderID: nil); XCTFail("Consumed intent replayed") }
      catch { XCTAssertEqual(error as? FolderImportError, .consumedIntent) }
    }
    // Fresh explicit fixture confirmations after joining admitted work, not an automatic product retry.
    for _ in 0..<denied {
      let fresh = try await service.prepare(source: source)
      admitted.append(try await service.continueImport(fresh.id, destinationFolderID: nil))
    }
    XCTAssertEqual(admitted.count, 2)
    let first = admitted[0], second = admitted[1]
    XCTAssertNotEqual(first, second)
    XCTAssertEqual(Set(try db.libraryRecords().map(\.id)), Set([first, second]))
    XCTAssertEqual(try Data(contentsOf: pdf(db, first)), try Data(contentsOf: pdf(db, second)))
    let firstAttributes = try FileManager.default.attributesOfItem(atPath: pdf(db, first).path)
    let secondAttributes = try FileManager.default.attributesOfItem(atPath: pdf(db, second).path)
    XCTAssertNotEqual(firstAttributes[.systemFileNumber] as? NSNumber,
      secondAttributes[.systemFileNumber] as? NSNumber)
  }

  func testInvalidRecognitionNeverReservesAndMissingPaperCannotBeAssigned() async throws {
    let (root, source, db) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let lifecycle = try await LocalLibraryLifecycle.open(database: db)
    let service = FolderImportService(database: db, lifecycle: lifecycle)
    try Data("not a PDF".utf8).write(to: source)
    do {
      _ = try await service.prepare(source: source)
      XCTFail("Invalid signature must not produce confirmation")
    } catch {}
    XCTAssertTrue(try db.libraryRecords().isEmpty)
    XCTAssertEqual(try db.adapterRead { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM importJob") }, 0)
    let folder = try db.createFolder(name: "Destination")
    XCTAssertThrowsError(try db.capturePaperPlacement(paperID: UUID(), generation: UUID())) { error in
      XCTAssertEqual(error as? FolderImportError, .paperNotReady)
    }
    XCTAssertEqual(try db.folders(), [folder])
  }

  func testSelectedSourceRealHashKnownCloseReleasesActualCapacity() async throws {
    let (root, source, db) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let pool = try RequestResourcePool(authority: ProviderRequest(), kind: "import")
    XCTAssertEqual(pool.active, 0)
    let lifecycle = try await LocalLibraryLifecycle.open(database: db)
    let calls = CloseCalls()
    let service = FolderImportService(database: db, lifecycle: lifecycle,
      closeSelectedSource: { handle in calls.record(); try handle.close() })
    let confirmation = try await service.prepare(source: source)
    let digest = SHA256.hash(data: try Data(contentsOf: source))
      .map { String(format: "%02x", $0) }.joined()
    XCTAssertEqual(confirmation.sha256, digest)
    XCTAssertEqual(calls.count, 1)
    XCTAssertEqual(pool.active, 0)
    XCTAssertFalse(FolderImportService.unknownSelectedSourceReads().contains { $0.source == source })
    try assertNoImportEffects(db)
  }

  func testUnknownCloseRetainsRealHandleLeaseAndScopeAfterFacadeLoss() async throws {
    let (root, source, db) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let authority = try ProviderRequest()
    let pool = try RequestResourcePool(authority: authority, kind: "import")
    XCTAssertEqual(pool.active, 0)
    let lifecycle = try await LocalLibraryLifecycle.open(database: db)
    let calls = CloseCalls()
    var service: FolderImportService? = FolderImportService(database: db, lifecycle: lifecycle,
      closeSelectedSource: { _ in
        calls.record()
        // Deliberately do not close the real fixture descriptor.
        throw CocoaError(.fileReadUnknown)
      })
    do {
      _ = try await service!.prepare(source: source)
      XCTFail("Unproved close must not create a confirmation")
    } catch { XCTAssertEqual(error as? LocalLibraryError, .producerClosureUnknown) }
    let pending = await service!.pendingConfirmationCount
    XCTAssertEqual(pending, 0)
    XCTAssertEqual(calls.count, 1)
    weak var retainedHandle: FileHandle?
    weak var retainedOwner: SelectedSourceReadOwner?
    do {
      let captured = try XCTUnwrap(FolderImportService.unknownSelectedSourceReads().first { $0.source == source })
      retainedHandle = captured.handle
      retainedOwner = captured
    }
    service = nil
    // No test-owned strong handle/owner exists at these assertions: the static root owns it.
    XCTAssertNotNil(retainedHandle)
    XCTAssertNotNil(retainedOwner)
    let debt = try XCTUnwrap(FolderImportService.unknownSelectedSourceReads().first { $0.source == source })
    // Manual owned-fixture teardown only, independent of runtime unknown state or ACK.
    defer {
      do {
        try debt.handle.close()
        debt.lease.close()
        if debt.securityScoped { debt.source.stopAccessingSecurityScopedResource() }
        XCTAssertEqual(pool.active, 0)
        XCTAssertTrue(FolderImportService.unknownSelectedSourceReads().contains { $0.id == debt.id })
      } catch { XCTFail("Fixture physical teardown failed: \(error)") }
    }
    XCTAssertEqual(pool.active, 1)
    let cap = authority.limit(authority.contract["pools"]["import"]["limit"].string)
    var remaining: [RequestResourceLease] = []
    defer { remaining.forEach { $0.close() } }
    for _ in 1..<cap { remaining.append(try XCTUnwrap(pool.acquire())) }
    XCTAssertEqual(pool.active, cap)
    XCTAssertNil(pool.acquire(), "The retained real lease must consume a contract-defined slot")
    // Inspect the captured real handle, not a possibly reused numeric descriptor.
    try debt.handle.seek(toOffset: 0)
    XCTAssertEqual(try debt.handle.read(upToCount: 5), Data("%PDF-".utf8))
    XCTAssertEqual(calls.count, 1)
    XCTAssertTrue(FolderImportService.unknownSelectedSourceReads().contains { $0.id == debt.id })
    try assertNoImportEffects(db)
  }

  func testSignatureFailureKnownClosePreservesTypedCauseAndReleasesCapacity() async throws {
    let (root, source, db) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("not a PDF".utf8).write(to: source)
    let pool = try RequestResourcePool(authority: ProviderRequest(), kind: "import")
    let lifecycle = try await LocalLibraryLifecycle.open(database: db)
    let calls = CloseCalls()
    let service = FolderImportService(database: db, lifecycle: lifecycle,
      closeSelectedSource: { handle in calls.record(); try handle.close() })
    do { _ = try await service.prepare(source: source); XCTFail("Invalid signature admitted") }
    catch {
      let failure = try XCTUnwrap(error as? RequestContractError)
      XCTAssertEqual(failure.code, "importRejected")
      XCTAssertEqual(failure.field, "import")
    }
    XCTAssertEqual(calls.count, 1)
    XCTAssertEqual(pool.active, 0)
    let pending = await service.pendingConfirmationCount
    XCTAssertEqual(pending, 0)
    try assertNoImportEffects(db)
  }

  func testSelectedSourceRejectsSpecialFilesAndOversizeWithoutReadOrReservation() async throws {
    let (root, source, db) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let lifecycle = try await LocalLibraryLifecycle.open(database: db)
    let service = FolderImportService(database: db, lifecycle: lifecycle)
    let symlink = root.appendingPathComponent("link.pdf")
    try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: source)
    let fifo = root.appendingPathComponent("pipe.pdf")
    XCTAssertEqual(fifo.withUnsafeFileSystemRepresentation { Darwin.mkfifo($0!, 0o600) }, 0)
    let directory = root.appendingPathComponent("directory.pdf")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    let large = root.appendingPathComponent("large.pdf")
    let empty = root.appendingPathComponent("empty.pdf")
    try Data().write(to: empty)
    try Data("%PDF-".utf8).write(to: large)
    let output = try FileHandle(forWritingTo: large)
    try output.truncate(atOffset: UInt64(try ProviderRequest().limit("pdfBytes")) + 1)
    try output.close()
    for candidate in [symlink, fifo, directory, empty, large] {
      do { _ = try await service.prepare(source: candidate); XCTFail("Invalid source admitted") }
      catch { XCTAssertEqual(error as? FolderImportError, .invalidSource) }
      XCTAssertEqual(try RequestResourcePool(authority: ProviderRequest(), kind: "import").active, 0)
    }
    let pending = await service.pendingConfirmationCount
    XCTAssertEqual(pending, 0)
    try assertNoImportEffects(db)
  }

  func testObservedRegularSourceSwapRejectsActualFIFOOrSymlinkOrDifferentInode() async throws {
    for replacement in ["fifo", "symlink", "regular"] {
      let (root, source, db) = try fixture()
      defer { try? FileManager.default.removeItem(at: root) }
      let target = root.appendingPathComponent("other.pdf")
      try Data("%PDF-1.4\nother\n%%EOF".utf8).write(to: target)
      let lifecycle = try await LocalLibraryLifecycle.open(database: db)
      let calls = CloseCalls()
      let service = FolderImportService(database: db, lifecycle: lifecycle,
        closeSelectedSource: { handle in calls.record(); try handle.close() },
        beforeOpen: { selected in
          // Move rather than unlink so the observed inode cannot be reused by replacement.
          try FileManager.default.moveItem(at: selected, to: root.appendingPathComponent("observed.pdf"))
          switch replacement {
          case "fifo":
            guard selected.withUnsafeFileSystemRepresentation({ Darwin.mkfifo($0!, 0o600) }) == 0
            else { throw CocoaError(.fileWriteUnknown) }
          case "symlink":
            try FileManager.default.createSymbolicLink(at: selected, withDestinationURL: target)
          default: try FileManager.default.copyItem(at: target, to: selected)
          }
        })
      do { _ = try await service.prepare(source: source); XCTFail("Swapped source admitted") }
      catch { XCTAssertEqual(error as? FolderImportError, .invalidSource) }
      XCTAssertEqual(calls.count, replacement == "symlink" ? 0 : 1)
      XCTAssertEqual(try RequestResourcePool(authority: ProviderRequest(), kind: "import").active, 0)
      let pending = await service.pendingConfirmationCount
      XCTAssertEqual(pending, 0)
      try assertNoImportEffects(db)
    }
  }

  func testCapturedMovementUnfiledAndReopenPreserveOwnedPDFAndPaperJobIdentity() async throws {
    let (root, source, db) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let lifecycle = try await LocalLibraryLifecycle.open(database: db)
    let service = FolderImportService(database: db, lifecycle: lifecycle)
    // Equal names must still represent distinct UUID destinations.
    let first = try await service.createFolder(name: "동일 이름")
    let second = try await service.createFolder(name: "동일 이름")
    let intent = try await service.prepare(source: source, destinationFolderID: first.id)
    let paper = try await service.continueImport(intent.id, destinationFolderID: first.id)
    let original = try capture(db, paper)
    let observed = try await service.capturePaperPlacement(paperID: paper, generation: original.generation)
    XCTAssertEqual(observed, original)
    XCTAssertEqual(observed.folder, first)
    let bytes = try Data(contentsOf: pdf(db, paper))
    let inode = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: pdf(db, paper).path)[.systemFileNumber] as? NSNumber)
    let papers = try db.adapterRead { try Row.fetchAll($0, sql: "SELECT * FROM paper ORDER BY id") }
    let jobs = try db.adapterRead { try Row.fetchAll($0, sql: "SELECT * FROM importJob ORDER BY id") }

    try await service.movePaper(observed, to: second.id)
    let reopened = try ProductDatabase.open(at: db.root)
    let moved = try reopened.capturePaperPlacement(paperID: paper, generation: original.generation)
    XCTAssertEqual(moved.folder, second)
    XCTAssertEqual(moved.sha256, original.sha256)
    XCTAssertEqual(moved.pdfReference, original.pdfReference)
    try reopened.movePaper(moved, to: nil)
    let unfiledDB = try ProductDatabase.open(at: db.root)
    let unfiled = try unfiledDB.capturePaperPlacement(paperID: paper, generation: original.generation)
    XCTAssertNil(unfiled.folder)
    try unfiledDB.movePaper(unfiled, to: first.id)
    XCTAssertEqual(try ProductDatabase.open(at: db.root).folderID(for: paper), first.id)
    XCTAssertEqual(try db.adapterRead { try Row.fetchAll($0, sql: "SELECT * FROM paper ORDER BY id") }, papers)
    XCTAssertEqual(try db.adapterRead { try Row.fetchAll($0, sql: "SELECT * FROM importJob ORDER BY id") }, jobs)
    XCTAssertEqual(try Data(contentsOf: pdf(db, paper)), bytes)
    XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: pdf(db, paper).path)[.systemFileNumber] as? NSNumber, inode)
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: db.root.appendingPathComponent("papers").path), [paper.uuidString])
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: pdf(db, paper).deletingLastPathComponent().path), ["document.pdf"])
  }

  func testCapturedMovementRejectsReboundImmutableFactsDeletionAndMissingPaperWithoutWrite() async throws {
    let mutations = [
      "generation = '\(UUID().uuidString)'",
      "pdfSHA256 = '\(String(repeating: "0", count: 64))'",
      "pdfSHA256 = 'invalid'",
      "pdfReference = 'papers/other/document.pdf'",
      "pdfReference = NULL",
      "deletionID = '\(UUID().uuidString)'",
      "status = 'deleting'",
      "status = 'tombstone'",
    ]
    for mutation in mutations + ["missing"] {
      let (root, source, db) = try fixture()
      defer { try? FileManager.default.removeItem(at: root) }
      let lifecycle = try await LocalLibraryLifecycle.open(database: db)
      let service = FolderImportService(database: db, lifecycle: lifecycle)
      let first = try db.createFolder(name: "First")
      let destination = try db.createFolder(name: "Destination")
      let intent = try await service.prepare(source: source, destinationFolderID: first.id)
      let paper = try await service.continueImport(intent.id, destinationFolderID: first.id)
      let observed = try capture(db, paper)
      try db.adapterWrite { sql in
        if mutation == "missing" {
          try sql.execute(sql: "DELETE FROM importJob WHERE paperID = ?", arguments: [paper.uuidString])
          try sql.execute(sql: "DELETE FROM paper WHERE id = ?", arguments: [paper.uuidString])
        } else {
          try sql.execute(sql: "UPDATE paper SET \(mutation) WHERE id = ?", arguments: [paper.uuidString])
        }
      }
      try assertRejectedMove(db, observed, to: destination.id)
    }
  }

  func testCapturedMovementRejectsChangedPlacementFolderNameAndDeletedDestinationWithoutWrite() async throws {
    for change in ["move", "unfile", "rename", "deleteCurrent", "deleteDestination"] {
      let (root, source, db) = try fixture()
      defer { try? FileManager.default.removeItem(at: root) }
      let lifecycle = try await LocalLibraryLifecycle.open(database: db)
      let service = FolderImportService(database: db, lifecycle: lifecycle)
      let first = try db.createFolder(name: "First")
      let destination = try db.createFolder(name: "Destination")
      let intent = try await service.prepare(source: source, destinationFolderID: first.id)
      let paper = try await service.continueImport(intent.id, destinationFolderID: first.id)
      let observed = try capture(db, paper)
      switch change {
      case "move": try db.movePaper(observed, to: destination.id)
      case "unfile": try db.movePaper(observed, to: nil)
      case "rename": try db.renameFolder(id: first.id, name: "Renamed")
      case "deleteCurrent": try db.deleteFolder(id: first.id)
      default: try db.deleteFolder(id: destination.id)
      }
      try assertRejectedMove(db, observed, to: destination.id)
      // A fresh, explicit observation can be saved; the old command is never replayed.
      let fresh = try capture(db, paper)
      try db.movePaper(fresh, to: nil)
      XCTAssertNil(try db.folderID(for: paper))
    }
  }

  func testCaptureRequiresRequestedGenerationAndValidStoredIdentity() async throws {
    let (root, source, db) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let lifecycle = try await LocalLibraryLifecycle.open(database: db)
    let service = FolderImportService(database: db, lifecycle: lifecycle)
    let intent = try await service.prepare(source: source)
    let paper = try await service.continueImport(intent.id, destinationFolderID: nil)
    let observed = try capture(db, paper)
    XCTAssertThrowsError(try db.capturePaperPlacement(paperID: paper, generation: UUID())) { error in
      XCTAssertEqual(error as? FolderImportError, .paperNotReady)
    }
    for mutation in ["pdfSHA256 = NULL", "pdfSHA256 = 'bad'", "pdfReference = '../document.pdf'"] {
      try db.adapterWrite { try $0.execute(sql: "UPDATE paper SET \(mutation) WHERE id = ?", arguments: [paper.uuidString]) }
      XCTAssertThrowsError(try db.capturePaperPlacement(paperID: paper, generation: observed.generation)) { error in
        XCTAssertEqual(error as? ProductDatabaseError, .invalidRecord)
      }
      try db.adapterWrite { try $0.execute(sql: "UPDATE paper SET pdfSHA256 = ?, pdfReference = ? WHERE id = ?",
        arguments: [observed.sha256, observed.pdfReference, paper.uuidString]) }
    }
    try db.adapterWrite { try $0.execute(sql: "UPDATE paper SET generation = 'invalid' WHERE id = ?", arguments: [paper.uuidString]) }
    XCTAssertThrowsError(try db.capturePaperPlacement(paperID: paper, generation: observed.generation))
  }

  func testPlacementLoadFenceDismissalReplacementAndLateFailureAreQuiescent() async throws {
    let (root, source, db) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let lifecycle = try await LocalLibraryLifecycle.open(database: db)
    let paper = try await lifecycle.importPDF(from: source)
    let captured = try capture(db, paper)
    var state = PaperPlacementLoadState()
    let dismissed = state.begin(paperID: paper, generation: captured.generation)
    state.invalidate()
    XCTAssertFalse(state.accept(captured, folders: [], request: dismissed))
    state.reject(dismissed)
    XCTAssertFalse(state.loading)
    XCTAssertFalse(state.failed)
    XCTAssertNil(state.captured)
    let replaced = state.begin(paperID: paper, generation: captured.generation)
    let current = state.begin(paperID: paper, generation: captured.generation)
    XCTAssertFalse(state.accept(captured, folders: [], request: replaced))
    state.reject(replaced)
    XCTAssertTrue(state.loading)
    XCTAssertFalse(state.failed)
    XCTAssertTrue(state.accept(captured, folders: [], request: current))
    state.reject(replaced)
    state.reject(current)
    XCTAssertEqual(state.captured, captured)
    XCTAssertFalse(state.loading)
    XCTAssertFalse(state.failed)
    state.invalidate()
    XCTAssertNil(state.captured)
    XCTAssertTrue(state.folders.isEmpty)
  }

  func testPlacementLoadFenceRequiresCapturedTargetAndActualFolderBeforeFreshSave() async throws {
    let (root, source, db) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let lifecycle = try await LocalLibraryLifecycle.open(database: db)
    let folder = try db.createFolder(name: "Actual")
    let paper = try await lifecycle.importPDF(from: source, destinationFolderID: folder.id)
    let captured = try capture(db, paper)
    var state = PaperPlacementLoadState()
    let wrongTarget = state.begin(paperID: UUID(), generation: captured.generation)
    XCTAssertFalse(state.accept(captured, folders: [folder], request: wrongTarget))
    state.reject(wrongTarget)
    XCTAssertTrue(state.failed)
    let wrongGeneration = state.begin(paperID: paper, generation: UUID())
    XCTAssertFalse(state.accept(captured, folders: [folder], request: wrongGeneration))
    state.reject(wrongGeneration)
    let missingFolder = state.begin(paperID: paper, generation: captured.generation)
    XCTAssertFalse(state.accept(captured, folders: [], request: missingFolder))
    state.reject(missingFolder)
    XCTAssertNil(state.captured)
    XCTAssertFalse(state.loading)
    try db.renameFolder(id: folder.id, name: "Renamed")
    let renamedFolder = state.begin(paperID: paper, generation: captured.generation)
    XCTAssertFalse(state.accept(captured, folders: try db.folders(), request: renamedFolder))
    state.reject(renamedFolder)
    let current = try capture(db, paper)
    let fresh = state.begin(paperID: paper, generation: captured.generation)
    XCTAssertTrue(state.accept(current, folders: try db.folders(), request: fresh))
    XCTAssertEqual(state.captured, current)
    XCTAssertFalse(state.failed)
  }

  private func capture(_ db: ProductDatabase, _ paper: UUID) throws -> CapturedPaperPlacement {
    let raw = try XCTUnwrap(try db.adapterRead { try String.fetchOne($0,
      sql: "SELECT generation FROM paper WHERE id = ?", arguments: [paper.uuidString]) })
    let generation = try XCTUnwrap(UUID(uuidString: raw))
    return try db.capturePaperPlacement(paperID: paper, generation: generation)
  }

  private func assertRejectedMove(_ db: ProductDatabase, _ captured: CapturedPaperPlacement,
    to destination: UUID?) throws {
    let papers = try db.adapterRead { try Row.fetchAll($0, sql: "SELECT * FROM paper ORDER BY id") }
    let jobs = try db.adapterRead { try Row.fetchAll($0, sql: "SELECT * FROM importJob ORDER BY id") }
    let placements = try db.adapterRead { try Row.fetchAll($0, sql: "SELECT * FROM paperFolder ORDER BY paperID") }
    let bytes = try Data(contentsOf: pdf(db, captured.paperID))
    let inode = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: pdf(db, captured.paperID).path)[.systemFileNumber] as? NSNumber)
    XCTAssertThrowsError(try db.movePaper(captured, to: destination))
    XCTAssertEqual(try db.adapterRead { try Row.fetchAll($0, sql: "SELECT * FROM paper ORDER BY id") }, papers)
    XCTAssertEqual(try db.adapterRead { try Row.fetchAll($0, sql: "SELECT * FROM importJob ORDER BY id") }, jobs)
    XCTAssertEqual(try db.adapterRead { try Row.fetchAll($0, sql: "SELECT * FROM paperFolder ORDER BY paperID") }, placements)
    XCTAssertEqual(try Data(contentsOf: pdf(db, captured.paperID)), bytes)
    XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: pdf(db, captured.paperID).path)[.systemFileNumber] as? NSNumber, inode)
  }

  private func assertNoImportEffects(_ db: ProductDatabase) throws {
    XCTAssertTrue(try db.libraryRecords().isEmpty)
    XCTAssertEqual(try db.adapterRead { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM importJob") }, 0)
    XCTAssertFalse(FileManager.default.fileExists(atPath: db.root.appendingPathComponent("papers").path))
  }

  private func pdf(_ database: ProductDatabase, _ id: UUID) -> URL {
    database.root.appendingPathComponent("papers").appendingPathComponent(id.uuidString)
      .appendingPathComponent("document.pdf")
  }
}
