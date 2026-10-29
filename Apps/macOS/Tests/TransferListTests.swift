import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// Transfers between the owner's accounts in the lists of operations: a row of their own on
/// their day, in no income or spending total, found by the filters of the Transactions window,
/// and deleted together with operations in one step of ⌘Z.
@MainActor
final class TransferListTests: XCTestCase {
  private let sber = PaymentMethod(name: "Sber", currency: .rub, isDefault: true)
  private let kaspi = PaymentMethod(name: "Kaspi", currency: CurrencyCode("KZT"))
  private let today = DateOnly(year: 2026, month: 9, day: 18)
  private var yesterday: DateOnly { today.adding(days: -1) }

  private func moment(_ day: DateOnly, hour: Int) -> Date {
    CalendarContext.utc.startOfDay(day).addingTimeInterval(TimeInterval(hour * 3600))
  }

  private func transfer(
    on day: DateOnly, hour: Int, amount: Int64 = 1_000, note: String? = nil
  ) -> Transfer {
    let at = moment(day, hour: hour)
    return Transfer(
      occurredAt: at, fromAccountId: sber.id, fromCurrency: .rub,
      fromAmountE4: AmountE4(whole: amount), toAccountId: kaspi.id,
      toCurrency: CurrencyCode("KZT"), toAmountE4: AmountE4(whole: amount * 5), note: note,
      createdAt: at, updatedAt: at)
  }

  private func expense(_ amount: Int64, on day: DateOnly, hour: Int) throws -> TransactionEntry {
    var draft = TransactionDraft(
      occurredAt: moment(day, hour: hour), amount: AmountE4(whole: amount), note: "coffee",
      paymentMethodId: sber.id)
    draft.normalizeSinglePart()
    return try draft.materialize(now: moment(day, hour: hour))
  }

  // MARK: - The days of Overview

  func testATransferIsARowOfItsDayInNoTotal() throws {
    let coffee = try expense(300, on: today, hour: 9)
    let moved = transfer(on: today, hour: 11)
    let alone = transfer(on: yesterday, hour: 10)
    let groups = TransactionsStore.group(
      [coffee], calendar: .utc, transfers: [alone, moved])

    XCTAssertEqual(groups.map(\.day), [today, yesterday])
    XCTAssertEqual(groups[0].transfers.map(\.id), [moved.id])
    XCTAssertEqual(groups[0].expenses.map(\.id), [coffee.id])
    // Only the coffee is spending: the transfer adds nothing.
    XCTAssertEqual(groups[0].totals, RowTotals(entries: [coffee], debts: [:]))
    XCTAssertEqual(groups[0].selectableIds, [coffee.id, moved.id])
    // A day of transfers alone is a day too, and comes to nothing.
    XCTAssertEqual(groups[1].transfers.map(\.id), [alone.id])
    XCTAssertTrue(groups[1].entries.isEmpty)
    XCTAssertEqual(groups[1].totals, .zero)
  }

  // MARK: - The Transactions table

  private func ledger(_ entries: [TransactionEntry], transfers: [Transfer]) -> Ledger {
    Ledger(
      dataset: Dataset(
        entries: entries, paymentMethods: [sber, kaspi], transfers: transfers),
      calendar: .utc)
  }

