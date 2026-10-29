import CoreKit
import Foundation
import GRDB

/// The cashback typed for an operation is two columns, `cashback_currency` and `cashback_e4`:
/// both or neither. One without the other — only a hand edit leaves it — reads as none.
extension CoreKit.Transaction: @retroactive FetchableRecord, @retroactive PersistableRecord {
  public static let databaseTableName = "transactions"

  public init(row: Row) throws {
    self.init(
      id: try RowMapping.uuid(row, "id"),
      kind: TransactionKind(rawValue: row["kind"] ?? "expense") ?? .expense,
      occurredAt: try RowMapping.instant(row, "occurred_at"),
      currency: CurrencyCode(row["currency"] ?? "RUB"),
      amountE4: try RowMapping.amount(row, "amount_e4"),
      amountExpr: row["amount_expr"],
      rate: RowMapping.decimal(row, "rate"),
      rateDate: RowMapping.day(row, "rate_date"),
      rateSource: (row["rate_source"] as String?).flatMap(RateSource.init(rawValue:)),
      rateProvisional: try RowMapping.flag(row, "rate_provisional", fallback: false),
      amountRubE4: try RowMapping.amount(row, "amount_rub_e4"),
      note: row["note"],
      placeId: RowMapping.optionalUUID(row, "place_id"),
      paymentMethodId: RowMapping.optionalUUID(row, "payment_method_id"),
      accountCurrency: RowMapping.currency(row, "account_currency"),
      accountAmountE4: try RowMapping.optionalAmount(row, "account_amount_e4"),
      periodMonth: RowMapping.month(row, "period_month"),
      debtId: RowMapping.optionalUUID(row, "debt_id"),
      creditDebtId: RowMapping.optionalUUID(row, "credit_debt_id"),
      importBatchId: RowMapping.optionalUUID(row, "import_batch_id"),
      externalId: row["external_id"],
      createdAt: try RowMapping.instant(row, "created_at"),
      updatedAt: try RowMapping.instant(row, "updated_at"),
      deletedAt: try RowMapping.optionalInstant(row, "deleted_at"),
      cardId: RowMapping.optionalUUID(row, "card_id"),
      cashback: try Self.cashback(row),
      timeZoneId: Self.zone(row),
      isOneOff: (try? RowMapping.flag(row, "one_off", fallback: false)) ?? false,
      source: Self.text(row, "source"), bankStatus: Self.text(row, "bank_status"),
      postedOn: RowMapping.day(row, "posted_on"), dedupKey: Self.text(row, "dedup_key"),
      warrantyUntil: RowMapping.day(row, "warranty_until"),
      warrantyWhere: Self.text(row, "warranty_where"),
      returnUntil: RowMapping.day(row, "return_until"))
  }

