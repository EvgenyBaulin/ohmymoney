import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// A bank and a mirror that answer as a test tells them, and remember every request.
private actor ScriptedBank {
  enum Answer {
    case rates(DateOnly)
    case failure(any Error)
  }

  private(set) var requests: [String] = []
  private let official: Answer
  private let mirror: Answer

  init(official: Answer, mirror: Answer) {
    self.official = official
    self.mirror = mirror
  }

  func answer(_ source: CBRClient.Source, _ day: DateOnly) throws -> RateSnapshot {
    let name = source == .official ? "official" : "mirror"
    requests.append("\(name) \(day.iso)")
    switch source == .official ? official : mirror {
    case .rates(let published):
      return RateSnapshot(
        date: published,
        rates: [
          .usd: Rate(
            date: published, currency: .usd, rubPerUnit: Decimal(string: "80.5")!,
            source: source == .official ? .cbr : .cbrMirror)
        ],
        source: source == .official ? .cbr : .cbrMirror)
    case .failure(let error):
      throw error
    }
  }
}

/// When the bank does not answer, the mirror is asked — and only for Moscow's today or the day
/// after it, since the mirror knows its latest day alone. These scenarios move «today» to the
/// ends of a month, a leap February and a year, and break the bank in every way it breaks.
final class DataScenarioMirrorTests: XCTestCase {
  private let down = RateFetchError.unavailable(status: 503)

  private func client(_ bank: ScriptedBank, today: DateOnly) -> CBRClient {
    CBRClient(fetch: { try await bank.answer($0, $1) }, today: { today })
  }

  func testTheBankThatAnswersIsTheOnlyOneAsked() async throws {
    let today = DateOnly(year: 2026, month: 10, day: 14)
    let bank = ScriptedBank(official: .rates(today), mirror: .rates(today))
    let snapshot = try await client(bank, today: today).dailyRates(on: today)
    XCTAssertEqual(snapshot.source, .cbr)
    let requests = await bank.requests
    XCTAssertEqual(requests, ["official 2026-10-14"])
  }

  func testTodayGoesToTheMirrorWhenTheBankIsDown() async throws {
    let today = DateOnly(year: 2026, month: 10, day: 14)
    let bank = ScriptedBank(official: .failure(down), mirror: .rates(today))
    let snapshot = try await client(bank, today: today).dailyRates(on: today)
    XCTAssertEqual(snapshot.source, .cbrMirror)
    let requests = await bank.requests
    XCTAssertEqual(requests, ["official 2026-10-14", "mirror 2026-10-14"])
  }

  /// East of Moscow the owner's day turns first: Moscow's tomorrow is asked of the mirror too.
  func testMoscowsTomorrowGoesToTheMirror() async throws {
    let today = DateOnly(year: 2026, month: 10, day: 14)
    let tomorrow = DateOnly(year: 2026, month: 10, day: 15)
    let bank = ScriptedBank(official: .failure(down), mirror: .rates(tomorrow))
    let snapshot = try await client(bank, today: today).dailyRates(on: tomorrow)
    XCTAssertEqual(snapshot.date, tomorrow)
  }

  func testYesterdayNeverGoesToTheMirror() async throws {
    let today = DateOnly(year: 2026, month: 10, day: 14)
    let bank = ScriptedBank(official: .failure(down), mirror: .rates(today))
    do {
      _ = try await client(bank, today: today).dailyRates(
        on: DateOnly(year: 2026, month: 10, day: 13))
      XCTFail("a past day was answered")
    } catch {
      XCTAssertEqual(error as? RateFetchError, down)
    }
    let requests = await bank.requests
    XCTAssertEqual(requests, ["official 2026-10-13"])
  }

  func testTheDayAfterTomorrowNeverGoesToTheMirror() async throws {
    let today = DateOnly(year: 2026, month: 10, day: 14)
    let bank = ScriptedBank(official: .failure(down), mirror: .rates(today))
    let later = DateOnly(year: 2026, month: 10, day: 16)
    do {
      _ = try await client(bank, today: today).dailyRates(on: later)
      XCTFail("a day two ahead was answered")
    } catch {}
    let requests = await bank.requests
    XCTAssertEqual(requests.count, 1)
  }

