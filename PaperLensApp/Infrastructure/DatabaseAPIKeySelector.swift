import Foundation

/// The database, not the connection view, owns selector generations and model identity.
@MainActor
public final class DatabaseAPIKeySelector: APIKeySelectorPersistence {
  private let database: ProductDatabase
  private let model: String
  private var firstObservedEmptySelection: ProviderConfiguration?

  public init(database: ProductDatabase, configuration: NativeOpenAIConfiguration) {
    self.database = database
    model = configuration.model
  }

  public func selectorSnapshot() throws -> ProviderConfiguration {
    try database.providerConfiguration()
  }

  public func currentSelection() throws -> APIKeySelection? {
    let snapshot = try selectorSnapshot()
    if snapshot.slotID == nil, firstObservedEmptySelection == nil {
      firstObservedEmptySelection = snapshot
    }
    return snapshot.kind == .openAIAPIKey ? snapshot.slotSelection : nil
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

  public func compareAndSwap(expected: APIKeySelection?, slotID: UUID) throws -> APIKeySelection? {
    // Existing callers with only a slot receipt cannot identify a newer empty generation.
    let snapshot: ProviderConfiguration
    if let expected {
      snapshot = try selectorSnapshot()
      guard snapshot.kind == .openAIAPIKey, snapshot.slotSelection == expected else { return nil }
    } else {
      guard let firstObservedEmptySelection else { throw APIKeyConnectionError.persistenceFailure }
      snapshot = firstObservedEmptySelection
    }
    return try compareAndSwap(expected: snapshot, slotID: slotID)
  }
}
