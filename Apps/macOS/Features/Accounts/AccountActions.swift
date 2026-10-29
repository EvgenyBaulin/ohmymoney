import AppCore
import AppDatabase
import SwiftUI

/// Money a count says is on an account, in one currency.
struct HeldMoney: Hashable, Sendable {
  let currency: CurrencyCode
  let amount: AmountE4
}

/// Why an action on the accounts was not taken. Nothing is written then.
enum AccountRefusal: Error, Hashable, Sendable {
  case emptyName
  /// Another account is called that, or has it among its other names.
  case nameTaken
  /// One of the other names is already the name or another name of a live account.
  case otherNameTaken(String)
  /// A live card of another account is called that — the entry line would read the card: the
  /// card's name.
  case nameTakenByCard(String)
  /// A new account named like one in the archive: that one comes back instead.
  case inArchive(UUID)
  case noCurrency
  case duplicateCurrency
  case currencyNotEnabled(CurrencyCode)
  /// The currency is taken off while money is on it.
  case removesCurrencyWithMoney(CurrencyCode)
  /// The currency is taken off while nobody knows what is on it.
  case currencyBalanceUnknown(CurrencyCode)
  /// «Остаток сейчас» does not read as an amount.
  case unreadableBalance(CurrencyCode)
  /// Into the archive with money still on the account.
  case hasMoney
  /// Deleted while a count says money is on the account: the money would leave every total
  /// with no step of ⌘Z to bring it back.
  case deletesWithMoney
  /// Into the archive while nobody knows what is on the account: it moved but was never
  /// counted, so it is counted first rather than taken for money or for zero.
  case balanceUnknown
  case lastLiveAccount
  /// A credit card would be left without a card: the first one cannot be made (its name is
  /// empty or taken).
  case creditCardNeedsCard
  /// The main account leaves the live ones and no account was named to take it over.
  case needsNewMain
  /// The main account leaves and no other live account in the summary could take it over.
  case noSuccessor
  /// The main account in a group left out of the summary: its money must count.
  case mainInExcludedGroup
  /// Something points at the account: it is archived or merged, never deleted.
  case inUse(UUID, AccountUsage)
  /// The group holds the main account: it stays in the summary.
  case groupHoldsMain
  /// A group goes to the archive only once every account in it has.
  case groupHasLiveAccounts
  /// Accounts, archived ones included, are filed under the group.
  case groupInUse
  case groupNameTaken
  /// A live bank is already called so.
  case bankNameTaken
  /// A bank goes to the archive once every account under it has.
  case bankHasLiveAccounts
  /// Accounts, archived ones included, are filed under the bank: it is not deleted.
  case bankInUse
  /// A merge of two accounts under different banks: money of one bank never lands on an
  /// account of another by a merge — the banks are merged first.
  case otherBank
  /// «Объединить с…» of a bank: the banks are not two live banks.
  case bankMerge(BankMergeIssue)
  case notFound
  /// The money on the key is not what the question showed any more — something was written
  /// meanwhile —: nothing was written, and the amounts are shown again.
  case balanceChanged(BalanceKey)
  /// «Проценты» do not read, or name where the interest cannot go.
  case interest(InterestIssue)
  /// The terms of a credit card do not read.
  case credit(CreditTermsIssue)

  /// The account a refusal of `inUse` is about: it can still be merged or archived.
  var accountInUse: UUID? {
    if case .inUse(let id, _) = self { return id }
    return nil
  }
}

/// What came of an action on the accounts.
enum AccountActionOutcome: Hashable, Sendable {
  case done
  case refused(AccountRefusal)
  /// The database did not take the write; the journal says why.
  case failed
}

/// The books an action on the accounts judges by, read from the database as it is now: the
/// money on every (account, currency) and how many live operations each account has.
struct AccountBooks: Sendable {
  let dataset: Dataset
  let balances: AccountBalances
  /// Live operations per account — the most used account takes over as main.
  let liveOperations: [UUID: Int]
  /// The moment the balances are worked out for.
  let at: Date

  init(dataset: Dataset, at: Date, calendar: CalendarContext) {
    self.dataset = dataset
    self.at = at
    balances = AccountBalances.build(
      entries: dataset.entries, transfers: dataset.transfers,
      debtEntries: dataset.planning.debtEntries, debts: dataset.debtsById,
      reconciliations: dataset.planning.reconciliations,
      balances: dataset.planning.reconciledBalances, accounts: dataset.paymentMethods,
      tree: CategoryTree(dataset.categories), now: at, calendar: calendar)
    var counts: [UUID: Int] = [:]
    for entry in dataset.entries where !entry.transaction.isDeleted {
      if let id = entry.transaction.paymentMethodId { counts[id, default: 0] += 1 }
    }
    liveOperations = counts
  }

  /// Money is on the key: a balance that is not zero now, or once everything written on it has
  /// happened — an operation typed ahead of now counts (`AccountBalances.balanceAhead`), as
  /// the rules of saving an account count it —, or movements on a key never counted — a balance
  /// nobody knows is not taken for zero.
  func hasMoney(_ key: BalanceKey) -> Bool {
    if let amount = balances.balanceAhead(key) {
      return !amount.isZero || !(balances.balance(key, at: balances.now) ?? .zero).isZero
    }
    return balances.hasHistory(key)
  }

  /// The key moved but was never counted: what is on it nobody knows.
  func isUnknown(_ key: BalanceKey) -> Bool {
    guard let balance = balances[key] else { return false }
    return balance.amountE4 == nil && balances.hasHistory(key)
  }

  /// A count says money is on the key.
  func holdsCountedMoney(_ key: BalanceKey) -> Bool {
    guard let amount = balances[key]?.amountE4 else { return false }
    return !amount.isZero
  }
}

/// A merge worked out before the owner agrees to it: the plan the repository writes, what the
/// owner still has to count, and how many transfers between the two accounts go.
struct AccountMergePreview: Sendable {
  var plan: AccountMergePlan
  /// Keys whose balance cannot be worked out; the merge dialog asks for them.
  var needsBalance: [BalanceKey]
  /// What the merged account will hold now in each currency it knows, as the plan stands —
  /// what the dialog shows, rather than the count it rests on.
  var balancesAfter: [BalanceKey: AmountE4] = [:]
  var deletedTransfers: Int { plan.deletedTransferIds.count }

  /// A key asked for that, left empty, keeps the target's own latest count: the other
  /// account's past becomes history.
  func keepsItsCountWhenEmpty(_ key: BalanceKey) -> Bool {
    needsBalance.contains(key) && plan.opening[key] != nil
  }
}

/// Every action on the accounts and their groups that the settings and the sidebar offer.
///
/// A new account, an edit, the archive and «Вернуть», the main account passed on, the order
/// and the groups are one `PlanningChange` each — one step of ⌘Z. A merge and a deletion are
/// not undone (`AccountRepository`): after each the history of ⌘Z is forgotten, as after
/// money back is recorded, since a step taken before may name the account that is gone.
@MainActor
struct AccountActions {
  let environment: AppEnvironment
  let store: TransactionsStore

