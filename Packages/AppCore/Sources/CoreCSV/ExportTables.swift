import CoreKit
import Foundation

// Column names drop the `_e4` suffix the SQL schema uses: the files carry amounts as
// decimal strings with a dot, not stored units of 1/10000, and a header that said `amount_e4`
// would promise something the value is not. The way back is plain: the CSV value times
// 10 000, rounded, is what the `*_e4` column of the database holds.

/// One CSV file: its file name and its column order. This is the single source of truth
/// for both the Export feature and the `data/csv/` folder of the transfer archive, so
/// column order must never change once a table ships — old exports and old archives must
/// keep meaning the same thing. Column names are the field names of the SQL schema
/// (`Schema/0001_initial.sql`) in snake_case, in the order the schema declares them; a column
/// a later migration adds goes last, and a table it adds goes at the end of the list.
public struct ExportTable: Hashable, Sendable {
  public let fileName: String
  public let columns: [String]

  public init(fileName: String, columns: [String]) {
    self.fileName = fileName
    self.columns = columns
  }
}

/// The 44 files of Export, always in the same order.
public enum ExportTables {
  /// `account_currency` and `account_amount` came with `Schema/0004_accounts.sql`: what the
  /// account moved when it does not hold the operation's currency. `card_id`,
  /// `cashback_currency` and `cashback` came with `Schema/0005_cards.sql`: the card of the
  /// account that paid, and the cashback the owner typed for the operation, in the currency
  /// that moved on the account.
  /// `time_zone` came with `Schema/0011_travel.sql`: the zone the operation was recorded in, empty
  /// for Moscow. `one_off` came with `Schema/0013_spending_rules.sql`: `true` when the owner marked
  /// the operation as a one-off. `source`, `bank_status`, `posted_on` and `dedup_key` came with
  /// `Schema/0014_import_year_questions_subscriptions.sql`: where a statement line came from
  /// (`statement`, `screenshot`, `receipt`; empty — typed by hand), what the bank said of it
  /// (`posted`, `pending`, `declined`, `unknown`; empty — posted), the day the bank posted it and
  /// the hash that finds the same line again.
  public static let transactions = ExportTable(
    fileName: "transactions.csv",
    columns: [
      "id", "kind", "occurred_at", "currency", "amount", "amount_expr", "rate",
      "rate_date", "rate_source", "rate_provisional", "amount_rub", "note", "place_id",
      "payment_method_id", "period_month", "debt_id", "credit_debt_id", "import_batch_id",
      "external_id", "created_at", "updated_at", "deleted_at", "account_currency",
      "account_amount", "card_id", "cashback_currency", "cashback", "time_zone", "one_off",
      "source", "bank_status", "posted_on", "dedup_key",
    ])

  /// `refund_of_part_id` came with `Schema/0004_accounts.sql`: the purchase part a refund
  /// takes money back from.
  public static let transactionParts = ExportTable(
    fileName: "transaction_parts.csv",
    columns: [
      "id", "transaction_id", "category_id", "category_source", "quality", "quality_source",
      "amount", "amount_rub", "for_whom", "for_person_id", "reimbursable",
      "debtor_person_id", "reimbursement_status", "event_id", "goal_id", "note",
      "refund_of_part_id",
    ])

  public static let reimbursementLinks = ExportTable(
    fileName: "reimbursement_links.csv",
    columns: ["id", "reimbursement_tx_id", "part_id", "amount"])

  public static let people = ExportTable(
    fileName: "people.csv",
    columns: ["id", "name", "relation", "aliases", "archived"])

  /// The accounts. `group_id`, `sort` and `other_currencies` came with
  /// `Schema/0004_accounts.sql`; `other_currencies` holds the codes after the main one,
  /// joined by commas as the database keeps them (`USD,RUB,KZT`). `bank_id` came with
  /// `Schema/0006_banks.sql`: the bank the account belongs to, empty for none. The interest
  /// columns came with `Schema/0007_debts_and_deposits.sql`: the yearly rate in percent, how
  /// often and on what day it is paid, the account it is paid to, and the term of a deposit.
  /// `cushion` came with `Schema/0008_capital.sql`: the money of the account is the safety
  /// cushion. The terms of a credit card and `main_card_id` came with
  /// `Schema/0009_credit_and_allocation.sql`: the limit, the grace period (`statement` — the
  /// statement day and the days to pay it, `purchase` — the days from a purchase), the rates, the
  /// minimum payment, the fee for cash and transfers, and the card a purchase is made with.
  public static let paymentMethods = ExportTable(
    fileName: "payment_methods.csv",
    columns: [
      "id", "name", "kind", "currency", "aliases", "is_default", "archived", "group_id", "sort",
      "other_currencies", "bank_id", "cashback_precision", "cashback_direction",
      "cashback_payout", "cashback_payout_day", "cashback_points_account_id", "interest_rate",
      "interest_period", "interest_day", "interest_account_id", "deposit_opened_on",
      "deposit_ends_on", "cushion", "credit_limit", "credit_grace", "credit_statement_day",
      "credit_pay_days", "credit_grace_days", "credit_purchase_rate", "credit_cash_rate",
      "credit_min_percent", "credit_min_floor", "credit_cash_fee_percent", "credit_cash_fee_fixed",
      "credit_cash_no_grace", "main_card_id", "accent",
    ])

  public static let places = ExportTable(
    fileName: "places.csv",
    columns: ["id", "name", "aliases", "archived"])

  /// `trip_currency` and `budget_currency` came with `Schema/0011_travel.sql`: the one currency of
  /// a trip and the currency the budget is kept in.
  public static let events = ExportTable(
    fileName: "events.csv",
    columns: [
      "id", "name", "kind", "start_date", "end_date", "budget", "recurring_yearly",
      "series_id", "archived", "trip_currency", "budget_currency",
    ])

