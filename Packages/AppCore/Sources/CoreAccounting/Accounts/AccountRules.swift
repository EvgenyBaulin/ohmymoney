import CoreKit
import Foundation

/// What is wrong with an account about to be saved.
public enum AccountIssue: Hashable, Sendable {
  case emptyName
  /// Another account is called that, or has it among its other names.
  case nameTaken
  /// A currency is listed twice.
  case duplicateCurrency
  /// A currency of the account is not switched on.
  case currencyNotEnabled(CurrencyCode)
  /// The currency is taken off the account while money is on it.
  case removesCurrencyWithMoney(CurrencyCode)
  /// Into the archive with money still on it.
  case archivesWithMoney
  /// The main account goes into the archive: another becomes main first.
  case archivesMain
  /// The last live account goes into the archive.
  case archivesLastLiveAccount
  /// The main account in a group left out of the summary: its money must count.
  case mainInExcludedGroup
}

/// What is wrong with a group about to be saved.
public enum AccountGroupIssue: Hashable, Sendable {
  case emptyName
  /// The group holds the main account and is being left out of the summary.
  case holdsMain
}

/// What becomes of «Списано со счёта» when an operation is edited.
public struct LegEdit: Hashable, Sendable {
  public enum Outcome: Hashable, Sendable {
    /// The account holds the operation's currency: nothing is charged apart.
    case cleared
    /// Worked out again from the rates; `amount` is `nil` when a rate is missing and the
    /// figure has to be typed.
    case prefilled
    /// Nothing it depends on changed.
    case kept
    /// The figure was typed from the statement and is kept although the operation changed:
    /// the editor asks to check it.
    case keptTyped
  }

  public var outcome: Outcome
  public var currency: CurrencyCode?
  public var amount: AmountE4?

  public init(outcome: Outcome, currency: CurrencyCode? = nil, amount: AmountE4? = nil) {
    self.outcome = outcome
    self.currency = currency
    self.amount = amount
  }
}

/// The rules of the accounts that do not need the database: their order, their sections in
/// the sidebar, which account and currency a new operation takes, what an account charges
/// for an operation in a currency it does not hold, and what may be saved.
public enum AccountRules {

  // MARK: - Order

  /// The order of every menu and list of accounts: the main account first, then the others by
  /// the place the owner dragged them to and, where that is the same, by name — alphabetical
  /// while nothing was dragged. Groups do not reorder a menu. Archived accounts are listed only
  /// with `includeArchived`.
  public static func ordered(
    _ accounts: [PaymentMethod], locale: Locale, includeArchived: Bool = false
  ) -> [PaymentMethod] {
    accounts.filter { includeArchived || !$0.archived }.sorted { left, right in
      precedes(left, right, locale: locale)
    }
  }

  /// A section of the sidebar: a group and its accounts, or the accounts of no group.
  public struct Section: Hashable, Sendable {
    public var group: AccountGroup?
    public var accounts: [PaymentMethod]

    public init(group: AccountGroup?, accounts: [PaymentMethod]) {
      self.group = group
      self.accounts = accounts
    }
  }

  /// The sections of the sidebar, live accounts and groups only: first the section of the main
  /// account — the accounts of no group, or the main account's group — so the main account is
  /// the first row; then the other sections in the summary — the accounts of no group, then the
  /// groups by their place and name; the groups left out of the summary last. Inside a section
  /// the main account first, then by place and name. The accounts of no group are a section
  /// only when there are some.
  public static func sidebarSections(
    accounts: [PaymentMethod], groups: [AccountGroup], locale: Locale
  ) -> [Section] {
    let liveGroups = groups.filter { !$0.archived }
    let known = Set(liveGroups.map(\.id))
    let live = ordered(accounts, locale: locale)
    func members(_ group: UUID?) -> [PaymentMethod] {
      live.filter { account in
        guard let id = account.groupId, known.contains(id) else { return group == nil }
        return id == group
      }
    }
    let sortedGroups = liveGroups.sorted { groupPrecedes($0, $1, locale: locale) }
    let mainGroup = live.first(where: \.isDefault).flatMap { main in
      main.groupId.flatMap { id in liveGroups.first { $0.id == id } }
    }
    var sections: [Section] = []
    let loose = members(nil)
    if let mainGroup {
      sections.append(Section(group: mainGroup, accounts: members(mainGroup.id)))
      if !loose.isEmpty { sections.append(Section(group: nil, accounts: loose)) }
    } else if !loose.isEmpty {
      sections.append(Section(group: nil, accounts: loose))
    }
    for group in sortedGroups where group.inSummary && group.id != mainGroup?.id {
      sections.append(Section(group: group, accounts: members(group.id)))
    }
    for group in sortedGroups where !group.inSummary && group.id != mainGroup?.id {
      sections.append(Section(group: group, accounts: members(group.id)))
    }
    return sections
  }

