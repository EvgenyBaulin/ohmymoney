import CoreKit
import Foundation

/// What a line of a statement is worth in rubles, and the rate that says so.
public struct StatementRubles: Sendable, Hashable {
  public var amount: AmountE4
  /// Rubles per unit of the line's currency; `nil` for a line in rubles.
  public var rate: Decimal?
  public var rateDate: DateOnly?
  public var source: RateSource?
  public var isProvisional: Bool
}

public enum StatementRubleResolver {
  /// The magnitude of a line in rubles. A line in rubles is its own amount. A line in another
  /// currency that the bank also gives in rubles (the account is charged in rubles) takes the
  /// bank's figure and the rate it implies — the bank's word, never replaced by the Central
  /// Bank's. Otherwise `rate` (the day's rate from the cache) converts it; with no rate the
  /// answer is `nil`, and the line waits instead of being written at a guessed figure.
  public static func resolve(
    _ operation: ImportedOperation,
    rate: (CurrencyCode, DateOnly) -> (rate: Decimal, provisional: Bool)?
  ) -> StatementRubles? {
    let magnitude = operation.amount.magnitude
    if operation.currency == .rub {
      return StatementRubles(
        amount: magnitude, rate: nil, rateDate: nil, source: nil, isProvisional: false)
    }
    if operation.accountCurrency == .rub, let account = operation.accountAmount,
      !magnitude.isZero
    {
      let rubles = account.magnitude
      let perUnit = DecimalMath.round(rubles.decimal / magnitude.decimal, scale: 6)
      return StatementRubles(
        amount: rubles, rate: perUnit, rateDate: operation.moment.day, source: .imported,
        isProvisional: false)
    }
    guard let known = rate(operation.currency, operation.moment.day), known.rate > 0 else {
      return nil
    }
    let rubles = DecimalMath.round(magnitude.decimal * known.rate, scale: 4)
    guard let amount = try? AmountE4(decimal: rubles) else { return nil }
    return StatementRubles(
      amount: amount, rate: known.rate, rateDate: operation.moment.day, source: .cbr,
      isProvisional: known.provisional)
  }
}

/// Everything about a line the person or the rules decided before writing.
public struct StatementEntryChoice: Sendable, Hashable {
  public var categoryID: UUID?
  public var categorySource: CategorySource
  public var quality: Quality?
  public var placeID: UUID?
  /// The card the line was paid with, when a card of the account carries the last digits the
  /// file names.
  public var cardID: UUID?

  public init(
    categoryID: UUID?, categorySource: CategorySource = .imported, quality: Quality? = nil,
    placeID: UUID? = nil, cardID: UUID? = nil
  ) {
    self.categoryID = categoryID
    self.categorySource = categorySource
    self.quality = quality
    self.placeID = placeID
    self.cardID = cardID
  }
}

