import AppCore
import AppDatabase
import Foundation

/// The settings of the loading of statements. They live in the `settings` table of the database
/// (they travel in the archive), and are not steps of ⌘Z, like any other setting.
extension AppEnvironment {
  /// The category «Не разобрано», where an operation put off is filed (`nil`: not made yet).
  public func unsortedCategoryId() -> UUID? {
    (try? settings?.string(StatementSettings.unsortedCategoryKey)).flatMap {
      $0.flatMap(UUID.init(uuidString:))
    }
  }

  /// Remembers which category is «Не разобрано». Whether it landed.
  @discardableResult
  public func saveUnsortedCategory(_ id: UUID) -> Bool {
    attempt("settings.unsortedCategory", on: settings) {
      try $0.set(StatementSettings.unsortedCategoryKey, to: id.uuidString)
    }
  }
}
