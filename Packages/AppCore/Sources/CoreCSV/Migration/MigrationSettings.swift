import CoreKit
import Foundation

/// What a move from another application remembers for the next time, in the `settings` table of
/// the book (so it travels with the archive): the mapping of columns per layout, the own
/// category each of the other application's categories went to, and the own account each of its
/// accounts went to. Each is one key holding JSON; an unreadable value reads as empty.
public enum MigrationSettings {
  /// `MigrationTable.signature` → `MigrationMapping`.
  public static let mappingsKey = "migration.mappings"
  /// `MigrationCategoryKey.id` → own category id.
  public static let categoryMapKey = "migration.categoryMap"
  /// Folded account name of the other application → own account id.
  public static let accountMapKey = "migration.accountMap"

  public static func mappings(from text: String?) -> [String: MigrationMapping] {
    decode(text) ?? [:]
  }

  public static func ids(from text: String?) -> [String: UUID] {
    let raw: [String: String] = decode(text) ?? [:]
    return raw.compactMapValues(UUID.init(uuidString:))
  }

  public static func text(_ mappings: [String: MigrationMapping]) -> String {
    encode(mappings)
  }

  public static func text(_ ids: [String: UUID]) -> String {
    encode(ids.mapValues(\.uuidString))
  }

  private static func decode<T: Decodable>(_ text: String?) -> T? {
    guard let data = text?.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(T.self, from: data)
  }

  private static func encode<T: Encodable>(_ value: T) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(value) else { return "{}" }
    return String(decoding: data, as: UTF8.self)
  }
}
