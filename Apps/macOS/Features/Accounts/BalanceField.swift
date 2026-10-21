import AppCore
import SwiftUI

/// «Остаток сейчас»: a balance that may be unknown.
///
/// Empty is «не знаю» (`nil`), never zero: an account nobody counted stays uncounted, and its
/// first count becomes its starting point. A 0 typed is a count of zero and shows «0». A minus
/// is money owed — a credit card counted at −30,000 — and «-» or «−» both read. The text is an
/// amount or an expression, as in any amount field; it stays as typed while the owner types
/// and is written back the one way the app writes amounts once he is done (Enter, Tab, leaving
/// the field). Text that does not read yet leaves the balance as it was.
///
/// Unlike the amount field of the ↓ panel, which shows 0 as empty, this one tells the two
/// apart: that is the whole point of it.
struct BalanceField: View {
  @Binding var amount: AmountE4?
  /// What the empty field shows: «не знаю», or the balance the books expect.
  let placeholder: String
  @State private var text = ""
  /// The balance the text says, as last told: a change of `amount` from outside is shown, the
  /// field's own is not written over the text being typed.
  @State private var told: AmountE4?
  @FocusState private var isFocused: Bool

  /// What a text says.
  enum Reading: Equatable {
    /// Nothing typed: «не знаю».
    case unknown
    case amount(AmountE4)
    /// Half typed or not a number: the balance stays as it was.
    case unreadable
  }

  var body: some View {
    TextField(text: $text, prompt: Text(verbatim: placeholder)) {
      Text(verbatim: placeholder)
    }
    .labelsHidden()
    .appFont(.body.monospacedDigit())
    .focused($isFocused)
    .onAppear { show(amount) }
    .onChange(of: amount) { _, newValue in
      guard newValue != told else { return }
      show(newValue)
    }
    .onChange(of: text) { _, newValue in
      switch Self.read(newValue) {
      case .unknown:
        told = nil
        amount = nil
      case .amount(let value):
        told = value
        amount = value
      case .unreadable:
        break
      }
    }
    .onSubmit { settle() }
    .onChange(of: isFocused) { _, focused in
      if !focused { settle() }
    }
  }

  /// What `text` says: nothing typed is «не знаю»; an amount or an expression — a minus
  /// included — is its value; anything else does not read.
  static func read(_ text: String) -> Reading {
    guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return .unknown }
    guard let value = try? ExpressionEvaluator.evaluate(text),
      let amount = try? AmountE4(decimal: value)
    else { return .unreadable }
    return .amount(amount)
  }

  /// What the field shows for a balance: nothing for «не знаю», «0» for zero, otherwise the
  /// amount the way the app writes amounts — «-30,000», «1,500.50» — which reads back the same.
  static func text(for amount: AmountE4?) -> String {
    guard let amount else { return "" }
    return FieldNumber.text(amount)
  }

  /// The text once the owner is done: the amount it reads as, written the app's way; `nil`
  /// leaves the text as it is — empty, or not readable yet.
  static func settledText(_ text: String) -> String? {
    guard case .amount(let value) = read(text) else { return nil }
    let settled = Self.text(for: value)
    return settled == text ? nil : settled
  }

  private func settle() {
    guard let settled = Self.settledText(text) else { return }
    text = settled
  }

  private func show(_ value: AmountE4?) {
    told = value
    text = Self.text(for: value)
  }
}
