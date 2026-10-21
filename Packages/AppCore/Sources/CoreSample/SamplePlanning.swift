import CoreKit
import Foundation

/// The planning of a synthetic history (`SampleDataSet.planning`), so the Planning section of
/// a sample is not empty: scheduled payments and subscriptions — one with a price history
/// and a price change announced ahead, one paid for somebody who gives the money back, one
/// yearly in dollars — two monthly limits, and an expected income with its prepayment.
///
/// It is built on top of the history and never adds to it: not one operation, so the known
/// answers of the history (`SampleExpectations`) and the golden figures stay as they are.
/// There is no reconciliation either: the owner meets the first one the way a new user does.
public struct SamplePlanning: Hashable, Sendable {
  public var scheduled: [ScheduledPayment]
  /// The price history of the subscriptions, oldest first for each.
  public var prices: [SubscriptionPrice]
  public var expected: [ExpectedIncome]
  /// Income of the history tied to `expected`.
  public var expectedLinks: [ExpectedIncomeLink]
  public var budgets: [Budget]

  public init(
    scheduled: [ScheduledPayment] = [], prices: [SubscriptionPrice] = [],
    expected: [ExpectedIncome] = [], expectedLinks: [ExpectedIncomeLink] = [],
    budgets: [Budget] = []
  ) {
    self.scheduled = scheduled
    self.prices = prices
    self.expected = expected
    self.expectedLinks = expectedLinks
    self.budgets = budgets
  }

  public static let empty = SamplePlanning()
}

extension SampleDataSet {
  /// The planning of this history, built from it on every call (`SamplePlanning(for:)`),
  /// with the payments due once and the income expected that the layers over it add after its
  /// own.
  public var planning: SamplePlanning {
    var planning = SamplePlanning(for: self)
    planning.scheduled += oneOffPayments
    planning.expected += addedExpectedIncome
    return planning
  }

  /// The planning book of a database holding this history: its planning, the journals of
  /// its debts, the counts of its accounts and the default settings — what
  /// `Dataset.planning` carries.
  public var planningBook: PlanningBook {
    let planning = planning
    return PlanningBook(
      scheduled: planning.scheduled, prices: planning.prices, expected: planning.expected,
      expectedLinks: planning.expectedLinks, budgets: planning.budgets,
      reconciliations: reconciliations, debtEntries: debtEntries,
      reconciledBalances: reconciledBalances)
  }
}

extension SamplePlanning {
  /// A limit whose history has no complete month to size it by: the first month of a history
  /// that ends in it.
  static let fallbackGroceriesLimit = AmountE4(whole: 25_000)
  static let fallbackBadLimit = AmountE4(whole: 5_000)
  /// The whole of the expected income; a side job of the history pays less than that.
  static let expectedTotal = AmountE4(whole: 40_000)
  /// How far back from the last operation a side job still counts as its prepayment.
  static let prepaymentWindowDays = 62

