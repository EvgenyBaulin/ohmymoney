import AppCore
import SwiftUI

/// The tiles of 2.0. Each reads what the figure store holds for the snapshot of the data step —
/// the core's figures, once — and puts it into words; «Почему так» reads the same figures.

// MARK: - A tile that is one figure

/// A tile of one figure: the figure big, a caption, and — on a regular card — the detail lines.
/// The compact card is the same without the details, so two stand in one cell.
struct FigureTileCard: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  let tile: OverviewTile
  var compact = false

  var body: some View {
    let store = OverviewFiguresStore.shared
    ComputedBlock(
      title: OverviewTileText.name(of: tile, environment),
      state: compute.states.data.flatMap { snapshot, at in
        result(snapshot, store).figure == nil ? .notEnoughData : .ready(snapshot, at: at)
      },
      fillsHeight: true,
      emptyReason: compute.snapshot.flatMap { result($0, store).emptyKey }.map {
        environment.language($0, table: OverviewFigureText.table)
      },
      retry: { compute.retry(ComputeStep.data) }
    ) { snapshot in
      if let figure = result(snapshot, store).figure {
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

  private func result(
    _ snapshot: DataSnapshot, _ store: OverviewFiguresStore
  )
    -> OverviewFigureResult
  {
    OverviewFigureText.result(
      of: tile, snapshot: snapshot, figures: store.figures(for: snapshot),
      system: store.systemStatus(for: snapshot, environment: environment), environment)
  }
}

// MARK: - Money by currency

/// «Деньги по валютам»: the money of the accounts in the summary by currency, in rubles at the
/// rate of the day, the biggest first.
struct CurrencyBalancesCard: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute

  var body: some View {
    ComputedBlock(
      title: OverviewTileText.name(of: .currencyBalances, environment),
      state: compute.states.data.flatMap { snapshot, at in
        OverviewCurrencyBalances(snapshot.planning.accounts).lines.isEmpty
          ? .notEnoughData : .ready(OverviewCurrencyBalances(snapshot.planning.accounts), at: at)
      },
      fillsHeight: true, emptyReason: t("overview.currencies.none"),
      retry: { compute.retry(ComputeStep.data) }
    ) { balances in
      VStack(alignment: .leading, spacing: 6) {
        Text(verbatim: environment.money.rounded(balances.totalRub))
          .appFont(.title2.monospacedDigit())
        ForEach(balances.lines.prefix(OverviewFigures.topCount), id: \.currency) { line in
          VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
              Text(verbatim: line.currency.code)
              if line.currency != .rub {
                Text(verbatim: environment.money.rounded(line.amount, currency: line.currency))
                  .foregroundStyle(.secondary)
              }
              Spacer(minLength: 8)
              Text(verbatim: environment.money.rounded(line.rub)).monospacedDigit()
              ShareText(basisPoints: Shares.ratio(line.rub, of: balances.totalRub))
            }
            .appFont(.callout)
            ShareBar(basisPoints: Shares.ratio(line.rub, of: balances.totalRub))
          }
          .accessibilityElement(children: .combine)
        }
        if !balances.withoutRate.isEmpty {
          Label {
            Text(
              verbatim: environment.format(
                "overview.currencies.withoutRate", table: OverviewTileText.table,
                balances.withoutRate.map(\.code).joined(separator: ", "))
            )
            .fixedSize(horizontal: false, vertical: true)
          } icon: {
            Image(systemName: "exclamationmark.triangle")
          }
          .appFont(.caption)
          .foregroundStyle(.secondary)
        }
      }
    }
  }

  private func t(_ key: String) -> String {
    environment.language(key, table: OverviewTileText.table)
  }
}

// MARK: - Charts and lists, the whole width

/// The base of a chart or a list tile: its figures from the store, its words, never more than
/// `OverviewFigures.topCount` lines.
private struct FiguresTile<Content: View>: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  let tile: OverviewTile
  /// The key of the sentence that says there is nothing, or `nil` when there is something.
  let emptyKey: (OverviewFigures) -> String?
  let content: (OverviewFigures, DataSnapshot) -> Content

  init(
    tile: OverviewTile, emptyKey: @escaping (OverviewFigures) -> String?,
    @ViewBuilder content: @escaping (OverviewFigures, DataSnapshot) -> Content
  ) {
    self.tile = tile
    self.emptyKey = emptyKey
    self.content = content
  }

  var body: some View {
    let store = OverviewFiguresStore.shared
    ComputedBlock(
      title: OverviewTileText.name(of: tile, environment),
      state: compute.states.data.flatMap { snapshot, at in
        emptyKey(store.figures(for: snapshot)) == nil ? .ready(snapshot, at: at) : .notEnoughData
      },
      fillsHeight: true,
      emptyReason: compute.snapshot.flatMap { emptyKey(store.figures(for: $0)) }.map {
        environment.language($0, table: OverviewTileText.table)
      },
      retry: { compute.retry(ComputeStep.data) }
    ) { snapshot in
      content(store.figures(for: snapshot), snapshot)
    }
  }
}

