import Foundation

/// What the entry line and the ↓ panel build before anything is written to the database.
/// A draft is always validated first: parts must add up to the total.
public struct TransactionDraft: Hashable, Sendable {
  public var kind: TransactionKind
  public var occurredAt: Date
  public var currency: CurrencyCode
  public var amount: AmountE4
  public var amountExpression: String?
  public var rate: Decimal?
  public var rateDate: DateOnly?
  public var rateSource: RateSource?
  public var rateProvisional: Bool
  public var note: String?
  public var placeId: UUID?
  public var paymentMethodId: UUID?
  /// «Списано со счёта»: what the account moved when it does not hold `currency` — its main
  /// currency and the amount the bank showed. Both `nil` otherwise.
  public var accountCurrency: CurrencyCode?
  public var accountAmount: AmountE4?
  public var periodMonth: MonthKey?
  public var debtId: UUID?
  public var creditDebtId: UUID?
  public var parts: [PartDraft]
  /// The card that paid, a card of `paymentMethodId`; `nil` — the account itself.
  public var cardId: UUID?
  /// The cashback the owner typed, in the currency that moves on the account.
  public var cashback: Money?

  public init(
    kind: TransactionKind = .expense,
    occurredAt: Date = Date(),
    currency: CurrencyCode = .rub,
    amount: AmountE4 = .zero,
    amountExpression: String? = nil,
    rate: Decimal? = nil,
    rateDate: DateOnly? = nil,
    rateSource: RateSource? = nil,
    rateProvisional: Bool = false,
    note: String? = nil,
    placeId: UUID? = nil,
    paymentMethodId: UUID? = nil,
    accountCurrency: CurrencyCode? = nil,
    accountAmount: AmountE4? = nil,
    periodMonth: MonthKey? = nil,
    debtId: UUID? = nil,
    creditDebtId: UUID? = nil,
    parts: [PartDraft] = [],
    cardId: UUID? = nil,
    cashback: Money? = nil
  ) {
    self.kind = kind
    self.occurredAt = occurredAt
    self.currency = currency
    self.amount = amount
    self.amountExpression = amountExpression
    self.rate = rate
    self.rateDate = rateDate
    self.rateSource = rateSource
    self.rateProvisional = rateProvisional
    self.note = note
    self.placeId = placeId
    self.paymentMethodId = paymentMethodId
    self.accountCurrency = accountCurrency
    self.accountAmount = accountAmount
    self.periodMonth = periodMonth
    self.debtId = debtId
    self.creditDebtId = creditDebtId
    self.parts = parts
    self.cardId = cardId
    self.cashback = cashback
  }

  /// Reopens a saved operation for editing: the panel edits drafts, never records.
  public init(entry: TransactionEntry) {
    let transaction = entry.transaction
    self.init(
      kind: transaction.kind,
      occurredAt: transaction.occurredAt,
      currency: transaction.currency,
      amount: transaction.amountE4,
      amountExpression: transaction.amountExpr,
      rate: transaction.rate,
      rateDate: transaction.rateDate,
      rateSource: transaction.rateSource,
      rateProvisional: transaction.rateProvisional,
      note: transaction.note,
      placeId: transaction.placeId,
      paymentMethodId: transaction.paymentMethodId,
      accountCurrency: transaction.accountCurrency,
      accountAmount: transaction.accountAmountE4,
      periodMonth: transaction.periodMonth,
      debtId: transaction.debtId,
      creditDebtId: transaction.creditDebtId,
      parts: entry.parts.map(PartDraft.init(part:)),
      cardId: transaction.cardId,
      cashback: transaction.cashback)
  }

  /// Amount not yet distributed between parts. Saving is only allowed when it is zero.
  public var unallocated: AmountE4 {
    amount - AmountE4.sum(parts.map(\.amount))
  }

  public var isBalanced: Bool {
    parts.isEmpty ? false : unallocated.isZero
  }

  /// Fills the single implicit part used by the plain entry line.
  public mutating func normalizeSinglePart() {
    if parts.isEmpty {
      parts = [PartDraft(amount: amount)]
    } else if parts.count == 1 {
      parts[0].amount = amount
    }
  }

