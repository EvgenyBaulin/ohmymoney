import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// Money given back on a debt owed to me, saved by the entry line: the one rule of repayments
/// holds there as in the debt's own form — the journal takes what is left of the debt, the debt
/// closes once covered, what came back above it is income in «Доплаты» — and all of it is one
/// step of ⌘Z. A debt kept in another currency is repaid in its own currency, at the rate the
/// money-back confirmation showed, with the money as the account received it.
@MainActor
final class EntryDebtRepaymentTests: XCTestCase {
  private var host: EntryHost?
  private var environment: AppEnvironment?
  private var directory: URL?
  private var dataDirectoryBefore: String?

  override func tearDown() async throws {
    host?.close()
    host = nil
    if let environment { await environment.close() }
    environment = nil
    if let directory {
      if let dataDirectoryBefore {
        setenv("OHMYMONEY_DATA_DIR", dataDirectoryBefore, 1)
      } else {
        unsetenv("OHMYMONEY_DATA_DIR")
      }
      try? FileManager.default.removeItem(at: directory)
    }
  }

  /// A debt owed to me of `balance` in `currency`, as a line of money lent.
  private static func lent(
    _ balance: Int64, to name: String, in currency: CurrencyCode = .rub,
    environment: AppEnvironment
  ) throws -> Debt {
    let debt = Debt(
      direction: .owedToMe, type: .personal, name: name, currency: currency,
      paymentsAreExpenses: false)
    var rows = PlanningRows.empty
    rows.debts = [debt]
    rows.debtEntries = [
      DebtRules.makeEntry(debtId: debt.id, kind: .borrowed, amountE4: AmountE4(whole: balance))
    ]
    _ = try XCTUnwrap(environment.planning).apply(PlanningChange(upsert: rows))
    environment.refreshVocabulary()
    return debt
  }

  private static func surcharges(in environment: AppEnvironment) throws -> UUID {
    try XCTUnwrap(
      try XCTUnwrap(environment.references).category(systemRole: .surcharges, kind: .income)?.id)
  }

  /// «+1700 долг Маша» on Маша's 1,000 ₽ is the same as money back: the debt takes 1,000 ₽ and
  /// closes, 700 ₽ are income in «Доплаты», and the 1,000 ₽ are not income — the operation is
  /// money back, not an income of 1,700 ₽. One ⌘Z takes all of it back.
  func testAnIncomeNamingTheDebtRepaysItLikeMoneyBack() async throws {
    var debt: Debt?
    let host = try await EntryHost(opensDetails: false) { environment in
      try XCTUnwrap(environment.references).save(
        PaymentMethod(name: "Card", currency: .rub, isDefault: true))
      debt = try Self.lent(1_000, to: "Маша", environment: environment)
    }
    self.host = host
    let masha = try XCTUnwrap(debt)
    try host.type("+1700 долг Маша", into: try host.line())
    host.pressReturn()

    let lines = try host.references.debtEntries(debtId: masha.id)
    XCTAssertEqual(
      lines.filter { $0.kind == .payment }.map(\.amountE4), [AmountE4(whole: -1_000)],
      "the debt takes what was left of it, not the whole 1,700")
    XCTAssertEqual(DebtRules.balance(entries: lines), .zero)
    XCTAssertEqual(
      try host.references.debts(includeClosed: true).first { $0.id == masha.id }?.closed, true)
    let written = try host.transactions.entries(from: .distantPast, to: .distantFuture)
    XCTAssertEqual(
      written.map(\.transaction.kind).sorted { $0.rawValue < $1.rawValue },
      [.income, .reimbursement])
    let surplus = try XCTUnwrap(written.first { $0.transaction.kind == .income })
    XCTAssertEqual(surplus.transaction.amountE4, AmountE4(whole: 700))
    XCTAssertEqual(
      surplus.parts.first?.categoryId, try Self.surcharges(in: host.environment),
      "the 700 over are «Доплаты»")
    let back = try XCTUnwrap(written.first { $0.transaction.kind == .reimbursement })
    XCTAssertEqual(back.transaction.amountE4, AmountE4(whole: 1_700))

    host.store.undo()
    XCTAssertTrue(try host.transactions.entries(from: .distantPast, to: .distantFuture).isEmpty)
    XCTAssertEqual(
      DebtRules.balance(entries: try host.references.debtEntries(debtId: masha.id)),
      AmountE4(whole: 1_000))
  }

