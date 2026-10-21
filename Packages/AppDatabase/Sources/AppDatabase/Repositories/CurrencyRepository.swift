import AppCore
import CoreKit
import Foundation
import GRDB

/// One row of `rates` by its primary key: the day, the currency and where the rate came from.
public struct RateKey: Hashable, Sendable {
  public var date: DateOnly
  public var currency: CurrencyCode
  public var source: RateSource

  public init(date: DateOnly, currency: CurrencyCode, source: RateSource) {
    self.date = date
    self.currency = currency
    self.source = source
  }

  public init(_ rate: Rate) {
    self.init(date: rate.date, currency: rate.currency, source: rate.source)
  }

  /// The key as GRDB looks a row of `rates` up by it.
  var databaseKey: [String: (any DatabaseValueConvertible)?] {
    ["date": date.iso, "currency": currency.code, "source": source.rawValue]
  }
}

/// Why a write of custom currencies was refused; nothing is written then.
public enum CustomCurrencyWriteError: Error, Equatable, Sendable {
  /// The currency itself cannot be written so (`CurrencyCatalog.refusal(for:existing:)`).
  case refused(CustomCurrencyRefusal)
  /// No custom currency of that code is there.
  case notThere(CurrencyCode)
  /// A rate is only typed for a custom currency: the rates of the others are the bank's.
  case notCustom(CurrencyCode)
  /// A rate is more than zero.
  case rateNotPositive
  /// Operations, accounts, plans or settings are in the currency: it can only go to the archive.
  case inUse(CurrencyCode)
  /// The default currency, which everything new is in, does not go to the archive.
  case isDefault(CurrencyCode)
}

/// The currencies outside the Bank of Russia list and their rates typed by hand.
///
/// Reads are direct. Every write is a `PlanningChange` this repository works out and the caller
/// applies — through the store, so it is one step of ⌘Z: a new currency with its first rate, an
/// edit, the archive and back, a rate of a day and its removal, a deletion with all its rates.
/// Each builder reads what is there now and refuses with `CustomCurrencyWriteError` before
/// anything is written.
///
/// A rate of a custom currency lives in `rates` with the source `manual`, one per day: the rate
/// of a day is the last one typed for it or before it, and a day before the first has none
/// (`RateTable`). The bank is never asked for such a code.
public struct CurrencyRepository: Sendable {
  private let writer: any DatabaseWriter

  public init(writer: any DatabaseWriter) {
    self.writer = writer
  }

  // MARK: Reading

  /// Archived ones included, in the owner's order.
  public func customCurrencies() throws -> [CustomCurrency] {
    try writer.read { db in try SettingsRepository.customCurrencies(db) }
  }

  /// Names, symbols and digits of the custom currencies, for the formatter and the entry line.
  public func catalog() throws -> CurrencyCatalog {
    CurrencyCatalog(custom: try customCurrencies())
  }

  /// The rates typed for the currency, latest day first.
  public func rates(of code: CurrencyCode) throws -> [Rate] {
    try writer.read { db in
      try Rate
        .filter(Column("currency") == code.code && Column("source") == RateSource.manual.rawValue)
        .order(Column("date").desc)
        .fetchAll(db)
    }
  }

  /// The rate of the currency on `day`: the last one typed for that day or before it; `nil`
  /// before the first.
  public func rate(of code: CurrencyCode, on day: DateOnly) throws -> Rate? {
    RateTable(rates: try rates(of: code)).rate(for: code, on: day)
  }

  /// Whether anything but the currency itself and its rates names it: an operation, an account,
  /// a goal, a debt, a plan, a template, a rule, a count, a transfer, an asset — any column of
  /// any table that holds a currency — or the default currency.
  public func isUsed(_ code: CurrencyCode) throws -> Bool {
    try writer.read { db in try Self.isUsed(code, db: db) }
  }

  static func isUsed(_ code: CurrencyCode, db: Database) throws -> Bool {
    if try SettingsRepository.defaultCurrency(db) == code { return true }
    for (table, column, isList) in try currencyColumns(db) {
      let condition =
        isList
        ? "',' || \(column) || ',' LIKE '%,' || ? || ',%'"
        : "\(column) = ?"
      let found = try Bool.fetchOne(
        db, sql: "SELECT EXISTS (SELECT 1 FROM \(table) WHERE \(condition))",
        arguments: [code.code])
      if found == true { return true }
    }
    return false
  }

  /// Every column of the schema that holds a currency — `currency`, `…_currency`, and the
  /// comma list `other_currencies` —, read from the schema itself so a table added later is not
  /// forgotten. The rates, the custom currencies and the list of enabled ones are left out:
  /// they are the currency, not a use of it.
  private static func currencyColumns(_ db: Database) throws -> [(String, String, Bool)] {
    let skipped: Set<String> = ["rates", "custom_currencies", "currencies", "grdb_migrations"]
    let tables = try String.fetchAll(
      db,
      sql: """
        SELECT name FROM sqlite_master
        WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name
        """)
    var found: [(String, String, Bool)] = []
    for table in tables where !skipped.contains(table) {
      for column in try db.columns(in: table).map(\.name) {
        if column == "other_currencies" {
          found.append((table, column, true))
        } else if column == "currency" || column.hasSuffix("_currency") {
          found.append((table, column, false))
        }
      }
    }
    return found
  }

  // MARK: Changes

