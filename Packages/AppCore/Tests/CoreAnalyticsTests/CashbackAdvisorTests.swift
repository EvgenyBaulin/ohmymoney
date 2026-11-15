import CoreAccounting
import CoreKit
import Foundation
import Testing

@testable import CoreAnalytics

/// Two banks for the advisor, synthetic names only, rubles, rounding to the kopeck.
/// Alpha: an account without cards, «Кафе» 5 % up to 100 ₽ a month, everything else 1 %.
/// Beta: one card, «Супермаркеты» 5 %, everything else 1 %; the account earns at most 60 ₽ a
/// month whatever the card.
private enum Book {
  static let alpha = id(7001)
  static let beta = id(7002)
  static let betaCard = id(7012)
  static let bank = id(7100)

  static let cafes = id(7201)
  static let coffee = id(7202)
  static let supermarkets = id(7203)
  static let pharmacy = id(7204)
  static let fuel = id(7205)
  static let shop = id(7400)

  static let categories: [CoreKit.Category] = [
    CoreKit.Category(id: cafes, kind: .expense, name: "Cafes"),
    CoreKit.Category(id: coffee, parentId: cafes, kind: .expense, name: "Coffee"),
    CoreKit.Category(id: supermarkets, kind: .expense, name: "Supermarkets"),
    CoreKit.Category(id: pharmacy, kind: .expense, name: "Pharmacy"),
    CoreKit.Category(id: fuel, kind: .expense, name: "Fuel"),
  ]

  static let kopecks = CashbackRounding(precision: .cents)

  static func accounts(betaCap: AmountE4? = money("60"), choiceDay: Int? = nil) -> [PaymentMethod] {
    [
      PaymentMethod(
        id: alpha, name: "Alpha", kind: .card, isDefault: true, bankId: bank,
        cashbackRounding: kopecks, cashbackChoiceDay: choiceDay),
      PaymentMethod(
        id: beta, name: "Beta", kind: .card, cashbackRounding: kopecks,
        cashbackMonthlyCapE4: betaCap),
    ]
  }

  static let cards = [PaymentCard(id: betaCard, accountId: beta, name: "Beta card")]

  static func rule(
    _ n: Int, _ account: UUID, _ card: UUID?, _ category: UUID?, _ e4: Int64,
    month: MonthKey? = nil, cap: String? = nil
  ) -> CashbackRule {
    CashbackRule(
      id: id(n), accountId: account, cardId: card, categoryId: category, month: month,
      percent: CashbackPercent(e4: e4)!, monthlyCapE4: cap.map(money))
  }

  static let rules = [
    rule(7301, alpha, nil, cafes, 50_000, cap: "100"),
    rule(7302, alpha, nil, nil, 10_000),
    rule(7311, beta, betaCard, supermarkets, 50_000),
    rule(7312, beta, betaCard, nil, 10_000),
  ]

  static func buy(
    _ n: Int, _ day: String, _ category: UUID, _ amount: String, on account: UUID,
    card: UUID? = nil, place: UUID? = nil, kind: TransactionKind = .expense,
    cashback: String? = nil
  ) -> TransactionEntry {
    CashbackBook.operation(
      n, kind, on: day, parts: [(category, amount)], account: account, card: card,
      cashback: cashback, place: place)
  }

  static func ledger(
    _ entries: [TransactionEntry], rules: [CashbackRule] = rules,
    accounts: [PaymentMethod] = accounts(), mappings: [BankCategoryMapping] = []
  ) -> Ledger {
    var dataset = Dataset(
      entries: entries, categories: categories, places: [Place(id: shop, name: "Shop")],
      paymentMethods: accounts, cards: cards, cashbackRules: rules)
    if !mappings.isEmpty { dataset.cashbackChoice = CashbackChoiceBook(mappings: mappings) }
    return Ledger(dataset: dataset, calendar: .utc)
  }

  static let september = MonthKey(year: 2026, month: 9)
  static let october = MonthKey(year: 2026, month: 10)
}

private func expected(_ report: CashbackReport, _ account: UUID, _ month: MonthKey) -> AmountE4 {
  AmountE4.sum(
    report.cells.filter { $0.holder.accountId == account && $0.month == month }
      .map(\.expectedRub))
}

@Suite("Monthly ceilings of cashback")
struct CashbackCapTests {
  @Test func aRuleEarnsNoMoreThanItsCeilingAMonth() {
    let entries = [
      Book.buy(5001, "09-02", Book.cafes, "1000", on: Book.alpha),
      Book.buy(5002, "09-03", Book.coffee, "1000", on: Book.alpha),
      Book.buy(5003, "09-04", Book.cafes, "1000", on: Book.alpha),
      Book.buy(5004, "10-01", Book.cafes, "1000", on: Book.alpha),
    ]
    let report = CashbackReport(
      ledger: Book.ledger(entries),
      period: .twelveMonths(endingWith: Book.october))
    #expect(expected(report, Book.alpha, Book.september) == money("100"))
    #expect(expected(report, Book.alpha, Book.october) == money("50"))
    // A period that starts mid-month still counts the month from its first day.
    let late = CashbackReport(
      ledger: Book.ledger(entries),
      period: .days(DayRange(DateOnly(iso: "2026-09-04")!, DateOnly(iso: "2026-09-30")!)))
    #expect(expected(late, Book.alpha, Book.september) == .zero)
  }

  @Test func theOrderOfTheBooksChangesNothing() {
    let entries = (0..<6).map {
      Book.buy(5100 + $0, String(format: "09-%02d", 2 + $0), Book.cafes, "700", on: Book.alpha)
    }
    let reference = expected(
      CashbackReport(ledger: Book.ledger(entries), period: .month(Book.september)), Book.alpha,
      Book.september)
    var rng = SystemRandomNumberGenerator()
    for _ in 0..<10 {
      let report = CashbackReport(
        ledger: Book.ledger(entries.shuffled(using: &rng)), period: .month(Book.september))
      #expect(expected(report, Book.alpha, Book.september) == reference)
    }
    #expect(reference == money("100"))
  }

