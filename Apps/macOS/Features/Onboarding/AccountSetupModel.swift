import AppCore
import AppDatabase
import Foundation

/// The setup of the accounts as the owner fills it in: which accounts there are, what each
/// holds and how much is on it now, the groups, the main account — and the plan it comes to.
///
/// Every account of the database is listed (they already are accounts); banks, cash and other
/// accounts are added next to them. The balances typed here are the first count of each
/// account and currency: from then on the balance is that count plus what moved after it. A
/// field left empty is «не знаю»: nothing is written for it, the account stays uncounted, and
/// its first count becomes its starting point; a 0 typed is a count of zero. A balance may be
/// below zero — a credit card. A key counted before — after «Позже», by a reconciliation or the
/// editor of an account — keeps its count while its field is left empty; typed, it is compared
/// with what the books expected, and the difference is shown.
struct AccountSetupModel: Equatable {
  struct Account: Identifiable, Equatable {
    var id: UUID
    /// The account as the database has it; `nil` for one added here.
    var stored: PaymentMethod?
    var name: String
    var kind: PaymentMethodKind
    /// In the owner's order; the first is the account's main currency.
    var currencies: [CurrencyCode]
    /// What the owner typed for a currency; a currency left untouched has no value here.
    var typed: [CurrencyCode: AmountE4] = [:]
    var groupId: UUID?

    var isNew: Bool { stored == nil }

    func key(_ currency: CurrencyCode) -> BalanceKey {
      BalanceKey(accountId: id, currency: currency)
    }
  }

  struct Group: Identifiable, Equatable {
    var id: UUID
    /// The group as the database has it; `nil` for one made here.
    var stored: AccountGroup?
    var name: String
    var inSummary: Bool

    var isNew: Bool { stored == nil }
  }

  /// Why «Готово» cannot be pressed yet. Each has its words in the Onboarding table.
  enum Issue: Hashable {
    case noAccount
    case emptyName(UUID)
    case nameTaken(UUID)
    /// The name is another name of the live account `rival`: the words name that account, so
    /// the owner knows where to change it.
    case nameIsOtherNameOf(UUID, rival: String)
    /// An archived account has the name: it is brought back from the archive, not made twice.
    case nameArchived(UUID)
    /// A live card of another account is called so: the entry line would read the name as that
    /// card. The words name the card.
    case nameTakenByCard(UUID, card: String)
    case emptyGroupName(UUID)
    case groupNameTaken(UUID)
    /// An archived group has the name: it is brought back in Settings, not made twice.
    case groupNameArchived(UUID)
    case noMain
    /// The money of the main account always counts: it cannot sit in a group out of the
    /// summary.
    case mainInExcludedGroup

    var messageKey: String {
      switch self {
      case .noAccount: "onboarding.issue.noAccount"
      case .emptyName: "onboarding.issue.emptyName"
      case .nameTaken: "onboarding.issue.nameTaken"
      case .nameIsOtherNameOf: "onboarding.issue.nameIsOtherName"
      case .nameArchived: "onboarding.issue.nameArchived"
      case .nameTakenByCard: "onboarding.issue.nameTakenByCard"
      case .emptyGroupName: "onboarding.issue.emptyGroupName"
      case .groupNameTaken: "onboarding.issue.groupNameTaken"
      case .groupNameArchived: "onboarding.issue.groupNameArchived"
      case .noMain: "onboarding.issue.noMain"
      case .mainInExcludedGroup: "onboarding.issue.mainInExcludedGroup"
      }
    }
  }

  /// The words the sheet shows for `issue`. An account the database already has, named like an
  /// archived one, can only be renamed: Settings refuses to bring the archived one back beside a
  /// live one of its name. An account added here can also give way to the archived one.
  func messageKey(for issue: Issue) -> String {
    if case .nameArchived(let id) = issue, accounts.first(where: { $0.id == id })?.isNew == false {
      return "onboarding.issue.nameArchivedStored"
    }
    return issue.messageKey
  }

  /// The words the sheet shows for `issue`, in `language`: a clash with another name of an
  /// account names that account, a clash with a card names the card.
  @MainActor
  func message(for issue: Issue, language: AppLanguage) -> String {
    if case .nameIsOtherNameOf(_, let rival) = issue {
      return language.format(messageKey(for: issue), table: "Onboarding", rival)
    }
    if case .nameTakenByCard(_, let card) = issue {
      return language.format(messageKey(for: issue), table: "Onboarding", card)
    }
    return language(messageKey(for: issue), table: "Onboarding")
  }