  /// `essential` came with `Schema/0008_capital.sql`: `true` or `false` as the owner marked
  /// it, empty — a subcategory follows its parent, a category is not essential. `tax_rate` and
  /// `tax_npd` came with `Schema/0009_credit_and_allocation.sql`: the tax an income in the
  /// category owes, in percent, and whether it is the tax on professional income. `basket` came
  /// with `Schema/0013_spending_rules.sql`: `needs`, `wants` or `savings`, empty when not said.
  public static let categories = ExportTable(
    fileName: "categories.csv",
    columns: [
      "id", "parent_id", "kind", "name", "sort", "archived", "quality", "system_role",
      "essential", "tax_rate", "tax_npd", "basket",
    ])

  /// `archived` came with `Schema/0004_accounts.sql`.
  public static let templates = ExportTable(
    fileName: "templates.csv",
    columns: [
      "id", "text", "category_id", "amount", "currency", "pinned", "use_count", "archived",
    ])

  /// Columns match `Schema/0001_initial.sql`; `card_id` and `event_id` came with
  /// `Schema/0005_cards.sql`: the card that pays, and the event whose budget the payment is a
  /// part of.
  public static let scheduledPayments = ExportTable(
    fileName: "scheduled_payments.csv",
    columns: [
      "id", "name", "kind", "amount", "currency", "category_id", "payment_method_id",
      "for_whom", "for_person_id", "reimbursable", "debtor_person_id",
      "reimbursement_amount", "reimbursement_currency", "freq", "interval", "day",
      "month", "next_date", "end_date", "trial_end", "cancel_url", "remind_days_before",
      "active", "card_id", "event_id",
    ])

  /// Columns match `Schema/0001_initial.sql`.
  public static let subscriptionPrices = ExportTable(
    fileName: "subscription_prices.csv",
    columns: ["id", "payment_id", "date", "amount"])

  /// Columns match `Schema/0001_initial.sql`. `expected_income_links` is not one of the
  /// files: the links travel in the archive's database. `payment_method_id` came with
  /// `Schema/0005_cards.sql`: the account the money is to come to.
  public static let expectedIncome = ExportTable(
    fileName: "expected_income.csv",
    columns: [
      "id", "name", "category_id", "person_id", "kind", "total", "currency", "due_date",
      "freq", "day", "parts_expected", "closed", "payment_method_id", "payout_kind", "asset_id",
    ])

  /// Columns match `Schema/0001_initial.sql`; `start_month` came with
  /// `Schema/0002_planning.sql` and goes last, so every older column keeps its place.
  public static let budgets = ExportTable(
    fileName: "budgets.csv",
    columns: ["id", "scope", "category_id", "for_whom", "amount", "rollover", "start_month"])

  /// `currency` came with `Schema/0004_accounts.sql`: the target, the plan and the progress
  /// are in it. `plan_start_month` came with `Schema/0005_cards.sql`: the month the monthly
  /// plan counts from. `account_id` and `transfer_on_contribution` came with
  /// `Schema/0009_credit_and_allocation.sql`: the account the money of the goal is kept on.
  /// `sort` came with `Schema/0010_scenarios.sql`: the place the owner dragged the goal to.
  public static let goals = ExportTable(
    fileName: "goals.csv",
    columns: [
      "id", "name", "target", "target_date", "monthly_plan", "subcategory_id",
      "archived", "currency", "plan_start_month", "account_id", "transfer_on_contribution",
      "sort",
    ])

  /// `deleted_at` came with `Schema/0005_cards.sql`: the instant the debt was deleted. The
  /// terms of a loan came with `Schema/0007_debts_and_deposits.sql`: whether the bank charges
  /// interest day by day, the grace period (the first day of the main schedule, `interest` or
  /// `fixed`, and the fixed sum) and the months the main payment is worked out over. The rest
  /// came with `Schema/0009_credit_and_allocation.sql`: dues every few days, the parts and the
  /// markup of an instalment plan, the full cost of credit from the contract, the rules of
  /// early repayment and the one planned, the payoff ladder, a pledge and its day, and whether
  /// the owner has seen these terms.
  public static let debts = ExportTable(
    fileName: "debts.csv",
    columns: [
      "id", "direction", "type", "name", "person_id", "currency", "interest_rate",
      "monthly_payment", "payment_day", "remind_days_before", "payments_are_expenses",
      "origin", "note", "closed", "loans_subcategory_id", "deleted_at", "accrues_interest",
      "main_from", "grace_kind", "grace_payment", "repay_months", "step_days", "first_due_on",
      "parts", "markup", "psk", "prepay_any_day", "prepay_notice_days", "planned_prepay_on",
      "planned_prepay", "in_ladder", "pledge", "return_by", "terms_reviewed",
    ])

  /// `payment_method_id`, `occurred_at`, `account_currency` and `account_amount` came with
  /// `Schema/0004_accounts.sql`: the account money borrowed or lent through the journal alone
  /// went into or out of, when, and what moved on it. `closes_term` came with
  /// `Schema/0006_banks.sql`: the payment that says no more money comes toward its due.
  /// `tranche` came with `Schema/0007_debts_and_deposits.sql`: a part of the loan drawn later.
  /// `prepay` came with `Schema/0009_credit_and_allocation.sql`: an early repayment, `term` or
  /// `payment` as the owner chose.
  public static let debtEntries = ExportTable(
    fileName: "debt_entries.csv",
    columns: [
      "id", "debt_id", "group_name", "date", "description", "full_amount", "share",
      "amount", "kind", "transaction_id", "note", "payment_method_id", "occurred_at",
      "account_currency", "account_amount", "closes_term", "tranche", "prepay",
    ])

  /// Columns match `Schema/0001_initial.sql`; `reconciled_at` and `breakdown` came with
  /// `Schema/0002_planning.sql` and go last, so every older column keeps its place. The
  /// breakdown is the JSON text of the database column (`ReconciliationBreakdown`). `kind`
  /// came with `Schema/0004_accounts.sql`, `origin` with `Schema/0005_cards.sql`: where the
  /// starting balances of an opening came from.
  public static let reconciliations = ExportTable(
    fileName: "reconciliations.csv",
    columns: [
      "id", "date", "actual_total_rub", "expected_total_rub", "difference",
      "transaction_id", "reconciled_at", "breakdown", "kind", "origin",
    ])

