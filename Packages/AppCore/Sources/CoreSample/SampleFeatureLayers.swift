import CoreAccounting
import CoreKit
import Foundation

extension SampleDataSet {
  /// The history with its accounts (`withAccounts`) and every layer that comes after them: the
  /// cards of the accounts and their cashback (`withCards`), the planning of an event, a goal's
  /// plan and an expected salary (`withPlanningLayer`), an archived place and a one-day event
  /// (`withReferencesLayer`), a credit card below zero with a later count whose difference
  /// follows the books (`withCountsLayer`), and an education loan with its tranches and grace
  /// payments beside a savings account that earns interest (`withLoanAndSavingsLayer`), and a car
  /// and a brokerage account valued by hand, the savings kept as the safety cushion and the
  /// essential spending marked (`withCapitalLayer`), a credit card of «Т-Банк» with a statement
  /// paid in full, an instalment plan, an early repayment and a pledge (`withCreditLayer`), and
  /// the rules of allocation with one income allocated, self-employment with its tax paid and a
  /// currency of the owner's own (`withAllocationLayer`) — what `make sample` and `make demo`
  /// open on.
  ///
  /// Each layer draws from random streams of its own (`seed` mixed with the layer's tag, then
  /// with what the row is and its day), so the history and the accounts under them keep every
  /// draw: their digests and known answers stay as they were. The operations the layers add join
  /// the known answers (`expectations`) and the money of every account at the end
  /// (`accountExpectations`) as they are written. Every row that moves money is dated after the
  /// accounts' own count two weeks before the last day, so that count still finds what it
  /// found, and the later count is written already following the books: opening the set
  /// settles nothing.
  ///
  /// `demo` adds what only the demo shows: a payment due a few days ago and not paid, which the
  /// app asks about at every launch — the sample stays calm for screenshots. Applied once: a set
  /// that already has cards comes back as it is.
  public func withEveryFeature(
    seed: UInt64, calendar: CalendarContext, language: String, now: Date? = nil,
    demo: Bool = false
  ) -> SampleDataSet {
    let accounts = withAccounts(seed: seed, calendar: calendar, language: language, now: now)
    guard accounts.cards.isEmpty else { return accounts }
    return
      accounts
      .withLayersThroughTheCapital(
        seed: seed, calendar: calendar, language: language, now: now, demo: demo
      )
      .withCreditLayer(seed: seed, calendar: calendar, language: language, now: now)
      .withAllocationLayer(seed: seed, calendar: calendar, language: language, now: now)
  }

  /// The layers from the cards through the capital, on a set that has its accounts: what the
  /// layers of credit and allocation are written on — the sample as it was before them, with no
  /// debt of the kinds they bring.
  public func withLayersThroughTheCapital(
    seed: UInt64, calendar: CalendarContext, language: String, now: Date?, demo: Bool
  ) -> SampleDataSet {
    withLayersThroughTheLoanAndSavings(
      seed: seed, calendar: calendar, language: language, now: now, demo: demo
    )
    .withCapitalLayer(seed: seed, calendar: calendar, language: language, now: now)
  }

  /// The layers from the cards through the education loan and the savings account, on a set that
  /// has its accounts: what the capital layer is written on.
  func withLayersThroughTheLoanAndSavings(
    seed: UInt64, calendar: CalendarContext, language: String, now: Date?, demo: Bool
  ) -> SampleDataSet {
    withLayersThroughTheCounts(
      seed: seed, calendar: calendar, language: language, now: now, demo: demo
    )
    .withLoanAndSavingsLayer(seed: seed, calendar: calendar, language: language, now: now)
  }

  /// The layers from the cards through the later count, on a set that has its accounts: what
  /// every layer after them is written on.
  func withLayersThroughTheCounts(
    seed: UInt64, calendar: CalendarContext, language: String, now: Date?, demo: Bool
  ) -> SampleDataSet {
    self
      .withCards(seed: seed, calendar: calendar, language: language, now: now)
      .withPlanningLayer(seed: seed, calendar: calendar, language: language, now: now, demo: demo)
      .withReferencesLayer(seed: seed, calendar: calendar, language: language, now: now)
      .withCountsLayer(seed: seed, calendar: calendar, language: language, now: now)
  }
}

/// What the layers after the accounts share: their random streams, the days they may write on
/// and the moments on those days.
struct SampleLayer {
  /// The seed of the layer's streams: the set's own, mixed with the layer's tag.
  let seed: UInt64
  let calendar: CalendarContext
  let russian: Bool
  let now: Date?
  let firstDay: DateOnly
  let lastDay: DateOnly

