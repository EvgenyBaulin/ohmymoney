import AppCore
import Foundation

/// The filters of «Операции» and the text of its search box, as the popover of filters
/// edits them. Pure, so the rules of resetting are tested without a window:
///
/// * the type narrows the categories on offer to its kind, and a category of the other kind
///   is dropped together with its subcategory — it would filter everything out, and the
///   picker could no longer show it;
/// * another category drops the subcategory, exactly as the ↓ panel does;
/// * a value archived after it was chosen is dropped (`keep(within:)`) — but a place, a person
///   and an event, which the filter goes on offering from the archive, are kept;
/// * «Reset» brings everything back, the search included;
/// * the period starts as «All time»: the table shows the newest months of the whole history,
///   and the search looks through all of it.
struct TransactionFilters: Hashable, Sendable {
  enum PeriodChoice: String, CaseIterable, Hashable, Sendable {
    case thisMonth, lastMonth, thisYear, allTime, custom

    var titleKey: String {
      switch self {
      case .thisMonth: "filters.thisMonth"
      case .lastMonth: "filters.lastMonth"
      case .thisYear: "filters.thisYear"
      case .allTime: "filters.allTime"
      case .custom: "filters.custom"
      }
    }
  }

  var period: PeriodChoice = .allTime
  /// The two days of «Custom range». Kept when another period is chosen, so going back to
  /// the custom one finds them as they were.
  var customStart: DateOnly
  var customEnd: DateOnly
  private(set) var kind: TransactionKind?
  private(set) var categoryId: UUID?
  var subcategoryId: UUID?
  var quality: Quality?
  var forWhom: ForWhom?
  var personId: UUID?
  var placeId: UUID?
  var eventId: UUID?
  /// The account: its operations, and the transfers from it or to it.
  var paymentMethodId: UUID?
  /// A card of the account: only the operations it paid. No transfer is paid by a card.
  var cardId: UUID?
  var status: ReimbursementStatus?
  var search = ""

  /// The custom range starts as this month so far.
  init(today: DateOnly) {
    customStart = today.monthKey.firstDay
    customEnd = today
  }

  /// A type, and whatever category it leaves no room for.
  mutating func setKind(_ kind: TransactionKind?, tree: [CoreKit.Category]) {
    self.kind = kind
    guard let categoryId,
      !Self.filterCategories(tree, kind: kind).contains(where: { $0.id == categoryId })
    else { return }
    self.categoryId = nil
    subcategoryId = nil
  }

  /// Another category drops the subcategory: a child of the category that was there before
  /// would leave the pair mismatched.
  mutating func setCategory(_ categoryId: UUID?) {
    guard categoryId != self.categoryId else { return }
    self.categoryId = categoryId
    subcategoryId = nil
  }

  /// The account picker's choice: a card, or an account.
  var accountOrCard: UUID? { cardId ?? paymentMethodId }

  /// Picks an account — every operation of it and its cards — or one card, which brings its
  /// account.
  mutating func setAccountOrCard(_ id: UUID?, cards: [PaymentCard]) {
    let resolved = CardRules.resolve(selection: id, cards: cards)
    paymentMethodId = resolved.accountId
    cardId = resolved.cardId
  }

  /// Keeps only the values `choices` still offers. One chosen here and archived since — in
  /// Settings, or gone with a restore — is not offered any more, so its picker shows «Any»:
  /// kept, it went on filtering the table with nothing on screen to say so.
  mutating func keep(within choices: FilterChoices) {
    if let categoryId, !choices.topLevel(for: kind).contains(where: { $0.id == categoryId }) {
      self.categoryId = nil
    }
    if let subcategoryId,
      !choices.subcategories(of: categoryId).contains(where: { $0.id == subcategoryId })
    {
      self.subcategoryId = nil
    }
    if let personId, !choices.people.contains(where: { $0.id == personId }) {
      self.personId = nil
    }
    if let placeId, !choices.places.contains(where: { $0.id == placeId }) {
      self.placeId = nil
    }
    if let eventId, !choices.events.contains(where: { $0.id == eventId }) {
      self.eventId = nil
    }
    if let paymentMethodId,
      !choices.paymentMethods.contains(where: { $0.id == paymentMethodId })
    {
      self.paymentMethodId = nil
      cardId = nil
    }
    // A card archived since, or one of another account, is no longer offered: the account
    // alone stays.
    if let cardId,
      !choices.cards.contains(where: { $0.id == cardId && $0.accountId == paymentMethodId })
    {
      self.cardId = nil
    }
  }