  /// «Сортировать по алфавиту»: every place the owner dragged to is forgotten.
  public static func alphabetized(_ accounts: [PaymentMethod]) -> [PaymentMethod] {
    accounts.map { account in
      var account = account
      account.sort = 0
      return account
    }
  }

  /// `accounts` in the order shown, the one with `id` moved to `index`, and every account
  /// numbered 1…n in the new order, so the order the owner dragged stays.
  public static func reordered(
    _ accounts: [PaymentMethod], moving id: UUID, to index: Int
  ) -> [PaymentMethod] {
    var list = accounts
    if let from = list.firstIndex(where: { $0.id == id }) {
      let moved = list.remove(at: from)
      list.insert(moved, at: min(max(0, index), list.count))
    }
    for position in list.indices { list[position].sort = position + 1 }
    return list
  }

  /// The place of a new account: after every other once the owner has dragged them, otherwise
  /// alphabetical like the rest.
  public static func sortForNewAccount(among accounts: [PaymentMethod]) -> Int {
    let highest = accounts.map(\.sort).max() ?? 0
    return highest > 0 ? highest + 1 : 0
  }

  /// The account to become main when the main one is archived, merged away or deleted: the
  /// live account with the most live operations, by name where they are equal. A merge always
  /// passes the flag to its target instead.
  public static func mainHandOverCandidate(
    leaving id: UUID, accounts: [PaymentMethod], liveOperations: [UUID: Int]
  ) -> UUID? {
    accounts.filter { !$0.archived && $0.id != id }.min { left, right in
      let leftCount = liveOperations[left.id] ?? 0
      let rightCount = liveOperations[right.id] ?? 0
      if leftCount != rightCount { return leftCount > rightCount }
      if left.name != right.name { return left.name < right.name }
      return left.id.uuidString < right.id.uuidString
    }?.id
  }

  // MARK: - A new operation

  /// The account of a new operation: the one typed or picked; else the account whose screen is
  /// open; else the one last used at the place; else the main account.
  public static func accountForNewOperation(
    typed: UUID?, openAccountScreen: UUID?, lastAtPlace: UUID?, main: UUID?
  ) -> UUID? {
    typed ?? openAccountScreen ?? lastAtPlace ?? main
  }

  /// The currency of a new operation: the one typed; else the main currency of an account the
  /// owner chose — typed, picked, or the one whose screen is open; else the default currency.
  /// An account that came by itself — the place's last one, the main one — does not choose the
  /// currency: every operation has an account, and the default currency would never apply.
  public static func currencyForNewOperation(
    typed: CurrencyCode?, chosenAccount: PaymentMethod?, default defaultCurrency: CurrencyCode
  ) -> CurrencyCode {
    typed ?? chosenAccount?.mainCurrency ?? defaultCurrency
  }

  /// The currency the account is charged in for an operation in `currency`: its main currency
  /// when it does not hold that one; `nil` when it does, and nothing is charged apart.
  public static func legCurrency(
    for currency: CurrencyCode, account: PaymentMethod
  )
    -> CurrencyCode?
  {
    account.holds(currency) ? nil : account.mainCurrency
  }

  // MARK: - «Списано со счёта»

  /// `amount` in another currency through rubles, with one rounding: amount × from ÷ to, the
  /// rates being rubles for one unit (1 for the ruble). `nil` without a usable rate.
  public static func crossConvert(
    _ amount: AmountE4, fromPerUnit: Decimal, toPerUnit: Decimal
  ) -> AmountE4? {
    guard fromPerUnit > 0, toPerUnit > 0 else { return nil }
    return try? AmountE4(decimal: amount.decimal * fromPerUnit / toPerUnit)
  }

  /// What the account is charged for an operation of `amount` in `currency`, as the bank
  /// would show it — to prefill «Списано со счёта», editable:
  ///
  /// * `nil` when the account holds the currency: nothing is charged apart;
  /// * in rubles, the operation's own rubles, `amount × rate` — an untouched prefill changes no
  ///   ruble figure;
  /// * in another currency, the amount through rubles at the rates of `day` — `nil` when a
  ///   rate is missing, and the figure is typed.
  ///
  /// `rate` is the operation's rubles for one unit; without one, the rate of `day`.
  public static func prefillLeg(
    amount: AmountE4, currency: CurrencyCode, rate: Decimal?, day: DateOnly,
    account: PaymentMethod, rates: DayRates
  ) -> AmountE4? {
    guard let leg = legCurrency(for: currency, account: account) else { return nil }
    return prefill(
      amount: amount, currency: currency, rate: rate, day: day, in: leg, rates: rates)
  }

