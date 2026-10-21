import AppCore
import AppDatabase
import Foundation

/// «Для оплаты чего-либо»: the income category for money a person sent for things the owner
/// paid for them, and for what is over the parts they cover. An ordinary income category — no
/// system role, so it can be renamed or deleted — that the app makes itself the first time it is
/// needed and finds again by its name in either language. If the owner renamed it, a second one
/// may be made; that is accepted.
enum PaidForOthersCategory {
  static let russianName = "Для оплаты чего-либо"
  static let englishName = "Paid for others"

  enum Choice: Equatable {
    case existing(UUID)
    case create(CoreKit.Category)
  }

  /// The live income category of that name at the top level, else a new one called `name`.
  static func choose(categories: [CoreKit.Category], name: String) -> Choice {
    let names: Set<String> = [
      NameKey.fold(russianName), NameKey.fold(englishName), NameKey.fold(name),
    ]
    if let found = categories.first(where: {
      $0.kind == .income && !$0.archived && $0.systemRole == nil && $0.parentId == nil
        && names.contains(NameKey.fold($0.name))
    }) {
      return .existing(found.id)
    }
    let siblings = categories.filter { $0.kind == .income && $0.parentId == nil }
    return .create(
      CoreKit.Category(
        kind: .income, name: name,
        sort: (siblings.map(\.sort).max() ?? 0) + 1))
  }

  /// The id of the category, made and saved when there is none yet.
  static func ensure(references: ReferenceRepository, name: String) throws -> UUID {
    switch choose(categories: try references.categories(), name: name) {
    case .existing(let id): return id
    case .create(let category):
      try references.save(category)
      return category.id
    }
  }
}