/// Turns lines of a statement into operations and transfers of the books. Pure: ids, time and
/// the rubles are given, so the same line always becomes the same operation.
public enum StatementEntryBuilder {
  /// The moment of a line on the clock of the bank's zone. A line without a time of day sits at
  /// noon, so the day survives a change of zone.
  public static func occurredAt(_ moment: StatementMoment, zoneID: String) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: zoneID) ?? TravelDay.moscowZone
    var parts = DateComponents()
    parts.year = moment.day.year
    parts.month = moment.day.month
    parts.day = moment.day.day
    let minute = moment.minuteOfDay ?? 12 * 60
    parts.hour = minute / 60
    parts.minute = minute % 60
    return calendar.date(from: parts) ?? Date(timeIntervalSince1970: 0)
  }

  /// The kind of operation a line is: an expense when money left, a refund of a purchase when
  /// the bank says so, income otherwise.
  public static func kind(of operation: ImportedOperation) -> TransactionKind {
    if operation.amount.isNegative { return .expense }
    return operation.kind == .purchaseRefund ? .refund : .income
  }

  /// The operation of a line, with one part holding the whole amount.
  ///
  /// `zoneID` is the bank's zone: the operation is recorded in it, so its day and time read as
  /// the bank wrote them. `accountKey` finds the same line again (`StatementDedupKey`).
  public static func entry(
    for operation: ImportedOperation, accountID: UUID, accountKey: String, importID: UUID?,
    zoneID: String, rubles: StatementRubles, choice: StatementEntryChoice,
    id: UUID = UUID(), now: Date
  ) -> TransactionEntry {
    let kind = kind(of: operation)
    let magnitude = operation.amount.magnitude
    var accountCurrency: CurrencyCode?
    var accountAmount: AmountE4?
    if let currency = operation.accountCurrency, let amount = operation.accountAmount,
      currency != operation.currency
    {
      accountCurrency = currency
      accountAmount = amount.magnitude
    }
    let note = operation.merchant ?? operation.counterparty.name ?? operation.description
    var cashback: Money?
    if kind == .expense, let accrued = operation.cashbackAccrued, !accrued.isZero {
      cashback = Money(
        amount: accrued.magnitude, currency: operation.accountCurrency ?? operation.currency)
    }
    let transaction = Transaction(
      id: id, kind: kind, occurredAt: occurredAt(operation.moment, zoneID: zoneID),
      currency: operation.currency, amountE4: magnitude, rate: rubles.rate,
      rateDate: rubles.rateDate, rateSource: rubles.source,
      rateProvisional: rubles.isProvisional, amountRubE4: rubles.amount, note: note,
      placeId: choice.placeID, paymentMethodId: accountID, accountCurrency: accountCurrency,
      accountAmountE4: accountAmount, importBatchId: importID, createdAt: now, updatedAt: now,
      cardId: choice.cardID, cashback: cashback,
      timeZoneId: zoneID == TravelDay.moscowId ? nil : zoneID, source: "statement",
      bankStatus: operation.status.rawValue, postedOn: operation.postedOn,
      dedupKey: StatementDedupKey(account: accountKey, operation: operation).value)
    let part = TransactionPart(
      transactionId: id, categoryId: choice.categoryID, categorySource: choice.categorySource,
      quality: kind.hasQuality ? choice.quality : nil,
      qualitySource: kind.hasQuality && choice.quality != nil ? .category : nil,
      amountE4: magnitude,
      amountRubE4: rubles.amount)
    return TransactionEntry(transaction: transaction, parts: [part])
  }

  /// The hand-typed operation a bank line merges into: the amount, the moment of the day, the
  /// status and the key become the bank's; the category, the comment and the place stay the
  /// person's. The operation does not point at the import, so undoing the import leaves it.
  public static func merged(
    _ existing: TransactionEntry, with operation: ImportedOperation, accountKey: String,
    zoneID: String, rubles: StatementRubles, now: Date
  ) -> TransactionEntry {
    var entry = existing
    let magnitude = operation.amount.magnitude
    entry.transaction.amountE4 = magnitude
    entry.transaction.amountRubE4 = rubles.amount
    entry.transaction.rate = rubles.rate
    entry.transaction.rateDate = rubles.rateDate
    entry.transaction.rateSource = rubles.source
    entry.transaction.rateProvisional = rubles.isProvisional
    if operation.moment.minuteOfDay != nil {
      entry.transaction.occurredAt = occurredAt(operation.moment, zoneID: zoneID)
      entry.transaction.timeZoneId = zoneID == TravelDay.moscowId ? nil : zoneID
    }
    entry.transaction.bankStatus = operation.status.rawValue
    entry.transaction.postedOn = operation.postedOn
    entry.transaction.dedupKey = StatementDedupKey(account: accountKey, operation: operation).value
    entry.transaction.updatedAt = now
    if entry.parts.count == 1 {
      entry.parts[0].amountE4 = magnitude
      entry.parts[0].amountRubE4 = rubles.amount
    }
    return entry
  }

  /// What finds a transfer again when the same two lines are loaded once more: both halves' keys
  /// (each under its own account) and the place of the pair among identical ones — two equal
  /// transfers on one day are two, and stay two. It is the transfer's external id, which is
  /// unique, so a transfer is never written twice.
  public static func transferExternalID(
    outgoing: ImportedOperation, from fromAccount: UUID, incoming: ImportedOperation,
    to toAccount: UUID, ordinal: Int = 0
  ) -> String {
    let out = StatementDedupKey(account: fromAccount.uuidString, operation: outgoing).value
    let into = StatementDedupKey(account: toAccount.uuidString, operation: incoming).value
    return "stmt:" + StatementText.fnv1a([out, into, String(ordinal)].joined(separator: "|"))
  }

  /// The transfer two paired lines stand for: the outgoing line's account and amount, the
  /// incoming line's account and amount, under the external id of `transferExternalID`.
  public static func transfer(
    outgoing: ImportedOperation, from fromAccount: UUID, incoming: ImportedOperation,
    to toAccount: UUID, zoneID: String, now: Date, ordinal: Int = 0, id: UUID = UUID()
  ) -> Transfer {
    Transfer(
      id: id, occurredAt: occurredAt(outgoing.moment, zoneID: zoneID), fromAccountId: fromAccount,
      fromCurrency: outgoing.currency, fromAmountE4: outgoing.amount.magnitude,
      toAccountId: toAccount, toCurrency: incoming.currency,
      toAmountE4: incoming.amount.magnitude, createdAt: now, updatedAt: now,
      externalId: transferExternalID(
        outgoing: outgoing, from: fromAccount, incoming: incoming, to: toAccount,
        ordinal: ordinal),
      arrivedAt: incoming.moment.day > outgoing.moment.day
        ? occurredAt(incoming.moment, zoneID: zoneID) : nil)
  }
}