  @Test func theAccountCeilingCoversItsCardsTogether() {
    let entries = [
      Book.buy(5201, "09-02", Book.supermarkets, "1000", on: Book.beta, card: Book.betaCard),
      Book.buy(5202, "09-03", Book.supermarkets, "1000", on: Book.beta, card: Book.betaCard),
      Book.buy(5203, "09-04", Book.fuel, "1000", on: Book.beta, card: Book.betaCard),
    ]
    let report = CashbackReport(ledger: Book.ledger(entries), period: .month(Book.september))
    #expect(expected(report, Book.beta, Book.september) == money("60"))
    let free = CashbackReport(
      ledger: Book.ledger(entries, accounts: Book.accounts(betaCap: nil)),
      period: .month(Book.september))
    #expect(expected(free, Book.beta, Book.september) == money("110"))
  }

  @Test func aTypedFigureStaysAndFillsTheAccountCeiling() {
    let entries = [
      Book.buy(
        5301, "09-02", Book.supermarkets, "1000", on: Book.beta, card: Book.betaCard,
        cashback: "55"),
      Book.buy(5302, "09-03", Book.supermarkets, "1000", on: Book.beta, card: Book.betaCard),
    ]
    let report = CashbackReport(ledger: Book.ledger(entries), period: .month(Book.september))
    // 55 typed, then 5 of the 50 the rule promises.
    #expect(expected(report, Book.beta, Book.september) == money("60"))
  }

  @Test func theTrackerNeverPassesACeilingAndRefundsFreeRoom() {
    let caps = CashbackCaps(rules: Book.rules, accounts: Book.accounts())
    var tracker = CashbackCapTracker(caps: caps)
    let rule = Book.rules[0].id
    func earned(_ rubles: String) -> CashbackExpectation {
      CashbackExpectation(
        money: Money(amount: money(rubles), currency: .rub), rubles: money(rubles),
        holder: .account(Book.alpha), source: .rules([rule]),
        byRule: [rule: Decimal(string: rubles)!])
    }
    #expect(
      tracker.admit(earned("70"), month: Book.september, account: Book.alpha).rubles == money("70"))
    #expect(
      tracker.admit(earned("70"), month: Book.september, account: Book.alpha).rubles == money("30"))
    #expect(tracker.room(rule: rule, account: Book.alpha, month: Book.september) == 0)
    _ = tracker.admit(earned("-20"), month: Book.september, account: Book.alpha)
    #expect(tracker.room(rule: rule, account: Book.alpha, month: Book.september) == 20)
    #expect(tracker.room(rule: nil, account: Book.alpha, month: Book.september) == nil)
    #expect(tracker.room(rule: rule, account: Book.alpha, month: Book.october) == 100)
  }
}

@Suite("Cashback advisor")
struct CashbackAdvisorTests {
  @Test func theBestCardForACategory() {
    let ledger = Book.ledger([])
    let book = CashbackRuleBook(
      rules: Book.rules, tree: ledger.tree, cards: Book.cards, accounts: Book.accounts())
    let candidates = CashbackAdvisor.candidates(
      accounts: Book.accounts(), cards: Book.cards, book: book)
    #expect(candidates.map(\.holder) == [.account(Book.alpha), .card(Book.betaCard)])
    let tracker = CashbackCapTracker(
      caps: CashbackCaps(rules: Book.rules, accounts: Book.accounts()))
    let options = CashbackAdvisor.options(
      categoryId: Book.supermarkets, amountRub: money("1000"), month: Book.september,
      candidates: candidates, book: book, tracker: tracker)
    #expect(options.first?.candidate.holder == .card(Book.betaCard))
    #expect(options.first?.expectedRub == money("50"))
    // A subcategory takes the rule of its category.
    let coffee = CashbackAdvisor.options(
      categoryId: Book.coffee, amountRub: money("1000"), month: Book.september,
      candidates: candidates, book: book, tracker: tracker)
    #expect(coffee.first?.candidate.holder == .account(Book.alpha))
    // A hidden account is never offered.
    let shown = CashbackAdvisor.candidates(
      accounts: Book.accounts(), cards: Book.cards, book: book, hidden: [Book.beta])
    #expect(shown.map(\.accountId) == [Book.alpha])
  }

  @Test func aCardWhoseCeilingIsSpentIsNoLongerTheBest() {
    let ledger = Book.ledger([])
    let book = CashbackRuleBook(
      rules: Book.rules, tree: ledger.tree, cards: Book.cards, accounts: Book.accounts())
    var tracker = CashbackCapTracker(
      caps: CashbackCaps(rules: Book.rules, accounts: Book.accounts()))
    _ = tracker.admit(
      CashbackExpectation(
        money: Money(amount: money("60"), currency: .rub), rubles: money("60"),
        holder: .card(Book.betaCard), source: .override),
      month: Book.september, account: Book.beta)
    let options = CashbackAdvisor.options(
      categoryId: Book.supermarkets, amountRub: money("1000"), month: Book.september,
      candidates: CashbackAdvisor.candidates(
        accounts: Book.accounts(), cards: Book.cards, book: book),
      book: book, tracker: tracker)
    #expect(options.first?.candidate.holder == .account(Book.alpha))
    #expect(options.first?.expectedRub == money("10"))
  }

  @Test func missedCashbackOfPurchasesMadeWithTheWeakerCard() throws {
    let entries = [
      Book.buy(5401, "09-05", Book.supermarkets, "1000", on: Book.alpha),
      Book.buy(5402, "09-06", Book.supermarkets, "1000", on: Book.beta, card: Book.betaCard),
      Book.buy(5403, "09-07", Book.cafes, "1000", on: Book.alpha),
    ]
    let missed = MissedCashback(ledger: Book.ledger(entries), period: .month(Book.september))
    let item = try #require(missed.items.first)
    #expect(missed.items.count == 1)
    #expect(item.transactionId == id(5401))
    #expect(item.actualRub == money("10"))
    // Beta had earned nothing yet that month: its 5 % fits under its 60.
    #expect(item.bestRub == money("50"))
    #expect(missed.totalRub == money("40"))
    #expect(missed.byMonth.map(\.month) == [Book.september])
    let hidden = MissedCashback(
      ledger: Book.ledger(entries), period: .month(Book.september), hidden: [Book.beta])
    #expect(hidden.items.isEmpty)
  }

