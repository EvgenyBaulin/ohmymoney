import CoreKit
import Foundation
import Testing

@testable import CoreAccounting

@Suite("Rules of the accounts")
struct AccountRulesTests {
  let categories = StartingCategories()
  let russian = Locale(identifier: "ru_RU")
  let kzt = CurrencyCode("KZT")

  func account(
    _ number: Int, _ name: String, main: Bool = false, sort: Int = 0, group: UUID? = nil,
    currency: CurrencyCode = .rub, others: [CurrencyCode] = [], archived: Bool = false
  ) -> PaymentMethod {
    PaymentMethod(
      id: id(number), name: name, currency: currency, isDefault: main, archived: archived,
      groupId: group, sort: sort, otherCurrencies: others)
  }

  // MARK: Order

  @Test func theMainAccountComesFirstAndTheRestAlphabetically() {
    let list = [
      account(1, "Сбер"), account(2, "альфа"), account(3, "Т-Банк", main: true),
      account(4, "Наличные"), account(5, "Архив", archived: true),
    ]
    #expect(
      AccountRules.ordered(list, locale: russian).map(\.name) == [
        "Т-Банк", "альфа", "Наличные", "Сбер",
      ])
    #expect(AccountRules.ordered(list, locale: russian, includeArchived: true).count == 5)
  }

  @Test func theDraggedOrderStaysAndAlphabetizingForgetsIt() {
    let list = [account(1, "B"), account(2, "A"), account(3, "C", main: true)]
    let dragged = AccountRules.reordered(
      AccountRules.ordered(list, locale: russian), moving: id(1), to: 1)
    #expect(dragged.map(\.sort) == [1, 2, 3])
    #expect(AccountRules.ordered(dragged, locale: russian).map(\.name) == ["C", "B", "A"])
    let alphabetical = AccountRules.alphabetized(dragged)
    #expect(alphabetical.allSatisfy { $0.sort == 0 })
    #expect(AccountRules.ordered(alphabetical, locale: russian).map(\.name) == ["C", "A", "B"])
    #expect(AccountRules.sortForNewAccount(among: dragged) == 4)
    #expect(AccountRules.sortForNewAccount(among: alphabetical) == 0)
  }

  @Test func theSidebarPutsTheMainSectionFirstAndTheExcludedGroupsLast() {
    let russia = AccountGroup(id: id(80), name: "Россия")
    let kazakhstan = AccountGroup(id: id(81), name: "Казахстан", inSummary: false)
    let abroad = AccountGroup(id: id(82), name: "Армения")
    let old = AccountGroup(id: id(83), name: "Старое", archived: true)
    let accounts = [
      account(1, "Сбер", group: russia.id), account(2, "Т-Банк", main: true, group: russia.id),
      account(3, "Kaspi", group: kazakhstan.id, currency: kzt), account(4, "Наличные"),
      account(5, "Ереван", group: abroad.id), account(6, "Потерянная", group: old.id),
    ]
    let sections = AccountRules.sidebarSections(
      accounts: accounts, groups: [kazakhstan, abroad, russia, old], locale: russian)
    #expect(sections.map(\.group?.name) == ["Россия", nil, "Армения", "Казахстан"])
    #expect(sections[0].accounts.map(\.name) == ["Т-Банк", "Сбер"])
    #expect(sections[1].accounts.map(\.name) == ["Наличные", "Потерянная"])
  }

  @Test func withTheMainAccountInNoGroupThoseAccountsComeFirst() {
    let russia = AccountGroup(id: id(80), name: "Россия")
    let sections = AccountRules.sidebarSections(
      accounts: [account(1, "Сбер", group: russia.id), account(2, "Наличные", main: true)],
      groups: [russia], locale: russian)
    #expect(sections.map(\.group?.name) == [nil, "Россия"])
  }

  @Test func theMainAccountPassesToTheMostUsed() {
    let list = [account(1, "Main", main: true), account(2, "B"), account(3, "A"), account(4, "Z")]
    #expect(
      AccountRules.mainHandOverCandidate(
        leaving: id(1), accounts: list, liveOperations: [id(1): 50, id(4): 9, id(2): 3]) == id(4))
    #expect(
      AccountRules.mainHandOverCandidate(leaving: id(1), accounts: list, liveOperations: [:])
        == id(3))
    #expect(
      AccountRules.mainHandOverCandidate(
        leaving: id(1), accounts: [account(1, "Main", main: true)], liveOperations: [:]) == nil)
  }

  // MARK: A new operation

  @Test func theAccountOfANewOperation() {
    #expect(
      AccountRules.accountForNewOperation(
        typed: id(1), openAccountScreen: id(2), lastAtPlace: id(3), main: id(4)) == id(1))
    #expect(
      AccountRules.accountForNewOperation(
        typed: nil, openAccountScreen: id(2), lastAtPlace: id(3), main: id(4)) == id(2))
    #expect(
      AccountRules.accountForNewOperation(
        typed: nil, openAccountScreen: nil, lastAtPlace: id(3), main: id(4)) == id(3))
    #expect(
      AccountRules.accountForNewOperation(
        typed: nil, openAccountScreen: nil, lastAtPlace: nil, main: id(4)) == id(4))
  }

  /// Typed wins; an account the owner chose gives its main currency; the account that came by
  /// itself does not, and the default currency applies.
  @Test func theCurrencyOfANewOperation() {
    let freedom = account(1, "Freedom", currency: .eur, others: [.usd])
    #expect(
      AccountRules.currencyForNewOperation(typed: kzt, chosenAccount: freedom, default: .rub)
        == kzt)
    #expect(
      AccountRules.currencyForNewOperation(typed: nil, chosenAccount: freedom, default: .rub)
        == .eur)
    #expect(
      AccountRules.currencyForNewOperation(typed: nil, chosenAccount: nil, default: .usd) == .usd)
    #expect(AccountRules.legCurrency(for: .usd, account: freedom) == nil)
    #expect(AccountRules.legCurrency(for: kzt, account: freedom) == .eur)
  }

  // MARK: «Списано со счёта»

  let rates = DayRates(series: [
    CurrencyCode.usd: [DayRate(day: DateOnly(year: 2026, month: 3, day: 1), perUnit: 90)],
    CurrencyCode.eur: [DayRate(day: DateOnly(year: 2026, month: 3, day: 1), perUnit: 100)],
    CurrencyCode("KZT"): [
      DayRate(day: DateOnly(year: 2026, month: 3, day: 1), perUnit: Decimal(18) / 100)
    ],
  ])

  @Test func nothingIsChargedApartOnAnAccountThatHoldsTheCurrency() {
    let cash = account(1, "Cash", others: [.usd])
    #expect(
      AccountRules.prefillLeg(
        amount: money(50), currency: .usd, rate: 90, day: day("2026-03-02"), account: cash,
        rates: rates) == nil)
  }

  /// A leg in rubles is the operation's own rubles, at its own rate.
  @Test func aRubleChargeIsTheOperationsRubles() {
    let card = account(1, "Card")
    #expect(
      AccountRules.prefillLeg(
        amount: money(50), currency: .usd, rate: Decimal(912_345) / 10_000, day: day("2026-03-02"),
        account: card, rates: rates) == money("4561.725"))
  }

  @Test func anyOtherChargeGoesThroughRublesAtTheRatesOfTheDay() {
    let tenge = account(1, "Tenge", currency: kzt)
    #expect(
      AccountRules.prefillLeg(
        amount: money(10), currency: .usd, rate: 90, day: day("2026-03-02"), account: tenge,
        rates: rates) == money(5000))
    #expect(
      AccountRules.prefillLeg(
        amount: money(900), currency: .rub, rate: nil, day: day("2026-03-02"), account: tenge,
        rates: rates) == money(5000))
    let noRate = account(2, "Lari", currency: CurrencyCode("GEL"))
    #expect(
      AccountRules.prefillLeg(
        amount: money(10), currency: .usd, rate: 90, day: day("2026-03-02"), account: noRate,
        rates: rates) == nil)
    #expect(AccountRules.crossConvert(money(10), fromPerUnit: 90, toPerUnit: 0) == nil)
  }

  func usdDinner(leg: Int?, rateSource: RateSource = .cbr, rate: Decimal = 90) -> TransactionEntry {
    let transaction = Transaction(
      id: id(9), kind: .expense, occurredAt: moment("2026-03-02"), currency: .usd,
      amountE4: money(50), rate: rate, rateSource: rateSource, amountRubE4: money(4500),
      paymentMethodId: id(1), accountCurrency: leg == nil ? nil : .rub,
      accountAmountE4: leg.map { money($0) })
    return TransactionEntry(
      transaction: transaction, parts: [TransactionPart(transactionId: id(9), amountE4: money(50))])
  }

  @Test func anUntouchedChargeIsWorkedOutAgainAfterAnEdit() {
    let before = usdDinner(leg: 4500)
    var after = TransactionDraft(entry: before)
    after.amount = money(60)
    let edit = AccountRules.legAfterEdit(
      before: before, after: after, account: account(1, "Card"), rates: rates,
      calendar: .utc)
    #expect(edit == LegEdit(outcome: .prefilled, currency: .rub, amount: money(5400)))
  }

  @Test func aTypedChargeIsKeptAndTheEditorAsksToCheckIt() {
    let before = usdDinner(leg: 4635, rateSource: .manual, rate: Decimal(927) / 10)
    var after = TransactionDraft(entry: before)
    after.amount = money(60)
    let edit = AccountRules.legAfterEdit(
      before: before, after: after, account: account(1, "Card"), rates: rates, calendar: .utc)
    #expect(edit == LegEdit(outcome: .keptTyped, currency: .rub, amount: money(4635)))
  }

  /// A refund taken back from a purchase carries the purchase's rate, 90, but the card was
  /// credited at the rate of the refund's day, 95: 40 dollars were 3 800. Cut to 30 dollars, the
  /// charge is worked out again at 95 — 2 850 —, never at the purchase's rate.
  @Test func aRefundsChargeFollowsTheRateOfItsOwnDay() {
    let refundDay = day("2026-03-20")
    let rates = DayRates(series: [
      CurrencyCode.usd: [
        DayRate(day: day("2026-03-01"), perUnit: 90), DayRate(day: refundDay, perUnit: 95),
      ]
    ])
    let transaction = Transaction(
      id: id(9), kind: .refund, occurredAt: moment("2026-03-20"), currency: .usd,
      amountE4: money(40), rate: 90, rateSource: .manual, amountRubE4: money(3600),
      paymentMethodId: id(1), accountCurrency: .rub, accountAmountE4: money(3800))
    let before = TransactionEntry(
      transaction: transaction,
      parts: [
        TransactionPart(
          transactionId: id(9), amountE4: money(40), amountRubE4: money(3600),
          refundOfPartId: id(77))
      ])
    var after = TransactionDraft(entry: before)
    after.amount = money(30)
    after.parts[0].amount = money(30)
    #expect(
      AccountRules.legAfterEdit(
        before: before, after: after, account: account(1, "Card"), rates: rates, calendar: .utc)
        == LegEdit(outcome: .prefilled, currency: .rub, amount: money(2850)))
    // A figure typed from the statement stays, and the editor asks to check it.
    var typed = before
    typed.transaction.accountAmountE4 = money(3790)
    #expect(
      AccountRules.legAfterEdit(
        before: typed, after: after, account: account(1, "Card"), rates: rates, calendar: .utc)
        == LegEdit(outcome: .keptTyped, currency: .rub, amount: money(3790)))
  }

  @Test func aChargeIsClearedOnAnAccountThatHoldsTheCurrencyAndKeptWhenNothingChanged() {
    let before = usdDinner(leg: 4500)
    var moved = TransactionDraft(entry: before)
    moved.paymentMethodId = id(2)
    #expect(
      AccountRules.legAfterEdit(
        before: before, after: moved, account: account(2, "Cash", others: [.usd]), rates: rates,
        calendar: .utc
      ).outcome == .cleared)
    var renamed = TransactionDraft(entry: before)
    renamed.note = "dinner"
    #expect(
      AccountRules.legAfterEdit(
        before: before, after: renamed, account: account(1, "Card"), rates: rates,
        calendar: .utc) == LegEdit(outcome: .kept, currency: .rub, amount: money(4500)))
  }

  // MARK: Saving an account

  func balances(
    _ entries: [TransactionEntry] = [], anchored: [(BalanceKey, Int)] = [],
    accounts: [PaymentMethod]
  ) -> AccountBalances {
    let reconciliation = Reconciliation(
      id: id(90), date: day("2026-03-01"), reconciledAt: moment("2026-03-01"),
      actualTotalRubE4: .zero, kind: .opening)
    let counted = anchored.map {
      ReconciledBalance(
        reconciliationId: id(90), accountId: $0.0.accountId, currency: $0.0.currency,
        actualE4: money($0.1))
    }
    return AccountBalances.build(
      entries: entries, transfers: [], debtEntries: [], debts: [:],
      reconciliations: [reconciliation], balances: counted, accounts: accounts,
      tree: categories.tree, now: moment("2026-03-31"), calendar: .utc)
  }

  @Test func aNameIsNeededAndMustBeFree() {
    let others = [
      PaymentMethod(id: id(2), name: "Сбер", aliases: ["сбербанк"]),
      account(3, "Old", archived: true),
    ]
    let empty = balances(accounts: others)
    let enabled: [CurrencyCode] = [.rub]
    #expect(
      AccountRules.validate(
        account(1, "  "), previous: nil, balances: empty, enabled: enabled, others: others)
        == [.emptyName])
    #expect(
      AccountRules.validate(
        account(1, " сбер "), previous: nil, balances: empty, enabled: enabled, others: others)
        == [.nameTaken])
    #expect(
      AccountRules.validate(
        account(1, "Сбербанк"), previous: nil, balances: empty, enabled: enabled, others: others)
        == [.nameTaken])
    #expect(
      AccountRules.validate(
        account(1, "old"), previous: nil, balances: empty, enabled: enabled, others: others)
        == [.nameTaken])
    #expect(
      AccountRules.validate(
        account(1, "Т-Банк"), previous: nil, balances: empty, enabled: enabled, others: others
      )
      .isEmpty)
  }

  /// The words of a clash name the account in the way: «Card» against «Cash», whose other name
  /// is «card», is a clash with «Cash» by its other name; a clash by name wins over one by other
  /// name; the account itself, an empty name and a free one clash with nobody.
  @Test func theRivalIsNamedByItsOtherName() throws {
    let cash = PaymentMethod(id: id(2), name: "Cash", kind: .cash, aliases: ["card"])
    let old = account(3, "Old Visa", archived: true)
    let visa = PaymentMethod(id: id(4), name: "Visa", aliases: ["Old Visa", "Кошелёк"])
    let others = [cash, old, visa]

    let byOtherName = try #require(AccountRules.rival(of: " CARD ", account: id(1), among: others))
    #expect(byOtherName.account.id == cash.id)
    #expect(byOtherName.byOtherName)

    let byName = try #require(AccountRules.rival(of: "old visa", account: id(1), among: others))
    #expect(byName.account.id == old.id, "the name of an archived account is taken by it")
    #expect(!byName.byOtherName, "a clash by name wins over the other name of «Visa»")

    let folded = try #require(AccountRules.rival(of: "кошелек", account: id(1), among: others))
    #expect(folded.account.id == visa.id && folded.byOtherName, "«ё» and «е» are one letter")

    #expect(AccountRules.rival(of: "Cash", account: cash.id, among: others) == nil)
    #expect(AccountRules.rival(of: "card", account: cash.id, among: others) == nil)
    #expect(AccountRules.rival(of: "  ", account: id(1), among: others) == nil)
    #expect(AccountRules.rival(of: "Т-Банк", account: id(1), among: others) == nil)
  }

  /// «Ё» and «е» are one letter to a name, as the entry line reads them: «Ёлка» is the same
  /// account as «Елка», and a name taken by another account's other name stays taken.
  @Test func aNameWrittenWithЁOrЕIsTheSameName() {
    let others = [
      PaymentMethod(id: id(2), name: "Елка"),
      PaymentMethod(id: id(3), name: "Кошелек", aliases: ["зелёная карта"]),
    ]
    let empty = balances(accounts: others)
    let enabled: [CurrencyCode] = [.rub]
    for name in ["Ёлка", "ёлка", " ЁЛКА ", "Кошелёк", "Зеленая карта"] {
      #expect(
        AccountRules.validate(
          account(1, name), previous: nil, balances: empty, enabled: enabled, others: others)
          == [.nameTaken], "\(name)")
    }
    #expect(
      AccountRules.validate(
        account(1, "Ёж"), previous: nil, balances: empty, enabled: enabled, others: others
      )
      .isEmpty)
  }

  @Test func theCurrenciesMustBeOnAndEachListedOnce() {
    let freedom = account(1, "Freedom", currency: .eur, others: [.usd, .eur, kzt])
    let issues = AccountRules.validate(
      freedom, previous: nil, balances: balances(accounts: []), enabled: [.rub, .eur, .usd],
      others: [])
    #expect(issues == [.duplicateCurrency, .currencyNotEnabled(kzt)])
  }

  @Test func aCurrencyWithMoneyStaysOnTheAccount() {
    let before = account(1, "Cash", others: [.usd, .eur])
    let after = account(1, "Cash")
    let known = balances(
      anchored: [
        (BalanceKey(accountId: id(1), currency: .usd), 20),
        (BalanceKey(accountId: id(1), currency: .eur), 0),
      ], accounts: [before])
    #expect(
      AccountRules.validate(
        after, previous: before, balances: known, enabled: [.rub, .usd, .eur], others: [])
        == [.removesCurrencyWithMoney(.usd)])
  }

  @Test func archivingNeedsNoMoneyAnotherMainAndAnotherLiveAccount() {
    let main = account(1, "Main", main: true)
    var archivedMain = main
    archivedMain.archived = true
    let known = balances(
      anchored: [(BalanceKey(accountId: id(1), currency: .rub), 500)], accounts: [main])
    #expect(
      AccountRules.validate(
        archivedMain, previous: main, balances: known, enabled: [.rub], others: [])
        == [.archivesWithMoney, .archivesMain, .archivesLastLiveAccount])

    let empty = balances(accounts: [main])
    let other = account(2, "Other")
    var archivedOther = other
    archivedOther.archived = true
    #expect(
      AccountRules.validate(
        archivedOther, previous: other, balances: empty, enabled: [.rub], others: [main]
      )
      .isEmpty)
  }

  /// A key with movements but never counted: its money is not known, so it is not taken for
  /// zero.
  @Test func moneyNobodyCountedStillCounts() {
    let card = account(1, "Card", others: [.usd])
    let spent = TransactionEntry(
      transaction: Transaction(
        id: id(9), kind: .expense, occurredAt: moment("2026-03-02"), currency: .usd,
        amountE4: money(5), paymentMethodId: id(1)),
      parts: [TransactionPart(transactionId: id(9), amountE4: money(5))])
    #expect(
      AccountRules.validate(
        account(1, "Card"), previous: card, balances: balances([spent], accounts: [card]),
        enabled: [.rub, .usd], others: []) == [.removesCurrencyWithMoney(.usd)])
  }

  @Test func theMainAccountNeverSitsInAGroupOutOfTheSummary() {
    let kazakhstan = AccountGroup(id: id(81), name: "Казахстан", inSummary: false)
    let main = account(1, "Kaspi", main: true, group: kazakhstan.id)
    #expect(
      AccountRules.validate(
        main, previous: nil, balances: balances(accounts: []), enabled: [.rub], others: [],
        groups: [kazakhstan]) == [.mainInExcludedGroup])
    var switched = AccountGroup(id: id(80), name: "Россия")
    let inRussia = account(2, "Сбер", main: true, group: switched.id)
    #expect(AccountRules.validate(group: switched, accounts: [inRussia]).isEmpty)
    switched.inSummary = false
    #expect(AccountRules.validate(group: switched, accounts: [inRussia]) == [.holdsMain])
    #expect(
      AccountRules.validate(group: AccountGroup(name: " "), accounts: []) == [.emptyName])
  }
}
