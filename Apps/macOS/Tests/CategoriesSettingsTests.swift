import AppCore
import AppDatabase
import SwiftUI
import XCTest

@testable import OhMyMoney

/// The row that adds a category in Settings → Categories (`categories` — два
/// уровня, категория → подкатегория, `kind` expense/income).
@MainActor
final class CategoriesSettingsTests: XCTestCase {
  private let home = CoreKit.Category(kind: .expense, name: "Home", quality: .neutral)
  private let salary = CoreKit.Category(kind: .income, name: "Salary")
  private let old = CoreKit.Category(
    kind: .expense, name: "Old", archived: true, quality: .neutral)
  private lazy var rent = CoreKit.Category(parentId: home.id, kind: .expense, name: "Rent")
  private lazy var all = [home, salary, old, rent]

  /// Chosen under «Расходы» and kept when the switch went to «Доходы», the parent was an
  /// expense root under which an income category was saved: listed under «Дом» with a quality
  /// picker, reported by the tree as an expense, offered by no form.
  func testANewCategoryIsFiledOnlyUnderALiveRootOfItsOwnKind() {
    XCTAssertTrue(CategoriesSettingsView.acceptsParent(nil, for: .income, in: all))
    XCTAssertTrue(CategoriesSettingsView.acceptsParent(home.id, for: .expense, in: all))
    XCTAssertTrue(CategoriesSettingsView.acceptsParent(salary.id, for: .income, in: all))

    XCTAssertFalse(
      CategoriesSettingsView.acceptsParent(home.id, for: .income, in: all),
      "an income category was filed under an expense root")
    XCTAssertFalse(
      CategoriesSettingsView.acceptsParent(salary.id, for: .expense, in: all),
      "an expense category was filed under an income root")
    XCTAssertFalse(
      CategoriesSettingsView.acceptsParent(old.id, for: .expense, in: all),
      "a category was filed under an archived root")
    XCTAssertFalse(
      CategoriesSettingsView.acceptsParent(rent.id, for: .expense, in: all),
      "a third level was made under a subcategory")
    XCTAssertFalse(
      CategoriesSettingsView.acceptsParent(UUID(), for: .expense, in: all),
      "a category was filed under a parent that is not there")
  }

  /// A contribution to a goal is always good, whatever its subcategory says:
  /// the picker of Goals and of every goal's subcategory is disabled rather
  /// than silently ignored. A debt's subcategory under Loans and «Не помню» keep theirs: the
  /// quality there is only a default («оценка по умолчанию neutral»).
  func testTheQualityOfEverythingUnderGoalsIsFixedAndOnlyThere() {
    let goals = CoreKit.Category(kind: .expense, name: "Goals", systemRole: .goals)
    let bicycle = CoreKit.Category(parentId: goals.id, kind: .expense, name: "A bicycle")
    let loans = CoreKit.Category(kind: .expense, name: "Loans", systemRole: .loans)
    let mortgage = CoreKit.Category(parentId: loans.id, kind: .expense, name: "Mortgage")
    let unknown = CoreKit.Category(kind: .expense, name: "Unknown", systemRole: .unknown)
    let tree = CategoryTree([goals, bicycle, loans, mortgage, unknown, home, rent])

    XCTAssertTrue(CategoriesSettingsView.qualityIsFixed(goals, in: tree))
    XCTAssertTrue(
      CategoriesSettingsView.qualityIsFixed(bicycle, in: tree),
      "a goal's subcategory offered a quality the rules ignore")
    for free in [loans, mortgage, unknown, home, rent] {
      XCTAssertFalse(CategoriesSettingsView.qualityIsFixed(free, in: tree), free.name)
    }
  }

