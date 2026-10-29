import AppCore
import SwiftUI

/// The nearest birthdays at the top of Planning: «Ближайшие дни рождения» with a line for each —
/// the name, the day and the gift budget. Hidden while nobody has one in the next month.
enum PlanningBirthdays {
  /// How many days ahead the strip looks and how many lines it keeps.
  static let withinDays = 30
  static let limit = 3

  static func upcoming(people: [Person], today: DateOnly) -> [GiftDay] {
    Array(GiftCalendar.upcoming(people: people, today: today, withinDays: withinDays).prefix(limit))
  }
}

struct PlanningBirthdaysStrip: View {
  @Dependency(\.environment) private var environment
  let snapshot: DataSnapshot

  var body: some View {
    let days = PlanningBirthdays.upcoming(people: snapshot.dataset.people, today: snapshot.today)
    if !days.isEmpty {
      VStack(alignment: .leading, spacing: 4) {
        Text(verbatim: PurchaseHookText.t("planning.birthdays.title", environment))
          .appFont(.subheadline)
          .foregroundStyle(.secondary)
        ForEach(days) { day in
          Label {
            Text(verbatim: PurchaseHookText.planningLine(day, environment))
              .monospacedDigit()
          } icon: {
            Image(systemName: "gift")
          }
          .appFont(.callout)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("planning.birthdays")
    }
  }
}
