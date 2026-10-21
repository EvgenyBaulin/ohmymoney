import CoreKit
import Foundation
import Testing

@testable import CoreAccounting

/// When Enter on a new operation stops to ask for the category or the subcategory instead of
/// saving the words into the note alone: only when nothing the app knows — history, the model
/// when sure, a chip, the owner — has filed the money, or when the model filed it under a
/// category with subcategories without saying which one.
@Suite("What the entry line leaves the panel to ask")
struct EntryCompletenessTests {
  static let cafe = id(101)
  static let transport = id(102)
  static let taxi = id(103)
  static let bus = id(104)
  static let home = id(105)
  static let homeOld = id(106)
  static let goals = id(107)
  static let goalSub = id(108)
  static let loans = id(109)
  static let unknown = id(110)
  static let salary = id(111)
  static let surcharges = id(112)
  static let stranger = id(199)

  static let tree = CategoryTree([
    CoreKit.Category(id: cafe, kind: .expense, name: "Cafe"),
    CoreKit.Category(id: transport, kind: .expense, name: "Transport"),
    CoreKit.Category(id: taxi, parentId: transport, kind: .expense, name: "Taxi"),
    CoreKit.Category(id: bus, parentId: transport, kind: .expense, name: "Bus"),
    CoreKit.Category(id: home, kind: .expense, name: "Home"),
    CoreKit.Category(id: homeOld, parentId: home, kind: .expense, name: "Old", archived: true),
    CoreKit.Category(id: goals, kind: .expense, name: "Goals", systemRole: .goals),
    CoreKit.Category(id: goalSub, parentId: goals, kind: .expense, name: "Trip"),
    CoreKit.Category(id: loans, kind: .expense, name: "Loans", systemRole: .loans),
    CoreKit.Category(id: unknown, kind: .expense, name: "Unknown", systemRole: .unknown),
    CoreKit.Category(id: salary, kind: .income, name: "Salary"),
    CoreKit.Category(id: surcharges, kind: .income, name: "Surcharges", systemRole: .surcharges),
  ])

  struct Case: Sendable, CustomTestStringConvertible {
    let name: String
    let draft: TransactionDraft
    let gap: EntryGap?
    var testDescription: String { name }
  }

  static func draft(
    _ kind: TransactionKind = .expense, category: UUID? = nil,
    source: CategorySource = .manual, goal: UUID? = nil, debt: UUID? = nil,
    refundOf: UUID? = nil, parts: Int = 1
  ) -> TransactionDraft {
    let one = PartDraft(
      categoryId: category, categorySource: source, amount: money(250), goalId: goal,
      refundOfPartId: refundOf)
    var all = [one]
    if parts > 1 { all.append(PartDraft(amount: money(100))) }
    return TransactionDraft(
      kind: kind, amount: money(parts > 1 ? 350 : 250), debtId: debt, parts: all)
  }

  static let cases: [Case] = [
    Case(name: "no category", draft: draft(), gap: .category),
    Case(name: "income with no category", draft: draft(.income), gap: .category),
    Case(name: "a refund with no category", draft: draft(.refund), gap: .category),
    Case(
      name: "a category of the other kind", draft: draft(.income, category: cafe),
      gap: .category),
    Case(
      name: "top level with children, the model's",
      draft: draft(category: transport, source: .model), gap: .subcategory),
    Case(
      name: "top level with children, history's",
      draft: draft(category: transport, source: .history), gap: nil),
    Case(
      name: "top level with children, the owner's",
      draft: draft(category: transport, source: .manual), gap: nil),
    Case(
      name: "top level with children, a template's",
      draft: draft(category: transport, source: .template), gap: nil),
    Case(name: "a subcategory", draft: draft(category: taxi, source: .model), gap: nil),
    Case(
      name: "top level without children", draft: draft(category: cafe, source: .model),
      gap: nil),
    Case(
      name: "top level whose children are archived",
      draft: draft(category: home, source: .model), gap: nil),
    Case(name: "Goals", draft: draft(category: goals, source: .model), gap: nil),
    Case(name: "Loans", draft: draft(category: loans, source: .model), gap: nil),
    Case(name: "Unknown", draft: draft(category: unknown, source: .model), gap: nil),
    Case(
      name: "Surcharges", draft: draft(.income, category: surcharges, source: .model), gap: nil),
    Case(name: "a goal named", draft: draft(goal: id(300)), gap: nil),
    Case(name: "under a goal's subcategory", draft: draft(category: goalSub), gap: nil),
    Case(name: "a payment on a debt", draft: draft(debt: id(301)), gap: nil),
    Case(name: "a refund of a purchase", draft: draft(.refund, refundOf: id(302)), gap: nil),
    Case(name: "money back", draft: draft(.reimbursement), gap: nil),
    Case(name: "a split with an uncategorised part", draft: draft(parts: 2), gap: nil),
    Case(
      name: "a category the tree does not know", draft: draft(category: stranger), gap: nil),
    Case(name: "income filed", draft: draft(.income, category: salary), gap: nil),
  ]

  @Test("The gap of a new operation", arguments: cases)
  func theGap(_ testCase: Case) {
    #expect(EntryCompleteness.gap(of: testCase.draft, tree: Self.tree) == testCase.gap)
  }
}
