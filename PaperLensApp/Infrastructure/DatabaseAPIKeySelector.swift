import Foundation

/// The database, not the connection view, owns selector generations and model identity.
@MainActor
public final class DatabaseAPIKeySelector: APIKeySelectorPersistence {
  private let database: ProductDatabase
  private let model: String

  public init(database: ProductDatabase, configuration: NativeOpenAIConfiguration) {
    self.database = database
    model = configuration.model
  }

  public func selectorSnapshot() throws -> ProviderConfiguration {
    try database.providerConfiguration()
  }

  public func selectionMatchesConfiguration(_ configuration: NativeOpenAIConfiguration) throws -> Bool {
    let snapshot = try database.providerConfiguration()
    return snapshot.kind == .openAIAPIKey && snapshot.slotID != nil
      && snapshot.model == configuration.model
      && configuration.model == model
  }

  public func compareAndSwap(expected: ProviderConfiguration, slotID: UUID) throws -> APIKeySelection? {
    do {
      let committed = try database.compareAndSwapProviderConfiguration(
        expected: expected, replacementKind: .openAIAPIKey,
        replacementSlotID: slotID, replacementModel: model)
      return committed.slotSelection
    } catch ProductDatabaseError.staleConfiguration {
      return nil
    }
  }
}
