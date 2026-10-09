import Foundation
import GRDB
import XCTest
@testable import PaperLensProduct

final class FolderImportTests: XCTestCase {
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
    XCTAssertThrowsError(try reopened.assignPaper(paper, to: UUID()))
    XCTAssertEqual(try reopened.folderID(for: paper), first.id)
    XCTAssertThrowsError(try reopened.renameFolder(id: first.id, name: " \n "))
    XCTAssertEqual(try reopened.folders().first(where: { $0.id == first.id })?.name, "Renamed")
    try await service.assignPaper(paper, to: second.id)
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
    try await lifecycle.delete(paperID: first)
    let reopened = try ProductDatabase.open(at: db.root)
    XCTAssertEqual(try reopened.libraryRecords().map(\.id), [second])
    XCTAssertEqual(try Data(contentsOf: secondPDF), try Data(contentsOf: source))
    XCTAssertFalse(FileManager.default.fileExists(atPath: firstPDF.path))
    XCTAssertThrowsError(try reopened.assignPaper(first, to: nil))
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
    XCTAssertThrowsError(try db.assignPaper(UUID(), to: folder.id)) { error in
      XCTAssertEqual(error as? FolderImportError, .paperNotReady)
    }
  }

  private func pdf(_ database: ProductDatabase, _ id: UUID) -> URL {
    database.root.appendingPathComponent("papers").appendingPathComponent(id.uuidString)
      .appendingPathComponent("document.pdf")
  }
}