  func testTheTableListsTransfersLastInTheirDayAddingUpToNothing() throws {
    let coffee = try expense(300, on: today, hour: 9)
    let moved = transfer(on: today, hour: 11, note: "rent money")
    let alone = transfer(on: yesterday, hour: 10)
    let older = try expense(200, on: today.adding(days: -2), hour: 9)
    let ledger = ledger([coffee, older], transfers: [moved, alone])
    let listing = TransactionListing.build(
      matching: EntryFilter(period: .month(today.monthKey)), in: ledger)

    XCTAssertEqual(
      listing.sections.map { "\($0.day.iso).\($0.side.rawValue)" },
      [
        "\(today.iso).expenses", "\(today.iso).transfers", "\(yesterday.iso).transfers",
        "\(today.adding(days: -2).iso).expenses",
      ])
    let row = try XCTUnwrap(listing.sections[1].rows.first)
    XCTAssertEqual(row.id, .transfer(moved.id))
    XCTAssertEqual(row.transfer?.from, "Sber")
    XCTAssertEqual(row.transfer?.to, "Kaspi")
    XCTAssertEqual(row.transfer?.received, AmountE4(whole: 5_000))
    XCTAssertEqual(row.paymentMethod, "Sber → Kaspi")
    XCTAssertEqual(row.category, .none)
    XCTAssertEqual(listing.sections[1].totals, .zero)
    // Transfers are selected like operations and addressed as transfers.
    XCTAssertTrue(listing.visibleIds.isSuperset(of: [moved.id, alone.id, coffee.id]))
    XCTAssertEqual(listing.transferIds, [moved.id, alone.id])
    XCTAssertEqual(listing.row(of: moved.id), .transfer(moved.id))
    XCTAssertEqual(listing.row(of: coffee.id), .transaction(coffee.id))
    XCTAssertEqual(
      TransactionListing.operations(in: [.transfer(moved.id), .transaction(coffee.id)]),
      [moved.id, coffee.id])
    XCTAssertEqual(listing.owners(of: [.transfer(moved.id)]), [moved.id])
    // The first page keeps the transfers of its months.
    XCTAssertEqual(listing.latestMonths(1).transferIds, [moved.id, alone.id])
  }

  func testTheFiltersFindTransfersByAccountPeriodAndWords() throws {
    let cash = PaymentMethod(name: "Cash", kind: .cash, currency: .rub)
    let moved = transfer(on: today, hour: 11, note: "rent money")
    let lastMonth = transfer(on: today.monthKey.previous.firstDay, hour: 10)
    let ledger = Ledger(
      dataset: Dataset(
        paymentMethods: [sber, kaspi, cash], transfers: [moved, lastMonth]),
      calendar: .utc)
    func found(_ filter: EntryFilter) -> [UUID] {
      TransactionListing.transfers(matching: filter, in: ledger).map(\.id)
    }

    XCTAssertEqual(found(EntryFilter()), [moved.id, lastMonth.id])
    XCTAssertEqual(found(EntryFilter(period: .month(today.monthKey))), [moved.id])
    // The account finds a transfer from it and to it; another account finds none.
    XCTAssertEqual(found(EntryFilter(paymentMethodId: kaspi.id)), [moved.id, lastMonth.id])
    XCTAssertEqual(found(EntryFilter(paymentMethodId: sber.id)), [moved.id, lastMonth.id])
    XCTAssertEqual(found(EntryFilter(paymentMethodId: cash.id)), [])
    // Words look in the note and the names of the accounts.
    XCTAssertEqual(found(EntryFilter(text: "rent")), [moved.id])
    XCTAssertEqual(found(EntryFilter(text: "kaspi")), [moved.id, lastMonth.id])
    XCTAssertEqual(found(EntryFilter(text: "groceries")), [])
    // A transfer is neither income nor spending, and has no category or place.
    XCTAssertEqual(found(EntryFilter(kind: .expense)), [])
    XCTAssertEqual(found(EntryFilter(placeId: UUID())), [])
    XCTAssertEqual(found(EntryFilter(quality: .bad)), [])
  }

  func testTheSearchFindsATransferByWhatWasSentOrReceived() {
    let moved = transfer(on: today, hour: 11, amount: 1_234)
    let ledger = Ledger(
      dataset: Dataset(paymentMethods: [sber, kaspi], transfers: [moved]), calendar: .utc)
    func found(_ text: String) -> [UUID] {
      TransactionListing.transfers(matching: EntryFilter(text: text), in: ledger).map(\.id)
    }
    // As an operation is found by its amount.
    XCTAssertEqual(found("1234"), [moved.id])
    XCTAssertEqual(found("6170"), [moved.id])
    XCTAssertEqual(found("999"), [])
  }

  func testAnExchangeInsideOneAccountNamesTheAccountOnce() throws {
    let kzt = CurrencyCode("KZT")
    let freedom = PaymentMethod(name: "Freedom", currency: .rub, otherCurrencies: [kzt])
    let at = moment(today, hour: 11)
    let exchange = Transfer(
      occurredAt: at, fromAccountId: freedom.id, fromCurrency: .rub,
      fromAmountE4: AmountE4(whole: 1_000), toAccountId: freedom.id, toCurrency: kzt,
      toAmountE4: AmountE4(whole: 5_000), createdAt: at, updatedAt: at)
    let ledger = Ledger(
      dataset: Dataset(paymentMethods: [sber, freedom], transfers: [exchange]), calendar: .utc)
    let listing = TransactionListing.build(matching: EntryFilter(), in: ledger)
    let row = try XCTUnwrap(listing.sections.first?.rows.first)
    XCTAssertEqual(row.paymentMethod, "Freedom")
  }