  /// A dinner at 02:00 on 1 October in Bali is October's: the period reads the day in the zone the
  /// purchase was recorded in, the same zone its rule month and the ledger use, not the zone of
  /// the Mac it is opened on.
  @Test func missedCashbackReadsThePurchaseDayInItsRecordedZone() throws {
    var late = Book.buy(5601, "10-01", Book.supermarkets, "1000", on: Book.alpha)
    // 02:00 in UTC+8 is 18:00 of 30 September in UTC.
    late.transaction.occurredAt = Date(timeIntervalSince1970: 1_790_791_200)  // 2026-09-30T18:00Z
    late.transaction.timeZoneId = "Asia/Makassar"
    let ledger = Book.ledger([late])
    let october = MissedCashback(ledger: ledger, period: .month(Book.october))
    #expect(october.items.map(\.transactionId) == [id(5601)])
    #expect(october.byMonth.map(\.month) == [Book.october])
    let september = MissedCashback(ledger: ledger, period: .month(Book.september))
    #expect(september.items.isEmpty)
  }

  @Test func missedCashbackWeighsTheRoomLeftAtThatMoment() {
    let entries = [
      Book.buy(5501, "09-02", Book.supermarkets, "1000", on: Book.beta, card: Book.betaCard),
      Book.buy(5502, "09-03", Book.supermarkets, "1000", on: Book.alpha),
    ]
    let missed = MissedCashback(ledger: Book.ledger(entries), period: .month(Book.september))
    // Beta had 10 ₽ of room left: Alpha's 10 ₽ was as good.
    #expect(missed.items.isEmpty)
  }
}

@Suite("Monthly choice of cashback categories")
struct CashbackChoiceTests {
  static let mappings = [
    BankCategoryMapping(bankId: Book.bank, label: "Супермаркеты", categoryId: Book.supermarkets),
    BankCategoryMapping(bankId: Book.bank, label: "Кафе и рестораны", categoryId: Book.cafes),
    BankCategoryMapping(bankId: Book.bank, label: "Аптеки", categoryId: Book.pharmacy),
    BankCategoryMapping(bankId: Book.bank, label: "Всё для дома", categoryId: Book.supermarkets),
    BankCategoryMapping(bankId: id(9999), label: "АЗС", categoryId: Book.fuel),
  ]

  static func offer(_ n: Int, _ label: String, _ e4: Int64) -> CashbackOffer {
    CashbackOffer(
      id: id(n), accountId: Book.alpha, month: Book.october, label: label,
      percent: CashbackPercent(e4: e4)!)
  }

  static let offers = [
    offer(7501, "Супермаркеты", 50_000), offer(7502, "кафе и рестораны ", 50_000),
    offer(7503, "Аптеки", 70_000), offer(7504, "АЗС", 30_000),
  ]

  /// Supermarkets 6 000 a month, cafes 3 000 (coffee 1 000 of it), pharmacy 2 000, fuel 9 000.
  static func history() -> Ledger {
    var entries: [TransactionEntry] = []
    var n = 6000
    for month in ["07", "08", "09"] {
      for (category, amount) in [
        (Book.supermarkets, "6000"), (Book.cafes, "2000"), (Book.coffee, "1000"),
        (Book.pharmacy, "2000"), (Book.fuel, "9000"),
      ] {
        entries.append(Book.buy(n, "\(month)-10", category, amount, on: Book.alpha))
        n += 1
      }
    }
    return Book.ledger(entries)
  }

  @Test func theSpendingOfTheLastMonthsByCategory() {
    let spending = CashbackChoiceAdvisor.monthlySpending(
      ledger: Self.history(), before: Book.october)
    #expect(spending[Book.supermarkets] == money("6000"))
    #expect(spending[Book.coffee] == money("1000"))
    #expect(spending[Book.fuel] == money("9000"))
    let ledger = Self.history()
    // A label covers its categories and what lies under them; another bank's table is not read.
    #expect(
      CashbackChoiceAdvisor.spending(
        of: "КАФЕ И РЕСТОРАНЫ", bankId: Book.bank, mappings: Self.mappings, spending: spending,
        tree: ledger.tree) == money("3000"))
    #expect(
      CashbackChoiceAdvisor.spending(
        of: "АЗС", bankId: Book.bank, mappings: Self.mappings, spending: spending,
        tree: ledger.tree) == .zero)
  }

  @Test func theBestTwoOfFour() throws {
    let ledger = Self.history()
    let spending = CashbackChoiceAdvisor.monthlySpending(ledger: ledger, before: Book.october)
    let picks = CashbackChoiceAdvisor.best(
      offers: Self.offers, pick: 2, bankId: Book.bank, mappings: Self.mappings,
      spending: spending, tree: ledger.tree)
    let best = try #require(picks.first)
    // Supermarkets 300 + cafes 150 = 450 beats supermarkets + pharmacy 300 + 140 = 440.
    #expect(Set(best.offerIds) == [id(7501), id(7502)])
    #expect(best.expectedRub == money("450"))
    #expect(picks.count == 3)
    #expect(picks[1].expectedRub == money("440"))
    // The account's ceiling bounds every choice.
    let capped = CashbackChoiceAdvisor.best(
      offers: Self.offers, pick: 2, bankId: Book.bank, mappings: Self.mappings,
      spending: spending, tree: ledger.tree, accountCap: money("400"))
    #expect(capped.first?.expectedRub == money("400"))
    #expect(
      CashbackChoiceAdvisor.best(
        offers: [], pick: 2, bankId: Book.bank, mappings: Self.mappings, spending: spending,
        tree: ledger.tree
      ).isEmpty)
  }

  @Test func takingAChoiceWritesTheMonthsRules() {
    let chosen = [Self.offers[0], Self.offers[3], Self.offer(7505, "Всё для дома", 70_000)]
    let rules = CashbackChoiceAdvisor.rules(
      for: chosen, bankId: Book.bank, mappings: Self.mappings)
    // «АЗС» has no category in this bank's table: nothing for it. Supermarkets: the higher of
    // the two labels that stand for it.
    #expect(rules.count == 1)
    #expect(rules.first?.categoryId == Book.supermarkets)
    #expect(rules.first?.month == Book.october)
    #expect(rules.first?.percent == CashbackPercent(e4: 70_000))
    // A rule already kept for the key keeps its row.
    let kept = CashbackRule(
      accountId: Book.alpha, categoryId: Book.supermarkets, month: Book.october,
      percent: CashbackPercent(e4: 10_000)!)
    let again = CashbackChoiceAdvisor.rules(
      for: chosen, bankId: Book.bank, mappings: Self.mappings, existing: [kept])
    #expect(again.first?.id == kept.id)
  }

  @Test func theReminderComesOnTheDayTheBankOpensTheChoice() {
    let calendar = CalendarContext.utc
    let accounts = Book.accounts(choiceDay: 5)
    func due(
      _ iso: String, rules: [CashbackRule] = [], offers: [CashbackOffer] = [],
      accounts: [PaymentMethod] = accounts, hidden: Set<UUID> = []
    )
      -> [CashbackChoiceDue]
    {
      CashbackChoiceDue.due(
        today: DateOnly(iso: iso)!, accounts: accounts, rules: rules, offers: offers,
        hidden: hidden, calendar: calendar)
    }
    #expect(due("2026-10-04").isEmpty)
    #expect(due("2026-10-05").map(\.accountId) == [Book.alpha])
    #expect(
      due("2026-10-05").first?.id == "cashback.choice:\(Book.alpha.uuidString.lowercased()):2026-10"
    )
    let monthRule = CashbackRule(
      accountId: Book.alpha, categoryId: Book.cafes, month: Book.october,
      percent: CashbackPercent(e4: 50_000)!)
    #expect(due("2026-10-20", rules: [monthRule]).isEmpty)
    var taken = Self.offers[0]
    taken.chosen = true
    #expect(due("2026-10-20", offers: [taken]).isEmpty)
    #expect(due("2026-10-20", offers: [Self.offers[0]]).count == 1)
    #expect(due("2026-10-20", hidden: [Book.alpha]).isEmpty)
    // The 31st in February is its last day.
    #expect(due("2027-02-28", accounts: Book.accounts(choiceDay: 31)).count == 1)
    #expect(due("2027-02-27", accounts: Book.accounts(choiceDay: 31)).isEmpty)
    #expect(due("2026-10-20", accounts: Book.accounts(choiceDay: nil)).isEmpty)
  }
}

