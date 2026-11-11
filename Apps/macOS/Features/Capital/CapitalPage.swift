import AppCore
import SwiftUI

/// The numbers of «Капитал» as its frames draw it — the Mac's master (1440 × 900), the phone's
/// (440) and the tablet's (1366 × 1024). The page, the cards and the rows are the three screens'
/// (`SectionMetrics`); what is Capital's own is here.
enum CapitalMetrics {
  /// The coloured card: 18 inside, 5 between its four lines.
  static let heroPadding: CGFloat = 18
  static let heroGap: CGFloat = 5
  /// Its figure: 34 bold on the Mac, 32 on a phone, 36 on a tablet.
  static func heroFigure(_ idiom: LayoutIdiom) -> CGFloat {
    switch idiom {
    case .mac: 34
    case .phone: 32
    case .pad: 36
    }
  }
  /// The opacity of its caption, its change and its line of what is had and owed.
  static let heroCaptionOpacity: Double = 0.8
  static let heroChangeOpacity: Double = 0.85
  static let heroLineOpacity: Double = 0.75

  /// «Из чего складывается»: the ring 120 and its legend 16 to the right, the legend's rows 5
  /// apart, the square 9 rounded 3 and 7 from its word.
  static let donut: CGFloat = 120
  static let donutToLegend: CGFloat = 16
  static let legendGap: CGFloat = 5
  static let legendSquare: CGFloat = 9
  static let legendSquareRadius: CGFloat = 3
  static let legendWordGap: CGFloat = 7

  /// The chart of the months: 120 tall, the months 10 under it.
  static let chartHeight: CGFloat = 120
  /// The bar of the cushion: 8 tall, rounded 4.
  static let barHeight: CGFloat = 8
  static let barRadius: CGFloat = 4

  /// The tablet's two columns are not equal: the left one 448 of the 1,032 the two share.
  static let padLeftShare: CGFloat = 448.43 / 1_032

  /// Two columns from this width of content; one below it, in the phone's order.
  static let twoColumnsFrom: CGFloat = ScreenColumns.twoFrom
}

/// How «Капитал» lays itself out: two columns on the Mac and a tablet wide enough, one on a phone.
enum CapitalLayout {
  static func columns(forContent width: CGFloat, idiom: LayoutIdiom) -> Int {
    if idiom == .phone { return 1 }
    return width == 0 || width >= CapitalMetrics.twoColumnsFrom ? 2 : 1
  }

  /// The widths of the two columns of a content `width`: equal on the Mac (568 + 16 + 568),
  /// 448 and 584 of the tablet's 1,052.
  static func columnWidths(forContent width: CGFloat, idiom: LayoutIdiom) -> (CGFloat, CGFloat) {
    let room = max(0, width - SectionMetrics.columnGap(idiom))
    if idiom == .pad {
      let left = (room * CapitalMetrics.padLeftShare).rounded(.toNearestOrEven)
      return (left, room - left)
    }
    return (room / 2, room / 2)
  }
}

/// The four parts of the ring of «Из чего складывается»: what is had, by kind. Accounts left out
/// of the summary are accounts too.
enum CapitalShareKind: String, CaseIterable, Hashable {
  case accounts, deposits, assets, owedToMe

  var titleKey: String { "capital.shares.\(rawValue)" }

  static func of(_ group: CapitalLine.Group) -> CapitalShareKind? {
    switch group {
    case .accounts, .outOfSummary: .accounts
    case .deposits: .deposits
    case .assets: .assets
    case .owedToMe: .owedToMe
    case .iOwe: nil
    }
  }
}

/// The figures of the screen worked out from its model, without a word of text: the parts of the
/// ring and the change since the end of last month in percent.
enum CapitalFigures {
  struct Share: Hashable {
    var kind: CapitalShareKind
    var basisPoints: Int
  }

