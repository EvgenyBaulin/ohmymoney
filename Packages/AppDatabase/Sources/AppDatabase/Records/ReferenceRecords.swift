import CoreKit
import Foundation
import GRDB

extension CoreKit.Category: @retroactive FetchableRecord, @retroactive PersistableRecord {
  public static let databaseTableName = "categories"

  public init(row: Row) throws {
    self.init(
      id: try RowMapping.uuid(row, "id"),
      parentId: RowMapping.optionalUUID(row, "parent_id"),
      kind: CategoryKind(rawValue: row["kind"] ?? "expense") ?? .expense,
      name: row["name"] ?? "",
      sort: try RowMapping.optionalInteger(row, "sort") ?? 0,
      archived: try RowMapping.flag(row, "archived", fallback: false),
      quality: (row["quality"] as String?).flatMap(Quality.init(rawValue:)),
      systemRole: (row["system_role"] as String?).flatMap(SystemRole.init(rawValue:)),
      essential: Self.essential(row),
      tax: Self.tax(row),
      basket: (row["basket"] as String?).flatMap(BudgetBasket.init(rawValue:)))
  }

  /// The tax of an income. A rate that does not read reads as none.
  private static func tax(_ row: Row) -> IncomeTax? {
    guard let rate = RowMapping.decimal(row, "tax_rate") else { return nil }
    return IncomeTax(
      rate: rate, npd: (try? RowMapping.flag(row, "tax_npd", fallback: false)) ?? false)
  }

  /// The mark «Необходимая трата». A value that is not a number — only a hand edit leaves one —
  /// reads as not said: one damaged cell must not stop the history from being read.
  private static func essential(_ row: Row) -> Bool? {
    guard let value = (try? RowMapping.optionalInteger(row, "essential")) ?? nil else {
      return nil
    }
    return value != 0
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["id"] = id.uuidString
    container["parent_id"] = parentId?.uuidString
    container["kind"] = kind.rawValue
    container["name"] = name
    container["sort"] = sort
    container["archived"] = archived
    container["quality"] = quality?.rawValue
    container["system_role"] = systemRole?.rawValue
    container["essential"] = essential
    container["tax_rate"] = RowMapping.string(tax?.rate)
    container["tax_npd"] = tax?.npd ?? false
    container["basket"] = basket?.rawValue
  }
}

extension Person: @retroactive FetchableRecord, @retroactive PersistableRecord {
  public static let databaseTableName = "people"

  public init(row: Row) throws {
    self.init(
      id: try RowMapping.uuid(row, "id"),
      name: row["name"] ?? "",
      relation: PersonRelation(rawValue: row["relation"] ?? "other") ?? .other,
      aliases: RowMapping.aliases(row, "aliases"),
      archived: try RowMapping.flag(row, "archived", fallback: false),
      birthday: Self.birthday(row),
      giftBudgetE4: (try? RowMapping.optionalAmount(row, "gift_budget_e4")) ?? nil)
  }

  /// A birthday whose month or day does not read is none: one damaged cell must not stop the
  /// people from being read.
  private static func birthday(_ row: Row) -> Birthday? {
    guard let month = (try? RowMapping.optionalInteger(row, "birthday_month")) ?? nil,
      let day = (try? RowMapping.optionalInteger(row, "birthday_day")) ?? nil
    else { return nil }
    let year = (try? RowMapping.optionalInteger(row, "birthday_year")) ?? nil
    return Birthday(month: month, day: day, year: year)
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["id"] = id.uuidString
    container["name"] = name
    container["relation"] = relation.rawValue
    container["aliases"] = RowMapping.join(aliases)
    container["archived"] = archived
    container["birthday_month"] = birthday?.month
    container["birthday_day"] = birthday?.day
    container["birthday_year"] = birthday?.year
    container["gift_budget_e4"] = giftBudgetE4?.raw
  }
}

extension Place: @retroactive FetchableRecord, @retroactive PersistableRecord {
  public static let databaseTableName = "places"

  public init(row: Row) throws {
    self.init(
      id: try RowMapping.uuid(row, "id"),
      name: row["name"] ?? "",
      aliases: RowMapping.aliases(row, "aliases"),
      archived: try RowMapping.flag(row, "archived", fallback: false))
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["id"] = id.uuidString
    container["name"] = name
    container["aliases"] = RowMapping.join(aliases)
    container["archived"] = archived
  }
}