  /// Materializes the draft into records ready for the repository.
  ///
  /// A leg in rubles is the operation's rubles: what the bank charged the ruble account is
  /// what the operation cost, markup included. When it is not what the rate gives
  /// (`round(amount × rate)`), it was typed from the statement, and the rate becomes the one it
  /// implies — `leg ÷ amount` to six places, a manual rate the refinement of the bank's rates
  /// leaves alone. A leg that is exactly the rate's figure keeps the bank's rate, and is
  /// refined with it. A refund taken back from a purchase keeps the purchase's rate whatever
  /// its leg says: the leg is only the money that moved.
  public func materialize(
    id: UUID = UUID(),
    now: Date = Date(),
    timeZone: TimeZone = .current,
    rublesConverter: (AmountE4) throws -> AmountE4 = { $0 }
  ) throws -> TransactionEntry {
    var rate = rate
    var rateSource = rateSource
    var rateProvisional = rateProvisional
    let totalRub: AmountE4
    if let leg = rubleLeg {
      totalRub = leg
      let prefill = rate.flatMap { try? AmountE4(decimal: amount.decimal * $0) }
      if prefill != leg, !amount.isZero {
        rate = DecimalMath.round(leg.decimal / amount.decimal, scale: 6)
        rateSource = .manual
        rateProvisional = false
      }
    } else {
      totalRub = try rublesConverter(amount)
    }
    let transaction = Transaction(
      id: id,
      kind: kind,
      occurredAt: occurredAt,
      currency: currency,
      amountE4: amount,
      amountExpr: amountExpression,
      rate: rate,
      rateDate: rateDate,
      rateSource: rateSource,
      rateProvisional: rateProvisional,
      amountRubE4: totalRub,
      note: note,
      placeId: placeId,
      paymentMethodId: paymentMethodId,
      accountCurrency: accountCurrency,
      accountAmountE4: accountAmount,
      periodMonth: periodMonth,
      debtId: debtId,
      creditDebtId: creditDebtId,
      createdAt: now,
      updatedAt: now,
      cardId: cardId,
      cashback: cashback,
      timeZoneId: TravelDay.recordedId(in: timeZone))

    // Ruble shares are split from the converted total so rounding never loses a unit.
    let shares = totalRub.allocated(proportionallyTo: parts.map(\.amount), outOf: amount)
    let parts = zip(parts, shares).map { part, rubles in
      part.materialize(transactionId: id, amountRub: rubles)
    }
    return TransactionEntry(transaction: transaction, parts: parts)
  }

  /// The leg that sets the operation's rubles: one in rubles, on an operation in another
  /// currency that takes nothing back from a purchase.
  private var rubleLeg: AmountE4? {
    guard accountCurrency == .rub, currency != .rub, let accountAmount,
      !parts.contains(where: { $0.refundOfPartId != nil })
    else { return nil }
    return accountAmount
  }

  /// Materializes the draft over the saved operation it was opened from. Only what the
  /// panel edits changes; the rest stays as `original` has it (`TransactionEntry.rebased`).
  public func materialize(
    updating original: TransactionEntry,
    now: Date = Date(),
    timeZone: TimeZone = .current,
    rublesConverter: (AmountE4) throws -> AmountE4 = { $0 }
  ) throws -> TransactionEntry {
    try materialize(
      id: original.id, now: now, timeZone: timeZone, rublesConverter: rublesConverter
    )
    .rebased(onto: original)
  }

}

extension TransactionEntry {
  /// The edit of a saved operation laid over that operation as it is now: what the ↓ panel
  /// edits comes from `self`, everything else from `current`.
  ///
  /// * When the operation was created and which import it came from (`import_batch_id`,
  ///   `external_id`) are facts about it, not fields of the panel: resetting them would put
  ///   an old purchase among today's additions and let the same bank row be imported a
  ///   second time. Whether it is deleted is not the panel's either.
  /// * How far a part paid for somebody else has come back is written by a reimbursement
  ///   and by writing the part off, never by the panel. An editor holds the copy it was
  ///   opened with, and one of those may happen meanwhile: the old «expected» written back
  ///   would list the part as owed again while its link says the money came. Parts are
  ///   matched by id; one `current` has no status for — new, or paid for nobody before —
  ///   keeps what the draft gave it.
  ///
  /// The account and what moved on it (`accountCurrency`, `accountAmountE4`), the card that paid
  /// and the cashback typed for the operation, and the purchase part a refund takes back from,
  /// are the panel's: they come from the edit. An edit rebuilds the operation from the draft,
  /// so a draft opened from an operation carries its card and cashback, or the edit would drop
  /// them.
  public func rebased(onto current: TransactionEntry) -> TransactionEntry {
    var rebased = self
    rebased.transaction.createdAt = current.transaction.createdAt
    rebased.transaction.importBatchId = current.transaction.importBatchId
    rebased.transaction.externalId = current.transaction.externalId
    rebased.transaction.deletedAt = current.transaction.deletedAt
    // The zone is a fact of the record: an edit that leaves the moment where it was leaves the
    // zone it was recorded in; one that moves the moment is a new date typed on this Mac.
    if rebased.transaction.occurredAt == current.transaction.occurredAt {
      rebased.transaction.timeZoneId = current.transaction.timeZoneId
    }
    let statuses = Dictionary(
      current.parts.compactMap { part in part.reimbursementStatus.map { (part.id, $0) } },
      uniquingKeysWith: { first, _ in first })
    for index in rebased.parts.indices where rebased.parts[index].reimbursable {
      if let status = statuses[rebased.parts[index].id] {
        rebased.parts[index].reimbursementStatus = status
      }
    }
    return rebased
  }
}

