import CoreAnalytics
import CoreKit
import Foundation

/// «Итог поездки»: what a trip cost, by day, by category and by currency, against its budget,
/// and what the people who travelled with the owner still owe. Every operation of the event
/// counts, whatever its date — tickets bought three months ago, the hotel, and what was spent
/// there. The figures are the ledger's, in rubles: the rubles of the bank's debits where they
/// have come, so the total is what actually left the accounts.
public struct TripSummary: Hashable, Sendable {
  public struct DayAmount: Hashable, Sendable {
    public var day: DateOnly
    public var amount: AmountE4
  }

  public struct CategoryAmount: Hashable, Sendable {
    /// The top-level category; `nil` — without one.
    public var categoryId: UUID?
    public var amount: AmountE4
  }

  public struct CurrencyAmount: Hashable, Sendable {
    public var currency: CurrencyCode
    /// In that currency.
    public var amount: AmountE4
    /// The rubles of the same operations.
    public var rubles: AmountE4
  }

  /// What one person still owes the owner for the trip: the parts paid for them (for «Пополам»
  /// and «Поровну» too, 0334) that have not come back, less what came back for each.
  public struct PersonShare: Hashable, Sendable {
    public var personId: UUID
    public var owed: AmountE4
    /// How many parts the amount is made of.
    public var parts: Int

    public init(personId: UUID, owed: AmountE4, parts: Int) {
      self.personId = personId
      self.owed = owed
      self.parts = parts
    }
  }

  public var eventId: UUID
  /// My expenses on the event over all its operations, in rubles.
  public var total: AmountE4
  /// By day of the zone each operation was recorded in, oldest first; days without a cost are
  /// not listed.
  public var byDay: [DayAmount]
  /// By top-level category, largest first.
  public var byCategory: [CategoryAmount]
  /// By currency of the operation, largest (in rubles) first.
  public var byCurrency: [CurrencyAmount]
  /// The budget in rubles; `nil` — the trip has none.
  public var budget: AmountE4?
  /// Budget minus total; negative when over.
  public var versusBudget: AmountE4? { budget.map { $0 - total } }
  /// The people who still owe, largest debt first; nobody owing is an empty list, and so is a
  /// trip nobody paid for.
  public var settlement: [PersonShare]

  public init(event: Event, ledger: Ledger, budgetRub: AmountE4?) {
    var total = AmountE4.zero
    var days: [DateOnly: AmountE4] = [:]
    var categories: [UUID?: AmountE4] = [:]
    var currencies: [CurrencyCode: (amount: AmountE4, rubles: AmountE4)] = [:]
    var owed: [UUID: (amount: AmountE4, parts: Int)] = [:]
    for row in ledger.rows where row.eventId == event.id {
      if row.reimbursable, row.reimbursementStatus == .expected,
        let person = row.debtorPersonId, row.kind == .expense
      {
        let left = ledger.remaining(ofPart: row)
        if !left.isZero {
          let current = owed[person] ?? (.zero, 0)
          owed[person] = (current.amount + left, current.parts + 1)
        }
      }
      let contribution = row.contribution
      guard !contribution.isZero else { continue }
      total += contribution
      days[row.day, default: .zero] += contribution
      categories[row.rootCategoryId, default: .zero] += contribution
      // The operation's own amount keeps the sign of what it contributes: a refund is negative.
      let own = contribution.isNegative ? -row.amountE4.magnitude : row.amountE4.magnitude
      let current = currencies[row.currency] ?? (.zero, .zero)
      currencies[row.currency] = (current.amount + own, current.rubles + contribution)
    }
    self.eventId = event.id
    self.total = total
    self.byDay = days.map { DayAmount(day: $0.key, amount: $0.value) }.sorted { $0.day < $1.day }
    self.byCategory = categories.map { CategoryAmount(categoryId: $0.key, amount: $0.value) }
      .sorted { left, right in
        left.amount != right.amount
          ? left.amount > right.amount
          : (left.categoryId?.uuidString ?? "") < (right.categoryId?.uuidString ?? "")
      }
    self.byCurrency = currencies.map {
      CurrencyAmount(currency: $0.key, amount: $0.value.amount, rubles: $0.value.rubles)
    }.sorted { left, right in
      left.rubles != right.rubles
        ? left.rubles > right.rubles : left.currency.code < right.currency.code
    }
    self.budget = budgetRub
    self.settlement = owed.map {
      PersonShare(personId: $0.key, owed: $0.value.amount, parts: $0.value.parts)
    }
    .sorted { left, right in
      left.owed != right.owed
        ? left.owed > right.owed : left.personId.uuidString < right.personId.uuidString
    }
  }

  /// What the trip cost on `day` (the zone of each operation), against the days of the trip.
  public func spent(on day: DateOnly) -> AmountE4 {
    byDay.first { $0.day == day }?.amount ?? .zero
  }

  /// What the trip cost before `day`.
  public func spent(before day: DateOnly) -> AmountE4 {
    AmountE4.sum(byDay.filter { $0.day < day }.map(\.amount))
  }

  /// «Сегодня потрачено / осталось на день» of the trip on `today`.
  public func allowance(event: Event, today: DateOnly) -> TripAllowance? {
    TripAllowance.make(
      budget: budget, spentBeforeToday: spent(before: today), spentToday: spent(on: today),
      endDate: event.endDate, today: today)
  }
}