@Suite("Pay here and the cashback trap")
struct CashbackHintTests {
  @Test func aPlacePaidWithTheWeakerCardGetsAHint() throws {
    let entries = (0..<3).map {
      Book.buy(
        5600 + $0, "10-\(10 + $0)", Book.supermarkets, "2000", on: Book.alpha, place: Book.shop)
    }
    let accounts = Book.accounts(betaCap: nil)
    let ledger = Book.ledger(entries, accounts: accounts)
    let hints = CashbackHints.payHere(ledger: ledger, today: DateOnly(iso: "2026-10-20")!)
    let hint = try #require(hints.first)
    #expect(hint.placeId == Book.shop)
    #expect(hint.best.holder == .card(Book.betaCard))
    #expect(hint.bestPercent == CashbackPercent(e4: 50_000))
    #expect(hint.usual?.holder == .account(Book.alpha))
    #expect(hint.usualPercent == CashbackPercent(e4: 10_000))
    // 6 000 at 5 % instead of 1 %.
    #expect(hint.gainRub == money("240"))
    #expect(
      CashbackHints.payHere(
        ledger: ledger, today: DateOnly(iso: "2026-10-20")!, hidden: [Book.beta]
      ).isEmpty)
    // Too small a gain says nothing.
    #expect(
      CashbackHints.payHere(
        ledger: ledger, today: DateOnly(iso: "2026-10-20")!, minGain: money("500")
      ).isEmpty)
  }

  /// What the usual card really paid under its ceiling is what the better card is compared to:
  /// 2 × 2 000 at 1 % is 40 while the ceiling lasts, 30 when it stops at 30, nothing when
  /// earlier purchases of the month used it up; Beta pays 200.
  @Test func theUsualCardsCeilingCountsInTheGain() throws {
    let entries = (0..<2).map {
      Book.buy(
        5950 + $0, "10-\(10 + $0)", Book.supermarkets, "2000", on: Book.alpha, place: Book.shop)
    }
    func gain(cap: String, _ entries: [TransactionEntry]) throws -> AmountE4 {
      let rules = Book.rules + [Book.rule(7303, Book.alpha, nil, Book.supermarkets, 10_000, cap: cap)]
      let ledger = Book.ledger(entries, rules: rules, accounts: Book.accounts(betaCap: nil))
      return try #require(
        CashbackHints.payHere(ledger: ledger, today: DateOnly(iso: "2026-10-20")!).first
      ).gainRub
    }
    #expect(try gain(cap: "1000", entries) == money("160"))
    #expect(try gain(cap: "50", entries) == money("160"))
    #expect(try gain(cap: "30", entries) == money("170"))
    // Earlier in the month a purchase without a place used the whole ceiling of 50.
    let earlier = Book.buy(5949, "10-01", Book.supermarkets, "5000", on: Book.alpha)
    #expect(try gain(cap: "50", [earlier] + entries) == money("200"))
  }

  /// A split purchase whose second part was refunded earns its place on what is left of the
  /// whole receipt: the hint prices 6 000, not the 8 000 the receipt first said.
  @Test func aRefundOfALaterPartTakesItsMoneyOutOfTheHint() throws {
    var entries = (0..<2).map {
      Book.buy(
        5800 + $0, "10-\(10 + $0)", Book.supermarkets, "2000", on: Book.alpha, place: Book.shop)
    }
    entries.append(
      CashbackBook.operation(
        5810, on: "10-12", parts: [(Book.supermarkets, "2000"), (Book.pharmacy, "2000")],
        account: Book.alpha, place: Book.shop))
    entries.append(
      CashbackBook.operation(
        5811, .refund, on: "10-13", parts: [(Book.pharmacy, "2000")], account: Book.alpha,
        refundOf: id(58_101), place: Book.shop))
    let ledger = Book.ledger(entries, accounts: Book.accounts(betaCap: nil))
    let hint = try #require(
      CashbackHints.payHere(ledger: ledger, today: DateOnly(iso: "2026-10-20")!).first)
    // 6 000 at 5 % instead of 1 %.
    #expect(hint.gainRub == money("240"))
  }

  @Test func theTrapOfAMonthCategory() throws {
    var entries: [TransactionEntry] = []
    var n = 5700
    for month in ["07", "08", "09"] {
      entries.append(Book.buy(n, "\(month)-10", Book.pharmacy, "1000", on: Book.alpha))
      n += 1
    }
    entries.append(Book.buy(n, "10-10", Book.pharmacy, "3000", on: Book.alpha))
    let monthRule = Book.rule(7320, Book.alpha, nil, Book.pharmacy, 50_000, month: Book.october)
    let ledger = Book.ledger(entries, rules: Book.rules + [monthRule])
    let trap = try #require(CashbackHints.traps(ledger: ledger, month: Book.october).first)
    #expect(trap.categoryId == Book.pharmacy)
    #expect(trap.spentRub == money("3000"))
    #expect(trap.usualRub == money("1000"))
    #expect(trap.cashbackRub == money("150"))
    #expect(trap.id == "cashback.trap:2026-10:\(Book.pharmacy.uuidString.lowercased())")
    // Usual spending is no trap.
    var calm = entries
    calm[calm.count - 1] = Book.buy(n, "10-10", Book.pharmacy, "1200", on: Book.alpha)
    #expect(
      CashbackHints.traps(
        ledger: Book.ledger(calm, rules: Book.rules + [monthRule]), month: Book.october
      )
      .isEmpty)
    // Without the month's rule there is nothing the cashback lured.
    #expect(CashbackHints.traps(ledger: Book.ledger(entries), month: Book.october).isEmpty)
    // A hidden account's rule says nothing.
    #expect(
      CashbackHints.traps(
        ledger: ledger, month: Book.october, hidden: [Book.alpha]
      ).isEmpty)
  }

  @Test func theTrapCountsMyExpensesNotWhatWasPaidForSomebodyElse() throws {
    var entries: [TransactionEntry] = []
    var n = 5900
    for month in ["07", "08", "09"] {
      entries.append(Book.buy(n, "\(month)-10", Book.pharmacy, "1000", on: Book.alpha))
      n += 1
    }
    entries.append(Book.buy(n, "10-10", Book.pharmacy, "1000", on: Book.alpha))
    var friend = Book.buy(n + 1, "10-11", Book.pharmacy, "2500", on: Book.alpha)
    friend.parts[0].reimbursable = true
    entries.append(friend)
    let monthRule = Book.rule(7320, Book.alpha, nil, Book.pharmacy, 50_000, month: Book.october)
    // 3 500 left the card, only 1 000 is mine and that is the usual: no trap.
    #expect(
      CashbackHints.traps(
        ledger: Book.ledger(entries, rules: Book.rules + [monthRule]), month: Book.october
      )
      .isEmpty)
    // Written off, the 2 500 become mine and the trap speaks with the sum of my expenses.
    entries[entries.count - 1].parts[0].reimbursementStatus = .writtenOff
    let trap = try #require(
      CashbackHints.traps(
        ledger: Book.ledger(entries, rules: Book.rules + [monthRule]), month: Book.october
      ).first)
    #expect(trap.spentRub == money("3500"))
  }

  @Test func theNotesTogetherWithoutThePutAway() {
    var entries: [TransactionEntry] = []
    var n = 5800
    for month in ["07", "08", "09"] {
      entries.append(Book.buy(n, "\(month)-10", Book.pharmacy, "1000", on: Book.alpha))
      n += 1
    }
    entries.append(Book.buy(n, "10-10", Book.pharmacy, "3000", on: Book.alpha))
    let monthRule = Book.rule(7320, Book.alpha, nil, Book.pharmacy, 50_000, month: Book.october)
    let ledger = Book.ledger(
      entries, rules: Book.rules + [monthRule], accounts: Book.accounts(choiceDay: 1))
    let today = DateOnly(iso: "2026-10-20")!
    let notes = CashbackNote.list(ledger: ledger, today: today)
    // The month has a rule of Alpha's, so its choice is made; the trap speaks.
    #expect(notes.contains { if case .trap = $0 { true } else { false } })
    #expect(!notes.contains { if case .choose = $0 { true } else { false } })
    let ids = Set(notes.map(\.id))
    #expect(CashbackNote.list(ledger: ledger, today: today, dismissed: ids).isEmpty)
  }
}