/// A line of a list: the name, the amount, the share, and a thin bar as long as the share.
private struct ShareLine: View {
  @Dependency(\.environment) private var environment
  let name: String
  let amount: AmountE4
  let basisPoints: Int?

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(verbatim: name)
          .lineLimit(1)
          .truncationMode(.tail)
        Spacer(minLength: 8)
        Text(verbatim: environment.money.rounded(amount)).monospacedDigit()
        ShareText(basisPoints: basisPoints)
      }
      .appFont(.callout)
      ShareBar(basisPoints: basisPoints)
    }
    .accessibilityElement(children: .combine)
  }
}

/// «Расходы по дням недели»: the last twelve weeks, a bar for each day as long as its share of
/// the spending, the day, the average of one such day and the total.
struct WeekdaySpendingCard: View {
  @Dependency(\.environment) private var environment

  var body: some View {
    FiguresTile(
      tile: .weekdaySpending,
      emptyKey: { $0.weekdays.total.raw > 0 ? nil : "overview.noSpendingYet" }
    ) { figures, _ in
      let weekdays = figures.weekdays
      VStack(alignment: .leading, spacing: 6) {
        ForEach(weekdays.days, id: \.weekday) { day in
          VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
              Text(verbatim: environment.dates.weekday(day.weekday))
              Spacer(minLength: 8)
              if let average = day.average {
                Text(
                  verbatim: environment.format(
                    "overview.weekday.average", table: OverviewTileText.table,
                    environment.money.rounded(average))
                )
                .foregroundStyle(.secondary)
              }
              Text(verbatim: environment.money.rounded(day.total)).monospacedDigit()
            }
            .appFont(.callout)
            ShareBar(basisPoints: Shares.ratio(day.total, of: weekdays.total))
          }
          .accessibilityElement(children: .combine)
        }
        Text(
          verbatim: environment.format(
            "overview.weekday.over", table: OverviewTileText.table,
            environment.dates.span(weekdays.interval))
        )
        .appFont(.caption)
        .foregroundStyle(.secondary)
      }
    }
  }
}

/// «Расходы по месяцам»: twelve bars, the current month the last, each as tall as the month's
/// share of the largest one; the amount of the current month and the average above them.
struct MonthlySpendingCard: View {
  @Dependency(\.environment) private var environment

  var body: some View {
    FiguresTile(
      tile: .monthlySpending, emptyKey: { $0.months.total.raw > 0 ? nil : "overview.noSpendingYet" }
    ) { figures, _ in
      let months = figures.months.months
      let largest = months.map(\.amount.raw).max() ?? 1
      VStack(alignment: .leading, spacing: 6) {
        if let current = months.last {
          Text(verbatim: environment.money.rounded(current.amount))
            .appFont(.title2.monospacedDigit())
          Text(
            verbatim: environment.format(
              "overview.months.current", table: OverviewTileText.table,
              environment.dates.monthTitle(current.month))
          )
          .appFont(.caption)
          .foregroundStyle(.secondary)
        }
        HStack(alignment: .bottom, spacing: 4) {
          ForEach(months, id: \.month) { month in
            VStack(spacing: 2) {
              Capsule()
                .fill(
                  month.month == months.last?.month
                    ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary)
                )
                .frame(
                  height: max(3, 56 * CGFloat(max(month.amount.raw, 0)) / CGFloat(max(largest, 1))))
              Text(verbatim: environment.dates.shortMonth(month.month))
                .appFont(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            }
            .frame(maxWidth: .infinity, alignment: .bottom)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
              Text(
                verbatim:
                  "\(environment.dates.monthTitle(month.month)), \(environment.money.rounded(month.amount))"
              ))
          }
        }
        .frame(height: 80, alignment: .bottom)
      }
    }
  }
}

/// «Доходы по источникам».
struct IncomeSourcesCard: View {
  @Dependency(\.environment) private var environment