/// An account. A main currency left NULL, empty or blank by an older build reads as none —
/// which counts as rubles (`PaymentMethod.mainCurrency`) — and is written back only when the
/// owner saves the account. `other_currencies` is the codes after the main one, joined by
/// commas.
extension PaymentMethod: @retroactive FetchableRecord, @retroactive PersistableRecord {
  public static let databaseTableName = "payment_methods"

  public init(row: Row) throws {
    self.init(
      id: try RowMapping.uuid(row, "id"),
      name: row["name"] ?? "",
      kind: PaymentMethodKind(rawValue: row["kind"] ?? "card") ?? .card,
      currency: RowMapping.currency(row, "currency"),
      aliases: RowMapping.aliases(row, "aliases"),
      isDefault: try RowMapping.flag(row, "is_default", fallback: false),
      archived: try RowMapping.flag(row, "archived", fallback: false),
      groupId: RowMapping.optionalUUID(row, "group_id"),
      sort: try RowMapping.optionalInteger(row, "sort") ?? 0,
      otherCurrencies: RowMapping.currencies(row, "other_currencies"),
      bankId: RowMapping.optionalUUID(row, "bank_id"),
      cashbackRounding: Self.cashbackRounding(row),
      cashbackPayout: Self.cashbackPayout(row),
      cashbackPointsAccountId: RowMapping.optionalUUID(row, "cashback_points_account_id"),
      interest: Self.interest(row),
      cushion: try RowMapping.flag(row, "cushion", fallback: false),
      credit: Self.credit(row),
      mainCardId: RowMapping.optionalUUID(row, "main_card_id"),
      accent: Self.accent(row))
  }

  /// A palette key (`01` to `12`); any other text — only a hand edit leaves one — reads as none.
  private static func accent(_ row: Row) -> String? {
    guard let text: String = row["accent"] else { return nil }
    return Self.accentKeys.contains(text) ? text : nil
  }

  /// The keys of the palette an account may be drawn in.
  static let accentKeys: Set<String> = Set((1...12).map { String(format: "%02d", $0) })

  /// The terms of a credit card. A limit or a grace period that does not read reads as no
  /// credit card, any other term that does not as not said: one damaged cell must not stop the
  /// history from being read.
  private static func credit(_ row: Row) -> CreditCardTerms? {
    func integer(_ column: String) -> Int? {
      (try? RowMapping.optionalInteger(row, column)) ?? nil
    }
    func amount(_ column: String) -> AmountE4? {
      (try? RowMapping.optionalAmount(row, column)) ?? nil
    }
    guard let limit = amount("credit_limit_e4"), limit.raw > 0 else { return nil }
    let grace: CreditGrace
    switch row["credit_grace"] as String? {
    case "statement":
      guard let day = integer("credit_statement_day"), let payDays = integer("credit_pay_days")
      else { return nil }
      grace = .statement(day: day, payDays: payDays)
    case "purchase":
      guard let days = integer("credit_grace_days") else { return nil }
      grace = .fromPurchase(days: days)
    default:
      return nil
    }
    return CreditCardTerms(
      limitE4: limit, grace: grace,
      purchaseRate: RowMapping.decimal(row, "credit_purchase_rate"),
      cashRate: RowMapping.decimal(row, "credit_cash_rate"),
      minPercent: RowMapping.decimal(row, "credit_min_percent"),
      minFloorE4: amount("credit_min_floor_e4"),
      cashFeePercent: RowMapping.decimal(row, "credit_cash_fee_percent"),
      cashFeeFixedE4: amount("credit_cash_fee_fixed_e4"),
      cashWithoutGrace: (try? RowMapping.flag(row, "credit_cash_no_grace", fallback: false))
        ?? false)
  }

  /// The interest the account earns. A rate or a period that does not read reads as none, a day
  /// or a date that does not as not said: one damaged cell must not stop the history from being
  /// read.
  private static func interest(_ row: Row) -> DepositTerms? {
    guard let rate = RowMapping.decimal(row, "interest_rate"),
      let period = (row["interest_period"] as String?).flatMap(InterestPeriod.init(rawValue:))
    else { return nil }
    let day = (try? RowMapping.optionalInteger(row, "interest_day")) ?? nil
    return DepositTerms(
      rate: rate, period: period, day: day.flatMap { (1...31).contains($0) ? $0 : nil },
      payoutAccountId: RowMapping.optionalUUID(row, "interest_account_id"),
      openedOn: RowMapping.day(row, "deposit_opened_on"),
      endsOn: RowMapping.day(row, "deposit_ends_on"))
  }

