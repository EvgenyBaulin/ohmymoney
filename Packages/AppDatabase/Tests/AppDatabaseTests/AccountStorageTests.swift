import AppCore
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

private let noon = Date(timeIntervalSince1970: 1_789_128_000)  // 2026-09-11 12:00:00 UTC

@Suite("What keeps an account from being deleted, and what a deletion takes")
struct AccountDeletionTests {
  @Test func anUnusedAccountHasNoUsage() throws {
    let stack = try TestSupport.makeStack()
    let card = PaymentMethod(name: "Card")
    try ReferenceRepository(writer: stack.writer).save(card)
    let usage = try AccountRepository(writer: stack.writer).usage(of: card.id)
    #expect(usage == AccountUsage())
    #expect(!usage.isUsed)
  }

  /// Operations — the ones in the bin included —, transfers either way, scheduled payments
  /// and journal lines all count; any of them refuses the deletion, and nothing is written.
  @Test func everythingThatPointsAtAnAccountCountsAndRefusesItsDeletion() throws {
    let stack = try TestSupport.makeStack()
    let fixture = try TestSupport.seedReferences(stack)
    let card = fixture.paymentMethod
    let cash = PaymentMethod(name: "Cash", kind: .cash)
    try ReferenceRepository(writer: stack.writer).save(cash)
    let transactions = TransactionRepository(writer: stack.writer)
    var draft = TransactionDraft(amount: AmountE4(whole: 10), paymentMethodId: card.id)
    draft.normalizeSinglePart()
    let binned = try draft.materialize()
    try transactions.save(binned)
    try transactions.softDelete(id: binned.id)
    _ = try PlanningRepository(writer: stack.writer).apply(
      PlanningChange(
        upsert: PlanningRows(
          scheduled: [
            ScheduledPayment(name: "Rent", amountE4: AmountE4(whole: 1), paymentMethodId: card.id)
          ],
          debtEntries: [
            DebtEntry(
              debtId: fixture.debt.id, amountE4: AmountE4(whole: 1), kind: .borrowed,
              paymentMethodId: card.id)
          ],
          transfers: [
            Transfer(
              occurredAt: noon, fromAccountId: cash.id, fromCurrency: .rub,
              fromAmountE4: AmountE4(whole: 5), toAccountId: card.id, toCurrency: .rub,
              toAmountE4: AmountE4(whole: 5), createdAt: noon, updatedAt: noon)
          ])))
    let accounts = AccountRepository(writer: stack.writer)

    let usage = try accounts.usage(of: card.id)
    #expect(usage == AccountUsage(operations: 1, transfers: 1, scheduled: 1, debtEntries: 1))
    #expect(throws: AccountWriteError.inUse(usage)) { try accounts.delete(card.id) }
    #expect(try accounts.usage(of: cash.id) == AccountUsage(transfers: 1))
    #expect(throws: AccountWriteError.inUse(AccountUsage(transfers: 1))) {
      try accounts.delete(cash.id)
    }
    #expect(try accounts.accounts().count == 2)
    #expect(throws: AccountWriteError.notFound) { try accounts.delete(UUID()) }
  }

  /// A main account goes only while another live account is main — as in an older file that
  /// holds two —; an archived one flagged main does not count.
  @Test func theMainAccountIsDeletedOnlyWhenAnotherIsMain() throws {
    let stack = try TestSupport.makeStack()
    let main = PaymentMethod(name: "Card", isDefault: true)
    let second = PaymentMethod(name: "Second", isDefault: true)
    let archivedMain = PaymentMethod(name: "Old", isDefault: true, archived: true)
    let cash = PaymentMethod(name: "Cash", kind: .cash)
    try stack.writer.write { db in
      for method in [main, second, archivedMain, cash] { try method.insert(db) }
    }
    let accounts = AccountRepository(writer: stack.writer)

    try accounts.delete(main.id)
    #expect(
      Set(try accounts.accounts(includeArchived: true).map(\.id))
        == [second.id, archivedMain.id, cash.id])

    // Now the only live main one: the archived flag keeps nothing.
    #expect(throws: AccountWriteError.isMain) { try accounts.delete(second.id) }
    #expect(
      try accounts.accounts(includeArchived: true).filter(\.isMain).map(\.id).sorted {
        $0.uuidString < $1.uuidString
      } == [second.id, archivedMain.id].sorted { $0.uuidString < $1.uuidString })
  }

  /// A deleted account takes its counts along, and a reconciliation of accounts left with no
  /// count at all; a total of the time before accounts is history and stays.
  @Test func aDeletedAccountTakesItsCountsAndTheReconciliationsLeftEmpty() throws {
    let stack = try TestSupport.makeStack()
    let card = PaymentMethod(name: "Card")
    let cash = PaymentMethod(name: "Cash", kind: .cash)
    let alone = Reconciliation(
      date: DateOnly(year: 2026, month: 9, day: 1), reconciledAt: noon, actualTotalRubE4: .zero,
      kind: .accounts)
    let shared = Reconciliation(
      date: DateOnly(year: 2026, month: 9, day: 2), reconciledAt: noon, actualTotalRubE4: .zero,
      kind: .opening)
    let total = Reconciliation(
      date: DateOnly(year: 2026, month: 8, day: 31), actualTotalRubE4: AmountE4(whole: 100))
    let counts = [
      ReconciledBalance(
        reconciliationId: alone.id, accountId: card.id, currency: .rub, actualE4: .zero),
      ReconciledBalance(
        reconciliationId: shared.id, accountId: card.id, currency: .rub, actualE4: .zero),
      ReconciledBalance(
        reconciliationId: shared.id, accountId: cash.id, currency: .rub, actualE4: .zero),
    ]
    _ = try PlanningRepository(writer: stack.writer).apply(
      PlanningChange(
        upsert: PlanningRows(
          reconciliations: [total, alone, shared], paymentMethods: [card, cash],
          reconciledBalances: counts)))

    try AccountRepository(writer: stack.writer).delete(card.id)

    let book = try PlanningRepository(writer: stack.writer).book()
    #expect(book.reconciliations.map(\.id) == [total.id, shared.id])
    #expect(book.reconciledBalances == [counts[2]])
  }

  @Test func aGroupIsDeletedOnlyWhenNoAccountIsFiledUnderIt() throws {
    let stack = try TestSupport.makeStack()
    let used = AccountGroup(name: "Russia")
    let empty = AccountGroup(name: "Georgia")
    let archived = PaymentMethod(name: "Old card", archived: true, groupId: used.id)
    _ = try PlanningRepository(writer: stack.writer).apply(
      PlanningChange(
        upsert: PlanningRows(accountGroups: [used, empty], paymentMethods: [archived])))
    let accounts = AccountRepository(writer: stack.writer)

    #expect(throws: AccountWriteError.groupInUse) { try accounts.deleteGroup(used.id) }
    try accounts.deleteGroup(empty.id)
    #expect(try accounts.groups(includeArchived: true) == [used])
    #expect(throws: AccountWriteError.notFound) { try accounts.deleteGroup(empty.id) }
  }
}

