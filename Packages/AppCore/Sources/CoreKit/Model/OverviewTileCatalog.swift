import Foundation

/// A function of the app a tile depends on. A tile that shows itself (`OverviewCatalogItem.showsItself`)
/// appears on Overview as soon as its function has data, and stays out of the way before.
public enum OverviewFeature: String, CaseIterable, Sendable, Hashable, Codable {
  /// Parts paid for others, deposits and pledges still owed to me.
  case owedToMe
  /// A debt of mine.
  case iOwe
  /// An income expected and not yet received.
  case expectedIncome
  /// A scheduled payment whose day has passed.
  case overdue
  /// A credit card.
  case creditCard
  /// The trip mode is on.
  case trip
  /// A deposit that pays interest.
  case deposit
  /// A salary is set up.
  case salary
  /// An income waiting to be allocated.
  case incomeToAllocate
  /// Money in more than one currency.
  case multiCurrency
  /// The limit of a «small purchase» is set.
  case smallLimit
}

/// What the app knows about the owner's books that decides which self-showing tiles appear.
/// Plain flags, filled from the books by the app, so the rule itself is tested without a window.
public struct OverviewFacts: Hashable, Sendable {
  public var features: Set<OverviewFeature>

  public init(_ features: Set<OverviewFeature> = []) {
    self.features = features
  }

  public func has(_ feature: OverviewFeature) -> Bool { features.contains(feature) }

  public static let none = OverviewFacts()
}

/// One tile of the owner's list of 2.0, by its number there. A tile that is not built yet has no
/// `tile`: the catalog lists it as «в работе» and nothing can put it on Overview.
public struct OverviewCatalogItem: Hashable, Sendable, Identifiable {
  /// The number in the list the owner chose from.
  public var number: Int
  /// The tile on Overview; `nil` while the tile is not built.
  public var tile: OverviewTile?
  /// The group it stands in until moved.
  public var group: OverviewTileGroup
  /// It can be put in a pair: one figure and a caption.
  public var canBeCompact: Bool
  /// A chart or a list: always the whole width, never compact, never in a pair.
  public var isWide: Bool
  /// The function it depends on.
  public var needs: OverviewFeature?
  /// It appears by itself once `needs` has data.
  public var showsItself: Bool

  public var id: Int { number }

  /// The tile is built and can be shown.
  public var isAvailable: Bool { tile != nil }

  /// The key of its name in the Overview catalog of strings.
  public var nameKey: String {
    tile.map { "overview.tile.\($0.rawValue)" } ?? "overview.tile.stub.\(number)"
  }

  /// Whether the tile shows with `facts`: always unless it shows itself — then when its function
  /// has data.
  public func isVisibleByItself(_ facts: OverviewFacts) -> Bool {
    guard showsItself, let needs else { return true }
    return facts.has(needs)
  }
}

/// Two tiles that are good side by side, by their numbers: «Можно ставить рядом».
public struct OverviewPairSuggestion: Hashable, Sendable, Identifiable {
  public var first: Int
  public var second: Int

  public var id: String { "\(first)+\(second)" }

  /// Both tiles, when both are built.
  public var tiles: (OverviewTile, OverviewTile)? {
    guard let a = OverviewCatalog.item(number: first)?.tile,
      let b = OverviewCatalog.item(number: second)?.tile
    else { return nil }
    return (a, b)
  }
}

/// The catalog of Overview: the 48 tiles the owner chose from the 100 drawn for them, and the
/// six tiles of the first versions they did not choose and that stay (10, 11, 15, 17, 18, 24).
/// Data, not code: the rules around it read these rows.
public enum OverviewCatalog {
  private static func row(
    _ number: Int, _ tile: OverviewTile?, _ group: OverviewTileGroup, compact: Bool = false,
    wide: Bool = false, needs: OverviewFeature? = nil, itself: Bool = false
  ) -> OverviewCatalogItem {
    OverviewCatalogItem(
      number: number, tile: tile, group: group, canBeCompact: compact && !wide, isWide: wide,
      needs: needs, showsItself: itself)
  }

