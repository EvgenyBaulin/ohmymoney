import CoreKit
import Foundation

/// Identity belongs to a kind of record: an income and a payment may have the same UUID.
public enum NamesakeKind: String, Hashable, Sendable {
  case expectedIncome, scheduledPayment, goal, event, person, place, account, card, bank, category
}

/// A record's name and history, supplied by its owner. No proposed action changes this value.
public struct NamesakeRecord: Hashable, Sendable, Identifiable {
  public var kind: NamesakeKind
  public var id: UUID
  public var name: String
  public var archived: Bool
  public var period: NameHistoryPeriod?

  public init(
    kind: NamesakeKind, id: UUID, name: String, archived: Bool = false,
    history: [MonthKey] = []
  ) {
    self.kind = kind
    self.id = id
    self.name = name
    self.archived = archived
    self.period = NameHistoryPeriod(months: history)
  }
}

/// Actual history bounds, never a due date or today's month substituted for missing history.
public struct NameHistoryPeriod: Hashable, Sendable {
  public let first: MonthKey
  public let last: MonthKey

  public init?(months: [MonthKey]) {
    guard let first = months.min(), let last = months.max() else { return nil }
    self.first = first
    self.last = last
  }

  public func title(locale: Locale) -> String {
    let formatter = DateFormatter()
    formatter.locale = locale
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = CalendarContext.utc.timeZone
    formatter.dateFormat = "LLL yyyy"
    func month(_ value: MonthKey) -> String {
      formatter.string(from: CalendarContext.utc.startOfDay(value.firstDay))
    }
    return first == last ? month(first) : "\(month(first)) – \(month(last))"
  }
}

public struct NamesakeProposal: Hashable, Sendable, Identifiable {
  public enum Choice: Hashable, Sendable {
    case renameNew, renameExisting, renameArchived, restoreArchived
  }

  public let existing: NamesakeRecord
  /// The same key from either side of the pair; independent of their names and archive state.
  public let id: String
  /// The matching alias, when the collision is not with the record's canonical name.
  public let existingSpelling: String?
  public let newSpelling: String?
  public let restoresAccount: Bool

  init(
    existing: NamesakeRecord, id: String, existingSpelling: String? = nil,
    newSpelling: String? = nil, restoresAccount: Bool = false
  ) {
    self.existing = existing
    self.id = id
    self.existingSpelling = existingSpelling
    self.newSpelling = newSpelling
    self.restoresAccount = restoresAccount
  }

  public var choices: [Choice] {
    if existing.archived, [.account, .card, .bank].contains(existing.kind) {
      return [.renameNew, .renameArchived, .restoreArchived]
    }
    return existing.archived ? [.renameArchived, .restoreArchived] : [.renameNew, .renameExisting]
  }

  /// Nil without history: the interface can still offer a name typed by the owner.
  public func archivedName(locale: Locale) -> String? {
    guard existing.archived, let period = existing.period else { return nil }
    return "\(existingSpelling ?? existing.name) (\(period.title(locale: locale)))"
  }
}

/// Names are advice, never a reason to refuse a write, revive a row or replace its identity.
public enum Namesakes {
  /// Stored in the dataset settings as sorted, newline-separated pair keys.
  public static let hiddenPairsKey = "namesakes.hiddenPairs"

  public static func proposals(
    for record: NamesakeRecord, among records: [NamesakeRecord], hidden: String = ""
  ) -> [NamesakeProposal] {
    let name = NameKey.fold(record.name)
    guard !name.isEmpty else { return [] }
    let hidden = Set(hidden.split(whereSeparator: \.isNewline).map(String.init))
    return records.compactMap { other in
      guard record.kind == other.kind, record.id != other.id,
        NameKey.fold(other.name) == name
      else { return nil }
      let key = pairKey(record, other)
      guard !hidden.contains(key) else { return nil }
      return NamesakeProposal(existing: other, id: key)
    }
  }

  public static func pairKey(_ lhs: NamesakeRecord, _ rhs: NamesakeRecord) -> String {
    [
      "\(lhs.kind.rawValue):\(lhs.id.uuidString.lowercased())",
      "\(rhs.kind.rawValue):\(rhs.id.uuidString.lowercased())",
    ].sorted().joined(separator: "|")
  }

  public static func hiding(_ pair: String, in stored: String) -> String {
    var pairs = Set(stored.split(whereSeparator: \.isNewline).map(String.init))
    pairs.insert(pair)
    return pairs.sorted().joined(separator: "\n")
  }
}