  init(environment: AppEnvironment, store: TransactionsStore) {
    self.environment = environment
    self.store = store
  }

  // MARK: Reading

  /// Every account, archived ones too.
  var all: [PaymentMethod] { (try? environment.accounts?.accounts(includeArchived: true)) ?? [] }

  /// Every group, archived ones too.
  var groups: [AccountGroup] {
    (try? environment.accounts?.groups(includeArchived: true)) ?? []
  }

  /// Every card, archived ones too.
  var cards: [PaymentCard] {
    guard let writer = environment.stack?.writer else { return [] }
    return (try? CardRepository(writer: writer).cards(includeArchived: true)) ?? []
  }

  var enabledCurrencies: [CurrencyCode] {
    (try? environment.settings?.enabledCurrencies()) ?? CurrencyCode.defaultEnabled
  }

  /// The live accounts in the order of every list: the main one first, then as dragged, then
  /// by name.
  func ordered(_ accounts: [PaymentMethod]) -> [PaymentMethod] {
    AccountRules.ordered(accounts, locale: environment.language.locale)
  }

  /// The books as the database has them this moment. Read fresh rather than from the last
  /// calculation, which can be a moment behind a write — and a merge is not undone.
  func books() async -> AccountBooks? {
    guard let writer = environment.stack?.writer else { return nil }
    let at = environment.now()
    let calendar = environment.calendar
    do {
      let dataset = try await DatasetRepository(writer: writer).load(version: 0)
      return AccountBooks(dataset: dataset, at: at, calendar: calendar)
    } catch {
      AppLog.error(
        "accounts.booksRead", .db, "the books of the accounts could not be read",
        [LogPair("error", .error(error))])
      return nil
    }
  }

  // MARK: One step of ⌘Z

  /// Saves a new account (`previous == nil`) or an edit of one. `openings` are «Остаток
  /// сейчас» typed for currencies never counted and never moved: each becomes the starting
  /// point of its key, in one opening count written with the account. A new account of the kind
  /// card or account starts with a card named like it, in the same step of ⌘Z.
  ///
  /// The account goes under a bank: `account.bankId` when it names one, else the live bank
  /// called `newBankNamed` — the account's own name when that is not given — or a new bank of
  /// that name, written in the same step (`BankRules.bank(forNewAccountNamed:)`).
  ///
  /// An account that earns interest brings the income category of interest along in the same
  /// step, when there is no live one yet — remembered under `accounts.interestCategory`
  /// (`addInterestCategory(to:books:)`): ⌘Z takes back the interest, the category and the
  /// setting together.
  func save(
    _ account: PaymentMethod, previous: PaymentMethod?, openings: [CurrencyCode: AmountE4] = [:],
    books: AccountBooks, newBankNamed: String? = nil, firstCardNamed: String? = nil
  ) -> AccountActionOutcome {
    let all = self.all
    var account = Self.tidied(account)
    if let previous, previous.isDefault, !previous.archived {
      // The main account is only ever passed on, never switched off.
      account.isDefault = true
    }
    if let refusal = Self.refusal(
      saving: account, previous: previous, books: books, enabled: enabledCurrencies, all: all,
      groups: groups, cards: cards)
    {
      return .refused(refusal)
    }
    if previous == nil {
      account.sort = AccountRules.sortForNewAccount(among: all.filter { !$0.archived })
    }
    // The main card is always a live card of the account: one that went to the archive or was
    // merged away since the form opened is not written.
    account.mainCardId = CardRules.validMainCard(of: account, cards: cards)
    let at = environment.now()
    var bankRows: [Bank] = []
    let banks = self.banks
    if let id = account.bankId {
      // A live account goes under a live bank; an account in the archive may stay under the
      // bank it is in.
      guard let bank = banks.first(where: { $0.id == id }),
        !bank.archived || previous?.bankId == id || account.archived
      else { return .refused(.notFound) }
    } else {
      let given = newBankNamed?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      let choice = BankRules.bank(
        forNewAccountNamed: given.isEmpty ? account.name : given, among: banks)
      if choice.isNew, let refusal = Self.refusal(saving: choice.bank, among: banks) {
        return .refused(refusal)
      }
      account.bankId = choice.bank.id
      if choice.isNew { bankRows = [choice.bank] }
    }
    var rows = PlanningRows(paymentMethods: [account], banks: bankRows)
    // A credit card is never opened, or left, without a card: the first is made with it, named
    // as typed. Any other new account starts with a card named like itself.
    let allCards = cards
    if account.credit != nil, !account.archived {
      if CardRules.creditCardLacksCard(account, cards: allCards) {
        guard let card = CardRules.startingCard(for: account, named: firstCardNamed),
          CardRules.validate(card, previous: nil, cards: allCards, accounts: all).isEmpty
        else { return .refused(.creditCardNeedsCard) }
        rows.cards = [card]
      }
    } else if previous == nil, let card = CardRules.startingCard(for: account) {
      rows.cards = [card]
    }
    let counted = openings.filter { currency, _ in
      account.holds(currency)
        && !books.balances.hasHistory(BalanceKey(accountId: account.id, currency: currency))
    }
    if !counted.isEmpty {
      let count = Reconciliation(
        date: environment.calendar.day(of: at), reconciledAt: at, actualTotalRubE4: .zero,
        kind: .opening, origin: .account)
      rows.reconciliations = [count]
      rows.reconciledBalances = counted.sorted { $0.key.code < $1.key.code }.map {
        ReconciledBalance(
          reconciliationId: count.id, accountId: account.id, currency: $0.key, actualE4: $0.value)
      }
    }
    var change = PlanningChange(upsert: rows, at: at)
    if account.interest != nil, !account.archived {
      addInterestCategory(to: &change, books: books)
    }
    let outcome = apply(change)
    if outcome == .done { Self.logCredit(of: account, previous: previous) }
    return outcome
  }

  /// A saved account whose terms of a credit card or main card changed is said in the journal,
  /// by id and flags only.
  static func logCredit(of account: PaymentMethod, previous: PaymentMethod?) {
    if account.credit != previous?.credit {
      AppLog.info(
        "cards.credit.saved", .db, "the terms of a credit card were saved",
        [LogPair("account", .id(account.id)), LogPair("credit", .flag(account.credit != nil))])
    }
    if account.mainCardId != previous?.mainCardId {
      AppLog.info(
        "cards.mainCard.set", .db, "the main card of an account changed",
        [LogPair("account", .id(account.id)), LogPair("chosen", .flag(account.mainCardId != nil))])
    }
  }

  /// Makes a live account the main one; the flag leaves every other in the same write.
  func makeMain(_ id: UUID) -> AccountActionOutcome {
    guard var account = all.first(where: { $0.id == id && !$0.archived }) else {
      return .refused(.notFound)
    }
    guard !account.isDefault else { return .done }
    guard !Self.isInExcludedGroup(account, groups: groups) else {
      return .refused(.mainInExcludedGroup)
    }
    account.isDefault = true
    return apply(
      PlanningChange(upsert: PlanningRows(paymentMethods: [account]), at: environment.now()))
  }

