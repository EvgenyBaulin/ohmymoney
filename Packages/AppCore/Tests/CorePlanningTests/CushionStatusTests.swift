import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CorePlanning

/// The safety cushion: the money of the accounts marked as the cushion, the months of
/// obligatory spending it lasts, and the goal — how much is missing and how to get there.
@Suite("The status of the safety cushion")
struct CushionStatusTests {
  typealias Fx = CapitalFx

  let today = Fx.day("2026-10-11")
  let main = Fx.id(1)
  let savings = Fx.id(2)
  let stash = Fx.id(3)
  let outGroup = Fx.id(20)

  func obligatory(_ monthly: String?) -> ObligatorySpending {
    guard let monthly else { return .empty }
    let amount = Fx.rub(monthly)
    return ObligatorySpending(
      months: [], medianRub: amount, committedRub: .zero, monthlyRub: amount, state: .ready)
  }

  func accounts(
    cushion: Bool = true, rates: [CurrencyCode: Decimal] = [.usd: 100]
  )
    -> AccountsSnapshot
  {
    let (count, rows) = Fx.count(
      1, "2026-10-01",
      [
        (main, .rub, "50000"), (savings, .rub, "300000"), (savings, .usd, "500"),
        (stash, .rub, "70000"),
      ])
    let dataset = Dataset(
      paymentMethods: [
        PaymentMethod(id: main, name: "Main", isDefault: true),
        PaymentMethod(
          id: savings, name: "Savings", otherCurrencies: [.usd], cushion: cushion),
        PaymentMethod(id: stash, name: "Stash", groupId: outGroup, cushion: cushion),
        PaymentMethod(id: Fx.id(4), name: "Euro", currency: .eur, cushion: cushion),
      ],
      planning: PlanningBook(reconciliations: [count], reconciledBalances: rows),
      accountGroups: [AccountGroup(id: outGroup, name: "Out", inSummary: false)])
    return AccountsSnapshot.build(
      dataset: dataset, now: Fx.noon(today.iso), calendar: .utc, rubPerUnit: rates,
      localeIdentifier: "en")
  }

  func capital(cushionAtMonthEnds ends: [String]) -> CapitalSnapshot {
    var points = ends.enumerated().map { index, amount in
      CapitalPoint(
        day: today.monthKey.adding(months: index - ends.count).lastDay, isNow: false,
        cushionRub: Fx.rub(amount))
    }
    let now = CapitalPoint(day: today, isNow: true)
    points.append(now)
    return CapitalSnapshot(points: points, now: now, breakdown: .empty, changeThisMonth: nil)
  }

