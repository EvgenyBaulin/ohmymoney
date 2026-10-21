import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation

/// Planning and reconciliation and the debts screen: pure functions over the
/// `Ledger` and the `PlanningBook`, the same on every platform. Amounts are `AmountE4`, all
/// arithmetic goes through `Decimal`, and a foreign amount is converted at the latest rate the
/// caller knows (`rubPerUnit`) or listed as without a rate — never guessed. No words of the
/// interface live here: results carry keys and numbers, the app supplies the words.
public enum CorePlanning {}
