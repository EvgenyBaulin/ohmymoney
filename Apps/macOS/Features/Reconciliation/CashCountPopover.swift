import AppCore
import SwiftUI

/// «По купюрам»: a cash wallet counted by the bill. One field per denomination of the row's
/// currency, the sum under them as the owner reads it («5000 × 2, 1000 × 3 = 13 700 ₽») before
/// anything is saved. «Подставить» puts the sum into the count of the row — the sheet then
/// compares it with the books like any other typed amount; the number of bills is kept nowhere.
struct CashCountPopover: View {
  @Dependency(\.environment) private var environment
  let currency: CurrencyCode
  let onUse: (AmountE4) -> Void
  @State private var count: CashCount
  @State private var texts: [String: String] = [:]

  init(currency: CurrencyCode, onUse: @escaping (AmountE4) -> Void) {
    self.currency = currency
    self.onUse = onUse
    _count = State(initialValue: CashCount(currency: currency))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(verbatim: t("reconcile.cash.title")).appFont(.headline)
      ForEach(CashCount.denominations(for: currency) ?? [], id: \.id) { denomination in
        HStack {
          Text(verbatim: label(denomination))
            .monospacedDigit()
            .frame(minWidth: 90, alignment: .leading)
          Text(verbatim: "×").foregroundStyle(.secondary)
          TextField(
            "", text: binding(for: denomination), prompt: Text(verbatim: "0")
          )
          .multilineTextAlignment(.trailing)
          .monospacedDigit()
          .frame(width: 80)
          .accessibilityLabel(
            Text(verbatim: "\(label(denomination)) \(currency.code)"))
        }
      }
      Divider()
      Text(verbatim: Self.summary(count, money: environment.money))
        .monospacedDigit()
        .fontWeight(.semibold)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("reconcile.cash.total")
      HStack {
        Spacer()
        Button(t("reconcile.cash.use")) { onUse(count.total) }
          .buttonStyle(.borderedProminent)
          .disabled(count.isEmpty)
      }
    }
    .padding(16)
    .frame(width: 280)
  }

  /// Whether the table has coins next to notes, so that a label has to say which is which.
  private var notesAndCoins: Bool {
    (CashCount.denominations(for: currency) ?? []).contains { $0.form == .coin }
  }

  private func binding(for denomination: CashDenomination) -> Binding<String> {
    Binding(
      get: { texts[denomination.id] ?? "" },
      set: { text in
        let digits = text.filter(\.isNumber)
        texts[denomination.id] = digits
        count.set(denomination, Self.number(digits))
      })
  }

  /// The count a field's digits make; an empty field is none and a huge one is clamped by the
  /// count itself.
  static func number(_ digits: String) -> Int {
    guard !digits.isEmpty else { return 0 }
    return Int(digits) ?? CashCount.maxPerDenomination
  }

  /// «1000»; a coin where coins share the table with notes says so: «монета 10».
  private func label(_ denomination: CashDenomination) -> String {
    guard notesAndCoins, denomination.form == .coin else { return "\(denomination.value)" }
    return environment.format("reconcile.cash.coin", table: "Planning", "\(denomination.value)")
  }

  /// «5000 × 2, 1000 × 3 = 13,700.00 ₽»; just the sum while nothing is counted.
  static func summary(_ count: CashCount, money: MoneyFormatter) -> String {
    let total = money.exact(count.total, currency: count.currency)
    guard !count.isEmpty else { return total }
    return count.terms.joined(separator: ", ") + " = " + total
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Planning") }
}
