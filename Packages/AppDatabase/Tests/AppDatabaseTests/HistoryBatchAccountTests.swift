import AppCore
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

/// A history written at once — a sample, a data set, later an import — is held to the rules of
/// every other write: an operation without an account gets the main one, one that moves money
/// on an account that does not hold its currency says what the account was charged, and a
/// refund takes back from its purchase no more than the purchase gave. And a sample with its
/// accounts lands whole.
@Suite("A history written at once names its accounts and their charges")
struct HistoryBatchAccountTests {
  let moment = Date(timeIntervalSince1970: 1_789_000_000)
  let card = PaymentMethod(name: "Card", currency: .rub, isDefault: true)

  func operation(
    _ amount: Int64, _ currency: CurrencyCode = .rub, kind: TransactionKind = .expense,
    account: UUID? = nil, charged: AmountE4? = nil, refunding part: UUID? = nil
  ) -> TransactionEntry {
    let id = UUID()
    let rate: Decimal? = currency == .rub ? nil : 90
    let rubles = AmountE4(whole: currency == .rub ? amount : amount * 90)
    return TransactionEntry(
      transaction: Transaction(
        id: id, kind: kind, occurredAt: moment, currency: currency,
        amountE4: AmountE4(whole: amount), rate: rate, rateSource: rate == nil ? nil : .manual,
        amountRubE4: rubles, paymentMethodId: account,
        accountCurrency: charged == nil ? nil : .rub, accountAmountE4: charged,
        createdAt: moment, updatedAt: moment),
      parts: [
        TransactionPart(
          transactionId: id, amountE4: AmountE4(whole: amount), amountRubE4: rubles,
          refundOfPartId: part)
      ])
  }

