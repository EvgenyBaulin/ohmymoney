import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// «On credit» belongs to a purchase alone: an income or a refund on credit used to open an
/// instalment debt that nothing bought.
@MainActor
final class EntryCreditKindTests: XCTestCase {
  private var references: ReferenceRepository!
  private var transactions: TransactionRepository!
  private let today = DateOnly(year: 2026, month: 9, day: 25)

  override func setUp() async throws {
    let stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    references = ReferenceRepository(writer: stack.writer)
    transactions = TransactionRepository(writer: stack.writer)
  }

  private func makeModel(_ kind: TransactionKind = .expense) -> EntryDraftModel {
    let model = EntryDraftModel(
      references: references, transactions: transactions, calendar: .utc)
    model.reload()
    model.draft.kind = kind
    model.setTotal(AmountE4(whole: 120_000))
    return model
  }

  /// The switch is offered for a purchase only.
  func testOnlyAPurchaseOffersCredit() {
    XCTAssertTrue(makeModel(.expense).offersCredit)
    for kind in [TransactionKind.income, .refund, .reimbursement] {
      XCTAssertFalse(makeModel(kind).offersCredit, kind.rawValue)
    }
  }

  /// Turned on for an income, the switch starts no plan.
  func testAnIncomeStartsNoCreditPlan() {
    for kind in [TransactionKind.income, .refund] {
      let model = makeModel(kind)
      model.startCreditPlan()
      XCTAssertNil(model.creditPlan, kind.rawValue)
      XCTAssertFalse(model.isOnCredit)
    }
  }

  /// A purchase on credit turned into an income in the panel — or by a line that says «+» —
  /// loses its plan: nothing is left to open a debt with.
  func testChangingThePurchaseToAnIncomeDropsThePlan() {
    let model = makeModel(.expense)
    model.startCreditPlan()
    XCTAssertNotNil(model.creditPlan)

    model.draft.kind = .income
    model.applyDefaults(today: today)
    XCTAssertNil(model.creditPlan)
    XCTAssertFalse(model.isOnCredit)

    let byTheLine = makeModel(.expense)
    byTheLine.startCreditPlan()
    byTheLine.apply(
      ParsedInput(kind: .refund, amount: 500, note: "boots"), amount: AmountE4(whole: 500),
      today: today)
    XCTAssertNil(byTheLine.creditPlan)
  }

  /// A plan that somehow reached the save with an income refuses it, with a reason, and the
  /// panel says so.
  func testAPlanOnAnIncomeIsRefused() {
    let model = makeModel(.expense)
    model.startCreditPlan()
    // Put straight on the draft, past the panel's own rules.
    model.draft.kind = .income
    XCTAssertEqual(model.saveRefusalKey, "entry.error.creditNotPurchase")
    XCTAssertEqual(model.shownRefusalKey, "entry.error.creditNotPurchase")
  }

  /// The commit refuses a debt opened for anything but a purchase, so nothing is written.
  func testTheCommitRefusesCreditForAnIncome() throws {
    let debt = Debt(
      direction: .iOwe, type: .installment, name: "salary", paymentsAreExpenses: false,
      origin: .purchase)
    for kind in [TransactionKind.income, .refund, .reimbursement] {
      let entry = try TransactionDraft(
        kind: kind, amount: AmountE4(whole: 1_000), creditDebtId: debt.id,
        parts: [PartDraft(amount: AmountE4(whole: 1_000))]
      ).materialize()
      XCTAssertThrowsError(
        try EntryCommit.change(
          entry: entry, openedCredit: debt, paidDebt: nil, expectedIncomeId: nil, day: today),
        kind.rawValue
      ) { error in
        XCTAssertEqual(EntryCommit.errorKey(of: error), "entry.error.creditNotPurchase")
      }
    }
  }

  private func editor(of entry: TransactionEntry) -> EntryDraftModel {
    let editor = EntryDraftModel(
      references: references, transactions: transactions, calendar: .utc,
      editsSavedOperation: true)
    editor.reload()
    editor.draft = TransactionDraft(entry: entry)
    return editor
  }

  /// An income or a refund saved on credit before the switch belonged to a purchase alone can
  /// still be edited — its note, its category — and even made the purchase it should have
  /// been. Only turning it into another kind that is never bought on credit is refused.
  func testAnOldIncomeOnCreditCanStillBeEdited() throws {
    for kind in [TransactionKind.income, .refund] {
      let entry = try TransactionDraft(
        kind: kind, amount: AmountE4(whole: 1_000), creditDebtId: UUID(),
        parts: [PartDraft(amount: AmountE4(whole: 1_000))]
      ).materialize()
      let editor = editor(of: entry)
      XCTAssertTrue(editor.isOnCredit)
      editor.draft.note = "salary, September"
      XCTAssertNil(editor.saveRefusalKey, kind.rawValue)

      editor.draft.kind = kind == .income ? .refund : .income
      XCTAssertEqual(editor.saveRefusalKey, "entry.error.creditNotPurchase", kind.rawValue)
      editor.draft.kind = .expense
      XCTAssertNil(editor.saveRefusalKey, kind.rawValue)
      editor.draft.kind = kind
      XCTAssertNil(editor.saveRefusalKey, kind.rawValue)
    }
  }

  /// A purchase on credit turned into an income in the editor is refused: the debt it joined
  /// would be left paying off an income.
  func testThePurchaseOfADebtCannotBecomeAnIncomeInTheEditor() throws {
    let entry = try TransactionDraft(
      kind: .expense, amount: AmountE4(whole: 1_000), creditDebtId: UUID(),
      parts: [PartDraft(amount: AmountE4(whole: 1_000))]
    ).materialize()
    let editor = editor(of: entry)
    XCTAssertNil(editor.saveRefusalKey)
    for kind in [TransactionKind.income, .refund, .reimbursement] {
      editor.draft.kind = kind
      XCTAssertEqual(editor.saveRefusalKey, "entry.error.creditNotPurchase", kind.rawValue)
    }
  }

  /// The reason is a caption of the catalogue in both languages.
  func testTheRefusalIsTranslated() {
    let language = AppLanguage()
    for choice in [AppLanguage.Choice.english, .russian] {
      language.choice = choice
      let key = "entry.error.creditNotPurchase"
      XCTAssertNotEqual(language(key, table: "Entry"), key, choice.rawValue)
    }
  }
}
