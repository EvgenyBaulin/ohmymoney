import Foundation

/// A small typed shelf on the dataset for data that belongs to a layer above the analytics.
/// The dataset is read in one transaction and copied around as one value; the layers that
/// build on it (planning, subscriptions) can not be named by it, so they put their own types on
/// this shelf under a key of their own and read them back through a typed accessor they add to
/// `Dataset` (`Dataset.subscriptions`, `Dataset.yearPlan`).
public struct DatasetExtras: Sendable {
  private var storage: [String: any Sendable] = [:]

  public init() {}

  /// The value under `key` when it is a `Value`; `nil` when there is none or it is another type.
  public func value<Value: Sendable>(_ key: String, as type: Value.Type = Value.self) -> Value? {
    storage[key] as? Value
  }

  public mutating func set<Value: Sendable>(_ value: Value, for key: String) {
    storage[key] = value
  }

  public var keys: [String] { storage.keys.sorted() }
}