  /// No `id` column: the schema's primary key is `(date, currency, source)`. `rub_per_unit`
  /// keeps the schema's name but carries the rate as published — rubles per `nominal` units
  /// (56.2349 for 100 JPY); per one unit it is `rub_per_unit / nominal`.
  public static let rates = ExportTable(
    fileName: "rates.csv",
    columns: ["date", "currency", "rub_per_unit", "nominal", "source", "fetched_at"])

  /// Columns match `Schema/0004_accounts.sql`.
  public static let accountGroups = ExportTable(
    fileName: "account_groups.csv",
    columns: ["id", "name", "in_summary", "sort", "archived"])

  /// Columns match `Schema/0004_accounts.sql`; `external_id` came with
  /// `Schema/0009_credit_and_allocation.sql`: what wrote the transfer, when the app did.
  /// `arrived_at` came with `Schema/0014_import_year_questions_subscriptions.sql`: when the money
  /// arrived, empty when it arrived when it was sent.
  public static let transfers = ExportTable(
    fileName: "transfers.csv",
    columns: [
      "id", "occurred_at", "from_payment_method_id", "from_currency", "from_amount",
      "to_payment_method_id", "to_currency", "to_amount", "note", "created_at", "updated_at",
      "external_id", "arrived_at",
    ])

  /// Columns match `Schema/0004_accounts.sql`. Amounts are in the row's currency; an empty
  /// `expected` marks the first count of the account and currency. `records_difference` came
  /// with `Schema/0005_cards.sql`: `true` — the difference is one live operation, `false` —
  /// only the numbers follow it, empty — a starting point, or no sheet.
  public static let reconciliationBalances = ExportTable(
    fileName: "reconciliation_balances.csv",
    columns: [
      "id", "reconciliation_id", "payment_method_id", "currency", "actual", "expected",
      "difference", "transaction_id", "records_difference",
    ])

  /// Columns match `Schema/0005_cards.sql`: the cards of an account; `aliases` one per line.
  /// `fx_fee`, `atm_fee_percent`, `atm_fee_fixed` and `atm_fee_fixed_currency` came with
  /// `Schema/0011_travel.sql`: what the card costs abroad, the percents as decimal strings with a
  /// dot (`1.5` is 1.5 %), empty when not typed. `last4` and `details` came with
  /// `Schema/0013_spending_rules.sql`: the four digits a bank text names the card by, and free text.
  public static let cards = ExportTable(
    fileName: "cards.csv",
    columns: [
      "id", "payment_method_id", "name", "aliases", "sort", "archived", "fx_fee",
      "atm_fee_percent", "atm_fee_fixed", "atm_fee_fixed_currency", "last4", "details",
      "expires_on",
    ])

  /// Columns match `Schema/0005_cards.sql`. `percent` is the percent as a decimal string with
  /// a dot (`1.5` is 1.5 %); an empty `category_id` is «everything else», an empty `month`
  /// «always», an empty `card_id` the account's own rule.
  public static let cashbackRules = ExportTable(
    fileName: "cashback_rules.csv",
    columns: ["id", "payment_method_id", "card_id", "category_id", "month", "percent"])

  /// Columns match `Schema/0006_banks.sql`: the banks the accounts belong to.
  public static let banks = ExportTable(
    fileName: "banks.csv",
    columns: ["id", "name", "sort", "archived"])

  /// Columns match `Schema/0008_capital.sql`: the things valued by hand. `disposed_on` is the
  /// day it was sold or written off, empty while it is kept.
  public static let assets = ExportTable(
    fileName: "assets.csv",
    columns: ["id", "name", "kind", "currency", "note", "disposed_on", "sort"])

  /// Columns match `Schema/0008_capital.sql`: what an asset was worth on a day, in its
  /// currency.
  public static let assetValuations = ExportTable(
    fileName: "asset_valuations.csv",
    columns: ["id", "asset_id", "day", "value", "note"])

  /// Columns match `Schema/0009_credit_and_allocation.sql`: what a due asks for, typed from a
  /// bank's app, from due `from_index` (0 the first) on.
  public static let debtInstalments = ExportTable(
    fileName: "debt_instalments.csv",
    columns: ["id", "debt_id", "from_index", "amount"])

  /// Columns match `Schema/0009_credit_and_allocation.sql`: what else a loan costs — `fee`,
  /// `insurance` or `other`, paid `once`, `monthly` or `yearly` from `day`.
  public static let debtCosts = ExportTable(
    fileName: "debt_costs.csv",
    columns: [
      "id", "debt_id", "kind", "name", "amount", "every", "day", "in_loan", "transaction_id",
      "sort",
    ])

  /// Columns match `Schema/0009_credit_and_allocation.sql`: how the owner usually allocates an
  /// income — `percent` of it or a `fixed` sum in `currency`, into a goal, to an account or to
  /// the cushion.
  public static let allocationRules = ExportTable(
    fileName: "allocation_rules.csv",
    columns: [
      "id", "target", "goal_id", "payment_method_id", "mode", "percent", "amount", "currency",
      "sort", "active",
    ])

  /// No `id` column: the schema's primary key is `code`, as for the rates. Columns match
  /// `Schema/0009_credit_and_allocation.sql`.
  public static let customCurrencies = ExportTable(
    fileName: "custom_currencies.csv",
    columns: [
      "code", "name", "symbol", "fraction_digits", "archived", "sort", "rate_source", "coin_id",
    ])

  /// The whole `settings` table, by key: the settings that belong to the data — the default
  /// currency, self-employment, the allocation, the debts — as the database keeps them.
  public static let settings = ExportTable(
    fileName: "settings.csv",
    columns: ["key", "value"])

