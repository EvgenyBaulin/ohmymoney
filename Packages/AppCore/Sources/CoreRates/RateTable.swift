import CoreKit
import Foundation

/// Every rate the app knows about, indexed so the rules of currency rates can be applied
/// without a database and without a network:
///
/// - the rate of an operation is the one published on its own day;
/// - on a day the bank does not publish — a weekend or a holiday — the last rate published
///   before it applies, and that is the right answer, not a guess. Which days those are only
///   the bank can say: asked for such a day, it answers with the publication before it;
/// - a day whose rate is already known is never requested again, because the bank blocks
///   addresses that ask too often;
/// - with no network at all the last known rate is used and the operation is marked
///   provisional, to be refined once the real rate arrives — before everything the table
///   holds, the nearest rate it knows;
/// - a rate entered by hand or brought in by an import is never overwritten automatically;
/// - a currency outside ISO 4217 — a custom one, with rates typed by hand — is never asked of
///   the bank, which publishes none: its rate on a day is the last one typed for that day or
///   before it, and before the first one there is no rate at all, not a guess.
public struct RateTable: Sendable, Equatable {
  /// Rates per currency, ascending by date, at most one per date.
  private let series: [CurrencyCode: [Rate]]
  /// Days the bank was asked about and answered with an earlier publication, each with the
  /// date of that publication: its own word that nothing was published in between.
  public let unpublishedDays: [DateOnly: DateOnly]

  public init(rates: [Rate] = [], unpublishedDays: [DateOnly: DateOnly] = [:]) {
    var grouped: [CurrencyCode: [DateOnly: Rate]] = [:]
    for rate in rates {
      var days = grouped[rate.currency] ?? [:]
      if let existing = days[rate.date], !RateTable.overwrites(existing.source, with: rate.source) {
        continue
      }
      days[rate.date] = rate
      grouped[rate.currency] = days
    }
    self.series = grouped.mapValues { $0.values.sorted { $0.date < $1.date } }
    self.unpublishedDays = unpublishedDays.filter { $0.value < $0.key }
  }

  private init(series: [CurrencyCode: [Rate]], unpublishedDays: [DateOnly: DateOnly]) {
    self.series = series
    self.unpublishedDays = unpublishedDays
  }

  /// All rates, ordered by currency and then by day, so callers get a stable sequence.
  public var rates: [Rate] {
    series.keys.sorted { $0.code < $1.code }.flatMap { series[$0] ?? [] }
  }

  public var currencies: [CurrencyCode] {
    series.keys.sorted { $0.code < $1.code }
  }

  public var isEmpty: Bool { series.isEmpty }

  /// Whether the bank is ever asked for the currency: every code of ISO 4217 but the ruble. A
  /// custom currency is never one — its code is not ISO by definition — and the bank publishes
  /// nothing but ISO codes.
  public static func isAskedOfTheBank(_ currency: CurrencyCode) -> Bool {
    currency != .rub && ISOCurrencies.contains(currency)
  }

  /// Every rate of the currency, latest first: the history of the rates of a custom currency, as
  /// its list shows it.
  public func history(of currency: CurrencyCode) -> [Rate] {
    (series[currency] ?? []).reversed()
  }

  // MARK: - Lookup

  /// The rate that applies to an operation made on `day`: the rate published that day, or,
  /// when the bank published nothing, the last one published before it.
  public func rate(for currency: CurrencyCode, on day: DateOnly) -> Rate? {
    if currency == .rub { return RateTable.identity(on: day) }
    guard let history = series[currency] else { return nil }
    let cut = RateTable.upperBound(of: history, notAfter: day)
    guard cut > 0 else { return nil }
    return history[cut - 1]
  }

  /// The rate published on exactly that day, with no fallback. This is what decides whether
  /// the day still has to be fetched.
  public func publishedRate(for currency: CurrencyCode, on day: DateOnly) -> Rate? {
    if currency == .rub { return RateTable.identity(on: day) }
    guard let rate = rate(for: currency, on: day), rate.date == day else { return nil }
    return rate
  }