@Suite("The setup of the accounts, done or put off")
struct AccountSetupStorageTests {
  /// The setup writes the accounts and groups, one main account, the counted balances as the
  /// first reconciliation, the currencies they need, the default currency and the mark; the
  /// operations that had no account get the main one — `updated_at` untouched.
  @Test func finishingTheSetupWritesEverythingInOneGo() throws {
    let stack = try TestSupport.makeStack()
    let settings = SettingsRepository(writer: stack.writer)
    try settings.setEnabledCurrencies([.rub, .usd])
    let transactions = TransactionRepository(writer: stack.writer)
    let loose = try TestSupport.makeEntry(note: "no account")
    try transactions.save(loose)
    let stored = try #require(try transactions.entry(id: loose.id))
    let old = PaymentMethod(name: "Old main", isDefault: true)
    try ReferenceRepository(writer: stack.writer).save(old)

    let kazakhstan = AccountGroup(name: "Kazakhstan", inSummary: false)
    let card = PaymentMethod(name: "Card", currency: .rub, isDefault: true)
    let freedom = PaymentMethod(
      name: "Freedom", kind: .account, currency: .eur, groupId: kazakhstan.id,
      otherCurrencies: [.usd, CurrencyCode("KZT")])
    let cardRub = BalanceKey(accountId: card.id, currency: .rub)
    let freedomKzt = BalanceKey(accountId: freedom.id, currency: CurrencyCode("KZT"))
    let plan = AccountSetupPlan(
      accounts: [card, freedom], groups: [kazakhstan], mainAccountId: card.id,
      openingBalances: [cardRub: AmountE4(whole: 90_000), freedomKzt: AmountE4(whole: 50_000)],
      expected: [freedomKzt: AmountE4(whole: 52_000)], defaultCurrency: CurrencyCode("KZT"),
      at: noon)
    try AccountRepository(writer: stack.writer).finishSetup(plan, calendar: .moscow)

    let accounts = try AccountRepository(writer: stack.writer).accounts(includeArchived: true)
    #expect(accounts.filter(\.isMain).map(\.id) == [card.id])
    #expect(accounts.contains(freedom))
    #expect(try AccountRepository(writer: stack.writer).groups() == [kazakhstan])

    let book = try PlanningRepository(writer: stack.writer).book()
    let opening = try #require(book.reconciliations.first)
    #expect(book.reconciliations.count == 1)
    #expect(opening.kind == .opening)
    #expect(opening.reconciledAt == noon)
    #expect(opening.date == DateOnly(year: 2026, month: 9, day: 11))
    let counts = Dictionary(uniqueKeysWithValues: book.reconciledBalances.map { ($0.key, $0) })
    #expect(counts.count == 2)
    #expect(counts[cardRub]?.isStartingPoint == true)
    #expect(counts[cardRub]?.actualE4 == AmountE4(whole: 90_000))
    #expect(counts[freedomKzt]?.expectedE4 == AmountE4(whole: 52_000))
    #expect(counts[freedomKzt]?.differenceE4 == AmountE4(whole: -2_000))
    #expect(counts[freedomKzt]?.transactionId == nil)

    #expect(try settings.enabledCurrencies() == [.rub, .usd, .eur, CurrencyCode("KZT")])
    #expect(try settings.defaultCurrency() == CurrencyCode("KZT"))
    #expect(try settings.string(AccountSettings.setupKey) == "done")
    let moved = try #require(try transactions.entry(id: loose.id))
    #expect(moved.transaction.paymentMethodId == card.id)
    #expect(moved.transaction.updatedAt == stored.transaction.updatedAt)
  }

