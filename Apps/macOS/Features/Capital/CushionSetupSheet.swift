import AppCore
import AppDatabase
import SwiftUI

/// What the cushion is made of, as the sheet holds it until «Сохранить»: the accounts whose
/// money is the cushion and the expense categories that are essential spending. A category's
/// mark is the one it counts with — its own, or its parent's when it has none.
struct CushionSetup: Equatable {
  /// The categories offered on a first setup, by name in either language: those that exist
  /// are ticked, nothing is written until the owner saves.
  static let suggestedNames = [
    "Продукты", "ЖКХ", "Коммунальные услуги", "Связь", "Мобильная связь", "Транспорт",
    "Здоровье", "Аренда", "Groceries", "Utilities", "Mobile", "Phone", "Transport", "Health",
    "Rent",
  ]

  /// The live accounts offered, in the order of every list.
  let accounts: [PaymentMethod]
  /// The live expense categories the owner may mark: roots, each followed by its children.
  let categories: [CoreKit.Category]
  var cushionAccounts: Set<UUID>
  var essential: Set<UUID>
  /// The categories were ticked by their names, not by what is stored: no category of the
  /// book was ever marked or unmarked.
  let suggested: Bool

  private let tree: CategoryTree
  private let stored: [UUID: CoreKit.Category]
  private let storedAccounts: [UUID: PaymentMethod]

  /// `accounts` and `categories` as the database has them, archived included.
  init(accounts: [PaymentMethod], categories all: [CoreKit.Category]) {
    let tree = CategoryTree(all)
    self.tree = tree
    let live = accounts.filter { !$0.archived }
    self.accounts = live
    storedAccounts = Dictionary(uniqueKeysWithValues: live.map { ($0.id, $0) })
    let offered = all.filter {
      $0.kind == .expense && !$0.archived && tree.systemRole(of: $0.id) == nil
    }
    let ordered = { (rows: [CoreKit.Category]) in
      rows.sorted { ($0.sort, $0.name) < ($1.sort, $1.name) }
    }
    let roots = ordered(offered.filter { $0.parentId == nil })
    var listed: [CoreKit.Category] = []
    for root in roots {
      listed.append(root)
      listed.append(contentsOf: ordered(offered.filter { $0.parentId == root.id }))
    }
    categories = listed
    stored = Dictionary(uniqueKeysWithValues: listed.map { ($0.id, $0) })
    cushionAccounts = Set(live.filter(\.cushion).map(\.id))
    let neverMarked = !all.contains { $0.essential != nil }
    suggested = neverMarked
    essential =
      neverMarked
      ? Self.suggested(in: listed, tree: tree)
      : Set(listed.filter { tree.isEssential($0.id) }.map(\.id))
  }

  /// The categories whose names are among `suggestedNames`, with their children.
  static func suggested(in categories: [CoreKit.Category], tree: CategoryTree) -> Set<UUID> {
    let names = Set(suggestedNames.map(NameKey.fold))
    let named = categories.filter { names.contains(NameKey.fold($0.name)) }.map(\.id)
    var result = Set(named)
    for id in named {
      for child in categories where child.parentId == id { result.insert(child.id) }
    }
    return result
  }

  func isChild(_ category: CoreKit.Category) -> Bool { category.parentId != nil }

  /// A category ticked or unticked; its children follow it.
  mutating func set(_ id: UUID, essential on: Bool) {
    let ids = [id] + categories.filter { $0.parentId == id }.map(\.id)
    for id in ids {
      if on { essential.insert(id) } else { essential.remove(id) }
    }
  }

  mutating func set(account id: UUID, cushion on: Bool) {
    if on { cushionAccounts.insert(id) } else { cushionAccounts.remove(id) }
  }

  /// The value to store so that a category counts as `desired`: what is stored stays when it
  /// already counts so; otherwise nothing when the parent gives the same, else the value.
  static func storedValue(stored: Bool?, desired: Bool, inherited: Bool) -> Bool? {
    if (stored ?? inherited) == desired { return stored }
    return desired == inherited ? nil : desired
  }

  /// The accounts whose mark changed, as they will be written.
  var changedAccounts: [PaymentMethod] {
    accounts.compactMap { account in
      let on = cushionAccounts.contains(account.id)
      guard on != account.cushion, var row = storedAccounts[account.id] else { return nil }
      row.cushion = on
      return row
    }
  }

  /// The categories whose stored mark changed, as they will be written.
  var changedCategories: [CoreKit.Category] {
    categories.compactMap { category in
      let desired = essential.contains(category.id)
      let inherited =
        category.parentId.map { parent in
          stored[parent] != nil ? essential.contains(parent) : tree.isEssential(parent)
        } ?? false
      let value = Self.storedValue(
        stored: category.essential, desired: desired, inherited: inherited)
      guard value != category.essential, var row = stored[category.id] else { return nil }
      row.essential = value
      return row
    }
  }