  @Test func theMonthsAreFlooredToATenth() {
    #expect(
      CushionRules.months(money: Fx.rub("350000"), monthly: Fx.rub("120000"))
        == Decimal(string: "2.9"))
    #expect(CushionRules.months(money: Fx.rub("360000"), monthly: Fx.rub("120000")) == 3)
    #expect(
      CushionRules.months(money: Fx.rub("119999.99"), monthly: Fx.rub("120000"))
        == Decimal(string: "0.9"))
    #expect(CushionRules.months(money: .zero, monthly: Fx.rub("120000")) == 0)
    #expect(CushionRules.months(money: Fx.rub("-5000"), monthly: Fx.rub("120000")) == 0)
    #expect(CushionRules.months(money: Fx.rub("5000"), monthly: .zero) == nil)
  }

  /// The money is the cushion accounts' balances now, at today's rate; the part in the summary
  /// is what the free sum can leave out; a currency never counted is listed.
  @Test func theMoneyIsTheCushionAccountsNow() {
    let status = CushionRules.status(
      capital: .empty, obligatory: obligatory("100000"), accounts: accounts(),
      settings: .standard, today: today)
    #expect(status.state == .ready)
    #expect(status.moneyRub == Fx.rub("420000"))
    #expect(status.inSummaryRub == Fx.rub("350000"))
    #expect(Set(status.accounts) == [savings, stash, Fx.id(4)])
    #expect(status.unanchored == [BalanceKey(accountId: Fx.id(4), currency: .eur)])
    #expect(status.months == Decimal(string: "4.2"))
    #expect(status.goal == nil)
  }

  @Test func withoutCushionAccountsOrObligatorySpendingThereIsNoFigure() {
    let none = CushionRules.status(
      capital: .empty, obligatory: obligatory("100000"), accounts: accounts(cushion: false),
      settings: .standard, today: today)
    #expect(none.state == .noAccounts)
    #expect(none.obligatory.monthlyRub == Fx.rub("100000"))
    #expect(none.months == nil)

    let early = CushionRules.status(
      capital: .empty, obligatory: obligatory(nil), accounts: accounts(), settings: .standard,
      today: today)
    #expect(early.state == .notEnoughData)
    #expect(early.moneyRub == Fx.rub("420000"))
    #expect(early.months == nil)
    #expect(early.goal == nil)
  }

  /// N months of the obligatory spending, rounded up to 1,000 ₽; by the target month, what is
  /// missing over the months left rounded up to 100 ₽; otherwise a twelfth of it.
  @Test func theGoalAndWhatToPutAside() {
    let settings = CapitalSettings(targetMonths: 6, targetMonth: MonthKey(year: 2027, month: 3))
    let status = CushionRules.status(
      capital: .empty, obligatory: obligatory("120345"), accounts: accounts(),
      settings: settings, today: today)
    let goal = status.goal
    #expect(goal?.targetMonths == 6)
    #expect(goal?.targetRub == Fx.rub("723000"))
    #expect(goal?.missingRub == Fx.rub("303000"))
    #expect(goal?.reached == false)
    // Five months left, October's end included: 60,600 each.
    #expect(goal?.perMonthRub == Fx.rub("60600"))
    // 303,000 ÷ 12 = 25,250 → 25,300.
    #expect(goal?.defaultPerMonthRub == Fx.rub("25300"))
    #expect(goal?.pacePerMonthRub == nil)
    #expect(goal?.reachedBy == nil)

    // A target month already here or gone leaves one month.
    let late = CushionRules.status(
      capital: .empty, obligatory: obligatory("120345"), accounts: accounts(),
      settings: CapitalSettings(targetMonths: 6, targetMonth: MonthKey(year: 2026, month: 9)),
      today: today)
    #expect(late.goal?.perMonthRub == Fx.rub("303000"))

    // No target month: no figure by it.
    let open = CushionRules.status(
      capital: .empty, obligatory: obligatory("120345"), accounts: accounts(),
      settings: CapitalSettings(targetMonths: 2), today: today)
    #expect(open.goal?.perMonthRub == nil)
    #expect(open.goal?.targetRub == Fx.rub("241000"))
    #expect(open.goal?.missingRub == .zero)
    #expect(open.goal?.reached == true)
    #expect(open.goal?.defaultPerMonthRub == .zero)
    #expect(open.goal?.reachedBy == today.monthKey)
  }

  @Test func theShareIsNeverShortOfWhatIsMissing() {
    for missing in [
      Fx.rub("1"), Fx.rub("100"), Fx.rub("100.0001"), Fx.rub("303000"), Fx.rub("999999.99"),
    ] {
      for months in 1...24 {
        let share = CushionRules.share(
          of: missing, over: months, roundedUpTo: CushionRules.perMonthStep)
        #expect(share.raw % CushionRules.perMonthStep.raw == 0)
        #expect(share.raw * Int64(months) >= missing.raw)
        #expect((share.raw - CushionRules.perMonthStep.raw) * Int64(months) < missing.raw)
      }
    }
  }

  /// The pace is the mean growth over the last three month ends, and the month the goal is
  /// reached at it — this month's saving counts.
  @Test func thePaceAndTheMonthItReachesTheGoal() {
    let settings = CapitalSettings(targetMonths: 6)
    let growing = capital(cushionAtMonthEnds: ["50000", "100000", "120000", "130000", "160000"])
    #expect(CushionRules.pace(capital: growing) == Fx.rub("20000"))
    let status = CushionRules.status(
      capital: growing, obligatory: obligatory("120345"), accounts: accounts(),
      settings: settings, today: today)
    #expect(status.goal?.pacePerMonthRub == Fx.rub("20000"))
    // 303,000 at 20,000 a month: 16 months less a little, so the 16th month from October.
    #expect(status.goal?.reachedBy == MonthKey(year: 2028, month: 1))

    let two = capital(cushionAtMonthEnds: ["100000", "110000"])
    #expect(CushionRules.pace(capital: two) == Fx.rub("10000"))
    #expect(CushionRules.pace(capital: capital(cushionAtMonthEnds: ["100000"])) == nil)

    let shrinking = capital(cushionAtMonthEnds: ["160000", "150000", "150000", "140000"])
    let stalled = CushionRules.status(
      capital: shrinking, obligatory: obligatory("120345"), accounts: accounts(),
      settings: settings, today: today)
    #expect(stalled.goal?.pacePerMonthRub.map { $0.raw < 0 } == true)
    #expect(stalled.goal?.reachedBy == nil)

    let flat = capital(cushionAtMonthEnds: ["150000", "150000"])
    #expect(
      CushionRules.status(
        capital: flat, obligatory: obligatory("120345"), accounts: accounts(),
        settings: settings, today: today
      ).goal?.reachedBy == nil)
  }

  /// The snapshot builds the cushion from the books: the accounts it marks, the obligatory
  /// spending of the ledger and the goal of the settings.
  @Test func theSnapshotCarriesTheCushion() {
    let (count, rows) = Fx.count(
      1, "2026-06-01", [(main, .rub, "10000"), (savings, .rub, "90000")])
    let food = Fx.id(10)
    let entries = (6...9).map { month in
      Fx.operation(
        month, String(format: "2026-%02d-10", month), "3000", category: food, method: main)
    }
    let dataset = Dataset(
      entries: entries,
      categories: [CoreKit.Category(id: food, kind: .expense, name: "Food", essential: true)],
      paymentMethods: [
        PaymentMethod(id: main, name: "Main", isDefault: true),
        PaymentMethod(id: savings, name: "Savings", cushion: true),
      ],
      planning: PlanningBook(reconciliations: [count], reconciledBalances: rows),
      capitalSettings: CapitalSettings(targetMonths: 6))
    let snapshot = PlanningSnapshot.build(
      ledger: Ledger(dataset: dataset, calendar: .utc), today: today, now: Fx.noon(today.iso),
      rubPerUnit: [:])
    #expect(snapshot.cushion.state == .ready)
    #expect(snapshot.cushion.moneyRub == Fx.rub("90000"))
    #expect(snapshot.cushion.obligatory.monthlyRub == Fx.rub("3000"))
    #expect(snapshot.cushion.months == 30)
    #expect(snapshot.cushion.goal?.reached == true)
    #expect(snapshot.capital.now.cushionRub == Fx.rub("90000"))
    #expect(snapshot.capital.points.count == 5)
  }
}
