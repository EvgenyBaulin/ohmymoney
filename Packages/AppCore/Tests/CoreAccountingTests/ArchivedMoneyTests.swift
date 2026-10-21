import CoreKit
import Foundation
import Testing

@testable import CoreAccounting

/// An account in the archive stays at zero: what an edit, a deletion or the archive itself
/// would leave on it is moved to a live account by a transfer.
@Suite("Money left on an archived account")
struct ArchivedMoneyTests {
  let categories = StartingCategories()
  let sber = PaymentMethod(
    id: id(2), name: "Sber", currency: .rub, isDefault: true, otherCurrencies: [.usd])
  let wallet = PaymentMethod(id: id(3), name: "Wallet", currency: .rub)
  var cash: PaymentMethod {
    PaymentMethod(
      id: id(1), name: "Cash", currency: .rub, archived: true, otherCurrencies: [.usd])
  }
  var cashRub: BalanceKey { BalanceKey(accountId: id(1), currency: .rub) }
  var cashUsd: BalanceKey { BalanceKey(accountId: id(1), currency: .usd) }
  var sberRub: BalanceKey { BalanceKey(accountId: id(2), currency: .rub) }

  /// 26.09 at `hour` UTC.
  func at(_ hour: Double) -> Date { moment("2026-09-26").addingTimeInterval(hour * 3600) }

  func purchase(_ number: Int, _ amount: Int, on account: UUID, at moment: Date) -> TransactionEntry
  {
    TransactionEntry(
      transaction: Transaction(
        id: id(number), kind: .expense, occurredAt: moment, currency: .rub,
        amountE4: money(amount), paymentMethodId: account),
      parts: [TransactionPart(transactionId: id(number), amountE4: money(amount))])
  }

  func balances(
    entries: [TransactionEntry] = [], transfers: [Transfer] = [],
    counted: [(BalanceKey, Int)] = [(BalanceKey(accountId: id(1), currency: .rub), 5_000)],
    now: Date? = nil
  ) -> AccountBalances {
    let count = Reconciliation(
      id: id(90), date: day("2026-09-26"), reconciledAt: at(6), actualTotalRubE4: .zero,
      kind: .accounts)
    return AccountBalances.build(
      entries: entries, transfers: transfers, debtEntries: [], debts: [:],
      reconciliations: [count],
      balances: counted.enumerated().map { index, row in
        ReconciledBalance(
          id: id(900 + index), reconciliationId: count.id, accountId: row.0.accountId,
          currency: row.0.currency, actualE4: money(row.1))
      },
      accounts: [sber, wallet, cash], tree: categories.tree, now: now ?? at(12),
      calendar: .utc)
  }

  func movement(_ entry: TransactionEntry) -> [AccountMovement] {
    AccountBalances.movement(of: entry, mainId: sber.id, tree: categories.tree).map { [$0] } ?? []
  }

