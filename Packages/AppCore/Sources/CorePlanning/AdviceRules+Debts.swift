import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation

// MARK: - Debts and what is owed to me

extension AdviceRules {
  /// The extra of the payoff scenario: 10 % of the monthly payment.
  static let payoffExtraBp = 1_000
  /// People «who owes how much» names at most; the rest go into one line.
  static let owedPeopleShown = 5
  /// The oldest expectations listed.
  static let oldestShown = 3

  /// The debt load: the total balance of the debts I owe and `DebtLoad.month` — what the
  /// schedules of the month ask plus 5 % of the debt on credit cards, against the median income
  /// of «Заработок» of the six full months before (`DebtLoad.history`, its last month). No debt
  /// I owe: no suggestion; no earnings: «not enough data».
  static func debtLoad(
    _ context: AdviceContext, debts: DebtsOverview, accounts: AccountBalances,
    rubPerUnit: [CurrencyCode: Decimal], earnings: ((UUID?) -> Bool)? = nil
  ) -> [Advice] {
    guard !debts.iOwe.isEmpty else { return [] }
    let dataset = context.ledger.dataset
    let tree = context.ledger.tree
    let isEarnings =
      earnings ?? { categoryId in
        Allocation.isEarnings(
          categoryId: categoryId, tree: tree, settings: dataset.allocationSettings)
      }
    guard
      let load = DebtLoad.history(
        months: 1, ledger: context.ledger, debts: dataset.debts,
        journal: dataset.planning.debtEntries, accounts: accounts, rubPerUnit: rubPerUnit,
        today: context.today, earnings: isEarnings
      ).last?.load
    else { return [.notEnoughData(.debtLoad, reason: Reason.noIncome)] }
    guard case .ready = load.status, let loadBp = load.loadBp, let incomeRub = load.incomeRub
    else {
      return [.notEnoughData(.debtLoad, reason: Reason.noIncome)]
    }
    var notes: [AdviceTerm] = []
    if !load.withoutRate.isEmpty {
      notes.append(AdviceTerm(key: Key.debtsWithoutRate, value: .count(load.withoutRate.count)))
    }
    if !load.withoutPayment.isEmpty {
      notes.append(
        AdviceTerm(key: Key.debtsWithoutPayment, value: .count(load.withoutPayment.count)))
    }
    return [
      Advice(
        id: AdviceBook.id(.debtLoad, nil), kind: .debtLoad,
        terms: [
          AdviceTerm(key: Key.debtTotal, value: .money(debts.totalIOweRub)),
          AdviceTerm(key: Key.debtMonthlyPayments, value: .money(load.monthlyPaymentsRub)),
          AdviceTerm(key: Key.debtIncome, value: .money(incomeRub)),
        ],
        result: AdviceTerm(key: Key.debtLoad, op: .equals, value: .basisPoints(loadBp)),
        notes: notes)
    ]
  }

  /// «Pay a little extra and the debt closes sooner», for every open debt I owe with a
  /// balance, a rate and a monthly payment: `DebtPayoff.scenario` with an extra of 10 % of
  /// the payment, rounded to 100 ₽ and never below it; a debt in another currency rounds to
  /// whole units of its own and never below one — 100 dollars would be no «little extra».
  /// A loan in its grace period gets none: its dues are interest, and paying more there is not
  /// what closes it sooner. A loan whose main payment is worked out over months takes that
  /// payment (`DebtLoad.payment`).
  static func debtPayoffs(_ debts: DebtsOverview) -> [Advice] {
    debts.iOwe.compactMap { line in
      let debt = line.debt
      guard line.schedule?.phase != .grace else { return nil }
      let monthly = line.schedule?.mainAmount ?? DebtLoad.payment(of: debt, dues: line.dues)
      guard let rate = debt.interestRate, rate > 0, let payment = debt.monthlyPaymentE4 ?? monthly,
        payment.raw > 0, line.balance.raw > 0
      else { return nil }
      let extra = payoffExtra(payment, currency: debt.currency)
      let scenario = DebtPayoff.scenario(
        balance: line.balance, annualRatePercent: rate, monthlyPayment: payment, extra: extra)
      let currency = debt.currency
      let terms = [
        AdviceTerm(key: Key.debtBalance, value: AdviceMath.money(line.balance, in: currency)),
        AdviceTerm(key: Key.debtRate, value: .basisPoints(AdviceMath.basisPoints(percent: rate))),
        AdviceTerm(key: Key.debtPayment, value: AdviceMath.money(payment, in: currency)),
        AdviceTerm(key: Key.debtExtra, op: .plus, value: AdviceMath.money(extra, in: currency)),
      ]
      let result: AdviceTerm
      var notes: [AdviceTerm] = []
      switch (scenario.monthsWithout, scenario.monthsWith, scenario.monthsSaved) {
      case (let without?, let with?, let saved?):
        result = AdviceTerm(key: Key.monthsSooner, op: .equals, value: .months(saved))
        notes.append(AdviceTerm(key: Key.monthsWithoutExtra, value: .months(without)))
        notes.append(AdviceTerm(key: Key.monthsWithExtra, value: .months(with)))
        if let interest = scenario.interestSaved, interest.raw > 0 {
          notes.append(
            AdviceTerm(key: Key.interestSaved, value: AdviceMath.money(interest, in: currency)))
        }
      case (nil, let with?, _):
        result = AdviceTerm(key: Key.closesOnlyWithExtra, op: .equals, value: .months(with))
      default:
        result = AdviceTerm(key: Key.notClosedWithin, value: .months(DebtPayoff.horizonMonths))
      }
      return Advice(
        id: AdviceBook.id(.debtPayoff, debt.id), kind: .debtPayoff, subject: .debt(debt.name),
        terms: terms, result: result, notes: notes)
    }
  }

