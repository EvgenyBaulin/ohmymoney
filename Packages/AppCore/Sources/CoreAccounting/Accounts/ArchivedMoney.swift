import CoreKit
import Foundation

/// Money a change would leave on a key of an account in the archive.
public struct ArchivedLeftover: Hashable, Sendable {
  public var key: BalanceKey
  /// Plus: money left on the archived key, to be moved off to a live account. Minus: the key
  /// taken below its count, to be brought back from one.
  public var amount: AmountE4
  /// The latest moment the change puts on this key: the transfer that settles it is dated no
  /// earlier, or the money would sit on the archived account from then on.
  public var latest: Date
  /// For the whole balance of a key (`ArchivedMoney.balancesToMove`): what it holds now. When
  /// money typed ahead of now makes `amount` another figure, the key is settled in two legs —
  /// what it holds now by a transfer dated now, the rest by one dated `latest` —, so it is at
  /// zero in between too, when no total would count the money it held. `nil` for what a change
  /// leaves.
  public var heldNow: AmountE4?
  /// For what a change leaves (`ArchivedMoney.leftovers`): the moment of the last movement of
  /// the key once the change is made — every movement the books know, less the ones the change
  /// takes away, plus the ones it puts in —, or of the key's latest count when that is later.
  /// The transfer that settles the key is dated a second after it, so the money never sits on
  /// the archived account between its last movement and now. `nil` for a whole balance, which
  /// is settled now and later (`settlingTransfers`).
  public var settleAfter: Date?

  public init(
    key: BalanceKey, amount: AmountE4, latest: Date, heldNow: AmountE4? = nil,
    settleAfter: Date? = nil
  ) {
    self.key = key
    self.amount = amount
    self.latest = latest
    self.heldNow = heldNow
    self.settleAfter = settleAfter
  }

  /// The money the question about the key names: what it holds now when that is not zero —
  /// the transfer dated now moves it —, else `amount`.
  public var shownAmount: AmountE4 {
    if let heldNow, !heldNow.isZero { return heldNow }
    return amount
  }
}

/// What a change leaves on archived accounts: the leftovers to move, and the keys that moved
/// but were never counted — nobody knows their balance, so nothing is moved for them.
public struct ArchivedMoneyCheck: Hashable, Sendable {
  public var leftovers: [ArchivedLeftover]
  public var unknown: [BalanceKey]

  public init(leftovers: [ArchivedLeftover] = [], unknown: [BalanceKey] = []) {
    self.leftovers = leftovers
    self.unknown = unknown
  }

  public static let none = ArchivedMoneyCheck()
}

/// One transfer of a settling, told for the question that asks where the money goes: when it is
/// dated, how much, between which accounts, and whether the money goes back into the account
/// that is archived — to pay what is typed ahead there.
public struct SettlingLeg: Hashable, Sendable {
  public enum When: Hashable, Sendable {
    /// Dated in the past, right after the last movement of the archived account: what a change
    /// of its past leaves is moved off from then on.
    case earlier
    /// Dated now: the money moves with the answer.
    case now
    /// Dated with an operation typed ahead.
    case later
  }

  public var when: When
  public var at: Date
  /// The amount, above zero, in `currency`.
  public var amount: AmountE4
  public var currency: CurrencyCode
  public var from: UUID
  public var to: UUID
  /// The money comes into the archived account: it is brought back to pay for what is typed
  /// ahead on it.
  public var returnsToArchived: Bool

  public init(
    when: When, at: Date, amount: AmountE4, currency: CurrencyCode, from: UUID, to: UUID,
    returnsToArchived: Bool
  ) {
    self.when = when
    self.at = at
    self.amount = amount
    self.currency = currency
    self.from = from
    self.to = to
    self.returnsToArchived = returnsToArchived
  }
}