  /// Writes a new custom currency, or the one of the same code anew — its name, symbol, digits;
  /// its code never changes. A new one goes last in the owner's order. `firstRate` — rubles for
  /// one unit from a day on — is written in the same step: the first rate of a new currency, or
  /// one more of an edited one.
  public func saving(
    _ currency: CustomCurrency, firstRate: (day: DateOnly, rubPerUnit: Decimal)? = nil,
    at instant: Date = Date()
  ) throws -> PlanningChange {
    try writer.read { db in
      let existing = try SettingsRepository.customCurrencies(db)
      var row = currency
      row.name = currency.name.trimmingCharacters(in: .whitespacesAndNewlines)
      let symbol = currency.symbol?.trimmingCharacters(in: .whitespacesAndNewlines)
      row.symbol = symbol?.isEmpty == false ? symbol : nil
      if let refusal = CurrencyCatalog.refusal(for: row, existing: existing) {
        throw CustomCurrencyWriteError.refused(refusal)
      }
      let isNew = !existing.contains { $0.code == row.code }
      if isNew { row.sort = (existing.map(\.sort).max() ?? -1) + 1 }
      var rows = PlanningRows(customCurrencies: [row])
      if let firstRate {
        guard firstRate.rubPerUnit > 0 else { throw CustomCurrencyWriteError.rateNotPositive }
        rows.rates = [
          Self.typedRate(row.code, firstRate.rubPerUnit, on: firstRate.day, at: instant)
        ]
      }
      return PlanningChange(upsert: rows, at: instant)
    }
  }

  /// Sends the currency to the archive — it is no longer offered for anything new, and every
  /// amount in it stays and reads as before — or brings it back. The default currency does not
  /// go.
  public func archiving(
    _ code: CurrencyCode, archived: Bool = true, at instant: Date = Date()
  ) throws -> PlanningChange {
    try writer.read { db in
      guard var row = try CustomCurrency.fetchOne(db, key: code.code) else {
        throw CustomCurrencyWriteError.notThere(code)
      }
      if archived, try SettingsRepository.defaultCurrency(db) == code {
        throw CustomCurrencyWriteError.isDefault(code)
      }
      row.archived = archived
      return PlanningChange(upsert: PlanningRows(customCurrencies: [row]), at: instant)
    }
  }

  /// Deletes a currency nothing names (`isUsed`), with every rate typed for it; one in use goes
  /// to the archive instead.
  public func deleting(_ code: CurrencyCode, at instant: Date = Date()) throws -> PlanningChange {
    try writer.read { db in
      guard try CustomCurrency.fetchOne(db, key: code.code) != nil else {
        throw CustomCurrencyWriteError.notThere(code)
      }
      if try Self.isUsed(code, db: db) { throw CustomCurrencyWriteError.inUse(code) }
      let rates = try Rate.filter(Column("currency") == code.code).fetchAll(db)
      return PlanningChange(
        delete: PlanningRowIDs(customCurrencies: [code], rates: rates.map(RateKey.init)),
        at: instant)
    }
  }

  /// The rate of a day, `rubPerUnit` rubles for one unit, in place of the one typed for that day
  /// before. It holds from that day until the next one typed. An operation already written keeps
  /// the rate it was written with, as with any rate.
  public func savingRate(
    _ code: CurrencyCode, on day: DateOnly, rubPerUnit: Decimal, at instant: Date = Date()
  ) throws -> PlanningChange {
    try writer.read { db in
      guard try CustomCurrency.fetchOne(db, key: code.code) != nil else {
        throw ISOCurrencies.contains(code)
          ? CustomCurrencyWriteError.notCustom(code) : CustomCurrencyWriteError.notThere(code)
      }
      guard rubPerUnit > 0 else { throw CustomCurrencyWriteError.rateNotPositive }
      return PlanningChange(
        upsert: PlanningRows(rates: [Self.typedRate(code, rubPerUnit, on: day, at: instant)]),
        at: instant)
    }
  }

  /// Takes away the rate typed for the day; the day before it then holds on. A day with no
  /// rate typed changes nothing.
  public func removingRate(
    _ code: CurrencyCode, on day: DateOnly, at instant: Date = Date()
  ) throws -> PlanningChange {
    try writer.read { db in
      guard try CustomCurrency.fetchOne(db, key: code.code) != nil else {
        throw CustomCurrencyWriteError.notThere(code)
      }
      return PlanningChange(
        delete: PlanningRowIDs(
          rates: [RateKey(date: day, currency: code, source: .manual)]),
        at: instant)
    }
  }

  /// The custom currencies in this order; ones left out keep their place after them.
  public func reordering(
    _ codes: [CurrencyCode], at instant: Date = Date()
  ) throws -> PlanningChange {
    try writer.read { db in
      let existing = try SettingsRepository.customCurrencies(db)
      let named = codes.compactMap { code in existing.first { $0.code == code } }
      let rest = existing.filter { row in !named.contains { $0.code == row.code } }
      var rows: [CustomCurrency] = []
      for (index, var row) in (named + rest).enumerated() where row.sort != index {
        row.sort = index
        rows.append(row)
      }
      return PlanningChange(upsert: PlanningRows(customCurrencies: rows), at: instant)
    }
  }

  /// A rate typed by hand: one unit, the source `manual`, stamped with the instant it was typed.
  private static func typedRate(
    _ code: CurrencyCode, _ rubPerUnit: Decimal, on day: DateOnly, at instant: Date
  ) -> Rate {
    Rate(
      date: day, currency: code, rubPerUnit: rubPerUnit, nominal: 1, source: .manual,
      fetchedAt: instant)
  }
}