  /// A name is saved trimmed, and only when it says something new: « Дом » is «Дом», an empty
  /// field keeps the name that is stored, and a name typed back to what it was writes nothing.
  func testARenameIsSavedTrimmedAndOnlyWhenItChangesTheName() {
    XCTAssertEqual(CategoriesSettingsView.renamed(home, to: "  Жильё \n")?.name, "Жильё")
    XCTAssertEqual(CategoriesSettingsView.renamed(home, to: "Жильё")?.id, home.id)
    XCTAssertNil(CategoriesSettingsView.renamed(home, to: "   "), "an empty name was saved")
    XCTAssertNil(
      CategoriesSettingsView.renamed(home, to: "Home"), "the same name was written again")
    XCTAssertNil(
      CategoriesSettingsView.renamed(home, to: " Home "), "the same name, padded, was written")
  }

  /// The list was made of sections, a category as the header of its own: the header stuck to
  /// the top while its subcategories scrolled under it, with a background of its own. One flat
  /// list now — each category, its subcategories right after it, then the subcategories whose
  /// parent is in the archive after a caption.
  func testTheListIsFlatEachCategoryFollowedByItsSubcategories() {
    let food = CoreKit.Category(kind: .expense, name: "Food")
    let groceries = CoreKit.Category(parentId: food.id, kind: .expense, name: "Groceries")
    let stray = CoreKit.Category(parentId: old.id, kind: .expense, name: "Stray")
    let subcategories = [rent, groceries]
    let children: (CoreKit.Category) -> [CoreKit.Category] = { parent in
      subcategories.filter { $0.parentId == parent.id }
    }

    XCTAssertEqual(
      CategoriesSettingsView.rows(roots: [home, food], children: children, orphans: [stray]),
      [
        .category(home, isChild: false), .category(rent, isChild: true),
        .category(food, isChild: false), .category(groceries, isChild: true),
        .orphansCaption, .category(stray, isChild: true),
      ])
    XCTAssertEqual(
      CategoriesSettingsView.rows(roots: [home], children: children, orphans: []),
      [.category(home, isChild: false), .category(rent, isChild: true)],
      "a caption with nothing under it")
  }

  func testTheRefusalIsSaidInBothLanguages() {
    let environment = AppEnvironment()
    for choice in [AppLanguage.Choice.english, .russian] {
      environment.language.choice = choice
      let key = "categories.add.parentRefused"
      XCTAssertNotEqual(environment.language(key, table: "Settings"), key, "\(choice)")
    }
  }

  /// Under the picker of the cashback category: how much cashback to expect is set by the
  /// cards' rules — said in both languages, pointing at where the rules are.
  func testTheCashbackRulesHint() {
    let environment = AppEnvironment()
    let before = environment.language.choice
    defer { environment.language.choice = before }
    let expected: [AppLanguage.Choice: String] = [
      .english: "Settings → Accounts", .russian: "«Настройки → Счета»",
    ]
    for (choice, words) in expected {
      environment.language.choice = choice
      let key = CategoriesSettingsView.cashbackRulesHintKey
      let text = environment.language(key, table: "Settings")
      XCTAssertNotEqual(text, key, "\(choice)")
      XCTAssertTrue(text.contains(words), "\(choice): \(text)")
    }
  }
}

/// The monthly limit typed into a category's row in Settings → Категории, an amount edited in
/// place in Planning, and the one order the lists of limits share.
@MainActor
final class CategoryLimitsTests: XCTestCase {
  private var store: TransactionsStore!
  private var references: ReferenceRepository!
  private var planning: PlanningRepository!
  private let month = MonthKey(year: 2026, month: 9)
  private let food = CoreKit.Category(kind: .expense, name: "Food", quality: .neutral)
  private let taxi = CoreKit.Category(kind: .expense, name: "Taxi", quality: .neutral)

  override func setUp() async throws {
    let stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    references = ReferenceRepository(writer: stack.writer)
    planning = PlanningRepository(writer: stack.writer)
    store = TransactionsStore()
    store.attach(
      TransactionRepository(writer: stack.writer), references: references, planning: planning)
    try references.save(food)
    try references.save(taxi)
  }