/// An account in the archive stays at zero. No total counts it, so money left on it would
/// leave «Всего» for good, and money taken from it would be made out of nothing. An edit or a
/// deletion that would do either — or the archive of an account that still holds money — is
/// paired with a transfer between the archived key and a live account of the same currency, so
/// the archived key is back at zero and the live account holds the real money. What a change
/// leaves goes a second after the key's last movement once the change is made — in the past or
/// typed ahead —, so the money never sits on the archived account in between. An account
/// archived with money is settled now, and money typed ahead on it then: two legs.
///
/// Only what moves the balance counts: a change dated at or before the archived key's latest
/// count changes that count's difference, not its balance, and a money-neutral edit (a comment,
/// a category, a place) moves nothing at all.
public enum ArchivedMoney {
  /// What the change — `old` movements taken away, `new` ones put in — leaves on every key of
  /// an archived account among `accounts`, per key, the non-zero ones only, in key order, each
  /// with the moment its settling transfer follows (`ArchivedLeftover.settleAfter`). A key
  /// that moves but was never counted goes to `unknown`.
  public static func leftovers(
    removing old: [AccountMovement], adding new: [AccountMovement], balances: AccountBalances,
    accounts: [PaymentMethod]
  ) -> ArchivedMoneyCheck {
    let archived = Set(accounts.filter(\.archived).map(\.id))
    var sums: [BalanceKey: AmountE4] = [:]
    var latest: [BalanceKey: Date] = [:]
    var unknown: Set<BalanceKey> = []
    func add(_ movement: AccountMovement, sign: Int64) {
      guard archived.contains(movement.key.accountId), !movement.amountE4.isZero else { return }
      guard let effect = balances.effectAfterLatestCount(movement) else {
        unknown.insert(movement.key)
        return
      }
      guard !effect.isZero else { return }
      sums[movement.key, default: .zero] += sign > 0 ? effect : -effect
      latest[movement.key] = max(latest[movement.key] ?? movement.at, movement.at)
    }
    for movement in old { add(movement, sign: -1) }
    for movement in new { add(movement, sign: 1) }
    let leftovers = sums.keys.sorted().compactMap { key -> ArchivedLeftover? in
      guard let amount = sums[key], !amount.isZero else { return nil }
      return ArchivedLeftover(
        key: key, amount: amount, latest: latest[key] ?? balances.now,
        settleAfter: lastMoment(of: key, removing: old, adding: new, balances: balances))
    }
    return ArchivedMoneyCheck(leftovers: leftovers, unknown: unknown.sorted())
  }

  /// The last movement of the key once the change is made, or its latest count when that is
  /// later: a transfer dated at or before the count would change the count's difference and
  /// leave the money where it is. A movement known only by its day may have been as late as the
  /// end of that day (`AccountBalances.lastInstant(of:)`).
  private static func lastMoment(
    of key: BalanceKey, removing old: [AccountMovement], adding new: [AccountMovement],
    balances: AccountBalances
  ) -> Date? {
    var moments = new.filter { $0.key == key }.compactMap(balances.lastInstant(of:))
    if let kept = balances.latestInstant(of: key, removing: old) { moments.append(kept) }
    if let count = balances.latestAnchor(key)?.at { moments.append(count) }
    return moments.max()
  }

  /// The moment of the latest count of the live account's key that takes or gives the money of
  /// `key` — `counterpart` in the same currency —, `nil` while it was never counted. The
  /// transfer that settles `key` goes after it (`settlingTransfer`).
  public static func counterpartCount(
    _ counterpart: UUID, for key: BalanceKey, balances: AccountBalances
  ) -> Date? {
    balances.latestAnchor(BalanceKey(accountId: counterpart, currency: key.currency))?.at
  }

  /// What archiving `account` leaves — or what an account already in the archive still holds:
  /// every counted key of it with money now or once everything written on it has happened, plus
  /// or minus, in key order (`AccountBalances.balanceAhead`), with what it holds now
  /// (`ArchivedLeftover.heldNow`). An operation typed ahead of now counts: left out, it would
  /// take the archived key off zero on its day. The money of now is then settled now and the
  /// rest with the latest movement (`settlingTransfers`). A key that moved but was never counted
  /// goes to `unknown`.
  public static func balancesToMove(
    of account: PaymentMethod, balances: AccountBalances
  ) -> ArchivedMoneyCheck {
    var keys = Set(account.currencies.map { BalanceKey(accountId: account.id, currency: $0) })
    for key in balances.keys where key.accountId == account.id { keys.insert(key) }
    var check = ArchivedMoneyCheck()
    for key in keys.sorted() {
      if let amount = balances.balanceAhead(key) {
        let now = balances.balance(key, at: balances.now)
        guard !amount.isZero || !(now ?? .zero).isZero else { continue }
        check.leftovers.append(
          ArchivedLeftover(
            key: key, amount: amount, latest: balances.momentAhead(key), heldNow: now))
      } else if balances.hasHistory(key) {
        check.unknown.append(key)
      }
    }
    return check
  }

  /// The live accounts that hold the key's currency and can take its money, in the order of
  /// every menu (the main account first). Never the archived account itself.
  public static func counterparts(
    for key: BalanceKey, accounts: [PaymentMethod], locale: Locale
  ) -> [PaymentMethod] {
    AccountRules.ordered(
      accounts.filter { !$0.archived && $0.id != key.accountId && $0.holds(key.currency) },
      locale: locale)
  }

  /// The transfer that brings the key back to zero: money left on it goes from it to
  /// `counterpart`, money taken below its count comes from `counterpart` to it — the whole
  /// amount, in the key's currency. What a change leaves is dated a second after the key's last
  /// movement (`ArchivedLeftover.settleAfter`) — in the past, or ahead of now when that movement
  /// is typed ahead; a last movement less than a second before now gives now, still after it.
  /// Without that moment: `now`, or the change's latest moment when that is later.
  ///
  /// The transfer moves the counterpart's key too, so it never lands inside the window of a count
  /// of that key: `counterpartCountedAt`, the moment of its latest count
  /// (`counterpartCount(_:for:balances:)`), is a moment the transfer goes after as well. Dated
  /// before it, the transfer would change what that count expected and make up a «Сверка»
  /// difference of the live account.
  public static func settlingTransfer(
    _ leftover: ArchivedLeftover, counterpart: UUID, counterpartCountedAt: Date?, now: Date,
    note: String?, id: UUID
  ) -> Transfer {
    transfer(
      leftover.amount, of: leftover.key, counterpart: counterpart,
      at: settlingMoment(of: leftover, counterpartCountedAt: counterpartCountedAt, now: now),
      now: now, note: note, id: id)
  }

