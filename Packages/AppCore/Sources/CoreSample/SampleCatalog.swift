import CoreKit
import Foundation

/// Declarative seed for one starter category: its name in both interface languages, its
/// optional parent (by English name, within the same `kind`), and the defaults the app
/// assigns on first launch.
///
/// `quality` is the *override* for this entry. Top-level categories that leave it `nil`
/// fall back to `neutral` when the tree is built; subcategories that leave it `nil` stay
/// `nil` so they inherit their parent's quality, exactly as the schema comment on
/// `categories.quality` describes it.
public struct CategorySeed: Sendable {
  public let english: String
  public let russian: String
  public let parentEnglish: String?
  public let kind: CategoryKind
  public let systemRole: SystemRole?
  public let quality: Quality?

  public init(
    english: String,
    russian: String,
    parentEnglish: String? = nil,
    kind: CategoryKind,
    systemRole: SystemRole? = nil,
    quality: Quality? = nil
  ) {
    self.english = english
    self.russian = russian
    self.parentEnglish = parentEnglish
    self.kind = kind
    self.systemRole = systemRole
    self.quality = quality
  }
}

/// Starter category tree, shared by first-run seeding (`StarterCategories.tree` in the app,
/// which numbers `sort` over the whole list), the sample data generator and screenshots:
/// one declarative list feeds all three, so they can never drift apart.
public enum SampleCatalog {
  /// One row per category, expenses first then income, every top-level category
  /// immediately followed by its subcategories — the order `makeCategories` also uses
  /// to number `sort`.
  public static let categorySeeds: [CategorySeed] = expenseSeeds + incomeSeeds

  /// Builds the starter category tree in the given interface language ("en" or "ru"),
  /// with `id`, `parentId` and per-parent `sort` filled in.
  ///
  /// `idGenerator` defaults to a fresh random `UUID` per category, which is what a real
  /// first launch wants. The sample data generator instead passes a seeded generator so
  /// the whole synthetic dataset stays byte-for-byte reproducible.
  public static func makeCategories(
    language: String,
    seeds categorySeeds: [CategorySeed] = categorySeeds,
    idGenerator: () -> UUID = UUID.init
  ) -> [CoreKit.Category] {
    let useRussian = language.lowercased().hasPrefix("ru")
    var idsByKey: [SeedKey: UUID] = [:]
    var nextSortByParent: [ParentKey: Int] = [:]
    var categories: [CoreKit.Category] = []
    categories.reserveCapacity(categorySeeds.count)

    for seed in categorySeeds {
      let id = idGenerator()
      idsByKey[SeedKey(kind: seed.kind, english: seed.english)] = id

      let parentId = seed.parentEnglish.flatMap {
        idsByKey[SeedKey(kind: seed.kind, english: $0)]
      }
      let parentKey = ParentKey(kind: seed.kind, parentEnglish: seed.parentEnglish)
      let sort = nextSortByParent[parentKey, default: 0]
      nextSortByParent[parentKey] = sort + 1

      let quality: Quality?
      if seed.kind == .income {
        // Income never carries a quality.
        quality = nil
      } else if let explicit = seed.quality {
        quality = explicit
      } else if seed.parentEnglish == nil {
        // Every top-level expense category has an explicit quality; unlisted ones
        // default to `neutral`.
        quality = .neutral
      } else {
        // Subcategories with no override inherit the parent's quality.
        quality = nil
      }

      categories.append(
        CoreKit.Category(
          id: id,
          parentId: parentId,
          kind: seed.kind,
          name: useRussian ? seed.russian : seed.english,
          sort: sort,
          quality: quality,
          systemRole: seed.systemRole))
    }
    return categories
  }

  private struct SeedKey: Hashable {
    let kind: CategoryKind
    let english: String
  }

  private struct ParentKey: Hashable {
    let kind: CategoryKind
    let parentEnglish: String?
  }