@Suite("Cashback categories by merchant code")
struct CashbackMerchantCodeTests {
  static let eatingOut = BankCategoryMapping(
    bankId: Book.bank, label: "Рестораны", categoryId: Book.cafes,
    includeCodes: MerchantCodeList(parsing: "5811-5814")!,
    excludeCodes: MerchantCodeList(parsing: "5813")!)

  /// Three months of the same month: Cafes 600 with code 5812, Cafes 300 with 5813, Cafes 90
  /// without a code, Fuel 150 with 5812 (a code in the list, a category the row does not name),
  /// Supermarkets 300 without a code.
  static func history() -> Ledger {
    var entries: [TransactionEntry] = []
    var n = 8000
    for month in ["07", "08", "09"] {
      for (category, amount, mcc) in [
        (Book.cafes, "600", "5812"), (Book.cafes, "300", "5813"), (Book.cafes, "90", nil),
        (Book.fuel, "150", "5812"), (Book.supermarkets, "300", nil),
      ] as [(UUID, String, String?)] {
        var entry = Book.buy(n, "\(month)-10", category, amount, on: Book.alpha)
        entry.transaction.mcc = mcc
        entries.append(entry)
        n += 1
      }
    }
    return Book.ledger(entries)
  }

  @Test func theSpendingKeepsTheCodeApart() {
    let ledger = Self.history()
    let coded = CashbackChoiceAdvisor.monthlyCodedSpending(ledger: ledger, before: Book.october)
    #expect(coded.buckets[.init(categoryId: Book.cafes, mcc: "5812")] == money("600"))
    #expect(coded.buckets[.init(categoryId: Book.cafes, mcc: "5813")] == money("300"))
    #expect(coded.buckets[.init(categoryId: Book.cafes)] == money("90"))
    // The plain figure per category is what it was before codes were kept.
    let plain = CashbackChoiceAdvisor.monthlySpending(ledger: ledger, before: Book.october)
    #expect(plain[Book.cafes] == money("990"))
    #expect(plain[Book.fuel] == money("150"))
  }

