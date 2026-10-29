import Foundation

/// One operation as a whole. Amounts live in its parts; `amountE4` is their total.
public struct Transaction: Identifiable, Hashable, Sendable, Codable {
  public var id: UUID
  public var kind: TransactionKind
  public var occurredAt: Date

  public var currency: CurrencyCode
  public var amountE4: AmountE4
  /// The expression the user typed, kept verbatim: "(1000+600)/2".
  public var amountExpr: String?

  public var rate: Decimal?
  public var rateDate: DateOnly?
  public var rateSource: RateSource?
  public var rateProvisional: Bool
  public var amountRubE4: AmountE4

  public var note: String?
  public var placeId: UUID?
  /// The account the money moved on.
  public var paymentMethodId: UUID?
  /// What the account moved when it does not hold `currency`: its main currency and the
  /// amount the bank showed, never estimated. Both `nil` when the account holds `currency`
  /// and moved by `amountE4` itself.
  public var accountCurrency: CurrencyCode?
  public var accountAmountE4: AmountE4?
  /// Income only: which month the money is for. Defaults to the month of the date.
  public var periodMonth: MonthKey?
  /// Payment against a debt.
  public var debtId: UUID?
  /// Purchase made on credit or in instalments.
  public var creditDebtId: UUID?

  public var importBatchId: UUID?
  public var externalId: String?

  public var createdAt: Date
  public var updatedAt: Date
  public var deletedAt: Date?
  /// The card that paid: always a card of `paymentMethodId`, which is what moves the money.
  /// `nil`: the account itself.
  public var cardId: UUID?
  /// The cashback the owner typed for this operation, in the currency that moved on the
  /// account — an expectation, never income. `nil`: the card's rules say what to expect.
  public var cashback: Money?
  /// The identifier of the time zone the operation was recorded in (`Asia/Makassar`); `nil`
  /// reads as Moscow, where every operation of the earlier versions was recorded. The day and
  /// the time of day the operation is shown on are read in this zone (`TravelDay`).
  public var timeZoneId: String?
  /// The owner marked the whole operation as a one-off (a laptop, a repair): it leaves the
  /// averages and the forecasts and stays in every total and every limit.
  public var isOneOff: Bool
  /// Where the operation came from: `manual`, `statement`, `screenshot` or `receipt`; `nil`
  /// reads as `manual`. Kept as the stored text so a value a newer build writes survives
  /// (`StatementOperationRecord` of `CoreCSV` has the typed form).
  public var source: String?
  /// What the bank said of the operation: `posted`, `pending`, `declined` or `unknown`; `nil`
  /// reads as `posted`.
  public var bankStatus: String?
  /// The day the bank posted the operation, when it is not the day of the operation.
  public var postedOn: DateOnly?
  /// The versioned hash of a statement line, which finds the same line when the same period is
  /// loaded again; never the text of the line.
  public var dedupKey: String?
  /// The last day of the warranty of what the operation bought; `nil`: none.
  public var warrantyUntil: DateOnly?
  /// Where the original of the warranty or the receipt lies, in the owner's words.
  public var warrantyWhere: String?
  /// The last day the goods can be returned; `nil`: none.
  public var returnUntil: DateOnly?
  /// How much the price fell for the owner (a coupon, points), in the currency of the operation;
  /// `nil`: none.
  public var discountE4: AmountE4?
  /// The owner's answer to «would you buy it again»; `nil`: not asked or not answered yet.
  public var regret: PurchaseRegret?
  /// The day the question about regret was put.
  public var regretAskedOn: DateOnly?
  /// A refund of the purchase is expected to reach the account by this day.
  public var refundWaitingUntil: DateOnly?
  /// The mileage of the car at a fill-up, whole kilometres.
  public var odometerKm: Int?

