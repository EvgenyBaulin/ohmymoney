import CoreKit
import Foundation
import GRDB

// The rows `Schema/0009_credit_and_allocation.sql` adds — the sums of dues typed from a bank's
// app, the costs of a loan, the rules of the allocation of income and the currencies outside the
// Bank of Russia list —, mapped by hand like every other record (`RowMapping`).

extension DebtInstalmentStep: @retroactive FetchableRecord, @retroactive PersistableRecord {
  public static let databaseTableName = "debt_instalments"

  public init(row: Row) throws {
    self.init(
      id: try RowMapping.uuid(row, "id"),
      debtId: try RowMapping.uuid(row, "debt_id"),
      fromIndex: try RowMapping.optionalInteger(row, "from_index") ?? 0,
      amountE4: try RowMapping.amount(row, "amount_e4"))
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["id"] = id.uuidString
    container["debt_id"] = debtId.uuidString
    container["from_index"] = fromIndex
    container["amount_e4"] = amountE4.raw
  }
}

/// A kind or a period this build does not know reads as `other` and `once`: one odd cell must
/// not stop the history from being read.
extension DebtCost: @retroactive FetchableRecord, @retroactive PersistableRecord {
  public static let databaseTableName = "debt_costs"

  public init(row: Row) throws {
    self.init(
      id: try RowMapping.uuid(row, "id"),
      debtId: try RowMapping.uuid(row, "debt_id"),
      kind: (row["kind"] as String?).flatMap(DebtCostKind.init(rawValue:)) ?? .other,
      name: row["name"],
      amountE4: try RowMapping.amount(row, "amount_e4"),
      every: (row["every"] as String?).flatMap(DebtCostEvery.init(rawValue:)) ?? .once,
      day: RowMapping.day(row, "day") ?? DateOnly(year: 1970, month: 1, day: 1),
      inLoan: try RowMapping.flag(row, "in_loan", fallback: false),
      transactionId: RowMapping.optionalUUID(row, "transaction_id"),
      sort: try RowMapping.optionalInteger(row, "sort") ?? 0)
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["id"] = id.uuidString
    container["debt_id"] = debtId.uuidString
    container["kind"] = kind.rawValue
    container["name"] = name
    container["amount_e4"] = amountE4.raw
    container["every"] = every.rawValue
    container["day"] = day.iso
    container["in_loan"] = inLoan
    container["transaction_id"] = transactionId?.uuidString
    container["sort"] = sort
  }
}

/// A rule whose target or amount does not read — only a hand edit leaves one — reads as a rule
/// on the cushion of no amount, switched off: one damaged row must not stop the history from
/// being read, nor suggest money the owner never set.
extension AllocationRule: @retroactive FetchableRecord, @retroactive PersistableRecord {
  public static let databaseTableName = "allocation_rules"

  public init(row: Row) throws {
    let goal = RowMapping.optionalUUID(row, "goal_id")
    let account = RowMapping.optionalUUID(row, "payment_method_id")
    var readable = true
    let target: AllocationTarget
    switch (row["target"] as String?, goal, account) {
    case ("goal", .some(let goal), _): target = .goal(goal)
    case ("account", _, .some(let account)): target = .account(account)
    case ("cushion", _, let account): target = .cushion(account)
    default:
      target = .cushion(nil)
      readable = false
    }
    let amount: AllocationAmount
    switch (row["mode"] as String?, RowMapping.decimal(row, "percent")) {
    case ("percent", .some(let percent)):
      amount = .percent(percent)
    case ("fixed", _):
      if let value = (try? RowMapping.optionalAmount(row, "amount_e4")) ?? nil,
        let currency = RowMapping.currency(row, "currency")
      {
        amount = .fixed(value, currency)
      } else {
        amount = .percent(0)
        readable = false
      }
    default:
      amount = .percent(0)
      readable = false
    }
    let active = try RowMapping.flag(row, "active", fallback: true)
    self.init(
      id: try RowMapping.uuid(row, "id"),
      target: target, amount: amount,
      sort: try RowMapping.optionalInteger(row, "sort") ?? 0,
      active: readable && active)
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["id"] = id.uuidString
    container["target"] = target.storedKind
    switch target {
    case .goal(let goal):
      container["goal_id"] = goal.uuidString
      container["payment_method_id"] = nil
    case .account(let account):
      container["goal_id"] = nil
      container["payment_method_id"] = account.uuidString
    case .cushion(let account):
      container["goal_id"] = nil
      container["payment_method_id"] = account?.uuidString
    }
    switch amount {
    case .percent(let percent):
      container["mode"] = "percent"
      container["percent"] = RowMapping.string(percent)
      container["amount_e4"] = nil
      container["currency"] = nil
    case .fixed(let value, let currency):
      container["mode"] = "fixed"
      container["percent"] = nil
      container["amount_e4"] = value.raw
      container["currency"] = currency.code
    }
    container["sort"] = sort
    container["active"] = active
  }
}

/// Keyed by its code, as the rates are.
extension CustomCurrency: @retroactive FetchableRecord, @retroactive PersistableRecord {
  public static let databaseTableName = "custom_currencies"

  public init(row: Row) throws {
    self.init(
      code: CurrencyCode(row["code"] ?? ""),
      name: row["name"] ?? "",
      symbol: row["symbol"],
      fractionDigits: ((try? RowMapping.optionalInteger(row, "fraction_digits")) ?? nil)
        .flatMap { CustomCurrency.fractionDigitsRange.contains($0) ? $0 : nil } ?? 2,
      archived: try RowMapping.flag(row, "archived", fallback: false),
      sort: try RowMapping.optionalInteger(row, "sort") ?? 0)
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["code"] = code.code
    container["name"] = name
    container["symbol"] = symbol
    container["fraction_digits"] = fractionDigits
    container["archived"] = archived
    container["sort"] = sort
  }
}
