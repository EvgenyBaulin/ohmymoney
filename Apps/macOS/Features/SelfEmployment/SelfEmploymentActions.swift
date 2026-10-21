import AppCore
import AppDatabase
import Foundation

/// The actions of self-employment: turning it on — with the ready categories «Заработок →
/// Самозанятость → от физлиц (4 %) / от организаций (6 %)» or with the owner's own —, and paying
/// the tax of a month. Each is one `PlanningChange`: one write, one step of ⌘Z. The rules that
/// make a change are static, so a test can read them alone.
@MainActor
struct SelfEmploymentActions {
  let environment: AppEnvironment
  let store: TransactionsStore
  let snapshot: DataSnapshot?
  let deps: AppDependencies

  init(_ deps: AppDependencies) {
    self.deps = deps
    environment = deps.environment
    store = deps.store
    snapshot = deps.compute.snapshot
  }

  /// The names the ready categories are made with, in the language of the interface.
  struct Names: Hashable {
    var earnings: String
    var selfEmployed: String
    var individuals: String
    var organizations: String
    var taxes: String
    var tax: String
    var returns: String

    @MainActor static func of(_ environment: AppEnvironment) -> Names {
      Names(
        earnings: AllocationText.t("selfEmployed.category.earnings", environment),
        selfEmployed: AllocationText.t("selfEmployed.category.selfEmployed", environment),
        individuals: AllocationText.t("selfEmployed.category.individuals", environment),
        organizations: AllocationText.t("selfEmployed.category.organizations", environment),
        taxes: AllocationText.t("selfEmployed.category.taxes", environment),
        tax: AllocationText.t("selfEmployed.category.tax", environment),
        returns: AllocationText.t("selfEmployed.category.returns", environment))
    }
  }

  // MARK: Rules

  private static func same(_ left: String, _ right: String) -> Bool {
    left.trimmingCharacters(in: .whitespaces).lowercased()
      == right.trimmingCharacters(in: .whitespaces).lowercased()
  }

  /// A live category of `kind` under `parent` named `name`, or a new one at the end of them.
  private static func find(
    _ name: String, kind: CategoryKind, parent: UUID?, in categories: [CoreKit.Category],
    made: inout [CoreKit.Category], tax: IncomeTax? = nil
  ) -> UUID {
    let all = categories + made
    if var found = all.first(where: {
      $0.parentId == parent && $0.kind == kind && !$0.archived && same($0.name, name)
    }) {
      if let tax, found.tax != tax {
        found.tax = tax
        made.removeAll { $0.id == found.id }
        made.append(found)
      }
      return found.id
    }
    let sort = (all.filter { $0.parentId == parent && $0.kind == kind }.map(\.sort).max() ?? -1) + 1
    let category = CoreKit.Category(parentId: parent, kind: kind, name: name, sort: sort, tax: tax)
    made.append(category)
    return category.id
  }

  /// The change that turns self-employment on: with `ready`, the categories of income with the
  /// rates of the law (made, or given their rates where they are already), else none — the
  /// owner marks the rates of his own categories. The reference may have been corrected.
  static func enabling(
    ready: Bool, categories: [CoreKit.Category], settings: SelfEmploymentSettings,
    allocation: AllocationSettings, names: Names, at moment: Date
  ) -> PlanningChange {
    var made: [CoreKit.Category] = []
    if ready {
      let reference = settings.reference
      let tree = CategoryTree(categories)
      let earnings =
        Allocation.earningsCategory(tree: tree, categories: categories, settings: allocation)
        ?? find(names.earnings, kind: .income, parent: nil, in: categories, made: &made)
      let selfEmployed = find(
        names.selfEmployed, kind: .income, parent: earnings, in: categories, made: &made)
      _ = find(
        names.individuals, kind: .income, parent: selfEmployed, in: categories, made: &made,
        tax: IncomeTax(rate: reference.individualsRate, npd: true))
      _ = find(
        names.organizations, kind: .income, parent: selfEmployed, in: categories, made: &made,
        tax: IncomeTax(rate: reference.organizationsRate, npd: true))
    }
    var settings = settings
    settings.enabled = true
    settings.offered = true
    var rows = PlanningRows.empty
    rows.categories = made
    return PlanningChange(upsert: rows, settings: settings.storedValues, at: moment)
  }

