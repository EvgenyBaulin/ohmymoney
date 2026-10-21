import CoreKit
import Foundation

/// The categories a difference is written to: «Сверка» for money missing, its income twin for
/// money found.
public struct ReconcileCategories: Hashable, Sendable {
  public var expense: UUID
  public var income: UUID

  public init(expense: UUID, income: UUID) {
    self.expense = expense
    self.income = income
  }
}

/// The rate of the bank for a difference in a foreign currency: rubles for one unit, the day it
/// is for, and whether it still waits for the day's own publication.
public struct CountRate: Hashable, Sendable {
  public var perUnit: Decimal
  public var day: DateOnly
  public var provisional: Bool

  public init(perUnit: Decimal, day: DateOnly, provisional: Bool) {
    self.perUnit = perUnit
    self.day = day
    self.provisional = provisional
  }
}

/// One count as it is stored, with the operation keyed `reconcile:<reconciliation>:<count>`,
/// live or in the bin, when there is one.
public struct CountState: Hashable, Sendable {
  public var count: ReconciledBalance
  public var countAt: Date
  public var operation: TransactionEntry?

  public init(count: ReconciledBalance, countAt: Date, operation: TransactionEntry? = nil) {
    self.count = count
    self.countAt = countAt
    self.operation = operation
  }
}

/// What following the books does to one count and its operation.
public struct CountSettlement: Hashable, Sendable {
  public enum OperationChange: Hashable, Sendable {
    case none
    /// A new operation of the difference, with the ids derived from the count.
    case create(TransactionEntry)
    /// The operation written over in place: the same ids, only its money and — on a change of
    /// sign — its kind, category and rating move.
    case rewrite(TransactionEntry)
    /// The operation goes for good: the difference is zero.
    case purge(UUID)
  }

  /// The count with its expected balance, difference, operation and mode as they follow now.
  public var count: ReconciledBalance
  public var operation: OperationChange
  /// Whether anything of the stored count differs from `count`.
  public var countChanged: Bool
  /// Whether the count's mode — recording or only keeping the numbers — changed.
  public var modeChanged: Bool
  /// Recording a non-zero difference in a foreign currency with no rate at all: the operation
  /// waits for a rate, and the next settle writes it.
  public var waitsForRate: Bool
  /// A new operation or a change of sign needs the categories, and none were given: ask again
  /// with them.
  public var needsCategories: Bool

  public init(
    count: ReconciledBalance, operation: OperationChange = .none, countChanged: Bool = false,
    modeChanged: Bool = false, waitsForRate: Bool = false, needsCategories: Bool = false
  ) {
    self.count = count
    self.operation = operation
    self.countChanged = countChanged
    self.modeChanged = modeChanged
    self.waitsForRate = waitsForRate
    self.needsCategories = needsCategories
  }
}

/// A later count's difference follows the books.
///
/// The first count of an account in a currency is its starting point: it is what was counted
/// and neither income nor spending. Every later count compares with what the books expect — the
/// count before it plus what moved between the two —, and that comparison is not frozen when
/// the sheet is saved: an operation or a transfer dated inside the window and added, changed or
/// deleted afterwards moves the expected balance, and with it the difference and the one
/// operation that records it. So money found at a count and entered later as the salary it
/// was is never income twice.
///
/// A count follows the books — is live — when it was compared, belongs to a sheet of accounts,
/// no starting balance of the same account and currency was written after it (a merge or a
/// new starting point cuts the windows before it), and it is not a first count the owner still
/// has to decide about (`ZeroOpenings.frozenCounts`).
public enum LiveCounts {

