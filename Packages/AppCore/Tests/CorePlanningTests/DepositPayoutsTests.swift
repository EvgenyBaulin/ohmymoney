import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CorePlanning

/// The book of the free-sum suites (`CashFx`) with a savings account: 100,000 ₽ counted on 1
/// August, 16 % a year paid at the end of each month onto itself, and a category «Interest»
/// with a child the bank's income is filed under. Today is 19 September 2026.
///
/// August pays on the 31st: the 30 days from the 2nd earn on 100,000 — 1,315.07. Paid onto the
/// account, September earns on 101,315.07: 1,332.36 on the 30th, 843.83 of it through today.
struct DepositFx {
  typealias Fx = CashFx

  static let savings = Fx.id(4)
  static let interest = Fx.id(27)
  static let bankInterest = Fx.id(28)
  static let savingsRub = BalanceKey(accountId: savings, currency: .rub)

  static let terms = DepositTerms(rate: 16, period: .monthly)

  var cash = Fx()
  var interestCategoryId: UUID? = DepositFx.interest

  init(terms: DepositTerms? = DepositFx.terms, counted: Bool = true) {
    cash.accounts.append(
      PaymentMethod(id: Self.savings, name: "Savings", currency: .rub, interest: terms))
    cash.count([(Fx.main, .rub, "50000")], at: Fx.at("2026-08-01", 9))
    if counted { cash.count([(Self.savings, .rub, "100000")], at: Fx.at("2026-08-01", 9)) }
  }

  /// The bank's interest recorded on `account`, filed under `category`.
  @discardableResult
  mutating func income(
    _ amount: String, on iso: String, account: UUID = DepositFx.savings,
    category: UUID = DepositFx.bankInterest
  ) -> UUID {
    cash.add(.income, amount, at: Fx.at(iso, 12), account: account, category: category)
  }

  var ledger: Ledger {
    let base = cash.ledger.dataset
    return Ledger(
      dataset: Dataset(
        entries: base.entries,
        categories: CashFx.categories + [
          CoreKit.Category(id: Self.interest, kind: .income, name: "Interest"),
          CoreKit.Category(
            id: Self.bankInterest, parentId: Self.interest, kind: .income, name: "Bank"),
        ],
        events: base.events, paymentMethods: base.paymentMethods, debts: base.debts,
        goals: base.goals, planning: base.planning, transfers: base.transfers,
        accountGroups: base.accountGroups,
        accountSettings: AccountSettings(interestCategoryId: interestCategoryId)),
      calendar: .utc)
  }

  func snapshot(today: DateOnly = CashFx.today, now: Date? = nil) -> PlanningSnapshot {
    PlanningSnapshot.build(
      ledger: ledger, today: today, now: now ?? CashFx.at(today.iso, 15),
      rubPerUnit: cash.rubPerUnit)
  }

  func outlook(today: DateOnly = CashFx.today) -> DepositOutlook? {
    let ledger = ledger
    let snapshot = snapshot(today: today)
    return DepositPayouts.outlook(
      of: Self.savings, ledger: ledger, balances: snapshot.accounts.balances,
      interestCategoryId: interestCategoryId, today: today, through: today.monthKey.lastDay)
  }

  func payouts(today: DateOnly = CashFx.today) -> [DepositPayout] {
    snapshot(today: today).deposits
  }
}

@Suite("The payouts of a deposit's interest")
struct DepositPayoutsTests {
  typealias Fx = CashFx
  typealias D = DepositFx

  func payout(_ list: [DepositPayout], _ iso: String) -> DepositPayout? {
    list.first { $0.payDate == Fx.day(iso) }
  }

  @Test func theSnapshotHoldsThePayoutsOfTheWindowAndTheCurrentPeriod() throws {
    var fx = D()
    let august = fx.income("1315.07", on: "2026-08-31")
    let list = fx.payouts()
    #expect(list.map(\.payDate.iso) == ["2026-08-31", "2026-09-30"])

    let first = try #require(payout(list, "2026-08-31"))
    #expect(first.state == .received(august))
    #expect(first.expectedE4 == Fx.money("1315.07"))
    #expect(first.periodStart == Fx.day("2026-07-31"))
    #expect(first.target == D.savingsRub)
    #expect(first.capitalized)

    let current = try #require(payout(list, "2026-09-30"))
    #expect(current.state == .accruing)
    #expect(current.periodStart == Fx.day("2026-08-31"))
    #expect(current.expectedE4 == Fx.money("1332.36"))
    #expect(current.accruedE4 == Fx.money("843.83"))
  }

  /// Unrecorded, August's interest still joins the deposit from its pay date: September earns
  /// the same as if it had been recorded.
  @Test func aCapitalizedPayoutNotRecordedStillCompounds() throws {
    let list = D().payouts()
    let first = try #require(payout(list, "2026-08-31"))
    #expect(first.state == .missing)
    #expect(first.expectedE4 == Fx.money("1315.07"))
    #expect(try #require(payout(list, "2026-09-30")).expectedE4 == Fx.money("1332.36"))
  }