  /// The shares of «Что есть» by kind, in the order of the legend; a kind with nothing is left
  /// out. The shares are the model's own — those of the rows of the whole column —, so the legend
  /// and the list below it never disagree.
  static func shares(of model: CapitalViewModel) -> [Share] {
    CapitalShareKind.allCases.compactMap { kind in
      let points = model.haveGroups
        .filter { CapitalShareKind.of($0.kind) == kind }
        .compactMap(\.shareBp)
      guard !points.isEmpty else { return nil }
      let sum = points.reduce(0, +)
      return sum > 0 ? Share(kind: kind, basisPoints: sum) : nil
    }
  }

  /// The change of net worth since the end of last month as a share of what it was then, in basis
  /// points; `nil` when it was not above zero and a percent would say nothing.
  static func changeBasisPoints(change: AmountE4, net: AmountE4) -> Int? {
    let before = net.decimal - change.decimal
    guard before > 0 else { return nil }
    let share = DecimalMath.round(change.decimal * 10_000 / before, scale: 0)
    return NSDecimalNumber(decimal: share).intValue
  }
}

// MARK: - The cards

/// The coloured card at the top: «Капитал», the figure, the change since the end of last month
/// with an arrow and its sign — never the colour of good or bad: more debt can be a flat bought —,
/// and what is had and owed.
struct CapitalHeroCard: View {
  @Dependency(\.environment) private var environment
  @Environment(\.appTheme) private var theme
  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.layoutIdiom) private var idiom
  let model: CapitalViewModel?

  var body: some View {
    let design = LayoutIdiom.resolved(idiom)
    let shape = RoundedRectangle(cornerRadius: SectionMetrics.cardRadius)
    VStack(alignment: .leading, spacing: CapitalMetrics.heroGap) {
      // Small captions keep the theme's ink opaque; fading it loses contrast on the gradient.
      Text(verbatim: CapitalText.t("capital.title", environment))
        .appFont(.system(size: 12, weight: .medium))
      Text(verbatim: model.map { environment.money.rounded($0.net) } ?? "—")
        .appFont(.system(size: CapitalMetrics.heroFigure(design), weight: .bold).monospacedDigit())
        .minimumScaleFactor(0.6)
        .lineLimit(1)
        .accessibilityIdentifier("capital.net")
      if let change = changeLine {
        Text(verbatim: change)
          .appFont(.system(size: 12).monospacedDigit())
          .accessibilityIdentifier("capital.hero.change")
      }
      if let model {
        Text(
          verbatim: CapitalText.format(
            "capital.hero.haveOwe", environment, environment.money.rounded(model.have),
            environment.money.rounded(model.owe))
        )
        .appFont(.system(size: 11).monospacedDigit())
        if model.partHidden {
          Text(verbatim: PartHiddenNote.text(environment.language))
            .appFont(.system(size: 11))
        }
      }
    }
    .foregroundStyle(theme.heroContent)
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(CapitalMetrics.heroPadding)
    .background(
      LinearGradient(
        colors: [theme.heroStart, theme.heroEnd], startPoint: .leading, endPoint: .trailing),
      in: shape
    )
    .overlay { if contrast == .increased { shape.strokeBorder(.separator, lineWidth: 1) } }
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("screen.hero")
  }

  /// «↑ 3.1 % с конца сентября»; the change in rubles when the month began at zero or below.
  private var changeLine: String? {
    guard let model, let change = model.change, let since = model.sinceMonth else { return nil }
    let arrow = change.wholeRubles < 0 ? "↓" : "↑"
    let figure: String
    if let points = CapitalFigures.changeBasisPoints(change: change, net: model.net) {
      figure = environment.money.percent(basisPoints: abs(points))
    } else {
      figure = environment.money.signedRounded(change)
    }
    return arrow + " " + figure + " " + CapitalText.since(since, environment)
  }
}

/// «Из чего складывается»: the ring of what is had by kind with the figure in its hole, and the
/// legend of the kinds with their whole percents. The list of every account, deposit, asset and
/// debt — with their clicks — is the card «Что есть и что должен» further down.
struct CapitalSharesCard: View {
  @Dependency(\.environment) private var environment
  @Environment(\.appTheme) private var theme
  let model: CapitalViewModel

