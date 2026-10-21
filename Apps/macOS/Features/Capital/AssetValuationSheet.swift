import AppCore
import SwiftUI

/// «Новая оценка…»: what the asset is worth on a day, in its currency. A day that has a
/// valuation already keeps one: the new value takes its place, and the sheet says so before it
/// is saved. One `PlanningChange`, one step of ⌘Z.
struct AssetValuationSheet: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies
  let asset: Asset
  @State private var value: AmountE4 = .zero
  @State private var day: DateOnly?
  @State private var note = ""

  var body: some View {
    let chosen = day ?? environment.today
    let valuations = compute.snapshot?.dataset.assetValuations ?? []
    let replaces = valuations.contains { $0.assetId == asset.id && $0.day == chosen }
    VStack(alignment: .leading) {
      Text(verbatim: CapitalText.format("capital.valuation.title", environment, asset.name))
        .appFont(.headline)
      Form {
        LabeledContent(CapitalText.t("capital.editor.value", environment)) {
          HStack {
            AmountField(amount: $value, locale: environment.language.locale)
            Text(verbatim: environment.money.symbol(for: asset.currency))
              .foregroundStyle(.secondary)
          }
        }
        DatePicker(
          CapitalText.t("capital.editor.day", environment),
          selection: Binding(
            get: { environment.calendar.startOfDay(chosen) },
            set: { day = environment.calendar.day(of: $0) }),
          displayedComponents: .date)
        if replaces {
          Label {
            Text(verbatim: CapitalText.t("capital.valuation.replaces", environment))
          } icon: {
            Image(systemName: "arrow.triangle.2.circlepath")
          }
          .appFont(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("capital.valuation.replaces")
        }
        TextField(text: $note) {
          Text(verbatim: CapitalText.t("capital.editor.note", environment))
        }
      }
      .formStyle(.grouped)
      FormButtons(title: environment.language("action.save"), enabled: !value.isNegative) {
        guard let dependencies else { return false }
        return AssetActions(dependencies).value(
          asset.id, value: value, on: chosen, note: note, among: valuations) == .done
      }
    }
    .padding(20)
    .sheetFrame(width: 420, height: 320)
    .onAppear {
      // Starts from the last value: a new valuation is mostly a small change of it.
      guard day == nil else { return }
      day = environment.today
      if let latest = AssetActions.latest(of: asset.id, among: valuations) {
        value = latest.valueE4
      }
    }
  }
}

/// «История оценок»: every valuation of the asset, the latest first, each with «Удалить» — one
/// step of ⌘Z each.
struct AssetHistorySheet: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies
  @Environment(\.dismiss) private var dismiss
  let asset: Asset

  var body: some View {
    let history = AssetActions.history(
      of: asset.id, among: compute.snapshot?.dataset.assetValuations ?? [])
    VStack(alignment: .leading, spacing: 12) {
      Text(verbatim: CapitalText.format("capital.history.title", environment, asset.name))
        .appFont(.headline)
      if history.isEmpty {
        Text(verbatim: CapitalText.t("capital.history.empty", environment))
          .foregroundStyle(.secondary)
      }
      List(history) { valuation in
        HStack(alignment: .firstTextBaseline) {
          VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: environment.dates.longDay(valuation.day))
            if let note = valuation.note {
              Text(verbatim: note)
                .appFont(.caption)
                .foregroundStyle(.secondary)
            }
          }
          Spacer(minLength: 8)
          Text(verbatim: environment.money.rounded(valuation.valueE4, currency: asset.currency))
            .monospacedDigit()
          Button {
            guard let dependencies else { return }
            _ = AssetActions(dependencies).delete(valuation: valuation)
          } label: {
            Image(systemName: "trash")
          }
          .buttonStyle(.borderless)
          .accessibilityLabel(Text(verbatim: environment.language("action.delete")))
        }
      }
      .frame(minHeight: 160)
      HStack {
        Spacer()
        Button(environment.language("action.ok")) { dismiss() }
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .sheetFrame(width: 420, height: 360)
  }
}

/// «Продано / списано…»: the day the asset left. It counts through the day before, then it is
/// gone from net worth and listed under «Проданное». One step of ⌘Z.
struct AssetDisposalSheet: View {
  @Dependency(\.environment) private var environment
  @Environment(\.dependencies) private var dependencies
  let asset: Asset
  @State private var day: DateOnly?

  var body: some View {
    let chosen = day ?? environment.today
    VStack(alignment: .leading) {
      Text(verbatim: CapitalText.format("capital.dispose.title", environment, asset.name))
        .appFont(.headline)
      Form {
        DatePicker(
          CapitalText.t("capital.dispose.day", environment),
          selection: Binding(
            get: { environment.calendar.startOfDay(chosen) },
            set: { day = environment.calendar.day(of: $0) }),
          displayedComponents: .date)
        Text(verbatim: CapitalText.t("capital.dispose.hint", environment))
          .appFont(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .formStyle(.grouped)
      FormButtons(title: environment.language("action.save"), enabled: true) {
        guard let dependencies else { return false }
        return AssetActions(dependencies).dispose(asset, on: chosen) == .done
      }
    }
    .padding(20)
    .sheetFrame(width: 420, height: 240)
  }
}
