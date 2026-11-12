import AppCore
import SwiftUI

/// The numbers of Planning as the design draws it on the Mac — the master at 1440 × 900 and its
/// two narrower frames at 1280 and 1024 —, so the screen and its frames agree to the point. The
/// margins of the page are the one style's (`StyleMetrics`); what is Planning's own is here.
enum PlanningMetrics {
  /// The margins of the page: 28 at the sides, 22 above, 24 below on the Mac; 16 each on a phone
  /// and a tablet, as their frames draw every screen.
  static var pageSide: CGFloat {
    #if os(iOS)
      16
    #else
      StyleMetrics.pageSide
    #endif
  }
  static var pageTop: CGFloat {
    #if os(iOS)
      16
    #else
      StyleMetrics.pageTop
    #endif
  }
  static var pageBottom: CGFloat {
    #if os(iOS)
      16
    #else
      StyleMetrics.pageBottom
    #endif
  }

  /// Between the parts stacked down the page — the header, the tabs, the free sum, the next 14
  /// days, the blocks —, between the title and its subtitle, and between two cards: 14.
  static let stackGap: CGFloat = 14
  static let columnGap: CGFloat = StyleMetrics.columnGap

  /// A card: its content 16 inside a 1 pt edge, 8 between its rows, radius 12.
  static let cardInset: CGFloat = 16
  static let cardGap: CGFloat = 8
  static let cardEdge: CGFloat = 1

  /// The card of the free sum: 17 inside its edge and 10 between its title, figures and hint.
  static let freeInset: CGFloat = 17
  static let freeGap: CGFloat = 10
  /// Its six columns: 24 after the first, 20 at each side of the others, a divider of 1 × 52, 4
  /// between a figure and its words.
  static let freeFirstTrailing: CGFloat = 24
  static let freeColumnSide: CGFloat = 20
  static let dividerHeight: CGFloat = 52
  static let figureGap: CGFloat = 4
  /// Its four metrics on a narrower window: 18 apart, 5 between a figure and its words.
  static let metricGap: CGFloat = 18
  static let metricLineGap: CGFloat = 5

  /// A tab: 11 × 5 inside a capsule, 6 apart.
  static let tabHorizontal: CGFloat = 11
  static let tabVertical: CGFloat = 5
  static let tabGap: CGFloat = 6

  /// A day of «Ближайшие 14 дней»: 4 × 8 inside, radius 10, 6 apart; 3 between its number and its
  /// mark of 12.
  static let dayHorizontal: CGFloat = 4
  static let dayVertical: CGFloat = 8
  static let dayRadius: CGFloat = 10
  static let dayGap: CGFloat = 6
  static let dayLineGap: CGFloat = 3
  static let dayMark: CGFloat = 12

  /// The header of a card: its symbol 16, 8 from the title.
  static let headerIcon: CGFloat = 16
  static let headerIconGap: CGFloat = 8

  /// The narrowest card of three columns, at «Обычный»: three of them and two gaps (928) fit the
  /// 992 of the 1280 frame and not the 736 of the 1024 one.
  static let cardMinWidth: CGFloat = 300
  /// The free sum spreads over six columns from this width of content, at «Обычный»: the 1,152
  /// of the master holds them, the 992 of the 1280 frame shows the four metrics.
  static let sixColumnsFrom: CGFloat = 1_072

  /// A phone's width (the iPhone master, 440 wide): 8 between the parts; a card 13 inside its
  /// edge and 6 between its rows; the days 4 apart, 2 × 6 inside, radius 8, 2 to the mark of 11,
  /// seven of them on the screen and the rest a swipe away.
  static let phoneStackGap: CGFloat = 8
  static let phoneCardInset: CGFloat = 13
  static let phoneCardGap: CGFloat = 6
  static let phoneDayGap: CGFloat = 4
  static let phoneDayHorizontal: CGFloat = 2
  static let phoneDayVertical: CGFloat = 6
  static let phoneDayRadius: CGFloat = 8
  static let phoneDayLineGap: CGFloat = 2
  static let phoneDayMark: CGFloat = 11
  static let phoneVisibleDays = 7

  /// The inset and the row gap of a card on a phone's width or a wider one.
  static func cardInset(compact: Bool) -> CGFloat { compact ? phoneCardInset : cardInset }
  static func cardGap(compact: Bool) -> CGFloat { compact ? phoneCardGap : cardGap }
}