  var accounts: [Account]
  var groups: [Group]
  var mainId: UUID?
  /// The currency of everything new; a new account holds it unless it is a bank of another
  /// country.
  var defaultCurrency: CurrencyCode
  /// The currencies switched on now.
  let enabled: [CurrencyCode]
  /// The archived accounts and groups: never listed, they only keep their names — and the
  /// other names of the accounts — from being taken.
  private(set) var archivedAccounts: [PaymentMethod] = []
  private(set) var archivedGroups: [AccountGroup] = []
  /// The cards of every account, archived ones included: a live card keeps its name from being
  /// taken by another account.
  private(set) var cards: [PaymentCard] = []
  /// The banks of the books, archived ones included: an account added here goes under the live
  /// bank of its name, or under a bank the plan makes for it.
  private(set) var banks: [Bank] = []
  /// What the books expect now for every key that has been counted before.
  private(set) var expected: [BalanceKey: AmountE4] = [:]
  /// Whether `expected` has been read. Until it has, a key counted before would look like a
  /// starting point and be written as zero: there is no plan.
  private(set) var hasExpected = false
  /// The main account as the database had it at the last read: a choice made here is told
  /// from one made in Settings meanwhile.
  private var storedMainId: UUID?
  /// The sort of the stored accounts that was the highest: a new account goes after them
  /// when the owner has ordered them by hand, and stays alphabetical when not.
  private var highestSort: Int
  private var highestGroupSort: Int

  /// `accounts` and `groups` as the database has them, archived ones included: the live ones
  /// are listed, the archived ones only keep their names from being taken. `locale` orders
  /// the names. `cards` are the cards of the accounts, whose live names are taken too; `banks`
  /// are the banks they stand under.
  init(
    accounts: [PaymentMethod], groups: [AccountGroup], defaultCurrency: CurrencyCode,
    enabled: [CurrencyCode], locale: Locale = Locale(identifier: "en"), cards: [PaymentCard] = [],
    banks: [Bank] = []
  ) {
    // The order of every list of accounts: the main one first, then the owner's order.
    let live = AccountRules.ordered(accounts, locale: locale)
    self.accounts = live.map { account in
      Account(
        id: account.id, stored: account, name: account.name, kind: account.kind,
        currencies: account.currencies, groupId: account.groupId)
    }
    let liveGroups = groups.filter { !$0.archived }
    self.groups = liveGroups.map {
      Group(id: $0.id, stored: $0, name: $0.name, inSummary: $0.inSummary)
    }
    // A group that is gone or archived holds nobody here: the account shows without one.
    let groupIds = Set(liveGroups.map(\.id))
    for index in self.accounts.indices
    where self.accounts[index].groupId.map({ !groupIds.contains($0) }) ?? false {
      self.accounts[index].groupId = nil
    }
    self.mainId = live.first { $0.isDefault }?.id
    self.storedMainId = mainId
    self.defaultCurrency = defaultCurrency
    self.enabled = enabled
    self.archivedAccounts = accounts.filter(\.archived)
    self.archivedGroups = groups.filter(\.archived)
    self.cards = cards
    self.banks = banks
    self.highestSort = accounts.map(\.sort).max() ?? 0
    self.highestGroupSort = groups.map(\.sort).max() ?? 0
  }

  /// How names are compared: without the spaces around them, the case and the diacritics.
  static func nameKey(_ name: String) -> String {
    name.trimmingCharacters(in: .whitespacesAndNewlines)
      .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
  }

  // MARK: Balances

  /// What the books expect now for the keys counted before; a key never counted is absent.
  mutating func setExpected(_ values: [BalanceKey: AmountE4]) {
    expected = values
    hasExpected = true
  }

  /// The balance of the key as the plan will write it: what was typed — zero and below zero
  /// included —; `nil` for a field left empty, «не знаю», which writes nothing.
  func balance(_ key: BalanceKey) -> AmountE4? {
    accounts.first { $0.id == key.accountId }?.typed[key.currency]
  }

  /// What the owner typed; `nil` — the field emptied — is «не знаю» again.
  mutating func setBalance(_ amount: AmountE4?, for key: BalanceKey) {
    guard let index = index(of: key.accountId) else { return }
    accounts[index].typed[key.currency] = amount
  }

