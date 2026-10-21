import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// Transfers against a real database: money moved between accounts and between currencies of
/// one account, never income or spending; the fee as an expense in «Комиссии» that goes with
/// its transfer; one step of ⌘Z for a new transfer, an edit and a deletion; and the question
/// about a count a transfer made on its day asks.
@MainActor
final class TransfersTests: XCTestCase {
  private var environment: AppEnvironment!
  private var store: TransactionsStore!
  private var directory: URL!
  private var dataDirectoryBefore: String?

  override func setUp() async throws {
    dataDirectoryBefore = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-transfers-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    setenv("OHMYMONEY_DATA_DIR", directory.path, 1)
    environment = AppEnvironment()
    await environment.start(preparing: {
      try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    })
    store = TransactionsStore()
    store.attach(
      try XCTUnwrap(environment.transactions), references: environment.references,
      planning: environment.planning)
  }

  override func tearDown() async throws {
    if let environment { await environment.close() }
    if let dataDirectoryBefore {
      setenv("OHMYMONEY_DATA_DIR", dataDirectoryBefore, 1)
    } else {
      unsetenv("OHMYMONEY_DATA_DIR")
    }
    if let directory { try? FileManager.default.removeItem(at: directory) }
  }

  private var transfers: TransferActions {
    TransferActions(environment: environment, store: store)
  }

  // MARK: Money moves, nothing is spent

  /// Sent from one account, received on the other: both balances move, and the books hold
  /// no operation — a transfer is neither income nor spending. One step of ⌘Z takes it back.
  func testATransferMovesBothBalancesAndIsNoOperation() async throws {
    let sber = try account("Сбер", main: true)
    let tbank = try account("Т-Банк")
    try count(
      [(sber.id, .rub, 10_000), (tbank.id, .rub, 0)], at: Date().addingTimeInterval(-7_200))

    var form = TransferForm(from: sber, accounts: [sber, tbank], day: environment.today)
    form.chooseTo(tbank)
    form.sent = AmountE4(whole: 3_000)
    let saved1 = try await save(form)
    XCTAssertEqual(saved1, .done)

    let books = try await freshBooks()
    XCTAssertEqual(balance(books, sber.id, .rub), AmountE4(whole: 7_000))
    XCTAssertEqual(balance(books, tbank.id, .rub), AmountE4(whole: 3_000))
    XCTAssertEqual(books.dataset.transfers.count, 1)
    XCTAssertTrue(
      books.dataset.entries.isEmpty, "a transfer writes no operation: no income, no spending")
    XCTAssertEqual(
      RowTotals(entries: books.dataset.entries), .zero, "no total of a day counts a transfer")

    store.undo()
    let after = try await freshBooks()
    XCTAssertTrue(after.dataset.transfers.isEmpty, "one step of ⌘Z takes the transfer back")
    XCTAssertEqual(balance(after, sber.id, .rub), AmountE4(whole: 10_000))
  }

  /// An exchange inside one account of several currencies keeps both amounts as the bank
  /// showed them; the rate they imply is only shown, never used to convert.
  func testAnExchangeInsideOneAccountKeepsBothAmounts() async throws {
    let freedom = try account("Freedom", main: true, currencies: [.rub, CurrencyCode("KZT")])
    try count(
      [(freedom.id, .rub, 20_000), (freedom.id, CurrencyCode("KZT"), 0)],
      at: Date().addingTimeInterval(-7_200))

    var form = TransferForm(from: freedom, accounts: [freedom], day: environment.today)
    XCTAssertNil(form.toAccountId, "the main account does not send to itself by default")
    form.chooseTo(freedom)
    form.toCurrency = CurrencyCode("KZT")
    XCTAssertTrue(form.isExchange)
    form.sent = AmountE4(whole: 10_000)
    form.received = AmountE4(whole: 57_000)
    XCTAssertEqual(form.impliedRate, Decimal(string: "5.7"))
    let saved2 = try await save(form)
    XCTAssertEqual(saved2, .done)

    let books = try await freshBooks()
    XCTAssertEqual(balance(books, freedom.id, .rub), AmountE4(whole: 10_000))
    XCTAssertEqual(balance(books, freedom.id, CurrencyCode("KZT")), AmountE4(whole: 57_000))
    let written = try XCTUnwrap(books.dataset.transfers.first)
    XCTAssertEqual(written.fromAmountE4, AmountE4(whole: 10_000))
    XCTAssertEqual(written.toAmountE4, AmountE4(whole: 57_000))
  }

  /// The rate an exchange implies is written with the stronger currency as one unit.
  func testTheRateOfAnExchangeCountsTheStrongerCurrencyAsOne() {
    let money = MoneyFormatter(locale: Locale(identifier: "ru"))
    XCTAssertEqual(
      TransferText.rate(
        sent: AmountE4(whole: 10_000), from: .rub, received: AmountE4(whole: 57_000),
        to: CurrencyCode("KZT"), money: money),
      "1\u{00A0}₽ = 5.7\u{00A0}₸")
    XCTAssertEqual(
      TransferText.rate(
        sent: AmountE4(whole: 9_000), from: .rub, received: AmountE4(whole: 100), to: .usd,
        money: money),
      "1\u{00A0}$ = 90\u{00A0}₽")
    XCTAssertNil(
      TransferText.rate(
        sent: AmountE4(whole: 100), from: .rub, received: AmountE4(whole: 100), to: .rub,
        money: money),
      "one currency has no rate")
  }

  /// What the rules refuse, nothing written: no side chosen, one key to itself, an amount of
  /// zero, a currency the account does not hold, an archived account, a fee below zero.
  func testWhatCannotBeATransferIsRefusedAndNothingIsWritten() async throws {
    let sber = try account("Сбер", main: true)
    let old = try account("Старый", archived: true)
    let books = try await freshBooks()
    let occurredAt = Date()

    var form = TransferForm(from: nil, accounts: [], day: environment.today)
    XCTAssertEqual(refusal(form, books, occurredAt), .noFrom)

    form = TransferForm(from: sber, accounts: [sber], day: environment.today)
    XCTAssertEqual(refusal(form, books, occurredAt), .noTo)

    form.chooseTo(sber)
    form.sent = AmountE4(whole: 100)
    XCTAssertEqual(refusal(form, books, occurredAt), .issue(.sameKey))

    form.toAccountId = old.id
    XCTAssertEqual(refusal(form, books, occurredAt), .issue(.archivedAccount))

    let tbank = try account("Т-Банк")
    let fresh = try await freshBooks()
    form.chooseTo(tbank)
    form.sent = .zero
    XCTAssertEqual(refusal(form, fresh, occurredAt), .issue(.notPositive))

    form.sent = AmountE4(whole: 100)
    form.toCurrency = .usd
    form.received = AmountE4(whole: 1)
    XCTAssertEqual(refusal(form, fresh, occurredAt), .issue(.currencyNotHeld(.to)))

    form.toCurrency = .rub
    form.fee = AmountE4(whole: -5)
    XCTAssertEqual(refusal(form, fresh, occurredAt), .negativeFee)

    XCTAssertEqual(
      transfers.save(form, occurredAt: occurredAt, books: fresh), .refused(.negativeFee))
    let after = try await freshBooks()
    XCTAssertTrue(after.dataset.transfers.isEmpty)
    XCTAssertFalse(store.canUndo)
  }

