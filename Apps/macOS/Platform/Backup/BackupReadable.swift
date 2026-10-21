import AppCore
import AppDatabase
import Foundation

/// The readable version beside a copy: a folder with the name of the copy (without `.sqlite`)
/// that holds the files of «Экспорт» and a `README.txt`. Only the copy of the day and the copy
/// written before an update have one; it lies on this Mac alone and never in the mirrored folder
/// (the mirror gets the `.sqlite` only).
enum BackupReadable {
  /// The folder of the readable version of the copy at `copy`.
  static func folder(forCopyAt copy: URL) -> URL {
    copy.deletingPathExtension()
  }

  /// The copies that have a readable version: the day's and the one before an update.
  static func isKept(for reason: BackupName.Reason) -> Bool {
    switch reason {
    case .daily, .beforeMigration: true
    case .change, .beforeRestore, .beforeImport, .beforeRepair: false
    }
  }

  /// The suffix of a folder that is still being written.
  static let unfinished = ".readable-partial"

  /// Whether the copy has its readable folder already.
  static func exists(forCopyAt copy: URL) -> Bool {
    var isFolder: ObjCBool = false
    return FileManager.default.fileExists(
      atPath: folder(forCopyAt: copy).path, isDirectory: &isFolder) && isFolder.boolValue
  }

  /// Writes the readable version of the copy: into a folder no list shows, put in place by one
  /// rename once whole. Returns whether it is there afterwards; a failure is in the journal and
  /// costs the copy nothing.
  @discardableResult
  static func write(forCopyAt copy: URL, schema: any SchemaSource) -> Bool {
    let manager = FileManager.default
    let target = folder(forCopyAt: copy)
    let partial = URL(fileURLWithPath: target.path + unfinished, isDirectory: true)
    do {
      try? manager.removeItem(at: partial)
      try manager.createDirectory(at: partial, withIntermediateDirectories: true)
      for table in try ReadableCopy.tables(ofFileAt: copy, schema: schema) {
        try table.data.write(to: partial.appendingPathComponent(table.fileName))
      }
      try Data(readme.utf8).write(to: partial.appendingPathComponent("README.txt"))
      try? manager.removeItem(at: target)
      try manager.moveItem(at: partial, to: target)
      return true
    } catch {
      try? manager.removeItem(at: partial)
      AppLog.warning(
        "backup.readableFailed", .backup, "the readable version of a copy was not written",
        [LogPair("error", .error(error))])
      return false
    }
  }

  /// What the folder says of itself — in Russian and in English in one file.
  static let readme = """
    OhMyMoney — читаемая версия копии базы
    ================================

    По-русски
    ---------
    Это читаемая версия резервной копии. Рядом лежит файл с таким же именем и расширением
    .sqlite — это сама копия: из неё приложение восстанавливает данные («Настройки → Бэкапы →
    Восстановить»). Эта папка нужна, чтобы просто посмотреть данные глазами или разобрать их
    своими скриптами. Из неё приложение ничего не восстанавливает.

    Внутри — таблицы в формате CSV, тот же, что у «Файл → Экспорт»: кодировка UTF-8, первая строка —
    названия столбцов, суммы — десятичные числа с точкой, даты — ISO 8601, пустое поле — нет
    значения. Файл открывается в Numbers, Excel и в pandas без параметров:

        import pandas
        pandas.read_csv("transactions.csv")

    Если копия сделана перед обновлением приложения, её база старше нынешней схемы: в такой папке
    нет таблиц и столбцов, которых в той копии ещё не было.

    Эта папка лежит только на этом Mac. В папку iCloud Drive (если вы её выбрали для копий)
    попадает только файл .sqlite — открыто, без шифрования.

    English
    -------
    This is the readable version of a backup of the database. Beside it lies the file with the
    same name ending in .sqlite — that is the backup itself, the one the app restores from
    (Settings → Backups → Restore). This folder is for looking at your data or reading it with
    your own scripts. The app does not restore from it.

    The files are CSV, the same as File → Export: UTF-8, the first row holds the column names,
    amounts are decimal numbers with a dot, dates are ISO 8601, an empty field means no value.
    They open in Numbers, Excel and pandas with no options:

        import pandas
        pandas.read_csv("transactions.csv")

    A backup made before an update of the app has an older schema than today's: a folder like
    that has no tables and no columns the backup did not have yet.

    This folder lives on this Mac only. A folder in iCloud Drive (if you chose one for backups)
    receives the .sqlite file alone — in the open, not encrypted.
    """
}
