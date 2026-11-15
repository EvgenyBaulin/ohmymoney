import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation

/// What the owner had and owed at one moment, in rubles: the end of a full month or now.
///
/// «Что есть» is the money on every account — those in the summary, the deposits and savings
/// accounts, the groups left out of the summary —, the assets at their last valuation and the
/// debts owed to me; «что должен» is the debts I owe. Each line is converted at the rate of its
/// day and rounded on its own, then the lines are added up.
public struct CapitalPoint: Hashable, Sendable {
  /// The last day of the month the point closes, or today for «now».
  public var day: DateOnly
  /// The point is «now», not the end of a month.
  public var isNow: Bool
  /// The accounts in the summary that earn no interest.
  public var accountsRub: AmountE4
  /// The deposits and savings accounts (an account with interest terms).
  public var depositsRub: AmountE4
  /// The accounts of the groups left out of the summary.
  public var outOfSummaryRub: AmountE4
  /// The assets at their last valuation on or before `day`.
  public var assetsRub: AmountE4
  /// The debts owed to me by their journals.
  public var owedToMeRub: AmountE4
  /// The debts I owe by their journals and interest, never below zero each.
  public var iOweRub: AmountE4
  /// The money of the accounts marked as the safety cushion.
  public var cushionRub: AmountE4
  /// Balances not counted by `day`: their money is in no figure.
  public var unanchored: [BalanceKey]
  /// Currencies without a rate on `day`: their money is in no figure.
  public var withoutRate: [CurrencyCode]
  /// Assets with no valuation yet by `day` (listed for «now» only).
  public var unvalued: [UUID]
  /// The point lies before the first count of any balance: the books of the accounts had not
  /// begun, so what it shows of them is what the owner said, never a balance.
  public var beforeBooks: Bool
  /// The rough sum the owner named for all accounts, carried to this day along a straight line
  /// to the first count (`PastCash`); shown, never a balance, and part of «что есть».
  public var estimatedCashRub: AmountE4
  /// `estimatedCashRub` is set, even when the sum named is nothing.
  public var cashEstimated: Bool
  /// An asset is worth a point on the straight line from its purchase price to its next
  /// valuation, not a valuation.
  public var straightLineAssets: Bool
  /// A loan I owe is worked out from its schedule since it was taken out (`DebtRestoration`),
  /// not read from the journal.
  public var restoredDebts: Bool
  /// Before the books and no rough sum for the accounts: the point holds the assets and the
  /// debts alone.
  public var withoutCash: Bool

  public init(
    day: DateOnly, isNow: Bool, accountsRub: AmountE4 = .zero, depositsRub: AmountE4 = .zero,
    outOfSummaryRub: AmountE4 = .zero, assetsRub: AmountE4 = .zero,
    owedToMeRub: AmountE4 = .zero, iOweRub: AmountE4 = .zero, cushionRub: AmountE4 = .zero,
    unanchored: [BalanceKey] = [], withoutRate: [CurrencyCode] = [], unvalued: [UUID] = [],
    beforeBooks: Bool = false, estimatedCashRub: AmountE4 = .zero, cashEstimated: Bool = false,
    straightLineAssets: Bool = false, restoredDebts: Bool = false, withoutCash: Bool = false
  ) {
    self.beforeBooks = beforeBooks
    self.estimatedCashRub = estimatedCashRub
    self.cashEstimated = cashEstimated
    self.straightLineAssets = straightLineAssets
    self.restoredDebts = restoredDebts
    self.withoutCash = withoutCash
    self.day = day
    self.isNow = isNow
    self.accountsRub = accountsRub
    self.depositsRub = depositsRub
    self.outOfSummaryRub = outOfSummaryRub
    self.assetsRub = assetsRub
    self.owedToMeRub = owedToMeRub
    self.iOweRub = iOweRub
    self.cushionRub = cushionRub
    self.unanchored = unanchored
    self.withoutRate = withoutRate
    self.unvalued = unvalued
  }

  /// «Что есть».
  public var haveRub: AmountE4 {
    accountsRub + depositsRub + outOfSummaryRub + estimatedCashRub + assetsRub + owedToMeRub
  }

  /// Net worth: what I have less what I owe.
  public var netRub: AmountE4 { haveRub - iOweRub }
}

/// One row of the breakdown of «now»: an account, an asset or a debt.
public struct CapitalLine: Hashable, Sendable {
  /// What the row is.
  public enum Source: Hashable, Sendable {
    case account(UUID)
    case asset(UUID)
    case ownedItem(UUID)
    case debt(UUID)
  }

