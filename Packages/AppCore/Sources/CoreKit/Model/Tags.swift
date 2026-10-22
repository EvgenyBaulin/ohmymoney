import Foundation

/// A free label on a part of an operation: «#отпуск», «#подарки». Not an event: an event is a
/// period with a budget, a tag is a word and nothing else, and one part may carry several.
public struct Tag: Identifiable, Hashable, Sendable, Codable {
  public var id: UUID
  /// As first typed, without the «#»: «Отпуск». Two names with the same `TagName.key` are one
  /// tag.
  public var name: String
  public var archived: Bool
  public var createdAt: Date

  public init(id: UUID = UUID(), name: String, archived: Bool = false, createdAt: Date = Date()) {
    self.id = id
    self.name = name
    self.archived = archived
    self.createdAt = createdAt
  }
}

/// One row of the link between a part and a tag. Tags live on parts, so a split receipt can
/// carry «#день-рождения-маши» on the gift alone.
public struct PartTag: Hashable, Sendable, Codable {
  public var partId: UUID
  public var tagId: UUID

  public init(partId: UUID, tagId: UUID) {
    self.partId = partId
    self.tagId = tagId
  }
}

/// How a tag is written and compared.
public enum TagName {
  public static let maxLength = 40

  /// The name `raw` stands for, without the «#» and the spaces around it, or `nil` when it is
  /// no tag: letters, digits, «-» and «_» only, at least one letter (so «#1» stays a number),
  /// at most `maxLength` characters.
  public static func normalized(_ raw: String) -> String? {
    var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.hasPrefix("#") { text.removeFirst() }
    guard !text.isEmpty, text.count <= maxLength, text.contains(where: \.isLetter),
      text.allSatisfy({ isTagCharacter($0) })
    else { return nil }
    return text
  }

  /// What two spellings are compared by: «#Отпуск» and «#отпуск», «#Ёлка» and «#елка» are one.
  public static func key(_ name: String) -> String { NameKey.fold(name) }

  public static func isTagCharacter(_ character: Character) -> Bool {
    character.isLetter || character.isNumber || character == "-" || character == "_"
  }
}

/// Names of the stored forms the schema step will give these types, kept in one place so the
/// table, the CSV files and the archive agree.
public enum TagStorage {
  public static let tagsTable = "tags"
  public static let partTagsTable = "part_tags"
  public static let tagsCSV = "tags.csv"
  public static let partTagsCSV = "part_tags.csv"
}