  /// The prefill in the currency `leg`, whatever the account.
  static func prefill(
    amount: AmountE4, currency: CurrencyCode, rate: Decimal?, day: DateOnly,
    in leg: CurrencyCode, rates: DayRates
  ) -> AmountE4? {
    let own = currency == .rub ? Decimal(1) : (rate ?? rates.perUnit(currency, on: day))
    guard let own, own > 0 else { return nil }
    if leg == .rub { return try? AmountE4(decimal: amount.decimal * own) }
    guard let target = rates.perUnit(leg, on: day) else { return nil }
    return crossConvert(amount, fromPerUnit: own, toPerUnit: target)
  }

  /// «Списано со счёта» after an operation is edited (`before` → `after`, on `account`):
  ///
  /// * the account holds the currency → cleared;
  /// * the currency, the amount, the day, the account or the rate changed, and the figure stored
  ///   was the prefill — or there was none → prefilled again;
  /// * changed, but the figure was typed from the statement → kept, and the editor asks to
  ///   check it (`keptTyped`); a figure in a currency the account is not charged in any more
  ///   is prefilled instead, and so is a figure in rubles under a new rate: the rate typed last
  ///   is the owner's later word, and the rubles are what the rate gives;
  /// * nothing of those changed → kept.
  ///
  /// A leg in rubles was typed when it gave the operation a rate of its own (`manual`); any
  /// other leg was typed when it differs from what the prefill gave for `before`.
  ///
  /// A refund taken back from a purchase carries the purchase's rate for its rubles, while its
  /// account received it at the rates of its own day: its leg — in rubles too — is prefilled at
  /// those (`RefundRules.prefillLeg`), and was typed when it differs from that prefill.
  public static func legAfterEdit(
    before: TransactionEntry, after: TransactionDraft, account: PaymentMethod, rates: DayRates,
    calendar: CalendarContext
  ) -> LegEdit {
    guard let leg = legCurrency(for: after.currency, account: account) else {
      return LegEdit(outcome: .cleared)
    }
    let old = before.transaction
    let oldDay = calendar.day(of: old.occurredAt)
    let newDay = calendar.day(of: after.occurredAt)
    let wasRefund = RefundRules.takesBack(before)
    let isRefund = RefundRules.takesBack(after)
    // A new rate of the same currency. A refund taken back from a purchase carries the
    // purchase's rate, and what its account received never follows that rate.
    let rateChanged =
      !isRefund && old.currency == after.currency && after.rate != nil && after.rate != old.rate
    let changed =
      old.currency != after.currency || old.amountE4 != after.amount || oldDay != newDay
      || old.paymentMethodId != after.paymentMethodId || rateChanged
    if !changed {
      return LegEdit(outcome: .kept, currency: old.accountCurrency, amount: old.accountAmountE4)
    }
    let refill = LegEdit(
      outcome: .prefilled, currency: leg,
      amount: prefill(
        amount: after.amount, currency: after.currency,
        rate: isRefund
          ? nil : after.currency == old.currency ? (after.rate ?? old.rate) : after.rate,
        day: newDay, in: leg, rates: rates))
    guard let storedCurrency = old.accountCurrency, let stored = old.accountAmountE4,
      storedCurrency == leg
    else { return refill }
    // A figure in rubles is the operation's rubles: kept over a new rate, it would make the save
    // put back the rate it implies, and the rate typed would be lost. The rate typed last is the
    // owner's later word, so the figure follows it.
    if rateChanged, storedCurrency == .rub { return refill }
    let typed: Bool
    if storedCurrency == .rub, !wasRefund {
      typed = old.rateSource == .manual
    } else {
      let original = prefill(
        amount: old.amountE4, currency: old.currency, rate: wasRefund ? nil : old.rate,
        day: oldDay, in: storedCurrency, rates: rates)
      typed = original != stored
    }
    return typed ? LegEdit(outcome: .keptTyped, currency: leg, amount: stored) : refill
  }

  // MARK: - Saving