  private var tree: CategoryTree { CategoryTree([food, taxi]) }

  /// The field of the row as the view commits it: the book read from the database first.
  @discardableResult
  private func type(_ text: String, in category: CoreKit.Category) throws -> String? {
    CategoriesSettingsView.commitLimit(
      text, for: category.id, budgets: try planning.budgets(), tree: tree, month: month,
      store: store)
  }

  private func limit(of category: CoreKit.Category) throws -> Budget? {
    LimitRules.categoryLimit(of: category.id, in: try planning.budgets())
  }

  func testAnAmountTypedInARowSetsTheLimitAndOneUndoTakesItBack() throws {
    XCTAssertNil(try type("5,000", in: food))
    let set = try XCTUnwrap(try limit(of: food))
    XCTAssertEqual(set.amountE4, AmountE4(whole: 5_000))
    XCTAssertEqual(set.startMonth, month)
    XCTAssertEqual(set.scope, .category)
    XCTAssertNil(try limit(of: taxi), "the limit went to another row")

    store.undo()
    XCTAssertEqual(try planning.budgets(), [])
    XCTAssertFalse(store.canUndo)
  }

  /// A new amount and then an empty field are two commits: two steps of ⌘Z, each taking back
  /// its own. The new amount keeps the limit and its rollover and starts the carry again.
  func testEachCommitIsOneStepANewAmountKeepsTheLimitAndAnEmptyFieldDeletesIt() throws {
    let june = MonthKey(year: 2026, month: 6)
    let stored = Budget(
      scope: .category, categoryId: food.id, amountE4: AmountE4(whole: 5_000), rollover: true,
      startMonth: june)
    var rows = PlanningRows.empty
    rows.budgets = [stored]
    XCTAssertTrue(store.apply(PlanningChange(upsert: rows)))

    XCTAssertNil(try type("7000", in: food))
    let raised = try XCTUnwrap(try limit(of: food))
    XCTAssertEqual(raised.id, stored.id)
    XCTAssertEqual(raised.amountE4, AmountE4(whole: 7_000))
    XCTAssertTrue(raised.rollover)
    XCTAssertEqual(raised.startMonth, month, "a new amount starts the carry again")

    XCTAssertNil(try type("   ", in: food))
    XCTAssertNil(try limit(of: food), "an empty field keeps the limit")

    store.undo()
    XCTAssertEqual(try limit(of: food), raised)
    store.undo()
    XCTAssertEqual(try limit(of: food), stored)
  }

  /// Zero is refused, never taken for «no limit»; text that is no amount is refused too; the
  /// same amount typed again writes nothing. None of them leaves a step of ⌘Z.
  func testZeroTextThatIsNoAmountAndTheSameAmountWriteNothing() throws {
    XCTAssertEqual(try type("0", in: food), "limit.issue.nonPositive")
    XCTAssertEqual(try type("-100", in: food), "limit.issue.nonPositive")
    XCTAssertEqual(try type("five", in: food), "limits.unreadable")
    XCTAssertEqual(try planning.budgets(), [])
    XCTAssertFalse(store.canUndo)

    XCTAssertNil(try type("1,500", in: food))
    XCTAssertNil(try type("1500", in: food))
    XCTAssertEqual(try type("0", in: food), "limit.issue.nonPositive")
    XCTAssertEqual(try limit(of: food)?.amountE4, AmountE4(whole: 1_500), "zero deleted it")
    store.undo()
    XCTAssertFalse(store.canUndo, "the same amount wrote a step of its own")
  }

