import Foundation

/// The words a copy's name is written in — one language at the moment it is made — and every
/// wording of every language, to read a name back whatever language it was written in.
/// They are keys of the Settings catalog (`backups.name.*`).
enum BackupWords {
  /// The languages a name may have been written in.
  static let languages = ["ru", "en"]

  /// The words of the name in the language `code` (two letters); anything but Russian is English.
  static func writer(code: String) -> (BackupName.Word) -> String {
    let language = code.hasPrefix("ru") ? "ru" : "en"
    return { word in text(of: word, in: language) }
  }

  /// The language of the interface as the owner stored it, readable off the main thread.
  static var interfaceCode: String { AppLanguage.storedCode(in: .standard) }

  /// Every wording in every language the app has; the reader takes the longest one that fits.
  static let wordings: [(BackupName.Word, String)] = {
    let words: [BackupName.Word] = [
      .reason(.change), .reason(.daily), .reason(.beforeMigration(to: nil)),
      .reason(.beforeRestore), .reason(.beforeImport), .reason(.beforeRepair), .damaged,
    ]
    return words.flatMap { word in languages.map { (word, text(of: word, in: $0)) } }
  }()

  static func text(of word: BackupName.Word, in language: String) -> String {
    switch word {
    case .reason(.change): string("backups.name.change", language)
    case .reason(.daily): string("backups.name.daily", language)
    case .reason(.beforeMigration(let target)):
      if let target {
        String(format: string("backups.name.beforeMigration.to", language), target)
      } else {
        string("backups.name.beforeMigration", language)
      }
    case .reason(.beforeRestore): string("backups.name.beforeRestore", language)
    case .reason(.beforeImport): string("backups.name.beforeImport", language)
    case .reason(.beforeRepair): string("backups.name.beforeRepair", language)
    case .damaged: string("backups.name.damaged", language)
    }
  }

  private static func string(_ key: String, _ language: String) -> String {
    let bundle =
      Bundle.main.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:))
      ?? .main
    return bundle.localizedString(forKey: key, value: key, table: "Settings")
  }
}

/// Any file name of a copy of the database, read: the moment it was taken, why, and whether it
/// failed its check. The one place that knows the two kinds of names —
///
/// * `finance-2026-10-06T233200+0300-before-migration.sqlite`, written until 1.11 (names
///   without an offset are older still and read as local time) — never renamed;
/// * `2026-10-06 23.32 · 1.12.0 · после правки.sqlite` (`BackupName`), written from 1.12.
///
/// — so that old and new copies lie in one folder, are ordered by their moment and kept or
/// pruned by one rule. A name that is neither is not a copy of ours and is never touched.
struct BackupCopy: Equatable, Sendable {
  var fileName: String
  var moment: Date
  /// The local calendar day written in the name, `YYYY-MM-DD`.
  var day: String
  var reason: BackupName.Reason
  var damaged: Bool
  /// 2, 3… of the new kind when copies of one minute and reason share a folder.
  var duplicate: Int
  /// The name is of the kind written before 1.12.
  var isLegacy: Bool

  /// The copy written before an update, which no rotation ever prunes.
  var isBeforeMigration: Bool {
    if case .beforeMigration = reason { return true }
    return false
  }

  static func parse(
    _ fileName: String, in zone: TimeZone = .current,
    wordings: [(BackupName.Word, String)] = BackupWords.wordings
  ) -> BackupCopy? {
    if let legacy = parseLegacy(fileName, in: zone) { return legacy }
    guard let name = BackupName.parse(fileName, in: zone, wordings: wordings) else { return nil }
    return BackupCopy(
      fileName: fileName, moment: name.moment,
      day: String(BackupName.stamp(of: name.moment, in: zone).prefix(10)), reason: name.reason,
      damaged: name.damaged, duplicate: name.duplicate, isLegacy: false)
  }

  private static let stampFormat = "yyyy-MM-dd'T'HHmmss"

  private static func parseLegacy(_ fileName: String, in zone: TimeZone) -> BackupCopy? {
    guard fileName.hasPrefix("finance-"), fileName.hasSuffix(".sqlite"), fileName.count > 18
    else { return nil }
    let rest = fileName.dropFirst(8)
    let stamp = String(rest.prefix(17))
    let offset = rest.dropFirst(17).prefix(5)
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    var tail = rest.dropFirst(17)
    let moment: Date?
    if offset.count == 5, let sign = offset.first, sign == "+" || sign == "-",
      offset.dropFirst().allSatisfy({ $0.isASCII && $0.isNumber })
    {
      formatter.dateFormat = stampFormat + "Z"
      moment = formatter.date(from: stamp + offset)
      tail = tail.dropFirst(5)
    } else {
      formatter.timeZone = zone
      formatter.dateFormat = stampFormat
      moment = formatter.date(from: stamp)
    }
    guard let moment else { return nil }
    let label = tail.dropLast(".sqlite".count)
    let reason: BackupName.Reason =
      label.contains("-before-migration")
      ? .beforeMigration(to: nil)
      : label.contains("-before-restore")
        ? .beforeRestore : label.contains("-before-import") ? .beforeImport : .change
    return BackupCopy(
      fileName: fileName, moment: moment, day: String(rest.prefix(10)), reason: reason,
      damaged: label.hasSuffix("-damaged"), duplicate: 1, isLegacy: true)
  }

  /// Newest first by the moment the copies were taken; of one moment the later duplicate, then
  /// the name, decides.
  static func newerFirst(_ left: BackupCopy, _ right: BackupCopy) -> Bool {
    if left.moment != right.moment { return left.moment > right.moment }
    if left.duplicate != right.duplicate { return left.duplicate > right.duplicate }
    return left.fileName > right.fileName
  }
}
