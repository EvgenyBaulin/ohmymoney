import CoreKit
import Foundation

/// Settings the calculations read. They live in the `settings` table; the app passes them in.
public struct AnalyticsSettings: Hashable, Sendable, Codable {
  /// The key `cashbackCategoryId` is stored under in the `settings` table; its value is the
  /// id of the category as text. Part of the data, so the Windows port reads the same key.
  public static let cashbackCategoryKey = "analytics.cashbackCategoryId"

  /// The key the sensitivity of the anomaly rules is stored under. One setting for all
  /// seven rules.
  public static let anomalySensitivityKey = "analytics.anomalySensitivity"

  /// The income category whose money is cashback (`analytics.cashbackCategoryId`). Its
  /// subcategories count too.
  public var cashbackCategoryId: UUID?
  public var anomalySensitivity: AnomalySensitivity

  public init(
    cashbackCategoryId: UUID? = nil, anomalySensitivity: AnomalySensitivity = .standard
  ) {
    self.cashbackCategoryId = cashbackCategoryId
    self.anomalySensitivity = anomalySensitivity
  }
}

/// One consistent snapshot of everything the numbers are made of.
///
/// Reference books come **with** their archived rows and debts **with** the closed ones:
/// closing a loan must not drop its payments out of past months, and archiving a category
/// must not tear its subcategories off their parent. Archived values are only hidden in
/// pickers and filters; reports show them marked «(archive)».
///
/// Deleted operations may be present — the calculations skip them — so the app can lay
/// its own writes over the snapshot (`upserting`, `removing`) without a reload.
public struct Dataset: Sendable {
  public var entries: [TransactionEntry]
  public var links: [ReimbursementLink]
  public var categories: [CoreKit.Category]
  public var people: [Person]
  public var places: [Place]
  public var events: [Event]
  public var paymentMethods: [PaymentMethod]
  /// The debts the owner has, closed ones included; deleted ones are in `deletedDebts`.
  public var debts: [Debt]
  public var goals: [Goal]
  /// Scheduled payments, expected income, limits, reconciliations and debt journals.
  public var planning: PlanningBook
  /// «Это нормально» on an anomaly (`anomaly_dismissals`).
  public var dismissals: [AnomalyDismissal]
  /// The owner's choices of a category against what the model offered (`category_feedback`),
  /// oldest first.
  public var feedback: [CategoryFeedback]
  public var settings: AnalyticsSettings
  /// Money moved between accounts, oldest first: never income, never spending.
  public var transfers: [Transfer]
  /// The groups of the accounts, archived ones included, in the owner's order.
  public var accountGroups: [AccountGroup]
  /// The default currency and the state of the setup of the accounts.
  public var accountSettings: AccountSettings
  /// Grows with every change, so a result cached for one version is never shown for another.
  public var version: Int
  /// The cards of the accounts, archived ones included, in the owner's order.
  public var cards: [PaymentCard]
  /// The cashback rules of the cards and of the accounts without cards.
  public var cashbackRules: [CashbackRule]
  /// The debts the owner deleted: gone from every list and figure of the debts, still there
  /// for the operations that point at them (`debtsById`).
  public var deletedDebts: [Debt]
  /// The banks the accounts are filed under, archived ones included, in the owner's order.
  public var banks: [Bank]
  /// The things valued by hand, disposed ones included, in the owner's order.
  public var assets: [Asset]
  /// Every valuation of every asset, by asset and then by day.
  public var assetValuations: [AssetValuation]
  /// The safety cushion's goal and how its obligatory spending is taken.
  public var capitalSettings: CapitalSettings
  /// The trip mode: the trip the entry takes its defaults from, and the one waiting for its card.
  public var tripSettings: TripSettings
  /// The sums of dues typed from a bank's app, by debt and then from the first due.
  public var debtInstalments: [DebtInstalmentStep]
  /// What else the loans cost, by debt in the owner's order.
  public var debtCosts: [DebtCost]
  /// How the owner usually allocates an income, in the owner's order.
  public var allocationRules: [AllocationRule]
  /// The currencies outside the Bank of Russia list, archived ones included, in the owner's
  /// order.
  public var customCurrencies: [CustomCurrency]
  /// Self-employment and the tax on professional income.
  public var selfEmployment: SelfEmploymentSettings
  /// What the allocation of income remembers.
  public var allocationSettings: AllocationSettings
  /// The payoff ladder, the reminder to a debtor, the interest of credit cards.
  public var debtSettings: DebtSettings

