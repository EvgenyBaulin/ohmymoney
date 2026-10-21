import AppCore
import SwiftUI

/// «Календарь» on Overview: the days of this week in one strip — what each cost, the days that
/// cost more than usual marked, what is planned for the days ahead — and the way into the
/// calendar of the sidebar. The same model as the screen (`CalendarScreen`), counted nowhere
/// else.
struct CalendarTileCard: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute

  var body: some View {
    ComputedBlock(
      title: OverviewTileText.name(of: .spendingCalendar, environment),
      state: compute.states.data, fillsHeight: true,
      retry: { compute.retry(ComputeStep.data) }
    ) { snapshot in
      let calendar = CalendarScreen.calendar(
        of: snapshot, scope: .week, anchor: snapshot.today,
        firstWeekday: CalendarScreen.firstWeekday(locale: environment.language.locale))
      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 4) {
          ForEach(calendar.weeks.first ?? []) { day in
            VStack(spacing: 2) {
              Text(verbatim: environment.dates.shortWeekday(day.day.weekday))
                .appFont(.caption2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
              CalendarDayCell(day: day, calendar: calendar, compact: true)
            }
          }
        }
        HStack(alignment: .firstTextBaseline) {
          Text(
            verbatim: environment.format(
              "calendar.total", table: CalendarText.table,
              CalendarText.money(calendar.spent, of: calendar, environment))
          )
          .appFont(.callout.monospacedDigit())
          Spacer(minLength: 6)
          Button(CalendarText.t("calendar.open", environment)) {
            NotificationCenter.default.post(
              name: .selectSection, object: MainWindow.Section.calendar.shortcutIndex)
          }
          .buttonStyle(.link)
          .accessibilityIdentifier("overview.calendar.open")
        }
      }
    }
  }
}
