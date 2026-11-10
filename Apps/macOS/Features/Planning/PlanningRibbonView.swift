import AppCore
import SwiftUI

/// «Ближайшие 14 дней», as the design draws it: a card with the calendar's symbol and the title,
/// and a row of fourteen days from today, each a rounded cell with its number; a day with
/// something planned is on the accent's tint, its number in the accent, with its mark under the
/// number — a coin for a payment (scheduled payments, subscriptions, debts), an arrow down for
/// an income expected. Hovering says what and how much; a click opens the form of what is
/// planned, a day of several asks which. What comes in and what goes out in all is said by the
/// title's hover and to VoiceOver. Content, never glass; a day is told by its mark and its
/// spoken label, never by the tint alone.
struct PlanningRibbonView: View {
  @Dependency(\.environment) private var environment
  @Environment(\.appTheme) private var theme
  @Environment(\.windowWidth) private var windowWidth
  let ribbon: PlanningRibbon
  let open: (CalendarPlan) -> Void

  /// The mark of what is planned on a day.
  static func mark(of kind: CalendarPlan.Kind) -> String {
    switch kind {
    case .payment: "rublesign.circle"
    case .income: "arrow.down.circle"
    }
  }

  /// A phone's width: seven days on the screen, the other seven a swipe away, under «14 дней».
  private var compact: Bool { ScreenWidth.isCompact(windowWidth) }

