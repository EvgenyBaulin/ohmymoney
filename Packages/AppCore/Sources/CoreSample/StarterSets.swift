import CoreKit
import Foundation

/// A way of living the starter set is chosen by; several can be chosen at once.
public enum Lifestyle: String, CaseIterable, Sendable, Hashable, Codable {
  case student
  case working
  case freelance
  case family
  case alone
  case partner
  case kids
}

/// What the owner told the starter set: the ways of living and the questions after them. The
/// currency and the bank are asked by the account questionnaire of the first launch, which the
/// set does not repeat.
public struct StarterChoice: Hashable, Sendable, Codable {
  public var lifestyles: Set<Lifestyle>
  public var hasLoans: Bool
  public var hasSubscriptions: Bool
  public var tracksCashback: Bool
  public var wantsACushion: Bool

  public init(
    lifestyles: Set<Lifestyle> = [], hasLoans: Bool = false, hasSubscriptions: Bool = false,
    tracksCashback: Bool = false, wantsACushion: Bool = false
  ) {
    self.lifestyles = lifestyles
    self.hasLoans = hasLoans
    self.hasSubscriptions = hasSubscriptions
    self.tracksCashback = tracksCashback
    self.wantsACushion = wantsACushion
  }
}

/// An example monthly limit of a set, on a category named by its English seed name.
public struct StarterLimitSeed: Hashable, Sendable {
  public let categoryEnglish: String
  public let parentEnglish: String?
  public let rubles: Int64

  public init(_ categoryEnglish: String, parent: String? = nil, rubles: Int64) {
    self.categoryEnglish = categoryEnglish
    self.parentEnglish = parent
    self.rubles = rubles
  }
}

/// What applying a set would add — and nothing else: a set never removes, renames or changes
/// what is there. The app shows this list before it writes, and writes it as one step of ⌘Z.
public struct StarterAdditions: Hashable, Sendable {
  /// New categories, parents before their children.
  public var categories: [CoreKit.Category]
  /// Example limits on categories that have none.
  public var budgets: [Budget]
  /// Tiles of Overview to show after the ones chosen, as long as there is room.
  public var tiles: [OverviewTile]

  public var isEmpty: Bool { categories.isEmpty && budgets.isEmpty && tiles.isEmpty }
}

/// The starter sets as data: the categories, the example limits and the tiles each way of
/// living brings, and the categories every new database has since 1.4.
public enum StarterSets {
  /// The categories a new database gets on top of the catalog the samples are made of: «Зарплата»
  /// under «Заработок» and «Налоги и сборы» with three taxes. The samples keep the catalog as it
  /// was — their digests hold it.
  public static let newDatabaseSeeds: [CategorySeed] = [
    .init(english: "Salary", russian: "Зарплата", parentEnglish: "Work", kind: .income),
    .init(english: "Taxes & fees", russian: "Налоги и сборы", kind: .expense),
    .init(
      english: "Vehicle tax", russian: "Транспортный налог", parentEnglish: "Taxes & fees",
      kind: .expense),
    .init(
      english: "Property tax", russian: "Имущественный налог", parentEnglish: "Taxes & fees",
      kind: .expense),
    .init(
      english: "Income tax", russian: "НДФЛ", parentEnglish: "Taxes & fees", kind: .expense),
  ]

  /// Every seed of a new database: the catalog with `newDatabaseSeeds` put in their places —
  /// «Зарплата» first under «Заработок», «Налоги и сборы» before «Прочее».
  public static var starterSeeds: [CategorySeed] {
    var seeds = SampleCatalog.categorySeeds
    let salary = newDatabaseSeeds[0]
    if let work = seeds.firstIndex(where: { $0.kind == .income && $0.english == "Work" }) {
      seeds.insert(salary, at: work + 1)
    }
    let taxes = Array(newDatabaseSeeds.dropFirst())
    let other =
      seeds.firstIndex { $0.kind == .expense && $0.english == "Other" && $0.parentEnglish == nil }
      ?? seeds.count
    seeds.insert(contentsOf: taxes, at: other)
    return seeds
  }