  /// A system category takes no limit: its row has no field, and a write is refused anyway.
  func testASystemCategoryHasNoFieldAndIsRefused() throws {
    let goals = CoreKit.Category(kind: .expense, name: "Goals", systemRole: .goals)
    try references.save(goals)
    let tree = CategoryTree([food, taxi, goals])
    XCTAssertFalse(LimitRules.offersLimit(on: goals.id, tree: tree))
    XCTAssertEqual(
      CategoriesSettingsView.commitLimit(
        "100", for: goals.id, budgets: [], tree: tree, month: month, store: store),
      "limit.issue.systemCategory")
    XCTAssertEqual(try planning.budgets(), [])
  }

  /// «Сверка», as the reconciliation remembers it, takes no limit, nor does anything under it:
  /// its row has no field and a write is refused with its own words; a limit 1.1 stored there
  /// can be deleted, not changed. «Food» beside it is untouched.
  func testTheReconciliationRowHasNoLimitField() throws {
    let reconcile = CoreKit.Category(kind: .expense, name: "Сверка", quality: .neutral)
    let small = CoreKit.Category(parentId: reconcile.id, kind: .expense, name: "Мелочи")
    try references.save(reconcile)
    try references.save(small)
    let tree = CategoryTree([food, taxi, reconcile, small])
    let limitless: Set<UUID> = [reconcile.id]
    for category in [reconcile, small] {
      XCTAssertFalse(
        LimitRules.offersLimit(on: category.id, tree: tree, limitless: limitless), category.name)
      XCTAssertEqual(
        CategoriesSettingsView.commitLimit(
          "5000", for: category.id, budgets: try planning.budgets(), tree: tree, month: month,
          store: store, limitless: limitless),
        "limit.issue.reconciliationCategory")
    }
    XCTAssertTrue(LimitRules.offersLimit(on: food.id, tree: tree, limitless: limitless))
    XCTAssertEqual(try planning.budgets(), [])
    XCTAssertFalse(store.canUndo)

    let stored = Budget(
      scope: .category, categoryId: reconcile.id, amountE4: AmountE4(whole: 5_000),
      startMonth: month)
    var rows = PlanningRows.empty
    rows.budgets = [stored]
    XCTAssertTrue(store.apply(PlanningChange(upsert: rows)))
    XCTAssertEqual(
      LimitWrites.changeAmount(
        of: stored, typed: "6000", budgets: try planning.budgets(), tree: tree, month: month,
        store: store, limitless: limitless),
      "limit.issue.reconciliationCategory")
    XCTAssertEqual(try planning.budgets(), [stored])
    XCTAssertNil(
      CategoriesSettingsView.commitLimit(
        "", for: reconcile.id, budgets: try planning.budgets(), tree: tree, month: month,
        store: store, limitless: limitless))
    XCTAssertEqual(try planning.budgets(), [], "an empty field did not delete the stored limit")

    let environment = AppEnvironment()
    for choice in [AppLanguage.Choice.english, .russian] {
      environment.language.choice = choice
      let key = "limit.issue.reconciliationCategory"
      XCTAssertNotEqual(environment.language(key, table: "Planning"), key, "\(choice)")
    }
  }

  /// In place in Planning: Enter over a new amount is one step of ⌘Z; an empty field puts the
  /// amount back and writes nothing.
  func testAnAmountEditedInPlaceIsOneStepAndAnEmptyFieldWritesNothing() throws {
    let friends = Budget(scope: .forWhom, forWhom: .friends, amountE4: AmountE4(whole: 3_000))
    var rows = PlanningRows.empty
    rows.budgets = [friends]
    XCTAssertTrue(store.apply(PlanningChange(upsert: rows)))
    func edit(_ text: String) throws -> String? {
      LimitWrites.changeAmount(
        of: friends, typed: text, budgets: try planning.budgets(), tree: tree, month: month,
        store: store)
    }

    XCTAssertNil(try edit(""))
    XCTAssertEqual(try planning.budgets(), [friends])
    XCTAssertEqual(try edit("0"), "limit.issue.nonPositive")
    XCTAssertEqual(try edit("4k"), nil)
    XCTAssertEqual(try planning.budgets().first?.amountE4, AmountE4(whole: 4_000))
    store.undo()
    XCTAssertEqual(try planning.budgets(), [friends])
  }