  func testTheCountOfOperationsLeavesTransfersOut() throws {
    let coffee = try expense(300, on: today, hour: 9)
    let moved = transfer(on: today, hour: 11)
    let listing = TransactionListing.build(
      matching: EntryFilter(), in: ledger([coffee], transfers: [moved]))
    // «N earlier operations» counts operations: a transfer is not one.
    XCTAssertEqual(listing.operationCount, 1)
  }

  func testTheAccountFilterListsTheMainAccountFirst() {
    let alpha = PaymentMethod(name: "Alpha", currency: .rub)
    let choices = FilterChoices(Dataset(paymentMethods: [alpha, kaspi, sber]))
    XCTAssertEqual(choices.paymentMethods.map(\.name), ["Sber", "Alpha", "Kaspi"])
  }

  // MARK: - Deleting

  private struct Setup {
    let stack: DatabaseStack
    let repository: TransactionRepository
    let planning: PlanningRepository
    let store: TransactionsStore
  }

  private func setUpStore() throws -> (Setup, Box) {
    let stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    let repository = TransactionRepository(writer: stack.writer)
    let references = ReferenceRepository(writer: stack.writer)
    try references.save(sber)
    try references.save(kaspi)
    let planning = PlanningRepository(writer: stack.writer)
    let store = TransactionsStore(repository: repository, references: references)
    store.attach(repository, references: references, planning: planning)
    let box = Box()
    store.didWrite = { box.writes.append($0) }
    return (Setup(stack: stack, repository: repository, planning: planning, store: store), box)
  }

  @MainActor
  private final class Box {
    var writes: [StoreWrite] = []
  }

  /// What the lists show after the writes: the store reads its ids from here.
  private func show(_ setup: Setup) async throws {
    let dataset = try await DatasetRepository(writer: setup.stack.writer).load(version: 0)
    setup.store.show(Ledger(dataset: dataset, calendar: .utc))
  }

  private func transfers(_ setup: Setup) async throws -> [UUID] {
    try await DatasetRepository(writer: setup.stack.writer).load(version: 0).transfers.map(\.id)
  }

  /// A double click on a transfer in the days of Overview or in Transactions, or «Изменить…»
  /// in its menu, opens the transfer's own sheet with its fee — there is no operation to open
  /// in the editor, and nothing used to open at all.
  func testEditingATransferFromAListOpensItsSheetWithItsFee() async throws {
    let (setup, _) = try setUpStore()
    let moved = transfer(on: today, hour: 11)
    var fee = try expense(15, on: today, hour: 11)
    fee.transaction.externalId = TransferRules.feeKey(of: moved.id)
    let coffee = try expense(300, on: today, hour: 9)
    _ = try setup.planning.apply(
      PlanningChange(created: [fee, coffee], upsert: PlanningRows(transfers: [moved])))
    try await show(setup)

    let actions = OperationActions()
    var opened: [UUID] = []
    actions.opensEditor = { opened.append($0.id) }
    actions.edit([moved.id], store: setup.store)
    XCTAssertEqual(opened, [], "a transfer is not an operation for the editor")
    XCTAssertNil(actions.editing)
    let editing = try XCTUnwrap(actions.editingTransfer)
    XCTAssertEqual(editing.id, moved.id)
    let form = editing.form(calendar: .utc)
    XCTAssertEqual(form.previous?.id, moved.id)
    XCTAssertEqual(form.sent, AmountE4(whole: 1_000))
    XCTAssertEqual(form.fee, AmountE4(whole: 15))
    XCTAssertEqual(form.day, today)

    // An operation still opens in the editor, and the transfer's sheet stays as it was.
    actions.editingTransfer = nil
    actions.edit([coffee.id], store: setup.store)
    XCTAssertEqual(opened, [coffee.id])
    XCTAssertNil(actions.editingTransfer)
  }