  /// More than ten currencies needed: there is no limit any more, the setup is written and
  /// switches the new ones on after the ten.
  @Test func aSetupThatNeedsMoreThanTenCurrenciesSwitchesThemOn() throws {
    let stack = try TestSupport.makeStack()
    let settings = SettingsRepository(writer: stack.writer)
    try settings.setEnabledCurrencies(CurrencyCode.defaultEnabled)
    let wide = PaymentMethod(
      name: "Wide", currency: .rub, isDefault: true,
      otherCurrencies: [CurrencyCode("JPY"), CurrencyCode("GBP")])
    let plan = AccountSetupPlan(accounts: [wide], mainAccountId: wide.id, at: noon)
    try AccountRepository(writer: stack.writer).finishSetup(plan, calendar: .utc)
    #expect(try AccountRepository(writer: stack.writer).accounts().map(\.id) == [wide.id])
    #expect(try settings.string(AccountSettings.setupKey) == "done")
    #expect(
      try settings.enabledCurrencies()
        == CurrencyCode.defaultEnabled + [CurrencyCode("JPY"), CurrencyCode("GBP")])
  }

  /// «Позже» with no main account makes one in the default currency and gives it every
  /// operation without an account; with a main account it only gives them to it.
  @Test func puttingTheSetupOffMakesAMainAccountOnlyWhenThereIsNone() throws {
    let stack = try TestSupport.makeStack()
    let transactions = TransactionRepository(writer: stack.writer)
    let loose = try TestSupport.makeEntry(note: "no account")
    try transactions.save(loose)
    let accounts = AccountRepository(writer: stack.writer)

    try accounts.postponeSetup(
      mainAccountName: "Основной счёт", defaultCurrency: CurrencyCode("KZT"), at: noon)
    let made = try #require(try accounts.accounts().first)
    #expect(try accounts.accounts().count == 1)
    #expect(made.name == "Основной счёт")
    #expect(made.kind == .account)
    #expect(made.currency == CurrencyCode("KZT"))
    #expect(made.isMain)
    #expect(try transactions.entry(id: loose.id)?.transaction.paymentMethodId == made.id)
    let setup = try SettingsRepository(writer: stack.writer).string(AccountSettings.setupKey)
    #expect(setup == "later")

    // The main account holds tenge: an operation in tenge needs nothing charged apart.
    var later = TransactionDraft(
      currency: CurrencyCode("KZT"), amount: AmountE4(whole: 1500), rate: Decimal(2) / 10,
      note: "later still")
    later.normalizeSinglePart()
    let another = try later.materialize(rublesConverter: { AmountE4(raw: $0.raw / 5) })
    try transactions.save(another)
    try accounts.postponeSetup(mainAccountName: "Second", defaultCurrency: .rub, at: noon)
    #expect(try accounts.accounts().map(\.id) == [made.id])
    #expect(try transactions.entry(id: another.id)?.transaction.paymentMethodId == made.id)
  }
}

