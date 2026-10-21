import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CorePlanning

/// A small book of accounts built in code.
///
/// Т-Банк (main, rubles) and Cash have no group; Сбер is in «Россия», which counts;
/// Freedom (euros, dollars, tenge) is in «Казахстан», left out of the summary; Old is
/// archived. Everything but Cash was counted at noon on 10 September.
private struct AccountsBook {
  static func id(_ number: Int) -> UUID {
    UUID(uuidString: String(format: "ACC00000-0000-0000-0000-%012d", number))!
  }
  static func day(_ iso: String) -> DateOnly { DateOnly(iso: iso)! }
  static func noon(_ iso: String) -> Date {
    CalendarContext.utc.startOfDay(day(iso)).addingTimeInterval(12 * 3600)
  }
  static func money(_ text: String) -> AmountE4 { amountLiteral(text) }

  static let tenge = CurrencyCode("KZT")
  static let tbank = id(1)
  static let cash = id(2)
  static let sber = id(3)
  static let freedom = id(4)
  static let old = id(5)
  static let russia = id(11)
  static let kazakhstan = id(12)
  static let counted = noon("2026-09-10")
  static let now = noon("2026-09-19")

  var accounts: [PaymentMethod] = [
    PaymentMethod(id: tbank, name: "Т-Банк", currency: .rub, isDefault: true),
    PaymentMethod(id: cash, name: "Cash", kind: .cash, currency: .rub),
    PaymentMethod(id: sber, name: "Сбер", currency: .rub, groupId: russia),
    PaymentMethod(
      id: freedom, name: "Freedom", currency: .eur, groupId: kazakhstan,
      otherCurrencies: [.usd, tenge]),
    PaymentMethod(id: old, name: "Old", currency: .rub, archived: true),
  ]
  var groups: [AccountGroup] = [
    AccountGroup(id: russia, name: "Россия"),
    AccountGroup(id: kazakhstan, name: "Казахстан", inSummary: false),
  ]
  var reconciliations = [
    Reconciliation(
      id: id(21), date: day("2026-09-10"), reconciledAt: counted, actualTotalRubE4: .zero,
      kind: .opening)
  ]
  var counts: [ReconciledBalance] = [
    count(31, tbank, .rub, "100000"),
    count(32, freedom, .eur, "1000"),
    count(33, freedom, .usd, "50"),
    count(34, freedom, tenge, "500000"),
    count(35, sber, .rub, "20000"),
    count(36, old, .rub, "5000"),
  ]
  var entries: [TransactionEntry] = [
    // The main account, named by no account at all.
    expense(41, "2026-09-12", "1500", account: nil),
    expense(42, "2026-09-13", "10000", currency: tenge, rubles: "1900", account: freedom),
    // Dollars paid from the ruble card before accounts had currencies: a key it does not hold.
    expense(43, "2026-08-01", "20", currency: .usd, rubles: "1800", account: tbank),
    // After `now`: waits for its moment.
    expense(44, "2026-09-25", "700", account: tbank),
    expense(45, "2026-09-11", "300", account: cash),
  ]
  var transfers = [
    Transfer(
      id: id(51), occurredAt: noon("2026-09-14"), fromAccountId: tbank, fromCurrency: .rub,
      fromAmountE4: money("10000"), toAccountId: sber, toCurrency: .rub,
      toAmountE4: money("10000"), createdAt: noon("2026-09-14"), updatedAt: noon("2026-09-14"))
  ]
  /// Today: 100 ₽ a euro, 0.2 ₽ a tenge, no rate for dollars.
  var rubPerUnit: [CurrencyCode: Decimal] = [.eur: 100, tenge: Decimal(string: "0.2")!]

  static func count(
    _ number: Int, _ account: UUID, _ currency: CurrencyCode, _ amount: String
  ) -> ReconciledBalance {
    ReconciledBalance(
      id: id(number), reconciliationId: id(21), accountId: account, currency: currency,
      actualE4: money(amount))
  }

