import AppCore
import SwiftUI

/// «Разделить по категориям» for a receipt that becomes a new operation: the QR carries only the
/// total, so the owner shares it by hand — a line is a category and a sum. What the lines leave
/// goes to «Не помню» by itself; lines above the receipt are said and block the write. A plain
/// system form: no glass, one code for the Mac and the touch screens.
struct ReceiptSplitSection: View {
  let model: ReceiptModel
  @Dependency(\.environment) private var environment
  @State private var category: UUID?
  @State private var amountText = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(verbatim: text("receipt.split.title")).appFont(.headline)
      Text(verbatim: text("receipt.split.hint"))
        .appFont(.callout).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      ForEach(Array(model.splitLines.enumerated()), id: \.offset) { index, line in
        HStack {
          Text(verbatim: name(of: line.categoryId))
          Spacer()
          Text(verbatim: environment.money.exact(line.amountE4, currency: currency))
            .monospacedDigit()
          Button {
            model.removeSplitLine(at: index)
          } label: {
            Image(systemName: "minus.circle")
          }
          .buttonStyle(.borderless)
          .accessibilityLabel(Text(verbatim: text("receipt.split.remove")))
        }
      }
      HStack {
        Picker(text("receipt.split.category"), selection: $category) {
          Text(verbatim: "—").tag(UUID?.none)
          ForEach(model.splitCategories, id: \.id) { Text(verbatim: $0.name).tag(Optional($0.id)) }
        }
        .accessibilityIdentifier("receipt.split.category")
        TextField(text("receipt.split.amount"), text: $amountText)
          .multilineTextAlignment(.trailing)
          .frame(maxWidth: 110)
          .onSubmit(add)
          .accessibilityIdentifier("receipt.split.amount")
        Button(text("receipt.split.add"), action: add)
          .disabled(parsed == nil || category == nil)
          .accessibilityIdentifier("receipt.split.add")
      }
      status
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("receipt.split")
  }

  @ViewBuilder
  private var status: some View {
    let left = model.splitRemainder
    if !model.splitLines.isEmpty {
      HStack {
        if left.isNegative {
          Label(
            ReceiptText.format(
              "receipt.split.over", environment, environment.money.exact(-left, currency: currency)
            ), systemImage: "exclamationmark.triangle"
          )
          .foregroundStyle(.orange)
        } else if left.isZero {
          Label(text("receipt.split.done"), systemImage: "checkmark.circle")
            .foregroundStyle(.secondary)
        } else {
          let shown = environment.money.exact(left, currency: currency)
          Text(verbatim: ReceiptText.format("receipt.split.left", environment, shown))
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button(text("receipt.split.clear")) { model.clearSplit() }
          .buttonStyle(.borderless)
      }
      .appFont(.callout)
    }
  }

  private var currency: CurrencyCode { model.receipt?.currency ?? .rub }

  private var parsed: AmountE4? {
    guard let value = AmountField.amount(from: amountText), value > .zero else { return nil }
    return value
  }

  private func add() {
    guard let category, let parsed else { return }
    model.addSplitLine(category: category, amount: parsed)
    amountText = ""
  }

  private func name(of id: UUID) -> String {
    model.splitCategories.first { $0.id == id }?.name ?? "—"
  }

  private func text(_ key: String) -> String { ReceiptText.t(key, environment) }
}