  /// The Planning block, the sheet of all limits and the Overview card read one order and the
  /// number from the settings; a limit of an archived category is in none of them.
  func testTheListsShowTheTopOfOneOrderAndHideAnArchivedCategory() {
    let old = CoreKit.Category(kind: .expense, name: "Old", archived: true)
    let books = CoreKit.Category(kind: .expense, name: "Books")
    let budgets = [food, taxi, old, books].map { category in
      Budget(scope: .category, categoryId: category.id, amountE4: AmountE4(whole: 1_000))
    }
    var book = PlanningBook(budgets: budgets)
    book.settings.limitsTopN = 2
    let today = DateOnly(year: 2026, month: 9, day: 19)
    let snapshot = DataSnapshot.build(
      dataset: Dataset(categories: [food, taxi, old, books], planning: book), calendar: .utc,
      today: today, context: SnapshotContext(), version: DataVersion(load: 0))
    let environment = AppEnvironment()

    let top = LimitLists.ranked(snapshot, environment)
    XCTAssertEqual(top.total, 3, "the archived category's limit was counted")
    XCTAssertEqual(
      top.shown.map { $0.budget.categoryId }, [books.id, food.id],
      "nothing is spent: by name, and only the top two")
    let all = LimitLists.ranked(snapshot, environment, all: true).shown
    XCTAssertEqual(all.map { $0.budget.categoryId }, [books.id, food.id, taxi.id])
  }

  /// The field of a row as the database has its limit now.
  private func shown(_ category: CoreKit.Category) throws -> String {
    try limit(of: category).map { AmountField.text(for: $0.amountE4) } ?? ""
  }

  /// What the row's field writes with: the book read from the database first, as the view does.
  private func write(_ category: CoreKit.Category) -> (String) -> Bool {
    { text in
      CategoriesSettingsView.commitLimit(
        text, for: category.id, budgets: (try? self.planning.budgets()) ?? [], tree: self.tree,
        month: self.month, store: self.store) == nil
    }
  }

  /// Return writes the amount and lets go of the field; ⌘Z then takes the write back, the field
  /// shows the amount it took back, and leaving the field writes nothing. The field used to
  /// keep the cursor and what it had written: leaving it wrote that again — the undo silently
  /// redone — or, with the typing taken back in the field instead, wrote the old amount anew,
  /// the carry since June lost.
  func testReturnThenUndoThenLeavingTheFieldWritesNothing() throws {
    let june = MonthKey(year: 2026, month: 6)
    let stored = Budget(
      scope: .category, categoryId: food.id, amountE4: AmountE4(whole: 24_000), rollover: true,
      startMonth: june)
    var rows = PlanningRows.empty
    rows.budgets = [stored]
    XCTAssertTrue(store.apply(PlanningChange(upsert: rows)))

    var draft = LimitFieldDraft(showing: try shown(food))
    draft.type("25000")
    XCTAssertEqual(
      draft.submit(shown: try shown(food), write: write(food)), .written,
      "a write that landed lets go of the field, so ⌘Z reaches the write")
    XCTAssertEqual(try limit(of: food)?.amountE4, AmountE4(whole: 25_000))
    draft.storedChanged(to: try shown(food))
    XCTAssertEqual(draft.text, try shown(food))

    store.undo()
    draft.storedChanged(to: try shown(food))
    XCTAssertEqual(draft.text, try shown(food), "the field kept the amount ⌘Z took back")
    XCTAssertEqual(draft.leave(shown: try shown(food), write: write(food)), .nothing)
    XCTAssertEqual(try limit(of: food), stored, "leaving the field wrote the limit again")

    store.undo()
    XCTAssertEqual(try planning.budgets(), [])
    XCTAssertFalse(store.canUndo, "leaving the field left a step of its own")
  }

