import Foundation

/// One event — one line. The only thing that may run to several lines is the stack of an
/// error.
public struct LogEvent: Hashable, Sendable {
  public var at: Date
  public var level: LogLevel
  public var category: LogCategory
  /// What happened, from the vocabulary written in the code: `pipeline.step`,
  /// `backup.written`, `session.interrupted`.
  public var name: String
  /// A short sentence of ours. Never a value of the owner's: those go in `pairs`, typed.
  public var message: String
  public var pairs: [LogPair]
  /// The stack of an error, the one thing that may be multi-line: the frames of
  /// `Thread.callStackSymbols`, one per line. Never a description of the error — a line that
  /// is not a frame is written as `<not-a-frame>` (`LogValue.isFrame`).
  public var failure: String?

  public init(
    at: Date, level: LogLevel, category: LogCategory, name: String, message: String,
    pairs: [LogPair] = [], failure: String? = nil
  ) {
    self.at = at
    self.level = level
    self.category = category
    self.name = name
    self.message = message
    self.pairs = pairs
    self.failure = failure
  }
}

/// Turns an event into the line that goes on disk.
///
///     2026-09-20T14:31:02.123+03:00 error db migration.failed "the migration did not finish" from=1 to=2 ms=412
///
/// The message is quoted so that the line can be read back apart: everything before the quote
/// is fixed in width and meaning, everything after the closing quote is `key=value`.
public enum LogLine {
  public static func text(of event: LogEvent, timeZone: TimeZone = .current) -> String {
    var line = stamp(event.at, in: timeZone)
    line += " \(event.level.rawValue) \(event.category.rawValue)"
    line += " \(LogValue.isToken(event.name) ? event.name : "<not-a-name>")"
    line += " \"\(escaped(event.message))\""
    for pair in event.pairs { line += " \(pair.text)" }
    guard let failure = event.failure, !failure.isEmpty else { return line }
    // The stack goes under the line, indented, so a reader can tell it from the next event.
    // Frame by frame: the one field that is not a pair is held to a rule all the same.
    let frames = failure.split(separator: "\n").map { frame in
      "    " + (LogValue.isFrame(String(frame)) ? String(frame) : "<not-a-frame>")
    }
    return line + "\n" + frames.joined(separator: "\n")
  }

  /// ISO 8601 with milliseconds and the offset, written by hand: `ISO8601DateFormatter` has
  /// no thousandths together with the offset on every platform this has to build for.
  public static func stamp(_ date: Date, in timeZone: TimeZone) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let parts = calendar.dateComponents(
      [.year, .month, .day, .hour, .minute, .second, .nanosecond], from: date)
    let offset = timeZone.secondsFromGMT(for: date)
    let sign = offset < 0 ? "-" : "+"
    let minutes = abs(offset) / 60
    // Numbers only in the formats: the sign is joined as a string, not passed as `%@`, which
    // on Linux rests on Foundation bridging a Swift `String` to an object.
    let moment = String(
      format: "%04d-%02d-%02dT%02d:%02d:%02d.%03d",
      parts.year ?? 0, parts.month ?? 0, parts.day ?? 0, parts.hour ?? 0, parts.minute ?? 0,
      parts.second ?? 0, (parts.nanosecond ?? 0) / 1_000_000)
    return moment + sign + String(format: "%02d:%02d", minutes / 60, minutes % 60)
  }

  /// A quote or a line break in our own message would break the line apart; nothing else
  /// can. Every kind of break is a space: `\n`, `\r` and `\r\n`, the vertical tab and form
  /// feed, and the Unicode separators — a reader splits on any of them.
  static func escaped(_ message: String) -> String {
    let quoted =
      message
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
    return String(quoted.map { $0.isNewline ? " " : $0 })
  }
}