  /// The categories of each way of living.
  public static func categories(of lifestyle: Lifestyle) -> [CategorySeed] {
    switch lifestyle {
    case .student:
      return [
        .init(
          english: "Textbooks", russian: "Учебники", parentEnglish: "Education", kind: .expense),
        .init(
          english: "Dormitory", russian: "Общежитие", parentEnglish: "Home", kind: .expense),
        .init(english: "Stipend", russian: "Стипендия", parentEnglish: "Work", kind: .income),
      ]
    case .working:
      return [
        .init(english: "Lunches", russian: "Обеды", parentEnglish: "Food out", kind: .expense),
        .init(english: "Bonus", russian: "Премия", parentEnglish: "Work", kind: .income),
      ]
    case .freelance:
      return [
        .init(
          english: "Self-employed tax", russian: "Налог самозанятого",
          parentEnglish: "Taxes & fees", kind: .expense),
        .init(
          english: "Work tools", russian: "Инструменты для работы", parentEnglish: "Electronics",
          kind: .expense),
        .init(english: "Clients", russian: "Заказчики", parentEnglish: "Work", kind: .income),
      ]
    case .family:
      return [
        .init(
          english: "Family help", russian: "Помощь родным", parentEnglish: "Gifts", kind: .expense)
      ]
    case .alone:
      return []
    case .partner:
      return [
        .init(
          english: "Dates", russian: "Свидания", parentEnglish: "Entertainment", kind: .expense)
      ]
    case .kids:
      return [
        .init(english: "Kids", russian: "Дети", kind: .expense),
        .init(
          english: "Kindergarten and school", russian: "Сад и школа", parentEnglish: "Kids",
          kind: .expense),
        .init(
          english: "Kids' clothes", russian: "Детская одежда", parentEnglish: "Kids", kind: .expense
        ),
        .init(english: "Toys", russian: "Игрушки", parentEnglish: "Kids", kind: .expense),
        .init(english: "Activities", russian: "Кружки", parentEnglish: "Kids", kind: .expense),
        .init(english: "Child benefit", russian: "Детские пособия", kind: .income),
      ]
    }
  }

  /// The example limits of each way of living, in rubles a month.
  public static func limits(of lifestyle: Lifestyle) -> [StarterLimitSeed] {
    switch lifestyle {
    case .student:
      return [.init("Food out", rubles: 6_000), .init("Entertainment", rubles: 3_000)]
    case .working:
      return [.init("Food out", rubles: 12_000), .init("Taxi", parent: "Transport", rubles: 5_000)]
    case .freelance:
      return [.init("Electronics", rubles: 10_000)]
    case .family:
      return [.init("Groceries", rubles: 40_000)]
    case .alone:
      return [.init("Groceries", rubles: 20_000)]
    case .partner:
      return [.init("Groceries", rubles: 30_000), .init("Entertainment", rubles: 8_000)]
    case .kids:
      return [.init("Kids", rubles: 20_000)]
    }
  }

  /// The tiles of Overview the answers ask for.
  public static func tiles(for choice: StarterChoice) -> [OverviewTile] {
    var tiles: [OverviewTile] = []
    if choice.hasLoans { tiles.append(.iOwe) }
    if choice.hasSubscriptions { tiles.append(.upcoming) }
    if choice.wantsACushion { tiles.append(.freeMoney) }
    if choice.lifestyles.contains(.freelance) { tiles.append(.incomeForecast) }
    if !choice.lifestyles.isDisjoint(with: [.family, .partner, .kids]) { tiles.append(.owedToMe) }
    if choice.lifestyles.contains(.student) { tiles.append(.limits) }
    return tiles
  }

  /// The categories the choice brings, in order and without repeats: the new-database
  /// categories first, then each way of living in the order of `Lifestyle`.
  public static func categorySeeds(for choice: StarterChoice) -> [CategorySeed] {
    var seeds = newDatabaseSeeds
    for lifestyle in Lifestyle.allCases where choice.lifestyles.contains(lifestyle) {
      for seed in categories(of: lifestyle)
      where !seeds.contains(where: {
        $0.kind == seed.kind && $0.english == seed.english && $0.parentEnglish == seed.parentEnglish
      }) {
        seeds.append(seed)
      }
    }
    return seeds
  }

