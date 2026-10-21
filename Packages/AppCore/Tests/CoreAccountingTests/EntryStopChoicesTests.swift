import CoreKit
import Foundation
import Testing

@testable import CoreAccounting

/// What ↓ and ↑ walk while Enter's stop for a category stands: nothing chosen first, then what
/// the chips suggest, then the other categories of the menu in its order, and last the
/// categories of the app — Goals, Loans, «Не помню».
@Suite("The categories the arrows walk at the stop")
struct EntryStopChoicesTests {
  typealias Fixture = EntryCompletenessTests

  private func menu(_ ids: [UUID]) -> [CoreKit.Category] {
    ids.compactMap { Fixture.tree[$0] }
  }

  /// The menu as the picker lists it: Goals and Loans stand where the dictionary put them,
  /// among the owner's own categories.
  private var expenseMenu: [CoreKit.Category] {
    menu([
      Fixture.goals, Fixture.cafe, Fixture.transport, Fixture.loans, Fixture.home, Fixture.unknown,
    ])
  }

  @Test func withoutSuggestionsTheMenuGoesInItsOrderAndTheAppLast() {
    let choices = EntryCompleteness.stopChoices(
      suggested: [], menu: expenseMenu, tree: Fixture.tree)
    #expect(
      choices == [
        nil, Fixture.cafe, Fixture.transport, Fixture.home, Fixture.goals, Fixture.loans,
        Fixture.unknown,
      ])
  }

  /// The chips come first, in their order; a category that is a chip is not walked again where
  /// the menu has it, and a subcategory is a stop of its own.
  @Test func suggestionsComeFirstInTheirOrder() {
    let choices = EntryCompleteness.stopChoices(
      suggested: [Fixture.home, Fixture.taxi], menu: expenseMenu, tree: Fixture.tree)
    #expect(
      choices == [
        nil, Fixture.home, Fixture.taxi, Fixture.cafe, Fixture.transport, Fixture.goals,
        Fixture.loans, Fixture.unknown,
      ])
  }

  /// A chip that is a category of the app is a chip: it comes with the chips, not at the end.
  @Test func aSuggestedCategoryOfTheAppIsWalkedWithTheChips() {
    let choices = EntryCompleteness.stopChoices(
      suggested: [Fixture.unknown], menu: expenseMenu, tree: Fixture.tree)
    #expect(
      choices == [
        nil, Fixture.unknown, Fixture.cafe, Fixture.transport, Fixture.home, Fixture.goals,
        Fixture.loans,
      ])
  }

  @Test func incomeKeepsItsOwnCategoriesOfTheApp() {
    let income = menu([Fixture.surcharges, Fixture.salary])
    let choices = EntryCompleteness.stopChoices(suggested: [], menu: income, tree: Fixture.tree)
    #expect(choices == [nil, Fixture.salary, Fixture.surcharges])
  }

  @Test func anEmptyMenuHasOnlyNothingChosen() {
    #expect(EntryCompleteness.stopChoices(suggested: [], menu: [], tree: Fixture.tree) == [nil])
  }
}
