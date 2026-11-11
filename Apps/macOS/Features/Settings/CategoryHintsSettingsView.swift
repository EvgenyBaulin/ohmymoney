import AppCore
import SwiftUI

/// Measured quality of category suggestions and forecast backtesting.
struct CategoryHintsSettingsView: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @State private var state: BlockState<ModelQuality> = .calculating
  @State private var attempt = 0
  @State private var measuredGeneration: Int?

  private struct LoadKey: Hashable {
    var generation: Int
    var ready: Bool
    var attempt: Int
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        caption("settings.categoryHints.explanation")
        ComputedBlock(
          title: nil, state: state, style: .plain,
          asOf: measuredGeneration == compute.generation ? nil : state.readyAt,
          retry: { attempt += 1 }
        ) { quality in
          VStack(alignment: .leading, spacing: 18) {
            CategoryHintsSummary(categories: quality.categories)
            accuracyCard(quality.categories)
            caption("settings.categoryHints.metricsHint")
            details(quality)
          }
        }
      }
      .padding(.horizontal, SettingsChromeMetrics.contentInset)
      .padding(.top, 14)
      .padding(.bottom, 24)
      .frame(maxWidth: .infinity, alignment: .topLeading)
    }
    .accessibilityIdentifier("settings.categoryHints")
    .task(
      id: LoadKey(
        generation: compute.generation, ready: compute.states.data.phase == .ready, attempt: attempt
      )
    ) { await load() }
  }

  private func accuracyCard(_ categories: ModelQuality.Categories) -> some View {
    CategoryHintsCard {
      VStack(alignment: .leading, spacing: 8) {
        Text(verbatim: t("settings.categoryHints.chart"))
          .appFont(AppFont.system(size: 11, weight: .semibold))
          .accessibilityAddTraits(.isHeader)
        if categories.months.isEmpty {
          Text(verbatim: t("settings.categoryHints.noMonths"))
            .appFont(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 122, alignment: .center)
        } else {
          ModelAccuracyChart(months: categories.months)
        }
      }
      .padding(10)
    }
    .accessibilityIdentifier("settings.categoryHints.chart")
  }

  /// Keep the existing detailed measurements, including forecast backtesting, available here.
  private func details(_ quality: ModelQuality) -> some View {
    DisclosureGroup(t("settings.categoryHints.details")) {
      VStack(alignment: .leading, spacing: 16) {
        if quality.categories.metrics != nil {
          MeasuredTable(rows: MeasuredTable.rows(of: quality.categories, environment))
        }
        Text(verbatim: AnalyticsText.t("analytics.block.modelForecast", environment))
          .appFont(.headline)
        if quality.forecast.isEmpty {
          Text(verbatim: AnalyticsText.t("analytics.reason.noBacktest", environment))
            .appFont(.callout)
            .foregroundStyle(.secondary)
        } else {
          ForecastQualityTable(backtest: quality.forecast)
        }
      }
      .padding(.top, 12)
    }
    .appFont(.callout)
  }

  private func load() async {
    guard compute.states.data.phase == .ready, let snapshot = compute.snapshot else {
      return
    }
    let generation = compute.generation
    let ledger = snapshot.ledger
    let today = snapshot.today
    do {
      let quality = try await compute.compute { ModelQuality.build(ledger: ledger, today: today) }
      try Task.checkCancellation()
      state = .ready(quality, at: Date())
      measuredGeneration = generation
    } catch is CancellationError {
      return
    } catch {
      state = .failed(messageKey: "compute.failed.data")
    }
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Settings") }

  private func caption(_ key: String) -> some View {
    Text(verbatim: t(key))
      .appFont(.callout)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
  }
}

/// The four headline measurements; unknown accuracy is a dash rather than an invented zero.
struct CategoryHintsSummary: View {
  @Dependency(\.environment) private var environment
  let categories: ModelQuality.Categories

  struct Card: Identifiable {
    var key: String
    var value: String
    var id: String { key }
  }

  static let keys = [
    "settings.categoryHints.accuracy", "settings.categoryHints.macroF1",
    "settings.categoryHints.coverage", "settings.categoryHints.examples",
  ]

  static func cards(_ categories: ModelQuality.Categories, _ environment: AppEnvironment) -> [Card]
  {
    let money = environment.money
    let metrics = categories.metrics.flatMap { $0.asked > 0 ? $0 : nil }
    return [
      Card(
        key: keys[0],
        value: metrics.map {
          money.percent(basisPoints: $0.top1Bp)
        } ?? "—"),
      Card(
        key: keys[1],
        value: metrics.map {
          money.number(Decimal($0.macroF1Bp) / 10_000, fractionDigits: 2...2)
        } ?? "—"),
      Card(
        key: keys[2],
        value: metrics.map {
          money.percent(basisPoints: $0.coverageBp)
        } ?? "—"),
      Card(key: keys[3], value: money.count(Int64(categories.examples))),
    ]
  }

  var body: some View {
    LazyVGrid(columns: columns, spacing: 14) {
      ForEach(Self.cards(categories, environment)) { card in
        CategoryHintsCard {
          VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: environment.language(card.key, table: "Settings"))
              .appFont(.callout)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: card.value)
              .appFont(AppFont.system(size: 24, weight: .bold).monospacedDigit())
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(16)
          .accessibilityElement(children: .combine)
        }
        .accessibilityIdentifier(card.key)
      }
    }
  }

  private var columns: [GridItem] {
    #if os(macOS)
      Array(repeating: GridItem(.flexible(), spacing: 14, alignment: .topLeading), count: 4)
    #else
      [GridItem(.adaptive(minimum: 140), spacing: 14, alignment: .topLeading)]
    #endif
  }
}

/// Settings cards on Mac, the platform's ordinary content card on phone and tablet.
private struct CategoryHintsCard<Content: View>: View {
  @ViewBuilder let content: Content

  var body: some View {
    #if os(macOS)
      SettingsCard { content }
    #else
      content.contentCard()
    #endif
  }
}