  static func expense(
    _ number: Int, _ iso: String, _ amount: String, currency: CurrencyCode = .rub,
    rubles: String? = nil, account: UUID?
  ) -> TransactionEntry {
    let when = noon(iso)
    let transactionId = id(1000 + number)
    return TransactionEntry(
      transaction: Transaction(
        id: transactionId, kind: .expense, occurredAt: when, currency: currency,
        amountE4: money(amount), amountRubE4: money(rubles ?? amount), paymentMethodId: account,
        createdAt: when, updatedAt: when),
      parts: [
        TransactionPart(
          id: id(2000 + number), transactionId: transactionId, quality: .neutral,
          qualitySource: .category, amountE4: money(amount),
          amountRubE4: money(rubles ?? amount))
      ])
  }

  var dataset: Dataset {
    Dataset(
      entries: entries, paymentMethods: accounts,
      planning: PlanningBook(reconciliations: reconciliations, reconciledBalances: counts),
      transfers: transfers, accountGroups: groups)
  }

  func snapshot(
    now: Date = AccountsBook.now, localeIdentifier: String = "en"
  ) -> AccountsSnapshot {
    AccountsSnapshot.build(
      dataset: dataset, now: now, calendar: .utc, rubPerUnit: rubPerUnit,
      localeIdentifier: localeIdentifier)
  }
}

@Suite("Accounts: balances, sections and «Всего» in rubles")
struct AccountsSnapshotTests {
  private typealias B = AccountsBook

  private func key(_ account: UUID, _ currency: CurrencyCode) -> BalanceKey {
    BalanceKey(accountId: account, currency: currency)
  }