  var body: some View {
    let shares = CapitalFigures.shares(of: model)
    VStack(alignment: .leading, spacing: SectionMetrics.cardGap) {
      SectionCardHeader(
        title: CapitalText.t("capital.breakdown.title", environment),
        caption: CapitalText.t("capital.shares.caption", environment))
      if shares.isEmpty {
        Text(verbatim: CapitalText.t("capital.empty", environment))
          .appFont(SectionType.rowDetail)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      } else {
        HStack(alignment: .center, spacing: CapitalMetrics.donutToLegend) {
          ShareDonutChart(
            slices: shares.map { share in
              ShareDonutSlice(
                id: share.kind.rawValue, name: name(share), basisPoints: share.basisPoints,
                tint: tint(share.kind))
            },
            figure: environment.money.axis(model.have.wholeRubles),
            caption: CapitalText.t("capital.shares.have", environment),
            side: CapitalMetrics.donut)
          VStack(alignment: .leading, spacing: CapitalMetrics.legendGap) {
            ForEach(shares, id: \.kind) { share in legendRow(share) }
          }
          Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)
      }
    }
    .sectionCard()
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("capital.shares")
  }

  private func name(_ share: CapitalFigures.Share) -> String {
    CapitalText.t(share.kind.titleKey, environment)
  }

  private func legendRow(_ share: CapitalFigures.Share) -> some View {
    HStack(spacing: CapitalMetrics.legendWordGap) {
      RoundedRectangle(cornerRadius: CapitalMetrics.legendSquareRadius)
        .fill(tint(share.kind))
        .frame(width: CapitalMetrics.legendSquare, height: CapitalMetrics.legendSquare)
        .accessibilityHidden(true)
      Text(verbatim: name(share))
        .appFont(.system(size: 12))
      Text(verbatim: environment.money.percent(basisPoints: share.basisPoints, fractionDigits: 0))
        .appFont(.system(size: 12, weight: .semibold).monospacedDigit())
        .foregroundStyle(.secondary)
    }
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("capital.shares.\(share.kind.rawValue)")
  }

  /// The colours of the frame: accounts in the accent, deposits, property and what is owed to me
  /// in the third, second and fourth colours of the charts.
  func tint(_ kind: CapitalShareKind) -> Color {
    switch kind {
    case .accounts: theme.accentDefault
    case .deposits: theme.chart3
    case .assets: theme.chart2
    case .owedToMe: theme.chart4
    }
  }
}

/// «Имущество»: the things valued by hand, each with the day of its last valuation, and the ones
/// sold or written off under «Проданное». A click on a row opens its menu — «Новая оценка…»,
/// «История оценок», «Изменить…», «Продано / списано…», «Удалить…» —, and so does a right click;
/// a click on the title offers a new one and the deposit showcase.
struct CapitalAssetsCard: View {
  @Dependency(\.environment) private var environment
  @Environment(\.dependencies) private var dependencies
  @Environment(\.appTheme) private var theme
  let assets: [Asset]
  let valuations: [AssetValuation]
  @Binding var sheet: CapitalSheet?
  @Binding var deleting: Asset?
  @State private var refusal: String?