  /// Whether the day has to be asked for over the network.
  ///
  /// It does not, when its rate is already stored, and it does not either when the bank has
  /// already answered for it with an earlier publication that the table holds: a weekend or
  /// a holiday, where a request would come back with the rate that is already there and
  /// only bring the address closer to being blocked.
  ///
  /// Every other day is asked for, even one between two stored days. The cache is filled
  /// day by day, as operations need it, so two purchases a week apart leave the business
  /// days between them without a rate, although the bank published one for each; nothing
  /// but the bank can tell such a day from a holiday.
  public func needsFetch(currency: CurrencyCode, on day: DateOnly) -> Bool {
    guard RateTable.isAskedOfTheBank(currency) else { return false }
    guard let rate = rate(for: currency, on: day) else { return true }
    if rate.date == day { return false }
    // The bank said nothing was published after `publication` up to this day. A rate the
    // table holds from then on is what applies; an older one says this currency was never
    // brought in for that publication, and it still has to be.
    guard let publication = unpublishedDays[day] else { return true }
    return rate.date < publication
  }

  /// Rate to apply right now, together with the flag that goes into `rate_provisional`.
  ///
  /// The flag is raised whenever the day's own rate is not in the table and the bank has not
  /// said the day has none — past everything the table knows (the offline case) and in a
  /// hole of the cache alike: the last known rate is used and the pipeline refines it later.
  /// A weekend the bank answered for resolves to the publication before it with the flag
  /// down — that rate is final.
  ///
  /// A day before everything the table holds for the currency — a backdated purchase, entered
  /// offline or before the background request comes back — takes the nearest rate known, the
  /// first one, provisional: without it the operation could not be saved at all, and
  /// offline an operation takes the last known rate with the flag anyway. Only a currency
  /// with no rate at all resolves to nil.
  ///
  /// A custom currency is never provisional — no bank will ever refine its rate —, and a day
  /// before its first rate has none: the owner types it.
  public func resolve(_ currency: CurrencyCode, on day: DateOnly) -> RateResolution? {
    if currency != .rub, !RateTable.isAskedOfTheBank(currency) {
      return rate(for: currency, on: day).map { RateResolution(rate: $0, isProvisional: false) }
    }
    guard let rate = rate(for: currency, on: day) else {
      guard currency != .rub, let nearest = series[currency]?.first else { return nil }
      return RateResolution(rate: nearest, isProvisional: true)
    }
    let isGuess = rate.date != day && needsFetch(currency: currency, on: day)
    return RateResolution(rate: rate, isProvisional: isGuess)
  }

  /// What an answer to a request for `day` says about that day: the publication that holds
  /// on it when the bank published nothing of its own — nil when the answer says nothing of
  /// the kind.
  ///
  /// Only the bank's own answer counts: the mirror always sends its latest day, whatever day
  /// was asked. And only for a day not after `today` in Moscow: asked about a later day, the
  /// bank sends what it has published so far, and the day's own rate may still come.
  public static func publicationHolding(
    on day: DateOnly, answer: RateSnapshot, today: DateOnly
  ) -> DateOnly? {
    guard answer.source == .cbr, answer.date < day, day <= today else { return nil }
    return answer.date
  }

  // MARK: - Merging

  /// Folds a freshly fetched snapshot into the table.
  ///
  /// A manual rate and a rate that arrived with an import are protected and stay untouched.
  /// Between the two automatic sources the bank itself wins, so a mirror reading never
  /// replaces an official one for the same day.
  public func merging(_ snapshot: RateSnapshot) -> RateTable {
    var merged = series
    for rate in snapshot.rates.values {
      var history = merged[rate.currency] ?? []
      let cut = RateTable.upperBound(of: history, notAfter: rate.date)
      if cut > 0, history[cut - 1].date == rate.date {
        guard RateTable.overwrites(history[cut - 1].source, with: rate.source) else { continue }
        history[cut - 1] = rate
      } else {
        history.insert(rate, at: cut)
      }
      merged[rate.currency] = history
    }
    return RateTable(series: merged, unpublishedDays: unpublishedDays)
  }

  /// Convenience for loading a cache row by row; the same precedence rules apply.
  public func merging(_ rates: [Rate]) -> RateTable {
    rates.reduce(self) { table, rate in
      let snapshot = RateSnapshot(
        date: rate.date, rates: [rate.currency: rate], source: rate.source)
      return table.merging(snapshot)
    }
  }