  /// Т-Банк 100 000 − 1 500 − 10 000 moved to Сбер = 88 500 (the 700 of the 25th is still
  /// ahead); Сбер 30 000; Freedom 1 000 € = 100 000 ₽ and 490 000 ₸ = 98 000 ₽, its 50 $
  /// without a rate today; Cash never counted. «Всего» adds Т-Банк and Сбер: 118 500. Freedom's
  /// 198 000 stay apart with «Казахстан»; Old, archived, is nowhere.
  @Test func theSectionsTheirTotalsAndAll() throws {
    let snapshot = AccountsBook().snapshot()

    #expect(snapshot.sections.map(\.group?.id) == [nil, B.russia, B.kazakhstan])
    #expect(snapshot.sections.map(\.inSummary) == [true, true, false])
    #expect(
      snapshot.sections.map { $0.accounts.map(\.account.id) }
        == [[B.tbank, B.cash], [B.sber], [B.freedom]])
    #expect(
      snapshot.sections.map(\.totalRub)
        == [B.money("88500"), B.money("30000"), B.money("198000")])
    #expect(snapshot.inSummaryTotalRub == B.money("118500"))
    #expect(snapshot.unanchored == [key(B.cash, .rub)])
    #expect(snapshot.withoutRate == [.usd])
    #expect(snapshot.sections.map(\.withoutRate) == [[], [], [.usd]])
    #expect(snapshot.inSummaryWithoutRate.isEmpty)

    let tbank = try #require(snapshot.line(of: B.tbank))
    #expect(tbank.keys.map(\.key) == [key(B.tbank, .rub), key(B.tbank, .usd)])
    #expect(tbank.keys.map(\.isHeld) == [true, false])
    #expect(tbank.keys.map(\.balance) == [B.money("88500"), nil])
    #expect(tbank.keys.first?.anchorAt == B.counted)
    #expect(tbank.totalRub == B.money("88500"))
    #expect(tbank.unknown == 0)
    #expect(tbank.withoutRate.isEmpty)

    let cash = try #require(snapshot.line(of: B.cash))
    #expect(cash.totalRub == nil)
    #expect(cash.unknown == 1)
    #expect(cash.keys.map(\.balance) == [nil])

    let freedom = try #require(snapshot.line(of: B.freedom))
    #expect(freedom.keys.map(\.key.currency) == [.eur, .usd, B.tenge])
    #expect(freedom.keys.map(\.balance) == [B.money("1000"), B.money("50"), B.money("490000")])
    #expect(freedom.keys.map(\.rub) == [B.money("100000"), nil, B.money("98000")])
    #expect(freedom.totalRub == B.money("198000"))
    #expect(freedom.withoutRate == [.usd])

    #expect(snapshot.line(of: B.old) == nil)
    #expect(snapshot.balances[key(B.old, .rub)]?.amountE4 == B.money("5000"))
    #expect(snapshot.excluded.map(\.group?.id) == [B.kazakhstan])
    #expect(!snapshot.isInSummary(B.freedom))
    #expect(snapshot.isInSummary(B.sber))
    #expect(snapshot.isInSummary(nil))
    #expect(snapshot.isInSummary(B.old))
  }

  /// A counted balance without a rate today is no «0 ₽»: the only account, 50 $ counted and
  /// no dollar rate, has no total in rubles, and neither has its section. «Всего» is there —
  /// something was counted, so it is no «сделайте первую сверку» — but adds nothing it could
  /// not convert and says which currency it left out.
  @Test func aBalanceWithoutARateIsNoZero() throws {
    var book = AccountsBook()
    book.accounts = [
      PaymentMethod(id: B.freedom, name: "Freedom", currency: .usd, isDefault: true)
    ]
    book.groups = []
    book.entries = []
    book.transfers = []
    book.counts = [AccountsBook.count(33, B.freedom, .usd, "50")]
    book.rubPerUnit = [:]
    let snapshot = book.snapshot()

    let freedom = try #require(snapshot.line(of: B.freedom))
    #expect(freedom.keys.map(\.balance) == [B.money("50")])
    #expect(freedom.keys.map(\.rub) == [nil])
    #expect(freedom.totalRub == nil)
    #expect(freedom.withoutRate == [.usd])
    #expect(snapshot.sections.map(\.totalRub) == [nil])
    #expect(snapshot.sections.map(\.withoutRate) == [[.usd]])
    #expect(snapshot.inSummaryTotalRub == .zero)
    #expect(snapshot.inSummaryWithoutRate == [.usd])
    #expect(snapshot.withoutRate == [.usd])
    #expect(snapshot.unanchored.isEmpty)
  }

  /// An archived account keeps the group it was in: one that sat in «Казахстан», left out of
  /// the summary, is still left out, so a payment still pointing at it is not taken from the
  /// money in the summary. An archived group is no group, as in the sidebar.
  @Test func anArchivedAccountKeepsItsGroup() {
    var book = AccountsBook()
    let oldKaspi = B.id(6)
    let oldStash = B.id(7)
    let closed = B.id(13)
    book.accounts += [
      PaymentMethod(
        id: oldKaspi, name: "Kaspi", currency: B.tenge, archived: true, groupId: B.kazakhstan),
      PaymentMethod(id: oldStash, name: "Stash", currency: .rub, archived: true, groupId: closed),
    ]
    book.groups.append(AccountGroup(id: closed, name: "Closed", inSummary: false, archived: true))
    let snapshot = book.snapshot()

    #expect(snapshot.line(of: oldKaspi) == nil)
    #expect(!snapshot.isInSummary(oldKaspi))
    #expect(snapshot.isInSummary(oldStash))
    #expect(snapshot.isInSummary(B.old))
    #expect(snapshot.isInSummary(B.id(99)))
    #expect(!snapshot.isInSummary(B.freedom))
  }

  /// Nothing counted yet — or only the one total of rubles counts were before accounts: no
  /// «Всего», every currency waits for its first count.
  @Test func withoutACountThereIsNoTotal() {
    var book = AccountsBook()
    book.counts = []
    #expect(book.snapshot().inSummaryTotalRub == nil)
    #expect(book.snapshot().sections.allSatisfy { $0.totalRub == nil })
    #expect(
      book.snapshot().unanchored
        == [
          key(B.tbank, .rub), key(B.cash, .rub), key(B.sber, .rub), key(B.freedom, .eur),
          key(B.freedom, .usd), key(B.freedom, B.tenge),
        ])

    var legacy = AccountsBook()
    legacy.reconciliations = [
      Reconciliation(
        id: B.id(21), date: B.day("2026-09-10"), reconciledAt: B.counted,
        actualTotalRubE4: B.money("125000"), kind: .total)
    ]
    #expect(legacy.snapshot().inSummaryTotalRub == nil)
  }

  /// Right after the count «Всего» is the counted total at today's rates, and a rate that
  /// moves changes the rubles, never the money on the account.
  @Test func rightAfterACountTheTotalIsTheCount() throws {
    var book = AccountsBook()
    book.groups = []
    book.accounts = book.accounts.map { account in
      var account = account
      account.groupId = nil
      return account
    }
    book.entries = []
    book.transfers = []
    book.rubPerUnit[.usd] = 90
    let counted = book.snapshot(now: B.counted)
    // 100 000 + 1 000 € × 100 + 50 $ × 90 + 500 000 ₸ × 0.2 + 20 000; Old is archived.
    #expect(counted.inSummaryTotalRub == B.money("324500"))

    book.rubPerUnit[.eur] = 110
    let moved = book.snapshot(now: B.counted)
    let euros = try #require(moved.line(of: B.freedom)?.keys.first)
    #expect(euros.balance == B.money("1000"))
    #expect(euros.rub == B.money("110000"))
    #expect(moved.inSummaryTotalRub == B.money("334500"))
  }

  /// Money spent from a group left out of the summary moves that group's total, not «Всего».
  /// So does an exchange inside it: 100 € sold for 45 000 ₸ leave 900 € = 90 000 ₽ and
  /// 535 000 ₸ = 107 000 ₽ on Freedom, 197 000 ₽ in all, and «Всего» stays 118 500.
  @Test func aGroupLeftOutKeepsItsMoneyApart() {
    let before = AccountsBook().snapshot()
    var book = AccountsBook()
    book.entries.append(
      AccountsBook.expense(
        46, "2026-09-15", "50000", currency: B.tenge, rubles: "9500", account: B.freedom))
    let after = book.snapshot()
    #expect(after.inSummaryTotalRub == before.inSummaryTotalRub)
    #expect(after.excluded.first?.totalRub == B.money("188000"))

    var exchange = AccountsBook()
    exchange.transfers.append(
      Transfer(
        id: B.id(52), occurredAt: B.noon("2026-09-16"), fromAccountId: B.freedom,
        fromCurrency: .eur, fromAmountE4: B.money("100"), toAccountId: B.freedom,
        toCurrency: B.tenge, toAmountE4: B.money("45000"), createdAt: B.noon("2026-09-16"),
        updatedAt: B.noon("2026-09-16")))
    let exchanged = exchange.snapshot()
    #expect(exchanged.inSummaryTotalRub == B.money("118500"))
    #expect(
      exchanged.line(of: B.freedom)?.keys.map(\.balance)
        == [B.money("900"), B.money("50"), B.money("535000")])
    #expect(exchanged.excluded.first?.totalRub == B.money("197000"))
  }

  /// The names are ordered the way the interface language orders them: in Russian the
  /// Cyrillic names come first, in English the Latin ones.
  @Test func theOrderFollowsTheLanguage() {
    var book = AccountsBook()
    book.accounts = [
      PaymentMethod(id: B.tbank, name: "Основной", currency: .rub, isDefault: true),
      PaymentMethod(id: B.cash, name: "Kaspi", currency: .rub),
      PaymentMethod(id: B.sber, name: "Альфа", currency: .rub),
    ]
    book.groups = []
    let russian = book.snapshot(localeIdentifier: "ru").sections.first?.accounts
    #expect(russian?.map(\.account.id) == [B.tbank, B.sber, B.cash])
    let english = book.snapshot(localeIdentifier: "en").sections.first?.accounts
    #expect(english?.map(\.account.id) == [B.tbank, B.cash, B.sber])
  }

  /// The language switched while the snapshot stays: ordered again for the new language, the
  /// snapshot is the one built in it — sections, accounts and the keys never counted alike —
  /// so the sidebar and the menus show one order.
  @Test func aSnapshotIsOrderedAgainForAnotherLanguage() {
    var book = AccountsBook()
    book.accounts += [
      PaymentMethod(id: B.id(6), name: "Kaspi", currency: .rub),
      PaymentMethod(id: B.id(7), name: "Альфа", currency: .rub),
      PaymentMethod(id: B.id(8), name: "Zeta", currency: .rub, groupId: B.russia),
    ]
    book.groups.append(AccountGroup(id: B.id(13), name: "Armenia"))
    let russian = Locale(identifier: "ru")
    let english = Locale(identifier: "en")
    let builtInEnglish = book.snapshot(localeIdentifier: "en")
    let builtInRussian = book.snapshot(localeIdentifier: "ru")
    #expect(builtInEnglish != builtInRussian)
    #expect(builtInEnglish.ordered(locale: russian) == builtInRussian)
    #expect(builtInRussian.ordered(locale: english) == builtInEnglish)
    #expect(AccountsSnapshot.empty.ordered(locale: russian) == .empty)
  }

  /// The planning snapshot carries the same accounts, as of its own moment.
  @Test func thePlanningSnapshotCarriesTheAccounts() {
    let book = AccountsBook()
    let ledger = Ledger(dataset: book.dataset, calendar: .utc)
    let planning = PlanningSnapshot.build(
      ledger: ledger, today: B.day("2026-09-19"), now: B.now, rubPerUnit: book.rubPerUnit,
      localeIdentifier: "ru")
    #expect(planning.accounts == book.snapshot(localeIdentifier: "ru"))
    #expect(planning.accounts.inSummaryTotalRub == B.money("118500"))
    #expect(PlanningSnapshot.empty.accounts == .empty)
  }

  /// A credit card holds what is owed to the bank as a balance below zero, and it counts as
  /// such: counted at −30,000 beside Сбер at 100,000, «Всего» and what can be spent now are
  /// 70,000; a purchase of 2,000 on the card takes the card to −32,000 and both to 68,000. The
  /// sign is in the figure, never in a colour.
  @Test func aNegativeBalanceCountsNegativeInAllAndTheFreeSum() throws {
    var book = AccountsBook()
    book.accounts = [
      PaymentMethod(id: B.tbank, name: "Credit", currency: .rub, isDefault: true),
      PaymentMethod(id: B.sber, name: "Сбер", currency: .rub),
    ]
    book.groups = []
    book.counts = [
      AccountsBook.count(31, B.tbank, .rub, "-30000"),
      AccountsBook.count(35, B.sber, .rub, "100000"),
    ]
    book.entries = []
    book.transfers = []
    func free(_ snapshot: AccountsSnapshot) -> AmountE4? {
      FreeMoney(
        accounts: snapshot, plan: CashPlan(), stillExpected: .zero, today: B.day("2026-09-19"),
        until: B.day("2026-09-30")
      ).main
    }

    let counted = book.snapshot()
    #expect(counted.line(of: B.tbank)?.keys.first?.balance == B.money("-30000"))
    #expect(counted.inSummaryTotalRub == B.money("70000"))
    #expect(free(counted) == B.money("70000"))

    book.entries = [AccountsBook.expense(41, "2026-09-12", "2000", account: B.tbank)]
    let spent = book.snapshot()
    #expect(spent.line(of: B.tbank)?.keys.first?.balance == B.money("-32000"))
    #expect(spent.line(of: B.tbank)?.totalRub == B.money("-32000"))
    #expect(spent.inSummaryTotalRub == B.money("68000"))
    #expect(free(spent) == B.money("68000"))
  }
}