  /// The category the tax is paid in: the chosen one while it is a live expense category, else a
  /// live one named «Налог самозанятого», else a new one under «Налоги и сборы» (made too when
  /// there is none) — with the rows to write and the settings that remember it.
  static func taxCategory(
    categories: [CoreKit.Category], settings: SelfEmploymentSettings, names: Names
  ) -> (id: UUID, made: [CoreKit.Category], settings: SelfEmploymentSettings) {
    if let chosen = settings.taxCategoryId,
      categories.contains(where: { $0.id == chosen && $0.kind == .expense && !$0.archived })
    {
      return (chosen, [], settings)
    }
    var made: [CoreKit.Category] = []
    var settings = settings
    if let found = categories.first(where: {
      $0.kind == .expense && !$0.archived && same($0.name, names.tax)
    }) {
      settings.taxCategoryId = found.id
      return (found.id, [], settings)
    }
    let taxes = find(names.taxes, kind: .expense, parent: nil, in: categories, made: &made)
    let tax = find(names.tax, kind: .expense, parent: taxes, in: categories, made: &made)
    settings.taxCategoryId = tax
    return (tax, made, settings)
  }

  /// The category a return to a client goes to, made under «Самозанятость» of expenses — or at
  /// the top — the first time, with the settings that remember it.
  static func returnCategory(
    categories: [CoreKit.Category], settings: SelfEmploymentSettings, names: Names
  ) -> (id: UUID, made: [CoreKit.Category], settings: SelfEmploymentSettings) {
    if let chosen = settings.returnCategoryId,
      categories.contains(where: { $0.id == chosen && $0.kind == .expense && !$0.archived })
    {
      return (chosen, [], settings)
    }
    var made: [CoreKit.Category] = []
    var settings = settings
    let parent = find(names.selfEmployed, kind: .expense, parent: nil, in: categories, made: &made)
    let id = find(names.returns, kind: .expense, parent: parent, in: categories, made: &made)
    settings.returnCategoryId = id
    return (id, made, settings)
  }

  /// What the form of a payment starts with: the tax of the earliest month due, else that of
  /// today's month.
  static func prefill(_ npd: NPDState?, today: DateOnly) -> NPDMonth? {
    npd?.nextDue ?? npd?.months.last { $0.month == today.monthKey }
  }

  // MARK: Actions

  /// «Я самозанятый».
  @discardableResult
  func enable(ready: Bool) -> Bool {
    guard let snapshot else { return false }
    let change = Self.enabling(
      ready: ready, categories: snapshot.dataset.categories,
      settings: snapshot.dataset.selfEmployment, allocation: snapshot.dataset.allocationSettings,
      names: .of(environment), at: environment.now())
    guard store.apply(change) else { return false }
    AppLog.info(
      "selfEmployed.enabled", .db, "self-employment was turned on",
      [LogPair("categories", .count(change.upsert.categories.count))])
    environment.refreshVocabulary()
    return true
  }

  /// «Заплатить…»: an expense in the category of the tax with `npd:<month>`, which pays that
  /// month whatever it comes to; the category made in the same record when there is none.
  @discardableResult
  func pay(
    month: MonthKey, amount: AmountE4, from accountId: UUID?, on day: DateOnly
  ) -> Bool {
    pay(key: NPDTax.paymentKey(month: month), amount: amount, from: accountId, on: day)
  }

  /// «Заплатить…» of a quarter of a tax at another rate: the same expense with
  /// `tax:<YYYY>-Q<n>`, which pays that quarter whatever it comes to.
  @discardableResult
  func pay(
    quarter: TaxQuarter, amount: AmountE4, from accountId: UUID?, on day: DateOnly
  ) -> Bool {
    pay(key: quarter.paymentKey, amount: amount, from: accountId, on: day)
  }

  private func pay(
    key: String, amount: AmountE4, from accountId: UUID?, on day: DateOnly
  ) -> Bool {
    guard let snapshot, amount.raw > 0 else { return false }
    let category = Self.taxCategory(
      categories: snapshot.dataset.categories, settings: snapshot.dataset.selfEmployment,
      names: .of(environment))
    let tree = CategoryTree(snapshot.dataset.categories + category.made)
    let decision = QualityResolver.resolve(categoryId: category.id, categories: tree)
    let draft = TransactionDraft(
      kind: .expense, occurredAt: environment.calendar.noon(of: day), currency: .rub,
      amount: amount, paymentMethodId: accountId,
      parts: [
        PartDraft(
          categoryId: category.id, quality: decision.quality, qualitySource: decision.source,
          amount: amount)
      ])
    guard var entry = try? PlanningActions(deps).operation(draft, link: nil) else {
      return false
    }
    entry.transaction.externalId = key
    var rows = PlanningRows.empty
    rows.categories = category.made
    let change = PlanningChange(
      created: [entry], upsert: rows, settings: category.settings.storedValues,
      at: environment.now())
    guard store.apply(change) else { return false }
    AppLog.info(
      "selfEmployed.taxPaid", .db, "a tax of self-employment was paid",
      [LogPair("operation", .id(entry.id))])
    return true
  }
}
