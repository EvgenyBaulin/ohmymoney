import AppCore
import SwiftUI

/// Settings → «Подсказки категорий» (0577): what the category model and the month forecast
/// scored on this history, on every platform. Moved here from Analytics; the tables are the
/// same ones, counted on demand off the main thread like the spending sections.
struct CategoryHintsSettingsView: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        Text(verbatim: AnalyticsText.t("analytics.section.modelQuality", environment))
          .appFont(.title3.weight(.semibold))
          .accessibilityAddTraits(.isHeader)
        SpendingBlock(
          identifier: AnalyticsBlock.modelCategories.rawValue,
          title: AnalyticsText.t("analytics.block.modelCategories", environment),
          subtitle: AnalyticsText.t("analytics.basis.modelQuality", environment), request: 0,
          fetch: { snapshot, _ -> SpendingOutcome<ModelQuality.Categories> in
            let quality = try await measured(snapshot)
            return quality.categories.metrics == nil
              ? .empty(reason: reason(.modelNotReady)) : .ready(quality.categories)
          }
        ) { categories in
          MeasuredTable(rows: MeasuredTable.rows(of: categories, environment))
        }
        SpendingBlock(
          identifier: AnalyticsBlock.modelForecast.rawValue,
          title: AnalyticsText.t("analytics.block.modelForecast", environment),
          subtitle: AnalyticsText.t("analytics.basis.modelQuality", environment), request: 0,
          fetch: { snapshot, _ -> SpendingOutcome<ForecastBacktest> in
            let quality = try await measured(snapshot)
            return quality.forecast.isEmpty
              ? .empty(reason: reason(.noBacktest)) : .ready(quality.forecast)
          }
        ) { backtest in
          ForecastQualityTable(backtest: backtest)
        }
      }
      .padding(20)
      .frame(maxWidth: .infinity, alignment: .topLeading)
    }
    .accessibilityIdentifier("settings.categoryHints")
  }

  /// Measured off the main thread: this is a page opened now and then, not a number that has
  /// to be fresh after every write.
  private func measured(_ snapshot: DataSnapshot) async throws -> ModelQuality {
    let ledger = snapshot.ledger
    let today = snapshot.today
    return try await compute.compute { ModelQuality.build(ledger: ledger, today: today) }
  }

  private func reason(_ reason: AnalyticsReason) -> String {
    AnalyticsText.t(reason.key, environment)
  }
}