  public static let items: [OverviewCatalogItem] = [
    row(1, .monthToDate, .money),
    row(2, .canSave, .money),
    row(3, .balanceForecast, .money),
    row(4, .owedToMe, .money, compact: true, needs: .owedToMe, itself: true),
    row(5, .iOwe, .money, compact: true, needs: .iOwe, itself: true),
    row(6, .lastCount, .money, compact: true),
    row(7, .lastRecord, .money, compact: true),
    row(8, .lastCountAndRecord, .money),
    row(9, .freeMoney, .money),
    row(10, .capital, .money),
    row(11, .cushion, .money),
    row(12, .limits, .plan),
    row(13, .upcoming, .plan, compact: true),
    row(14, .expectedIncome, .plan, needs: .expectedIncome, itself: true),
    row(15, .event, .plan),
    row(16, .spendingCalendar, .plan),
    row(17, .installments, .plan),
    row(18, .selfEmployment, .plan),
    row(19, .topCategories, .analysis),
    row(20, .qualities, .analysis),
    row(21, .spendingForecast, .analysis),
    row(22, .incomeForecast, .analysis),
    row(23, .worthALook, .analysis),
    row(24, .currencyChart, .analysis),
    row(27, .currencyBalances, .money, needs: .multiCurrency, itself: true),
    row(31, .spendToday, .money, compact: true),
    row(32, .weekOverWeek, .money, compact: true),
    row(33, .averageDaily, .money, compact: true),
    row(34, .monthIncome, .money, compact: true),
    row(35, .savingsRate, .money, compact: true),
    row(38, nil, .money, compact: true, needs: .salary, itself: true),
    row(39, nil, .money, needs: .salary, itself: true),
    row(40, nil, .money, compact: true, needs: .salary, itself: true),
    row(48, nil, .money, needs: .deposit, itself: true),
    row(51, nil, .plan, compact: true),
    row(52, nil, .plan),
    row(55, nil, .plan, needs: .overdue, itself: true),
    row(58, nil, .plan, needs: .iOwe, itself: true),
    row(62, nil, .plan, needs: .creditCard, itself: true),
    row(67, nil, .plan, needs: .trip, itself: true),
    row(68, nil, .plan, needs: .trip, itself: true),
    row(70, .monthRest, .plan, compact: true),
    row(71, nil, .plan, needs: .incomeToAllocate, itself: true),
    row(73, .weekdaySpending, .analysis, wide: true),
    row(74, .monthlySpending, .analysis, wide: true),
    row(75, .incomeSources, .analysis, wide: true),
    row(76, .topPlaces, .analysis, wide: true),
    row(77, .spendingByPerson, .analysis, wide: true),
    row(79, .categoryGrew, .analysis),
    row(80, .categoryShrank, .analysis),
    row(88, .smallPurchases, .analysis, compact: true, needs: .smallLimit, itself: true),
    row(96, .backups, .analysis, compact: true),
    row(97, .integrity, .analysis, compact: true),
    row(98, .ratesStatus, .analysis, compact: true, needs: .multiCurrency, itself: true),
  ]

  /// The numbers the owner chose, for the record: 48 of the 100.
  public static let chosenNumbers: Set<Int> = [
    1, 2, 3, 4, 5, 6, 7, 8, 9, 12, 13, 14, 16, 19, 20, 21, 22, 23, 27, 31, 32, 33, 34, 35, 38,
    39, 40, 48, 51, 52, 55, 58, 62, 67, 68, 70, 71, 73, 74, 75, 76, 77, 79, 80, 88, 96, 97, 98,
  ]

  public static func item(number: Int) -> OverviewCatalogItem? {
    items.first { $0.number == number }
  }

  public static func item(of tile: OverviewTile) -> OverviewCatalogItem? {
    items.first { $0.tile == tile }
  }

  /// The tiles not built yet: listed in «Добавить плитку» as «в работе».
  public static var unbuilt: [OverviewCatalogItem] { items.filter { !$0.isAvailable } }

  /// The tiles that can be on Overview.
  public static var built: [OverviewCatalogItem] { items.filter(\.isAvailable) }

  /// The pairs offered in «Добавить плитку».
  public static let suggestedPairs: [OverviewPairSuggestion] = [
    .init(first: 4, second: 5), .init(first: 31, second: 33), .init(first: 34, second: 35),
    .init(first: 38, second: 40), .init(first: 6, second: 7), .init(first: 13, second: 51),
    .init(first: 96, second: 97),
  ]

  /// Who a tile is paired with in the suggestions, by their numbers: «Можно ставить рядом».
  public static func suggestedPartner(of tile: OverviewTile) -> OverviewTile? {
    guard let number = item(of: tile)?.number else { return nil }
    for pair in suggestedPairs {
      if pair.first == number { return item(number: pair.second)?.tile }
      if pair.second == number { return item(number: pair.first)?.tile }
    }
    return nil
  }

  /// A tile can be compact: it is in the catalog as one.
  public static func canBeCompact(_ tile: OverviewTile) -> Bool {
    item(of: tile)?.canBeCompact ?? false
  }

  /// A tile is a chart or a list: the whole width.
  public static func isWide(_ tile: OverviewTile) -> Bool {
    item(of: tile)?.isWide ?? false
  }

  /// The tile shows itself once its function has data.
  public static func showsItself(_ tile: OverviewTile) -> Bool {
    item(of: tile)?.showsItself ?? false
  }

  /// The tiles an owner who never chose sees: the ten of the answer, in their order.
  public static let firstRunTiles: [OverviewTile] = [
    .monthToDate, .freeMoney, .canSave, .balanceForecast, .upcoming, .limits, .monthRest,
    .topCategories, .qualities, .worthALook,
  ]
}
