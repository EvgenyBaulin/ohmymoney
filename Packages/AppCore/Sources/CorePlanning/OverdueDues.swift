import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation

/// One subject with a due date passed and unpaid, as the launch asks about it: a scheduled
/// payment or a debt I owe, with its earliest unpaid due before today.
public struct OverdueDue: Hashable, Sendable, Identifiable {
  public enum Subject: Hashable, Sendable {
    case scheduled(UUID)
    case debt(UUID)
  }

  public var subject: Subject
  /// The name of the payment or of the debt, as the owner typed it.
  public var name: String
  /// The earliest unpaid due before today.
  public var due: DateOnly
  /// In `currency`: the price on `due`; for a debt min(what is left of the monthly payment —
  /// less what was paid toward the due —, balance).
  public var amount: AmountE4
  public var currency: CurrencyCode
  /// Further unpaid dues of the same subject before today.
  public var moreOverdue: Int
  /// The latest unpaid due before today — where «Пропустить все» stops; `due` when it is the only
  /// one.
  public var lastDue: DateOnly
  /// The moment of the latest count, on or after the due day, of the balance the due is about
  /// (`DueKeys`): the money may have left inside it, so «Уже списано до сверки» is offered;
  /// `nil` — it is not.
  public var countAfter: Date?
  /// The balance the due is about; `nil` while there is no main account to stand for it.
  public var key: BalanceKey?
  /// `pay:<payment>:<due>` / `debt:<debt>:<due>`, lowercased — the id of its reminder.
  public var id: String

  public init(
    subject: Subject, name: String, due: DateOnly, amount: AmountE4, currency: CurrencyCode,
    moreOverdue: Int, countAfter: Date?, key: BalanceKey?, lastDue: DateOnly? = nil
  ) {
    self.subject = subject
    self.name = name
    self.due = due
    self.amount = amount
    self.currency = currency
    self.moreOverdue = moreOverdue
    self.lastDue = lastDue ?? due
    self.countAfter = countAfter
    self.key = key
    switch subject {
    case .scheduled(let id): self.id = "pay:\(id.uuidString.lowercased()):\(due.iso)"
    case .debt(let id): self.id = "debt:\(id.uuidString.lowercased()):\(due.iso)"
    }
  }

  public var isDebt: Bool {
    if case .debt = subject { return true }
    return false
  }

  /// The due «Пропустить» closes — the earliest unpaid —, or with `all` «Пропустить все N»:
  /// the latest, so that every unpaid due before today is closed at once.
  public func skipping(all: Bool) -> DateOnly { all ? lastDue : due }
}

/// The balance whose money a due date is about: the one a count may already hold its money in.
public enum DueKeys {
  /// A scheduled payment's: its account — the main one when it names none or is archived
  /// (`DueAccounts.effective`) — in the payment's currency when the account holds it, else in
  /// the account's main currency. `nil` without an account to stand for it.
  public static func key(
    of payment: ScheduledPayment, accounts: [PaymentMethod], mainId: UUID?
  ) -> BalanceKey? {
    key(
      account: DueAccounts.effective(payment.paymentMethodId, accounts: accounts) ?? mainId,
      currency: payment.currency, accounts: accounts)
  }

  /// A debt's: the account of its last payment (`DebtAccount.lastPayment` — the account the
  /// pay form starts on), the main one when there is none or it is archived, in the debt's
  /// currency when the account holds it, else in the account's main currency.
  public static func key(
    of debt: Debt, ledger: Ledger, journal: [DebtEntry], mainId: UUID?
  ) -> BalanceKey? {
    let accounts = ledger.dataset.paymentMethods
    let last = DebtAccount.lastPayment(of: debt, ledger: ledger, journal: journal, mainId: mainId)
    return key(
      account: DueAccounts.effective(last, accounts: accounts) ?? mainId,
      currency: debt.currency, accounts: accounts)
  }

  private static func key(
    account: UUID?, currency: CurrencyCode, accounts: [PaymentMethod]
  ) -> BalanceKey? {
    guard let account else { return nil }
    let held =
      accounts.first { $0.id == account }.map { $0.holds(currency) ? currency : $0.mainCurrency }
      ?? currency
    return BalanceKey(accountId: account, currency: held)
  }
}

