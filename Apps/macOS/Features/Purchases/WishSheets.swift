import AppCore
import SwiftUI

/// A wish: its name, price and currency, how much it is wanted, where it is sold and a note.
/// «Сохранить» writes it; an empty name or a link that does not read is told, not saved.
struct WishEditor: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies
  let original: Wish?
  @State private var wish: Wish
  @State private var price: AmountE4
  @State private var refusal: PurchaseRefusal?
  @State private var loaded = false

  init(original: Wish?) {
    self.original = original
    _wish = State(
      initialValue: original
        ?? Wish(name: "", createdOn: DateOnly(year: 2000, month: 1, day: 1)))
    _price = State(initialValue: original?.priceE4 ?? .zero)
  }

  private func t(_ key: String) -> String { PurchasesText.t(key, environment) }

  var body: some View {
    VStack(alignment: .leading) {
      Text(
        verbatim: t(original == nil ? "purchases.wish.editor.new" : "purchases.wish.editor.edit")
      )
      .appFont(.headline)
      Form {
        TextField(text: $wish.name) {
          Text(verbatim: t("purchases.wish.editor.name"))
        }
        .accessibilityIdentifier("purchases.wish.editor.name")
        LabeledContent(t("purchases.wish.editor.price")) {
          HStack {
            AmountField(amount: $price, locale: environment.language.locale)
            CurrencyMenu(
              currencies: currencies, label: t("purchases.wish.editor.currency"),
              selection: $wish.currency)
          }
        }
        Stepper(value: $wish.priority, in: 0...9) {
          Text(
            verbatim: PurchasesText.f(
              "purchases.wish.editor.priority", environment,
              PurchasesText.priority(wish.priority, environment)))
        }
        .accessibilityIdentifier("purchases.wish.editor.priority")
        TextField(
          text: Binding(get: { wish.url ?? "" }, set: { wish.url = $0 })
        ) {
          Text(verbatim: t("purchases.wish.editor.link"))
        }
        .autocorrectionDisabled()
        .accessibilityIdentifier("purchases.wish.editor.link")
        TextField(
          text: Binding(get: { wish.note ?? "" }, set: { wish.note = $0 }), axis: .vertical
        ) {
          Text(verbatim: t("purchases.wish.editor.note"))
        }
        .lineLimit(1...3)
      }
      .formStyle(.grouped)
      FormButtons(
        title: environment.language("action.save"),
        enabled: !wish.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        failure: { refusal.map { PurchasesText.refusal($0, environment) } ?? "" }
      ) {
        guard let dependencies else { return false }
        var next = wish
        next.priceE4 = price.raw > 0 ? price : nil
        let actions = PurchaseActions(dependencies)
        let outcome = original == nil ? actions.add(next) : actions.save(next)
        if case .refused(let why) = outcome { refusal = why }
        return outcome == .done
      }
    }
    .padding(20)
    .sheetFrame(width: 480, height: 470)
    .onAppear {
      guard !loaded else { return }
      loaded = true
      if original == nil {
        wish.createdOn = environment.today
        wish.currency = environment.defaultCurrency
      }
    }
  }

  private var currencies: [CurrencyCode] {
    let enabled = PlanningChoices(compute, environment).currencies
    return enabled.contains(wish.currency) ? enabled : enabled + [wish.currency]
  }
}

/// «Цена…»: the price seen today, written into the history of the wish and made its price; the
/// prices noted before are listed below and can be taken back one by one.
struct WishPriceSheet: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies
  @Environment(\.dismiss) private var dismiss
  let wish: Wish
  @State private var price: AmountE4
  @State private var day: DateOnly?
  @State private var refusal: PurchaseRefusal?

  init(wish: Wish) {
    self.wish = wish
    _price = State(initialValue: wish.priceE4 ?? .zero)
  }

  private func t(_ key: String) -> String { PurchasesText.t(key, environment) }

  private var noted: [WishPrice] {
    (compute.snapshot?.dataset.wishPrices ?? []).filter { $0.wishId == wish.id }
      .sorted { ($0.onDate, $0.id.uuidString) > ($1.onDate, $1.id.uuidString) }
  }

  var body: some View {
    VStack(alignment: .leading) {
      Text(verbatim: PurchasesText.f("purchases.price.title", environment, wish.name))
        .appFont(.headline)
      Form {
        LabeledContent(t("purchases.price.now")) {
          HStack {
            AmountField(amount: $price, locale: environment.language.locale)
            Text(verbatim: environment.money.symbol(for: wish.currency))
              .foregroundStyle(.secondary)
          }
        }
        DatePicker(
          t("purchases.price.day"),
          selection: Binding(
            get: { environment.calendar.startOfDay(day ?? environment.today) },
            set: { day = environment.calendar.day(of: $0) }),
          displayedComponents: .date)
        Section {
          if noted.isEmpty {
            Text(verbatim: t("purchases.price.none")).foregroundStyle(.secondary)
          }
          ForEach(noted) { entry in
            HStack {
              Text(verbatim: environment.dates.longDay(entry.onDate))
              Spacer()
              Text(verbatim: environment.money.rounded(entry.priceE4, currency: wish.currency))
                .monospacedDigit()
              Button {
                if let dependencies { _ = PurchaseActions(dependencies).deletePrice(entry.id) }
              } label: {
                Image(systemName: "minus.circle")
              }
              .buttonStyle(.borderless)
              .accessibilityLabel(Text(verbatim: t("purchases.price.remove")))
            }
          }
        } header: {
          Text(verbatim: t("purchases.price.history"))
        }
      }
      .formStyle(.grouped)
      FormButtons(
        title: t("purchases.price.note"), enabled: price.raw > 0,
        failure: { refusal.map { PurchasesText.refusal($0, environment) } ?? "" }
      ) {
        guard let dependencies else { return false }
        let outcome = PurchaseActions(dependencies).notePrice(
          of: wish.id, price, on: day ?? environment.today)
        if case .refused(let why) = outcome { refusal = why }
        return outcome == .done
      }
    }
    .padding(20)
    .sheetFrame(width: 460, height: 520)
  }
}

