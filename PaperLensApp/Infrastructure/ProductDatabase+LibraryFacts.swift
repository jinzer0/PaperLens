import Foundation
import GRDB

extension ProductDatabase {
  /// One read transaction binds read, year and metadata observations to the ready Paper/revision.
  public func librarySortFacts() throws -> [OrganizationSortFacts] {
    try adapterRead { db in
      try Row.fetchAll(db, sql: """
        SELECT p.id, p.generation, p.lastReadAt, m.payload
        FROM paper p
        LEFT JOIN extractionVisible v ON v.paperID = p.id
        LEFT JOIN extractionRevision r ON r.id = v.revision AND r.paperID = p.id
          AND r.generation = p.generation AND r.pdfSHA256 = p.pdfSHA256
          AND r.pdfReference = p.pdfReference
        LEFT JOIN readerMetadata m ON m.paperID = p.id AND m.revisionID = r.id
        WHERE p.status = 'ready' AND p.deletionID IS NULL
        """).map { row in
          let id: String = row["id"], generation: String = row["generation"]
          guard let paperID = UUID(uuidString: id), let generationID = UUID(uuidString: generation)
          else { throw ProductDatabaseError.invalidRecord }
          let timestamp: Double? = row["lastReadAt"]
          guard timestamp?.isFinite != false else { throw ProductDatabaseError.invalidRecord }
          var year: Int?
          var metadata: ReaderMetadataSnapshot?
          if let payload: Data = row["payload"] {
            let snapshot = try JSONDecoder().decode(ReaderMetadataSnapshot.self, from: payload)
            try snapshot.validate()
            metadata = snapshot
            let field = snapshot.year
            if !field.isConflict, let text = field.candidates.first?.text,
              !text.isEmpty, text.count <= 4, text.allSatisfy({ $0 >= "0" && $0 <= "9" }),
              let value = Int(text), (1...9999).contains(value) {
              year = value
            }
          }
          return OrganizationSortFacts(paperID: paperID, generation: generationID,
            lastReadAt: timestamp.map(Date.init(timeIntervalSince1970:)), publicationYear: year,
            metadata: metadata)
        }
    }
  }
}