  /// A blank text reads as none, like a NULL.
  private static func text(_ row: Row, _ column: String) -> String? {
    guard let text: String = row[column] else { return nil }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  /// A blank zone reads as none, like a NULL: Moscow.
  private static func zone(_ row: Row) -> String? {
    guard let text: String = row["time_zone"] else { return nil }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private static func cashback(_ row: Row) throws -> Money? {
    guard let currency = RowMapping.currency(row, "cashback_currency"),
      let amount = try RowMapping.optionalAmount(row, "cashback_e4")
    else { return nil }
    return Money(amount: amount, currency: currency)
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["id"] = id.uuidString
    container["kind"] = kind.rawValue
    container["occurred_at"] = StoredInstant.databaseValue(occurredAt)
    container["currency"] = currency.code
    container["amount_e4"] = amountE4.raw
    container["amount_expr"] = amountExpr
    container["rate"] = RowMapping.string(rate)
    container["rate_date"] = rateDate?.iso
    container["rate_source"] = rateSource?.operationMark.rawValue
    container["rate_provisional"] = rateProvisional
    container["amount_rub_e4"] = amountRubE4.raw
    container["note"] = note
    container["place_id"] = placeId?.uuidString
    container["payment_method_id"] = paymentMethodId?.uuidString
    container["account_currency"] = accountCurrency?.code
    container["account_amount_e4"] = accountAmountE4?.raw
    container["period_month"] = periodMonth?.iso
    container["debt_id"] = debtId?.uuidString
    container["credit_debt_id"] = creditDebtId?.uuidString
    container["import_batch_id"] = importBatchId?.uuidString
    container["external_id"] = externalId
    container["created_at"] = StoredInstant.databaseValue(createdAt)
    container["updated_at"] = StoredInstant.databaseValue(updatedAt)
    container["deleted_at"] = StoredInstant.databaseValue(deletedAt)
    container["card_id"] = cardId?.uuidString
    container["cashback_currency"] = cashback?.currency.code
    container["cashback_e4"] = cashback?.amount.raw
    container["time_zone"] = timeZoneId
    container["one_off"] = isOneOff
    container["source"] = source
    container["bank_status"] = bankStatus
    container["posted_on"] = postedOn?.iso
    container["dedup_key"] = dedupKey
    container["warranty_until"] = warrantyUntil?.iso
    container["warranty_where"] = warrantyWhere
    container["return_until"] = returnUntil?.iso
  }
}

extension TransactionPart: @retroactive FetchableRecord, @retroactive PersistableRecord {
  public static let databaseTableName = "transaction_parts"

  public init(row: Row) throws {
    self.init(
      id: try RowMapping.uuid(row, "id"),
      transactionId: try RowMapping.uuid(row, "transaction_id"),
      categoryId: RowMapping.optionalUUID(row, "category_id"),
      categorySource: CategorySource(rawValue: row["category_source"] ?? "manual") ?? .manual,
      quality: (row["quality"] as String?).flatMap(Quality.init(rawValue:)),
      qualitySource: (row["quality_source"] as String?).flatMap(QualitySource.init(rawValue:)),
      amountE4: try RowMapping.amount(row, "amount_e4"),
      amountRubE4: try RowMapping.amount(row, "amount_rub_e4"),
      forWhom: ForWhom(rawValue: row["for_whom"] ?? "me") ?? .me,
      forPersonId: RowMapping.optionalUUID(row, "for_person_id"),
      reimbursable: try RowMapping.flag(row, "reimbursable", fallback: false),
      debtorPersonId: RowMapping.optionalUUID(row, "debtor_person_id"),
      reimbursementStatus: (row["reimbursement_status"] as String?)
        .flatMap(ReimbursementStatus.init(rawValue:)),
      eventId: RowMapping.optionalUUID(row, "event_id"),
      goalId: RowMapping.optionalUUID(row, "goal_id"),
      note: row["note"],
      refundOfPartId: RowMapping.optionalUUID(row, "refund_of_part_id"))
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["id"] = id.uuidString
    container["transaction_id"] = transactionId.uuidString
    container["category_id"] = categoryId?.uuidString
    container["category_source"] = categorySource.rawValue
    container["quality"] = quality?.rawValue
    container["quality_source"] = qualitySource?.rawValue
    container["amount_e4"] = amountE4.raw
    container["amount_rub_e4"] = amountRubE4.raw
    container["for_whom"] = forWhom.rawValue
    container["for_person_id"] = forPersonId?.uuidString
    container["reimbursable"] = reimbursable
    container["debtor_person_id"] = debtorPersonId?.uuidString
    container["reimbursement_status"] = reimbursementStatus?.rawValue
    container["event_id"] = eventId?.uuidString
    container["goal_id"] = goalId?.uuidString
    container["note"] = note
    container["refund_of_part_id"] = refundOfPartId?.uuidString
  }
}

extension ReimbursementLink: @retroactive FetchableRecord, @retroactive PersistableRecord {
  public static let databaseTableName = "reimbursement_links"

  public init(row: Row) throws {
    self.init(
      id: try RowMapping.uuid(row, "id"),
      reimbursementTxId: try RowMapping.uuid(row, "reimbursement_tx_id"),
      partId: try RowMapping.uuid(row, "part_id"),
      amountE4: try RowMapping.amount(row, "amount_e4"))
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["id"] = id.uuidString
    container["reimbursement_tx_id"] = reimbursementTxId.uuidString
    container["part_id"] = partId.uuidString
    container["amount_e4"] = amountE4.raw
  }
}

/// `deleted_at` is an instant, written the way the one of an operation is (`StoredInstant`).
extension Debt: @retroactive FetchableRecord, @retroactive PersistableRecord {
  public static let databaseTableName = "debts"

  public init(row: Row) throws {
    self.init(
      id: try RowMapping.uuid(row, "id"),
      direction: DebtDirection(rawValue: row["direction"] ?? "i_owe") ?? .iOwe,
      type: DebtType(rawValue: row["type"] ?? "personal") ?? .personal,
      name: row["name"] ?? "",
      personId: RowMapping.optionalUUID(row, "person_id"),
      currency: CurrencyCode(row["currency"] ?? "RUB"),
      interestRate: RowMapping.decimal(row, "interest_rate"),
      monthlyPaymentE4: try RowMapping.optionalAmount(row, "monthly_payment_e4"),
      paymentDay: try RowMapping.optionalInteger(row, "payment_day"),
      remindDaysBefore: try RowMapping.optionalInteger(row, "remind_days_before"),
      paymentsAreExpenses: try RowMapping.flag(row, "payments_are_expenses", fallback: true),
      origin: DebtOrigin(rawValue: row["origin"] ?? "existing") ?? .existing,
      note: row["note"],
      closed: try RowMapping.flag(row, "closed", fallback: false),
      loansSubcategoryId: RowMapping.optionalUUID(row, "loans_subcategory_id"),
      deletedAt: try RowMapping.optionalInstant(row, "deleted_at"),
      accruesInterest: try RowMapping.flag(row, "accrues_interest", fallback: false),
      grace: Self.grace(row),
      repayMonths: (try? RowMapping.optionalInteger(row, "repay_months")) ?? nil,
      steps: Self.steps(row),
      parts: Self.integer(row, "parts"),
      markupE4: (try? RowMapping.optionalAmount(row, "markup_e4")) ?? nil,
      psk: RowMapping.decimal(row, "psk"),
      prepayAnyDay: (try? RowMapping.flag(row, "prepay_any_day", fallback: true)) ?? true,
      prepayNoticeDays: Self.integer(row, "prepay_notice_days"),
      plannedPrepay: Self.plannedPrepay(row),
      inLadder: Self.integer(row, "in_ladder").map { $0 != 0 },
      pledge: (try? RowMapping.flag(row, "pledge", fallback: false)) ?? false,
      returnBy: RowMapping.day(row, "return_by"),
      termsReviewed: (try? RowMapping.flag(row, "terms_reviewed", fallback: false)) ?? false)
  }

  /// A number that does not read — only a hand edit leaves one — reads as not said.
  private static func integer(_ row: Row, _ column: String) -> Int? {
    (try? RowMapping.optionalInteger(row, column)) ?? nil
  }

  /// Dues every few days: the step and the first day, both or neither.
  private static func steps(_ row: Row) -> DebtSteps? {
    guard let every = integer(row, "step_days"), DebtSteps.range.contains(every),
      let first = RowMapping.day(row, "first_due_on")
    else { return nil }
    return DebtSteps(everyDays: every, firstDue: first)
  }

  /// The early repayment planned: the day and the sum, both or neither.
  private static func plannedPrepay(_ row: Row) -> PlannedPrepay? {
    guard let day = RowMapping.day(row, "planned_prepay_on"),
      let amount = (try? RowMapping.optionalAmount(row, "planned_prepay_e4")) ?? nil
    else { return nil }
    return PlannedPrepay(day: day, amountE4: amount)
  }

  /// The grace period. A day or a word that does not read — only a hand edit leaves one — or a
  /// fixed payment without a sum reads as no grace period: one damaged cell must not stop the
  /// history from being read.
  private static func grace(_ row: Row) -> DebtGrace? {
    guard let mainFrom = RowMapping.day(row, "main_from"),
      let payment = GracePayment(
        storedKind: row["grace_kind"],
        amount: (try? RowMapping.optionalAmount(row, "grace_payment_e4")) ?? nil)
    else { return nil }
    return DebtGrace(mainFrom: mainFrom, payment: payment)
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["id"] = id.uuidString
    container["direction"] = direction.rawValue
    container["type"] = type.rawValue
    container["name"] = name
    container["person_id"] = personId?.uuidString
    container["currency"] = currency.code
    container["interest_rate"] = RowMapping.string(interestRate)
    container["monthly_payment_e4"] = monthlyPaymentE4?.raw
    container["payment_day"] = paymentDay
    container["remind_days_before"] = remindDaysBefore
    container["payments_are_expenses"] = paymentsAreExpenses
    container["origin"] = origin.rawValue
    container["note"] = note
    container["closed"] = closed
    container["loans_subcategory_id"] = loansSubcategoryId?.uuidString
    container["deleted_at"] = StoredInstant.databaseValue(deletedAt)
    container["accrues_interest"] = accruesInterest
    container["main_from"] = grace?.mainFrom.iso
    container["grace_kind"] = grace?.payment.storedKind
    container["grace_payment_e4"] = grace?.payment.fixedAmount?.raw
    container["repay_months"] = repayMonths
    container["step_days"] = steps?.everyDays
    container["first_due_on"] = steps?.firstDue.iso
    container["parts"] = parts
    container["markup_e4"] = markupE4?.raw
    container["psk"] = RowMapping.string(psk)
    container["prepay_any_day"] = prepayAnyDay
    container["prepay_notice_days"] = prepayNoticeDays
    container["planned_prepay_on"] = plannedPrepay?.day.iso
    container["planned_prepay_e4"] = plannedPrepay?.amountE4.raw
    container["in_ladder"] = inLadder
    container["pledge"] = pledge
    container["return_by"] = returnBy?.iso
    container["terms_reviewed"] = termsReviewed
  }
}

extension DebtEntry: @retroactive FetchableRecord, @retroactive PersistableRecord {
  public static let databaseTableName = "debt_entries"

  public init(row: Row) throws {
    self.init(
      id: try RowMapping.uuid(row, "id"),
      debtId: try RowMapping.uuid(row, "debt_id"),
      groupName: row["group_name"],
      date: RowMapping.day(row, "date"),
      description: row["description"],
      fullAmountE4: try RowMapping.optionalAmount(row, "full_amount_e4"),
      share: RowMapping.decimal(row, "share"),
      amountE4: try RowMapping.amount(row, "amount_e4"),
      kind: DebtEntryKind(rawValue: row["kind"] ?? "adjustment") ?? .adjustment,
      transactionId: RowMapping.optionalUUID(row, "transaction_id"),
      note: row["note"],
      paymentMethodId: RowMapping.optionalUUID(row, "payment_method_id"),
      occurredAt: try RowMapping.optionalInstant(row, "occurred_at"),
      accountCurrency: RowMapping.currency(row, "account_currency"),
      accountAmountE4: try RowMapping.optionalAmount(row, "account_amount_e4"),
      closesTerm: row["closes_term"] ?? false,
      tranche: row["tranche"] ?? false,
      prepay: (row["prepay"] as String?).flatMap(PrepayChoice.init(rawValue:)))
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["id"] = id.uuidString
    container["debt_id"] = debtId.uuidString
    container["group_name"] = groupName
    container["date"] = date?.iso
    container["description"] = description
    container["full_amount_e4"] = fullAmountE4?.raw
    container["share"] = RowMapping.string(share)
    container["amount_e4"] = amountE4.raw
    container["kind"] = kind.rawValue
    container["transaction_id"] = transactionId?.uuidString
    container["note"] = note
    container["payment_method_id"] = paymentMethodId?.uuidString
    container["occurred_at"] = StoredInstant.databaseValue(occurredAt)
    container["account_currency"] = accountCurrency?.code
    container["account_amount_e4"] = accountAmountE4?.raw
    container["closes_term"] = closesTerm
    container["tranche"] = tranche
    container["prepay"] = prepay?.rawValue
  }
}