  @Test func aCodeInTheIncludeListCountsWhateverTheCategory() {
    let ledger = Self.history()
    let coded = CashbackChoiceAdvisor.monthlyCodedSpending(ledger: ledger, before: Book.october)
    // 5812 in Cafes (600) and in Fuel (150); 5813 is excluded; no code → by category (90).
    #expect(
      CashbackChoiceAdvisor.spending(
        of: "Рестораны", bankId: Book.bank, mappings: [Self.eatingOut], coded: coded,
        tree: ledger.tree) == money("840"))
  }

  @Test func withoutACodeTheCategoryDecidesAsBefore() {
    let ledger = Self.history()
    let plainRow = BankCategoryMapping(
      bankId: Book.bank, label: "Рестораны", categoryId: Book.cafes)
    let coded = CashbackChoiceAdvisor.monthlyCodedSpending(ledger: ledger, before: Book.october)
    let spending = CashbackChoiceAdvisor.monthlySpending(ledger: ledger, before: Book.october)
    // A row with no lists reads the same whether or not the purchases carry codes.
    #expect(
      CashbackChoiceAdvisor.spending(
        of: "Рестораны", bankId: Book.bank, mappings: [plainRow], coded: coded,
        tree: ledger.tree)
        == CashbackChoiceAdvisor.spending(
          of: "Рестораны", bankId: Book.bank, mappings: [plainRow], spending: spending,
          tree: ledger.tree))
    // Operations with no code at all: the code lists change nothing.
    let bare = Book.ledger(
      (0..<3).map { Book.buy(8500 + $0, "0\(7 + $0)-10", Book.cafes, "300", on: Book.alpha) })
    let bareCoded = CashbackChoiceAdvisor.monthlyCodedSpending(
      ledger: bare, before: Book.october)
    #expect(
      CashbackChoiceAdvisor.spending(
        of: "Рестораны", bankId: Book.bank, mappings: [Self.eatingOut], coded: bareCoded,
        tree: bare.tree) == money("300"))
  }

  @Test func rowsWithoutListsGiveTheOldFiguresToTheKopeck() {
    // 100 with a code and 100 without in one month, nothing in the others: 200 / 3 months.
    var coded = Book.buy(8700, "09-10", Book.cafes, "100", on: Book.alpha)
    coded.transaction.mcc = "5812"
    let bare = Book.buy(8701, "09-11", Book.cafes, "100", on: Book.alpha)
    let other = Book.buy(8702, "09-12", Book.coffee, "100", on: Book.alpha)
    let ledger = Book.ledger([coded, bare, other])
    let both = CashbackChoiceAdvisor.monthlyCodedSpending(ledger: ledger, before: Book.october)
    let old = CashbackChoiceAdvisor.monthlySpending(ledger: ledger, before: Book.october)
    #expect(both.plain == old)
    let plainRow = BankCategoryMapping(
      bankId: Book.bank, label: "Кафе", categoryId: Book.cafes)
    #expect(
      CashbackChoiceAdvisor.spending(
        of: "Кафе", bankId: Book.bank, mappings: [plainRow], coded: both, tree: ledger.tree)
        == CashbackChoiceAdvisor.spending(
          of: "Кафе", bankId: Book.bank, mappings: [plainRow], spending: old, tree: ledger.tree))
    let offers = [CashbackChoiceTests.offer(8801, "Кафе", 50_000)]
    #expect(
      CashbackChoiceAdvisor.best(
        offers: offers, pick: 1, bankId: Book.bank, mappings: [plainRow], coded: both,
        tree: ledger.tree)
        == CashbackChoiceAdvisor.best(
          offers: offers, pick: 1, bankId: Book.bank, mappings: [plainRow], spending: old,
          tree: ledger.tree))
  }

  @Test func anExclusionOnlyRowStillGoesByCategory() {
    let ledger = Self.history()
    let row = BankCategoryMapping(
      bankId: Book.bank, label: "Кафе", categoryId: Book.cafes,
      excludeCodes: MerchantCodeList(parsing: "5813")!)
    let coded = CashbackChoiceAdvisor.monthlyCodedSpending(ledger: ledger, before: Book.october)
    // Cafes 600 + 90 without the excluded 300; Fuel is not under Cafes.
    #expect(
      CashbackChoiceAdvisor.spending(
        of: "Кафе", bankId: Book.bank, mappings: [row], coded: coded, tree: ledger.tree)
        == money("690"))
  }

  @Test func twoLabelsOverTheSameCodeCountOnceAtTheHigherPercent() throws {
    let ledger = Self.history()
    let coded = CashbackChoiceAdvisor.monthlyCodedSpending(ledger: ledger, before: Book.october)
    let wide = BankCategoryMapping(
      bankId: Book.bank, label: "Всё вкусное", categoryId: Book.cafes,
      includeCodes: MerchantCodeList(parsing: "5811-5814")!)
    let offers = [
      CashbackChoiceTests.offer(8601, "Рестораны", 50_000),
      CashbackChoiceTests.offer(8602, "Всё вкусное", 30_000),
    ]
    let picks = CashbackChoiceAdvisor.best(
      offers: offers, pick: 2, bankId: Book.bank, mappings: [Self.eatingOut, wide],
      coded: coded, tree: ledger.tree)
    // «Рестораны» 5 % of 840 = 42.00; «Всё вкусное» also reaches 5813 (300 → 3 %): 9.00.
    // The shared 5812 purchases are counted once at 5 %.
    #expect(picks.first?.expectedRub == money("51"))
  }

  @Test func theCodeListsReadAndWriteBack() throws {
    let list = try #require(MerchantCodeList(parsing: "5814, 5811–5812; 742, 5813"))
    #expect(list.text == "0742, 5811-5814")
    #expect(list.contains("5812") && list.contains("742") && !list.contains("5815"))
    #expect(!list.contains(nil as String?))
    #expect(MerchantCodeList(parsing: "")?.isEmpty == true)
    #expect(MerchantCodeList(parsing: "58x1") == nil)
    #expect(MerchantCodeList(parsing: "5814-5811") == nil)
    #expect(MerchantCodeList(parsing: "10000") == nil)
    #expect(MerchantCodeList(parsing: "1-2-3") == nil)
  }

  @Test func aMappingWrittenBeforeCodesDecodesWithNoLists() throws {
    let old = """
      {"id":"00000000-0000-0000-0000-000000000001","bankId":"00000000-0000-0000-0000-000000000002",
      "label":"X","categoryId":"00000000-0000-0000-0000-000000000003"}
      """
    let mapping = try JSONDecoder().decode(BankCategoryMapping.self, from: Data(old.utf8))
    #expect(!mapping.hasCodes)
    let round = try JSONDecoder().decode(
      BankCategoryMapping.self, from: JSONEncoder().encode(Self.eatingOut))
    #expect(round == Self.eatingOut)
  }
}

