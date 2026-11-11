import AppCore
import SwiftUI

/// The numbers of «Календарь» as its Mac master draws it (5:35813, 1440 × 900). The page, the
/// cards and the rows are the three screens' (`SectionMetrics`); what is the calendar's own is
/// here.
enum CalendarMetrics {
  /// A day of the month: 63 square on the Mac (71 on a tablet, 5:76678), 4 apart, rounded 8; its number 4 from the left and 3 from the
  /// top; the marks of its plans 12, 4 from the left, at the foot (47 of 63), 2 apart.
  static let cell: CGFloat = 63
  static let padCell: CGFloat = 71
  static let cellGap: CGFloat = 4
  static let cellRadius: CGFloat = 8
  static let numberLeading: CGFloat = 4
  static let numberTop: CGFloat = 3
  static let mark: CGFloat = 12
  static let markGap: CGFloat = 2
  static let markBottom: CGFloat = 4
  /// The chosen day: a 2 pt edge in the accent.
  static let chosenEdge: CGFloat = 2
  /// The row of the weekdays: 14 tall, 4 above the first week.
  static let weekdayHeight: CGFloat = 14
  /// Under the grid: the legend 10 below it, its items 10 apart, a mark 4 from its word; the line
  /// of the fill 10 under the legend.
  static let legendTop: CGFloat = 10
  static let legendGap: CGFloat = 10
  static let legendMarkGap: CGFloat = 4
  /// A row of «Ближайшие события»: 34 tall, its badge 34 with a glyph of 20, the words 10 after.
  static let eventRow: CGFloat = 34
  static let eventGlyph: CGFloat = 20
  /// The least height of the list of the chosen day: three rows of operations.
  static let dayListMinimum: CGFloat = 126
  /// «Дороже обычного» lists the dearest days of the month, the newest first.
  static let dearDaysShown = 3

  /// The room inside a card of a column `column` wide: its margins and edges off.
  static func gridWidth(column: CGFloat) -> CGFloat {
    max(0, column - 2 * (SectionMetrics.cardPadding + SectionMetrics.cardEdge))
  }

  /// The side of a day in a grid `width` wide: 63 at most, smaller when seven of them and their
  /// gaps do not fit.
  static func cellSide(forWidth width: CGFloat, idiom: LayoutIdiom = .mac) -> CGFloat {
    let largest = idiom == .pad ? padCell : cell
    guard width > 0 else { return largest }
    return min(largest, ((width - 6 * cellGap) / 7).rounded(.down))
  }
}

/// The type of the calendar: the number of a day 11 medium (the chosen one bold), the weekdays
/// and the legend 11, the line of the fill 11.
enum CalendarType {
  static func number(chosen: Bool) -> AppFont {
    .system(size: 11, weight: chosen ? .bold : .medium).monospacedDigit()
  }
  static let weekday = AppFont.system(size: 11)
  static let legend = AppFont.system(size: 11)
}

/// What the calendar shows apart from the grid, worked out from the core's calendar without a
/// word of text.
enum CalendarFigures {
  /// The days of the scope that cost more than usual, the newest first: «Дороже обычного».
  static func dearDays(in calendar: SpendingCalendar) -> [SpendingCalendarDay] {
    calendar.days
      .filter { ($0.level ?? .usual) > .usual && ($0.spent?.raw ?? 0) > 0 }
      .sorted { $0.day > $1.day }
  }

  /// What the chosen day's operations came to — the day's «мои расходы», as the grid counts it.
  static func spent(on day: SpendingCalendarDay?) -> AmountE4? {
    guard let spent = day?.spent, spent.raw > 0 else { return nil }
    return spent
  }
}

/// The marks of the plans, as the legend of the frame draws them: an income a green circle with
/// a plus, a payment a blue square with an arrow, a subscription a purple circle with a cycle, a
/// debt a red diamond, a goal contribution a teal star. The words of the legend name them: the
/// shape tells the kind, the colour only agrees.
enum CalendarMark {
  /// The order of the legend and of the marks of a day.
  static let all: [CalendarPlan.Source] = [.income, .payment, .subscription, .debt, .goal]

  static func symbol(_ source: CalendarPlan.Source) -> String {
    switch source {
    case .income: "plus.circle.fill"
    case .payment: "arrow.up.right.square.fill"
    case .subscription: "arrow.triangle.2.circlepath.circle.fill"
    case .debt: "rhombus.fill"
    case .goal: "star.fill"
    }
  }