  /// `true` when a rate from `incoming` may replace one already stored from `existing`.
  static func overwrites(_ existing: RateSource, with incoming: RateSource) -> Bool {
    if existing.isProtected { return false }
    if existing == .cbr && incoming == .cbrMirror { return false }
    return true
  }

  // MARK: - Provisional refinement

  /// What an operation used for its conversion, reduced to the four facts the rule needs:
  /// the currency, the day of the operation, where its rate came from and whether it was
  /// marked provisional. `appliedRateDate` is the day of the rate actually used, which tells
  /// a stale guess apart from a rate that is already the right one.
  public struct RateUsage: Hashable, Sendable {
    /// Identifier of the operation, so the caller can map the answer back to its row.
    public var id: UUID
    public var currency: CurrencyCode
    public var day: DateOnly
    public var source: RateSource?
    public var isProvisional: Bool
    public var appliedRateDate: DateOnly?

    public init(
      id: UUID = UUID(), currency: CurrencyCode, day: DateOnly, source: RateSource? = nil,
      isProvisional: Bool = false, appliedRateDate: DateOnly? = nil
    ) {
      self.id = id
      self.currency = currency
      self.day = day
      self.source = source
      self.isProvisional = isProvisional
      self.appliedRateDate = appliedRateDate
    }
  }

  /// What a provisional operation takes now: the rate the table resolves its day to, and
  /// the flag that goes with it.
  public struct RateRefinement: Hashable, Sendable {
    public let usageId: UUID
    public let rate: Rate
    /// What `resolve` says of the operation's day. A weekday whose own rate is not published
    /// yet takes the rate of the day before and stays provisional; a later run refines it
    /// again or settles it.
    public let isProvisional: Bool

    public init(usageId: UUID, rate: Rate, isProvisional: Bool) {
      self.usageId = usageId
      self.rate = rate
      self.isProvisional = isProvisional
    }
  }

  /// Which provisional operations the table can now refine or settle, as a pure function:
  /// same inputs, same answer, no clock and no storage. Only an operation marked provisional,
  /// in a currency other than the ruble, whose rate is not a manual one and did not come with
  /// an import, is looked at. The table resolves its day, and the operation gets an answer
  /// when either holds:
  ///
  /// - the rate is of another day than the one it carries — it takes the new rate, with the
  ///   flag `resolve` gives the day;
  /// - the rate is the one it carries, and the table now knows it is final — a Sunday or a
  ///   holiday once the bank, asked for that day, answered with the publication before it.
  ///   The rate stays and the flag comes down. The day's own rate never comes, so nothing
  ///   else would ever settle such an operation.
  ///
  /// Everything else is left alone: once an answer is written, running the rule on what was
  /// written changes nothing.
  public static func refinement(
    for usages: [RateUsage], with table: RateTable
  ) -> [RateRefinement] {
    usages.compactMap { usage in
      guard usage.isProvisional, usage.currency != .rub else { return nil }
      if let source = usage.source, source.isProtected { return nil }
      guard let resolved = table.resolve(usage.currency, on: usage.day) else { return nil }
      guard resolved.rate.date != usage.appliedRateDate || !resolved.isProvisional else {
        return nil
      }
      return RateRefinement(
        usageId: usage.id, rate: resolved.rate, isProvisional: resolved.isProvisional)
    }
  }

  // MARK: - Helpers

  /// The ruble converts to itself; keeping it here spares every caller a special case.
  private static func identity(on day: DateOnly) -> Rate {
    Rate(date: day, currency: .rub, rubPerUnit: 1, nominal: 1, source: .cbr)
  }

  /// Number of rates dated on or before `day`, found by bisection.
  private static func upperBound(of history: [Rate], notAfter day: DateOnly) -> Int {
    var low = 0
    var high = history.count
    while low < high {
      let middle = (low + high) / 2
      if history[middle].date <= day {
        low = middle + 1
      } else {
        high = middle
      }
    }
    return low
  }

}

/// The rate to use plus the `rate_provisional` flag that travels with the operation.
public struct RateResolution: Hashable, Sendable {
  public let rate: Rate
  public let isProvisional: Bool

  public init(rate: Rate, isProvisional: Bool) {
    self.rate = rate
    self.isProvisional = isProvisional
  }
}
