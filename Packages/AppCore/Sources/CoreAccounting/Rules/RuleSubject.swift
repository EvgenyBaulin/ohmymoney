import CoreKit
import Foundation

/// What a rule looks at: an operation reduced to the facts the conditions speak of. It is
/// made from a stored operation (history, «Применить к прошлым») or from the entry line before
/// anything is saved (the rule seen before Enter), so both are judged by the same code.
public struct RuleSubject: Hashable, Sendable {
  /// A part with the facts a condition about a category or a description may need.
  public struct PartFacts: Hashable, Sendable {
    /// `nil` for the part of an entry line that is not saved yet.
    public var partId: UUID?
    /// The category and the category it hangs on: «Кафе» is in the scope of both «Кафе» and
    /// its subcategory «Кофе».
    public var categoryScope: Set<UUID>
    /// The part's own description, folded.
    public var text: String

    public init(partId: UUID?, categoryScope: Set<UUID> = [], text: String = "") {
      self.partId = partId
      self.categoryScope = categoryScope
      self.text = text
    }
  }

  public var kind: TransactionKind
  public var placeId: UUID?
  public var accountId: UUID?
  public var cardId: UUID?
  /// The total of the operation in rubles; `nil` while a line has no amount.
  public var amountRubE4: AmountE4?
  /// 1 = Monday … 7 = Sunday, in the zone the operation was recorded in.
  public var weekday: Int?
  public var minuteOfDay: Int?
  /// The place's name and aliases and the operation's description, folded (`NameKey`).
  public var texts: [String]
  public var parts: [PartFacts]

  public init(
    kind: TransactionKind, placeId: UUID? = nil, accountId: UUID? = nil, cardId: UUID? = nil,
    amountRubE4: AmountE4? = nil, weekday: Int? = nil, minuteOfDay: Int? = nil,
    texts: [String] = [], parts: [PartFacts] = []
  ) {
    self.kind = kind
    self.placeId = placeId
    self.accountId = accountId
    self.cardId = cardId
    self.amountRubE4 = amountRubE4
    self.weekday = weekday
    self.minuteOfDay = minuteOfDay
    self.texts = texts.map(NameKey.fold).filter { !$0.isEmpty }
    self.parts = parts
  }

  /// A stored operation. `places` names the places so the text of a rule can find «Пятёрочка»
  /// by its name or an alias.
  public init(
    entry: TransactionEntry, places: [UUID: Place] = [:], tree: CategoryTree = CategoryTree(),
    calendar: CalendarContext = .system
  ) {
    let transaction = entry.transaction
    let zoneId = transaction.timeZoneId
    let day = calendar.day(of: transaction.occurredAt, recordedIn: zoneId)
    let clock = calendar.timeOfDay(transaction.occurredAt, recordedIn: zoneId)
    var texts: [String] = []
    if let place = transaction.placeId.flatMap({ places[$0] }) {
      texts.append(place.name)
      texts.append(contentsOf: place.aliases)
    }
    if let note = transaction.note { texts.append(note) }
    self.init(
      kind: transaction.kind, placeId: transaction.placeId,
      accountId: transaction.paymentMethodId, cardId: transaction.cardId,
      amountRubE4: transaction.amountRubE4, weekday: calendar.weekdayIndex(day),
      minuteOfDay: clock.hour * 60 + clock.minute, texts: texts,
      parts: entry.parts.map { part in
        PartFacts(
          partId: part.id, categoryScope: Self.scope(of: part.categoryId, in: tree),
          text: NameKey.fold(part.note ?? ""))
      })
  }

  static func scope(of categoryId: UUID?, in tree: CategoryTree) -> Set<UUID> {
    guard let category = tree.category(categoryId) else {
      return categoryId.map { [$0] } ?? []
    }
    var scope: Set<UUID> = [category.id]
    if let parentId = category.parentId { scope.insert(parentId) }
    return scope
  }
}