  /// The planning of a generated history, as a pure function of it: the same set — so the
  /// same seed, language and density — always gives the same rows.
  ///
  /// * The rent and the mobile plan the history pays every month, with its amounts, days and
  ///   card. The history has paid their due dates through its last day, so each is next due
  ///   the first time after it.
  /// * Cloud storage, due 2–6 days after the last day: 149 at first, 199 from three months
  ///   before that, 249 from that very due date — a price history, and a change close enough
  ///   for its reminder.
  /// * Music paid for a relative, who gives back 250 of its 299: a payment for somebody else
  ///   with my share of 49.
  /// * Domain and hosting, 48 $ once a year, on the card for foreign money.
  /// * A limit on groceries, with rollover, and one on bad spending, both from the first month
  ///   of the history, sized by what the history spent in its complete months: the mean
  ///   rounded up to a thousand for groceries, down to a thousand for bad spending — a
  ///   tighter wish.
  /// * A website for a client, 40 000 in two parts, due three weeks after the last day; the
  ///   latest side job of the last two months is its prepayment, when the history has one.
  ///
  /// The payments not in the history may be due on its last day itself. Ids come from a
  /// random stream of the planning's own, seeded from the first id the history drew, so they
  /// are as reproducible as the history and take nothing from it. Categories, people and
  /// cards are the set's own, found by what they are rather than by position, so a set whose
  /// system categories the app swapped for its own (the Debug menu does) gives the same rows.
  public init(for set: SampleDataSet) {
    let starter = StarterCategories(set.categories)
    var rng = SeededRandom(seed: Self.seed(starter.id("Groceries")))
    func word(_ english: String, _ russian: String) -> String {
      starter.russian ? russian : english
    }
    let card = set.paymentMethods.first(where: \.isDefault)
    let foreignCard = set.paymentMethods.first { $0.kind == .card && !$0.isDefault } ?? card
    let lastDay = set.lastDay

    var scheduled: [ScheduledPayment] = []
    var prices: [SubscriptionPrice] = []
    scheduled.append(
      ScheduledPayment(
        id: rng.nextUUID(), name: word("Apartment rent", "Аренда квартиры"), kind: .bill,
        amountE4: SampleHistoryWriter.rent, categoryId: starter.id("Rent"),
        paymentMethodId: card?.id, day: SampleHistoryWriter.rentDay,
        nextDate: Self.monthly(day: SampleHistoryWriter.rentDay, after: lastDay),
        remindDaysBefore: 3))
    scheduled.append(
      ScheduledPayment(
        id: rng.nextUUID(), name: word("Mobile plan", "Мобильная связь"), kind: .bill,
        amountE4: SampleHistoryWriter.mobile, categoryId: starter.id("Mobile"),
        paymentMethodId: card?.id, day: SampleHistoryWriter.mobileDay,
        nextDate: Self.monthly(day: SampleHistoryWriter.mobileDay, after: lastDay)))

    let cloudDue = Self.days.adding(days: rng.int(in: 2...6), to: lastDay)
    let cloud = ScheduledPayment(
      id: rng.nextUUID(), name: word("Cloud storage", "Облачное хранилище"),
      kind: .subscription, amountE4: AmountE4(whole: 149), categoryId: starter.id("Cloud"),
      paymentMethodId: card?.id, day: cloudDue.day, nextDate: cloudDue)
    scheduled.append(cloud)
    let raised = cloudDue.monthKey.previous.previous.previous
    prices.append(
      SubscriptionPrice(
        id: rng.nextUUID(), paymentId: cloud.id,
        date: Self.clipped(day: cloudDue.day, in: raised), amountE4: AmountE4(whole: 199)))
    prices.append(
      SubscriptionPrice(
        id: rng.nextUUID(), paymentId: cloud.id, date: cloudDue, amountE4: AmountE4(whole: 249)))

    let relative = set.people.last { $0.relation == .family }
    let musicDay = rng.int(in: 1...28)
    scheduled.append(
      ScheduledPayment(
        id: rng.nextUUID(), name: word("Music subscription", "Подписка на музыку"),
        kind: .subscription, amountE4: AmountE4(whole: 299),
        categoryId: starter.id("Subscriptions & services"), paymentMethodId: card?.id,
        forWhom: relative == nil ? .me : .family, forPersonId: relative?.id,
        reimbursable: relative != nil, debtorPersonId: relative?.id,
        reimbursementAmountE4: relative == nil ? nil : AmountE4(whole: 250),
        reimbursementCurrency: relative == nil ? nil : .rub, day: musicDay,
        nextDate: Self.monthly(day: musicDay, after: lastDay, including: true)))

    let hostingMonth = rng.int(in: 1...12)
    let hostingDay = rng.int(in: 1...28)
    scheduled.append(
      ScheduledPayment(
        id: rng.nextUUID(), name: word("Domain and hosting", "Домен и хостинг"),
        kind: .subscription, amountE4: AmountE4(whole: 48), currency: .usd,
        categoryId: starter.id("Hosting"), paymentMethodId: foreignCard?.id, freq: .yearly,
        day: hostingDay, month: hostingMonth,
        nextDate: Self.yearly(month: hostingMonth, day: hostingDay, onOrAfter: lastDay),
        cancelURL: "https://example.com/cancel"))

    // Limits, sized by the complete months of the history.
    let firstMonth = set.firstDay.monthKey
    var complete: [MonthKey] = []
    var month = firstMonth
    while month < lastDay.monthKey {
      complete.append(month)
      month = month.next
    }
    var budgets: [Budget] = []
    if let groceries = starter.id("Groceries") {
      let mean = Self.mean(complete.map { set.expectations[$0].byRootCategory[groceries] ?? .zero })
      budgets.append(
        Budget(
          id: rng.nextUUID(), scope: .category, categoryId: groceries,
          amountE4: mean.map { Self.thousands($0, up: true) } ?? Self.fallbackGroceriesLimit,
          rollover: true, startMonth: firstMonth))
    }
    let bad = Self.mean(complete.map { set.expectations[$0].byQuality[.bad] ?? .zero })
    budgets.append(
      Budget(
        id: rng.nextUUID(), scope: .badTotal,
        amountE4: bad.map { Self.thousands($0, up: false) } ?? Self.fallbackBadLimit,
        rollover: false, startMonth: firstMonth))

    let sideJobs = starter.id("Side jobs", .income)
    let website = ExpectedIncome(
      id: rng.nextUUID(), name: word("Website for a client", "Сайт для клиента"),
      categoryId: sideJobs, kind: .oneOff, totalE4: Self.expectedTotal,
      dueDate: Self.days.adding(days: 21, to: lastDay), partsExpected: 2)
    var links: [ExpectedIncomeLink] = []
    if let sideJobs, let prepayment = Self.prepayment(in: set.entries, category: sideJobs) {
      links.append(
        ExpectedIncomeLink(
          id: rng.nextUUID(), expectedIncomeId: website.id, transactionId: prepayment))
    }

    self.init(
      scheduled: scheduled, prices: prices, expected: [website], expectedLinks: links,
      budgets: budgets)
  }