/// The type of Planning, in points at «Обычный»; each grows with the size of the text chosen in
/// Settings (`AppFont`).
enum PlanningType {
  /// «Планирование»: 22 bold; under it «Ноябрь 2026», 14 medium.
  static let title = StyleType.screenTitle
  static let subtitle = AppFont.system(size: 14, weight: .medium)
  /// A tab: 12; the chosen one 12 semibold.
  static let tab = AppFont.callout
  static let chosenTab = AppFont.callout.weight(.semibold)
  /// «Сейчас свободно»: 14 semibold; the figure 34 semibold, the figures beside it 16 semibold,
  /// the words under them 12, the hint 11.
  static let freeTitle = AppFont.system(size: 14, weight: .semibold)
  static let freeFigure = AppFont.system(size: 34, weight: .semibold).monospacedDigit()
  static let freeColumn = AppFont.system(size: 16, weight: .semibold).monospacedDigit()
  static let freeWords = AppFont.callout
  static let freeHint = AppFont.subheadline
  /// A figure of the four metrics: 21 semibold.
  static let metricFigure = AppFont.system(size: 21, weight: .semibold).monospacedDigit()
  /// The title of a card: 15 semibold; «все» at its right, 12.
  static let cardTitle = StyleType.tileTitle
  static let cardLink = AppFont.callout
  /// The number of a day: 13 semibold; 12 on a phone.
  static let dayNumber = AppFont.body.weight(.semibold).monospacedDigit()
  static let phoneDayNumber = AppFont.callout.weight(.semibold).monospacedDigit()
  /// The phone's line of the free sum: 13 medium.
  static let phoneLine = AppFont.body.weight(.medium).monospacedDigit()
}

/// How Planning lays itself out by the width of its content: three columns of blocks on a wide
/// window and one on a narrow one, and the free sum in six columns or in four metrics. The width
/// is the content's — the window less the sidebar, the form at the right and the margins — and
/// every threshold grows with the size of the text.
enum PlanningPageLayout {
  static func blockColumns(forContent width: CGFloat, fontSize: AppFontSize = .regular) -> Int {
    let card = fontSize.points(fromRegular: PlanningMetrics.cardMinWidth)
    return width >= 3 * card + 2 * PlanningMetrics.columnGap ? 3 : 1
  }

  static func freeShowsColumns(
    forContent width: CGFloat, fontSize: AppFontSize = .regular
  ) -> Bool {
    width >= fontSize.points(fromRegular: PlanningMetrics.sixColumnsFrom)
  }

  /// The width of one card in `columns` columns.
  static func cardWidth(forContent width: CGFloat, columns: Int) -> CGFloat {
    let count = CGFloat(max(1, columns))
    return max(0, (width - (count - 1) * PlanningMetrics.columnGap) / count)
  }

  /// The blocks in `count` columns, each column a run of the order: the first blocks fill the
  /// first column, the next the second, the earlier columns taking one more when they do not
  /// share evenly — so the order reads down each column, as the design lays «Платежи» over
  /// «Ожидаемые поступления».
  static func deal(_ blocks: [PlanningBlock], into count: Int) -> [[PlanningBlock]] {
    let count = max(1, count)
    let base = blocks.count / count
    let extra = blocks.count % count
    var result: [[PlanningBlock]] = []
    var start = 0
    for column in 0..<count {
      let size = base + (column < extra ? 1 : 0)
      result.append(Array(blocks[start..<start + size]))
      start += size
    }
    return result
  }

  /// The blocks of the grid: the shown order without the free sum, which is the card above it.
  static func gridBlocks(_ shown: [PlanningBlock]) -> [PlanningBlock] {
    shown.filter { $0 != .freeMoney }
  }
}

/// The tabs under the title: «Всё» shows every block; each other tab shows its block alone over
/// the whole page, «Подушка» the safety cushion and «План года» the plan of the year.
enum PlanningTab: String, CaseIterable, Identifiable {
  case all
  case payments
  case income
  case limits
  case goals
  case events
  case cushion
  case year

  var id: String { rawValue }

  var titleKey: String { "layout.tab.\(rawValue)" }