  var body: some View {
    let today = environment.today
    let ordered = AssetActions.ordered(assets, today: today, locale: environment.language.locale)
    let live = ordered.filter { !$0.isDisposed(on: today) }
    let gone = ordered.filter { $0.isDisposed(on: today) }
    VStack(alignment: .leading, spacing: SectionMetrics.cardGap) {
      Menu {
        Button(CapitalText.t("capital.assets.add", environment)) { sheet = .newAsset }
          .accessibilityIdentifier("capital.assets.add")
        Button(DepositText.t("dep.open", environment)) { sheet = .showcase }
          .accessibilityIdentifier("capital.deposits.showcase")
      } label: {
        SectionCardHeader(
          title: CapitalText.t("capital.assets.title", environment),
          caption: live.isEmpty ? nil : "\(live.count)")
      }
      .menuStyle(.button)
      .buttonStyle(.plain)
      .menuIndicator(.hidden)
      .accessibilityIdentifier("capital.assets.header")
      if assets.isEmpty {
        Text(verbatim: CapitalText.t("capital.assets.empty", environment))
          .appFont(SectionType.rowDetail)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        Button(CapitalText.t("capital.assets.add", environment)) { sheet = .newAsset }
          .buttonStyle(.rowAction)
          .accessibilityIdentifier("capital.assets.addEmpty")
      }
      ForEach(live) { asset in row(asset) }
      if !gone.isEmpty {
        Text(verbatim: CapitalText.t("capital.assets.disposed", environment))
          .appFont(SectionType.cardCaption)
          .foregroundStyle(.secondary)
        ForEach(gone) { asset in row(asset) }
      }
      if let refusal {
        Text(verbatim: CapitalText.t(refusal, environment))
          .appFont(SectionType.rowDetail)
          .foregroundStyle(.secondary)
      }
    }
    .sectionCard()
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("capital.assets")
  }