  // MARK: The fee

  /// A fee is an expense from the account the money left, in the category of fees, pointing
  /// back at its transfer; the category is remembered, the next fee goes to the same one, and
  /// the transfer and its fee are one step of ⌘Z.
  func testAFeeIsAnExpenseInFeesThatGoesWithItsTransfer() async throws {
    let sber = try account("Сбер", main: true)
    let tbank = try account("Т-Банк")
    try count(
      [(sber.id, .rub, 10_000), (tbank.id, .rub, 0)], at: Date().addingTimeInterval(-7_200))

    var form = TransferForm(from: sber, accounts: [sber, tbank], day: environment.today)
    form.chooseTo(tbank)
    form.sent = AmountE4(whole: 3_000)
    form.fee = AmountE4(whole: 50)
    let saved3 = try await save(form)
    XCTAssertEqual(saved3, .done)

    let books = try await freshBooks()
    let transfer = try XCTUnwrap(books.dataset.transfers.first)
    let fee = try XCTUnwrap(TransferActions.fee(of: transfer.id, in: books.dataset.entries))
    XCTAssertEqual(fee.transaction.kind, .expense)
    XCTAssertEqual(fee.transaction.paymentMethodId, sber.id)
    XCTAssertEqual(fee.transaction.amountE4, AmountE4(whole: 50))
    XCTAssertEqual(fee.transaction.occurredAt, transfer.occurredAt)
    let categoryId = try XCTUnwrap(fee.parts.first?.categoryId)
    let category = try XCTUnwrap(books.dataset.categories.first { $0.id == categoryId })
    XCTAssertTrue(
      ["Комиссии", "Fees"].contains(category.name), "the fee went to «\(category.name)»")
    XCTAssertEqual(
      try environment.settings?.string(AccountSettings.transferFeeCategoryKey),
      categoryId.uuidString, "the category of fees is remembered")
    XCTAssertEqual(balance(books, sber.id, .rub), AmountE4(whole: 6_950), "sent and the fee")
    XCTAssertEqual(balance(books, tbank.id, .rub), AmountE4(whole: 3_000))
    XCTAssertEqual(
      RowTotals(entries: books.dataset.entries).myExpenses, AmountE4(whole: 50),
      "the fee is spending; the transfer is not")

    // The next fee goes to the same category, and makes none.
    var second = TransferForm(from: tbank, accounts: [sber, tbank], day: environment.today)
    second.chooseTo(sber)
    second.sent = AmountE4(whole: 100)
    second.fee = AmountE4(whole: 10)
    let saved4 = try await save(second)
    XCTAssertEqual(saved4, .done)
    let twice = try await freshBooks()
    let fees = twice.dataset.entries.filter {
      if case .transferFee = OperationLink(externalId: $0.transaction.externalId) { return true }
      return false
    }
    XCTAssertEqual(Set(fees.compactMap(\.parts.first?.categoryId)), [categoryId])
    XCTAssertEqual(twice.dataset.categories.count, books.dataset.categories.count)

    store.undo()
    store.undo()
    let undone = try await freshBooks()
    XCTAssertTrue(undone.dataset.transfers.isEmpty)
    XCTAssertTrue(
      undone.dataset.entries.filter { !$0.transaction.isDeleted }.isEmpty,
      "⌘Z of a transfer takes its fee along")
    XCTAssertEqual(balance(undone, sber.id, .rub), AmountE4(whole: 10_000))
  }

  /// With no category of fees yet, live or in the archive, the first fee makes one — under
  /// «Прочее» when there is one, rated bad — remembers it, and ⌘Z takes the category and the
  /// memory back with it.
  func testTheFirstFeeWithNoFeesEvenInTheArchiveMakesTheCategoryInTheSameStep() async throws {
    let sber = try account("Сбер", main: true)
    let tbank = try account("Т-Банк")
    let references = try XCTUnwrap(environment.references)
    // An archived «Комиссии» would come back with the fee rather than be made again, so
    // whatever the starter tree has for fees is renamed: none is left to find, live or archived.
    for var category in try references.categories(includeArchived: true)
    where ["комиссии", "fees"].contains(category.name.lowercased()) {
      category.name = "Банковские сборы"
      try references.save(category)
    }
    let before = try references.categories(includeArchived: true)

    var form = TransferForm(from: sber, accounts: [sber, tbank], day: environment.today)
    form.chooseTo(tbank)
    form.sent = AmountE4(whole: 500)
    form.fee = AmountE4(whole: 20)
    let saved = try await save(form)
    XCTAssertEqual(saved, .done)

    let after = try references.categories(includeArchived: true)
    XCTAssertEqual(after.count, before.count + 1, "the first fee makes its category")
    let made = try XCTUnwrap(after.first { made in !before.contains { $0.id == made.id } })
    XCTAssertEqual(made.name, environment.language("category.fees", table: "Accounts"))
    XCTAssertEqual(made.kind, .expense)
    XCTAssertEqual(made.quality, .bad)
    if let other = before.first(where: {
      $0.parentId == nil && ["прочее", "other"].contains($0.name.lowercased()) && !$0.archived
    }) {
      XCTAssertEqual(made.parentId, other.id, "under «Прочее»")
    }
    XCTAssertEqual(
      try environment.settings?.string(AccountSettings.transferFeeCategoryKey),
      made.id.uuidString)

    store.undo()
    XCTAssertEqual(
      try references.categories(includeArchived: true).count, before.count,
      "one ⌘Z takes the category made for the fee back")
    XCTAssertNil(try environment.settings?.string(AccountSettings.transferFeeCategoryKey))
  }

