import CoreKit
import Foundation

/// What happens to the files over time: the trash, and the receipt photos the owner chose not to
/// keep for good. Pure rules; the app reads the rows, asks here and carries the answer out.
public enum AttachmentRetention {
  /// A receipt photo stays this many days before it goes to the trash, when it is not kept
  /// for good.
  public static let receiptGraceDays = 7

  public enum Action: Equatable, Sendable {
    /// The file goes to the trash now; the clock of the trash starts at `at`.
    case moveToTrash(id: UUID, at: Date)
    /// The row and, when nothing else names it, the file are removed.
    case delete(id: UUID)
  }

  /// What is due at `now`, rows in the order given.
  ///
  /// - A row in the trash is deleted once it has been there `trashDays` days, whatever it is.
  /// - A receipt photo that is not kept for good (`keepReceiptsForever` off, `keepForever` off) goes
  ///   to the trash `receiptGraceDays` days after it was added. The clock of the trash starts when
  ///   the move is carried out, not when it was due: a Mac that was off for a month does not delete
  ///   a photo it never showed in the trash.
  /// - Everything else stays where it is.
  public static func actions(
    for attachments: [AttachedFile], settings: AttachmentSettings, now: Date
  ) -> [Action] {
    var result: [Action] = []
    for attachment in attachments {
      if let trashedAt = attachment.trashedAt {
        if now >= trashedAt.addingTimeInterval(trashSeconds(settings)) {
          result.append(.delete(id: attachment.id))
        }
      } else if !settings.keepReceiptsForever, attachment.kind == .receipt,
        !attachment.keepForever,
        now >= attachment.addedAt.addingTimeInterval(TimeInterval(receiptGraceDays * 86_400))
      {
        result.append(.moveToTrash(id: attachment.id, at: now))
      }
    }
    return result
  }

  /// Whole days left before a row in the trash is deleted, never below zero; `nil` when the row
  /// is not in the trash.
  public static func daysLeftInTrash(
    _ attachment: AttachedFile, settings: AttachmentSettings, now: Date
  ) -> Int? {
    guard let trashedAt = attachment.trashedAt else { return nil }
    let left = trashedAt.addingTimeInterval(trashSeconds(settings)).timeIntervalSince(now)
    return max(0, Int((left / 86_400).rounded(.up)))
  }

  /// What the owner is told about a row whose file may be gone.
  public enum Availability: Equatable, Sendable {
    case present
    /// The file is not in the folder, and a rule or the owner removed it after the copy the row
    /// came from was made: «удалено по правилу хранения», not an error.
    case removedByRule
    /// A file kept for good that is not there: a real loss.
    case missing
  }

  /// A restored old copy names files that were deleted afterwards by the trash, the receipt rule
  /// or the owner; none of that is damage. Only a file the owner pinned (`keepForever`) that is
  /// not there is reported as lost.
  public static func availability(of attachment: AttachedFile, fileExists: Bool) -> Availability {
    if fileExists { return .present }
    return attachment.keepForever ? .missing : .removedByRule
  }
}

extension AttachmentRetention {
  private static func trashSeconds(_ settings: AttachmentSettings) -> TimeInterval {
    TimeInterval(max(0, settings.trashDays) * 86_400)
  }
}

/// Which files the rows still name. A file goes only when no row does.
public enum AttachmentReferences {
  /// Rows per hash.
  public static func counts(_ attachments: [AttachedFile]) -> [String: Int] {
    var counts: [String: Int] = [:]
    for attachment in attachments { counts[attachment.contentHash, default: 0] += 1 }
    return counts
  }

  /// The hashes whose last row is among `ids`: the files that may be removed with them.
  public static func filesFreed(deleting ids: Set<UUID>, from all: [AttachedFile]) -> Set<String> {
    let counts = counts(all)
    var removed: [String: Int] = [:]
    for attachment in all where ids.contains(attachment.id) {
      removed[attachment.contentHash, default: 0] += 1
    }
    return Set(removed.filter { counts[$0.key] == $0.value }.keys)
  }

  /// Files in the folder that no row names: left by a row that was removed with its owner.
  public static func orphanFiles(stored: Set<String>, attachments: [AttachedFile]) -> Set<String> {
    stored.subtracting(counts(attachments).keys)
  }

  /// Hashes named by rows whose file is not in the folder.
  public static func absentFiles(stored: Set<String>, attachments: [AttachedFile]) -> Set<String> {
    Set(counts(attachments).keys).subtracting(stored)
  }
}
