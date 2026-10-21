import AppCore
import SwiftUI

/// «Ближайшие 14 дней»: a scale of days from today with two lanes — the incomes expected on top,
/// the payments below (scheduled payments, subscriptions, debts) —, each day of a lane marked
/// with its symbol and how many there are. Hovering says what and how much; a click opens the
/// form of what is planned, a day of several asks which. Under the scale, what comes in and
/// what goes out in all. Content, never glass; a lane is told by its symbol and its name, never
/// by colour alone.
struct PlanningRibbonView: View {
  @Dependency(\.environment) private var environment
  let ribbon: PlanningRibbon
  let open: (CalendarPlan) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Label {
          Text(verbatim: t("layout.ribbon.title")).appFont(.headline)
        } icon: {
          Image(systemName: "calendar.day.timeline.left").foregroundStyle(.secondary)
        }
        .accessibilityAddTraits(.isHeader)
        Spacer(minLength: 8)
        Text(verbatim: Self.totals(ribbon, environment))
          .appFont(.callout.monospacedDigit())
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .minimumScaleFactor(0.8)
          .accessibilityIdentifier("planning.ribbon.totals")
      }
      if ribbon.isEmpty {
        Text(verbatim: t("layout.ribbon.empty"))
          .foregroundStyle(.secondary)
      }
      Grid(horizontalSpacing: 2, verticalSpacing: 4) {
        GridRow {
          laneTitle(income: true)
          ForEach(ribbon.days) { day in cell(day.incomes, income: true) }
        }
        GridRow {
          Color.clear.frame(width: 18, height: 1)
          ForEach(ribbon.days) { day in scale(day.day) }
        }
        GridRow {
          laneTitle(income: false)
          ForEach(ribbon.days) { day in cell(day.payments, income: false) }
        }
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
    .contentCard()
    .accessibilityElement(children: .contain)
    .accessibilityLabel(Text(verbatim: t("layout.ribbon.title")))
    .accessibilityIdentifier("planning.ribbon")
  }

  /// «Придёт +100,000 ₽ · уйдёт −32,900 ₽».
  static func totals(_ ribbon: PlanningRibbon, _ environment: AppEnvironment) -> String {
    environment.format(
      "layout.ribbon.totals", table: "Planning", environment.money.rounded(ribbon.incomesRub),
      environment.money.rounded(ribbon.paymentsRub))
  }

  /// «Аренда — 30,000 ₽»: one plan as a hover and a menu say it.
  static func line(_ plan: CalendarPlan, _ environment: AppEnvironment) -> String {
    let name = plan.name.isEmpty ? "—" : plan.name
    return "\(name) — \(environment.money.exact(plan.amount, currency: plan.currency))"
  }

  private func laneTitle(income: Bool) -> some View {
    Image(systemName: income ? "arrow.up.circle" : "arrow.down.circle")
      .foregroundStyle(income ? Color.green : Color.secondary)
      .frame(width: 18)
      .help(t(income ? "layout.ribbon.incomes" : "layout.ribbon.payments"))
      .accessibilityLabel(
        Text(verbatim: t(income ? "layout.ribbon.incomes" : "layout.ribbon.payments")))
  }

  /// The day of the scale: its weekday and number; today in bold.
  private func scale(_ day: DateOnly) -> some View {
    let isToday = day == environment.today
    return VStack(spacing: 0) {
      Text(verbatim: environment.dates.shortWeekday(environment.calendar.weekdayIndex(day)))
        .appFont(.caption2)
        .foregroundStyle(.tertiary)
      Text(verbatim: "\(day.day)")
        .appFont(.caption.monospacedDigit().weight(isToday ? .bold : .regular))
        .foregroundStyle(isToday ? .primary : .secondary)
    }
    .lineLimit(1)
    .minimumScaleFactor(0.6)
    .frame(maxWidth: .infinity)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Text(verbatim: environment.dates.dayAndMonth(day)))
  }

  @ViewBuilder
  private func cell(_ plans: [CalendarPlan], income: Bool) -> some View {
    let symbol = income ? "arrow.up.circle.fill" : "arrow.down.circle.fill"
    let help = plans.map { Self.line($0, environment) }.joined(separator: "\n")
    Group {
      if plans.isEmpty {
        Color.clear.frame(height: 22)
      } else if plans.count == 1, let plan = plans.first {
        Button {
          open(plan)
        } label: {
          mark(symbol: symbol, count: 1, income: income)
        }
        .buttonStyle(.borderless)
      } else {
        Menu {
          ForEach(plans) { plan in
            Button(Self.line(plan, environment)) { open(plan) }
          }
        } label: {
          mark(symbol: symbol, count: plans.count, income: income)
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
      }
    }
    .frame(maxWidth: .infinity, minHeight: 22)
    .help(help)
    .accessibilityLabel(
      Text(
        verbatim: t(income ? "layout.ribbon.incomes" : "layout.ribbon.payments") + ": " + help))
  }

  private func mark(symbol: String, count: Int, income: Bool) -> some View {
    HStack(spacing: 1) {
      Image(systemName: symbol)
        .foregroundStyle(income ? Color.green : Color.secondary)
      if count > 1 {
        Text(verbatim: "\(count)")
          .appFont(.caption2.monospacedDigit())
          .foregroundStyle(.secondary)
      }
    }
    .lineLimit(1)
    .minimumScaleFactor(0.6)
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Planning") }
}
