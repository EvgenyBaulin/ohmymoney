import AppCore
import SwiftUI

/// A tax to pay: the tax on professional income of a month, or the tax at another rate of a
/// quarter.
enum TaxToPay: Hashable {
  case month(NPDMonth)
  case quarter(TaxQuarter)

  var toPayE4: AmountE4 {
    switch self {
    case .month(let month): month.toPayE4
    case .quarter(let quarter): quarter.toPayE4
    }
  }
}

/// «Заплатить…» of a quarter of a tax at another rate.
struct PayingQuarter: Identifiable {
  var quarter: TaxQuarter
  var id: String { quarter.paymentKey }
}

/// «Заплатить налог…»: the tax of a month — or of a quarter at another rate — as the app worked it
/// out, to be checked against «Мой налог» or the tax office — it has the last word, and what it
/// charged differently is shown later as «ФНС насчитала на X меньше». Written as an expense in
/// «Налоги и сборы → Налог самозанятого» with the key of the month (`npd:<YYYY-MM>`) or of the
/// quarter (`tax:<YYYY>-Q<n>`), one step of ⌘Z.
struct NPDPaymentSheet: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies
  let tax: TaxToPay

  init(month: NPDMonth) { tax = .month(month) }
  init(quarter: TaxQuarter) { tax = .quarter(quarter) }

  @State private var amount: AmountE4 = .zero
  @State private var accountId: UUID?
  @State private var day: DateOnly?
  @State private var started = false

  var body: some View {
    let snapshot = compute.snapshot
    let accounts = (snapshot?.dataset.paymentMethods ?? []).filter { !$0.archived }
    let chosen = day ?? environment.today
    VStack(alignment: .leading) {
      Text(verbatim: title)
        .appFont(.headline)
      Form {
        LabeledContent(AllocationText.t("npd.pay.amount", environment)) {
          HStack {
            AmountField(amount: $amount).frame(width: 120)
            Text(verbatim: environment.money.symbol(for: .rub)).foregroundStyle(.secondary)
          }
        }
        Text(verbatim: check)
          .appFont(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        Picker(AllocationText.t("npd.pay.account", environment), selection: $accountId) {
          ForEach(accounts) { account in
            Text(verbatim: account.name).tag(UUID?.some(account.id))
          }
        }
        DatePicker(
          AllocationText.t("npd.pay.day", environment),
          selection: Binding(
            get: { environment.calendar.startOfDay(chosen) },
            set: { day = environment.calendar.day(of: $0) }),
          displayedComponents: .date)
      }
      .formStyle(.grouped)
      FormButtons(title: AllocationText.t("npd.pay.save", environment), enabled: amount.raw > 0) {
        guard let dependencies else { return false }
        switch tax {
        case .month(let month):
          return SelfEmploymentActions(dependencies).pay(
            month: month.month, amount: amount, from: accountId, on: chosen)
        case .quarter(let quarter):
          return SelfEmploymentActions(dependencies).pay(
            quarter: quarter, amount: amount, from: accountId, on: chosen)
        }
      }
    }
    .padding(20)
    .sheetFrame(width: 440, height: 340)
    .onAppear {
      guard !started else { return }
      started = true
      amount = tax.toPayE4
      let settings = snapshot?.dataset.selfEmployment
      accountId =
        settings?.taxAccountId.flatMap { id in accounts.contains { $0.id == id } ? id : nil }
        ?? accounts.first { $0.isDefault }?.id
    }
  }

  /// «Налог самозанятого за октябрь 2026», «Налог УСН за III квартал 2026».
  private var title: String {
    switch tax {
    case .month(let month):
      AllocationText.format("npd.pay.title", environment, environment.dates.monthTitle(month.month))
    case .quarter(let quarter):
      AllocationText.format(
        "tax.pay.title", environment, NPDPaymentRows.quarterName(quarter, environment))
    }
  }

  private var check: String {
    let sum = environment.money.exact(tax.toPayE4)
    switch tax {
    case .month: return AllocationText.format("npd.pay.check", environment, sum)
    case .quarter: return AllocationText.format("tax.pay.check", environment, sum)
    }
  }
}