  /// The latest live income of the history filed wholly under `category`, in rubles, less
  /// than the expected total and paid within `prepaymentWindowDays` of the last operation.
  /// Instants, not days: the set does not say which time zone its days were cut in. The last
  /// operation may be a deleted one: it still marks the moment the history ends, which is
  /// all the window is measured from.
  private static func prepayment(in entries: [TransactionEntry], category: UUID) -> UUID? {
    guard let latest = entries.last?.transaction.occurredAt else { return nil }
    let since = latest.addingTimeInterval(-TimeInterval(prepaymentWindowDays * 86_400))
    return entries.last { entry in
      let transaction = entry.transaction
      return transaction.kind == .income && !transaction.isDeleted
        && transaction.currency == .rub && transaction.occurredAt >= since
        && transaction.amountRubE4 < expectedTotal && !entry.parts.isEmpty
        && entry.parts.allSatisfy { $0.categoryId == category }
    }?.id
  }

  // MARK: - Days

  /// Plain day arithmetic: a calendar day moves the same in any zone, so UTC does.
  private static let days = CalendarContext.utc

  /// `day` (1…28, so every month has it) of the month of `last` when it falls after `last`
  /// — or on it, `including` — otherwise of the month after.
  static func monthly(day: Int, after last: DateOnly, including: Bool = false) -> DateOnly {
    let candidate = DateOnly(year: last.year, month: last.month, day: day)
    if candidate > last || (including && candidate == last) { return candidate }
    let next = last.monthKey.next
    return DateOnly(year: next.year, month: next.month, day: day)
  }

  /// `day` (1…28) of `month` of the year of `last` when it falls on or after `last`,
  /// otherwise of the year after.
  static func yearly(month: Int, day: Int, onOrAfter last: DateOnly) -> DateOnly {
    let candidate = DateOnly(year: last.year, month: month, day: day)
    return candidate >= last ? candidate : DateOnly(year: last.year + 1, month: month, day: day)
  }

