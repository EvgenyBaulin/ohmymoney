import CoreKit
import Foundation

/// Everything the sample generator produces in one run: the starter category tree, the
/// dictionaries, a plausible history built on top of them, and the answers that history is
/// known to have. The Debug menu, the analytics tests, the performance suite and README
/// screenshots all consume this same shape.
public struct SampleDataSet: Sendable {
  public var categories: [CoreKit.Category]
  public var people: [Person]
  public var places: [Place]
  public var paymentMethods: [PaymentMethod]
  public var events: [Event]
  public var templates: [Template]
  public var goals: [Goal]
  public var debts: [Debt]
  /// The journals of the debts: the opening lines and one line per payment.
  public var debtEntries: [DebtEntry]
  /// Oldest first. A few are soft-deleted, the way the app deletes.
  public var entries: [TransactionEntry]
  /// The links of the reimbursements to the parts they closed, in rubles.
  public var links: [ReimbursementLink]
  /// The income category whose money is cashback — what `analytics.cashbackCategoryId`
  /// points at.
  public var cashbackCategoryId: UUID
  /// The first and the last day of the history.
  public var firstDay: DateOnly
  public var lastDay: DateOnly
  public var expectations: SampleExpectations

  // What the accounts add (`withAccounts`); the history alone leaves all of it empty.

  /// The groups the accounts are filed under.
  public var accountGroups: [AccountGroup] = []
  /// Money moved between the accounts, oldest first.
  public var transfers: [Transfer] = []
  /// The counts of the accounts, oldest first, and the balances each counted, in that order.
  public var reconciliations: [Reconciliation] = []
  public var reconciledBalances: [ReconciledBalance] = []
  /// Settings the rows point at or depend on, by their keys in the `settings` table.
  public var settings: [String: String] = [:]
  /// Scheduled payments due once, added to the planning (`SampleDataSet.planning`).
  public var oneOffPayments: [ScheduledPayment] = []
  /// The money on every account and currency once the whole history has happened, as the
  /// accounts layer kept it while it wrote — never read back through a rule of the app.
  public var accountExpectations: [BalanceKey: AmountE4] = [:]
  /// The cards of the accounts, and the cashback rules on them; none unless a layer adds them.
  public var cards: [PaymentCard] = []
  public var cashbackRules: [CashbackRule] = []
  /// The banks the accounts are filed under (`assigningBanks`); none until they are.
  public var banks: [Bank] = []
  /// Income expected on top of what the planning of the history expects
  /// (`SampleDataSet.planning`); none unless a layer adds it.
  public var addedExpectedIncome: [ExpectedIncome] = []
  /// The things valued by hand and their valuations, oldest first for each; none unless a layer
  /// adds them (`withCapitalLayer`).
  public var assets: [Asset] = []
  public var assetValuations: [AssetValuation] = []
  /// What else the loans cost, and the sums of dues typed from a bank's app; none unless a layer
  /// adds them (`withCreditLayer`).
  public var debtCosts: [DebtCost] = []
  public var debtInstalments: [DebtInstalmentStep] = []
  /// How the owner allocates an income; none unless a layer adds them (`withAllocationLayer`).
  public var allocationRules: [AllocationRule] = []
  /// Currencies outside the Bank of Russia list and their rates typed by hand (`manual`), oldest
  /// first; none unless a layer adds them (`withAllocationLayer`).
  public var customCurrencies: [CustomCurrency] = []
  public var rates: [Rate] = []

  public init(
    categories: [CoreKit.Category],
    people: [Person],
    places: [Place],
    paymentMethods: [PaymentMethod],
    events: [Event],
    templates: [Template],
    goals: [Goal],
    debts: [Debt],
    debtEntries: [DebtEntry],
    entries: [TransactionEntry],
    links: [ReimbursementLink],
    cashbackCategoryId: UUID,
    firstDay: DateOnly,
    lastDay: DateOnly,
    expectations: SampleExpectations
  ) {
    self.categories = categories
    self.people = people
    self.places = places
    self.paymentMethods = paymentMethods
    self.events = events
    self.templates = templates
    self.goals = goals
    self.debts = debts
    self.debtEntries = debtEntries
    self.entries = entries
    self.links = links
    self.cashbackCategoryId = cashbackCategoryId
    self.firstDay = firstDay
    self.lastDay = lastDay
    self.expectations = expectations
  }
}

/// Builds a plausible, entirely fictional history from a fixed seed, so the same seed always
/// reproduces the same dataset byte for byte: no real names, no real places and nothing from
/// the owner's own data ever needs to touch a test, the Debug menu or a screenshot.
///
/// The history carries every case the analytics have a rule for: bad spending —
/// fines, fees, bars I rated bad by hand; a second part of a split with no stored quality,
/// one of them in Other → Fees; purchases for my partner, my family and particular people;
/// parts paid for friends that come back — exactly, with a surplus, short, several at once
/// — are written off or still wait, with the reimbursement, its links and its surplus and
/// shortfall written the way the app's reimbursement sheet writes them; a part in dollars
/// paid for a friend abroad; a refund of a bad purchase, and one of a ticket bought for a
/// friend, which takes nothing off my spending; cashback on two cards; salary paid on the
/// 1st–3rd for the month before; a loan whose payments are expenses and a phone bought in
/// instalments whose payments are not; goal contributions; birthdays and New Year every
/// year in one series; 1 % of parts without a category; 0.5 % of all operations deleted,
/// at any density. Next to the data it returns `SampleExpectations`, the known answers.
public struct SampleDataGenerator: Sendable {
  private let seed: UInt64

  public init(seed: UInt64) {
    self.seed = seed
  }

  /// The large set of the performance suite and of `make sample-large`: at this density 24
  /// months come to about 20 000 operations.
  public static let largeSetMonths = 24
  public static let largeSetDensity = 15

  /// Generates `months` calendar months of history, from the 1st of the starting month
  /// through `endingOn` inclusive, in the given interface language ("en" or "ru").
  ///
  /// `density` is how many times a day the everyday life of the history — shopping, coffee,
  /// the odd fine or dinner with friends — is lived: 1 gives about 70 operations a month,
  /// `largeSetDensity` about 870. Salary, rent, the loan and the other monthly operations
  /// stay monthly whatever the density.
  ///
  /// `now` is the moment a set ending today is made (the Debug menu, `--generate`): the
  /// last day's operations then all fall before it, the way a day lived so far would, so an
  /// operation typed right after is the latest one. Without it the day is lived whole.
  public func generate(
    months: Int,
    endingOn: DateOnly,
    now: Date? = nil,
    calendar: CalendarContext,
    language: String,
    density: Int = 1
  ) -> SampleDataSet {
    precondition(months > 0, "sample history needs at least one month")
    precondition(density > 0, "sample history needs a positive density")
    var startMonth = endingOn.monthKey
    for _ in 1..<months { startMonth = startMonth.previous }
    let writer = SampleHistoryWriter(
      seed: seed, firstDay: startMonth.firstDay, lastDay: endingOn, now: now,
      calendar: calendar, language: language, density: density)
    return writer.write()
  }
}