  /// The accounts that can take over from the main account `leaving`, in list order, and the
  /// one preselected: the most used. Only live accounts in the summary: the money of the main
  /// account always counts.
  func successors(
    leaving id: UUID, books: AccountBooks
  ) -> (all: [PaymentMethod], preselected: UUID?) {
    successors(leaving: [id], books: books)
  }

  /// The same when several accounts go at once, the main one among them: none of them is
  /// offered.
  func successors(
    leaving ids: Set<UUID>, books: AccountBooks
  ) -> (all: [PaymentMethod], preselected: UUID?) {
    let groups = self.groups
    let candidates = ordered(all).filter {
      !ids.contains($0.id) && !Self.isInExcludedGroup($0, groups: groups)
    }
    // The candidates already leave out every account that goes.
    let preselected = ids.first.flatMap {
      AccountRules.mainHandOverCandidate(
        leaving: $0, accounts: candidates, liveOperations: books.liveOperations)
    }
    return (candidates, preselected)
  }

  /// Into the archive; the main account goes only with `newMain`, which takes the flag in the
  /// same step. Money still on it keeps it out, unless `settling` moves every currency of it
  /// that holds money to a live account (`ArchivedMoney.balancesToMove`): the transfers and the
  /// archive are then one change and one step of ⌘Z. `expecting` are the amounts the question
  /// showed; when the books hold other money now, nothing is written
  /// (`AccountRefusal.balanceChanged`), and the write itself checks them once more.
  ///
  /// `expectingNow` are what the keys held now when the question was shown
  /// (`ArchivedLeftover.heldNow`): with money typed ahead, the money of now is moved apart, so
  /// both are checked.
  func archive(
    _ id: UUID, newMain: UUID? = nil, books: AccountBooks, settling: [Transfer] = [],
    expecting: [BalanceKey: AmountE4] = [:], expectingNow: [BalanceKey: AmountE4] = [:]
  ) -> AccountActionOutcome {
    let all = self.all
    let groups = self.groups
    guard let account = all.first(where: { $0.id == id }) else { return .refused(.notFound) }
    guard !account.archived else { return .done }
    var archived = account
    archived.archived = true
    archived.isDefault = false
    if let refusal = archiveRefusal(
      account, books: books, all: all, groups: groups, settling: settling)
    {
      return .refused(refusal)
    }
    if let changed = Self.changedBalance(
      of: account, books: books, expecting: expecting, expectingNow: expectingNow)
    {
      return .refused(.balanceChanged(changed))
    }
    var rows = [archived]
    if account.isDefault {
      switch successor(newMain, leaving: [id], all: all, groups: groups) {
      case .success(let next): rows.append(next)
      case .failure(let refusal): return .refused(refusal)
      }
    }
    let outcome = apply(
      PlanningChange(
        upsert: PlanningRows(paymentMethods: rows, transfers: settling), at: environment.now(),
        expectingBalances: settling.isEmpty ? [:] : expecting,
        expectingBalancesNow: settling.isEmpty ? [:] : expectingNow))
    if outcome == .done, !settling.isEmpty {
      AppLog.info(
        "accounts.archivedSettled", .db, "an account went to the archive with its money moved",
        [LogPair("transfers", .count(settling.count)), LogPair("archive", .flag(true))])
    }
    return outcome
  }

  /// Moves what an account already in the archive still holds — money left there before the
  /// archive kept accounts at zero — to live accounts: the transfers `settling`, one change and
  /// one step of ⌘Z. `expecting` are the amounts the question showed, `expectingNow` what the
  /// keys held now then.
  func settleLeftovers(
    of account: PaymentMethod, books: AccountBooks, settling: [Transfer],
    expecting: [BalanceKey: AmountE4], expectingNow: [BalanceKey: AmountE4] = [:]
  ) -> AccountActionOutcome {
    guard !settling.isEmpty else { return .done }
    if let changed = Self.changedBalance(
      of: account, books: books, expecting: expecting, expectingNow: expectingNow)
    {
      return .refused(.balanceChanged(changed))
    }
    let outcome = apply(
      PlanningChange(
        upsert: PlanningRows(transfers: settling), at: environment.now(),
        expectingBalances: expecting, expectingBalancesNow: expectingNow))
    if outcome == .done {
      AppLog.info(
        "accounts.archivedSettled", .db, "money left on an archived account was moved",
        [LogPair("transfers", .count(settling.count)), LogPair("archive", .flag(false))])
    }
    return outcome
  }

  /// The first key whose money is not what the question showed (`expecting`) — worked out the
  /// way the question worked it out, once everything written on the key has happened
  /// (`ArchivedMoney.balancesToMove`) —, or, with `expectingNow`, whose money now is not what it
  /// held then; `nil` when every amount holds, or when nothing was shown.
  static func changedBalance(
    of account: PaymentMethod, books: AccountBooks, expecting: [BalanceKey: AmountE4],
    expectingNow: [BalanceKey: AmountE4] = [:]
  ) -> BalanceKey? {
    guard !expecting.isEmpty else { return nil }
    let held = ArchivedMoney.balancesToMove(of: account, balances: books.balances)
    let amounts = Dictionary(
      held.leftovers.map { ($0.key, $0.amount) }, uniquingKeysWith: { first, _ in first })
    let now = Dictionary(
      held.leftovers.map { ($0.key, $0.heldNow ?? .zero) }, uniquingKeysWith: { first, _ in first })
    var keys = Set(amounts.keys).union(expecting.keys)
    if !expectingNow.isEmpty { keys.formUnion(expectingNow.keys) }
    return keys.sorted().first { key in
      (amounts[key] ?? .zero) != (expecting[key] ?? .zero)
        || (!expectingNow.isEmpty && (now[key] ?? .zero) != (expectingNow[key] ?? .zero))
    }
  }

  /// Why the account cannot go to the archive now, or `nil`: the last live account stays, and
  /// so does one with money on it — or with a balance nobody knows, which is counted first.
  func archiveRefusal(_ account: PaymentMethod, books: AccountBooks) -> AccountRefusal? {
    archiveRefusal(account, books: books, all: all, groups: groups)
  }

  private func archiveRefusal(
    _ account: PaymentMethod, books: AccountBooks, all: [PaymentMethod], groups: [AccountGroup],
    settling: [Transfer] = []
  ) -> AccountRefusal? {
    var archived = account
    archived.archived = true
    archived.isDefault = false
    let issues = AccountRules.validate(
      archived, previous: account, balances: books.balances, enabled: enabledCurrencies,
      others: all, groups: groups)
    if issues.contains(.archivesLastLiveAccount) { return .lastLiveAccount }
    guard issues.contains(.archivesWithMoney) else { return nil }
    let money = ArchivedMoney.balancesToMove(of: account, balances: books.balances)
    guard money.unknown.isEmpty else { return .balanceUnknown }
    // Money on it goes with it only when a transfer moves every currency that holds some.
    let settled = Set(settling.flatMap { [$0.from, $0.to] })
    let held = money.leftovers.map(\.key)
    if !held.isEmpty, held.allSatisfy(settled.contains) { return nil }
    return held.isEmpty ? nil : .hasMoney
  }