  /// «возврат денег 1700 долг Маша» on Маша's 1,000 ₽: the line of the debt takes 1,000 ₽ and
  /// the debt closes; the 700 ₽ above it are income in «Доплаты»; one ⌘Z takes all of it back.
  func testRepaymentOverTheDebtFromTheLineIsOneUndoStep() async throws {
    var debt: Debt?
    let host = try await EntryHost(opensDetails: false) { environment in
      try XCTUnwrap(environment.references).save(
        PaymentMethod(name: "Card", currency: .rub, isDefault: true))
      debt = try Self.lent(1_000, to: "Маша", environment: environment)
    }
    self.host = host
    let masha = try XCTUnwrap(debt)
    try host.type("возврат денег 1700 долг Маша", into: try host.line())
    host.pressReturn()

    let references = host.references
    let lines = try references.debtEntries(debtId: masha.id)
    XCTAssertEqual(
      lines.filter { $0.kind == .payment }.map(\.amountE4), [AmountE4(whole: -1_000)],
      "the debt takes what was left of it")
    XCTAssertEqual(DebtRules.balance(entries: lines), .zero)
    XCTAssertEqual(
      try references.debts(includeClosed: true).first { $0.id == masha.id }?.closed, true)
    let written = try host.transactions.entries(from: .distantPast, to: .distantFuture)
    XCTAssertEqual(written.count, 2)
    let back = try XCTUnwrap(written.first { $0.transaction.kind == .reimbursement })
    XCTAssertEqual(back.transaction.amountE4, AmountE4(whole: 1_700))
    XCTAssertEqual(back.transaction.debtId, masha.id)
    let surplus = try XCTUnwrap(written.first { $0.transaction.kind == .income })
    XCTAssertEqual(surplus.transaction.amountE4, AmountE4(whole: 700))
    XCTAssertEqual(surplus.parts.first?.categoryId, try Self.surcharges(in: host.environment))
    XCTAssertEqual(
      surplus.transaction.externalId, ReimbursementCompanions.surplusKey(of: back.id))

    XCTAssertTrue(host.store.canUndo)
    host.store.undo()
    XCTAssertTrue(try host.transactions.entries(from: .distantPast, to: .distantFuture).isEmpty)
    XCTAssertEqual(
      DebtRules.balance(entries: try references.debtEntries(debtId: masha.id)),
      AmountE4(whole: 1_000))
    XCTAssertEqual(
      try references.debts(includeClosed: true).first { $0.id == masha.id }?.closed, false)
    XCTAssertFalse(host.store.canUndo, "one step of ⌘Z")
  }

  /// Маша owes 100 $ lent at 90 ₽; 10,000 ₽ come back to the ruble card. The confirmation hands
  /// the line the repayment in dollars — 111.1111 $ at 90, the card getting 10,000 ₽ — and the
  /// line writes it: −100 $ on the debt, closed, 1,000 ₽ over it income in «Доплаты», one ⌘Z.
  func testAForeignDebtIsRepaidFromTheSheetAtTheDebtRate() async throws {
    dataDirectoryBefore = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-entry-repayment-\(UUID().uuidString)", isDirectory: true)
    self.directory = directory
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    setenv("OHMYMONEY_DATA_DIR", directory.path, 1)
    let environment = AppEnvironment()
    self.environment = environment
    await environment.start(preparing: {
      try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    })
    let store = TransactionsStore()
    store.attach(
      try XCTUnwrap(environment.transactions), references: environment.references,
      planning: environment.planning)
    let card = PaymentMethod(name: "Card", currency: .rub, isDefault: true)
    try XCTUnwrap(environment.references).save(card)
    let masha = try Self.lent(100, to: "Маша", in: .usd, environment: environment)

    // The line «возврат денег 10000»; the confirmation converts it at the debt's rate.
    let model = EntryDraftModel(environment: environment)
    model.reload()
    let parsed = CoreLineInterpreter(
      vocabulary: environment.vocabulary, calendar: environment.calendar
    ).interpret("возврат денег 10000", today: environment.today)
    model.apply(
      parsed, amount: try AmountE4(decimal: try XCTUnwrap(parsed.amount)),
      today: environment.today)
    XCTAssertEqual(model.draft.kind, .reimbursement)
    let money = try model.draftForSaving.materialize()
    let converted = try XCTUnwrap(
      MoneyBackConfirmation.debtRepayment(
        of: model.draftForSaving, money: money, debt: masha, debtRate: 90, account: card,
        received: nil, calendar: environment.calendar))
    XCTAssertEqual(converted.amount, AmountE4(raw: 1_111_111))

    model.recordMoneyBackInstead(
      .debtRepayment(masha.id), from: converted, fromNote: { $0 }, today: environment.today)
    XCTAssertNil(model.saveRefusalKey)
    let written = try XCTUnwrap(
      try EntrySave.write(model, environment: environment, store: store))

    let back = written.entry.transaction
    XCTAssertEqual(back.currency, .usd)
    XCTAssertEqual(back.amountE4, AmountE4(raw: 1_111_111))
    // The rate is what the card's rubles make of the dollars, set by hand.
    XCTAssertEqual(back.rateSource, .manual)
    XCTAssertEqual(back.accountCurrency, .rub)
    XCTAssertEqual(back.accountAmountE4, AmountE4(whole: 10_000))
    XCTAssertEqual(back.amountRubE4, AmountE4(whole: 10_000))
    let references = try XCTUnwrap(environment.references)
    let lines = try references.debtEntries(debtId: masha.id)
    XCTAssertEqual(
      lines.filter { $0.kind == .payment }.map(\.amountE4), [AmountE4(whole: -100)])
    XCTAssertEqual(
      try references.debts(includeClosed: true).first { $0.id == masha.id }?.closed, true)
    let entries = try XCTUnwrap(environment.transactions)
      .entries(from: .distantPast, to: .distantFuture)
    let surplus = try XCTUnwrap(entries.first { $0.transaction.kind == .income })
    XCTAssertEqual(surplus.transaction.currency, .rub)
    XCTAssertEqual(surplus.transaction.amountE4, AmountE4(whole: 1_000))
    XCTAssertEqual(surplus.transaction.paymentMethodId, card.id)
    XCTAssertEqual(surplus.parts.first?.categoryId, try Self.surcharges(in: environment))

    store.undo()
    XCTAssertTrue(
      try XCTUnwrap(environment.transactions).entries(from: .distantPast, to: .distantFuture)
        .isEmpty)
    XCTAssertEqual(
      DebtRules.balance(entries: try references.debtEntries(debtId: masha.id)),
      AmountE4(whole: 100))
    XCTAssertFalse(store.canUndo, "one step of ⌘Z")
  }
}