  func count(_ table: String, in stack: DatabaseStack) throws -> Int {
    try stack.writer.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0 }
  }

  @Test(arguments: [false, true])
  func anOperationWithoutAnAccountGetsTheMainOne(overExistingRows: Bool) throws {
    let stack = try TestSupport.makeStack()
    let repository = TransactionRepository(writer: stack.writer)
    let entry = operation(250)
    let batch = HistoryBatch(paymentMethods: [card], entries: [entry])
    if overExistingRows { try repository.save(batch) } else { try repository.insert(batch) }
    #expect(try repository.entry(id: entry.id)?.transaction.paymentMethodId == card.id)
  }

  /// Dollars on a ruble card with nothing said of the rubles it was charged: the whole batch is
  /// refused, and nothing of it is written.
  @Test(arguments: [false, true])
  func dollarsOnARubleCardWithoutTheirChargeAreRefused(overExistingRows: Bool) throws {
    let stack = try TestSupport.makeStack()
    let repository = TransactionRepository(writer: stack.writer)
    let batch = HistoryBatch(
      paymentMethods: [card], entries: [operation(250), operation(20, .usd, account: card.id)])
    #expect(throws: AccountWriteError.chargeMissing) {
      if overExistingRows { try repository.save(batch) } else { try repository.insert(batch) }
    }
    #expect(try count("transactions", in: stack) == 0)
    #expect(try count("payment_methods", in: stack) == 0)

    let charged = HistoryBatch(
      paymentMethods: [card],
      entries: [operation(20, .usd, account: card.id, charged: AmountE4(whole: 1_850))])
    if overExistingRows { try repository.save(charged) } else { try repository.insert(charged) }
    #expect(try count("transactions", in: stack) == 1)
  }

  /// The list of operations alone is the same write.
  @Test func operationsInsertedAloneAreHeldToTheSameRule() throws {
    let stack = try TestSupport.makeStack()
    try ReferenceRepository(writer: stack.writer).save(card)
    let repository = TransactionRepository(writer: stack.writer)
    #expect(throws: AccountWriteError.chargeMissing) {
      try repository.insert([operation(20, .usd)])
    }
    try repository.insert([operation(20)])
    #expect(try count("transactions", in: stack) == 1)
  }

  /// A refund that takes back more than its purchase part is refused inside the write, and so is
  /// one of something that is not a purchase.
  @Test func aRefundIsHeldToItsPurchase() throws {
    let stack = try TestSupport.makeStack()
    let repository = TransactionRepository(writer: stack.writer)
    let purchase = operation(1_000, account: card.id)
    let part = try #require(purchase.parts.first?.id)
    let tooMuch = operation(1_200, kind: .refund, account: card.id, refunding: part)
    #expect(throws: RefundError.exceedsRemaining) {
      try repository.insert(HistoryBatch(paymentMethods: [card], entries: [purchase, tooMuch]))
    }
    #expect(try count("transactions", in: stack) == 0)

    let income = operation(1_000, kind: .income, account: card.id)
    let ofIncome = operation(
      100, kind: .refund, account: card.id, refunding: try #require(income.parts.first?.id))
    #expect(throws: RefundError.notRefundable) {
      try repository.insert(HistoryBatch(paymentMethods: [card], entries: [income, ofIncome]))
    }

    let half = operation(500, kind: .refund, account: card.id, refunding: part)
    try repository.save(HistoryBatch(paymentMethods: [card], entries: [purchase, half]))
    // Written again over itself, the refund is not counted twice against its part.
    try repository.save(HistoryBatch(paymentMethods: [card], entries: [purchase, half]))
    #expect(try count("transactions", in: stack) == 2)
  }

  /// A history of the generator alone — before its accounts — is written the way accounts keep
  /// it: nothing is refused, and every operation is on an account.
  @Test func theHistoryAloneIsWrittenWithItsAccounts() throws {
    let stack = try TestSupport.makeStack()
    let set = TestSupport.sample(months: 2)
    try TransactionRepository(writer: stack.writer).insert(HistoryBatch(sample: set))
    #expect(try count("transactions", in: stack) == set.entries.count)
    #expect(
      try stack.writer.read { db in
        try Int.fetchOne(
          db, sql: "SELECT COUNT(*) FROM transactions WHERE payment_method_id IS NULL")
      } == 0)
  }

  /// A sample with its accounts lands whole: its groups, transfers and counts, the settings of
  /// accounts that are set up, the payment due once — and the balances the app works out from
  /// what it reads back are the ones the sample kept.
  @Test func aSampleWithItsAccountsLandsWhole() async throws {
    let stack = try TestSupport.makeStack()
    let set = TestSupport.sample().withAccounts(
      seed: 20_260_918, calendar: TestSupport.sampleCalendar, language: "en")
    try TransactionRepository(writer: stack.writer).insert(HistoryBatch(sample: set))

    let counts = try ExportRepository(writer: stack.writer).rowCounts()
    #expect(counts["transactions"] == set.entries.count)
    #expect(counts["account_groups"] == 2)
    #expect(counts["transfers"] == set.transfers.count)
    #expect(counts["reconciliations"] == set.reconciliations.count)
    #expect(counts["reconciliation_balances"] == set.reconciledBalances.count)
    #expect(counts["reimbursement_links"] == set.links.count)
    #expect(counts["scheduled_payments"] == set.planning.scheduled.count)
    #expect(counts["cards"] == set.cards.count)
    #expect(counts["cashback_rules"] == set.cashbackRules.count)
    let settings = SettingsRepository(writer: stack.writer)
    #expect(try settings.string(AccountSettings.setupKey) == "done")
    #expect(try settings.defaultCurrency() == .rub)

    let dataset = try await DatasetRepository(writer: stack.writer).load(version: 1)
    #expect(dataset.accountSettings.setup == .done)
    let balances = AccountBalances.build(
      entries: dataset.entries, transfers: dataset.transfers,
      debtEntries: dataset.planning.debtEntries,
      debts: Dictionary(uniqueKeysWithValues: dataset.debts.map { ($0.id, $0) }),
      reconciliations: dataset.planning.reconciliations,
      balances: dataset.planning.reconciledBalances, accounts: dataset.paymentMethods,
      tree: CategoryTree(dataset.categories),
      now: TestSupport.sampleCalendar.startOfDay(
        TestSupport.sampleCalendar.adding(days: 1, to: set.lastDay)),
      calendar: TestSupport.sampleCalendar)
    for (key, amount) in set.accountExpectations {
      #expect(balances[key]?.amountE4 == amount, "\(key)")
    }

    // Written again over itself, as the Debug menu does: one history, not two.
    try TransactionRepository(writer: stack.writer).save(HistoryBatch(sample: set))
    #expect(try ExportRepository(writer: stack.writer).rowCounts() == counts)
  }

  /// The Debug menu clicked on one day and again on another writes the second sample over the
  /// first without a refusal: a row of the accounts layer that both days hold is the same row,
  /// so no purchase loses a part its refund points at.
  @Test(arguments: [(6, 20), (11, 29), (16, 30), (1, 31)])
  func aSampleWrittenAgainOnAnotherDayLands(first: Int, second: Int) throws {
    let stack = try TestSupport.makeStack()
    let repository = TransactionRepository(writer: stack.writer)
    for day in [first, second] {
      let set = SampleDataGenerator(seed: 20_260_918).generate(
        months: 6, endingOn: DateOnly(year: 2026, month: 8, day: day),
        calendar: TestSupport.sampleCalendar, language: "en"
      ).withAccounts(seed: 20_260_918, calendar: TestSupport.sampleCalendar, language: "en")
      try repository.save(HistoryBatch(sample: set))
    }
    #expect(try count("transactions", in: stack) > 0)
  }

  /// The menu clicked once a day for three weeks into one database: every sample lands.
  @Test func aSampleWrittenEveryDayLands() throws {
    let stack = try TestSupport.makeStack()
    let repository = TransactionRepository(writer: stack.writer)
    let calendar = TestSupport.sampleCalendar
    for offset in 0..<21 {
      let day = calendar.adding(days: offset, to: DateOnly(year: 2026, month: 8, day: 1))
      let set = SampleDataGenerator(seed: 20_260_918).generate(
        months: 6, endingOn: day, calendar: calendar, language: "en"
      ).withAccounts(seed: 20_260_918, calendar: calendar, language: "en")
      #expect(throws: Never.self, "\(day.iso)") { try repository.save(HistoryBatch(sample: set)) }
    }
  }
}