/// The expected cashback of a purchase, the advice of a card and «Упущенный кэшбэк» read the
/// code lists of the bank's table through the rule's category (`CashbackRuleBook`): Alpha's
/// bank names «Рестораны» → Cafes with codes 5811-5814 except 5813; Alpha has Cafes 5 % and
/// everything else 1 %.
@Suite("Expected cashback by merchant code")
struct CashbackRuleByCodeTests {
  static let eatingOut = CashbackMerchantCodeTests.eatingOut

  static func purchase(
    _ n: Int, _ category: UUID, _ amount: String, mcc: String?, day: String = "09-10",
    on account: UUID = Book.alpha, card: UUID? = nil
  ) -> TransactionEntry {
    var entry = Book.buy(n, day, category, amount, on: account, card: card)
    entry.transaction.mcc = mcc
    return entry
  }

  static func earned(
    _ entry: TransactionEntry, mappings: [BankCategoryMapping], rules: [CashbackRule] = Book.rules,
    holder: CashbackHolder = .account(Book.alpha)
  ) -> AmountE4? {
    let ledger = Book.ledger([entry], rules: rules, mappings: mappings)
    let book = CashbackRuleBook(
      rules: rules, tree: ledger.tree, cards: Book.cards, accounts: Book.accounts(),
      mappings: mappings)
    return CashbackMath.expected(
      entry, holder: holder, book: book, tree: ledger.tree, calendar: ledger.calendar,
      refunded: { _ in .zero }
    )?.money.amount
  }

  @Test func withoutListsTheFigureIsTheOldOneToTheKopeck() {
    let plainRow = BankCategoryMapping(
      bankId: Book.bank, label: "Рестораны", categoryId: Book.cafes)
    for (n, category, mcc) in [
      (9001, Book.cafes, "5813"), (9002, Book.fuel, "5812"), (9003, Book.coffee, nil),
    ] as [(Int, UUID, String?)] {
      let entry = Self.purchase(n, category, "333.33", mcc: mcc)
      let old = Self.earned(entry, mappings: [])
      #expect(Self.earned(entry, mappings: [plainRow]) == old)
      // A list at another bank changes nothing for Alpha.
      var elsewhere = Self.eatingOut
      elsewhere.bankId = id(9999)
      #expect(Self.earned(entry, mappings: [elsewhere]) == old)
    }
    #expect(Self.earned(Self.purchase(9004, Book.cafes, "333.33", mcc: nil), mappings: [])
      == money("16.67"))
  }

  @Test func theListsDecideForAPurchaseWithACode() {
    let rows = [Self.eatingOut]
    // In the list: Cafes 5 %.
    #expect(Self.earned(Self.purchase(9101, Book.cafes, "1000", mcc: "5812"), mappings: rows)
      == money("50"))
    // Excluded: the label does not take it, everything else does.
    #expect(Self.earned(Self.purchase(9102, Book.cafes, "1000", mcc: "5813"), mappings: rows)
      == money("10"))
    // A code outside a non-empty include list: not the label's.
    #expect(Self.earned(Self.purchase(9103, Book.cafes, "1000", mcc: "5999"), mappings: rows)
      == money("10"))
    // No code: by category, as before.
    #expect(Self.earned(Self.purchase(9104, Book.coffee, "1000", mcc: nil), mappings: rows)
      == money("50"))
    // A code the list names, in a category the row does not name: the bank counts the code.
    #expect(Self.earned(Self.purchase(9105, Book.fuel, "1000", mcc: "5812"), mappings: rows)
      == money("50"))
  }

  @Test func anExclusionOnlyRowIsTheCategoryWithoutTheExcludedCodes() {
    let rows = [
      BankCategoryMapping(
        bankId: Book.bank, label: "Кафе", categoryId: Book.cafes,
        excludeCodes: MerchantCodeList(parsing: "5813")!)
    ]
    #expect(Self.earned(Self.purchase(9201, Book.cafes, "1000", mcc: "5813"), mappings: rows)
      == money("10"))
    #expect(Self.earned(Self.purchase(9202, Book.coffee, "1000", mcc: "5999"), mappings: rows)
      == money("50"))
    #expect(Self.earned(Self.purchase(9203, Book.fuel, "1000", mcc: "5812"), mappings: rows)
      == money("10"))
  }

  @Test func aRowWithoutListsBesideOneWithListsStillTakesTheCategory() {
    // Two labels for Cafes: one by codes, one plain. The plain one takes every Cafes purchase.
    let plain = BankCategoryMapping(bankId: Book.bank, label: "Кафе", categoryId: Book.cafes)
    #expect(
      Self.earned(
        Self.purchase(9301, Book.cafes, "1000", mcc: "5999"), mappings: [Self.eatingOut, plain])
        == money("50"))
  }

  @Test func theMonthStepComesFirstAndInItTheNamedCodeWins() {
    let fuelMonth = Book.rule(9401, Book.alpha, nil, Book.fuel, 30_000, month: Book.september)
    let rows = [Self.eatingOut]
    // Fuel's own month rule beats Cafes' «always» rule that names the code.
    #expect(
      Self.earned(
        Self.purchase(9402, Book.fuel, "1000", mcc: "5812"), mappings: rows,
        rules: Book.rules + [fuelMonth]) == money("30"))
    // A month rule of Cafes that names the code beats Fuel's month rule.
    let cafesMonth = Book.rule(9403, Book.alpha, nil, Book.cafes, 70_000, month: Book.september)
    #expect(
      Self.earned(
        Self.purchase(9404, Book.fuel, "1000", mcc: "5812"), mappings: rows,
        rules: Book.rules + [fuelMonth, cafesMonth]) == money("70"))
    // Another month: the September rules are not there, «always» Cafes takes the code.
    #expect(
      Self.earned(
        Self.purchase(9405, Book.fuel, "1000", mcc: "5812", day: "10-10"), mappings: rows,
        rules: Book.rules + [fuelMonth, cafesMonth]) == money("50"))
  }

  @Test func theAdviceOfACardReadsThePlacesCode() {
    let ledger = Book.ledger([], mappings: [Self.eatingOut])
    let book = CashbackRuleBook(
      rules: Book.rules, tree: ledger.tree, cards: Book.cards, accounts: Book.accounts(),
      mappings: [Self.eatingOut])
    let candidates = CashbackAdvisor.candidates(
      accounts: Book.accounts(), cards: Book.cards, book: book)
    let tracker = CashbackCapTracker(caps: CashbackCaps(rules: [], accounts: []))
    let byCode = CashbackAdvisor.options(
      categoryId: Book.fuel, amountRub: money("1000"), month: Book.september,
      candidates: candidates, book: book, tracker: tracker, mcc: "5812")
    #expect(byCode.first?.candidate.accountId == Book.alpha)
    #expect(byCode.first?.percent == CashbackPercent(e4: 50_000))
    let byCategory = CashbackAdvisor.options(
      categoryId: Book.fuel, amountRub: money("1000"), month: Book.september,
      candidates: candidates, book: book, tracker: tracker)
    #expect(byCategory.first?.percent == CashbackPercent(e4: 10_000))
  }

  @Test func theMissedCashbackSeesTheCardTheCodeWouldHavePaidMore() {
    // Fuel 1000 with code 5812 paid by Beta's card: 1 % there; Alpha's «Рестораны» takes 5812.
    let entry = Self.purchase(
      9501, Book.fuel, "1000", mcc: "5812", on: Book.beta, card: Book.betaCard)
    let plain = MissedCashback(ledger: Book.ledger([entry]), period: .month(Book.september))
    #expect(plain.items.isEmpty)
    let coded = MissedCashback(
      ledger: Book.ledger([entry], mappings: [Self.eatingOut]), period: .month(Book.september))
    let item = try? #require(coded.items.first)
    #expect(item?.actualRub == money("10"))
    #expect(item?.bestRub == money("50"))
    #expect(item?.best.accountId == Book.alpha)
    // The report of the card that was used says the same figure as the missed list.
    let report = CashbackReport(
      ledger: Book.ledger([entry], mappings: [Self.eatingOut]), period: .month(Book.september))
    #expect(expected(report, Book.beta, Book.september) == money("10"))
  }

  @Test func theReportOfTheAccountCountsByTheCode() {
    let entry = Self.purchase(9601, Book.fuel, "1000", mcc: "5812")
    let plain = CashbackReport(ledger: Book.ledger([entry]), period: .month(Book.september))
    #expect(expected(plain, Book.alpha, Book.september) == money("10"))
    let coded = CashbackReport(
      ledger: Book.ledger([entry], mappings: [Self.eatingOut]), period: .month(Book.september))
    #expect(expected(coded, Book.alpha, Book.september) == money("50"))
  }
}

