import Foundation

/// What the owner made of a text of a bank once: the place, the description, the category and
/// for whom. A field the owner left empty is `nil` and fills nothing.
public struct BankTextFill: Hashable, Sendable, Codable {
  public var placeId: UUID?
  public var note: String?
  public var categoryId: UUID?
  public var forWhom: ForWhom?
  public var forPersonId: UUID?

  public init(
    placeId: UUID? = nil, note: String? = nil, categoryId: UUID? = nil, forWhom: ForWhom? = nil,
    forPersonId: UUID? = nil
  ) {
    self.placeId = placeId
    let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
    self.note = (trimmed?.isEmpty ?? true) ? nil : trimmed
    self.categoryId = categoryId
    self.forWhom = forWhom
    self.forPersonId = forPersonId
  }

  /// What an operation of the owner's says. A split operation teaches only its place and its
  /// description: which of its parts the next line would be is not known.
  public init(entry: TransactionEntry) {
    let single = entry.parts.count == 1 ? entry.parts.first : nil
    self.init(
      placeId: entry.transaction.placeId, note: entry.transaction.note,
      categoryId: single?.categoryId, forWhom: single?.forWhom,
      forPersonId: single?.forPersonId)
  }

  /// Nothing to fill.
  public var isEmpty: Bool {
    placeId == nil && note == nil && categoryId == nil && forPersonId == nil
      && (forWhom == nil || forWhom == .me)
  }
}

/// The bank's texts the owner has already written as operations of his own, remembered per
/// account: «SAMPLE CAFE» of the card of one bank, once matched with a coffee typed by hand as
/// «Кофейня у дома · Кафе · для партнёра», fills the next line of the same text with the same
/// fields, without a question. One memory serves every way a bank's text comes in — a statement
/// of any format and a text a bank sent on its own (an SMS, a push).
///
/// What is kept is the folded text of the bank (letters and digits only), never a line or a
/// message. The operations a pair filled are kept too, so the owner's later edit of one of them
/// teaches the pair anew. Stored as JSON in the `settings` table (`statement.learned`), so it
/// travels in the archive and leaves with one step of ⌘Z together with the write that taught it;
/// a copy with the names taken out drops it whole.
public struct BankTextMemory: Hashable, Sendable, Codable {
  public static let settingsKey = "statement.learned"
  public static let currentVersion = 1
  /// More pairs than this keep the latest ones: it is a habit, not a ledger.
  public static let capacity = 1_000
  /// Operations remembered for re-learning by an edit, latest kept.
  public static let operationsCapacity = 3_000

  /// Where a text was seen: the account, and its bank. An account without a bank is a bank of
  /// its own: `bankId` is `nil` and the pair is found by the account only.
  public struct Scope: Hashable, Sendable {
    public var accountId: UUID
    public var bankId: UUID?

    public init(accountId: UUID, bankId: UUID? = nil) {
      self.accountId = accountId
      self.bankId = bankId
    }
  }

  public struct Item: Hashable, Sendable, Codable {
    public var account: UUID
    public var bank: UUID?
    /// An expense and an income of the same name are different things («Иван П.» paid back
    /// and «Иван П.» paid to).
    public var kind: TransactionKind
    /// `textKey` of the bank's text.
    public var text: String
    public var fill: BankTextFill
  }

  public private(set) var version: Int
  public private(set) var items: [String: Item]
  /// Keys of `items` in the order they were last taught or used, oldest first.
  public private(set) var order: [String]
  /// Operation id → key of the pair that filled it or was learned from it.
  public private(set) var operations: [String: String]
  public private(set) var operationOrder: [String]

  public init() {
    version = Self.currentVersion
    items = [:]
    order = []
    operations = [:]
    operationOrder = []
  }

  /// The key a bank's text is compared by: letters and digits only, lower case, «ё» as «е» —
  /// the same squeeze the shop names of auto entry use, so a statement's «SAMPLE CAFE» and an
  /// SMS's «Sample-Cafe» are one text. `nil` without a letter or a digit.
  public static func textKey(_ text: String) -> String? {
    let key = String(NameKey.fold(text).filter { $0.isLetter || $0.isNumber })
    return key.isEmpty ? nil : key
  }

  private static func itemKey(account: UUID, kind: TransactionKind, text: String) -> String {
    account.uuidString + "|" + kind.rawValue + "|" + text
  }

  public var isEmpty: Bool { items.isEmpty }

  /// What the owner made of `text` before: of this very account first; else of another account
  /// of the same bank, the latest taught. A text of another bank is never used.
  public func fill(scope: Scope, kind: TransactionKind, text: String) -> BankTextFill? {
    item(scope: scope, kind: kind, text: text)?.fill
  }