  /// Whether «Reset» has anything to do. The days of a custom range count only while it is
  /// the period chosen.
  var canReset: Bool {
    var plain = self
    plain.reset()
    plain.customStart = customStart
    plain.customEnd = customEnd
    return plain != self
  }

  /// How many filters narrow the table, the search aside: the period other than «All time»
  /// counts one, an account or a card one, and every other choice one.
  var activeCount: Int {
    var count = period == .allTime ? 0 : 1
    count +=
      [
        kind != nil, categoryId != nil, subcategoryId != nil, quality != nil, forWhom != nil,
        personId != nil, placeId != nil, eventId != nil, accountOrCard != nil, status != nil,
      ].filter { $0 }.count
    return count
  }

  /// Back to the whole history, nothing else chosen, nothing searched. The custom days stay.
  mutating func reset() {
    let (start, end) = (customStart, customEnd)
    self = TransactionFilters(today: start)
    customStart = start
    customEnd = end
  }

  /// The period as the core reads it. The months take income by the month it is for, like
  /// every monthly figure; a custom range is its days, in either order.
  func period(today: DateOnly) -> Period? {
    let month = today.monthKey
    switch period {
    case .thisMonth: return .month(month)
    case .lastMonth: return .month(month.previous)
    case .thisYear: return .year(today.year)
    case .allTime: return nil
    case .custom:
      return .days(DayRange(min(customStart, customEnd), max(customStart, customEnd)))
    }
  }

  /// The filter of the core over the whole history.
  func entryFilter(today: DateOnly) -> EntryFilter {
    EntryFilter(
      period: period(today: today), kind: kind, categoryId: categoryId,
      subcategoryId: subcategoryId, quality: quality, forWhom: forWhom, personId: personId,
      placeId: placeId, eventId: eventId, paymentMethodId: paymentMethodId,
      reimbursementStatus: status, text: search.trimmingCharacters(in: .whitespaces),
      cardId: cardId)
  }

  /// Top-level categories the category filter offers: those of the kind the type filter
  /// chose — a refund and a reimbursement live among the spending ones — and all of them
  /// while the type is «any».
  static func filterCategories(
    _ tree: [CoreKit.Category], kind: TransactionKind?
  ) -> [CoreKit.Category] {
    tree.filter { category in
      category.parentId == nil && (kind.map { $0.categoryKind == category.kind } ?? true)
    }
  }
}

/// The values the filters offer, taken from the data the table shows whenever it changes.
/// Archived categories, accounts and cards are not offered, though an operation filed under an
/// archived subcategory is still found by its live parent. Places, people and events in the
/// archive are: their operations keep them, and the table is where the owner finds those — the
/// live ones first, then the archived ones, which the picker names «(архив)» after a line
/// (`placeOptions`, `personOptions`, `eventOptions`).
struct FilterChoices: Sendable {
  var categories: [CoreKit.Category] = []
  var people: [Person] = []
  var places: [Place] = []
  var events: [Event] = []
  var paymentMethods: [PaymentMethod] = []
  /// The live cards of the accounts offered.
  var cards: [PaymentCard] = []
  /// The banks the accounts are filed under, and every account there is: the lists name an account
  /// as its bank does (`AccountLabels`).
  var banks: [Bank] = []
  var everyAccount: [PaymentMethod] = []
  /// The places of `places` that are in the archive, named «(архив)» by the picker.
  var archivedPlaceIds: Set<UUID> = []
  /// The people of `people` that are in the archive, named «(архив)» by the picker.
  var archivedPersonIds: Set<UUID> = []
  /// The events of `events` that are in the archive, named «(архив)» by the picker.
  var archivedEventIds: Set<UUID> = []