  /// The blocks a tab shows; «Всё» shows the whole page, the cushion and the year a page of
  /// their own.
  var blocks: [PlanningBlock] {
    switch self {
    case .payments: [.payments, .subscriptions]
    case .income: [.expectedIncome]
    case .limits: [.limits]
    case .goals: [.goals]
    case .events: [.events]
    case .all, .cushion, .year: []
    }
  }

  /// The tab «все» of a card opens; nothing for a block without a tab of its own.
  static func tab(of block: PlanningBlock) -> PlanningTab? {
    allCases.first { $0.blocks.contains(block) }
  }
}

/// The header of Planning: «Планирование» and the month under it, and at the right the one main
/// button «+ Добавить ▾», whose menu holds the six forms. The questions of the screen — «Хватит
/// ли?», «Что если…», the warranties, the order of the blocks — wait in the quiet menu before it.
/// On a phone's width the large title of the design stands alone with one menu at its right.
struct PlanningHeader: View {
  @Dependency(\.environment) private var environment
  @Environment(\.openWindow) private var openWindow
  @Environment(\.dependencies) private var dependencies
  @Environment(\.windowWidth) private var windowWidth
  @State private var asksAfford = false
  @State private var showsWarranty = false
  @Binding var editing: Bool
  let add: (PlanningAddition) -> Void

  private var compact: Bool { ScreenWidth.isCompact(windowWidth) }

  var body: some View {
    VStack(
      alignment: .leading,
      spacing: compact ? PlanningMetrics.phoneStackGap : PlanningMetrics.stackGap
    ) {
      HStack(alignment: .center, spacing: 12) {
        Text(verbatim: environment.language("section.planning"))
          .appFont(Self.titleFont)
          .lineLimit(1)
          #if os(iOS)
            .minimumScaleFactor(compact ? 0.8 : 1)
          #endif
          .accessibilityAddTraits(.isHeader)
          .accessibilityIdentifier("planning.title")
        Spacer(minLength: 8)
        if compact {
          actionsMenu
        } else {
          HStack(spacing: StyleMetrics.headerButtonGap) {
            moreMenu
            addMenu
          }
        }
      }
      // A phone's frame has no subtitle: the free sum's line stands under the title.
      if !compact {
        Text(verbatim: Self.subtitle(environment))
          .appFont(PlanningType.subtitle)
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("planning.subtitle")
      }
    }
    .sheet(isPresented: $asksAfford) { AffordSheet().handingOver(dependencies) }
    .sheet(isPresented: $showsWarranty) { WarrantyScreen().handingOver(dependencies) }
  }

  /// The title as the design sets it: 22 bold on the Mac, the large title on touch devices.
  private static var titleFont: AppFont {
    #if os(iOS)
      .largeTitle.bold()
    #else
      PlanningType.title
    #endif
  }

  /// «Ноябрь 2026»: the month of today, in the language of the interface.
  @MainActor
  static func subtitle(_ environment: AppEnvironment) -> String {
    environment.dates.monthTitle(environment.today.monthKey)
  }

  /// The six forms, in the order of the design: Платёж, Подписку, Поступление, Лимит, Цель,
  /// Событие. Plain items, without symbols of their own, as every menu of the app.
  @ViewBuilder
  private var addItems: some View {
    ForEach(PlanningAddition.allCases) { addition in
      Button(PlanningBlockText.t(addition.titleKey, environment)) { add(addition) }
        .accessibilityIdentifier("planning.add.\(addition.rawValue)")
    }
  }

  @ViewBuilder
  private var questionItems: some View {
    Button(environment.language("afford.title", table: "WhatIf")) { asksAfford = true }
      .accessibilityIdentifier("planning.afford")
    Button(environment.language("window.whatIf")) { AppScreens.open(.whatIf, with: openWindow) }
      .accessibilityIdentifier("planning.whatIf")
    Button(WarrantyText.t("warranty.button", environment)) { showsWarranty = true }
      .accessibilityIdentifier("planning.warranty")
    Button(PlanningBlockText.t(editing ? "layout.done" : "layout.edit", environment)) {
      editing.toggle()
    }
    .accessibilityIdentifier("planning.edit")
  }

