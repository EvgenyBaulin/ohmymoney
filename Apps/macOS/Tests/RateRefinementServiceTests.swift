import AppCore
import AppDatabase
import Synchronization
import XCTest

@testable import OhMyMoney

/// The rate step of the pipeline against a fake bank: which days it asks for, which source it
/// asks, what it does when the bank fails or the step is cancelled, and how a day the bank
/// never publishes gets settled.
final class RateRefinementServiceTests: XCTestCase {
  /// Friday 18 September 2026 in Moscow.
  private let today = DateOnly(year: 2026, month: 9, day: 18)

  private func day(_ number: Int) -> DateOnly { DateOnly(year: 2026, month: 9, day: number) }

  /// Answers every request with the day the real bank would publish for it, or fails. Keeps
  /// every request it got, «official 2026-09-13».
  private actor FakeBank {
    private(set) var requests: [String] = []
    private let answer: @Sendable (CBRClient.Source, DateOnly) throws -> DateOnly

    init(answer: @escaping @Sendable (CBRClient.Source, DateOnly) throws -> DateOnly) {
      self.answer = answer
    }

    func rates(_ source: CBRClient.Source, _ day: DateOnly) throws -> RateSnapshot {
      requests.append("\(source) \(day.iso)")
      let date = try answer(source, day)
      return RateSnapshot(
        date: date,
        // The same number the cache holds: a day's rate is the same whoever asks for it.
        rates: [.usd: Rate(date: date, currency: .usd, rubPerUnit: Decimal(string: "80.1")!)],
        source: source == .official ? .cbr : .cbrMirror)
    }

    func mirrorRequests() -> [String] { requests.filter { $0.hasPrefix("mirror") } }
  }

  private struct Setup {
    let rates: RateRepository
    let transactions: TransactionRepository
  }

  private func makeSetup() throws -> Setup {
    let stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    return Setup(
      rates: RateRepository(writer: stack.writer),
      transactions: TransactionRepository(writer: stack.writer))
  }

  /// A clock the test moves by hand.
  private final class HandClock: CoreKit.Clock, Sendable {
    private let instant: Mutex<Date>
    init(_ start: Date) { instant = Mutex(start) }
    var now: Date { instant.withLock { $0 } }
    func advance(by seconds: TimeInterval) { instant.withLock { $0 += seconds } }
  }

  private func service(
    _ setup: Setup, bank: FakeBank, clock: any CoreKit.Clock = SystemClock()
  ) -> RateService {
    let today = self.today
    let client = CBRClient(
      fetch: { source, day in try await bank.rates(source, day) }, today: { today })
    return RateService(
      repository: setup.rates, transactions: setup.transactions, client: client,
      calendar: .utc, policy: .init(retryDelay: .milliseconds(1), budget: .seconds(20)),
      today: { today }, clock: clock)
  }

  /// A 10 $ book bought on `number` at noon, carrying the rate of `rateDay` with the
  /// provisional mark — what the entry panel writes offline.
  @discardableResult
  private func book(
    on number: Int, rateOf rateDay: Int, currency: CurrencyCode = .usd, in setup: Setup
  ) throws
    -> TransactionEntry
  {
    let rate = Decimal(string: "80.1")!
    var draft = TransactionDraft(
      occurredAt: CalendarContext.utc.startOfDay(day(number)).addingTimeInterval(12 * 3600),
      currency: currency, amount: AmountE4(whole: 10), rate: rate, rateDate: day(rateDay),
      rateSource: .cbr, rateProvisional: true, note: "book")
    draft.normalizeSinglePart()
    let entry = try draft.materialize(rublesConverter: { try AmountE4(decimal: $0.decimal * rate) })
    try setup.transactions.save(entry)
    return entry
  }

  private func cache(_ number: Int, currency: CurrencyCode = .usd, in setup: Setup) throws {
    try setup.rates.save([
      Rate(date: day(number), currency: currency, rubPerUnit: Decimal(string: "80.1")!)
    ])
  }

