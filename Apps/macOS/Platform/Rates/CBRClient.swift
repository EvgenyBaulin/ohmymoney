import AppCore
import Foundation

/// Reads the official daily rates of the Bank of Russia.
///
/// The rules: the rate is taken for the day of the operation; a day that is already cached is
/// never requested again, because the bank blocks addresses that ask too often; the mirror is
/// used only when the main source is unavailable — and only for today, because it always
/// answers with its latest day whatever day was asked, and only while that latest day is not
/// after the day asked. «Today» is Moscow's or the day after it: east of Moscow the owner's
/// day turns first, and from the evening on the mirror already serves that day. A cancelled
/// request is a cancellation, never a reason to try the mirror.
public struct CBRClient: Sendable, RatesFetching {
  public enum Source: Sendable {
    case official
    case mirror
  }

  /// One request to one source.
  typealias Fetch = @Sendable (Source, DateOnly) async throws -> RateSnapshot

  private let fetch: Fetch
  private let today: @Sendable () -> DateOnly

  /// Ten seconds per request, nothing kept on disk: the rates are cached in the database.
  public init(
    session: URLSession = CBRClient.makeSession(), clock: any CoreKit.Clock = SystemClock()
  ) {
    self.init(
      fetch: { source, day in try await Self.download(day, from: source, session: session) },
      today: { CalendarContext.moscow.day(of: clock.now) })
  }

  /// With the network replaced, for tests.
  init(fetch: @escaping Fetch, today: @escaping @Sendable () -> DateOnly) {
    self.fetch = fetch
    self.today = today
  }

  public static func makeSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 10
    return URLSession(configuration: configuration)
  }

  public func dailyRates(on day: DateOnly) async throws -> RateSnapshot {
    do {
      return try await fetch(.official, day)
    } catch {
      if Self.isCancellation(error) { throw CancellationError() }
      // The mirror is a fallback, never the default: it is somebody else's copy, and it
      // only knows its latest day. For a day in the past it would hand over a wrong rate.
      // An operation's day is the owner's, in the system calendar; east of Moscow it may
      // already be Moscow's tomorrow.
      let moscowToday = today()
      guard day == moscowToday || day == CalendarContext.moscow.adding(days: 1, to: moscowToday)
      else { throw error }
      AppLog.info(
        "rates.mirror", .rates, "the bank did not answer, asking the mirror",
        [LogPair("day", .token(day.iso)), LogPair("source", .token("mirror"))]
          + RateFetchError.logPairs(of: error))
      let snapshot: RateSnapshot
      do {
        snapshot = try await fetch(.mirror, day)
      } catch {
        if Self.isCancellation(error) { throw CancellationError() }
        throw error
      }
      // From the evening on, its latest day is already tomorrow: that is no answer for
      // today, which stays provisional and is asked for again on the next run. An earlier
      // day is stored as that day's rate and leaves the day asked provisional as well.
      guard snapshot.date <= day else { throw RateFetchError.unavailable(status: nil) }
      return snapshot
    }
  }

  /// URLSession reports a cancelled task as `URLError(.cancelled)`.
  static func isCancellation(_ error: any Error) -> Bool {
    error is CancellationError || (error as? URLError)?.code == .cancelled || Task.isCancelled
  }

  private static func download(
    _ day: DateOnly, from source: Source, session: URLSession
  ) async throws -> RateSnapshot {
    let (data, response) = try await session.data(from: url(for: day, source: source))
    return try snapshot(from: data, response: response, source: source)
  }

  /// What one answer holds. A status other than 200 is kept in the error, for the journal,
  /// and so is every currency the bank's document gave no usable rate for: the rest of the
  /// day is taken without it.
  static func snapshot(
    from data: Data, response: URLResponse, source: Source
  ) throws -> RateSnapshot {
    guard let http = response as? HTTPURLResponse else {
      throw RateFetchError.unavailable(status: nil)
    }
    guard http.statusCode == 200 else { throw RateFetchError.unavailable(status: http.statusCode) }
    switch source {
    case .official:
      let reading = try CBRDocumentParser.read(data, source: .cbr)
      for currency in reading.rejected {
        AppLog.warning(
          "rates.rejected", .rates, "a currency of the bank's document was left out",
          [
            LogPair("date", .token(reading.snapshot.date.iso)),
            LogPair("currency", .token(currency.code)),
            LogPair("source", .token(RateSource.cbr.rawValue)),
          ])
      }
      return reading.snapshot
    case .mirror:
      return try CBRMirrorParser.parse(data)
    }
  }

  private static func url(for day: DateOnly, source: Source) -> URL {
    switch source {
    case .official:
      let formatted = String(format: "%02d/%02d/%04d", day.day, day.month, day.year)
      return URL(string: "https://www.cbr.ru/scripts/XML_daily.asp?date_req=\(formatted)")!
    case .mirror:
      return URL(string: "https://www.cbr-xml-daily.ru/daily_json.js")!
    }
  }
}

public enum RateFetchError: Error, Sendable, Equatable {
  /// The source answered, but not with rates: an HTTP status other than 200, kept for the
  /// journal, or — from the mirror — a day other than the one asked (no status).
  case unavailable(status: Int?)
  /// The rate step used up its time (30 s per run) before the bank answered.
  case outOfTime

  /// What the journal may say about a failed request: the kind of error, the HTTP status the
  /// source answered with, or the code of a network error. Never a URL or a message.
  static func logPairs(of error: any Error) -> [LogPair] {
    if let network = error as? URLError {
      // A bridged URLError would otherwise call itself NSError.
      return [
        LogPair("error", .token("URLError")),
        LogPair("code", .token(String(network.code.rawValue))),
      ]
    }
    var pairs = [LogPair("error", .error(error))]
    if case .unavailable(let status?) = error as? RateFetchError {
      pairs.append(LogPair("status", .count(status)))
    }
    return pairs
  }
}
