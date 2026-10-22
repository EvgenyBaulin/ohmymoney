import Foundation

/// A tile of Overview the owner can show. The raw value is what the setting `overview.tiles` and
/// the archive keep: a case is never renamed. The cases are in the order the settings list them.
public enum OverviewTile: String, CaseIterable, Sendable, Hashable, Codable {
  /// «С начала месяца»: spending, income and their difference from the 1st to today.
  case monthToDate
  /// «Топ категорий»: the largest categories of my spending this month, «Сверка» left out.
  case topCategories
  /// «Хорошие и плохие».
  case qualities
  /// «Можно отложить».
  case canSave
  /// «Прогноз расхода до конца месяца».
  case spendingForecast
  /// «Прогноз дохода до конца месяца».
  case incomeForecast
  /// «Прогноз остатка до конца месяца»: the money of the accounts in the summary at the end of
  /// the month.
  case balanceForecast
  /// «Лимиты».
  case limits
  /// «Платежи на 7 дней».
  case upcoming
  /// «Ожидаемые поступления».
  case expectedIncome
  /// «Мне должны».
  case owedToMe
  /// «Я должен».
  case iOwe
  /// «Событие».
  case event
  /// «Последняя сверка».
  case lastCount
  /// «Последняя операция».
  case lastRecord
  /// «Последняя сверка и операция», one tile for both.
  case lastCountAndRecord
  /// «Стоит посмотреть».
  case worthALook
  /// «Свободные средства».
  case freeMoney
  /// «График валюты»: a pair of currencies over a week, a month or a year.
  case currencyChart
  /// «Календарь»: the days of this week with my spending of each, and what is planned ahead.
  case spendingCalendar
  /// «Капитал»: what I have minus what I owe, and how it changed this month.
  case capital
  /// «Подушка безопасности»: how many months the cushion money lasts without income.
  case cushion
  /// «Рассрочки»: what the instalment plans and purchases on credit still ask, and the next
  /// payments.
  case installments
  /// «Самозанятость»: the income of the month, the tax to pay and the limit of the year.
  case selfEmployment

  // The tiles of 2.0: each counts from what the books already hold (`OverviewFigures`), and
  // none is shown to an owner who did not ask for it (`isShownUnnamed`).

  /// «Деньги по валютам» (27): the money of the accounts in the summary, by currency, in rubles.
  case currencyBalances
  /// «Расход сегодня» (31): today's spending against an ordinary day.
  case spendToday
  /// «Неделя к неделе» (32): the spending of this week against the same days of the last one.
  case weekOverWeek
  /// «Средний расход в день» (33): the month so far per day.
  case averageDaily
  /// «Доход месяца» (34): what came this month and what is still expected.
  case monthIncome
  /// «Норма сбережений» (35): the share of the income put aside this month.
  case savingsRate
  /// «Остаток месяца» (70): what is left of the month just past and where to put it.
  case monthRest
  /// «Расходы по дням недели» (73).
  case weekdaySpending
  /// «Расходы по месяцам» (74): the last twelve months.
  case monthlySpending
  /// «Доходы по источникам» (75).
  case incomeSources
  /// «Топ мест» (76).
  case topPlaces
  /// «Траты по людям» (77): my spending by «на кого».
  case spendingByPerson
  /// «Категория выросла сильнее всего» (79).
  case categoryGrew
  /// «Категория сократилась» (80).
  case categoryShrank
  /// «Мелкие покупки» (88): the small purchases of the month, up to a limit the owner sets.
  case smallPurchases
  /// «Резервные копии» (96): when the last copy of the database was made.
  case backups
  /// «Проверка базы» (97): the result of the last check.
  case integrity
  /// «Курсы ЦБ» (98): how fresh the rates are.
  case ratesStatus

  // The tiles of 2.1, numbered after the hundred of the first list (`OverviewCatalog.laterNumbers`).

  /// «Цена выходных» (101): what the weekend of the settings cost this month.
  case weekendPrice
  /// «Обычный день» (102): the usual day of spending, weekdays and weekends told apart.
  case usualDay
  // The tile of 2.2, waiting hidden like the tiles of 2.0 until the owner adds it.

  /// «Финансовое здоровье»: one number 0–100 and what it is made of.
  case financialHealth
}

extension OverviewTile: Identifiable {
  public var id: Self { self }
}

extension OverviewTile {
  /// The group a tile stands in until the owner moves it: what money there is, what is planned
  /// ahead, what the month says.
  public var defaultGroup: OverviewTileGroup {
    switch self {
    case .monthToDate, .canSave, .balanceForecast, .owedToMe, .iOwe, .lastCount, .lastRecord,
      .lastCountAndRecord, .freeMoney, .capital, .cushion, .currencyBalances, .spendToday,
      .weekOverWeek, .averageDaily, .monthIncome, .savingsRate:
      return .money
    case .limits, .upcoming, .expectedIncome, .event, .spendingCalendar, .installments,
      .selfEmployment, .monthRest:
      return .plan
    case .topCategories, .qualities, .spendingForecast, .incomeForecast, .worthALook,
      .currencyChart, .weekdaySpending, .monthlySpending, .incomeSources, .topPlaces,
      .spendingByPerson, .categoryGrew, .categoryShrank, .smallPurchases, .backups, .integrity,
      .ratesStatus, .weekendPrice, .usualDay, .financialHealth:
      return .analysis
    }
  }
}