  /// 10 % of the payment: to 100 ₽ (at least 100 ₽), or to whole units of another currency
  /// (at least one).
  static func payoffExtra(_ payment: AmountE4, currency: CurrencyCode) -> AmountE4 {
    let exact = payment.decimal * Decimal(payoffExtraBp) / Decimal(Shares.whole)
    if currency == .rub {
      return max(AdviceMath.hundred, AdviceMath.roundedToHundred(exact))
    }
    return max(AmountE4(whole: 1), AdviceMath.roundedToWhole(exact))
  }

  /// Who owes me how much: the groups of «Owed to me» with something owed, the largest first,
  /// the group without a person last; beyond five people the rest are summed in one line.
  static func owedByPerson(_ context: AdviceContext, debts: DebtsOverview) -> [Advice] {
    let groups = debts.owedToMe.filter { $0.totalRub.raw > 0 }
    guard !groups.isEmpty else { return [] }
    var terms = groups.prefix(owedPeopleShown).map { group in
      AdviceTerm(
        key: Key.owedBy, op: .plus, value: .money(group.totalRub),
        subject: .person(context.personName(group.personId)))
    }
    let rest = groups.dropFirst(owedPeopleShown)
    if !rest.isEmpty {
      terms.append(
        AdviceTerm(
          key: Key.owedByOthers, op: .plus, value: .money(AmountE4.sum(rest.map(\.totalRub)))))
    }
    return [
      Advice(
        id: AdviceBook.id(.owedByPerson, nil), kind: .owedByPerson, terms: terms,
        result: AdviceTerm(
          key: Key.owedTotal, op: .equals, value: .money(AmountE4.sum(groups.map(\.totalRub)))))
    ]
  }

  /// The oldest expectations («самые старые ожидания»): the parts paid for others still
  /// expected, by the day of the purchase, and the debts owed to me with something left, by
  /// their earliest dated line — the three oldest, each with who owes it and how much.
  static func oldestOwed(_ context: AdviceContext, debts: DebtsOverview) -> [Advice] {
    struct Expectation {
      var day: DateOnly
      var personId: UUID?
      var value: AdviceValue
      var id: UUID
    }
    var all: [Expectation] = []
    for group in debts.owedToMe {
      for part in group.parts {
        all.append(
          Expectation(
            day: part.day, personId: part.personId, value: .money(part.amountRub),
            id: part.partId))
      }
      for line in group.debts where line.balance.raw > 0 {
        guard let start = line.entries.compactMap(\.date).min() else { continue }
        all.append(
          Expectation(
            day: start, personId: line.debt.personId,
            value: line.balanceRub.map(AdviceValue.money)
              ?? AdviceMath.money(line.balance, in: line.debt.currency),
            id: line.debt.id))
      }
    }
    guard !all.isEmpty else { return [] }
    let oldest = all.sorted { left, right in
      left.day != right.day ? left.day < right.day : left.id.uuidString < right.id.uuidString
    }
    .prefix(oldestShown)
    return [
      Advice(
        id: AdviceBook.id(.oldestOwed, nil), kind: .oldestOwed,
        terms: oldest.flatMap { item in
          [
            AdviceTerm(
              key: Key.owedSince, value: .date(item.day),
              subject: .person(context.personName(item.personId))),
            AdviceTerm(key: Key.owedAmount, value: item.value),
          ]
        })
    ]
  }
}
