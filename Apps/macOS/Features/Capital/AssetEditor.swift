import AppCore
import SwiftUI

/// A thing valued by hand: its name, kind, currency and note, and — for a new one — «Стоимость»
/// «на дату», today unless changed. «Сохранить» writes the asset and its first valuation as one
/// `PlanningChange`, one step of ⌘Z; an edit leaves the valuations alone (they have «Новая
/// оценка…» and «История оценок»).
struct AssetEditor: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies
  let original: Asset?
  @State private var asset: Asset
  @State private var value: AmountE4 = .zero
  @State private var day: DateOnly?
  @State private var refusal: AssetRefusal?
  @State private var loaded = false

  init(original: Asset?) {
    self.original = original
    _asset = State(initialValue: original ?? Asset(name: ""))
  }

  var body: some View {
    VStack(alignment: .leading) {
      Text(
        verbatim: CapitalText.t(
          original == nil ? "capital.editor.new" : "capital.editor.edit", environment)
      )
      .appFont(.headline)
      Form {
        TextField(text: $asset.name) {
          Text(verbatim: CapitalText.t("capital.editor.name", environment))
        }
        .accessibilityIdentifier("capital.editor.name")
        Picker(selection: $asset.kind) {
          ForEach(AssetKind.allCases, id: \.self) { kind in
            Label {
              Text(verbatim: CapitalText.t(CapitalText.kindKey(kind), environment))
            } icon: {
              Image(systemName: CapitalText.kindSymbol(kind))
            }
            .tag(kind)
          }
        } label: {
          Text(verbatim: CapitalText.t("capital.editor.kind", environment))
        }
        LabeledContent(CapitalText.t("capital.editor.currency", environment)) {
          CurrencyMenu(
            currencies: currencies,
            label: CapitalText.t("capital.editor.currency", environment),
            selection: $asset.currency)
        }
        if original == nil {
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
              get: { environment.calendar.startOfDay(day ?? environment.today) },
              set: { day = environment.calendar.day(of: $0) }),
            displayedComponents: .date)
        } else {
          Text(verbatim: CapitalText.t("capital.editor.valueHint", environment))
            .appFont(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        TextField(
          text: Binding(get: { asset.note ?? "" }, set: { asset.note = $0 }), axis: .vertical
        ) {
          Text(verbatim: CapitalText.t("capital.editor.note", environment))
        }
        .lineLimit(1...3)
      }
      .formStyle(.grouped)
      FormButtons(
        title: environment.language("action.save"),
        enabled: AssetActions.refusal(saving: asset, value: value) == nil,
        failure: { failureText }
      ) {
        guard let dependencies else { return false }
        let outcome = Self.save(
          asset, isNew: original == nil, value: value, on: day ?? environment.today,
          with: AssetActions(dependencies))
        if case .refused(let why) = outcome { refusal = why }
        return outcome == .done
      }
    }
    .padding(20)
    .sheetFrame(width: 460, height: original == nil ? 420 : 360)
    .onAppear {
      // A new thing is valued in the default currency unless the owner picks another.
      guard !loaded else { return }
      loaded = true
      if original == nil { asset.currency = environment.defaultCurrency }
    }
  }

  /// What «Сохранить» writes: a new asset with its first valuation, or the edit of one.
  static func save(
    _ asset: Asset, isNew: Bool, value: AmountE4, on day: DateOnly, with actions: AssetActions
  ) -> AssetActionOutcome {
    isNew ? actions.create(asset, value: value, on: day) : actions.save(asset)
  }

  /// Why the last «Сохранить» wrote nothing, in words.
  private var failureText: String {
    guard let refusal, let key = CapitalText.refusalKey(.refused(refusal)) else { return "" }
    return CapitalText.t(key, environment)
  }

  /// The enabled currencies, and the asset's own when it is not among them.
  private var currencies: [CurrencyCode] {
    let enabled = PlanningChoices(compute, environment).currencies
    return enabled.contains(asset.currency) ? enabled : enabled + [asset.currency]
  }
}
