import AppCore
import SwiftUI

/// What a card of the debts overview says, worked out from a `DebtLine` without a view: the
/// kind of debt (with its own word and symbol, never colour alone), how far it is paid, the
/// payment and the nearest due.
struct DebtCardModel: Identifiable, Equatable {
  enum Badge: String, Equatable {
    case existing, purchase, instalment, closed

    var symbol: String {
      switch self {
      case .existing: "clock.arrow.circlepath"
      case .purchase: "cart"
      case .instalment: "calendar.badge.clock"
      case .closed: "checkmark.circle"
      }
    }

    var key: String { "debts.badge.\(rawValue)" }
  }

  let id: UUID
  let name: String
  let badge: Badge
  let balance: AmountE4
  let currency: CurrencyCode
  /// 0…1 of what was borrowed that is already paid; `nil` when the journal has no borrowing.
  let progress: Double?
  /// What was borrowed on the debt and how much of it is paid, in the debt's currency: «87 400 из
  /// 230 000 ₽»; `nil` when the journal has no borrowing.
  let paid: AmountE4?
  let borrowed: AmountE4?
  let payment: AmountE4?
  let nextPayment: DateOnly?
  let rate: Decimal?

  init(_ line: DebtLine) {
    let debt = line.debt
    id = line.id
    name = debt.name
    badge = Self.badge(of: debt)
    balance = line.balanceRub ?? line.balance
    currency = line.balanceRub == nil ? debt.currency : .rub
    progress = Self.progress(of: line)
    let lent = Self.borrowed(of: line)
    borrowed = lent
    paid = lent.map { Self.paid(of: line, borrowed: $0) }
    payment = debt.monthlyPaymentE4
    nextPayment = line.nextPayment
    rate = debt.interestRate
  }

  static func badge(of debt: Debt) -> Badge {
    if debt.closed { return .closed }
    if debt.isInstalmentPlan { return .instalment }
    return debt.origin == .purchase ? .purchase : .existing
  }

  /// Everything borrowed on the debt: the sum of the lines of the journal that raised it.
  static func borrowed(of line: DebtLine) -> AmountE4? {
    let raised = AmountE4.sum(line.entries.lazy.map(\.amountE4).filter { $0.raw > 0 })
    return raised.raw > 0 ? raised : nil
  }

  /// What of `borrowed` is paid: the part no longer owed, never below nothing or above it.
  static func paid(of line: DebtLine, borrowed: AmountE4) -> AmountE4 {
    let left = max(line.balance, .zero)
    return left >= borrowed ? .zero : borrowed - left
  }

  /// Paid share of everything borrowed on the debt, clamped to 0…1.
  static func progress(of line: DebtLine) -> Double? {
    let borrowed = line.entries.filter { $0.amountE4.raw > 0 }
      .reduce(Decimal(0)) { $0 + Decimal($1.amountE4.raw) }
    guard borrowed > 0 else { return nil }
    let left = Decimal(max(line.balance.raw, 0))
    let share = (borrowed - left) / borrowed
    let value = NSDecimalNumber(decimal: share).doubleValue  // chart-only
    return min(max(value, 0), 1)
  }
}