  init() {}

  /// `locale` orders the accounts by name the way the interface language does.
  init(_ dataset: Dataset, locale: Locale = Locale(identifier: "en")) {
    categories = dataset.categories.filter { !$0.archived }
    let byName: (Person, Person) -> Bool = { $0.name < $1.name }
    let archivedPeople = dataset.people.filter(\.archived).sorted(by: byName)
    people = dataset.people.filter { !$0.archived }.sorted(by: byName) + archivedPeople
    archivedPersonIds = Set(archivedPeople.map(\.id))
    let archivedPlaces = dataset.places.filter(\.archived).sorted { $0.name < $1.name }
    places =
      dataset.places.filter { !$0.archived }.sorted { $0.name < $1.name } + archivedPlaces
    archivedPlaceIds = Set(archivedPlaces.map(\.id))
    // The latest first, in each part: the event one looks for is usually the last one.
    let latestFirst: (Event, Event) -> Bool = { $0.startDate > $1.startDate }
    let archivedEvents = dataset.events.filter(\.archived).sorted(by: latestFirst)
    events = dataset.events.filter { !$0.archived }.sorted(by: latestFirst) + archivedEvents
    archivedEventIds = Set(archivedEvents.map(\.id))
    // The order of every list of accounts: the main one first, then the owner's order.
    paymentMethods = AccountRules.ordered(dataset.paymentMethods, locale: locale)
    let offered = Set(paymentMethods.map(\.id))
    cards = dataset.cards.filter { !$0.archived && offered.contains($0.accountId) }
    banks = dataset.banks
    everyAccount = dataset.paymentMethods
    self.locale = locale
  }

  private var locale = Locale(identifier: "en")

  /// The account filter's choices: each account followed by its cards.
  var accountItems: [AccountCardChoices.Item] {
    AccountCardChoices.items(
      accounts: paymentMethods, cards: cards, banks: banks, among: everyAccount, locale: locale)
  }

  /// The choices of a picker that offers the archive too: each value with its name — an archived
  /// one through `archivedName`, «Кофемания (архив)» — and where the archived ones start, for the
  /// line that sets them apart (`nil` when there are none, or nothing live before them).
  struct Options {
    var options: [(UUID, String)]
    var dividerBefore: Int?
  }

  /// `archivedName` names a value in the archive: `common.archivedName` of the interface.
  func placeOptions(archivedName: (String) -> String) -> Options {
    Self.options(places.map { ($0.id, $0.name) }, archived: archivedPlaceIds, archivedName)
  }

  func personOptions(archivedName: (String) -> String) -> Options {
    Self.options(people.map { ($0.id, $0.name) }, archived: archivedPersonIds, archivedName)
  }

  func eventOptions(archivedName: (String) -> String) -> Options {
    Self.options(events.map { ($0.id, $0.name) }, archived: archivedEventIds, archivedName)
  }

  private static func options(
    _ values: [(UUID, String)], archived: Set<UUID>, _ archivedName: (String) -> String
  ) -> Options {
    let first = values.firstIndex { archived.contains($0.0) }
    return Options(
      options: values.map { archived.contains($0.0) ? ($0.0, archivedName($0.1)) : $0 },
      dividerBefore: first.flatMap { $0 > 0 ? $0 : nil })
  }

  func topLevel(for kind: TransactionKind?) -> [CoreKit.Category] {
    TransactionFilters.filterCategories(categories, kind: kind)
  }

  func subcategories(of categoryId: UUID?) -> [CoreKit.Category] {
    guard let categoryId else { return [] }
    return categories.filter { $0.parentId == categoryId }
  }
}
