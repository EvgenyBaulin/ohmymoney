import AppCore
import AppDatabase
import SwiftUI

/// Updates a thing's market value without rewriting what it was bought for.
struct ThingValuationSheet: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies
  let origin: OwnedLine.Origin

  init(line: OwnedLine) { origin = origin }
  init(asset: Asset) { origin = .asset(asset) }

  private var name: String {
    switch origin {
    case .asset(let asset): asset.name
    case .item(let item): item.name
    }
  }
  @State private var amount: AmountE4 = .zero
  @State private var currency: CurrencyCode = .rub
  @State private var day: DateOnly?
  @State private var note = ""
  @State private var history: [ThingValuation] = []
  @State private var failed = false
  @State private var loaded = false

  private func t(_ key: String) -> String { PurchasesText.t(key, environment) }

  private var identity: (ThingValuation.Owner, UUID) {
    switch origin {
    case .asset(let asset): (.asset, asset.id)
    case .item(let item): (.ownedItem, item.id)
    }
  }

  private var currencies: [CurrencyCode] {
    let enabled = PlanningChoices(compute, environment).currencies
    return enabled.contains(currency) ? enabled : enabled + [currency]
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(verbatim: name).appFont(.headline)
      Form {
        LabeledContent(t("purchases.valuation.amount")) {
          HStack {
            AmountField(amount: $amount, locale: environment.language.locale)
            CurrencyMenu(
              currencies: currencies, label: t("purchases.thing.editor.currency"),
              selection: $currency)
          }
        }
        DatePicker(
          t("purchases.valuation.day"),
          selection: Binding(
            get: { environment.calendar.startOfDay(day ?? environment.today) },
            set: { day = environment.calendar.day(of: $0) }), displayedComponents: .date)
        TextField(text: $note) { Text(verbatim: t("purchases.thing.editor.note")) }
        Section {
          historyView
        } header: {
          Text(verbatim: t("purchases.valuation.history"))
        }
        if failed {
          Text(verbatim: t("purchases.refusal.failed")).foregroundStyle(.red)
        }
      }
      .formStyle(.grouped)
      FormButtons(title: environment.language("action.save"), enabled: amount.raw >= 0) {
        guard let dependencies else { return false }
        let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = ThingValuation(
          owner: identity.0, ownerId: identity.1,
          day: day ?? environment.today, amountE4: amount, currency: currency,
          note: text.isEmpty ? nil : text, recordedAt: environment.now())
        guard let encoded = try? value.storedValue else { return false }
        return dependencies.store.apply(
          PlanningChange(
            settings: [value.storageKey: encoded], at: environment.now()))
      }
    }
    .padding(20)
    .sheetFrame(width: 500, height: 620)
    .onAppear {
      reload()
      guard !loaded else { return }
      loaded = true
      let last = history.last { $0.day <= environment.today }
      switch origin {
      case .asset(let asset): currency = last?.currency ?? asset.currency
      case .item(let item): currency = last?.currency ?? item.currency
      }
      amount = last?.amountE4 ?? .zero
    }
  }

  @ViewBuilder
  private var historyView: some View {
    if history.isEmpty {
      Text(verbatim: t("purchases.valuation.empty")).foregroundStyle(.secondary)
    }
    ForEach(Array(Set(history.map(\.currency))).sorted { $0.code < $1.code }, id: \.self) { code in
      let values = history.filter { $0.currency == code }
      Text(verbatim: code.code).appFont(.caption)
      ThingValuationChart(values: values, calendar: environment.calendar) { value in
        environment.dates.longDay(value.day) + ", "
          + environment.money.exact(value.amountE4, currency: value.currency)
      }
      .frame(height: 100)
    }
    ForEach(history.reversed()) { value in
      VStack(alignment: .leading, spacing: 3) {
        HStack {
          Text(verbatim: environment.dates.longDay(value.day))
          Spacer()
          Text(verbatim: environment.money.exact(value.amountE4, currency: value.currency))
            .monospacedDigit()
          Button {
            remove(value)
          } label: {
            Image(systemName: "trash")
          }
          .buttonStyle(.borderless)
          .accessibilityLabel(Text(verbatim: environment.language("action.delete")))
        }
        if let note = value.note {
          Text(verbatim: note).appFont(.caption).foregroundStyle(.secondary)
        }
      }
    }
  }

  private func remove(_ value: ThingValuation) {
    guard let dependencies else { return }
    let legacy = compute.snapshot?.dataset.assetValuations.first { $0.id == value.id }
    let outcome: Bool
    if let legacy {
      outcome = AssetActions(dependencies).delete(valuation: legacy) == .done
    } else {
      outcome = dependencies.store.apply(
        PlanningChange(
          settings: [value.storageKey: nil], at: environment.now()))
    }
    if outcome { history.removeAll { $0.id == value.id } } else { failed = true }
  }

  private func reload() {
    guard let stack = environment.stack else { return }
    do {
      let updates = try ThingValuationRepository(writer: stack.writer).all()
      history = ThingValuation.history(updates, owner: identity.0, id: identity.1)
      if case .asset(let asset) = origin {
        history = ThingValuation.history(
          asset: asset,
          legacy: compute.snapshot?.dataset.assetValuations ?? [], updates: updates)
      }
      history = ThingValuation.history(history, owner: identity.0, id: identity.1)
    } catch { failed = true }
  }
}
