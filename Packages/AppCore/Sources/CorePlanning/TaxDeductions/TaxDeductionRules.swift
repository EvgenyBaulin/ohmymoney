import CoreKit
import Foundation

/// The limits of the personal income tax deductions and the scale of the tax, year by year. The
/// app carries the table (`builtIn`) and renews it with each release; nothing is fetched and no
/// rule of the report holds a number of its own. A year the table does not hold takes the
/// nearest earlier year it does (`rules(for:)` says which), so the report never invents a limit.
public struct TaxDeductionRules: Hashable, Sendable {
  /// One step of the scale: the rate on the income up to `upTo` (`nil` — no ceiling), counted
  /// on the part above the previous step.
  public struct Step: Hashable, Sendable {
    public var upTo: AmountE4?
    /// Percent: 13 is 13 %.
    public var percent: Decimal

    public init(upTo: AmountE4?, percent: Decimal) {
      self.upTo = upTo
      self.percent = percent
    }
  }

  /// The limits of one year of spending, in rubles.
  public struct Year: Hashable, Sendable {
    public var year: Int
    /// The one limit treatment, the owner's own education and sport share (and the rest of the
    /// social deductions the app does not track).
    public var socialLimit: AmountE4
    /// The limit of a child's education, per child.
    public var childEducationLimit: AmountE4
    /// The limit of the contributions to an individual investment account.
    public var iisLimit: AmountE4
    /// The limit of the interest of a mortgage — for the whole life of the owner, one home.
    public var mortgageInterestLimit: AmountE4
    /// The scale of the tax on the main income, lowest step first.
    public var scale: [Step]

    public init(
      year: Int, socialLimit: AmountE4, childEducationLimit: AmountE4, iisLimit: AmountE4,
      mortgageInterestLimit: AmountE4, scale: [Step]
    ) {
      self.year = year
      self.socialLimit = socialLimit
      self.childEducationLimit = childEducationLimit
      self.iisLimit = iisLimit
      self.mortgageInterestLimit = mortgageInterestLimit
      self.scale = scale
    }

    /// The rate of the lowest step: what «до N ₽» is counted at when the income is not known.
    public var basePercent: Decimal { scale.first?.percent ?? 13 }

    /// The tax on `income` by the scale, in whole rubles as the tax is counted, half up.
    public func tax(on income: AmountE4) -> AmountE4 {
      guard income.raw > 0 else { return .zero }
      var left = income.decimal
      var floor = Decimal(0)
      var total = Decimal(0)
      for step in scale {
        let ceiling = step.upTo?.decimal
        let width = ceiling.map { max(0, $0 - floor) } ?? left
        let taxed = min(left, width)
        total += taxed * step.percent / 100
        left -= taxed
        if let ceiling { floor = ceiling }
        if left <= 0 { break }
      }
      return AmountE4(whole: (try? DecimalMath.int64(rounding: total)) ?? 0)
    }
  }

  /// Oldest first, one row a year.
  public let years: [Year]

  public init(years: [Year]) {
    var unique: [Int: Year] = [:]
    for year in years { unique[year.year] = year }
    self.years = unique.values.sorted { $0.year < $1.year }
  }

  /// The rules of `year`, or of the nearest earlier year the table holds; `nil` before the first.
  public func rules(for year: Int) -> Year? {
    years.last { $0.year <= year }
  }

  private static func rub(_ whole: Int64) -> AmountE4 { AmountE4(whole: whole) }

  /// The scale before 2025: 13 % up to 5 million a year, 15 % above
  /// (Tax Code of Russia, art. 224 p. 1, as amended by Federal Law 372-FZ of 23.11.2020).
  private static let scaleTo2024: [Step] = [
    Step(upTo: rub(5_000_000), percent: 13), Step(upTo: nil, percent: 15),
  ]

  /// The scale from 2025: 13 % up to 2.4 million, 15 % up to 5 million, 18 % up to 20 million,
  /// 20 % up to 50 million, 22 % above (art. 224 p. 1 as amended by Federal Law 176-FZ of
  /// 12.07.2024).
  private static let scaleFrom2025: [Step] = [
    Step(upTo: rub(2_400_000), percent: 13), Step(upTo: rub(5_000_000), percent: 15),
    Step(upTo: rub(20_000_000), percent: 18), Step(upTo: rub(50_000_000), percent: 20),
    Step(upTo: nil, percent: 22),
  ]

  /// The table the app ships.
  ///
  /// * Social limit: 120 000 ₽ for spending up to 2023, 150 000 ₽ from 2024; a child's education
  ///   50 000 ₽ and 110 000 ₽ per child (art. 219 p. 2 and p. 1 sub. 2 as amended by Federal Law
  ///   382-FZ of 31.07.2023); expensive treatment has no limit (art. 219 p. 2).
  /// * Individual investment account: 400 000 ₽ of contributions a year (art. 219.1 p. 3).
  /// * Interest of a mortgage: 3 000 000 ₽ for life (art. 220 p. 4).
  /// * The scale: art. 224 p. 1, as above.
  public static let builtIn = TaxDeductionRules(years: [
    Year(
      year: 2021, socialLimit: rub(120_000), childEducationLimit: rub(50_000),
      iisLimit: rub(400_000), mortgageInterestLimit: rub(3_000_000), scale: scaleTo2024),
    Year(
      year: 2024, socialLimit: rub(150_000), childEducationLimit: rub(110_000),
      iisLimit: rub(400_000), mortgageInterestLimit: rub(3_000_000), scale: scaleTo2024),
    Year(
      year: 2025, socialLimit: rub(150_000), childEducationLimit: rub(110_000),
      iisLimit: rub(400_000), mortgageInterestLimit: rub(3_000_000), scale: scaleFrom2025),
    Year(
      year: 2026, socialLimit: rub(150_000), childEducationLimit: rub(110_000),
      iisLimit: rub(400_000), mortgageInterestLimit: rub(3_000_000), scale: scaleFrom2025),
  ])
}