  /// Paid to the main account, the interest earns nothing more: September earns on 100,000.
  @Test func aPayoutElsewhereDoesNotCompound() throws {
    var terms = D.terms
    terms.payoutAccountId = Fx.main
    var fx = D(terms: terms)
    let august = fx.income("1315.07", on: "2026-08-31", account: Fx.main)
    let list = fx.payouts()
    let first = try #require(payout(list, "2026-08-31"))
    #expect(first.target == BalanceKey(accountId: Fx.main, currency: .rub))
    #expect(!first.capitalized)
    #expect(first.state == .received(august))
    #expect(try #require(payout(list, "2026-09-30")).expectedE4 == Fx.money("1315.07"))
    // Recorded on the deposit instead, it is not the payout's money.
    var wrong = D(terms: terms)
    wrong.income("1315.07", on: "2026-08-31")
    #expect(try #require(payout(wrong.payouts(), "2026-08-31")).state == .missing)
  }

  @Test func anArchivedTargetSendsTheInterestToTheMainAccount() throws {
    var terms = D.terms
    terms.payoutAccountId = Fx.card
    var fx = D(terms: terms)
    if let index = fx.cash.accounts.firstIndex(where: { $0.id == Fx.card }) {
      fx.cash.accounts[index].archived = true
    }
    let first = try #require(payout(fx.payouts(), "2026-08-31"))
    #expect(first.target.accountId == Fx.main)
  }

  /// Due for five days after the pay date, then missing.
  @Test func dueThenMissing() throws {
    let fx = D()
    for (today, state) in [
      ("2026-08-31", DepositPayout.State.due), ("2026-09-03", .due), ("2026-09-05", .due),
      ("2026-09-06", .missing),
    ] {
      let first = try #require(payout(fx.payouts(today: Fx.day(today)), "2026-08-31"))
      #expect(first.state == state, "\(today)")
    }
    // Before the pay date it is still earning.
    let before = try #require(payout(fx.payouts(today: Fx.day("2026-08-30")), "2026-08-31"))
    #expect(before.state == .accruing)
  }

  /// The income may come three days early and up to the day before the next pay date.
  @Test func theWindowOfAPayout() throws {
    for (iso, received) in [
      ("2026-08-27", false), ("2026-08-28", true), ("2026-09-15", true),
    ] {
      var fx = D()
      fx.income("1315.07", on: iso)
      let first = try #require(payout(fx.payouts(), "2026-08-31"))
      #expect((first.state != .missing) == received, "\(iso)")
    }
  }

  @Test func onlyTheInterestCategoryOrItsChildrenBringAPayout() throws {
    var root = D()
    let byRoot = root.income("1315.07", on: "2026-08-31", category: D.interest)
    #expect(try #require(payout(root.payouts(), "2026-08-31")).state == .received(byRoot))

    var salary = D()
    salary.income("1315.07", on: "2026-08-31", category: Fx.salary)
    #expect(try #require(payout(salary.payouts(), "2026-08-31")).state == .missing)

    var none = D()
    none.interestCategoryId = nil
    none.income("1315.07", on: "2026-08-31")
    #expect(try #require(payout(none.payouts(), "2026-08-31")).state == .missing)
  }

  /// One income brings one payout: the earliest whose window holds it.
  @Test func oneIncomeForOnePayout() throws {
    var fx = D()
    let income = fx.income("1315.07", on: "2026-09-01")
    let list = fx.payouts(today: Fx.day("2026-10-06"))
    #expect(try #require(payout(list, "2026-08-31")).state == .received(income))
    #expect(try #require(payout(list, "2026-09-30")).state == .missing)
  }

  /// A deleted income brings nothing.
  @Test func aDeletedIncomeBringsNothing() throws {
    var fx = D()
    fx.income("1315.07", on: "2026-08-31")
    if let index = fx.cash.entries.indices.last {
      fx.cash.entries[index].transaction.deletedAt = Fx.now
    }
    #expect(try #require(payout(fx.payouts(), "2026-08-31")).state == .missing)
  }

  @Test func neverCountedThereAreNoPayouts() throws {
    let fx = D(counted: false)
    #expect(fx.payouts().isEmpty)
    let outlook = try #require(fx.outlook())
    #expect(!outlook.counted)
    #expect(outlook.payouts.isEmpty)
  }

  @Test func anAccountWithoutTermsOrArchivedHasNone() {
    #expect(D(terms: nil).payouts().isEmpty)
    var archived = D()
    if let index = archived.cash.accounts.firstIndex(where: { $0.id == D.savings }) {
      archived.cash.accounts[index].archived = true
    }
    #expect(archived.payouts().isEmpty)
  }

  /// A deposit that ends on 31 October: what is still to come is September's and October's
  /// payouts — October earning on what September adds.
  @Test func theOutlookOfADepositToItsEnd() throws {
    var terms = D.terms
    terms.endsOn = Fx.day("2026-10-31")
    var fx = D(terms: terms)
    fx.income("1315.07", on: "2026-08-31")
    let outlook = try #require(fx.outlook())
    #expect(outlook.counted)
    let current = try #require(outlook.current(today: Fx.today))
    #expect(current.payDate == Fx.day("2026-09-30"))
    // October: 31 days on 101,315.07 + 1,332.36 = 102,647.43 at 16 %: 1,394.88.
    #expect(outlook.toEndE4 == Fx.money("1332.36") + Fx.money("1394.88"))
    #expect(outlook.missing.isEmpty)
    // A savings account has no end.
    #expect(try #require(D().outlook()).toEndE4 == nil)
  }

  /// The pay dates are no earlier than the first count: a period that ended before it earned on
  /// nothing known.
  @Test func nothingBeforeTheFirstCount() {
    let list = D().payouts(today: Fx.day("2026-08-20"))
    #expect(list.map(\.payDate.iso) == ["2026-08-31"])
  }
}