/// One part of a draft: its own category, quality, amount and analytics cuts.
public struct PartDraft: Hashable, Sendable, Identifiable {
  public var id: UUID
  public var categoryId: UUID?
  public var categorySource: CategorySource
  public var quality: Quality?
  public var qualitySource: QualitySource?
  public var amount: AmountE4
  public var amountExpression: String?
  public var forWhom: ForWhom
  public var forPersonId: UUID?
  public var reimbursable: Bool
  public var debtorPersonId: UUID?
  public var reimbursementStatus: ReimbursementStatus?
  public var eventId: UUID?
  public var goalId: UUID?
  public var note: String?
  /// A refund part: the part of a purchase it takes money back from.
  public var refundOfPartId: UUID?

  public init(
    id: UUID = UUID(),
    categoryId: UUID? = nil,
    categorySource: CategorySource = .manual,
    quality: Quality? = nil,
    qualitySource: QualitySource? = nil,
    amount: AmountE4 = .zero,
    amountExpression: String? = nil,
    forWhom: ForWhom = .me,
    forPersonId: UUID? = nil,
    reimbursable: Bool = false,
    debtorPersonId: UUID? = nil,
    reimbursementStatus: ReimbursementStatus? = nil,
    eventId: UUID? = nil,
    goalId: UUID? = nil,
    note: String? = nil,
    refundOfPartId: UUID? = nil
  ) {
    self.id = id
    self.categoryId = categoryId
    self.categorySource = categorySource
    self.quality = quality
    self.qualitySource = qualitySource
    self.amount = amount
    self.amountExpression = amountExpression
    self.forWhom = forWhom
    self.forPersonId = forPersonId
    self.reimbursable = reimbursable
    self.debtorPersonId = debtorPersonId
    self.reimbursementStatus = reimbursementStatus
    self.eventId = eventId
    self.goalId = goalId
    self.note = note
    self.refundOfPartId = refundOfPartId
  }

  public init(part: TransactionPart) {
    self.init(
      id: part.id,
      categoryId: part.categoryId,
      categorySource: part.categorySource,
      quality: part.quality,
      qualitySource: part.qualitySource,
      amount: part.amountE4,
      forWhom: part.forWhom,
      forPersonId: part.forPersonId,
      reimbursable: part.reimbursable,
      debtorPersonId: part.debtorPersonId,
      reimbursementStatus: part.reimbursementStatus,
      eventId: part.eventId,
      goalId: part.goalId,
      note: part.note,
      refundOfPartId: part.refundOfPartId)
  }

  public func materialize(transactionId: UUID, amountRub: AmountE4) -> TransactionPart {
    TransactionPart(
      id: id,
      transactionId: transactionId,
      categoryId: categoryId,
      categorySource: categorySource,
      quality: quality,
      qualitySource: qualitySource,
      amountE4: amount,
      amountRubE4: amountRub,
      forWhom: forWhom,
      forPersonId: forPersonId,
      reimbursable: reimbursable,
      debtorPersonId: debtorPersonId,
      reimbursementStatus: reimbursable ? (reimbursementStatus ?? .expected) : nil,
      eventId: eventId,
      goalId: goalId,
      note: note,
      refundOfPartId: refundOfPartId)
  }
}
