import AppCore
import SwiftUI

/// «Ждут зачисления»: the refunds of purchases that the owner is waiting for. They stay out of the
/// spending and out of the balances until the money comes; «Зачислено» ends the wait and the
/// operation counts as an ordinary refund from then on.
struct WaitingPage: View {
  @Dependency(\.environment) private var environment
  @Environment(\.dependencies) private var dependencies
  @Environment(\.appTheme) private var theme
  let page: PurchasesPage
  let today: DateOnly
  let open: (PurchasesSheet) -> Void
  let report: (PurchaseOutcome) -> Void

  private func t(_ key: String) -> String { PurchasesText.t(key, environment) }

  var body: some View {
    VStack(alignment: .leading, spacing: SectionMetrics.stackGap) {
      if page.waiting.items.isEmpty {
        Text(verbatim: t("purchases.waiting.empty"))
          .appFont(SectionType.rowDetail)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .sectionCard()
          .accessibilityIdentifier("purchases.waiting.empty")
      } else {
        PurchasesColumns(
          items: page.waiting.items,
          head: { total },
          tail: { EmptyView() },
          card: { card($0) })
      }
    }
  }

  /// The sum waited for, the number of refunds and why they change nothing yet.
  private var total: some View {
    PurchasesFactCard(gap: PurchasesMetrics.totalGap) {
      Text(verbatim: t(PurchasesText.Page.waiting.titleKey))
        .appFont(PurchasesType.fieldLabel)
        .foregroundStyle(.secondary)
      Text(verbatim: environment.money.rounded(page.waiting.totalRubE4))
        .appFont(PurchasesType.totalFigure)
      Text(
        verbatim: PurchasesText.count(
          "purchases.waiting.total", environment, page.waiting.items.count) + " · "
          + t("purchases.waiting.hint")
      )
      .appFont(PurchasesType.fieldLabel)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
    }
    .accessibilityIdentifier("purchases.waiting.total")
  }

  private func card(_ refund: WaitingRefund) -> some View {
    let late = refund.isLate(today: today)
    return PurchasesFactCard {
      PurchasesCardTitle(
        title: refund.note ?? t("purchases.waiting.noNote"),
        figure: environment.money.exact(refund.amountE4, currency: refund.currency))
      PurchasesDetailLine(
        symbol: late ? "exclamationmark.triangle" : "hourglass",
        text: PurchasesText.expected(refund, today: today, environment),
        ink: late ? theme.contentWarning : nil
      )
      .accessibilityIdentifier("purchases.waiting.expected")
      PurchasesActionRow {
        Button(t("purchases.waiting.credited")) {
          if let dependencies { report(PurchaseActions(dependencies).credit(refund.transactionId)) }
        }
        .accessibilityIdentifier("purchases.waiting.credited")
        Button(t("purchases.waiting.postpone")) { open(.postpone(refund)) }
          .accessibilityIdentifier("purchases.waiting.postpone")
      }
    }
    .accessibilityElement(children: .contain)
  }
}

/// «Перенести срок…»: the day the money is expected moves.
struct WaitingPostponeSheet: View {
  @Dependency(\.environment) private var environment
  @Environment(\.dependencies) private var dependencies
  let refund: WaitingRefund
  @State private var day: DateOnly?

  private func t(_ key: String) -> String { PurchasesText.t(key, environment) }

  var body: some View {
    VStack(alignment: .leading) {
      Text(verbatim: t("purchases.postpone.title")).appFont(.headline)
      Form {
        DatePicker(
          t("purchases.postpone.day"),
          selection: Binding(
            get: { environment.calendar.startOfDay(day ?? refund.expectedBy) },
            set: { day = environment.calendar.day(of: $0) }),
          displayedComponents: .date)
      }
      .formStyle(.grouped)
      FormButtons(title: environment.language("action.save"), enabled: true) {
        guard let dependencies else { return false }
        return PurchaseActions(dependencies).expect(
          refund.transactionId, by: day ?? refund.expectedBy) == .done
      }
    }
    .padding(20)
    .sheetFrame(width: 420, height: 240)
  }
}
