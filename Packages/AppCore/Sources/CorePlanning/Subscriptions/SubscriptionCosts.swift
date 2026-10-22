import CoreAnalytics
import CoreKit
import Foundation

// MARK: - What a subscription costs

/// One running subscription with what it costs, in the payment's currency and in rubles.
public struct SubscriptionLine: Identifiable, Hashable, Sendable {
  public var payment: ScheduledPayment
  /// The price on the day asked for (`SubscriptionMath.price`), in the payment's currency.
  public var price: AmountE4
  public var type: ServiceType?
  public var people: [UUID]
  /// One charge per month and per year, in the payment's currency.
  public var monthly: AmountE4
  public var yearly: AmountE4
  /// The same in rubles; `nil` without a rate for the currency, so the screen lists the line
  /// apart instead of guessing.
  public var monthlyRub: AmountE4?
  public var yearlyRub: AmountE4?

  public var id: UUID { payment.id }
}

/// The totals of all running subscriptions, in rubles.
public struct SubscriptionTotals: Hashable, Sendable {
  public var monthlyRub: AmountE4
  public var yearlyRub: AmountE4
  /// Subscriptions left out of the sums for want of a rate.
  public var withoutRate: [UUID]

  public init(monthlyRub: AmountE4, yearlyRub: AmountE4, withoutRate: [UUID]) {
    self.monthlyRub = monthlyRub
    self.yearlyRub = yearlyRub
    self.withoutRate = withoutRate
  }
}

public enum SubscriptionCosts {

  /// Running subscriptions: active, of kind subscription, not a one-off, with a next date,
  /// and not ended — a subscription cancelled «с 1 ноября» still runs until then.
  public static func isRunning(_ payment: ScheduledPayment, on today: DateOnly) -> Bool {
    guard payment.kind == .subscription, payment.active, !payment.isOneOff,
      payment.nextDate != nil
    else { return false }
    if let end = payment.endDate, end < today { return false }
    return true
  }

  /// The running subscriptions of the book on `today`, sorted by yearly cost in rubles
  /// (priciest first, those without a rate last), then by name.
  public static func lines(
    book: PlanningBook, subscriptions: SubscriptionBook, today: DateOnly,
    rubPerUnit: [CurrencyCode: Decimal]
  ) -> [SubscriptionLine] {
    let lines = book.scheduled.filter { isRunning($0, on: today) }.map {
      payment -> SubscriptionLine in
      let rule = RecurrenceRule(payment: payment)
      let price = SubscriptionMath.price(of: payment, on: today, prices: book.prices)
      let monthly = SubscriptionMath.monthlyEquivalent(price, rule: rule)
      let yearly = SubscriptionMath.yearlyEquivalent(price, rule: rule)
      let override = subscriptions.terms(of: payment.id)?.serviceType
      return SubscriptionLine(
        payment: payment, price: price,
        type: ServiceCatalog.type(of: payment.name, override: override),
        people: subscriptions.people(of: payment.id), monthly: monthly, yearly: yearly,
        monthlyRub: SubscriptionMath.rubles(monthly, in: payment.currency, rubPerUnit: rubPerUnit),
        yearlyRub: SubscriptionMath.rubles(yearly, in: payment.currency, rubPerUnit: rubPerUnit))
    }
    return lines.sorted { left, right in
      switch (left.yearlyRub, right.yearlyRub) {
      case (let first?, let second?) where first != second: return first > second
      case (.some, .none): return true
      case (.none, .some): return false
      default: return left.payment.name.lowercased() < right.payment.name.lowercased()
      }
    }
  }

  /// The sums of the lines that have a rate.
  public static func totals(of lines: [SubscriptionLine]) -> SubscriptionTotals {
    SubscriptionTotals(
      monthlyRub: AmountE4.sum(lines.compactMap(\.monthlyRub)),
      yearlyRub: AmountE4.sum(lines.compactMap(\.yearlyRub)),
      withoutRate: lines.filter { $0.yearlyRub == nil }.map(\.id))
  }

  /// Cost per day: a year's cost over 365 days, in rubles, rounded once.
  public static func perDay(yearlyRub: AmountE4) -> AmountE4 {
    SubscriptionMath.rounded(yearlyRub.decimal / 365)
  }
}

// MARK: - Year or month

/// What a yearly plan saves over twelve monthly ones.
public struct BillingComparison: Hashable, Sendable {
  public enum Cheaper: String, Hashable, Sendable { case yearly, monthly, same }

  /// Twelve monthly charges.
  public var twelveMonths: AmountE4
  public var yearlyPlan: AmountE4
  /// `twelveMonths − yearlyPlan`: positive when the yearly plan is cheaper.
  public var saving: AmountE4
  /// The saving as a share of twelve monthly charges, whole percent rounded half away from
  /// zero; negative when the yearly plan costs more.
  public var savingPercent: Int
  public var cheaper: Cheaper
  /// How many monthly charges the yearly plan costs (for «как 10 месяцев»), one decimal.
  public var equivalentMonths: Decimal
}

