import AppCore
import Foundation

/// The words the preview of Finder shows for an archive of OhMyMoney (space bar on the file): what
/// `ArchivePeek` read from its first bytes — the day it was made, the version that made it, how
/// many operations it carries — or «Зашифровано» for a file with a password. The app and its
/// Quick Look extension share this file, so the two say the same; the extension has no settings
/// of the app, so it speaks the language of the system.
struct ArchivePreviewText: Equatable {
  let title: String
  let lines: [String]

  /// `text` looks a key up in the catalog `MacFeatures`; `locale` writes the day.
  static func make(
    _ result: ArchivePeek.Result, locale: Locale, text: (String) -> String
  ) -> ArchivePreviewText {
    let title = text("mac.quicklook.title")
    switch result {
    case .encrypted:
      return ArchivePreviewText(
        title: title, lines: [text("mac.quicklook.encrypted"), text("mac.quicklook.encryptedHint")])
    case .unreadable:
      return ArchivePreviewText(title: title, lines: [text("mac.quicklook.unreadable")])
    case .plain(let facts):
      var lines = [
        format(text("mac.quicklook.created"), locale, day(facts.createdAt, locale: locale)),
        format(text("mac.quicklook.version"), locale, facts.appVersion),
      ]
      if let operations = facts.operations {
        lines.append(
          format(text("mac.quicklook.operations"), locale, NumberText.grouped(String(operations))))
      } else {
        lines.append(
          format(text("mac.quicklook.tables"), locale, NumberText.grouped(String(facts.tables))))
      }
      return ArchivePreviewText(title: title, lines: lines)
    }
  }

  private static func format(_ pattern: String, _ locale: Locale, _ value: String) -> String {
    String(format: pattern, locale: locale, value)
  }

  /// «1 ноября 2026», «November 1, 2026».
  static func day(_ day: DateOnly, locale: Locale) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
    let date = calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day))
    let formatter = DateFormatter()
    formatter.locale = locale
    formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone
    formatter.setLocalizedDateFormatFromTemplate("d MMMM y")
    return date.map(formatter.string(from:)) ?? day.iso
  }

  /// Reads the start of the file at `url` — never the whole of an archive that may be gigabytes.
  static func peek(at url: URL) -> ArchivePeek.Result {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return .unreadable }
    defer { try? handle.close() }
    let data = (try? handle.read(upToCount: ArchivePeek.prefixByteCount)) ?? Data()
    return ArchivePeek.read(prefix: data)
  }
}
