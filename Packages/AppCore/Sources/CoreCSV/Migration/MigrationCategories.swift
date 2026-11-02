import CoreKit
import Foundation

/// Where the operations of one category of the other application go.
public enum MigrationCategoryTarget: Sendable, Hashable, Codable {
  case existing(UUID)
  /// A new category under the other application's name (and its subcategory under it). Only
  /// ever chosen by the person: the guess never creates anything.
  case create
  /// «Не разобрано», to be sorted later.
  case unsorted
}

/// Pairs the other application's categories with the book's own.
public enum MigrationCategoryMatcher {
  /// A guess per category: what the person chose for it the last time (`remembered`, by
  /// `MigrationCategoryKey.id`), else an own category of the same kind and the same name or
  /// meaning («Еда вне дома» → «Кафе») — the subcategory before the parent —, else
  /// «Не разобрано». System categories are never a target.
  public static func suggest(
    _ keys: [MigrationCategoryKey], categories: [CoreKit.Category],
    remembered: [String: UUID] = [:]
  ) -> [String: MigrationCategoryTarget] {
    let open = categories.filter { !$0.archived && $0.systemRole == nil }
    let byID = Dictionary(open.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    var result: [String: MigrationCategoryTarget] = [:]
    for key in keys {
      if let id = remembered[key.id], let category = byID[id], category.kind == key.kind {
        result[key.id] = .existing(id)
        continue
      }
      let mine = open.filter { $0.kind == key.kind }
      let names = [key.child, key.parent].compactMap { $0 }
      var found: UUID?
      // The more specific name first: the subcategory by name, then by meaning, then the parent.
      for name in names where found == nil {
        let folded = NameKey.fold(name)
        let same = mine.filter { NameKey.fold($0.name) == folded }
        // Of two of one name, the one under a parent named like the other application's.
        found =
          same.first { category in
            category.parentId.flatMap { byID[$0] }.map { NameKey.fold($0.name) }
              == NameKey.fold(key.parent)
          }?.id ?? same.first?.id
        if found == nil, let group = synonymGroup(of: name) {
          found = mine.first { synonymGroup(of: $0.name) == group }?.id
        }
      }
      result[key.id] = found.map(MigrationCategoryTarget.existing) ?? .unsorted
    }
    return result
  }

  /// Names that mean the same in money trackers, folded; one list per meaning.
  static let synonyms: [[String]] = [
    [
      "кафе", "еда вне дома", "рестораны", "кафе и рестораны", "рестораны и кафе", "фастфуд",
      "фаст-фуд", "кофе", "eating out", "restaurants", "restaurant", "cafe", "dining out",
      "cafes", "coffee",
    ],
    ["продукты", "супермаркеты", "еда", "groceries", "food", "продукты питания", "supermarket"],
    ["транспорт", "общественный транспорт", "проезд", "метро", "transport", "public transport"],
    ["такси", "taxi"],
    [
      "авто", "автомобиль", "машина", "бензин", "топливо", "car", "fuel", "gas",
      "автомобиль и бензин",
    ],
    ["связь", "мобильная связь", "телефон", "интернет", "интернет и связь", "phone", "internet"],
    ["здоровье", "медицина", "аптека", "лекарства", "health", "pharmacy", "medicine"],
    ["развлечения", "досуг", "entertainment", "leisure", "fun"],
    ["одежда", "одежда и обувь", "clothes", "clothing", "apparel"],
    ["дом", "жилье", "квартира", "аренда", "home", "housing", "rent"],
    ["коммунальные", "коммунальные услуги", "жкх", "коммуналка", "квартплата", "utilities"],
    ["подписки", "сервисы", "subscriptions", "services"],
    ["подарки", "gifts", "presents"],
    ["путешествия", "отпуск", "travel", "vacation", "trips"],
    ["образование", "учеба", "курсы", "education", "learning"],
    ["спорт", "фитнес", "sport", "fitness", "gym"],
    ["красота", "уход", "beauty", "personal care"],
    ["дети", "children", "kids"],
    ["животные", "питомцы", "pets"],
    ["зарплата", "заработная плата", "оклад", "salary", "wage", "wages", "payroll"],
    ["подработка", "фриланс", "freelance", "side job"],
    ["проценты", "проценты по вкладам", "interest"],
    ["кэшбэк", "кешбэк", "кэшбек", "cashback"],
  ]

  static func synonymGroup(of name: String) -> Int? {
    let folded = NameKey.fold(name)
    return synonyms.firstIndex { $0.contains(folded) }
  }
}

/// The categories a write needs: the id each of the other application's categories ends up
/// under, and the new categories to make for those the person chose to create.
public struct MigrationCategoryPlan: Sendable, Hashable {
  public var ids: [String: UUID]
  public var made: [CoreKit.Category]

  /// `unsorted` gives the «Не разобрано» category of a kind (the caller makes it when needed).
  /// A new category is made once per name and kind; a new subcategory goes under its new or
  /// existing parent of the same name. New ones go to the end of the list.
  public static func resolve(
    _ keys: [MigrationCategoryKey], targets: [String: MigrationCategoryTarget],
    categories: [CoreKit.Category], unsorted: (CategoryKind) -> UUID
  ) -> MigrationCategoryPlan {
    var plan = MigrationCategoryPlan(ids: [:], made: [])
    var sort = (categories.map(\.sort).max() ?? 0) + 1
    func topLevel(_ name: String, _ kind: CategoryKind) -> UUID {
      let folded = NameKey.fold(name)
      if let mine = (categories + plan.made).first(where: {
        $0.parentId == nil && $0.kind == kind && !$0.archived && $0.systemRole == nil
          && NameKey.fold($0.name) == folded
      }) {
        return mine.id
      }
      let made = CoreKit.Category(kind: kind, name: name, sort: sort)
      sort += 1
      plan.made.append(made)
      return made.id
    }
    for key in keys {
      switch targets[key.id] ?? .unsorted {
      case .existing(let id):
        plan.ids[key.id] = id
      case .unsorted:
        plan.ids[key.id] = unsorted(key.kind)
      case .create:
        let parent = topLevel(key.parent, key.kind)
        guard let child = key.child else {
          plan.ids[key.id] = parent
          continue
        }
        let folded = NameKey.fold(child)
        if let mine = (categories + plan.made).first(where: {
          $0.parentId == parent && !$0.archived && NameKey.fold($0.name) == folded
        }) {
          plan.ids[key.id] = mine.id
        } else {
          var made = CoreKit.Category(kind: key.kind, name: child, sort: sort)
          made.parentId = parent
          sort += 1
          plan.made.append(made)
          plan.ids[key.id] = made.id
        }
      }
    }
    return plan
  }
}
