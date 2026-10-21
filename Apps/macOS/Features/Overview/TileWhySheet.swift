import AppCore
import SwiftUI

/// «Почему так» of a tile: a sheet over Overview with where the figure of the tile comes from —
/// the figures line by line, each with its sign, the total under them, the rule in one plain
/// sentence — and «Открыть …», which closes the sheet and goes to the screen the figure lives on.
///
/// Nothing here counts: the breakdown is the core's (`TileExplanations`), built from the very
/// values the tile shows — the data step's snapshot, the forecast's remainder, the owed figure,
/// the anomalies — so its total is the tile's figure. Amounts go through `environment.money`,
/// which hides them while «Скрыть суммы» is on; content, so no glass.
struct TileWhySheet: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dismiss) private var dismiss
  @Environment(\.openWindow) private var openWindow
  let tile: OverviewTile
  let actions: OperationActions
  /// The rates of the chart tile, loaded the way the tile loads them.
  @State private var rates: TileRateSeries?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text(verbatim: OverviewTileText.name(of: tile, environment))
          .appFont(.title3.weight(.semibold))
        Text(verbatim: t("why.sheet.subtitle"))
          .appFont(.callout)
          .foregroundStyle(.secondary)
      }
      .accessibilityElement(children: .combine)
      .accessibilityAddTraits(.isHeader)
      ScrollView {
        content
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(minHeight: 120)
      footer
    }
    .padding(20)
    .frame(width: TileWhySheet.width)
    .frame(minHeight: 300, idealHeight: 460, maxHeight: 680)
    .accessibilityIdentifier("overview.why.\(tile.rawValue)")
    .onExitCommand { dismiss() }
    .task(id: tile) {
      guard tile == .currencyChart else { return }
      rates = await TileWhy.loadRates(environment)
    }
  }

  static let width: CGFloat = 480

  private var explanation: TileExplanation? {
    TileWhy.explanation(
      of: tile, compute: compute, environment: environment, rates: rates)
  }

  @ViewBuilder
  private var content: some View {
    if let explanation, let snapshot = compute.snapshot {
      TileWhyContent(explanation: explanation, tree: snapshot.ledger.tree)
    } else {
      Text(verbatim: t("why.sheet.noData"))
        .foregroundStyle(.secondary)
    }
  }

  private var footer: some View {
    HStack(spacing: 8) {
      if let destination = explanation?.destination ?? TileDestination.of(tile) {
        // Content, not a floating control: a plain button, never glass.
        Button(t(TileWhyNavigation.openKey(destination))) { open(destination) }
          .accessibilityIdentifier("overview.why.open")
      }
      Spacer(minLength: 8)
      Button(environment.language("action.close")) { dismiss() }
        .keyboardShortcut(.cancelAction)
        .accessibilityIdentifier("overview.why.close")
    }
  }

  /// The sheet closes first, then the window goes: a sheet of the window — «Сверка» — cannot
  /// open while this one is still on screen.
  private func open(_ destination: TileDestination) {
    let target = TileWhyNavigation.target(of: destination)
    let openWindow = openWindow
    let environment = environment
    dismiss()
    Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(250))
      TileWhyNavigation.go(target, environment: environment, openWindow: openWindow)
    }
  }

  private func t(_ key: String) -> String { environment.language(key, table: TilePhrase.overview) }
}

// MARK: - The lines

