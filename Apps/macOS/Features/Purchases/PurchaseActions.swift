import AppCore
import AppDatabase
import Foundation

/// Why an action on the purchases was not taken. Nothing is written then.
enum PurchaseRefusal: Error, Hashable, Sendable {
  case emptyName
  /// A price that is not above zero.
  case badPrice
  /// The address of the wish does not read as a link.
  case badLink
  case notFound
}

/// What became of an action on the purchases.
enum PurchaseOutcome: Hashable, Sendable {
  case done
  case refused(PurchaseRefusal)
  /// The write failed; the log says how.
  case failed
}

/// The actions of the screens «Хочу купить», «Покупки», «Вещи» and «Ждут зачисления». A wish, a
/// line of the shopping list and a thing noted apart are rows of their own and are written
/// directly; what touches an operation or an asset — the sale of a thing, the credit of a
/// refund — goes through the store, one step of ⌘Z. The rules that make a row or a change are
/// static, so a test reads them alone.
@MainActor
struct PurchaseActions {
  let environment: AppEnvironment
  let store: TransactionsStore
  let deps: AppDependencies

  init(_ deps: AppDependencies) {
    self.deps = deps
    environment = deps.environment
    store = deps.store
  }

  // MARK: Rules

  private static func trimmed(_ text: String?) -> String? {
    let value = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return value.isEmpty ? nil : value
  }

  /// The link as the browser opens it: `https://` is put in front of an address typed without a
  /// scheme; anything but http and https, and an address without a host, is no link.
  static func link(_ text: String?) -> URL? {
    guard var value = trimmed(text), !value.contains(" ") else { return nil }
    if !value.contains("://") { value = "https://" + value }
    guard let url = URL(string: value), let scheme = url.scheme?.lowercased(),
      scheme == "http" || scheme == "https", let host = url.host, host.contains(".")
    else { return nil }
    return url
  }

  /// A wish as the editor saves it: the spaces around the texts gone, an empty text as none, the
  /// link written out in full, a price that is not above zero as none.
  static func cleaned(_ wish: Wish) -> Wish {
    var wish = wish
    wish.name = trimmed(wish.name) ?? ""
    wish.note = trimmed(wish.note)
    wish.url = link(wish.url)?.absoluteString
    if let price = wish.priceE4, price.raw <= 0 { wish.priceE4 = nil }
    return wish
  }

  /// What keeps `wish` from being saved, the first thing only. A link typed and not readable is
  /// told, not dropped quietly.
  static func refusal(saving wish: Wish) -> PurchaseRefusal? {
    if trimmed(wish.name) == nil { return .emptyName }
    if let price = wish.priceE4, price.raw < 0 { return .badPrice }
    if trimmed(wish.url) != nil, link(wish.url) == nil { return .badLink }
    return nil
  }

  static func refusal(saving item: OwnedItem) -> PurchaseRefusal? {
    if trimmed(item.name) == nil { return .emptyName }
    if let price = item.priceE4, price.raw < 0 { return .badPrice }
    return nil
  }

  static func cleaned(_ item: OwnedItem) -> OwnedItem {
    var item = item
    item.name = trimmed(item.name) ?? ""
    item.note = trimmed(item.note)
    if let price = item.priceE4, price.raw <= 0 { item.priceE4 = nil }
    return item
  }

  private static func same(_ left: String, _ right: String) -> Bool {
    left.trimmingCharacters(in: .whitespaces).lowercased()
      == right.trimmingCharacters(in: .whitespaces).lowercased()
  }

  /// The category the sale of a thing goes to: a live income category of that name (or of one
  /// of `alsoKnownAs`) at the top, else a new one at the end of the income categories.
  static func salesCategory(
    categories: [CoreKit.Category], name: String, alsoKnownAs other: [String] = []
  ) -> (id: UUID, made: [CoreKit.Category]) {
    let names = [name] + other
    if let found = categories.first(where: { category in
      category.kind == .income && !category.archived && category.parentId == nil
        && names.contains { Self.same($0, category.name) }
    }) {
      return (found.id, [])
    }
    let sort =
      (categories.filter { $0.parentId == nil && $0.kind == .income }.map(\.sort).max() ?? -1) + 1
    let made = CoreKit.Category(parentId: nil, kind: .income, name: name, sort: sort)
    return (made.id, [made])
  }

