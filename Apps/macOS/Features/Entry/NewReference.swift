import AppCore
import AppDatabase
import Foundation

/// A new row of a dictionary as every screen that adds one makes it: the tabs of Settings and
/// the sheet that «Add…» of a picker opens in the ↓ panel. What a new row starts with — the
/// quality of a new category, which account is the main one, the days of an event — is
/// decided here once, so the two ways of adding cannot drift apart.
///
/// A name the archive holds is never made a second time: the archived row comes back instead,
/// with everything it had.
enum NewReference {
  /// A category of `kind`, a subcategory when `parent` is given, placed after every category
  /// there is. A new top-level expense category starts neutral, as every category the owner
  /// has not rated yet; a subcategory has no quality of its own and takes its parent's, and
  /// income is never rated. Nil when `parent` cannot take a category of `kind`.
  static func category(
    named name: String, kind: CategoryKind, parent: UUID?, among all: [CoreKit.Category]
  ) -> CoreKit.Category? {
    guard acceptsParent(parent, for: kind, in: all) else { return nil }
    return CoreKit.Category(
      parentId: parent, kind: kind, name: name, sort: all.count,
      quality: parent == nil && kind == .expense ? .neutral : nil)
  }

  /// The category in the archive «Add…» brings back for `name` instead of making a second
  /// one: of `kind`, beside the same `parent` — top-level when nil —, its name compared the way
  /// the entry line compares names. Nil when the archive holds none. A system category is never
  /// in the archive; it is left out all the same.
  static func archivedCategory(
    named name: String, kind: CategoryKind, parent: UUID?, among all: [CoreKit.Category]
  ) -> CoreKit.Category? {
    let wanted = ReferenceNames.folded(name)
    guard !wanted.isEmpty else { return nil }
    return all.first { category in
      category.archived && category.systemRole == nil && category.kind == kind
        && category.parentId == parent && ReferenceNames.folded(category.name) == wanted
    }
  }

  /// Whether a new category of `kind` may be filed under `parent`: under nothing, or under a
  /// live top-level category of the same kind. The dictionary is two levels deep, and the
  /// schema ties nothing to the parent's kind, so this is the check: an income category filed
  /// under an expense root would be listed there with a quality picker, reported by the tree
  /// as an expense and offered by no form.
  static func acceptsParent(
    _ parent: UUID?, for kind: CategoryKind, in categories: [CoreKit.Category]
  ) -> Bool {
    guard let parent else { return true }
    guard let root = categories.first(where: { $0.id == parent }) else { return false }
    return root.parentId == nil && root.kind == kind && !root.archived
  }

  /// An account of `kind` in `currency` — the default currency, which everything new is in; an
  /// account without one counts as rubles. It goes where a new account goes: after every other
  /// once the owner has dragged them, alphabetical until then. The first one in the book is the
  /// main account: the entry line puts the main account on every operation that names none.
  static func paymentMethod(
    named name: String, kind: PaymentMethodKind = .card, currency: CurrencyCode? = nil,
    among live: [PaymentMethod]
  ) -> PaymentMethod {
    PaymentMethod(
      name: name, kind: kind, currency: currency, isDefault: live.isEmpty,
      sort: AccountRules.sortForNewAccount(among: live))
  }

  /// The archived account «Add…» brings back for `name` instead of making a second one: the
  /// one the name is the name of, else one it is an other name of, compared the way the entry
  /// line compares them. Nil when none is archived under it, and when a live account already
  /// has that account's own name — it cannot come back beside it.
  static func archivedAccount(
    answering name: String, among all: [PaymentMethod]
  ) -> PaymentMethod? {
    let wanted = ReferenceNames.folded(name)
    guard !wanted.isEmpty else { return nil }
    let live = Set(all.filter { !$0.archived }.map { ReferenceNames.folded($0.name) })
    let archived = all.filter { $0.archived && !live.contains(ReferenceNames.folded($0.name)) }
    return archived.first { ReferenceNames.folded($0.name) == wanted }
      ?? archived.first { $0.aliases.contains { ReferenceNames.folded($0) == wanted } }
  }

  /// An event from `start` to `end`. It ends on or after the day it starts, or it would cover
  /// no day at all: an end before the start is the start itself.
  static func event(named name: String, from start: DateOnly, to end: DateOnly) -> Event {
    Event(name: name, startDate: start, endDate: max(start, end))
  }

  /// «Добавить» of a reference book: the person, the place or the event the archive holds
  /// under `name` comes back (`ReferenceRepository.revive`) — an event only when its days meet
  /// `start…end`, since a yearly event is made again under the same name every year —, and
  /// otherwise a new row is written. Returns its id.
  static func add(
    _ name: String, to book: ReferenceBook, from start: DateOnly, to end: DateOnly,
    references: ReferenceRepository
  ) throws -> UUID {
    let name = name.trimmingCharacters(in: .whitespaces)
    let days = start...max(start, end)
    if let id = try references.revive(named: name, in: book, days: days) { return id }
    switch book {
    case .people:
      let person = Person(name: name)
      try references.save(person)
      return person.id
    case .places:
      let place = Place(name: name)
      try references.save(place)
      return place.id
    case .events:
      let event = event(named: name, from: start, to: end)
      try references.save(event)
      return event.id
    }
  }
}
