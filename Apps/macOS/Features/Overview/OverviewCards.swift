import AppCore
import SwiftUI

/// The grids of Overview: the tiles of each group (`AppEnvironment.overviewLayout`,
/// `OverviewGroupedGrid`), in their order. Each tile is a block of the pipeline with its own title, bound to the state of the step
/// it comes from — the data step for the month, the categories, the qualities and the
/// reconciliation; «owed to me» for its card; the forecast for the forecasts. A failed step turns
/// only its own tiles into a message with «Повторить»; the rest keep their numbers.
enum OverviewCard {
  /// Three columns from about 840 pt of list, two from about 560, one below that.
  static func columns(forWidth width: CGFloat) -> Int {
    width >= 840 ? 3 : width >= 560 ? 2 : 1
  }

  /// The tiles in rows of `columns`, in order.
  static func rows(_ tiles: [OverviewTile], columns: Int) -> [[OverviewTile]] {
    let size = max(1, columns)
    return stride(from: 0, to: tiles.count, by: size).map {
      Array(tiles[$0..<min($0 + size, tiles.count)])
    }
  }
}

struct OverviewCardView: View {
  let tile: OverviewTile
  let actions: OperationActions
  /// The tile is compact: one figure and a caption (`OverviewLayout.isCompact`).
  var compact = false

  var body: some View {
    if compact, OverviewCatalog.canBeCompact(tile) {
      OverviewNewCardView(tile: tile, compact: true)
    } else {
      regular
    }
  }

  @ViewBuilder
  private var regular: some View {
    switch tile {
    case .monthToDate: MonthToDateCard()
    case .topCategories: TopCategoriesCard()
    case .qualities: QualitiesCard()
    case .canSave: CanSaveCard()
    case .spendingForecast: ForecastCard()
    case .incomeForecast: IncomeForecastCard()
    case .balanceForecast: BalanceForecastCard()
    case .limits: LimitsCard()
    case .upcoming: UpcomingPaymentsCard()
    case .expectedIncome: ExpectedIncomeCard()
    case .owedToMe: OwedCard(actions: actions)
    case .iOwe: IOweCard()
    case .event: EventCard()
    case .lastCount: ReconciliationCard()
    case .lastRecord: LastRecordCard()
    case .lastCountAndRecord: LastCountAndRecordCard()
    case .worthALook: AnomaliesCard()
    case .freeMoney: FreeMoneyCard()
    case .currencyChart: CurrencyChartCard()
    case .spendingCalendar: CalendarTileCard()
    case .capital: CapitalTileCard()
    case .cushion: CushionTileCard()
    case .installments: InstalmentsTileCard()
    case .selfEmployment: SelfEmploymentTile()
    case .currencyBalances, .spendToday, .weekOverWeek, .averageDaily, .monthIncome,
      .savingsRate, .monthRest, .weekdaySpending, .monthlySpending, .incomeSources, .topPlaces,
      .spendingByPerson, .categoryGrew, .categoryShrank, .smallPurchases, .backups, .integrity,
      .ratesStatus, .weekendPrice, .usualDay, .financialHealth:
      OverviewNewCardView(tile: tile)
    }
  }
}

// MARK: - The cards

/// Spending, income and their difference from the 1st to today, each of the first two
/// against the same span of the previous month.
private struct MonthToDateCard: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute

  var body: some View {
    ComputedBlock(
      title: OverviewTileText.name(of: .monthToDate, environment),
      state: compute.states.data, fillsHeight: true,
      retry: { compute.retry(ComputeStep.data) }
    ) { snapshot in
      let summary = snapshot.summary
      VStack(alignment: .leading, spacing: 4) {
        FigureLine(
          label: environment.language("overview.expenses", table: "Overview"),
          amount: summary.expenses.current)
        ComparisonLine(change: summary.expenses, span: summary.previousSpan)
          .padding(.bottom, 4)
        FigureLine(
          label: environment.language("overview.income", table: "Overview"),
          amount: summary.income.current)
        ComparisonLine(change: summary.income, span: summary.previousSpan)
          .padding(.bottom, 4)
        FigureLine(label: environment.language("common.net"), amount: summary.net)
      }
    }
  }
}