  /// «Вернуть»: back among the live accounts, not main, after every other once the owner has
  /// dragged them. Its name and other names, which a merge left on another account as other
  /// names, go back to it — one name is never on two live accounts —, and a group in the
  /// archive comes back with it unless a live group has taken its name.
  ///
  /// Its currencies are switched on with it: every currency a live account holds is on, or the
  /// entry line would not know it and the bank's table would not be checked for it. When that
  /// would make more than ten, the account stays in the archive. ⌘Z sends the account back to
  /// the archive and leaves the currencies on, which nothing minds.
  func restore(_ id: UUID) -> AccountActionOutcome {
    let all = self.all
    guard var account = all.first(where: { $0.id == id }) else { return .refused(.notFound) }
    guard account.archived else { return .done }
    let name = Self.folded(account.name)
    let live = all.filter { !$0.archived && $0.id != id }
    guard !live.contains(where: { Self.folded($0.name) == name }) else {
      return .refused(.nameTaken)
    }
    // Every currency the account holds is switched on again, however many are on already.
    let enabled = enabledCurrencies
    var missing: [CurrencyCode] = []
    for currency in account.currencies where !enabled.contains(currency) {
      if !missing.contains(currency) { missing.append(currency) }
    }
    var rows = PlanningRows()
    if let groupId = account.groupId,
      var group = groups.first(where: { $0.id == groupId }), group.archived
    {
      let groupName = Self.folded(group.name)
      guard
        !groups.contains(where: {
          !$0.archived && $0.id != groupId && Self.folded($0.name) == groupName
        })
      else { return .refused(.groupNameTaken) }
      group.archived = false
      rows.accountGroups = [group]
    }
    // A live account's name is its own: another name of this one that became it is dropped.
    let liveNames = Set(live.map { Self.folded($0.name) })
    account.aliases.removeAll { liveNames.contains(Self.folded($0)) }
    let names = Set(([account.name] + account.aliases).map(Self.folded))
    switch bank(forRestoring: account) {
    case .success(let placed):
      account.bankId = placed.bankId
      rows.banks = placed.rows
    case .failure(let refusal):
      return .refused(refusal)
    }
    account.archived = false
    account.isDefault = false
    account.sort = AccountRules.sortForNewAccount(among: live)
    var accounts = [account]
    for var other in live {
      let before = other.aliases.count
      other.aliases.removeAll { names.contains(Self.folded($0)) }
      if other.aliases.count != before { accounts.append(other) }
    }
    rows.paymentMethods = accounts
    let outcome = apply(PlanningChange(upsert: rows, at: environment.now()))
    guard outcome == .done, !missing.isEmpty else { return outcome }
    // The account is back either way; a currency the database would not switch on is said in
    // the journal and stays offered in Settings → Валюты.
    environment.attempt("settings.currencies", on: environment.settings) {
      try $0.setEnabledCurrencies(enabled + missing)
    }
    environment.refreshAccountSettings()
    environment.refreshVocabulary()
    return outcome
  }

  /// «Сортировать по алфавиту»: every place the owner dragged an account to is forgotten.
  func alphabetize() -> AccountActionOutcome {
    let changed = AccountRules.alphabetized(all.filter { $0.sort != 0 })
    guard !changed.isEmpty else { return .done }
    return apply(
      PlanningChange(upsert: PlanningRows(paymentMethods: changed), at: environment.now()))
  }

  /// A drag in the list of live accounts, in the terms of `onMove`: the accounts are numbered
  /// 1…n in the new order, the main account staying first.
  func reorder(from source: IndexSet, to destination: Int) -> AccountActionOutcome {
    let before = ordered(all)
    let after = Self.reordered(before, from: source, to: destination)
    let old = Dictionary(uniqueKeysWithValues: before.map { ($0.id, $0.sort) })
    let changed = after.filter { old[$0.id] != $0.sort }
    guard !changed.isEmpty else { return .done }
    return apply(
      PlanningChange(upsert: PlanningRows(paymentMethods: changed), at: environment.now()))
  }

  /// «Выше» (`by: -1`) or «Ниже» (`by: 1`): a drag by one place, for the keyboard and
  /// VoiceOver. The main account stays first, so nothing moves above it.
  func move(_ id: UUID, by step: Int) -> AccountActionOutcome {
    let list = ordered(all)
    guard let index = list.firstIndex(where: { $0.id == id }), !list[index].isDefault else {
      return .done
    }
    let target = index + step
    guard list.indices.contains(target), !list[target].isDefault else { return .done }
    return reorder(from: [index], to: step > 0 ? target + 1 : target)
  }

  /// The live accounts in list order after a drag, numbered 1…n; the main account stays first
  /// whatever was dragged over it.
  static func reordered(
    _ accounts: [PaymentMethod], from source: IndexSet, to destination: Int
  ) -> [PaymentMethod] {
    var list = accounts
    list.move(fromOffsets: source, toOffset: destination)
    if let main = list.firstIndex(where: \.isDefault), main != 0 {
      list.insert(list.remove(at: main), at: 0)
    }
    for position in list.indices { list[position].sort = position + 1 }
    return list
  }

  // MARK: Groups, one step of ⌘Z each

  /// Saves a new group or an edit of one.
  func save(group: AccountGroup) -> AccountActionOutcome {
    var group = group
    group.name = group.name.trimmingCharacters(in: .whitespacesAndNewlines)
    let groups = self.groups
    let issues = AccountRules.validate(group: group, accounts: all)
    if issues.contains(.emptyName) { return .refused(.emptyName) }
    if issues.contains(.holdsMain) { return .refused(.groupHoldsMain) }
    let name = Self.folded(group.name)
    if let rival = groups.first(where: { $0.id != group.id && Self.folded($0.name) == name }) {
      return .refused(rival.archived ? .inArchive(rival.id) : .groupNameTaken)
    }
    if !groups.contains(where: { $0.id == group.id }) {
      let highest = groups.map(\.sort).max() ?? 0
      group.sort = highest > 0 ? highest + 1 : 0
    }
    return apply(
      PlanningChange(upsert: PlanningRows(accountGroups: [group]), at: environment.now()))
  }

  /// «Учитывать в общей сводке». A group that holds the main account stays in.
  func setInSummary(_ id: UUID, _ isOn: Bool) -> AccountActionOutcome {
    guard var group = groups.first(where: { $0.id == id }) else { return .refused(.notFound) }
    guard group.inSummary != isOn else { return .done }
    group.inSummary = isOn
    return save(group: group)
  }

  /// A group goes to the archive once every account in it has.
  func archiveGroup(_ id: UUID) -> AccountActionOutcome {
    guard var group = groups.first(where: { $0.id == id }) else { return .refused(.notFound) }
    guard !group.archived else { return .done }
    guard !all.contains(where: { $0.groupId == id && !$0.archived }) else {
      return .refused(.groupHasLiveAccounts)
    }
    group.archived = true
    return apply(
      PlanningChange(upsert: PlanningRows(accountGroups: [group]), at: environment.now()))
  }