/// How «Провести» of a due date asks about a count.
public enum DueCountAsk: Sendable {
  /// No count to ask about.
  case none
  /// A count made on the day the operation is dated, before it was saved: the question of
  /// every operation (`AccountReconciliation.countToAsk`).
  case sameDay(CountAsk)
  /// The due is earlier than a later count of its balance, the operation's moment before it:
  /// «Деньги за «X» ушли до сверки 10 сентября в 14:00?». «Да» keeps the moment (inside the
  /// count, where the money already is), «Нет» dates the operation now
  /// (`AccountReconciliation.dueAnswer`). The count's reconciliation lets the question offer
  /// «Больше не спрашивать для этой сверки».
  case dueBefore(count: Date, due: DateOnly, reconciliation: UUID)
  /// That question answered already with «Больше не спрашивать» for the count's
  /// reconciliation: the moment the remembered answer gives, saved without asking.
  case dueAnswered(stamp: Date)
}

extension AccountReconciliation {
  /// «Провести» of a due date whose moment falls before a later count of a balance it moves:
  /// the due is on an earlier day than that count, the moment is before it, and the payment is
  /// saved after it. The moment of that count — the latest one of `keys` —, or `nil`.
  public static func countAfterDue(
    due: DateOnly, occurredAt: Date, savedAt: Date, keys: [BalanceKey],
    balances: AccountBalances, calendar: CalendarContext
  ) -> Date? {
    laterCount(
      due: due, occurredAt: occurredAt, savedAt: savedAt, keys: keys, balances: balances,
      calendar: calendar)?.at
  }

  /// The count of `countAfterDue` with its reconciliation, which an answer can be remembered
  /// for. Of two counts at one moment, the one of the key given first.
  public static func laterCount(
    due: DateOnly, occurredAt: Date, savedAt: Date, keys: [BalanceKey],
    balances: AccountBalances, calendar: CalendarContext
  ) -> (at: Date, reconciliation: UUID)? {
    var latest: (at: Date, reconciliation: UUID)?
    var seen: Set<BalanceKey> = []
    for key in keys where seen.insert(key).inserted {
      guard let anchor = balances.latestAnchor(key), calendar.day(of: anchor.at) > due,
        occurredAt < anchor.at, savedAt > anchor.at
      else { continue }
      if let found = latest, found.at >= anchor.at { continue }
      latest = (anchor.at, anchor.balance.reconciliationId)
    }
    return latest
  }

  /// Which question «Провести» of `due` asks: the dated one when the moment falls before a
  /// later count (`countAfterDue`) — answered at once when the owner said «Больше не
  /// спрашивать» for that count's reconciliation (`remembered`: reconciliation → «до») —,
  /// else the question of the operation's own day (`countToAsk`, the same answers applied).
  public static func dueQuestion(
    due: DateOnly, occurredAt: Date, savedAt: Date, keys: [BalanceKey],
    balances: AccountBalances, calendar: CalendarContext, remembered: [UUID: Bool] = [:]
  ) -> DueCountAsk {
    if let count = laterCount(
      due: due, occurredAt: occurredAt, savedAt: savedAt, keys: keys, balances: balances,
      calendar: calendar)
    {
      if let wasBefore = remembered[count.reconciliation] {
        return .dueAnswered(
          stamp: dueAnswer(
            count: count.at, occurredAt: occurredAt, wasBefore: wasBefore, now: savedAt))
      }
      return .dueBefore(count: count.at, due: due, reconciliation: count.reconciliation)
    }
    switch countToAsk(
      occurredAt: occurredAt, savedAt: savedAt, keys: keys, balances: balances,
      calendar: calendar, remembered: remembered)
    {
    case .none: return .none
    case let ask: return .sameDay(ask)
    }
  }

  /// The moment «Да, до сверки» of the dated question saves at: the moment chosen while it is
  /// before the count, else a second before the count.
  public static func momentBefore(count: Date, occurredAt: Date) -> Date {
    occurredAt < count ? occurredAt : count.addingTimeInterval(-1)
  }