  /// A screen that edits in a column (the table's editor column, the form at the side) takes a
  /// transfer as it takes an operation: the sheet stays shut.
  func testAScreenWithAnEditorColumnTakesATransferInsteadOfTheSheet() async throws {
    let (setup, _) = try setUpStore()
    let moved = transfer(on: today, hour: 11)
    _ = try setup.planning.apply(PlanningChange(upsert: PlanningRows(transfers: [moved])))
    try await show(setup)

    let actions = OperationActions()
    var taken: [UUID] = []
    actions.opensTransferEditor = { taken.append($0.id) }
    actions.edit([moved.id], store: setup.store)
    XCTAssertEqual(taken, [moved.id])
    XCTAssertNil(actions.editingTransfer, "no separate window beside an editor column")
    XCTAssertEqual(TransferEditing.find(moved.id, in: setup.store)?.id, moved.id)
    XCTAssertNil(TransferEditing.find(UUID(), in: setup.store))
  }

  func testTheEditPlaceFollowsTheEntryStyleAndTheRoom() {
    let wide = OperationEditPlace.widthForEditorColumn
    XCTAssertEqual(OperationEditPlace.choose(style: .line, width: wide), .column)
    XCTAssertEqual(OperationEditPlace.choose(style: .line, width: 0), .column)
    XCTAssertEqual(OperationEditPlace.choose(style: .line, width: wide - 1), .sheet)
    XCTAssertEqual(OperationEditPlace.choose(style: .form, width: wide - 1), .form)
    XCTAssertEqual(OperationEditPlace.choose(style: .form, width: 2_000), .form)
  }

  func testDeletingATransferWithAnOperationIsOneStepOfUndo() async throws {
    let (setup, box) = try setUpStore()
    let moved = transfer(on: today, hour: 11)
    var fee = try expense(15, on: today, hour: 11)
    fee.transaction.externalId = TransferRules.feeKey(of: moved.id)
    let coffee = try expense(300, on: today, hour: 9)
    _ = try setup.planning.apply(
      PlanningChange(created: [fee, coffee], upsert: PlanningRows(transfers: [moved])))
    try await show(setup)

    XCTAssertEqual(setup.store.transferIds(in: [moved.id, coffee.id]), [moved.id])
    XCTAssertTrue(setup.store.delete(ids: [moved.id, coffee.id]))
    // The transfer is gone, and so are the coffee and the transfer's fee.
    let afterDelete = try await transfers(setup)
    XCTAssertEqual(afterDelete, [])
    XCTAssertTrue(
      try setup.repository.entries(ids: [coffee.id, fee.id]).allSatisfy(\.transaction.isDeleted))
    XCTAssertEqual(Set(box.writes.last?.removed ?? []), [coffee.id, fee.id])
    XCTAssertTrue(box.writes.last?.planningChanged == true)

    // One ⌘Z brings back all three.
    setup.store.undo()
    let afterUndo = try await transfers(setup)
    XCTAssertEqual(afterUndo, [moved.id])
    let back = try setup.repository.entries(ids: [coffee.id, fee.id])
    XCTAssertFalse(back.contains(where: \.transaction.isDeleted))
    XCTAssertFalse(setup.store.canUndo)
  }

  /// A purchase a refund still takes money back from cannot go, as in any deletion: it stays,
  /// and everything else selected goes — in one step of ⌘Z.
  func testAMixedDeletionLeavesARefundedPurchaseAndTakesTheRest() async throws {
    let (setup, _) = try setUpStore()
    let moved = transfer(on: today, hour: 11)
    let coffee = try expense(300, on: today, hour: 9)
    let purchase = try expense(1_000, on: today, hour: 8)
    var back = TransactionDraft(
      kind: .refund, occurredAt: moment(today, hour: 10), amount: AmountE4(whole: 200),
      paymentMethodId: sber.id)
    let bought = try XCTUnwrap(purchase.parts.first)
    back.parts = [PartDraft(amount: AmountE4(whole: 200), refundOfPartId: bought.id)]
    let refund = try back.materialize(now: moment(today, hour: 10))
    _ = try setup.planning.apply(
      PlanningChange(
        created: [purchase, refund, coffee], upsert: PlanningRows(transfers: [moved])))
    try await show(setup)

    XCTAssertTrue(setup.store.delete(ids: [moved.id, purchase.id, coffee.id]))
    let afterDelete = try await transfers(setup)
    XCTAssertEqual(afterDelete, [])
    XCTAssertTrue(try XCTUnwrap(try setup.repository.entry(id: coffee.id)).transaction.isDeleted)
    XCTAssertFalse(
      try XCTUnwrap(try setup.repository.entry(id: purchase.id)).transaction.isDeleted)

    setup.store.undo()
    let afterUndo = try await transfers(setup)
    XCTAssertEqual(afterUndo, [moved.id])
    XCTAssertFalse(try XCTUnwrap(try setup.repository.entry(id: coffee.id)).transaction.isDeleted)
    XCTAssertFalse(setup.store.canUndo)
  }