/// The sections of a breakdown, the notes under them and the rule.
struct TileWhyContent: View {
  @Dependency(\.environment) private var environment
  let explanation: TileExplanation
  let tree: CategoryTree

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      switch explanation.state {
      case .waiting:
        Label {
          Text(verbatim: t("why.sheet.waiting"))
            .fixedSize(horizontal: false, vertical: true)
        } icon: {
          Image(systemName: "hourglass")
        }
        .foregroundStyle(.secondary)
      case .empty(let phrase):
        Text(verbatim: TileWhy.text(phrase, tree: tree, environment))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      case .ready:
        ForEach(Array(explanation.sections.enumerated()), id: \.offset) { _, section in
          if !section.rows.isEmpty || section.total != nil {
            TileWhySectionView(section: section, tree: tree)
          }
        }
        ForEach(Array(explanation.notes.enumerated()), id: \.offset) { _, note in
          Label {
            Text(verbatim: TileWhy.text(note, tree: tree, environment))
              .fixedSize(horizontal: false, vertical: true)
          } icon: {
            Image(systemName: "info.circle")
          }
          .appFont(.caption)
          .foregroundStyle(.secondary)
        }
      }
      VStack(alignment: .leading, spacing: 4) {
        Text(verbatim: t("why.sheet.rule"))
          .appFont(.headline)
        Text(verbatim: TileWhy.text(explanation.rule, tree: tree, environment))
          .appFont(.callout)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("overview.why.rule")
      }
      .accessibilityElement(children: .combine)
    }
  }

  private func t(_ key: String) -> String { environment.language(key, table: TilePhrase.overview) }
}

/// A block: its title, its lines with their signs, and the total under a rule.
private struct TileWhySectionView: View {
  @Dependency(\.environment) private var environment
  let section: TileSection
  let tree: CategoryTree

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if let title = section.title {
        Text(verbatim: TileWhy.text(title, tree: tree, environment))
          .appFont(.headline)
      }
      ForEach(Array(section.rows.enumerated()), id: \.offset) { _, row in
        TileWhyRowView(row: row, tree: tree, isTotal: false)
      }
      if let total = section.total {
        if !section.rows.isEmpty { Divider() }
        TileWhyRowView(row: total, tree: tree, isTotal: true)
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    // Content, never glass: the plain background of a block, radius 12.
    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
  }
}

/// One line: «+», «−» or «=» — the sign says what the line does, never a colour —, the mark of
/// its meaning with its word, the words, the share and the figure.
private struct TileWhyRowView: View {
  @Dependency(\.environment) private var environment
  let row: TileRow
  let tree: CategoryTree
  let isTotal: Bool

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(verbatim: TileWhy.sign(of: row, isTotal: isTotal))
        .appFont(.callout.monospacedDigit())
        .foregroundStyle(.secondary)
        .frame(width: 12, alignment: .center)
        .accessibilityHidden(true)
      if let mark = row.mark, let symbol = TileWhy.symbol(of: mark) {
        Image(systemName: symbol)
          .foregroundStyle(.secondary)
          .accessibilityLabel(Text(verbatim: TileWhy.word(of: mark, environment) ?? ""))
          .accessibilityHidden(TileWhy.word(of: mark, environment) == nil)
      }
      VStack(alignment: .leading, spacing: 2) {
        Text(verbatim: TileWhy.text(row.label, tree: tree, environment))
          .fixedSize(horizontal: false, vertical: true)
        if let note = row.note {
          Text(verbatim: TileWhy.text(note, tree: tree, environment))
            .appFont(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      Spacer(minLength: 8)
      if let share = row.share {
        Text(verbatim: environment.money.percent(basisPoints: share))
          .monospacedDigit()
          .foregroundStyle(.secondary)
      }
      if let value = row.value {
        Text(verbatim: TileWhy.value(value, environment))
          .monospacedDigit()
          .fixedSize()
      }
    }
    .appFont(isTotal ? .callout.weight(.semibold) : .callout)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      Text(verbatim: TileWhy.spoken(row, isTotal: isTotal, tree: tree, environment)))
  }
}

// MARK: - Words and figures

/// The breakdown of a tile from what the window has at hand, and its words — apart from the
/// views, so a test reads them in both languages.
@MainActor
enum TileWhy {
  /// The breakdown from the store: `nil` before the first data arrives.
  static func explanation(
    of tile: OverviewTile, compute: ComputeStore, environment: AppEnvironment,
    rates: TileRateSeries? = nil
  ) -> TileExplanation? {
    guard let snapshot = compute.snapshot else { return nil }
    let states = compute.states
    return explanation(
      of: tile, snapshot: snapshot, remainder: states.forecast.value,
      owed: states.owed.value?.amount, anomalies: states.anomalies.value, rates: rates,
      environment: environment)
  }