  /// «Вернуть» for a group.
  func restoreGroup(_ id: UUID) -> AccountActionOutcome {
    guard var group = groups.first(where: { $0.id == id }) else { return .refused(.notFound) }
    guard group.archived else { return .done }
    let name = Self.folded(group.name)
    guard !groups.contains(where: { !$0.archived && Self.folded($0.name) == name }) else {
      return .refused(.groupNameTaken)
    }
    group.archived = false
    return apply(
      PlanningChange(upsert: PlanningRows(accountGroups: [group]), at: environment.now()))
  }

  // MARK: For good

  /// The merge of `sourceId` into `targetId`, worked out: the currencies of both, the main
  /// flag, the balances together, the transfers between them that go. The old name and other
  /// names of the source become other names of the target, so the entry line still knows
  /// them. `answers` are balances the owner counted for keys the books cannot work out.
  func mergePreview(
    _ sourceId: UUID, into targetId: UUID, answers: [BalanceKey: AmountE4] = [:],
    books: AccountBooks
  ) -> AccountMergePreview? {
    let all = self.all
    guard sourceId != targetId,
      let source = all.first(where: { $0.id == sourceId && !$0.archived }),
      let target = all.first(where: { $0.id == targetId && !$0.archived })
    else { return nil }
    return Self.mergePreview(
      source: source, target: target, answers: answers, books: books, at: environment.now())
  }

  /// The accounts `source` can be merged into, in list order: the other live accounts of its
  /// bank (`AccountMerge.canMerge`) — and, when the main account is merged away, only those in
  /// the summary, since the target takes over as main. An account under no bank is offered
  /// nothing.
  func mergeTargets(for source: PaymentMethod) -> [PaymentMethod] {
    let groups = self.groups
    return ordered(all).filter {
      AccountMerge.canMerge(source, into: $0)
        && !(source.isDefault && Self.isInExcludedGroup($0, groups: groups))
    }
  }

  static func mergePreview(
    source: PaymentMethod, target: PaymentMethod, answers: [BalanceKey: AmountE4],
    books: AccountBooks, at: Date
  ) -> AccountMergePreview {
    var (plan, needs) = AccountMerge.plan(
      source: source, target: target, transfers: books.dataset.transfers,
      balances: books.balances, at: at)
    let own = folded(plan.target.name)
    for name in [source.name] + source.aliases {
      let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
      let key = folded(trimmed)
      guard !key.isEmpty, key != own, !plan.target.aliases.contains(where: { folded($0) == key })
      else { continue }
      plan.target.aliases.append(trimmed)
    }
    for key in needs {
      if let amount = answers[key] { plan.count(key, typed: amount) }
    }
    return AccountMergePreview(
      plan: plan, needsBalance: needs,
      balancesAfter: AccountMerge.balancesAfter(plan, source: source.id, balances: books.balances))
  }

  /// Merges the account into another of its bank, for good; the ⌘Z history is forgotten after
  /// it. Accounts of two banks are refused (`otherBank`), here and by the repository.
  func merge(_ preview: AccountMergePreview) -> AccountActionOutcome {
    guard let repository = environment.accounts else { return .failed }
    let all = self.all
    guard let source = all.first(where: { $0.id == preview.plan.sourceId }),
      let target = all.first(where: { $0.id == preview.plan.target.id })
    else { return .refused(.notFound) }
    guard AccountMerge.canMerge(source, into: target) else { return .refused(.otherBank) }
    if preview.plan.target.isDefault,
      Self.isInExcludedGroup(preview.plan.target, groups: groups)
    {
      return .refused(.mainInExcludedGroup)
    }
    do {
      try repository.merge(preview.plan, calendar: environment.calendar)
    } catch AccountWriteError.notFound {
      return .refused(.notFound)
    } catch AccountWriteError.otherBank {
      return .refused(.otherBank)
    } catch {
      AppLog.error(
        "accounts.merge", .db, "the accounts were not merged",
        [LogPair("error", .error(error)), LogPair("code", .count((error as NSError).code))])
      return .failed
    }
    AppLog.info(
      "accounts.merged", .db, "two accounts were merged",
      [
        LogPair("transfers", .count(preview.deletedTransfers)),
        LogPair("counted", .count(preview.plan.opening.count)),
      ])
    settleForGood()
    return .done
  }

  /// Deletes accounts nothing points at, for good; the ⌘Z history is forgotten after it. An
  /// account a count says holds money stays, as it stays out of the archive: its money would
  /// leave every total for good. When the main account is among them, `newMain` takes the flag
  /// first — a step of its own, forgotten with the rest.
  func delete(
    _ ids: [UUID], newMain: UUID? = nil, losingMoney: Bool = false
  ) -> AccountActionOutcome {
    guard let repository = environment.accounts, !ids.isEmpty else { return .failed }
    let all = self.all
    for id in ids {
      guard all.contains(where: { $0.id == id }) else { return .refused(.notFound) }
      guard let usage = try? repository.usage(of: id) else { return .failed }
      if usage.isUsed { return .refused(.inUse(id, usage)) }
    }
    var nextMain: PaymentMethod?
    if all.contains(where: { ids.contains($0.id) && $0.isDefault && !$0.archived }) {
      switch successor(newMain, leaving: Set(ids), all: all, groups: groups) {
      case .success(let next): nextMain = next
      case .failure(let refusal): return .refused(refusal)
      }
    }
    guard let held = heldMoney(on: ids) else { return .failed }
    // Money typed or counted on an account nothing points at leaves the totals with it: only
    // after the owner was told how much.
    if !held.isEmpty, !losingMoney { return .refused(.deletesWithMoney) }
    if let nextMain {
      guard
        store.apply(
          PlanningChange(upsert: PlanningRows(paymentMethods: [nextMain]), at: environment.now()))
      else { return .failed }
    }
    var deleted = 0
    defer {
      if deleted > 0 {
        AppLog.info(
          "accounts.deleted", .db, "accounts were deleted", [LogPair("count", .count(deleted))])
        settleForGood()
      }
    }
    for id in ids {
      do {
        try repository.delete(id)
        deleted += 1
      } catch AccountWriteError.inUse(let usage) {
        return .refused(.inUse(id, usage))
      } catch {
        AppLog.error(
          "accounts.delete", .db, "an account was not deleted",
          [LogPair("error", .error(error)), LogPair("code", .count((error as NSError).code))])
        return .failed
      }
    }
    return .done
  }

  /// The money counts say is on `ids` — «Остаток сейчас» typed when an account was made is one,
  /// a credit card below zero too. An account nothing points at holds exactly its last counts;
  /// `nil` when the counts cannot be read.
  func heldMoney(on ids: [UUID]) -> [HeldMoney]? {
    guard let book = try? environment.planning?.book() else { return nil }
    let wanted = Set(ids)
    let balances = AccountBalances.build(
      entries: [], transfers: [], debtEntries: [], debts: [:],
      reconciliations: book.reconciliations, balances: book.reconciledBalances, accounts: all,
      tree: CategoryTree([]), now: environment.now(), calendar: environment.calendar)
    return balances.keys.compactMap { key -> HeldMoney? in
      guard wanted.contains(key.accountId), let amount = balances[key]?.amountE4, !amount.isZero
      else { return nil }
      return HeldMoney(currency: key.currency, amount: amount)
    }.sorted { $0.currency.code < $1.currency.code }
  }