  /// Without transfers the same holds: the refunded purchase stays, the rest goes.
  func testAPlainDeletionLeavesARefundedPurchaseAndTakesTheRest() async throws {
    let (setup, _) = try setUpStore()
    let coffee = try expense(300, on: today, hour: 9)
    let purchase = try expense(1_000, on: today, hour: 8)
    var back = TransactionDraft(
      kind: .refund, occurredAt: moment(today, hour: 10), amount: AmountE4(whole: 200),
      paymentMethodId: sber.id)
    let bought = try XCTUnwrap(purchase.parts.first)
    back.parts = [PartDraft(amount: AmountE4(whole: 200), refundOfPartId: bought.id)]
    let refund = try back.materialize(now: moment(today, hour: 10))
    _ = try setup.planning.apply(PlanningChange(created: [purchase, refund, coffee]))
    try await show(setup)

    XCTAssertTrue(setup.store.delete(ids: [purchase.id, coffee.id]))
    XCTAssertTrue(try XCTUnwrap(try setup.repository.entry(id: coffee.id)).transaction.isDeleted)
    XCTAssertFalse(
      try XCTUnwrap(try setup.repository.entry(id: purchase.id)).transaction.isDeleted)
  }

  /// The question before a deletion counts transfers apart from operations and names their
  /// fees, in both languages.
  func testTheQuestionSaysWhichTransfersGoAndWhatTheirFeesCameTo() async throws {
    let (setup, _) = try setUpStore()
    let moved = transfer(on: today, hour: 11)
    var fee = try expense(15, on: today, hour: 11)
    fee.transaction.externalId = TransferRules.feeKey(of: moved.id)
    let coffee = try expense(300, on: today, hour: 9)
    _ = try setup.planning.apply(
      PlanningChange(created: [fee, coffee], upsert: PlanningRows(transfers: [moved])))
    try await show(setup)

    let alone = setup.store.transferDeletion(in: [moved.id])
    XCTAssertEqual(alone.count, 1)
    XCTAssertEqual(alone.fees, AmountE4(whole: 15))
    XCTAssertEqual(setup.store.transferDeletion(in: [coffee.id]), .none)

    let environment = AppEnvironment()
    // The choice is stored for the whole test host: it goes back to what it was.
    let before = environment.language.choice
    defer { environment.language.choice = before }
    for choice in [AppLanguage.Choice.english, .russian] {
      environment.language.choice = choice
      // Transfers alone: the question counts transfers.
      let title = try XCTUnwrap(
        TransferDeletionText.title(operations: 0, alone, language: environment.language))
      XCTAssertTrue(title.contains("1"), title)
      XCTAssertFalse(title.contains("transactions."), title)
      XCTAssertNil(TransferDeletionText.title(operations: 1, alone, language: environment.language))
      // With an operation: the operations' question, and a line for the transfers and fees.
      let lines = TransferDeletionText.lines(operations: 1, alone, environment: environment)
      XCTAssertEqual(lines.count, 2, "\(lines)")
      XCTAssertFalse(lines.joined().contains("transactions."), "\(lines)")
      XCTAssertTrue(lines.joined().contains("15"), "\(lines)")
      // Alone, only the fees are said besides the title.
      XCTAssertEqual(
        TransferDeletionText.lines(operations: 0, alone, environment: environment).count, 1)
    }
  }

