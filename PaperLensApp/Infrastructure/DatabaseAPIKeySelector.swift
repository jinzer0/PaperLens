import Foundation

/// The database, not the connection view, owns selector generations and model identity.
@MainActor
public final class DatabaseAPIKeySelector: APIKeySelectorPersistence {
  private let database: ProductDatabase
  private let model: String
  private var unselectedSnapshot: ProviderConfiguration?

  public init(database: ProductDatabase, configuration: NativeOpenAIConfiguration) {
    self.database = database
    model = configuration.model
  }

  public func currentSelection() throws -> APIKeySelection? {
    let snapshot = try database.providerConfiguration()
    guard let slotID = snapshot.slotID else {
      // nil has no token in the connection protocol. Never overwrite the first token:
      // a nil -> selected -> nil transition must lose, not silently acquire a new epoch.
      if unselectedSnapshot == nil { unselectedSnapshot = snapshot }
      return nil
    }
    return APIKeySelection(slotID: slotID, configGeneration: snapshot.generation)
  }

  public func selectionMatchesConfiguration(_ configuration: NativeOpenAIConfiguration) throws -> Bool {
    let snapshot = try database.providerConfiguration()
    return snapshot.kind == .openAIAPIKey && snapshot.slotID != nil
      && snapshot.model == configuration.model
      && configuration.model == model
  }

  public func compareAndSwap(expected: APIKeySelection?, slotID: UUID) throws -> APIKeySelection? {
    let snapshot: ProviderConfiguration
    if let expected {
      let current = try database.providerConfiguration()
      guard current.slotID == expected.slotID, current.generation == expected.configGeneration
      else { return nil }
      snapshot = current
    } else {
      guard let captured = unselectedSnapshot else {
        throw APIKeyConnectionError.persistenceFailure
      }
      snapshot = captured
    }
    do {
      let committed = try database.compareAndSwapProviderConfiguration(
        expected: snapshot, replacementKind: .openAIAPIKey,
        replacementSlotID: slotID, replacementModel: model)
      return APIKeySelection(slotID: slotID, configGeneration: committed.generation)
    } catch ProductDatabaseError.staleConfiguration {
      return nil
    }
  }
}