@Suite("The default currency and the currencies that stay on")
struct CurrencySettingsStorageTests {
  @Test func theDefaultCurrencyIsRublesUntilOneIsChosen() throws {
    let stack = try TestSupport.makeStack()
    let settings = SettingsRepository(writer: stack.writer)
    try settings.setEnabledCurrencies([.rub, .usd])
    #expect(try settings.defaultCurrency() == .rub)

    try settings.setDefaultCurrency(CurrencyCode("KZT"))
    #expect(try settings.defaultCurrency() == CurrencyCode("KZT"))
    #expect(try settings.enabledCurrencies() == [.rub, .usd, CurrencyCode("KZT")])
    #expect(try settings.string(AccountSettings.defaultCurrencyKey) == "KZT")

    // One already on stays where it is.
    try settings.setDefaultCurrency(.usd)
    #expect(try settings.enabledCurrencies() == [.rub, .usd, CurrencyCode("KZT")])
  }

  /// The default currency may be an eleventh: there is no limit any more.
  @Test func theDefaultCurrencyMayBeAnEleventh() throws {
    let stack = try TestSupport.makeStack()
    let settings = SettingsRepository(writer: stack.writer)
    try settings.setEnabledCurrencies(CurrencyCode.defaultEnabled)
    try settings.setDefaultCurrency(CurrencyCode("JPY"))
    #expect(try settings.defaultCurrency() == CurrencyCode("JPY"))
    #expect(try settings.enabledCurrencies() == CurrencyCode.defaultEnabled + [CurrencyCode("JPY")])
  }