/// Where my money went this month: the five largest top-level categories, each with its
/// share of all my spending and a thin bar as long as that share.
private struct TopCategoriesCard: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute

  var body: some View {
    ComputedBlock(
      title: OverviewTileText.name(of: .topCategories, environment),
      state: compute.states.data.flatMap { snapshot, at in
        snapshot.summary.topCategories.isEmpty ? .notEnoughData : .ready(snapshot, at: at)
      },
      fillsHeight: true,
      emptyReason: environment.language("overview.noSpendingYet", table: "Overview"),
      retry: { compute.retry(ComputeStep.data) }
    ) { snapshot in
      VStack(alignment: .leading, spacing: 8) {
        ForEach(snapshot.summary.topCategories, id: \.key) { node in
          VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
              Text(
                verbatim: OverviewText.name(of: node.key, tree: snapshot.ledger.tree, environment)
              )
              .lineLimit(1)
              .truncationMode(.tail)
              Spacer(minLength: 8)
              Text(verbatim: environment.money.rounded(node.amount))
                .monospacedDigit()
              ShareText(basisPoints: node.share)
            }
            .appFont(.callout)
            ShareBar(basisPoints: node.share)
          }
          .accessibilityElement(children: .combine)
        }
      }
    }
  }
}

/// Good, neutral and bad spending this month: symbol, words, amount and share for each, a
/// bar in the fixed order good → neutral → bad, and how bad spending moved against the same
/// span of last month.
private struct QualitiesCard: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute

  var body: some View {
    ComputedBlock(
      title: OverviewTileText.name(of: .qualities, environment),
      state: compute.states.data.flatMap { snapshot, at in
        // Shares need something positive to be shares of: before the first spending of the
        // month there is nothing to split.
        snapshot.summary.qualities.allSatisfy { $0.share == nil }
          ? .notEnoughData : .ready(snapshot.summary, at: at)
      },
      fillsHeight: true,
      emptyReason: environment.language("overview.noSpendingYet", table: "Overview"),
      retry: { compute.retry(ComputeStep.data) }
    ) { summary in
      VStack(alignment: .leading, spacing: 6) {
        ForEach(summary.qualities, id: \.key) { node in
          if case .quality(let quality) = node.key {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
              QualityTag(
                quality: quality, title: environment.language(Palette.qualityKey(quality)),
                font: .callout)
              Spacer(minLength: 8)
              Text(verbatim: environment.money.rounded(node.amount))
                .monospacedDigit()
              ShareText(basisPoints: node.share)
            }
            .appFont(.callout)
            .accessibilityElement(children: .combine)
          }
        }
        QualityBar(nodes: summary.qualities)
          .padding(.vertical, 2)
        HStack(alignment: .firstTextBaseline, spacing: 4) {
          Image(systemName: Palette.qualitySymbol(.bad))
            .foregroundStyle(Palette.quality(.bad))
            .accessibilityHidden(true)
          Text(verbatim: environment.language("overview.badChange", table: "Overview"))
          ComparisonLine(change: summary.bad, span: summary.previousSpan)
        }
        .appFont(.caption)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
      }
    }
  }
}

/// The spending of the whole month as it is likely to end: the remainder of the forecast
/// step laid over what is spent and planned in the data on screen, so the known part is
/// always fresh and P10 never falls below what is already spent.
private struct ForecastCard: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute

  /// What the card shows: the forecast, and when its model was computed.
  struct Model: Sendable {
    var forecast: MonthForecast
    /// Scheduled payments (my share), expense debts and goal plans still due.
    var planned: AmountE4
    var computedAt: Date
  }

  var body: some View {
    ComputedBlock(
      title: OverviewTileText.name(of: .spendingForecast, environment),
      state: state, fillsHeight: true, retry: { compute.retry(ComputeStep.forecast) }
    ) { model in
      let forecast = model.forecast
      VStack(alignment: .leading, spacing: 4) {
        Text(verbatim: "≈ \(environment.money.rounded(forecast.p50))")
          .appFont(.title2.monospacedDigit())
        // With no day left the interval is a point: the figure above says it all.
        if forecast.p10 != forecast.p90 {
          Text(
            verbatim: String(
              format: environment.language("overview.forecastRange", table: "Overview"),
              locale: environment.language.locale, environment.money.rounded(forecast.p10),
              environment.money.rounded(forecast.p90))
          )
          .appFont(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
        }
        if forecast.lowData {
          Label {
            Text(verbatim: environment.language("common.noData"))
          } icon: {
            Image(systemName: "hourglass")
          }
          .appFont(.caption)
          .foregroundStyle(.secondary)
        }
        Text(
          verbatim: environment.format(
            "overview.forecastPlannedAmount", table: "Overview",
            environment.money.rounded(model.planned))
        )
        .appFont(.caption)
        .foregroundStyle(.secondary)
        Text(verbatim: OverviewText.modelComputed(model.computedAt, environment))
          .appFont(.caption)
          .foregroundStyle(.tertiary)
      }
    }
  }

  /// The forecast step's state, its remainder added to the current data.
  private var state: BlockState<Model> {
    compute.states.forecast.flatMap { remainder, at in
      guard let snapshot = compute.snapshot else { return .calculating }
      return .ready(
        Model(
          forecast: MonthForecast(
            spent: snapshot.summary.expenses.current, planned: snapshot.planning.planned.total,
            remainder: remainder),
          planned: snapshot.planning.planned.total,
          computedAt: at),
        at: at)
    }
  }
}