  /// The mirror only knows its latest day: for a day in the past it would hand over a wrong
  /// rate. When the bank is down the day stays provisional, and the next run asks the bank
  /// again — a failure is never remembered as «asked already».
  func testAPastDayNeverGoesToTheMirrorAndIsAskedAgainNextTime() async throws {
    let setup = try makeSetup()
    try cache(15, in: setup)
    try book(on: 16, rateOf: 15, in: setup)
    let bank = FakeBank { _, _ in throw URLError(.notConnectedToInternet) }
    let service = service(setup, bank: bank)

    do {
      _ = try await service.refine()
      XCTFail("a bank that does not answer is a failure of the step")
    } catch {
      XCTAssertFalse(error is CancellationError)
    }
    let first = await bank.requests
    XCTAssertEqual(first, ["official 2026-09-16", "official 2026-09-16"], "one retry, no more")
    let mirror = await bank.mirrorRequests()
    XCTAssertEqual(mirror, [])
    XCTAssertEqual(try setup.transactions.provisionalUsages(calendar: .utc).count, 1)

    _ = try? await service.refine()
    let second = await bank.requests
    XCTAssertEqual(second.count, 4)
    XCTAssertEqual(second.last, "official 2026-09-16")
  }

  /// «Курсы: запрос за дату, источник (ЦБ или зеркало), код ответа, сколько курсов получено,
  /// повторы и задержки». A request that fails twice is in the journal with its day, both
  /// attempts and the delay between them — the pipeline's own «step failed» line says none
  /// of it.
  func testARequestThatFailsTwiceIsInTheJournalWithItsDay() async throws {
    let logs = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-rates-log-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: logs) }
    Logbook.shared.open(directory: logs, threshold: .debug)
    let setup = try makeSetup()
    try cache(15, in: setup)
    try book(on: 16, rateOf: 15, in: setup)
    // The bank refuses the address, as it does when it is asked too often.
    let bank = FakeBank { _, _ in throw RateFetchError.unavailable(status: 403) }

    _ = try? await service(setup, bank: bank).refine()

    // The journal is written off the calling task; give it its turn.
    var lines: [String] = []
    for _ in 0..<50 {
      lines = Logbook.shared.lines().filter { $0.contains(" rates.") }
      if lines.contains(where: { $0.contains("rates.failed") }) { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    Logbook.shared.close()
    let requested = lines.filter { $0.contains("rates.requested") }
    XCTAssertEqual(requested.count, 1, "\(lines)")
    XCTAssertTrue(requested.allSatisfy { $0.contains("day=2026-09-16") }, "\(lines)")
    XCTAssertTrue(requested.allSatisfy { $0.contains("source=cbr") }, "\(lines)")
    let retry = try XCTUnwrap(lines.first { $0.contains("rates.retry") }, "\(lines)")
    XCTAssertTrue(retry.contains("day=2026-09-16"), retry)
    XCTAssertTrue(retry.contains("delay=1ms"), retry)
    XCTAssertTrue(retry.contains("status=403"), retry)
    let failed = try XCTUnwrap(lines.first { $0.contains("rates.failed") }, "\(lines)")
    XCTAssertTrue(failed.contains("day=2026-09-16"), failed)
    XCTAssertTrue(failed.contains("attempt=2"), failed)
    XCTAssertTrue(failed.contains("status=403"), failed)
  }

  /// The status the source answered with is kept in the error, so the journal can say it.
  func testTheStatusOfARefusedAnswerIsKept() throws {
    let url = try XCTUnwrap(URL(string: "https://www.cbr.ru/scripts/XML_daily.asp"))
    let refused = try XCTUnwrap(
      HTTPURLResponse(url: url, statusCode: 403, httpVersion: nil, headerFields: nil))
    XCTAssertThrowsError(
      try CBRClient.snapshot(from: Data(), response: refused, source: .official)
    ) { error in
      XCTAssertEqual(error as? RateFetchError, .unavailable(status: 403))
    }
    XCTAssertEqual(
      RateFetchError.logPairs(of: RateFetchError.unavailable(status: 403)).map(\.text),
      ["error=RateFetchError", "status=403"])
    XCTAssertEqual(
      RateFetchError.logPairs(of: URLError(.notConnectedToInternet)).map(\.text),
      ["error=URLError", "code=-1009"])
  }

  /// «Любая перехваченная ошибка: тип»: a type name longer than a token — 24 characters — is
  /// written whole, as every caught error of the journal is, not as `<not-a-token>`.
  func testTheTypeOfAFailedRequestIsWrittenWhateverItsLength() {
    XCTAssertEqual(
      RateFetchError.logPairs(of: TheAnswerOfTheBankCouldNotBeRead()).map(\.text),
      ["error=TheAnswerOfTheBankCouldNotBeRead"])
  }

  private struct TheAnswerOfTheBankCouldNotBeRead: Error {}

  /// Today the mirror is a fair fallback: its latest day is today.
  func testTodayFallsBackToTheMirror() async throws {
    let bank = FakeBank { source, day in
      guard source == .mirror else { throw URLError(.timedOut) }
      return day
    }
    let today = self.today
    let client = CBRClient(fetch: { try await bank.rates($0, $1) }, today: { today })

    let snapshot = try await client.dailyRates(on: today)

    XCTAssertEqual(snapshot.source, .cbrMirror)
    let requests = await bank.requests
    XCTAssertEqual(requests, ["official 2026-09-18", "mirror 2026-09-18"])
  }

  /// East of Moscow the day turns first: at 01:00 in Novosibirsk it is still 21:00 of the day
  /// before in Moscow, so the owner's today is Moscow's tomorrow — and from the evening on the
  /// mirror serves exactly that day. It is as fair a fallback there as for Moscow's today; a
  /// day after that is nobody's today yet and never goes to the mirror.
  func testTheMirrorServesTheDayThatHasBegunEastOfMoscow() async throws {
    let tomorrow = day(19)
    let bank = FakeBank { source, _ in
      guard source == .mirror else { throw URLError(.timedOut) }
      return tomorrow
    }
    let today = self.today
    let client = CBRClient(fetch: { try await bank.rates($0, $1) }, today: { today })

    let snapshot = try await client.dailyRates(on: tomorrow)

    XCTAssertEqual(snapshot.source, .cbrMirror)
    XCTAssertEqual(snapshot.date, tomorrow)
    var requests = await bank.requests
    XCTAssertEqual(requests, ["official 2026-09-19", "mirror 2026-09-19"])

    do {
      _ = try await client.dailyRates(on: day(20))
      XCTFail("the day after tomorrow went to the mirror")
    } catch {
      XCTAssertFalse(error is CancellationError, "\(error)")
    }
    requests = await bank.requests
    XCTAssertEqual(requests.last, "official 2026-09-20")
  }

  /// From about 20:00 in Moscow the mirror already serves tomorrow's rates (its own sample,
  /// `mirror_2026-09-18.json`, is stamped the 17th at 20:00). An answer for another day than
  /// the one asked is no answer: nothing is stored, today stays provisional, and the next run
  /// asks the bank again.
  func testTheMirrorsNextDayIsNotTakenForToday() async throws {
    let tomorrow = day(19)
    let bank = FakeBank { source, _ in
      guard source == .mirror else { throw URLError(.timedOut) }
      return tomorrow
    }
    let today = self.today
    let client = CBRClient(fetch: { try await bank.rates($0, $1) }, today: { today })
    do {
      let snapshot = try await client.dailyRates(on: today)
      XCTFail("the mirror's \(snapshot.date.iso) was taken for \(today.iso)")
    } catch {
      XCTAssertFalse(error is CancellationError, "\(error)")
    }

    let setup = try makeSetup()
    try cache(17, in: setup)
    let book = try book(on: 18, rateOf: 17, in: setup)
    do {
      _ = try await service(setup, bank: bank).refine()
      XCTFail("a day nobody answered for is a failure of the step")
    } catch {
      XCTAssertFalse(error is CancellationError, "\(error)")
    }
    XCTAssertEqual(try setup.rates.allRates().map(\.date), [day(17)], "tomorrow is not stored")
    let still = try XCTUnwrap(try setup.transactions.entry(id: book.id))
    XCTAssertTrue(still.transaction.rateProvisional)
    XCTAssertEqual(still.transaction.rateDate, day(17))
    XCTAssertEqual(try setup.transactions.provisionalUsages(calendar: .utc).count, 1)
  }

  /// A cancelled request is a cancellation: not a reason to try the mirror, and not a
  /// failure the step would show.
  func testACancelledRequestIsACancellationNotAFailure() async throws {
    let bank = FakeBank { _, _ in throw URLError(.cancelled) }
    let today = self.today
    let client = CBRClient(fetch: { try await bank.rates($0, $1) }, today: { today })
    do {
      _ = try await client.dailyRates(on: today)
      XCTFail("a cancelled request has no rates")
    } catch {
      XCTAssertTrue(error is CancellationError, "\(error)")
    }
    let requests = await bank.requests
    XCTAssertEqual(requests, ["official 2026-09-18"])

    let setup = try makeSetup()
    try cache(15, in: setup)
    try book(on: 16, rateOf: 15, in: setup)
    do {
      _ = try await service(setup, bank: bank).refine()
      XCTFail("a cancelled refinement has no result")
    } catch {
      XCTAssertTrue(error is CancellationError, "\(error)")
    }
  }

  /// A Sunday carries Saturday's rate, provisional until the bank says Sunday has none of
  /// its own: asked for Sunday, it answers with Saturday. That answer settles the Sunday —
  /// Saturday's rate, no longer provisional — and is kept, so the next launch does not ask
  /// about the same Sunday again.
  func testAWeekendOperationSettlesOnTheBanksAnswerForItsDay() async throws {
    let setup = try makeSetup()
    try cache(12, in: setup)
    let sunday = try book(on: 13, rateOf: 12, in: setup)
    let bank = FakeBank { _, day in
      // The bank publishes nothing for a Sunday and answers with the Saturday before it.
      day == DateOnly(year: 2026, month: 9, day: 13) ? DateOnly(year: 2026, month: 9, day: 12) : day
    }

    let result = try await service(setup, bank: bank).refine()

    let requests = await bank.requests
    XCTAssertEqual(requests, ["official 2026-09-13"])
    XCTAssertEqual(result.provisional, 1)
    XCTAssertEqual(result.refined, 1)
    XCTAssertEqual(result.remaining, 0)
    let settled = try XCTUnwrap(try setup.transactions.entry(id: sunday.id))
    XCTAssertFalse(settled.transaction.rateProvisional)
    XCTAssertEqual(settled.transaction.rateDate, day(12))
    XCTAssertEqual(settled.transaction.amountRubE4, sunday.transaction.amountRubE4)

    // Another Sunday operation, entered after a restart: nothing to ask.
    var draft = TransactionDraft(
      occurredAt: CalendarContext.utc.startOfDay(day(13)).addingTimeInterval(15 * 3600),
      currency: .usd, amount: AmountE4(whole: 3), note: "tea")
    AppEnvironment.applyRate(to: &draft, from: try setup.rates.table(), calendar: .utc)
    XCTAssertEqual(draft.rateDate, day(12))
    XCTAssertFalse(draft.rateProvisional)
    await service(setup, bank: bank).refresh(day: day(13), currency: .usd)
    let afterRestart = await bank.requests
    XCTAssertEqual(afterRestart, ["official 2026-09-13"])
  }

  /// Two purchases filled the 5th and the 15th; an operation on the 8th, entered offline,
  /// carries the 5th's rate. The 8th had a rate of its own: the step asks for it and takes
  /// it, instead of reading the hole as a holiday.
  func testABusinessDayInAHoleOfTheCacheIsAskedFor() async throws {
    let setup = try makeSetup()
    try cache(5, in: setup)
    try cache(15, in: setup)
    let tuesday = try book(on: 8, rateOf: 5, in: setup)
    let bank = FakeBank { _, day in day }

    let result = try await service(setup, bank: bank).refine()

    let requests = await bank.requests
    XCTAssertEqual(requests, ["official 2026-09-08"])
    XCTAssertEqual(result.refined, 1)
    XCTAssertEqual(result.remaining, 0)
    let settled = try XCTUnwrap(try setup.transactions.entry(id: tuesday.id))
    XCTAssertEqual(settled.transaction.rateDate, day(8))
    XCTAssertFalse(settled.transaction.rateProvisional)
  }

  /// Asked about a day after today in Moscow, the bank sends what it has so far. That says
  /// nothing about the day, whose rate may still be published: it is not kept.
  func testAnAnswerForADayAfterTodayIsNotKept() async throws {
    let setup = try makeSetup()
    let bank = FakeBank { _, day in min(day, DateOnly(year: 2026, month: 9, day: 18)) }

    await service(setup, bank: bank).refresh(day: day(19), currency: .usd)

    XCTAssertEqual(try setup.rates.unpublishedDays(), [:])
    XCTAssertEqual(try setup.rates.allRates().map(\.date), [day(18)])
  }

  /// In the morning the bank has nothing for tomorrow and answers with today; it publishes
  /// tomorrow's rate in the afternoon. An operation dated tomorrow is not asked about at every
  /// save or every run — but once an hour has passed it is asked again, in the same session,
  /// and takes its own rate.
  func testADayAfterTodayIsAskedAgainOnceAnHourHasPassed() async throws {
    let setup = try makeSetup()
    try cache(18, in: setup)
    let saturday = try book(on: 19, rateOf: 18, in: setup)
    let morning = CalendarContext.moscow.startOfDay(today).addingTimeInterval(10 * 3600)
    let afternoon = morning.addingTimeInterval(6 * 3600)
    let clock = HandClock(morning)
    let friday = day(18)
    let bank = FakeBank { _, asked in clock.now < afternoon ? min(asked, friday) : asked }
    let service = service(setup, bank: bank, clock: clock)

    let first = try await service.refine()
    await service.refresh(day: day(19), currency: .usd)
    clock.advance(by: 30 * 60)
    let second = try await service.refine()
    await service.refresh(day: day(19), currency: .usd)

    var requests = await bank.requests
    XCTAssertEqual(requests, ["official 2026-09-19"], "once in the morning, not at every run")
    XCTAssertEqual(first.remaining, 1)
    XCTAssertEqual(second.remaining, 1)

    clock.advance(by: 6 * 3600)
    let evening = try await service.refine()

    requests = await bank.requests
    XCTAssertEqual(requests, ["official 2026-09-19", "official 2026-09-19"])
    XCTAssertEqual(evening.refined, 1)
    XCTAssertEqual(evening.remaining, 0)
    let settled = try XCTUnwrap(try setup.transactions.entry(id: saturday.id))
    XCTAssertEqual(settled.transaction.rateDate, day(19))
    XCTAssertFalse(settled.transaction.rateProvisional)
  }

  /// A bank that holds every answer until the test opens it: a request that is on its way.
  private actor GatedBank: RatesFetching {
    private(set) var requests: [String] = []
    /// Whether each request had been cancelled by the time its answer was let through.
    private(set) var cancelled: [Bool] = []
    private var isOpen = false
    private var held: [CheckedContinuation<Void, Never>] = []
    private var watchers: [CheckedContinuation<Void, Never>] = []

    func dailyRates(on day: DateOnly) async throws -> RateSnapshot {
      requests.append(day.iso)
      watchers.forEach { $0.resume() }
      watchers = []
      if !isOpen { await withCheckedContinuation { held.append($0) } }
      cancelled.append(Task.isCancelled)
      return RateSnapshot(
        date: day,
        rates: [.usd: Rate(date: day, currency: .usd, rubPerUnit: Decimal(string: "80.1")!)],
        source: .cbr)
    }

    /// Returns once a request has come in.
    func firstRequest() async {
      guard requests.isEmpty else { return }
      await withCheckedContinuation { watchers.append($0) }
    }

    func open() {
      isOpen = true
      held.forEach { $0.resume() }
      held = []
    }
  }

  /// The entry line asks for the day of an operation it has just saved; the pipeline runs
  /// while that answer is on its way. The run waits for it rather than finishing with the
  /// operation still provisional and nothing said — and the bank is asked once.
  func testARunWaitsForTheAnswerTheEntryLineIsAlreadyWaitingFor() async throws {
    let setup = try makeSetup()
    try cache(15, in: setup)
    let book = try book(on: 16, rateOf: 15, in: setup)
    let bank = GatedBank()
    let today = self.today
    let service = RateService(
      repository: setup.rates, transactions: setup.transactions, client: bank,
      calendar: .utc, policy: .init(retryDelay: .milliseconds(1), budget: .seconds(20)),
      today: { today })

    let wednesday = day(16)
    let entryLine = Task { await service.refresh(day: wednesday, currency: .usd) }
    await bank.firstRequest()
    let run = Task { try await service.refine() }
    // Time for the run to reach the day the entry line is asking about.
    try await Task.sleep(for: .milliseconds(200))
    await bank.open()
    let result = try await run.value
    await entryLine.value

    XCTAssertEqual(result.refined, 1)
    XCTAssertEqual(result.remaining, 0)
    let requests = await bank.requests
    XCTAssertEqual(requests, ["2026-09-16"])
    let settled = try XCTUnwrap(try setup.transactions.entry(id: book.id))
    XCTAssertEqual(settled.transaction.rateDate, day(16))
    XCTAssertFalse(settled.transaction.rateProvisional)
  }

  /// A run cancelled while it waits for the entry line's answer stops at once: the wait
  /// holds nothing up, and the entry line's own request goes on.
  func testARunCancelledWhileWaitingStopsAtOnce() async throws {
    let setup = try makeSetup()
    try cache(15, in: setup)
    try book(on: 16, rateOf: 15, in: setup)
    let bank = GatedBank()
    let today = self.today
    let service = RateService(
      repository: setup.rates, transactions: setup.transactions, client: bank,
      calendar: .utc, policy: .init(retryDelay: .milliseconds(1), budget: .seconds(20)),
      today: { today })

    let wednesday = day(16)
    let entryLine = Task { await service.refresh(day: wednesday, currency: .usd) }
    await bank.firstRequest()
    let run = Task { try await service.refine() }
    try await Task.sleep(for: .milliseconds(200))
    run.cancel()
    do {
      _ = try await run.value
      XCTFail("a cancelled run has no result")
    } catch {
      XCTAssertTrue(error is CancellationError, "\(error)")
    }

    await bank.open()
    await entryLine.value
    XCTAssertEqual(try setup.rates.allRates().map(\.date).sorted(), [day(15), day(16)])
  }

  /// The bank's document for a day may lack a currency — left out as broken, or not
  /// published. A past day's document never changes, so the day is not asked again at every
  /// run of the same session for that currency; the next launch asks once more.
  func testADayTheBankAnsweredIsNotAskedAgainInTheSameSession() async throws {
    let euro = CurrencyCode("EUR")
    let setup = try makeSetup()
    try cache(15, in: setup)
    try cache(15, currency: euro, in: setup)
    try book(on: 16, rateOf: 15, currency: euro, in: setup)
    // The bank answers the day with its dollar only.
    let bank = FakeBank { _, day in day }
    let service = service(setup, bank: bank)

    let first = try await service.refine()
    let second = try await service.refine()

    let requests = await bank.requests
    XCTAssertEqual(requests, ["official 2026-09-16"])
    XCTAssertEqual(first.remaining, 1)
    XCTAssertEqual(second.remaining, 1)
    XCTAssertEqual(second.requestedDays, 0)
  }

  /// A currency the bank's document gave no usable rate for is named in the journal, with
  /// the day; the rest of the document is taken.
  func testABrokenCurrencyOfTheBanksDocumentIsInTheJournal() async throws {
    let logs = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-rates-log-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: logs) }
    Logbook.shared.open(directory: logs, threshold: .debug)
    let document = """
      <?xml version="1.0" encoding="utf-8"?>
      <ValCurs Date="16.09.2026">
      <Valute><CharCode>USD</CharCode><Nominal>1</Nominal><Value>83,1250</Value></Valute>
      <Valute><CharCode>JPY</CharCode><Nominal>100</Nominal><Value>56,2349</Value>
      <VunitRate>56,2349</VunitRate></Valute>
      </ValCurs>
      """
    let url = try XCTUnwrap(URL(string: "https://www.cbr.ru/scripts/XML_daily.asp"))
    let ok = try XCTUnwrap(
      HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))

    let snapshot = try CBRClient.snapshot(
      from: Data(document.utf8), response: ok, source: .official)

    XCTAssertEqual(snapshot.rates.keys.map(\.code), ["USD"])
    var lines: [String] = []
    for _ in 0..<50 {
      lines = Logbook.shared.lines().filter { $0.contains("rates.rejected") }
      if !lines.isEmpty { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    Logbook.shared.close()
    let line = try XCTUnwrap(lines.first, "no rates.rejected line")
    XCTAssertTrue(line.contains("date=2026-09-16"), line)
    XCTAssertTrue(line.contains("currency=JPY"), line)
  }

  /// A rate typed by hand for the dollar on a day says nothing about the euro: a euro
  /// operation of that day still has the day asked for.
  func testADollarTypedByHandDoesNotSilenceTheDayForTheEuro() async throws {
    let setup = try makeSetup()
    try setup.rates.save([
      Rate(date: day(16), currency: .usd, rubPerUnit: Decimal(string: "90")!, source: .manual)
    ])
    let bank = FakeBank { _, day in day }

    await service(setup, bank: bank).refresh(day: day(16), currency: CurrencyCode("EUR"))

    let requests = await bank.requests
    XCTAssertEqual(requests, ["official 2026-09-16"])
  }

  /// Nothing writes after the database is closed. The entry line's request is on
  /// its way when the app quits; once the service is closed, the answer that arrives later
  /// is not written, and the request itself is cancelled.
  func testNothingIsWrittenOnceTheServiceIsClosed() async throws {
    let setup = try makeSetup()
    let bank = GatedBank()
    let today = self.today
    let service = RateService(
      repository: setup.rates, transactions: setup.transactions, client: bank,
      calendar: .utc, policy: .init(retryDelay: .milliseconds(1), budget: .seconds(20)),
      today: { today })

    let wednesday = day(16)
    let entryLine = Task { await service.refresh(day: wednesday, currency: .usd) }
    await bank.firstRequest()
    await service.close()
    await bank.open()
    await entryLine.value

    XCTAssertEqual(try setup.rates.allRates(), [], "a rate was written after close")
    let cancelled = await bank.cancelled
    XCTAssertEqual(cancelled, [true], "the request on its way was not cancelled")
    await service.refresh(day: day(17), currency: .usd)
    let requests = await bank.requests
    XCTAssertEqual(requests, ["2026-09-16"], "a closed service asked the bank")
  }

  /// Without a provisional operation the step never touches the network.
  func testNothingProvisionalMeansNoRequest() async throws {
    let setup = try makeSetup()
    let bank = FakeBank { _, day in day }

    let result = try await service(setup, bank: bank).refine()

    XCTAssertEqual(result, RefinementResult())
    let requests = await bank.requests
    XCTAssertEqual(requests, [])
  }
}
