import AppCore
import SwiftUI

/// «Последняя запись: сегодня, 14:35» — the first line of Overview, above the cards: when the
/// owner last wrote an operation or a transfer, so it is plain at a glance whether the figures
/// below are up to date. Nothing is shown before the first record, nor before the data comes.
///
/// It reads the snapshot on its own, so resizing the grid under it never walks the book again:
/// the moment is found once per change of the data.
struct LastRecordLine: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute

  var body: some View {
    if let snapshot = compute.snapshot,
      let moment = OverviewSummary.lastRecordedAt(snapshot.dataset)
    {
      Label {
        Text(verbatim: OverviewText.lastRecord(moment, environment))
      } icon: {
        Image(systemName: "square.and.pencil")
      }
      .appFont(.callout)
      .foregroundStyle(.secondary)
      .accessibilityElement(children: .combine)
      .accessibilityIdentifier("overview.lastRecord")
    }
  }
}

extension OverviewText {
  /// The words of the line: today and yesterday by name with the time; a day of this year with
  /// its short month; a day of another year in full, with its year.
  static func lastRecord(_ moment: Date, _ environment: AppEnvironment) -> String {
    let dates = environment.dates
    let calendar = environment.calendar
    let day = calendar.day(of: moment)
    let today = environment.today
    if day == today {
      return environment.format("overview.lastRecord.today", table: "Overview", dates.time(moment))
    }
    if day == calendar.adding(days: -1, to: today) {
      return environment.format(
        "overview.lastRecord.yesterday", table: "Overview", dates.time(moment))
    }
    let when =
      day.year == today.year
      ? dates.moment(moment) : "\(dates.longDay(day)), \(dates.time(moment))"
    return environment.format("overview.lastRecord.on", table: "Overview", when)
  }
}
