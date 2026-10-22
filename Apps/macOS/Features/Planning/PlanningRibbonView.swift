import AppCore
import SwiftUI

/// «Ближайшие 14 дней»: a row of days from today, each a small chip with its number; a day with
/// something planned is tinted and carries its mark under the number — a circle for an income
/// expected, a square for a payment (scheduled payments, subscriptions, debts) —, and the legend
/// under the row says which is which. Hovering says what and how much; a click opens the form of
/// what is planned, a day of several asks which. Under the legend, what comes in and what goes
/// out in all. Content, never glass; a day is told by its mark and its spoken label, never by
/// the tint alone.
struct PlanningRibbonView: View {
  @Dependency(\.environment) private var environment
  @Environment(\.themeSurfaces) private var surfaces
  let ribbon: PlanningRibbon
  let open: (CalendarPlan) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(verbatim: t("layout.ribbon.title"))
          .appFont(.headline)
          .lineLimit(2)
          .accessibilityAddTraits(.isHeader)
        Spacer(minLength: 8)
        if let range = rangeText {
          Text(verbatim: range)
            .appFont(.callout.monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        }
      }
      if ribbon.isEmpty {
        Text(verbatim: t("layout.ribbon.empty"))
          .foregroundStyle(.secondary)
      }
      HStack(alignment: .top, spacing: 3) {
        ForEach(ribbon.days) { day in chip(day) }
      }
      HStack(spacing: 12) {
        legend(shape: Circle(), key: "layout.ribbon.legend.income")
        legend(shape: Rectangle(), key: "layout.ribbon.legend.payment")
      }
      Text(verbatim: Self.totals(ribbon, environment))
        .appFont(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .lineLimit(2)
        .accessibilityIdentifier("planning.ribbon.totals")
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
    let name = plan.name.isEmpty ? "—" : plan.name
    return "\(name) — \(environment.money.exact(plan.amount, currency: plan.currency))"
  }

  private func legend<S: Shape>(shape: S, key: String) -> some View {
    HStack(spacing: 5) {
      shape
        .fill(.secondary)
        .frame(width: 6, height: 6)
        .accessibilityHidden(true)
      Text(verbatim: t(key))
        .appFont(.caption)
        .foregroundStyle(.secondary)
    }
  }

  /// One day: its number over the marks of what is planned; the whole chip is the button when
  /// one plan stands on it, a menu when several do.
  @ViewBuilder
  private func chip(_ day: PlanningRibbon.Day) -> some View {
    let plans = day.incomes + day.payments
    let isToday = day.day == environment.today
    let face = VStack(spacing: 3) {
      Text(verbatim: "\(day.day.day)")
        .appFont(.caption.monospacedDigit().weight(isToday || !plans.isEmpty ? .bold : .regular))
        .foregroundStyle(isToday || !plans.isEmpty ? .primary : .secondary)
      HStack(spacing: 2) {
        if !day.incomes.isEmpty {
          Circle().fill(.secondary).frame(width: 4, height: 4)
        }
        if !day.payments.isEmpty {
          Rectangle().fill(.secondary).frame(width: 4, height: 4)
        }
        if day.isEmpty {
          Rectangle().fill(.quaternary).frame(width: 4, height: 4)
        }
      }
      .frame(height: 4)
    }
    .lineLimit(1)
    .minimumScaleFactor(0.6)
    .frame(maxWidth: .infinity, minHeight: 36)
    .background(
      plans.isEmpty ? AnyShapeStyle(.quaternary) : AnyShapeStyle(surfaces.accent.opacity(0.18)),
      in: .rect(cornerRadius: 6)
    )
    .overlay {
      if isToday { RoundedRectangle(cornerRadius: 6).strokeBorder(.secondary, lineWidth: 1) }
    }
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

  private func t(_ key: String) -> String { environment.language(key, table: "Planning") }
}