// MARK: - Pieces of the cards

/// A figure of a card: its name on the left, the amount in whole rubles on the right.
struct FigureLine: View {
  @Dependency(\.environment) private var environment
  let label: String
  let amount: AmountE4

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(verbatim: label)
        .appFont(.callout)
      Spacer(minLength: 8)
      Text(verbatim: environment.money.rounded(amount))
        .appFont(.title3.monospacedDigit())
    }
    .accessibilityElement(children: .combine)
  }
}

/// «↗ +3 400 ₽ · +8,3 % к 1–18 авг.»: the arrow and the sign say which way it went, never a
/// colour. With nothing to compare with, the percent gives way to «no data last month».
struct ComparisonLine: View {
  @Dependency(\.environment) private var environment
  let change: Change
  let span: DayRange

  var body: some View {
    let text = environment.money.change(change)
    HStack(alignment: .firstTextBaseline, spacing: 4) {
      Image(systemName: Palette.changeSymbol(text.direction))
        .accessibilityHidden(true)
      Text(verbatim: OverviewText.comparison(text, span: span, environment))
    }
    .appFont(.caption.monospacedDigit())
    .foregroundStyle(.secondary)
  }
}

/// A share of a card line, or a dash for a bucket that has none.
struct ShareText: View {
  @Dependency(\.environment) private var environment
  let basisPoints: Int?

  var body: some View {
    Text(verbatim: basisPoints.map { environment.money.percent(basisPoints: $0) } ?? "—")
      .monospacedDigit()
      .foregroundStyle(.secondary)
      .frame(minWidth: 56, alignment: .trailing)
  }
}

/// The thin bar under a line of the top: as long as its share of all my spending.
struct ShareBar: View {
  let basisPoints: Int?

  var body: some View {
    let share = min(max(basisPoints ?? 0, 0), Shares.whole)
    Capsule()
      .fill(.quaternary)
      .overlay {
        ProportionalRow(weights: [share, Shares.whole - share]) {
          Capsule().fill(.tint)
          Color.clear
        }
      }
      .frame(height: 3)
      .accessibilityHidden(true)
  }
}

/// Good, neutral and bad side by side, always in that order, 2 pt apart. A segment wide
/// enough for it carries the symbol of its quality, so the bar reads without colour; a
/// bucket without a share has no width. The lines above say the same in words, so the bar
/// is hidden from VoiceOver.
private struct QualityBar: View {
  let nodes: [BreakdownNode]

  var body: some View {
    ProportionalRow(weights: nodes.map { $0.share ?? 0 }, spacing: 2) {
      ForEach(nodes, id: \.key) { node in
        if case .quality(let quality) = node.key {
          RoundedRectangle(cornerRadius: 3)
            .fill(Palette.quality(quality))
            .overlay {
              ViewThatFits(in: .horizontal) {
                Image(systemName: Palette.qualitySymbol(quality))
                  .appFont(.caption2.weight(.semibold))
                  .foregroundStyle(.background)
                  .padding(.horizontal, 3)
                Color.clear
              }
            }
            .clipped()
        }
      }
    }
    .frame(height: 16)
    .accessibilityHidden(true)
  }
}

// MARK: - Words

/// The words of the cards, apart from the views so a test can read them in both languages.
@MainActor
enum OverviewText {
  /// «+3 400 ₽ · +8,3 % к 1–18 авг.», or «+3 400 ₽ · в прошлом месяце данных нет» when the
  /// same span of last month had nothing to compare with.
  static func comparison(
    _ text: ChangeText, span: DayRange, _ environment: AppEnvironment
  ) -> String {
    guard let percent = text.percent else {
      return environment.format("overview.comparisonNoBase", table: "Overview", text.delta)
    }
    return String(
      format: environment.language("overview.comparison", table: "Overview"),
      locale: environment.language.locale, text.delta, percent, environment.dates.span(span))
  }

