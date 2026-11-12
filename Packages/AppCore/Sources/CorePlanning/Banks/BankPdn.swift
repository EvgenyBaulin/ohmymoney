import CoreAnalytics
import CoreKit
import Foundation

/// The debt burden as a bank reads it («показатель долговой нагрузки», ПДН): the monthly
/// payments on all credits and credit cards over the monthly income.
///
/// It stands on the schedules the debt load already works from (`DebtLoad.month`), and differs
/// from it in what banks count:
/// * a credit card weighs 5 % of its limit, not of what is owed;
/// * a purchase in instalments (Сплит, «Долями») is told apart, so the figure is shown both
///   without it — as the credit history sees credits — and with it;
/// * the income can also be cut by a tenth, the cautious figure a bank may take instead of the
///   one the owner gives: a reference, never the bank's own verdict.
public struct BankPdn: Hashable, Sendable {
  /// Monthly payments on credits and loans, instalment plans and credit cards apart.
  public var creditsRub: AmountE4
  /// 5 % of the limits of credit cards in rubles.
  public var cardsRub: AmountE4
  /// Monthly payments on purchases in instalments.
  public var instalmentsRub: AmountE4
  /// What the owner earns in a month; `nil`: no figure.
  public var incomeRub: AmountE4?
  /// Debts in a currency without a rate and credit cards in one: left out, never guessed.
  public var withoutRate: [UUID]

  public init(
    creditsRub: AmountE4, cardsRub: AmountE4, instalmentsRub: AmountE4, incomeRub: AmountE4?,
    withoutRate: [UUID]
  ) {
    self.creditsRub = creditsRub
    self.cardsRub = cardsRub
    self.instalmentsRub = instalmentsRub
    self.incomeRub = incomeRub
    self.withoutRate = withoutRate
  }

  /// A bank may count only nine tenths of the income given.
  public static let cautiousIncomeShare = Decimal(9) / 10
  public static let cardLimitShare = Decimal(5) / 100

  /// Credits and credit cards, as the bank counts the burden.
  public var bankPaymentsRub: AmountE4 { creditsRub + cardsRub }
  /// The same with the instalments added.
  public var withInstalmentsRub: AmountE4 { creditsRub + cardsRub + instalmentsRub }
  /// The income a cautious bank would use; `nil` without an income.
  public var cautiousIncomeRub: AmountE4? {
    incomeRub.flatMap { try? AmountE4(decimal: $0.decimal * Self.cautiousIncomeShare) }
  }

  /// The burden in basis points (10 000 = 100 %), half away from zero; `nil` without an income
  /// above zero.
  static func bp(_ payments: AmountE4, over income: AmountE4?) -> Int? {
    guard let income, income.raw > 0 else { return nil }
    let exact = payments.decimal * 10_000 / income.decimal
    return (try? DecimalMath.int64(rounding: exact)).map { Int(clamping: $0) } ?? Int.max
  }

  /// Without instalments, over the income given.
  public var bankBp: Int? { Self.bp(bankPaymentsRub, over: incomeRub) }
  /// With instalments, over the income given.
  public var withInstalmentsBp: Int? { Self.bp(withInstalmentsRub, over: incomeRub) }
  /// Without instalments, over the cautious income.
  public var cautiousBp: Int? { Self.bp(bankPaymentsRub, over: cautiousIncomeRub) }
  /// With instalments, over the cautious income.
  public var cautiousWithInstalmentsBp: Int? {
    Self.bp(withInstalmentsRub, over: cautiousIncomeRub)
  }

  /// The burden of `month`. `states` are the dues of the debts (`DebtDues.states`); `accounts`
  /// are the payment accounts, whose credit limits weigh as cards; `incomeRub` is the median
  /// income of «Заработок» the debt load uses.
  public static func build(
    month: MonthKey, debts: [Debt], states: [UUID: DebtDueState], accounts: [PaymentMethod],
    incomeRub: AmountE4?, rubPerUnit: [CurrencyCode: Decimal]
  ) -> BankPdn {
    let owing = debts.filter { !$0.isDeleted && $0.direction == .iOwe }
    // A credit card kept as a debt weighs through its account's limit when it has one; with
    // none, its schedule stands for it and it is told as a credit.
    let credits = owing.filter { !$0.isInstalmentPlan && $0.type != .creditCard }
    let instalments = owing.filter(\.isInstalmentPlan)
    func payments(_ list: [Debt]) -> DebtLoad {
      DebtLoad.month(
        month, debts: list, states: states, creditDebtRub: .zero, earningsMedianRub: nil,
        rubPerUnit: rubPerUnit)
    }
    let creditLoad = payments(credits)
    let instalmentLoad = payments(instalments)
    var limits = Decimal(0)
    var withoutRate = Set(creditLoad.withoutRate + instalmentLoad.withoutRate)
    for account in accounts where !account.archived {
      guard let terms = account.credit else { continue }
      guard
        let rubles = DebtRubles.convert(
          terms.limitE4, from: account.mainCurrency, rubPerUnit: rubPerUnit)
      else {
        withoutRate.insert(account.id)
        continue
      }
      limits += rubles.decimal
    }
    return BankPdn(
      creditsRub: creditLoad.monthlyPaymentsRub, cardsRub: DebtRubles.round(limits * cardLimitShare),
      instalmentsRub: instalmentLoad.monthlyPaymentsRub, incomeRub: incomeRub,
      withoutRate: DebtRubles.sorted(withoutRate))
  }
}