  /// On the last day of a year the first day of the next one is tomorrow.
  func testTheFirstOfJanuaryIsTomorrowOnNewYearsEve() async throws {
    let today = DateOnly(year: 2026, month: 12, day: 31)
    let first = DateOnly(year: 2027, month: 1, day: 1)
    let bank = ScriptedBank(official: .failure(down), mirror: .rates(first))
    let snapshot = try await client(bank, today: today).dailyRates(on: first)
    XCTAssertEqual(snapshot.date, first)
  }

  /// In a leap year the day after 28 February is the 29th, not the 1st of March.
  func testTheLeapDayIsTomorrowOnTheTwentyEighth() async throws {
    let today = DateOnly(year: 2028, month: 2, day: 28)
    let leap = DateOnly(year: 2028, month: 2, day: 29)
    let bank = ScriptedBank(official: .failure(down), mirror: .rates(leap))
    _ = try await client(bank, today: today).dailyRates(on: leap)
    let march = ScriptedBank(official: .failure(down), mirror: .rates(today))
    do {
      _ = try await client(march, today: today).dailyRates(
        on: DateOnly(year: 2028, month: 3, day: 1))
      XCTFail("the 1st of March was taken for tomorrow in a leap year")
    } catch {}
    let requests = await march.requests
    XCTAssertEqual(requests, ["official 2028-03-01"])
  }

  /// From the evening on, the mirror's latest day is already tomorrow: no answer for today.
  func testTheMirrorsNextDayIsNoAnswerForToday() async throws {
    let today = DateOnly(year: 2026, month: 10, day: 14)
    let bank = ScriptedBank(
      official: .failure(down), mirror: .rates(DateOnly(year: 2026, month: 10, day: 15)))
    do {
      _ = try await client(bank, today: today).dailyRates(on: today)
      XCTFail("tomorrow's rates were taken for today")
    } catch {
      XCTAssertEqual(error as? RateFetchError, .unavailable(status: nil))
    }
  }

  /// A mirror that still has the day before is handed over as that day's rates.
  func testTheMirrorsEarlierDayIsHandedOverAsItsDay() async throws {
    let today = DateOnly(year: 2026, month: 10, day: 14)
    let earlier = DateOnly(year: 2026, month: 10, day: 13)
    let bank = ScriptedBank(official: .failure(down), mirror: .rates(earlier))
    let snapshot = try await client(bank, today: today).dailyRates(on: today)
    XCTAssertEqual(snapshot.date, earlier)
  }

  func testAMirrorThatFailsTooFailsWithItsOwnError() async throws {
    let today = DateOnly(year: 2026, month: 10, day: 14)
    let bank = ScriptedBank(
      official: .failure(down), mirror: .failure(RateFetchError.unavailable(status: 502)))
    do {
      _ = try await client(bank, today: today).dailyRates(on: today)
      XCTFail("nobody answered, yet there were rates")
    } catch {
      XCTAssertEqual(error as? RateFetchError, .unavailable(status: 502))
    }
  }

  func testACancelledRequestNeverReachesTheMirror() async throws {
    let today = DateOnly(year: 2026, month: 10, day: 14)
    for cancelled in [CancellationError() as any Error, URLError(.cancelled)] {
      let bank = ScriptedBank(official: .failure(cancelled), mirror: .rates(today))
      do {
        _ = try await client(bank, today: today).dailyRates(on: today)
        XCTFail("a cancelled request returned rates")
      } catch {
        XCTAssertTrue(error is CancellationError, "\(error)")
      }
      let requests = await bank.requests
      XCTAssertEqual(requests, ["official 2026-10-14"])
    }
  }

  /// A timeout or a lost connection is a failure, not a cancellation: the mirror is asked.
  func testATimeoutGoesToTheMirror() async throws {
    let today = DateOnly(year: 2026, month: 10, day: 14)
    for failure in [URLError(.timedOut), URLError(.notConnectedToInternet)] {
      let bank = ScriptedBank(official: .failure(failure), mirror: .rates(today))
      let snapshot = try await client(bank, today: today).dailyRates(on: today)
      XCTAssertEqual(snapshot.source, .cbrMirror, "\(failure.code)")
    }
  }
}