  /// A refused amount stays next to its reason while the owner is in the field; once the
  /// field is left — or Esc is pressed — it shows the limit the database has. An amount typed
  /// and left without Return is written, as when the tab or the window goes away.
  func testARefusedAmountGivesWayToTheStoredOneWhenTheFieldIsLeft() throws {
    XCTAssertNil(try type("15,000", in: food))
    var draft = LimitFieldDraft(showing: try shown(food))

    draft.type("0")
    XCTAssertEqual(draft.submit(shown: try shown(food), write: write(food)), .refused)
    XCTAssertEqual(draft.text, "0", "Return took away what was typed next to its reason")
    XCTAssertEqual(draft.leave(shown: try shown(food), write: write(food)), .refused)
    XCTAssertEqual(draft.text, try shown(food), "the field went on saying 0 over a limit")

    draft.type("9")
    draft.cancel(shown: try shown(food))
    XCTAssertEqual(draft.text, try shown(food))
    XCTAssertEqual(draft.leave(shown: try shown(food), write: write(food)), .nothing)
    XCTAssertEqual(try limit(of: food)?.amountE4, AmountE4(whole: 15_000))

    draft.type("16000")
    XCTAssertEqual(draft.leave(shown: try shown(food), write: write(food)), .written)
    XCTAssertEqual(try limit(of: food)?.amountE4, AmountE4(whole: 16_000))
  }

  /// The reason under the list names the row it is about.
  func testARefusalInSettingsNamesItsCategory() {
    let environment = AppEnvironment()
    let drinks = CoreKit.Category(parentId: food.id, kind: .expense, name: "Drinks")
    let tree = CategoryTree([food, taxi, drinks])
    for choice in [AppLanguage.Choice.english, .russian] {
      environment.language.choice = choice
      let reason = environment.language("limit.issue.nonPositive", table: "Planning")
      let text = CategoriesSettingsView.limitRefusal(
        "limit.issue.nonPositive", for: drinks.id, tree: tree, environment)
      XCTAssertTrue(text.contains("Food › Drinks"), "\(choice): \(text)")
      XCTAssertTrue(text.contains(reason), "\(choice): \(text)")
    }
  }

  /// The Overview card shares the order and the number of Planning, but lists five at most:
  /// with «all» and many limits it grew, and the cards beside it grew with it.
  func testTheCardListsTheTopOfTheOrderFiveAtMost() {
    let categories = (1...7).map { CoreKit.Category(kind: .expense, name: "Limit \($0)") }
    let budgets = categories.map {
      Budget(scope: .category, categoryId: $0.id, amountE4: AmountE4(whole: 1_000))
    }
    func card(_ topN: Int?) -> (shown: Int, rest: Int) {
      var book = PlanningBook(budgets: budgets)
      book.settings.limitsTopN = topN
      let snapshot = DataSnapshot.build(
        dataset: Dataset(categories: categories, planning: book), calendar: .utc,
        today: DateOnly(year: 2026, month: 9, day: 19), context: SnapshotContext(),
        version: DataVersion(load: 0))
      let lines = LimitsCard.lines(snapshot, AppEnvironment())
      return (lines.shown.count, lines.rest.count)
    }
    XCTAssertTrue(card(nil) == (5, 2), "«all» listed every limit in the card: \(card(nil))")
    XCTAssertTrue(card(10) == (5, 2), "\(card(10))")
    XCTAssertTrue(card(3) == (3, 4), "\(card(3))")
  }

