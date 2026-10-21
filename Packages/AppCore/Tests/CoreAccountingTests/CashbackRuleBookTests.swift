import CoreKit
import Foundation
import Testing

@testable import CoreAccounting

/// The accounts, cards, categories and rules every cashback suite prices against (September
/// 2026, rubles unless said). Synthetic names only.
///
/// T-Bank has two cards that hold rules of their own, Sber (main) has the rules on the account
/// and the card the update gave it, Kaspi in tenge has its card with rules, cash has no card.
/// Alfa has rules on the account for both its cards, and one card that differs. All of them
/// round to the kopeck, as 1.2 did, but Alfa, which rounds the way a new account does.
struct CashbackFixture {
  let tBank = id(1)
  let sber = id(2)
  let kaspi = id(3)
  let cash = id(4)
  let alfa = id(5)
  let black = id(11)
  let virtual = id(12)
  let sberCard = id(21)
  let kaspiCard = id(31)
  let alfaCard = id(41)
  let alfaVirtual = id(42)

  let cafes = id(200)
  let coffee = id(201)
  let supermarkets = id(202)
  let health = id(203)
  let pharmacy = id(204)
  let home = id(205)
  let subscriptions = id(206)
  let clothes = id(207)
  let loans = id(208)
  let cinema = id(209)
  let goals = id(210)
  let goalTrip = id(211)
  let salary = id(212)

  let september = MonthKey(year: 2026, month: 9)
  let october = MonthKey(year: 2026, month: 10)

  let tree: CategoryTree
  let accounts: [PaymentMethod]
  let cards: [PaymentCard]
  let rules: [CashbackRule]
  let book: CashbackRuleBook

  init() {
    tree = CategoryTree([
      CoreKit.Category(id: cafes, kind: .expense, name: "Cafes"),
      CoreKit.Category(id: coffee, parentId: cafes, kind: .expense, name: "Coffee"),
      CoreKit.Category(id: supermarkets, kind: .expense, name: "Supermarkets"),
      CoreKit.Category(id: health, kind: .expense, name: "Health"),
      CoreKit.Category(id: pharmacy, parentId: health, kind: .expense, name: "Pharmacy"),
      CoreKit.Category(id: home, kind: .expense, name: "Home"),
      CoreKit.Category(id: subscriptions, kind: .expense, name: "Subscriptions"),
      CoreKit.Category(id: clothes, kind: .expense, name: "Clothes"),
      CoreKit.Category(id: loans, kind: .expense, name: "Loans", systemRole: .loans),
      CoreKit.Category(id: cinema, kind: .expense, name: "Cinema"),
      CoreKit.Category(id: goals, kind: .expense, name: "Goals", systemRole: .goals),
      CoreKit.Category(id: goalTrip, parentId: goals, kind: .expense, name: "Trip"),
      CoreKit.Category(id: salary, kind: .income, name: "Salary"),
    ])
    let kopecks = CashbackRounding(precision: .cents)
    accounts = [
      PaymentMethod(id: tBank, name: "T-Bank", kind: .card, cashbackRounding: kopecks),
      PaymentMethod(
        id: sber, name: "Sber", kind: .card, isDefault: true, cashbackRounding: kopecks),
      PaymentMethod(
        id: kaspi, name: "Kaspi", kind: .card, currency: CurrencyCode("KZT"),
        cashbackRounding: kopecks),
      PaymentMethod(id: cash, name: "Cash", kind: .cash, cashbackRounding: kopecks),
      PaymentMethod(id: alfa, name: "Alfa", kind: .card),
    ]
    cards = [
      PaymentCard(id: black, accountId: tBank, name: "Black"),
      PaymentCard(id: virtual, accountId: tBank, name: "Virtual", aliases: ["virt"]),
      PaymentCard(id: sberCard, accountId: sber, name: "Sber"),
      PaymentCard(id: kaspiCard, accountId: kaspi, name: "Kaspi"),
      PaymentCard(id: alfaCard, accountId: alfa, name: "Alfa"),
      PaymentCard(id: alfaVirtual, accountId: alfa, name: "Alfa Virtual"),
    ]
    func rule(
      _ number: Int, _ account: UUID, _ card: UUID?, _ category: UUID?, _ month: MonthKey?,
      _ percent: String
    ) -> CashbackRule {
      CashbackRule(
        id: id(number), accountId: account, cardId: card, categoryId: category, month: month,
        percent: CashbackPercent(decimal: Decimal(string: percent)!)!)
    }
    rules = [
      rule(301, tBank, black, cafes, nil, "5"),
      rule(302, tBank, black, coffee, nil, "3"),
      rule(303, tBank, black, cafes, september, "10"),
      rule(304, tBank, black, supermarkets, september, "3"),
      rule(305, tBank, black, loans, nil, "0"),
      rule(306, tBank, black, nil, nil, "1"),
      rule(311, tBank, virtual, pharmacy, nil, "7"),
      rule(312, tBank, virtual, nil, september, "3"),
      rule(313, tBank, virtual, nil, nil, "1.5"),
      rule(321, sber, nil, nil, nil, "0.5"),
      rule(331, kaspi, nil, nil, nil, "2"),
      rule(341, alfa, nil, cafes, nil, "5"),
      rule(342, alfa, nil, supermarkets, september, "3"),
      rule(343, alfa, nil, nil, nil, "1"),
      rule(344, alfa, alfaVirtual, cafes, nil, "10"),
    ]
    book = CashbackRuleBook(rules: rules, tree: tree, cards: cards, accounts: accounts)
  }