  /// The default currency, and one a live account holds, are not switched off; an archived
  /// account holds nothing on.
  @Test func aCurrencyStillNeededStaysOn() throws {
    let stack = try TestSupport.makeStack()
    let settings = SettingsRepository(writer: stack.writer)
    try settings.setEnabledCurrencies([.rub, .usd, .eur, CurrencyCode("KZT")])
    let references = ReferenceRepository(writer: stack.writer)
    try references.save(PaymentMethod(name: "Dollars", currency: .usd))
    try references.save(
      PaymentMethod(name: "Freedom", currency: .eur, otherCurrencies: [CurrencyCode("KZT")]))
    try references.save(PaymentMethod(name: "Old", currency: CurrencyCode("GEL"), archived: true))

    #expect(throws: SettingsWriteError.currencyInUse(.rub)) {
      try settings.setEnabledCurrencies([.usd, .eur, CurrencyCode("KZT")])
    }
    #expect(throws: SettingsWriteError.currencyInUse(.usd)) {
      try settings.setEnabledCurrencies([.rub, .eur, CurrencyCode("KZT")])
    }
    #expect(throws: SettingsWriteError.currencyInUse(CurrencyCode("KZT"))) {
      try settings.setEnabledCurrencies([.rub, .usd, .eur])
    }
    #expect(try settings.enabledCurrencies() == [.rub, .usd, .eur, CurrencyCode("KZT")])

    // Reordering drops nothing; adding is always fine.
    try settings.setEnabledCurrencies([CurrencyCode("KZT"), .eur, .usd, .rub, CurrencyCode("GEL")])
    #expect(
      try settings.enabledCurrencies() == [
        CurrencyCode("KZT"), .eur, .usd, .rub, CurrencyCode("GEL"),
      ])
    // A currency no live account holds goes.
    try settings.setEnabledCurrencies([CurrencyCode("KZT"), .eur, .usd, .rub])
  }
}