  private func row(_ asset: Asset) -> some View {
    let latest = AssetActions.latest(of: asset.id, among: valuations)
    let gone = asset.isDisposed(on: environment.today)
    return Menu {
      menu(asset)
    } label: {
      SectionRow(
        badge: SectionBadge(
          symbol: CapitalText.kindSymbol(asset.kind), tint: tint(asset.kind).ink,
          fill: tint(asset.kind).fill),
        title: asset.name, detail: detail(asset, latest),
        figure: latest.map { environment.money.rounded($0.valueE4, currency: asset.currency) },
        figureInk: gone ? .secondary : nil)
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .contextMenu { menu(asset) }
    .accessibilityLabel(
      Text(verbatim: CapitalText.format("capital.assets.menu", environment, asset.name))
    )
    .accessibilityIdentifier("capital.asset.menu.\(asset.id)")
  }

  @ViewBuilder
  private func menu(_ asset: Asset) -> some View {
    Button(CapitalText.t("capital.assets.newValuation", environment)) { sheet = .value(asset) }
    Button(CapitalText.t("capital.assets.history", environment)) { sheet = .history(asset) }
    Button(CapitalText.t("capital.assets.edit", environment)) { sheet = .edit(asset) }
    if asset.kind == .investment, asset.disposedOn == nil {
      Button(DepositText.t("payout.fromAsset", environment)) { sheet = .payout(asset) }
    }
    if asset.disposedOn == nil {
      Button(CapitalText.t("capital.assets.dispose", environment)) { sheet = .dispose(asset) }
    } else {
      Button(CapitalText.t("capital.assets.undispose", environment)) {
        guard let dependencies else { return }
        refusal = CapitalText.refusalKey(AssetActions(dependencies).dispose(asset, on: nil))
      }
    }
    Divider()
    Button(CapitalText.t("capital.assets.delete", environment), role: .destructive) {
      deleting = asset
    }
  }

  /// «оценка 12 октября» (with the year when it is not this one), «Ещё нет оценки»; for one sold
  /// «Продано или списано 3 октября 2026» after it.
  private func detail(_ asset: Asset, _ latest: AssetValuation?) -> String {
    var parts: [String] = []
    if let latest {
      let day =
        latest.day.year == environment.today.year
        ? environment.dates.dayAndMonth(latest.day) : environment.dates.longDay(latest.day)
      parts.append(CapitalText.format("capital.assets.valuedShort", environment, day))
    } else {
      parts.append(CapitalText.t("capital.assets.unvalued", environment))
    }
    if let disposed = asset.disposedOn {
      parts.append(
        CapitalText.format(
          "capital.assets.disposedOn", environment, environment.dates.longDay(disposed)))
    }
    return parts.joined(separator: " · ")
  }

  /// The badge of a kind of property: a car in the accent, investments in the third colour of the
  /// charts, a flat in the second, the rest in the sixth and seventh.
  private func tint(_ kind: AssetKind) -> (ink: Color, fill: Color) {
    switch kind {
    case .vehicle: (theme.accentDefault, theme.accentTint)
    case .investment: (theme.chart3, theme.chart3Tint)
    case .realty: (theme.chart2, theme.chart2Tint)
    case .equipment: (theme.chart6, theme.chart6Tint)
    case .other: (theme.chart7, theme.chart7Tint)
    }
  }
}

/// «Капитал по месяцам»: the caption of the range at the right, «12 мес. | Всё» under the title,
/// the chart and the months under it. Twelve months come with the snapshot; «Всё» is worked out
/// off the main thread (`CapitalChartSection.allPoints`).
struct CapitalMonthsCard: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.layoutIdiom) private var idiom
  let model: CapitalViewModel
  @State private var range = CapitalChartRange.year
  @State private var restored = false
  @State private var allPoints: [CapitalPoint]?
  @State private var allVersion: DataVersion?

  var body: some View {
    VStack(alignment: .leading, spacing: SectionMetrics.cardGap) {
      SectionCardHeader(
        title: CapitalText.t("capital.chart.title", environment),
        caption: CapitalText.t(
          range == .year ? "capital.chart.year" : "capital.chart.all", environment))
      SectionSegments(
        options: [
          (CapitalChartRange.year, CapitalText.t("capital.chart.yearShort", environment)),
          (CapitalChartRange.all, CapitalText.t("capital.chart.all", environment)),
        ],
        selection: $range,
        identifier: { "capital.chart.range.\($0.rawValue)" }
      )
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("capital.chart.range")
      chartBlock
    }
    .sectionCard()
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("capital.chart")
    .onAppear {
      guard !restored else { return }
      restored = true
      range = CapitalChartRange.stored()
    }
    .onChange(of: range) { _, new in new.store() }
    .task(id: AllKey(range: range, version: compute.snapshot?.version)) { await workOutAll() }
  }

  private var chartBlock: some View {
    ComputedBlock(
      title: nil, state: state, style: .plain,
      emptyReason: CapitalText.t("capital.chart.notEnough", environment),
      retry: { compute.retry(ComputeStep.data) }
    ) { chart in
      VStack(alignment: .leading, spacing: SectionMetrics.cardGap) {
        NetWorthAreaChart(
          model: chart,
          names: (
            CapitalText.t("capital.chart.net", environment),
            CapitalText.t("capital.chart.have", environment),
            CapitalText.t("capital.chart.owe", environment)
          ),
          spoken: { point in
            point.isNow
              ? CapitalText.t("capital.chart.now", environment)
              : environment.dates.monthTitle(point.day.monthKey)
          },
          height: CapitalMetrics.chartHeight)
        months(chart)
      }
    }
  }

  /// The months under the chart, the first at the left edge and «сегодня» at the right: 11 on the
  /// Mac, 10 on touch.
  private func months(_ chart: NetWorthChartModel) -> some View {
    let labelled = chart.labelled(limit: 5)
    let points = labelled.compactMap { x in chart.points.first { $0.x == x } }
    return HStack(spacing: 0) {
      ForEach(Array(points.enumerated()), id: \.element.x) { index, point in
        if index > 0 { Spacer(minLength: 4) }
        Text(verbatim: label(point, in: chart))
          .appFont(.system(size: LayoutIdiom.resolved(idiom) == .mac ? 11 : 10))
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    }
    .accessibilityHidden(true)
  }

  private func label(_ point: NetWorthChartPoint, in chart: NetWorthChartModel) -> String {
    point.isNow
      ? CapitalText.t("capital.chart.today", environment)
      : environment.dates.shortMonth(
        point.day.monthKey,
        withYear: chart.points.first?.day.year != point.day.year
          && range == .all)
  }

  private var state: BlockState<NetWorthChartModel> {
    compute.states.data.flatMap { snapshot, at in
      let points: [CapitalPoint]
      switch range {
      case .year: points = model.points
      case .all:
        guard let allPoints, allVersion == snapshot.version else { return .calculating }
        points = allPoints
      }
      let chart = NetWorthChartModel(points)
      return chart.hasLine ? .ready(chart, at: at) : .notEnoughData
    }
  }

  private struct AllKey: Hashable {
    var range: CapitalChartRange
    var version: DataVersion?
  }

  private func workOutAll() async {
    guard range == .all, let snapshot = compute.snapshot, allVersion != snapshot.version else {
      return
    }
    let points = await CapitalChartSection.allPoints(of: snapshot)
    guard !Task.isCancelled else { return }
    allPoints = points
    allVersion = snapshot.version
  }
}