  /// «+ Добавить ▾»: the accent fill, 13 medium, 16 × 9, radius 10.
  private var addMenu: some View {
    Menu {
      addItems
    } label: {
      HStack(spacing: 6) {
        Image(systemName: "plus")
          .appFont(.subheadline.weight(.semibold))
        Text(verbatim: PlanningBlockText.t("layout.add", environment))
        Image(systemName: "chevron.down")
          .appFont(.caption2.weight(.bold))
      }
    }
    .menuStyle(.button)
    .buttonStyle(.primaryAction)
    .menuIndicator(.hidden)
    .fixedSize()
    .accessibilityLabel(Text(verbatim: PlanningBlockText.t("layout.add", environment)))
    .accessibilityIdentifier("planning.add")
    // The whole button as one place on the screen, the size the design gives it.
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("planning.addButton")
  }

  /// The questions of the screen and the order of the blocks: a quiet round button before
  /// «Добавить», so the one main button of the design stays alone.
  private var moreMenu: some View {
    Menu {
      questionItems
    } label: {
      Image(systemName: "ellipsis")
        .accessibilityLabel(Text(verbatim: PlanningBlockText.t("layout.more", environment)))
    }
    .menuStyle(.button)
    .buttonStyle(.quietAction)
    .menuIndicator(.hidden)
    .fixedSize()
    .help(PlanningBlockText.t("layout.more", environment))
    .accessibilityIdentifier("planning.more")
  }

  /// One round button on a phone: the forms first, then the questions and the order.
  private var actionsMenu: some View {
    Menu {
      Section { addItems }
      Section { questionItems }
    } label: {
      Image(systemName: "ellipsis.circle")
        .appFont(.title2)
        .accessibilityLabel(Text(verbatim: PlanningBlockText.t("layout.add", environment)))
    }
    .menuStyle(.button)
    .buttonStyle(.borderless)
    .fixedSize()
    .accessibilityIdentifier("planning.actions")
  }
}

/// The row of tabs under the header: grey capsules, the chosen one on the accent's tint and in
/// semibold — the weight says it as well as the colour.
struct PlanningTabsRow: View {
  @Dependency(\.environment) private var environment
  @Environment(\.appTheme) private var theme
  @Binding var tab: PlanningTab

