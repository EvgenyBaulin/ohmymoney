import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CorePlanning

/// «+ Цель» with the name of an archived goal, and «Удалить старую»: the archived goal is
/// deleted, its contributions stay spending as they were and let go of it, its subcategory goes
/// to the archive, and a new goal of the name starts from zero.
@Suite("Deleting an archived goal")
struct GoalDeletionTests: SavingsFixtures {
  let today = DateOnly(year: 2026, month: 9, day: 27)

  private func goal(
    _ name: String, archived: Bool = false, id: Int = 500, subcategory: UUID? = nil
  ) -> Goal {
    Goal(
      id: uid(id), name: name, targetE4: rub("100000"), subcategoryId: subcategory,
      archived: archived)
  }

  /// The archived «Отпуск»: 20 000 on 10.03 and 10 000 on 10.04, both good expenses in
  /// «Цели → Отпуск» tied to it.
  private func vacationBook() -> (book: SavingsBook, goal: Goal) {
    var book = SavingsBook()
    let vacation = goal("Отпуск", archived: true, subcategory: book.carSubcategory)
    book.categories = book.categories.map { category in
      guard category.id == book.carSubcategory else { return category }
      var renamed = category
      renamed.name = "Отпуск"
      return renamed
    }
    book.goals = [vacation]
    book.contribute("2026-03-10", "20000", goal: vacation.id)
    book.contribute("2026-04-10", "10000", goal: vacation.id)
    return (book, vacation)
  }

  private func parts(of goal: Goal, in book: SavingsBook) -> [(partId: UUID, categoryId: UUID?)] {
    book.entries.flatMap(\.parts).filter { $0.goalId == goal.id }.map {
      (partId: $0.id, categoryId: $0.categoryId)
    }
  }

  /// The book as deleting the goal writes it: the parts let go of it, its subcategory archived,
  /// the goal row gone.
  private func deleted(
    _ goal: Goal, from book: SavingsBook, as deletion: GoalRules.Deletion
  )
    -> SavingsBook
  {
    var after = book
    after.entries = book.entries.map { entry in
      var entry = entry
      entry.parts = entry.parts.map { part in
        var part = part
        if part.goalId == goal.id { part.goalId = nil }
        return part
      }
      return entry
    }
    if let archived = deletion.archivedSubcategory {
      after.categories = book.categories.map { $0.id == archived.id ? archived : $0 }
    }
    after.goals = book.goals.filter { $0.id != goal.id }
    return after
  }

  /// «отпуск» repeats the archived «Отпуск», «елка» the archived «Ёлка», and the spaces around
  /// a name do not count.
  @Test func anArchivedNamesakeFoldsCaseAndYo() {
    let vacation = goal("Отпуск", archived: true, id: 1)
    let tree = goal("Ёлка", archived: true, id: 2)
    let goals = [vacation, tree, goal("Машина", id: 3)]
    #expect(GoalRules.archivedNamesake(of: "отпуск", among: goals) == vacation)
    #expect(GoalRules.archivedNamesake(of: " ОТПУСК ", among: goals) == vacation)
    #expect(GoalRules.archivedNamesake(of: "Елка", among: goals) == tree)
    #expect(GoalRules.archivedNamesake(of: "машина", among: goals) == nil)
    #expect(GoalRules.archivedNamesake(of: "Дача", among: goals) == nil)
    #expect(GoalRules.archivedNamesake(of: "  ", among: goals) == nil)
  }

  /// A live goal of the name: the archive is not asked — the live goal is the namesake
  /// (`GoalRules.liveNamesake`).
  @Test func noNamesakeWhileALiveGoalHasTheName() {
    let goals = [goal("Отпуск", archived: true, id: 1), goal("отпуск", id: 2)]
    #expect(GoalRules.archivedNamesake(of: "Отпуск", among: goals) == nil)
  }

