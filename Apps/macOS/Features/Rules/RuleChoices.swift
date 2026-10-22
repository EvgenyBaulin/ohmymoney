import AppCore
import Foundation

/// What the pickers of the rule editor offer, from the data: only what can be chosen today.
struct RuleChoices: Sendable {
  struct Choice: Identifiable, Hashable, Sendable {
    var id: UUID
    var title: String
  }

  var conditionCategories: [Choice] = []
  var actionCategories: [Choice] = []
  var places: [Choice] = []
  var accounts: [Choice] = []
  var cards: [Choice] = []
  var people: [Choice] = []
  /// The tags a rule can name, archived ones left out.
  var tags: [Choice] = []

  init() {}

  init(dataset: Dataset) {
    let names = RuleNames(dataset: dataset)
    let tree = names.tree
    func sorted(_ choices: [Choice]) -> [Choice] {
      choices.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }
    // Every live category, a subcategory after its category: a condition may look at a system
    // category too, an action may not file anything into one.
    let live = dataset.categories.filter { !$0.archived }
    let roots = live.filter { $0.parentId == nil }.sorted {
      ($0.kind.rawValue, $0.sort, $0.name) < ($1.kind.rawValue, $1.sort, $1.name)
    }
    var all: [Choice] = []
    for root in roots {
      all.append(Choice(id: root.id, title: names.category(root.id)))
      for child in live.filter({ $0.parentId == root.id }).sorted(by: { $0.sort < $1.sort }) {
        all.append(Choice(id: child.id, title: names.category(child.id)))
      }
    }
    conditionCategories = all
    actionCategories = all.filter { tree.systemRole(of: $0.id) == nil }
    places = sorted(
      dataset.places.filter { !$0.archived }.map { Choice(id: $0.id, title: $0.name) })
    accounts = dataset.paymentMethods.filter { !$0.archived }.map {
      Choice(id: $0.id, title: $0.name)
    }
    cards = dataset.cards.filter { !$0.archived }.map { Choice(id: $0.id, title: $0.name) }
    people = sorted(
      dataset.people.filter { !$0.archived }.map { Choice(id: $0.id, title: $0.name) })
    tags = sorted(
      dataset.tagBook.tags.filter { !$0.archived }.map { Choice(id: $0.id, title: $0.name) })
  }
}
