import AppCore
import AppDatabase
import SwiftUI

/// What stands under the chart of the capital when it reaches before the books: a line for each
/// way the line is not a record (symbol and words, never colour alone) and the quiet button that
/// asks once what was on the accounts then. Nothing here blocks the chart.
struct CapitalPastFooter: View {
  @Dependency(\.environment) private var environment
  @Environment(\.dependencies) private var dependencies
  let model: NetWorthChartModel
  @State private var asking = false

  static func symbol(_ note: NetWorthChartNote) -> String {
    switch note {
    case .straightLine: "line.diagonal"
    case .restored: "arrow.counterclockwise"
    case .cashEstimated: "questionmark.circle"
    case .withoutCash: "minus.circle"
    }
  }

  var body: some View {
    if !model.notes.isEmpty || model.cashQuestionDay != nil {
      VStack(alignment: .leading, spacing: 4) {
        ForEach(model.notes, id: \.self) { note in
          Label {
            Text(verbatim: CapitalText.t("capital.chart.note.\(note.rawValue)", environment))
          } icon: {
            Image(systemName: Self.symbol(note))
          }
          .appFont(.caption)
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("capital.chart.note.\(note.rawValue)")
        }
        if let day = model.cashQuestionDay {
          Button {
            asking = true
          } label: {
            Text(
              verbatim: CapitalText.t(
                model.pastCash == nil ? "capital.chart.cash.ask" : "capital.chart.cash.edit",
                environment))
          }
          .buttonStyle(.link)
          .appFont(.caption)
          .accessibilityIdentifier("capital.chart.cash.ask")
          .sheet(isPresented: $asking) {
            CapitalPastCashSheet(day: day, current: model.pastCash)
              .handingOver(dependencies)
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

/// The rule of what the sheet writes: the sum and the day it was asked about, as one step of
/// ⌘Z, and only the keys that change.
enum CapitalPastCashChange {
  static func change(
    from before: PastCash?, to after: PastCash?, at now: Date
  ) -> PlanningChange? {
    let old = CapitalSettings(pastCash: before).storedValues
    let new = CapitalSettings(pastCash: after).storedValues
    var settings: [String: String?] = [:]
    for key in [CapitalSettings.pastCashKey, CapitalSettings.pastCashDayKey]
    where old[key] != new[key] {
      settings.updateValue(new[key] ?? nil, forKey: key)
    }
    guard !settings.isEmpty else { return nil }
    return PlanningChange(settings: settings, at: now)
  }
}

/// «Сколько примерно было на счетах?»: one rough sum for all accounts on the day of the
/// earliest purchase or loan. Only the chart of the capital reads it; «Убрать ответ» takes it
/// back.
struct CapitalPastCashSheet: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.store) private var store
  @Environment(\.dismiss) private var dismiss
  let day: DateOnly
  let current: PastCash?
  @State private var amount: AmountE4 = .zero
  @State private var failed = false

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(
        verbatim: CapitalText.format(
          "capital.chart.cash.title", environment, environment.dates.longDay(current?.day ?? day))
      )
      .appFont(.headline)
      Text(verbatim: CapitalText.t("capital.chart.cash.hint", environment))
        .appFont(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Form {
        LabeledContent(CapitalText.t("capital.chart.cash.amount", environment)) {
          HStack {
            AmountField(amount: $amount, locale: environment.language.locale)
            Text(verbatim: environment.money.symbol(for: .rub)).foregroundStyle(.secondary)
          }
        }
      }
      .formStyle(.grouped)
      HStack {
        if current != nil {
          Button(CapitalText.t("capital.chart.cash.remove", environment), role: .destructive) {
            write(nil)
          }
        }
        Spacer()
        Button(environment.language("action.cancel"), role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button(environment.language("action.save")) {
          write(PastCash(day: current?.day ?? day, amountE4: amount))
        }
        .keyboardShortcut(.defaultAction)
        .buttonStyle(.borderedProminent)
        .disabled(amount.isNegative || store.isWritingInBackground)
        .accessibilityIdentifier("capital.chart.cash.save")
      }
    }
    .padding(20)
    .sheetFrame(width: 440)
    .onAppear { amount = current?.amountE4 ?? .zero }
    .refusedWriteAlert($failed, environment)
  }

  private func write(_ cash: PastCash?) {
    guard let change = CapitalPastCashChange.change(from: current, to: cash, at: environment.now())
    else {
      dismiss()
      return
    }
    guard store.apply(change) else {
      failed = true
      return
    }
    AppLog.info(
      "capital.pastCash.set", .db, "the rough cash before the books was set",
      [LogPair("answered", .flag(cash != nil))])
    dismiss()
  }
}
