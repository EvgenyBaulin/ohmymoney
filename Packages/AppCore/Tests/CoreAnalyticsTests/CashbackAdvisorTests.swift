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
    accounts: [PaymentMethod] = accounts()
  ) -> Ledger {
    Ledger(
      dataset: Dataset(
        entries: entries, categories: categories, places: [Place(id: shop, name: "Shop")],
        paymentMethods: accounts, cards: cards, cashbackRules: rules),
      calendar: .utc)
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