@Suite("The accounts reach the dataset, the export and a history batch")
struct AccountDataTests {
  @Test func theDatasetCarriesTransfersGroupsAndTheSettingsOfTheAccounts() async throws {
    let stack = try TestSupport.makeStack()
    let card = PaymentMethod(name: "Card")
    let cash = PaymentMethod(name: "Cash", kind: .cash)
    let groups = [
      AccountGroup(name: "B", sort: 1), AccountGroup(name: "A", sort: 1),
      AccountGroup(name: "Z", sort: 0),
    ]
    let later = Transfer(
      occurredAt: noon.addingTimeInterval(60), fromAccountId: card.id, fromCurrency: .rub,
      fromAmountE4: AmountE4(whole: 2), toAccountId: cash.id, toCurrency: .rub,
      toAmountE4: AmountE4(whole: 2), createdAt: noon, updatedAt: noon)
    let earlier = Transfer(
      occurredAt: noon, fromAccountId: cash.id, fromCurrency: .rub,
      fromAmountE4: AmountE4(whole: 1), toAccountId: card.id, toCurrency: .rub,
      toAmountE4: AmountE4(whole: 1), createdAt: noon, updatedAt: noon)
    let fees = UUID()
    _ = try PlanningRepository(writer: stack.writer).apply(
      PlanningChange(
        upsert: PlanningRows(
          accountGroups: groups, paymentMethods: [card, cash], transfers: [later, earlier]),
        settings: [
          AccountSettings.defaultCurrencyKey: "USD", AccountSettings.setupKey: "done",
          AccountSettings.transferFeeCategoryKey: fees.uuidString,
        ]))

    let dataset = try await DatasetRepository(writer: stack.writer).load(version: 3)
    #expect(dataset.transfers == [earlier, later])
    #expect(dataset.accountGroups.map(\.name) == ["Z", "A", "B"])
    #expect(
      dataset.accountSettings
        == AccountSettings(defaultCurrency: .usd, setup: .done, transferFeeCategoryId: fees))
  }

  /// The three files the accounts brought are written with their rows, and the counts of the
  /// export know them.
  @Test func theExportWritesTheTablesOfTheAccounts() throws {
    let stack = try TestSupport.makeStack()
    let card = PaymentMethod(name: "Card")
    let cash = PaymentMethod(name: "Cash", kind: .cash)
    let group = AccountGroup(name: "Russia")
    let sheet = Reconciliation(
      date: DateOnly(year: 2026, month: 9, day: 11), reconciledAt: noon, actualTotalRubE4: .zero,
      kind: .accounts)
    _ = try PlanningRepository(writer: stack.writer).apply(
      PlanningChange(
        upsert: PlanningRows(
          reconciliations: [sheet], accountGroups: [group], paymentMethods: [card, cash],
          transfers: [
            Transfer(
              occurredAt: noon, fromAccountId: card.id, fromCurrency: .rub,
              fromAmountE4: AmountE4(whole: 1), toAccountId: cash.id, toCurrency: .rub,
              toAmountE4: AmountE4(whole: 1))
          ],
          reconciledBalances: [
            ReconciledBalance(
              reconciliationId: sheet.id, accountId: card.id, currency: .rub,
              actualE4: AmountE4(whole: 7))
          ])))

    let export = ExportRepository(writer: stack.writer)
    let tables = try export.tables()
    #expect(tables.count == 31)
    #expect(
      tables.dropLast(7).suffix(6).map(\.fileName) == [
        "account_groups.csv", "transfers.csv", "reconciliation_balances.csv", "cards.csv",
        "cashback_rules.csv", "banks.csv",
      ])
    let counts = try export.rowCounts()
    #expect(counts["account_groups"] == 1)
    #expect(counts["transfers"] == 1)
    #expect(counts["reconciliation_balances"] == 1)
    #expect(counts["cards"] == 0)
    #expect(counts["cashback_rules"] == 0)
    for table in tables.dropLast(10).suffix(3) {
      let rows = try CSVReader.dictionaries(from: table.data)
      #expect(rows.count == 1, "\(table.fileName)")
    }
    let balances = try CSVReader.dictionaries(from: tables[20].data)
    #expect(balances.first?["actual"] == "7")
    #expect(balances.first?["expected"] == "")
  }

  /// A history batch brings its groups, transfers, reconciliations and counts in one write,
  /// and written twice over its own rows it stays one history.
  @Test func aHistoryBatchWritesTheRowsOfTheAccounts() throws {
    let stack = try TestSupport.makeStack()
    let group = AccountGroup(name: "Kazakhstan", inSummary: false)
    let card = PaymentMethod(name: "Card", groupId: group.id)
    let cash = PaymentMethod(name: "Cash", kind: .cash)
    let transfer = Transfer(
      occurredAt: noon, fromAccountId: card.id, fromCurrency: .rub,
      fromAmountE4: AmountE4(whole: 3), toAccountId: cash.id, toCurrency: .rub,
      toAmountE4: AmountE4(whole: 3), createdAt: noon, updatedAt: noon)
    let sheet = Reconciliation(
      date: DateOnly(year: 2026, month: 9, day: 11), reconciledAt: noon, actualTotalRubE4: .zero,
      kind: .opening)
    let count = ReconciledBalance(
      reconciliationId: sheet.id, accountId: cash.id, currency: .rub,
      actualE4: AmountE4(whole: 3))
    let batch = HistoryBatch(
      paymentMethods: [card, cash], settings: [AccountSettings.setupKey: "done"],
      accountGroups: [group], transfers: [transfer], reconciliations: [sheet],
      reconciledBalances: [count])
    let repository = TransactionRepository(writer: stack.writer)
    try repository.insert(batch)
    try repository.save(batch)

    let book = try PlanningRepository(writer: stack.writer).book()
    #expect(book.reconciliations == [sheet])
    #expect(book.reconciledBalances == [count])
    #expect(try stack.writer.read { db in try Transfer.fetchAll(db) } == [transfer])
    #expect(try AccountRepository(writer: stack.writer).groups() == [group])
    #expect(try SettingsRepository(writer: stack.writer).string(AccountSettings.setupKey) == "done")
  }
}