  /// The name of a line of the top: a category as the dictionary holds it now, with
  /// «(архив)» when it has been archived; money without a category as «Без категории».
  static func name(
    of key: ReportKey, tree: CategoryTree, _ environment: AppEnvironment
  ) -> String {
    switch key {
    case .category(let id):
      guard let category = tree.category(id) else { return "—" }
      return category.archived
        ? environment.format("common.archivedName", category.name) : category.name
    case .uncategorized:
      return environment.language("category.uncategorized")
    case .forWhom(let value):
      return environment.label(for: value)
    default:
      return "—"
    }
  }

  /// What «Стоит посмотреть» lists (`WorthALook.recent`).
  static func recentAnomalies(_ report: AnomalyReport, today: DateOnly) -> [Anomaly] {
    WorthALook.recent(report, today: today)
  }

  /// An account in the archive that still holds money, with what it holds per currency.
  typealias ArchivedMoneyLine = ArchivedMoneyHolder

  /// Every account in the archive that still holds money (`WorthALook.archivedMoney`).
  static func archivedMoney(
    accounts: [PaymentMethod], balances: AccountBalances
  ) -> [ArchivedMoneyLine] {
    WorthALook.archivedMoney(accounts: accounts, balances: balances)
  }

  /// What an archived account holds, currency by currency, to the ruble: «1,000 ₽, −50 $» —
  /// what it holds now, or what money typed ahead leaves on it when it holds nothing now.
  static func archivedAmounts(_ line: ArchivedMoneyLine, money: MoneyFormatter) -> String {
    line.leftovers.map { money.rounded($0.shownAmount, currency: $0.key.currency) }
      .joined(separator: ", ")
  }

  /// A line of «Стоит посмотреть».
  typealias AnomalyLine = WorthALookLine

  /// The lines of «Стоит посмотреть», in order (`WorthALook.lines`).
  static func anomalyLines(
    _ report: AnomalyReport, today: DateOnly, free: FreeMoney?, shown: Int,
    archived: [ArchivedMoneyLine] = []
  ) -> [AnomalyLine] {
    WorthALook.lines(report, today: today, free: free, shown: shown, archived: archived)
  }

  /// When the model of the forecast was computed: the time today, the day and time before.
  static func modelComputed(_ instant: Date, _ environment: AppEnvironment) -> String {
    if environment.calendar.day(of: instant) == environment.today {
      return environment.format(
        "overview.forecastComputedAt", table: "Overview", environment.dates.time(instant))
    }
    return environment.format(
      "overview.forecastComputedOn", table: "Overview", environment.dates.moment(instant))
  }
}

/// «Потратили деньги цели? Нажмите «Забрать»»: the goals hold more than the money on the
/// accounts of the summary, with both figures and the way to the goals.
struct GoalsExceedRow: View {
  @Dependency(\.environment) private var environment
  let goals: AmountE4
  let money: AmountE4

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Label {
        Text(verbatim: environment.language("overview.goalsExceed", table: "Overview"))
      } icon: {
        Image(systemName: "exclamationmark.triangle")
      }
      .appFont(.callout)
      Text(
        verbatim: environment.format(
          "overview.goalsExceedDetail", table: "Overview", environment.money.rounded(goals),
          environment.money.rounded(money))
      )
      .appFont(.caption.monospacedDigit())
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      Button(environment.language("overview.openGoals", table: "Overview")) {
        // The goals are on the Planning screen, the second section.
        NotificationCenter.default.post(name: .selectSection, object: 2)
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
    }
    .accessibilityElement(children: .contain)
  }
}

/// «На «Наличные» в архиве 1,000 ₽ — перевести на другой счёт?»: an account the archive took
/// with money before 1.2, and the way to move that money to live accounts in one step of ⌘Z
/// (`ArchivedMoneySheet(leftoversOf:)`).
struct ArchivedMoneyRow: View {
  @Dependency(\.environment) private var environment
  let line: OverviewText.ArchivedMoneyLine
  let move: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Label {
        Text(
          verbatim: environment.format(
            "overview.archivedMoney", table: "Overview", line.account.name,
            OverviewText.archivedAmounts(line, money: environment.money))
        )
        .monospacedDigit()
        .fixedSize(horizontal: false, vertical: true)
      } icon: {
        Image(systemName: "archivebox")
      }
      .appFont(.callout)
      Button(environment.language("overview.archivedMoney.move", table: "Overview"), action: move)
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
    .accessibilityElement(children: .contain)
  }
}