  var body: some View {
    VStack(alignment: .leading, spacing: PlanningMetrics.cardGap(compact: compact)) {
      HStack(alignment: .center, spacing: PlanningMetrics.headerIconGap) {
        Image(systemName: "calendar")
          .appFont(.callout.weight(.semibold))
          .foregroundStyle(theme.accentDefault)
          .frame(width: PlanningMetrics.headerIcon, height: PlanningMetrics.headerIcon)
          .accessibilityHidden(true)
        Text(verbatim: t(compact ? "layout.ribbon.phoneTitle" : "layout.ribbon.title"))
          .appFont(PlanningType.cardTitle)
          .foregroundStyle(theme.contentPrimary)
          .lineLimit(2)
          .accessibilityAddTraits(.isHeader)
        Spacer(minLength: 0)
      }
      .help(rangeText.map { "\($0)\n\(Self.totals(ribbon, environment))" } ?? "")
      if ribbon.isEmpty {
        Text(verbatim: t("layout.ribbon.empty"))
          .appFont(PlanningType.cardLink)
          .foregroundStyle(theme.contentSecondary)
      }
      if compact {
        ScrollView(.horizontal) {
          HStack(alignment: .top, spacing: PlanningMetrics.phoneDayGap) {
            ForEach(ribbon.days) { day in
              chip(day)
                .containerRelativeFrame(
                  .horizontal, count: PlanningMetrics.phoneVisibleDays,
                  spacing: PlanningMetrics.phoneDayGap)
            }
          }
        }
        .scrollIndicators(.hidden)
        .accessibilityIdentifier("planning.ribbon.days")
      } else {
        HStack(alignment: .top, spacing: PlanningMetrics.dayGap) {
          ForEach(ribbon.days) { day in chip(day) }
        }
        .accessibilityIdentifier("planning.ribbon.days")
      }
      if !ribbon.withoutRate.isEmpty {
        Text(
          verbatim: environment.format(
            "layout.ribbon.withoutRate", table: "Planning",
            ribbon.withoutRate.map(\.code).joined(separator: ", "))
        )
        .appFont(.caption)
        .foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .padding(PlanningMetrics.cardInset(compact: compact) + PlanningMetrics.cardEdge)
    .planningCardSurface()
    .accessibilityElement(children: .contain)
    .accessibilityLabel(Text(verbatim: t("layout.ribbon.title")))
    .accessibilityValue(Text(verbatim: Self.totals(ribbon, environment)))
    .accessibilityIdentifier("planning.ribbon")
  }

  /// «22 октября — 4 ноября»: the first and the last day of the row.
  private var rangeText: String? {
    guard let first = ribbon.days.first?.day, let last = ribbon.days.last?.day else { return nil }
    return environment.dates.dayAndMonth(first) + " — " + environment.dates.dayAndMonth(last)
  }

  /// «Придёт +100,000 ₽ · уйдёт −32,900 ₽».
  static func totals(_ ribbon: PlanningRibbon, _ environment: AppEnvironment) -> String {
    environment.format(
      "layout.ribbon.totals", table: "Planning", environment.money.rounded(ribbon.incomesRub),
      environment.money.rounded(ribbon.paymentsRub))
  }

  /// «Аренда — 30,000 ₽»: one plan as a hover and a menu say it.
  static func line(_ plan: CalendarPlan, _ environment: AppEnvironment) -> String {
    let name = plan.name.isEmpty ? "—" : CalendarText.title(of: plan, environment)
    return "\(name) — \(environment.money.exact(plan.amount, currency: plan.currency))"
  }

  /// One day: its number over the marks of what is planned; the whole chip is the button when
  /// one plan stands on it, a menu when several do.
  @ViewBuilder
  private func chip(_ day: PlanningRibbon.Day) -> some View {
    let plans = day.incomes + day.payments
    let planned = !plans.isEmpty
    let mark = compact ? PlanningMetrics.phoneDayMark : PlanningMetrics.dayMark
    let radius = compact ? PlanningMetrics.phoneDayRadius : PlanningMetrics.dayRadius
    let inside =
      compact
      ? CGSize(width: PlanningMetrics.phoneDayHorizontal, height: PlanningMetrics.phoneDayVertical)
      : CGSize(width: PlanningMetrics.dayHorizontal, height: PlanningMetrics.dayVertical)
    let face = VStack(
      spacing: compact ? PlanningMetrics.phoneDayLineGap : PlanningMetrics.dayLineGap
    ) {
      Text(verbatim: "\(day.day.day)")
        .appFont(compact ? PlanningType.phoneDayNumber : PlanningType.dayNumber)
        .foregroundStyle(planned ? theme.accentDefault : theme.contentPrimary)
      HStack(spacing: 2) {
        if !day.payments.isEmpty { markImage(.payment) }
        if !day.incomes.isEmpty { markImage(.income) }
      }
      .frame(height: mark)
    }
    .lineLimit(1)
    .minimumScaleFactor(0.6)
    .padding(.horizontal, inside.width)
    .padding(.vertical, inside.height)
    .frame(maxWidth: .infinity)
    .background(planned ? theme.accentTint : theme.fillNeutral, in: .rect(cornerRadius: radius))
    .contentShape(.rect(cornerRadius: radius))
    let help = plans.map { Self.line($0, environment) }.joined(separator: "\n")
    let spoken =
      environment.dates.dayAndMonth(day.day)
      + (help.isEmpty
        ? "" : ": " + help.replacingOccurrences(of: "\n", with: "; "))
    Group {
      if plans.isEmpty {
        face
      } else if plans.count == 1, let plan = plans.first {
        Button {
          open(plan)
        } label: {
          face
        }
        .buttonStyle(.plain)
      } else {
        Menu {
          ForEach(plans) { plan in
            Button(Self.line(plan, environment)) { open(plan) }
          }
        } label: {
          face
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
      }
    }
    .help(help)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Text(verbatim: spoken))
    .accessibilityAddTraits(plans.isEmpty ? [] : .isButton)
  }

  private var markSize: CGFloat {
    compact ? PlanningMetrics.phoneDayMark : PlanningMetrics.dayMark
  }

  private func markImage(_ kind: CalendarPlan.Kind) -> some View {
    Image(systemName: Self.mark(of: kind))
      .resizable()
      .scaledToFit()
      .frame(width: markSize, height: markSize)
      .foregroundStyle(theme.accentDefault)
      .accessibilityHidden(true)
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Planning") }
}