  /// The tags, the links to parts, the rules and the notes of days came with
  /// `Schema/0013_spending_rules.sql`; they go last, after `settings`, so the order of every
  /// older file stays. `part_tags` has the pair itself as `id`. `conditions` and `actions` of a
  /// rule are the JSON of the database, as it is (`RuleStorage`).
  public static let tags = ExportTable(
    fileName: "tags.csv", columns: ["id", "name", "archived", "created_at"])

  public static let partTags = ExportTable(
    fileName: "part_tags.csv", columns: ["id", "part_id", "tag_id"])

  public static let rules = ExportTable(
    fileName: "rules.csv",
    columns: [
      "id", "name", "position", "enabled", "origin", "conditions", "actions", "created_at",
      "updated_at",
    ])

  public static let dayNotes = ExportTable(
    fileName: "day_notes.csv", columns: ["id", "day", "text", "created_at", "updated_at"])

  /// The limits that differ in one month, the articles of the budget of an event, the owner's
  /// templates of events and the extras of subscriptions came with
  /// `Schema/0014_import_year_questions_subscriptions.sql`, and go last. Amounts are written
  /// without `_e4` as decimal strings, flags as `true` and `false`. `lines` of a template and
  /// `payment_ids` of a group of kept subscriptions are the JSON of the database, as it is. The
  /// saved filters and reports, the owner's own statement profiles, the numbers of one's own
  /// contracts and the list of imports are not exported: the archive carries the database whole.
  public static let budgetMonthExceptions = ExportTable(
    fileName: "budget_month_exceptions.csv", columns: ["id", "budget_id", "month", "amount"])

  public static let eventBudgetItems = ExportTable(
    fileName: "event_budget_items.csv", columns: ["id", "event_id", "title", "planned", "sort"])

  public static let eventTemplates = ExportTable(
    fileName: "event_templates.csv",
    columns: ["id", "name", "event_kind", "total", "lines", "created_at", "updated_at"])

  public static let subscriptionTerms = ExportTable(
    fileName: "subscription_terms.csv",
    columns: [
      "payment_id", "yearly_plan", "monthly_plan", "floating", "tolerance_percent",
      "service_type", "needed", "yearly_reminder_off", "owner_uses",
    ])

  public static let subscriptionUsage = ExportTable(
    fileName: "subscription_usage.csv", columns: ["id", "payment_id", "day"])

  public static let subscriptionUsers = ExportTable(
    fileName: "subscription_users.csv", columns: ["id", "payment_id", "person_id"])

  public static let subscriptionKeepGroups = ExportTable(
    fileName: "subscription_keep_groups.csv", columns: ["id", "type", "payment_ids"])

  /// The conditions of bank products and the deposits the owner typed in came with
  /// `Schema/0015_bank_conditions.sql`, and go last. Amounts are written without `_e4` as decimal
  /// strings, an empty amount is a condition not stated; `rate_percent` is a decimal string with a
  /// dot. The new columns of older files (`payment_methods.accent`, `cards.expires_on`,
  /// `custom_currencies.rate_source` and `coin_id`, `expected_income.payout_kind` and `asset_id`)
  /// go last in their files, empty for none.
  public static let bankConditions = ExportTable(
    fileName: "bank_conditions.csv",
    columns: [
      "id", "payment_method_id", "card_id", "currency", "free_cash", "free_sbp",
      "free_interbank", "service_free_spend", "service_free_balance", "min_balance", "note",
    ])

  public static let depositOffers = ExportTable(
    fileName: "deposit_offers.csv",
    columns: [
      "id", "bank_name", "rate_percent", "term_months", "min_amount", "max_amount",
      "new_client_only", "needs_subscription", "topup", "rate_on", "note", "archived",
    ])

  /// All 44 tables, in the fixed order of the export: the 18 of the first schema, then the
  /// three the accounts brought, then the two of the cards, then the banks, then the assets
  /// and their valuations, then the instalments and costs of the debts, the allocation rules,
  /// the custom currencies and the settings, then the tags, their links, the rules and the notes
  /// of days, then the month limits, event articles and templates and the subscription extras, then
  /// the conditions of bank products and the deposits of the owner.
  public static let all: [ExportTable] = [
    transactions, transactionParts, reimbursementLinks, people, paymentMethods, places,
    events, categories, templates, scheduledPayments, subscriptionPrices, expectedIncome,
    budgets, goals, debts, debtEntries, reconciliations, rates, accountGroups, transfers,
    reconciliationBalances, cards, cashbackRules, banks, assets, assetValuations,
    debtInstalments, debtCosts, allocationRules, customCurrencies, settings, tags, partTags, rules,
    dayNotes, budgetMonthExceptions, eventBudgetItems, eventTemplates, subscriptionTerms,
    subscriptionUsage, subscriptionUsers, subscriptionKeepGroups, bankConditions, depositOffers,
  ]
}

// MARK: - Row serialization

/// Turns one `CoreKit` record into a CSV row matching the column order declared above.
extension ExportTables {
  public static func row(_ transaction: Transaction) -> [String] {
    [
      transaction.id.uuidString,
      transaction.kind.rawValue,
      CSVValue.string(instant: transaction.occurredAt),
      transaction.currency.code,
      CSVValue.string(amount: transaction.amountE4),
      CSVValue.string(transaction.amountExpr),
      CSVValue.string(decimal: transaction.rate),
      CSVValue.string(day: transaction.rateDate),
      CSVValue.string(transaction.rateSource?.rawValue),
      CSVValue.string(bool: transaction.rateProvisional),
      CSVValue.string(amount: transaction.amountRubE4),
      CSVValue.string(transaction.note),
      CSVValue.string(transaction.placeId),
      CSVValue.string(transaction.paymentMethodId),
      CSVValue.string(month: transaction.periodMonth),
      CSVValue.string(transaction.debtId),
      CSVValue.string(transaction.creditDebtId),
      CSVValue.string(transaction.importBatchId),
      CSVValue.string(transaction.externalId),
      CSVValue.string(instant: transaction.createdAt),
      CSVValue.string(instant: transaction.updatedAt),
      CSVValue.string(instant: transaction.deletedAt),
      CSVValue.string(transaction.accountCurrency?.code),
      CSVValue.string(amount: transaction.accountAmountE4),
      CSVValue.string(transaction.cardId),
      CSVValue.string(transaction.cashback?.currency.code),
      CSVValue.string(amount: transaction.cashback?.amount),
      CSVValue.string(transaction.timeZoneId),
      CSVValue.string(bool: transaction.isOneOff),
      CSVValue.string(transaction.source),
      CSVValue.string(transaction.bankStatus),
      CSVValue.string(transaction.postedOn?.iso),
      CSVValue.string(transaction.dedupKey),
    ]
  }

