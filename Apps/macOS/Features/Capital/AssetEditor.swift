import AppCore
import SwiftUI

/// A thing valued by hand: its name, kind, currency and note, «Куплено: дата и цена» when the
/// owner knows them, and — for a new one — «Стоимость» «на дату», today unless changed.
/// «Сохранить» writes the asset and its first valuation as one `PlanningChange`, one step of ⌘Z;
/// an edit leaves the valuations alone (they have «Новая оценка…» and «История оценок»).
struct AssetEditor: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Dependency(\.store) private var store
  @Environment(\.dependencies) private var dependencies
  let original: Asset?
  /// The warranty, the receipt, the contract: a new thing keeps them waiting until it is saved.
  @State private var files: AttachmentsModel
  @State private var asset: Asset
  @State private var value: AmountE4 = .zero
  @State private var day: DateOnly?
  @State private var refusal: AssetRefusal?
  @State private var loaded = false
  /// «Куплено: дата и цена»: on when either was said before.
  @State private var purchaseKnown: Bool
  @State private var purchaseDay: DateOnly?
  @State private var purchasePrice: AmountE4

  init(original: Asset?) {
    self.original = original
    let seed = original ?? Asset(name: "")
    _asset = State(initialValue: seed)
    _purchaseKnown = State(
      initialValue: seed.purchasedOn != nil || seed.purchasePriceE4 != nil)
    _purchaseDay = State(initialValue: seed.purchasedOn)
    _purchasePrice = State(initialValue: seed.purchasePriceE4 ?? .zero)
    _files = State(
      initialValue: AttachmentsModel(owner: .asset, ownerId: seed.id, deferred: original == nil))
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
        purchaseRows
        if original == nil {
          LabeledContent(CapitalText.t("capital.editor.value", environment)) {
            HStack {
              AmountField(amount: $value, locale: environment.language.locale)
              Text(verbatim: environment.money.symbol(for: asset.currency))
                .secondaryInk()
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
            .secondaryInk()
            .fixedSize(horizontal: false, vertical: true)
        }
        TextField(
          text: Binding(get: { asset.note ?? "" }, set: { asset.note = $0 }), axis: .vertical
        ) {
          Text(verbatim: CapitalText.t("capital.editor.note", environment))
        }
        .lineLimit(1...3)
        if environment.attachments != nil {
          Section { AttachmentsSection(model: files) }
        }
      }
      .formStyle(.grouped)
      FormButtons(
        title: environment.language("action.save"),
        enabled: AssetActions.refusal(saving: edited, value: value) == nil,
        failure: { failureText }
      ) {
        guard let dependencies else { return false }
        let outcome = Self.save(
          edited, isNew: original == nil, value: value, on: day ?? environment.today,
          with: AssetActions(dependencies))
        if case .refused(let why) = outcome { refusal = why }
        if outcome == .done {
          let files = files
          let service = environment.attachments
          let store = store
          Task { await files.commitPending(service: service, store: store) }
        }
        return outcome == .done
      }
    }
    .padding(20)
    .sheetFrame(width: 460, height: original == nil ? 640 : 580)
    .onAppear {
      // A new thing is valued in the default currency unless the owner picks another.
      guard !loaded else { return }
      loaded = true
      if original == nil { asset.currency = environment.defaultCurrency }
    }
  }

  /// The asset as «Сохранить» writes it: what was typed with «Куплено: дата и цена».
  private var edited: Asset {
    AssetActions.purchased(
      asset, known: purchaseKnown, on: purchaseDay ?? environment.today, price: purchasePrice)
  }

  /// «Куплено: дата и цена»: a switch, then the day and the price in the currency of the asset.
  /// Both may lie long before the books began.
  @ViewBuilder
  private var purchaseRows: some View {
    Toggle(isOn: $purchaseKnown) {
      Text(verbatim: CapitalText.t("capital.editor.purchase", environment))
    }
    .accessibilityIdentifier("capital.editor.purchase")
    if purchaseKnown {
      DatePicker(
        CapitalText.t("capital.editor.purchase.day", environment),
        selection: Binding(
          get: { environment.calendar.startOfDay(purchaseDay ?? environment.today) },
          set: { purchaseDay = environment.calendar.day(of: $0) }),
        displayedComponents: .date)
      LabeledContent(CapitalText.t("capital.editor.purchase.price", environment)) {
        HStack {
          AmountField(amount: $purchasePrice, locale: environment.language.locale)
          Text(verbatim: environment.money.symbol(for: asset.currency))
            .secondaryInk()
        }
      }
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