  /// Deletes a group nothing is filed under, for good; the ⌘Z history is forgotten after it.
  func deleteGroup(_ id: UUID) -> AccountActionOutcome {
    guard let repository = environment.accounts else { return .failed }
    do {
      try repository.deleteGroup(id)
    } catch AccountWriteError.groupInUse {
      return .refused(.groupInUse)
    } catch AccountWriteError.notFound {
      return .refused(.notFound)
    } catch {
      AppLog.error(
        "accounts.deleteGroup", .db, "a group was not deleted",
        [LogPair("error", .error(error)), LogPair("code", .count((error as NSError).code))])
      return .failed
    }
    settleForGood()
    return .done
  }

  // MARK: Rules

  /// What keeps `account` from being saved over `previous`, the first thing only. `cards` are
  /// every card: a name or another name of a live card of another account is taken.
  static func refusal(
    saving account: PaymentMethod, previous: PaymentMethod?, books: AccountBooks,
    enabled: [CurrencyCode], all: [PaymentMethod], groups: [AccountGroup],
    cards: [PaymentCard] = []
  ) -> AccountRefusal? {
    let name = folded(account.name)
    if previous == nil, !name.isEmpty,
      let archived = all.first(where: {
        $0.archived && $0.id != account.id && folded($0.name) == name
      }),
      !all.contains(where: { !$0.archived && $0.id != account.id && folded($0.name) == name })
    {
      return .inArchive(archived.id)
    }
    let issues = AccountRules.validate(
      account, previous: previous, balances: books.balances, enabled: enabled, others: all,
      groups: groups)
    for issue in issues {
      switch issue {
      case .emptyName: return .emptyName
      case .nameTaken: return .nameTaken
      case .duplicateCurrency: return .duplicateCurrency
      case .currencyNotEnabled(let currency): return .currencyNotEnabled(currency)
      case .removesCurrencyWithMoney(let currency):
        let key = BalanceKey(accountId: account.id, currency: currency)
        return books.isUnknown(key)
          ? .currencyBalanceUnknown(currency) : .removesCurrencyWithMoney(currency)
      case .archivesWithMoney: return .hasMoney
      case .archivesMain: return .needsNewMain
      case .archivesLastLiveAccount: return .lastLiveAccount
      case .mainInExcludedGroup: return .mainInExcludedGroup
      }
    }
    // Checked again the way the entry line reads names, «ё» folded into «е»: «Ёлка» and
    // «Елка» are one name there, so they are one name here too.
    if !name.isEmpty,
      all.contains(where: {
        $0.id != account.id
          && (folded($0.name) == name || $0.aliases.contains { folded($0) == name })
      })
    {
      return .nameTaken
    }
    for spelling in [account.name] + account.aliases {
      if let card = CardRules.cardTaking(spelling, except: account.id, cards: cards) {
        return .nameTakenByCard(card.name)
      }
    }
    let rivals = all.filter { !$0.archived && $0.id != account.id }
    for alias in account.aliases {
      let spelling = folded(alias)
      if rivals.contains(where: {
        folded($0.name) == spelling || $0.aliases.contains { folded($0) == spelling }
      }) {
        return .otherNameTaken(alias)
      }
    }
    // The interest goes to another live account; one it already goes to may stay in the
    // archive — the payouts then go to the main account, as for any account gone.
    if let target = account.interest?.payoutAccountId {
      let kept = target == previous?.interest?.payoutAccountId
      if target == account.id || !all.contains(where: { $0.id == target && (kept || !$0.archived) })
      {
        return .interest(.payoutAccount)
      }
    }
    return nil
  }

  /// The name and the other names without the spaces around them; other names empty, repeated
  /// or the same as the name are dropped.
  static func tidied(_ account: PaymentMethod) -> PaymentMethod {
    var account = account
    account.name = account.name.trimmingCharacters(in: .whitespacesAndNewlines)
    var seen: Set<String> = [folded(account.name)]
    account.aliases = account.aliases.compactMap { alias in
      let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
      return seen.insert(folded(trimmed)).inserted && !trimmed.isEmpty ? trimmed : nil
    }
    return account
  }

  /// The account sits in a live group left out of the summary. A group in the archive counts
  /// as none, as everywhere else.
  static func isInExcludedGroup(_ account: PaymentMethod, groups: [AccountGroup]) -> Bool {
    guard let id = account.groupId, let group = groups.first(where: { $0.id == id }) else {
      return false
    }
    return !group.archived && !group.inSummary
  }

  /// Names compared the way the entry line reads them: case, «ё» against «е» and the spaces
  /// around do not count.
  static func folded(_ name: String) -> String {
    String(
      name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().map {
        $0 == "ё" ? "е" : $0
      })
  }

  // MARK: Helpers

  /// The account named to take over as main, made main — or why it cannot be.
  private func successor(
    _ id: UUID?, leaving: Set<UUID>, all: [PaymentMethod], groups: [AccountGroup]
  ) -> Result<PaymentMethod, AccountRefusal> {
    let candidates = all.filter {
      !$0.archived && !leaving.contains($0.id) && !Self.isInExcludedGroup($0, groups: groups)
    }
    guard !candidates.isEmpty else { return .failure(.noSuccessor) }
    guard let id, var next = candidates.first(where: { $0.id == id }) else {
      return .failure(.needsNewMain)
    }
    next.isDefault = true
    return .success(next)
  }

  func apply(_ change: PlanningChange) -> AccountActionOutcome {
    guard store.apply(change) else { return .failed }
    environment.refreshVocabulary()
    return .done
  }

  /// After a write that is not undone: the steps of ⌘Z taken before may name what it removed.
  func settleForGood() {
    store.forgetUndoHistory()
    environment.scheduleBackup()
    environment.refreshVocabulary()
  }
}

// MARK: - Words

/// The words of the accounts, shared by the settings, the editors and the sidebar.
@MainActor
enum AccountText {
  static let table = "Accounts"

  static func kindKey(_ kind: PaymentMethodKind) -> String {
    switch kind {
    case .card: "account.kind.card"
    case .cash: "account.kind.cash"
    case .account: "account.kind.account"
    case .other: "account.kind.other"
    }
  }

  /// A symbol for the kind, beside its name — never the only thing that tells it.
  static func kindSymbol(_ kind: PaymentMethodKind) -> String {
    switch kind {
    case .card: "creditcard"
    case .cash: "banknote"
    case .account: "building.columns"
    case .other: "wallet.bifold"
    }
  }

  /// The name of a group, with «не в сводке» when its money is left out of the summary.
  static func groupTitle(_ group: AccountGroup, _ environment: AppEnvironment) -> String {
    group.inSummary
      ? group.name
      : environment.format("account.group.excludedTitle", table: table, group.name)
  }