  /// The ids of the live counts. `balances` are every count in the order of the book;
  /// `frozen` are the first counts the owner has not decided about.
  public static func liveIds(
    reconciliations: [Reconciliation], balances: [ReconciledBalance], frozen: Set<UUID>
  ) -> Set<UUID> {
    let byId = Dictionary(
      reconciliations.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    var openedLater: Set<BalanceKey> = []
    var live: Set<UUID> = []
    for balance in balances.reversed() {
      guard let reconciliation = byId[balance.reconciliationId],
        reconciliation.reconciledAt != nil
      else { continue }
      switch reconciliation.kind {
      case .opening:
        openedLater.insert(balance.key)
      case .accounts:
        guard balance.expectedE4 != nil, !openedLater.contains(balance.key),
          !frozen.contains(balance.id)
        else { continue }
        live.insert(balance.id)
      case .total:
        continue
      }
    }
    return live
  }

  /// One live count against what the books expect of it now.
  ///
  /// * The expected balance and the difference, `actual − expected`, are written whatever the
  ///   mode.
  /// * The mode follows the operation: an operation the owner put in the bin turns the count to
  ///   keeping only the numbers; an operation brought back from the bin turns it to recording
  ///   again. A count without a mode records when it has a live operation.
  /// * Recording: at zero the operation goes for good; a difference of the same sign rewrites
  ///   only the amount — and the rubles at the operation's own rate — in place, keeping its
  ///   ids, category, comment, «на кого» and rating; a change of sign turns an expense into an
  ///   income or back, in the twin category; a difference without an operation writes a new
  ///   one with the ids derived from the count, at `rate` in a foreign currency, and waits
  ///   when there is none.
  /// * Keeping: nothing is written but the numbers.
  /// * Asked to record again (mode «record», no operation linked) while the operation is in the
  ///   bin: a new operation is written over the binned one, with the count's ids.
  ///
  /// `template` is the count's operation as a write being taken back found it: when that write
  /// purged it at zero, the operation written again is that one — its ids, the owner's category,
  /// comment, «на кого» and rating, the moment it was made, its own rate —, as it was when the
  /// difference is the same, resized or turned to the other sign otherwise. A template in the
  /// bin is none.
  public static func settle(
    _ state: CountState, expected: AmountE4, rate: CountRate?,
    categories: ReconcileCategories?, tree: CategoryTree, now: Date,
    template: TransactionEntry? = nil
  ) -> CountSettlement {
    let stored = state.count
    var count = stored
    let difference = count.actualE4 - expected
    let live = state.operation.flatMap { $0.transaction.isDeleted ? nil : $0 }
    let binned = state.operation.map(\.transaction.isDeleted) ?? false
    var records = count.recordsDifference ?? (live != nil)
    // An operation put in the bin while the count held it turns the count to keeping. A count
    // told to record with no operation linked — «Записывать разницу» — is the owner asking
    // again: the binned operation does not hold it back, and a new one is written over it.
    let askedAgain = count.recordsDifference == true && count.transactionId == nil
    if records, binned, !askedAgain {
      records = false
    } else if !records, live != nil {
      records = true
    }
    count.expectedE4 = expected
    count.differenceE4 = difference
    count.recordsDifference = records

    var change = CountSettlement.OperationChange.none
    var waits = false
    var needs = false
    if !records {
      count.transactionId = nil
    } else if difference.isZero {
      count.transactionId = nil
      if let live { change = .purge(live.id) }
    } else if let live {
      count.transactionId = live.id
      let kind: TransactionKind = difference.isNegative ? .expense : .income
      if live.transaction.kind != kind {
        if let categories {
          change = .rewrite(
            switched(
              live, to: kind, amount: difference.magnitude, categories: categories, tree: tree,
              now: now))
        } else {
          needs = true
        }
      } else if live.transaction.amountE4 != difference.magnitude {
        change = .rewrite(resized(live, to: difference.magnitude, now: now))
      }
    } else if let template = template.flatMap({ $0.transaction.isDeleted ? nil : $0 }) {
      let kind: TransactionKind = difference.isNegative ? .expense : .income
      var entry: TransactionEntry?
      if template.transaction.kind != kind {
        entry = categories.map {
          switched(
            template, to: kind, amount: difference.magnitude, categories: $0, tree: tree, now: now)
        }
      } else if template.transaction.amountE4 != difference.magnitude {
        entry = resized(template, to: difference.magnitude, now: now)
      } else {
        entry = template
      }
      if var entry {
        entry.transaction.externalId =
          OperationLink.reconciledBalance(
            reconciliation: stored.reconciliationId, balance: stored.id
          ).externalId
        count.transactionId = entry.id
        change = .create(entry)
      } else {
        count.transactionId = nil
        needs = true
      }
    } else if stored.currency != .rub, rate == nil {
      count.transactionId = nil
      waits = true
    } else if let categories {
      let entry = differenceOperation(
        difference, key: stored.key, rate: rate, at: state.countAt, tree: tree,
        categories: categories, countId: stored.id,
        link: .reconciledBalance(reconciliation: stored.reconciliationId, balance: stored.id),
        now: now)
      count.transactionId = entry.id
      change = .create(entry)
    } else {
      count.transactionId = nil
      needs = true
    }
    return CountSettlement(
      count: count, operation: change, countChanged: count != stored,
      modeChanged: count.recordsDifference != stored.recordsDifference, waitsForRate: waits,
      needsCategories: needs)
  }

  /// The operation that records one difference: less money than expected is an expense of the
  /// gap in «Сверка», more is an income in its twin; on the count's account, in its currency,
  /// at its moment, keyed `link`. A foreign one is at `rate` of the bank for the count's day;
  /// its rubles are rounded once. The operation and its one part take the ids derived from the
  /// count (`ReconcileDifferenceIds`), so a purge and a re-creation always name the same rows.
  public static func differenceOperation(
    _ difference: AmountE4, key: BalanceKey, rate: CountRate?, at moment: Date,
    tree: CategoryTree, categories: ReconcileCategories, countId: UUID, link: OperationLink,
    now: Date
  ) -> TransactionEntry {
    let id = ReconcileDifferenceIds.operation(forCount: countId)
    let missing = difference.isNegative
    let amount = difference.magnitude
    let foreign = key.currency != .rub
    let perUnit: Decimal? = foreign ? rate?.perUnit : nil
    var draft = TransactionDraft(
      kind: missing ? .expense : .income, occurredAt: moment, currency: key.currency,
      amount: amount, rate: perUnit, rateDate: foreign ? rate?.day : nil,
      rateSource: foreign ? .cbr : nil,
      rateProvisional: foreign ? (rate?.provisional ?? true) : false,
      paymentMethodId: key.accountId)
    draft.normalizeSinglePart()
    draft.parts[0].id = ReconcileDifferenceIds.part(forCount: countId)
    draft.parts[0].categoryId = missing ? categories.expense : categories.income
    draft.parts[0].categorySource = .system
    if missing {
      let decision = QualityResolver.resolve(categoryId: categories.expense, categories: tree)
      draft.parts[0].quality = decision.quality
      draft.parts[0].qualitySource = decision.source
    }
    let rubles = perUnit.map { rounded(amount.decimal * $0) } ?? amount
    let transaction = Transaction(
      id: id, kind: draft.kind, occurredAt: moment, currency: key.currency, amountE4: amount,
      rate: draft.rate, rateDate: draft.rateDate, rateSource: draft.rateSource,
      rateProvisional: draft.rateProvisional, amountRubE4: rubles,
      paymentMethodId: key.accountId, externalId: link.externalId, createdAt: now,
      updatedAt: now)
    return TransactionEntry(
      transaction: transaction,
      parts: draft.parts.map { $0.materialize(transactionId: id, amountRub: rubles) })
  }

  // MARK: - Rewrites in place

  /// The same operation with a new amount: its rubles at its own rate — a ruble operation's
  /// are its amount —, its parts in proportion, stamped `now`. Nothing else moves.
  static func resized(
    _ entry: TransactionEntry, to amount: AmountE4, now: Date
  )
    -> TransactionEntry
  {
    var result = entry
    let old = entry.transaction
    let rubles: AmountE4
    if old.currency == .rub {
      rubles = amount
    } else if let rate = old.rate, rate > 0 {
      rubles = rounded(amount.decimal * rate)
    } else if !old.amountE4.isZero {
      rubles = rounded(old.amountRubE4.decimal * amount.decimal / old.amountE4.decimal)
    } else {
      rubles = old.amountRubE4
    }
    result.transaction.amountE4 = amount
    result.transaction.amountRubE4 = rubles
    result.transaction.updatedAt = now
    let weights = entry.parts.map(\.amountE4)
    let amounts = amount.allocated(proportionallyTo: weights, outOf: old.amountE4)
    let rubleShares = rubles.allocated(proportionallyTo: weights, outOf: old.amountE4)
    for index in result.parts.indices {
      if weights.count == 1 {
        result.parts[index].amountE4 = amount
        result.parts[index].amountRubE4 = rubles
      } else {
        result.parts[index].amountE4 = amounts[index]
        result.parts[index].amountRubE4 = rubleShares[index]
      }
    }
    return result
  }

  /// The operation turned to the other sign: an expense of missing money becomes an income of
  /// money found, or back, in the twin category, rated as that category is for an expense and
  /// not at all for an income.
  static func switched(
    _ entry: TransactionEntry, to kind: TransactionKind, amount: AmountE4,
    categories: ReconcileCategories, tree: CategoryTree, now: Date
  ) -> TransactionEntry {
    var result = resized(entry, to: amount, now: now)
    result.transaction.kind = kind
    let category = kind == .expense ? categories.expense : categories.income
    for index in result.parts.indices {
      result.parts[index].categoryId = category
      result.parts[index].categorySource = .system
      if kind == .expense {
        let decision = QualityResolver.resolve(categoryId: category, categories: tree)
        result.parts[index].quality = decision.quality
        result.parts[index].qualitySource = decision.source
      } else {
        result.parts[index].quality = nil
        result.parts[index].qualitySource = nil
      }
    }
    return result
  }

  /// Rounded half away from zero to stored units; clamped rather than trapping.
  static func rounded(_ value: Decimal) -> AmountE4 {
    (try? AmountE4(decimal: value)) ?? (value < 0 ? AmountE4(raw: .min) : AmountE4(raw: .max))
  }
}