  var body: some View {
    FiguresTile(
      tile: .incomeSources, emptyKey: { $0.sources.sources.isEmpty ? "overview.sources.none" : nil }
    ) { figures, snapshot in
      VStack(alignment: .leading, spacing: 8) {
        ForEach(figures.sources.sources.prefix(OverviewFigures.topCount), id: \.key) { node in
          ShareLine(
            name: OverviewText.name(of: node.key, tree: snapshot.ledger.tree, environment),
            amount: node.amount, basisPoints: node.share)
        }
      }
    }
  }
}

/// «Топ мест».
struct TopPlacesCard: View {
  @Dependency(\.environment) private var environment

  var body: some View {
    FiguresTile(
      tile: .topPlaces, emptyKey: { $0.places.top.isEmpty ? "overview.places.none" : nil }
    ) { figures, snapshot in
      let names = Dictionary(
        snapshot.dataset.places.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
      VStack(alignment: .leading, spacing: 8) {
        ForEach(figures.places.top, id: \.key) { node in
          if case .place(let id) = node.key {
            ShareLine(
              name: names[id] ?? "—", amount: node.amount,
              basisPoints: Shares.ratio(node.amount, of: figures.places.total))
          }
        }
      }
    }
  }
}

/// «Траты по людям»: my spending by «на кого», with the names the owner gave the values.
struct SpendingByPersonCard: View {
  @Dependency(\.environment) private var environment

  var body: some View {
    FiguresTile(
      tile: .spendingByPerson,
      emptyKey: { $0.people.values.isEmpty ? "overview.noSpendingYet" : nil }
    ) { figures, _ in
      VStack(alignment: .leading, spacing: 8) {
        ForEach(figures.people.values, id: \.key) { node in
          if case .forWhom(let value) = node.key {
            ShareLine(
              name: environment.label(for: value), amount: node.amount, basisPoints: node.share)
          }
        }
      }
    }
  }
}

// MARK: - A category that moved

/// «Категория выросла сильнее всего» and «Категория сократилась»: the category, how much more or
/// less it has taken than in the same days of last month, in rubles and in per cent. The arrow
/// and the sign say which way it went, never a colour.
struct CategoryMoveCard: View {
  @Dependency(\.environment) private var environment
  let grew: Bool

  var body: some View {
    FiguresTile(
      tile: grew ? .categoryGrew : .categoryShrank,
      emptyKey: {
        ($0.move(grew: grew)) == nil ? (grew ? "overview.grew.none" : "overview.shrank.none") : nil
      }
    ) { figures, snapshot in
      if let move = figures.move(grew: grew) {
        VStack(alignment: .leading, spacing: 4) {
          Text(
            verbatim: OverviewText.name(of: move.key, tree: snapshot.ledger.tree, environment)
          )
          .appFont(.headline)
          .lineLimit(2)
          HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: grew ? "arrow.up.right" : "arrow.down.right")
              .accessibilityHidden(true)
            Text(verbatim: environment.money.signedRounded(move.delta))
              .appFont(.title2.monospacedDigit())
            if let bp = move.basisPoints {
              Text(verbatim: environment.money.signedPercent(basisPoints: bp))
                .foregroundStyle(.secondary)
            }
          }
          Text(
            verbatim: environment.format(
              "overview.move.was", table: OverviewTileText.table,
              environment.money.rounded(move.previous), environment.money.rounded(move.current))
          )
          .appFont(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
      }
    }
  }
}

extension OverviewFigures {
  /// The category that grew or the one that shrank.
  func move(grew: Bool) -> CategoryMove? { grew ? self.grew : shrank }
}

// MARK: - Which card

/// The card of a tile of 2.0.
struct OverviewNewCardView: View {
  let tile: OverviewTile
  var compact = false

  var body: some View {
    switch tile {
    case .currencyBalances: CurrencyBalancesCard()
    case .weekdaySpending: WeekdaySpendingCard()
    case .monthlySpending: MonthlySpendingCard()
    case .incomeSources: IncomeSourcesCard()
    case .topPlaces: TopPlacesCard()
    case .spendingByPerson: SpendingByPersonCard()
    case .categoryGrew: CategoryMoveCard(grew: true)
    case .categoryShrank: CategoryMoveCard(grew: false)
    case .weekendPrice, .usualDay: SpendingFigureTileCard(tile: tile, compact: compact)
    case .savingsRate: SavingsNormTileCard(compact: compact)
    case .financialHealth: FinancialHealthTileCard(compact: compact)
    default: FigureTileCard(tile: tile, compact: compact)
    }
  }
}
