import AppCore
import AppDatabase
import Foundation

/// The settings of the spending, income and savings screens. They live in the `settings` table
/// of the database (they travel in the archive), are read with the data (`Dataset`) and are not
/// steps of ⌘Z, like any other setting.
extension AppEnvironment {
  /// The proportions of the baskets, «only earnings», and the switch and memory of the line
  /// «spending follows income». Whether it landed.
  @discardableResult
  public func saveIncomeSavings(_ settings: IncomeSavingsSettings) -> Bool {
    attempt("settings.incomeSavings", on: spendingRules) { try $0.save(settings) }
  }

  /// The hours that count as the weekend (`analytics.weekend`).
  @discardableResult
  public func saveWeekend(_ window: WeekendWindow) -> Bool {
    attempt("settings.weekend", on: spendingRules) { try $0.save(weekend: window) }
  }

  /// The price in hours of work (`spending.workHours.*`).
  @discardableResult
  public func saveWorkHours(_ settings: WorkHoursSettings) -> Bool {
    attempt("settings.workHours", on: spendingRules) { try $0.save(workHours: settings) }
  }
}