  /// A transfer of an account in the archive goes when a list deletes it, and the money it
  /// would take off the archived account is brought in from a live one in the same step. Сбер
  /// 100 000 ₽ and cash 5 000 ₽, 1 000 ₽ to the cash and 6 000 ₽ back, the empty cash
  /// archived: deleting the first transfer used to make «Всего» 106 000 ₽ while the money was
  /// 105 000 ₽. Now the question names it with the coffee; the write without the transfer that
  /// keeps the cash at zero is not made; with it, the coffee, the transfer and the new transfer
  /// are one step of ⌘Z, and the cash stays at zero.
  func testAListDeletionOfATransferOfAnArchivedAccountKeepsItAtZero() async throws {
    let (setup, _) = try setUpStore()
    let references = ReferenceRepository(writer: setup.stack.writer)
    var cash = PaymentMethod(name: "Cash", kind: .cash, currency: .rub)
    try references.save(cash)
    let opening = Reconciliation(
      date: today, reconciledAt: moment(today, hour: 7), actualTotalRubE4: .zero,
      kind: .accounts)
    let toCash = Transfer(
      occurredAt: moment(today, hour: 9), fromAccountId: sber.id, fromCurrency: .rub,
      fromAmountE4: AmountE4(whole: 1_000), toAccountId: cash.id, toCurrency: .rub,
      toAmountE4: AmountE4(whole: 1_000), createdAt: moment(today, hour: 9),
      updatedAt: moment(today, hour: 9))
    let fromCash = Transfer(
      occurredAt: moment(today, hour: 10), fromAccountId: cash.id, fromCurrency: .rub,
      fromAmountE4: AmountE4(whole: 6_000), toAccountId: sber.id, toCurrency: .rub,
      toAmountE4: AmountE4(whole: 6_000), createdAt: moment(today, hour: 10),
      updatedAt: moment(today, hour: 10))
    let coffee = try expense(300, on: today, hour: 8)
    _ = try setup.planning.apply(
      PlanningChange(
        created: [coffee],
        upsert: PlanningRows(
          reconciliations: [opening], transfers: [toCash, fromCash],
          reconciledBalances: [
            ReconciledBalance(
              reconciliationId: opening.id, accountId: sber.id, currency: .rub,
              actualE4: AmountE4(whole: 100_000)),
            ReconciledBalance(
              reconciliationId: opening.id, accountId: cash.id, currency: .rub,
              actualE4: AmountE4(whole: 5_000)),
          ])))
    cash.archived = true
    try references.save(cash)
    try await show(setup)

    let actions = OperationActions()
    actions.requestDeletion(of: [toCash.id, coffee.id], store: setup.store)
    let both = try XCTUnwrap(actions.confirmation)
    guard case .delete(let ids, _, _, _, _) = both else { return XCTFail("a deletion expected") }
    XCTAssertEqual(Set(ids), [coffee.id, toCash.id], "the transfer of the archived cash goes too")

    // Without the transfer that keeps the cash at zero nothing is written.
    let check = setup.store.archivedLeftovers(ofDeleting: [toCash.id, coffee.id])
    XCTAssertEqual(check.leftovers.map(\.amount), [AmountE4(whole: -1_000)])
    XCTAssertFalse(setup.store.delete(ids: [toCash.id, coffee.id]))
    let unwritten = try await transfers(setup)
    XCTAssertEqual(Set(unwritten), [toCash.id, fromCash.id])
    XCTAssertFalse(try XCTUnwrap(try setup.repository.entry(id: coffee.id)).transaction.isDeleted)

    let form = ArchivedMoneyForm(
      check: check, accounts: [sber, cash], locale: Locale(identifier: "en"))
    let settling = form.transfers(now: Date(), note: "left over")
    XCTAssertTrue(setup.store.delete(ids: [toCash.id, coffee.id], settling: settling))
    let afterDelete = try await transfers(setup)
    XCTAssertEqual(Set(afterDelete), [fromCash.id, settling[0].id])
    XCTAssertTrue(try XCTUnwrap(try setup.repository.entry(id: coffee.id)).transaction.isDeleted)
    let dataset = try await DatasetRepository(writer: setup.stack.writer).load(version: 0)
    let balances = TransactionsStore.balances(of: dataset)
    XCTAssertEqual(balances[BalanceKey(accountId: cash.id, currency: .rub)]?.amountE4, .zero)

    setup.store.undo()
    let undone = try await transfers(setup)
    XCTAssertEqual(Set(undone), [toCash.id, fromCash.id])
    XCTAssertFalse(try XCTUnwrap(try setup.repository.entry(id: coffee.id)).transaction.isDeleted)
    XCTAssertFalse(setup.store.canUndo)
  }