  public static func row(_ part: TransactionPart) -> [String] {
    [
      part.id.uuidString,
      part.transactionId.uuidString,
      CSVValue.string(part.categoryId),
      part.categorySource.rawValue,
      CSVValue.string(part.quality?.rawValue),
      CSVValue.string(part.qualitySource?.rawValue),
      CSVValue.string(amount: part.amountE4),
      CSVValue.string(amount: part.amountRubE4),
      part.forWhom.rawValue,
      CSVValue.string(part.forPersonId),
      CSVValue.string(bool: part.reimbursable),
      CSVValue.string(part.debtorPersonId),
      CSVValue.string(part.reimbursementStatus?.rawValue),
      CSVValue.string(part.eventId),
      CSVValue.string(part.goalId),
      CSVValue.string(part.note),
      CSVValue.string(part.refundOfPartId),
    ]
  }

  public static func row(_ link: ReimbursementLink) -> [String] {
    [
      link.id.uuidString,
      link.reimbursementTxId.uuidString,
      link.partId.uuidString,
      CSVValue.string(amount: link.amountE4),
    ]
  }

  public static func row(_ person: Person) -> [String] {
    [
      person.id.uuidString,
      person.name,
      person.relation.rawValue,
      CSVValue.string(joining: person.aliases),
      CSVValue.string(bool: person.archived),
    ]
  }

  public static func row(_ method: PaymentMethod) -> [String] {
    [
      method.id.uuidString,
      method.name,
      method.kind.rawValue,
      CSVValue.string(method.currency?.code),
      CSVValue.string(joining: method.aliases),
      CSVValue.string(bool: method.isDefault),
      CSVValue.string(bool: method.archived),
      CSVValue.string(method.groupId),
      String(method.sort),
      method.otherCurrencies.map(\.code).joined(separator: ","),
      CSVValue.string(method.bankId),
      method.cashbackRounding.precision.rawValue,
      method.cashbackRounding.direction.rawValue,
      method.cashbackPayout?.timing.rawValue ?? "",
      method.cashbackPayout?.day.map(String.init) ?? "",
      CSVValue.string(method.cashbackPointsAccountId),
      CSVValue.string(decimal: method.interest?.rate),
      CSVValue.string(method.interest?.period.rawValue),
      CSVValue.string(method.interest?.day),
      CSVValue.string(method.interest?.payoutAccountId),
      CSVValue.string(day: method.interest?.openedOn),
      CSVValue.string(day: method.interest?.endsOn),
      CSVValue.string(bool: method.cushion),
      CSVValue.string(amount: method.credit?.limitE4),
      CSVValue.string(method.credit?.grace.storedKind),
      CSVValue.string(statementDay(method.credit?.grace)),
      CSVValue.string(payDays(method.credit?.grace)),
      CSVValue.string(graceDays(method.credit?.grace)),
      CSVValue.string(decimal: method.credit?.purchaseRate),
      CSVValue.string(decimal: method.credit?.cashRate),
      CSVValue.string(decimal: method.credit?.minPercent),
      CSVValue.string(amount: method.credit?.minFloorE4),
      CSVValue.string(decimal: method.credit?.cashFeePercent),
      CSVValue.string(amount: method.credit?.cashFeeFixedE4),
      CSVValue.string(bool: method.credit?.cashWithoutGrace ?? false),
      CSVValue.string(method.mainCardId),
      CSVValue.string(method.accent),
    ]
  }

  private static func statementDay(_ grace: CreditGrace?) -> Int? {
    if case .statement(let day, _) = grace { return day }
    return nil
  }

  private static func payDays(_ grace: CreditGrace?) -> Int? {
    if case .statement(_, let payDays) = grace { return payDays }
    return nil
  }

  private static func graceDays(_ grace: CreditGrace?) -> Int? {
    if case .fromPurchase(let days) = grace { return days }
    return nil
  }

  public static func row(_ place: Place) -> [String] {
    [
      place.id.uuidString,
      place.name,
      CSVValue.string(joining: place.aliases),
      CSVValue.string(bool: place.archived),
    ]
  }

  public static func row(_ event: Event) -> [String] {
    [
      event.id.uuidString,
      event.name,
      event.kind.rawValue,
      CSVValue.string(day: event.startDate),
      CSVValue.string(day: event.endDate),
      CSVValue.string(amount: event.budgetE4),
      CSVValue.string(bool: event.recurringYearly),
      CSVValue.string(event.seriesId),
      CSVValue.string(bool: event.archived),
      CSVValue.string(event.tripCurrency?.code),
      CSVValue.string(event.budgetCurrency?.code),
    ]
  }

  public static func row(_ category: CoreKit.Category) -> [String] {
    [
      category.id.uuidString,
      CSVValue.string(category.parentId),
      category.kind.rawValue,
      category.name,
      String(category.sort),
      CSVValue.string(bool: category.archived),
      CSVValue.string(category.quality?.rawValue),
      CSVValue.string(category.systemRole?.rawValue),
      CSVValue.string(bool: category.essential),
      CSVValue.string(decimal: category.tax?.rate),
      CSVValue.string(bool: category.tax?.npd ?? false),
      CSVValue.string(category.basket?.rawValue),
    ]
  }

  public static func row(_ template: Template) -> [String] {
    [
      template.id.uuidString,
      template.text,
      CSVValue.string(template.categoryId),
      CSVValue.string(amount: template.amountE4),
      CSVValue.string(template.currency?.code),
      CSVValue.string(bool: template.pinned),
      String(template.useCount),
      CSVValue.string(bool: template.archived),
    ]
  }

