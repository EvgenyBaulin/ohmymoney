import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// «Оформлен: дата и сумма» of a loan: the switch, the day and the sum as the forms hold them,
/// the wizard of a new loan and «График…» of one already written, against a real database. Only a
/// loan I owe has it; neither half moves money, and saving the terms is one step of ⌘Z.
@MainActor
final class DebtOpeningFormTests: XCTestCase {
  private var environment: AppEnvironment!
  private var store: TransactionsStore!
  private var compute: ComputeStore!
  private var directory: URL!
  private var dataDirectoryBefore: String?
  private let today = DateOnly(year: 2026, month: 10, day: 11)
  private let opened = DateOnly(year: 2018, month: 3, day: 1)

  override func setUp() async throws {
    dataDirectoryBefore = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-debt-opening-\(UUID().uuidString)", isDirectory: true)
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
    compute = ComputeStore(calendar: .system, rebuildsInline: true)
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

  private var actions: DebtActions {
    DebtActions(AppDependencies(environment: environment, store: store, compute: compute))
  }

  private func storedDebts() async throws -> [Debt] {
    let stack = try XCTUnwrap(environment.stack)
    return try await DatasetRepository(writer: stack.writer).load(version: 0).debts
  }

  private var loan: Debt {
    Debt(direction: .iOwe, type: .loan, name: "Ипотека", monthlyPaymentE4: AmountE4(whole: 45_000))
  }

  func testTheSwitchSetsBothHalvesOrNeither() {
    var draft = DebtOpeningDraft()
    XCTAssertFalse(draft.known)
    XCTAssertEqual(draft.applied(to: loan, today: today).openedOn, nil)

    draft.known = true
    var made = draft.applied(to: loan, today: today)
    XCTAssertEqual(made.openedOn, today, "a day left as it is is the day shown: today")
    XCTAssertNil(made.originalAmountE4, "a sum of zero is not said")

    draft.day = opened
    draft.amount = AmountE4(whole: 4_200_000)
    made = draft.applied(to: loan, today: today)
    XCTAssertEqual(made.openedOn, opened)
    XCTAssertEqual(made.originalAmountE4, AmountE4(whole: 4_200_000))
    XCTAssertEqual(made.opening?.amountE4, AmountE4(whole: 4_200_000))

    draft.known = false
    made = draft.applied(to: made, today: today)
    XCTAssertNil(made.openedOn, "the switch off keeps neither half")
    XCTAssertNil(made.originalAmountE4)
  }

  func testOnlyALoanIOweHasAnOpening() {
    XCTAssertTrue(DebtOpeningDraft.applies(to: loan))
    let friend = Debt(direction: .iOwe, type: .personal, name: "Маша")
    let lent = Debt(direction: .owedToMe, type: .loan, name: "Займ другу")
    let card = Debt(direction: .iOwe, type: .creditCard, name: "Карта")
    var draft = DebtOpeningDraft()
    draft.known = true
    draft.day = opened
    draft.amount = AmountE4(whole: 10_000)
    for debt in [friend, lent, card] {
      XCTAssertFalse(DebtOpeningDraft.applies(to: debt), debt.name)
      XCTAssertEqual(draft.applied(to: debt, today: today), debt, "\(debt.name) was changed")
    }
  }

  func testASumBelowZeroIsNeverSaved() {
    var draft = DebtOpeningDraft()
    draft.amount = AmountE4(whole: -1)
    XCTAssertTrue(draft.isValid, "a sum hidden behind the switch off says nothing")
    draft.known = true
    XCTAssertFalse(draft.isValid)
  }

  func testTheDraftReadsWhatTheDebtSays() {
    var debt = loan
    XCTAssertFalse(DebtOpeningDraft(debt: debt).known)
    debt.originalAmountE4 = AmountE4(whole: 100)
    let amountOnly = DebtOpeningDraft(debt: debt)
    XCTAssertTrue(amountOnly.known, "either half turns the switch on")
    XCTAssertNil(amountOnly.day)
    debt.openedOn = opened
    let both = DebtOpeningDraft(debt: debt)
    XCTAssertEqual(both.day, opened)
    XCTAssertEqual(both.amount, AmountE4(whole: 100))
  }

  /// «Новый долг»: a loan carries the opening, and a sum below zero keeps the step from being
  /// left; a person's debt never takes one.
  func testTheWizardSavesTheOpeningOfALoanOnly() {
    var model = DebtWizardModel(today: today, currency: .rub)
    model.choose(.loan, today: today, language: environment.language)
    model.name = "Ипотека"
    model.amount = AmountE4(whole: 3_100_000)
    model.monthly = AmountE4(whole: 45_000)
    model.opening.known = true
    model.opening.day = opened
    model.opening.amount = AmountE4(whole: 4_200_000)
    XCTAssertTrue(model.canLeave(.amount))
    XCTAssertEqual(
      model.debt().opening,
      DebtOpening(day: opened, amountE4: AmountE4(whole: 4_200_000), currency: .rub))

    model.opening.amount = AmountE4(whole: -5)
    XCTAssertFalse(model.canLeave(.amount), "a sum below zero went on")

    model.opening.amount = AmountE4(whole: 4_200_000)
    model.choose(.personIOwe, today: today, language: environment.language)
    XCTAssertNil(model.debt().openedOn, "a person's debt took the opening of a loan")
    XCTAssertTrue(model.canLeave(.amount))
  }

  /// The loan the owner wrote down long after it was taken out: «График…» saves the opening in
  /// one step of ⌘Z, and the balance of the journal stays as it was.
  func testTheTermsOfAWrittenLoanSaveTheOpeningInOneStep() async throws {
    XCTAssertTrue(
      actions.create(
        loan, balance: AmountE4(whole: 3_100_000), on: today, moneyMovedNow: false,
        account: nil, at: environment.calendar.noon(of: today)))
    let afterCreate = try await storedDebts()
    let written = try XCTUnwrap(afterCreate.first)
    XCTAssertNil(written.openedOn)
    let balance = actions.balance(of: written)

    var draft = DebtOpeningDraft(debt: written)
    draft.known = true
    draft.day = opened
    draft.amount = AmountE4(whole: 4_200_000)
    XCTAssertTrue(actions.save(draft.applied(to: written, today: today)))
    let afterSave = try await storedDebts()
    let saved = try XCTUnwrap(afterSave.first)
    XCTAssertEqual(saved.openedOn, opened)
    XCTAssertEqual(saved.originalAmountE4, AmountE4(whole: 4_200_000))
    XCTAssertEqual(actions.balance(of: saved), balance, "the opening moved money")

    store.undo()
    let afterUndo = try await storedDebts()
    let undone = try XCTUnwrap(afterUndo.first)
    XCTAssertNil(undone.openedOn, "one ⌘Z left the opening")
    XCTAssertNil(undone.originalAmountE4)
  }
}