  /// The moment `settlingTransfer` dates its transfer.
  static func settlingMoment(
    of leftover: ArchivedLeftover, counterpartCountedAt: Date?, now: Date
  ) -> Date {
    guard var after = leftover.settleAfter else { return max(now, leftover.latest) }
    if let counted = counterpartCountedAt, counted > after { after = counted }
    let next = after.addingTimeInterval(1)
    return after <= now ? min(next, now) : next
  }

  /// The transfers that keep the key at zero from now on. What a change leaves goes by one
  /// (`settlingTransfer`). A whole balance goes by what it holds now, dated `now`, and by the
  /// rest money typed ahead makes of it, dated with the latest movement ahead: one leg or two,
  /// the ones that are not zero. `counterpartCountedAt` is the latest count of the counterpart's
  /// key, which the transfer of what a change leaves goes after (`settlingTransfer`).
  public static func settlingTransfers(
    _ leftover: ArchivedLeftover, counterpart: UUID, counterpartCountedAt: Date?, now: Date,
    note: String?, ids: () -> UUID = { UUID() }
  ) -> [Transfer] {
    let later = max(now, leftover.latest)
    guard let held = leftover.heldNow, later > now else {
      return [
        settlingTransfer(
          leftover, counterpart: counterpart, counterpartCountedAt: counterpartCountedAt,
          now: now, note: note, id: ids())
      ]
    }
    var legs: [(AmountE4, Date)] = []
    if !held.isZero { legs.append((held, now)) }
    let rest = leftover.amount - held
    if !rest.isZero { legs.append((rest, later)) }
    return legs.map { amount, at in
      transfer(
        amount, of: leftover.key, counterpart: counterpart, at: at, now: now, note: note,
        id: ids())
    }
  }

  /// The transfers of a settling told one by one, in the order given: each with when it is
  /// dated against `now` and whether it brings money into `archived`. What the question says
  /// before it writes them (`settlingTransfers`) — a settling can be two transfers, and the
  /// second, dated with what is typed ahead, takes money back out of the account that was just
  /// emptied.
  public static func legs(of transfers: [Transfer], archived: UUID, now: Date) -> [SettlingLeg] {
    transfers.map { transfer in
      SettlingLeg(
        when: transfer.occurredAt > now ? .later : transfer.occurredAt < now ? .earlier : .now,
        at: transfer.occurredAt,
        amount: transfer.fromAmountE4, currency: transfer.fromCurrency,
        from: transfer.fromAccountId, to: transfer.toAccountId,
        returnsToArchived: transfer.toAccountId == archived)
    }
  }

  /// `amount` between the key and `counterpart`: plus leaves the key, minus comes to it.
  private static func transfer(
    _ amount: AmountE4, of key: BalanceKey, counterpart: UUID, at moment: Date, now: Date,
    note: String?, id: UUID
  ) -> Transfer {
    let other = BalanceKey(accountId: counterpart, currency: key.currency)
    let (from, to) = amount.raw > 0 ? (key, other) : (other, key)
    return Transfer(
      id: id, occurredAt: moment, fromAccountId: from.accountId, fromCurrency: from.currency,
      fromAmountE4: amount.magnitude, toAccountId: to.accountId, toCurrency: to.currency,
      toAmountE4: amount.magnitude, note: note, createdAt: now, updatedAt: now)
  }

  /// The two legs of a transfer as the balances see them: money out of one key, into another.
  public static func movements(of transfer: Transfer) -> [AccountMovement] {
    [
      AccountMovement(
        key: transfer.from, at: transfer.occurredAt, amountE4: -transfer.fromAmountE4,
        source: .transferOut(transfer.id)),
      AccountMovement(
        key: transfer.to, at: transfer.occurredAt, amountE4: transfer.toAmountE4,
        source: .transferIn(transfer.id)),
    ]
  }
}

extension AccountBalances {
  /// What `movement` does to its key's balance from its latest count on: its whole amount when
  /// it is after that count, by the rule of the balances; zero when it is at or before it —
  /// then it changes the count's difference, not the balance — and for a journal line dated
  /// only by the count's day or not dated at all. `nil` when the key was never counted: its
  /// balance is not known. A movement dated after now counts too: it will move the balance.
  public func effectAfterLatestCount(_ movement: AccountMovement) -> AmountE4? {
    guard let anchor = latestAnchor(movement.key) else { return nil }
    switch movement.timing {
    case .undated:
      return .zero
    case .day(let day):
      if day == self.day(of: anchor.at) { return .zero }
    case .moment:
      break
    }
    return movement.at > anchor.at ? movement.amountE4 : .zero
  }
}
