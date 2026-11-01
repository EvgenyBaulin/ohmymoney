import AppCore
import SwiftUI

/// The badges of a period in «Итоги»: what was earned within its days, and the streak alive now.
/// Shown quietly with the cards — no pop-up announces a badge, and nothing is compared with
/// anybody. A badge stays once earned (`HabitAwards`).
struct HabitBadgesSection: View {
  @Dependency(\.environment) private var environment
  let range: DayRange
  let snapshot: DataSnapshot

  private var badges: [HabitBadge] {
    HabitBadges.earned(in: range, of: snapshot.ledger.dataset.habits.badges)
      .filter { $0.kind != nil }
  }

  /// The streak alive today, told only in the period that holds today.
  private var streak: Int? {
    guard range.contains(snapshot.today) else { return nil }
    let days = HabitNotesOnMac.entryDays(snapshot)
    return EntryStreaks.current(days: days, today: snapshot.today).map(\.length)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(verbatim: HabitText.t("badges.title", environment))
        .appFont(.headline)
        .accessibilityAddTraits(.isHeader)
      if let streak, streak > 1 {
        Label {
          Text(
            verbatim: environment.format("badges.streakNow", table: HabitText.table, counts: streak)
          )
        } icon: {
          Image(systemName: "flame")
        }
        .appFont(.callout)
      }
      if badges.isEmpty {
        Text(verbatim: HabitText.t("badges.none", environment))
          .appFont(.callout)
          .foregroundStyle(.secondary)
      } else {
        ForEach(badges) { badge in
          Label {
            VStack(alignment: .leading, spacing: 2) {
              Text(verbatim: HabitText.name(badge, environment) ?? "")
              Text(
                verbatim: HabitText.f(
                  "badges.earnedOn", environment, environment.dates.dayAndMonth(badge.earnedOn))
              )
              .appFont(.caption)
              .foregroundStyle(.secondary)
            }
          } icon: {
            Image(systemName: HabitText.symbol(badge.kind))
          }
          .appFont(.callout)
          .accessibilityElement(children: .combine)
          .accessibilityIdentifier("badge.\(badge.kindText)")
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(12)
    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    .accessibilityIdentifier("summaries.badges")
  }
}
