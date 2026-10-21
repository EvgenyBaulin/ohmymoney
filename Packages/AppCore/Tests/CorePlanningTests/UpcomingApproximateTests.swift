import CoreKit
import CorePlanning
import Foundation
import Testing

/// «Платежи на 7 дней» shows a payment in its own currency and, when that is not the default
/// currency, about how much it is in the default one at today's rate, in whole units — or says
/// there is no rate, never a guess. The rates are rubles for one unit, as the Bank of Russia
/// publishes them; the ruble is always 1.
@Suite("The approximate amount of a payment due soon")
struct UpcomingApproximateTests {
  static let kzt = CurrencyCode("KZT")
  /// 1 $ = 90 ₽, 1 ₸ = 0.2 ₽; no rate for the euro.
  static let rates: [CurrencyCode: Decimal] = [
    .usd: Decimal(90), kzt: Decimal(string: "0.2") ?? 0,
  ]

  static func amount(_ text: String) -> AmountE4 {
    amountLiteral(text)
  }

  static func payment(
    _ amount: String, _ currency: CurrencyCode, kind: UpcomingPayment.Kind = .scheduled,
    overdue: Bool = false
  ) -> UpcomingPayment {
    UpcomingPayment(
      kind: kind, id: UUID(), name: "payment",
      due: DateOnly(year: 2026, month: 9, day: 30), currency: currency,
      amount: Self.amount(amount), isOverdue: overdue)
  }

  @Test func aDollarPaymentIsShownInRublesInWholeRubles() {
    // 2.99 × 90 = 269.10 → «≈ 269 ₽».
    #expect(
      Self.payment("2.99", .usd).approximate(to: .rub, rubPerUnit: Self.rates)
        == .amount(Self.amount("269"), .rub))
    // 5,000 ₸ × 0.2 = 1,000 ₽.
    #expect(
      Self.payment("5000", Self.kzt).approximate(to: .rub, rubPerUnit: Self.rates)
        == .amount(Self.amount("1000"), .rub))
  }

  @Test func withoutARateItSaysSoInsteadOfGuessing() {
    #expect(
      Self.payment("20", .eur).approximate(to: .rub, rubPerUnit: Self.rates) == .noRate(.eur))
    // The default currency itself without a rate: nothing can be said either.
    #expect(
      Self.payment("1000", .rub).approximate(to: .eur, rubPerUnit: Self.rates) == .noRate(.eur))
    // A rate of zero is no rate.
    #expect(
      Self.payment("10", .usd).approximate(to: .rub, rubPerUnit: [.usd: 0]) == .noRate(.usd))
  }

  @Test func aPaymentInTheDefaultCurrencyHasNoSecondLine() {
    #expect(Self.payment("1000", .rub).approximate(to: .rub, rubPerUnit: Self.rates) == nil)
    #expect(Self.payment("5000", Self.kzt).approximate(to: Self.kzt, rubPerUnit: [:]) == nil)
  }

  @Test func anotherDefaultCurrencyGoesThroughRubles() {
    // 1,000 ₽ ÷ 0.2 = 5,000 ₸.
    #expect(
      Self.payment("1000", .rub).approximate(to: Self.kzt, rubPerUnit: Self.rates)
        == .amount(Self.amount("5000"), Self.kzt))
    // 2.99 × 90 ÷ 0.2 = 1,345.5 → 1,346 ₸: half away from zero, rounded once.
    #expect(
      Self.payment("2.99", .usd).approximate(to: Self.kzt, rubPerUnit: Self.rates)
        == .amount(Self.amount("1346"), Self.kzt))
  }

  @Test func aDebtPaymentIsShownTheSameWay() {
    // The monthly payment of a loan in rubles, the default currency tenge: 10,000 ₽ = 50,000 ₸.
    #expect(
      Self.payment("10000", .rub, kind: .debt).approximate(to: Self.kzt, rubPerUnit: Self.rates)
        == .amount(Self.amount("50000"), Self.kzt))
  }

  @Test func anOverduePaymentKeepsItsApproximateAmount() {
    // The money has not left yet: the row still says how much it is.
    #expect(
      Self.payment("2.99", .usd, overdue: true).approximate(to: .rub, rubPerUnit: Self.rates)
        == .amount(Self.amount("269"), .rub))
  }

  @Test func theRuleRoundsOnceFromTheExactProduct() {
    // 1,345.49996 ₸ would read 1,346 if it were rounded to kopecks first; it is 1,345.
    let rates: [CurrencyCode: Decimal] = [
      .usd: Decimal(string: "134.549996") ?? 0, Self.kzt: Decimal(string: "0.1") ?? 0,
    ]
    #expect(
      UpcomingPayment.approximate(
        Self.amount("1"), in: .usd, to: Self.kzt, rubPerUnit: rates)
        == .amount(Self.amount("1345"), Self.kzt))
  }
}