  /// The block of the breakdown the row is listed under.
  public enum Group: String, Hashable, Sendable, CaseIterable {
    /// «Счета в сводке».
    case accounts
    /// «Вклады и накопительные».
    case deposits
    /// «Вне сводки», by group (`accountGroupId`).
    case outOfSummary
    /// «Имущество», by kind (`assetKind`).
    case assets
    /// «Мне должны».
    case owedToMe
    /// «Что должен».
    case iOwe
  }

  /// Why a row adds nothing.
  public enum Issue: String, Hashable, Sendable {
    /// «Не сверен»: a balance never counted.
    case unanchored
    /// «Нет курса».
    case withoutRate
    /// «Нет оценки»: an asset with no valuation yet.
    case unvalued
  }

  public var source: Source
  public var group: Group
  public var name: String
  public var currency: CurrencyCode
  /// In `currency`; `nil` while it is not known (`issue`).
  public var amount: AmountE4?
  /// In rubles; `nil` while it adds nothing (`issue`).
  public var amountRub: AmountE4?
  /// The group of an account left out of the summary.
  public var accountGroupId: UUID?
  /// The kind of an asset.
  public var assetKind: AssetKind?
  /// Of a debt I owe: the part of the balance that is interest («из них проценты ≈»).
  public var interestRub: AmountE4?
  /// Of a deposit: interest accrued and not paid yet — shown, never counted.
  public var accruedNotCountedRub: AmountE4?
  public var issue: Issue?

  public init(
    source: Source, group: Group, name: String, currency: CurrencyCode, amount: AmountE4?,
    amountRub: AmountE4?, accountGroupId: UUID? = nil, assetKind: AssetKind? = nil,
    interestRub: AmountE4? = nil, accruedNotCountedRub: AmountE4? = nil, issue: Issue? = nil
  ) {
    self.source = source
    self.group = group
    self.name = name
    self.currency = currency
    self.amount = amount
    self.amountRub = amountRub
    self.accountGroupId = accountGroupId
    self.assetKind = assetKind
    self.interestRub = interestRub
    self.accruedNotCountedRub = accruedNotCountedRub
    self.issue = issue
  }
}

/// The rows of «now», «что есть» and «что должен», each in the order the screen lists them.
public struct CapitalBreakdown: Hashable, Sendable {
  public var have: [CapitalLine]
  public var owe: [CapitalLine]

  public init(have: [CapitalLine] = [], owe: [CapitalLine] = []) {
    self.have = have
    self.owe = owe
  }

  public static let empty = CapitalBreakdown()
}

/// Net worth over time: the ends of the full months, oldest first, and «now» last.
public struct CapitalSnapshot: Hashable, Sendable {
  /// Oldest first; the last one is `now`.
  public var points: [CapitalPoint]
  public var now: CapitalPoint
  public var breakdown: CapitalBreakdown
  /// Net worth now less at the end of last month; `nil` without that point.
  public var changeThisMonth: AmountE4?
  public var events: [CapitalEvent]
  /// The day the owner can be asked what was on all the accounts: the earliest purchase or
  /// loan before the first count; `nil` when nothing lies before the books.
  public var pastCashDay: DateOnly?

  public init(
    points: [CapitalPoint], now: CapitalPoint, breakdown: CapitalBreakdown,
    changeThisMonth: AmountE4?, events: [CapitalEvent] = [], pastCashDay: DateOnly? = nil
  ) {
    self.pastCashDay = pastCashDay
    self.points = points
    self.now = now
    self.breakdown = breakdown
    self.changeThisMonth = changeThisMonth
    self.events = events
  }

  /// Nothing known: no point but an empty «now».
  public static let empty: CapitalSnapshot = {
    let now = CapitalPoint(day: DateOnly(year: 1970, month: 1, day: 1), isNow: true)
    return CapitalSnapshot(points: [now], now: now, breakdown: .empty, changeThisMonth: nil)
  }()
}

