import CoreKit
import Foundation

/// One piece of a pasted list: the text it was read from and what the bank's templates made
/// of it (nil: not a bank's text, the line stays a line).
public struct BankListItem: Hashable, Sendable {
  public var source: String
  public var message: BankMessage?

  public init(source: String, message: BankMessage?) {
    self.source = source
    self.message = message
  }
}

/// What a paste into the entry field is.
public enum PasteReading: Hashable, Sendable {
  /// Not a bank's text: it goes into the field exactly as it was pasted.
  case plain(String)
  /// One text of a bank: the field is filled with `BankMessage.suggestedLine`.
  case message(BankMessage)
  /// Several operations at once, a list from the bank's app: shown
  /// with ticks, the ticked ones are written in one step.
  case list([BankListItem])
}

extension BankTextParser {
  /// A text split into the operations it holds.
  ///
  /// Texts are separated by blank lines. A block of several lines is read one line at a time
  /// when at least two of its lines are bank texts (a list of pushes), then as rows of a history
  /// when at least two lines have a signed amount; otherwise the whole block is one text (a
  /// letter that puts the card, the amount and the shop on lines of their own).
  public func items(in text: String, today: DateOnly? = nil) -> [BankListItem] {
    let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
      .map { String($0).trimmingCharacters(in: .whitespaces) }
    var blocks: [[String]] = [[]]
    for line in lines {
      if line.isEmpty {
        if !(blocks.last?.isEmpty ?? true) { blocks.append([]) }
      } else {
        blocks[blocks.count - 1].append(line)
      }
    }
    var items: [BankListItem] = []
    for block in blocks where !block.isEmpty {
      if block.count == 1 {
        items.append(BankListItem(source: block[0], message: parse(block[0], today: today)))
        continue
      }
      let strict = block.map { parse($0, today: today) }
      if strict.compactMap({ $0 }).count >= 2 {
        items += zip(block, strict).map { BankListItem(source: $0, message: $1) }
        continue
      }
      let rows = block.map { readHistoryRow($0, today: today) }
      if rows.compactMap({ $0 }).count >= 2 {
        items += zip(block, rows).map { BankListItem(source: $0, message: $1) }
        continue
      }
      let whole = block.joined(separator: "\n")
      if let message = parse(whole, today: today) {
        items.append(BankListItem(source: whole, message: message))
      } else {
        items += block.map { BankListItem(source: $0, message: nil) }
      }
    }
    return items
  }

  /// What a paste is. A text is a bank's only when at least half of its pieces are.
  public func reading(of pasted: String, today: DateOnly? = nil) -> PasteReading {
    guard pasted.count <= Self.longestPaste else { return .plain(pasted) }
    let items = items(in: pasted, today: today)
    let recognised = items.filter { $0.message != nil }
    guard !recognised.isEmpty, recognised.count * 2 >= items.count else { return .plain(pasted) }
    if items.count == 1, let message = items[0].message { return .message(message) }
    return .list(items)
  }

  /// A paste longer than this is a document, not a few pushes.
  static let longestPaste = 200_000
}

/// An operation already in the ledger, as far as the duplicate check needs it.
public struct KnownOperation: Hashable, Sendable {
  public var day: DateOnly
  public var kind: TransactionKind
  public var money: Money

  public init(day: DateOnly, kind: TransactionKind, money: Money) {
    self.day = day
    self.kind = kind
    self.money = money
  }
}

/// One line of the list that is about to be written, with its tick.
public struct BankImportCandidate: Hashable, Sendable {
  public var message: BankMessage
  /// The ledger already has an operation of the same day, kind and amount.
  public var isDuplicate: Bool
  /// Ticked unless it is a duplicate.
  public var isSelected: Bool
}

public enum BankImport {
  /// The recognised pieces of a list, each marked when the ledger already has it. An operation
  /// of the ledger matches only one piece: two coffees of the same price on a day with one
  /// of them written leave the other ticked. A piece without a day is today's.
  public static func candidates(
    _ items: [BankListItem], known: [KnownOperation], today: DateOnly
  ) -> [BankImportCandidate] {
    var remaining: [KnownOperation: Int] = [:]
    for operation in known { remaining[operation, default: 0] += 1 }
    return items.compactMap { item in
      guard let message = item.message else { return nil }
      let key = KnownOperation(
        day: message.day ?? today, kind: message.kind, money: message.money)
      let duplicate = (remaining[key] ?? 0) > 0
      if duplicate { remaining[key, default: 0] -= 1 }
      return BankImportCandidate(message: message, isDuplicate: duplicate, isSelected: !duplicate)
    }
  }
}

/// A card or account the owner keeps the last four digits of (`cards`, accounts).
public struct CardDigits: Hashable, Sendable {
  public var cardId: UUID?
  public var accountId: UUID
  public var last4: String

  public init(cardId: UUID? = nil, accountId: UUID, last4: String) {
    self.cardId = cardId
    self.accountId = accountId
    self.last4 = last4
  }
}

/// Finds the card of a bank text by the last four digits it carries.
public struct CardDigitsIndex: Sendable {
  public enum Lookup: Hashable, Sendable {
    /// The text carries no digits.
    case none
    case card(CardDigits)
    /// Two cards end the same way: the owner is asked which.
    case ambiguous([CardDigits])
    /// Nobody has these digits yet: the owner is asked once, and the answer is kept.
    case unknown(last4: String)
  }

  private let byDigits: [String: [CardDigits]]

  public init(_ cards: [CardDigits]) {
    byDigits = Dictionary(grouping: cards.filter { $0.last4.count == 4 }, by: \.last4)
  }

  public func lookup(_ message: BankMessage) -> Lookup {
    guard let last4 = message.cardLast4 else { return .none }
    switch byDigits[last4] ?? [] {
    case []: return .unknown(last4: last4)
    case let single where single.count == 1: return .card(single[0])
    case let several: return .ambiguous(several)
    }
  }
}