  /// An edit rewrites the fee in place — the same operation —, a fee taken off goes, and each
  /// edit is one step of ⌘Z that brings the transfer and its fee back as they were.
  func testAnEditRewritesTheFeeAndOneUndoBringsBothBack() async throws {
    let sber = try account("Сбер", main: true)
    let tbank = try account("Т-Банк")
    var form = TransferForm(from: sber, accounts: [sber, tbank], day: environment.today)
    form.chooseTo(tbank)
    form.sent = AmountE4(whole: 1_000)
    form.fee = AmountE4(whole: 30)
    let saved5 = try await save(form)
    XCTAssertEqual(saved5, .done)
    let before = try await freshBooks()
    let transfer = try XCTUnwrap(before.dataset.transfers.first)
    let fee = try XCTUnwrap(TransferActions.fee(of: transfer.id, in: before.dataset.entries))

    var edit = TransferForm(
      editing: transfer, fee: fee.transaction.amountE4, calendar: environment.calendar)
    XCTAssertEqual(edit.fee, AmountE4(whole: 30))
    edit.sent = AmountE4(whole: 1_500)
    edit.fee = AmountE4(whole: 45)
    let saved6 = try await save(edit)
    XCTAssertEqual(saved6, .done)
    let edited = try await freshBooks()
    XCTAssertEqual(edited.dataset.transfers.first?.fromAmountE4, AmountE4(whole: 1_500))
    XCTAssertEqual(edited.dataset.transfers.first?.toAmountE4, AmountE4(whole: 1_500))
    let rewritten = try XCTUnwrap(TransferActions.fee(of: transfer.id, in: edited.dataset.entries))
    XCTAssertEqual(rewritten.id, fee.id, "the fee is rewritten, not made again")
    XCTAssertEqual(rewritten.transaction.amountE4, AmountE4(whole: 45))

    var noFee = TransferForm(
      editing: try XCTUnwrap(edited.dataset.transfers.first), fee: rewritten.transaction.amountE4,
      calendar: environment.calendar)
    noFee.fee = .zero
    let saved7 = try await save(noFee)
    XCTAssertEqual(saved7, .done)
    let bare = try await freshBooks()
    XCTAssertNil(TransferActions.fee(of: transfer.id, in: bare.dataset.entries))

    store.undo()
    let feeBack = try await freshBooks()
    XCTAssertEqual(
      TransferActions.fee(of: transfer.id, in: feeBack.dataset.entries)?.transaction.amountE4,
      AmountE4(whole: 45), "⌘Z brings the fee taken off back")

    store.undo()
    let first = try await freshBooks()
    XCTAssertEqual(first.dataset.transfers.first?.fromAmountE4, AmountE4(whole: 1_000))
    XCTAssertEqual(
      TransferActions.fee(of: transfer.id, in: first.dataset.entries)?.transaction.amountE4,
      AmountE4(whole: 30), "one ⌘Z brings the transfer and its fee back as they were")
  }

  /// A deletion takes the fee along, and one ⌘Z brings both back.
  func testDeletingATransferTakesItsFeeAlongInOneStep() async throws {
    let sber = try account("Сбер", main: true)
    let tbank = try account("Т-Банк")
    var form = TransferForm(from: sber, accounts: [sber, tbank], day: environment.today)
    form.chooseTo(tbank)
    form.sent = AmountE4(whole: 1_000)
    form.fee = AmountE4(whole: 30)
    let saved8 = try await save(form)
    XCTAssertEqual(saved8, .done)
    let books = try await freshBooks()
    let transfer = try XCTUnwrap(books.dataset.transfers.first)

    let deleted = await transfers.delete(transfer)
    XCTAssertEqual(deleted, .done)
    let gone = try await freshBooks()
    XCTAssertTrue(gone.dataset.transfers.isEmpty)
    XCTAssertNil(TransferActions.fee(of: transfer.id, in: gone.dataset.entries))

    store.undo()
    let back = try await freshBooks()
    XCTAssertEqual(back.dataset.transfers.map(\.id), [transfer.id])
    XCTAssertNotNil(TransferActions.fee(of: transfer.id, in: back.dataset.entries))
  }

  /// Deleting reads the fee from the books as they are now, not from a list that may not have
  /// seen it yet: no fee is left behind with nothing to belong to.
  func testDeletingFindsTheFeeInTheBooksAsTheyAreNow() async throws {
    let sber = try account("Сбер", main: true)
    let tbank = try account("Т-Банк")
    let transfer = try await transferWithFee(from: sber, to: tbank, sent: 1_000, fee: 30)

    let deleted = await transfers.delete(transfer)
    XCTAssertEqual(deleted, .done)
    let gone = try await freshBooks()
    XCTAssertTrue(gone.dataset.transfers.isEmpty)
    XCTAssertTrue(
      gone.dataset.entries.filter { !$0.transaction.isDeleted }.isEmpty,
      "the fee went with its transfer")
    let again = await transfers.delete(transfer)
    XCTAssertEqual(again, .refused(.notFound), "a transfer already gone is said to be gone")
  }

  // MARK: The fee as the owner left it

  /// An edit that changes nothing the fee is made of — only the comment of the transfer —
  /// does not touch the fee: the same part, the note the owner gave it, not even written.
  func testACommentEditLeavesTheFeeAsItWas() async throws {
    let sber = try account("Сбер", main: true)
    let tbank = try account("Т-Банк")
    let transfer = try await transferWithFee(from: sber, to: tbank, sent: 1_000, fee: 30)
    let fee = try await noteTheFee(of: transfer, "paid for Anya")

    var edit = TransferForm(
      editing: transfer, fee: fee.transaction.amountE4, calendar: environment.calendar)
    edit.note = "rent"
    let saved = try await save(edit)
    XCTAssertEqual(saved, .done)
    let books = try await freshBooks()
    XCTAssertEqual(books.dataset.transfers.first?.note, "rent")
    let after = try XCTUnwrap(TransferActions.fee(of: transfer.id, in: books.dataset.entries))
    XCTAssertEqual(after.parts.map(\.id), fee.parts.map(\.id), "the fee keeps its part")
    XCTAssertEqual(after.parts.first?.note, "paid for Anya", "and the owner's note on it")
    XCTAssertEqual(
      after.transaction.updatedAt, fee.transaction.updatedAt, "the fee is not written at all")
  }

  /// An edit of the fee's amount changes the amount and nothing else the owner gave the fee:
  /// its part, its note, its category and its rating stay.
  func testAnEditOfTheFeeKeepsWhatTheOwnerGaveIt() async throws {
    let sber = try account("Сбер", main: true)
    let tbank = try account("Т-Банк")
    let transfer = try await transferWithFee(from: sber, to: tbank, sent: 1_000, fee: 30)
    let fee = try await noteTheFee(of: transfer, "paid for Anya")

    var edit = TransferForm(
      editing: transfer, fee: fee.transaction.amountE4, calendar: environment.calendar)
    edit.sent = AmountE4(whole: 1_500)
    edit.fee = AmountE4(whole: 45)
    let saved = try await save(edit)
    XCTAssertEqual(saved, .done)
    let books = try await freshBooks()
    let after = try XCTUnwrap(TransferActions.fee(of: transfer.id, in: books.dataset.entries))
    XCTAssertEqual(after.id, fee.id)
    XCTAssertEqual(after.transaction.amountE4, AmountE4(whole: 45))
    XCTAssertEqual(after.parts.map(\.id), fee.parts.map(\.id), "the fee keeps its part")
    XCTAssertEqual(after.parts.first?.amountE4, AmountE4(whole: 45))
    XCTAssertEqual(after.parts.first?.note, "paid for Anya")
    XCTAssertEqual(after.parts.first?.categoryId, fee.parts.first?.categoryId)
    XCTAssertEqual(after.parts.first?.quality, fee.parts.first?.quality)
    XCTAssertEqual(after.transaction.externalId, TransferRules.feeKey(of: transfer.id))
  }