  init(
    tag: UInt64, seed: UInt64, set: SampleDataSet, calendar: CalendarContext, language: String,
    now: Date?
  ) {
    self.seed = seed ^ tag
    self.calendar = calendar
    self.russian = language.lowercased().hasPrefix("ru")
    self.now = now
    self.firstDay = set.firstDay
    self.lastDay = set.lastDay
  }

  func word(_ english: String, _ russianText: String) -> String {
    russian ? russianText : english
  }

  /// A random stream for one row, keyed by what the row is — and its day, when it has one —
  /// and not by how many rows were drawn before it.
  func stream(_ feature: String, on day: DateOnly? = nil) -> SeededRandom {
    let key = day.map { "\(feature)|\($0.iso)" } ?? feature
    return SeededRandom(seed: seed ^ SampleAccountsWriter.fnv1a(key))
  }

  /// The day `days` before the last one, while it is on or after the first day; `nil` before.
  func daysBeforeEnd(_ days: Int) -> DateOnly? {
    let day = calendar.adding(days: -days, to: lastDay)
    return day >= firstDay && day < lastDay ? day : nil
  }

  /// `hour:minute` of `day` in the owner's calendar, never after `now`.
  func moment(_ day: DateOnly, hour: Int, minute: Int) -> Date {
    clamped(calendar.moment(day, hour: hour, minute: minute))
  }

  /// A time of day between 09:00 and 21:59, never after `now`.
  func moment(on day: DateOnly, rng: inout SeededRandom) -> Date {
    moment(day, hour: rng.int(in: 9...21), minute: rng.int(in: 0...59))
  }

  func clamped(_ instant: Date) -> Date {
    guard let now else { return instant }
    return min(instant, now)
  }

  /// A purchase of one part in rubles on `account`, the way the entry line writes one: the
  /// category's own quality stored, the moment it was written the moment it happened unless
  /// `writtenAt` says it was entered later.
  func purchase(
    _ amount: AmountE4, of category: CoreKit.Category, parent: CoreKit.Category?, at moment: Date,
    account: UUID, note: String? = nil, placeId: UUID? = nil, eventId: UUID? = nil,
    goalId: UUID? = nil, writtenAt: Date? = nil, rng: inout SeededRandom
  ) -> TransactionEntry {
    let id = rng.nextUUID()
    let quality: Quality
    let source: QualitySource
    if goalId != nil {
      quality = .good
      source = .system
    } else {
      quality = category.quality ?? parent?.quality ?? .neutral
      source = .category
    }
    let part = TransactionPart(
      id: rng.nextUUID(), transactionId: id, categoryId: category.id, quality: quality,
      qualitySource: source, amountE4: amount, amountRubE4: amount, eventId: eventId,
      goalId: goalId)
    let written = writtenAt ?? moment
    return TransactionEntry(
      transaction: Transaction(
        id: id, kind: .expense, occurredAt: moment, amountE4: amount, amountRubE4: amount,
        note: note, placeId: placeId, paymentMethodId: account, createdAt: written,
        updatedAt: written),
      parts: [part])
  }
}

extension SampleDataSet {
  /// A layer's purchase joins the set: the operation, in time order after what the set already
  /// has at its moment; the spending of its month in the known answers; the money of its
  /// account at the end.
  mutating func add(_ entry: TransactionEntry, calendar: CalendarContext) {
    let index =
      entries.firstIndex { $0.transaction.occurredAt > entry.transaction.occurredAt }
      ?? entries.endIndex
    entries.insert(entry, at: index)
    let month = calendar.day(of: entry.transaction.occurredAt).monthKey
    let byId = Dictionary(categories.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    for part in entry.parts {
      let category = part.categoryId.flatMap { byId[$0] }
      expectations.spend(
        part.amountRubE4, in: month, root: category.map { $0.parentId ?? $0.id },
        quality: part.quality ?? .neutral)
    }
    let movesMoney = !entry.parts.allSatisfy { $0.goalId != nil }
    if movesMoney, let account = entry.transaction.paymentMethodId {
      let key = BalanceKey(accountId: account, currency: entry.transaction.currency)
      accountExpectations[key] = (accountExpectations[key] ?? .zero) - entry.transaction.amountE4
    }
  }

  /// A starter category of the set by its English seed name and kind, with its parent.
  func starter(
    _ english: String, _ kind: CategoryKind = .expense
  ) -> (category: CoreKit.Category, parent: CoreKit.Category?)? {
    guard let id = StarterCategories(categories).id(english, kind),
      let category = categories.first(where: { $0.id == id })
    else { return nil }
    return (category, category.parentId.flatMap { parent in categories.first { $0.id == parent } })
  }

  /// The live main account.
  var mainAccount: PaymentMethod? { paymentMethods.first { $0.isDefault && !$0.archived } }
}