  /// The breakdown from the values the tiles read: the snapshot of the data step and what the
  /// other steps delivered, each `nil` while its step has not.
  static func explanation(
    of tile: OverviewTile, snapshot: DataSnapshot, remainder: MonthForecast.Remainder?,
    owed: AmountE4?, anomalies: AnomalyReport?, rates: TileRateSeries?,
    environment: AppEnvironment
  ) -> TileExplanation {
    TileExplanations.explain(
      tile,
      inputs(
        snapshot: snapshot, remainder: remainder, owed: owed, anomalies: anomalies, rates: rates,
        environment: environment))
  }

  /// What the core reads, gathered the way each tile gathers it: the limits in the order and
  /// with the names of the limits card, the week of the calendar tile, the accounts of the
  /// balance forecast.
  static func inputs(
    snapshot: DataSnapshot, remainder: MonthForecast.Remainder?, owed: AmountE4?,
    anomalies: AnomalyReport?, rates: TileRateSeries?, environment: AppEnvironment
  ) -> TileInputs {
    let tree = snapshot.ledger.tree
    let limits = LimitsCard.lines(snapshot, environment)
    let all = limits.shown + limits.rest
    return TileInputs(
      ledger: snapshot.ledger, summary: snapshot.summary, planning: snapshot.planning,
      today: snapshot.today, remainder: remainder, accountPlan: snapshot.accountPlan,
      summaryAccountIds: BalanceForecastModel.summaryAccountIds(
        snapshot.planning.accounts, locale: environment.language.locale),
      owed: owed, anomalies: anomalies, limits: all,
      limitNames: Dictionary(
        all.map { ($0.budget.id, PlanningText.limitName($0.budget, tree: tree, environment)) },
        uniquingKeysWith: { first, _ in first }),
      anomaliesShown: 3,
      calendarWeek: CalendarScreen.calendar(
        of: snapshot, scope: .week, anchor: snapshot.today,
        firstWeekday: CalendarScreen.firstWeekday(locale: environment.language.locale)),
      rates: rates)
  }

  /// The rates of the chart tile's pair and period, as the tile keeps them on this Mac and
  /// loads them (`CurrencyChart`); `nil` without the rate service.
  static func loadRates(_ environment: AppEnvironment) async -> TileRateSeries? {
    let (pair, period) = CurrencyChart.decode(
      UserDefaults.standard.string(forKey: CurrencyChartCard.storageKey))
    guard let service = environment.rateService else { return nil }
    let days = CurrencyChart.days(period, today: environment.today, calendar: environment.calendar)
    let points =
      await CurrencyChart.points(of: pair, on: days) { currency, day in
        await service.rate(for: currency, on: day)?.perUnit
      } ?? []
    return series(pair: pair, period: period, points: points)
  }

  /// The first and the last point and the change, by `CurrencyChart.summary` — what the tile
  /// writes over its chart.
  static func series(
    pair: CurrencyPair, period: CurrencyChartPeriod, points: [CurrencyChartPoint]
  ) -> TileRateSeries {
    let summary = CurrencyChart.summary(points)
    return TileRateSeries(
      base: pair.base, quote: pair.quote,
      period: TileRateSeries.Period(rawValue: period.rawValue) ?? .month,
      first: summary == nil ? nil : points.first.map { .init(day: $0.day, rateE4: $0.rateE4) },
      last: summary == nil ? nil : points.last.map { .init(day: $0.day, rateE4: $0.rateE4) },
      changeE4: summary?.change ?? 0, changeBp: summary?.changeBp ?? 0)
  }

  // MARK: Words

  /// A phrase in the language of the interface. A phrase of counts alone picks its plural form.
  static func text(
    _ phrase: TilePhrase, tree: CategoryTree, _ environment: AppEnvironment
  )
    -> String
  {
    if phrase.isCounted {
      let counts = phrase.arguments.compactMap { argument -> Int? in
        if case .count(let count) = argument { return count }
        return nil
      }
      return environment.language.counted(phrase.key, table: phrase.table, counts)
    }
    let arguments = phrase.arguments.map { argument(text: $0, tree: tree, environment) }
    let format = environment.language(phrase.key, table: phrase.table)
    guard !arguments.isEmpty else { return format }
    return String(
      format: format, locale: environment.language.locale,
      arguments: arguments.map { $0 as CVarArg })
  }

