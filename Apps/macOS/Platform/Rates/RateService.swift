import AppCore
import AppDatabase
import Foundation

/// What one refinement of provisional rates did — the result of step 1 of the pipeline.
/// Counts only: no amounts and no descriptions ever leave it.
public struct RefinementResult: Hashable, Sendable {
  /// Operations with a provisional rate when the step began.
  public var provisional = 0
  /// Days asked of the bank.
  public var requestedDays = 0
  /// Operations that took a better rate or were settled.
  public var refined = 0
  /// Operations still provisional at the end: their day has no rate yet.
  public var remaining = 0

  public init(provisional: Int = 0, requestedDays: Int = 0, refined: Int = 0, remaining: Int = 0) {
    self.provisional = provisional
    self.requestedDays = requestedDays
    self.refined = refined
    self.remaining = remaining
  }
}

/// Keeps the rate cache filled, hands rates to the rest of the application and refines the
/// provisional rates of operations.
///
/// Whether a day is worth asking about at all is decided by `RateTable.needsFetch`: a day
/// whose rate is stored, or that the bank has already answered with an earlier publication
/// (a weekend, a holiday — kept in the database), is never asked about again: the bank can
/// block an address that asks too often.
/// A request that fails is tried once more two seconds later, and a refinement never spends
/// more than thirty seconds on the network: there is no retrying in a loop. A day after today
/// that the bank has not published yet is asked about again once an hour at most.
///
/// A custom currency — a code outside ISO 4217, with rates typed by hand — is never asked
/// about: the bank publishes none (`RateTable.isAskedOfTheBank`). Its rate is the one the
/// owner typed for the day or before it, and before the first one there is none.
public actor RateService {
  /// How patient the refinement is with the network.
  public struct Policy: Sendable {
    public var retryDelay: Duration = .seconds(2)
    public var budget: Duration = .seconds(30)
    /// How long a day after today rests once the bank answered it with an earlier
    /// publication: its own rate comes out on the business day before it, in the afternoon.
    public var aheadRecheck: Duration = .seconds(3600)

    public init(
      retryDelay: Duration = .seconds(2), budget: Duration = .seconds(30),
      aheadRecheck: Duration = .seconds(3600)
    ) {
      self.retryDelay = retryDelay
      self.budget = budget
      self.aheadRecheck = aheadRecheck
    }
  }

  private let repository: RateRepository
  private let transactions: TransactionRepository?
  private let client: any RatesFetching
  private let calendar: CalendarContext
  private let policy: Policy
  private let today: @Sendable () -> DateOnly
  /// Stamps `fetched_at` on what arrives.
  private let clock: any CoreKit.Clock
  /// The note of the income a refinement writes when money that came back now covers a part
  /// with some over — «Излишек возврата» in the interface language of the moment.
  private let surplusNote: @Sendable () -> String?
  /// Days being asked about right now.
  private var inFlight: Set<String> = []
  /// The requests on their way, for `close()` to cancel.
  private var requests: [UUID: Task<RateSnapshot, any Error>] = [:]
  /// Set by `close()`: the database is about to close.
  public private(set) var isClosed = false
  /// Callers waiting for the answer about a day another caller is asking about; each learns
  /// whether that answer was stored.
  private var waiting: [String: [UUID: CheckedContinuation<Bool, any Error>]] = [:]
  /// Days up to today the bank itself answered, in this session. Its document for such a day
  /// never changes: asking again would bring the same currencies, and one it left out — broken
  /// or not published — would be asked for at every run. A day it answered with an earlier
  /// publication is kept in the database as well (`RateRepository.noteUnpublished`). A failure
  /// or the mirror's answer never lands here, so the next run asks the official source again.
  private var attempted: Set<String> = []
  /// Days after today the bank answered with what it had published so far, with the instant
  /// of that answer. Their rate may still come — the bank sets tomorrow's in the afternoon —
  /// so such a day rests for `Policy.aheadRecheck` and is then asked again.
  private var askedAhead: [String: Date] = [:]

  public init(
    repository: RateRepository, transactions: TransactionRepository? = nil,
    client: any RatesFetching = CBRClient(), calendar: CalendarContext = .system,
    policy: Policy = Policy(),
    today: @escaping @Sendable () -> DateOnly = { CalendarContext.moscow.day(of: Date()) },
    clock: any CoreKit.Clock = SystemClock(),
    surplusNote: @escaping @Sendable () -> String? = { nil }
  ) {
    self.repository = repository
    self.transactions = transactions
    self.client = client
    self.calendar = calendar
    self.policy = policy
    self.today = today
    self.clock = clock
    self.surplusNote = surplusNote
  }

  /// Rate for one day, taken from the cache when it is there. Returns nil when the day is
  /// not cached and the network is unavailable — the caller then marks the amount
  /// provisional and a later run refines it.
  public func rate(for currency: CurrencyCode, on day: DateOnly) async -> Rate? {
    if currency == .rub { return nil }
    let table = (try? repository.table()) ?? RateTable()
    if !table.needsFetch(currency: currency, on: day) {
      return table.rate(for: currency, on: day)
    }
    await refresh(day: day, currency: currency)
    return try? repository.rate(for: currency, on: day)
  }

  /// Asks the bank for one day and stores everything it published for it, when the day has
  /// no rate yet for `currency` — the currency of the operation that needs it: a rate typed
  /// by hand or imported for another currency says nothing about this one. Fire and forget:
  /// the entry line calls it after a save, and a failure is left to the pipeline.
  public func refresh(day: DateOnly, currency: CurrencyCode) async {
    let key = day.iso
    guard RateTable.isAskedOfTheBank(currency), !isClosed, !isAnswered(key) else { return }
    let table = (try? repository.table()) ?? RateTable()
    guard table.needsFetch(currency: currency, on: day) else { return }
    _ = try? await fetchAndStore(day, retrying: false)
  }

  /// Stops the service before its database closes: the requests still on their way are cancelled,
  /// and nothing is asked or written any more — an answer that arrives later is dropped. The actor
  /// runs one thing at a time, so once this has run, no write of the service is left to happen.
  public func close() {
    isClosed = true
    for request in requests.values { request.cancel() }
  }

  // MARK: - Refinement (step 1 of the pipeline)

  /// Refines the provisional rates of operations.
  ///
  /// 1. What the cache can settle is settled first, without the network.
  /// 2. The network is used only while provisional operations remain, for their days. A
  ///    weekend or a holiday among them is answered with the publication before it, which
  ///    settles it.
  /// 3. What arrived is applied, off the main thread, by compare and set.
  ///
  /// Errors are thrown, not swallowed: the step shows «не удалось» and «Повторить». A
  /// cancellation is thrown as `CancellationError`, which the pipeline reports as a
  /// cancellation and not as a failure.
  public func refine() async throws -> RefinementResult {
    guard let transactions else { return RefinementResult() }
    guard !isClosed else { throw CancellationError() }
    let usages = try transactions.provisionalUsages(calendar: calendar)
    var result = RefinementResult(provisional: usages.count)
    guard !usages.isEmpty else { return result }

    result.refined += try apply(repository.table(), to: usages)
    var remaining = try transactions.provisionalUsages(calendar: calendar)
    guard !remaining.isEmpty else { return result }

    let days = daysToAsk(for: remaining, table: try repository.table())
    result.requestedDays = days.count
    var failure: (any Error)?
    do {
      try await withinBudget { try await self.fetchAll(days) }
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      // What did arrive before the failure is still applied below.
      failure = error
    }

    guard !isClosed else { throw CancellationError() }
    result.refined += try apply(repository.table(), to: remaining)
    remaining = try transactions.provisionalUsages(calendar: calendar)
    result.remaining = remaining.count
    if let failure { throw failure }
    return result
  }

  /// The days whose rates the remaining operations wait for, oldest first.
  private func daysToAsk(for usages: [RateTable.RateUsage], table: RateTable) -> [DateOnly] {
    let days = Set(
      usages.filter {
        table.needsFetch(currency: $0.currency, on: $0.day) && !isAnswered($0.day.iso)
      }.map(\.day))
    return days.sorted()
  }

  /// Whether the bank has already answered for the day without giving it — for good, or, for
  /// a day after today, recently enough that asking again would only bring the same answer.
  private func isAnswered(_ key: String) -> Bool {
    if attempted.contains(key) { return true }
    guard let asked = askedAhead[key] else { return false }
    return Duration.seconds(clock.now.timeIntervalSince(asked)) < policy.aheadRecheck
  }

  private func fetchAll(_ days: [DateOnly]) async throws {
    for day in days {
      try Task.checkCancellation()
      try await fetchAndStore(day, retrying: true)
    }
  }

  /// Runs `work` for at most the policy's budget; past it the work is cancelled and the
  /// refinement fails with `outOfTime`.
  private func withinBudget(_ work: @escaping @Sendable () async throws -> Void) async throws {
    let budget = policy.budget
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { try await work() }
      group.addTask {
        try await Task.sleep(for: budget)
        throw RateFetchError.outOfTime
      }
      defer { group.cancelAll() }
      _ = try await group.next()
    }
  }

  /// Asks for one day — once more after a pause when the first answer fails — and stores
  /// what the bank published. A day another caller is asking about right now is not asked
  /// twice: its answer is waited for. When that answer brought nothing, a caller that
  /// retries asks on its own, so the refinement never ends as if the day had been asked.
  ///
  /// Every request is in the journal: the day, the source, the attempt, and — when it fails —
  /// the status or the network code and the delay before the second attempt. A cancellation
  /// is not a failure and is not logged as one.
  private func fetchAndStore(_ day: DateOnly, retrying: Bool) async throws {
    let key = day.iso
    while inFlight.contains(key) {
      if try await answer(of: key) || !retrying { return }
    }
    inFlight.insert(key)
    var stored = false
    defer { finish(key, stored: stored) }

    let dayPair = LogPair("day", .token(key))
    AppLog.info(
      "rates.requested", .rates, "asking the bank for a day",
      [dayPair, LogPair("source", .token(RateSource.cbr.rawValue))])
    var attempt = 1
    let snapshot: RateSnapshot
    do {
      snapshot = try await ask(day)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      guard retrying else {
        AppLog.warning(
          "rates.failed", .rates, "the bank was not reached",
          [dayPair, LogPair("attempt", .count(attempt))] + RateFetchError.logPairs(of: error))
        throw error
      }
      let delay = policy.retryDelay.components
      AppLog.info(
        "rates.retry", .rates, "asking the bank again after a wait",
        [
          dayPair,
          LogPair(
            "delay",
            .milliseconds(
              Int(delay.seconds) * 1000 + Int(delay.attoseconds / 1_000_000_000_000_000))),
        ] + RateFetchError.logPairs(of: error))
      try await Task.sleep(for: policy.retryDelay)
      attempt = 2
      do {
        snapshot = try await ask(day)
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        AppLog.warning(
          "rates.failed", .rates, "the bank was not reached",
          [dayPair, LogPair("attempt", .count(attempt))] + RateFetchError.logPairs(of: error))
        throw error
      }
    }
    // The app may have quit while the answer was on its way.
    guard !isClosed else { throw CancellationError() }
    AppLog.info(
      "rates.fetched", .rates, "rates arrived",
      [
        dayPair,
        LogPair("source", .token(snapshot.source.rawValue)),
        LogPair("rates", .count(snapshot.rates.count)),
        LogPair("forToday", .flag(snapshot.date == day)),
        LogPair("attempt", .count(attempt)),
      ])
    try store(snapshot)
    if let publication = RateTable.publicationHolding(on: day, answer: snapshot, today: today()) {
      try repository.noteUnpublished(day, holding: publication)
    }
    stored = true
    // Only the bank's own answer settles anything: the mirror always gives its latest day,
    // whatever day was asked. About a day up to today it has said all it will say; about a
    // later day it said only what it has published so far.
    if snapshot.source == .cbr {
      if day <= today() {
        attempted.insert(key)
      } else if snapshot.date != day {
        askedAhead[key] = clock.now
      }
    }
  }

  /// One request to the bank, which `close()` cancels while it is on its way; a cancelled
  /// caller cancels it too. A closed service asks nothing.
  private func ask(_ day: DateOnly) async throws -> RateSnapshot {
    guard !isClosed else { throw CancellationError() }
    let id = UUID()
    let client = self.client
    let request = Task { try await client.dailyRates(on: day) }
    requests[id] = request
    defer { requests[id] = nil }
    return try await withTaskCancellationHandler {
      try await request.value
    } onCancel: {
      request.cancel()
    }
  }

  /// Waits for the caller asking about the day right now and says whether its answer was
  /// stored. A cancelled wait ends at once, without cancelling that request.
  private func answer(of key: String) async throws -> Bool {
    let id = UUID()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        guard !Task.isCancelled else {
          continuation.resume(throwing: CancellationError())
          return
        }
        waiting[key, default: [:]][id] = continuation
      }
    } onCancel: {
      Task { await self.stopWaiting(for: key, id: id) }
    }
  }

  private func stopWaiting(for key: String, id: UUID) {
    waiting[key]?.removeValue(forKey: id)?.resume(throwing: CancellationError())
  }

  /// The day is no longer being asked about: everyone waiting for it learns how it went.
  private func finish(_ key: String, stored: Bool) {
    inFlight.remove(key)
    for continuation in (waiting.removeValue(forKey: key) ?? [:]).values {
      continuation.resume(returning: stored)
    }
  }

  /// A rate the owner typed by hand, and a rate that arrived with an import, are never
  /// overwritten automatically — the same rule the table applies when merging. What arrives
  /// carries the instant it arrived (`rates.fetched_at`); a stored rate that wins keeps its own.
  private func store(_ snapshot: RateSnapshot) throws {
    let known = try repository.allRates()
    let protectedKeys = Set(
      known.filter { $0.source.isProtected }.map { "\($0.currency.code)|\($0.date.iso)" })
    let now = clock.now
    let arrived = RateSnapshot(
      date: snapshot.date,
      rates: snapshot.rates.mapValues { rate in
        var stamped = rate
        stamped.fetchedAt = rate.fetchedAt ?? now
        return stamped
      },
      source: snapshot.source)
    let incoming = RateTable(rates: known)
      .merging(arrived)
      .rates
      .filter { rate in
        rate.date == snapshot.date && !rate.source.isProtected
          && !protectedKeys.contains("\(rate.currency.code)|\(rate.date.iso)")
      }
    try repository.save(incoming)
  }

  /// Writes what the table can refine now and returns how many operations took it. How much
  /// the money back of the refined parts was balanced again goes to the journal.
  private func apply(_ table: RateTable, to usages: [RateTable.RateUsage]) throws -> Int {
    guard let transactions else { return 0 }
    let refinements = RateTable.refinement(for: usages, with: table)
    guard !refinements.isEmpty else { return 0 }
    return try transactions.applyRefinements(
      refinements, of: usages, calendar: calendar, surplusNote: surplusNote(),
      settled: { $0.log() })
  }
}
