import Foundation
import GRDB

extension ProductDatabase {
  // The caller aliases paper as p. Bind metadata to the visible revision of the same live PDF.
  static let currentLibraryMetadataJoins = """
    LEFT JOIN extractionVisible v ON v.paperID = p.id AND p.status = 'ready' AND p.deletionID IS NULL
    LEFT JOIN extractionRevision r ON r.id = v.revision AND r.paperID = p.id
      AND r.generation = p.generation AND r.pdfSHA256 = p.pdfSHA256
      AND r.pdfReference = p.pdfReference
    LEFT JOIN readerMetadata m ON m.paperID = p.id AND m.revisionID = r.id
    """

  static func decodeReaderMetadata(_ payload: Data?) throws -> ReaderMetadataSnapshot? {
    guard let payload else { return nil }
    do {
      let snapshot = try JSONDecoder().decode(ReaderMetadataSnapshot.self, from: payload)
      try snapshot.validate()
      return snapshot
    } catch is DecodingError {
      throw ReaderMetadataError.invalidMetadata
    }
  }

  static func libraryMetadataObservation(_ payload: Data?) throws -> (snapshot: ReaderMetadataSnapshot?, invalid: Bool) {
    do { return (try decodeReaderMetadata(payload), false) }
    catch ReaderMetadataError.invalidMetadata { return (nil, true) }
  }

  /// One read transaction binds read, year, metadata and Summary observations to the ready Paper/revision.
  public func librarySortFacts() throws -> [OrganizationSortFacts] {
    try adapterRead { try librarySortFacts(for: nil, in: $0) }
  }

  static func librarySummarySource(revision: UUID, in db: Database) throws -> LibrarySummarySource {
    guard let row = try Row.fetchOne(db, sql: """
      SELECT (SELECT count(*) FROM extractionSentence WHERE revision = ?) AS sentences,
        count(*) AS owners, coalesce(sum(length(originalAnchor)), 0) AS bytes
      FROM extractionGeometryOwner WHERE revision = ?
      """, arguments: [revision.uuidString, revision.uuidString])
    else { throw ProductDatabaseError.invalidRecord }
    return LibrarySummarySource(revision: revision, sentences: try row.decode(Int.self, forColumn: "sentences"),
      geometryOwners: try row.decode(Int.self, forColumn: "owners"),
      geometryBytes: try row.decode(Int.self, forColumn: "bytes"))
  }

  func librarySortFacts(for paperIDs: Set<UUID>?, in db: Database) throws -> [OrganizationSortFacts] {
    if paperIDs?.isEmpty == true { return [] }
    return try Row.fetchAll(db, sql: """
      SELECT p.id, p.generation, p.pdfSHA256, p.lastReadAt, r.id AS sourceRevision, m.payload
      FROM paper p
      \(Self.currentLibraryMetadataJoins)
      WHERE p.status = 'ready' AND p.deletionID IS NULL
      """).compactMap { row in
      let id: String = row["id"]
      let generation: String = row["generation"]
      guard let paperID = UUID(uuidString: id), let generationID = UUID(uuidString: generation)
      else { throw ProductDatabaseError.invalidRecord }
      guard paperIDs?.contains(paperID) ?? true else { return nil }
      let timestamp: Double? = row["lastReadAt"]
      guard timestamp?.isFinite != false else { throw ProductDatabaseError.invalidRecord }
      var year: Int?
      let metadata = try Self.libraryMetadataObservation(row.decode(Data?.self, forColumn: "payload")).snapshot
      if let field = metadata?.year {
        if !field.isConflict, let text = field.candidates.first?.text,
          !text.isEmpty, text.count <= 4, text.allSatisfy({ $0 >= "0" && $0 <= "9" }),
          let value = Int(text), (1...9999).contains(value) {
          year = value
        }
      }
      let pdfSHA256: String = try row.decode(String.self, forColumn: "pdfSHA256")
      var record: LibrarySummaryRecord?
      var availability: LibrarySummaryAvailability = .unavailable
      do {
        if let restored = try restoreLibrarySummary(paperID: paperID, geometry: nil, in: db) {
          guard restored.identity.paperID == paperID, restored.identity.generation == generationID,
            restored.identity.pdfSHA256 == pdfSHA256
          else { throw LibrarySummaryError.staleIdentity }
          record = restored
          availability = .available
        }
      } catch let error as DatabaseError {
        throw error
      } catch let error as RowDecodingError {
        throw error
      } catch LibrarySummaryError.geometryUnavailable {
        availability = .unavailable
      } catch {
        availability = .verificationFailed
      }
      var recentAttempt: LibrarySummaryRecentAttempt?
      // Insertion order is only a display observation, never action authority.
      if let job = try Row.fetchOne(db, sql: """
        SELECT job, attempt, fence, correlation, input, epoch, identity, state, failure
        FROM librarySummaryJob WHERE paperID = ? ORDER BY rowid DESC LIMIT 1
        """, arguments: [id]) {
        // SQL/storage decoding stays outside semantic isolation.
        let identityBytes = try job.decode(Data.self, forColumn: "identity")
        let jobID = try job.decode(String.self, forColumn: "job")
        let attemptID = try job.decode(String.self, forColumn: "attempt")
        let fence = try job.decode(String.self, forColumn: "fence")
        let correlation = try job.decode(String.self, forColumn: "correlation")
        let input = try job.decode(String.self, forColumn: "input")
        let epoch = try job.decode(String.self, forColumn: "epoch")
        let state = try job.decode(String.self, forColumn: "state")
        do {
          let activity: LibrarySummaryAttemptActivity
          switch state {
          case "running": activity = .running
          case "failed": activity = .failed
          case "succeeded": activity = .succeeded
          default: throw LibrarySummaryError.invalidResult
          }
          let identity = try JSONDecoder().decode(LibrarySummaryIdentity.self, from: identityBytes)
          guard identity.paperID == paperID, identity.generation == generationID,
            identity.pdfSHA256 == pdfSHA256,
            UUID(uuidString: jobID) == identity.job,
            UUID(uuidString: attemptID) == identity.attempt,
            UUID(uuidString: fence) == identity.fence,
            UUID(uuidString: correlation) == identity.correlation,
            UUID(uuidString: input) == identity.input,
            UUID(uuidString: epoch) == identity.epoch
          else { throw LibrarySummaryError.staleIdentity }
          let failure: LibrarySummaryFailure? = state == "failed"
            ? (job["failure"] as String?).flatMap(LibrarySummaryFailure.init(rawValue:))
            : nil
          recentAttempt = LibrarySummaryRecentAttempt(identity: identity, activity: activity,
            failure: failure)
        } catch {
          availability = .verificationFailed
        }
      }
      let source = try row.decode(String?.self, forColumn: "sourceRevision")
        .flatMap(UUID.init(uuidString:)).map { try Self.librarySummarySource(revision: $0, in: db) }
      let summary = LibrarySummaryObservation(record: record, recentAttempt: recentAttempt,
        availability: availability, source: source)
      return OrganizationSortFacts(paperID: paperID, generation: generationID,
        lastReadAt: timestamp.map(Date.init(timeIntervalSince1970:)), publicationYear: year,
        metadata: metadata, summary: summary)
    }
  }
}