  /// The count typed against what the books expected, for a key counted before; `nil` for a
  /// starting point and for a field left empty.
  func difference(_ key: BalanceKey) -> AmountE4? {
    guard let expected = expected[key], let balance = balance(key) else { return nil }
    return balance - expected
  }

  /// Some field of an account never counted is left empty: that account stays uncounted.
  var leavesAccountsUncounted: Bool {
    accounts.contains { account in
      account.currencies.contains { currency in
        account.typed[currency] == nil && expected[account.key(currency)] == nil
      }
    }
  }

  // MARK: Accounts

  /// An account of this bank is listed already, by either spelling of its name.
  func lists(_ bank: BankCatalog.Bank) -> Bool {
    lists(names: bank.names)
  }

  /// An account is listed under one of `names`.
  func lists(names: [String]) -> Bool {
    let keys = Set(names.map(Self.nameKey))
    return accounts.contains { keys.contains(Self.nameKey($0.name)) }
  }

  func account(named name: String) -> Account? {
    let key = Self.nameKey(name)
    return accounts.first { Self.nameKey($0.name) == key }
  }

  /// Adds the bank, or takes it away again when it was added here. An account the database
  /// already has stays. The bank's account holds the currency of its country and goes into a
  /// group named like the country when there is one.
  mutating func toggle(_ bank: BankCatalog.Bank, languageCode: String, countryName: String) {
    let names = Set(bank.names.map(Self.nameKey))
    if let listed = accounts.first(where: { names.contains(Self.nameKey($0.name)) }) {
      if listed.isNew { removeAccount(listed.id) }
      return
    }
    let group = groups.first { Self.nameKey($0.name) == Self.nameKey(countryName) }
    addAccount(
      name: bank.name(languageCode: languageCode), kind: .card,
      currency: bank.country.currency, groupId: group?.id)
  }

  /// A new account, in the default currency unless another is given. The first account of
  /// the setup becomes the main one. Nothing is added under an empty name.
  @discardableResult
  mutating func addAccount(
    name: String, kind: PaymentMethodKind, currency: CurrencyCode? = nil, groupId: UUID? = nil
  ) -> UUID? {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let account = Account(
      id: UUID(), stored: nil, name: trimmed, kind: kind,
      currencies: [currency ?? defaultCurrency], groupId: groupId)
    accounts.append(account)
    if mainId == nil { mainId = account.id }
    return account.id
  }

  /// Only an account added here goes away; one the database has is kept (its operations are
  /// on it). The main account passes to the first account left.
  mutating func removeAccount(_ id: UUID) {
    guard let index = index(of: id), accounts[index].isNew else { return }
    accounts.remove(at: index)
    if mainId == id { mainId = accounts.first?.id }
  }

  /// The currencies that can be added to the account: those switched on and those a fresh
  /// install switches on, less the ones it holds.
  func addableCurrencies(to id: UUID) -> [CurrencyCode] {
    guard let account = accounts.first(where: { $0.id == id }) else { return [] }
    var result: [CurrencyCode] = []
    for currency in enabled + CurrencyCode.defaultEnabled
    where !account.currencies.contains(currency) && !result.contains(currency) {
      result.append(currency)
    }
    return result
  }

  mutating func addCurrency(_ currency: CurrencyCode, to id: UUID) {
    guard let index = index(of: id), !accounts[index].currencies.contains(currency) else {
      return
    }
    accounts[index].currencies.append(currency)
  }

  /// A currency the account held before the setup stays: money may have moved in it. The last
  /// one stays too.
  func canRemove(_ currency: CurrencyCode, from id: UUID) -> Bool {
    guard let account = accounts.first(where: { $0.id == id }) else { return false }
    return account.currencies.count > 1 && account.currencies.contains(currency)
      && !(account.stored?.currencies.contains(currency) ?? false)
  }

  mutating func removeCurrency(_ currency: CurrencyCode, from id: UUID) {
    guard canRemove(currency, from: id), let index = index(of: id) else { return }
    accounts[index].currencies.removeAll { $0 == currency }
    accounts[index].typed[currency] = nil
  }

  /// Moves the currency to the front: the first currency is the account's main one.
  mutating func makeMainCurrency(_ currency: CurrencyCode, of id: UUID) {
    guard let index = index(of: id), accounts[index].currencies.contains(currency) else {
      return
    }
    accounts[index].currencies.removeAll { $0 == currency }
    accounts[index].currencies.insert(currency, at: 0)
  }