  /// A fee a refund was recorded against: the transfer is still edited — its comment, a fee
  /// that grows —, but the fee is not taken below what came back, taken off, or deleted with
  /// its transfer: each is refused in words, and nothing is written.
  func testATransferWhoseFeeWasRefundedCanStillBeEdited() async throws {
    let sber = try account("Сбер", main: true)
    let tbank = try account("Т-Банк")
    let transfer = try await transferWithFee(from: sber, to: tbank, sent: 1_000, fee: 30)
    let written = try await freshBooks()
    let fee = try XCTUnwrap(TransferActions.fee(of: transfer.id, in: written.dataset.entries))
    try refund(fee, whole: 10)

    var edit = TransferForm(editing: transfer, fee: AmountE4(whole: 30), calendar: calendar)
    edit.note = "rent"
    let renamed = try await save(edit)
    XCTAssertEqual(renamed, .done, "a comment edit is written")

    let renamedTransfer = try await theTransfer()
    edit = TransferForm(editing: renamedTransfer, fee: AmountE4(whole: 30), calendar: calendar)
    edit.fee = AmountE4(whole: 45)
    let grown = try await save(edit)
    XCTAssertEqual(grown, .done, "the fee may grow")

    let grownTransfer = try await theTransfer()
    edit = TransferForm(editing: grownTransfer, fee: AmountE4(whole: 45), calendar: calendar)
    edit.fee = AmountE4(whole: 5)
    let shrunk = try await save(edit)
    XCTAssertEqual(shrunk, .refused(.feeRefunded), "not below the 10 that came back")
    edit.fee = .zero
    let removed = try await save(edit)
    XCTAssertEqual(removed, .refused(.feeRefunded), "not taken off")
    let kept = try await theTransfer()
    let deleted = await transfers.delete(kept)
    XCTAssertEqual(deleted, .refused(.feeRefunded), "not deleted with its transfer")

    let books = try await freshBooks()
    XCTAssertEqual(books.dataset.transfers.map(\.id), [transfer.id])
    XCTAssertEqual(
      TransferActions.fee(of: transfer.id, in: books.dataset.entries)?.transaction.amountE4,
      AmountE4(whole: 45))
    let words = TransferText.message(.feeRefunded, environment)
    XCTAssertFalse(words.isEmpty)
    XCTAssertNotEqual(words, "transfer.refusal.feeRefunded", "said in words, not by its key")
  }

  /// Money a person gave back for the fee holds its amount and its currency as they are; a
  /// fee closed by it is not taken off. A refund holds the fee from going below what came
  /// back, from another currency and from going.
  func testWhatCameBackForTheFeeHoldsIt() throws {
    var draft = TransactionDraft(amount: AmountE4(whole: 30), paymentMethodId: UUID())
    draft.normalizeSinglePart()
    draft.parts[0].reimbursable = true
    draft.parts[0].debtorPersonId = UUID()
    let fee = try draft.materialize()
    let part = try XCTUnwrap(fee.parts.first?.id)
    var more = fee
    more.transaction.amountE4 = AmountE4(whole: 45)
    more.parts[0].amountE4 = AmountE4(whole: 45)
    var dollars = fee
    dollars.transaction.currency = .usd

    XCTAssertNil(
      TransferActions.feeRefusal(fee, becoming: more, refunds: .empty, moneyBack: []),
      "nothing came back: anything goes")
    XCTAssertEqual(
      TransferActions.feeRefusal(fee, becoming: more, refunds: .empty, moneyBack: [part]),
      .feeMoneyBack)
    XCTAssertEqual(
      TransferActions.feeRefusal(fee, becoming: dollars, refunds: .empty, moneyBack: [part]),
      .feeMoneyBack)
    var moved = fee
    moved.transaction.paymentMethodId = UUID()
    XCTAssertNil(
      TransferActions.feeRefusal(fee, becoming: moved, refunds: .empty, moneyBack: [part]),
      "another account or day is no other money")
    var closed = fee
    closed.parts[0].reimbursementStatus = .returned
    XCTAssertEqual(
      TransferActions.feeRefusal(closed, becoming: nil, refunds: .empty, moneyBack: [part]),
      .feeMoneyBack, "a fee closed by money back is not taken off")

    var refundDraft = TransactionDraft(kind: .refund, amount: AmountE4(whole: 10))
    refundDraft.normalizeSinglePart()
    refundDraft.parts[0].refundOfPartId = part
    let refunds = RefundIndex(entries: [fee, try refundDraft.materialize()], debts: [:])
    XCTAssertNil(TransferActions.feeRefusal(fee, becoming: more, refunds: refunds, moneyBack: []))
    var less = fee
    less.transaction.amountE4 = AmountE4(whole: 5)
    less.parts[0].amountE4 = AmountE4(whole: 5)
    XCTAssertEqual(
      TransferActions.feeRefusal(fee, becoming: less, refunds: refunds, moneyBack: []),
      .feeRefunded)
    XCTAssertEqual(
      TransferActions.feeRefusal(fee, becoming: dollars, refunds: refunds, moneyBack: []),
      .feeRefunded)
    XCTAssertEqual(
      TransferActions.feeRefusal(fee, becoming: nil, refunds: refunds, moneyBack: []),
      .feeRefunded)
  }

  // MARK: Moving a balance away

  /// «Перевести остаток…» starts from the currency the money is in and the whole of it.
  func testMovingTheBalanceAwayStartsFromTheCurrencyThatHoldsIt() async throws {
    let sber = try account("Сбер", main: true)
    let freedom = try account("Freedom", currencies: [.rub, CurrencyCode("KZT")])
    try count(
      [(sber.id, .rub, 1_000), (freedom.id, .rub, 0), (freedom.id, CurrencyCode("KZT"), 600_000)],
      at: Date().addingTimeInterval(-7_200))
    let books = try await freshBooks()

    let form = TransferForm(
      movingBalanceOf: freedom, balances: books.balances, accounts: [sber, freedom],
      day: environment.today)
    XCTAssertEqual(form.fromAccountId, freedom.id)
    XCTAssertEqual(form.fromCurrency, CurrencyCode("KZT"), "where the money is, not the main one")
    XCTAssertEqual(form.sent, AmountE4(whole: 600_000), "the whole of it")
    XCTAssertEqual(form.toAccountId, sber.id)
    XCTAssertEqual(form.toCurrency, .rub)

    let empty = TransferForm(
      movingBalanceOf: sber, balances: .empty, accounts: [sber, freedom], day: environment.today)
    XCTAssertEqual(empty.fromCurrency, .rub, "nothing known: the main currency")
    XCTAssertEqual(empty.sent, .zero)
  }

  // MARK: Before the count