  /// How the account's bank rounds. A word the app never writes — only a hand edit leaves one —
  /// reads as the default: one damaged cell must not stop the history from being read.
  private static func cashbackRounding(_ row: Row) -> CashbackRounding {
    let precision = (row["cashback_precision"] as String?)
      .flatMap(CashbackRounding.Precision.init(rawValue:))
    let direction = (row["cashback_direction"] as String?)
      .flatMap(CashbackRounding.Direction.init(rawValue:))
    return CashbackRounding(precision: precision ?? .whole, direction: direction ?? .nearest)
  }

  /// When the bank pays. A word or a day that does not read, or a day that does not belong with
  /// the word, reads as «not said».
  private static func cashbackPayout(_ row: Row) -> CashbackPayout? {
    guard
      let timing = (row["cashback_payout"] as String?)
        .flatMap(CashbackPayout.Timing.init(rawValue:))
    else { return nil }
    let day = (try? RowMapping.optionalInteger(row, "cashback_payout_day")) ?? nil
    return CashbackPayout(timing: timing, storedDay: day)
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["id"] = id.uuidString
    container["name"] = name
    container["kind"] = kind.rawValue
    container["currency"] = currency?.code
    container["aliases"] = RowMapping.join(aliases)
    container["is_default"] = isDefault
    container["archived"] = archived
    container["group_id"] = groupId?.uuidString
    container["sort"] = sort
    container["other_currencies"] = otherCurrencies.map(\.code).joined(separator: ",")
    container["bank_id"] = bankId?.uuidString
    container["cashback_precision"] = cashbackRounding.precision.rawValue
    container["cashback_direction"] = cashbackRounding.direction.rawValue
    container["cashback_payout"] = cashbackPayout?.timing.rawValue
    container["cashback_payout_day"] = cashbackPayout?.day
    container["cashback_points_account_id"] = cashbackPointsAccountId?.uuidString
    container["interest_rate"] = RowMapping.string(interest?.rate)
    container["interest_period"] = interest?.period.rawValue
    container["interest_day"] = interest?.day
    container["interest_account_id"] = interest?.payoutAccountId?.uuidString
    container["deposit_opened_on"] = interest?.openedOn?.iso
    container["deposit_ends_on"] = interest?.endsOn?.iso
    container["cushion"] = cushion
    container["credit_limit_e4"] = credit?.limitE4.raw
    container["credit_grace"] = credit?.grace.storedKind
    if case .statement(let day, let payDays) = credit?.grace {
      container["credit_statement_day"] = day
      container["credit_pay_days"] = payDays
    } else {
      container["credit_statement_day"] = nil
      container["credit_pay_days"] = nil
    }
    if case .fromPurchase(let days) = credit?.grace {
      container["credit_grace_days"] = days
    } else {
      container["credit_grace_days"] = nil
    }
    container["credit_purchase_rate"] = RowMapping.string(credit?.purchaseRate)
    container["credit_cash_rate"] = RowMapping.string(credit?.cashRate)
    container["credit_min_percent"] = RowMapping.string(credit?.minPercent)
    container["credit_min_floor_e4"] = credit?.minFloorE4?.raw
    container["credit_cash_fee_percent"] = RowMapping.string(credit?.cashFeePercent)
    container["credit_cash_fee_fixed_e4"] = credit?.cashFeeFixedE4?.raw
    container["credit_cash_no_grace"] = credit?.cashWithoutGrace ?? false
    container["main_card_id"] = mainCardId?.uuidString
    container["accent"] = accent
  }
}

extension Event: @retroactive FetchableRecord, @retroactive PersistableRecord {
  public static let databaseTableName = "events"