  var body: some View {
    FlowRow(spacing: PlanningMetrics.tabGap, lineSpacing: PlanningMetrics.tabGap) {
      ForEach(PlanningTab.allCases) { item in
        let chosen = item == tab
        Button {
          tab = item
        } label: {
          Text(verbatim: PlanningBlockText.t(item.titleKey, environment))
            .appFont(chosen ? PlanningType.chosenTab : PlanningType.tab)
            .foregroundStyle(chosen ? theme.contentPrimary : theme.contentSecondary)
            .lineLimit(1)
            .padding(.horizontal, PlanningMetrics.tabHorizontal)
            .padding(.vertical, PlanningMetrics.tabVertical)
            .background(chosen ? theme.accentTint : theme.fillNeutral, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(chosen ? .isSelected : [])
        .accessibilityIdentifier("planning.tab.\(item.rawValue)")
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("planning.tabs")
  }
}

/// The words and figures of the card «Сейчас свободно»: on a wide window the free sum big with
/// five columns beside it — the day's guide, the payments ahead, the incomes waited for, the tax
/// of self-employment, the cushion —; on a narrower one four metrics. Every figure is the free
/// sum's (`FreeMoney`); only the words are put here, and a column with nothing to say is left
/// out.
struct PlanningFreeFigures: Equatable {
  struct Figure: Equatable {
    var figure: String
    var words: String
    var id: String
  }

  var title: String
  var main: Figure
  var columns: [Figure]
  var metrics: [Figure]
  var hint: String
  var recovery: String? = nil
  /// The one line a phone shows instead of the card: «Сейчас свободно 41 600 ₽ · до 1 386 ₽/день».
  var line: String

  /// `horizon` is the owner's when the screen shows the configured free sum, nil when a day
  /// was picked in the block of the free sum. `nil` while nothing is counted.
  @MainActor
  static func make(
    free: FreeMoney, horizon: FreeMoneyHorizon?, _ environment: AppEnvironment
  ) -> PlanningFreeFigures? {
    guard free.state == .ready, let grey = free.grey else { return nil }
    func t(_ key: String) -> String { PlanningBlockText.t(key, environment) }
    let money = environment.money
    let day = PlanningBlockText.dayText(free.until, environment)
    let thirtyDays = horizon == .thirtyDays
    let span =
      thirtyDays
      ? environment.format("layout.free.days", table: "Planning", counts: free.days)
      : environment.format("layout.free.until", table: "Planning", day)
    let reserve =
      free.cushion.isZero
      ? ""
      : environment.format(
        "layout.free.reserveOut", table: "Planning", money.rounded(free.cushion))
    let daily = money.rubles(free.dailyRubles)
    // Below zero the plans ask more than there is: the card says so with the shortfall, as the
    // main card of Overview does, and has no figure for a day.
    let short = FreeVerdict(free: grey) == .short
    let figure = money.rounded(free.spendable ?? .zero)
    let recovery = FreeMoneyRecoveryText.explanation(free, environment)
    let summary = PlanningSummary(free)
    let dues = summary.map { ($0.dueCount, $0.duesAmount) }
    let expected = free.info.filter { $0.key == FreeMoney.Key.stillExpected }
      .reduce(AmountE4.zero) { $0 + $1.amount }
    let tax = free.lines.filter { $0.key == FreeMoney.Key.npdTax }
      .reduce(AmountE4.zero) { $0 + $1.amount }

    var columns: [Figure] = []
    if free.dailyReductionRubles == nil {
      columns.append(
        Figure(
          figure: environment.format("layout.free.perDay", table: "Planning", daily),
          words: thirtyDays ? t("layout.free.noIncome") : span, id: "daily"))
    }
    if let dues, dues.0 > 0 {
      columns.append(
        Figure(
          figure: PlanningText.sign(false) + " " + money.rounded(dues.1),
          words: environment.format("layout.free.dues", table: "Planning", counts: dues.0),
          id: "dues"))
    }
    if expected > .zero {
      columns.append(
        Figure(
          figure: PlanningText.sign(true) + " " + money.rounded(expected),
          words: t("layout.free.expected"), id: "expected"))
    }
    if tax > .zero {
      columns.append(
        Figure(figure: "≈ " + money.rounded(tax), words: t("layout.free.tax"), id: "tax"))
    }
    if !free.cushion.isZero {
      columns.append(
        Figure(
          figure: money.rounded(free.cushion), words: t("layout.free.cushion"), id: "cushion"))
    }

    var metrics = [
      Figure(
        figure: figure,
        words: short
          ? t("free.now")
          : thirtyDays
            ? environment.format("layout.free.metric.span", table: "Planning", counts: free.days)
            : environment.format("layout.free.metric.until", table: "Planning", day),
        id: "free")
    ]
    if free.dailyReductionRubles == nil {
      metrics.append(Figure(figure: daily, words: t("layout.free.metric.daily"), id: "daily"))
    }
    if !free.cushion.isZero {
      metrics.append(
        Figure(
          figure: money.rounded(free.cushion), words: t("layout.free.metric.reserve"),
          id: "reserve"))
    }
    if let dues, dues.0 > 0 {
      metrics.append(
        Figure(figure: money.rounded(dues.1), words: t("layout.free.metric.dues"), id: "dues"))
    }

    let caption = horizon == .nearestIncome ? "free.untilIncome" : "free.now"
    let title = t(caption)
    let line =
      free.dailyReductionRubles != nil
      ? "\(title) \(figure)\n\(recovery)"
      : "\(title) \(figure) · "
        + environment.format("layout.free.phoneDaily", table: "Planning", daily)
    return PlanningFreeFigures(
      title: title,
      main: Figure(
        figure: figure, words: free.dailyReductionRubles == nil ? span + reserve : span, id: "free"),
      columns: columns, metrics: metrics, hint: t("layout.free.hint"),
      recovery: free.dailyReductionRubles == nil ? nil : recovery, line: line)
  }
}

/// The card «Сейчас свободно» at the top of Planning: white, with the theme's hairline, the sum
/// and what it is made of. Its title opens the whole block of the free sum — the day to count
/// to, the lines taken away, the cushion, «Сколько нужно в этом месяце». Content, never glass;
/// the figures stay in the primary ink, the words say what each one is.
struct PlanningFreeCard: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.themeSurfaces) private var surfaces
  let figures: PlanningFreeFigures
  let showsColumns: Bool
  let open: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: PlanningMetrics.freeGap) {
      Button(action: open) {
        Text(verbatim: figures.title)
          .appFont(PlanningType.freeTitle)
          .foregroundStyle(theme.contentPrimary)
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("planning.free.open")
      if showsColumns {
        columns
      } else {
        metrics
      }
      if let recovery = figures.recovery {
        Text(verbatim: recovery)
          .appFont(PlanningType.freeWords)
          .foregroundStyle(theme.contentSecondary)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("planning.free.recovery")
      }
      Text(verbatim: figures.hint)
        .appFont(PlanningType.freeHint)
        .foregroundStyle(theme.contentSecondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(PlanningMetrics.freeInset + PlanningMetrics.cardEdge)
    .planningCardSurface()
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("planning.free")
  }

  private var columns: some View {
    HStack(alignment: .center, spacing: 0) {
      VStack(alignment: .leading, spacing: PlanningMetrics.figureGap) {
        Text(verbatim: figures.main.figure)
          .appFont(PlanningType.freeFigure)
          .foregroundStyle(theme.contentPrimary)
          .lineLimit(1)
          .minimumScaleFactor(0.6)
          .accessibilityIdentifier("planning.hero.figure")
        Text(verbatim: figures.main.words)
          .appFont(PlanningType.freeWords)
          .foregroundStyle(theme.contentSecondary)
          .lineLimit(1)
      }
      .fixedSize()
      .padding(.trailing, PlanningMetrics.freeFirstTrailing)
      ForEach(Array(figures.columns.enumerated()), id: \.element.id) { index, column in
        Rectangle()
          .fill(theme.borderOutline)
          .frame(width: 1, height: PlanningMetrics.dividerHeight)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: PlanningMetrics.figureGap) {
          Text(verbatim: column.figure)
            .appFont(PlanningType.freeColumn)
            .foregroundStyle(theme.contentPrimary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
          Text(verbatim: column.words)
            .appFont(PlanningType.freeWords)
            .foregroundStyle(theme.contentSecondary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, PlanningMetrics.freeColumnSide)
        .padding(
          .trailing, index == figures.columns.count - 1 ? 0 : PlanningMetrics.freeColumnSide
        )
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("planning.free.\(column.id)")
      }
      if figures.columns.isEmpty { Spacer(minLength: 0) }
    }
    .accessibilityIdentifier("planning.free.columns")
  }

  private var metrics: some View {
    HStack(alignment: .top, spacing: PlanningMetrics.metricGap) {
      ForEach(figures.metrics, id: \.id) { metric in
        VStack(alignment: .leading, spacing: PlanningMetrics.metricLineGap) {
          Text(verbatim: metric.figure)
            .appFont(PlanningType.metricFigure)
            .foregroundStyle(theme.contentPrimary)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .accessibilityIdentifier("planning.metric.\(metric.id).figure")
          Text(verbatim: metric.words)
            .appFont(PlanningType.freeWords)
            .foregroundStyle(theme.contentSecondary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("planning.metric.\(metric.id)")
      }
    }
    .accessibilityIdentifier("planning.free.metrics")
  }
}

/// The free sum on a phone's width, as its frame draws it: one line of 13 medium under the title,
/// «Сейчас свободно 41 600 ₽ · до 1 386 ₽/день», which opens the whole block of the free sum.
struct PlanningFreeLine: View {
  @Environment(\.appTheme) private var theme
  let figures: PlanningFreeFigures
  let open: () -> Void

  var body: some View {
    Button(action: open) {
      Text(verbatim: figures.line)
        .appFont(PlanningType.phoneLine)
        .foregroundStyle(theme.contentPrimary)
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("planning.free.line")
  }
}

extension View {
  /// The surface of a card of Planning: the theme's card colour, its hairline at 1 pt, radius 12
  /// (22 on touch devices, as their cards), the separator edge too under «Увеличить контраст».
  func planningCardSurface() -> some View {
    modifier(PlanningCardSurface())
  }
}

private struct PlanningCardSurface: ViewModifier {
  @Environment(\.themeSurfaces) private var surfaces
  @Environment(\.colorSchemeContrast) private var contrast

  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: ContentCard.cornerRadius)
    content
      .background(surfaces.card, in: shape)
      .overlay {
        shape.strokeBorder(surfaces.cardBorder, lineWidth: PlanningMetrics.cardEdge)
        if contrast == .increased { shape.strokeBorder(.separator, lineWidth: 1) }
      }
  }
}