/// «Аномалии» on Overview: the few most recent things worth a second look — those of the last
/// month (`OverviewText.recentAnomalies`) — rule and day, read-only. The whole list with
/// «Это нормально» is the «Аномалии» section of the Analytics window, opened from the toolbar
/// like any other. The card says «ничего необычного» when the rules ran and found nothing in
/// the month — that is an answer, not an absence of one.
struct AnomaliesCard: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies
  /// The archived account whose money the sheet moves.
  @State private var moving: PaymentMethod?
  /// The lines of 1.9 settled on this card, hidden until the data is read again.
  @State private var settled: Set<String> = []
  /// What a line of 1.9 opened.
  @State private var opened: WorthALookSheet?
  /// How many fit on a card before «и ещё N».
  private static let shown = 3

  /// The accounts in the archive that still hold money, from the data the card shows.
  private var archived: [OverviewText.ArchivedMoneyLine] {
    guard let snapshot = compute.snapshot else { return [] }
    return OverviewText.archivedMoney(
      accounts: snapshot.dataset.paymentMethods, balances: snapshot.planning.accounts.balances)
  }

  var body: some View {
    ComputedBlock(
      title: OverviewTileText.name(of: .worthALook, environment),
      state: compute.states.anomalies, fillsHeight: true,
      retry: { compute.retry(ComputeStep.anomalies) }
    ) { report in
      let notes = Self.notes(compute.snapshot, settled: settled)
      let lines = Self.lines(
        OverviewText.anomalyLines(
          report, today: compute.snapshot?.today ?? environment.today,
          free: compute.snapshot?.planning.freeMoney, shown: Self.shown, archived: archived),
        notes: notes)
      VStack(alignment: .leading, spacing: 6) {
        TrendNudgeRow()
        DraftReminderRow()
        if let snapshot = compute.snapshot {
          ForEach(notes) { note in
            WorthALookNoteRow(
              note: note, snapshot: snapshot, settled: { settled.insert($0) },
              open: { opened = $0 })
          }
        }
        ForEach(lines) { line in
          switch line {
          case .goalsExceed(let goals, let money):
            GoalsExceedRow(goals: goals, money: money)
          case .archivedMoney(let archived):
            ArchivedMoneyRow(line: archived) { moving = archived.account }
          case .anomaly(let anomaly):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
              Text(
                verbatim: environment.language(
                  "analytics.anomaly.\(anomaly.rule.rawValue)", table: "Analytics")
              )
              .appFont(.callout)
              Text(verbatim: environment.dates.dayAndMonth(anomaly.day))
                .appFont(.caption)
                .foregroundStyle(.secondary)
            }
          case .more(let count):
            Text(
              verbatim: environment.language.format(
                "overview.anomaliesMore", table: "Overview", counts: count)
            )
            .appFont(.caption)
            .foregroundStyle(.secondary)
          case .nothingUnusual:
            Text(verbatim: environment.language("overview.anomaliesNone", table: "Overview"))
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }
    }
    .sheet(item: $moving) { account in
      ArchivedMoneySheet(leftoversOf: account) { _ in moving = nil }
        .handingOver(dependencies)
    }
    .sheet(item: $opened) { sheet in
      switch sheet {
      case .allocate(let request): AllocationSheetView(request: request).handingOver(dependencies)
      case .monthRest(let offer): MonthRestSheet(offer: offer).handingOver(dependencies)
      case .pay(let month): NPDPaymentSheet(month: month).handingOver(dependencies)
      }
    }
    // A new read brings the marks of this Mac in: what was settled is gone from the data.
    .onChange(of: compute.generation) { _, _ in settled = [] }
  }

  /// The lines of 1.9 the card shows: those of the core, less those settled here.
  static func notes(_ snapshot: DataSnapshot?, settled: Set<String>) -> [WorthALookNote] {
    guard let snapshot else { return [] }
    return WorthALook.notes(of: snapshot).filter { !settled.contains($0.id) }
  }

  /// «Ничего необычного» speaks only for a card with nothing else on it.
  static func lines(
    _ lines: [OverviewText.AnomalyLine], notes: [WorthALookNote]
  )
    -> [OverviewText.AnomalyLine]
  {
    notes.isEmpty ? lines : lines.filter { $0 != .nothingUnusual }
  }
}

/// The tile «Самозанятость»: the figures of the block of Planning, under the name of the tile.
private struct SelfEmploymentTile: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute

  var body: some View {
    ComputedBlock(
      title: OverviewTileText.name(of: .selfEmployment, environment),
      state: compute.states.data, fillsHeight: true,
      retry: { compute.retry(ComputeStep.data) }
    ) { _ in
      SelfEmploymentTileCard()
    }
  }
}