  /// What the deletion question says: that nothing refers to the account — and, when counts
  /// put money on it, how much leaves every total with it.
  static func deleteMessage(
    count: Int, held: [HeldMoney], _ environment: AppEnvironment
  ) -> String {
    guard !held.isEmpty else {
      return environment.language(
        count == 1 ? "accounts.delete.message" : "accounts.delete.messageMany", table: table)
    }
    let amounts = held.map { environment.money.exact($0.amount, currency: $0.currency) }
      .joined(separator: ", ")
    return environment.format(
      count == 1 ? "accounts.delete.messageMoney" : "accounts.delete.messageMoneyMany",
      table: table, amounts)
  }

  /// Why an action was not taken, in words.
  static func message(_ refusal: AccountRefusal, _ environment: AppEnvironment) -> String {
    func t(_ key: String) -> String { environment.language(key, table: table) }
    switch refusal {
    case .emptyName: return t("account.refusal.emptyName")
    case .nameTaken: return t("account.refusal.nameTaken")
    case .nameTakenByCard(let card):
      return environment.format("account.refusal.nameTakenByCard", table: table, card)
    case .otherNameTaken(let name):
      return environment.format("account.refusal.otherNameTaken", table: table, name)
    case .inArchive: return t("account.refusal.inArchive")
    case .noCurrency: return t("account.refusal.noCurrency")
    case .duplicateCurrency: return t("account.refusal.duplicateCurrency")
    case .currencyNotEnabled(let currency):
      return environment.format("account.refusal.currencyNotEnabled", table: table, currency.code)
    case .removesCurrencyWithMoney(let currency):
      return environment.format(
        "account.refusal.removesCurrencyWithMoney", table: table, currency.code)
    case .unreadableBalance(let currency):
      return environment.format("account.refusal.unreadableBalance", table: table, currency.code)
    case .hasMoney: return t("account.refusal.hasMoney")
    case .deletesWithMoney: return t("account.refusal.deletesWithMoney")
    case .balanceUnknown: return t("account.refusal.balanceUnknown")
    case .currencyBalanceUnknown(let currency):
      return environment.format(
        "account.refusal.currencyBalanceUnknown", table: table, currency.code)
    case .lastLiveAccount: return t("account.refusal.lastLiveAccount")
    case .creditCardNeedsCard: return t("account.refusal.creditCardNeedsCard")
    case .needsNewMain: return t("account.refusal.needsNewMain")
    case .noSuccessor: return t("account.refusal.noSuccessor")
    case .mainInExcludedGroup: return t("account.refusal.mainInExcludedGroup")
    case .inUse(_, let usage):
      // An account that is only the points account of another account's cashback has no
      // operations to count: it says what it is.
      let busy = usage.operations + usage.transfers + usage.scheduled + usage.debtEntries > 0
      guard usage.cashbackPoints > 0 else {
        return environment.format(
          "account.refusal.inUse", table: table,
          counts: usage.operations, usage.transfers, usage.scheduled, usage.debtEntries)
      }
      guard busy else {
        return environment.format(
          "account.refusal.inUsePoints", table: table, counts: usage.cashbackPoints)
      }
      return environment.format(
        "account.refusal.inUse", table: table,
        counts: usage.operations, usage.transfers, usage.scheduled, usage.debtEntries) + " "
        + environment.format(
          "account.refusal.inUseAlsoPoints", table: table, counts: usage.cashbackPoints)
    case .groupHoldsMain: return t("account.refusal.groupHoldsMain")
    case .groupHasLiveAccounts: return t("account.refusal.groupHasLiveAccounts")
    case .groupInUse: return t("account.refusal.groupInUse")
    case .groupNameTaken: return t("account.refusal.groupNameTaken")
    case .bankNameTaken: return t("account.refusal.bankNameTaken")
    case .bankHasLiveAccounts: return t("account.refusal.bankHasLiveAccounts")
    case .bankInUse: return t("account.refusal.bankInUse")
    case .otherBank: return t("account.refusal.otherBank")
    case .bankMerge(.archived): return t("bank.merge.refusal.archived")
    case .bankMerge(.notFound), .bankMerge(.sameBank): return t("account.refusal.notFound")
    case .notFound: return t("account.refusal.notFound")
    case .interest(let issue): return t(InterestText.issueKey(issue))
    case .credit(let issue): return t(issue.messageKey)
    case .balanceChanged(let key):
      let name =
        (try? environment.accounts?.accounts(includeArchived: true))?
        .first { $0.id == key.accountId }?.name ?? ""
      return environment.format("archived.leftover.changed", table: table, name)
    }
  }
}

/// A refusal said under the form it came from, with a symbol, never by colour alone. A name
/// that is in the archive offers «Вернуть»; an account in use, which cannot be deleted, offers
/// what can be done with it instead — «Объединить с…» and «В архив».
struct AccountRefusalNote: View {
  @Dependency(\.environment) private var environment
  let refusal: AccountRefusal
  var restore: ((UUID) -> Void)?
  /// For an account in use: opens the merge of it.
  var merge: ((UUID) -> Void)?
  /// For an account in use: moves it to the archive.
  var archive: ((UUID) -> Void)?

  private func t(_ key: String) -> String { environment.language(key, table: AccountText.table) }

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      Image(systemName: "exclamationmark.triangle")
        .foregroundStyle(.orange)
        .accessibilityHidden(true)
      Text(verbatim: AccountText.message(refusal, environment))
        .fixedSize(horizontal: false, vertical: true)
      if case .inArchive(let id) = refusal, let restore {
        Button(t("account.refusal.restore")) { restore(id) }
      }
      if let id = refusal.accountInUse {
        if let merge {
          Button(t("accounts.mergeWith")) { merge(id) }
        }
        if let archive {
          Button(t("accounts.archive")) { archive(id) }
        }
      }
    }
    .appFont(.callout)
    .accessibilityElement(children: .contain)
  }
}

// MARK: - The main account passed on

/// Which account becomes main when the main one goes to the archive or is deleted: a picker of
/// the live accounts in the summary, the most used preselected.
struct MainHandOverSheet: View {
  @Dependency(\.environment) private var environment
  let leaving: PaymentMethod
  let candidates: [PaymentMethod]
  /// «В архив» or «Удалить» — what happens once the owner has chosen.
  let confirmTitle: String
  /// What else the owner is asked to agree to — for a deletion, that it cannot be undone.
  let note: String?
  let confirm: (UUID) -> Void
  let cancel: () -> Void
  @State private var chosen: UUID?

  init(
    leaving: PaymentMethod, candidates: [PaymentMethod], preselected: UUID?,
    confirmTitle: String, note: String? = nil, confirm: @escaping (UUID) -> Void,
    cancel: @escaping () -> Void
  ) {
    self.leaving = leaving
    self.candidates = candidates
    self.confirmTitle = confirmTitle
    self.note = note
    self.confirm = confirm
    self.cancel = cancel
    _chosen = State(initialValue: preselected ?? candidates.first?.id)
  }

