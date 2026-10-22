import AppCore
import Foundation

/// The words of the loading of statements (the `Import` catalog).
@MainActor
enum ImportText {
  static let table = "Import"

  static func t(_ key: String, _ environment: AppEnvironment) -> String {
    environment.language(key, table: table)
  }

  static func format(
    _ key: String, _ environment: AppEnvironment, _ arguments: CVarArg...
  ) -> String {
    String(
      format: environment.language(key, table: table), locale: environment.language.locale,
      arguments: arguments)
  }

  /// A string whose arguments are all counts (`%lld`), each choosing its plural form.
  static func counted(_ key: String, _ environment: AppEnvironment, _ counts: Int...) -> String {
    environment.language.counted(key, table: table, counts)
  }
}