  public static func row(_ goal: Goal) -> [String] {
    [
      goal.id.uuidString,
      goal.name,
      CSVValue.string(amount: goal.targetE4),
      CSVValue.string(day: goal.targetDate),
      CSVValue.string(amount: goal.monthlyPlanE4),
      CSVValue.string(goal.subcategoryId),
      CSVValue.string(bool: goal.archived),
      goal.currency.code,
      CSVValue.string(month: goal.planStartMonth),
      CSVValue.string(goal.accountId),
      CSVValue.string(bool: goal.transfersOnContribution),
      String(goal.sort),
    ]
  }

  public static func row(_ debt: Debt) -> [String] {
    [
      debt.id.uuidString,
      debt.direction.rawValue,
      debt.type.rawValue,
      debt.name,
      CSVValue.string(debt.personId),
      debt.currency.code,
      CSVValue.string(decimal: debt.interestRate),
      CSVValue.string(amount: debt.monthlyPaymentE4),
      CSVValue.string(debt.paymentDay),
      CSVValue.string(debt.remindDaysBefore),
      CSVValue.string(bool: debt.paymentsAreExpenses),
      debt.origin.rawValue,
      CSVValue.string(debt.note),
      CSVValue.string(bool: debt.closed),
      CSVValue.string(debt.loansSubcategoryId),
      CSVValue.string(instant: debt.deletedAt),
      CSVValue.string(bool: debt.accruesInterest),
      CSVValue.string(day: debt.grace?.mainFrom),
      CSVValue.string(debt.grace?.payment.storedKind),
      CSVValue.string(amount: debt.grace?.payment.fixedAmount),
      CSVValue.string(debt.repayMonths),
      CSVValue.string(debt.steps?.everyDays),
      CSVValue.string(day: debt.steps?.firstDue),
      CSVValue.string(debt.parts),
      CSVValue.string(amount: debt.markupE4),
      CSVValue.string(decimal: debt.psk),
      CSVValue.string(bool: debt.prepayAnyDay),
      CSVValue.string(debt.prepayNoticeDays),
      CSVValue.string(day: debt.plannedPrepay?.day),
      CSVValue.string(amount: debt.plannedPrepay?.amountE4),
      CSVValue.string(bool: debt.inLadder),
      CSVValue.string(bool: debt.pledge),
      CSVValue.string(day: debt.returnBy),
      CSVValue.string(bool: debt.termsReviewed),
    ]
  }

  public static func row(_ entry: DebtEntry) -> [String] {
    [
      entry.id.uuidString,
      entry.debtId.uuidString,
      CSVValue.string(entry.groupName),
      CSVValue.string(day: entry.date),
      CSVValue.string(entry.description),
      CSVValue.string(amount: entry.fullAmountE4),
      CSVValue.string(decimal: entry.share),
      CSVValue.string(amount: entry.amountE4),
      entry.kind.rawValue,
      CSVValue.string(entry.transactionId),
      CSVValue.string(entry.note),
      CSVValue.string(entry.paymentMethodId),
      CSVValue.string(instant: entry.occurredAt),
      CSVValue.string(entry.accountCurrency?.code),
      CSVValue.string(amount: entry.accountAmountE4),
      CSVValue.string(bool: entry.closesTerm),
      CSVValue.string(bool: entry.tranche),
      CSVValue.string(entry.prepay?.rawValue),
    ]
  }

  public static func row(_ payment: ScheduledPayment) -> [String] {
    [
      payment.id.uuidString,
      payment.name,
      payment.kind.rawValue,
      CSVValue.string(amount: payment.amountE4),
      payment.currency.code,
      CSVValue.string(payment.categoryId),
      CSVValue.string(payment.paymentMethodId),
      payment.forWhom.rawValue,
      CSVValue.string(payment.forPersonId),
      CSVValue.string(bool: payment.reimbursable),
      CSVValue.string(payment.debtorPersonId),
      CSVValue.string(amount: payment.reimbursementAmountE4),
      CSVValue.string(payment.reimbursementCurrency?.code),
      payment.freq.rawValue,
      String(payment.interval),
      CSVValue.string(payment.day),
      CSVValue.string(payment.month),
      CSVValue.string(day: payment.nextDate),
      CSVValue.string(day: payment.endDate),
      CSVValue.string(day: payment.trialEnd),
      CSVValue.string(payment.cancelURL),
      CSVValue.string(payment.remindDaysBefore),
      CSVValue.string(bool: payment.active),
      CSVValue.string(payment.cardId),
      CSVValue.string(payment.eventId),
    ]
  }

  public static func row(_ price: SubscriptionPrice) -> [String] {
    [
      price.id.uuidString,
      price.paymentId.uuidString,
      CSVValue.string(day: price.date),
      CSVValue.string(amount: price.amountE4),
    ]
  }

  public static func row(_ income: ExpectedIncome) -> [String] {
    [
      income.id.uuidString,
      income.name,
      CSVValue.string(income.categoryId),
      CSVValue.string(income.personId),
      income.kind.rawValue,
      CSVValue.string(amount: income.totalE4),
      income.currency.code,
      CSVValue.string(day: income.dueDate),
      CSVValue.string(income.freq?.rawValue),
      CSVValue.string(income.day),
      String(income.partsExpected),
      CSVValue.string(bool: income.closed),
      CSVValue.string(income.paymentMethodId),
      CSVValue.string(income.payoutKind?.rawValue),
      CSVValue.string(income.assetId),
    ]
  }

  public static func row(_ budget: Budget) -> [String] {
    [
      budget.id.uuidString,
      budget.scope.rawValue,
      CSVValue.string(budget.categoryId),
      CSVValue.string(budget.forWhom?.rawValue),
      CSVValue.string(amount: budget.amountE4),
      CSVValue.string(bool: budget.rollover),
      CSVValue.string(month: budget.startMonth),
    ]
  }