  /// What is wrong with `account` about to be saved over `previous` (`nil` for a new one).
  ///
  /// `balances` say whether money is on a key, `enabled` the currencies switched on, `others`
  /// every other account — archived ones too — and `groups` whether a group is in the summary.
  public static func validate(
    _ account: PaymentMethod, previous: PaymentMethod?, balances: AccountBalances,
    enabled: [CurrencyCode], others: [PaymentMethod], groups: [AccountGroup] = []
  ) -> [AccountIssue] {
    var issues: [AccountIssue] = []
    let name = folded(account.name)
    if name.isEmpty { issues.append(.emptyName) }
    let rivals = others.filter { $0.id != account.id }
    if !name.isEmpty,
      rivals.contains(where: { folded($0.name) == name || $0.aliases.map(folded).contains(name) })
    {
      issues.append(.nameTaken)
    }
    let listed = [account.mainCurrency] + account.otherCurrencies
    if Set(listed).count != listed.count { issues.append(.duplicateCurrency) }
    for currency in account.currencies where !enabled.contains(currency) {
      issues.append(.currencyNotEnabled(currency))
    }
    if let previous {
      for currency in previous.currencies where !account.holds(currency) {
        let key = BalanceKey(accountId: account.id, currency: currency)
        if hasMoney(key, in: balances) { issues.append(.removesCurrencyWithMoney(currency)) }
      }
      if account.archived, !previous.archived {
        let keys =
          previous.currencies.map { BalanceKey(accountId: account.id, currency: $0) }
          + balances.keys.filter { $0.accountId == account.id }
        if keys.contains(where: { hasMoney($0, in: balances) }) {
          issues.append(.archivesWithMoney)
        }
        if previous.isDefault || account.isDefault { issues.append(.archivesMain) }
        if !rivals.contains(where: { !$0.archived }) { issues.append(.archivesLastLiveAccount) }
      }
    }
    if account.isDefault, let groupId = account.groupId,
      groups.first(where: { $0.id == groupId })?.inSummary == false
    {
      issues.append(.mainInExcludedGroup)
    }
    return issues
  }

  /// The account whose name `name` would clash with, for the account `account` about to take
  /// it: another account of `among` — archived ones too — named so, or holding it among its
  /// other names, by the same folding `validate` uses. A clash by name wins over one by other
  /// name; among several, the first in `among`. `byOtherName` says which it is, so the words
  /// can name the account whose other name is in the way. `nil` when the name is free or empty.
  public static func rival(
    of name: String, account: UUID, among accounts: [PaymentMethod]
  ) -> (account: PaymentMethod, byOtherName: Bool)? {
    let folded = folded(name)
    guard !folded.isEmpty else { return nil }
    let others = accounts.filter { $0.id != account }
    if let named = others.first(where: { Self.folded($0.name) == folded }) {
      return (named, false)
    }
    if let aliased = others.first(where: { $0.aliases.map(Self.folded).contains(folded) }) {
      return (aliased, true)
    }
    return nil
  }

  /// What is wrong with `group` about to be saved: a group that holds the main account is never
  /// left out of the summary.
  public static func validate(
    group: AccountGroup, accounts: [PaymentMethod]
  )
    -> [AccountGroupIssue]
  {
    var issues: [AccountGroupIssue] = []
    if group.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      issues.append(.emptyName)
    }
    if !group.inSummary,
      accounts.contains(where: { $0.isDefault && !$0.archived && $0.groupId == group.id })
    {
      issues.append(.holdsMain)
    }
    return issues
  }

  /// Money is on the key: a balance that is not zero now, or once everything written on it has
  /// happened — an operation typed ahead of now counts (`AccountBalances.balanceAhead`) —, or
  /// movements on a key never counted — a balance nobody knows is not taken for zero.
  static func hasMoney(_ key: BalanceKey, in balances: AccountBalances) -> Bool {
    if let amount = balances.balanceAhead(key) {
      return !amount.isZero || !(balances.balance(key, at: balances.now) ?? .zero).isZero
    }
    return balances.hasHistory(key)
  }

  // MARK: - Helpers

  static func precedes(_ left: PaymentMethod, _ right: PaymentMethod, locale: Locale) -> Bool {
    let leftMain = left.isDefault && !left.archived
    let rightMain = right.isDefault && !right.archived
    if leftMain != rightMain { return leftMain }
    if left.sort != right.sort { return left.sort < right.sort }
    switch left.name.compare(right.name, options: [.caseInsensitive], range: nil, locale: locale) {
    case .orderedAscending: return true
    case .orderedDescending: return false
    case .orderedSame: return left.id.uuidString < right.id.uuidString
    }
  }

  static func groupPrecedes(_ left: AccountGroup, _ right: AccountGroup, locale: Locale) -> Bool {
    if left.sort != right.sort { return left.sort < right.sort }
    switch left.name.compare(right.name, options: [.caseInsensitive], range: nil, locale: locale) {
    case .orderedAscending: return true
    case .orderedDescending: return false
    case .orderedSame: return left.id.uuidString < right.id.uuidString
    }
  }

  /// A name as the entry line reads it: case, «ё» against «е» and the spaces around do not
  /// count, so «Ёлка» and « елка » are one name.
  private static func folded(_ name: String) -> String {
    String(
      name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().map {
        $0 == "ё" ? "е" : $0
      })
  }
}
