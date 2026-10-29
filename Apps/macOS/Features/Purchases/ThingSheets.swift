import AppCore
import SwiftUI

/// A thing noted apart from the capital: its name, the day and the price it was bought for, the
/// tag that gathers what it costs to keep, and a note.
struct ThingEditor: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies
  let original: OwnedItem?
  @State private var item: OwnedItem
  @State private var price: AmountE4
  @State private var hasDay: Bool
  @State private var day: DateOnly?
  @State private var refusal: PurchaseRefusal?
  @State private var loaded = false

  init(original: OwnedItem?) {
    self.original = original
    _item = State(initialValue: original ?? OwnedItem(name: ""))
    _price = State(initialValue: original?.priceE4 ?? .zero)
    _hasDay = State(initialValue: original?.boughtOn != nil)
    _day = State(initialValue: original?.boughtOn)
  }

  private func t(_ key: String) -> String { PurchasesText.t(key, environment) }

  private var tags: [Tag] {
    (compute.snapshot?.dataset.tagBook.tags ?? []).filter { !$0.archived }
      .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  var body: some View {
    VStack(alignment: .leading) {
      Text(
        verbatim: t(original == nil ? "purchases.thing.editor.new" : "purchases.thing.editor.edit")
      )
      .appFont(.headline)
      Form {
        TextField(text: $item.name) {
          Text(verbatim: t("purchases.thing.editor.name"))
        }
        .accessibilityIdentifier("purchases.thing.editor.name")
        LabeledContent(t("purchases.thing.editor.price")) {
          HStack {
            AmountField(amount: $price, locale: environment.language.locale)
            CurrencyMenu(
              currencies: currencies, label: t("purchases.thing.editor.currency"),
              selection: $item.currency)
          }
        }
        Toggle(isOn: $hasDay) {
          Text(verbatim: t("purchases.thing.editor.hasDay"))
        }
        if hasDay {
          DatePicker(
            t("purchases.thing.editor.day"),
            selection: Binding(
              get: { environment.calendar.startOfDay(day ?? environment.today) },
              set: { day = environment.calendar.day(of: $0) }),
            displayedComponents: .date)
        }
        Picker(selection: $item.tagId) {
          Text(verbatim: t("purchases.thing.editor.noTag")).tag(UUID?.none)
          ForEach(tags) { tag in
            Text(verbatim: "#" + tag.name).tag(UUID?.some(tag.id))
          }
        } label: {
          Text(verbatim: t("purchases.thing.editor.tag"))
        }
        Text(verbatim: t("purchases.thing.editor.tagHint"))
          .appFont(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        TextField(
          text: Binding(get: { item.note ?? "" }, set: { item.note = $0 }), axis: .vertical
        ) {
          Text(verbatim: t("purchases.thing.editor.note"))
        }
        .lineLimit(1...3)
      }
      .formStyle(.grouped)
      FormButtons(
        title: environment.language("action.save"),
        enabled: !item.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        failure: { refusal.map { PurchasesText.refusal($0, environment) } ?? "" }
      ) {
        guard let dependencies else { return false }
        var next = item
        next.priceE4 = price.raw > 0 ? price : nil
        next.boughtOn = hasDay ? (day ?? environment.today) : nil
        let actions = PurchaseActions(dependencies)
        let outcome = original == nil ? actions.add(next) : actions.save(next)
        if case .refused(let why) = outcome { refusal = why }
        return outcome == .done
      }
    }
    .padding(20)
    .sheetFrame(width: 480, height: 560)
    .onAppear {
      guard !loaded else { return }
      loaded = true
      if original == nil { item.currency = environment.defaultCurrency }
    }
  }

  private var currencies: [CurrencyCode] {
    let enabled = PlanningChoices(compute, environment).currencies
    return enabled.contains(item.currency) ? enabled : enabled + [item.currency]
  }
}

/// «Продал…»: what the thing was sold for, on which day and onto which account. The sale is an
/// income in the category of sales of things, the thing is closed, and the screen of the thing
/// keeps what owning it cost less what the sale brought.
struct ThingSaleSheet: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies
  let line: OwnedLine
  @State private var price: AmountE4 = .zero
  @State private var currency: CurrencyCode = .rub
  @State private var day: DateOnly?
  @State private var account: UUID?
  @State private var refusal: PurchaseRefusal?
  @State private var loaded = false

  private func t(_ key: String) -> String { PurchasesText.t(key, environment) }

  var body: some View {
    let choices = PlanningChoices(compute, environment)
    VStack(alignment: .leading) {
      Text(verbatim: PurchasesText.f("purchases.sale.title", environment, line.name))
        .appFont(.headline)
      Form {
        LabeledContent(t("purchases.sale.price")) {
          HStack {
            AmountField(amount: $price, locale: environment.language.locale)
            CurrencyMenu(
              currencies: currencies(choices), label: t("purchases.sale.currency"),
              selection: $currency)
          }
        }
        DatePicker(
          t("purchases.sale.day"),
          selection: Binding(
            get: { environment.calendar.startOfDay(day ?? environment.today) },
            set: { day = environment.calendar.day(of: $0) }),
          displayedComponents: .date)
        Picker(selection: $account) {
          Text(verbatim: t("purchases.sale.mainAccount")).tag(UUID?.none)
          ForEach(choices.methods) { method in
            Text(verbatim: method.name).tag(UUID?.some(method.id))
          }
        } label: {
          Text(verbatim: t("purchases.sale.account"))
        }
        Text(verbatim: t("purchases.sale.hint"))
          .appFont(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .formStyle(.grouped)
      FormButtons(
        title: t("purchases.sale.button"), enabled: price.raw > 0,
        failure: { refusal.map { PurchasesText.refusal($0, environment) } ?? "" }
      ) {
        guard let dependencies else { return false }
        let outcome = PurchaseActions(dependencies).sell(
          line.origin, for: price, currency: currency, on: day ?? environment.today, to: account)
        if case .refused(let why) = outcome { refusal = why }
        return outcome == .done
      }
    }
    .padding(20)
    .sheetFrame(width: 460, height: 400)
    .onAppear {
      guard !loaded else { return }
      loaded = true
      switch line.origin {
      case .asset(let asset): currency = asset.currency
      case .item(let item): currency = item.currency
      }
    }
  }

  private func currencies(_ choices: PlanningChoices) -> [CurrencyCode] {
    choices.currencies.contains(currency) ? choices.currencies : choices.currencies + [currency]
  }
}
