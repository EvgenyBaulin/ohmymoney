import AppCore
import SwiftUI

/// What the period a gain is worked out for starts at.
enum CurrencyGainPeriod: String, CaseIterable, Identifiable {
  case month, year

  var id: String { rawValue }

  /// The first day of the period that ends `today`.
  func start(today: DateOnly) -> DateOnly {
    switch self {
    case .month: today.monthKey.firstDay
    case .year: DateOnly(year: today.year, month: 1, day: 1)
    }
  }
}

/// «Курсовая разница» of «Капитал»: what the money held in foreign currencies gained or lost in
/// rubles only because the rate moved, over the month or the year, with every pair of an account
/// and a currency counted. A row, never an income or an expense. A pair not counted yet or
/// without a rate is named, not guessed. Shown only where there is a foreign balance at all.
struct CurrencyGainSection: View {
  @Dependency(\.environment) private var environment
  let snapshot: DataSnapshot
  @State private var period: CurrencyGainPeriod = .month

  var body: some View {
    let gain = CurrencyGain(
      balances: snapshot.planning.accounts.balances, calendar: environment.calendar,
      rates: snapshot.planning.dayRates, from: period.start(today: environment.today),
      to: environment.today)
    if !(gain.pairs.isEmpty && gain.uncounted.isEmpty && gain.unpriced.isEmpty) {
      VStack(alignment: .leading, spacing: 6) {
        HStack(alignment: .firstTextBaseline) {
          Text(verbatim: TravelText.t("travel.gain.title", environment))
            .appFont(.headline)
            .accessibilityAddTraits(.isHeader)
          Spacer()
          Picker(TravelText.t("travel.gain.period", environment), selection: $period) {
            Text(verbatim: TravelText.t("travel.gain.month", environment)).tag(
              CurrencyGainPeriod.month)
            Text(verbatim: TravelText.t("travel.gain.year", environment)).tag(
              CurrencyGainPeriod.year)
          }
          .pickerStyle(.segmented)
          .labelsHidden()
          .frame(width: 160)
        }
        Label {
          Text(verbatim: environment.money.signedRounded(gain.total))
            .appFont(.title3.monospacedDigit())
        } icon: {
          Image(systemName: Self.symbol(of: gain.total))
        }
        .accessibilityIdentifier("travel.gain.total")
        Text(verbatim: TravelText.t("travel.gain.note", environment))
          .appFont(.caption)
          .foregroundStyle(.secondary)
        if !gain.uncounted.isEmpty {
          Text(
            verbatim: environment.format(
              "travel.gain.uncounted", table: TravelText.table, counts: gain.uncounted.count)
          )
          .appFont(.caption)
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("travel.gain.uncounted")
        }
        if !gain.unpriced.isEmpty {
          Text(
            verbatim: environment.format(
              "travel.gain.unpriced", table: TravelText.table, counts: gain.unpriced.count)
          )
          .appFont(.caption)
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("travel.gain.unpriced")
        }
      }
      .accessibilityIdentifier("travel.gain")
    }
  }

  /// An arrow by the sign of the whole rubles: up, down or level — never the colour of good or
  /// bad.
  static func symbol(of total: AmountE4) -> String {
    let whole = total.wholeRubles
    return whole > 0 ? "arrow.up.right" : whole < 0 ? "arrow.down.right" : "arrow.right"
  }
}