  public static func row(_ reconciliation: Reconciliation) -> [String] {
    [
      reconciliation.id.uuidString,
      CSVValue.string(day: reconciliation.date),
      CSVValue.string(amount: reconciliation.actualTotalRubE4),
      CSVValue.string(amount: reconciliation.expectedTotalRubE4),
      CSVValue.string(amount: reconciliation.differenceE4),
      CSVValue.string(reconciliation.transactionId),
      CSVValue.string(instant: reconciliation.reconciledAt),
      CSVValue.string(ReconciliationBreakdown.json(reconciliation.breakdown)),
      reconciliation.kind.rawValue,
      CSVValue.string(reconciliation.origin?.rawValue),
    ]
  }

  public static func row(_ rate: Rate) -> [String] {
    [
      CSVValue.string(day: rate.date),
      rate.currency.code,
      CSVValue.string(decimal: rate.rubPerUnit),
      String(rate.nominal),
      rate.source.rawValue,
      CSVValue.string(instant: rate.fetchedAt),
    ]
  }

  public static func row(_ group: AccountGroup) -> [String] {
    [
      group.id.uuidString,
      group.name,
      CSVValue.string(bool: group.inSummary),
      String(group.sort),
      CSVValue.string(bool: group.archived),
    ]
  }

  public static func row(_ transfer: Transfer) -> [String] {
    [
      transfer.id.uuidString,
      CSVValue.string(instant: transfer.occurredAt),
      transfer.fromAccountId.uuidString,
      transfer.fromCurrency.code,
      CSVValue.string(amount: transfer.fromAmountE4),
      transfer.toAccountId.uuidString,
      transfer.toCurrency.code,
      CSVValue.string(amount: transfer.toAmountE4),
      CSVValue.string(transfer.note),
      CSVValue.string(instant: transfer.createdAt),
      CSVValue.string(instant: transfer.updatedAt),
      CSVValue.string(transfer.externalId),
      CSVValue.string(instant: transfer.arrivedAt),
    ]
  }

  public static func row(_ balance: ReconciledBalance) -> [String] {
    [
      balance.id.uuidString,
      balance.reconciliationId.uuidString,
      balance.accountId.uuidString,
      balance.currency.code,
      CSVValue.string(amount: balance.actualE4),
      CSVValue.string(amount: balance.expectedE4),
      CSVValue.string(amount: balance.differenceE4),
      CSVValue.string(balance.transactionId),
      CSVValue.string(bool: balance.recordsDifference),
    ]
  }

  public static func row(_ card: PaymentCard) -> [String] {
    [
      card.id.uuidString,
      card.accountId.uuidString,
      card.name,
      CSVValue.string(joining: card.aliases),
      String(card.sort),
      CSVValue.string(bool: card.archived),
      CSVValue.string(decimal: card.foreign.conversionFee?.decimal),
      CSVValue.string(decimal: card.foreign.atmFeePercent?.decimal),
      CSVValue.string(amount: card.foreign.atmFeeFixed?.amount),
      CSVValue.string(card.foreign.atmFeeFixed?.currency.code),
      CSVValue.string(card.last4),
      CSVValue.string(card.details),
      CSVValue.string(month: card.expiresOn),
    ]
  }

  public static func row(_ tag: Tag) -> [String] {
    [
      tag.id.uuidString, tag.name, CSVValue.string(bool: tag.archived),
      CSVValue.string(instant: tag.createdAt),
    ]
  }

  public static func row(_ link: PartTag) -> [String] {
    [
      link.partId.uuidString + ":" + link.tagId.uuidString, link.partId.uuidString,
      link.tagId.uuidString,
    ]
  }

  public static func row(_ rule: Rule) -> [String] {
    [
      rule.id.uuidString, rule.name, String(rule.position), CSVValue.string(bool: rule.enabled),
      rule.origin.rawValue, RuleStorage.json(rule.conditions), RuleStorage.json(rule.actions),
      CSVValue.string(instant: rule.createdAt), CSVValue.string(instant: rule.updatedAt),
    ]
  }

  public static func row(_ note: DayNote) -> [String] {
    [
      note.id.uuidString, note.day.iso, note.text, CSVValue.string(instant: note.createdAt),
      CSVValue.string(instant: note.updatedAt),
    ]
  }

  public static func row(_ rule: CashbackRule) -> [String] {
    [
      rule.id.uuidString,
      rule.accountId.uuidString,
      CSVValue.string(rule.cardId),
      CSVValue.string(rule.categoryId),
      CSVValue.string(month: rule.month),
      CSVValue.string(decimal: rule.percent.decimal),
    ]
  }

  public static func row(_ bank: Bank) -> [String] {
    [
      bank.id.uuidString,
      bank.name,
      String(bank.sort),
      CSVValue.string(bool: bank.archived),
    ]
  }

  public static func row(_ asset: Asset) -> [String] {
    [
      asset.id.uuidString,
      asset.name,
      asset.kind.rawValue,
      asset.currency.code,
      CSVValue.string(asset.note),
      CSVValue.string(day: asset.disposedOn),
      String(asset.sort),
    ]
  }

  public static func row(_ valuation: AssetValuation) -> [String] {
    [
      valuation.id.uuidString,
      valuation.assetId.uuidString,
      CSVValue.string(day: valuation.day),
      CSVValue.string(amount: valuation.valueE4),
      CSVValue.string(valuation.note),
    ]
  }

  public static func row(_ step: DebtInstalmentStep) -> [String] {
    [
      step.id.uuidString,
      step.debtId.uuidString,
      String(step.fromIndex),
      CSVValue.string(amount: step.amountE4),
    ]
  }

  public static func row(_ cost: DebtCost) -> [String] {
    [
      cost.id.uuidString,
      cost.debtId.uuidString,
      cost.kind.rawValue,
      CSVValue.string(cost.name),
      CSVValue.string(amount: cost.amountE4),
      cost.every.rawValue,
      CSVValue.string(day: cost.day),
      CSVValue.string(bool: cost.inLoan),
      CSVValue.string(cost.transactionId),
      String(cost.sort),
    ]
  }

