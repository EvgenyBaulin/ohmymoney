import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

@MainActor
final class PlanningNamesakeActionsTests: XCTestCase {
  func testAnExplicitArchivedAliasRenameKeepsTheNameArchiveAndOtherAliases() throws {
    let stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    let planning = PlanningRepository(writer: stack.writer)
    let references = ReferenceRepository(writer: stack.writer)
    let old = PaymentMethod(name: "Old", aliases: ["Reserve", "Savings"], archived: true)
    try references.save(old)
    let store = TransactionsStore()
    store.attach(
      TransactionRepository(writer: stack.writer), references: references,
      planning: planning)
    let record = NamesakeRecord(kind: .account, id: old.id, name: old.name, archived: true)
    let change = try XCTUnwrap(
      PlanningActions.renamingArchivedFinancialRecord(
        record,
        to: "Reserve (May 2026)", spelling: "Reserve", accounts: [old], cards: [], banks: []))
    XCTAssertTrue(store.apply(change))
    let updated = try XCTUnwrap(try references.paymentMethods(includeArchived: true).first)
    XCTAssertEqual(updated.id, old.id)
    XCTAssertEqual(updated.name, "Old")
    XCTAssertTrue(updated.archived)
    XCTAssertEqual(updated.aliases, ["Reserve (May 2026)", "Savings"])
    store.undo()
    XCTAssertEqual(try references.paymentMethods(includeArchived: true), [old])
    var live = old
    live.archived = false
    XCTAssertNil(
      PlanningActions.renamingArchivedFinancialRecord(
        record, to: "Changed",
        accounts: [live], cards: [], banks: []))
  }

  func testWarningsKeepTheNamesOfCoveredPlansPrivate() {
    let income = NamesakeRecord(kind: .expectedIncome, id: UUID(), name: "Private income")
    let payment = NamesakeRecord(kind: .scheduledPayment, id: UUID(), name: "Private payment")
    let visible = NamesakeRecord(kind: .expectedIncome, id: UUID(), name: "Public income")
    let hiding = HiddenPlans(scheduled: [payment.id], expected: [income.id])
    XCTAssertEqual(
      PlanningNamesakeNotice.listed([income, payment, visible], hiding: hiding),
      [visible])
    XCTAssertEqual(
      PlanningNamesakeNotice.listed([income, payment], hiding: .none),
      [income, payment])
  }

  func testRenamingAndRestoringAnArchivedIncomeAreSeparateUndoableChoices() throws {
    let stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    let planning = PlanningRepository(writer: stack.writer)
    let settings = SettingsRepository(writer: stack.writer)
    let store = TransactionsStore()
    store.attach(
      TransactionRepository(writer: stack.writer),
      references: ReferenceRepository(writer: stack.writer), planning: planning)
    let actions = PlanningActions(
      AppDependencies(
        environment: AppEnvironment(), store: store,
        compute: ComputeStore(calendar: .utc, rebuildsInline: true)))
    let old = ExpectedIncome(name: "Project", totalE4: AmountE4(whole: 100), closed: true)
    let new = ExpectedIncome(name: "Project", totalE4: AmountE4(whole: 50))
    XCTAssertTrue(actions.save([old, new]))
    let named = NamesakeRecord(kind: .expectedIncome, id: old.id, name: old.name, archived: true)
    XCTAssertTrue(actions.renameNamesake(named, to: "Project (May 2026)", in: try planning.book()))
    let renamed = try XCTUnwrap(try planning.expected().first { $0.id == old.id })
    XCTAssertEqual(renamed.name, "Project (May 2026)")
    XCTAssertTrue(renamed.closed)
    XCTAssertEqual(try planning.expected().first { $0.id == new.id }, new)
    store.undo()
    XCTAssertEqual(try planning.expected().first { $0.id == old.id }, old)
    XCTAssertTrue(actions.restoreNamesake(named, in: try planning.book()))
    XCTAssertEqual(try planning.expected().count, 2)
    XCTAssertEqual(try planning.expected().filter { !$0.closed }.count, 2)
    store.undo()
    XCTAssertEqual(try planning.expected().first { $0.id == old.id }, old)

    let pair = Namesakes.pairKey(
      named,
      NamesakeRecord(kind: .expectedIncome, id: new.id, name: new.name))
    XCTAssertTrue(actions.hideNamesake(pair, stored: ""))
    XCTAssertEqual(try settings.string(Namesakes.hiddenPairsKey), pair)
  }

  func testRenamingAPaymentPreservesPriceHistoryAndRestoringKeepsBothNamesakes() throws {
    let stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    let planning = PlanningRepository(writer: stack.writer)
    let store = TransactionsStore()
    store.attach(
      TransactionRepository(writer: stack.writer),
      references: ReferenceRepository(writer: stack.writer), planning: planning)
    let actions = PlanningActions(
      AppDependencies(
        environment: AppEnvironment(), store: store,
        compute: ComputeStore(calendar: .utc, rebuildsInline: true)))
    let old = ScheduledPayment(name: "Cloud", amountE4: AmountE4(whole: 100), active: false)
    let new = ScheduledPayment(name: "Cloud", amountE4: AmountE4(whole: 50))
    XCTAssertTrue(actions.save(old, previous: nil))
    XCTAssertTrue(actions.save(new, previous: nil))
    var rows = PlanningRows.empty
    rows.prices = [
      SubscriptionPrice(
        paymentId: old.id,
        date: DateOnly(year: 2026, month: 5, day: 1), amountE4: AmountE4(whole: 80))
    ]
    XCTAssertTrue(store.apply(PlanningChange(upsert: rows)))
    let before = try planning.book()
    let named = NamesakeRecord(kind: .scheduledPayment, id: old.id, name: old.name, archived: true)
    XCTAssertTrue(actions.renameNamesake(named, to: "Old cloud", in: before))
    XCTAssertEqual(try planning.book().prices, before.prices)
    XCTAssertEqual(try planning.scheduled().first { $0.id == old.id }?.active, false)
    store.undo()
    XCTAssertTrue(actions.restoreNamesake(named, in: try planning.book()))
    XCTAssertEqual(try planning.scheduled().filter(\.active).count, 2)
    XCTAssertEqual(try planning.scheduled().map(\.name), ["Cloud", "Cloud"])
    store.undo()
    XCTAssertEqual(try planning.scheduled().first { $0.id == old.id }?.active, false)
  }
}
