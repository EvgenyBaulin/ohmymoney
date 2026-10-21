import CoreAccounting
import CoreKit
import Foundation

/// «Рассрочка»: a purchase paid in a number of parts. The debt is the price and the markup
/// together; the purchase is spent once, at its price, the way a purchase on credit is; each part
/// pays the same share of both, to the kopeck, the rest going to the last part.
///
/// By default the parts are four, every fourteen days, the first on the day of the purchase; a
/// plan paid on a day of every month has no step (`Debt.steps`) and a payment day instead.
public enum InstalmentPlan {
  /// The parts a plan has unless the owner says otherwise.
  public static let defaultCount = 4
  /// The days between two parts unless the owner says otherwise.
  public static let defaultEveryDays = 14

  /// Equal parts to the kopeck down, the rest to the last: 1,000 / 3 → 333.33, 333.33, 333.34;
  /// 9,999 / 4 → 2,499.75 × 4; 0.01 / 3 → 0, 0, 0.01. The parts always add up to `total`. None
  /// for fewer than one part.
  public static func parts(total: AmountE4, count: Int) -> [AmountE4] {
    guard count >= 1 else { return [] }
    let kopeck: Int64 = 100
    let each = total.raw / Int64(count) / kopeck * kopeck
    var result = Array(repeating: AmountE4(raw: each), count: count)
    result[count - 1] = AmountE4(raw: total.raw - each * Int64(count - 1))
    return result
  }

  /// The markup of each part by the same rule (600 / 4 → 150 × 4).
  public static func markupShares(markup: AmountE4, count: Int) -> [AmountE4] {
    parts(total: markup, count: count)
  }

  /// What each due asks for: its part of the price and its part of the markup. The due after the
  /// last asks for nothing — the plan has no more dues.
  public static func instalments(debt: Debt, price: AmountE4) -> DebtInstalments {
    let count = debt.parts ?? 1
    guard count >= 1, price.raw > 0 else { return .none }
    let prices = parts(total: price, count: count)
    let markups = markupShares(markup: debt.markupE4 ?? .zero, count: count)
    var steps: [DebtInstalments.Step] = []
    var last: AmountE4?
    for index in 0..<count {
      let amount = prices[index] + markups[index]
      if amount != last { steps.append(DebtInstalments.Step(fromIndex: index, amountE4: amount)) }
      last = amount
    }
    steps.append(DebtInstalments.Step(fromIndex: count, amountE4: .zero))
    return DebtInstalments(steps: steps)
  }

  /// The days of the dues, every `steps.everyDays` from `steps.firstDue`.
  public static func dueDays(steps: DebtSteps, count: Int) -> [DateOnly] {
    guard count >= 1 else { return [] }
    let every = max(1, steps.everyDays)
    return (0..<count).map { steps.firstDue.adding(days: $0 * every) }
  }

  /// The debt and its `borrowed` line (price + markup) naming the purchase; the purchase is the
  /// caller's expense, pointing at the debt as a purchase on credit does (`creditDebtId`). With
  /// `everyDays` the first part is due on the day of the purchase and every `everyDays` after it;
  /// without, the plan is paid on `paymentDay` of every month, the first time the month after the
  /// purchase when the day already came (`DebtStart`). The plan is written with its terms seen.
  public static func make(
    purchase: TransactionEntry, price: AmountE4, count: Int, everyDays: Int?, paymentDay: Int?,
    markup: AmountE4?, name: String, id: UUID, calendar: CalendarContext = .system
  ) -> (Debt, DebtEntry) {
    let day = calendar.day(of: purchase.transaction.occurredAt)
    let parts = min(max(count, 2), 120)
    let markup = markup.flatMap { $0.raw > 0 ? $0 : nil }
    let steps = everyDays.map {
      DebtSteps(
        everyDays: min(max($0, DebtSteps.range.lowerBound), DebtSteps.range.upperBound),
        firstDue: day)
    }
    let total = price + (markup ?? .zero)
    let first = self.parts(total: price, count: parts).first ?? .zero
    let firstMarkup = markupShares(markup: markup ?? .zero, count: parts).first ?? .zero
    let debt = Debt(
      id: id, direction: .iOwe, type: .installment, name: name,
      currency: purchase.transaction.currency,
      monthlyPaymentE4: steps == nil ? first + firstMarkup : nil,
      paymentDay: steps == nil ? paymentDay.map { min(max($0, 1), 31) } : nil,
      paymentsAreExpenses: false, origin: .purchase, steps: steps, parts: parts,
      markupE4: markup, termsReviewed: true)
    let line = DebtRules.makeEntry(
      debtId: id, kind: .borrowed, amountE4: total, date: day, transactionId: purchase.id)
    return (debt, line)
  }

  /// The price of a plan: what its journal borrowed — the price and the markup — less the
  /// markup. Lines without a day count; payments and lines that lower the debt do not.
  public static func price(of debt: Debt, journal: [DebtEntry]) -> AmountE4 {
    let borrowed = AmountE4.sum(
      journal.filter { $0.debtId == debt.id && $0.kind != .payment && $0.amountE4.raw > 0 }
        .map(\.amountE4))
    return max(borrowed - (debt.markupE4 ?? .zero), .zero)
  }
}
