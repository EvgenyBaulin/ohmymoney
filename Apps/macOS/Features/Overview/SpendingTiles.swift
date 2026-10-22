import AppCore
import SwiftUI

/// The words of the tiles «Цена выходных» and «Обычный день»: from the very figures «Почему так»
/// explains (`WeekendTileFigure`, `UsualDay`), apart from the views so a test reads them in
/// both languages.
@MainActor
enum SpendingTileText {
  enum Result: Equatable {
    case figure(OverviewTileFigure)
    /// Why there is no figure, in words.
    case empty(String)
  }

  static func result(
    of tile: OverviewTile, snapshot: DataSnapshot, _ environment: AppEnvironment
  ) -> Result {
    switch tile {
    case .weekendPrice: weekend(snapshot, environment)
    case .usualDay: usual(snapshot, environment)
    default: .empty(environment.language("overview.noData", table: "Overview"))
    }
  }

  private static func t(_ key: String, _ environment: AppEnvironment) -> String {
    SpendingText.t(key, environment)
  }

  static func weekend(_ snapshot: DataSnapshot, _ environment: AppEnvironment) -> Result {
    let figure = SpendingTileCache.shared.weekend(for: snapshot)
    guard !figure.isEmpty else { return .empty(t("spending.tile.weekend.none", environment)) }
    let money = environment.money
    var details: [String] = []
    details.append(
      SpendingText.format(
        "spending.tile.weekend.previous", environment, money.rounded(figure.previous)))
    return .figure(
      .init(
        value: money.rounded(figure.weekend),
        caption: figure.share.map {
          SpendingText.format(
            "spending.tile.weekend.share", environment,
            money.percent(basisPoints: $0, fractionDigits: 0))
        },
        symbol: "sun.max", details: details))
  }

  static func usual(_ snapshot: DataSnapshot, _ environment: AppEnvironment) -> Result {
    let usual = SpendingTileCache.shared.usualDay(for: snapshot)
    guard let overall = usual.overall.amount else {
      return .empty(
        SpendingText.format(
          "spending.tile.usual.lowData", environment, usual.overall.daysWithSpending,
          UsualDay.minimumDays))
    }
    let money = environment.money
    func line(_ key: String, _ figure: UsualDay.Figure) -> String {
      figure.amount.map {
        SpendingText.format(key, environment, money.rounded($0), figure.daysWithSpending)
      }
        ?? SpendingText.format(
          "spending.usual.low", environment, figure.daysWithSpending, UsualDay.minimumDays)
    }
    return .figure(
      .init(
        value: money.rounded(overall), caption: nil, symbol: "calendar.day.timeline.left",
        details: [
          line("spending.tile.usual.weekdays", usual.weekdays),
          line("spending.tile.usual.weekends", usual.weekends),
        ]))
  }
}

/// The figures of the two tiles, counted once per version of the data (a pass over the rows of a
/// month and of 90 days), shared by the tile and by «Почему так».
@MainActor
final class SpendingTileCache {
  static let shared = SpendingTileCache()
  private var weekendCache: (DataVersion, DateOnly, WeekendWindow, WeekendTileFigure)?
  private var usualCache: (DataVersion, DateOnly, WeekendWindow, UsualDay)?

  init() {}

  func reset() {
    weekendCache = nil
    usualCache = nil
  }

  func weekend(for snapshot: DataSnapshot) -> WeekendTileFigure {
    let window = snapshot.dataset.weekendWindow
    if let cached = weekendCache, cached.0 == snapshot.version, cached.1 == snapshot.today,
      cached.2 == window
    {
      return cached.3
    }
    let figure = WeekendTileFigure(ledger: snapshot.ledger, today: snapshot.today)
    weekendCache = (snapshot.version, snapshot.today, window, figure)
    return figure
  }

  func usualDay(for snapshot: DataSnapshot) -> UsualDay {
    let window = snapshot.dataset.weekendWindow
    if let cached = usualCache, cached.0 == snapshot.version, cached.1 == snapshot.today,
      cached.2 == window
    {
      return cached.3
    }
    let usual = UsualDay(
      ledger: snapshot.ledger, today: snapshot.today, window: window,
      oneOff: snapshot.dataset.oneOffMarks)
    usualCache = (snapshot.version, snapshot.today, window, usual)
    return usual
  }
}

/// «Цена выходных» and «Обычный день» on Overview: the figure big, a caption, the detail lines on
/// a regular card; compact — the figure and the caption alone, two to a cell.
struct SpendingFigureTileCard: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  let tile: OverviewTile
  var compact = false

  var body: some View {
    ComputedBlock(
      title: OverviewTileText.name(of: tile, environment),
      state: compute.states.data.flatMap { snapshot, at in
        result(snapshot).figure == nil ? .notEnoughData : .ready(snapshot, at: at)
      },
      fillsHeight: true,
      emptyReason: compute.snapshot.flatMap { result($0).reason },
      retry: { compute.retry(ComputeStep.data) }
    ) { snapshot in
      if let figure = result(snapshot).figure {
        VStack(alignment: .leading, spacing: 4) {
          HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let symbol = figure.symbol {
              Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            }
            Text(verbatim: figure.value)
              .appFont(compact ? .title3.monospacedDigit() : .title2.monospacedDigit())
              .lineLimit(compact ? 2 : 1)
              .minimumScaleFactor(0.7)
              .accessibilityIdentifier("overview.\(tile.rawValue).figure")
          }
          if let caption = figure.caption {
            Text(verbatim: caption)
              .appFont(.caption.monospacedDigit())
              .foregroundStyle(.secondary)
              .lineLimit(compact ? 2 : 3)
              .fixedSize(horizontal: false, vertical: true)
          }
          if !compact {
            ForEach(figure.details, id: \.self) { line in
              Text(verbatim: line)
                .appFont(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
          }
        }
        .accessibilityElement(children: .combine)
      }
    }
  }

  private func result(_ snapshot: DataSnapshot) -> SpendingTileText.Result {
    SpendingTileText.result(of: tile, snapshot: snapshot, environment)
  }
}

extension SpendingTileText.Result {
  var figure: OverviewTileFigure? {
    if case .figure(let figure) = self { return figure }
    return nil
  }

  var reason: String? {
    if case .empty(let reason) = self { return reason }
    return nil
  }
}