/// «Подушка безопасности»: the goal in months at the right, how long the cushion lasts over the
/// obligatory spending of a month, its money, and the bar of the months against the goal. A click
/// on the title offers the accounts and categories of the cushion and its goal. Before the cushion
/// can be counted — no account marked, too few months — the full section says why.
struct CapitalCushionCard: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies
  @Environment(\.appTheme) private var theme
  let status: CushionStatus
  @State private var sheet: CushionSheet?

  var body: some View {
    Group {
      if status.state == .ready {
        card
      } else {
        CushionSection(status: status)
      }
    }
    .sheet(item: $sheet) { sheet in
      Group {
        switch sheet {
        case .setup: CushionSetupSheet { self.sheet = nil }
        case .goal: CushionGoalForm { self.sheet = nil }
        }
      }
      .handingOver(dependencies)
    }
  }

  private var card: some View {
    let weights = CushionText.barWeights(status)
    let whole = max(1, weights.reduce(0, +))
    return VStack(alignment: .leading, spacing: SectionMetrics.cardGap) {
      Menu {
        Button(CushionText.t("cushion.setup.open", environment)) { sheet = .setup }
          .accessibilityIdentifier("cushion.setup.open")
        Button(CushionText.t("cushion.goal.open", environment)) { sheet = .goal }
          .accessibilityIdentifier("cushion.goal.open")
      } label: {
        SectionCardHeader(
          title: CushionText.t("cushion.title", environment),
          caption: CapitalText.format(
            "capital.cushion.goal", environment, String(CushionText.targetMonths(status))))
      }
      .menuStyle(.button)
      .buttonStyle(.plain)
      .menuIndicator(.hidden)
      .accessibilityIdentifier("capital.cushion.header")
      SectionRow(
        badge: SectionBadge(
          symbol: CushionText.symbol, tint: theme.statusPositive, fill: theme.statusPositiveTint),
        title: CapitalText.format(
          "capital.cushion.lasts", environment, CushionText.monthsNumber(status.months ?? 0)),
        detail: status.obligatory.monthlyRub.map {
          CapitalText.format("capital.cushion.monthly", environment, environment.money.rounded($0))
        },
        figure: environment.money.rounded(status.moneyRub))
      GeometryReader { proxy in
        ZStack(alignment: .leading) {
          RoundedRectangle(cornerRadius: CapitalMetrics.barRadius).fill(theme.fillNeutral)
          RoundedRectangle(cornerRadius: CapitalMetrics.barRadius)
            .fill(theme.statusPositive)
            .frame(width: proxy.size.width * CGFloat(weights[0]) / CGFloat(whole))
        }
      }
      .frame(height: CapitalMetrics.barHeight)
      .accessibilityElement()
      .accessibilityLabel(Text(verbatim: CushionText.barLabel(status, environment)))
      .accessibilityIdentifier("capital.cushion.bar")
      if CushionText.touchesHidden(status, hiding: compute.snapshot?.hiding) {
        PartHiddenNote()
      }
      let unanchored = CushionText.unanchored(status.unanchored, hiding: compute.snapshot?.hiding)
      if !unanchored.isEmpty {
        Label {
          Text(
            verbatim: CushionText.unanchoredLine(unanchored, compute.snapshot?.dataset, environment)
          )
        } icon: {
          Image(systemName: "hourglass")
        }
        .appFont(SectionType.rowDetail)
        .foregroundStyle(.secondary)
      }
    }
    .sectionCard()
    .help(
      CushionText.goalHint(
        status.goal, settings: compute.snapshot?.dataset.capitalSettings ?? .standard,
        environment)
    )
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("cushion.section")
  }
}