/// One answer of the bank, as its bytes arrive: a status other than 200, an answer that is no
/// HTTP at all, the bank's XML in its own encoding with a nominal of a hundred, the mirror's JSON.
final class DataScenarioBankAnswerTests: XCTestCase {
  private let url = URL(string: "https://www.cbr.ru/scripts/XML_daily.asp")!

  private func response(_ status: Int) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
  }

  func testAStatusOtherThan200IsKept() {
    for status in [301, 403, 404, 429, 500, 503] {
      XCTAssertThrowsError(
        try CBRClient.snapshot(from: Data(), response: response(status), source: .official)
      ) {
        XCTAssertEqual($0 as? RateFetchError, .unavailable(status: status))
      }
    }
  }

  func testAnAnswerThatIsNoHTTPIsUnavailable() {
    let plain = URLResponse(
      url: url, mimeType: nil, expectedContentLength: 0, textEncodingName: nil)
    XCTAssertThrowsError(try CBRClient.snapshot(from: Data(), response: plain, source: .mirror)) {
      XCTAssertEqual($0 as? RateFetchError, .unavailable(status: nil))
    }
  }

  /// The bank writes its XML in windows-1251, with Russian names of the currencies.
  func testTheBanksDocumentInItsOwnEncodingIsRead() throws {
    let document = """
      <?xml version="1.0" encoding="windows-1251"?>
      <ValCurs Date="31.12.2026" name="Foreign Currency Market">
      <Valute ID="R01235"><NumCode>840</NumCode><CharCode>USD</CharCode><Nominal>1</Nominal>\
      <Name>Доллар США</Name><Value>90,1234</Value></Valute>
      <Valute ID="R01820"><NumCode>392</NumCode><CharCode>JPY</CharCode><Nominal>100</Nominal>\
      <Name>Японских иен</Name><Value>58,5000</Value></Valute>
      </ValCurs>
      """
    let data = try XCTUnwrap(document.data(using: .windowsCP1251))
    let snapshot = try CBRClient.snapshot(from: data, response: response(200), source: .official)
    XCTAssertEqual(snapshot.date, DateOnly(year: 2026, month: 12, day: 31))
    XCTAssertEqual(snapshot.rates[.usd]?.perUnit, Decimal(string: "90.1234"))
    let yen = try XCTUnwrap(snapshot.rates[CurrencyCode("JPY")])
    XCTAssertEqual(yen.nominal, 100)
    XCTAssertEqual(yen.perUnit, Decimal(string: "0.585"))
  }

  func testTheMirrorsJSONIsRead() throws {
    let json = """
      {"Date": "2026-10-14T11:30:00+03:00", "Valute": {
        "USD": {"CharCode": "USD", "Nominal": 1, "Value": 81.25},
        "KZT": {"CharCode": "KZT", "Nominal": 100, "Value": 16.5}
      }}
      """
    let snapshot = try CBRClient.snapshot(
      from: Data(json.utf8), response: response(200), source: .mirror)
    XCTAssertEqual(snapshot.source, .cbrMirror)
    XCTAssertEqual(snapshot.date, DateOnly(year: 2026, month: 10, day: 14))
    XCTAssertEqual(snapshot.rates[CurrencyCode("KZT")]?.perUnit, Decimal(string: "0.165"))
  }

  /// A rate of zero from the mirror fails the whole answer rather than being applied.
  func testAMirrorRateOfZeroIsRefused() {
    let json = """
      {"Date": "2026-10-14T11:30:00+03:00", "Valute": {
        "USD": {"CharCode": "USD", "Nominal": 1, "Value": 0}}}
      """
    XCTAssertThrowsError(
      try CBRClient.snapshot(from: Data(json.utf8), response: response(200), source: .mirror))
  }

  func testBrokenXMLIsNoAnswer() {
    XCTAssertThrowsError(
      try CBRClient.snapshot(
        from: Data("<html>maintenance</html>".utf8), response: response(200), source: .official))
  }

  func testWhatIsACancellation() {
    XCTAssertTrue(CBRClient.isCancellation(CancellationError()))
    XCTAssertTrue(CBRClient.isCancellation(URLError(.cancelled)))
    XCTAssertFalse(CBRClient.isCancellation(URLError(.timedOut)))
    XCTAssertFalse(CBRClient.isCancellation(RateFetchError.outOfTime))
  }
}

