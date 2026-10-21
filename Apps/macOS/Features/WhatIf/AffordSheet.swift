import AppCore
import SwiftUI

/// «Хватит ли?»: the owner types the price of a purchase and the sheet says whether today's
/// numbers pay for it — read from the planning snapshot, nothing is written. It never offers a
/// loan or an instalment; that is a scenario the owner opens by hand in «Что если…».
struct AffordSheet: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dismiss) private var dismiss

  @State private var amount: AmountE4

  /// `amount` starts the field: the amount typed in the entry panel, or empty.
  init(amount: AmountE4 = .zero) {
    _amount = State(initialValue: amount)
  }

  private func text(_ key: String) -> String { environment.language(key, table: "WhatIf") }

  private var snapshot: PlanningSnapshot? { compute.states.data.value?.planning }

  /// The median spending of the last three full months, cut from the ledger of the same data.
  private var spending: AffordSpending {
    guard let data = compute.states.data.value else { return .none }
    return AffordSpending.build(ledger: data.ledger, today: data.today)
  }

  private var writer: AffordModel.Writer {
    AffordModel.Writer(
      money: { environment.money.rounded($0) },
      month: { environment.dates.monthTitle($0) },
      day: { environment.dates.longDay($0) })
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(verbatim: text("afford.title")).appFont(.headline)
      Form {
        LabeledContent(text("afford.amount")) {
          AmountField(amount: $amount)
        }
      }
      .formStyle(.grouped)
      answer
      Text(verbatim: text("afford.note")).appFont(.caption).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      HStack {
        Spacer()
        Button(text("afford.close")) { dismiss() }
          .keyboardShortcut(.cancelAction)
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .sheetFrame(width: 460)
    .accessibilityIdentifier("afford.sheet")
  }

  @ViewBuilder
  private var answer: some View {
    if let snapshot {
      if amount.raw <= 0 {
        Text(verbatim: text("afford.typeAmount")).foregroundStyle(.secondary)
      } else if let input = AffordModel.input(
        amount: amount, snapshot: snapshot, spending: spending)
      {
        let told = AffordModel.told(AffordCheck.check(input), input: input, writer: writer)
        VStack(alignment: .leading, spacing: 6) {
          Text(verbatim: render(told.headline)).appFont(.headline)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("afford.answer")
          ForEach(told.lines, id: \.arguments) { line in
            Text(verbatim: render(line)).appFont(.subheadline)
          }
          if AffordModel.usesObligatory(spending), told.headline.key == "afford.yesIfWait" {
            Text(verbatim: text("afford.fewHistory")).appFont(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
              .accessibilityIdentifier("afford.fewHistory")
          }
          Text(
            verbatim: environment.format(
              "afford.free", table: "WhatIf", environment.money.rounded(input.freeE4))
          ).appFont(.caption).foregroundStyle(.secondary)
        }
      } else {
        Text(verbatim: text("afford.noCount")).foregroundStyle(.secondary)
      }
    } else {
      Text(verbatim: text("whatif.waiting")).foregroundStyle(.secondary)
    }
  }

  private func render(_ phrase: AffordModel.Phrase) -> String {
    switch phrase.arguments.count {
    case 0: return text(phrase.key)
    case 1: return environment.format(phrase.key, table: "WhatIf", phrase.arguments[0])
    default:
      return environment.format(
        phrase.key, table: "WhatIf", phrase.arguments[0], phrase.arguments[1])
    }
  }
}
