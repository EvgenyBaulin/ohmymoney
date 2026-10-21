import AppCore
import CoreKit
import Foundation
import GRDB

/// Stores Bank of Russia rates. Manual rates and rates that came with an import are
/// never overwritten automatically.
public struct RateRepository: Sendable {
  private let writer: any DatabaseWriter

  public init(writer: any DatabaseWriter) {
    self.writer = writer
  }

  public func save(_ rates: [Rate]) throws {
    try writer.write { db in
      for rate in rates {
        try rate.save(db)
      }
    }
  }

  public func allRates() throws -> [Rate] {
    try writer.read { db in try Rate.order(Column("date").desc).fetchAll(db) }
  }

  /// The cache as the rules of `RateTable` read it: every stored rate, and the days the bank
  /// has said it published nothing on.
  public func table() throws -> RateTable {
    RateTable(rates: try allRates(), unpublishedDays: try unpublishedDays())
  }

  /// Days the bank was asked about and answered with an earlier publication, each with the
  /// date of that publication. Kept so a weekend or a holiday is asked about once, not again
  /// on every launch, and so an operation on it can be settled with the rate before it.
  public func unpublishedDays() throws -> [DateOnly: DateOnly] {
    let stored = try writer.read { db in try Self.storedUnpublishedDays(db) }
    return Self.decodeUnpublishedDays(stored)
  }

  /// Records the bank's answer that nothing was published on `day` after `publication`.
  public func noteUnpublished(_ day: DateOnly, holding publication: DateOnly) throws {
    guard publication < day else { return }
    try writer.write { db in
      var days = Self.decodeUnpublishedDays(try Self.storedUnpublishedDays(db))
      guard days[day] != publication else { return }
      days[day] = publication
      try db.execute(
        sql: """
          INSERT INTO settings (key, value) VALUES (?, ?)
          ON CONFLICT(key) DO UPDATE SET value = excluded.value
          """,
        arguments: [Self.unpublishedDaysKey, Self.encodeUnpublishedDays(days)])
    }
  }

  /// The `settings` row that holds them: `2026-09-20>2026-09-19,2026-09-21>2026-09-19`,
  /// ordered by day. The schema has no column for it, and the settings travel with the
  /// database and its backups, which is where the rate cache lives too.
  static let unpublishedDaysKey = "rates.unpublishedDays"

  private static func storedUnpublishedDays(_ db: Database) throws -> String? {
    try String.fetchOne(
      db, sql: "SELECT value FROM settings WHERE key = ?", arguments: [unpublishedDaysKey])
  }

  static func encodeUnpublishedDays(_ days: [DateOnly: DateOnly]) -> String {
    days.sorted { $0.key < $1.key }
      .map { "\($0.key.iso)>\($0.value.iso)" }
      .joined(separator: ",")
  }

  /// A malformed pair is dropped: the day is then simply asked about again.
  static func decodeUnpublishedDays(_ stored: String?) -> [DateOnly: DateOnly] {
    var days: [DateOnly: DateOnly] = [:]
    for pair in (stored ?? "").split(separator: ",") {
      let sides = pair.split(separator: ">")
      guard sides.count == 2, let day = DateOnly(iso: String(sides[0])),
        let publication = DateOnly(iso: String(sides[1])), publication < day
      else { continue }
      days[day] = publication
    }
    return days
  }

  public func rates(for currency: CurrencyCode) throws -> [Rate] {
    try writer.read { db in
      try Rate
        .filter(Column("currency") == currency.code)
        .order(Column("date").desc)
        .fetchAll(db)
    }
  }

  /// The rate actually used for a day: the exact one, otherwise the last published before
  /// it.
  ///
  /// The primary key holds the source, so one day can carry several rates at once. The
  /// protected ones win: a rate entered by hand or brought in with an import is never
  /// pushed aside by the bank, and the bank itself wins over its mirror — the same order
  /// `RateTable` uses when it merges.
  public func rate(for currency: CurrencyCode, on day: DateOnly) throws -> Rate? {
    try writer.read { db in
      try Rate.fetchOne(
        db,
        sql: """
          SELECT * FROM rates WHERE currency = ? AND date <= ?
          ORDER BY date DESC, \(Self.sourceOrder) LIMIT 1
          """,
        arguments: [currency.code, day.iso])
    }
  }

  /// `CASE source WHEN … END`, built from the enum so the two can never drift apart.
  private static let sourceOrder: String = {
    let ranked: [RateSource] = [.manual, .imported, .cbr, .cbrMirror]
    let cases = ranked.enumerated()
      .map { rank, source in "WHEN '\(source.rawValue)' THEN \(rank)" }
      .joined(separator: " ")
    return "CASE source \(cases) ELSE \(ranked.count) END"
  }()
}
