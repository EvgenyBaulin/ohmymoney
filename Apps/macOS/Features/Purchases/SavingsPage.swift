import AppCore
import SwiftUI

/// «Сэкономлено на скидках»: what the discounts noted on operations took off the price — this
/// month, this year and month by month — and how big that is against the price without them.
struct SavingsPage: View {
  @Dependency(\.environment) private var environment
  let page: PurchasesPage

  private func t(_ key: String) -> String { PurchasesText.t(key, environment) }

  var body: some View {
    VStack(alignment: .leading, spacing: SectionMetrics.stackGap) {
      if page.savingsYear.count == 0 {
        Text(verbatim: t("purchases.savings.empty"))
          .appFont(SectionType.rowDetail)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .sectionCard()
          .accessibilityIdentifier("purchases.savings.empty")
      } else {
        PurchasesTwoColumns {
          figure(t("purchases.savings.month"), page.savingsMonth)
            .accessibilityIdentifier("purchases.savings.month")
          figure(t("purchases.savings.year"), page.savingsYear)
            .accessibilityIdentifier("purchases.savings.year")
        } right: {
          Text(verbatim: t("purchases.savings.byMonth"))
            .appFont(PurchasesType.groupTitle)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
          let months = Array(page.savingsYear.months.reversed())
          PurchasesListCard(count: months.count) { index in
            PurchasesRow(
              symbol: nil, title: environment.dates.monthTitle(months[index]),
              figure: environment.money.rounded(
                page.savingsYear.byMonth[months[index]] ?? .zero))
          }
        }
      }
    }
  }

  private func figure(_ title: String, _ savings: DiscountSavings) -> some View {
    PurchasesFactCard(gap: PurchasesMetrics.totalGap) {
      Text(verbatim: title).appFont(PurchasesType.fieldLabel).foregroundStyle(.secondary)
      Text(verbatim: PurchasesText.savings(savings, environment))
        .appFont(PurchasesType.totalFigure)
      Text(
        verbatim: PurchasesText.count("purchases.savings.count", environment, savings.count)
          + (savings.count > 0
            ? " · "
              + PurchasesText.f(
                "purchases.savings.share", environment,
                PurchasesText.percent(savings.shareBp / 100, environment))
            : "")
      )
      .appFont(PurchasesType.fieldLabel)
      .foregroundStyle(.secondary)
    }
  }
}
