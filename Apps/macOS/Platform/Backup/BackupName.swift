import Foundation

/// The name a copy of the database is given from 1.12: `2026-10-06 23.32 · 1.12.0 · после правки.sqlite`
/// — the local date and time first (Finder sorts by name, which is by time), the version of the
/// app that wrote it, and in words why the copy was made. Names written before 1.12
/// (`finance-2026-10-06T233200+0300.sqlite`) are never renamed and are read as before
/// (`BackupService.date(in:)`); this type reads and writes only the new kind.
///
/// The words of the reason are the interface language of the moment the copy was made, so they
/// come in from the caller: `words` to write one, and every known wording of every language
/// to read one. Restoring reads the date and the reason, never the words themselves.
struct BackupName: Equatable, Sendable {
  enum Reason: Hashable, Sendable {
    /// Taken after a change of the data.
    case change
    /// Taken once a day, with a readable copy beside it.
    case daily
    /// Taken before the schema of the database is migrated up to `schema`.
    case beforeMigration(to: String?)
    case beforeRestore
    case beforeImport
    /// Taken before «Исправить» removes the rows the check found to be orphans.
    case beforeRepair
  }

  /// What the words of a name say: a reason, or that the copy failed its check.
  enum Word: Hashable, Sendable {
    case reason(Reason)
    case damaged
  }

  var moment: Date
  var appVersion: String
  var reason: Reason
  /// The copy was kept although it failed its check.
  var damaged = false
  /// 2, 3… when another copy of the same minute and reason already stood in the folder.
  var duplicate = 1

  static let separator = " · "
  static let fileExtension = "sqlite"

  /// Characters a name must not hold on any file system a folder of copies may sit on.
  private static let forbidden = CharacterSet(charactersIn: "/:\\\0")

  // MARK: Writing

  func fileName(in zone: TimeZone = .current, words: (Word) -> String) -> String {
    var parts = [Self.stamp(of: moment, in: zone), Self.clean(appVersion)]
    var reasonText = Self.clean(words(.reason(reason)))
    if damaged { reasonText += " (" + Self.clean(words(.damaged)) + ")" }
    if duplicate > 1 { reasonText += " (\(duplicate))" }
    parts.append(reasonText)
    return parts.joined(separator: Self.separator) + "." + Self.fileExtension
  }

  /// `2026-10-06 23.32`: no colon, which a file name may not hold.
  static func stamp(of moment: Date, in zone: TimeZone) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: moment)
    return String(
      format: "%04d-%02d-%02d %02d.%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0,
      c.minute ?? 0)
  }

  private static func clean(_ text: String) -> String {
    String(
      String.UnicodeScalarView(text.unicodeScalars.filter { !forbidden.contains($0) })
    ).trimmingCharacters(in: .whitespaces)
  }

  // MARK: Reading

  /// The name read back, or nil when it is not of this kind. `wordings` is every way each
  /// reason is worded, in every language; the longest wording that begins the reason text
  /// wins, so «перед обновлением до 10» is `beforeMigration(to: "10")`.
  static func parse(
    _ fileName: String, in zone: TimeZone = .current, wordings: [(Word, String)]
  ) -> BackupName? {
    let suffix = "." + fileExtension
    guard fileName.hasSuffix(suffix) else { return nil }
    let base = String(fileName.dropLast(suffix.count))
    let fields = base.components(separatedBy: separator)
    guard fields.count == 3, let moment = moment(of: fields[0], in: zone) else { return nil }
    var text = fields[2]
    var result = BackupName(moment: moment, appVersion: fields[1], reason: .change)
    if let (stripped, number) = trailingNumber(of: text) {
      text = stripped
      result.duplicate = number
    }
    let marks = wordings.filter { $0.0 == .damaged }.map(\.1)
    for mark in marks where text.hasSuffix(" (" + mark + ")") {
      text = String(text.dropLast(mark.count + 3))
      result.damaged = true
      break
    }
    let candidates = wordings.compactMap { entry -> (Reason, String)? in
      guard case .reason(let reason) = entry.0, text.hasPrefix(entry.1) else { return nil }
      return (reason, entry.1)
    }.sorted { $0.1.count > $1.1.count }
    guard let (reason, words) = candidates.first else { return nil }
    result.reason = reason
    if case .beforeMigration = reason {
      // «… до 10» / «… to 10»: the connecting word is the language's, the schema is the last word.
      let tail = text.dropFirst(words.count).split(separator: " ").last.map(String.init)
      result.reason = .beforeMigration(to: tail)
    } else if text != words {
      return nil
    }
    return result
  }

  private static func moment(of stamp: String, in zone: TimeZone) -> Date? {
    let halves = stamp.split(separator: " ")
    guard halves.count == 2 else { return nil }
    let day = halves[0].split(separator: "-").compactMap { Int($0) }
    let time = halves[1].split(separator: ".").compactMap { Int($0) }
    guard day.count == 3, time.count == 2 else { return nil }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    let parts = DateComponents(
      year: day[0], month: day[1], day: day[2], hour: time[0], minute: time[1])
    guard let date = calendar.date(from: parts),
      calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        == parts
        .withCalendarFields
    else { return nil }
    return date
  }

  private static func trailingNumber(of text: String) -> (String, Int)? {
    guard text.hasSuffix(")"), let open = text.lastIndex(of: "(") else { return nil }
    let inside = text[text.index(after: open)..<text.index(before: text.endIndex)]
    guard let number = Int(inside), number >= 2, open > text.startIndex else { return nil }
    return (String(text[..<open]).trimmingCharacters(in: .whitespaces), number)
  }
}

private extension DateComponents {
  var withCalendarFields: DateComponents {
    DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
  }
}
