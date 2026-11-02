import AppCore
import AppDatabase
import Foundation
import Observation

/// Asks the main window to open the move from another application. The id makes a second
/// request a new one.
struct MigrationRequest: Identifiable, Equatable {
  let id = UUID()
}

/// What a finished move did, in counts.
struct MigrationOutcome: Equatable {
  var written = 0
  var categoriesMade = 0
  var accounts = 0
}

/// The move from another application: a file in, its columns, its accounts and categories paired
/// with the book's own, a preview, and one write. Nothing is written before `apply()`; the write
/// is preceded by a copy of the database and is one step of ⌘Z. The arithmetic is in `CoreCSV`
/// (`MigrationTableReader`, `MigrationColumnGuesser`, `MigrationRowReader`,
/// `MigrationCategoryMatcher`, `MigrationPlanner`); this class holds the state of the screen and
/// does the reading and the writing.
@MainActor
@Observable
final class MigrationModel {
  /// What the chosen file turned out to be.
  enum FileState: Equatable {
    case none
    case reading
    case table
    case numbers
    case legacyExcel
    case unreadable
  }

  // MARK: State

  private(set) var fileName = ""
  private(set) var fileState: FileState = .none
  private(set) var table: MigrationTable?
  private(set) var usedLegacyEncoding = false
  private(set) var mapping = MigrationMapping()
  private(set) var parse = MigrationParse()
  private(set) var preview = MigrationPreview(dispositions: [])
  /// Positions in `parse.operations` that will be written.
  var ticks: Set<Int> = []
  /// Folded name of the other application's account → own account (`nil`: not moved).
  private(set) var accountMap: [String: UUID?] = [:]
  private(set) var categoryTargets: [String: MigrationCategoryTarget] = [:]
  private(set) var outcome: MigrationOutcome?
  private(set) var isWriting = false

  // MARK: Dependencies

  let environment: AppEnvironment
  let store: TransactionsStore
  private let dataset: () -> Dataset?
  private let now: () -> Date
  /// The copy of the database before the write; `nil` only where there is no copy service (a
  /// test), and then the write goes ahead without one.
  private let backup: (() async throws -> Void)?

  init(
    environment: AppEnvironment, store: TransactionsStore, dataset: @escaping () -> Dataset?,
    now: @escaping () -> Date = Date.init, backup: (() async throws -> Void)? = nil
  ) {
    self.environment = environment
    self.store = store
    self.dataset = dataset
    self.now = now
    if let backup {
      self.backup = backup
    } else if let backups = environment.backups {
      self.backup = { _ = try await backups.writeBackup(label: "before-import") }
    } else {
      self.backup = nil
    }
  }

  // MARK: Reading

  /// Reads a file and opens it already mapped: as the same layout was mapped the last time, or
  /// as the guess says.
  func load(url: URL) async {
    let scoped = url.startAccessingSecurityScopedResource()
    let data = try? Data(contentsOf: url)
    if scoped { url.stopAccessingSecurityScopedResource() }
    await load(data: data ?? Data(), name: url.lastPathComponent)
  }

  func load(data: Data, name: String) async {
    fileName = name
    fileState = .reading
    outcome = nil
    let reading = await Task.detached(priority: .userInitiated) {
      MigrationTableReader.read(data, fileName: name)
    }.value
    switch reading {
    case .table(let table, let legacy):
      self.table = table
      usedLegacyEncoding = legacy
      mapping = rememberedMapping(for: table) ?? MigrationColumnGuesser.guess(table)
      fileState = .table
      accountMap = [:]
      categoryTargets = [:]
      reparse()
    case .numbers:
      clear(.numbers)
    case .legacyExcel:
      clear(.legacyExcel)
    case .unreadable:
      clear(.unreadable)
    }
  }

  private func clear(_ state: FileState) {
    table = nil
    parse = MigrationParse()
    preview = MigrationPreview(dispositions: [])
    ticks = []
    fileState = state
  }

  private func rememberedMapping(for table: MigrationTable) -> MigrationMapping? {
    let text = (try? environment.settings?.string(MigrationSettings.mappingsKey)) ?? nil
    guard let mapping = MigrationSettings.mappings(from: text)[table.signature],
      mapping.roles.keys.allSatisfy({ $0 < table.header.count })
    else { return nil }
    return mapping
  }

  // MARK: Columns

  func setRole(_ role: MigrationRole?, column: Int) {
    mapping.assign(role, to: column)
    reparse()
  }

  func setDateOrder(_ order: MigrationDates.Order) {
    mapping.dateOrder = order
    reparse()
  }

  /// Reads the rows again under the mapping, keeps what was already paired, pairs what is new.
  private func reparse() {
    guard let table else { return }
    parse =
      mapping.isComplete ? MigrationRowReader.read(table, mapping: mapping) : MigrationParse()
    pairAccounts()
    pairCategories()
    rebuildPreview()
  }

  // MARK: Accounts

  /// The accounts the history can go to: open ones, and of the hidden ones only while they are
  /// shown.
  var accounts: [PaymentMethod] {
    let covered = environment.shield.covering.ids
    return (dataset()?.paymentMethods ?? []).filter { !$0.archived && !covered.contains($0.id) }
  }

