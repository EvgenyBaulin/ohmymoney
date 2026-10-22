import AppCore
import SwiftUI

/// The words and sums of the subscription calendar, apart from the view so a test reads them.
enum SubscriptionCalendarDay {
  struct Group: Identifiable, Hashable {
    var day: DateOnly
    var items: [SubscriptionCalendarItem]
    /// What the day comes to in rubles; the charges in a currency without a rate are left out.
    var totalRub: AmountE4
    var id: DateOnly { day }
    /// Two or more charges on one day: where the charges bunch up.
    var isBunched: Bool { items.count >= 2 }
  }

  /// The charges of a month grouped by day, in the order of the days.
  static func groups(
    _ items: [SubscriptionCalendarItem], rubPerUnit: [CurrencyCode: Decimal]
  ) -> [Group] {
    SubscriptionCalendar.byDay(items).map { day, items in
      let sorted = items.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
      let rub = sorted.compactMap {
        SubscriptionMath.rubles($0.amount, in: $0.currency, rubPerUnit: rubPerUnit)
      }
      return Group(day: day, items: sorted, totalRub: AmountE4.sum(rub))
    }.sorted { $0.day < $1.day }
  }
}

/// «Только подписки» of the calendar: the days of the month on which something is charged, each
/// with the subscriptions and what they come to, the coming ones told from the paid ones by the
/// word and a symbol, and the days where charges bunch up marked. The calendar of the spending
/// stays the screen; this replaces its grid while the filter is on.
struct SubscriptionCalendarCard: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  let month: MonthKey
  @State private var items: [SubscriptionCalendarItem]?

  private func t(_ key: String) -> String { SubscriptionsText.t(key, environment) }

  var body: some View {
    let rates = compute.snapshot?.context.rubPerUnit ?? [:]
    VStack(alignment: .leading, spacing: 10) {
      ScreenCardHeader(title: t("subs.calendar.only"), caption: caption(items, rates: rates))
      if let items {
        if items.isEmpty {
          Text(verbatim: t("subs.calendar.none")).foregroundStyle(.secondary)
        }
        ForEach(SubscriptionCalendarDay.groups(items, rubPerUnit: rates)) { group in
          dayRow(group)
        }
      } else {
        ProgressView().frame(maxWidth: .infinity)
      }
    }
    .contentCard()
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("subs.calendar")
    .task(id: "\(compute.generation)|\(month.iso)") { await load() }
  }

  private func caption(
    _ items: [SubscriptionCalendarItem]?, rates: [CurrencyCode: Decimal]
  )
    -> String?
  {
    guard let items, !items.isEmpty else { return nil }
    let total = AmountE4.sum(
      SubscriptionCalendarDay.groups(items, rubPerUnit: rates).map(\.totalRub))
    return SubscriptionsText.f("subs.calendar.total", environment, environment.money.rounded(total))
  }

  private func dayRow(_ group: SubscriptionCalendarDay.Group) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .firstTextBaseline) {
        Text(verbatim: environment.dates.dayAndMonth(group.day))
          .appFont(.callout.weight(.semibold))
        if group.isBunched {
          Image(systemName: "square.stack.3d.up").accessibilityHidden(true)
          Text(
            verbatim: SubscriptionsText.count(
              "subs.calendar.bunched", environment, group.items.count)
          )
          .appFont(.caption)
        }
        Spacer(minLength: 6)
        if group.totalRub.raw != 0 {
          Text(verbatim: environment.money.rounded(group.totalRub))
            .appFont(.callout.monospacedDigit())
        }
      }
      ForEach(group.items) { item in
        HStack(spacing: 6) {
          Image(systemName: item.paid ? "checkmark.circle" : "clock").accessibilityHidden(true)
          Text(verbatim: item.name).lineLimit(1)
          Text(verbatim: t(item.paid ? "subs.calendar.paid" : "subs.calendar.coming"))
            .foregroundStyle(.secondary)
          Spacer(minLength: 6)
          Text(verbatim: environment.money.rounded(item.amount, currency: item.currency))
            .monospacedDigit()
        }
        .appFont(.caption)
      }
    }
    .accessibilityElement(children: .combine)
  }

  private func load() async {
    guard compute.states.data.phase == .ready, let snapshot = compute.snapshot else { return }
    guard let counted = try? await compute.analysis.subscriptions.calendar(snapshot, month: month),
      !Task.isCancelled
    else { return }
    items = counted
  }
}
