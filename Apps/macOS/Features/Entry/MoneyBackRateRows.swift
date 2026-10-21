import AppCore
import SwiftUI

/// A purchase in a third currency that money back reaches: its rate can be typed from the
/// statement, and the purchase is then written at it (`PurchaseRate`).
struct PurchaseRateRow: Identifiable, Hashable {
  /// The purchase operation.
  let id: UUID
  let description: String
  let currency: CurrencyCode
  /// What the parts the money reaches cost, in the purchase's currency.
  let amount: AmountE4
  /// Rubles one unit cost: the purchase's rubles over its amount (`PurchaseRate.costRate`).
  let costRate: Decimal
  /// The purchase is still on the bank's provisional rate: the part waits, unless a rate is
  /// typed.
  let provisional: Bool
}

/// The rates money back in another currency is worked out at — shared by the confirmation of
/// the entry line and the per-part sheet.
///
/// * «Курс возврата» — only for money not in rubles: «1 $ = [95.00] ₽». A ruble figure on the
///   account decides it, and then the row only shows it.
/// * «Курс покупки «…»» — one row per purchase in a third currency the money reaches: the rate
///   the part cost me, which the owner may correct from the statement; the purchase is written
///   at the rate typed, in the same write as the money back.
///
/// The rows are `GridRow`s: they sit in the sheet's own `Grid`.
struct MoneyBackRateRows: View {
  @Dependency(\.environment) private var environment
  /// The money's currency.
  let currency: CurrencyCode
  /// The rate of the money as the sheet works it out: the leg's, the typed one or the bank's.
  let moneyRate: Decimal?
  /// The rate of the money follows a ruble figure on the account: it is shown, not typed.
  let moneyRateLocked: Bool
  @Binding var typedMoneyRate: String
  let purchases: [PurchaseRateRow]
  @Binding var purchaseRates: [UUID: String]

  var body: some View {
    if currency != .rub {
      GridRow {
        label(t("moneyBack.moneyRate"))
        HStack(spacing: 6) {
          Text(verbatim: "1 \(currency.code) =").foregroundStyle(.secondary)
          if moneyRateLocked {
            Text(verbatim: moneyRate.map { environment.money.rate($0) } ?? "—")
              .monospacedDigit()
          } else {
            RateTextField(
              title: t("moneyBack.moneyRate"), text: $typedMoneyRate,
              prompt: moneyRate.map { environment.money.rate($0) } ?? "0.00")
          }
          Text(verbatim: "RUB").foregroundStyle(.secondary)
        }
      }
    }
    ForEach(purchases) { purchase in
      GridRow {
        label(environment.format("moneyBack.purchaseRate", table: "Entry", purchase.description))
        VStack(alignment: .leading, spacing: 4) {
          HStack(spacing: 6) {
            Text(verbatim: "1 \(purchase.currency.code) =").foregroundStyle(.secondary)
            RateTextField(
              title: environment.format(
                "moneyBack.purchaseRate", table: "Entry", purchase.description),
              text: binding(purchase.id), prompt: Self.shown(purchase.costRate)
            )
            .accessibilityIdentifier("moneyBack.purchaseRate")
            Text(verbatim: "RUB").foregroundStyle(.secondary)
          }
          if let typed = Self.typedRate(purchaseRates[purchase.id]) {
            Text(
              verbatim: environment.format(
                "moneyBack.purchaseRate.caption", table: "Entry",
                environment.money.exact(purchase.amount, currency: purchase.currency),
                environment.money.exact(
                  Self.rubles(purchase.amount, at: typed) ?? .zero))
            )
            .appFont(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          } else if purchase.provisional {
            Label {
              Text(verbatim: t("moneyBack.purchaseRate.provisional"))
            } icon: {
              Image(systemName: "hourglass")
            }
            .appFont(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          }
        }
      }
    }
  }

  private func binding(_ id: UUID) -> Binding<String> {
    Binding(get: { purchaseRates[id] ?? "" }, set: { purchaseRates[id] = $0 })
  }

  private func label(_ text: String) -> some View {
    Text(verbatim: text)
      .appFont(.caption)
      .foregroundStyle(.secondary)
      .gridColumnAlignment(.leading)
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Entry") }

  // MARK: The rules of the rows

  /// A rate typed as a number or a formula above zero (`RateText`); `nil` for empty or
  /// unreadable text.
  static func typedRate(_ text: String?) -> Decimal? {
    text.flatMap(RateText.rate)
  }

  /// A rate as the rows show it: four decimals, as a statement has it.
  static func shown(_ rate: Decimal) -> String {
    NumberText.decimal(DecimalMath.round(rate, scale: 4), fractionDigits: 4...4)
  }

  static func rubles(_ amount: AmountE4, at rate: Decimal) -> AmountE4? {
    try? AmountE4(decimal: amount.decimal * rate)
  }

  /// The rates typed for the purchases whose rows are still shown (`rows`, their ids): a rate
  /// whose row went goes with it.
  static func keeping(_ texts: [UUID: String], rows: [UUID]) -> [UUID: String] {
    let shown = Set(rows)
    return texts.filter { shown.contains($0.key) }
  }

  /// The purchases typed rates reprice: purchase → the rate, for every row whose text reads.
  static func repricing(_ texts: [UUID: String], among rows: [PurchaseRateRow]) -> [UUID: Decimal] {
    var repricing: [UUID: Decimal] = [:]
    for row in rows {
      if let rate = typedRate(texts[row.id]) { repricing[row.id] = rate }
    }
    return repricing
  }

  /// The owed parts as the typed rates make them: each purchase with a rate written again at it
  /// (`PurchaseRate.repriced`, its day in `calendar`), its parts' rubles following — what the
  /// plan and the write both count with.
  static func owed(
    _ owed: [OwedPart], purchases: [UUID: TransactionEntry], rates: [UUID: Decimal],
    calendar: CalendarContext
  ) -> [OwedPart] {
    var result = owed
    for (id, rate) in rates {
      guard let purchase = purchases[id],
        let repriced = try? PurchaseRate.repriced(
          purchase, rate: rate, day: calendar.day(of: purchase.transaction.occurredAt))
      else { continue }
      result = PurchaseRate.repriced(result, of: repriced)
    }
    return result
  }

  /// A row for every purchase in a currency other than rubles and `money` that one of `reached`
  /// parts belongs to — the parts the money closes, covers partly or passes over for their
  /// rate —, in the order of the parts.
  static func rows(
    reaching reached: [OwedPart], money: CurrencyCode, purchases: [UUID: TransactionEntry],
    note: (OwedPart) -> String
  ) -> [PurchaseRateRow] {
    var rows: [PurchaseRateRow] = []
    for part in reached where part.currency != .rub && part.currency != money {
      guard !rows.contains(where: { $0.id == part.transactionId }),
        let purchase = purchases[part.transactionId],
        let cost = PurchaseRate.costRate(of: purchase.transaction)
      else { continue }
      let amount = AmountE4.sum(
        reached.filter { $0.transactionId == part.transactionId }.map(\.amountE4))
      rows.append(
        PurchaseRateRow(
          id: purchase.id, description: note(part), currency: part.currency, amount: amount,
          costRate: cost, provisional: purchase.transaction.rateProvisional))
    }
    return rows
  }
}