  // MARK: Groups

  /// A new group; nothing under an empty name or a name another group has.
  @discardableResult
  mutating func addGroup(name: String, inSummary: Bool = true) -> UUID? {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !hasGroup(named: trimmed) else { return nil }
    let group = Group(id: UUID(), stored: nil, name: trimmed, inSummary: inSummary)
    groups.append(group)
    return group.id
  }

  /// A group listed here or in the archive has the name.
  func hasGroup(named name: String) -> Bool {
    let key = Self.nameKey(name)
    return groups.contains { Self.nameKey($0.name) == key }
      || archivedGroups.contains { Self.nameKey($0.name) == key }
  }

  /// Only a group made here goes away; its accounts are left without a group.
  mutating func removeGroup(_ id: UUID) {
    guard let index = groups.firstIndex(where: { $0.id == id }), groups[index].isNew else {
      return
    }
    groups.remove(at: index)
    for account in accounts.indices where accounts[account].groupId == id {
      accounts[account].groupId = nil
    }
  }

  // MARK: Checks and the plan

  /// Every currency the accounts hold, each once, in the order they are met.
  var heldCurrencies: [CurrencyCode] {
    var result: [CurrencyCode] = []
    for account in accounts {
      for currency in account.currencies where !result.contains(currency) {
        result.append(currency)
      }
    }
    return result
  }

  /// What stops «Готово», by the rules Settings saves accounts and groups by
  /// (`AccountRules`): a name no other account has, live or archived, among its names or its
  /// other names, nor a live card of another account; the main account in the summary.
  var issues: [Issue] {
    var result: [Issue] = []
    if accounts.isEmpty { result.append(.noAccount) }
    let rows = accounts.map(row)
    let groupRows = groups.map(groupRow)
    // Every currency held is switched on by the setup: none is refused for being off here.
    let switchedOn = enabled + heldCurrencies + [defaultCurrency]
    for (account, row) in zip(accounts, rows) {
      let found = AccountRules.validate(
        row, previous: nil, balances: .empty, enabled: switchedOn,
        others: rows + archivedAccounts, groups: groupRows + archivedGroups)
      if found.contains(.emptyName) {
        result.append(.emptyName(account.id))
      } else if found.contains(.nameTaken) {
        // A live account in the way is named when the clash is with one of its other names:
        // the owner changes that name in Settings.
        if let rival = AccountRules.rival(of: row.name, account: row.id, among: rows) {
          result.append(
            rival.byOtherName
              ? .nameIsOtherNameOf(account.id, rival: rival.account.name)
              : .nameTaken(account.id))
        } else {
          result.append(.nameArchived(account.id))
        }
      } else if let card = cardTaking(account, row: row) {
        result.append(.nameTakenByCard(account.id, card: card.name))
      }
      if found.contains(.mainInExcludedGroup), !result.contains(.mainInExcludedGroup) {
        result.append(.mainInExcludedGroup)
      }
    }
    for (group, row) in zip(groups, groupRows) {
      let found = AccountRules.validate(group: row, accounts: rows)
      let key = Self.nameKey(group.name)
      if found.contains(.emptyName) {
        result.append(.emptyGroupName(group.id))
      } else if groups.contains(where: { $0.id != group.id && Self.nameKey($0.name) == key }) {
        result.append(.groupNameTaken(group.id))
      } else if archivedGroups.contains(where: { Self.nameKey($0.name) == key }) {
        result.append(.groupNameArchived(group.id))
      }
      if found.contains(.holdsMain), !result.contains(.mainInExcludedGroup) {
        result.append(.mainInExcludedGroup)
      }
    }
    if !accounts.isEmpty, !accounts.contains(where: { $0.id == mainId }) {
      result.append(.noMain)
    }
    return result
  }