  func account(for name: String) -> UUID? {
    accountMap[NameKey.fold(name)] ?? nil
  }

  func setAccount(_ id: UUID?, for name: String) {
    accountMap[NameKey.fold(name)] = .some(id)
    rebuildPreview()
  }

  /// Each new account name: the own account it went to the last time, else an own account of
  /// the same name, else the main account (the first one when none is main).
  private func pairAccounts() {
    let open = accounts
    let ids = Set(open.map(\.id))
    let remembered = MigrationSettings.ids(
      from: (try? environment.settings?.string(MigrationSettings.accountMapKey)) ?? nil)
    let fallback = open.first(where: \.isDefault)?.id ?? open.first?.id
    for name in parse.accountNames {
      let key = NameKey.fold(name)
      guard accountMap[key] == nil else { continue }
      if let id = remembered[key], ids.contains(id) {
        accountMap[key] = .some(id)
      } else if let same = open.first(where: { NameKey.fold($0.name) == key }) {
        accountMap[key] = .some(same.id)
      } else {
        accountMap[key] = .some(fallback)
      }
    }
  }

  // MARK: Categories

  func target(for key: MigrationCategoryKey) -> MigrationCategoryTarget {
    categoryTargets[key.id] ?? .unsorted
  }

  func setTarget(_ target: MigrationCategoryTarget, for key: MigrationCategoryKey) {
    categoryTargets[key.id] = target
  }

  /// The categories nothing was found for: what «Создать все» would make.
  var unmatchedCategories: [MigrationCategoryKey] {
    parse.categories.filter { target(for: $0) == .unsorted }
  }

  /// «Создать недостающие»: every category left to «Не разобрано» is made under its own name.
  func createAllUnmatched() {
    for key in unmatchedCategories { categoryTargets[key.id] = .create }
  }

  /// Own categories of a kind for the picker, «Родитель / Дочерняя» for a subcategory; system
  /// ones are not offered.
  func categoryChoices(_ kind: CategoryKind) -> [(id: UUID, title: String)] {
    let all = (dataset()?.categories ?? []).filter { !$0.archived && $0.systemRole == nil }
    let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    return all.filter { $0.kind == kind }
      .map { category in
        let parent = category.parentId.flatMap { byID[$0]?.name }
        return (category.id, parent.map { $0 + " / " + category.name } ?? category.name)
      }
      .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
  }

  private func pairCategories() {
    let fresh = parse.categories.filter { categoryTargets[$0.id] == nil }
    guard !fresh.isEmpty else { return }
    let remembered = MigrationSettings.ids(
      from: (try? environment.settings?.string(MigrationSettings.categoryMapKey)) ?? nil)
    let suggested = MigrationCategoryMatcher.suggest(
      fresh, categories: dataset()?.categories ?? [], remembered: remembered)
    for (id, target) in suggested { categoryTargets[id] = target }
  }

  // MARK: Preview

  private func rates() -> RateTable { (try? environment.rates?.table()) ?? RateTable() }

  private func rubles(_ table: RateTable) -> (ImportedOperation) -> StatementRubles? {
    { operation in
      StatementRubleResolver.resolve(operation) { currency, day in
        table.resolve(currency, on: day).map { ($0.rate.perUnit, $0.isProvisional) }
      }
    }
  }

  private func rebuildPreview() {
    let imports = environment.statementImports
    let period = parse.period
    let resolve = rubles(rates())
    preview = MigrationPlanner.preview(
      parse, account: { [accountMap] in accountMap[NameKey.fold($0)] ?? nil },
      existing: { (try? imports?.existing(account: $0)) ?? [] },
      manual: { id in
        guard let period else { return [] }
        return
          (try? imports?.manualEntries(
            account: id, from: Self.shift(period.from, by: -3), to: Self.shift(period.to, by: 3)))
          ?? []
      },
      hasRate: { resolve($0) != nil })
    ticks = preview.defaultTicks.filter {
      account(for: parse.operations[$0].operation.accountRef) != nil
    }
  }

  nonisolated static func shift(_ day: DateOnly, by days: Int) -> DateOnly {
    StatementImportModel.shift(day, by: days)
  }

  /// The likely duplicates go in too (or stay out again).
  func includeLikelyDuplicates(_ on: Bool) {
    for index in preview.dispositions.indices where preview.dispositions[index] == .likelyDuplicate
    {
      if on { ticks.insert(index) } else { ticks.remove(index) }
    }
  }

  var includesLikelyDuplicates: Bool {
    let likely = preview.dispositions.indices.filter {
      preview.dispositions[$0] == .likelyDuplicate
    }
    return !likely.isEmpty && likely.allSatisfy(ticks.contains)
  }

  /// How many lines a write would make now.
  var toWrite: Int {
    ticks.filter { index in
      preview.dispositions.indices.contains(index)
        && preview.dispositions[index] != .waitingForRate
        && account(for: parse.operations[index].operation.accountRef) != nil
    }.count
  }