  private func t(_ key: String) -> String { environment.language(key, table: AccountText.table) }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(
        verbatim: environment.format(
          "account.handOver.title", table: AccountText.table, leaving.name)
      )
      .appFont(.headline)
      if candidates.isEmpty {
        AccountRefusalNote(refusal: .noSuccessor)
      } else {
        Text(verbatim: t("account.handOver.message"))
          .fixedSize(horizontal: false, vertical: true)
        Picker(selection: $chosen) {
          ForEach(candidates, id: \.id) { account in
            Text(verbatim: account.name).tag(UUID?.some(account.id))
          }
        } label: {
          Text(verbatim: t("account.handOver.newMain"))
        }
        if let note {
          Label {
            Text(verbatim: note)
              .fixedSize(horizontal: false, vertical: true)
          } icon: {
            Image(systemName: "exclamationmark.triangle")
          }
        }
      }
      HStack {
        Spacer()
        Button(environment.language("action.cancel"), role: .cancel, action: cancel)
          .keyboardShortcut(.cancelAction)
        Button(confirmTitle, role: .destructive) {
          if let chosen { confirm(chosen) }
        }
        .keyboardShortcut(.defaultAction)
        .disabled(chosen == nil || candidates.isEmpty)
      }
    }
    .padding(20)
    .sheetFrame(width: 420)
  }
}

// MARK: - Merge

/// The merge of one account into another, asked before it is made: into which account, what
/// the merged account will hold, what the owner still has to count, how many transfers between
/// the two go. A merge is not undone, and the sheet says so.
struct AccountMergeSheet: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.store) private var store
  let source: PaymentMethod
  let targets: [PaymentMethod]
  /// Called once the sheet is done with: whether the accounts were merged.
  let finish: (Bool) -> Void

  @State private var target: UUID?
  @State private var books: AccountBooks?
  /// Balances typed for keys the books cannot work out, as typed.
  @State private var answers: [BalanceKey: String] = [:]
  @State private var refusal: AccountRefusal?
  @State private var failed = false
  /// The books could not be read: nothing is worked out, and the alert says so.
  @State private var unreadable = false
  /// The source has cards: they move to the kept account with it.
  @State private var sourceHasCards = false

  init(
    source: PaymentMethod, targets: [PaymentMethod], preselected: UUID?,
    finish: @escaping (Bool) -> Void
  ) {
    self.source = source
    self.targets = targets
    self.finish = finish
    _target = State(initialValue: preselected ?? targets.first?.id)
  }

  private var actions: AccountActions { AccountActions(environment: environment, store: store) }

  private func t(_ key: String) -> String { environment.language(key, table: AccountText.table) }

  private var preview: AccountMergePreview? {
    guard let books, let target else { return nil }
    return actions.mergePreview(source.id, into: target, books: books)
  }

  private var targetName: String {
    targets.first { $0.id == target }?.name ?? ""
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(
        verbatim: environment.format("account.merge.title", table: AccountText.table, source.name)
      )
      .appFont(.headline)
      Picker(selection: $target) {
        ForEach(targets, id: \.id) { account in
          Text(verbatim: account.name).tag(UUID?.some(account.id))
        }
      } label: {
        Text(verbatim: t("account.merge.into"))
      }
      if let preview {
        details(preview)
      } else if !unreadable {
        ProgressView()
          .controlSize(.small)
      }
      if let refusal {
        AccountRefusalNote(refusal: refusal)
      }
      HStack {
        Spacer()
        Button(environment.language("action.cancel"), role: .cancel) { finish(false) }
          .keyboardShortcut(.cancelAction)
        Button(t("account.merge.confirm"), role: .destructive, action: merge)
          .disabled(preview == nil || store.isWritingInBackground)
      }
    }
    .padding(20)
    .sheetFrame(width: 460)
    .task {
      sourceHasCards = actions.cards.contains { $0.accountId == source.id }
      books = await actions.books()
      if books == nil {
        unreadable = true
        failed = true
      }
    }
    .onChange(of: target) { _, _ in
      answers = [:]
      refusal = nil
    }
    .refusedWriteAlert($failed, environment)
  }

  @ViewBuilder
  private func details(_ preview: AccountMergePreview) -> some View {
    // What the merged account will hold now; a key asked for is typed below instead.
    let counted = preview.balancesAfter.filter { !preview.needsBalance.contains($0.key) }
      .sorted { $0.key.currency.code < $1.key.currency.code }
    if !counted.isEmpty || !preview.needsBalance.isEmpty {
      Text(
        verbatim: environment.format(
          "account.merge.balances", table: AccountText.table, targetName)
      )
      .appFont(.subheadline)
      .foregroundStyle(.secondary)
      Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
        ForEach(counted, id: \.key) { key, amount in
          GridRow {
            Text(verbatim: key.currency.code)
              .appFont(.body.monospaced())
            Text(verbatim: environment.money.exact(amount, currency: key.currency))
              .appFont(.body.monospacedDigit())
          }
        }
        ForEach(preview.needsBalance, id: \.self) { key in
          GridRow {
            Text(verbatim: key.currency.code)
              .appFont(.body.monospaced())
            TextField(
              text: Binding(get: { answers[key] ?? "" }, set: { answers[key] = $0 })
            ) {
              Text(verbatim: t("account.merge.unknown"))
            }
            .appFont(.body.monospacedDigit())
            .frame(width: 160)
          }
        }
      }
      if !preview.needsBalance.isEmpty {
        Text(
          verbatim: preview.needsBalance.contains(where: preview.keepsItsCountWhenEmpty)
            ? environment.format(
              "account.merge.emptyKeepsCount", table: AccountText.table, targetName)
            : t("account.merge.unknownHint")
        )
        .appFont(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }
    }
    if preview.deletedTransfers > 0 {
      Label {
        Text(
          verbatim: environment.format(
            "account.merge.transfers", table: AccountText.table, counts: preview.deletedTransfers))
      } icon: {
        Image(systemName: "arrow.left.arrow.right")
      }
    }
    if source.isDefault {
      Label {
        Text(
          verbatim: environment.format(
            "account.merge.mainMoves", table: AccountText.table, targetName))
      } icon: {
        Image(systemName: "star.fill")
      }
    }
    if sourceHasCards {
      Label {
        Text(
          verbatim: environment.format(
            "account.merge.cardsMove", table: AccountText.table, source.name, targetName))
      } icon: {
        Image(systemName: "creditcard")
      }
    }
    Text(
      verbatim: environment.format(
        "account.merge.message", table: AccountText.table, targetName, source.name)
    )
    .fixedSize(horizontal: false, vertical: true)
  }

  private func merge() {
    guard let books, let target else { return }
    var typed: [BalanceKey: AmountE4] = [:]
    for (key, text) in answers where !text.trimmingCharacters(in: .whitespaces).isEmpty {
      guard let amount = AmountField.amount(from: text) else {
        refusal = .unreadableBalance(key.currency)
        return
      }
      typed[key] = amount
    }
    guard
      let preview = actions.mergePreview(source.id, into: target, answers: typed, books: books)
    else {
      refusal = .notFound
      return
    }
    switch actions.merge(preview) {
    case .done: finish(true)
    case .refused(let reason): refusal = reason
    case .failed: failed = true
    }
  }
}