  static func ink(_ source: CalendarPlan.Source, _ theme: AppThemeColors) -> Color {
    switch source {
    case .income: theme.statusPositive
    case .payment: theme.chart3
    case .subscription: theme.chart7
    case .debt: theme.statusNegative
    case .goal: theme.chart6
    }
  }

  static func fill(_ source: CalendarPlan.Source, _ theme: AppThemeColors) -> Color {
    switch source {
    case .income: theme.statusPositiveTint
    case .payment: theme.chart3Tint
    case .subscription: theme.chart7Tint
    case .debt: theme.statusNegativeTint
    case .goal: theme.chart6Tint
    }
  }

  static func wordKey(_ source: CalendarPlan.Source) -> String {
    "calendar.\(source.rawValue)"
  }
}

/// One day of the grid: its number, the fill of what it cost against a usual day — light for
/// dearer, stronger for much dearer —, the chosen day in the accent with its edge, and the marks
/// of its plans at the foot. The level is never told by the fill alone: its symbol stands at the
/// top right and VoiceOver reads it in words.
struct CalendarGridCell: View {
  @Dependency(\.environment) private var environment
  @Environment(\.appTheme) private var theme
  @Environment(\.colorSchemeContrast) private var contrast
  let day: SpendingCalendarDay
  let calendar: SpendingCalendar
  let side: CGFloat
  var isChosen = false
  var hasNote = false
  var hasBirthday = false
  var isDropTarget = false

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: CalendarMetrics.cellRadius)
    let shown = day.inScope || calendar.scope == .week
    ZStack(alignment: .topLeading) {
      shape.fill(fill)
      if shown {
        Text(verbatim: "\(day.day.day)")
          .appFont(CalendarType.number(chosen: isChosen || day.isToday))
          .foregroundStyle(theme.contentPrimary)
          .lineLimit(1)
          .padding(
            .leading, CalendarMetrics.numberLeading - (isChosen ? CalendarMetrics.chosenEdge : 0)
          )
          .padding(.top, CalendarMetrics.numberTop - (isChosen ? CalendarMetrics.chosenEdge : 0))
        if let symbol = CalendarText.symbol(of: day.level) {
          Image(systemName: symbol)
            .font(.system(size: 9, weight: .semibold))  // font-fixed: a mark of a fixed cell
            .foregroundStyle(theme.contentWarning)
            .padding(4)
            .frame(maxWidth: .infinity, alignment: .topTrailing)
        }
        marks
          .padding(.leading, CalendarMetrics.numberLeading)
          .padding(.bottom, CalendarMetrics.markBottom)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
      }
    }
    .frame(width: side, height: side)
    .overlay {
      if isChosen || isDropTarget {
        shape.strokeBorder(theme.accentDefault, lineWidth: CalendarMetrics.chosenEdge)
      } else if contrast == .increased, day.level ?? .usual > .usual {
        shape.strokeBorder(.separator, lineWidth: 1)
      }
    }
    .contentShape(shape)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(
      Text(
        verbatim: CalendarText.label(of: day, in: calendar, environment)
          + (hasNote ? ", " + QuickText.t("quick.note.mark", environment) : "")
          + (hasBirthday ? ", " + PurchaseHookText.t("calendar.birthday.mark", environment) : ""))
    )
    .accessibilityAddTraits(isChosen ? [.isButton, .isSelected] : .isButton)
  }

  @ViewBuilder
  private var marks: some View {
    let kinds = CalendarMark.all.filter { source in
      day.plans.contains { $0.source == source }
    }
    if !kinds.isEmpty || hasBirthday || hasNote {
      HStack(spacing: CalendarMetrics.markGap) {
        ForEach(kinds, id: \.self) { kind in
          Image(systemName: CalendarMark.symbol(kind))
            .font(.system(size: CalendarMetrics.mark - 1))  // font-fixed: a mark of a fixed cell
            .foregroundStyle(CalendarMark.ink(kind, theme))
            .frame(width: CalendarMetrics.mark, height: CalendarMetrics.mark)
        }
        if hasBirthday {
          Image(systemName: "gift")
            .font(.system(size: CalendarMetrics.mark - 2))  // font-fixed: a mark of a fixed cell
            .foregroundStyle(theme.contentSecondary)
        }
        if hasNote {
          Image(systemName: "note.text")
            .font(.system(size: CalendarMetrics.mark - 2))  // font-fixed: a mark of a fixed cell
            .foregroundStyle(theme.contentSecondary)
        }
      }
    }
  }

  /// No fill for a usual day; the accent's tint for a dearer one, its stronger tint for a much
  /// dearer one, its muted fill for the chosen day.
  private var fill: Color {
    if isChosen { return theme.accentMuted }
    // A day of the next or the last month stands in the grid only to fill its week.
    guard day.inScope || calendar.scope == .week else { return .clear }
    switch day.level {
    case .higher: return theme.accentTint
    case .muchHigher: return theme.accentTintStrong
    case .usual, .none: return .clear
    }
  }
}