  static func argument(
    text argument: TileArgument, tree: CategoryTree, _ environment: AppEnvironment
  ) -> String {
    switch argument {
    case .text(let text): text
    case .day(let day): environment.dates.dayAndMonth(day)
    case .moment(let moment): environment.dates.moment(moment)
    case .span(let span): environment.dates.span(span)
    case .count(let count): NumberText.integer(Int64(count))
    case .money(let amount, let currency): environment.money.rounded(amount, currency: currency)
    case .percent(let basisPoints): environment.money.signedPercent(basisPoints: basisPoints)
    case .months(let months): CushionText.monthsNumber(months)
    case .rate(let e4, let quote): rate(e4, quote, environment)
    case .category(let key): OverviewText.name(of: key, tree: tree, environment)
    case .quality(let quality): environment.language(Palette.qualityKey(quality))
    case .anomalyRule(let rule):
      environment.language("analytics.anomaly.\(rule.rawValue)", table: "Analytics")
    case .limitStatus(let status): PlanningText.statusWord(status, environment)
    }
  }

  /// A figure the way the rest of Overview writes it: rounded to the unit, «≈» for an
  /// estimate, a sign for a change.
  static func value(_ value: TileValue, _ environment: AppEnvironment) -> String {
    let money = environment.money
    switch value {
    case .money(let amount, let currency):
      return money.rounded(amount, currency: currency)
    case .approximately(let amount, let currency):
      return "≈\u{00A0}" + money.rounded(amount, currency: currency)
    case .change(let amount, let currency):
      return money.signedRounded(amount, currency: currency)
    case .spentOf(let spent, let available):
      return "\(money.rounded(spent)) / \(money.rounded(available))"
    case .months(let months):
      return environment.format(
        "cushion.tile.months", table: CushionText.table, CushionText.monthsNumber(months))
    case .day(let day):
      return environment.dates.longDay(day)
    case .moment(let moment):
      return environment.dates.moment(moment)
    case .count(let count):
      return NumberText.integer(Int64(count))
    case .rate(let e4, let quote):
      return rate(e4, quote, environment)
    case .rateChange(let e4, let quote):
      let sign = e4 > 0 ? "+" : e4 < 0 ? "−" : ""
      return sign + rate(abs(e4), quote, environment)
    case .percent(let basisPoints):
      return money.percent(basisPoints: basisPoints)
    }
  }

  static func rate(_ e4: Int64, _ quote: CurrencyCode, _ environment: AppEnvironment) -> String {
    environment.money.rate(Decimal(e4) / 10_000) + " " + environment.money.symbol(for: quote)
  }

  /// «+», «−» for the lines that add or take away, «=» for the total, nothing for a detail.
  static func sign(of row: TileRow, isTotal: Bool) -> String {
    if isTotal { return "=" }
    switch row.role {
    case .plus: return "+"
    case .minus: return "−"
    case .detail: return ""
    }
  }

  /// What VoiceOver says of a line: what it does, its words and its figure.
  static func spoken(
    _ row: TileRow, isTotal: Bool, tree: CategoryTree, _ environment: AppEnvironment
  ) -> String {
    var parts: [String] = []
    if isTotal {
      parts.append(environment.language("why.sheet.equals", table: "Overview"))
    } else if row.role == .plus {
      parts.append(environment.language("why.sheet.plus", table: "Overview"))
    } else if row.role == .minus {
      parts.append(environment.language("why.sheet.minus", table: "Overview"))
    }
    if let mark = row.mark, let word = word(of: mark, environment) { parts.append(word) }
    parts.append(text(row.label, tree: tree, environment))
    if let value = row.value { parts.append(Self.value(value, environment)) }
    if let share = row.share { parts.append(environment.money.percent(basisPoints: share)) }
    if let note = row.note { parts.append(text(note, tree: tree, environment)) }
    return parts.joined(separator: ", ")
  }

