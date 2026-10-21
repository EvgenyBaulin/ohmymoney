import AppCore
import SwiftUI

/// The interest of deposits and savings accounts among «Поступления»: one grey row per payout
/// of this month not received yet — and per payout that did not come —, «Проценты · Вклад
/// ≈ 2,345.67 ₽ · 31 октября». They are read only and never part of the income expected: the
/// interest is income only once recorded, which «Записать…» does — the ordinary income,
/// prefilled — from three days before the pay date on.
struct DepositPayoutRows: View {
  @Dependency(\.environment) private var environment
  @Environment(\.dependencies) private var dependencies

  let payouts: [DepositPayout]
  /// Every account, to name the one that earns.
  let accounts: [PaymentMethod]

  @State private var recording: DepositIncomePrefill?

  var body: some View {
    let today = environment.today
    ForEach(Self.shown(payouts, today: today)) { payout in
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Image(systemName: payout.state == .missing ? "questionmark.circle" : "percent")
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
        Text(
          verbatim: Self.text(payout, names: InterestText.names(accounts), environment)
        )
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .lineLimit(2)
        Spacer(minLength: 6)
        if Self.offersRecording(payout, today: today) {
          Button(t("deposits.record")) { recording = DepositIncomePrefill(payout) }
            .buttonStyle(.link)
            .appFont(.caption)
            .accessibilityIdentifier("deposits.record")
        }
      }
      .accessibilityElement(children: .combine)
    }
    .sheet(item: $recording) { prefill in
      DepositIncomeSheet(prefill: prefill) { recording = nil }
        .handingOver(dependencies)
    }
  }

  /// The payouts listed: those that did not come, and those of this month not received yet, by
  /// pay date.
  static func shown(_ payouts: [DepositPayout], today: DateOnly) -> [DepositPayout] {
    payouts.filter { payout in
      switch payout.state {
      case .received: return false
      case .missing: return true
      case .accruing, .due: return payout.payDate.monthKey == today.monthKey
      }
    }
    .sorted { ($0.payDate, $0.accountId.uuidString) < ($1.payDate, $1.accountId.uuidString) }
  }

  /// «Записать…» from a few days before the pay date: a payout recorded earlier would not be
  /// taken for it.
  static func offersRecording(_ payout: DepositPayout, today: DateOnly) -> Bool {
    payout.payDate <= today.adding(days: DepositPayouts.earlyDays)
  }

  /// «Проценты · Вклад ≈ 2,345.67 ₽ · 31 октября», and «· не пришли?» for one that did not come.
  @MainActor
  static func text(
    _ payout: DepositPayout, names: [UUID: String], _ environment: AppEnvironment
  ) -> String {
    let row = environment.format(
      "deposits.row", table: "Planning", names[payout.accountId] ?? "—",
      InterestText.approximately(payout.expectedE4, payout.target.currency, environment),
      environment.dates.dayAndMonth(payout.payDate))
    guard payout.state == .missing else { return row }
    return row + " · " + environment.language("deposits.missing", table: "Planning")
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Planning") }
}