  private func item(scope: Scope, kind: TransactionKind, text: String) -> Item? {
    guard let key = Self.textKey(text) else { return nil }
    if let own = items[Self.itemKey(account: scope.accountId, kind: kind, text: key)] {
      return own
    }
    guard let bank = scope.bankId else { return nil }
    for itemKey in order.reversed() {
      guard let item = items[itemKey] else { continue }
      if item.bank == bank, item.kind == kind, item.text == key { return item }
    }
    return nil
  }

  /// The owner wrote `text` of this account as `fill` (a bank line matched an operation typed by
  /// hand, or he finished an offered one). The latest word wins. `operation` is the operation the
  /// pair stands for, so an edit of it later teaches the pair again. Says whether anything
  /// changed: an empty fill or a text without letters teaches nothing.
  @discardableResult
  public mutating func learn(
    scope: Scope, kind: TransactionKind, text: String, fill: BankTextFill, operation: UUID? = nil
  ) -> Bool {
    guard let key = Self.textKey(text), !fill.isEmpty else { return false }
    let itemKey = Self.itemKey(account: scope.accountId, kind: kind, text: key)
    let item = Item(
      account: scope.accountId, bank: scope.bankId, kind: kind, text: key, fill: fill)
    var changed = false
    if items[itemKey] != item {
      items[itemKey] = item
      changed = true
    }
    touch(itemKey)
    if let operation { changed = link(operation, to: itemKey) || changed }
    trim()
    return changed
  }

  /// A line was filled from what was learned of `text`: the operation is remembered so the
  /// owner's edit of it corrects the pair. Says whether anything changed.
  @discardableResult
  public mutating func filled(
    operation: UUID, scope: Scope, kind: TransactionKind, text: String
  ) -> Bool {
    guard let key = Self.textKey(text),
      let item = item(scope: scope, kind: kind, text: text)
    else { return false }
    // A pair found through another account of the same bank is copied to this one, so the
    // owner's correction here does not change what the other account does.
    let itemKey = Self.itemKey(account: scope.accountId, kind: kind, text: key)
    var changed = false
    if items[itemKey] == nil {
      items[itemKey] = Item(
        account: scope.accountId, bank: scope.bankId, kind: kind, text: key, fill: item.fill)
      changed = true
    }
    touch(itemKey)
    changed = link(operation, to: itemKey) || changed
    trim()
    return changed
  }

  /// Whether an edit of the operation teaches anything.
  public func remembers(operation: UUID) -> Bool {
    operations[operation.uuidString].flatMap { items[$0] } != nil
  }

  /// The owner edited an operation that a pair filled or was learned from: what he wrote now is
  /// what the text means from now on. Says whether anything changed.
  @discardableResult
  public mutating func relearn(operation: UUID, fill: BankTextFill) -> Bool {
    guard let itemKey = operations[operation.uuidString], var item = items[itemKey],
      !fill.isEmpty, item.fill != fill
    else { return false }
    item.fill = fill
    items[itemKey] = item
    touch(itemKey)
    return true
  }

  private mutating func touch(_ itemKey: String) {
    if order.last == itemKey { return }
    order.removeAll { $0 == itemKey }
    order.append(itemKey)
  }

  private mutating func link(_ operation: UUID, to itemKey: String) -> Bool {
    let id = operation.uuidString
    let changed = operations[id] != itemKey
    operations[id] = itemKey
    if operationOrder.last != id {
      operationOrder.removeAll { $0 == id }
      operationOrder.append(id)
    }
    return changed
  }

  private mutating func trim() {
    var forgot = false
    while order.count > Self.capacity {
      items[order.removeFirst()] = nil
      forgot = true
    }
    while operationOrder.count > Self.operationsCapacity {
      operations[operationOrder.removeFirst()] = nil
    }
    // An operation of a forgotten pair teaches nothing any more.
    if forgot {
      let gone = Set(operations.filter { items[$0.value] == nil }.map(\.key))
      for id in gone { operations[id] = nil }
      operationOrder.removeAll { gone.contains($0) }
    }
  }

  public func encoded() -> String? {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) }
  }

  /// The stored memory; an empty one for nothing, a text that does not read, or a version newer
  /// than this build knows (a later build's memory is left for that build, not misread).
  public static func decoded(_ text: String?) -> BankTextMemory {
    guard let data = text?.data(using: .utf8),
      let memory = try? JSONDecoder().decode(BankTextMemory.self, from: data),
      memory.version <= currentVersion
    else { return BankTextMemory() }
    return memory
  }
}
