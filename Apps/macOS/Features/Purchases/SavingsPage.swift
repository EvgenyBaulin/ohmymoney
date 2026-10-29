import AppCore
import SwiftUI

/// «Сэкономлено на скидках»: what the discounts noted on operations took off the price — this
/// month, this year and month by month — and how big that is against the price without them.
struct SavingsPage: View {
  @Dependency(\.environment) private var environment
  let page: PurchasesPage

  private func t(_ key: String) -> String { PurchasesText.t(key, environment) }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if page.savingsYear.count == 0 {
        Text(verbatim: t("purchases.savings.empty"))
          .appFont(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .contentCard()
          .accessibilityIdentifier("purchases.savings.empty")
      } else {
        figure(t("purchases.savings.month"), page.savingsMonth)
          .accessibilityIdentifier("purchases.savings.month")
        figure(t("purchases.savings.year"), page.savingsYear)
          .accessibilityIdentifier("purchases.savings.year")
        VStack(alignment: .leading, spacing: 6) {
          Text(verbatim: t("purchases.savings.byMonth")).appFont(.headline)
          ForEach(page.savingsYear.months.reversed(), id: \.self) { month in
            HStack {
              Text(verbatim: environment.dates.monthTitle(month))
              Spacer()
              Text(
                verbatim: environment.money.rounded(page.savingsYear.byMonth[month] ?? .zero)
              )
              .monospacedDigit()
            }
            .appFont(.callout)
          }
        }
        .contentCard()
      }
    }
  }

  private func figure(_ title: String, _ savings: DiscountSavings) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(verbatim: title).appFont(.caption).foregroundStyle(.secondary)
      Text(verbatim: PurchasesText.savings(savings, environment))
        .appFont(.title2.monospacedDigit())
      Text(
        verbatim: PurchasesText.count("purchases.savings.count", environment, savings.count)
          + (savings.count > 0
            ? " · "
              + PurchasesText.f(
                "purchases.savings.share", environment,
                PurchasesText.percent(savings.shareBp / 100, environment))
            : "")
      )
      .appFont(.caption.monospacedDigit())
      .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentCard()
  }
}