  /// What the choice would add to a database holding `existing` categories (archived ones
  /// too), `budgets` and the Overview `tiles`. A category is there already when one of the same
  /// kind under the same parent has its English or Russian name (case and «ё» aside), archived
  /// or not; a missing parent is added too when the set has it, and a category whose parent is
  /// nowhere or in the archive is left out. A limit goes only on a category without one, never on a category of
  /// the app; the first limit of a category wins.
  public static func additions(
    for choice: StarterChoice, language: String, existing: [CoreKit.Category],
    budgets: [Budget], tiles: [OverviewTile], startMonth: MonthKey,
    idGenerator: () -> UUID = UUID.init
  ) -> StarterAdditions {
    let russian = language.lowercased().hasPrefix("ru")
    var all = existing
    var added: [CoreKit.Category] = []
    let seeds = categorySeeds(for: choice)
    let catalog = SampleCatalog.categorySeeds + seeds

    func names(of english: String, kind: CategoryKind) -> Set<String> {
      var result: Set<String> = [NameKey.fold(english)]
      for seed in catalog where seed.kind == kind && seed.english == english {
        result.insert(NameKey.fold(seed.russian))
      }
      return result
    }
    func find(_ english: String, parent: UUID?, kind: CategoryKind) -> CoreKit.Category? {
      let wanted = names(of: english, kind: kind)
      return all.first {
        $0.kind == kind && $0.parentId == parent && wanted.contains(NameKey.fold($0.name))
      }
    }
    func parentId(of seed: CategorySeed) -> UUID?? {
      guard let parentEnglish = seed.parentEnglish else { return .some(nil) }
      guard let parent = find(parentEnglish, parent: nil, kind: seed.kind), !parent.archived
      else { return nil }
      return .some(parent.id)
    }

    for seed in seeds {
      guard let parent = parentId(of: seed) else { continue }
      guard find(seed.english, parent: parent, kind: seed.kind) == nil else { continue }
      let siblings = all.filter { $0.kind == seed.kind && $0.parentId == parent }
      let category = CoreKit.Category(
        id: idGenerator(), parentId: parent, kind: seed.kind,
        name: russian ? seed.russian : seed.english,
        sort: (siblings.map(\.sort).max() ?? -1) + 1,
        quality: seed.kind == .income
          ? nil : (parent == nil ? (seed.quality ?? .neutral) : seed.quality))
      all.append(category)
      added.append(category)
    }

    var limited = Set(budgets.compactMap { $0.scope == .category ? $0.categoryId : nil })
    var newBudgets: [Budget] = []
    for lifestyle in Lifestyle.allCases where choice.lifestyles.contains(lifestyle) {
      for limit in limits(of: lifestyle) {
        let parent: UUID?
        if let parentEnglish = limit.parentEnglish {
          guard let found = find(parentEnglish, parent: nil, kind: .expense) else { continue }
          parent = found.id
        } else {
          parent = nil
        }
        guard let category = find(limit.categoryEnglish, parent: parent, kind: .expense),
          category.systemRole == nil, !category.archived, !limited.contains(category.id)
        else { continue }
        limited.insert(category.id)
        newBudgets.append(
          Budget(
            id: idGenerator(), scope: .category, categoryId: category.id,
            amountE4: AmountE4(raw: limit.rubles * AmountE4.unitsPerWhole), startMonth: startMonth))
      }
    }

    var room = OverviewTiles.maximum - tiles.count
    var newTiles: [OverviewTile] = []
    for tile in Self.tiles(for: choice) where !tiles.contains(tile) && !newTiles.contains(tile) {
      guard room > 0 else { break }
      newTiles.append(tile)
      room -= 1
    }
    return StarterAdditions(categories: added, budgets: newBudgets, tiles: newTiles)
  }
}