  /// The income that sells a thing: the amount the thing was sold for, on the day, in the sales
  /// category, named after the thing.
  static func saleDraft(
    name: String, price: AmountE4, currency: CurrencyCode, day: DateOnly, category: UUID,
    accountId: UUID?, noon: Date
  ) -> TransactionDraft {
    TransactionDraft(
      kind: .income, occurredAt: noon, currency: currency, amount: price, note: name,
      paymentMethodId: accountId,
      parts: [PartDraft(categoryId: category, amount: price)])
  }

  /// The shopping line as it is saved.
  static func cleaned(_ item: ShoppingItem) -> ShoppingItem {
    var item = item
    item.name = trimmed(item.name) ?? ""
    item.note = trimmed(item.note)
    return item
  }

  // MARK: Wishes

  @discardableResult
  func add(_ wish: Wish) -> PurchaseOutcome {
    if let why = Self.refusal(saving: wish) { return .refused(why) }
    var next = Self.cleaned(wish)
    let known = try? environment.wishes?.wishes(includeBought: true, includeArchived: true)
    let last = known?.map(\.sort).max() ?? -1
    next.sort = max(next.sort, last + 1)
    guard
      environment.attempt("purchases.wishAdded", on: environment.wishes, { try $0.insert(next) })
    else { return .failed }
    return .done
  }

  @discardableResult
  func save(_ wish: Wish) -> PurchaseOutcome {
    if let why = Self.refusal(saving: wish) { return .refused(why) }
    let next = Self.cleaned(wish)
    guard
      environment.attempt("purchases.wishSaved", on: environment.wishes, { try $0.update(next) })
    else { return .failed }
    return .done
  }

  /// The price now, noted on `day`: it joins the history and becomes the price of the wish.
  @discardableResult
  func notePrice(of wishId: UUID, _ price: AmountE4, on day: DateOnly) -> PurchaseOutcome {
    guard price.raw > 0 else { return .refused(.badPrice) }
    guard
      environment.attempt(
        "purchases.priceNoted", on: environment.wishes,
        { _ = try $0.notePrice(of: wishId, price, on: day) })
    else { return .failed }
    return .done
  }

  @discardableResult
  func deletePrice(_ id: UUID) -> PurchaseOutcome {
    environment.attempt(
      "purchases.priceGone", on: environment.wishes, { try $0.deletePrice(id: id) })
      ? .done : .failed
  }

  /// «Купил»: the operation is tied to the wish with the price the owner expected, and the wish
  /// leaves the list of what is wanted. The history of its prices stays.
  @discardableResult
  func markBought(_ wish: Wish, by transactionId: UUID) -> PurchaseOutcome {
    guard
      environment.attempt(
        "purchases.wishBought", on: environment.wishes,
        { try $0.markBought(id: wish.id, by: transactionId, expectedE4: wish.priceE4) })
    else { return .failed }
    return .done
  }

  /// Takes a wish off the list without a purchase (it stays in the database, archived).
  @discardableResult
  func archive(_ wish: Wish) -> PurchaseOutcome {
    var next = wish
    next.archived = true
    return environment.attempt(
      "purchases.wishArchived", on: environment.wishes, { try $0.update(next) })
      ? .done : .failed
  }

  @discardableResult
  func delete(wish id: UUID) -> PurchaseOutcome {
    environment.attempt("purchases.wishGone", on: environment.wishes, { try $0.delete(ids: [id]) })
      ? .done : .failed
  }

  // MARK: Shopping

  @discardableResult
  func addShopping(_ name: String, note: String? = nil) -> PurchaseOutcome {
    var item = Self.cleaned(
      ShoppingItem(name: name, note: note, createdOn: environment.today))
    guard !item.name.isEmpty else { return .refused(.emptyName) }
    item.sort = ((try? environment.shopping?.items())?.map(\.sort).max() ?? -1) + 1
    let line = item
    return environment.attempt(
      "purchases.shopAdded", on: environment.shopping, { try $0.insert(line) }) ? .done : .failed
  }

  @discardableResult
  func setDone(_ id: UUID, _ done: Bool) -> PurchaseOutcome {
    environment.attempt(
      "purchases.shopTicked", on: environment.shopping, { try $0.setDone(id: id, done) })
      ? .done : .failed
  }

  @discardableResult
  func save(_ item: ShoppingItem) -> PurchaseOutcome {
    let next = Self.cleaned(item)
    guard !next.name.isEmpty else { return .refused(.emptyName) }
    return environment.attempt(
      "purchases.shopSaved", on: environment.shopping, { try $0.update(next) }) ? .done : .failed
  }