/// «Здесь лучше платить …»: the advice for a mark of the owner's on the map.
@Suite("Advice for a marked place")
struct PlaceAdviceTests {
  private let today = DateOnly(iso: "2026-10-20")!

  private func mark(place: UUID? = nil, category: UUID? = nil) -> PlaceMark {
    PlaceMark(
      name: "Mark", point: GeoPoint(latitudeE7: 0, longitudeE7: 0)!, placeId: place,
      categoryId: category)
  }

  private func history() -> [TransactionEntry] {
    (0..<3).map {
      Book.buy(
        6600 + $0, "10-\(10 + $0)", Book.supermarkets, "2000", on: Book.alpha, place: Book.shop)
    }
  }

  @Test func aPlaceWithHistoryAdvisesTheCardThatEarnsMoreForWhatIsBoughtThere() throws {
    let ledger = Book.ledger(history(), accounts: Book.accounts(betaCap: nil))
    let advice = try #require(
      PlaceAdvisor.advice(for: mark(place: Book.shop), ledger: ledger, today: today))
    #expect(advice.best.holder == .card(Book.betaCard))
    #expect(advice.bestPercent == CashbackPercent(e4: 50_000))
    #expect(advice.categoryId == Book.supermarkets)
    #expect(!advice.isUsualCard)
  }

  @Test func aMarkWithACategoryAndNoHistoryAdvisesByTheCategory() throws {
    let ledger = Book.ledger([], accounts: Book.accounts(betaCap: nil))
    let advice = try #require(
      PlaceAdvisor.advice(for: mark(category: Book.supermarkets), ledger: ledger, today: today))
    #expect(advice.best.holder == .card(Book.betaCard))
    let cafes = try #require(
      PlaceAdvisor.advice(for: mark(category: Book.cafes), ledger: ledger, today: today))
    #expect(cafes.best.holder == .account(Book.alpha))
    #expect(cafes.bestPercent == CashbackPercent(e4: 50_000))
  }

  @Test func aMarkThatSaysNothingOfWhatIsBoughtGetsNoAdvice() {
    let ledger = Book.ledger(history(), accounts: Book.accounts(betaCap: nil))
    #expect(PlaceAdvisor.advice(for: mark(), ledger: ledger, today: today) == nil)
    // A place the books never saw and no category either.
    #expect(PlaceAdvisor.advice(for: mark(place: UUID()), ledger: ledger, today: today) == nil)
  }

  @Test func aHiddenAccountIsNeverAdvised() throws {
    let ledger = Book.ledger(history(), accounts: Book.accounts(betaCap: nil))
    let advice = try #require(
      PlaceAdvisor.advice(
        for: mark(place: Book.shop), ledger: ledger, today: today, hidden: [Book.beta]))
    #expect(advice.best.accountId == Book.alpha)
    #expect(advice.isUsualCard)
  }

  @Test func withoutAnyRuleThereIsNothingToAdvise() {
    let ledger = Book.ledger(history(), rules: [])
    #expect(PlaceAdvisor.advice(for: mark(place: Book.shop), ledger: ledger, today: today) == nil)
  }
}