  /// A new amount typed in place starts the carry again: while the field is open, the row says
  /// so with what is carried now — the button shows the amount available, the field the limit.
  func testAnAmountEditedInPlaceSaysWhatCarryANewAmountStartsAgain() throws {
    let budget = Budget(
      scope: .category, categoryId: food.id, amountE4: AmountE4(whole: 24_000), rollover: true,
      startMonth: MonthKey(year: 2026, month: 6))
    var line = LimitLine(
      budget: budget, month: month, amount: budget.amountE4, carry: AmountE4(whole: 3_513),
      spent: .zero, spentShareBp: 0, elapsedShareBp: 6_000, paceBp: 0, planned: .zero,
      forecast: .zero, lowData: false, status: .ok)
    let environment = AppEnvironment()
    for choice in [AppLanguage.Choice.english, .russian] {
      environment.language.choice = choice
      let note = try XCTUnwrap(LimitRow.carryNote(line, environment), "\(choice)")
      XCTAssertTrue(
        note.contains(environment.money.rounded(AmountE4(whole: 3_513))), "\(choice): \(note)")
    }
    line.carry = .zero
    XCTAssertNil(LimitRow.carryNote(line, environment), "nothing carried, nothing to lose")
  }

  /// The picker writes its numbers the one way numbers are written: a number stored by hand as
  /// 1000 reads «1,000», in both languages.
  func testHowManyLimitsToShowIsWrittenLikeEveryOtherNumber() {
    let environment = AppEnvironment()
    for choice in [AppLanguage.Choice.english, .russian] {
      environment.language.choice = choice
      XCTAssertEqual(PlanningSettingsView.choiceTitle(5, environment.money), "5", "\(choice)")
      XCTAssertEqual(
        PlanningSettingsView.choiceTitle(1_000, environment.money), "1,000", "\(choice)")
    }
  }

  func testHowManyLimitsToShowKeepsANumberWrittenElsewhere() {
    XCTAssertEqual(PlanningSettingsView.limitsTopNChoices(including: 5), [3, 5, 10, 20])
    XCTAssertEqual(PlanningSettingsView.limitsTopNChoices(including: nil), [3, 5, 10, 20])
    XCTAssertEqual(PlanningSettingsView.limitsTopNChoices(including: 7), [3, 5, 7, 10, 20])

    let before = PlanningSettings()
    var all = before
    all.limitsTopN = nil
    XCTAssertEqual(
      PlanningSettingsView.changedKeys(before: before.storedValues, after: all.storedValues),
      [PlanningSettings.limitsTopNKey], "«all» wrote more than its key")
    XCTAssertEqual(all.storedValues[PlanningSettings.limitsTopNKey], "all")
  }

  /// Every word the limits added says something in both languages — the refusals included,
  /// which are looked up by keys built at run time.
  func testTheWordsOfTheLimitsAreThereInBothLanguages() {
    let environment = AppEnvironment()
    let planningKeys =
      [
        "limits.all", "limits.allTitle", "limits.unreadable", "limits.amount.placeholder",
        "limits.amount.help", "limits.amount.edit", "limits.amount.carryRestart",
        "overview.limitsMore",
        "form.limit.rolloverHint", "form.notSaved",
      ] + BudgetIssue.allCases.map { "limit.issue.\($0.rawValue)" }
    let settingsKeys = [
      "categories.limit.placeholder", "categories.limit.rollover", "categories.limit.hint",
      "categories.limit.refused",
      "settings.planning.includesGoals", "settings.planning.includesGoalsHint",
      "settings.planning.limits", "settings.planning.limitsTopN",
      "settings.planning.limitsTopN.all", "settings.planning.limitsHint",
    ]
    for choice in [AppLanguage.Choice.english, .russian] {
      environment.language.choice = choice
      for (table, keys) in [("Planning", planningKeys), ("Settings", settingsKeys)] {
        for key in keys {
          XCTAssertNotEqual(environment.language(key, table: table), key, "\(choice) \(table)")
        }
      }
    }
    // The switch of goal money keeps its key, and says where the money is.
    environment.language.choice = .russian
    XCTAssertEqual(
      environment.language("settings.planning.includesGoals", table: "Settings"),
      "Деньги целей лежат на счетах в сводке")
    environment.language.choice = .english
    XCTAssertEqual(
      environment.language("settings.planning.includesGoals", table: "Settings"),
      "Goal money sits on accounts in the summary")
  }
}

