import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// Goals in the archive, in Planning: «Вернуть» brings a goal back as the database holds it —
/// not as the snapshot on screen last saw it — and one ⌘Z puts it in the archive again.
@MainActor
final class GoalsArchiveTests: XCTestCase {
  private var environment: AppEnvironment!
  private var store: TransactionsStore!
  private var compute: ComputeStore!
  private var directory: URL!
  private var dataDirectoryBefore: String?

  override func setUp() async throws {
    dataDirectoryBefore = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-goals-archive-\(UUID().uuidString)", isDirectory: true)
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

  private var references: ReferenceRepository { environment.references! }

  private var actions: PlanningActions {
    PlanningActions(AppDependencies(environment: environment, store: store, compute: compute))
  }

  /// «Вернуть» makes the goal live with what the database holds now — a target changed after
  /// the block last read it stays — and one step of ⌘Z sends it back to the archive.
  func testBringingAGoalBackIsOneStepOfUndo() throws {
    let trip = Goal(name: "Отпуск", targetE4: AmountE4(whole: 100_000), archived: true)
    try references.save(trip)
    var changed = trip
    changed.targetE4 = AmountE4(whole: 150_000)
    try references.save(changed)

    XCTAssertTrue(GoalsBlock.restore(trip.id, with: actions, references: references))
    let back = try XCTUnwrap(try references.goals().first { $0.id == trip.id })
    XCTAssertEqual(back.targetE4, AmountE4(whole: 150_000), "an older copy was written back")
    XCTAssertTrue(store.canUndo)

    store.undo()
    XCTAssertTrue(try references.goals().isEmpty, "⌘Z left the goal out of the archive")
    XCTAssertEqual(
      try references.goals(includeArchived: true).first { $0.id == trip.id }?.targetE4,
      AmountE4(whole: 150_000))
  }

  /// «Сохранить» of a new goal named as one in the archive — «отпуск» for «Отпуск» — saves
  /// nothing: the form says «Такая цель есть в архиве» and offers «Вернуть» and «Удалить
  /// старую…». It used to bring the archived goal back silently, and what was typed was lost.
  func testANewGoalWithTheNameOfAnArchivedOneIsNotSaved() throws {
    let trip = Goal(name: "Отпуск", targetE4: AmountE4(whole: 100_000), archived: true)
    try references.save(trip)

    let typed = Goal(name: "отпуск", targetE4: AmountE4(whole: 50_000))
    let goals = try references.goals(includeArchived: true)
    XCTAssertEqual(GoalForm.namesake(of: typed, isNew: true, among: goals)?.id, trip.id)
    XCTAssertNil(GoalForm.namesake(of: typed, isNew: false, among: goals), "an edit was stopped")
    XCTAssertFalse(GoalForm.save(typed, isNew: true, with: actions, references: references))
    let all = try references.goals(includeArchived: true)
    XCTAssertEqual(all.map(\.id), [trip.id], "a second goal of the same name was made")
    XCTAssertEqual(all.first?.archived, true, "the archived goal came back without being asked")
    XCTAssertEqual(all.first?.targetE4, AmountE4(whole: 100_000))
    XCTAssertFalse(store.canUndo, "a step of ⌘Z was left for nothing written")
  }

  /// «Вернуть» under the name: the archived goal back as it was — its target, not the one
  /// typed —, one step of ⌘Z; no second goal is made.
  func testRestoreFromTheForm() throws {
    let trip = Goal(name: "Отпуск", targetE4: AmountE4(whole: 100_000), archived: true)
    try references.save(trip)
    let typed = Goal(name: " отпуск ", targetE4: AmountE4(whole: 50_000))
    let namesake = try XCTUnwrap(
      GoalForm.namesake(
        of: typed, isNew: true, among: try references.goals(includeArchived: true)))

    XCTAssertTrue(GoalsBlock.restore(namesake.id, with: actions, references: references))

    let all = try references.goals(includeArchived: true)
    XCTAssertEqual(all.map(\.id), [trip.id])
    XCTAssertEqual(all.first?.archived, false)
    XCTAssertEqual(all.first?.targetE4, AmountE4(whole: 100_000))
    XCTAssertNil(GoalForm.namesake(of: typed, isNew: true, among: all), "the note stayed")
    store.undo()
    XCTAssertEqual(try references.goals(includeArchived: true).map(\.archived), [true])
  }

  private var version = 0

  /// The data the actions read, as the pipeline would show it.
  @discardableResult
  private func show() async throws -> DataSnapshot {
    let stack = try XCTUnwrap(environment.stack)
    let dataset = try await DatasetRepository(writer: stack.writer).load(version: 0)
    version += 1
    let snapshot = DataSnapshot.build(
      dataset: dataset, calendar: environment.calendar, today: environment.today,
      context: SnapshotContext(rubPerUnit: [:]), version: DataVersion(load: version))
    compute.applyLight(snapshot)
    return snapshot
  }

  private func parts(of entries: [TransactionEntry]) throws -> [TransactionPart] {
    let ids = entries.map(\.transaction.id)
    return try XCTUnwrap(environment.transactions).entries(ids: ids).flatMap(\.parts)
      .sorted { $0.id.uuidString < $1.id.uuidString }
  }

  /// The archived «Отпуск» with 20,000 put in on 10.03 and 10,000 on 10.04. «Удалить старую»:
  /// the goal goes, both contributions stay as they were under «Цели → Отпуск» — the same money,
  /// category and day, no goal —, its subcategory goes to the archive; one step of ⌘Z. The new
  /// «Отпуск» of 150,000 is then saved and has put in nothing. Two ⌘Z bring everything back.
  func testDeleteTheOldOneThenSave() async throws {
    let card = PaymentMethod(name: "Карта", isDefault: true)
    try references.save(card)
    try await show()
    XCTAssertTrue(actions.save(Goal(name: "Отпуск", targetE4: AmountE4(whole: 100_000))))
    var old = try XCTUnwrap(try references.goals().first)
    let subcategory = try XCTUnwrap(old.subcategoryId, "the goal got no subcategory")
    try await show()
    let calendar = environment.calendar
    for (month, amount) in [(3, 20_000), (4, 10_000)] {
      let day = calendar.startOfDay(DateOnly(year: 2026, month: month, day: 10))
        .addingTimeInterval(12 * 3600)
      XCTAssertTrue(
        actions.move(
          old, amount: AmountE4(whole: Int64(amount)), on: day, paymentMethodId: card.id,
          withdraw: false))
    }
    XCTAssertTrue(actions.archive(old))
    old = try XCTUnwrap(try references.goals(includeArchived: true).first { $0.id == old.id })
    let contributions = try XCTUnwrap(environment.transactions)
      .entries(from: .distantPast, to: .distantFuture)
    XCTAssertEqual(contributions.count, 2)
    let before = try parts(of: contributions)
    XCTAssertEqual(before.map(\.goalId), [old.id, old.id])
    try await show()

    let typed = Goal(
      name: "отпуск", targetE4: AmountE4(whole: 150_000),
      targetDate: DateOnly(year: 2027, month: 6, day: 1),
      monthlyPlanE4: AmountE4(whole: 10_000))
    XCTAssertFalse(GoalForm.save(typed, isNew: true, with: actions, references: references))

    XCTAssertEqual(actions.deleteArchived(old), .deleted)
    XCTAssertFalse(try references.goals(includeArchived: true).contains { $0.id == old.id })
    let after = try parts(of: contributions)
    XCTAssertEqual(after.map(\.goalId), [nil, nil])
    XCTAssertEqual(after.map(\.amountRubE4), before.map(\.amountRubE4))
    XCTAssertEqual(after.map(\.categoryId), before.map(\.categoryId))
    XCTAssertEqual(after.map(\.quality), before.map(\.quality))
    let categories = try references.categories(includeArchived: true)
    XCTAssertEqual(categories.first { $0.id == subcategory }?.archived, true)
    XCTAssertNil(
      GoalForm.namesake(
        of: typed, isNew: true, among: try references.goals(includeArchived: true)))

    try await show()
    let saving = GoalForm.saving(
      typed, hasDate: true, original: nil, today: environment.today)
    XCTAssertTrue(GoalForm.save(saving, isNew: true, with: actions, references: references))
    let fresh = try XCTUnwrap(try references.goals().first)
    XCTAssertNotEqual(fresh.subcategoryId, subcategory, "the new goal took the old money in")
    XCTAssertEqual(fresh.planStartMonth, environment.today.monthKey)
    let snapshot = try await show()
    let status = try XCTUnwrap(
      GoalRules.statuses(goals: [fresh], ledger: snapshot.ledger, today: environment.today)
        .first)
    XCTAssertEqual(status.saved, .zero)

    store.undo()
    XCTAssertTrue(try references.goals(includeArchived: true).isEmpty)
    store.undo()
    let back = try XCTUnwrap(try references.goals(includeArchived: true).first)
    XCTAssertEqual(back.id, old.id)
    XCTAssertTrue(back.archived)
    XCTAssertEqual(try parts(of: contributions).map(\.goalId), [old.id, old.id])
    XCTAssertEqual(
      try references.categories(includeArchived: true).first { $0.id == subcategory }?.archived,
      false)
  }

  /// The archived «Отпуск» has 5,000 put in but filed under «Еда», outside «Цели». Let go of
  /// the goal, that part would turn into ordinary spending and start moving money, so the goal
  /// is not deleted: the form says «Эту цель не удалить…» under the name, «Удалить старую…» is
  /// no longer offered — only «Вернуть» — and nothing is written, no step of ⌘Z.
  func testAGoalWithAContributionOutsideGoalsIsNotDeleted() throws {
    let card = PaymentMethod(name: "Карта", isDefault: true)
    try references.save(card)
    let food = CoreKit.Category(kind: .expense, name: "Еда")
    try references.save(food)
    let trip = Goal(name: "Отпуск", targetE4: AmountE4(whole: 100_000), archived: true)
    try references.save(trip)
    var draft = TransactionDraft(
      occurredAt: environment.calendar.startOfDay(DateOnly(year: 2026, month: 3, day: 10))
        .addingTimeInterval(12 * 3600),
      amount: AmountE4(whole: 5_000), paymentMethodId: card.id)
    draft.parts = [PartDraft(categoryId: food.id, amount: AmountE4(whole: 5_000), goalId: trip.id)]
    let entry = try draft.materialize()
    let transactions = try XCTUnwrap(environment.transactions)
    try transactions.insert([entry])

    XCTAssertEqual(actions.deletion(of: trip), .failure(.contributionsOutsideGoals(1)))
    XCTAssertEqual(actions.deleteArchived(trip), .refused(.contributionsOutsideGoals(1)))
    let note = GoalForm.deletionNote(refusedBy: .contributionsOutsideGoals(1))
    XCTAssertEqual(note, "form.goal.delete.outsideGoals")
    XCTAssertFalse(GoalForm.offersDeletion(after: note), "«Удалить старую…» stayed on offer")
    XCTAssertTrue(GoalForm.offersDeletion(after: nil))
    XCTAssertTrue(
      GoalForm.offersDeletion(after: GoalForm.deletionNote(refusedBy: nil)),
      "a write that did not land took the button away for good")

    let stored = try XCTUnwrap(
      try references.goals(includeArchived: true).first { $0.id == trip.id }, "the goal went")
    XCTAssertTrue(stored.archived)
    let parts = try transactions.entries(ids: [entry.transaction.id]).flatMap(\.parts)
    XCTAssertEqual(parts.map(\.goalId), [trip.id])
    XCTAssertEqual(parts.map(\.categoryId), [food.id])
    XCTAssertFalse(store.canUndo, "a step of ⌘Z was left for nothing written")
  }

  /// «Удалить…» on the row of the archived «Отпуск» in Planning (20,000 put in on 10.03 and
  /// 10,000 on 10.04) asks the question of the form; «Удалить» deletes the goal, keeps both
  /// contributions as they were under «Цели → Отпуск» — money, category, quality — with no goal,
  /// and archives its subcategory; the row is gone from the archive. One ⌘Z brings back all of
  /// it, and the goal is saved 30,000 again.
  func testDeleteFromAnArchivedRow() async throws {
    let card = PaymentMethod(name: "Карта", isDefault: true)
    try references.save(card)
    try await show()
    XCTAssertTrue(actions.save(Goal(name: "Отпуск", targetE4: AmountE4(whole: 100_000))))
    var old = try XCTUnwrap(try references.goals().first)
    let subcategory = try XCTUnwrap(old.subcategoryId, "the goal got no subcategory")
    try await show()
    let calendar = environment.calendar
    for (month, amount) in [(3, 20_000), (4, 10_000)] {
      let day = calendar.startOfDay(DateOnly(year: 2026, month: month, day: 10))
        .addingTimeInterval(12 * 3600)
      XCTAssertTrue(
        actions.move(
          old, amount: AmountE4(whole: Int64(amount)), on: day, paymentMethodId: card.id,
          withdraw: false))
    }
    XCTAssertTrue(actions.archive(old))
    old = try XCTUnwrap(try references.goals(includeArchived: true).first { $0.id == old.id })
    let contributions = try XCTUnwrap(environment.transactions)
      .entries(from: .distantPast, to: .distantFuture)
    let before = try parts(of: contributions)
    XCTAssertEqual(before.map(\.goalId), [old.id, old.id])
    let shown = try await show()
    XCTAssertEqual(shown.dataset.goals.filter(\.archived).map(\.id), [old.id], "no archived row")

    XCTAssertEqual(GoalsBlock.askToDelete(old, with: actions), .ask)
    XCTAssertNil(GoalsBlock.delete(old, with: actions), "the goal was not deleted")

    XCTAssertFalse(try references.goals(includeArchived: true).contains { $0.id == old.id })
    let after = try parts(of: contributions)
    XCTAssertEqual(after.map(\.goalId), [nil, nil])
    XCTAssertEqual(after.map(\.amountRubE4), before.map(\.amountRubE4))
    XCTAssertEqual(after.map(\.categoryId), before.map(\.categoryId))
    XCTAssertEqual(after.map(\.quality), before.map(\.quality))
    XCTAssertEqual(
      try references.categories(includeArchived: true).first { $0.id == subcategory }?.archived,
      true)
    let without = try await show()
    XCTAssertTrue(without.dataset.goals.filter(\.archived).isEmpty, "the row stayed")

    store.undo()
    var back = try XCTUnwrap(try references.goals(includeArchived: true).first { $0.id == old.id })
    XCTAssertTrue(back.archived)
    XCTAssertEqual(try parts(of: contributions).map(\.goalId), [old.id, old.id])
    XCTAssertEqual(
      try references.categories(includeArchived: true).first { $0.id == subcategory }?.archived,
      false)
    let restored = try await show()
    XCTAssertEqual(restored.dataset.goals.filter(\.archived).map(\.id), [old.id])
    back.archived = false
    let status = try XCTUnwrap(
      GoalRules.statuses(goals: [back], ledger: restored.ledger, today: environment.today).first)
    XCTAssertEqual(status.saved, AmountE4(whole: 30_000))
  }

  /// «Удалить…» on the row of an archived goal with 5,000 filed under «Еда»: no question — the
  /// row says «Эту цель не удалить…», the button goes, nothing is written and no step of ⌘Z.
  func testAnArchivedRowWithAContributionOutsideGoalsSaysWhy() throws {
    let card = PaymentMethod(name: "Карта", isDefault: true)
    try references.save(card)
    let food = CoreKit.Category(kind: .expense, name: "Еда")
    try references.save(food)
    let trip = Goal(name: "Отпуск", targetE4: AmountE4(whole: 100_000), archived: true)
    try references.save(trip)
    var draft = TransactionDraft(
      occurredAt: environment.calendar.startOfDay(DateOnly(year: 2026, month: 3, day: 10))
        .addingTimeInterval(12 * 3600),
      amount: AmountE4(whole: 5_000), paymentMethodId: card.id)
    draft.parts = [PartDraft(categoryId: food.id, amount: AmountE4(whole: 5_000), goalId: trip.id)]
    try XCTUnwrap(environment.transactions).insert([try draft.materialize()])

    let asked = GoalsBlock.askToDelete(trip, with: actions)
    XCTAssertEqual(asked, .refused(note: "form.goal.delete.outsideGoals"))
    if case .refused(let note) = asked {
      XCTAssertFalse(GoalForm.offersDeletion(after: note), "«Удалить…» stayed on the row")
    }
    XCTAssertEqual(
      GoalsBlock.delete(trip, with: actions), "form.goal.delete.outsideGoals",
      "a refused deletion was written")
    XCTAssertEqual(
      try references.goals(includeArchived: true).first { $0.id == trip.id }?.archived, true)
    XCTAssertFalse(store.canUndo, "a step of ⌘Z was left for nothing written")
  }

  /// Nothing comes back while a live goal has the name, and an edit of a saved goal is only
  /// that edit: the archive is asked about new goals only. A new goal of a live goal's name is
  /// refused instead (`testALiveGoalNameIsTakenOnce`).
  func testALiveNameOrAnEditBringsNothingBackFromTheArchive() throws {
    let old = Goal(name: "Машина", targetE4: AmountE4(whole: 900_000), archived: true)
    let live = Goal(name: "Машина", targetE4: AmountE4(whole: 1_000_000))
    try references.save(old)
    try references.save(live)

    var edited = live
    edited.targetE4 = AmountE4(whole: 1_200_000)
    XCTAssertTrue(GoalForm.save(edited, isNew: false, with: actions, references: references))
    XCTAssertEqual(
      try references.goals(includeArchived: true).first { $0.id == old.id }?.archived, true)

    let another = Goal(name: "машина", targetE4: AmountE4(whole: 500_000))
    XCTAssertFalse(GoalForm.save(another, isNew: true, with: actions, references: references))
    let all = try references.goals(includeArchived: true)
    XCTAssertEqual(all.count, 2, "a goal was made beside a live one of its name")
    XCTAssertEqual(all.first { $0.id == old.id }?.archived, true)
  }

  /// A live goal's name is taken once: a new goal of it, a rename to it and an archived goal
  /// brought back under it are all refused, nothing is written and no step of ⌘Z is left.
  func testALiveGoalNameIsTakenOnce() throws {
    let live = Goal(name: "Машина", targetE4: AmountE4(whole: 1_000_000))
    let other = Goal(name: "Дача", targetE4: AmountE4(whole: 300_000))
    let old = Goal(name: "ОТПУСК", targetE4: AmountE4(whole: 90_000), archived: true)
    let tripNow = Goal(name: "отпуск", targetE4: AmountE4(whole: 80_000))
    for goal in [live, other, old, tripNow] { try references.save(goal) }

    let again = Goal(name: " машина ", targetE4: AmountE4(whole: 500_000))
    XCTAssertEqual(GoalForm.liveNamesake(of: again, among: try references.goals())?.id, live.id)
    XCTAssertFalse(GoalForm.save(again, isNew: true, with: actions, references: references))

    var renamed = other
    renamed.name = "МАШИНА"
    XCTAssertEqual(GoalForm.liveNamesake(of: renamed, among: try references.goals())?.id, live.id)
    XCTAssertFalse(GoalForm.save(renamed, isNew: false, with: actions, references: references))

    XCTAssertFalse(GoalsBlock.restore(old.id, with: actions, references: references))

    let all = try references.goals(includeArchived: true)
    XCTAssertEqual(all.count, 4)
    XCTAssertEqual(all.first { $0.id == other.id }?.name, "Дача")
    XCTAssertEqual(all.first { $0.id == old.id }?.archived, true)
    XCTAssertFalse(store.canUndo, "a step of ⌘Z was left for nothing written")

    // A goal saved under its own name is no namesake of itself, and a free name is saved.
    XCTAssertNil(GoalForm.liveNamesake(of: live, among: try references.goals()))
    var fresh = other
    fresh.name = "Дача у моря"
    XCTAssertTrue(GoalForm.save(fresh, isNew: false, with: actions, references: references))
  }

  /// A goal deleted meanwhile is not written back.
  func testAGoalGoneMeanwhileIsNotWrittenBack() throws {
    XCTAssertFalse(GoalsBlock.restore(UUID(), with: actions, references: references))
    XCTAssertTrue(try references.goals(includeArchived: true).isEmpty)
    XCTAssertFalse(store.canUndo)
  }
}
