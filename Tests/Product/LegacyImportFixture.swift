import Foundation
import GRDB
@testable import PaperLensProduct

/// Owned legacy SQL fixture only; never reconstructs permits or confirms fresh input.
func reserveLegacyImportFixture(in database: ProductDatabase, identity: ImportIdentity,
  title: String) throws {
  try database.adapterWrite { db in
    try ProductDatabase.insertImport(identity, title: title,
      createdAt: Date().timeIntervalSince1970, in: db)
    guard try Int.fetchOne(db, sql: """
      SELECT COUNT(*) FROM importJob WHERE id = ? AND recoveryJournal IS NULL
      """, arguments: [identity.jobID.uuidString]) == 1 else {
      throw ProductDatabaseError.invalidRecord
    }
  }
}