  /// Two counts on the transfer's day — Сбер at 10:00, Т-Банк at 18:00 — are asked about in
  /// turn: «Нет» to the first asks about the second, «Нет» to both puts the transfer after
  /// 18:00, and «Да» to the second puts it between them. The owner is never left unasked
  /// about a count the transfer lands inside.
  func testTwoCountsOnTheDayAreAskedAboutInTurn() async throws {
    let calendar = environment.calendar
    let today = calendar.day(of: Date())
    let yesterday = calendar.adding(days: -1, to: today)
    let early = calendar.startOfDay(yesterday).addingTimeInterval(10 * 3_600)
    let late = calendar.startOfDay(yesterday).addingTimeInterval(18 * 3_600)
    let savedAt = calendar.startOfDay(today).addingTimeInterval(9 * 3_600)
    environment.now = { savedAt }
    let sber = try account("Сбер", main: true)
    let tbank = try account("Т-Банк")
    try count([(sber.id, .rub, 10_000)], at: early)
    try count([(tbank.id, .rub, 3_000)], at: late)

    var form = TransferForm(from: sber, accounts: [sber, tbank], day: yesterday)
    form.chooseTo(tbank)
    form.sent = AmountE4(whole: 5_000)
    let occurredAt = form.occurredAt(now: savedAt, calendar: calendar)
    let books = try await freshBooks()
    let counts = askedCounts(form, occurredAt: occurredAt, books: books, now: savedAt)
    XCTAssertEqual(counts, [early, late])

    let first = CountQuestions(counts: counts, occurredAt: occurredAt, calendar: calendar)
    XCTAssertEqual(first.count, early, "the earlier count is asked first")
    guard case .ask(let second) = first.answer(wasBefore: false) else {
      return XCTFail("«Нет» to 10:00 asks about 18:00")
    }
    XCTAssertEqual(second.count, late)
    guard case .stamp(let between) = second.answer(wasBefore: true) else {
      return XCTFail("«Да» stamps")
    }
    XCTAssertGreaterThan(between, early)
    XCTAssertLessThan(between, late, "after 10:00, before 18:00")
    guard case .stamp(let before) = first.answer(wasBefore: true) else {
      return XCTFail("«Да» stamps")
    }
    XCTAssertLessThan(before, early)
    guard case .stamp(let after) = second.answer(wasBefore: false) else {
      return XCTFail("«Нет» to the last count stamps")
    }
    XCTAssertGreaterThan(after, late, "after both counts")

    XCTAssertEqual(transfers.save(form, occurredAt: after, books: books), .done)
    let saved = try await freshBooks()
    XCTAssertEqual(balance(saved, sber.id, .rub), AmountE4(whole: 5_000))
    XCTAssertEqual(
      balance(saved, tbank.id, .rub), AmountE4(whole: 8_000),
      "after 18:00 the money reaches Т-Банк's counted balance")
  }

  /// No answer moves a transfer to another day: «Да» to a count made at midnight keeps it on the
  /// count's day, «Нет» to one in the last second of the day keeps it on that day after the
  /// count, and «Да» to the second of two counts made in the first second of the day puts it
  /// between them, still on that day.
  func testTheAnswersNeverMoveATransferToAnotherDay() {
    let calendar = environment.calendar
    let today = calendar.day(of: Date())
    let yesterday = calendar.adding(days: -1, to: today)
    let midnight = calendar.startOfDay(yesterday)
    let noon = calendar.noon(of: yesterday)

    let atMidnight = CountQuestions(counts: [midnight], occurredAt: noon, calendar: calendar)
    guard case .stamp(let yes) = atMidnight.answer(wasBefore: true) else {
      return XCTFail("«Да» stamps")
    }
    XCTAssertEqual(calendar.day(of: yes), yesterday, "«Да» to a midnight count")
    XCTAssertLessThanOrEqual(yes, midnight)

    let lastSecond = calendar.startOfDay(today).addingTimeInterval(-1)
    let atLastSecond = CountQuestions(counts: [lastSecond], occurredAt: noon, calendar: calendar)
    guard case .stamp(let no) = atLastSecond.answer(wasBefore: false) else {
      return XCTFail("«Нет» to the only count stamps")
    }
    XCTAssertEqual(calendar.day(of: no), yesterday, "«Нет» to a count in the last second")
    XCTAssertGreaterThan(no, lastSecond)

    let second = midnight.addingTimeInterval(0.5)
    let two = CountQuestions(counts: [midnight, second], occurredAt: noon, calendar: calendar)
    guard case .ask(let next) = two.answer(wasBefore: false) else {
      return XCTFail("«Нет» to the first count asks about the second")
    }
    guard case .stamp(let between) = next.answer(wasBefore: true) else {
      return XCTFail("«Да» stamps")
    }
    XCTAssertEqual(calendar.day(of: between), yesterday, "between two counts of the first second")
    XCTAssertGreaterThan(between, midnight)
    XCTAssertLessThan(between, second)
  }

  /// Saved at 15:00 and dated today, after a count at 14:05: the transfer asks; «Да» puts it
  /// at 14:04:59, inside the balance counted, so the balance stays the count.
  func testATransferAfterTodaysCountAsksAndYesPutsItJustBefore() async throws {
    let calendar = environment.calendar
    let today = calendar.day(of: Date())
    let countAt = calendar.startOfDay(today).addingTimeInterval(14 * 3_600 + 5 * 60)
    let savedAt = calendar.startOfDay(today).addingTimeInterval(15 * 3_600)
    environment.now = { savedAt }
    let sber = try account("Сбер", main: true)
    let tbank = try account("Т-Банк")
    try count([(sber.id, .rub, 10_000), (tbank.id, .rub, 3_000)], at: countAt)

    var form = TransferForm(from: sber, accounts: [sber, tbank], day: today)
    form.chooseTo(tbank)
    form.sent = AmountE4(whole: 3_000)
    let books = try await freshBooks()
    let occurredAt = form.occurredAt(now: savedAt, calendar: calendar)
    XCTAssertEqual(occurredAt, savedAt, "a transfer of today happened now")
    let transfer = try XCTUnwrap(form.transfer(id: UUID(), occurredAt: occurredAt, now: savedAt))
    XCTAssertTrue(form.asksAboutTheCount(transfer, calendar: calendar))
    let asked = askedCounts(form, occurredAt: occurredAt, books: books, now: savedAt).first
    XCTAssertEqual(asked, countAt, "the transfer asks about the count of 14:05")

    let stamped = AccountReconciliation.stamped(
      occurredAt: occurredAt, count: try XCTUnwrap(asked), wasBefore: true)
    XCTAssertEqual(stamped, countAt.addingTimeInterval(-1), "«Да» is 14:04:59")
    XCTAssertEqual(transfers.save(form, occurredAt: stamped, books: books), .done)
    let after = try await freshBooks()
    XCTAssertEqual(
      balance(after, sber.id, .rub), AmountE4(whole: 10_000),
      "before the count, the transfer is inside the balance counted")
    XCTAssertEqual(balance(after, tbank.id, .rub), AmountE4(whole: 3_000))
  }