  public init(
    entries: [TransactionEntry] = [],
    links: [ReimbursementLink] = [],
    categories: [CoreKit.Category] = [],
    people: [Person] = [],
    places: [Place] = [],
    events: [Event] = [],
    paymentMethods: [PaymentMethod] = [],
    debts: [Debt] = [],
    goals: [Goal] = [],
    planning: PlanningBook = .empty,
    dismissals: [AnomalyDismissal] = [],
    feedback: [CategoryFeedback] = [],
    settings: AnalyticsSettings = AnalyticsSettings(),
    transfers: [Transfer] = [],
    accountGroups: [AccountGroup] = [],
    accountSettings: AccountSettings = AccountSettings(storedValues: [:]),
    version: Int = 0,
    cards: [PaymentCard] = [],
    cashbackRules: [CashbackRule] = [],
    deletedDebts: [Debt] = [],
    banks: [Bank] = [],
    assets: [Asset] = [],
    assetValuations: [AssetValuation] = [],
    capitalSettings: CapitalSettings = .standard,
    tripSettings: TripSettings = .off,
    debtInstalments: [DebtInstalmentStep] = [],
    debtCosts: [DebtCost] = [],
    allocationRules: [AllocationRule] = [],
    customCurrencies: [CustomCurrency] = [],
    selfEmployment: SelfEmploymentSettings = .standard,
    allocationSettings: AllocationSettings = .standard,
    debtSettings: DebtSettings = .standard
  ) {
    self.entries = entries
    self.links = links
    self.categories = categories
    self.people = people
    self.places = places
    self.events = events
    self.paymentMethods = paymentMethods
    self.debts = debts
    self.goals = goals
    self.planning = planning
    self.dismissals = dismissals
    self.feedback = feedback
    self.settings = settings
    self.transfers = transfers
    self.accountGroups = accountGroups
    self.accountSettings = accountSettings
    self.version = version
    self.cards = cards
    self.cashbackRules = cashbackRules
    self.deletedDebts = deletedDebts
    self.banks = banks
    self.assets = assets
    self.assetValuations = assetValuations
    self.capitalSettings = capitalSettings
    self.tripSettings = tripSettings
    self.debtInstalments = debtInstalments
    self.debtCosts = debtCosts
    self.allocationRules = allocationRules
    self.customCurrencies = customCurrencies
    self.selfEmployment = selfEmployment
    self.allocationSettings = allocationSettings
    self.debtSettings = debtSettings
  }

  public static let empty = Dataset()

  /// The snapshot with these operations written over it: an operation with the same id is
  /// replaced, a new one is added. The version moves on.
  public func upserting(_ written: [TransactionEntry]) -> Dataset {
    guard !written.isEmpty else { return self }
    var copy = self
    var index: [UUID: Int] = [:]
    for (position, entry) in copy.entries.enumerated() { index[entry.id] = position }
    for entry in written {
      if let position = index[entry.id] {
        copy.entries[position] = entry
      } else {
        index[entry.id] = copy.entries.count
        copy.entries.append(entry)
      }
    }
    copy.version &+= 1
    return copy
  }

  /// The snapshot without these operations. Their reimbursement links stay: a link counts
  /// only while both of its operations are alive, so it simply stops counting.
  public func removing(_ ids: some Sequence<UUID>) -> Dataset {
    let gone = Set(ids)
    guard !gone.isEmpty else { return self }
    var copy = self
    copy.entries.removeAll { gone.contains($0.id) }
    copy.version &+= 1
    return copy
  }

  /// Every debt an operation or a journal line may name, deleted ones included: a payment of
  /// a deleted debt still counts as it did.
  public var debtsById: [UUID: Debt] {
    Dictionary(
      (debts + deletedDebts).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
  }
}