  public static func row(_ rule: AllocationRule) -> [String] {
    var goal: UUID?
    var account: UUID?
    switch rule.target {
    case .goal(let id): goal = id
    case .account(let id): account = id
    case .cushion(let id): account = id
    }
    var percent: Decimal?
    var amount: AmountE4?
    var currency: CurrencyCode?
    switch rule.amount {
    case .percent(let value): percent = value
    case .fixed(let value, let code):
      amount = value
      currency = code
    }
    return [
      rule.id.uuidString,
      rule.target.storedKind,
      CSVValue.string(goal),
      CSVValue.string(account),
      percent == nil ? "fixed" : "percent",
      CSVValue.string(decimal: percent),
      CSVValue.string(amount: amount),
      CSVValue.string(currency?.code),
      String(rule.sort),
      CSVValue.string(bool: rule.active),
    ]
  }

  public static func row(_ currency: CustomCurrency) -> [String] {
    [
      currency.code.code,
      currency.name,
      CSVValue.string(currency.symbol),
      String(currency.fractionDigits),
      CSVValue.string(bool: currency.archived),
      String(currency.sort),
      CSVValue.string(currency.rateSource?.rawValue),
      CSVValue.string(currency.coinId),
    ]
  }

  public static func row(_ conditions: BankConditions) -> [String] {
    [
      conditions.id.uuidString,
      conditions.accountId.uuidString,
      CSVValue.string(conditions.cardId),
      conditions.currency.code,
      CSVValue.string(amount: conditions.freeCashE4),
      CSVValue.string(amount: conditions.freeSbpE4),
      CSVValue.string(amount: conditions.freeInterbankE4),
      CSVValue.string(amount: conditions.serviceFreeSpendE4),
      CSVValue.string(amount: conditions.serviceFreeBalanceE4),
      CSVValue.string(amount: conditions.minBalanceE4),
      CSVValue.string(conditions.note),
    ]
  }

  public static func row(_ offer: DepositOffer) -> [String] {
    [
      offer.id.uuidString,
      offer.bankName,
      CSVValue.string(decimal: offer.ratePercent),
      CSVValue.string(offer.termMonths),
      CSVValue.string(amount: offer.minAmountE4),
      CSVValue.string(amount: offer.maxAmountE4),
      CSVValue.string(bool: offer.newClientOnly),
      CSVValue.string(bool: offer.needsSubscription),
      CSVValue.string(bool: offer.topup),
      CSVValue.string(day: offer.rateOn),
      CSVValue.string(offer.note),
      CSVValue.string(bool: offer.archived),
    ]
  }

  /// One row of the `settings` table, its value as the database keeps it.
  public static func settingRow(key: String, value: String) -> [String] {
    [key, value]
  }
}

// MARK: - Breakdown of a reconciliation

/// A reconciliation's breakdown by currency as one JSON text — the way the
/// `reconciliations.breakdown` column keeps it (`Schema/0002_planning.sql`) and the way
/// `reconciliations.csv` carries it, so the database, the export and the archive spell it
/// alike and the Windows port needs one reader:
///
///     [{"amount_e4":1000000,"currency":"USD","rub_e4":81430000,"rub_per_unit":"81.43"}]
///
/// Keys are sorted, so the same breakdown is always the same text. The amounts are integers
/// in 1/10000, as their names say — the one place a file carries stored units, and the key
/// tells so. The rate is a decimal string with a dot, never a JSON number, which a reader
/// would take for a floating-point value; it is `null` for rubles. No breakdown is no text.
public enum ReconciliationBreakdown {
  public static func json(_ amounts: [ReconciliationAmount]) -> String? {
    guard !amounts.isEmpty else { return nil }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(amounts.map(Line.init)) else { return nil }
    return String(decoding: data, as: UTF8.self)
  }

  /// The breakdown a column or a cell holds; empty for no text and for text that is not a
  /// breakdown. A line whose rate does not read as a number keeps no rate.
  public static func amounts(fromJSON text: String?) -> [ReconciliationAmount] {
    guard let text, !text.isEmpty,
      let lines = try? JSONDecoder().decode([Line].self, from: Data(text.utf8))
    else { return [] }
    return lines.map(\.amount)
  }

  private static let posix = Locale(identifier: "en_US_POSIX")

  private struct Line: Codable {
    var currency: String
    var amountE4: Int64
    var rubPerUnit: String?
    var rubE4: Int64

    enum CodingKeys: String, CodingKey {
      case currency
      case amountE4 = "amount_e4"
      case rubPerUnit = "rub_per_unit"
      case rubE4 = "rub_e4"
    }

    init(_ amount: ReconciliationAmount) {
      currency = amount.currency.code
      amountE4 = amount.amountE4.raw
      rubPerUnit = amount.rubPerUnit.map { CSVValue.string(decimal: $0) }
      rubE4 = amount.rubE4.raw
    }

    init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      currency = try container.decode(String.self, forKey: .currency)
      amountE4 = try container.decode(Int64.self, forKey: .amountE4)
      rubPerUnit = try container.decodeIfPresent(String.self, forKey: .rubPerUnit)
      rubE4 = try container.decode(Int64.self, forKey: .rubE4)
    }

    /// Every line has all four keys: an absent rate is written as `null`, not left out.
    func encode(to encoder: any Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(currency, forKey: .currency)
      try container.encode(amountE4, forKey: .amountE4)
      try container.encode(rubPerUnit, forKey: .rubPerUnit)
      try container.encode(rubE4, forKey: .rubE4)
    }

    var amount: ReconciliationAmount {
      ReconciliationAmount(
        currency: CurrencyCode(currency),
        amountE4: AmountE4(raw: amountE4),
        rubPerUnit: rubPerUnit.flatMap {
          Decimal(string: $0, locale: ReconciliationBreakdown.posix)
        },
        rubE4: AmountE4(raw: rubE4))
    }
  }
}
