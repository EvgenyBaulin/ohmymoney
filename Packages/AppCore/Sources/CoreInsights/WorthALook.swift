import CoreAccounting
import CoreAnalytics
import CoreKit
import CorePlanning
import Foundation

/// An account in the archive that still holds money — the archive of 1.1 took accounts with
/// money, 1.2 no longer does —, with what it holds per currency.
public struct ArchivedMoneyHolder: Hashable, Sendable {
  public var account: PaymentMethod
  public var leftovers: [ArchivedLeftover]

  public init(account: PaymentMethod, leftovers: [ArchivedLeftover]) {
    self.account = account
    self.leftovers = leftovers
  }
}

/// A line of «Стоит посмотреть».
public enum WorthALookLine: Hashable, Sendable, Identifiable {
  /// «Потратили деньги цели?»: what the goals hold and the money of the summary.
  case goalsExceed(goals: AmountE4, money: AmountE4)
  /// «На «Наличные» в архиве 1,000 ₽ — перевести на другой счёт?»
  case archivedMoney(ArchivedMoneyHolder)
  case anomaly(Anomaly)
  /// «и ещё N».
  case more(Int)
  /// «За последний месяц ничего необычного».
  case nothingUnusual

  public var id: String {
    switch self {
    case .goalsExceed: "goalsExceed"
    case .archivedMoney(let line): "archivedMoney:\(line.account.id)"
    case .anomaly(let anomaly): "anomaly:\(anomaly.id)"
    case .more: "more"
    case .nothingUnusual: "nothingUnusual"
    }
  }
}

/// What the tile «Стоит посмотреть» lists, and the rule of it — the card and the breakdown of
/// the card read it, so they cannot tell two stories.
public enum WorthALook {
  /// The anomalies of the last month — from the same day a month ago — as the empty line «За
  /// последний месяц ничего необычного» says, newest first as the report has them, and a
  /// reimbursement still waiting, dated by the day the money was paid but a state that holds
  /// today. The rules run over the whole history; Analytics shows the rest.
  public static func recent(_ report: AnomalyReport, today: DateOnly) -> [Anomaly] {
    let start = today.adding(months: -1)
    return report.visible.filter { $0.day >= start || $0.rule == .slowReimbursement }
  }

  /// Every account in the archive whose balance is not zero in some currency it was counted in
  /// (`ArchivedMoney.balancesToMove`), in the order of the accounts. A currency never counted
  /// has no balance to move.
  public static func archivedMoney(
    accounts: [PaymentMethod], balances: AccountBalances
  ) -> [ArchivedMoneyHolder] {
    accounts.filter(\.archived).compactMap { account in
      let leftovers = ArchivedMoney.balancesToMove(of: account, balances: balances).leftovers
      return leftovers.isEmpty ? nil : ArchivedMoneyHolder(account: account, leftovers: leftovers)
    }
  }

  /// The lines, in order. First the goals holding more than the money on the accounts of the
  /// summary — goal money was spent without «Забрать» —, then each account in the archive that
  /// still holds money (`archived`), then at most `shown` anomalies of the last month (`recent`)
  /// and «и ещё N» for the rest. «Ничего необычного» only when there is none of them: with such
  /// a line on the card, there is something worth a look.
  public static func lines(
    _ report: AnomalyReport, today: DateOnly, free: FreeMoney?, shown: Int,
    archived: [ArchivedMoneyHolder] = []
  ) -> [WorthALookLine] {
    let all = recent(report, today: today)
    var lines: [WorthALookLine] = []
    if let free, free.goalsExceedMoney {
      lines.append(.goalsExceed(goals: free.goalSavings, money: free.moneyNow ?? .zero))
    }
    lines += archived.map { .archivedMoney($0) }
    lines += all.prefix(shown).map { .anomaly($0) }
    if all.count > shown { lines.append(.more(all.count - shown)) }
    return lines.isEmpty ? [.nothingUnusual] : lines
  }
}

