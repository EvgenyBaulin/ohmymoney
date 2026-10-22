import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation

/// The band a floating payment is expected in: «около 4 000 ₽ ±10 %» is 3 600–4 400.
public struct FloatingBand: Hashable, Sendable {
  public var center: AmountE4
  public var tolerancePercent: Int
  public var low: AmountE4
  public var high: AmountE4

  public init(center: AmountE4, tolerancePercent: Int) {
    let percent = min(100, max(1, tolerancePercent))
    self.center = center
    self.tolerancePercent = percent
    let spread = center.decimal * Decimal(percent) / 100
    self.low = SubscriptionMath.rounded(center.decimal - spread)
    self.high = SubscriptionMath.rounded(center.decimal + spread)
  }

  public enum Position: String, Hashable, Sendable { case below, within, above }

  public func position(of amount: AmountE4) -> Position {
    if amount < low { return .below }
    if amount > high { return .above }
    return .within
  }
}

/// Payments whose amount floats (utilities, a bill by use): expected as a band, flagged only
/// when a charge leaves it.
public enum FloatingAmount {
  /// The half-width when there is too little history to work one out.
  public static let defaultTolerancePercent = 15
  public static let minimumTolerancePercent = 5
  public static let maximumTolerancePercent = 30
  /// Charges needed before the history speaks.
  public static let historyNeeded = 3
  /// A charge is news for this many days.
  public static let newsDays = 35

  /// The half-width in percent: the owner's own when set; else the widest distance of the past
  /// charges from the centre, rounded up to a whole percent and kept within 5…30; with fewer
  /// than three charges, 15.
  public static func tolerance(
    center: AmountE4, history: [AmountE4], override: Int? = nil
  ) -> Int {
    if let override { return min(100, max(1, override)) }
    guard history.count >= historyNeeded, center.raw > 0 else { return defaultTolerancePercent }
    var widest = Decimal(0)
    for amount in history {
      let distance = (amount.decimal - center.decimal).magnitude / center.decimal * 100
      widest = max(widest, distance)
    }
    var rounded = Decimal()
    var input = widest
    NSDecimalRound(&rounded, &input, 0, .up)
    let percent = Int(truncating: rounded as NSDecimalNumber)
    return min(maximumTolerancePercent, max(minimumTolerancePercent, percent))
  }

  /// The band of a payment: its amount as the centre, the tolerance of its terms or history.
  public static func band(
    payment: ScheduledPayment, terms: SubscriptionTerms?, history: [AmountE4]
  ) -> FloatingBand {
    FloatingBand(
      center: payment.amountE4,
      tolerancePercent: tolerance(
        center: payment.amountE4, history: history, override: terms?.tolerancePercent))
  }

  /// A rise of a floating payment inside its band is not «рост цены подписки»: the anomaly
  /// rule asks this before it speaks.
  public static func isNormal(_ amount: AmountE4, band: FloatingBand) -> Bool {
    band.position(of: amount) == .within
  }

  /// What a payment was charged, in its own currency, oldest first: the operations
  /// «Отметить оплаченным» wrote for it in the last `months` months.
  public static func charges(
    of payment: ScheduledPayment, ledger: Ledger, today: DateOnly, months: Int = 12
  ) -> [(transactionId: UUID, day: DateOnly, amount: AmountE4)] {
    var seen = Set<UUID>()
    var result: [(transactionId: UUID, day: DateOnly, amount: AmountE4)] = []
    for row in ledger.rows(in: DayRange(today.adding(months: -max(1, months)), today))
    where row.isFirstPart {
      guard case .scheduled(let id, _)? = row.link, id == payment.id,
        seen.insert(row.transactionId).inserted,
        let entry = ledger.entry(row.transactionId),
        entry.transaction.currency == payment.currency
      else { continue }
      result.append((row.transactionId, row.day, entry.transaction.amountE4))
    }
    return result
  }

  /// A notice for every floating payment whose latest charge, within `newsDays`, left the band
  /// worked out from the charges before it. One notice per charge: put off, it stays away.
  public static func notices(
    book: PlanningBook, subscriptions: SubscriptionBook, ledger: Ledger, today: DateOnly
  ) -> [SubscriptionNotice] {
    var result: [SubscriptionNotice] = []
    for payment in book.scheduled where payment.active {
      let terms = subscriptions.terms(of: payment.id)
      guard terms?.floating == true else { continue }
      let charges = Self.charges(of: payment, ledger: ledger, today: today)
      guard let last = charges.last, last.day.days(to: today) <= newsDays else { continue }
      let band = band(payment: payment, terms: terms, history: charges.dropLast().map(\.amount))
      guard band.position(of: last.amount) != .within else { continue }
      result.append(
        SubscriptionNotice(
          id:
            "subfloat:\(payment.id.uuidString.lowercased()):\(last.transactionId.uuidString.lowercased())",
          kind: .floatingOutside, paymentId: payment.id, day: last.day, amount: last.amount,
          currency: payment.currency, notifyOn: last.day, band: band))
    }
    return result.sorted { ($0.day, $0.id) < ($1.day, $1.id) }
  }
}