@Suite("The fee of a transfer gives its key back when it is deleted")
struct TransferFeeKeyTests {
  /// Deleted, a fee pays nothing: its key is cleared, so the transfer can be given a fee
  /// again; restored, it takes the key back.
  @Test func aDeletedFeeReleasesItsKeyAndARestoredOneTakesItBack() throws {
    let stack = try TestSupport.makeStack()
    let repository = TransactionRepository(writer: stack.writer)
    let transfer = UUID()
    let key = OperationLink.transferFee(transfer).externalId
    var fee = try TestSupport.makeEntry(note: "fee")
    fee.transaction.externalId = key
    try repository.save(fee)

    let effects = try repository.softDelete(ids: [fee.id], at: noon)
    #expect(effects.releasedExternalIds == [fee.id: key])
    #expect(try repository.entry(id: fee.id)?.transaction.externalId == nil)

    var again = try TestSupport.makeEntry(note: "fee again")
    again.transaction.externalId = key
    try repository.save(again)
    try repository.softDelete(ids: [again.id], at: noon)

    try repository.restore(ids: effects.deletedIds, at: noon, effects: effects)
    #expect(try repository.entry(id: fee.id)?.transaction.externalId == key)
    #expect(try repository.entry(id: fee.id)?.transaction.isDeleted == false)
  }
}

@Suite("An account goes to the archive with its money moved")
struct ArchiveWithMoneyStorageTests {
  /// «В архив» on the cash with 3,000 ₽ shows 3,000 and moves them to Сбер with the archive.
  /// A purchase of 500 ₽ written meanwhile makes it 2,500: the change that still expects
  /// 3,000 is refused whole — no archive, no transfer —, and the one that expects 2,500 lands.
  @Test func archivingWithMoneyRefusesAStaleAmount() throws {
    let stack = try TestSupport.makeStack()
    let references = ReferenceRepository(writer: stack.writer)
    let sber = PaymentMethod(name: "Sber", currency: .rub, isDefault: true)
    var cash = PaymentMethod(name: "Cash", kind: .cash, currency: .rub)
    try references.save(sber)
    try references.save(cash)
    let planning = PlanningRepository(writer: stack.writer)
    let counted = noon.addingTimeInterval(-3_600)
    let count = Reconciliation(
      date: CalendarContext.utc.day(of: counted), reconciledAt: counted,
      actualTotalRubE4: .zero, kind: .accounts)
    _ = try planning.apply(
      PlanningChange(
        upsert: PlanningRows(
          reconciliations: [count],
          reconciledBalances: [
            ReconciledBalance(
              reconciliationId: count.id, accountId: cash.id, currency: .rub,
              actualE4: AmountE4(whole: 3_000))
          ]), at: counted))
    let key = BalanceKey(accountId: cash.id, currency: .rub)

    var draft = TransactionDraft(
      occurredAt: noon.addingTimeInterval(-600), amount: AmountE4(whole: 500),
      paymentMethodId: cash.id)
    draft.normalizeSinglePart()
    try TransactionRepository(writer: stack.writer).save(try draft.materialize())

    cash.archived = true
    func archive(expecting amount: Int64) -> PlanningChange {
      let settling = Transfer(
        occurredAt: noon, fromAccountId: cash.id, fromCurrency: .rub,
        fromAmountE4: AmountE4(whole: amount), toAccountId: sber.id, toCurrency: .rub,
        toAmountE4: AmountE4(whole: amount), createdAt: noon, updatedAt: noon)
      return PlanningChange(
        upsert: PlanningRows(paymentMethods: [cash], transfers: [settling]), at: noon,
        expectingBalances: [key: AmountE4(whole: amount)])
    }
    #expect(throws: PlanningWriteError.balanceChanged(key)) {
      try planning.apply(archive(expecting: 3_000))
    }
    let untouched = try AccountRepository(writer: stack.writer).accounts(includeArchived: true)
    #expect(untouched.first { $0.id == cash.id }?.archived == false)
    #expect(try stack.writer.read { db in try Transfer.fetchCount(db) } == 0)

    _ = try planning.apply(archive(expecting: 2_500))
    let archived = try AccountRepository(writer: stack.writer).accounts(includeArchived: true)
    #expect(archived.first { $0.id == cash.id }?.archived == true)
    #expect(try stack.writer.read { db in try Transfer.fetchCount(db) } == 1)
  }
}