public enum BillingComparisons {
  /// The comparison for a subscription paid every month or every year. The payment's own price
  /// is one plan; the terms hold the other. `nil` when the other plan is unknown, the payment
  /// has another rhythm (every two months, weekly) or a price of zero.
  public static func compare(
    payment: ScheduledPayment, terms: SubscriptionTerms?, price: AmountE4
  ) -> BillingComparison? {
    guard let terms, payment.interval == 1 else { return nil }
    let monthly: AmountE4
    let yearly: AmountE4
    switch payment.freq {
    case .monthly:
      guard let plan = terms.yearlyPlanE4 else { return nil }
      monthly = price
      yearly = plan
    case .yearly:
      guard let plan = terms.monthlyPlanE4 else { return nil }
      monthly = plan
      yearly = price
    case .weekly:
      return nil
    }
    guard monthly.raw > 0, yearly.raw > 0 else { return nil }
    let twelve = SubscriptionMath.rounded(monthly.decimal * 12)
    let saving = twelve - yearly
    let percent = (saving.decimal * 100 / twelve.decimal)
    let months = (yearly.decimal / monthly.decimal)
    return BillingComparison(
      twelveMonths: twelve, yearlyPlan: yearly, saving: saving,
      savingPercent: Int(truncating: rounded(percent, scale: 0) as NSDecimalNumber),
      cheaper: saving.raw > 0 ? .yearly : (saving.raw < 0 ? .monthly : .same),
      equivalentMonths: rounded(months, scale: 1))
  }

  static func rounded(_ value: Decimal, scale: Int) -> Decimal {
    var input = value
    var output = Decimal()
    NSDecimalRound(&output, &input, scale, .plain)
    return output
  }
}

// MARK: - Family subscriptions

/// Who owes what of a shared subscription.
public struct FamilyShare: Hashable, Sendable {
  public var total: AmountE4
  /// My part; zero when the owner does not use it himself.
  public var mine: AmountE4
  public var others: [Share]

  public struct Share: Hashable, Sendable {
    public var personId: UUID
    public var amount: AmountE4
  }
}

public enum FamilyShares {
  /// Splits `amount` equally between the chosen people and, when he uses it, the owner —
  /// «Поровну на N» of the entry panel: shares add up to the amount exactly, the extra units
  /// going to the first share, which is the owner's. Nobody chosen — the owner pays all.
  public static func split(
    _ amount: AmountE4, people: [UUID], ownerUses: Bool = true
  ) -> FamilyShare {
    var seen = Set<UUID>()
    let unique = people.filter { seen.insert($0).inserted }
    guard !unique.isEmpty else { return FamilyShare(total: amount, mine: amount, others: []) }
    let count = unique.count + (ownerUses ? 1 : 0)
    var shares = amount.split(into: count)
    let mine = ownerUses ? shares.removeFirst() : .zero
    return FamilyShare(
      total: amount, mine: mine,
      others: zip(unique, shares).map { FamilyShare.Share(personId: $0, amount: $1) })
  }
}

// MARK: - Use

/// What a subscription costs for the use I made of it. Without marks there is only the price
/// per month and per day — marks are optional.
public struct UsageValue: Hashable, Sendable {
  /// Distinct days marked in the window.
  public var usedDays: Int
  /// The latest mark ever, if any.
  public var lastUsed: DateOnly?
  /// Monthly cost over the days used in the window; `nil` when no day was marked in it.
  public var perUseRub: AmountE4?
  public var hasMarks: Bool
}

public enum SubscriptionUsage {
  public static let defaultWindowDays = 30

  public static func value(
    paymentId: UUID, monthlyRub: AmountE4?, marks: [UsageMark], today: DateOnly,
    windowDays: Int = defaultWindowDays
  ) -> UsageValue {
    let own = marks.filter { $0.paymentId == paymentId && $0.day <= today }
    let start = today.adding(days: -(max(1, windowDays) - 1))
    let days = Set(own.map(\.day).filter { $0 >= start })
    var perUse: AmountE4?
    if let monthlyRub, !days.isEmpty {
      // The window is a month by default; for another length the monthly cost is scaled.
      let cost = monthlyRub.decimal * Decimal(max(1, windowDays)) / Decimal(defaultWindowDays)
      perUse = SubscriptionMath.rounded(cost / Decimal(days.count))
    }
    return UsageValue(
      usedDays: days.count, lastUsed: own.map(\.day).max(), perUseRub: perUse,
      hasMarks: !own.isEmpty)
  }
}