  /// The moment an answer to the dated question saves the payment at: «Да» — inside the
  /// count, where its money already is (`momentBefore`); «Нет» — `now`, after the count, so
  /// the payment still moves the balance.
  public static func dueAnswer(
    count: Date, occurredAt: Date, wasBefore: Bool, now: Date
  ) -> Date {
    wasBefore ? momentBefore(count: count, occurredAt: occurredAt) : now
  }
}

/// The due dates passed and unpaid, one row per payment or debt — what the launch asks about.
public enum OverdueDues {
  /// Every overdue subject as of `today`, the oldest due first, then scheduled payments before
  /// debts, then by name, then by id.
  ///
  /// * Scheduled — every active payment whose due dates from `next_date` on include one before
  ///   today that nothing paid (`matches`): its earliest, with the count of the others. A
  ///   payment whose money is not in the summary (its effective account in a group left out)
  ///   is left out, as the free sum leaves it out.
  /// * Debts — every open debt I owe with a monthly payment and something left on it whose
  ///   earliest unpaid due is before today (`DebtLine.dues`): min(what is left of the monthly
  ///   payment, balance) — the payment less the money paid toward the due. A
  ///   debt paid from an account out of the summary (its `DueKeys` account in a group left
  ///   out) is left out, as the free sum leaves it out.
  ///
  /// `countAfter` is the moment of the latest count of the due's balance (`DueKeys`) made on
  /// the due day or later: only then may the money already be inside a count.
  public static func build(
    ledger: Ledger, book: PlanningBook, matches: ScheduledMatches, debts: DebtsOverview,
    accounts: AccountsSnapshot, today: DateOnly
  ) -> [OverdueDue] {
    let list = ledger.dataset.paymentMethods
    let mainId = list.first { $0.isDefault && !$0.archived }?.id
    let calendar = ledger.calendar
    func countAfter(_ key: BalanceKey?, due: DateOnly) -> Date? {
      guard let key, let anchor = accounts.balances.latestAnchor(key),
        calendar.day(of: anchor.at) >= due
      else { return nil }
      return anchor.at
    }

    var result: [OverdueDue] = []
    let yesterday = today.adding(days: -1)
    for payment in book.scheduled where payment.active {
      guard let next = payment.nextDate, next < today else { continue }
      let account = DueAccounts.effective(payment.paymentMethodId, accounts: list) ?? mainId
      guard accounts.isInSummary(account) else { continue }
      let dues = Recurrence.occurrences(
        from: next, through: yesterday, rule: RecurrenceRule(payment: payment),
        end: payment.endDate, limit: ScheduledMatching.duesPerPayment
      ).filter { !matches.isPaid(payment.id, $0) }
      guard let first = dues.first else { continue }
      let key = DueKeys.key(of: payment, accounts: list, mainId: mainId)
      result.append(
        OverdueDue(
          subject: .scheduled(payment.id), name: payment.name, due: first,
          amount: SubscriptionMath.price(of: payment, on: first, prices: book.prices),
          currency: payment.currency, moreOverdue: dues.count - 1,
          countAfter: countAfter(key, due: first), key: key, lastDue: dues.last))
    }
    for line in debts.iOwe {
      let left = line.dues.balance(or: line.balance)
      guard line.debt.hasDues, left.raw > 0 else { continue }
      let late = line.dues.overdue(today: today)
      guard let first = late.first else { continue }
      let key = DueKeys.key(
        of: line.debt, ledger: ledger, journal: book.debtEntries, mainId: mainId)
      guard accounts.isInSummary(key?.accountId) else { continue }
      result.append(
        OverdueDue(
          subject: .debt(line.debt.id), name: line.debt.name, due: first,
          amount: min(line.dues.knowing(line.debt).owed(first), left),
          currency: line.debt.currency,
          moreOverdue: late.count - 1, countAfter: countAfter(key, due: first), key: key,
          lastDue: late.last))
    }
    return result.sorted { left, right in
      if left.due != right.due { return left.due < right.due }
      if left.isDebt != right.isDebt { return !left.isDebt }
      if left.name != right.name { return left.name < right.name }
      return left.id < right.id
    }
  }
}
