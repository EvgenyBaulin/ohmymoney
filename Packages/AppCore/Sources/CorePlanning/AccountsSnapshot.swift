import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation

/// The money on the accounts as the sidebar, the account screens and the free sum show it:
/// every live account with its balance per currency (`AccountBalances`), the sections of the
/// sidebar (`AccountRules.sidebarSections`) and the totals in rubles.
///
/// * A balance is in its own currency. Rubles are only for showing and adding up: each
///   balance is converted at today's rate (`rubPerUnit`, rubles for one unit) and rounded on
///   its own, so a rate that moves never looks like money that came or went.
/// * A total adds only balances that are known — counted at least once — of live accounts. An
///   archived account is in no section and in no total. A balance whose currency has no rate
///   today adds nothing and its currency is listed in `withoutRate` — of its account, of its
///   section and of the whole — never guessed: a total that could convert nothing is `nil`,
///   not «0 ₽».
/// * «Всего» (`inSummaryTotalRub`) adds the sections in the summary: the accounts of no group
///   and the groups that count in it. A group left out keeps its own total apart, and its
///   income and spending still count everywhere else.
public struct AccountsSnapshot: Hashable, Sendable {
  /// One currency of one account.
  public struct KeyLine: Hashable, Sendable {
    public var key: BalanceKey
    /// In the key's currency; `nil` while it was never counted.
    public var balance: AmountE4?
    /// The balance in rubles at today's rate; `nil` while it was never counted or without a
    /// rate.
    public var rub: AmountE4?
    /// The moment of the latest count the balance starts from.
    public var anchorAt: Date?
    /// The account holds the currency. A currency it does not hold only appears when money
    /// moved in it anyway — an operation made before the currencies of the account were
    /// listed — and is shown as «вне списка валют».
    public var isHeld: Bool

    public init(
      key: BalanceKey, balance: AmountE4?, rub: AmountE4?, anchorAt: Date?, isHeld: Bool
    ) {
      self.key = key
      self.balance = balance
      self.rub = rub
      self.anchorAt = anchorAt
      self.isHeld = isHeld
    }
  }

  /// One account: its currencies in the account's own order first, then those it does not
  /// hold, by code.
  public struct AccountLine: Hashable, Sendable {
    public var account: PaymentMethod
    public var keys: [KeyLine]
    /// The known balances in rubles; `nil` while none of them was counted and converted.
    public var totalRub: AmountE4?
    /// Currencies of the account never counted: their money is not in any total until a count.
    public var unknown: Int
    /// Currencies of counted balances without a rate today, by code: left out of `totalRub`.
    public var withoutRate: [CurrencyCode]

    public init(
      account: PaymentMethod, keys: [KeyLine], totalRub: AmountE4?, unknown: Int,
      withoutRate: [CurrencyCode] = []
    ) {
      self.account = account
      self.keys = keys
      self.totalRub = totalRub
      self.unknown = unknown
      self.withoutRate = withoutRate
    }
  }

  /// A section of the sidebar: a group and its accounts, or the accounts of no group.
  public struct Section: Hashable, Sendable {
    public var group: AccountGroup?
    public var accounts: [AccountLine]
    /// The accounts' totals added up; `nil` while none of them has one.
    public var totalRub: AmountE4?
    /// The accounts of no group always count; a group counts as its switch says.
    public var inSummary: Bool
    /// The currencies its accounts left out for want of a rate today, by code.
    public var withoutRate: [CurrencyCode]

    public init(
      group: AccountGroup?, accounts: [AccountLine], totalRub: AmountE4?, inSummary: Bool,
      withoutRate: [CurrencyCode] = []
    ) {
      self.group = group
      self.accounts = accounts
      self.totalRub = totalRub
      self.inSummary = inSummary
      self.withoutRate = withoutRate
    }
  }