  /// What «Готово» writes, or `nil` while an issue is open or the balances expected are not
  /// read. A count for every balance typed, and only for those: a field left empty writes
  /// nothing — an account never counted stays uncounted, one counted before keeps its count.
  /// A key counted before and typed compares with what the books expected. Each new account of
  /// the kind card or account comes with its card, and every account stands under a bank: the live
  /// bank of its name, else a bank the plan makes for it, called like it — its id is the
  /// account's, masked, so the plan is the same every time it is asked for.
  func plan(at instant: Date) -> AccountSetupPlan? {
    guard hasExpected, issues.isEmpty, let mainId else { return nil }
    var nextSort = highestSort
    var methods: [PaymentMethod] = []
    var cards: [PaymentCard] = []
    var newBanks: [Bank] = []
    var openings: [BalanceKey: AmountE4] = [:]
    for account in accounts {
      var method = row(account)
      if account.isNew, highestSort > 0 {
        nextSort += 1
        method.sort = nextSort
      }
      if method.bankId == nil {
        let known = banks + newBanks
        if let bank = BankRules.live(named: method.name, among: known) {
          method.bankId = bank.id
        } else {
          let bank = Bank(
            id: BanksMigration.bankId(forAccount: method.id),
            name: method.name.trimmingCharacters(in: .whitespacesAndNewlines),
            sort: BankRules.sortForNewBank(among: known.filter { !$0.archived }))
          newBanks.append(bank)
          method.bankId = bank.id
        }
      }
      methods.append(method)
      // A new card or bank account starts with a card named like it; one already stored keeps
      // the cards it has. The card's id is the account's own, masked: the plan is the same
      // every time it is asked for.
      if account.isNew,
        let card = CardRules.startingCard(
          for: method, id: CardsMigration.cardId(forAccount: method.id))
      {
        cards.append(card)
      }
      for currency in account.currencies {
        let key = account.key(currency)
        if let typed = balance(key) { openings[key] = typed }
      }
    }
    var nextGroupSort = highestGroupSort
    let groups = groups.map { group in
      var stored = groupRow(group)
      if group.isNew, highestGroupSort > 0 {
        nextGroupSort += 1
        stored.sort = nextGroupSort
      }
      return stored
    }
    return AccountSetupPlan(
      accounts: methods, groups: groups, mainAccountId: mainId, openingBalances: openings,
      expected: expected.filter { openings[$0.key] != nil }, defaultCurrency: defaultCurrency,
      at: instant, cards: cards, banks: newBanks)
  }

  /// The live card of another account that the name of an account added or renamed here is
  /// already. Only the name is checked: the other names of a stored account are not edited
  /// here, and Settings checked them when they were written.
  private func cardTaking(_ account: Account, row: PaymentMethod) -> PaymentCard? {
    if let stored = account.stored, Self.nameKey(stored.name) == Self.nameKey(row.name) {
      return nil
    }
    return CardRules.cardTaking(row.name, except: row.id, cards: cards)
  }

  /// The account as «Готово» would write it: the row the database has, with what the sheet
  /// says of it.
  private func row(_ account: Account) -> PaymentMethod {
    var method =
      account.stored ?? PaymentMethod(id: account.id, name: account.name, kind: account.kind)
    method.name = account.name.trimmingCharacters(in: .whitespacesAndNewlines)
    method.kind = account.kind
    method.currency = account.currencies.first
    method.otherCurrencies = Array(account.currencies.dropFirst())
    method.groupId = account.groupId
    method.isDefault = account.id == mainId
    return method
  }

  private func groupRow(_ group: Group) -> AccountGroup {
    var stored = group.stored ?? AccountGroup(id: group.id, name: group.name)
    stored.name = group.name.trimmingCharacters(in: .whitespacesAndNewlines)
    stored.inSummary = group.inSummary
    return stored
  }

  // MARK: Read again

