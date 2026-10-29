import AppCore
import SwiftUI

/// «Ждут зачисления»: the refunds of purchases that the owner is waiting for. They stay out of the
/// spending and out of the balances until the money comes; «Зачислено» ends the wait and the
/// operation counts as an ordinary refund from then on.
struct WaitingPage: View {
  @Dependency(\.environment) private var environment
  @Environment(\.dependencies) private var dependencies
  let page: PurchasesPage
  let today: DateOnly
  let open: (PurchasesSheet) -> Void
  let report: (PurchaseOutcome) -> Void

  private func t(_ key: String) -> String { PurchasesText.t(key, environment) }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if page.waiting.items.isEmpty {
        Text(verbatim: t("purchases.waiting.empty"))
          .appFont(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .contentCard()
          .accessibilityIdentifier("purchases.waiting.empty")
      } else {
        VStack(alignment: .leading, spacing: 4) {
          Text(verbatim: environment.money.rounded(page.waiting.totalRubE4))
            .appFont(.title2.monospacedDigit())
          Text(
            verbatim: PurchasesText.count(
              "purchases.waiting.total", environment, page.waiting.items.count)
          )
          .appFont(.caption)
          .foregroundStyle(.secondary)
          Text(verbatim: t("purchases.waiting.hint"))
            .appFont(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .contentCard()
        .accessibilityIdentifier("purchases.waiting.total")
        ForEach(page.waiting.items) { refund in card(refund) }
      }
    }
  }

  private func card(_ refund: WaitingRefund) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .firstTextBaseline) {
        Text(verbatim: refund.note ?? t("purchases.waiting.noNote")).appFont(.headline)
        Spacer(minLength: 8)
        Text(verbatim: environment.money.exact(refund.amountE4, currency: refund.currency))
          .appFont(.title3.monospacedDigit())
      }
      Label {
        Text(verbatim: PurchasesText.expected(refund, today: today, environment))
      } icon: {
        Image(systemName: refund.isLate(today: today) ? "exclamationmark.triangle" : "hourglass")
      }
      .appFont(.callout)
      .accessibilityIdentifier("purchases.waiting.expected")
      HStack {
        Button(t("purchases.waiting.credited")) {
          if let dependencies { report(PurchaseActions(dependencies).credit(refund.transactionId)) }
        }
        .accessibilityIdentifier("purchases.waiting.credited")
        Button(t("purchases.waiting.postpone")) { open(.postpone(refund)) }
          .accessibilityIdentifier("purchases.waiting.postpone")
      }
      .buttonStyle(.bordered)
    }
    .contentCard()
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