  /// Noon UTC of a day of 2026: the tests price in UTC.
  func at(_ dayAndMonth: String) -> Date {
    CalendarContext.utc.noon(of: DateOnly(iso: "2026-" + dayAndMonth)!)
  }

  /// One operation: parts by category and amount in its currency, on an account and a card,
  /// with the leg the account moved when it does not hold the currency.
  func operation(
    _ kind: TransactionKind = .expense, on dayAndMonth: String, currency: CurrencyCode = .rub,
    parts: [(UUID?, AmountE4)], account: UUID?, card: UUID? = nil,
    leg: Money? = nil, rubles: AmountE4? = nil, cashback: Money? = nil, refundOf: UUID? = nil,
    credit: UUID? = nil, externalId: String? = nil, operationId: UUID = id(900)
  ) -> TransactionEntry {
    let total = AmountE4.sum(parts.map(\.1))
    let rub = rubles ?? leg.flatMap { $0.currency == .rub ? $0.amount : nil } ?? total
    let transaction = Transaction(
      id: operationId, kind: kind, occurredAt: at(dayAndMonth), currency: currency,
      amountE4: total, amountRubE4: rub, paymentMethodId: account,
      accountCurrency: leg?.currency, accountAmountE4: leg?.amount, creditDebtId: credit,
      externalId: externalId, cardId: card, cashback: cashback)
    let shares = rub.allocated(proportionallyTo: parts.map(\.1), outOf: total)
    let built = zip(parts.indices, shares).map { index, share in
      TransactionPart(
        id: id(1000 + index), transactionId: operationId, categoryId: parts[index].0,
        amountE4: parts[index].1, amountRubE4: share,
        refundOfPartId: index == 0 ? refundOf : nil)
    }
    return TransactionEntry(transaction: transaction, parts: built)
  }

  /// The expectation of an operation with the holder its account and card give.
  func expected(
    _ entry: TransactionEntry, refunded: [UUID: AmountE4] = [:], book: CashbackRuleBook? = nil
  ) -> CashbackExpectation? {
    let holder = CashbackHolders.holder(
      accountId: entry.transaction.paymentMethodId, cardId: entry.transaction.cardId,
      mainAccountId: sber)
    return CashbackMath.expected(
      entry, holder: holder, book: book ?? self.book, tree: tree, calendar: .utc,
      refunded: { refunded[$0] ?? .zero })
  }
}

