import AppCore
import CoreKit
import Foundation
import GRDB

extension TransactionRepository {
  /// What reading the kept formulas again came to: counts only.
  public struct FormulaCheck: Equatable, Sendable {
    /// Operations that keep a formula, deleted ones included.
    public var checked: Int
    /// Formulas that no longer came to their amount and were dropped.
    public var dropped: Int

    public init(checked: Int, dropped: Int) {
      self.checked = checked
      self.dropped = dropped
    }
  }

  /// Reads every formula kept with an operation (`amount_expr`) by today's rule for amounts
  /// typed by hand, and drops the ones that no longer come to their amount. The amount is the
  /// truth — it is what was saved and counted everywhere; the formula only shows how it was
  /// worked out. A single comma used to be decimal in every position, so «1,500+2,50» was
  /// saved as 4 and now reads as 1 502.50: such a formula goes, the 4 stays. A formula that
  /// cannot be read at all goes too. Every other formula stays exactly as it was written.
  ///
  /// Deleted operations are read as well, so ⌘Z never brings a stale formula back. Nothing else
  /// of the row changes, `updated_at` included: it orders my manual ratings, and dropping a
  /// formula is not an edit.
  @discardableResult
  public func dropFormulasThatNoLongerAddUp() throws -> FormulaCheck {
    try writer.write { db in
      let rows = try Row.fetchAll(
        db,
        sql: "SELECT id, amount_e4, amount_expr FROM transactions WHERE amount_expr IS NOT NULL")
      var stale: [String] = []
      for row in rows {
        // A row another program wrote with an amount that is no number is passed over, left
        // as it is: the load of the history says what is wrong with it, and a check run at
        // every start must not stop the app on it.
        guard let id: String = row["id"], let formula: String = row["amount_expr"],
          let amount = try? RowMapping.amount(row, "amount_e4")
        else { continue }
        if !Self.formula(formula, comesTo: amount) { stale.append(id) }
      }
      for id in stale {
        try db.execute(
          sql: "UPDATE transactions SET amount_expr = NULL WHERE id = ?", arguments: [id])
      }
      return FormulaCheck(checked: rows.count, dropped: stale.count)
    }
  }

  /// Whether the formula, read today, comes to the amount to the last of its four digits.
  static func formula(_ formula: String, comesTo amount: AmountE4) -> Bool {
    guard let value = try? ExpressionEvaluator.evaluate(formula) else { return false }
    return (try? AmountE4(decimal: value)) == amount
  }
}