  public init(
    id: UUID = UUID(),
    kind: TransactionKind,
    occurredAt: Date,
    currency: CurrencyCode = .rub,
    amountE4: AmountE4,
    amountExpr: String? = nil,
    rate: Decimal? = nil,
    rateDate: DateOnly? = nil,
    rateSource: RateSource? = nil,
    rateProvisional: Bool = false,
    amountRubE4: AmountE4? = nil,
    note: String? = nil,
    placeId: UUID? = nil,
    paymentMethodId: UUID? = nil,
    accountCurrency: CurrencyCode? = nil,
    accountAmountE4: AmountE4? = nil,
    periodMonth: MonthKey? = nil,
    debtId: UUID? = nil,
    creditDebtId: UUID? = nil,
    importBatchId: UUID? = nil,
    externalId: String? = nil,
    createdAt: Date = Date(),
    updatedAt: Date = Date(),
    deletedAt: Date? = nil,
    cardId: UUID? = nil,
    cashback: Money? = nil,
    timeZoneId: String? = nil,
    isOneOff: Bool = false,
    source: String? = nil,
    bankStatus: String? = nil,
    postedOn: DateOnly? = nil,
    dedupKey: String? = nil,
    warrantyUntil: DateOnly? = nil,
    warrantyWhere: String? = nil,
    returnUntil: DateOnly? = nil,
    discountE4: AmountE4? = nil,
    regret: PurchaseRegret? = nil,
    regretAskedOn: DateOnly? = nil,
    refundWaitingUntil: DateOnly? = nil,
    odometerKm: Int? = nil
  ) {
    self.id = id
    self.kind = kind
    self.occurredAt = occurredAt
    self.currency = currency
    self.amountE4 = amountE4
    self.amountExpr = amountExpr
    self.rate = rate
    self.rateDate = rateDate
    self.rateSource = rateSource
    self.rateProvisional = rateProvisional
    self.amountRubE4 = amountRubE4 ?? amountE4
    self.note = note
    self.placeId = placeId
    self.paymentMethodId = paymentMethodId
    self.accountCurrency = accountCurrency
    self.accountAmountE4 = accountAmountE4
    self.periodMonth = periodMonth
    self.debtId = debtId
    self.creditDebtId = creditDebtId
    self.importBatchId = importBatchId
    self.externalId = externalId
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.deletedAt = deletedAt
    self.cardId = cardId
    self.cashback = cashback
    self.timeZoneId = timeZoneId
    self.isOneOff = isOneOff
    self.source = source
    self.bankStatus = bankStatus
    self.postedOn = postedOn
    self.dedupKey = dedupKey
    self.warrantyUntil = warrantyUntil
    self.warrantyWhere = warrantyWhere
    self.returnUntil = returnUntil
    self.discountE4 = discountE4
    self.regret = regret
    self.regretAskedOn = regretAskedOn
    self.refundWaitingUntil = refundWaitingUntil
    self.odometerKm = odometerKm
  }

  public var isDeleted: Bool { deletedAt != nil }

  /// What moved on the account: the stored leg when there is one, the operation's own amount
  /// otherwise.
  public var movedMoney: Money {
    if let accountCurrency, let accountAmountE4 {
      return Money(amount: accountAmountE4, currency: accountCurrency)
    }
    return Money(amount: amountE4, currency: currency)
  }
}

/// A part of an operation. Every operation has at least one; parts add up to the total.
public struct TransactionPart: Identifiable, Hashable, Sendable, Codable {
  public var id: UUID
  public var transactionId: UUID

  public var categoryId: UUID?
  public var categorySource: CategorySource
  public var quality: Quality?
  public var qualitySource: QualitySource?

  public var amountE4: AmountE4
  public var amountRubE4: AmountE4

  public var forWhom: ForWhom
  public var forPersonId: UUID?

  /// Paid for somebody else and expected back. Such a part is not my spending.
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
    transactionId: UUID,
    categoryId: UUID? = nil,
    categorySource: CategorySource = .manual,
    quality: Quality? = nil,
    qualitySource: QualitySource? = nil,
    amountE4: AmountE4,
    amountRubE4: AmountE4? = nil,
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
    self.transactionId = transactionId
    self.categoryId = categoryId
    self.categorySource = categorySource
    self.quality = quality
    self.qualitySource = qualitySource
    self.amountE4 = amountE4
    self.amountRubE4 = amountRubE4 ?? amountE4
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
}

/// An operation with its parts, as the app and the reports work with it.
public struct TransactionEntry: Identifiable, Hashable, Sendable, Codable {
  public var transaction: Transaction
  public var parts: [TransactionPart]

  public init(transaction: Transaction, parts: [TransactionPart]) {
    self.transaction = transaction
    self.parts = parts
  }

  public var id: UUID { transaction.id }
  public var isSplit: Bool { parts.count > 1 }

  /// Parts must add up to the operation total, otherwise the entry cannot be saved.
  public var partsBalance: AmountE4 {
    transaction.amountE4 - AmountE4.sum(parts.map(\.amountE4))
  }

  /// At least one part, and the parts add up to the total. A zero operation without parts
  /// adds up too, and is still not one the repository may save — the same rule as
  /// `TransactionDraft.isBalanced`.
  public var isBalanced: Bool { !parts.isEmpty && partsBalance.isZero }
}
