import CoreKit
import Foundation
import GRDB

/// Key-value settings that belong to the data, not to the machine: language, enabled
/// currencies, thresholds. Window positions and folder bookmarks stay out of here.
public struct SettingsRepository: Sendable {
  private let writer: any DatabaseWriter

  public init(writer: any DatabaseWriter) {
    self.writer = writer
  }

  public func string(_ key: String) throws -> String? {
    try writer.read { db in
      try String.fetchOne(db, sql: "SELECT value FROM settings WHERE key = ?", arguments: [key])
    }
  }

  public func set(_ key: String, to value: String) throws {
    try writer.write { db in try Self.set(key, to: value, in: db) }
  }

  /// The same inside a write already open — a history batch sets what it points at with it.
  static func set(_ key: String, to value: String, in db: Database) throws {
    try db.execute(
      sql: """
        INSERT INTO settings (key, value) VALUES (?, ?)
        ON CONFLICT(key) DO UPDATE SET value = excluded.value
        """,
      arguments: [key, value])
  }

  /// The values these keys have; a key that is not there is left out.
  static func values(of keys: [String], db: Database) throws -> [String: String] {
    guard !keys.isEmpty else { return [:] }
    let marks = databaseQuestionMarks(count: keys.count)
    let rows = try Row.fetchAll(
      db, sql: "SELECT key, value FROM settings WHERE key IN (\(marks))",
      arguments: StatementArguments(keys))
    var values: [String: String] = [:]
    for row in rows {
      values[row["key"]] = row["value"]
    }
    return values
  }

  public func enabledCurrencies() throws -> [CurrencyCode] {
    try writer.read { db in try Self.enabledCurrencies(db) }
  }

  static func enabledCurrencies(_ db: Database) throws -> [CurrencyCode] {
    let codes = try String.fetchAll(
      db, sql: "SELECT code FROM currencies WHERE enabled = 1 ORDER BY sort, code")
    return codes.isEmpty ? CurrencyCode.defaultEnabled : codes.map(CurrencyCode.init)
  }

  /// Enables these currencies, as many as the owner likes, in their order.
  ///
  /// Refuses with `SettingsWriteError.currencyInUse` to switch off a currency that is on and
  /// is still needed: the default currency, which everything new is in, or one a live account
  /// holds. Nothing is written then.
  public func setEnabledCurrencies(_ currencies: [CurrencyCode]) throws {
    let limited = currencies
    _ = try writer.write { db in
      let kept = Set(limited)
      let dropped = try Self.enabledCurrencies(db).filter { !kept.contains($0) }
      if !dropped.isEmpty {
        let needed = try Self.neededCurrencies(db)
        if let first = dropped.first(where: needed.contains) {
          throw SettingsWriteError.currencyInUse(first)
        }
      }
      try Self.enable(limited, db: db)
    }
  }

  /// The currency everything new is in (`currencies.default`); rubles until one is chosen.
  public func defaultCurrency() throws -> CurrencyCode {
    try writer.read { db in try Self.defaultCurrency(db) }
  }

  static func defaultCurrency(_ db: Database) throws -> CurrencyCode {
    AccountSettings(
      storedValues: try values(of: [AccountSettings.defaultCurrencyKey], db: db)
    ).defaultCurrency
  }

  /// Makes `currency` the default and switches it on, last among the enabled ones when it was
  /// off.
  public func setDefaultCurrency(_ currency: CurrencyCode) throws {
    try writer.write { db in try Self.setDefaultCurrency(currency, db: db) }
  }

  static func setDefaultCurrency(_ currency: CurrencyCode, db: Database) throws {
    try enableAlso([currency], db: db)
    try set(AccountSettings.defaultCurrencyKey, to: currency.code, in: db)
  }

  /// Switches these currencies on, after the ones that are on, in their order.
  static func enableAlso(_ currencies: [CurrencyCode], db: Database) throws {
    let enabled = try enabledCurrencies(db)
    var all = enabled
    for currency in currencies where !all.contains(currency) { all.append(currency) }
    guard all != enabled else { return }
    try enable(all, db: db)
  }

  /// The currencies outside the Bank of Russia list, archived ones included, in the owner's
  /// order.
  public func customCurrencies() throws -> [CustomCurrency] {
    try writer.read { db in try Self.customCurrencies(db) }
  }

  static func customCurrencies(_ db: Database) throws -> [CustomCurrency] {
    try CustomCurrency.order(Column("sort"), Column("code")).fetchAll(db)
  }

  /// The default currency and every currency a live account holds.
  static func neededCurrencies(_ db: Database) throws -> Set<CurrencyCode> {
    var needed: Set<CurrencyCode> = [try defaultCurrency(db)]
    for account in try PaymentMethod.filter(Column("archived") == false).fetchAll(db) {
      needed.formUnion(account.currencies)
    }
    return needed
  }

  private static func enable(_ currencies: [CurrencyCode], db: Database) throws {
    try db.execute(sql: "UPDATE currencies SET enabled = 0")
    for (index, currency) in currencies.enumerated() {
      try db.execute(
        sql: """
          INSERT INTO currencies (code, enabled, sort) VALUES (?, 1, ?)
          ON CONFLICT(code) DO UPDATE SET enabled = 1, sort = excluded.sort
          """,
        arguments: [currency.code, index])
    }
  }
}

/// Why a change of the currencies was not written.
public enum SettingsWriteError: Error, Equatable, Sendable {
  /// The currency is the default one or a live account holds it, so it stays on.
  case currencyInUse(CurrencyCode)
  /// No longer thrown: any number of currencies may be on. Kept for the callers that still
  /// name it.
  case tooManyCurrencies
}