  /// Dated yesterday, after yesterday's count at 14:05, saved today: it asks too, and «Нет»
  /// puts it after the count, whatever time the day carried — noon is before 14:05.
  func testAYesterdaysTransferAfterYesterdaysCountAsksAndNoPutsItAfter() async throws {
    let calendar = environment.calendar
    let today = calendar.day(of: Date())
    let yesterday = calendar.adding(days: -1, to: today)
    let countAt = calendar.startOfDay(yesterday).addingTimeInterval(14 * 3_600 + 5 * 60)
    let savedAt = calendar.startOfDay(today).addingTimeInterval(10 * 3_600)
    environment.now = { savedAt }
    let sber = try account("Сбер", main: true)
    let tbank = try account("Т-Банк")
    try count([(sber.id, .rub, 10_000), (tbank.id, .rub, 0)], at: countAt)

    var form = TransferForm(from: sber, accounts: [sber, tbank], day: yesterday)
    form.chooseTo(tbank)
    form.sent = AmountE4(whole: 2_000)
    let occurredAt = form.occurredAt(now: savedAt, calendar: calendar)
    XCTAssertEqual(occurredAt, calendar.noon(of: yesterday), "another day is at its noon")
    let books = try await freshBooks()
    let asked = try XCTUnwrap(
      askedCounts(form, occurredAt: occurredAt, books: books, now: savedAt).first)
    XCTAssertEqual(asked, countAt)

    let stamped = AccountReconciliation.stamped(
      occurredAt: occurredAt, count: asked, wasBefore: false)
    XCTAssertGreaterThan(stamped, countAt, "«Нет» puts it after 14:05")
    XCTAssertEqual(transfers.save(form, occurredAt: stamped, books: books), .done)
    let after = try await freshBooks()
    XCTAssertEqual(balance(after, sber.id, .rub), AmountE4(whole: 8_000))
    XCTAssertEqual(balance(after, tbank.id, .rub), AmountE4(whole: 2_000))
  }

  /// Nothing to ask: a day without a count, or an edit that keeps its day and its accounts.
  func testNothingIsAskedWithoutACountOnTheDayOrForAnEditThatKeepsIt() async throws {
    let calendar = environment.calendar
    let today = calendar.day(of: Date())
    let sber = try account("Сбер", main: true)
    let tbank = try account("Т-Банк")
    var form = TransferForm(from: sber, accounts: [sber, tbank], day: today)
    form.chooseTo(tbank)
    form.sent = AmountE4(whole: 100)
    let now = Date()
    let books = try await freshBooks()
    let transfer = try XCTUnwrap(form.transfer(id: UUID(), occurredAt: now, now: now))
    XCTAssertEqual(
      askedCounts(form, occurredAt: now, books: books, now: now), [],
      "no count that day: nothing to ask")

    var edit = TransferForm(editing: transfer, fee: nil, calendar: calendar)
    edit.sent = AmountE4(whole: 200)
    let kept = edit.occurredAt(now: now.addingTimeInterval(3_600), calendar: calendar)
    XCTAssertEqual(kept, transfer.occurredAt, "an edit that keeps the day keeps the moment")
    let edited = try XCTUnwrap(edit.transfer(id: transfer.id, occurredAt: kept, now: now))
    XCTAssertFalse(edit.asksAboutTheCount(edited, calendar: calendar))
    edit.chooseTo(sber)
    let moved = try XCTUnwrap(edit.transfer(id: transfer.id, occurredAt: kept, now: now))
    XCTAssertTrue(edit.asksAboutTheCount(moved, calendar: calendar), "moved accounts ask again")
  }

  // MARK: The form

  /// A new transfer from an account goes to the main account in the same currency when it
  /// holds it; choosing another account follows the currency the money leaves in.
  func testANewTransferGoesToTheMainAccountInTheSameCurrency() throws {
    let main = PaymentMethod(name: "Сбер", currency: .rub, isDefault: true)
    let freedom = PaymentMethod(
      name: "Freedom", currency: CurrencyCode("EUR"), otherCurrencies: [.usd, .rub])
    let kaspi = PaymentMethod(name: "Kaspi", currency: CurrencyCode("KZT"))
    var form = TransferForm(
      from: freedom, accounts: [main, freedom, kaspi], day: environment.today)
    XCTAssertEqual(form.fromCurrency, CurrencyCode("EUR"))
    XCTAssertEqual(form.toAccountId, main.id)
    XCTAssertEqual(form.toCurrency, .rub, "the main account does not hold euros")
    form.fromCurrency = .rub
    form.chooseTo(freedom)
    XCTAssertEqual(form.toCurrency, .rub, "the account holds the currency sent")
    form.chooseTo(kaspi)
    XCTAssertEqual(form.toCurrency, CurrencyCode("KZT"))
    XCTAssertTrue(form.isExchange)
    form.chooseFrom(main)
    XCTAssertEqual(form.fromCurrency, .rub)
    form.sent = AmountE4(whole: 100)
    form.received = AmountE4(whole: 999)
    form.chooseTo(freedom)
    XCTAssertFalse(form.isExchange)
    XCTAssertEqual(form.receivedAmount, AmountE4(whole: 100), "one currency: sent is received")
  }

  // MARK: The time of a transfer

  /// A time the owner chose is the moment of the transfer, on its day, to the minute, and
  /// survives a change of the day; it is never asked «до сверки?» — it says itself where the
  /// transfer was. Without one the question is asked as before.
  func testAChosenTimeIsKeptAndNotAsked() async throws {
    let sber = try account("Сбер", main: true)
    let tbank = try account("Т-Банк")
    let yesterday = calendar.adding(days: -1, to: environment.today)
    let counted = calendar.moment(yesterday, hour: 14, minute: 5).addingTimeInterval(23)
    try count([(sber.id, .rub, 10_000), (tbank.id, .rub, 0)], at: counted)

    var form = TransferForm(from: sber, accounts: [sber, tbank], day: yesterday)
    form.chooseTo(tbank)
    form.sent = AmountE4(whole: 1_000)
    let now = environment.now()
    let plain = try XCTUnwrap(
      form.transfer(id: UUID(), occurredAt: form.occurredAt(now: now, calendar: calendar), now: now)
    )
    XCTAssertTrue(form.asksAboutTheCount(plain, calendar: calendar), "no time chosen: asked")

    form.time = TimeOfDay(hour: 14, minute: 5)
    let occurredAt = form.occurredAt(now: now, calendar: calendar)
    XCTAssertEqual(occurredAt, calendar.moment(yesterday, hour: 14, minute: 5))
    let chosen = try XCTUnwrap(form.transfer(id: UUID(), occurredAt: occurredAt, now: now))
    XCTAssertFalse(form.asksAboutTheCount(chosen, calendar: calendar), "a chosen time is not asked")
    let saved = try await save(form)
    XCTAssertEqual(saved, .done)
    let books = try await freshBooks()
    XCTAssertEqual(try XCTUnwrap(books.dataset.transfers.first).occurredAt, occurredAt)
    XCTAssertEqual(
      balance(books, sber.id, .rub), AmountE4(whole: 10_000),
      "14:05:00 is before the count of 14:05:23: inside the counted balance")

    // Another day keeps the time.
    form.day = calendar.adding(days: -2, to: environment.today)
    XCTAssertEqual(
      calendar.timeOfDay(form.occurredAt(now: now, calendar: calendar)),
      TimeOfDay(hour: 14, minute: 5))
  }

  // MARK: «Больше не спрашивать для этой сверки»

