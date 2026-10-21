import CoreAccounting
import CoreKit
import Foundation
import Testing

@testable import CoreAnalytics

/// The report with the rules on the account: a card added later changes nothing, the points an
/// account's cashback comes as are its cashback, and what only the rules promised is told apart
/// from what the owner typed.
@Suite("Cashback by account, its points and what is unconfirmed")
struct CashbackAccountRulesReportTests {
  static let bonus = id(4)
  static let bonusCard = id(41)

  func report(
    entries: [TransactionEntry] = CashbackBook.entries, accounts: [PaymentMethod]? = nil,
    cards: [PaymentCard]? = nil, rules: [CashbackRule] = CashbackBook.rules
  ) -> CashbackReport {
    let dataset = Dataset(
      entries: entries, categories: CashbackBook.categories,
      places: [Place(id: CashbackBook.place, name: "Shop")],
      paymentMethods: accounts ?? CashbackBook.accounts,
      settings: AnalyticsSettings(cashbackCategoryId: CashbackBook.cashback),
      cards: cards ?? CashbackBook.cards, cashbackRules: rules)
    return CashbackReport(
      ledger: Ledger(dataset: dataset, calendar: .utc), period: .month(CashbackBook.september))
  }

  func line(_ report: CashbackReport, _ account: UUID, _ card: UUID? = nil) -> CashbackReport.Cell?
  {
    report.byHolder().first { $0.holder == CashbackHolderKey(accountId: account, cardId: card) }
  }

  /// Sber's September: 60 ₽ bought naming no card, the account's rule 0.5 % → 0.30. A second
  /// card added in October does not take it away.
  @Test func aSecondCardLeavesSeptemberAlone() throws {
    let before = try #require(line(report(), CashbackBook.sber))
    #expect(before.expectedRub == money("0.3"))
    let another = PaymentCard(id: id(22), accountId: CashbackBook.sber, name: "Sber Mir")
    let after = try #require(
      line(report(cards: CashbackBook.cards + [another]), CashbackBook.sber))
    #expect(after.expectedRub == money("0.3"))
    #expect(
      line(report(cards: CashbackBook.cards + [another]), CashbackBook.sber, id(22)) == nil)
  }

  // MARK: Points

  /// T-Bank's cashback comes as points to «Bonus»: the 120 that arrive there in October for
  /// September are T-Bank's.
  @Test func pointsReceivedOnThePointsAccountAreTheAccountsCashback() throws {
    var accounts = CashbackBook.accounts
    accounts[0].cashbackPointsAccountId = Self.bonus
    accounts.append(PaymentMethod(id: Self.bonus, name: "Bonus", kind: .other))
    let points = CashbackBook.operation(
      1030, .income, on: "10-06", parts: [(CashbackBook.cashback, "120")], account: Self.bonus,
      period: CashbackBook.september)
    let result = report(entries: CashbackBook.entries + [points], accounts: accounts)
    let tBank = try #require(line(result, CashbackBook.tBank))
    #expect(tBank.receivedRub == money("120"))
    #expect(line(result, Self.bonus) == nil)
    // What came to the cards of T-Bank as money is still theirs.
    #expect(
      line(result, CashbackBook.tBank, CashbackBook.black)?.receivedRub == money("250"))
  }

  /// Two accounts that name the same points account: nobody can tell whose points an income
  /// there is, so it stays on the points account's own line.
  @Test func pointsOfTwoAccountsStayWhereTheyCame() throws {
    var accounts = CashbackBook.accounts
    accounts[0].cashbackPointsAccountId = Self.bonus
    accounts[1].cashbackPointsAccountId = Self.bonus
    accounts.append(PaymentMethod(id: Self.bonus, name: "Bonus", kind: .other))
    let points = CashbackBook.operation(
      1030, .income, on: "10-06", parts: [(CashbackBook.cashback, "120")], account: Self.bonus,
      period: CashbackBook.september)
    let result = report(entries: CashbackBook.entries + [points], accounts: accounts)
    #expect(try #require(line(result, Self.bonus)).receivedRub == money("120"))
    #expect(line(result, CashbackBook.tBank)?.receivedRub == nil)
  }

  // MARK: Unconfirmed

  /// 60 ₽ at 0.5 % is the rules' 0.30; the 100 ₽ with 5 typed is the owner's. The rules' part is
  /// what nobody has confirmed — it needs no confirming and is counted all the same.
  @Test func whatTheRulesGaveIsTheUnconfirmedPartOfTheExpectation() throws {
    let typed = CashbackBook.operation(
      1031, on: "09-19", parts: [(CashbackBook.home, "100")], account: CashbackBook.sber,
      cashback: "5")
    let result = report(entries: CashbackBook.entries + [typed])
    let sber = try #require(line(result, CashbackBook.sber))
    #expect(sber.expectedRub == money("5.3"))
    #expect(sber.unconfirmedRub == money("0.3"))
    // The rules alone: all of it is the rules'.
    let alone = try #require(line(report(), CashbackBook.sber))
    #expect(alone.unconfirmedRub == alone.expectedRub)
    // The lines add up, the unconfirmed part with them.
    let total = result.byHolder().reduce(AmountE4.zero) { $0 + $1.unconfirmedRub }
    #expect(total <= result.byHolder().reduce(AmountE4.zero) { $0 + $1.expectedRub })
    #expect(total > .zero)
  }

  /// A payment on a debt adds nothing to what is expected, rule or no rule.
  @Test func aDebtPaymentAddsNothingToTheExpectation() throws {
    let withoutDebt = CashbackBook.entries.filter { $0.id != id(1009) }
    #expect(
      try #require(line(report(), CashbackBook.tBank, CashbackBook.black)).expectedRub
        == (try #require(
          line(report(entries: withoutDebt), CashbackBook.tBank, CashbackBook.black)
        ).expectedRub))
    // «Everything else» on the account reaches the loan payment no more.
    let onSber = CashbackBook.operation(
      1032, on: "09-25", parts: [(CashbackBook.loans, "15000")], account: CashbackBook.sber)
    let result = report(entries: CashbackBook.entries + [onSber])
    #expect(try #require(line(result, CashbackBook.sber)).expectedRub == money("0.3"))
  }
}