/// The rate service in front of the cache: rubles need no rate, a rate typed by hand is the
/// rate of its day, a currency of the owner's own is never asked of the bank, and a closed
/// service asks nothing.
final class DataScenarioRateServiceTests: XCTestCase {
  private actor CountingBank: RatesFetching {
    private(set) var days: [DateOnly] = []
    func dailyRates(on day: DateOnly) async throws -> RateSnapshot {
      days.append(day)
      return RateSnapshot(
        date: day,
        rates: [.usd: Rate(date: day, currency: .usd, rubPerUnit: Decimal(string: "99")!)],
        source: .cbr)
    }
  }

  private func repository() throws -> RateRepository {
    RateRepository(writer: try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main)).writer)
  }

  private let day = DateOnly(year: 2026, month: 10, day: 14)

  func testRublesNeedNoRate() async throws {
    let bank = CountingBank()
    let service = RateService(repository: try repository(), client: bank, today: { [day] in day })
    let rate = await service.rate(for: .rub, on: day)
    XCTAssertNil(rate)
    let asked = await bank.days
    XCTAssertEqual(asked, [])
  }

  /// A rate typed by hand for the day is the rate of the day: the bank is not asked over it.
  func testARateTypedByHandIsNotAskedOver() async throws {
    let rates = try repository()
    try rates.save([
      Rate(date: day, currency: .usd, rubPerUnit: Decimal(string: "77.7")!, source: .manual)
    ])
    let bank = CountingBank()
    let service = RateService(repository: rates, client: bank, today: { [day] in day })
    let rate = await service.rate(for: .usd, on: day)
    XCTAssertEqual(rate?.rubPerUnit, Decimal(string: "77.7"))
    XCTAssertEqual(rate?.source, .manual)
    await service.refresh(day: day, currency: .usd)
    let asked = await bank.days
    XCTAssertEqual(asked, [])
    XCTAssertEqual(try rates.rate(for: .usd, on: day)?.source, .manual)
  }

  /// A day without a rate is asked once and kept.
  func testAMissingDayIsAskedAndKept() async throws {
    let rates = try repository()
    let bank = CountingBank()
    let service = RateService(repository: rates, client: bank, today: { [day] in day })
    let rate = await service.rate(for: .usd, on: day)
    XCTAssertEqual(rate?.rubPerUnit, Decimal(string: "99"))
    _ = await service.rate(for: .usd, on: day)
    let asked = await bank.days
    XCTAssertEqual(asked, [day])
  }

  func testACurrencyOfTheOwnersOwnIsNeverAsked() async throws {
    let bank = CountingBank()
    let service = RateService(repository: try repository(), client: bank, today: { [day] in day })
    await service.refresh(day: day, currency: CurrencyCode("MIL"))
    let rate = await service.rate(for: CurrencyCode("MIL"), on: day)
    XCTAssertNil(rate)
    let asked = await bank.days
    XCTAssertEqual(asked, [])
    XCTAssertFalse(RateTable.isAskedOfTheBank(CurrencyCode("MIL")))
    XCTAssertTrue(RateTable.isAskedOfTheBank(.usd))
  }

  func testAClosedServiceAsksNothing() async throws {
    let bank = CountingBank()
    let service = RateService(repository: try repository(), client: bank, today: { [day] in day })
    await service.close()
    await service.refresh(day: day, currency: .usd)
    let asked = await bank.days
    XCTAssertEqual(asked, [])
    let closed = await service.isClosed
    XCTAssertTrue(closed)
  }
}