  /// A transfer whose fee a refund was recorded against stays when a list deletes it, as on the
  /// screen of the account, and the question says why. It used to go into the write and take
  /// the whole deletion down with it: nothing selected went, and the owner read only that the
  /// deletion failed.
  func testAListDeletionKeepsATransferWhoseFeeWasRefundedAndTakesTheRest() async throws {
    let (setup, _) = try setUpStore()
    let moved = transfer(on: today, hour: 11)
    var fee = try expense(30, on: today, hour: 11)
    fee.transaction.externalId = TransferRules.feeKey(of: moved.id)
    let coffee = try expense(300, on: today, hour: 9)
    var back = TransactionDraft(
      kind: .refund, occurredAt: moment(today, hour: 12), amount: AmountE4(whole: 10),
      paymentMethodId: sber.id)
    let charged = try XCTUnwrap(fee.parts.first)
    back.parts = [PartDraft(amount: AmountE4(whole: 10), refundOfPartId: charged.id)]
    let refund = try back.materialize(now: moment(today, hour: 12))
    _ = try setup.planning.apply(
      PlanningChange(
        created: [fee, refund, coffee], upsert: PlanningRows(transfers: [moved])))
    try await show(setup)

    let environment = AppEnvironment()
    // The choice is stored for the whole test host: it goes back to what it was.
    let before = environment.language.choice
    defer { environment.language.choice = before }
    environment.language.choice = .english
    let actions = OperationActions()
    actions.requestDeletion(of: [moved.id, coffee.id], store: setup.store)
    let confirmation = try XCTUnwrap(actions.confirmation)
    guard case .delete(let ids, _, _, _, _) = confirmation else {
      return XCTFail("a deletion expected")
    }
    XCTAssertEqual(ids, [coffee.id])
    let message = BulkConfirmationText.message(confirmation, environment: environment)
    XCTAssertTrue(message.contains(TransferText.message(.feeRefunded, environment)), message)

    XCTAssertTrue(setup.store.delete(ids: [moved.id, coffee.id]))
    XCTAssertNil(setup.store.failure, "nothing failed: the transfer was kept, not refused")
    let afterDelete = try await transfers(setup)
    XCTAssertEqual(afterDelete, [moved.id])
    XCTAssertTrue(try XCTUnwrap(try setup.repository.entry(id: coffee.id)).transaction.isDeleted)
    XCTAssertFalse(try XCTUnwrap(try setup.repository.entry(id: fee.id)).transaction.isDeleted)
  }