  /// The accounts and groups as the database has them now, under the edits made here.
  ///
  /// Settings stays open next to the sheet. A field the sheet left as it was read takes what
  /// was written since; a field changed here keeps the change. An account or a group archived,
  /// merged or deleted since leaves the list — written back live, merged money would count
  /// twice — and one made since joins it. Returns whether the list changed that way: the
  /// owner sees it before anything is written.
  /// `cards` and `banks`, when given, replace the ones read before.
  @discardableResult
  mutating func rebase(
    accounts fresh: [PaymentMethod], groups freshGroups: [AccountGroup],
    cards freshCards: [PaymentCard]? = nil, banks freshBanks: [Bank]? = nil
  ) -> Bool {
    var changed = false
    let liveGroups = freshGroups.filter { !$0.archived }
    var mergedGroups: [Group] = []
    for var group in groups {
      guard let before = group.stored else {
        mergedGroups.append(group)
        continue
      }
      guard let now = liveGroups.first(where: { $0.id == group.id }) else {
        changed = true
        continue
      }
      if group.name == before.name { group.name = now.name }
      if group.inSummary == before.inSummary { group.inSummary = now.inSummary }
      group.stored = now
      mergedGroups.append(group)
    }
    for now in liveGroups where !mergedGroups.contains(where: { $0.id == now.id }) {
      mergedGroups.append(Group(id: now.id, stored: now, name: now.name, inSummary: now.inSummary))
      changed = true
    }
    groups = mergedGroups
    let groupIds = Set(groups.map(\.id))

    let live = fresh.filter { !$0.archived }
    var mergedAccounts: [Account] = []
    for var account in accounts {
      guard let before = account.stored else {
        mergedAccounts.append(account)
        continue
      }
      guard let now = live.first(where: { $0.id == account.id }) else {
        changed = true
        continue
      }
      if account.name == before.name { account.name = now.name }
      if account.kind == before.kind { account.kind = now.kind }
      if account.groupId == before.groupId { account.groupId = now.groupId }
      account.currencies = Self.merged(
        account.currencies, before: before.currencies, now: now.currencies)
      account.typed = account.typed.filter { account.currencies.contains($0.key) }
      account.stored = now
      mergedAccounts.append(account)
    }
    for now in AccountRules.ordered(live, locale: Locale(identifier: "en"))
    where !mergedAccounts.contains(where: { $0.id == now.id }) {
      mergedAccounts.append(
        Account(
          id: now.id, stored: now, name: now.name, kind: now.kind, currencies: now.currencies,
          groupId: now.groupId))
      changed = true
    }
    for index in mergedAccounts.indices
    where mergedAccounts[index].groupId.map({ !groupIds.contains($0) }) ?? false {
      mergedAccounts[index].groupId = nil
    }
    accounts = mergedAccounts

    // The main account: the one chosen here, unless it is gone or the choice was left alone
    // and Settings made another main meanwhile.
    let freshMain = live.first(where: \.isDefault)?.id
    if mainId == storedMainId, let freshMain, accounts.contains(where: { $0.id == freshMain }) {
      mainId = freshMain
    }
    if !accounts.contains(where: { $0.id == mainId }) { mainId = accounts.first?.id }
    storedMainId = freshMain
    archivedAccounts = fresh.filter(\.archived)
    archivedGroups = freshGroups.filter(\.archived)
    if let freshCards { cards = freshCards }
    if let freshBanks { banks = freshBanks }
    highestSort = fresh.map(\.sort).max() ?? 0
    highestGroupSort = freshGroups.map(\.sort).max() ?? 0
    return changed
  }

  /// The currencies of an account after a read: the order made here, less those Settings took
  /// away meanwhile, with those it added at the end.
  static func merged(
    _ here: [CurrencyCode], before: [CurrencyCode], now: [CurrencyCode]
  ) -> [CurrencyCode] {
    if here == before { return now }
    var result = here.filter { now.contains($0) || !before.contains($0) }
    for currency in now where !result.contains(currency) { result.append(currency) }
    return result.isEmpty ? now : result
  }

  private func index(of id: UUID) -> Int? {
    accounts.firstIndex { $0.id == id }
  }
}

extension AccountSetupModel {
  /// The setup as the database stands now, or `nil` when it is not open or its accounts
  /// cannot be read — an empty list would offer to make them again.
  @MainActor
  static func load(from environment: AppEnvironment) -> AccountSetupModel? {
    guard let (accounts, groups, cards, banks) = readAccounts(environment) else { return nil }
    let enabled = (try? environment.settings?.enabledCurrencies()) ?? CurrencyCode.defaultEnabled
    return AccountSetupModel(
      accounts: accounts, groups: groups, defaultCurrency: environment.defaultCurrency,
      enabled: enabled, locale: environment.language.locale, cards: cards, banks: banks)
  }

  /// `rebase` on what the database has now; `nil` when it cannot be read.
  @MainActor
  mutating func rebase(on environment: AppEnvironment) -> Bool? {
    guard let (accounts, groups, cards, banks) = Self.readAccounts(environment) else { return nil }
    return rebase(accounts: accounts, groups: groups, cards: cards, banks: banks)
  }

  /// The accounts, the groups, the cards and the banks, archived ones included.
  @MainActor
  private static func readAccounts(
    _ environment: AppEnvironment
  ) -> (
    accounts: [PaymentMethod], groups: [AccountGroup], cards: [PaymentCard], banks: [Bank]
  )? {
    guard let repository = environment.accounts, let stack = environment.stack else {
      return nil
    }
    do {
      return (
        try repository.accounts(includeArchived: true),
        try repository.groups(includeArchived: true),
        try CardRepository(writer: stack.writer).cards(includeArchived: true),
        try repository.banks(includeArchived: true)
      )
    } catch {
      AppLog.error(
        "accounts.setupRead", .db, "the accounts before the setup could not be read",
        [LogPair("error", .error(error))])
      return nil
    }
  }
}