/// Builds the capital: what the owner had and owed at the end of each full month and now.
///
/// * **Points** — the end of each full month (the last instant of its last day in the ledger's
///   calendar), `months` back from the month before today's, never before the month of the
///   first count of any balance; then «now». With no count at all there is only «now».
/// * **Accounts** — every balance the books know, archived accounts included, at the instant of
///   the point (`AccountBalances.balance(_:at:)`); «now» takes the balances as of `now`, so it
///   adds up exactly what the sidebar does. A group left out of the summary goes to
///   `outOfSummaryRub`, an account with interest terms to `depositsRub`, every other account to
///   `accountsRub`. A balance not counted by then adds nothing and is listed, never guessed;
///   interest a deposit accrued and has not paid is not money yet.
/// * **Assets** — the last valuation on or before the day; nothing before the first one (listed
///   for «now»), nothing from the day the asset was sold or written off.
/// * **Debts** — the debts not deleted, by their journals dated by the day (`DebtBalanceAt`):
///   what I owe with the interest the loan has charged and the interest accrued since the last
///   payment, what is owed to me by the journal alone; never below zero each; a closed debt is
///   nothing after the last day of its journal. Parts paid for somebody else are not debts.
/// * **Rates** — rubles for a unit on the day of the point (`dayRates`), today's for «now»
///   (`rubPerUnit`); a currency without one adds nothing and is listed. Each line is rounded on
///   its own, then the lines are added.
public enum NetWorth {
  /// The months back the chart shows by default.
  public static let defaultMonths = 12

  /// The capital through `now`. `months` is how many month ends back to go (`nil`: since the
  /// month of the first count of any balance); `rubPerUnit` are today's rates, `dayRates` the
  /// rates of past days.
  public static func build(
    ledger: Ledger, balances: AccountBalances, debtsJournal: [DebtEntry], assets: [Asset],
    valuations: [AssetValuation], today: DateOnly, now: Date,
    rubPerUnit: [CurrencyCode: Decimal], dayRates: DayRates, months: Int? = defaultMonths
  ) -> CapitalSnapshot {
    let books = Books(
      ledger: ledger, balances: balances, debtsJournal: debtsJournal, assets: assets,
      valuations: valuations)

    var points: [CapitalPoint] = []
    let thisMonth = today.monthKey
    if let first = books.firstCountMonth {
      let lastFull = thisMonth.previous
      // The months before the books began show what the owner bought and borrowed then.
      let lower = books.pastFirstDay.map { min($0.monthKey, first) } ?? first
      let start = months.map { max(lower, thisMonth.adding(months: -max(0, $0))) } ?? lower
      for month in MonthKey.range(start, through: lastFull) {
        let day = month.lastDay
        var reading = books.read(
          day: day, instant: ledger.calendar.endOfDay(day), isNow: false,
          rate: { dayRates.perUnit($0, on: day) })
        reading.point.beforeBooks = month < first
        points.append(reading.point)
      }
    }
    let nowReading = books.read(
      day: today, instant: now, isNow: true, rate: { rubPerUnit[$0] })
    points.append(nowReading.point)
    CapitalPast.applyCash(ledger.dataset.capitalSettings.pastCash, to: &points)

    let lastMonthEnd = thisMonth.previous.lastDay
    let change = points.first { !$0.isNow && $0.day == lastMonthEnd }.map {
      nowReading.point.netRub - $0.netRub
    }
    var breakdown = nowReading.breakdown
    books.markAccruedDepositInterest(
      in: &breakdown, today: today, rubPerUnit: rubPerUnit)
    return CapitalSnapshot(
      points: points, now: nowReading.point, breakdown: breakdown, changeThisMonth: change,
      events: CapitalEvents.build(ledger: ledger, journal: debtsJournal, today: today),
      pastCashDay: books.pastFirstDay)
  }

  /// Rubles for `amount` of `currency` at `rate`, rounded once; nothing is worth nothing in any
  /// currency, so zero needs no rate. `nil` without a rate.
  static func rubles(_ amount: AmountE4, in currency: CurrencyCode, rate: Decimal?) -> AmountE4? {
    if currency == .rub || amount.isZero { return amount }
    guard let rate, rate > 0 else { return nil }
    return SubscriptionMath.rounded(amount.decimal * rate)
  }

  // MARK: - The books read once

  /// Everything the points read, gathered once so each point is a walk over the keys, the
  /// assets and the debts.
  private struct Books {
    let ledger: Ledger
    let balances: AccountBalances
    let accountsById: [UUID: PaymentMethod]
    /// Groups left out of the summary — live ones; an archived group is no group, as in the
    /// sidebar.
    let leftOutGroups: Set<UUID>
    let groupOrder: [UUID: Int]
    /// The keys of known accounts, in a stable order.
    let keys: [BalanceKey]
    let assets: [Asset]
    let ownedItems: [OwnedItem]
    let updates: [ThingValuation]
    /// Each asset's valuations, oldest first.
    let valuations: [UUID: [AssetValuation]]
    let debts: [Debt]
    let journals: [UUID: [DebtEntry]]
    /// The month of the first count of any balance; `nil` with none.
    let firstCountMonth: MonthKey?
    /// The earliest purchase or loan dated before that month; `nil` with none.
    let pastFirstDay: DateOnly?
    /// The loans I owe worked out from their schedule until their journal begins.
    let restorations: [UUID: DebtRestoration]