/// «Купил»: the operations of the last two months that cost about as much as the wish, the
/// closest first. The one chosen is tied to the wish, and the wish says what it cost against what
/// was thought.
struct WishBoughtSheet: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies
  let wish: Wish
  @State private var selected: UUID?

  private func t(_ key: String) -> String { PurchasesText.t(key, environment) }

  private var candidates: [TransactionEntry] {
    guard let snapshot = compute.snapshot else { return [] }
    let taken = Set(snapshot.dataset.wishes.compactMap(\.boughtTransactionId))
    return PurchasesPage.candidates(
      for: wish, entries: snapshot.dataset.entries, takenBy: taken,
      rubPerUnit: snapshot.context.rubPerUnit, today: snapshot.today,
      calendar: environment.calendar)
  }

  var body: some View {
    let found = candidates
    VStack(alignment: .leading, spacing: 10) {
      Text(verbatim: PurchasesText.f("purchases.bought.title", environment, wish.name))
        .appFont(.headline)
      Text(
        verbatim: PurchasesText.f(
          "purchases.bought.hint", environment, PurchasesText.price(of: wish, environment))
      )
      .appFont(.callout)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      if found.isEmpty {
        Text(verbatim: t("purchases.bought.none"))
          .appFont(.callout)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.vertical, 8)
          .accessibilityIdentifier("purchases.bought.none")
      } else {
        List(found, id: \.id, selection: $selected) { entry in
          row(entry).tag(entry.id)
        }
        .frame(minHeight: 180)
        .accessibilityIdentifier("purchases.bought.list")
      }
      if let preview = preview(found) {
        Text(verbatim: preview)
          .appFont(.callout.monospacedDigit())
          .accessibilityIdentifier("purchases.bought.preview")
      }
      FormButtons(
        title: t("purchases.bought.link"), enabled: selected != nil
      ) {
        guard let dependencies, let selected else { return false }
        return PurchaseActions(dependencies).markBought(wish, by: selected) == .done
      }
    }
    .padding(20)
    .sheetFrame(width: 500, height: 440)
  }

  private func row(_ entry: TransactionEntry) -> some View {
    let transaction = entry.transaction
    let day = environment.calendar.day(
      of: transaction.occurredAt, recordedIn: transaction.timeZoneId)
    return HStack {
      VStack(alignment: .leading, spacing: 2) {
        Text(verbatim: describe(entry)).lineLimit(1)
        Text(verbatim: environment.dates.longDay(day))
          .appFont(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      Text(verbatim: environment.money.exact(transaction.amountE4, currency: transaction.currency))
        .monospacedDigit()
    }
  }

  private func describe(_ entry: TransactionEntry) -> String {
    if let note = entry.transaction.note, !note.isEmpty { return note }
    if let note = entry.parts.compactMap(\.note).first(where: { !$0.isEmpty }) { return note }
    let categories = compute.snapshot?.dataset.categories ?? []
    if let id = entry.parts.first?.categoryId,
      let category = categories.first(where: { $0.id == id })
    {
      return category.name
    }
    return t("purchases.bought.noDescription")
  }

  /// «Думал 32 000 ₽ — вышло 29 900 ₽ (−2 100 ₽)» for the operation chosen.
  private func preview(_ found: [TransactionEntry]) -> String? {
    guard let selected, let entry = found.first(where: { $0.id == selected }),
      let snapshot = compute.snapshot,
      let paid = PurchasesPage.paidAmount(
        of: entry, inCurrencyOf: wish, rubPerUnit: snapshot.context.rubPerUnit),
      let outcome = WishOutcome.compare(wish: wish, paidE4: paid)
    else { return nil }
    return PurchasesText.outcome(outcome, currency: wish.currency, environment)
  }
}
