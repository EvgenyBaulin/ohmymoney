import AppCore
import SwiftUI

/// One day of the calendar: its number, what was spent — to the ruble — and, for a day that
/// cost more than usual, a tint with a symbol beside the figure; for today and the days ahead,
/// what is planned, each kind with its own symbol. The level is never told by the tint alone:
/// the symbol and the words VoiceOver reads say it too. Content, not control: no glass.
struct CalendarDayCell: View {
  @Dependency(\.environment) private var environment
  @Environment(\.colorSchemeContrast) private var contrast

  let day: SpendingCalendarDay
  let calendar: SpendingCalendar
  /// The week shows a taller cell that names what is planned.
  var detailed = false
  var isChosen = false
  /// The Overview tile: a narrow strip, the figure only.
  var compact = false

  var body: some View {
    VStack(alignment: .leading, spacing: compact ? 2 : 4) {
      HStack(spacing: 4) {
        number
        Spacer(minLength: 0)
        if let symbol = CalendarText.symbol(of: day.level) {
          Image(systemName: symbol)
            .appFont(.caption2.weight(.semibold))
            .foregroundStyle(.orange)
        }
      }
      if day.inScope || calendar.scope == .week {
        if let spent = day.spent, spent.raw > 0 {
          Text(verbatim: CalendarText.money(spent, of: calendar, environment))
            .appFont((compact ? AppFont.caption : .callout).monospacedDigit())
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
        plans
      }
      if !compact { Spacer(minLength: 0) }
    }
    .padding(compact ? 4 : 6)
    .frame(
      maxWidth: .infinity, minHeight: compact ? 44 : (detailed ? 140 : 64), alignment: .topLeading
    )
    .background(background, in: .rect(cornerRadius: 8))
    .overlay {
      RoundedRectangle(cornerRadius: 8)
        .strokeBorder(borderStyle, lineWidth: isChosen ? 2 : 1)
        .opacity(isChosen || contrast == .increased ? 1 : 0)
    }
    .opacity(day.inScope ? 1 : 0.45)
    .contentShape(.rect)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Text(verbatim: CalendarText.label(of: day, in: calendar, environment)))
    .accessibilityAddTraits(isChosen ? [.isButton, .isSelected] : .isButton)
  }

  private var number: some View {
    Text(verbatim: "\(day.day.day)")
      .appFont(
        (compact ? AppFont.caption : .callout).monospacedDigit().weight(
          day.isToday ? .bold : .regular)
      )
      .foregroundStyle(day.isToday ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
      // A number is one line, however narrow the cell of the strip: «15» was «1» over «5». It
      // gives way a little in size instead of pushing the strip wider than the window.
      .lineLimit(1)
      .minimumScaleFactor(0.6)
      .padding(.horizontal, day.isToday ? (compact ? 3 : 5) : 0)
      .background {
        if day.isToday { Capsule().fill(.tint) }
      }
  }

  @ViewBuilder
  private var plans: some View {
    if !day.plans.isEmpty {
      if detailed {
        ForEach(day.plans.prefix(4)) { plan in
          Label {
            Text(verbatim: "\(plan.name) \(CalendarText.amount(of: plan, environment))")
              .lineLimit(1)
          } icon: {
            Image(systemName: CalendarText.symbol(of: plan.kind))
          }
          .appFont(.caption)
          .foregroundStyle(.secondary)
        }
        if day.plans.count > 4 {
          Text(verbatim: "+\(day.plans.count - 4)")
            .appFont(.caption)
            .foregroundStyle(.secondary)
        }
      } else {
        planLine(.payment, amount: day.plannedOut)
        planLine(.income, amount: day.plannedIn)
      }
    }
  }

  /// A kind of plan in one line: its symbol and the sum, or only the symbol when a rate is
  /// missing for all of it.
  @ViewBuilder
  private func planLine(_ kind: CalendarPlan.Kind, amount: AmountE4?) -> some View {
    if day.plans.contains(where: { $0.kind == kind }) {
      HStack(spacing: 3) {
        Image(systemName: CalendarText.symbol(of: kind))
        if let amount, !compact {
          Text(verbatim: CalendarText.money(amount, of: calendar, environment))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
      }
      .appFont(.caption)
      .foregroundStyle(.secondary)
    }
  }

  /// The tint of the level over the plain cell: a usual day and a day ahead keep the plain one.
  private var background: AnyShapeStyle {
    switch day.level {
    case .higher: AnyShapeStyle(Color.orange.quaternary)
    case .muchHigher: AnyShapeStyle(Color.orange.tertiary)
    case .usual, .none: AnyShapeStyle(.background.secondary)
    }
  }

  private var borderStyle: AnyShapeStyle {
    isChosen ? AnyShapeStyle(.tint) : AnyShapeStyle(.separator)
  }
}
