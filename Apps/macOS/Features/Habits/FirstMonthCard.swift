import AppCore
import SwiftUI

/// The memory of the first month on this Mac (`FirstMonthProgress`), kept in the settings of this
/// Mac per set of data, like the guide's: never in the database or the archive.
@MainActor
enum FirstMonthStore {
  static let key = "guide.firstMonth"

  static func storageKey(dataSet: String? = AppPaths.dataSet?.rawValue) -> String {
    key + (dataSet.map { ".\($0)" } ?? "")
  }

  static func read(_ defaults: UserDefaults = .standard) -> FirstMonthProgress? {
    guard let data = defaults.data(forKey: storageKey()) else { return nil }
    return try? JSONDecoder().decode(FirstMonthProgress.self, from: data)
  }

  static func write(_ progress: FirstMonthProgress, _ defaults: UserDefaults = .standard) {
    guard let data = try? JSONEncoder().encode(progress) else { return }
    defaults.set(data, forKey: storageKey())
  }

  /// What the first month checks, counted from the data.
  static func facts(_ dataset: Dataset, calendar: CalendarContext) -> FirstMonthFacts {
    let typed = dataset.entries.filter { HabitEntryDays.isTypedByHand($0.transaction) }
    return FirstMonthFacts(
      accountsReady: dataset.accountSettings.setup != nil,
      operations: typed.count,
      entryDays: HabitEntryDays.days(
        dataset.entries, noSpend: dataset.habits.markedDays, calendar: calendar
      ).count,
      scheduledPayments: dataset.planning.scheduled.count,
      limits: dataset.planning.budgets.count,
      goals: dataset.goals.filter { !$0.archived }.count,
      counts: dataset.planning.reconciliations.filter { $0.kind != .opening }.count)
  }

  /// The memory, started the first time it is asked for on a book that is new — nothing typed
  /// yet, or the first operation typed within the month. A book in use for longer never gets the
  /// first month. The tasks the data shows done are marked, and the memory is written back when
  /// it changed.
  static func current(
    _ dataset: Dataset, calendar: CalendarContext, today: DateOnly,
    defaults: UserDefaults = .standard
  ) -> FirstMonthProgress? {
    let facts = facts(dataset, calendar: calendar)
    var progress: FirstMonthProgress
    if let stored = read(defaults) {
      progress = stored
    } else {
      let first = HabitEntryDays.typedDays(dataset.entries, calendar: calendar).min()
      if let first, first.days(to: today) >= FirstMonth.length { return nil }
      progress = FirstMonthProgress(start: first ?? today)
    }
    let before = progress
    progress.record(facts)
    if progress != before || read(defaults) == nil { write(progress, defaults) }
    return progress
  }
}

/// «Первый месяц»: the tasks of the setup that have come by today and are not done — accounts,
/// subscriptions, a limit, the first count —, each with «Показать, где». Over the tiles of
/// Overview, for the thirty days of the month, until everything is done or the owner hides it.
struct FirstMonthCard: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @State private var hiddenNow = false
  /// The hosts of the tests lay out Overview on fresh books, which are new: the card would stand
  /// in every layout they measure. A test of the card turns it on.
  @MainActor static var showsInTestHost = false

  private var russian: Bool { environment.language.resolvedCode.hasPrefix("ru") }

  var body: some View {
    if !hiddenNow, !AppEnvironment.isTestHost || Self.showsInTestHost,
      let snapshot = compute.snapshot,
      let progress = FirstMonthStore.current(
        snapshot.ledger.dataset, calendar: snapshot.ledger.calendar, today: snapshot.today),
      let day = FirstMonth.dayIndex(start: progress.start, today: snapshot.today)
    {
      let facts = FirstMonthStore.facts(snapshot.ledger.dataset, calendar: snapshot.ledger.calendar)
      let open = FirstMonth.open(
        start: progress.start, today: snapshot.today, facts: facts, done: progress.done)
      if !progress.hidden, !open.isEmpty {
        card(day: day, progress: progress, facts: facts, open: open)
      }
    }
  }

  private func card(
    day: Int, progress: FirstMonthProgress, facts: FirstMonthFacts, open: [FirstMonthTask]
  ) -> some View {
    let counted = FirstMonth.progress(facts: facts, done: progress.done)
    return VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline) {
        Label {
          Text(verbatim: HabitText.t("month.title", environment)).appFont(.headline)
        } icon: {
          Image(systemName: "checklist")
        }
        Spacer()
        Text(
          verbatim: HabitText.f("month.dayOf", environment, day, FirstMonth.length) + " · "
            + HabitText.f("month.progress", environment, counted.done, counted.total)
        )
        .appFont(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
      }
      ForEach(open.prefix(3)) { task in
        VStack(alignment: .leading, spacing: 2) {
          Label {
            Text(verbatim: task.title.text(russian: russian))
          } icon: {
            Image(systemName: "circle")
          }
          .appFont(.callout)
          Text(verbatim: task.why.text(russian: russian))
            .appFont(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          if !task.hints.isEmpty {
            Button(HabitText.t("month.show", environment)) {
              GuideStore.shared.start(GuideWalkthrough(.task(task.id), steps: task.hints))
            }
            .buttonStyle(.link)
            .appFont(.caption)
          }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("month.task.\(task.id)")
      }
      Button(HabitText.t("month.hide", environment)) {
        var hidden = progress
        hidden.hidden = true
        FirstMonthStore.write(hidden)
        hiddenNow = true
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    .accessibilityIdentifier("month.card")
  }
}