    init(
      ledger: Ledger, balances: AccountBalances, debtsJournal: [DebtEntry], assets: [Asset],
      valuations: [AssetValuation]
    ) {
      self.ledger = ledger
      self.balances = balances
      let dataset = ledger.dataset
      accountsById = Dictionary(
        dataset.paymentMethods.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
      leftOutGroups = Set(
        dataset.accountGroups.filter { !$0.archived && !$0.inSummary }.map(\.id))
      let groups = dataset.accountGroups.sorted {
        ($0.sort, $0.name, $0.id.uuidString) < ($1.sort, $1.name, $1.id.uuidString)
      }
      groupOrder = Dictionary(
        groups.enumerated().map { ($0.element.id, $0.offset) },
        uniquingKeysWith: { first, _ in first })
      let known = accountsById
      keys = balances.keys.filter { known[$0.accountId] != nil }.sorted()
      updates = dataset.thingValuations
      let valuedIds = Set(updates.filter { $0.owner == .ownedItem }.map(\.ownerId))
      let owned = dataset.ownedItems.filter { !$0.archived && valuedIds.contains($0.id) }
      ownedItems = owned
      self.assets = assets
      var byAsset: [UUID: [AssetValuation]] = [:]
      for valuation in valuations { byAsset[valuation.assetId, default: []].append(valuation) }
      self.valuations = byAsset.mapValues { $0.sorted { $0.day < $1.day } }
      debts = dataset.debts.filter { !$0.isDeleted }
      var journals: [UUID: [DebtEntry]] = [:]
      for line in debtsJournal { journals[line.debtId, default: []].append(line) }
      self.journals = journals
      let firstCount = balances.keys.flatMap { balances.anchors($0).map(\.at) }.min()
      let firstValue = updates.map(\.day.monthKey).min()
      let firstMonth = [firstCount.map { balances.day(of: $0).monthKey }, firstValue]
        .compactMap { $0 }.min()
      firstCountMonth = firstMonth
      var restorations: [UUID: DebtRestoration] = [:]
      for debt in self.debts {
        if let restoration = DebtRestoration(
          debt: debt, journal: self.journals[debt.id] ?? [], calendar: ledger.calendar)
        {
          restorations[debt.id] = restoration
        }
      }
      self.restorations = restorations
      let beginnings =
        assets.compactMap { $0.purchase?.day } + restorations.values.map(\.opening.day)
      pastFirstDay = firstMonth.flatMap { first in
        beginnings.filter { $0.monthKey < first }.min()
      }
    }

    /// The block of the breakdown an account's money is listed under.
    func group(of account: PaymentMethod) -> CapitalLine.Group {
      if let groupId = account.groupId, leftOutGroups.contains(groupId) { return .outOfSummary }
      return account.interest != nil ? .deposits : .accounts
    }

    /// The first valuation of an asset dated after `day`, from either place valuations live.
    func nextValuation(
      of asset: UUID, after day: DateOnly
    ) -> (day: DateOnly, amount: AmountE4, currency: CurrencyCode)? {
      var found: (day: DateOnly, amount: AmountE4, currency: CurrencyCode)?
      if let legacy = valuations[asset]?.first(where: { $0.day > day }) {
        found = (legacy.day, legacy.valueE4, assets.first { $0.id == asset }?.currency ?? .rub)
      }
      let update = updates.filter { $0.owner == .asset && $0.ownerId == asset && $0.day > day }
        .min { $0.day < $1.day }
      if let update, found.map({ update.day < $0.day }) ?? true {
        found = (update.day, update.amountE4, update.currency)
      }
      return found
    }

    /// One point, and for «now» the rows of its breakdown.
    func read(
      day: DateOnly, instant: Date, isNow: Bool, rate: (CurrencyCode) -> Decimal?
    ) -> (point: CapitalPoint, breakdown: CapitalBreakdown) {
      var point = CapitalPoint(day: day, isNow: isNow)
      var have: [(order: [String], line: CapitalLine)] = []
      var owe: [(order: [String], line: CapitalLine)] = []
      var withoutRate: Set<CurrencyCode> = []
      var unanchored: [BalanceKey] = []

      // Accounts.
      for key in keys {
        guard let account = accountsById[key.accountId] else { continue }
        let amount = isNow ? balances[key]?.amountE4 : balances.balance(key, at: instant)
        let block = group(of: account)
        var issue: CapitalLine.Issue?
        var rub: AmountE4?
        if let amount {
          rub = NetWorth.rubles(amount, in: key.currency, rate: rate(key.currency))
          if let rub {
            switch block {
            case .outOfSummary: point.outOfSummaryRub += rub
            case .deposits: point.depositsRub += rub
            default: point.accountsRub += rub
            }
            if account.cushion { point.cushionRub += rub }
          } else {
            withoutRate.insert(key.currency)
            issue = .withoutRate
          }
        } else if isUnanchored(key, account: account, instant: instant, isNow: isNow) {
          unanchored.append(key)
          issue = .unanchored
        } else {
          continue
        }
        guard isNow else { continue }
        // An archived account is listed only while money is left on it.
        if account.archived, amount?.isZero ?? true, issue != .withoutRate { continue }
        let groupRank = account.groupId.flatMap { groupOrder[$0] } ?? -1
        have.append(
          (
            [
              String(Self.rank(of: block)), String(format: "%06d", groupRank + 1),
              account.isDefault ? "0" : "1", String(format: "%012d", account.sort + 1_000_000),
              account.name, account.id.uuidString, key.currency.code,
            ],
            CapitalLine(
              source: .account(account.id), group: block, name: account.name,
              currency: key.currency, amount: amount, amountRub: rub,
              accountGroupId: block == .outOfSummary ? account.groupId : nil, issue: issue)
          ))
      }

      // Assets.
      var unvalued: [UUID] = []
      let valuedThings =
        assets.map { ($0, ThingValuation.Owner.asset) }
        + ownedItems.map {
          (
            Asset(id: $0.id, name: $0.name, currency: $0.currency, disposedOn: $0.soldOn),
            ThingValuation.Owner.ownedItem
          )
        }
      for (asset, owner) in valuedThings {
        guard !asset.isDisposed(on: day) else { continue }
        let legacy = owner == .asset ? valuations[asset.id]?.last { $0.day <= day } : nil
        let update = ThingValuation.latest(
          updates,
          owner: owner, id: asset.id, through: day)
        let useUpdate = update.map { value in legacy.map { value.day >= $0.day } ?? true } ?? false
        var amount = useUpdate ? update?.amountE4 : legacy?.valueE4
        let currency = useUpdate ? (update?.currency ?? asset.currency) : asset.currency
        var issue: CapitalLine.Issue?
        var rub: AmountE4?
        if amount == nil, !isNow, owner == .asset, let purchase = asset.purchase,
          purchase.day <= day
        {
          // Before its first valuation an asset is worth what it cost, and then the straight
          // line towards that valuation; «now» keeps saying «no valuation».
          let next = nextValuation(of: asset.id, after: day)
          let price = NetWorth.rubles(purchase.priceE4, in: purchase.currency, rate: rate(purchase.currency))
          let target = next.flatMap { value in
            NetWorth.rubles(value.amount, in: value.currency, rate: rate(value.currency))
              .map { (value.day, $0) }
          }
          if let price {
            if let target {
              point.assetsRub += CapitalPast.onTheLine(
                from: (purchase.day, price), to: target, at: day)
              point.straightLineAssets = true
            } else {
              point.assetsRub += price
            }
          } else {
            withoutRate.insert(purchase.currency)
          }
          continue
        }
        if let amount {
          rub = NetWorth.rubles(amount, in: currency, rate: rate(currency))
          if let rub {
            point.assetsRub += rub
          } else {
            withoutRate.insert(currency)
            issue = .withoutRate
          }
        } else {
          guard isNow else { continue }
          unvalued.append(asset.id)
          issue = .unvalued
        }
        guard isNow else { continue }
        let kindRank = AssetKind.allCases.firstIndex(of: asset.kind) ?? 0
        have.append(
          (
            [
              String(Self.rank(of: .assets)), String(kindRank),
              String(format: "%012d", asset.sort + 1_000_000), asset.name, asset.id.uuidString,
            ],
            CapitalLine(
              source: owner == .ownedItem ? .ownedItem(asset.id) : .asset(asset.id),
              group: .assets, name: asset.name,
              currency: currency, amount: amount, amountRub: rub,
              assetKind: asset.kind, issue: issue)
          ))
      }

      // Debts.
      for debt in debts {
        let journal = journals[debt.id] ?? []
        if debt.closed {
          let days = journal.compactMap { $0.date ?? $0.occurredAt.map(ledger.calendar.day(of:)) }
          guard let last = days.max(), day <= last else { continue }
        }
        let iOwe = debt.direction == .iOwe
        let amount: AmountE4
        if !isNow, let restoration = restorations[debt.id], day < restoration.start {
          // Before its journal begins a loan is read from its schedule.
          guard let restored = restoration.balance(on: day) else { continue }
          amount = restored
          point.restoredDebts = true
        } else {
          let owed = DebtBalanceAt.owed(
            of: debt, journal: journal, through: day, calendar: ledger.calendar)
          amount = max(.zero, iOwe ? owed.balance + owed.accruedE4 : owed.balance)
        }
        guard !amount.isZero else { continue }
        let rub = NetWorth.rubles(amount, in: debt.currency, rate: rate(debt.currency))
        if let rub {
          if iOwe { point.iOweRub += rub } else { point.owedToMeRub += rub }
        } else {
          withoutRate.insert(debt.currency)
        }
        guard isNow else { continue }
        let accrued =
          DebtBalanceAt.owed(of: debt, journal: journal, through: day, calendar: ledger.calendar)
          .accruedE4
        let interest =
          iOwe && accrued.raw > 0
          ? NetWorth.rubles(accrued, in: debt.currency, rate: rate(debt.currency)) : nil
        let line = CapitalLine(
          source: .debt(debt.id), group: iOwe ? .iOwe : .owedToMe, name: debt.name,
          currency: debt.currency, amount: amount, amountRub: rub, interestRub: interest,
          issue: rub == nil ? .withoutRate : nil)
        let order = [String(Self.rank(of: line.group)), debt.name, debt.id.uuidString]
        if iOwe { owe.append((order, line)) } else { have.append((order, line)) }
      }

      point.unanchored = unanchored.sorted()
      point.withoutRate = withoutRate.sorted { $0.code < $1.code }
      point.unvalued = unvalued
      let byOrder:
        ((order: [String], line: CapitalLine), (order: [String], line: CapitalLine))
          -> Bool = { $0.order.lexicographicallyPrecedes($1.order) }
      return (
        point,
        CapitalBreakdown(
          have: have.sorted(by: byOrder).map(\.line), owe: owe.sorted(by: byOrder).map(\.line))
      )
    }

    /// Whether a balance not counted by the instant is money the figure misses: «now», a
    /// currency a live account holds or one money ever moved in; at a month end, a key money
    /// had moved on by then — one that had not even started is simply not there yet.
    func isUnanchored(
      _ key: BalanceKey, account: PaymentMethod, instant: Date, isNow: Bool
    ) -> Bool {
      if isNow {
        return (!account.archived && account.holds(key.currency)) || balances.hasHistory(key)
      }
      guard let first = balances[key]?.movements.first?.at else { return false }
      return first <= instant
    }

    /// Marks each deposit row with the interest its current period has earned and not paid
    /// yet: shown beside the balance, never added to it.
    func markAccruedDepositInterest(
      in breakdown: inout CapitalBreakdown, today: DateOnly, rubPerUnit: [CurrencyCode: Decimal]
    ) {
      guard breakdown.have.contains(where: { $0.group == .deposits }) else { return }
      let outlooks = DepositPayouts.outlooks(
        ledger: ledger, balances: balances,
        interestCategoryId: ledger.dataset.accountSettings.interestCategoryId, today: today,
        through: today.monthKey.lastDay)
      for outlook in outlooks {
        guard let payout = outlook.current(today: today), payout.accruedE4.raw > 0 else {
          continue
        }
        if case .received = payout.state { continue }
        guard
          let index = breakdown.have.firstIndex(where: {
            $0.group == .deposits && $0.source == .account(outlook.accountId)
              && $0.currency == outlook.key.currency
          })
        else { continue }
        breakdown.have[index].accruedNotCountedRub = NetWorth.rubles(
          payout.accruedE4, in: outlook.key.currency, rate: rubPerUnit[outlook.key.currency])
      }
    }

    /// The order of the blocks of the breakdown.
    static func rank(of group: CapitalLine.Group) -> Int {
      CapitalLine.Group.allCases.firstIndex(of: group) ?? 0
    }
  }
}