  private static let expenseSeeds: [CategorySeed] = [
    .init(english: "Groceries", russian: "Продукты", kind: .expense),

    .init(english: "Food out", russian: "Еда вне дома", kind: .expense),
    .init(english: "Coffee shops", russian: "Кофейни", parentEnglish: "Food out", kind: .expense),
    .init(english: "Fast food", russian: "Фастфуд", parentEnglish: "Food out", kind: .expense),
    .init(
      english: "Restaurants", russian: "Рестораны", parentEnglish: "Food out", kind: .expense),
    .init(
      english: "Food delivery", russian: "Доставка еды", parentEnglish: "Food out",
      kind: .expense),

    .init(english: "Transport", russian: "Транспорт", kind: .expense),
    .init(english: "Taxi", russian: "Такси", parentEnglish: "Transport", kind: .expense),
    .init(
      english: "Public transport", russian: "Общественный транспорт",
      parentEnglish: "Transport", kind: .expense),
    .init(
      english: "Carsharing", russian: "Каршеринг", parentEnglish: "Transport", kind: .expense),
    .init(english: "Scooters", russian: "Самокаты", parentEnglish: "Transport", kind: .expense),

    .init(english: "Car", russian: "Машина", kind: .expense),
    .init(english: "Fuel", russian: "Топливо", parentEnglish: "Car", kind: .expense),
    .init(english: "Parking", russian: "Парковка", parentEnglish: "Car", kind: .expense),
    .init(english: "Car wash", russian: "Мойка", parentEnglish: "Car", kind: .expense),
    .init(
      english: "Toll roads", russian: "Платные дороги", parentEnglish: "Car", kind: .expense),
    .init(
      english: "Fines", russian: "Штрафы", parentEnglish: "Car", kind: .expense, quality: .bad),
    .init(
      english: "Maintenance", russian: "Обслуживание", parentEnglish: "Car", kind: .expense),
    .init(english: "Insurance", russian: "Страховка", parentEnglish: "Car", kind: .expense),
    .init(english: "Tires", russian: "Шины", parentEnglish: "Car", kind: .expense),
    .init(
      english: "Accessories", russian: "Аксессуары", parentEnglish: "Car", kind: .expense),
    .init(
      english: "Consumables", russian: "Расходники", parentEnglish: "Car", kind: .expense),

    .init(english: "Home", russian: "Дом", kind: .expense),
    .init(english: "Rent", russian: "Аренда", parentEnglish: "Home", kind: .expense),
    .init(
      english: "Utilities", russian: "Коммунальные услуги", parentEnglish: "Home",
      kind: .expense),
    .init(
      english: "Household", russian: "Товары для дома", parentEnglish: "Home", kind: .expense),
    .init(english: "Repairs", russian: "Ремонт", parentEnglish: "Home", kind: .expense),

    .init(
      english: "Subscriptions & services", russian: "Подписки и сервисы", kind: .expense),
    .init(
      english: "Mobile", russian: "Мобильная связь",
      parentEnglish: "Subscriptions & services", kind: .expense),
    .init(
      english: "Home internet", russian: "Домашний интернет",
      parentEnglish: "Subscriptions & services", kind: .expense),
    .init(
      english: "Cloud", russian: "Облако", parentEnglish: "Subscriptions & services",
      kind: .expense),
    .init(
      english: "AI services", russian: "ИИ-сервисы",
      parentEnglish: "Subscriptions & services", kind: .expense),
    .init(
      english: "Banking", russian: "Банковские подписки",
      parentEnglish: "Subscriptions & services", kind: .expense),
    .init(
      english: "Hosting", russian: "Серверы и хостинг",
      parentEnglish: "Subscriptions & services", kind: .expense),
    .init(
      english: "Messengers", russian: "Мессенджеры",
      parentEnglish: "Subscriptions & services", kind: .expense),

    .init(english: "Health", russian: "Здоровье", kind: .expense, quality: .good),
    .init(english: "Pharmacy", russian: "Аптека", parentEnglish: "Health", kind: .expense),
    .init(english: "Doctors", russian: "Врачи", parentEnglish: "Health", kind: .expense),
    .init(english: "Sport", russian: "Спорт", parentEnglish: "Health", kind: .expense),

    .init(english: "Beauty", russian: "Красота", kind: .expense),
    .init(english: "Clothing", russian: "Одежда и аксессуары", kind: .expense),
    .init(english: "Electronics", russian: "Электроника", kind: .expense),

    .init(english: "Entertainment", russian: "Развлечения", kind: .expense),
    .init(english: "Bars", russian: "Бары", parentEnglish: "Entertainment", kind: .expense),
    .init(english: "Clubs", russian: "Клубы", parentEnglish: "Entertainment", kind: .expense),
    .init(english: "Cinema", russian: "Кино", parentEnglish: "Entertainment", kind: .expense),
    .init(english: "Games", russian: "Игры", parentEnglish: "Entertainment", kind: .expense),

    .init(english: "Gifts", russian: "Подарки", kind: .expense),
    .init(english: "Travel", russian: "Путешествия", kind: .expense),
    .init(english: "Education", russian: "Образование", kind: .expense, quality: .good),

    .init(english: "Other", russian: "Прочее", kind: .expense),
    .init(
      english: "Fees", russian: "Комиссии", parentEnglish: "Other", kind: .expense,
      quality: .bad),

    .init(
      english: "Goals", russian: "Цели", kind: .expense, systemRole: .goals, quality: .good),
    .init(english: "Loans", russian: "Кредиты", kind: .expense, systemRole: .loans),
    .init(english: "Unknown", russian: "Не помню", kind: .expense, systemRole: .unknown),
  ]

  private static let incomeSeeds: [CategorySeed] = [
    .init(english: "Work", russian: "Заработок", kind: .income),
    .init(english: "Projects", russian: "Проекты", parentEnglish: "Work", kind: .income),
    .init(
      english: "Teaching & tutoring", russian: "Преподавание и репетиторство",
      parentEnglish: "Work", kind: .income),
    .init(english: "Side jobs", russian: "Подработка", parentEnglish: "Work", kind: .income),

    .init(english: "Family", russian: "Семья", kind: .income),

    .init(english: "Passive", russian: "Пассивный доход", kind: .income),
    .init(english: "Cashback", russian: "Кэшбэк", parentEnglish: "Passive", kind: .income),
    .init(
      english: "Interest", russian: "Проценты по вкладам и счетам", parentEnglish: "Passive",
      kind: .income),

    .init(english: "Gifts", russian: "Подарки", kind: .income),
    .init(english: "Sales", russian: "Продажа вещей", kind: .income),
    .init(english: "Other", russian: "Прочее", kind: .income),

    .init(english: "Surcharges", russian: "Доплаты", kind: .income, systemRole: .surcharges),
    .init(english: "Unknown", russian: "Не помню", kind: .income, systemRole: .unknown),
  ]
}