  /// One write and one step of ⌘Z for everything changed; `nil` when nothing did.
  func change(at now: Date) -> PlanningChange? {
    let accounts = changedAccounts
    let categories = changedCategories
    guard !accounts.isEmpty || !categories.isEmpty else { return nil }
    return PlanningChange(
      upsert: PlanningRows(categories: categories, paymentMethods: accounts), at: now)
  }
}

/// «Счета и категории подушки»: which accounts hold the cushion, and which expense categories
/// are spending that cannot stop. A first setup ticks the usual essential categories that
/// exist; nothing is written before «Сохранить», and the whole of it is one step of ⌘Z.
struct CushionSetupSheet: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.store) private var store

  let finish: () -> Void

  @State private var setup: CushionSetup?
  @State private var failed = false

  private func t(_ key: String) -> String { CushionText.t(key, environment) }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(verbatim: t("cushion.setup.title"))
        .appFont(.headline)
      if let setup {
        form(setup)
      } else {
        Spacer()
      }
      HStack {
        Spacer()
        Button(environment.language("action.cancel"), role: .cancel) { finish() }
          .keyboardShortcut(.cancelAction)
        Button(environment.language("action.save"), action: save)
          .keyboardShortcut(.defaultAction)
          .buttonStyle(.borderedProminent)
          .disabled(setup == nil || store.isWritingInBackground)
          .accessibilityIdentifier("cushion.setup.save")
      }
    }
    .padding(20)
    .sheetFrame(width: 480)
    .frame(minHeight: 420, idealHeight: 600, maxHeight: 700)
    .task { load() }
    .refusedWriteAlert($failed, environment)
  }

  private func form(_ setup: CushionSetup) -> some View {
    Form {
      Section {
        if setup.accounts.isEmpty {
          Text(verbatim: t("cushion.setup.noAccounts")).foregroundStyle(.secondary)
        }
        ForEach(setup.accounts, id: \.id) { account in
          Toggle(
            isOn: Binding(
              get: { self.setup?.cushionAccounts.contains(account.id) ?? false },
              set: { self.setup?.set(account: account.id, cushion: $0) })
          ) {
            Text(verbatim: account.name)
          }
          .toggleStyle(.checkbox)
        }
      } header: {
        Text(verbatim: t("cushion.setup.accounts"))
      } footer: {
        Text(verbatim: t("cushion.setup.accountsHint")).foregroundStyle(.secondary)
      }
      Section {
        if setup.categories.isEmpty {
          Text(verbatim: t("cushion.setup.noCategories")).foregroundStyle(.secondary)
        }
        ForEach(setup.categories, id: \.id) { category in
          Toggle(
            isOn: Binding(
              get: { self.setup?.essential.contains(category.id) ?? false },
              set: { self.setup?.set(category.id, essential: $0) })
          ) {
            Text(verbatim: category.name)
              .fontWeight(setup.isChild(category) ? .regular : .semibold)
          }
          .toggleStyle(.checkbox)
          .padding(.leading, setup.isChild(category) ? 18 : 0)
        }
      } header: {
        Text(verbatim: t("cushion.setup.essential"))
      } footer: {
        VStack(alignment: .leading, spacing: 4) {
          Text(verbatim: t("cushion.setup.essentialHint"))
          if setup.suggested {
            Text(verbatim: t("cushion.setup.suggested"))
          }
        }
        .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
  }

  private func load() {
    guard setup == nil else { return }
    let accounts = (try? environment.accounts?.accounts(includeArchived: true)) ?? []
    let categories = (try? environment.references?.categories(includeArchived: true)) ?? []
    setup = CushionSetup(
      accounts: AccountRules.ordered(
        accounts, locale: environment.language.locale, includeArchived: true),
      categories: categories)
  }

  private func save() {
    guard let setup else { return }
    if Self.save(setup, store: store, now: environment.now()) {
      finish()
    } else {
      failed = true
    }
  }

  /// Writes what changed as one step of ⌘Z and says so in the journal; nothing changed is
  /// nothing written. Returns whether the sheet may close.
  static func save(_ setup: CushionSetup, store: TransactionsStore, now: Date) -> Bool {
    guard let change = setup.change(at: now) else { return true }
    guard store.apply(change) else { return false }
    if !change.upsert.paymentMethods.isEmpty {
      AppLog.info(
        "cushion.accounts.changed", .db, "the accounts of the safety cushion changed",
        [
          LogPair("accounts", .count(change.upsert.paymentMethods.count)),
          LogPair("cushion", .count(setup.cushionAccounts.count)),
        ])
    }
    if !change.upsert.categories.isEmpty {
      AppLog.info(
        "cushion.essential.set", .db, "the essential categories changed",
        [LogPair("categories", .count(change.upsert.categories.count))])
    }
    return true
  }
}
