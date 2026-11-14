import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation

/// The income tax on the interest of deposits and savings accounts: interest above a sum that is
/// free of tax each year is taxed, the tax comes by a notice of the tax service the next year.
///
/// The free sum is 1 million rubles times the highest key rate of the year, so it is known only
/// when the year is over; the table the app carries marks a year still open as provisional.
public enum InterestTax {
  /// The free sum of a year, in whole rubles, as far as the app knows it.
  struct YearRow: Sendable {
    var year: Int
    var wholeRub: Int64
    var provisional: Bool
  }

  /// Newest last. 2025: 21 % × 1 million; 2026: 16 % × 1 million until the board of the central
  /// bank meets in December.
  static let table: [YearRow] = [
    YearRow(year: 2025, wholeRub: 210_000, provisional: false),
    YearRow(year: 2026, wholeRub: 160_000, provisional: true),
  ]

  /// Interest of a year past this sum, after the free one, is taxed at the higher rate.
  public static let higherRateFromRub: Int64 = 2_400_000
  public static let baseRate = Decimal(13) / 100
  public static let higherRate = Decimal(15) / 100

  /// The free sum of a year.
  public struct Exemption: Hashable, Sendable {
    public var year: Int
    public var amountE4: AmountE4
    /// The year is not over for the rate it rests on, or the table has no row for it and the
    /// last known one stands in: say «≈».
    public var isEstimate: Bool
  }

  /// The free sum of `year`; a year the table does not know takes the last known row.
  public static func exemption(year: Int) -> Exemption {
    if let row = table.first(where: { $0.year == year }) {
      return Exemption(
        year: year, amountE4: AmountE4(whole: row.wholeRub), isEstimate: row.provisional)
    }
    let last = table.last { $0.year < year } ?? table[0]
    return Exemption(year: year, amountE4: AmountE4(whole: last.wholeRub), isEstimate: true)
  }

  /// The last day to pay the tax of `year`: 1 December of the next year.
  public static func dueDay(year: Int) -> DateOnly { DateOnly(year: year + 1, month: 12, day: 1) }

  /// The tax on `interestRub` of one year, to the whole ruble.
  public struct Figure: Hashable, Sendable {
    public var year: Int
    public var interestE4: AmountE4
    public var exemption: Exemption
    /// Interest past the free sum; zero below it.
    public var taxableE4: AmountE4
    public var taxE4: AmountE4
    public var dueDay: DateOnly
    public var isEstimate: Bool { exemption.isEstimate }
  }

  public static func figure(year: Int, interestRub: AmountE4) -> Figure {
    let exemption = exemption(year: year)
    let taxable = max(.zero, interestRub - exemption.amountE4)
    let higher = AmountE4(whole: higherRateFromRub)
    let low = min(taxable, higher).decimal * baseRate
    let high = max(.zero, taxable - higher).decimal * higherRate
    let tax = (try? AmountE4(decimal: DecimalMath.round(low + high, scale: 0))) ?? .zero
    return Figure(
      year: year, interestE4: interestRub, exemption: exemption, taxableE4: taxable, taxE4: tax,
      dueDay: dueDay(year: year))
  }

  /// What the books say of the interest of one year.
  public struct Year: Hashable, Sendable {
    public var year: Int
    /// Interest already written as income (the category of interest), in rubles.
    public var receivedE4: AmountE4
    /// Interest earned so far and not written yet: the payouts still to come, counted as far as
    /// the day has accrued.
    public var accruedE4: AmountE4
    /// Interest expected through the end of the year: received plus every payout still to come.
    public var expectedE4: AmountE4
    /// Payouts in a currency without a rate left out; never guessed.
    public var withoutRate: [CurrencyCode]

    public init(
      year: Int, receivedE4: AmountE4, accruedE4: AmountE4, expectedE4: AmountE4,
      withoutRate: [CurrencyCode] = []
    ) {
      self.year = year
      self.receivedE4 = receivedE4
      self.accruedE4 = accruedE4
      self.expectedE4 = expectedE4
      self.withoutRate = withoutRate
    }

    /// The tax on what has been earned through today — the part the money on the accounts
    /// already owes.
    public var sofar: Figure { InterestTax.figure(year: year, interestRub: receivedE4 + accruedE4) }
    /// The tax on the whole year, as far as it can be seen now.
    public var forecast: Figure { InterestTax.figure(year: year, interestRub: expectedE4) }
  }

  /// The interest of `today`'s year. `payouts` are `DepositPayouts.build` through the end of the
  /// year; payouts the owner already wrote as income are in `received` through the ledger.
  public static func year(
    ledger: Ledger, payouts: [DepositPayout], interestCategoryId: UUID?, today: DateOnly,
    rubPerUnit: [CurrencyCode: Decimal]
  ) -> Year {
    let year = today.year
    var received = AmountE4.zero
    if let interestCategoryId {
      for row in ledger.rows
      where row.isIncome && row.categoryId == interestCategoryId && row.day.year == year {
        received += row.amountRubE4
      }
    }
    var accrued = AmountE4.zero
    var expected = received
    var missing: Set<CurrencyCode> = []
    for payout in payouts where payout.payDate.year == year {
      if case .received = payout.state { continue }
      let currency = payout.target.currency
      guard
        let converted = DebtRubles.convert(
          payout.expectedE4, from: currency, rubPerUnit: rubPerUnit),
        let sofar = DebtRubles.convert(payout.accruedE4, from: currency, rubPerUnit: rubPerUnit)
      else {
        missing.insert(currency)
        continue
      }
      accrued += min(sofar, converted)
      expected += converted
    }
    return Year(
      year: year, receivedE4: received, accruedE4: accrued, expectedE4: expected,
      withoutRate: missing.sorted { $0.code < $1.code })
  }
}