  /// In the order of the sidebar: the main account's section first, the groups left out of
  /// the summary last.
  public var sections: [Section]
  /// «Всего»: the sections in the summary added up; `nil` while no balance of theirs was
  /// counted — there is nothing to show but «сделайте первую сверку». Once one was, it adds
  /// what could be converted, and `inSummaryWithoutRate` says what could not.
  public var inSummaryTotalRub: AmountE4?
  /// Currencies of live accounts never counted, in the order of the sidebar.
  public var unanchored: [BalanceKey]
  /// Currencies of counted balances without a rate today, by code: left out of every total.
  public var withoutRate: [CurrencyCode]
  /// Every balance, archived accounts included, with its movements.
  public var balances: AccountBalances
  /// Every account whose money is kept out of «Всего» — archived ones included: those of a
  /// live group left out of the summary.
  public var leftOut: Set<UUID>

  public init(
    sections: [Section], inSummaryTotalRub: AmountE4?, unanchored: [BalanceKey],
    withoutRate: [CurrencyCode], balances: AccountBalances, leftOut: Set<UUID> = []
  ) {
    self.sections = sections
    self.inSummaryTotalRub = inSummaryTotalRub
    self.unanchored = unanchored
    self.withoutRate = withoutRate
    self.balances = balances
    self.leftOut = leftOut
  }

  /// No account at all.
  public static let empty = AccountsSnapshot(
    sections: [], inSummaryTotalRub: nil, unanchored: [], withoutRate: [], balances: .empty)

  /// The sections left out of the summary, each with its own total.
  public var excluded: [Section] { sections.filter { !$0.inSummary } }

  /// The currencies «Всего» left out for want of a rate today, by code.
  public var inSummaryWithoutRate: [CurrencyCode] {
    Self.byCode(sections.filter(\.inSummary).flatMap(\.withoutRate))
  }

  /// The line of a live account; `nil` for an archived or unknown one.
  public func line(of accountId: UUID) -> AccountLine? {
    for section in sections {
      if let line = section.accounts.first(where: { $0.account.id == accountId }) {
        return line
      }
    }
    return nil
  }

  /// Whether the money of an account counts in «Всего». No account means the main one, which
  /// always counts. An archived account keeps its group: one of a group left out stays out,
  /// so a payment still pointing at it is not taken from the money in the summary.
  public func isInSummary(_ accountId: UUID?) -> Bool {
    guard let accountId else { return true }
    return !leftOut.contains(accountId)
  }

  /// The same snapshot with the sidebar in the order of `locale`: the language can change
  /// while the snapshot stays, and every list and menu has to show the accounts in one order.
  /// Nothing but the order changes.
  public func ordered(locale: Locale) -> AccountsSnapshot {
    let lines = sections.flatMap(\.accounts)
    let lineById = Dictionary(lines.map { ($0.account.id, $0) }, uniquingKeysWith: { a, _ in a })
    let sectionByGroup = Dictionary(
      sections.map { ($0.group?.id, $0) }, uniquingKeysWith: { a, _ in a })
    var copy = self
    copy.sections = AccountRules.sidebarSections(
      accounts: lines.map(\.account), groups: sections.compactMap(\.group), locale: locale
    ).map { section in
      let before = sectionByGroup[section.group?.id]
      return Section(
        group: section.group, accounts: section.accounts.compactMap { lineById[$0.id] },
        totalRub: before?.totalRub, inSummary: before?.inSummary ?? true,
        withoutRate: before?.withoutRate ?? [])
    }
    copy.unanchored = copy.sections.flatMap(\.accounts).flatMap { line in
      line.keys.filter { $0.isHeld && $0.balance == nil }.map(\.key)
    }
    return copy
  }

  /// The accounts of `dataset` as of `now`. `localeIdentifier` orders the names the way the
  /// interface language does.
  public static func build(
    dataset: Dataset, now: Date, calendar: CalendarContext,
    rubPerUnit: [CurrencyCode: Decimal], localeIdentifier: String
  ) -> AccountsSnapshot {
    let balances = AccountBalances.build(
      entries: dataset.entries, transfers: dataset.transfers,
      debtEntries: dataset.planning.debtEntries, debts: dataset.debtsById,
      reconciliations: dataset.planning.reconciliations,
      balances: dataset.planning.reconciledBalances, accounts: dataset.paymentMethods,
      tree: CategoryTree(dataset.categories), now: now, calendar: calendar)
    return build(
      balances: balances, accounts: dataset.paymentMethods, groups: dataset.accountGroups,
      rubPerUnit: rubPerUnit, locale: Locale(identifier: localeIdentifier))
  }