/// A line of «Стоит посмотреть» the version of income allocation, self-employment and the
/// credits brought: each with what the app shows it with. The lines of `WorthALook.lines` stay
/// as they were; these go above them (`WorthALook.notes`).
public enum WorthALookNote: Hashable, Sendable, Identifiable {
  /// A reminder of a debt or a credit card (`DebtReminders`).
  case debt(DebtReminder)
  /// «Налог НПД за октябрь ≈ X — до 28 ноября»: from `remindDaysBefore` days before the due
  /// day, and after it while unpaid.
  case npdDue(NPDMonth)
  /// «Зарплата не пришла?»: the day of the next term passed without the income.
  case salaryLate(PayHalf)
  /// «Распределить X?»: an income of the last 30 days not allocated in full; `leftE4` in the
  /// currency of the income.
  case allocate(incomeId: UUID, leftE4: AmountE4, currency: CurrencyCode)
  /// «Остаток сентября — X».
  case monthRest(MonthRestOffer)
  /// «До лимита самозанятого осталось X» from 90 % of it, «Лимит превышен» above it.
  case npdLimit(NPDYear)
  /// «Похоже на усталость: N мелких покупок за неделю, обычно M».
  case burnout(BurnoutSignal)
  /// «Мало места для копий: свободно X»: the disk the copies of the database lie on has less
  /// than the warning threshold free (`BackupSpace.lowThresholdBytes`). Nothing is deleted by it.
  case lowCopySpace(freeBytes: Int64)
  /// «Проверка базы нашла проблемы»: the weekly check of the database found `count` rows that
  /// are wrong. Said once it is found, until a later check finds none.
  case databaseProblems(count: Int)

  public var id: String {
    switch self {
    case .debt(let reminder): "debt:\(reminder.id)"
    case .npdDue(let month): "npdDue:\(month.month.iso)"
    case .salaryLate(let half): "salaryLate:\(half.nextIncomeId):\(half.nextIncomeDay.iso)"
    case .allocate(let id, _, _): "allocate:\(id)"
    case .monthRest(let offer): "monthRest:\(offer.month.iso)"
    case .npdLimit(let year): "npdLimit:\(year.year)"
    case .burnout(let signal): "burnout:\(signal.through.iso)"
    case .lowCopySpace: "lowCopySpace"
    case .databaseProblems: "databaseProblems"
    }
  }
}

extension WorthALook {
  /// The share of the limit of self-employment from which «Стоит посмотреть» speaks of it, in
  /// basis points.
  public static let npdLimitWarningBp = 9_000

  /// The lines of 1.9 in order: reminders of debts and cards, the tax due, the salary not come,
  /// incomes to allocate (newest first), the rest of the month, the limit of the year, burnout —
  /// the last only while it may show this week (`Burnout.shows`).
  public static func notes(
    planning: PlanningSnapshot, ledger: Ledger, today: DateOnly, burnout: BurnoutCheck = .quiet,
    burnoutEnabled: Bool = true, burnoutLastShownWeek: String? = nil, copyFreeBytes: Int64? = nil,
    lowCopySpaceBytes: Int64 = 1_000_000_000, databaseProblems: Int = 0
  ) -> [WorthALookNote] {
    var notes = planning.debtReminders.map(WorthALookNote.debt)
    if let npd = planning.npd {
      let reference = ledger.dataset.selfEmployment.reference
      for month in npd.months where month.state == .due || month.state == .overdue {
        guard month.toPayE4.raw > 0,
          today >= month.due.adding(days: -reference.remindDaysBefore)
        else { continue }
        notes.append(.npdDue(month))
      }
    }
    if let half = planning.payHalf, half.late { notes.append(.salaryLate(half)) }
    for id in planning.allocationOffers {
      guard let entry = ledger.entry(id) else { continue }
      let done = Allocation.distributed(
        incomeId: id, ledger: ledger, transfers: ledger.dataset.transfers)
      let left = entry.transaction.amountE4 - done
      guard left.raw > 0 else { continue }
      notes.append(.allocate(incomeId: id, leftE4: left, currency: entry.transaction.currency))
    }
    if let offer = planning.monthRest { notes.append(.monthRest(offer)) }
    if let year = planning.npd?.year, year.exceeded || year.shareBp >= npdLimitWarningBp {
      notes.append(.npdLimit(year))
    }
    if case .signal(let signal) = burnout,
      Burnout.shows(
        burnout, enabled: burnoutEnabled, lastShownWeek: burnoutLastShownWeek, today: today)
    {
      notes.append(.burnout(signal))
    }
    if let free = copyFreeBytes, free < lowCopySpaceBytes {
      notes.append(.lowCopySpace(freeBytes: free))
    }
    if databaseProblems > 0 { notes.append(.databaseProblems(count: databaseProblems)) }
    return notes
  }
}