/// The limit field of a category's row in a window, typed into the way the keyboard types:
/// what reaches the database, and when.
@MainActor
final class CategoryLimitFieldTests: XCTestCase {
  @Observable
  @MainActor
  final class Row {
    var stored: Budget?
    var shown = true
    var written: [String] = []
  }

  private struct Host: View {
    let row: Row

    var body: some View {
      if row.shown {
        CategoryLimitField(
          stored: row.stored,
          commit: { text in
            row.written.append(text)
            return true
          }, cancel: {})
      } else {
        Text(verbatim: "—")
      }
    }
  }

  private func limit(_ whole: Int64, id: UUID) -> Budget {
    Budget(
      id: id, scope: .category, categoryId: UUID(), amountE4: AmountE4(whole: whole),
      rollover: true, startMonth: MonthKey(year: 2026, month: 6))
  }

  private func settle(_ seconds: TimeInterval = 0.2) {
    RunLoop.current.run(until: Date().addingTimeInterval(seconds))
  }

  private func textFields(in view: NSView) -> [NSTextField] {
    view.subviews.flatMap { subview -> [NSTextField] in
      ((subview as? NSTextField).map { [$0] } ?? []) + textFields(in: subview)
    }
  }

  private func show(_ row: Row) throws -> (NSWindow, NSTextField) {
    let window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: 300, height: 120), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(
      rootView: Host(row: row).appDependencies(.forTests(AppEnvironment())))
    window.makeKeyAndOrderFront(nil)
    settle(0.3)
    let field = try XCTUnwrap(
      textFields(in: try XCTUnwrap(window.contentView)).first(where: \.isEditable))
    return (window, field)
  }

  /// Return writes once and lets go of the cursor, so ⌘Z reaches the write instead of the
  /// typing in the field; the amount ⌘Z puts back shows at once, and leaving writes nothing.
  func testReturnLetsGoOfTheFieldAndWhatUndoPutsBackIsNotWrittenAgain() throws {
    let id = UUID()
    let row = Row()
    row.stored = limit(24_000, id: id)
    let (window, field) = try show(row)
    defer {
      window.contentView = nil
      window.close()
    }

    XCTAssertTrue(window.makeFirstResponder(field))
    let editor = try XCTUnwrap(window.firstResponder as? NSTextView, "the field editor")
    editor.selectAll(nil)
    editor.insertText("25000", replacementRange: editor.selectedRange())
    settle()
    editor.insertNewline(nil)
    settle()
    XCTAssertEqual(row.written, ["25000"])
    XCTAssertFalse(
      window.firstResponder is NSTextView, "the field kept the cursor after Return")

    row.stored = limit(25_000, id: id)
    settle()
    row.stored = limit(24_000, id: id)
    settle()
    XCTAssertEqual(field.stringValue, AmountField.text(for: AmountE4(whole: 24_000)))

    XCTAssertTrue(window.makeFirstResponder(field))
    settle()
    XCTAssertTrue(window.makeFirstResponder(nil))
    settle()
    XCTAssertEqual(row.written, ["25000"], "leaving the field wrote again")
  }

  /// An amount typed without Return is written when the row goes away — the tab switched to
  /// income, the window closed — as the name in the same row is.
  func testAnAmountTypedWithoutReturnIsWrittenWhenTheRowGoesAway() throws {
    let row = Row()
    let (window, field) = try show(row)
    defer {
      window.contentView = nil
      window.close()
    }

    XCTAssertTrue(window.makeFirstResponder(field))
    let editor = try XCTUnwrap(window.firstResponder as? NSTextView, "the field editor")
    editor.insertText("15000", replacementRange: editor.selectedRange())
    settle()
    row.shown = false
    settle()
    XCTAssertEqual(row.written, ["15000"], "the typed limit was lost with its row")
  }
}
