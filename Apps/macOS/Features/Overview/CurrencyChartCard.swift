import AppCore
import SwiftUI

/// «График валюты»: a pair of currencies — USD/RUB, EUR/RUB or one of the accounts' — over a week,
/// a month or a year, with the rate now and its change. The rates are the bank's daily tables,
/// the ones the app keeps for operations anyway (`RateService`, cached); the choice of pair and
/// period is kept on this Mac (`overview.currencyChart`).
struct CurrencyChartCard: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute

  static let storageKey = "overview.currencyChart"

  @State private var pair = CurrencyChart.decode(nil).0
  @State private var period = CurrencyChart.decode(nil).1
  @State private var points: [CurrencyChartPoint] = []
  @State private var loading = true
  @State private var restored = false

  private func t(_ key: String) -> String { environment.language(key, table: "Overview") }

  private var pairs: [CurrencyPair] {
    let accounts = compute.snapshot?.dataset.paymentMethods.filter { !$0.archived } ?? []
    var list = CurrencyChart.pairs(
      accountCurrencies: accounts.flatMap(\.currencies),
      defaultCurrency: environment.defaultCurrency)
    if !list.contains(pair) { list.append(pair) }
    return list
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(verbatim: OverviewTileText.name(of: .currencyChart, environment))
          .appFont(.headline)
        Spacer(minLength: 8)
        Picker(selection: $pair) {
          ForEach(pairs, id: \.self) { pair in Text(verbatim: pair.description).tag(pair) }
        } label: {
          Text(verbatim: t("currencyChart.pair"))
        }
        .labelsHidden()
        .fixedSize()
        .accessibilityIdentifier("overview.currencyChart.pair")
      }
      Picker(selection: $period) {
        ForEach(CurrencyChartPeriod.allCases, id: \.self) { period in
          Text(verbatim: t("currencyChart.\(period.rawValue)")).tag(period)
        }
      } label: {
        Text(verbatim: t("currencyChart.period"))
      }
      .labelsHidden()
      .pickerStyle(.segmented)
      .controlSize(.small)
      if let summary = CurrencyChart.summary(points) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text(verbatim: rate(summary.current))
            .appFont(.title2.monospacedDigit())
          let arrow =
            summary.change > 0
            ? "arrow.up.right" : summary.change < 0 ? "arrow.down.right" : "arrow.right"
          Label {
            Text(
              verbatim: signed(summary.change) + " ("
                + environment.money.signedPercent(basisPoints: summary.changeBp) + ")")
          } icon: {
            Image(systemName: arrow)
          }
          .appFont(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
        }
        RateLineChart(points: points, calendar: environment.calendar) { point in
          environment.dates.dayAndMonth(point.day) + ": " + rate(point.rateE4)
        }
        .frame(height: 70)
      } else {
        Text(verbatim: loading ? t("currencyChart.loading") : t("currencyChart.noRates"))
          .appFont(.caption)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, minHeight: 70, alignment: .leading)
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    .onAppear {
      GuideStore.shared.report(GuideEvent.currencyChartSeen)
      guard !restored else { return }
      restored = true
      (pair, period) = CurrencyChart.decode(UserDefaults.standard.string(forKey: Self.storageKey))
    }
    .task(id: CurrencyChart.encode(pair, period)) {
      UserDefaults.standard.set(CurrencyChart.encode(pair, period), forKey: Self.storageKey)
      await load()
    }
  }

  /// The rates of the days of the period, one day after another; a day the bank has no table of
  /// gives the rate it says stands that day.
  private func load() async {
    loading = true
    defer { loading = false }
    guard let rates = environment.rateService else {
      points = []
      return
    }
    let days = CurrencyChart.days(period, today: environment.today, calendar: environment.calendar)
    let found = await CurrencyChart.points(of: pair, on: days) { currency, day in
      await rates.rate(for: currency, on: day)?.perUnit
    }
    guard let found else { return }
    points = found
  }

  private func rate(_ e4: Int64) -> String {
    environment.money.rate(Decimal(e4) / 10_000) + " " + environment.money.symbol(for: pair.quote)
  }

  private func signed(_ e4: Int64) -> String {
    (e4 > 0 ? "+" : e4 < 0 ? "−" : "") + environment.money.rate(Decimal(abs(e4)) / 10_000)
  }
}