  /// The same from balances already worked out.
  public static func build(
    balances: AccountBalances, accounts: [PaymentMethod], groups: [AccountGroup],
    rubPerUnit: [CurrencyCode: Decimal], locale: Locale
  ) -> AccountsSnapshot {
    // The keys the balances know of each account, for the currencies it does not hold.
    var otherKeys: [UUID: [BalanceKey]] = [:]
    for key in balances.keys {
      otherKeys[key.accountId, default: []].append(key)
    }

    var withoutRate: [CurrencyCode] = []
    var unanchored: [BalanceKey] = []
    var summaryTotal = AmountE4.zero
    var summaryCounted = false
    var sections: [Section] = []
    for section in AccountRules.sidebarSections(
      accounts: accounts, groups: groups, locale: locale)
    {
      let inSummary = section.group?.inSummary ?? true
      var lines: [AccountLine] = []
      var sectionTotal = AmountE4.zero
      var sectionConverted = false
      var sectionCounted = false
      var sectionWithoutRate: [CurrencyCode] = []
      for account in section.accounts {
        let held = account.currencies
        let others = (otherKeys[account.id] ?? []).filter { !account.holds($0.currency) }
          .sorted { $0.currency.code < $1.currency.code }
        let keys = held.map { BalanceKey(accountId: account.id, currency: $0) } + others
        var keyLines: [KeyLine] = []
        var total = AmountE4.zero
        var converted = false
        var counted = false
        var unknown = 0
        var lineWithoutRate: [CurrencyCode] = []
        for key in keys {
          let isHeld = account.holds(key.currency)
          let balance = balances[key]
          guard let amount = balance?.amountE4 else {
            if isHeld {
              unknown += 1
              unanchored.append(key)
            }
            keyLines.append(
              KeyLine(key: key, balance: nil, rub: nil, anchorAt: nil, isHeld: isHeld))
            continue
          }
          counted = true
          let rub = SubscriptionMath.rubles(amount, in: key.currency, rubPerUnit: rubPerUnit)
          if let rub {
            total += rub
            converted = true
          } else {
            lineWithoutRate.append(key.currency)
          }
          keyLines.append(
            KeyLine(
              key: key, balance: amount, rub: rub, anchorAt: balance?.anchorAt, isHeld: isHeld))
        }
        let lineMissing = byCode(lineWithoutRate)
        lines.append(
          AccountLine(
            account: account, keys: keyLines, totalRub: converted ? total : nil, unknown: unknown,
            withoutRate: lineMissing))
        sectionTotal += total
        sectionConverted = sectionConverted || converted
        sectionCounted = sectionCounted || counted
        sectionWithoutRate += lineMissing
      }
      let sectionMissing = byCode(sectionWithoutRate)
      sections.append(
        Section(
          group: section.group, accounts: lines,
          totalRub: sectionConverted ? sectionTotal : nil, inSummary: inSummary,
          withoutRate: sectionMissing))
      withoutRate += sectionMissing
      // «Всего» waits for a first count only: a count it cannot convert is said, not hidden.
      if inSummary, sectionCounted {
        summaryTotal += sectionTotal
        summaryCounted = true
      }
    }

    // Kept out of «Всего» is decided by the group, archived accounts too: an archived group is
    // no group, as in the sidebar.
    let excludedGroups = Set(groups.filter { !$0.archived && !$0.inSummary }.map(\.id))
    let leftOut = Set(
      accounts.filter { account in account.groupId.map(excludedGroups.contains) ?? false }
        .map(\.id))

    return AccountsSnapshot(
      sections: sections, inSummaryTotalRub: summaryCounted ? summaryTotal : nil,
      unanchored: unanchored, withoutRate: byCode(withoutRate), balances: balances,
      leftOut: leftOut)
  }

  /// Each currency once, by code.
  private static func byCode(_ currencies: [CurrencyCode]) -> [CurrencyCode] {
    Set(currencies).sorted { $0.code < $1.code }
  }
}
