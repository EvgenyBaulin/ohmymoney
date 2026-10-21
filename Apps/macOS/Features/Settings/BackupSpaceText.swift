import AppCore
import Foundation

/// The words of the two questions the Backups tab asks before it deletes copies — «Освободить
/// место» and «Удалить старше года» — and of what it says about the room the copies have. The
/// list in a question is the list that is deleted after «Да»: nothing is worked out again.
enum BackupSpaceText {
  static let table = "Settings"

  /// How many names a question lists before «…и ещё N».
  static let namesShown = 12

  /// «Будут удалены 3 копии, 12 МБ:» and the names under it.
  @MainActor
  static func freeUpMessage(_ plan: BackupSpace.Plan, in environment: AppEnvironment) -> String {
    guard !plan.isEmpty else { return environment.language("backups.freeUp.nothing", table: table) }
    var text = intro("backups.freeUp.intro", plan.removals, in: environment)
    text += "\n" + names(plan.removals, in: environment)
    if plan.staysLow {
      text += "\n\n" + environment.language("backups.freeUp.stillLow", table: table)
    }
    return text
  }

  /// The question of «Удалить старше года…», or that there is nothing of the kind.
  @MainActor
  static func oldUpdatesMessage(
    _ entries: [BackupEntry], in environment: AppEnvironment
  )
    -> String
  {
    guard !entries.isEmpty else {
      return environment.language("backups.beforeUpdate.none", table: table)
    }
    return intro("backups.beforeUpdate.confirmIntro", entries, in: environment) + "\n"
      + names(entries, in: environment) + "\n\n"
      + environment.language("backups.beforeUpdate.newestStays", table: table)
  }

  /// «Копий «перед обновлением»: 4 · 38 МБ · хранятся всегда».
  @MainActor
  static func beforeUpdateTotal(
    count: Int, bytes: Int64, in environment: AppEnvironment
  )
    -> String
  {
    environment.format("backups.beforeUpdate.total", table: table, counts: count) + " · "
      + size(bytes) + " · " + environment.language("backups.beforeUpdate.keptForever", table: table)
  }

  /// «Мало места для копий: свободно 640 МБ. Ничего не удаляется само.»
  @MainActor
  static func low(freeBytes: Int64, in environment: AppEnvironment) -> String {
    environment.format("backups.space.low", table: table, size(freeBytes))
  }

  static func size(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
  }

  @MainActor
  private static func intro(
    _ key: String, _ entries: [BackupEntry], in environment: AppEnvironment
  )
    -> String
  {
    environment.format(key, table: table, counts: entries.count) + ", "
      + size(entries.reduce(0) { $0 + $1.bytes }) + ":"
  }

  @MainActor
  private static func names(_ entries: [BackupEntry], in environment: AppEnvironment) -> String {
    var lines = entries.prefix(namesShown).map { "• " + $0.id }
    if entries.count > namesShown {
      lines.append(
        environment.format("backups.freeUp.more", table: table, counts: entries.count - namesShown))
    }
    return lines.joined(separator: "\n")
  }
}