  var canApply: Bool {
    fileState == .table && mapping.isComplete && toWrite > 0 && !isWriting && outcome == nil
  }

  // MARK: Writing

  /// Copies the database, then writes the ticked lines with the new categories and what to
  /// remember in one step of ⌘Z. A copy that fails stops the move: the state before it must be
  /// on disk first.
  @discardableResult
  func apply() async -> Bool {
    guard canApply, let dataset = dataset() else { return false }
    isWriting = true
    defer { isWriting = false }
    if let backup {
      do {
        try await backup()
      } catch {
        AppLog.error("migration.backupFailed", .db, "the copy before a move failed", [])
        return false
      }
    }
    let stamp = now()
    let unsorted = UnsortedCategories(environment: environment, categories: dataset.categories)
    let plan = MigrationCategoryPlan.resolve(
      parse.categories, targets: categoryTargets, categories: dataset.categories,
      unsorted: { unsorted.id(for: $0) })
    let tree = CategoryTree(dataset.categories + plan.made + unsorted.made)
    let map = accountMap
    let write = MigrationPlanner.write(
      parse, ticks: ticks, fileName: fileName,
      account: { map[NameKey.fold($0)] ?? nil },
      category: { key, kind in key.flatMap { plan.ids[$0.id] } ?? unsorted.id(for: kind) },
      quality: { id in
        id.flatMap { QualityResolver.resolve(categoryId: $0, categories: tree).quality }
      },
      rubles: rubles(rates()), zoneID: TravelDay.moscowId, now: stamp)
    guard !write.entries.isEmpty else { return false }
    // Only the categories the written lines use are made.
    let used = Set(write.entries.flatMap { $0.parts.compactMap(\.categoryId) })
    var made = plan.made + unsorted.made
    let parents = Set(made.filter { used.contains($0.id) }.compactMap(\.parentId))
    made = made.filter { used.contains($0.id) || parents.contains($0.id) }
    var change = PlanningChange(created: write.entries, at: stamp)
    change.upsert.categories = made
    change.settings = unsorted.settings.filter { key, _ in
      made.contains { $0.id.uuidString == unsorted.settings[key] ?? nil }
    }
    for (key, value) in remembered(plan: plan) { change.settings[key] = value }
    guard store.applyMigration(change, imports: write.imports) else { return false }
    outcome = MigrationOutcome(
      written: write.entries.count, categoriesMade: made.count, accounts: write.imports.count)
    AppLog.info(
      "migration.applied", .db, "history from another application was moved in",
      [
        LogPair("operations", .count(write.entries.count)),
        LogPair("categories", .count(made.count)), LogPair("accounts", .count(write.imports.count)),
      ])
    return true
  }

  /// The mapping of this layout, the categories and the accounts, merged into what was
  /// remembered before.
  private func remembered(plan: MigrationCategoryPlan) -> [String: String?] {
    let settings = environment.settings
    var mappings = MigrationSettings.mappings(
      from: (try? settings?.string(MigrationSettings.mappingsKey)) ?? nil)
    if let table { mappings[table.signature] = mapping }
    var categories = MigrationSettings.ids(
      from: (try? settings?.string(MigrationSettings.categoryMapKey)) ?? nil)
    for key in parse.categories {
      if case .existing(let id) = target(for: key) { categories[key.id] = id }
      if case .create = target(for: key), let id = plan.ids[key.id] { categories[key.id] = id }
    }
    var accounts = MigrationSettings.ids(
      from: (try? settings?.string(MigrationSettings.accountMapKey)) ?? nil)
    for (key, id) in accountMap { if let id { accounts[key] = id } }
    return [
      MigrationSettings.mappingsKey: MigrationSettings.text(mappings),
      MigrationSettings.categoryMapKey: MigrationSettings.text(categories),
      MigrationSettings.accountMapKey: MigrationSettings.text(accounts),
    ]
  }
}

/// «Не разобрано» of each kind: the one the loading of statements already uses, or one to make.
@MainActor
private final class UnsortedCategories {
  private(set) var made: [CoreKit.Category] = []
  private(set) var settings: [String: String?] = [:]
  private var ids: [CategoryKind: UUID] = [:]
  private let environment: AppEnvironment
  private let categories: [CoreKit.Category]

  init(environment: AppEnvironment, categories: [CoreKit.Category]) {
    self.environment = environment
    self.categories = categories
  }

  func id(for kind: CategoryKind) -> UUID {
    if let id = ids[kind] { return id }
    let key =
      kind == .income ? ImportSettings.unsortedIncomeKey : StatementSettings.unsortedCategoryKey
    if let text = (try? environment.settings?.string(key)) ?? nil, let id = UUID(uuidString: text),
      categories.contains(where: { $0.id == id && !$0.archived && $0.kind == kind })
    {
      ids[kind] = id
      return id
    }
    let name = environment.language("import.unsorted", table: ImportText.table)
    let category = CoreKit.Category(kind: kind, name: name, sort: 9_000)
    made.append(category)
    settings[key] = category.id.uuidString
    ids[kind] = category.id
    return category.id
  }
}