  /// A live goal is not deleted; an archived one is, with every part that names it.
  @Test func onlyAnArchivedGoalIsDeleted() throws {
    let (book, vacation) = vacationBook()
    var live = vacation
    live.archived = false
    let tree = CategoryTree(book.categories)
    #expect(
      GoalRules.deletion(of: live, parts: parts(of: vacation, in: book), tree: tree)
        == .failure(.notArchived))
    let deletion = try GoalRules.deletion(
      of: vacation, parts: parts(of: vacation, in: book), tree: tree
    ).get()
    #expect(deletion.goalId == vacation.id)
    #expect(deletion.unlinkedParts == 2)
  }

  /// A part that names the goal but is filed under groceries would turn into ordinary spending
  /// and move money once it let go of the goal: the goal is not deleted.
  @Test func aContributionOutsideGoalsRefusesTheDeletion() {
    var (book, vacation) = vacationBook()
    book.add(.expense, "2026-05-10", "5000", category: book.groceries, goal: vacation.id)
    book.add(.expense, "2026-05-11", "700", category: nil, goal: vacation.id)
    let result = GoalRules.deletion(
      of: vacation, parts: parts(of: vacation, in: book), tree: CategoryTree(book.categories))
    #expect(result == .failure(.contributionsOutsideGoals(2)))
  }

  /// The goal's subcategory is written archived, and nothing else of it changes; a
  /// subcategory that is archived already, or that another live goal files its money in, is
  /// left as it is.
  @Test func theSubcategoryGoesToTheArchive() throws {
    let (book, vacation) = vacationBook()
    let tree = CategoryTree(book.categories)
    let deletion = try GoalRules.deletion(
      of: vacation, parts: parts(of: vacation, in: book), tree: tree
    ).get()
    let archived = try #require(deletion.archivedSubcategory)
    var expected = try #require(tree[book.carSubcategory])
    expected.archived = true
    #expect(archived == expected)

    var alreadyArchived = book.categories
    alreadyArchived = alreadyArchived.map { category in
      var category = category
      if category.id == book.carSubcategory { category.archived = true }
      return category
    }
    let again = try GoalRules.deletion(
      of: vacation, parts: [], tree: CategoryTree(alreadyArchived)
    ).get()
    #expect(again.archivedSubcategory == nil)

    let sharing = goal("Отпуск 2", id: 777, subcategory: book.carSubcategory)
    let shared = try GoalRules.deletion(
      of: vacation, parts: [], tree: tree, goals: [vacation, sharing]
    ).get()
    #expect(shared.archivedSubcategory == nil)

    var rootGoal = vacation
    rootGoal.subcategoryId = book.goalsRoot
    let root = try GoalRules.deletion(of: rootGoal, parts: [], tree: tree).get()
    #expect(root.archivedSubcategory == nil)
  }

  /// Before and after the deletion every month's spending is the same (20 000 in March,
  /// 10 000 in April), and neither contribution moves money on an account: they stay under
  /// «Цели».
  @Test func theContributionsStaySpendingAndMoveNoMoney() throws {
    let (book, vacation) = vacationBook()
    let deletion = try GoalRules.deletion(
      of: vacation, parts: parts(of: vacation, in: book), tree: CategoryTree(book.categories)
    ).get()
    let after = deleted(vacation, from: book, as: deletion)

    func spending(_ book: SavingsBook) -> [MonthKey: AmountE4] {
      var months: [MonthKey: AmountE4] = [:]
      for entry in book.entries {
        for part in entry.parts {
          let month = CalendarContext.utc.day(of: entry.transaction.occurredAt).monthKey
          months[month, default: .zero] += MyExpensesRule.contribution(
            part: part, in: entry.transaction)
        }
      }
      return months
    }
    #expect(spending(book) == spending(after))
    #expect(spending(after)[MonthKey(year: 2026, month: 3)] == rub("20000"))
    #expect(spending(after)[MonthKey(year: 2026, month: 4)] == rub("10000"))

    let mainId = uid(900)
    for (tree, entries) in [
      (CategoryTree(book.categories), book.entries),
      (CategoryTree(after.categories), after.entries),
    ] {
      for entry in entries {
        #expect(AccountBalances.movement(of: entry, mainId: mainId, tree: tree) == nil)
      }
    }
    #expect(after.entries.flatMap(\.parts).allSatisfy { $0.goalId == nil })
  }

  /// A new «Отпуск» after the deletion gets a subcategory of its own and has saved nothing:
  /// the old contributions belong to no goal.
  @Test func theNewGoalOfTheNameStartsFromZero() throws {
    let (book, vacation) = vacationBook()
    let deletion = try GoalRules.deletion(
      of: vacation, parts: parts(of: vacation, in: book), tree: CategoryTree(book.categories)
    ).get()
    var after = deleted(vacation, from: book, as: deletion)
    #expect(GoalRules.archivedNamesake(of: "отпуск", among: after.goals) == nil)

    var fresh = Goal(
      id: uid(600), name: "Отпуск", targetE4: rub("150000"),
      targetDate: DateOnly(year: 2027, month: 6, day: 1), monthlyPlanE4: rub("10000"))
    let made = try #require(
      SystemSubcategories.goalSubcategory(
        for: fresh, tree: CategoryTree(after.categories), id: uid(601)))
    #expect(made.id != book.carSubcategory)
    fresh.subcategoryId = made.id
    after.categories.append(made)
    after.goals.append(fresh)

    let status = try #require(
      GoalRules.statuses(goals: after.goals, ledger: after.ledger, today: today).first)
    #expect(status.goal.id == fresh.id)
    #expect(status.saved == .zero)
    for row in after.ledger.rows {
      #expect(GoalRules.contribution(of: row, to: fresh, rates: .empty) == .zero)
    }
  }
}