  /// A transfer whose fee a person gave the money back for stays when a list deletes it, as on
  /// the screen of the account, and the question says why. It used to go with its fee, closed
  /// part and all: the money back was left pointing at a fee that was no longer there. The
  /// coffee selected with it still goes, in one step of ⌘Z.
  func testAListDeletionKeepsATransferWhoseFeeWasClosedByMoneyBackAndTakesTheRest() async throws {
    let (setup, _) = try setUpStore()
    let alex = Person(name: "Alex")
    let moved = transfer(on: today, hour: 11)
    var charged = TransactionDraft(
      occurredAt: moment(today, hour: 11), amount: AmountE4(whole: 30), note: "fee",
      paymentMethodId: sber.id)
    charged.normalizeSinglePart()
    charged.parts[0].reimbursable = true
    charged.parts[0].debtorPersonId = alex.id
    var fee = try charged.materialize(now: moment(today, hour: 11))
    fee.transaction.externalId = TransferRules.feeKey(of: moved.id)
    fee.parts[0].reimbursementStatus = .returned
    var back = TransactionDraft(
      kind: .reimbursement, occurredAt: moment(today, hour: 12), amount: AmountE4(whole: 30),
      paymentMethodId: sber.id)
    back.normalizeSinglePart()
    back.parts[0].forPersonId = alex.id
    let moneyBack = try back.materialize(now: moment(today, hour: 12))
    let link = ReimbursementLink(
      reimbursementTxId: moneyBack.id, partId: fee.parts[0].id, amountE4: AmountE4(whole: 30))
    let coffee = try expense(300, on: today, hour: 9)
    try setup.repository.insert(
      HistoryBatch(
        people: [alex], entries: [fee, moneyBack, coffee], links: [link], transfers: [moved]))
    try await show(setup)

    let environment = AppEnvironment()
    // The choice is stored for the whole test host: it goes back to what it was.
    let before = environment.language.choice
    defer { environment.language.choice = before }
    environment.language.choice = .english
    let actions = OperationActions()
    actions.requestDeletion(of: [moved.id, coffee.id], store: setup.store)
    let confirmation = try XCTUnwrap(actions.confirmation)
    guard case .delete(let ids, _, _, _, _) = confirmation else {
      return XCTFail("a deletion expected")
    }
    XCTAssertEqual(ids, [coffee.id], "the transfer whose fee came back is not asked about")
    let message = BulkConfirmationText.message(confirmation, environment: environment)
    XCTAssertTrue(message.contains(TransferText.message(.feeMoneyBack, environment)), message)

    XCTAssertTrue(setup.store.delete(ids: [moved.id, coffee.id]))
    XCTAssertNil(setup.store.failure, "nothing failed: the transfer was kept, not refused")
    let afterDelete = try await transfers(setup)
    XCTAssertEqual(afterDelete, [moved.id])
    XCTAssertTrue(try XCTUnwrap(try setup.repository.entry(id: coffee.id)).transaction.isDeleted)
    let kept = try XCTUnwrap(try setup.repository.entry(id: fee.id))
    XCTAssertFalse(kept.transaction.isDeleted, "the fee stays with its transfer")
    XCTAssertEqual(kept.parts.first?.reimbursementStatus, .returned, "and stays closed")
    setup.store.undo()
    XCTAssertFalse(try XCTUnwrap(try setup.repository.entry(id: coffee.id)).transaction.isDeleted)
    XCTAssertFalse(setup.store.canUndo)
  }

  func testAPlainDeletionOfOperationsStaysAsItWas() async throws {
    let (setup, _) = try setUpStore()
    let coffee = try expense(300, on: today, hour: 9)
    try setup.repository.save(coffee)
    try await show(setup)
    XCTAssertTrue(setup.store.delete(ids: [coffee.id]))
    XCTAssertTrue(try XCTUnwrap(try setup.repository.entry(id: coffee.id)).transaction.isDeleted)
    setup.store.undo()
    XCTAssertFalse(try XCTUnwrap(try setup.repository.entry(id: coffee.id)).transaction.isDeleted)
  }

  func testALargeDeletionWithATransferGoesOffTheMainThread() async throws {
    let (setup, _) = try setUpStore()
    let moved = transfer(on: today, hour: 11)
    let start = moment(today, hour: 0)
    let rows = try (0...TransactionsStore.backgroundThreshold).map { index in
      var draft = TransactionDraft(
        occurredAt: start.addingTimeInterval(TimeInterval(index)), amount: AmountE4(whole: 1),
        note: "row \(index)", paymentMethodId: sber.id)
      draft.normalizeSinglePart()
      return try draft.materialize(now: start)
    }
    try setup.repository.insert(rows)
    _ = try setup.planning.apply(PlanningChange(upsert: PlanningRows(transfers: [moved])))
    try await show(setup)

    XCTAssertTrue(setup.store.delete(ids: rows.map(\.id) + [moved.id]))
    XCTAssertTrue(setup.store.isWritingInBackground)
    let write = try XCTUnwrap(setup.store.backgroundWrite)
    let landed = await write.value
    XCTAssertTrue(landed)
    let afterDelete = try await transfers(setup)
    XCTAssertEqual(afterDelete, [])
    XCTAssertEqual(try setup.repository.count(), 0)

    setup.store.undo()
    if let undo = setup.store.backgroundWrite { _ = await undo.value }
    let afterUndo = try await transfers(setup)
    XCTAssertEqual(afterUndo, [moved.id])
    XCTAssertEqual(try setup.repository.count(), rows.count)
  }
}
