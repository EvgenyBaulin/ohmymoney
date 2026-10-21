import AppCore
import SwiftUI

/// A field of a rate the form reads as text — the money-back sheet, «Провести» without a rate of
/// the bank. The text is read by `RateText`: a plain number as rates always read, or a formula —
/// «95,5/1,02», «1/0.0105», «(90+92)/2» — worked out the way the field of an amount works one
/// out. While the text is a formula that reads, what it comes to stands beside the field; Enter,
/// Tab and leaving the field write the rate in its place, every digit of it, with a point. Text
/// that does not read stays as typed, for the owner to finish — the form refuses it as before.
struct RateTextField: View {
  let title: String
  @Binding var text: String
  var prompt: String?
  var width: CGFloat = 110
  @FocusState private var isFocused: Bool

  var body: some View {
    HStack(spacing: 6) {
      TextField(text: $text, prompt: prompt.map { Text(verbatim: $0) }) {
        Text(verbatim: title)
      }
      .labelsHidden()
      .frame(width: width)
      .focused($isFocused)
      .onSubmit { settle() }
      .onChange(of: isFocused) { _, focused in
        if !focused { settle() }
      }
      if let result = Self.formulaResult(text) {
        RateFormulaResult(rate: result)
      }
    }
  }

  private func settle() {
    let settled = Self.settled(text)
    if settled != text { text = settled }
  }

  /// The text once the owner is done with the field: the number it reads as — a rate or not —
  /// written the way the app writes rates, or the text itself when it does not read.
  static func settled(_ text: String) -> String {
    guard let value = RateText.value(text) else { return text }
    return NumberText.plain(value)
  }

  /// What a formula comes to, while the text is one that reads; nil for a plain number and for
  /// a formula still being typed.
  static func formulaResult(_ text: String) -> Decimal? {
    guard RateText.isFormula(text) else { return nil }
    return RateText.value(text)
  }
}

/// «= 93.6274509804» beside a rate typed as a formula: what will be saved, before it is.
struct RateFormulaResult: View {
  let rate: Decimal

  var body: some View {
    Text(verbatim: "= \(NumberText.plain(rate, minus: "\u{2212}"))")
      .appFont(.caption.monospacedDigit())
      .foregroundStyle(.secondary)
      .lineLimit(1)
      .fixedSize()
  }
}