/// The card of the grid: «Октябрь 2026» and what the month cost at the right, the weekdays, the
/// weeks, the legend of the marks and the line about the fill. The usual day, too few data and
/// the rate of today are said under it in the same small words when they apply.
struct CalendarGridCard: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.appTheme) private var theme
  @Environment(\.layoutIdiom) private var idiom
  let calendar: SpendingCalendar
  let chosen: DateOnly
  let noteDays: Set<DateOnly>
  let birthdays: Set<DateOnly>
  let dropTarget: DateOnly?
  let choose: (DateOnly) -> Void
  let drop: ([String], DateOnly) -> Bool
  let target: (DateOnly, Bool) -> Void
  /// The room inside the card, from the screen's own width; 0 while not known.
  let width: CGFloat

  private func t(_ key: String) -> String { CalendarText.t(key, environment) }

  var body: some View {
    let side = CalendarMetrics.cellSide(forWidth: width, idiom: LayoutIdiom.resolved(idiom))
    VStack(alignment: .leading, spacing: SectionMetrics.cardGap) {
      SectionCardHeader(
        title: CalendarText.title(of: calendar, environment),
        caption: CalendarText.format(
          "calendar.grid.spent", environment,
          CalendarText.money(calendar.spent, of: calendar, environment))
      )
      .accessibilityIdentifier("calendar.title")
      VStack(alignment: .leading, spacing: CalendarMetrics.cellGap) {
        HStack(spacing: CalendarMetrics.cellGap) {
          ForEach(calendar.weekdays, id: \.self) { weekday in
            Text(verbatim: environment.dates.shortWeekday(weekday))
              .appFont(CalendarType.weekday)
              .foregroundStyle(.secondary)
              .frame(width: side, height: CalendarMetrics.weekdayHeight)
          }
        }
        ForEach(calendar.weeks, id: \.first?.day) { week in
          HStack(spacing: CalendarMetrics.cellGap) {
            ForEach(week) { day in cell(day, side: side) }
          }
        }
      }
      // The grid never widens the card: until the screen knows its width it may overflow.
      .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
      .clipped()
      legend
      notes
    }
    .sectionCard()
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("calendar.grid")
  }

  private func cell(_ day: SpendingCalendarDay, side: CGFloat) -> some View {
    Button {
      choose(day.day)
    } label: {
      CalendarGridCell(
        day: day, calendar: calendar, side: side, isChosen: day.day == chosen,
        hasNote: noteDays.contains(day.day), hasBirthday: birthdays.contains(day.day),
        isDropTarget: dropTarget == day.day)
    }
    .buttonStyle(.plain)
    .dropDestination(for: String.self) { items, _ in
      drop(items, day.day)
    } isTargeted: { targeted in
      target(day.day, targeted)
    }
    .accessibilityIdentifier("calendar.day.\(day.day.iso)")
  }

  /// The five kinds of plan with their marks, 10 apart.
  private var legend: some View {
    HStack(spacing: CalendarMetrics.legendGap) {
      ForEach(CalendarMark.all, id: \.self) { kind in
        HStack(spacing: CalendarMetrics.legendMarkGap) {
          Image(systemName: CalendarMark.symbol(kind))
            .font(.system(size: CalendarMetrics.mark - 1))  // font-fixed: the mark of the legend
            .foregroundStyle(CalendarMark.ink(kind, theme))
            .frame(width: CalendarMetrics.mark, height: CalendarMetrics.mark)
            .accessibilityHidden(true)
          Text(verbatim: t(CalendarMark.wordKey(kind)))
        }
      }
    }
    .appFont(CalendarType.legend)
    .foregroundStyle(.secondary)
    .padding(.top, CalendarMetrics.legendTop - SectionMetrics.cardGap)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("calendar.legend")
  }

  /// The line about the fill, and under it what else the month needs said: too few data for a
  /// usual day, the usual day, the rate of today, a part hidden.
  @ViewBuilder
  private var notes: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(verbatim: t("calendar.legend.level"))
      if calendar.lowData || calendar.usual == nil {
        Label {
          Text(verbatim: t("calendar.lowData"))
        } icon: {
          Image(systemName: "hourglass")
        }
      } else if let usual = calendar.usual {
        Text(
          verbatim: environment.format(
            "calendar.usual", table: CalendarText.table,
            CalendarText.money(usual, of: calendar, environment)))
      }
      if calendar.currency != .rub { Text(verbatim: t("calendar.atTodaysRate")) }
      if let snapshot = compute.snapshot, CalendarScreen.partHidden(of: calendar, in: snapshot) {
        PartHiddenNote()
      }
    }
    .appFont(CalendarType.legend.monospacedDigit())
    .foregroundStyle(.secondary)
    .fixedSize(horizontal: false, vertical: true)
  }
}

