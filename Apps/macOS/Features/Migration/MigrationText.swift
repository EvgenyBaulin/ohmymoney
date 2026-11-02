import AppCore
import Foundation

/// The words of the move from another application (the `Migration` catalog).
@MainActor
enum MigrationText {
  static let table = "Migration"

  static func t(_ key: String, _ environment: AppEnvironment) -> String {
    environment.language(key, table: table)
  }

  static func format(
    _ key: String, _ environment: AppEnvironment, _ arguments: CVarArg...
  )
    -> String
  {
    String(
      format: environment.language(key, table: table), locale: environment.language.locale,
      arguments: arguments)
  }

  /// A string whose arguments are all counts (`%lld`), each choosing its plural form.
  static func counted(_ key: String, _ environment: AppEnvironment, _ counts: Int...) -> String {
    environment.language.counted(key, table: table, counts)
  }

  /// The name of a role in the picker of a column.
  static func role(_ role: MigrationRole?, _ environment: AppEnvironment) -> String {
    t("migration.role." + (role?.rawValue ?? "none"), environment)
  }

  /// «Похоже на экспорт CoinKeeper» and the like.
  static func source(_ source: MigrationSourceKind, _ environment: AppEnvironment) -> String {
    t("migration.source." + source.rawValue, environment)
  }
}