/// What the books expect for the keys that have been counted before: their latest count and
/// everything that moved after it, by the balance engine of the core.
enum AccountSetupExpectations {
  typealias Expected = [BalanceKey: AmountE4]

  /// The balances of every account at `instant`.
  static func balances(
    of dataset: Dataset, at instant: Date, calendar: CalendarContext
  ) -> AccountBalances {
    AccountBalances.build(
      entries: dataset.entries, transfers: dataset.transfers,
      debtEntries: dataset.planning.debtEntries, debts: dataset.debtsById,
      reconciliations: dataset.planning.reconciliations,
      balances: dataset.planning.reconciledBalances, accounts: dataset.paymentMethods,
      tree: CategoryTree(dataset.categories), now: instant, calendar: calendar)
  }

  /// The expected balance at `instant` of every key counted by then; a key never counted is
  /// a starting point and absent.
  static func expected(in balances: AccountBalances, at instant: Date) -> [BalanceKey: AmountE4] {
    var result: [BalanceKey: AmountE4] = [:]
    for key in balances.keys where balances.latestAnchor(key) != nil {
      if let value = balances.balance(key, at: instant) { result[key] = value }
    }
    return result
  }

  /// Read from the database of the environment; `nil` when it cannot be read. Never empty in
  /// its place: every key counted before would then be taken for a starting point and counted
  /// as zero.
  @MainActor
  static func load(from environment: AppEnvironment, at instant: Date) async -> Expected? {
    guard let writer = environment.stack?.writer else { return nil }
    let calendar = environment.calendar
    do {
      let dataset = try await DatasetRepository(writer: writer).load(version: 0)
      return expected(in: balances(of: dataset, at: instant, calendar: calendar), at: instant)
    } catch {
      AppLog.error(
        "accounts.setupRead", .db, "the balances before the setup could not be read",
        [LogPair("error", .error(error))])
      return nil
    }
  }
}

/// The two answers to the setup. Neither is a step of ⌘Z: the steps taken before may name an
/// account the setup changed, so the history of ⌘Z is forgotten after each, as after money
/// back is recorded.
@MainActor
enum AccountSetupWrites {
  enum Outcome: Equatable {
    case written
    case failed
  }

  /// «Готово»: the accounts, the groups, the main account and the counts, in one write.
  static func finish(
    _ plan: AccountSetupPlan, environment: AppEnvironment, store: TransactionsStore
  ) -> Outcome {
    guard let repository = environment.accounts else { return .failed }
    do {
      try repository.finishSetup(plan, calendar: environment.calendar)
    } catch {
      AppLog.error(
        "accounts.setupFailed", .db, "the setup of the accounts was not written",
        [LogPair("error", .error(error))])
      return .failed
    }
    settle(environment, store)
    AppLog.info(
      "accounts.setupDone", .db, "the accounts were set up",
      [
        LogPair("accounts", .count(plan.accounts.count)),
        LogPair("groups", .count(plan.groups.count)),
        LogPair("balances", .count(plan.openingBalances.count)),
        LogPair("compared", .count(plan.expected.count)),
      ])
    return .written
  }

  /// «Позже»: a main account when there is none, and the setup put off.
  static func postpone(environment: AppEnvironment, store: TransactionsStore) -> Bool {
    guard let repository = environment.accounts else { return false }
    do {
      try repository.postponeSetup(
        mainAccountName: environment.language("accounts.mainDefaultName"),
        defaultCurrency: environment.defaultCurrency, at: Date())
    } catch {
      AppLog.error(
        "accounts.laterFailed", .db, "the setup of the accounts was not put off",
        [LogPair("error", .error(error))])
      return false
    }
    settle(environment, store)
    AppLog.info("accounts.setupLater", .db, "the setup of the accounts was put off")
    return true
  }

  private static func settle(_ environment: AppEnvironment, _ store: TransactionsStore) {
    store.forgetUndoHistory()
    environment.scheduleBackup()
    environment.refreshAccountSettings()
    environment.refreshVocabulary()
  }
}