  /// The symbol of a mark: a shape, so the meaning never rests on a colour.
  static func symbol(of mark: TileMark) -> String? {
    switch mark {
    case .quality(let quality): Palette.qualitySymbol(quality)
    case .limit(let status): PlanningText.statusSymbol(status)
    case .overdue: "exclamationmark.circle"
    case .spendingLevel(let level): CalendarText.symbol(of: level)
    case .kind(let kind): OverviewTileText.symbol(of: kind)
    case .warning: "exclamationmark.triangle"
    case .lowData: "hourglass"
    }
  }

  /// The word of a mark, said beside its symbol; `nil` where the words of the line say it.
  static func word(of mark: TileMark, _ environment: AppEnvironment) -> String? {
    switch mark {
    case .quality(let quality): environment.language(Palette.qualityKey(quality))
    case .limit(let status): PlanningText.statusWord(status, environment)
    case .overdue: environment.language("planning.overdue", table: "Planning")
    case .spendingLevel(let level):
      CalendarText.levelKey(level).map { CalendarText.t($0, environment) }
    case .kind(let kind): environment.language("kind.\(kind.rawValue)")
    case .warning, .lowData: nil
    }
  }
}

// MARK: - Where «Открыть …» goes

/// The screen of a breakdown, as the main window reaches it: a section of the sidebar by the
/// number its menu item posts, «Всего» of the sidebar, a section of the Analytics window — kept
/// in its stored choice, then the window opened as a tab —, or the sheet «Сверка».
@MainActor
enum TileWhyNavigation {
  enum Target: Equatable {
    case section(MainWindow.Section)
    case sidebar(SidebarItem)
    case analytics(AnalyticsSection)
    case reconciliation
  }

  static func target(of destination: TileDestination) -> Target {
    switch destination {
    case .operations: .section(.operations)
    case .planning: .section(.planning)
    case .debts: .section(.debts)
    case .calendar: .section(.calendar)
    case .capital: .section(.capital)
    case .allAccounts: .sidebar(.allAccounts)
    case .reconciliation: .reconciliation
    case .analytics(let section):
      .analytics(AnalyticsSection(rawValue: section.rawValue) ?? .overview)
    }
  }

  /// The words of the button.
  static func openKey(_ destination: TileDestination) -> String {
    switch destination {
    case .operations: "why.open.operations"
    case .planning: "why.open.planning"
    case .debts: "why.open.debts"
    case .calendar: "why.open.calendar"
    case .capital: "why.open.capital"
    case .allAccounts: "why.open.allAccounts"
    case .reconciliation: "why.open.reconciliation"
    case .analytics(let section): "why.open.analytics.\(section.rawValue)"
    }
  }

  /// The sections of Analytics that follow the period: the breakdown is of this month, so the
  /// window opens on it.
  static func showsThisMonth(_ section: AnalyticsSection) -> Bool {
    section.followsThePeriod
  }

  /// `openWindow` opens the Analytics window; without it only the stored choice is made.
  static func go(_ target: Target, environment: AppEnvironment, openWindow: OpenWindowAction?) {
    switch target {
    case .section(let section):
      NotificationCenter.default.post(name: .selectSection, object: section.shortcutIndex)
    case .sidebar(let item):
      NotificationCenter.default.post(name: .openSidebarItem, object: item)
    case .reconciliation:
      environment.showsReconciliation = true
    case .analytics(let section):
      let defaults = UserDefaults.standard
      defaults.set(section.rawValue, forKey: AnalyticsWindow.sectionKey)
      if showsThisMonth(section) {
        defaults.set(
          AnalyticsPeriod.current(.month, today: environment.today).storage,
          forKey: AnalyticsWindow.periodKey)
      }
      #if os(macOS)
        if let openWindow { AppWindows.open("analytics", with: openWindow) }
      #else
        NotificationCenter.default.post(name: .openAppScreen, object: AppScreen.analytics)
      #endif
    }
  }
}