extension OverviewTile {
  /// Whether the tile is shown where a layout does not name it — an owner who never chose, a
  /// layout kept before the tile existed. The tiles that came with the credits, the
  /// self-employment and 2.0 wait hidden until the owner adds them: an owner's choice never
  /// changes because a build brought new tiles.
  public var isShownUnnamed: Bool {
    switch self {
    case .installments, .selfEmployment, .currencyBalances, .spendToday, .weekOverWeek,
      .averageDaily, .monthIncome, .savingsRate, .monthRest, .weekdaySpending, .monthlySpending,
      .incomeSources, .topPlaces, .spendingByPerson, .categoryGrew, .categoryShrank,
      .smallPurchases, .backups, .integrity, .ratesStatus, .weekendPrice, .usualDay,
      .financialHealth:
      false
    default: true
    }
  }
}

/// A group of tiles on Overview: «Деньги», «План», «Анализ». The groups are fixed — the owner
/// orders them and moves tiles between them, never renames, adds or removes one. The raw value
/// is what the layout keeps: a case is never renamed.
public enum OverviewTileGroup: String, CaseIterable, Sendable, Hashable, Codable, Identifiable {
  case money
  case plan
  case analysis

  public var id: Self { self }
}

/// Which tiles Overview shows and in what order, as a flat list — the form the setting
/// `overview.tiles` kept before the tiles stood in groups, read now only where no layout was
/// kept yet (`OverviewLayout`) and written beside the layout for a build that knows only the
/// list. Whatever the stored text says it reads as a list the grid can show: known tiles, each
/// once, at least one.
public enum OverviewTiles {
  /// How many tiles the grid shows at most: every one of them — there is no limit any more, and
  /// a list of every tile is a list the grid shows.
  public static let maximum = OverviewTile.allCases.count

  /// The tiles Overview had before they could be chosen, in their order: they come first for an
  /// owner who never chose, the rest after them (`OverviewLayout.init(tiles:)`).
  public static let standard: [OverviewTile] = [
    .monthToDate, .topCategories, .qualities, .canSave, .spendingForecast, .limits, .upcoming,
    .expectedIncome, .owedToMe, .event, .lastCount, .worthALook,
  ]

  /// The choice kept as text; nothing, an empty text or one that names no known tile is the
  /// standard choice.
  public static func decode(_ stored: String?) -> [OverviewTile] {
    guard let stored else { return standard }
    let tiles = stored.split(separator: ",", omittingEmptySubsequences: true).compactMap {
      OverviewTile(rawValue: $0.trimmingCharacters(in: .whitespaces))
    }
    return sanitized(tiles)
  }

  /// The raw values in their order, joined by commas: «monthToDate,topCategories,…».
  public static func encode(_ tiles: [OverviewTile]) -> String {
    tiles.map(\.rawValue).joined(separator: ",")
  }

  /// A choice the grid can show: a tile named twice keeps its first place, the tiles past the
  /// `maximum` go, and no tile at all is the standard choice.
  public static func sanitized(_ tiles: [OverviewTile]) -> [OverviewTile] {
    var result: [OverviewTile] = []
    for tile in tiles where !result.contains(tile) && result.count < maximum {
      result.append(tile)
    }
    return result.isEmpty ? standard : result
  }

  /// Whether `tile` can be switched on: it is not shown yet and the grid has room for it.
  public static func canAdd(_ tile: OverviewTile, to tiles: [OverviewTile]) -> Bool {
    !tiles.contains(tile) && tiles.count < maximum
  }

  /// Whether `tile` can be switched off: it is shown, and it is not the last one.
  public static func canRemove(_ tile: OverviewTile, from tiles: [OverviewTile]) -> Bool {
    tiles.contains(tile) && tiles.count > 1
  }

  /// The choice with `tile` switched on, at the end; `nil` when it is shown already.
  public static func adding(_ tile: OverviewTile, to tiles: [OverviewTile]) -> [OverviewTile]? {
    guard canAdd(tile, to: tiles) else { return nil }
    return tiles + [tile]
  }

  /// The choice with `tile` switched off; `nil` when it cannot be — the last tile stays.
  public static func removing(
    _ tile: OverviewTile, from tiles: [OverviewTile]
  ) -> [OverviewTile]? {
    guard canRemove(tile, from: tiles) else { return nil }
    return tiles.filter { $0 != tile }
  }

  /// The choice after rows were dragged, as a list moves them: the rows at `source` go before the
  /// row that was at `destination` — counted before they left —, or to the end. Indices outside
  /// the choice are passed over; nothing is lost.
  public static func moving(
    _ tiles: [OverviewTile], from source: IndexSet, to destination: Int
  ) -> [OverviewTile] {
    let moved = source.filter { tiles.indices.contains($0) }
    guard !moved.isEmpty else { return tiles }
    let target = min(max(destination, 0), tiles.count)
    let taken = moved.map { tiles[$0] }
    var rest: [OverviewTile] = []
    var insertion = 0
    for (index, tile) in tiles.enumerated() {
      if index == target { insertion = rest.count }
      if !moved.contains(index) { rest.append(tile) }
    }
    if target == tiles.count { insertion = rest.count }
    rest.insert(contentsOf: taken, at: insertion)
    return rest
  }

  /// The choice after `tile` was dragged onto the row of `target`: it takes the place of the
  /// target, which moves one row towards where the tile came from — a tile dragged down lands
  /// after it, dragged up before it. A tile or a target not shown, or a tile dropped on itself,
  /// leaves the choice as it was.
  public static func dropping(
    _ tile: OverviewTile, onto target: OverviewTile, in tiles: [OverviewTile]
  ) -> [OverviewTile] {
    guard tile != target, let from = tiles.firstIndex(of: tile),
      let to = tiles.firstIndex(of: target)
    else { return tiles }
    return moving(tiles, from: IndexSet(integer: from), to: from < to ? to + 1 : to)
  }

  /// The choice is the standard one: «Сбросить» has nothing to do.
  public static func isStandard(_ tiles: [OverviewTile]) -> Bool {
    tiles == standard
  }
}