  @discardableResult
  func deleteShopping(_ id: UUID) -> PurchaseOutcome {
    environment.attempt(
      "purchases.shopGone", on: environment.shopping, { try $0.delete(ids: [id]) })
      ? .done : .failed
  }

  /// «Очистить сделанные».
  @discardableResult
  func clearDone() -> PurchaseOutcome {
    environment.attempt(
      "purchases.shopCleared", on: environment.shopping, { _ = try $0.clearDone() })
      ? .done : .failed
  }

  // MARK: Things

  @discardableResult
  func add(_ item: OwnedItem) -> PurchaseOutcome {
    if let why = Self.refusal(saving: item) { return .refused(why) }
    let next = Self.cleaned(item)
    return environment.attempt(
      "purchases.itemAdded", on: environment.ownedItems, { try $0.insert(next) })
      ? .done : .failed
  }

  @discardableResult
  func save(_ item: OwnedItem) -> PurchaseOutcome {
    if let why = Self.refusal(saving: item) { return .refused(why) }
    let next = Self.cleaned(item)
    return environment.attempt(
      "purchases.itemSaved", on: environment.ownedItems, { try $0.update(next) })
      ? .done : .failed
  }

  @discardableResult
  func delete(item id: UUID) -> PurchaseOutcome {
    environment.attempt(
      "purchases.itemGone", on: environment.ownedItems, { try $0.delete(ids: [id]) })
      ? .done : .failed
  }

  /// «Продал…»: an income in the sales category, and the thing marked as sold — a thing noted
  /// apart gets the day and the operation, an asset of the capital is disposed of that day. The
  /// income and the disposal are one change, one step of ⌘Z.
  @discardableResult
  func sell(
    _ origin: OwnedLine.Origin, for price: AmountE4, currency: CurrencyCode, on day: DateOnly,
    to accountId: UUID?
  ) -> PurchaseOutcome {
    guard price.raw > 0 else { return .refused(.badPrice) }
    let name: String
    var rows = PlanningRows.empty
    switch origin {
    case .asset(let asset):
      name = asset.name
      rows.assets = [OwnershipSale.disposed(asset, on: day)]
    case .item(let item):
      name = item.name
    }
    let category = Self.salesCategory(
      categories: store.categories(),
      name: PurchasesText.t("purchases.category.sales", environment),
      alsoKnownAs: ["Продажа вещей", "Sales"])
    rows.categories = category.made
    let draft = Self.saleDraft(
      name: name, price: price, currency: currency, day: day, category: category.id,
      accountId: accountId, noon: environment.calendar.noon(of: day))
    guard let entry = try? PlanningActions(deps).operation(draft, link: nil) else {
      return .failed
    }
    let change = PlanningChange(created: [entry], upsert: rows, at: environment.now())
    guard store.apply(change) else { return .failed }
    if case .item(let item) = origin {
      let saleId = entry.id
      guard
        environment.attempt(
          "purchases.itemSold", on: environment.ownedItems,
          { try $0.markSold(id: item.id, on: day, by: saleId) })
      else { return .failed }
    }
    if !category.made.isEmpty { environment.refreshVocabulary() }
    AppLog.info(
      "purchases.sold", .db, "a thing was sold",
      [LogPair("operation", .id(entry.id))])
    return .done
  }

  // MARK: Refunds that are waited for

  /// The operation as the database holds it now (the list of the store may not show it).
  private func entry(_ id: UUID) -> TransactionEntry? {
    (try? environment.transactions?.entry(id: id)) ?? store.entry(id: id)
  }

  /// «Зачислено»: the wait ends and the operation counts as an ordinary refund.
  @discardableResult
  func credit(_ transactionId: UUID) -> PurchaseOutcome {
    guard var entry = entry(transactionId) else { return .refused(.notFound) }
    entry.transaction = WaitingRefunds.credited(entry.transaction)
    return store.save(entry) ? .done : .failed
  }

  /// «Перенести срок»: the day the money is expected moves.
  @discardableResult
  func expect(_ transactionId: UUID, by day: DateOnly) -> PurchaseOutcome {
    guard var entry = entry(transactionId) else { return .refused(.notFound) }
    entry.transaction = WaitingRefunds.expecting(entry.transaction, by: day)
    return store.save(entry) ? .done : .failed
  }

  // MARK: Settings

  @discardableResult
  func save(_ settings: PurchaseSettings) -> Bool {
    environment.attempt(
      "purchases.settings", on: environment.purchaseSettings, { try $0.save(settings) })
  }
}