  public init(row: Row) throws {
    self.init(
      id: try RowMapping.uuid(row, "id"),
      name: row["name"] ?? "",
      kind: EventKind(rawValue: row["kind"] ?? "other") ?? .other,
      startDate: RowMapping.day(row, "start_date") ?? DateOnly(year: 1970, month: 1, day: 1),
      endDate: RowMapping.day(row, "end_date") ?? DateOnly(year: 1970, month: 1, day: 1),
      budgetE4: try RowMapping.optionalAmount(row, "budget_e4"),
      recurringYearly: try RowMapping.flag(row, "recurring_yearly", fallback: false),
      seriesId: RowMapping.optionalUUID(row, "series_id"),
      archived: try RowMapping.flag(row, "archived", fallback: false),
      tripCurrency: RowMapping.currency(row, "trip_currency"),
      budgetCurrency: RowMapping.currency(row, "budget_currency"))
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["id"] = id.uuidString
    container["name"] = name
    container["kind"] = kind.rawValue
    container["trip_currency"] = tripCurrency?.code
    container["budget_currency"] = budgetCurrency?.code
    container["start_date"] = startDate.iso
    container["end_date"] = endDate.iso
    container["budget_e4"] = budgetE4?.raw
    container["recurring_yearly"] = recurringYearly
    container["series_id"] = seriesId?.uuidString
    container["archived"] = archived
  }
}

extension Template: @retroactive FetchableRecord, @retroactive PersistableRecord {
  public static let databaseTableName = "templates"

  public init(row: Row) throws {
    self.init(
      id: try RowMapping.uuid(row, "id"),
      text: row["text"] ?? "",
      categoryId: RowMapping.optionalUUID(row, "category_id"),
      amountE4: try RowMapping.optionalAmount(row, "amount_e4"),
      currency: (row["currency"] as String?).map(CurrencyCode.init),
      pinned: try RowMapping.flag(row, "pinned", fallback: false),
      useCount: try RowMapping.optionalInteger(row, "use_count") ?? 0,
      archived: try RowMapping.flag(row, "archived", fallback: false))
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["id"] = id.uuidString
    container["text"] = text
    container["category_id"] = categoryId?.uuidString
    container["amount_e4"] = amountE4?.raw
    container["currency"] = currency?.code
    container["pinned"] = pinned
    container["use_count"] = useCount
    container["archived"] = archived
  }
}

/// `plan_start_month` is 'YYYY-MM', or NULL for a plan counted from the first contribution.
extension Goal: @retroactive FetchableRecord, @retroactive PersistableRecord {
  public static let databaseTableName = "goals"

  public init(row: Row) throws {
    self.init(
      id: try RowMapping.uuid(row, "id"),
      name: row["name"] ?? "",
      targetE4: try RowMapping.amount(row, "target_e4"),
      targetDate: RowMapping.day(row, "target_date"),
      monthlyPlanE4: try RowMapping.optionalAmount(row, "monthly_plan_e4"),
      subcategoryId: RowMapping.optionalUUID(row, "subcategory_id"),
      archived: try RowMapping.flag(row, "archived", fallback: false),
      currency: CurrencyCode(row["currency"] ?? "RUB"),
      planStartMonth: RowMapping.month(row, "plan_start_month"),
      accountId: RowMapping.optionalUUID(row, "account_id"),
      transfersOnContribution: (try? RowMapping.flag(
        row, "transfer_on_contribution", fallback: false)) ?? false,
      sort: try RowMapping.optionalInteger(row, "sort") ?? 0)
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["id"] = id.uuidString
    container["name"] = name
    container["target_e4"] = targetE4.raw
    container["target_date"] = targetDate?.iso
    container["monthly_plan_e4"] = monthlyPlanE4?.raw
    container["subcategory_id"] = subcategoryId?.uuidString
    container["archived"] = archived
    container["currency"] = currency.code
    container["plan_start_month"] = planStartMonth?.iso
    container["account_id"] = accountId?.uuidString
    container["transfer_on_contribution"] = transfersOnContribution
    container["sort"] = sort
  }
}

extension Rate: @retroactive FetchableRecord, @retroactive PersistableRecord {
  public static let databaseTableName = "rates"

  public init(row: Row) throws {
    self.init(
      date: RowMapping.day(row, "date") ?? DateOnly(year: 1970, month: 1, day: 1),
      currency: CurrencyCode(row["currency"] ?? "RUB"),
      rubPerUnit: RowMapping.decimal(row, "rub_per_unit") ?? 0,
      nominal: try RowMapping.optionalInteger(row, "nominal") ?? 1,
      source: RateSource(rawValue: row["source"] ?? "cbr") ?? .cbr,
      fetchedAt: RowMapping.readableInstant(row, "fetched_at"))
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["date"] = date.iso
    container["currency"] = currency.code
    container["rub_per_unit"] = RowMapping.string(rubPerUnit)
    container["nominal"] = nominal
    container["source"] = source.rawValue
    container["fetched_at"] = StoredInstant.databaseValue(fetchedAt)
  }
}