/// «Дороже обычного»: the days of the scope that cost more than usual, the newest first, the
/// count at the right; a click on one chooses it.
struct CalendarDearDaysCard: View {
  @Dependency(\.environment) private var environment
  @Environment(\.appTheme) private var theme
  let calendar: SpendingCalendar
  let choose: (DateOnly) -> Void

  var body: some View {
    let days = CalendarFigures.dearDays(in: calendar)
    if !days.isEmpty {
      VStack(alignment: .leading, spacing: SectionMetrics.cardGap) {
        SectionCardHeader(
          title: CalendarText.t("calendar.level.higher", environment),
          caption: CalendarText.days(days.count, environment))
        ForEach(days.prefix(CalendarMetrics.dearDaysShown)) { day in
          Button {
            choose(day.day)
          } label: {
            SectionRow(
              badge: SectionBadge(
                symbol: "exclamationmark.triangle",
                tint: day.level == .muchHigher ? theme.statusNegative : theme.contentWarning,
                fill: day.level == .muchHigher ? theme.statusNegativeTint : theme.accentTint),
              title: environment.dates.dayAndMonth(day.day),
              detail: CalendarText.levelDetail(of: day, environment),
              figure: "−" + CalendarText.money(day.spent ?? .zero, of: calendar, environment))
          }
          .buttonStyle(.plain)
          .accessibilityIdentifier("calendar.dear.\(day.day.iso)")
        }
      }
      .sectionCard()
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("calendar.dear")
    }
  }
}

/// «Ближайшие события»: what is planned from today on, soonest first, the count at the right; a
/// payment and an income each with its mark in a badge, the income's figure green with its plus.
struct CalendarUpcomingCard: View {
  @Dependency(\.environment) private var environment
  @Environment(\.appTheme) private var theme
  let calendar: SpendingCalendar

  var body: some View {
    let plans = CalendarLayout.upcoming(in: calendar)
    if !plans.isEmpty {
      VStack(alignment: .leading, spacing: SectionMetrics.cardGap) {
        SectionCardHeader(
          title: CalendarText.t("calendar.upcoming", environment), caption: "\(plans.count)")
        ForEach(plans) { plan in
          HStack(spacing: SectionMetrics.rowGap) {
            Image(systemName: CalendarMark.symbol(plan.source))
              .font(.system(size: CalendarMetrics.eventGlyph - 2))  // font-fixed: a fixed badge
              .foregroundStyle(CalendarMark.ink(plan.source, theme))
              .frame(width: CalendarMetrics.eventRow, height: CalendarMetrics.eventRow)
              .background(
                CalendarMark.fill(plan.source, theme),
                in: .rect(cornerRadius: SectionMetrics.segmentRadius)
              )
              .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: SectionMetrics.rowLineGap) {
              Text(
                verbatim: environment.dates.dayAndMonth(plan.day) + " · "
                  + CalendarText.title(of: plan, environment)
              )
              .appFont(SectionType.rowTitle)
              .lineLimit(1)
              Text(verbatim: CalendarText.t(CalendarMark.wordKey(plan.source), environment))
                .appFont(SectionType.rowDetail)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(
              verbatim: (plan.kind == .income ? "+" : "−")
                + CalendarText.amount(of: plan, environment)
            )
            .appFont(SectionType.rowFigure)
            .foregroundStyle(plan.kind == .income ? theme.statusPositive : theme.contentPrimary)
            .lineLimit(1)
            .fixedSize()
          }
          .frame(minHeight: CalendarMetrics.eventRow)
          .accessibilityElement(children: .combine)
        }
      }
      .sectionCard()
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("calendar.upcoming")
    }
  }
}

extension CalendarText {
  /// «расходы 148 200 ₽»: the caption of the grid.
  static func format(
    _ key: String, _ environment: AppEnvironment, _ arguments: CVarArg...
  ) -> String {
    String(
      format: environment.language(key, table: table), locale: environment.language.locale,
      arguments: arguments)
  }

  /// «3 дня»: how many days are dearer than usual.
  static func days(_ count: Int, _ environment: AppEnvironment) -> String {
    environment.format("calendar.dear.count", table: table, counts: count)
  }
}