  /// Two counts on one day, 10:00 and 18:00, asked in turn the way the sheet asks them. «Нет»
  /// to both with «Больше не спрашивать для этой сверки» ticked on the second puts the transfer
  /// after 18:00 and keeps the answer: the next transfer of that day is dated after 18:00
  /// without a question. With the box left unticked nothing is kept.
  func testTransferQuestionsSkipRememberedCounts() async throws {
    let sber = try account("Сбер", main: true)
    let tbank = try account("Т-Банк")
    let yesterday = calendar.adding(days: -1, to: environment.today)
    let early = calendar.moment(yesterday, hour: 10, minute: 0)
    let late = calendar.moment(yesterday, hour: 18, minute: 0)
    try count([(sber.id, .rub, 10_000)], at: early)
    try count([(tbank.id, .rub, 3_000)], at: late)

    var form = TransferForm(from: sber, accounts: [sber, tbank], day: yesterday)
    form.chooseTo(tbank)
    form.sent = AmountE4(whole: 5_000)
    let now = environment.now()
    let occurredAt = form.occurredAt(now: now, calendar: calendar)
    let books = try await freshBooks()
    guard
      case .ask(let questions) = transfers.countStep(
        for: form, occurredAt: occurredAt, books: books, now: now)
    else { return XCTFail("nothing kept: the first count is asked") }
    XCTAssertEqual(questions.count, early)
    guard case .ask(let next) = transfers.answer(questions, wasBefore: false, remember: false)
    else { return XCTFail("«Нет» to 10:00 asks about 18:00") }
    XCTAssertEqual(next.count, late)
    XCTAssertTrue(environment.rememberedCountAnswers().isEmpty, "an unticked answer is not kept")
    guard case .stamp(let after) = transfers.answer(next, wasBefore: false, remember: true)
    else { return XCTFail("«Нет» to the last count stamps") }
    XCTAssertGreaterThan(after, late)
    XCTAssertEqual(transfers.save(form, occurredAt: after, books: books), .done)

    // The next transfer of that day: the kept «Нет» answers both counts, nothing is asked.
    var second = TransferForm(from: sber, accounts: [sber, tbank], day: yesterday)
    second.chooseTo(tbank)
    second.sent = AmountE4(whole: 1_000)
    let later = environment.now()
    let fresh = try await freshBooks()
    guard
      case .answered(let stamp) = transfers.countStep(
        for: second, occurredAt: second.occurredAt(now: later, calendar: calendar), books: fresh,
        now: later)
    else { return XCTFail("a kept answer answers without a question") }
    XCTAssertGreaterThan(stamp, late)
    XCTAssertEqual(calendar.day(of: stamp), yesterday)
    XCTAssertEqual(transfers.save(second, occurredAt: stamp, books: fresh), .done)
    let saved = try await freshBooks()
    let written = try XCTUnwrap(
      saved.dataset.transfers.first { $0.fromAmountE4 == AmountE4(whole: 1_000) })
    XCTAssertGreaterThan(written.occurredAt, late, "written after 18:00")
    XCTAssertEqual(
      balance(saved, tbank.id, .rub), AmountE4(whole: 9_000),
      "both transfers reach Т-Банк's counted balance")
  }

  // MARK: Transfers of an archived account

  /// A comment on a transfer of an account in the archive is saved: it moves no money. An edit
  /// of its money would leave money on the archived account, and says so before anything is
  /// written.
  func testANoteOfAnArchivedTransferCanBeEdited() async throws {
    let sber = try account("Сбер", main: true)
    var cash = try account("Наличные")
    let start = Date().addingTimeInterval(-7_200)
    try count([(sber.id, .rub, 10_000), (cash.id, .rub, 0)], at: start)
    let moved = try await transferWithFee(from: sber, to: cash, sent: 1_000, fee: 0)
    cash.archived = true
    try XCTUnwrap(environment.references).save(cash)

    let books = try await freshBooks()
    var form = TransferForm(editing: moved, fee: nil, calendar: calendar)
    form.note = "wallet"
    let occurredAt = form.occurredAt(now: environment.now(), calendar: calendar)
    let change = try XCTUnwrap(
      try? transfers.change(for: form, occurredAt: occurredAt, books: books).get())
    XCTAssertTrue(TransferActions.leftovers(of: change, books: books).leftovers.isEmpty)
    XCTAssertEqual(transfers.save(form, occurredAt: occurredAt, books: books), .done)
    let noted = try await theTransfer()
    XCTAssertEqual(noted.note, "wallet")

    form = TransferForm(editing: noted, fee: nil, calendar: calendar)
    form.sent = AmountE4(whole: 800)
    let fresh = try await freshBooks()
    let smaller = try XCTUnwrap(
      try? transfers.change(for: form, occurredAt: occurredAt, books: fresh).get())
    let check = TransferActions.leftovers(of: smaller, books: fresh)
    XCTAssertEqual(check.leftovers.map(\.amount), [AmountE4(whole: -200)])

    // A new transfer to the archived account is still refused.
    var new = TransferForm(from: sber, accounts: [sber, cash], day: environment.today)
    new.chooseTo(cash)
    new.sent = AmountE4(whole: 100)
    XCTAssertEqual(refusal(new, fresh, Date()), .issue(.archivedAccount))
  }

  /// «Сбер → Наличные» 1,000 and back 1,000, then «Наличные» archived at zero. Deleting the
  /// first transfer would take it to −1,000: the deletion asks which account covers it, and
  /// the deletion and the transfer are one step of ⌘Z. Without the transfer nothing is written.
  func testDeletingAnArchivedTransferAsksForACounterpart() async throws {
    let sber = try account("Сбер", main: true)
    var cash = try account("Наличные")
    try count(
      [(sber.id, .rub, 10_000), (cash.id, .rub, 0)], at: Date().addingTimeInterval(-7_200))
    let toCash = try await transferWithFee(from: sber, to: cash, sent: 1_000, fee: 0)
    var back = TransferForm(from: cash, accounts: [sber, cash], day: environment.today)
    back.chooseTo(sber)
    back.sent = AmountE4(whole: 1_000)
    let savedBack = try await save(back)
    XCTAssertEqual(savedBack, .done)
    cash.archived = true
    try XCTUnwrap(environment.references).save(cash)
    store.forgetUndoHistory()

    let books = try await freshBooks()
    XCTAssertEqual(balance(books, cash.id, .rub), .zero)
    let check = transfers.deletion(of: toCash, books: books)
    XCTAssertEqual(check.leftovers.map(\.amount), [AmountE4(whole: -1_000)])
    let form = ArchivedMoneyForm(
      check: check, accounts: books.dataset.paymentMethods, locale: Locale(identifier: "en"))
    XCTAssertEqual(form.rows.first?.chosen, sber.id)
    let settling = form.transfers(now: environment.now(), note: "left over")
    XCTAssertEqual(transfers.delete(toCash, books: books, settling: settling), .done)

    let after = try await freshBooks()
    XCTAssertEqual(balance(after, cash.id, .rub), .zero, "the archived account stays at zero")
    XCTAssertEqual(balance(after, sber.id, .rub), AmountE4(whole: 10_000))
    XCTAssertFalse(after.dataset.transfers.contains { $0.id == toCash.id })
    store.undo()
    let undone = try await freshBooks()
    XCTAssertTrue(undone.dataset.transfers.contains { $0.id == toCash.id })
    XCTAssertFalse(undone.dataset.transfers.contains { $0.id == settling[0].id })
  }