  /// The day of the month, clipped to the length of `month`.
  static func clipped(day: Int, in month: MonthKey) -> DateOnly {
    DateOnly(year: month.year, month: month.month, day: min(day, days.daysInMonth(month)))
  }

  // MARK: - Helpers

  /// The mean of the amounts, rounded down to stored units; `nil` for none.
  static func mean(_ amounts: [AmountE4]) -> AmountE4? {
    guard !amounts.isEmpty else { return nil }
    return AmountE4(raw: AmountE4.sum(amounts).raw / Int64(amounts.count))
  }

  /// Whole thousands of rubles, rounded up or down, and at least one.
  static func thousands(_ amount: AmountE4, up: Bool) -> AmountE4 {
    let step = AmountE4(whole: 1_000).raw
    let count = up ? (amount.raw + step - 1) / step : amount.raw / step
    return AmountE4(raw: max(1, count) * step)
  }

  /// The id of the rent payment, worked out the way `SamplePlanning` works it out.
  ///
  /// The planning is built from a finished history, but the history has to write its rent
  /// with a link to the payment that explains it — the same link «Отметить оплаченным»
  /// writes. Both sides derive the id from the same seed rather than passing it around, and
  /// a test keeps them equal.
  public static func rentPaymentId(categories: [CoreKit.Category]) -> UUID {
    billIds(categories: categories).rent
  }

  /// The id of the mobile plan, the other bill the history pays, worked out the same way.
  public static func mobilePaymentId(categories: [CoreKit.Category]) -> UUID {
    billIds(categories: categories).mobile
  }

  /// The first two draws of the planning's stream: the rent and the mobile plan, the order
  /// `init(for:)` draws them in.
  private static func billIds(categories: [CoreKit.Category]) -> (rent: UUID, mobile: UUID) {
    var rng = SeededRandom(seed: seed(StarterCategories(categories).id("Groceries")))
    let rent = rng.nextUUID()
    return (rent, rng.nextUUID())
  }

  /// A seed of the planning's own: the first eight bytes of `anchor` mixed with a tag, so the
  /// stream is not the history's own continued.
  static func seed(_ anchor: UUID?) -> UInt64 {
    let tag: UInt64 = 0x504C_414E_4E49_4E47  // "PLANNING"
    guard let anchor else { return tag }
    let bytes = anchor.uuid
    let high = [bytes.0, bytes.1, bytes.2, bytes.3, bytes.4, bytes.5, bytes.6, bytes.7]
      .reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
    return high ^ tag
  }
}

/// The sample's own starter categories by their English seed name and kind. Each is found by
/// its name in either language under the parent found before it, so the lookup does not
/// depend on where a category sits in the list, and a subcategory whose parent is gone is
/// not found at all.
struct StarterCategories {
  private struct Key: Hashable {
    let kind: CategoryKind
    let english: String
  }

  private var found: [Key: CoreKit.Category] = [:]
  /// The names are the Russian ones.
  private(set) var russian = false

  init(_ categories: [CoreKit.Category]) {
    for seed in SampleCatalog.categorySeeds {
      let parentId: UUID?
      if let parentEnglish = seed.parentEnglish {
        guard let parent = found[Key(kind: seed.kind, english: parentEnglish)] else { continue }
        parentId = parent.id
      } else {
        parentId = nil
      }
      let match = categories.first { category in
        category.kind == seed.kind && category.parentId == parentId
          && (category.name == seed.english || category.name == seed.russian)
      }
      guard let match else { continue }
      found[Key(kind: seed.kind, english: seed.english)] = match
      if match.name != seed.english { russian = true }
    }
  }

  func id(_ english: String, _ kind: CategoryKind = .expense) -> UUID? {
    found[Key(kind: kind, english: english)]?.id
  }
}