  /// «Наличные» counted 5,000 at 06:00, a purchase of 5,000 at 07:00, archived at 0.
  /// The purchase edited to 4,000 would leave 1,000 on it.
  @Test func anEditLeavingMoneyAsksForACounterpart() {
    let old = purchase(10, 5_000, on: cash.id, at: at(7))
    var new = old
    new.transaction.amountE4 = money(4_000)
    new.parts[0].amountE4 = money(4_000)
    let books = balances(entries: [old])
    #expect(books[cashRub]?.amountE4 == .zero)
    let check = ArchivedMoney.leftovers(
      removing: movement(old), adding: movement(new), balances: books,
      accounts: [sber, wallet, cash])
    #expect(check.unknown.isEmpty)
    #expect(
      check.leftovers == [
        ArchivedLeftover(key: cashRub, amount: money(1_000), latest: at(7), settleAfter: at(7))
      ])
  }

  /// A transfer «Сбер → Наличные» of 1,000 after the count, deleted: «Наличные» would fall to
  /// −1,000, so 1,000 is brought in from a live account.
  @Test func deletingATransferIntoAnArchivedAccountTakesItBelowZero() {
    let transfer = Transfer(
      id: id(20), occurredAt: at(8), fromAccountId: sber.id, fromCurrency: .rub,
      fromAmountE4: money(1_000), toAccountId: cash.id, toCurrency: .rub,
      toAmountE4: money(1_000))
    let books = balances(transfers: [transfer], counted: [(cashRub, 0), (sberRub, 10_000)])
    let check = ArchivedMoney.leftovers(
      removing: ArchivedMoney.movements(of: transfer), adding: [], balances: books,
      accounts: [sber, wallet, cash])
    #expect(check.leftovers.map(\.key) == [cashRub])
    #expect(check.leftovers.first?.amount == money(-1_000))
    let settling = ArchivedMoney.settlingTransfer(
      check.leftovers[0], counterpart: sber.id, counterpartCountedAt: nil, now: at(12), note: "n",
      id: id(30))
    #expect(settling.fromAccountId == sber.id && settling.toAccountId == cash.id)
    #expect(settling.fromAmountE4 == money(1_000) && settling.toAmountE4 == money(1_000))
    // Nothing moves on the key after the deletion: the transfer follows its count.
    #expect(settling.occurredAt == at(6).addingTimeInterval(1))
  }

  /// A change dated before the archived account's latest count changes that count's
  /// difference, not its balance: nothing is left on it.
  @Test func aChangeInsideACountWindowLeavesNothing() {
    let old = purchase(10, 500, on: cash.id, at: at(5))
    var new = old
    new.transaction.amountE4 = money(300)
    new.parts[0].amountE4 = money(300)
    let check = ArchivedMoney.leftovers(
      removing: movement(old), adding: movement(new), balances: balances(entries: [old]),
      accounts: [sber, wallet, cash])
    #expect(check.leftovers.isEmpty)
    #expect(check.unknown.isEmpty)
    // And a comment changes nothing at all.
    var noted = old
    noted.transaction.note = "lunch"
    #expect(
      ArchivedMoney.leftovers(
        removing: movement(old), adding: movement(noted), balances: balances(entries: [old]),
        accounts: [sber, wallet, cash]
      ).leftovers.isEmpty)
  }

  /// The transfer written with the change brings the key back to zero, and the live account
  /// gets the money.
  @Test func theSettlingTransferBringsTheKeyBackToZero() {
    let old = purchase(10, 5_000, on: cash.id, at: at(7))
    var new = old
    new.transaction.amountE4 = money(4_000)
    new.parts[0].amountE4 = money(4_000)
    let books = balances(entries: [old], counted: [(cashRub, 5_000), (sberRub, 10_000)])
    let check = ArchivedMoney.leftovers(
      removing: movement(old), adding: movement(new), balances: books,
      accounts: [sber, wallet, cash])
    let settling = ArchivedMoney.settlingTransfer(
      check.leftovers[0], counterpart: sber.id, counterpartCountedAt: nil, now: at(12), note: nil,
      id: id(30))
    let after = balances(
      entries: [new], transfers: [settling], counted: [(cashRub, 5_000), (sberRub, 10_000)],
      now: at(13))
    #expect(after[cashRub]?.amountE4 == .zero)
    #expect(after[sberRub]?.amountE4 == money(11_000))
  }

  /// A change dated after now: the transfer is dated no earlier than the change, or the money
  /// would sit on the archived account from then on.
  @Test func aFutureChangeDatesItsTransferAfterIt() {
    let future = purchase(10, 700, on: cash.id, at: at(30))
    var cheaper = future
    cheaper.transaction.amountE4 = money(500)
    cheaper.parts[0].amountE4 = money(500)
    let check = ArchivedMoney.leftovers(
      removing: movement(future), adding: movement(cheaper),
      balances: balances(entries: [future]), accounts: [sber, wallet, cash])
    let settling = ArchivedMoney.settlingTransfer(
      check.leftovers[0], counterpart: sber.id, counterpartCountedAt: nil, now: at(12), note: nil,
      id: id(30))
    #expect(settling.occurredAt == at(30).addingTimeInterval(1))
  }

  // MARK: - The day of the transfer that settles a change

  /// «Наличные», archived at zero: counted 5,000 at 06:00, a purchase of 5,000 at 07:00, a
  /// purchase of 1,000 at 08:00 settled by 1,000 from «Сбер» at 08:00. Now is days later
  /// unless said.
  func archivedAtZero(
    now: Date = moment("2026-10-05")
  ) -> (
    books: AccountBalances, first: TransactionEntry, second: TransactionEntry, settled: Transfer
  ) {
    let first = purchase(10, 5_000, on: cash.id, at: at(7))
    let second = purchase(11, 1_000, on: cash.id, at: at(8))
    let settled = Transfer(
      id: id(21), occurredAt: at(8), fromAccountId: sber.id, fromCurrency: .rub,
      fromAmountE4: money(1_000), toAccountId: cash.id, toCurrency: .rub,
      toAmountE4: money(1_000))
    let books = balances(
      entries: [first, second], transfers: [settled],
      counted: [(cashRub, 5_000), (sberRub, 10_000)], now: now)
    return (books, first, second, settled)
  }

  /// An edit of a past purchase on the archived account: the transfer that takes the money it
  /// leaves goes a second after the last movement the key keeps — not now, days later, or the
  /// money would sit on the archived account, in no total, all that time.
  @Test func anEditInThePastSettlesASecondAfterTheLastMovement() {
    let (books, first, second, settled) = archivedAtZero()
    #expect(books[cashRub]?.amountE4 == .zero)
    var cheaper = first
    cheaper.transaction.amountE4 = money(4_000)
    cheaper.parts[0].amountE4 = money(4_000)
    let check = ArchivedMoney.leftovers(
      removing: movement(first), adding: movement(cheaper), balances: books,
      accounts: [sber, wallet, cash])
    #expect(check.leftovers.map(\.amount) == [money(1_000)])
    #expect(check.leftovers.map(\.settleAfter) == [at(8)])
    let settling = ArchivedMoney.settlingTransfer(
      check.leftovers[0], counterpart: sber.id, counterpartCountedAt: nil, now: books.now,
      note: nil, id: id(30))
    #expect(settling.occurredAt == at(8).addingTimeInterval(1))
    #expect(settling.fromAccountId == cash.id && settling.toAccountId == sber.id)
    #expect(settling.createdAt == books.now)
    // The key is at zero from right after its last movement on, not only from now.
    let after = balances(
      entries: [cheaper, second], transfers: [settled, settling],
      counted: [(cashRub, 5_000), (sberRub, 10_000)], now: books.now)
    #expect(after.balance(cashRub, at: at(9)) == .zero)
    #expect(after[cashRub]?.amountE4 == .zero)
    #expect(after[sberRub]?.amountE4 == money(10_000))
  }

  /// The edit moves the purchase to a later moment than every other movement of the key: the
  /// transfer goes a second after the purchase's new moment.
  @Test func anEditMovedLaterSettlesAfterItsNewMoment() {
    let (books, first, _, _) = archivedAtZero()
    var moved = first
    moved.transaction.occurredAt = at(10)
    moved.transaction.amountE4 = money(4_000)
    moved.parts[0].amountE4 = money(4_000)
    let check = ArchivedMoney.leftovers(
      removing: movement(first), adding: movement(moved), balances: books,
      accounts: [sber, wallet, cash])
    #expect(check.leftovers.map(\.settleAfter) == [at(10)])
    let settling = ArchivedMoney.settlingTransfer(
      check.leftovers[0], counterpart: sber.id, counterpartCountedAt: nil, now: books.now,
      note: nil, id: id(30))
    #expect(settling.occurredAt == at(10).addingTimeInterval(1))
  }

  /// Deleting a movement of the key: the transfer goes a second after the latest movement that
  /// stays — the deleted one is not there any more.
  @Test func deletingTheLatestMovementSettlesAfterTheOneBefore() {
    let (books, first, second, settled) = archivedAtZero()
    let both = ArchivedMoney.leftovers(
      removing: movement(second) + ArchivedMoney.movements(of: settled), adding: [],
      balances: books, accounts: [sber, wallet, cash])
    #expect(both.leftovers.isEmpty, "the purchase and its transfer cancel out")

    let alone = ArchivedMoney.leftovers(
      removing: movement(second), adding: [], balances: books, accounts: [sber, wallet, cash])
    #expect(alone.leftovers.map(\.amount) == [money(1_000)])
    #expect(alone.leftovers.map(\.settleAfter) == [at(8)], "the transfer of 08:00 is still there")

    // The latest two gone, and the first edited: the purchase of 07:00 is the last.
    var cheaper = first
    cheaper.transaction.amountE4 = money(4_000)
    cheaper.parts[0].amountE4 = money(4_000)
    let earlier = ArchivedMoney.leftovers(
      removing: movement(first) + movement(second) + ArchivedMoney.movements(of: settled),
      adding: movement(cheaper), balances: books, accounts: [sber, wallet, cash])
    #expect(earlier.leftovers.map(\.amount) == [money(1_000)])
    #expect(earlier.leftovers.map(\.settleAfter) == [at(7)])
    let settling = ArchivedMoney.settlingTransfer(
      earlier.leftovers[0], counterpart: sber.id, counterpartCountedAt: nil, now: books.now,
      note: nil, id: id(30))
    #expect(settling.occurredAt == at(7).addingTimeInterval(1))
  }

  /// The same movement twice in the books — two equal lines — and one of them taken away: the
  /// other is still there.
  @Test func aMovementTakenAwayOnceLeavesItsTwin() {
    let late = purchase(12, 300, on: cash.id, at: at(9))
    let books = balances(entries: [late, late], counted: [(cashRub, 600)], now: at(20))
    #expect(books.latestMovement(of: cashRub, removing: movement(late)) == at(9))
    #expect(books.latestMovement(of: cashRub, removing: movement(late) + movement(late)) == nil)
    #expect(books.latestMovement(of: cashRub, removing: []) == at(9))
  }

  /// With nothing left on the key after its count, the transfer follows the count: before it,
  /// it would change the count's difference and leave the money where it is.
  @Test func withNothingAfterTheCountTheTransferFollowsTheCount() {
    let (books, first, second, settled) = archivedAtZero()
    let check = ArchivedMoney.leftovers(
      removing: movement(first) + movement(second) + ArchivedMoney.movements(of: settled),
      adding: [], balances: books, accounts: [sber, wallet, cash])
    #expect(check.leftovers.map(\.amount) == [money(5_000)])
    #expect(check.leftovers.map(\.settleAfter) == [at(6)])
  }

  /// «Сбер», the live account the money goes to, was counted again at 10:00, after the last
  /// movement of «Наличные» (08:00). A transfer at 08:00:01 would land inside the window of that
  /// count and make up a «Сверка» difference there: it goes a second after the count instead.
  /// To «Кошелёк», never counted, it goes a second after the last movement, as before.
  @Test func aLaterCountOfTheCounterpartDatesTheTransferAfterIt() {
    let first = purchase(10, 5_000, on: cash.id, at: at(7))
    let second = purchase(11, 1_000, on: cash.id, at: at(8))
    let settled = Transfer(
      id: id(21), occurredAt: at(8), fromAccountId: sber.id, fromCurrency: .rub,
      fromAmountE4: money(1_000), toAccountId: cash.id, toCurrency: .rub,
      toAmountE4: money(1_000))
    let early = Reconciliation(
      id: id(90), date: day("2026-09-26"), reconciledAt: at(6), actualTotalRubE4: .zero,
      kind: .accounts)
    let late = Reconciliation(
      id: id(91), date: day("2026-09-26"), reconciledAt: at(10), actualTotalRubE4: .zero,
      kind: .accounts)
    let books = AccountBalances.build(
      entries: [first, second], transfers: [settled], debtEntries: [], debts: [:],
      reconciliations: [early, late],
      balances: [
        ReconciledBalance(
          id: id(900), reconciliationId: early.id, accountId: cash.id, currency: .rub,
          actualE4: money(5_000)),
        ReconciledBalance(
          id: id(901), reconciliationId: early.id, accountId: sber.id, currency: .rub,
          actualE4: money(10_000)),
        ReconciledBalance(
          id: id(902), reconciliationId: late.id, accountId: sber.id, currency: .rub,
          actualE4: money(9_000)),
      ],
      accounts: [sber, wallet, cash], tree: categories.tree, now: moment("2026-10-05"),
      calendar: .utc)
    var cheaper = first
    cheaper.transaction.amountE4 = money(4_000)
    cheaper.parts[0].amountE4 = money(4_000)
    let check = ArchivedMoney.leftovers(
      removing: movement(first), adding: movement(cheaper), balances: books,
      accounts: [sber, wallet, cash])
    #expect(check.leftovers.map(\.settleAfter) == [at(8)])
    let leftover = check.leftovers[0]

    let counted = ArchivedMoney.counterpartCount(sber.id, for: leftover.key, balances: books)
    #expect(counted == at(10))
    let toSber = ArchivedMoney.settlingTransfer(
      leftover, counterpart: sber.id, counterpartCountedAt: counted, now: books.now, note: nil,
      id: id(30))
    #expect(toSber.occurredAt == at(10).addingTimeInterval(1))
    #expect(
      ArchivedMoney.settlingTransfers(
        leftover, counterpart: sber.id, counterpartCountedAt: counted, now: books.now, note: nil
      ).map(\.occurredAt) == [at(10).addingTimeInterval(1)])
    // The count of «Сбер» keeps what it found: the transfer is after it.
    let after = AccountBalances.build(
      entries: [cheaper, second], transfers: [settled, toSber], debtEntries: [], debts: [:],
      reconciliations: [early, late],
      balances: [
        ReconciledBalance(
          id: id(900), reconciliationId: early.id, accountId: cash.id, currency: .rub,
          actualE4: money(5_000)),
        ReconciledBalance(
          id: id(901), reconciliationId: early.id, accountId: sber.id, currency: .rub,
          actualE4: money(10_000)),
        ReconciledBalance(
          id: id(902), reconciliationId: late.id, accountId: sber.id, currency: .rub,
          actualE4: money(9_000)),
      ],
      accounts: [sber, wallet, cash], tree: categories.tree, now: moment("2026-10-05"),
      calendar: .utc)
    #expect(after.expected(forCount: id(902)) == books.expected(forCount: id(902)))
    #expect(after[cashRub]?.amountE4 == .zero)

    let walletCount = ArchivedMoney.counterpartCount(wallet.id, for: leftover.key, balances: books)
    #expect(walletCount == nil)
    let toWallet = ArchivedMoney.settlingTransfer(
      leftover, counterpart: wallet.id, counterpartCountedAt: walletCount, now: books.now,
      note: nil, id: id(31))
    #expect(toWallet.occurredAt == at(8).addingTimeInterval(1))
  }

  /// A line of a debt journal known only by its day — 27 September — is as late as the end of
  /// that day: the transfer goes at the start of the next one, never in the middle of a day the
  /// line may have moved money later in.
  @Test func aMovementKnownByItsDayCountsAsTheEndOfIt() {
    let (books, _, _, _) = archivedAtZero()
    let lineDay = day("2026-09-27")
    let line = AccountMovement(
      key: cashRub, at: CalendarContext.utc.startOfDay(lineDay), amountE4: money(700),
      source: .journal(id(40)), timing: .day(lineDay))
    let check = ArchivedMoney.leftovers(
      removing: [], adding: [line], balances: books, accounts: [sber, wallet, cash])
    #expect(check.leftovers.map(\.amount) == [money(700)])
    let nextDay = CalendarContext.utc.startOfDay(day("2026-09-28"))
    #expect(check.leftovers.map(\.settleAfter) == [nextDay.addingTimeInterval(-1)])
    let settling = ArchivedMoney.settlingTransfer(
      check.leftovers[0], counterpart: wallet.id, counterpartCountedAt: nil, now: books.now,
      note: nil, id: id(30))
    #expect(settling.occurredAt == nextDay)
  }

  /// Money typed ahead on the archived key: a change ahead is settled a second after the last
  /// movement, ahead of now, as before.
  @Test func aMovementTypedAheadSettlesAfterIt() {
    let rent = purchase(13, 30_000, on: cash.id, at: at(84))
    let back = Transfer(
      id: id(22), occurredAt: at(84), fromAccountId: sber.id, fromCurrency: .rub,
      fromAmountE4: money(30_000), toAccountId: cash.id, toCurrency: .rub,
      toAmountE4: money(30_000))
    let books = balances(
      entries: [rent], transfers: [back], counted: [(cashRub, 0), (sberRub, 50_000)],
      now: at(12))
    var cheaper = rent
    cheaper.transaction.amountE4 = money(25_000)
    cheaper.parts[0].amountE4 = money(25_000)
    let check = ArchivedMoney.leftovers(
      removing: movement(rent), adding: movement(cheaper), balances: books,
      accounts: [sber, wallet, cash])
    #expect(check.leftovers.map(\.amount) == [money(5_000)])
    let settling = ArchivedMoney.settlingTransfer(
      check.leftovers[0], counterpart: sber.id, counterpartCountedAt: nil, now: at(12), note: nil,
      id: id(30))
    #expect(settling.occurredAt == at(84).addingTimeInterval(1))
    #expect(
      ArchivedMoney.legs(of: [settling], archived: cash.id, now: at(12)).map(\.when) == [.later])
    let after = balances(
      entries: [cheaper], transfers: [back, settling],
      counted: [(cashRub, 0), (sberRub, 50_000)], now: at(96))
    #expect(after[cashRub]?.amountE4 == .zero)
    #expect(after[sberRub]?.amountE4 == money(25_000))
  }

  /// The last movement a hair before now: the transfer is dated now at the latest — still after
  /// it —, so the question tells it as a transfer of now, not as money typed ahead.
  @Test func aLastMovementJustBeforeNowSettlesNow() {
    let now = at(12)
    let leftover = ArchivedLeftover(
      key: cashRub, amount: money(100), latest: now.addingTimeInterval(-0.4),
      settleAfter: now.addingTimeInterval(-0.4))
    let settling = ArchivedMoney.settlingTransfer(
      leftover, counterpart: sber.id, counterpartCountedAt: nil, now: now, note: nil, id: id(30))
    #expect(settling.occurredAt == now)
    #expect(ArchivedMoney.legs(of: [settling], archived: cash.id, now: now).map(\.when) == [.now])
  }

  /// A transfer dated in the past is told as such, with its moment, not as one of now.
  @Test func aTransferInThePastIsAnEarlierLeg() {
    let (books, first, _, _) = archivedAtZero()
    var cheaper = first
    cheaper.transaction.amountE4 = money(4_000)
    cheaper.parts[0].amountE4 = money(4_000)
    let check = ArchivedMoney.leftovers(
      removing: movement(first), adding: movement(cheaper), balances: books,
      accounts: [sber, wallet, cash])
    let transfers = ArchivedMoney.settlingTransfers(
      check.leftovers[0], counterpart: sber.id, counterpartCountedAt: nil, now: books.now, note: nil
    )
    #expect(transfers.map(\.occurredAt) == [at(8).addingTimeInterval(1)])
    let legs = ArchivedMoney.legs(of: transfers, archived: cash.id, now: books.now)
    #expect(legs.map(\.when) == [.earlier])
    #expect(legs.map(\.at) == [at(8).addingTimeInterval(1)])
  }

  /// Archiving an account with money is not a change of its past: what it holds now still goes
  /// now, and what is typed ahead with its latest movement.
  @Test func archivingIsStillSettledNowAndLater() {
    var live = cash
    live.archived = false
    let plain = balances(counted: [(cashRub, 1_000)])
    let check = ArchivedMoney.balancesToMove(of: live, balances: plain)
    #expect(check.leftovers.map(\.settleAfter) == [nil])
    #expect(
      ArchivedMoney.settlingTransfers(
        check.leftovers[0], counterpart: sber.id, counterpartCountedAt: nil, now: at(12), note: nil
      ).map(\.occurredAt) == [at(12)])
    let (books, _, _, _) = archivedAtZero(now: at(12))
    #expect(ArchivedMoney.balancesToMove(of: live, balances: books).leftovers.isEmpty)
  }

  /// Only live accounts that hold the currency take the money, in the order of every menu:
  /// the main account first.
  @Test func counterpartsHoldTheCurrency() {
    let accounts = [wallet, cash, sber]
    let rub = ArchivedMoney.counterparts(
      for: cashRub, accounts: accounts, locale: Locale(identifier: "en"))
    #expect(rub.map(\.id) == [sber.id, wallet.id])
    let usd = ArchivedMoney.counterparts(
      for: cashUsd, accounts: accounts, locale: Locale(identifier: "en"))
    #expect(usd.map(\.id) == [sber.id])
    let kzt = BalanceKey(accountId: cash.id, currency: CurrencyCode("KZT"))
    #expect(
      ArchivedMoney.counterparts(for: kzt, accounts: accounts, locale: Locale(identifier: "en"))
        .isEmpty)
  }

  /// «В архив» on an account with 3,000 ₽ and 50 $: both are moved; a credit card at −30,000
  /// is covered from a live account.
  @Test func archivingMovesEveryCountedCurrency() {
    var live = cash
    live.archived = false
    let books = balances(counted: [(cashRub, 3_000), (cashUsd, 50)])
    let result = ArchivedMoney.balancesToMove(of: live, balances: books)
    #expect(result.unknown.isEmpty)
    #expect(result.leftovers.map(\.key) == [cashRub, cashUsd].sorted())
    #expect(Set(result.leftovers.map(\.amount)) == [money(3_000), money(50)])

    let credit = balances(counted: [(cashRub, -30_000)])
    let owed = ArchivedMoney.balancesToMove(of: live, balances: credit)
    #expect(owed.leftovers.map(\.amount) == [money(-30_000)])
    let settling = ArchivedMoney.settlingTransfer(
      owed.leftovers[0], counterpart: sber.id, counterpartCountedAt: nil, now: at(12), note: nil,
      id: id(31))
    #expect(settling.fromAccountId == sber.id && settling.toAccountId == cash.id)
    #expect(settling.fromAmountE4 == money(30_000))
  }

  /// «Наличные» holds 12,000 now, and rent of 30,000 is typed ahead, three days on. Archived
  /// today with only the 12,000 moved, it would fall to −30,000 once the rent is paid and leave
  /// «Всего» 30,000 too high; with one transfer of −18,000 dated with the rent, its 12,000 would
  /// sit on the archive, in no total, until then. So it is settled in two legs: the 12,000 it
  /// holds now go to «Сбер» now, and the 30,000 of the rent come back from «Сбер» with the rent.
  /// A key at zero now with the rent ahead holds money too, and so does one whose money now the
  /// rent takes back to zero.
  @Test func archivingCountsMoneyTypedAhead() {
    var live = cash
    live.archived = false
    let rent = purchase(10, 30_000, on: cash.id, at: at(84))
    let books = balances(entries: [rent], counted: [(cashRub, 12_000), (sberRub, 50_000)])
    #expect(books[cashRub]?.amountE4 == money(12_000), "the balance now leaves the rent out")
    let check = ArchivedMoney.balancesToMove(of: live, balances: books)
    #expect(check.unknown.isEmpty)
    #expect(
      check.leftovers == [
        ArchivedLeftover(
          key: cashRub, amount: money(-18_000), latest: at(84), heldNow: money(12_000))
      ])
    #expect(check.leftovers[0].shownAmount == money(12_000), "the question names the money now")
    var next = 30
    let settling = ArchivedMoney.settlingTransfers(
      check.leftovers[0], counterpart: sber.id, counterpartCountedAt: nil, now: at(12), note: nil,
      ids: {
        next += 1
        return id(next)
      })
    #expect(settling.map(\.occurredAt) == [at(12), at(84)])
    #expect(settling[0].fromAccountId == cash.id && settling[0].toAccountId == sber.id)
    #expect(settling[0].fromAmountE4 == money(12_000))
    #expect(settling[1].fromAccountId == sber.id && settling[1].toAccountId == cash.id)
    #expect(settling[1].toAmountE4 == money(30_000))
    #expect(Set(settling.map(\.id)).count == 2)
    let after = balances(
      entries: [rent], transfers: settling, counted: [(cashRub, 12_000), (sberRub, 50_000)],
      now: at(96))
    #expect(after[cashRub]?.amountE4 == .zero)
    #expect(after[sberRub]?.amountE4 == money(32_000))
    let meanwhile = balances(
      entries: [rent], transfers: settling, counted: [(cashRub, 12_000), (sberRub, 50_000)],
      now: at(13))
    #expect(meanwhile[cashRub]?.amountE4 == .zero, "no money sits on it before the rent either")
    #expect(meanwhile[sberRub]?.amountE4 == money(62_000))

    var archived = live
    archived.archived = true
    let atZero = balances(entries: [rent], counted: [(cashRub, 0)])
    #expect(atZero[cashRub]?.amountE4 == .zero)
    #expect(
      AccountRules.validate(
        archived, previous: live, balances: atZero, enabled: [.rub, .usd], others: [sber, wallet]
      ) == [.archivesWithMoney])
    let owed = ArchivedMoney.balancesToMove(of: live, balances: atZero).leftovers
    #expect(owed.map(\.amount) == [money(-30_000)])
    let onRentDay = ArchivedMoney.settlingTransfers(
      owed[0], counterpart: sber.id, counterpartCountedAt: nil, now: at(12), note: nil)
    #expect(onRentDay.map(\.occurredAt) == [at(84)], "nothing to move now: one leg, with the rent")

    let paidAhead = balances(entries: [rent], counted: [(cashRub, 30_000), (sberRub, 50_000)])
    #expect(
      AccountRules.validate(
        archived, previous: live, balances: paidAhead, enabled: [.rub, .usd],
        others: [sber, wallet]) == [.archivesWithMoney],
      "30,000 now is money, though the rent takes it back to zero")
    let both = ArchivedMoney.balancesToMove(of: live, balances: paidAhead).leftovers
    #expect(both.map(\.amount) == [.zero])
    #expect(both.map(\.shownAmount) == [money(30_000)])
    let legs = ArchivedMoney.settlingTransfers(
      both[0], counterpart: sber.id, counterpartCountedAt: nil, now: at(12), note: nil)
    #expect(legs.map(\.occurredAt) == [at(12), at(84)])
    let emptied = balances(
      entries: [rent], transfers: legs, counted: [(cashRub, 30_000), (sberRub, 50_000)],
      now: at(13))
    #expect(emptied[cashRub]?.amountE4 == .zero)
    #expect(emptied[sberRub]?.amountE4 == money(80_000))
    let paid = balances(
      entries: [rent], transfers: legs, counted: [(cashRub, 30_000), (sberRub, 50_000)],
      now: at(96))
    #expect(paid[cashRub]?.amountE4 == .zero)
    #expect(paid[sberRub]?.amountE4 == money(50_000))

    // Money held now and nothing typed ahead: one transfer, dated now, as before.
    let plain = balances(counted: [(cashRub, 1_000)])
    let one = ArchivedMoney.balancesToMove(of: live, balances: plain).leftovers
    #expect(
      ArchivedMoney.settlingTransfers(
        one[0], counterpart: sber.id, counterpartCountedAt: nil, now: at(12), note: nil
      )
      .map(\.occurredAt) == [at(12)])
  }

  /// A key that moved but was never counted: nobody knows its balance, so nothing is moved
  /// for it and it is named apart.
  @Test func aNeverCountedKeyIsUnknown() {
    let spend = purchase(10, 200, on: cash.id, at: at(7))
    let books = balances(entries: [spend], counted: [])
    let check = ArchivedMoney.leftovers(
      removing: movement(spend), adding: [], balances: books, accounts: [sber, wallet, cash])
    #expect(check.leftovers.isEmpty)
    #expect(check.unknown == [cashRub])
    var live = cash
    live.archived = false
    #expect(ArchivedMoney.balancesToMove(of: live, balances: books).unknown == [cashRub])
  }

  /// In a base from 1.1, «Наличные» went to the archive at +1,000 before 1.2 asked. The
  /// leftover is offered as it is.
  @Test func aLeftoverFromOnePointOneIsOffered() {
    let books = balances(counted: [(cashRub, 1_000)])
    let result = ArchivedMoney.balancesToMove(of: cash, balances: books)
    #expect(
      result.leftovers == [
        ArchivedLeftover(key: cashRub, amount: money(1_000), latest: at(12), heldNow: money(1_000))
      ])
  }

  /// A live account is never asked about: only archived keys have leftovers.
  @Test func aLiveAccountLeavesNothing() {
    let old = purchase(10, 500, on: sber.id, at: at(7))
    let check = ArchivedMoney.leftovers(
      removing: movement(old), adding: [], balances: balances(entries: [old]),
      accounts: [sber, wallet, cash])
    #expect(check.leftovers.isEmpty && check.unknown.isEmpty)
  }
}