  /// «Перевести остаток…» on a credit card at −30,000: the form covers it from the main
  /// account, the whole of it.
  func testMovingANegativeBalanceTransfersIntoTheAccount() async throws {
    let sber = try account("Сбер", main: true)
    let credit = try account("Кредитка")
    try count(
      [(sber.id, .rub, 100_000), (credit.id, .rub, -30_000)], at: Date().addingTimeInterval(-60))
    let books = try await freshBooks()
    let form = TransferForm(
      movingBalanceOf: credit, balances: books.balances, accounts: [sber, credit],
      day: environment.today)
    XCTAssertEqual(form.fromAccountId, sber.id)
    XCTAssertEqual(form.toAccountId, credit.id)
    XCTAssertEqual(form.sent, AmountE4(whole: 30_000))
    let saved = try await save(form)
    XCTAssertEqual(saved, .done)
    let after = try await freshBooks()
    XCTAssertEqual(balance(after, credit.id, .rub), .zero)
    XCTAssertEqual(balance(after, sber.id, .rub), AmountE4(whole: 70_000))
  }

  /// A dollar credit card at −500 $ and a main account of rubles only: the form covers the
  /// 500 $ from the main account in rubles, and what left in rubles is the owner's to type —
  /// never 500 ₽ for 500 $.
  func testMovingANegativeBalanceInAnotherCurrencyLeavesTheRublesToType() async throws {
    let sber = try account("Сбер", main: true)
    let credit = try account("Card $", currencies: [.usd])
    try count(
      [(sber.id, .rub, 100_000), (credit.id, .usd, -500)], at: Date().addingTimeInterval(-60))
    let books = try await freshBooks()
    let form = TransferForm(
      movingBalanceOf: credit, balances: books.balances, accounts: [sber, credit],
      day: environment.today)
    XCTAssertEqual(form.fromAccountId, sber.id)
    XCTAssertEqual(form.fromCurrency, .rub)
    XCTAssertEqual(form.toAccountId, credit.id)
    XCTAssertEqual(form.toCurrency, .usd)
    XCTAssertTrue(form.isExchange)
    XCTAssertEqual(form.received, AmountE4(whole: 500), "the debt is what arrives")
    XCTAssertEqual(form.sent, .zero, "the rubles it cost are typed, not taken one to one")
  }

  // MARK: Helpers

  private var calendar: CalendarContext { environment.calendar }

  /// The counts saving `form` at `occurredAt`, at `now`, asks about, oldest first, as the sheet
  /// asks them with nothing kept; empty when it asks nothing.
  private func askedCounts(
    _ form: TransferForm, occurredAt: Date, books: AccountBooks, now: Date
  ) -> [Date] {
    switch transfers.countStep(
      for: form, occurredAt: occurredAt, books: books, now: now, remembered: [:])
    {
    case .none: return []
    case .ask(let questions): return questions.counts
    case .answered: return []
    }
  }

  /// A transfer with a fee, saved; as the books have it.
  private func transferWithFee(
    from: PaymentMethod, to: PaymentMethod, sent: Int64, fee: Int64
  ) async throws -> Transfer {
    var form = TransferForm(from: from, accounts: [from, to], day: environment.today)
    form.chooseTo(to)
    form.sent = AmountE4(whole: sent)
    form.fee = AmountE4(whole: fee)
    let saved = try await save(form)
    XCTAssertEqual(saved, .done)
    return try await theTransfer()
  }

  /// The one transfer of the books.
  private func theTransfer() async throws -> Transfer {
    let books = try await freshBooks()
    return try XCTUnwrap(books.dataset.transfers.first)
  }

  /// The owner's note on the part of a transfer's fee, written as the editor of an operation
  /// writes it; the fee as it is then.
  private func noteTheFee(of transfer: Transfer, _ note: String) async throws -> TransactionEntry {
    let before = try await freshBooks()
    var fee = try XCTUnwrap(TransferActions.fee(of: transfer.id, in: before.dataset.entries))
    fee.parts[0].note = note
    XCTAssertTrue(store.apply(PlanningChange(rewritten: [fee])))
    store.forgetUndoHistory()
    let after = try await freshBooks()
    return try XCTUnwrap(TransferActions.fee(of: transfer.id, in: after.dataset.entries))
  }

  /// A refund of `whole` taken back from the fee's part.
  private func refund(_ fee: TransactionEntry, whole: Int64) throws {
    var draft = TransactionDraft(
      kind: .refund, currency: fee.transaction.currency, amount: AmountE4(whole: whole),
      paymentMethodId: fee.transaction.paymentMethodId)
    draft.normalizeSinglePart()
    draft.parts[0].categoryId = fee.parts.first?.categoryId
    draft.parts[0].refundOfPartId = fee.parts.first?.id
    XCTAssertTrue(store.apply(PlanningChange(created: [try draft.materialize()])))
    store.forgetUndoHistory()
  }

  @discardableResult
  private func account(
    _ name: String, main: Bool = false, currencies: [CurrencyCode] = [.rub],
    archived: Bool = false
  ) throws -> PaymentMethod {
    let account = PaymentMethod(
      name: name, currency: currencies.first, isDefault: main, archived: archived,
      otherCurrencies: Array(currencies.dropFirst()))
    try XCTUnwrap(environment.references).save(account)
    return account
  }

  /// A count of these keys at `at`, as a reconciliation of accounts writes it.
  private func count(_ keys: [(UUID, CurrencyCode, Int64)], at: Date) throws {
    let reconciliation = Reconciliation(
      date: environment.calendar.day(of: at), reconciledAt: at, actualTotalRubE4: .zero,
      kind: .accounts)
    let balances = keys.map { id, currency, whole in
      ReconciledBalance(
        reconciliationId: reconciliation.id, accountId: id, currency: currency,
        actualE4: AmountE4(whole: whole))
    }
    XCTAssertTrue(
      store.apply(
        PlanningChange(
          upsert: PlanningRows(reconciliations: [reconciliation], reconciledBalances: balances))))
    store.forgetUndoHistory()
  }

  private func save(_ form: TransferForm) async throws -> TransferOutcome {
    let books = try await freshBooks()
    let occurredAt = form.occurredAt(now: environment.now(), calendar: environment.calendar)
    return transfers.save(form, occurredAt: occurredAt, books: books)
  }

  private func refusal(
    _ form: TransferForm, _ books: AccountBooks, _ at: Date
  )
    -> TransferRefusal?
  {
    if case .failure(let reason) = transfers.change(for: form, occurredAt: at, books: books) {
      return reason
    }
    return nil
  }

  private func freshBooks() async throws -> AccountBooks {
    let books = await transfers.books()
    return try XCTUnwrap(books)
  }

  private func balance(_ books: AccountBooks, _ id: UUID, _ currency: CurrencyCode) -> AmountE4? {
    books.balances[BalanceKey(accountId: id, currency: currency)]?.amountE4
  }
}