/// Which rule prices a purchase: the month's rule over «always», the subcategory over its
/// category, «everything else» last, each holder its own rules.
@Suite("The order cashback rules are chosen in")
struct CashbackRuleBookTests {
  let fixture = CashbackFixture()

  func rule(_ holder: CashbackHolder, _ category: UUID?, _ month: MonthKey) -> UUID? {
    fixture.book.rule(for: holder, categoryId: category, month: month)?.id
  }

  /// 12.09 coffee on Black: the month's rule of «Cafes» (10 %) beats «always» of «Coffee».
  @Test func monthCategoryBeatsAlwaysSubcategory() {
    #expect(rule(.card(fixture.black), fixture.coffee, fixture.september) == id(303))
    #expect(rule(.card(fixture.black), fixture.supermarkets, fixture.september) == id(304))
  }

  /// 03.10 coffee on Black: October has no rules, «always» of «Coffee» (3 %).
  @Test func alwaysSubcategoryInOtherMonth() {
    #expect(rule(.card(fixture.black), fixture.coffee, fixture.october) == id(302))
    #expect(rule(.card(fixture.black), fixture.cafes, fixture.october) == id(301))
  }

  /// 14.09 pharmacy on Virtual: «always» of «Pharmacy» (7 %) beats the month's «everything
  /// else» (3 %).
  @Test func namedAlwaysBeatsMonthEverythingElse() {
    #expect(rule(.card(fixture.virtual), fixture.pharmacy, fixture.september) == id(311))
  }

  /// 14.09 cinema on Virtual: the month's «everything else»; 14.10: «always» «everything else».
  @Test func monthEverythingElseBeatsAlwaysEverythingElse() {
    #expect(rule(.card(fixture.virtual), fixture.cinema, fixture.september) == id(312))
    #expect(rule(.card(fixture.virtual), fixture.cinema, fixture.october) == id(313))
  }

  /// 25.09 a loan payment on Black: «Loans — 0 %» is found before «everything else».
  @Test func zeroPercentRuleExcludes() throws {
    let found = try #require(
      fixture.book.rule(
        for: .card(fixture.black), categoryId: fixture.loans, month: fixture.september))
    #expect(found.id == id(305) && found.percent == .zero)
  }

  /// A purchase with no category takes only «everything else».
  @Test func uncategorizedTakesEverythingElse() {
    #expect(rule(.card(fixture.virtual), nil, fixture.september) == id(312))
    #expect(rule(.card(fixture.black), nil, fixture.september) == id(306))
    // Pharmacy on Black: nothing named, no month «everything else»: «always» «everything else».
    #expect(rule(.card(fixture.black), fixture.pharmacy, fixture.september) == id(306))
  }

  /// A month rule is only that month's; another holder's rules never price this one.
  @Test func otherMonthRulesDoNotApply() {
    #expect(
      rule(.card(fixture.black), fixture.supermarkets, fixture.october) == id(306))
    #expect(rule(.card(fixture.kaspiCard), fixture.cafes, fixture.september) == id(331))
    #expect(rule(.account(fixture.cash), fixture.cafes, fixture.september) == nil)
    #expect(rule(.account(fixture.tBank), fixture.cafes, fixture.september) == nil)
  }

  @Test func theRulesOfAHolderAreItsOwn() {
    #expect(
      fixture.book.rules(of: .card(fixture.virtual)).map(\.id) == [id(311), id(312), id(313)])
    #expect(fixture.book.rules(of: .account(fixture.cash)).isEmpty)
    #expect(!fixture.book.isEmpty)
    #expect(CashbackRuleBook(rules: [], tree: fixture.tree).isEmpty)
  }
}
